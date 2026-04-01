# BZ RustDesk Server

Selbst-gehosteter RustDesk-Relay- und ID-Server für datenschutzkonforme Remote-Desktop-Verbindungen.

## Techstack

| Komponente | Technologie |
|---|---|
| ID-Server | RustDesk Server OSS `hbbs` |
| Relay-Server | RustDesk Server OSS `hbbr` |
| Prozess-Management | systemd |
| Firewall | ufw |
| SSL (optional) | Let's Encrypt via certbot |
| Betriebssystem | Debian 12 (Bookworm) |

## Mindest-Serveranforderungen

| Ressource | Minimum |
|---|---|
| vCPU | 1 |
| RAM | 1 GB |
| Disk | 10 GB |
| OS | Debian 12 (Bookworm) |
| Netzwerk | Statische öffentliche IP empfohlen |

### Benötigte Ports

| Port | Protokoll | Zweck |
|---|---|---|
| 22 | TCP | SSH (Verwaltung) |
| 21115 | TCP | NAT-Typ-Test |
| 21116 | TCP + UDP | ID-Server / Heartbeat |
| 21117 | TCP | Relay-Server |
| 21118 | TCP | WebSocket |
| 21119 | TCP | WebSocket TLS |
| 80 | TCP | Let's Encrypt ACME (nur bei Domain) |
| 443 | TCP | HTTPS (nur bei Domain) |

**Plesk Git kompatibel:** Nein (reine Server-Installation via SSH)

## Installation

### One-Line Install

```bash
curl -sL https://raw.githubusercontent.com/michaelnid/BZ-RustDesk/main/install.sh | sudo bash
```

### Manuelle Installation

```bash
git clone https://github.com/michaelnid/BZ-RustDesk.git
cd BZ-RustDesk
sudo bash install.sh
```

Das Script führt automatisch folgende Schritte durch:
1. Systemvoraussetzungen prüfen
2. Neueste RustDesk-Server-Version von GitHub laden
3. `.deb`-Pakete für `hbbs` und `hbbr` installieren
4. systemd-Services einrichten und starten
5. Firewall (ufw) konfigurieren
6. Optional: Let's Encrypt SSL-Zertifikat einrichten
7. Public Key und Client-Konfiguration ausgeben

## Deinstallation

```bash
sudo bash /opt/rustdesk/uninstall.sh
```

Entfernt vollständig: Services, Pakete, Verzeichnisse, Benutzer, Firewall-Regeln und optional Let's Encrypt-Zertifikate.

## Client-Konfiguration nach der Installation

Nach erfolgreicher Installation gibt das Script folgende Werte für die RustDesk-Client-Einstellung aus:

- **ID-Server:** `<deine-domain-oder-ip>`
- **Relay-Server:** `<deine-domain-oder-ip>`
- **Public Key:** Wird angezeigt und liegt unter `/opt/rustdesk/*.pub`

Im RustDesk-Client: `Einstellungen → Netzwerk → ID/Relay Server`
