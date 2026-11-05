# shellcheck shell=bash
# shellcheck disable=SC2034  # Variablen werden von install/update/uninstall.sh genutzt
# ============================================================
# BZ RustDesk Server - Gemeinsame Funktionen
# Wird von install.sh, update.sh und uninstall.sh eingebunden.
# ============================================================

# Version der Verwaltungs-Scripts (bei jeder Änderung erhöhen)
BZ_SCRIPT_VERSION="2.2.0"

# --- Pfade -------------------------------------------------------------------
# Programmdateien + Verwaltungs-Scripts: gehören root, für den Dienst nur lesbar.
INSTALL_DIR="/opt/rustdesk"
# Schlüssel, Datenbank, .env: gehören dem Dienstbenutzer (0700).
# Muss zu "StateDirectory=rustdesk" in den systemd-Units passen.
DATA_DIR="/var/lib/rustdesk"
SYSTEMD_DIR="/etc/systemd/system"
SYSTEMD_RUNTIME_DIR="/run/systemd/system"
BACKUP_DIR="/var/backups/rustdesk"
UNINSTALL_BACKUP_DIR="/root"
LOG_FILE="/var/log/rustdesk-setup.log"
LEGACY_LOG_FILE="/var/log/rustdesk-install.log"
LOCK_FILE="/run/lock/bz-rustdesk-setup.lock"
LETSENCRYPT_LIVE_DIR="/etc/letsencrypt/live"
VERSION_FILE="$INSTALL_DIR/version.txt"

SERVICE_USER="rustdesk"
SERVICES=(rustdesk-hbbs rustdesk-hbbr)
BINARIES=(hbbs hbbr rustdesk-utils)
MANAGEMENT_FILES=(update.sh uninstall.sh lib/common.sh)
BASE_PACKAGES=(ca-certificates curl unzip jq iproute2)

GITHUB_API="https://api.github.com/repos/rustdesk/rustdesk-server/releases/latest"
RELEASE_URL_PREFIX="https://github.com/rustdesk/rustdesk-server/releases/download/"
SCRIPTS_TARBALL_URL="https://github.com/michaelnid/BZ-RustDesk/archive/refs/heads/main.tar.gz"

# "Port/Protokoll|Kommentar" - nur was RustDesk-Clients wirklich brauchen
FIREWALL_RULES=(
    "21115/tcp|RustDesk hbbs NAT-Typ-Test"
    "21116/tcp|RustDesk hbbs ID-Server"
    "21116/udp|RustDesk hbbs ID-Server/Heartbeat"
    "21117/tcp|RustDesk hbbr Relay"
)
# Von älteren Versionen geöffnet, aber nicht benötigt (WebSocket nur für den Web-Client,
# der ohne TLS ohnehin nicht funktioniert) - werden bei Update/Deinstallation entfernt.
OBSOLETE_FIREWALL_RULES=(21118/tcp 21119/tcp)

# --- Laufzeit-Status ---------------------------------------------------------
ASSUME_YES=0          # --yes: Hauptaktion bestätigen, sonst jeweils Standardantwort
MANAGE_FIREWALL=1     # --no-firewall: ufw wird nicht angefasst
LOG_READY=0
MAIN_PID=""
FAILURE_HOOK=""       # Funktion, die bei Fehler/Abbruch ausgeführt wird (Rollback)
_TMP_PATHS=()

if [[ -t 1 ]]; then
    RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[1;33m' BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m' BOLD=$'\033[1m' NC=$'\033[0m'
else
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" NC=""
fi

# =============================================================================
# Ausgabe, Logging, Fehlerbehandlung
# =============================================================================

_log_file() {
    if ((LOG_READY)); then
        printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >>"$LOG_FILE" 2>/dev/null || true
    fi
}

log()  { printf '%s[OK]%s     %s\n' "$GREEN" "$NC" "$*"; _log_file OK "$*"; }
info() { printf '%s[INFO]%s   %s\n' "$BLUE" "$NC" "$*"; _log_file INFO "$*"; }
warn() { printf '%s[WARN]%s   %s\n' "$YELLOW" "$NC" "$*" >&2; _log_file WARN "$*"; }

die() {
    printf '%s[FEHLER]%s %s\n' "$RED" "$NC" "$*" >&2
    _log_file FEHLER "$*"
    _run_failure_hook
    if ((LOG_READY)) && [[ $BASHPID == "$MAIN_PID" ]]; then
        printf 'Details im Log: %s\n' "$LOG_FILE" >&2
    fi
    exit 1
}

_run_failure_hook() {
    [[ $BASHPID == "$MAIN_PID" ]] || return 0
    local hook=$FAILURE_HOOK
    FAILURE_HOOK=""
    if [[ -n $hook ]]; then
        trap - ERR
        set +e
        "$hook"
    fi
    return 0
}

_on_err() {
    local rc=$1 line=$2 cmd=$3
    trap - ERR
    # Fehler in Subshells ($(...)) nur weiterreichen, nicht doppelt melden
    if [[ $BASHPID != "$MAIN_PID" ]]; then exit "$rc"; fi
    printf '%s[FEHLER]%s Unerwarteter Fehler (Exit-Code %s) in Zeile %s: %s\n' "$RED" "$NC" "$rc" "$line" "$cmd" >&2
    _log_file FEHLER "Exit-Code $rc in Zeile $line: $cmd"
    _run_failure_hook
    if ((LOG_READY)); then printf 'Details im Log: %s\n' "$LOG_FILE" >&2; fi
    exit "$rc"
}

_on_signal() {
    trap - INT TERM HUP
    echo
    warn "Abbruch durch Benutzer/Signal."
    _run_failure_hook
    exit 130
}

cleanup_tmp() {
    local p
    for p in "${_TMP_PATHS[@]}"; do
        if [[ -n $p && -e $p ]]; then rm -rf -- "$p"; fi
    done
    _TMP_PATHS=()
}

_on_exit() {
    # Cursor wieder einblenden, falls die Intro-Animation unterbrochen wurde
    if ((_INTRO_CURSOR_HIDDEN)); then printf '\033[0m\033[?25h'; fi
    cleanup_tmp
}

# Muss als erstes in jedem Script aufgerufen werden.
bz_init() {
    set -Eeuo pipefail
    umask 022
    export DEBIAN_FRONTEND=noninteractive
    MAIN_PID=$BASHPID
    trap '_on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR
    trap '_on_exit' EXIT
    trap '_on_signal' INT TERM HUP
}

# Legt ein temporäres Verzeichnis an (wird beim Beenden gelöscht).
# Aufruf: make_tmp_dir VARIABLENNAME  (nicht in $(...) verwenden)
make_tmp_dir() {
    local d
    d=$(mktemp -d "${TMPDIR:-/tmp}/bz-rustdesk.XXXXXX")
    _TMP_PATHS+=("$d")
    printf -v "$1" '%s' "$d"
}

require_root() {
    [[ $(id -u) == 0 ]] || die "Dieses Script muss als root laufen. Bitte mit 'sudo bash $0' starten."
}

init_log() {
    install -d -m 0755 "$(dirname "$LOG_FILE")"
    (umask 077 && : >>"$LOG_FILE")
    chmod 0600 "$LOG_FILE"
    LOG_READY=1
    _log_file START "$(basename "$0") v$BZ_SCRIPT_VERSION $*"
}

# Verhindert parallele Läufe von install/update/uninstall.
acquire_lock() {
    install -d -m 0755 "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Es läuft bereits ein anderer Vorgang (Installation/Update/Deinstallation)."
}

# =============================================================================
# Intro: michaelnid.app-Animation (nur im Terminal, einmal pro Aufruf-Kette)
# =============================================================================

_INTRO_CURSOR_HIDDEN=0

# Kopfzeile bzw. Animation. $1 = Aktion (Installation, Update, Deinstallation)
banner() {
    local brand="michaelnid.app" title="BZ RustDesk Server"
    local sub="$1 - Scripts v$BZ_SCRIPT_VERSION" cols
    cols=$(tput cols 2>/dev/null || echo 80)
    [[ $cols =~ ^[0-9]+$ ]] || cols=80

    # Ohne Terminal (CI, Log, Pipe), zu schmal, abgeschaltet oder schon gezeigt: schlichte Kopfzeile
    if [[ ! -t 1 || ${TERM:-dumb} == dumb || -n ${BZ_NO_INTRO:-} || -n ${BZ_INTRO_SHOWN:-} ]] || ((cols < 52)); then
        printf '\n  %s%s%s  %s\n  %s\n\n' "$BOLD$CYAN" "$brand" "$NC" "$title" "$sub"
        return 0
    fi
    export BZ_INTRO_SHOWN=1
    _intro_animation "$brand" "$title" "$sub"
}

_intro_sleep() { sleep "$1" 2>/dev/null || true; }

# Cursor im Rahmen setzen - nur relative Bewegungen (überall unterstützt).
# $1 Zeile (0 = obere Rahmenlinie, 9 = Zeile unter dem Rahmen), $2 Spalte
_INTRO_ROW=9
_intro_at() {
    local delta=$(($1 - _INTRO_ROW))
    if ((delta < 0)); then printf '\033[%dA' $((-delta)); elif ((delta > 0)); then printf '\033[%dB' "$delta"; fi
    printf '\033[%dG' "$2"
    _INTRO_ROW=$1
}

_intro_animation() {
    local brand=$1 title=$2 sub=$3
    local w=46 i k ncol hline="" pad spaced="" e=$'\033'
    local frame grey white line_c rst=$'\033[0m'
    local -a col=() fade=()

    ncol=$(tput colors 2>/dev/null || echo 8)
    if [[ $ncol =~ ^[0-9]+$ ]] && ((ncol >= 256)); then
        for k in 51 50 45 44 39 38 33 69 63 99 135 141 171 177 207; do col+=("${e}[1;38;5;${k}m"); done
        frame="${e}[38;5;238m" grey="${e}[38;5;245m" white="${e}[1;38;5;231m" line_c="${e}[38;5;39m"
        fade=("${e}[38;5;236m" "${e}[38;5;240m" "${e}[38;5;244m" "${e}[38;5;249m" "${e}[38;5;254m")
    else
        col=("${e}[1;36m")
        frame="${e}[2m" grey="${e}[0m" white="${e}[1;37m" line_c="${e}[36m"
        fade=("${e}[2m" "${e}[0m")
    fi

    for ((i = 0; i < w; i++)); do hline+="─"; done
    printf -v pad '%*s' "$w" ''
    for ((i = 0; i < ${#brand}; i++)); do spaced+="${brand:i:1} "; done
    spaced=${spaced% }
    local bcol=$((4 + (w - ${#spaced}) / 2)) tcol=$((4 + (w - ${#title}) / 2)) scol=$((4 + (w - ${#sub}) / 2))

    # Rahmen zeichnen (Cursor steht danach in Zeile 9), Cursor ausblenden
    _INTRO_CURSOR_HIDDEN=1
    _INTRO_ROW=9
    printf '\033[?25l\n  %s╭%s╮%s\n' "$frame" "$hline" "$rst"
    for ((i = 1; i <= 7; i++)); do printf '  %s│%s│%s\n' "$frame" "$pad" "$rst"; done
    printf '  %s╰%s╯%s\n' "$frame" "$hline" "$rst"

    # 1) Schriftzug Buchstabe für Buchstabe im Farbverlauf
    for ((i = 0; i < ${#brand}; i++)); do
        _intro_at 2 $((bcol + 2 * i))
        printf '%s%s' "${col[i * ${#col[@]} / ${#brand}]}" "${brand:i:1}"
        _intro_sleep 0.04
    done
    # 2) Linie darunter wächst von links nach rechts
    _intro_at 3 "$bcol"
    printf '%s' "$line_c"
    for ((i = 0; i < ${#spaced}; i++)); do printf '─'; _intro_sleep 0.006; done
    # 3) Titel und Aktion einblenden
    for k in "${fade[@]}"; do
        _intro_at 5 "$tcol"; printf '%s%s' "$k" "$title"
        _intro_at 6 "$scol"; printf '%s%s' "$k" "$sub"
        _intro_sleep 0.05
    done
    _intro_at 5 "$tcol"; printf '%s%s' "$white" "$title"
    _intro_at 6 "$scol"; printf '%s%s' "$grey" "$sub"
    # 4) Lichtreflex über den Schriftzug
    for ((i = 0; i <= ${#brand}; i++)); do
        if ((i > 0)); then
            _intro_at 2 $((bcol + 2 * (i - 1)))
            printf '%s%s' "${col[(i - 1) * ${#col[@]} / ${#brand}]}" "${brand:i-1:1}"
        fi
        if ((i < ${#brand})); then
            _intro_at 2 $((bcol + 2 * i))
            printf '%s%s' "$white" "${brand:i:1}"
        fi
        _intro_sleep 0.03
    done

    _intro_at 9 1
    printf '%s\n\033[?25h' "$rst"
    _INTRO_CURSOR_HIDDEN=0
    _intro_sleep 0.2
}

# =============================================================================
# Benutzerabfragen
# =============================================================================

# Liest eine Eingabe nach REPLY - auch wenn stdin kein Terminal ist.
prompt_input() {
    REPLY=""
    if [[ -t 0 ]]; then
        read -r -p "$1" REPLY || REPLY=""
    elif { : </dev/tty; } 2>/dev/null; then
        read -r -p "$1" REPLY </dev/tty || REPLY=""
    else
        die "Keine interaktive Eingabe möglich. Script mit --yes ausführen."
    fi
}

# ask_yes_no "Frage" j|n  -> 0 = ja. Mit --yes wird die Standardantwort genommen.
ask_yes_no() {
    local question=$1 def=${2:-n} hint answer
    if [[ $def == j ]]; then hint="J/n"; else hint="j/N"; fi
    if ((ASSUME_YES)); then
        info "$question [$hint] -> automatisch: $def"
        answer=$def
    else
        prompt_input "$question ($hint): "
        answer=${REPLY,,}
        answer=${answer//[[:space:]]/}
        if [[ -z $answer ]]; then answer=$def; fi
    fi
    case $answer in
        j | ja | y | yes) return 0 ;;
        *) return 1 ;;
    esac
}

# Bestätigung der Hauptaktion: mit --yes immer ja, sonst Standard "nein".
confirm() {
    if ((ASSUME_YES)); then return 0; fi
    ask_yes_no "$1" n
}

# =============================================================================
# System
# =============================================================================

check_os() {
    [[ -r /etc/os-release ]] || die "Betriebssystem konnte nicht erkannt werden (/etc/os-release fehlt)."
    local os_id os_name
    # shellcheck source=/dev/null
    os_id=$(. /etc/os-release && printf '%s' "${ID:-}")
    # shellcheck source=/dev/null
    os_name=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${ID:-unbekannt}}")
    info "Betriebssystem: $os_name"
    if [[ $os_id != debian && $os_id != ubuntu ]]; then
        warn "Dieses Script ist für Debian 13/12 gedacht (Ubuntu 22.04+ funktioniert ebenfalls)."
        confirm "Trotzdem fortfahren?" || die "Abgebrochen."
    fi
    command -v apt-get >/dev/null 2>&1 || die "apt-get nicht gefunden - nur Debian/Ubuntu werden unterstützt."
}

check_systemd() {
    [[ -d $SYSTEMD_RUNTIME_DIR ]] || die "systemd läuft nicht auf diesem System (wird benötigt)."
}

detect_arch() {
    local machine
    machine=$(uname -m)
    case $machine in
        x86_64 | amd64) ZIP_ARCH="amd64" ;;
        aarch64 | arm64) ZIP_ARCH="arm64v8" ;;
        armv7l | armv7*) ZIP_ARCH="armv7" ;;
        i386 | i686) ZIP_ARCH="i386" ;;
        *) die "Nicht unterstützte Architektur: $machine" ;;
    esac
    info "Architektur: $machine ($ZIP_ARCH)"
}

# Installiert nur fehlende Pakete.
ensure_packages() {
    local missing=() pkg
    for pkg in "$@"; do
        if [[ $(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true) != "install ok installed" ]]; then
            missing+=("$pkg")
        fi
    done
    ((${#missing[@]})) || return 0
    info "Installiere Pakete: ${missing[*]}"
    apt-get update -qq >>"$LOG_FILE" 2>&1 || die "apt-get update fehlgeschlagen (siehe $LOG_FILE)."
    apt-get install -y -qq --no-install-recommends "${missing[@]}" >>"$LOG_FILE" 2>&1 ||
        die "Paketinstallation fehlgeschlagen: ${missing[*]} (siehe $LOG_FILE)."
    log "Pakete installiert: ${missing[*]}"
}

ensure_service_user() {
    if ! getent group "$SERVICE_USER" >/dev/null 2>&1; then
        groupadd --system "$SERVICE_USER"
    fi
    if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
        useradd --system --gid "$SERVICE_USER" --no-create-home --home-dir /nonexistent \
            --shell /usr/sbin/nologin "$SERVICE_USER"
        log "Systembenutzer '$SERVICE_USER' angelegt (kein Login)."
    fi
}

installation_present() {
    [[ -e $INSTALL_DIR/hbbs || -e $SYSTEMD_DIR/rustdesk-hbbs.service || -e $SYSTEMD_DIR/rustdesk-hbbr.service ]]
}

# Alte Struktur (bis v1): Schlüssel/Datenbank liegen in /opt/rustdesk,
# das Verzeichnis gehört dem Dienstbenutzer.
legacy_layout_present() {
    if [[ -e $INSTALL_DIR/id_ed25519 || -e $INSTALL_DIR/id_ed25519.pub || -e $INSTALL_DIR/db_v2.sqlite3 ]]; then
        return 0
    fi
    grep -qsx "WorkingDirectory=$INSTALL_DIR" "$SYSTEMD_DIR/rustdesk-hbbs.service" "$SYSTEMD_DIR/rustdesk-hbbr.service"
}

# Dateien in INSTALL_DIR, die von diesen Scripts verwaltet werden (keine Nutzdaten).
is_managed_name() {
    case $1 in
        hbbs | hbbr | rustdesk-utils | update.sh | uninstall.sh | install.sh | version.txt | lib | *.bak | *.new) return 0 ;;
        *) return 1 ;;
    esac
}

valid_host() {
    local h=$1
    ((${#h} > 0 && ${#h} <= 253)) || return 1
    if [[ $h =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then return 0; fi
    [[ $h =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

detect_public_ip() {
    local url ip
    for url in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
        ip=$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    printf '%s' "unbekannt"
}

file_sha256() {
    if [[ -f $1 ]]; then sha256sum "$1" | awk '{print $1}'; fi
}

# =============================================================================
# version.txt (wird nie per "source" eingelesen - nur geprüfte Werte)
# =============================================================================

read_version_value() {
    local v=""
    if [[ -f $VERSION_FILE && ! -L $VERSION_FILE ]]; then
        v=$(grep -m1 "^$1=" "$VERSION_FILE" 2>/dev/null | cut -d= -f2- || true)
    fi
    if [[ $v =~ ^[A-Za-z0-9._:-]*$ ]]; then printf '%s' "$v"; fi
}

write_version_file() {
    local tmp="$INSTALL_DIR/.version.txt.new"
    rm -f -- "$tmp"
    {
        printf 'RUSTDESK_VERSION=%s\n' "${RUSTDESK_VERSION:-}"
        printf 'SCRIPT_VERSION=%s\n' "$BZ_SCRIPT_VERSION"
        printf 'LAYOUT=2\n'
        printf 'INSTALL_DATE=%s\n' "${INSTALL_DATE:-}"
        printf 'UPDATE_DATE=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'SERVER_IP=%s\n' "${SERVER_IP:-}"
    } >"$tmp"
    chown root:root "$tmp"
    chmod 0644 "$tmp"
    mv -f -- "$tmp" "$VERSION_FILE"
}

script_version_of() {
    grep -m1 '^BZ_SCRIPT_VERSION=' "$1" 2>/dev/null | cut -d'"' -f2 || true
}

# version_gt A B -> wahr, wenn A > B
version_gt() {
    [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]
}

# =============================================================================
# RustDesk-Release: Abfrage, Download, Prüfsumme
# =============================================================================

fetch_release_info() {
    local json digest auth_cfg=""
    info "Neueste RustDesk-Server-Version wird bei GitHub abgefragt..."
    # Optional (z.B. CI): Token gegen das API-Limit - per stdin-Konfiguration, nicht sichtbar in "ps"
    if [[ ${GITHUB_TOKEN:-} =~ ^[A-Za-z0-9_]+$ ]]; then
        auth_cfg="header = \"Authorization: Bearer $GITHUB_TOKEN\""
    fi
    if ! json=$(curl -K - -fsSL --proto '=https' --retry 3 --retry-delay 2 --max-time 30 \
        -H 'Accept: application/vnd.github+json' -H 'User-Agent: bz-rustdesk-setup' \
        "$GITHUB_API" <<<"$auth_cfg" 2>>"$LOG_FILE"); then
        die "GitHub-API nicht erreichbar oder API-Limit (60 Anfragen/Stunde) erreicht. Bitte später erneut versuchen."
    fi
    RELEASE_TAG=$(jq -r '.tag_name // empty' <<<"$json" 2>/dev/null || true)
    [[ $RELEASE_TAG =~ ^[0-9A-Za-z][0-9A-Za-z._-]{0,31}$ ]] ||
        die "Ungültige Antwort der GitHub-API (tag_name: '${RELEASE_TAG}')."

    ASSET_NAME="rustdesk-server-linux-${ZIP_ARCH}.zip"
    ASSET_URL=$(jq -r --arg n "$ASSET_NAME" \
        'first(.assets[]? | select(.name == $n)) | .browser_download_url // empty' <<<"$json" 2>/dev/null || true)
    digest=$(jq -r --arg n "$ASSET_NAME" \
        'first(.assets[]? | select(.name == $n)) | .digest // empty' <<<"$json" 2>/dev/null || true)

    [[ $ASSET_URL == "${RELEASE_URL_PREFIX}${RELEASE_TAG}/${ASSET_NAME}" ]] ||
        die "Release $RELEASE_TAG enthält kein Paket $ASSET_NAME (oder unerwartete Download-Adresse)."
    [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] ||
        die "GitHub liefert keine SHA-256-Prüfsumme für $ASSET_NAME - aus Sicherheitsgründen keine Installation."
    ASSET_SHA256=${digest#sha256:}
    info "Neueste Version: $RELEASE_TAG"
}

# Lädt das Release-ZIP, prüft die Prüfsumme und entpackt es. Setzt STAGE_BIN_DIR.
download_release() {
    local tmp zip actual found
    local progress=(-sS)
    make_tmp_dir tmp
    zip="$tmp/$ASSET_NAME"
    if [[ -t 1 ]]; then progress=(--progress-bar); fi

    info "Lade $ASSET_NAME ($RELEASE_TAG) herunter..."
    curl -fL "${progress[@]}" --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 2 \
        --max-time 900 -o "$zip" "$ASSET_URL" || die "Download fehlgeschlagen: $ASSET_URL"

    actual=$(sha256sum "$zip" | awk '{print $1}')
    if [[ $actual != "$ASSET_SHA256" ]]; then
        die "SHA-256-Prüfsumme stimmt NICHT (erwartet $ASSET_SHA256, erhalten $actual) - Abbruch, nichts verändert."
    fi
    log "SHA-256-Prüfsumme verifiziert."

    mkdir "$tmp/extract"
    unzip -q "$zip" -d "$tmp/extract" >>"$LOG_FILE" 2>&1 || die "ZIP-Archiv konnte nicht entpackt werden."
    found=$(find "$tmp/extract" -type f -name hbbs -printf '%h\n' -quit)
    [[ -n $found && -f $found/hbbs && -f $found/hbbr ]] || die "hbbs/hbbr nicht im Archiv gefunden."
    STAGE_BIN_DIR=$found
}

# Kopiert Binaries atomar (umbenennen statt überschreiben) nach INSTALL_DIR.
install_binaries() {
    local src=$1 bin
    install -d -o root -g root -m 0755 "$INSTALL_DIR"
    for bin in "${BINARIES[@]}"; do
        if [[ -f $src/$bin ]]; then
            rm -f -- "$INSTALL_DIR/.$bin.new"
            install -o root -g root -m 0755 "$src/$bin" "$INSTALL_DIR/.$bin.new"
            mv -f -- "$INSTALL_DIR/.$bin.new" "$INSTALL_DIR/$bin"
        fi
    done
}

# =============================================================================
# Verzeichnisse, Rechte, Verwaltungs-Scripts
# =============================================================================

ensure_data_dir() {
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0700 "$DATA_DIR"
    chown -hR "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"
    chmod -R go-rwx "$DATA_DIR"
}

# Programmverzeichnis gehört root - der Dienst kann weder Binaries noch Scripts ändern.
harden_install_dir() {
    install -d -o root -g root -m 0755 "$INSTALL_DIR"
    chown -hR root:root "$INSTALL_DIR"
    chmod -R go-w "$INSTALL_DIR"
}

install_management_scripts() {
    local src=$1 f mode
    if [[ $src -ef $INSTALL_DIR ]]; then return 0; fi
    for f in "${MANAGEMENT_FILES[@]}"; do
        [[ -f $src/$f && ! -L $src/$f ]] || die "Datei fehlt: $src/$f"
    done
    install -d -o root -g root -m 0755 "$INSTALL_DIR" "$INSTALL_DIR/lib"
    for f in "${MANAGEMENT_FILES[@]}"; do
        if [[ $f == lib/* ]]; then mode=0644; else mode=0755; fi
        rm -f -- "$INSTALL_DIR/$f.new"
        install -o root -g root -m "$mode" "$src/$f" "$INSTALL_DIR/$f.new"
        mv -f -- "$INSTALL_DIR/$f.new" "$INSTALL_DIR/$f"
    done
}

# Installiert die Scripts aus SCRIPT_DIR, sofern dort nicht schon eine neuere Version liegt.
install_own_scripts() {
    local installed
    if [[ $SCRIPT_DIR -ef $INSTALL_DIR ]]; then return 0; fi
    installed=$(script_version_of "$INSTALL_DIR/lib/common.sh")
    if [[ -n $installed ]] && version_gt "$installed" "$BZ_SCRIPT_VERSION"; then
        warn "In $INSTALL_DIR liegen neuere Verwaltungs-Scripts (v$installed) - werden nicht ersetzt."
        return 0
    fi
    install_management_scripts "$SCRIPT_DIR"
    log "Verwaltungs-Scripts v$BZ_SCRIPT_VERSION nach $INSTALL_DIR installiert."
}

# Sichert jeden (unterschiedlichen) Schlüssel einmalig nach BACKUP_DIR.
backup_keys() {
    local fp dest
    [[ -s $DATA_DIR/id_ed25519 ]] || return 0
    fp=$(file_sha256 "$DATA_DIR/id_ed25519.pub")
    if [[ -z $fp ]]; then fp=$(file_sha256 "$DATA_DIR/id_ed25519"); fi
    dest="$BACKUP_DIR/keys-${fp:0:16}"
    if [[ -f $dest/id_ed25519 ]]; then return 0; fi
    install -d -o root -g root -m 0700 "$BACKUP_DIR" "$dest"
    install -o root -g root -m 0600 "$DATA_DIR/id_ed25519" "$dest/id_ed25519"
    if [[ -f $DATA_DIR/id_ed25519.pub ]]; then
        install -o root -g root -m 0600 "$DATA_DIR/id_ed25519.pub" "$dest/id_ed25519.pub"
    fi
    log "Schlüsselpaar gesichert: $dest/"
}

read_public_key() {
    PUBLIC_KEY=""
    if [[ -s $DATA_DIR/id_ed25519.pub ]]; then
        PUBLIC_KEY=$(tr -d '[:space:]' <"$DATA_DIR/id_ed25519.pub")
    fi
}

# =============================================================================
# systemd
# =============================================================================

# Bisherige Zusatzargumente aus ExecStart übernehmen (z.B. "-r relay.example.com").
_unit_extra_args() {
    local file="$SYSTEMD_DIR/$1.service" line
    [[ -f $file ]] || return 0
    line=$(grep -m1 '^ExecStart=' "$file" || true)
    line=${line#ExecStart=}
    if [[ $line == "$INSTALL_DIR/$2 "* ]]; then
        printf '%s' "${line#"$INSTALL_DIR/$2 "}"
    fi
}

_has_key_arg() {
    [[ " $1" =~ [[:space:]](-k|--key) ]]
}

# Eigener Schlüssel per .env (KEY=...) konfiguriert? Dann kein "-k _" erzwingen.
_env_defines_key() {
    local f
    for f in "$DATA_DIR/.env" "$INSTALL_DIR/.env"; do
        if [[ -f $f ]] && grep -qiE '^[[:space:]]*key[[:space:]]*=' "$f"; then return 0; fi
    done
    return 1
}

_render_unit() {  # $1 Name, $2 Beschreibung, $3 ExecStart, $4 zusätzliche After=-Einträge
    cat <<EOF
# Verwaltet von BZ RustDesk Server Setup - wird bei Updates neu geschrieben.
# Eigene Anpassungen bitte als Drop-in: systemctl edit $1
[Unit]
Description=$2
Documentation=https://rustdesk.com/docs/en/self-host/
After=network-online.target${4:+ $4}
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=$3
WorkingDirectory=${DATA_DIR}
StateDirectory=rustdesk
StateDirectoryMode=0700
UMask=0077
Restart=always
RestartSec=5
LimitNOFILE=1000000
SyslogIdentifier=$1

# --- Sicherheitshärtung ---
NoNewPrivileges=true
CapabilityBoundingSet=
AmbientCapabilities=
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
EOF
}

render_units() {  # $1 Zielverzeichnis
    local out=$1 hbbs_args hbbr_args
    hbbs_args=$(_unit_extra_args rustdesk-hbbs hbbs)
    hbbr_args=$(_unit_extra_args rustdesk-hbbr hbbr)
    # hbbs prüft den Schlüssel standardmäßig, hbbr nur mit "-k _" (sonst offenes Relay).
    if ! _has_key_arg "$hbbr_args" && ! _env_defines_key; then
        hbbr_args="-k _${hbbr_args:+ $hbbr_args}"
    fi
    _render_unit rustdesk-hbbs "RustDesk ID/Rendezvous Server (hbbs)" \
        "$INSTALL_DIR/hbbs${hbbs_args:+ $hbbs_args}" "" >"$out/rustdesk-hbbs.service"
    _render_unit rustdesk-hbbr "RustDesk Relay Server (hbbr)" \
        "$INSTALL_DIR/hbbr${hbbr_args:+ $hbbr_args}" "rustdesk-hbbs.service" >"$out/rustdesk-hbbr.service"
}

units_up_to_date() {
    local tmp svc
    make_tmp_dir tmp
    render_units "$tmp"
    for svc in "${SERVICES[@]}"; do
        cmp -s "$tmp/$svc.service" "$SYSTEMD_DIR/$svc.service" || return 1
    done
    return 0
}

install_units() {
    local tmp svc
    make_tmp_dir tmp
    render_units "$tmp"
    for svc in "${SERVICES[@]}"; do
        install -o root -g root -m 0644 "$tmp/$svc.service" "$SYSTEMD_DIR/$svc.service"
    done
    systemctl daemon-reload
}

stop_services() {
    systemctl stop "${SERVICES[@]}" >/dev/null 2>&1 || true
}

# Port lauscht und gehört dem erwarteten Prozess?  $1 t|u, $2 Port, $3 Prozessname
port_owned_by() {
    local out
    out=$(ss "-Hlnp$1" "sport = :$2" 2>/dev/null || true)
    [[ $out == *"((\"$3\","* ]]
}

_restart_counts() {
    systemctl show -p NRestarts --value "${SERVICES[@]}" 2>/dev/null | tr -s '\n' ' ' || true
}

wait_for_key() {
    local i
    for ((i = 0; i < 40; i++)); do
        if [[ -s $DATA_DIR/id_ed25519 && -s $DATA_DIR/id_ed25519.pub ]]; then
            sleep 0.5
            return 0
        fi
        sleep 0.5
    done
    warn "hbbs hat keinen Schlüssel in $DATA_DIR bereitgestellt."
    return 1
}

health_check() {
    local i svc before after ports_ok=0
    for ((i = 0; i < 15; i++)); do
        if port_owned_by t 21116 hbbs && port_owned_by t 21117 hbbr; then
            ports_ok=1
            break
        fi
        sleep 1
    done
    before=$(_restart_counts)
    sleep 3
    after=$(_restart_counts)
    for svc in "${SERVICES[@]}"; do
        if ! systemctl is-active --quiet "$svc"; then
            warn "$svc ist nicht aktiv."
            return 1
        fi
    done
    if [[ $before != "$after" ]]; then
        warn "Die Dienste starten wiederholt neu."
        return 1
    fi
    if ((ports_ok)); then
        log "Dienste laufen (hbbs: 21115/21116, hbbr: 21117)."
    else
        warn "Standard-Ports 21116/21117 nicht gefunden - abweichende Port-Konfiguration?"
    fi
    return 0
}

# hbbs zuerst starten (erzeugt bzw. liest den Schlüssel), danach hbbr -
# hbbr wartet nur 300 ms auf den Schlüssel und würde sonst selbst einen erzeugen.
start_services() {
    systemctl enable --quiet "${SERVICES[@]}" >>"$LOG_FILE" 2>&1 || return 1
    systemctl restart rustdesk-hbbs || return 1
    wait_for_key || return 1
    systemctl restart rustdesk-hbbr || return 1
    health_check
}

show_service_diagnostics() {
    local svc
    for svc in "${SERVICES[@]}"; do
        echo "----- $svc -----"
        systemctl status "$svc" --no-pager -l -n 20 2>&1 | tee -a "$LOG_FILE" || true
    done
}

# =============================================================================
# Rollback-Snapshot (Binaries, Units, version.txt, Schlüssel)
# =============================================================================

SNAPSHOT_DIR=""
SNAPSHOT_WAS_ACTIVE=0

take_snapshot() {
    local bin svc f
    make_tmp_dir SNAPSHOT_DIR
    mkdir -p "$SNAPSHOT_DIR/bin" "$SNAPSHOT_DIR/units" "$SNAPSHOT_DIR/data"
    for bin in "${BINARIES[@]}"; do
        if [[ -f $INSTALL_DIR/$bin && ! -L $INSTALL_DIR/$bin ]]; then
            cp -p -- "$INSTALL_DIR/$bin" "$SNAPSHOT_DIR/bin/$bin"
        fi
    done
    for svc in "${SERVICES[@]}"; do
        if [[ -f $SYSTEMD_DIR/$svc.service ]]; then
            cp -p -- "$SYSTEMD_DIR/$svc.service" "$SNAPSHOT_DIR/units/$svc.service"
        fi
    done
    for f in id_ed25519 id_ed25519.pub; do
        if [[ -f $DATA_DIR/$f && ! -L $DATA_DIR/$f ]]; then
            cp -p -- "$DATA_DIR/$f" "$SNAPSHOT_DIR/data/$f"
        fi
    done
    if [[ -f $VERSION_FILE && ! -L $VERSION_FILE ]]; then
        cp -p -- "$VERSION_FILE" "$SNAPSHOT_DIR/version.txt"
    fi
    SNAPSHOT_WAS_ACTIVE=0
    if systemctl is-active --quiet rustdesk-hbbs 2>/dev/null; then SNAPSHOT_WAS_ACTIVE=1; fi
}

# Best effort - läuft im Fehlerfall, bricht selbst nicht ab.
restore_snapshot() {
    local f name
    for f in "$SNAPSHOT_DIR"/bin/*; do
        [[ -f $f ]] || continue
        name=${f##*/}
        rm -f -- "$INSTALL_DIR/.$name.new"
        install -o root -g root -m 0755 "$f" "$INSTALL_DIR/.$name.new" &&
            mv -f -- "$INSTALL_DIR/.$name.new" "$INSTALL_DIR/$name"
    done
    for f in "$SNAPSHOT_DIR"/units/*; do
        [[ -f $f ]] || continue
        install -o root -g root -m 0644 "$f" "$SYSTEMD_DIR/${f##*/}"
    done
    systemctl daemon-reload
    if [[ -f $SNAPSHOT_DIR/version.txt ]]; then
        install -o root -g root -m 0644 "$SNAPSHOT_DIR/version.txt" "$VERSION_FILE"
    fi
}

restore_snapshot_keys() {
    local f name
    for f in "$SNAPSHOT_DIR"/data/*; do
        [[ -f $f ]] || continue
        name=${f##*/}
        if ! cmp -s "$f" "$DATA_DIR/$name"; then
            install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0600 "$f" "$DATA_DIR/$name"
            warn "$DATA_DIR/$name aus Sicherung wiederhergestellt."
        fi
    done
}

# =============================================================================
# Firewall (ufw)
# =============================================================================

print_port_list() {
    local rule
    for rule in "${FIREWALL_RULES[@]}"; do
        printf '         %-10s %s\n' "${rule%%|*}" "${rule#*|}"
    done
}

# SSH-Ports aus sshd-Konfiguration, lauschenden Sockets und aktueller Verbindung.
detect_ssh_ports() {
    local ports
    ports=$({
        sshd -T 2>/dev/null | awk '$1 == "port" {print $2}'
        ss -Hltnp 2>/dev/null | awk '/"sshd"/ {n = split($4, a, ":"); print a[n]}'
        if [[ -n ${SSH_CONNECTION:-} ]]; then awk '{print $4}' <<<"$SSH_CONNECTION"; fi
    } | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ' || true)
    ports=${ports% }
    printf '%s' "${ports:-22}"
}

# Öffentlich lauschende TCP-Dienste außer SSH/RustDesk (wären nach "ufw enable" gesperrt).
list_other_listeners() {
    ss -Hltnp 2>/dev/null | awk -v skip=" $1 21115 21116 21117 21118 21119 " '
        {
            addr = $4; n = split(addr, a, ":"); port = a[n]
            host = substr(addr, 1, length(addr) - length(port) - 1)
            if (host ~ /^127\./ || host == "[::1]" || host ~ /^\[::ffff:127\./) next
            if (index(skip, " " port " ") > 0) next
            proc = "?"
            if (match($0, /users:\(\("[^"]+"/)) proc = substr($0, RSTART + 9, RLENGTH - 10)
            print port "/tcp (" proc ")"
        }' | sort -u || true
}

ufw_rule_exists() {  # $1 z.B. "80/tcp" - auch Regeln mit Kommentar
    local added
    added=$(LC_ALL=C ufw show added 2>/dev/null || true)
    grep -qE "^ufw allow ${1//./\\.}( |$)" <<<"$added"
}

port_in_use() {
    local out
    out=$(ss -Hltn "sport = :$1" 2>/dev/null || true)
    [[ -n $out ]]
}

# Entfernt Freigaben, die ältere Versionen geöffnet haben, die RustDesk aber nicht braucht.
remove_obsolete_firewall_rules() {
    local rule removed=()
    ((MANAGE_FIREWALL)) || return 0
    command -v ufw >/dev/null 2>&1 || return 0
    for rule in "${OBSOLETE_FIREWALL_RULES[@]}"; do
        if ufw_rule_exists "$rule"; then
            ufw delete allow "$rule" >/dev/null 2>&1 || true
            removed+=("$rule")
        fi
    done
    if ((${#removed[@]})); then
        log "Nicht benötigte Firewall-Freigaben geschlossen: ${removed[*]} (WebSocket)"
    fi
}

# Altlast der v1-Installation: Let's-Encrypt-Zertifikat + Ports 80/443 - von RustDesk nie genutzt.
# $1 = Domain aus der alten version.txt
legacy_ssl_cleanup() {
    local domain=${1,,} have_cert=0 have_ports=0
    if [[ -n $domain ]] && valid_host "$domain" && command -v certbot >/dev/null 2>&1 &&
        [[ -d $LETSENCRYPT_LIVE_DIR/$domain ]]; then
        have_cert=1
    fi
    if ((MANAGE_FIREWALL)) && command -v ufw >/dev/null 2>&1 &&
        { ufw_rule_exists 80/tcp || ufw_rule_exists 443/tcp; }; then
        have_ports=1
    fi
    ((have_cert || have_ports)) || return 0

    if port_in_use 80 || port_in_use 443; then
        info "Auf Port 80/443 läuft ein anderer Dienst - Zertifikat und Freigaben 80/443 bleiben unverändert."
        return 0
    fi
    echo
    info "Die alte Installation hat ein Let's-Encrypt-Zertifikat angelegt und die Ports 80/443 geöffnet."
    info "RustDesk nutzt beides nicht (verschlüsselt wird über das Schlüsselpaar)."
    ask_yes_no "Zertifikat entfernen und Ports 80/443 schließen?" j || return 0

    if ((have_cert)); then
        if certbot delete --cert-name "$domain" --non-interactive >/dev/null 2>&1; then
            log "Zertifikat für $domain gelöscht."
        else
            warn "Zertifikat für $domain konnte nicht gelöscht werden."
        fi
        # certbot nur entfernen, wenn keine weiteren Zertifikate existieren
        if ! compgen -G "$LETSENCRYPT_LIVE_DIR/*/" >/dev/null; then
            if apt-get remove -y -qq certbot >/dev/null 2>&1; then
                log "certbot entfernt (keine weiteren Zertifikate vorhanden)."
            fi
        fi
    fi
    if ((have_ports)); then
        ufw delete allow 80/tcp >/dev/null 2>&1 || true
        ufw delete allow 443/tcp >/dev/null 2>&1 || true
        log "Ports 80/443 geschlossen."
    fi
}
