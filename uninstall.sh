#!/bin/bash
# ============================================================
# BZ RustDesk Server - Deinstallation
# Bietet vorher eine Sicherung von Schlüssel + Datenbank an.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh" || {
    echo "FEHLER: $SCRIPT_DIR/lib/common.sh fehlt." >&2
    exit 1
}

DATA_FILES_FOUND=()

usage() {
    cat <<EOF
Verwendung: sudo bash uninstall.sh [Optionen]

  -y, --yes    Ohne Rückfragen (Schlüssel werden dabei vorher gesichert)
  -h, --help   Diese Hilfe
EOF
}

parse_args() {
    while (($#)); do
        case $1 in
            -y | --yes) ASSUME_YES=1 ;;
            -h | --help) usage; exit 0 ;;
            *) die "Unbekannte Option: $1 (siehe --help)" ;;
        esac
        shift
    done
}

# Nutzdaten (Schlüssel, Datenbank, .env ...) aus neuer und ggf. alter Struktur
collect_data_files() {
    local entry
    DATA_FILES_FOUND=()
    shopt -s dotglob nullglob
    for entry in "$DATA_DIR"/*; do
        if [[ -f $entry && ! -L $entry ]]; then DATA_FILES_FOUND+=("$entry"); fi
    done
    for entry in "$INSTALL_DIR"/*; do
        if ! is_managed_name "${entry##*/}" && [[ -f $entry && ! -L $entry ]]; then
            DATA_FILES_FOUND+=("$entry")
        fi
    done
    shopt -u dotglob nullglob
}

backup_data() {
    local stage archive f
    make_tmp_dir stage
    for f in "${DATA_FILES_FOUND[@]}"; do cp -p -- "$f" "$stage/"; done
    archive="$UNINSTALL_BACKUP_DIR/rustdesk-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    (umask 077 && tar -czf "$archive" -C "$stage" .)
    log "Sicherung erstellt: $archive"
    echo "         Wiederherstellen vor einer Neuinstallation:"
    echo "         sudo mkdir -p $DATA_DIR && sudo tar -xzf $archive -C $DATA_DIR"
}

remove_dir() {
    local dir=$1
    [[ -n $dir && $dir != / ]] || die "Ungültiger Pfad: '$dir'"
    if [[ -d $dir ]]; then
        rm -rf -- "$dir"
        log "Verzeichnis $dir entfernt."
    fi
}

main() {
    local domain svc rule
    bz_init
    parse_args "$@"
    require_root
    acquire_lock
    banner "Deinstallation"

    domain=$(read_version_value DOMAIN)
    domain=${domain,,}
    collect_data_files

    printf '%s%sFolgendes wird entfernt:%s\n' "$YELLOW" "$BOLD" "$NC"
    echo "  - systemd-Dienste rustdesk-hbbs / rustdesk-hbbr"
    echo "  - Programme und Scripts in $INSTALL_DIR"
    echo "  - Schlüssel und Datenbank in $DATA_DIR"
    echo "  - Systembenutzer '$SERVICE_USER'"
    echo "  - RustDesk-Firewall-Regeln (ufw; die SSH-Freigabe bleibt bestehen)"
    echo "  - Logs ($LOG_FILE)"
    echo
    if ((${#DATA_FILES_FOUND[@]})); then
        warn "Ohne Sicherung des Schlüssels müssen nach einer Neuinstallation alle Clients neu konfiguriert werden."
    fi
    confirm "Wirklich deinstallieren?" || { echo "Abgebrochen."; exit 0; }
    echo

    if ((${#DATA_FILES_FOUND[@]})) &&
        ask_yes_no "Schlüssel und Datenbank vorher nach $UNINSTALL_BACKUP_DIR sichern? (empfohlen)" j; then
        backup_data
    fi

    for svc in "${SERVICES[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc"
            log "Dienst $svc gestoppt."
        fi
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            systemctl disable --quiet "$svc" 2>/dev/null || true
        fi
        if [[ -f $SYSTEMD_DIR/$svc.service ]]; then
            rm -f -- "$SYSTEMD_DIR/$svc.service"
            log "Service-Datei $svc.service entfernt."
        fi
    done
    systemctl daemon-reload
    systemctl reset-failed "${SERVICES[@]}" >/dev/null 2>&1 || true

    remove_dir "$INSTALL_DIR"
    remove_dir "$DATA_DIR"

    if id -u "$SERVICE_USER" >/dev/null 2>&1; then
        userdel "$SERVICE_USER" 2>/dev/null || warn "Benutzer '$SERVICE_USER' konnte nicht entfernt werden."
    fi
    if getent group "$SERVICE_USER" >/dev/null 2>&1; then
        groupdel "$SERVICE_USER" 2>/dev/null || true
    fi
    log "Systembenutzer '$SERVICE_USER' entfernt."

    if command -v ufw >/dev/null 2>&1; then
        # "ufw delete" funktioniert auch bei inaktiver Firewall und unabhängig vom Kommentar
        for rule in "${FIREWALL_RULES[@]}"; do
            ufw delete allow "${rule%%|*}" >/dev/null 2>&1 || true
        done
        log "RustDesk-Firewall-Regeln entfernt."
    fi

    # Altlasten der v1-Installation (Let's Encrypt wurde dort optional eingerichtet)
    if [[ -n $domain ]] && valid_host "$domain" && command -v certbot >/dev/null 2>&1 &&
        [[ -d $LETSENCRYPT_LIVE_DIR/$domain ]]; then
        if ask_yes_no "Let's-Encrypt-Zertifikat für $domain löschen? (nur wenn sonst nicht genutzt)" n; then
            if certbot delete --cert-name "$domain" --non-interactive >/dev/null 2>&1; then
                log "Zertifikat für $domain gelöscht."
            else
                warn "Zertifikat für $domain konnte nicht gelöscht werden."
            fi
        fi
    fi
    if command -v ufw >/dev/null 2>&1 && { ufw_rule_exists 80/tcp || ufw_rule_exists 443/tcp; }; then
        if ask_yes_no "Ports 80/443 in ufw schließen? (nur wenn dort kein Webserver läuft)" n; then
            ufw delete allow 80/tcp >/dev/null 2>&1 || true
            ufw delete allow 443/tcp >/dev/null 2>&1 || true
            log "Ports 80/443 in ufw geschlossen."
        fi
    fi

    if [[ -d $BACKUP_DIR ]]; then
        if ask_yes_no "Automatische Sicherungen in $BACKUP_DIR ebenfalls löschen?" n; then
            remove_dir "$BACKUP_DIR"
        else
            info "Sicherungen bleiben erhalten: $BACKUP_DIR"
        fi
    fi

    rm -f -- "$LOG_FILE" "$LEGACY_LOG_FILE"

    echo
    printf '%s%sDeinstallation abgeschlossen.%s\n' "$GREEN" "$BOLD" "$NC"
    echo
}

main "$@"
