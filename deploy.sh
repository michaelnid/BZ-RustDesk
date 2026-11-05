#!/bin/bash
# ============================================================
# BZ RustDesk Server - Deploy vom Mac (oder Linux)
#
# Lädt die Scripts per SCP auf den Server und startet dort automatisch
# die Neuinstallation oder das Update - erkannt am Zustand des Servers.
# Login per SSH-Key. Kompatibel mit der macOS-bash 3.2.
# ============================================================

set -euo pipefail

usage() {
    cat <<'EOF'
Verwendung: ./deploy.sh <Server-IP|Hostname> [Optionen] [Optionen für install.sh/update.sh]

  -u, --user NAME       SSH-Benutzer (Standard: root; andere Benutzer per sudo)
  -p, --port PORT       SSH-Port (Standard: 22)
  -i, --identity DATEI  SSH-Schlüssel (Standard: ssh-agent bzw. ~/.ssh)
  -h, --help            Diese Hilfe

Alle anderen Optionen (z.B. --yes, --force, --no-firewall) gehen an install.sh/update.sh.

Beispiele:
  ./deploy.sh 203.0.113.10
  ./deploy.sh 203.0.113.10 --no-firewall
  ./deploy.sh rd.example.com -u admin -p 2222 --yes
EOF
}

die() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

# Für die entfernte Shell sicher in einfache Anführungszeichen setzen
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
FILES="install.sh update.sh uninstall.sh lib/common.sh"
HOST=""
SSH_USER="${DEPLOY_USER:-root}"
PORT=22
IDENTITY=""
REMOTE_ARGS=()

while [ $# -gt 0 ]; do
    case $1 in
        -u | --user) [ $# -ge 2 ] || die "$1 benötigt einen Wert."; SSH_USER=$2; shift ;;
        -p | --port) [ $# -ge 2 ] || die "$1 benötigt einen Wert."; PORT=$2; shift ;;
        -i | --identity) [ $# -ge 2 ] || die "$1 benötigt einen Wert."; IDENTITY=$2; shift ;;
        -h | --help) usage; exit 0 ;;
        --) shift; REMOTE_ARGS+=("$@"); break ;;
        -*) REMOTE_ARGS+=("$1") ;;  # Option für install.sh/update.sh
        *) if [ -z "$HOST" ]; then HOST=$1; else REMOTE_ARGS+=("$1"); fi ;;
    esac
    shift
done

[ -n "$HOST" ] || { usage; exit 1; }
[[ $HOST =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || die "Ungültiger Server: $HOST"
[[ $SSH_USER =~ ^[a-z_][a-z0-9_.-]*$ ]] || die "Ungültiger Benutzer: $SSH_USER"
if ! [[ $PORT =~ ^[0-9]{1,5}$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    die "Ungültiger Port: $PORT"
fi
[ -z "$IDENTITY" ] || [ -f "$IDENTITY" ] || die "SSH-Schlüssel nicht gefunden: $IDENTITY"
{ command -v ssh && command -v scp; } >/dev/null 2>&1 || die "ssh/scp nicht gefunden."

for f in $FILES; do
    [ -f "$SCRIPT_DIR/$f" ] || die "Datei fehlt: $SCRIPT_DIR/$f"
    if grep -q $'\r' "$SCRIPT_DIR/$f"; then
        die "$f hat Windows-Zeilenenden (CRLF) - Repository neu auschecken (.gitattributes erzwingt LF)."
    fi
done

# Nur Key-Login; neue Hostkeys werden einmalig gemerkt, geänderte abgelehnt
SSH_OPTS=(-o PreferredAuthentications=publickey -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=30)
if [ -n "$IDENTITY" ]; then SSH_OPTS+=(-i "$IDENTITY" -o IdentitiesOnly=yes); fi
TARGET="$SSH_USER@$HOST"
SCP_TARGET=$TARGET
case $HOST in *:*) SCP_TARGET="$SSH_USER@[$HOST]" ;; esac

# 1) Verbinden, Upload-Verzeichnis anlegen, Neuinstallation oder Update erkennen
info "Verbinde mit $TARGET (Port $PORT, SSH-Key)..."
# shellcheck disable=SC2016  # wird absichtlich erst auf dem Server ausgewertet
DETECT='d=$(mktemp -d /tmp/bz-rustdesk-deploy.XXXXXX) && if [ -e /opt/rustdesk/hbbs ] || [ -e /etc/systemd/system/rustdesk-hbbs.service ]; then echo update $d; else echo install $d; fi'
REPLY_LINE=$(ssh "${SSH_OPTS[@]}" -p "$PORT" "$TARGET" "$DETECT" | tr -d '\r' | tail -n 1) ||
    die "SSH-Anmeldung fehlgeschlagen - ist der SSH-Key auf dem Server hinterlegt (Benutzer/Port korrekt)?"
MODE=${REPLY_LINE%% *}
REMOTE_DIR=${REPLY_LINE#* }
case $MODE in install | update) ;; *) die "Unerwartete Antwort vom Server: $REPLY_LINE" ;; esac
[[ $REMOTE_DIR =~ ^/tmp/bz-rustdesk-deploy\.[A-Za-z0-9]+$ ]] || die "Unerwartetes Upload-Verzeichnis: $REMOTE_DIR"

if [ "$MODE" = update ]; then
    info "Bestehende Installation gefunden -> Update"
else
    info "Keine Installation gefunden -> Neuinstallation"
fi

# 2) Scripts per SCP hochladen
info "Lade Scripts hoch (scp)..."
if ! (cd "$SCRIPT_DIR" && scp -q "${SSH_OPTS[@]}" -P "$PORT" -r install.sh update.sh uninstall.sh lib "$SCP_TARGET:$REMOTE_DIR/"); then
    ssh "${SSH_OPTS[@]}" -p "$PORT" "$TARGET" "rm -rf $REMOTE_DIR" >/dev/null 2>&1 || true
    die "Upload fehlgeschlagen."
fi

# 3) Ausführen (mit Terminal, damit Rückfragen und sudo funktionieren), danach aufräumen
ARGS=""
for a in ${REMOTE_ARGS[@]+"${REMOTE_ARGS[@]}"}; do
    [ "$a" = "--" ] && continue
    ARGS="$ARGS $(quote "$a")"
done
SUDO=""
if [ "$SSH_USER" != root ]; then SUDO="sudo "; fi
RUN="trap 'rm -rf $REMOTE_DIR' INT TERM HUP; ${SUDO}bash $REMOTE_DIR/$MODE.sh$ARGS; rc=\$?; rm -rf $REMOTE_DIR; exit \$rc"

info "Starte $MODE.sh auf dem Server..."
if ssh -t "${SSH_OPTS[@]}" -p "$PORT" "$TARGET" "$RUN"; then
    info "Deploy erfolgreich abgeschlossen ($MODE)."
else
    rc=$?
    die "$MODE.sh ist mit Exit-Code $rc beendet worden - Ausgabe oben prüfen."
fi
