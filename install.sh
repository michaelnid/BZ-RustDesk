#!/bin/bash
# ============================================================
# BZ RustDesk Server - Installations-Script
# Methode: ZIP-Binaries + systemd (kein Docker)
# Unterstützt: Debian 12 (Bookworm), Ubuntu 22+, x86_64 / arm64
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
    echo "  ============================================"
    echo "         BZ RustDesk Server Setup"
    echo "    Selbst-gehostete Remote-Desktop-Lösung"
    echo "  ============================================"
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
    if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
        warn "Dieses Script wurde für Debian/Ubuntu entwickelt. Erkanntes OS: $PRETTY_NAME"
        read -rp "Trotzdem fortfahren? (j/N): " CONTINUE
        [[ "${CONTINUE,,}" == "j" ]] || error "Installation abgebrochen."
    fi
    info "Betriebssystem: $PRETTY_NAME"
}

# --- Architektur-Erkennung ---
detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ZIP_ARCH="amd64"    ;;
        aarch64) ZIP_ARCH="arm64v8"  ;;
        armv7l)  ZIP_ARCH="armv7"    ;;
        *) error "Nicht unterstützte Architektur: $ARCH" ;;
    esac
    info "Architektur: $ARCH ($ZIP_ARCH)"
}

# --- Vorhandene Installation prüfen ---
check_existing() {
    if [[ -f "$INSTALL_DIR/hbbs" || -f "$INSTALL_DIR/hbbr" ]]; then
        warn "Vorhandene Installation erkannt in $INSTALL_DIR"
        echo "   Bitte zuerst deinstallieren: sudo bash $INSTALL_DIR/uninstall.sh"
        echo "   Oder für ein Update: sudo bash $INSTALL_DIR/update.sh"
        read -rp "Trotzdem neu installieren (überschreibt vorhandene)? (j/N): " OVERWRITE
        [[ "${OVERWRITE,,}" == "j" ]] || error "Installation abgebrochen."
        # Bestehende Services stoppen
        systemctl stop rustdesk-hbbs 2>/dev/null || true
        systemctl stop rustdesk-hbbr 2>/dev/null || true
    fi
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

# --- RustDesk ZIP herunterladen und entpacken ---
install_rustdesk() {
    info "RustDesk Server $RUSTDESK_VERSION wird heruntergeladen..."

    local BASE_URL="https://github.com/rustdesk/rustdesk-server/releases/download/${RUSTDESK_VERSION}"
    local ZIP_NAME="rustdesk-server-linux-${ZIP_ARCH}.zip"
    local TMP_DIR
    TMP_DIR=$(mktemp -d)

    wget -q --show-progress -O "$TMP_DIR/$ZIP_NAME" "${BASE_URL}/${ZIP_NAME}" || \
        error "Download fehlgeschlagen: ${BASE_URL}/${ZIP_NAME}"

    # Installationsverzeichnis anlegen
    mkdir -p "$INSTALL_DIR"

    # Entpacken
    unzip -o "$TMP_DIR/$ZIP_NAME" -d "$TMP_DIR/extract" >> "$LOG_FILE" 2>&1

    # Binaries finden und nach /opt/rustdesk/ kopieren
    # ZIP-Struktur: amd64/hbbs, amd64/hbbr, amd64/rustdesk-utils
    local EXTRACT_SUBDIR
    EXTRACT_SUBDIR=$(find "$TMP_DIR/extract" -name "hbbs" -type f -printf '%h\n' | head -1)
    if [[ -z "$EXTRACT_SUBDIR" ]]; then
        error "hbbs-Binary nicht im ZIP gefunden."
    fi

    cp "$EXTRACT_SUBDIR/hbbs" "$INSTALL_DIR/hbbs"
    cp "$EXTRACT_SUBDIR/hbbr" "$INSTALL_DIR/hbbr"
    # rustdesk-utils kopieren falls vorhanden
    if [[ -f "$EXTRACT_SUBDIR/rustdesk-utils" ]]; then
        cp "$EXTRACT_SUBDIR/rustdesk-utils" "$INSTALL_DIR/rustdesk-utils"
    fi

    chmod +x "$INSTALL_DIR/hbbs" "$INSTALL_DIR/hbbr"
    chown -R "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR"

    # Aufräumen
    rm -rf "$TMP_DIR"

    log "RustDesk Server Binaries installiert nach $INSTALL_DIR/"
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
ExecStart=${INSTALL_DIR}/hbbs
Restart=always
RestartSec=10
LimitNOFILE=1000000
StandardOutput=journal
StandardError=journal
SyslogIdentifier=rustdesk-hbbs

# Sicherheitshärtung
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
ExecStart=${INSTALL_DIR}/hbbr
Restart=always
RestartSec=10
LimitNOFILE=1000000
StandardOutput=journal
StandardError=journal
SyslogIdentifier=rustdesk-hbbr

# Sicherheitshärtung
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

    # SSH absichern
    ufw allow OpenSSH >> "$LOG_FILE" 2>&1

    # RustDesk Ports
    ufw allow 21115/tcp comment "RustDesk NAT-Typ-Test"  >> "$LOG_FILE" 2>&1
    ufw allow 21116/tcp comment "RustDesk ID-Server TCP" >> "$LOG_FILE" 2>&1
    ufw allow 21116/udp comment "RustDesk Heartbeat UDP" >> "$LOG_FILE" 2>&1
    ufw allow 21117/tcp comment "RustDesk Relay-Server"  >> "$LOG_FILE" 2>&1
    ufw allow 21118/tcp comment "RustDesk WebSocket"     >> "$LOG_FILE" 2>&1
    ufw allow 21119/tcp comment "RustDesk WebSocket TLS" >> "$LOG_FILE" 2>&1

    ufw --force enable >> "$LOG_FILE" 2>&1

    log "Firewall konfiguriert."
}

# --- Let's Encrypt SSL (optional) ---
configure_ssl() {
    if [[ -z "$DOMAIN" ]]; then
        return
    fi

    info "Let's Encrypt SSL-Zertifikat für '$DOMAIN' wird eingerichtet..."

    apt-get install -y -qq certbot >> "$LOG_FILE" 2>&1

    ufw allow 80/tcp  >> "$LOG_FILE" 2>&1
    ufw allow 443/tcp >> "$LOG_FILE" 2>&1

    if certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        -d "$DOMAIN" >> "$LOG_FILE" 2>&1; then
        log "SSL-Zertifikat erfolgreich ausgestellt: /etc/letsencrypt/live/$DOMAIN/"
        systemctl enable certbot.timer  >> "$LOG_FILE" 2>&1
        systemctl start certbot.timer   >> "$LOG_FILE" 2>&1
        log "Automatische Zertifikatserneuerung aktiviert."
    else
        warn "SSL-Zertifikat konnte nicht ausgestellt werden. DNS-Eintrag prüfen."
        warn "Manuell nachholen: certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d $DOMAIN"
    fi
}

# --- Schlüssel auslesen ---
get_public_key() {
    info "Warte auf Schlüsselgenerierung..."
    sleep 3

    local KEY_FILE
    KEY_FILE=$(find "$INSTALL_DIR" -name "*.pub" -type f 2>/dev/null | head -1)

    if [[ -n "$KEY_FILE" && -s "$KEY_FILE" ]]; then
        PUBLIC_KEY=$(cat "$KEY_FILE")
    else
        PUBLIC_KEY=""
        warn "Public Key noch nicht generiert. Prüfe nach Start: cat $INSTALL_DIR/id_ed25519.pub"
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

# --- Hilfs-Scripts ins Installationsverzeichnis kopieren ---
install_scripts() {
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

    for SCRIPT in uninstall.sh update.sh; do
        if [[ -f "$SCRIPT_DIR/$SCRIPT" ]]; then
            cp "$SCRIPT_DIR/$SCRIPT" "$INSTALL_DIR/$SCRIPT"
            chmod +x "$INSTALL_DIR/$SCRIPT"
            log "$SCRIPT nach $INSTALL_DIR/ kopiert."
        fi
    done
}

# --- Abschlusszusammenfassung ---
print_summary() {
    local SERVER_ADDR="${DOMAIN:-$SERVER_IP}"

    echo ""
    echo -e "${GREEN}${BOLD}============================================${NC}"
    echo -e "${GREEN}${BOLD}     Installation abgeschlossen!${NC}"
    echo -e "${GREEN}${BOLD}============================================${NC}"
    echo ""
    echo -e "${BOLD}Version:${NC} $RUSTDESK_VERSION"
    echo ""
    echo -e "${BOLD}RustDesk Client Konfiguration:${NC}"
    echo "  ID-Server:     $SERVER_ADDR"
    echo "  Relay-Server:  $SERVER_ADDR"
    if [[ -n "${PUBLIC_KEY:-}" ]]; then
        echo "  Public Key:    $PUBLIC_KEY"
    else
        echo "  Public Key:    cat $INSTALL_DIR/id_ed25519.pub"
    fi
    echo ""
    echo -e "${BOLD}Service-Befehle:${NC}"
    echo "  Status:    systemctl status rustdesk-hbbs rustdesk-hbbr"
    echo "  Neustart:  systemctl restart rustdesk-hbbs rustdesk-hbbr"
    echo "  Logs:      journalctl -u rustdesk-hbbs -f"
    echo ""
    echo -e "${BOLD}Verwaltung:${NC}"
    echo "  Update:      sudo bash $INSTALL_DIR/update.sh"
    echo "  Deinstall:   sudo bash $INSTALL_DIR/uninstall.sh"
    echo ""
    echo -e "Installations-Log: ${LOG_FILE}"
    echo ""
}

# --- Hauptprogramm ---
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"

    banner
    check_root
    check_os
    detect_arch
    check_existing
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
    install_scripts
    print_summary
}

main "$@"
