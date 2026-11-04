<h1 align="center">BZ RustDesk Server</h1>

<p align="center">
  <a href="https://github.com/michaelnid/BZ-RustDesk/actions/workflows/ci.yml"><img src="https://github.com/michaelnid/BZ-RustDesk/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
</p>

<p align="center">
  Selbst-gehosteter RustDesk ID- &amp; Relay-Server – offizielle Binaries, SHA-256-geprüft,<br>
  als gehärtete systemd-Dienste. Kein Docker.
</p>

---

## Deploy

Vom Mac oder Windows-11-Rechner – Login per SSH-Key, Upload per SCP. Das Script erkennt selbst, ob der Server neu eingerichtet oder aktualisiert wird.

```bash
./deploy.sh 203.0.113.10          # macOS
.\deploy.ps1 203.0.113.10         # Windows (PowerShell) – oder: deploy.cmd 203.0.113.10
```

Optionen: `-u <benutzer>` (Standard `root`, sonst per sudo) · `-p <ssh-port>` · `-i <schlüssel>` · alles Weitere geht an den Server, z. B. `--domain rd.example.com`, `--yes`, `--force`, `--no-firewall`

Debian 13/12 (Ubuntu 22.04+ funktioniert ebenfalls) · amd64, arm64, armv7, i386 · ab 1 vCPU, 1 GB RAM, 10 GB Disk · Plesk Git: nein

<details>
<summary><b>Ohne Deploy direkt auf dem Server</b></summary>

<br>

```bash
d=$(mktemp -d) && curl -fsSL https://github.com/michaelnid/BZ-RustDesk/archive/refs/heads/main.tar.gz | tar -xz -C "$d" --strip-components=1 && sudo bash "$d/install.sh"
```

Bei einer bestehenden Installation übergibt `install.sh` automatisch an `update.sh`.

</details>

## Verwaltung

| Aufgabe | Befehl auf dem Server |
|---|---|
| Update | `sudo bash /opt/rustdesk/update.sh` |
| Reparatur | `sudo bash /opt/rustdesk/update.sh --force` |
| Deinstallation | `sudo bash /opt/rustdesk/uninstall.sh` |
| Status / Logs | `systemctl status rustdesk-hbbs rustdesk-hbbr` · `journalctl -u rustdesk-hbbs -u rustdesk-hbbr -f` |

Updates prüfen die Prüfsumme, starten hbbs → hbbr, vergleichen den Schlüssel vorher/nachher und rollen bei jedem Fehler automatisch zurück. Die Deinstallation sichert vorher Schlüssel und Datenbank nach `/root`.

<details>
<summary><b>Umstieg von älteren Installationen (vor v2.0)</b></summary>

<br>

Einfach `deploy` ausführen (oder den Einzeiler oben mit `update.sh` statt `install.sh`). Die Migration läuft so ab:

1. Vollständige Sicherung nach `/var/backups/rustdesk/`.
2. Schlüssel und Datenbank werden von `/opt/rustdesk` nach `/var/lib/rustdesk` **kopiert** und byteweise geprüft.
3. Binaries werden aus dem verifizierten Release neu installiert.
4. Die Dienste starten mit der neuen Struktur, der Schlüssel-Hash wird verglichen.
5. Erst dann werden die alten Kopien entfernt. Schlägt etwas fehl, wird der alte Stand wiederhergestellt.

**Der Schlüssel bleibt identisch – an den Clients ändert sich nichts.** Nicht benötigte Freigaben (WebSocket 21118/21119) werden geschlossen. Das ungenutzte Let's-Encrypt-Zertifikat und die Ports 80/443 entfernt das Update nach Rückfrage – außer ein anderer Dienst nutzt Port 80/443.

</details>

## Client

`Einstellungen › Netzwerk › ID/Relay-Server`: **ID-Server** und **Relay-Server** = Domain oder IP, **Key** = Ausgabe der Installation bzw. `sudo cat /var/lib/rustdesk/id_ed25519.pub`

## Firewall

Geöffnet wird nur, was RustDesk wirklich braucht:

| Port | Dienst | Zweck |
|---|---|---|
| 21115/tcp | hbbs | NAT-Typ-Test |
| 21116/tcp+udp | hbbs | ID-Server, Heartbeat |
| 21117/tcp | hbbr | Relay |

Kein Let's Encrypt und keine Ports 80/443 – RustDesk verschlüsselt über das eigene Schlüsselpaar und nutzt keine TLS-Zertifikate. Die WebSocket-Ports 21118/21119 (nur für den Web-Client) bleiben zu. ufw ergänzt nur Regeln. Ist ufw aus, wird der SSH-Port erkannt und freigegeben. Laufen weitere öffentliche Dienste, wird ufw nicht automatisch eingeschaltet.

## Sicherheit

- Download nur per HTTPS, SHA-256-Prüfsumme gegen die GitHub-API verifiziert
- Programme und Scripts gehören root, Schlüssel und Datenbank nur dem Dienstbenutzer (`/var/lib/rustdesk`, 0700)
- Key-Pflicht für ID- **und** Relay-Server (`hbbr -k _`) – kein offenes Relay
- systemd-Sandbox: keine Capabilities, `ProtectSystem=strict`, Syscall-Filter, `MemoryDenyWriteExecute` u. a.
- Automatischer Rollback und Schlüssel-Sicherung bei jedem Update
- Deploy nur mit SSH-Key, neue Hostkeys werden gemerkt, geänderte abgelehnt

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
