#!/bin/bash
# ============================================================
# BZ RustDesk Server - Vollständiges Deinstallations-Script
# ============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}[OK]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[FEHLER]${NC} $*"; exit 1; }

# Root-Prüfung
if [[ $EUID -ne 0 ]]; then
    error "Dieses Script muss als root ausgeführt werden."
fi

echo ""
echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}║     BZ RustDesk Server - Deinstallation          ║${NC}"
echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Folgende Komponenten werden vollständig entfernt:${NC}"
echo "  - systemd Services (rustdesk-hbbs, rustdesk-hbbr)"
echo "  - Installierte .deb Pakete (hbbs, hbbr)"
echo "  - Installationsverzeichnis /opt/rustdesk"
echo "  - Systembenutzer 'rustdesk'"
echo "  - Firewall-Regeln (RustDesk-Ports)"
echo "  - Installations-Logs"
echo ""
read -rp "Wirklich deinstallieren? (j/N): " CONFIRM
[[ "${CONFIRM,,}" == "j" ]] || { echo "Abgebrochen."; exit 0; }

echo ""

# Services stoppen und deaktivieren
for SVC in rustdesk-hbbs rustdesk-hbbr; do
    if systemctl is-active --quiet "$SVC" 2>/dev/null; then
        systemctl stop "$SVC"
        log "Service '$SVC' gestoppt."
    fi
    if systemctl is-enabled --quiet "$SVC" 2>/dev/null; then
        systemctl disable "$SVC"
        log "Service '$SVC' deaktiviert."
    fi
    if [[ -f "/etc/systemd/system/$SVC.service" ]]; then
        rm -f "/etc/systemd/system/$SVC.service"
        log "Service-Datei '/etc/systemd/system/$SVC.service' entfernt."
    fi
done

systemctl daemon-reload

# .deb Pakete deinstallieren
for PKG in rustdesk-server-hbbs rustdesk-server-hbbr rustdesk-server-utils; do
    if dpkg -l "$PKG" &>/dev/null 2>&1; then
        apt-get remove -y -qq "$PKG" 2>/dev/null || true
        log "Paket '$PKG' entfernt."
    fi
done

# Installationsverzeichnis entfernen
if [[ -d "/opt/rustdesk" ]]; then
    rm -rf "/opt/rustdesk"
    log "Verzeichnis /opt/rustdesk entfernt."
fi

# Systembenutzer entfernen
if id "rustdesk" &>/dev/null; then
    userdel rustdesk 2>/dev/null || true
    log "Systembenutzer 'rustdesk' entfernt."
fi

# Firewall-Regeln entfernen
if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
    for RULE in "21115/tcp" "21116/tcp" "21116/udp" "21117/tcp" "21118/tcp" "21119/tcp"; do
        ufw delete allow "$RULE" >> /dev/null 2>&1 || true
    done
    log "Firewall-Regeln (RustDesk-Ports) entfernt."
fi

# Let's Encrypt Zertifikat entfernen (optional)
if command -v certbot &>/dev/null; then
    read -rp "Let's Encrypt Zertifikate ebenfalls entfernen? (j/N): " DEL_CERT
    if [[ "${DEL_CERT,,}" == "j" ]]; then
        certbot delete --non-interactive 2>/dev/null || true
        log "Let's Encrypt Zertifikate entfernt."
    fi
fi

# Installations-Log löschen
if [[ -f "/var/log/rustdesk-install.log" ]]; then
    rm -f "/var/log/rustdesk-install.log"
    log "Installations-Log entfernt."
fi

echo ""
echo -e "${GREEN}${BOLD}Deinstallation abgeschlossen. RustDesk Server wurde vollständig entfernt.${NC}"
echo ""
