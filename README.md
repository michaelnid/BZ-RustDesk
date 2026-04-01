# BZ RustDesk Server

Selbst-gehosteter RustDesk-Relay- und ID-Server für datenschutzkonforme Remote-Desktop-Verbindungen.
Installiert als native Binaries mit systemd (kein Docker).

## Techstack

| Komponente | Technologie |
|---|---|
| ID-Server | RustDesk Server OSS `hbbs` |
| Relay-Server | RustDesk Server OSS `hbbr` |
| Prozess-Management | systemd (gehärtet) |
| Firewall | ufw |
| SSL (optional) | Let's Encrypt via certbot |
| Betriebssystem | Debian 12 (Bookworm) / Ubuntu 22+ |

## Mindest-Serveranforderungen

| Ressource | Minimum |
|---|---|
| vCPU | 1 |
| RAM | 1 GB |
| Disk | 10 GB |
| OS | Debian 12 / Ubuntu 22.04+ |
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
curl -sL https://raw.githubusercontent.com/michaelnid/BZ-RustDesk/main/install.sh -o /tmp/install.sh && curl -sL https://raw.githubusercontent.com/michaelnid/BZ-RustDesk/main/uninstall.sh -o /tmp/uninstall.sh && curl -sL https://raw.githubusercontent.com/michaelnid/BZ-RustDesk/main/update.sh -o /tmp/update.sh && sudo bash /tmp/install.sh
```

### Manuelle Installation

```bash
git clone https://github.com/michaelnid/BZ-RustDesk.git
cd BZ-RustDesk
sudo bash install.sh
```

Das Script führt automatisch folgende Schritte durch:
1. Systemvoraussetzungen prüfen (OS, Architektur)
2. Neueste RustDesk-Server-Version von GitHub laden (ZIP-Binaries)
3. Binaries nach `/opt/rustdesk/` installieren
4. Dedizierter Systembenutzer `rustdesk` anlegen (kein Login)
5. Gehärtete systemd-Services einrichten und starten
6. Firewall (ufw) konfigurieren
7. Optional: Let's Encrypt SSL-Zertifikat einrichten
8. Public Key und Client-Konfiguration ausgeben

## Update

```bash
sudo bash /opt/rustdesk/update.sh
```

Prüft auf neue Versionen, lädt automatisch herunter und führt bei Fehlern einen Rollback durch.

## Deinstallation

```bash
sudo bash /opt/rustdesk/uninstall.sh
```

Entfernt vollständig: Services, Binaries, Verzeichnisse, Benutzer, Firewall-Regeln und optional Let's Encrypt-Zertifikate.

## Client-Konfiguration

Nach erfolgreicher Installation gibt das Script folgende Werte aus:

- **ID-Server:** `<deine-domain-oder-ip>`
- **Relay-Server:** `<deine-domain-oder-ip>`
- **Public Key:** `/opt/rustdesk/id_ed25519.pub`

Im RustDesk-Client: `Einstellungen` > `Netzwerk` > `ID/Relay Server`

## Sicherheit

- Dedizierter Systembenutzer ohne Login-Shell
- systemd-Härtung: `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`
- Firewall automatisch konfiguriert (nur benötigte Ports offen)
- Ende-zu-Ende Verschlüsselung zwischen Clients
