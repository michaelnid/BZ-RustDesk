#!/bin/bash
# ============================================================
# BZ RustDesk Server - Update-Script
# Aktualisiert hbbs + hbbr auf die neueste Version
# Bestehende Schlüssel und Konfiguration bleiben erhalten
# ============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="/opt/rustdesk"
GITHUB_API="https://api.github.com/repos/rustdesk/rustdesk-server/releases/latest"

log()   { echo -e "${GREEN}[OK]${NC}  $*"; }
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[FEHLER]${NC} $*"; exit 1; }

# Root-Prüfung
if [[ $EUID -ne 0 ]]; then
    error "Dieses Script muss als root ausgeführt werden."
fi

# Prüfen ob Installation vorhanden
if [[ ! -f "$INSTALL_DIR/hbbs" ]]; then
    error "Keine RustDesk-Installation unter $INSTALL_DIR gefunden."
fi

# Architektur erkennen
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ZIP_ARCH="amd64"    ;;
    aarch64) ZIP_ARCH="arm64v8"  ;;
    armv7l)  ZIP_ARCH="armv7"    ;;
    *) error "Nicht unterstützte Architektur: $ARCH" ;;
esac

# Aktuelle Version lesen
CURRENT_VERSION="unbekannt"
if [[ -f "$INSTALL_DIR/version.txt" ]]; then
    CURRENT_VERSION=$(grep "^RUSTDESK_VERSION=" "$INSTALL_DIR/version.txt" | cut -d'=' -f2)
fi
info "Installierte Version: $CURRENT_VERSION"

# Neueste Version abrufen
info "Prüfe auf Updates..."
LATEST_VERSION=$(curl -sL "$GITHUB_API" | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
if [[ -z "$LATEST_VERSION" ]]; then
    error "Version konnte nicht von GitHub abgerufen werden."
fi
info "Neueste Version: $LATEST_VERSION"

# Vergleich
if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
    log "RustDesk Server ist bereits auf dem neuesten Stand ($CURRENT_VERSION)."
    exit 0
fi

echo ""
echo -e "${BOLD}Update verfügbar: $CURRENT_VERSION -> $LATEST_VERSION${NC}"
read -rp "Update jetzt durchführen? (j/N): " CONFIRM
[[ "${CONFIRM,,}" == "j" ]] || { echo "Abgebrochen."; exit 0; }

# Download
BASE_URL="https://github.com/rustdesk/rustdesk-server/releases/download/${LATEST_VERSION}"
ZIP_NAME="rustdesk-server-linux-${ZIP_ARCH}.zip"
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

info "Lade $ZIP_NAME herunter..."
wget -q --show-progress -O "$TMP_DIR/$ZIP_NAME" "${BASE_URL}/${ZIP_NAME}" || \
    error "Download fehlgeschlagen."

# Entpacken
unzip -o "$TMP_DIR/$ZIP_NAME" -d "$TMP_DIR/extract" > /dev/null 2>&1

EXTRACT_SUBDIR=$(find "$TMP_DIR/extract" -name "hbbs" -type f -printf '%h\n' | head -1)
if [[ -z "$EXTRACT_SUBDIR" ]]; then
    error "hbbs-Binary nicht im ZIP gefunden."
fi

# Services stoppen
info "Services werden gestoppt..."
systemctl stop rustdesk-hbbs rustdesk-hbbr

# Alte Binaries sichern
cp "$INSTALL_DIR/hbbs" "$INSTALL_DIR/hbbs.bak" 2>/dev/null || true
cp "$INSTALL_DIR/hbbr" "$INSTALL_DIR/hbbr.bak" 2>/dev/null || true

# Neue Binaries kopieren
cp "$EXTRACT_SUBDIR/hbbs" "$INSTALL_DIR/hbbs"
cp "$EXTRACT_SUBDIR/hbbr" "$INSTALL_DIR/hbbr"
if [[ -f "$EXTRACT_SUBDIR/rustdesk-utils" ]]; then
    cp "$EXTRACT_SUBDIR/rustdesk-utils" "$INSTALL_DIR/rustdesk-utils"
fi

chmod +x "$INSTALL_DIR/hbbs" "$INSTALL_DIR/hbbr"
chown -R rustdesk:rustdesk "$INSTALL_DIR"

# Version aktualisieren
sed -i "s/^RUSTDESK_VERSION=.*/RUSTDESK_VERSION=${LATEST_VERSION}/" "$INSTALL_DIR/version.txt"

# Services starten
info "Services werden gestartet..."
systemctl start rustdesk-hbbs rustdesk-hbbr

# Prüfen ob Services laufen
sleep 2
if systemctl is-active --quiet rustdesk-hbbs && systemctl is-active --quiet rustdesk-hbbr; then
    log "Update erfolgreich: $CURRENT_VERSION -> $LATEST_VERSION"
    # Backup-Binaries entfernen
    rm -f "$INSTALL_DIR/hbbs.bak" "$INSTALL_DIR/hbbr.bak"
else
    warn "Services starten nicht korrekt. Rollback wird durchgeführt..."
    cp "$INSTALL_DIR/hbbs.bak" "$INSTALL_DIR/hbbs" 2>/dev/null || true
    cp "$INSTALL_DIR/hbbr.bak" "$INSTALL_DIR/hbbr" 2>/dev/null || true
    systemctl start rustdesk-hbbs rustdesk-hbbr
    error "Update fehlgeschlagen. Alte Version wurde wiederhergestellt."
fi

echo ""
echo -e "${BOLD}Service-Status:${NC}"
systemctl status rustdesk-hbbs --no-pager -l | head -5
echo ""
systemctl status rustdesk-hbbr --no-pager -l | head -5
echo ""
