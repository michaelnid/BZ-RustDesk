<#
.SYNOPSIS
    BZ RustDesk Server - Deploy vom Windows-Rechner (PowerShell 5.1 / 7, eingebautes OpenSSH)

.DESCRIPTION
    Lädt die Scripts per SCP auf den Server und startet dort automatisch die
    Neuinstallation oder das Update - erkannt am Zustand des Servers. Login per SSH-Key.

    Verwendung: .\deploy.ps1 <Server-IP|Hostname> [-u Benutzer] [-p Port] [-i Schlüssel] [Optionen für install/update]
    Alle unbekannten Optionen (z.B. --domain, --yes) werden an install.sh/update.sh weitergereicht.

.EXAMPLE
    .\deploy.ps1 203.0.113.10
.EXAMPLE
    .\deploy.ps1 203.0.113.10 --domain rd.example.com
.EXAMPLE
    .\deploy.ps1 rd.example.com -u admin -p 2222 --yes
#>
# Bewusst ohne param()-Block: so kommen die Argumente in allen Aufrufarten unverändert an
# (getippt, "powershell -File", deploy.cmd) - auch "--" unter Windows PowerShell 5.1.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Fail([string]$Message) {
    Write-Host "FEHLER: $Message" -ForegroundColor Red
    exit 1
}
function Info([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}
function Show-Usage {
    Write-Host @'
Verwendung: .\deploy.ps1 <Server-IP|Hostname> [Optionen] [Optionen für install.sh/update.sh]

  -u, --user NAME       SSH-Benutzer (Standard: root; andere Benutzer per sudo)
  -p, --port PORT       SSH-Port (Standard: 22)
  -i, --identity DATEI  SSH-Schlüssel (Standard: ssh-agent bzw. ~\.ssh)
  -h, --help            Diese Hilfe

Alle anderen Optionen (z.B. --domain, --yes, --force) gehen an install.sh/update.sh.

Beispiele:
  .\deploy.ps1 203.0.113.10
  .\deploy.ps1 203.0.113.10 --domain rd.example.com
  .\deploy.ps1 rd.example.com -u admin -p 2222 --yes
'@
}
# Für die entfernte Shell sicher in einfache Anführungszeichen setzen
function Quote([string]$Value) {
    return "'" + ($Value -replace "'", "'\''") + "'"
}

# --- Argumente auswerten ---
$Server = ''
$User = if ($env:DEPLOY_USER) { $env:DEPLOY_USER } else { 'root' }
$Port = '22'
$Identity = ''
$remoteArgs = New-Object System.Collections.Generic.List[string]
$rest = @($args | ForEach-Object { [string]$_ })
for ($i = 0; $i -lt $rest.Count; $i++) {
    $a = $rest[$i]
    $hasValue = ($i + 1) -lt $rest.Count
    switch -Regex ($a) {
        '^(-u|--user|-User)$' { if (-not $hasValue) { Fail "$a benötigt einen Wert." }; $User = $rest[++$i]; continue }
        '^(-p|--port|-Port)$' { if (-not $hasValue) { Fail "$a benötigt einen Wert." }; $Port = $rest[++$i]; continue }
        '^(-i|--identity|-Identity)$' { if (-not $hasValue) { Fail "$a benötigt einen Wert." }; $Identity = $rest[++$i]; continue }
        '^(-h|--help|-\?)$' { Show-Usage; exit 0 }
        '^--$' { for ($j = $i + 1; $j -lt $rest.Count; $j++) { $remoteArgs.Add($rest[$j]) }; $i = $rest.Count; continue }
        default {
            if (-not $Server -and -not $a.StartsWith('-')) { $Server = $a } else { $remoteArgs.Add($a) }
        }
    }
}

if (-not $Server) { Show-Usage; exit 1 }
if ($Server -notmatch '^[A-Za-z0-9][A-Za-z0-9.:-]*$') { Fail "Ungültiger Server: $Server" }
if ($User -cnotmatch '^[a-z_][a-z0-9_.-]*$') { Fail "Ungültiger Benutzer: $User" }
if ($Port -notmatch '^[0-9]{1,5}$' -or [int]$Port -lt 1 -or [int]$Port -gt 65535) { Fail "Ungültiger Port: $Port" }
if ($Identity -and -not (Test-Path -LiteralPath $Identity -PathType Leaf)) { Fail "SSH-Schlüssel nicht gefunden: $Identity" }
foreach ($tool in 'ssh', 'scp') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Fail "$tool nicht gefunden - Windows-Funktion 'OpenSSH-Client' aktivieren."
    }
}

$root = $PSScriptRoot
foreach ($file in 'install.sh', 'update.sh', 'uninstall.sh', 'lib\common.sh') {
    $path = Join-Path $root $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Fail "Datei fehlt: $path" }
    if ([IO.File]::ReadAllBytes($path) -contains 13) {
        Fail "$file hat Windows-Zeilenenden (CRLF) - Repository neu auschecken (.gitattributes erzwingt LF)."
    }
}

# Nur Key-Login; neue Hostkeys werden einmalig gemerkt, geänderte abgelehnt
$sshOpts = @('-o', 'PreferredAuthentications=publickey', '-o', 'StrictHostKeyChecking=accept-new',
    '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=30')
if ($Identity) { $sshOpts += @('-i', $Identity, '-o', 'IdentitiesOnly=yes') }
$target = "$User@$Server"
$scpTarget = if ($Server.Contains(':')) { "$User@[$Server]" } else { $target }

# Ausgabe des Servers (UTF-8) korrekt anzeigen
$previousEncoding = [Console]::OutputEncoding
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }

try {
    # 1) Verbinden, Upload-Verzeichnis anlegen, Neuinstallation oder Update erkennen
    Info "Verbinde mit $target (Port $Port, SSH-Key)..."
    $detect = 'd=$(mktemp -d /tmp/bz-rustdesk-deploy.XXXXXX) && if [ -e /opt/rustdesk/hbbs ] || [ -e /etc/systemd/system/rustdesk-hbbs.service ]; then echo update $d; else echo install $d; fi'
    $output = & ssh @sshOpts -p $Port $target $detect
    if ($LASTEXITCODE -ne 0) {
        Fail 'SSH-Anmeldung fehlgeschlagen - ist der SSH-Key auf dem Server hinterlegt (Benutzer/Port korrekt)?'
    }
    $line = (@($output) | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
    $line = "$line".Trim()
    $mode, $remoteDir = $line -split ' ', 2
    if ($mode -notin @('install', 'update')) { Fail "Unerwartete Antwort vom Server: $line" }
    if ($remoteDir -notmatch '^/tmp/bz-rustdesk-deploy\.[A-Za-z0-9]+$') { Fail "Unerwartetes Upload-Verzeichnis: $remoteDir" }

    if ($mode -eq 'update') { Info 'Bestehende Installation gefunden -> Update' }
    else { Info 'Keine Installation gefunden -> Neuinstallation' }

    # 2) Scripts per SCP hochladen (relative Pfade - keine Laufwerksbuchstaben für scp)
    Info 'Lade Scripts hoch (scp)...'
    Push-Location -LiteralPath $root
    try {
        & scp -q @sshOpts -P $Port -r install.sh update.sh uninstall.sh lib "$($scpTarget):$remoteDir/"
        if ($LASTEXITCODE -ne 0) {
            & ssh @sshOpts -p $Port $target "rm -rf $remoteDir" 2>$null | Out-Null
            Fail 'Upload fehlgeschlagen.'
        }
    }
    finally { Pop-Location }

    # 3) Ausführen (mit Terminal, damit Rückfragen und sudo funktionieren), danach aufräumen
    $quoted = @($remoteArgs | ForEach-Object { Quote $_ })
    $argString = if ($quoted.Count -gt 0) { ' ' + ($quoted -join ' ') } else { '' }
    $sudo = if ($User -eq 'root') { '' } else { 'sudo ' }
    $run = "trap 'rm -rf $remoteDir' INT TERM HUP; ${sudo}bash $remoteDir/$mode.sh$argString; rc=`$?; rm -rf $remoteDir; exit `$rc"

    Info "Starte $mode.sh auf dem Server..."
    & ssh -t @sshOpts -p $Port $target $run
    $rc = $LASTEXITCODE
    if ($rc -ne 0) { Fail "$mode.sh ist mit Exit-Code $rc beendet worden - Ausgabe oben prüfen." }
    Info "Deploy erfolgreich abgeschlossen ($mode)."
}
finally {
    try { [Console]::OutputEncoding = $previousEncoding } catch { }
}
