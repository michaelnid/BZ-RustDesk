#!/bin/bash
# ============================================================
# BZ RustDesk Server - Installation
# Methode: offizielle ZIP-Binaries (SHA-256-geprüft) + gehärtetes systemd
# Unterstützt: Debian 13/12 (Ubuntu 22.04+ funktioniert ebenfalls), amd64/arm64/armv7/i386
#
# Bei bestehender Installation wird an update.sh übergeben
# (Update/Migration/Reparatur - Schlüssel bleiben erhalten).
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh" || {
    echo "FEHLER: $SCRIPT_DIR/lib/common.sh fehlt - bitte das komplette Repository verwenden." >&2
    exit 1
}

DOMAIN=""
DOMAIN_SET=0
SERVER_IP=""

usage() {
    cat <<EOF
Verwendung: sudo bash install.sh [Optionen]

  --domain NAME     Domain/Hostname für die Clients (sonst Abfrage; leer = IP-Betrieb)
  --no-firewall     ufw nicht anfassen (z.B. bei Provider-Firewall oder nftables)
  -y, --yes         Ohne Rückfragen (Standardantworten verwenden)
  -h, --help        Diese Hilfe
EOF
}

parse_args() {
    while (($#)); do
        case $1 in
            --domain)
                (($# >= 2)) || die "--domain benötigt einen Wert."
                DOMAIN=$2
                DOMAIN_SET=1
                shift
                ;;
            --domain=*) DOMAIN=${1#*=}; DOMAIN_SET=1 ;;
            --no-firewall) MANAGE_FIREWALL=0 ;;
            -y | --yes) ASSUME_YES=1 ;;
            -h | --help) usage; exit 0 ;;
            *) die "Unbekannte Option: $1 (siehe --help)" ;;
        esac
        shift
    done
}

ask_config() {
    echo
    printf '%sKonfiguration%s\n' "$BOLD" "$NC"
    echo "--------------------------------------------"
    if ((!DOMAIN_SET && !ASSUME_YES)); then
        prompt_input "Domain für die Clients (leer lassen für reinen IP-Betrieb): "
        DOMAIN=$REPLY
    fi
    DOMAIN=${DOMAIN//[[:space:]]/}
    DOMAIN=${DOMAIN,,}
    if [[ -n $DOMAIN ]] && ! valid_host "$DOMAIN"; then
        die "Ungültige Domain: '$DOMAIN'"
    fi

    SERVER_IP=$(detect_public_ip)
    info "Öffentliche IPv4: $SERVER_IP"

    if [[ -n $DOMAIN && $SERVER_IP != unbekannt ]]; then
        local resolved
        resolved=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)
        if [[ " $resolved " != *" $SERVER_IP "* ]]; then
            warn "DNS: $DOMAIN zeigt auf '${resolved% }' statt auf $SERVER_IP - DNS-Eintrag prüfen."
        fi
    fi
    echo
}

configure_firewall() {
    local rule ssh_ports others status default_answer

    if ((!MANAGE_FIREWALL)); then
        warn "Firewall wird nicht verwaltet (--no-firewall). Bitte diese Ports freigeben:"
        print_port_list
        return 0
    fi
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        warn "firewalld ist aktiv - ufw wird nicht eingerichtet. Bitte diese Ports in firewalld freigeben:"
        print_port_list
        return 0
    fi

    ensure_packages ufw
    info "RustDesk-Ports werden in ufw freigegeben..."
    for rule in "${FIREWALL_RULES[@]}"; do
        ufw allow "${rule%%|*}" comment "${rule#*|}" >>"$LOG_FILE" 2>&1
    done

    status=$(LC_ALL=C ufw status 2>/dev/null || true)
    if [[ $status == "Status: active"* ]]; then
        log "RustDesk-Ports in der aktiven ufw-Firewall freigegeben (bestehende Regeln unverändert)."
        return 0
    fi

    # ufw ist inaktiv: nur nach Prüfung und Rückfrage einschalten
    ssh_ports=$(detect_ssh_ports)
    others=$(list_other_listeners "$ssh_ports")
    echo
    info "ufw ist derzeit nicht aktiv."
    info "Beim Aktivieren werden freigegeben: SSH (Port ${ssh_ports// /, }) und die RustDesk-Ports."
    default_answer=j
    if [[ -n $others ]]; then
        warn "Diese weiteren Dienste lauschen öffentlich und wären danach NICHT mehr erreichbar:"
        while IFS= read -r rule; do printf '         %s\n' "$rule"; done <<<"$others"
        warn "Vorher ggf. mit 'ufw allow <port>/tcp' freigeben."
        default_answer=n
    fi
    if ask_yes_no "ufw jetzt aktivieren?" "$default_answer"; then
        for rule in $ssh_ports; do
            ufw allow "$rule/tcp" comment "SSH" >>"$LOG_FILE" 2>&1
        done
        ufw --force enable >>"$LOG_FILE" 2>&1
        log "ufw aktiviert (SSH-Port ${ssh_ports// /, } bleibt erreichbar)."
    else
        warn "ufw bleibt deaktiviert. Die RustDesk-Regeln sind hinterlegt und greifen beim Aktivieren."
    fi
}

install_failed() {
    show_service_diagnostics
    warn "Installation unvollständig. Aufräumen mit: sudo bash $INSTALL_DIR/uninstall.sh"
}

print_summary() {
    local addr=${DOMAIN:-$SERVER_IP}
    read_public_key
    echo
    printf '%s%s============================================%s\n' "$GREEN" "$BOLD" "$NC"
    printf '%s%s     Installation abgeschlossen!%s\n' "$GREEN" "$BOLD" "$NC"
    printf '%s%s============================================%s\n' "$GREEN" "$BOLD" "$NC"
    echo
    printf '%sVersion:%s %s\n\n' "$BOLD" "$NC" "$RUSTDESK_VERSION"
    printf '%sRustDesk-Client (Einstellungen > Netzwerk > ID/Relay-Server):%s\n' "$BOLD" "$NC"
    printf '  ID-Server:     %s\n' "$addr"
    printf '  Relay-Server:  %s\n' "$addr"
    printf '  Key:           %s\n' "${PUBLIC_KEY:-sudo cat $DATA_DIR/id_ed25519.pub}"
    echo
    echo "  Der Key wird von ID- UND Relay-Server erzwungen - Clients ohne Key werden abgewiesen."
    echo
    printf '%sDateien:%s\n' "$BOLD" "$NC"
    echo "  Programme:   $INSTALL_DIR (root)"
    echo "  Daten/Keys:  $DATA_DIR (nur Dienstbenutzer)"
    echo "  Key-Backup:  $BACKUP_DIR"
    echo
    printf '%sBefehle:%s\n' "$BOLD" "$NC"
    echo "  Status:      systemctl status rustdesk-hbbs rustdesk-hbbr"
    echo "  Logs:        journalctl -u rustdesk-hbbs -u rustdesk-hbbr -f"
    echo "  Update:      sudo bash $INSTALL_DIR/update.sh"
    echo "  Deinstall:   sudo bash $INSTALL_DIR/uninstall.sh"
    echo
    echo "Log: $LOG_FILE"
    echo
}

main() {
    bz_init
    parse_args "$@"
    banner "Installation"
    require_root
    init_log "$@"
    acquire_lock
    check_os
    check_systemd
    detect_arch

    if installation_present; then
        warn "Es ist bereits eine Installation vorhanden ($INSTALL_DIR)."
        info "Update, Migration und Reparatur laufen über update.sh - Schlüssel bleiben dabei erhalten."
        if ask_yes_no "update.sh jetzt ausführen?" j; then
            local args=()
            if ((ASSUME_YES)); then args+=(--yes); fi
            cleanup_tmp
            exec bash "$SCRIPT_DIR/update.sh" "${args[@]}"
        fi
        die "Abgebrochen - bestehende Installation wurde nicht verändert."
    fi

    ask_config
    ensure_packages "${BASE_PACKAGES[@]}"
    fetch_release_info
    download_release

    FAILURE_HOOK=install_failed
    ensure_service_user
    ensure_data_dir
    if [[ -s $DATA_DIR/id_ed25519 ]]; then
        info "Vorhandener Schlüssel in $DATA_DIR wird weiterverwendet."
    fi
    install_binaries "$STAGE_BIN_DIR"
    install_management_scripts "$SCRIPT_DIR"
    harden_install_dir
    install_units
    log "systemd-Dienste eingerichtet (gehärtet)."

    RUSTDESK_VERSION=$RELEASE_TAG
    INSTALL_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    write_version_file

    info "Dienste werden gestartet..."
    start_services || die "Dienste konnten nicht korrekt gestartet werden."
    FAILURE_HOOK=""

    backup_keys
    configure_firewall
    print_summary
}

main "$@"
