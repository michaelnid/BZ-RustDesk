<h1 align="center">BZ RustDesk Server</h1>

<p align="center">
  <a href="https://github.com/michaelnid/BZ-RustDesk/actions/workflows/ci.yml"><img src="https://github.com/michaelnid/BZ-RustDesk/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
</p>

<p align="center">
  Selbst-gehosteter RustDesk ID- &amp; Relay-Server – offizielle Binaries, SHA-256-geprüft,<br>
  als gehärtete systemd-Dienste. Kein Docker.
</p>

---

## Installation

```bash
d=$(mktemp -d) && curl -fsSL https://github.com/michaelnid/BZ-RustDesk/archive/refs/heads/main.tar.gz | tar -xz -C "$d" --strip-components=1 && sudo bash "$d/install.sh"
```

Optionen: `--domain <name>` · `--no-firewall` · `--yes`

Debian 12+ / Ubuntu 22.04+ · amd64, arm64, armv7, i386 · ab 1 vCPU, 1 GB RAM, 10 GB Disk · statische IP empfohlen · Plesk Git: nein

## Verwaltung

| Aufgabe | Befehl |
|---|---|
| Update | `sudo bash /opt/rustdesk/update.sh` |
| Reparatur | `sudo bash /opt/rustdesk/update.sh --force` |
| Deinstallation | `sudo bash /opt/rustdesk/uninstall.sh` |
| Status / Logs | `systemctl status rustdesk-hbbs rustdesk-hbbr` · `journalctl -u rustdesk-hbbs -u rustdesk-hbbr -f` |

Updates prüfen die Prüfsumme, starten hbbs → hbbr, vergleichen den Schlüssel vorher/nachher und rollen bei jedem Fehler automatisch zurück. Die Deinstallation sichert vorher Schlüssel und Datenbank nach `/root`.

<details>
<summary><b>Umstieg von älteren Installationen (vor v2.0)</b></summary>

<br>

Ältere Versionen speichern Schlüssel und Datenbank in `/opt/rustdesk`, und der Dienst darf dort schreiben. Einmalig die neuen Scripts ausführen:

```bash
d=$(mktemp -d) && curl -fsSL https://github.com/michaelnid/BZ-RustDesk/archive/refs/heads/main.tar.gz | tar -xz -C "$d" --strip-components=1 && sudo bash "$d/update.sh"
```

Ablauf:

1. Vollständige Sicherung nach `/var/backups/rustdesk/`.
2. Daten werden nach `/var/lib/rustdesk` **kopiert** und byteweise geprüft.
3. Binaries werden aus dem verifizierten Release neu installiert.
4. Die Dienste starten mit der neuen Struktur, der Schlüssel-Hash wird verglichen.
5. Erst dann werden die alten Kopien entfernt. Schlägt etwas fehl, wird der alte Stand wiederhergestellt.

**Der Schlüssel bleibt identisch – an den Clients ändert sich nichts.** Das nicht mehr benötigte Let's-Encrypt-Zertifikat und die Ports 80/443 werden nur auf Nachfrage entfernt.

</details>

## Client

`Einstellungen › Netzwerk › ID/Relay-Server`: **ID-Server** und **Relay-Server** = Domain oder IP, **Key** = Ausgabe der Installation bzw. `sudo cat /var/lib/rustdesk/id_ed25519.pub`

## Ports

| Port | Dienst | Zweck |
|---|---|---|
| 21115/tcp | hbbs | NAT-Typ-Test |
| 21116/tcp+udp | hbbs | ID-Server, Heartbeat |
| 21117/tcp | hbbr | Relay |
| 21118/tcp · 21119/tcp | hbbs · hbbr | WebSocket (Web-Client, Client-Option „WebSocket“) |

Die Firewall (ufw) ergänzt nur Regeln. Ist ufw aus, wird der SSH-Port erkannt und freigegeben. Laufen weitere öffentliche Dienste, wird ufw nicht automatisch eingeschaltet.

## Sicherheit

- Download nur per HTTPS, SHA-256-Prüfsumme gegen die GitHub-API verifiziert
- Programme und Scripts gehören root, Schlüssel und Datenbank nur dem Dienstbenutzer (`/var/lib/rustdesk`, 0700)
- Key-Pflicht für ID- **und** Relay-Server (`hbbr -k _`) – kein offenes Relay
- systemd-Sandbox: keine Capabilities, `ProtectSystem=strict`, Syscall-Filter, `MemoryDenyWriteExecute` u. a.
- Automatischer Rollback und Schlüssel-Sicherung bei jedem Update

<details>
<summary><b>Verzeichnisse &amp; Schlüssel wiederherstellen</b></summary>

<br>

| Pfad | Inhalt |
|---|---|
| `/opt/rustdesk/` | Binaries, `update.sh`, `uninstall.sh`, `lib/`, `version.txt` (root) |
| `/var/lib/rustdesk/` | `id_ed25519`, `id_ed25519.pub`, `db_v2.sqlite3`, optional `.env` (Dienstbenutzer) |
| `/var/backups/rustdesk/` | Schlüssel- und Migrations-Sicherungen (root) |
| `/var/log/rustdesk-setup.log` | Log von Installation und Update |

Eigene Optionen gehören in `/var/lib/rustdesk/.env` oder in ein Drop-in (`systemctl edit rustdesk-hbbs`).

Wiederherstellen vor einer Neuinstallation – der Schlüssel wird dann automatisch übernommen:

```bash
sudo mkdir -p /var/lib/rustdesk && sudo tar -xzf /root/rustdesk-backup-<Datum>.tar.gz -C /var/lib/rustdesk
```

</details>
