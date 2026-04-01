#!/bin/bash
# ============================================================
# BZ RustDesk Server - Installations-Script
# Unterstützt: Debian 12 (Bookworm), x86_64 / arm64
# Keine Docker-Abhängigkeit - läuft als systemd-Service
# ============================================================

set -euo pipefail

# --- Farben ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Konfiguration ---
INSTALL_DIR="/opt/rustdesk"
SERVICE_USER="rustdesk"
LOG_FILE="/var/log/rustdesk-install.log"
GITHUB_API="https://api.github.com/repos/rustdesk/rustdesk-server/releases/latest"

# --- Hilfsfunktionen ---
log()   { echo -e "${GREEN}[OK]${NC}  $*" | tee -a "$LOG_FILE"; }
info()  { echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[FEHLER]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }

banner() {
    echo -e "${CYAN}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║        BZ RustDesk Server Setup          ║"
    echo "  ║   Selbst-gehostete Remote-Desktop-Lösung ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${NC}"
}

# --- Root-Prüfung ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Dieses Script muss als root ausgeführt werden. Bitte 'sudo bash install.sh' verwenden."
    fi
}

# --- OS-Prüfung ---
check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Betriebssystem konnte nicht erkannt werden."
    fi
    source /etc/os-release
    if [[ "$ID" != "debian" ]]; then
        warn "Dieses Script wurde für Debian entwickelt. Erkanntes OS: $PRETTY_NAME"
        read -rp "Trotzdem fortfahren? (j/N): " CONTINUE
        [[ "${CONTINUE,,}" == "j" ]] || error "Installation abgebrochen."
    fi
    info "Betriebssystem: $PRETTY_NAME"
}

# --- Architektur-Erkennung ---
detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  DEB_ARCH="amd64"  ;;
        aarch64) DEB_ARCH="arm64"  ;;
        armv7l)  DEB_ARCH="armhf"  ;;
        i386|i686) DEB_ARCH="i386" ;;
        *) error "Nicht unterstützte Architektur: $ARCH" ;;
    esac
    info "Architektur: $ARCH ($DEB_ARCH)"
}

# --- Neueste Version abrufen ---
fetch_version() {
    info "Neueste RustDesk-Server-Version wird abgerufen..."
    RUSTDESK_VERSION=$(curl -sL "$GITHUB_API" | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$RUSTDESK_VERSION" ]]; then
        error "Version konnte nicht von GitHub abgerufen werden. Internetverbindung prüfen."
    fi
    info "Gefundene Version: $RUSTDESK_VERSION"
}

# --- Benutzerabfragen ---
ask_config() {
    echo ""
    echo -e "${BOLD}Konfiguration${NC}"
    echo "--------------------------------------------"

    # Domain-Abfrage
    read -rp "Domain (leer lassen für reinen IP-Betrieb): " DOMAIN
    DOMAIN="${DOMAIN// /}"

    # Server-IP ermitteln
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 api.ipify.org || echo "unbekannt")
    info "Öffentliche IP: $SERVER_IP"

    echo ""
}

# --- Abhängigkeiten installieren ---
install_dependencies() {
    info "Systempakete werden aktualisiert..."
    apt-get update -qq >> "$LOG_FILE" 2>&1
    apt-get install -y -qq curl wget ufw unzip >> "$LOG_FILE" 2>&1
    log "Basispakete installiert."
}

# --- Systembenutzer anlegen ---
create_user() {
    if ! id "$SERVICE_USER" &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
        log "Systembenutzer '$SERVICE_USER' angelegt."
    else
        info "Systembenutzer '$SERVICE_USER' existiert bereits."
    fi
}

# --- RustDesk .deb Pakete herunterladen und installieren ---
install_rustdesk() {
    info "RustDesk Server $RUSTDESK_VERSION wird heruntergeladen..."

    local BASE_URL="https://github.com/rustdesk/rustdesk-server/releases/download/${RUSTDESK_VERSION}"
    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    trap "rm -rf $TMP_DIR" EXIT

    local HBBS_DEB="rustdesk-server-hbbs_${RUSTDESK_VERSION}_${DEB_ARCH}.deb"
    local HBBR_DEB="rustdesk-server-hbbr_${RUSTDESK_VERSION}_${DEB_ARCH}.deb"

    wget -q --show-progress -O "$TMP_DIR/$HBBS_DEB" "${BASE_URL}/${HBBS_DEB}" || \
        error "Download von hbbs fehlgeschlagen."
    wget -q --show-progress -O "$TMP_DIR/$HBBR_DEB" "${BASE_URL}/${HBBR_DEB}" || \
        error "Download von hbbr fehlgeschlagen."

    dpkg -i "$TMP_DIR/$HBBS_DEB" >> "$LOG_FILE" 2>&1 || apt-get install -f -y -qq >> "$LOG_FILE" 2>&1
    dpkg -i "$TMP_DIR/$HBBR_DEB" >> "$LOG_FILE" 2>&1 || apt-get install -f -y -qq >> "$LOG_FILE" 2>&1

    log "RustDesk Server Pakete installiert."

    # Arbeitsverzeichnis anlegen und Berechtigungen setzen
    mkdir -p "$INSTALL_DIR"
    chown -R "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR"
}

# --- systemd Services konfigurieren ---
configure_services() {
    info "systemd-Services werden konfiguriert..."

    # hbbs-Service (ID/Rendezvous-Server)
    cat > /etc/systemd/system/rustdesk-hbbs.service << EOF
[Unit]
Description=RustDesk ID/Rendezvous Server (hbbs)
Documentation=https://rustdesk.com/docs/en/self-host/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/hbbs
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=rustdesk-hbbs
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${INSTALL_DIR}
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    # hbbr-Service (Relay-Server)
    cat > /etc/systemd/system/rustdesk-hbbr.service << EOF
[Unit]
Description=RustDesk Relay Server (hbbr)
Documentation=https://rustdesk.com/docs/en/self-host/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/hbbr
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=rustdesk-hbbr
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${INSTALL_DIR}
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable rustdesk-hbbs rustdesk-hbbr >> "$LOG_FILE" 2>&1
    systemctl start rustdesk-hbbs rustdesk-hbbr

    log "Services gestartet und für Autostart aktiviert."
}

# --- Firewall konfigurieren ---
configure_firewall() {
    info "Firewall (ufw) wird konfiguriert..."

    # SSH absichern - zuerst erlauben, damit Verbindung nicht getrennt wird
    ufw allow OpenSSH >> "$LOG_FILE" 2>&1

    # RustDesk Ports
    ufw allow 21115/tcp comment "RustDesk NAT-Typ-Test"  >> "$LOG_FILE" 2>&1
    ufw allow 21116/tcp comment "RustDesk ID-Server TCP" >> "$LOG_FILE" 2>&1
    ufw allow 21116/udp comment "RustDesk Heartbeat UDP"  >> "$LOG_FILE" 2>&1
    ufw allow 21117/tcp comment "RustDesk Relay-Server"  >> "$LOG_FILE" 2>&1
    ufw allow 21118/tcp comment "RustDesk WebSocket"     >> "$LOG_FILE" 2>&1
    ufw allow 21119/tcp comment "RustDesk WebSocket TLS" >> "$LOG_FILE" 2>&1

    # Aktivieren (ohne interaktive Bestätigung)
    ufw --force enable >> "$LOG_FILE" 2>&1

    log "Firewall konfiguriert."
}

# --- Let's Encrypt SSL (optional, wenn Domain angegeben) ---
configure_ssl() {
    if [[ -z "$DOMAIN" ]]; then
        return
    fi

    info "Let's Encrypt SSL-Zertifikat für '$DOMAIN' wird eingerichtet..."

    # certbot installieren
    apt-get install -y -qq certbot >> "$LOG_FILE" 2>&1

    # Port 80 temporär für ACME-Challenge öffnen
    ufw allow 80/tcp >> "$LOG_FILE" 2>&1
    ufw allow 443/tcp >> "$LOG_FILE" 2>&1

    # Zertifikat beziehen (kein Email-Flag, standalone-Modus)
    if certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        -d "$DOMAIN" >> "$LOG_FILE" 2>&1; then
        log "SSL-Zertifikat erfolgreich ausgestellt: /etc/letsencrypt/live/$DOMAIN/"

        # Automatische Erneuerung via systemd-Timer aktivieren
        systemctl enable certbot.timer  >> "$LOG_FILE" 2>&1
        systemctl start certbot.timer   >> "$LOG_FILE" 2>&1
        log "Automatische Zertifikatserneuerung aktiviert."
    else
        warn "SSL-Zertifikat konnte nicht ausgestellt werden. DNS-Eintrag für '$DOMAIN' korrekt gesetzt?"
        warn "Manuell nachholen: certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d $DOMAIN"
    fi
}

# --- Schlüssel auslesen ---
get_public_key() {
    info "Öffentlicher Schlüssel wird ermittelt..."
    sleep 5  # Kurz warten bis hbbs den Schlüssel generiert hat

    local KEY_FILE
    KEY_FILE=$(find "$INSTALL_DIR" -name "*.pub" 2>/dev/null | head -1)

    if [[ -n "$KEY_FILE" && -s "$KEY_FILE" ]]; then
        PUBLIC_KEY=$(cat "$KEY_FILE")
    else
        # Fallback: Key aus systemd-Journal lesen
        PUBLIC_KEY=$(journalctl -u rustdesk-hbbs --no-pager -n 50 2>/dev/null | \
            grep -oP '(?<=key: )[\w+/=]+' | tail -1 || echo "")
    fi
}

# --- Versions-Info speichern ---
save_version_info() {
    cat > "$INSTALL_DIR/version.txt" << EOF
RUSTDESK_VERSION=${RUSTDESK_VERSION}
INSTALL_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DOMAIN=${DOMAIN:-}
SERVER_IP=${SERVER_IP:-}
EOF
    chown "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR/version.txt"
}

# --- Abschlusszusammenfassung ---
print_summary() {
    local SERVER_ADDR="${DOMAIN:-$SERVER_IP}"

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║          Installation abgeschlossen!             ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}RustDesk Client Konfiguration:${NC}"
    echo "  ID-Server:     $SERVER_ADDR"
    echo "  Relay-Server:  $SERVER_ADDR"
    if [[ -n "${PUBLIC_KEY:-}" ]]; then
        echo "  Public Key:    $PUBLIC_KEY"
    else
        echo "  Public Key:    Unter $INSTALL_DIR/*.pub abrufbar"
        echo "                 Alternativ: journalctl -u rustdesk-hbbs | grep 'key'"
    fi
    echo ""
    echo -e "${BOLD}Service-Status prüfen:${NC}"
    echo "  systemctl status rustdesk-hbbs"
    echo "  systemctl status rustdesk-hbbr"
    echo ""
    echo -e "${BOLD}Logs ansehen:${NC}"
    echo "  journalctl -u rustdesk-hbbs -f"
    echo "  journalctl -u rustdesk-hbbr -f"
    echo ""
    echo -e "${BOLD}Deinstallation:${NC}"
    echo "  bash /opt/rustdesk/uninstall.sh"
    echo ""
    echo -e "Installations-Log: ${LOG_FILE}"
    echo ""
}

# --- Uninstall-Script in das Installationsverzeichnis kopieren ---
install_uninstaller() {
    if [[ -f "$(dirname "$0")/uninstall.sh" ]]; then
        cp "$(dirname "$0")/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
        chmod +x "$INSTALL_DIR/uninstall.sh"
        log "Uninstall-Script in $INSTALL_DIR/ kopiert."
    fi
}

# --- Hauptprogramm ---
main() {
    # Log-Datei anlegen
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"

    banner
    check_root
    check_os
    detect_arch
    fetch_version
    ask_config
    install_dependencies
    create_user
    install_rustdesk
    configure_services
    configure_firewall
    configure_ssl
    get_public_key
    save_version_info
    install_uninstaller
    print_summary
}

main "$@"
