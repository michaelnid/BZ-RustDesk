#!/bin/bash
# ============================================================
# BZ RustDesk Server - Update / Migration / Reparatur
#
#  - aktualisiert die Verwaltungs-Scripts (optional) und hbbs/hbbr
#  - migriert alte Installationen (Daten in /opt/rustdesk) nach
#    /var/lib/rustdesk - Schlüssel und Datenbank bleiben unverändert
#  - automatischer Rollback, wenn die Dienste danach nicht laufen
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh" || {
    echo "FEHLER: $SCRIPT_DIR/lib/common.sh fehlt." >&2
    echo "Alte Installation? Neue Scripts laden - siehe README (Abschnitt 'Update')." >&2
    exit 1
}

ORIG_ARGS=("$@")
SELF_UPDATE=1
FORCE=0
LEGACY_DOMAIN=""
NEW_DOMAIN=""
NEW_DOMAIN_SET=0
LEGACY=0
NEED_BINARIES=0
NEED_UNITS=0
CURRENT_VERSION=""
EXPECTED_KEY_FP=""
EXPECTED_PUB=""
MIGRATION_BACKUP=""
CONFLICT_DIR=""
CREATED_FILES=()
MIGRATED_FILES=()
MOVED_ASIDE=()

usage() {
    cat <<EOF
Verwendung: sudo bash update.sh [Optionen]

  -y, --yes          Ohne Rückfragen
  --force            Binaries und Dienste auch bei gleicher Version neu einrichten (Reparatur)
  --domain NAME      Domain für die Client-Anzeige ändern (leer = IP-Betrieb)
  --no-firewall      ufw nicht anfassen
  --no-self-update   Verwaltungs-Scripts nicht von GitHub aktualisieren
  -h, --help         Diese Hilfe
EOF
}

parse_args() {
    while (($#)); do
        case $1 in
            -y | --yes) ASSUME_YES=1 ;;
            --force) FORCE=1 ;;
            --domain)
                (($# >= 2)) || die "--domain benötigt einen Wert."
                NEW_DOMAIN=$2
                NEW_DOMAIN_SET=1
                shift
                ;;
            --domain=*) NEW_DOMAIN=${1#*=}; NEW_DOMAIN_SET=1 ;;
            --no-firewall) MANAGE_FIREWALL=0 ;;
            --no-self-update) SELF_UPDATE=0 ;;
            -h | --help) usage; exit 0 ;;
            *) die "Unbekannte Option: $1 (siehe --help)" ;;
        esac
        shift
    done
}

# --- Verwaltungs-Scripts von GitHub aktualisieren ---------------------------
self_update_scripts() {
    local tmp src f remote_version changed=0
    make_tmp_dir tmp
    info "Prüfe auf neue Verwaltungs-Scripts..."
    if ! curl -fsSL --proto '=https' --proto-redir '=https' --retry 2 --max-time 60 \
        -o "$tmp/scripts.tar.gz" "$SCRIPTS_TARBALL_URL" 2>>"$LOG_FILE"; then
        warn "Verwaltungs-Scripts konnten nicht geprüft werden - weiter mit v$BZ_SCRIPT_VERSION."
        return 0
    fi
    src="$tmp/src"
    mkdir "$src"
    if ! tar -xzf "$tmp/scripts.tar.gz" -C "$src" --strip-components=1 --no-same-owner 2>>"$LOG_FILE"; then
        warn "Archiv der Verwaltungs-Scripts ungültig - übersprungen."
        return 0
    fi
    for f in "${MANAGEMENT_FILES[@]}"; do
        if [[ ! -f $src/$f || -L $src/$f ]] || ! bash -n "$src/$f" 2>>"$LOG_FILE"; then
            warn "Heruntergeladene Verwaltungs-Scripts unvollständig/fehlerhaft - übersprungen."
            return 0
        fi
        if ! cmp -s "$src/$f" "$INSTALL_DIR/$f"; then changed=1; fi
    done
    if ((!changed)); then
        info "Verwaltungs-Scripts sind aktuell (v$BZ_SCRIPT_VERSION)."
        return 0
    fi
    remote_version=$(script_version_of "$src/lib/common.sh")
    if [[ -z $remote_version ]] || version_gt "$BZ_SCRIPT_VERSION" "$remote_version"; then
        info "Installierte Verwaltungs-Scripts (v$BZ_SCRIPT_VERSION) sind neuer als GitHub (v${remote_version:-?})."
        return 0
    fi
    info "Neue Verwaltungs-Scripts verfügbar: v$BZ_SCRIPT_VERSION -> v$remote_version"
    if ! ask_yes_no "Verwaltungs-Scripts jetzt aktualisieren?" j; then
        return 0
    fi
    install_management_scripts "$src"
    log "Verwaltungs-Scripts aktualisiert - Update wird mit der neuen Version fortgesetzt."
    cleanup_tmp
    exec bash "$INSTALL_DIR/update.sh" --no-self-update "${ORIG_ARGS[@]}"
}

# --- Migration der alten Struktur -------------------------------------------

# Sicherung aller Nutzdaten + Units + version.txt der alten Installation.
create_migration_backup() {
    local stage entry svc
    make_tmp_dir stage
    mkdir -p "$stage/data" "$stage/systemd"
    shopt -s dotglob nullglob
    for entry in "$INSTALL_DIR"/*; do
        if is_managed_name "${entry##*/}"; then continue; fi
        if [[ -f $entry && ! -L $entry ]]; then cp -p -- "$entry" "$stage/data/"; fi
    done
    shopt -u dotglob nullglob
    for svc in "${SERVICES[@]}"; do
        if [[ -f $SYSTEMD_DIR/$svc.service ]]; then cp -p -- "$SYSTEMD_DIR/$svc.service" "$stage/systemd/"; fi
    done
    if [[ -f $VERSION_FILE && ! -L $VERSION_FILE ]]; then cp -p -- "$VERSION_FILE" "$stage/"; fi

    install -d -o root -g root -m 0700 "$BACKUP_DIR"
    MIGRATION_BACKUP="$BACKUP_DIR/rustdesk-vor-migration-$(date +%Y%m%d-%H%M%S).tar.gz"
    (umask 077 && tar -czf "$MIGRATION_BACKUP" -C "$stage" .)
    log "Sicherung der alten Installation: $MIGRATION_BACKUP"
}

# Kopiert (nicht verschiebt) alle Nutzdaten nach DATA_DIR und prüft jede Kopie.
# Die Originale werden erst nach erfolgreichem Start gelöscht.
migrate_legacy_data() {
    local entry name dst
    shopt -s dotglob nullglob
    for entry in "$INSTALL_DIR"/*; do
        name=${entry##*/}
        if is_managed_name "$name"; then continue; fi
        if [[ -L $entry || ! -f $entry ]]; then
            if [[ $name == id_ed25519* ]]; then
                die "$entry ist keine reguläre Datei - Migration aus Sicherheitsgründen abgebrochen."
            fi
            warn "Übersprungen (keine reguläre Datei): $entry"
            continue
        fi
        dst="$DATA_DIR/$name"
        if [[ -e $dst || -L $dst ]]; then
            if [[ -f $dst && ! -L $dst ]] && cmp -s "$entry" "$dst"; then
                MIGRATED_FILES+=("$name")
                continue
            fi
            # Abweichende Datei am Ziel nie überschreiben, sondern beiseitelegen
            if [[ -z $CONFLICT_DIR ]]; then
                CONFLICT_DIR="$BACKUP_DIR/konflikt-$(date +%Y%m%d-%H%M%S)"
                install -d -o root -g root -m 0700 "$BACKUP_DIR" "$CONFLICT_DIR"
            fi
            mv -f -- "$dst" "$CONFLICT_DIR/$name"
            MOVED_ASIDE+=("$name")
            warn "$dst existierte bereits mit anderem Inhalt - verschoben nach $CONFLICT_DIR/"
        fi
        install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0600 "$entry" "$dst"
        CREATED_FILES+=("$name")
        cmp -s "$entry" "$dst" || die "Kopie von $name ist fehlerhaft."
        MIGRATED_FILES+=("$name")
        info "Übernommen: $name"
    done
    shopt -u dotglob nullglob

    if [[ -f $INSTALL_DIR/id_ed25519 ]]; then
        cmp -s "$INSTALL_DIR/id_ed25519" "$DATA_DIR/id_ed25519" ||
            die "Schlüssel in $DATA_DIR stimmt nicht mit dem bisherigen überein."
        log "Schlüsselpaar unverändert nach $DATA_DIR übernommen."
    else
        warn "In der alten Installation wurde kein Schlüssel gefunden - hbbs erzeugt einen neuen."
    fi
}

undo_legacy_migration() {
    local name entry
    for name in "${CREATED_FILES[@]}"; do rm -f -- "$DATA_DIR/$name"; done
    for name in "${MOVED_ASIDE[@]}"; do mv -f -- "$CONFLICT_DIR/$name" "$DATA_DIR/$name"; done
    # Alte Units brauchen Schreibrechte auf Verzeichnis + Daten (Binaries bleiben root)
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
    shopt -s dotglob nullglob
    for entry in "$INSTALL_DIR"/*; do
        if ! is_managed_name "${entry##*/}" && [[ -f $entry && ! -L $entry ]]; then
            chown "$SERVICE_USER:$SERVICE_USER" "$entry"
        fi
    done
    shopt -u dotglob nullglob
}

# --- Rollback ---------------------------------------------------------------
rollback_update() {
    warn "Fehler - vorheriger Zustand wird wiederhergestellt..."
    show_service_diagnostics
    systemctl stop "${SERVICES[@]}" >/dev/null 2>&1
    restore_snapshot
    if ((LEGACY)); then
        undo_legacy_migration
    else
        restore_snapshot_keys
    fi
    if ((SNAPSHOT_WAS_ACTIVE)); then
        systemctl start rustdesk-hbbs
        sleep 2
        systemctl start rustdesk-hbbr
        sleep 3
        if systemctl is-active --quiet rustdesk-hbbs && systemctl is-active --quiet rustdesk-hbbr; then
            log "Rollback abgeschlossen - Dienste laufen wieder mit dem vorherigen Stand."
        else
            warn "Dienste laufen nach dem Rollback nicht. Prüfen: systemctl status rustdesk-hbbs rustdesk-hbbr"
        fi
    else
        log "Rollback abgeschlossen."
    fi
    if [[ -n $MIGRATION_BACKUP ]]; then warn "Sicherung der alten Installation: $MIGRATION_BACKUP"; fi
}

verify_keys_unchanged() {
    local fp pub
    if [[ -z $EXPECTED_KEY_FP ]]; then return 0; fi
    fp=$(file_sha256 "$DATA_DIR/id_ed25519")
    if [[ $fp != "$EXPECTED_KEY_FP" ]]; then
        warn "Privater Schlüssel hat sich verändert!"
        return 1
    fi
    if [[ -n $EXPECTED_PUB ]]; then
        pub=$(tr -d '[:space:]' <"$DATA_DIR/id_ed25519.pub")
        if [[ $pub != "$EXPECTED_PUB" ]]; then
            warn "Öffentlicher Schlüssel hat sich verändert!"
            return 1
        fi
    fi
    log "Schlüssel geprüft: unverändert."
}

print_plan() {
    echo
    printf '%sGeplante Schritte:%s\n' "$BOLD" "$NC"
    if ((LEGACY)); then
        echo "  - Sicherung der alten Installation nach $BACKUP_DIR"
        echo "  - Migration: Schlüssel/Datenbank von $INSTALL_DIR nach $DATA_DIR"
        echo "    (Schlüssel bleiben unverändert - Clients müssen nichts ändern)"
        echo "  - $INSTALL_DIR gehört künftig root (Dienst kann Programme/Scripts nicht mehr ändern)"
    fi
    if ((NEED_BINARIES)); then
        if [[ $CURRENT_VERSION == "$RELEASE_TAG" ]]; then
            echo "  - RustDesk Server $RELEASE_TAG neu aus verifiziertem Release installieren"
        else
            echo "  - RustDesk Server $CURRENT_VERSION -> $RELEASE_TAG (SHA-256-geprüft)"
        fi
    fi
    if ((NEED_UNITS)); then
        echo "  - systemd-Dienste aktualisieren (Härtung, Key-Pflicht auch für das Relay)"
    fi
    if ((MANAGE_FIREWALL)); then
        echo "  - Nicht benötigte Firewall-Freigaben schließen (WebSocket 21118/21119)"
        if ((LEGACY)); then
            echo "  - Ungenutztes Let's-Encrypt-Zertifikat + Ports 80/443 entfernen (nach Rückfrage)"
        fi
    fi
    echo "  - Dienste werden kurz neu gestartet; bei Problemen automatischer Rollback"
    echo
}

print_summary() {
    local addr
    read_public_key
    addr=${DOMAIN:-$SERVER_IP}
    echo
    printf '%s%s============================================%s\n' "$GREEN" "$BOLD" "$NC"
    printf '%s%s     Update abgeschlossen%s\n' "$GREEN" "$BOLD" "$NC"
    printf '%s%s============================================%s\n' "$GREEN" "$BOLD" "$NC"
    echo
    echo "  Version:       $RUSTDESK_VERSION"
    echo "  ID/Relay:      ${addr:-unbekannt}"
    echo "  Key:           ${PUBLIC_KEY:-sudo cat $DATA_DIR/id_ed25519.pub}"
    if [[ -n $EXPECTED_KEY_FP ]]; then
        echo "                 (unverändert - Clients müssen nichts anpassen)"
    fi
    echo "  Daten/Keys:    $DATA_DIR"
    if [[ -n $MIGRATION_BACKUP ]]; then
        echo "  Sicherung:     $MIGRATION_BACKUP"
    fi
    echo
    systemctl --no-pager --lines=0 status "${SERVICES[@]}" 2>/dev/null | grep -E '^\S|Active:' || true
    echo
}

main() {
    bz_init
    parse_args "$@"
    banner "Update"
    require_root
    init_log "$@"
    acquire_lock
    check_systemd
    installation_present || die "Keine Installation gefunden. Bitte install.sh verwenden."
    ensure_packages "${BASE_PACKAGES[@]}"

    if ((SELF_UPDATE)) && [[ $SCRIPT_DIR -ef $INSTALL_DIR ]]; then
        self_update_scripts
    fi

    detect_arch
    CURRENT_VERSION=$(read_version_value RUSTDESK_VERSION)
    CURRENT_VERSION=${CURRENT_VERSION:-unbekannt}
    DOMAIN=$(read_version_value DOMAIN)
    DOMAIN=${DOMAIN,,}
    if [[ -n $DOMAIN ]] && ! valid_host "$DOMAIN"; then DOMAIN=""; fi
    LEGACY_DOMAIN=$DOMAIN
    if ((NEW_DOMAIN_SET)); then
        NEW_DOMAIN=${NEW_DOMAIN//[[:space:]]/}
        NEW_DOMAIN=${NEW_DOMAIN,,}
        if [[ -n $NEW_DOMAIN ]] && ! valid_host "$NEW_DOMAIN"; then die "Ungültige Domain: '$NEW_DOMAIN'"; fi
        if [[ $NEW_DOMAIN != "$DOMAIN" ]]; then info "Domain für die Clients: '${DOMAIN:-IP}' -> '${NEW_DOMAIN:-IP}'"; fi
        DOMAIN=$NEW_DOMAIN
    fi
    SERVER_IP=$(read_version_value SERVER_IP)
    INSTALL_DATE=$(read_version_value INSTALL_DATE)
    info "Installierte Version: $CURRENT_VERSION"
    fetch_release_info

    if legacy_layout_present; then LEGACY=1; fi
    if ((LEGACY || FORCE)) || [[ $CURRENT_VERSION != "$RELEASE_TAG" ]] ||
        [[ ! -x $INSTALL_DIR/hbbs || ! -x $INSTALL_DIR/hbbr ]]; then
        NEED_BINARIES=1
    fi
    if ((LEGACY || FORCE)) || ! units_up_to_date; then
        NEED_UNITS=1
    fi

    if ((!NEED_BINARIES && !NEED_UNITS)); then
        log "RustDesk Server ist aktuell ($CURRENT_VERSION), Dienste sind auf dem neuesten Stand."
        RUSTDESK_VERSION=$CURRENT_VERSION
        harden_install_dir
        install_own_scripts
        ensure_data_dir
        write_version_file
        backup_keys
        remove_obsolete_firewall_rules
        if ! systemctl is-active --quiet rustdesk-hbbs || ! systemctl is-active --quiet rustdesk-hbbr; then
            warn "Mindestens ein Dienst läuft nicht. Reparatur: sudo bash $INSTALL_DIR/update.sh --force"
        fi
        exit 0
    fi

    print_plan
    confirm "Jetzt durchführen?" || { echo "Abgebrochen - nichts verändert."; exit 0; }

    if ((NEED_BINARIES)); then download_release; fi
    ensure_service_user
    if [[ -z $SERVER_IP || $SERVER_IP == unbekannt ]]; then SERVER_IP=$(detect_public_ip); fi

    # Ab hier: jeder Fehler oder Abbruch führt zum Rollback
    take_snapshot
    FAILURE_HOOK=rollback_update
    info "Dienste werden gestoppt..."
    stop_services

    if ((LEGACY)); then
        create_migration_backup
        harden_install_dir
        ensure_data_dir
        migrate_legacy_data
    else
        ensure_data_dir
    fi
    EXPECTED_KEY_FP=$(file_sha256 "$DATA_DIR/id_ed25519")
    EXPECTED_PUB=""
    if [[ -s $DATA_DIR/id_ed25519.pub ]]; then EXPECTED_PUB=$(tr -d '[:space:]' <"$DATA_DIR/id_ed25519.pub"); fi

    if ((NEED_BINARIES)); then
        install_binaries "$STAGE_BIN_DIR"
        RUSTDESK_VERSION=$RELEASE_TAG
    else
        RUSTDESK_VERSION=$CURRENT_VERSION
    fi
    install_units

    info "Dienste werden gestartet..."
    start_services || die "Dienste laufen nach dem Update nicht korrekt."
    verify_keys_unchanged || die "Schlüssel-Prüfung fehlgeschlagen."
    FAILURE_HOOK=""

    # Erfolgreich - jetzt aufräumen
    if ((LEGACY)); then
        local name
        for name in "${MIGRATED_FILES[@]}"; do rm -f -- "$INSTALL_DIR/$name"; done
        rm -f -- "$INSTALL_DIR"/*.bak
        log "Migration abgeschlossen - alte Datenkopien aus $INSTALL_DIR entfernt."
    fi
    harden_install_dir
    install_own_scripts
    if [[ -z $INSTALL_DATE ]]; then INSTALL_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ); fi
    write_version_file
    backup_keys
    remove_obsolete_firewall_rules
    if ((LEGACY)); then legacy_ssl_cleanup "$LEGACY_DOMAIN"; fi
    print_summary
}

main "$@"
