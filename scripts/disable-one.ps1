# Turns off ONE package on the TV with `pm disable-user --user 0 <package>`. Never uninstalls.
# This is the only way product code may disable a package; every safety check lives here.
# Exit: 0 done (or already off), 2 bad arguments, 3 setup missing, 10 protected, 11 streaming app,
#       12 forbidden, 13 no usable backup, 14 not in the backup, 20 TV refused, 21 unreachable,
#       22 unauthorized. (3 also covers an undo log that can't be written, checked before any change.)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/TvEnv.psm1') -Force

function Write-Err([string]$Text) { [Console]::Error.WriteLine($Text) }

# 1. Exactly one argument, shaped like a package name (no globs, no spaces, no shell characters).
if ($args.Count -ne 1) {
    Write-Err 'Usage: disable-one.ps1 <package.name>   (exactly one package)'
    exit 2
}
$pkg = [string]$args[0]
# -cmatch: ordinal ASCII classes; \z (not $) so a trailing newline cannot slip through.
if ($pkg -cnotmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+\z') {
    Write-Err "That doesn't look like a package name: $pkg. Nothing was changed. Stopping."
    exit 2
}

# 2. Config, then the three safety lists must exist.
Import-TvEnv
$cfg = Join-Path $global:REPO_ROOT 'config'
foreach ($list in @('protected-packages.txt', 'streaming-apps.txt', 'forbidden-packages.txt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $cfg $list) -PathType Leaf)) {
        Write-Err "Missing config/$list. Nothing was changed. Stopping."
        exit 3
    }
}

# 3. Never touch protected, streaming or forbidden packages.
if (Test-TvMatches $pkg (Join-Path $cfg 'protected-packages.txt')) {
    Write-Err "$pkg is protected (it keeps the TV working as a TV). Nothing was changed. Stopping."
    exit 10
}
if (Test-TvMatches $pkg (Join-Path $cfg 'streaming-apps.txt')) {
    Write-Err "$pkg is a streaming app. Turn it off yourself in TV Settings if you want to. Nothing was changed. Stopping."
    exit 11
}
if (Test-TvMatches $pkg (Join-Path $cfg 'forbidden-packages.txt')) {
    Write-Err "$pkg is a factory or service app that must never be touched. Nothing was changed. Stopping."
    exit 12
}

# 4. A backup must exist before the first change.
$backup = @(Get-TvLatestBackup | Where-Object { $_ })
if ($backup.Count -eq 0) {
    Write-Err 'No backup found. Run scripts/backup first. Nothing was changed. Stopping.'
    exit 13
}
$backup = [string]$backup[0]

# 5. The package must be in that backup's package list, or be one we installed ourselves.
# Exact, case-sensitive match of a line, ignoring CR, spaces and a package: prefix.
function Test-ListHas([string]$File, [string]$Name) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $false }
    foreach ($raw in [System.IO.File]::ReadAllLines($File)) {
        $line = $raw.Trim()
        if ($line.StartsWith('package:')) { $line = $line.Substring(8) }
        if ($line -ceq $Name) { return $true }
    }
    return $false
}
$known = Test-ListHas (Join-Path $backup 'packages-all.txt') $pkg
if (-not $known) {
    foreach ($d in Get-ChildItem -LiteralPath $global:TV_BACKUP_DIR -Directory) {
        if (Test-ListHas (Join-Path $d.FullName 'installed-by-us.txt') $pkg) { $known = $true; break }
    }
}
if (-not $known) {
    Write-Err "$pkg is not in the backup and was not installed by us. Nothing was changed. Stopping."
    exit 14
}

# 6. The TV must be reachable.
$rc = Test-TvReachable
if ($rc -eq 22) {
    Write-Err "Accept 'Allow debugging?' on the TV, then run this again"
    exit 22
}
if ($rc -eq 21) {
    Write-Err "Can't reach the TV at $($global:TV_IP)"
    exit 21
}
if ($rc -ne 0) { exit $rc }

# Runs a command on the TV (each element is one literal argument). Sets $script:AdbRc and returns stdout lines.
# Windows PowerShell 5.1 turns native stderr into terminating errors under 'Stop', so relax it here.
$script:AdbRc = 0
function Invoke-Adb([string[]]$Cmd) {
    $ErrorActionPreference = 'Continue'
    $out = & $global:ADB -s $global:SERIAL shell @Cmd 2>&1
    $script:AdbRc = $LASTEXITCODE
    # foreach, not a pipeline: empty output ($null) must not reach ToString() on 5.1.
    $lines = @()
    foreach ($o in $out) { if ($null -ne $o) { $lines += $o.ToString() } }
    return $lines
}

# Returns 0 if $Name is disabled, 1 if not, 2 if the TV could not answer.
function Get-DisabledState([string]$Name) {
    $lines = @(Invoke-Adb @('pm', 'list', 'packages', '-d'))
    if ($script:AdbRc -ne 0) { return 2 }
    foreach ($l in $lines) {
        if ($l.Trim() -ceq "package:$Name") { return 0 }
    }
    return 1
}

# 7. Already off: nothing to do, nothing to log.
$state = Get-DisabledState $pkg
if ($state -eq 0) {
    Write-Output "$pkg is already off. Nothing to do."
    exit 0
}
if ($state -ne 1) {
    Write-Err "The TV didn't answer when asked about $pkg. Nothing was changed. Stopping."
    exit 20
}

# 7b. The undo log must be writable BEFORE we change anything (open for append, then close).
# A log we just created for this check is removed again so a refusal leaves no stray file.
$logFile = Join-Path $backup 'disabled-by-us.txt'
$logExisted = Test-Path -LiteralPath $logFile
try {
    $fs = New-Object System.IO.FileStream($logFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
    $fs.Dispose()
} catch {
    Write-Err "Can't write the undo log $logFile. Nothing was changed. Stopping."
    exit 3
}
if (-not $logExisted) { Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue }

# 8. The one and only change. No retries.
$null = Invoke-Adb @('pm', 'disable-user', '--user', '0', $pkg)

# 9. Check it really is off, then record it for the undo.
$state = Get-DisabledState $pkg
if ($state -eq 2) {
    Write-Err "The TV didn't confirm whether $pkg was turned off. Check before doing anything else. Stopping."
    exit 20
}
if ($state -ne 0) {
    Write-Err "The TV refused to turn off $pkg. Nothing was changed. Stopping."
    exit 20
}
$stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
try {
    # UTF-8 without BOM, LF line ending: byte-identical to the shell version.
    [System.IO.File]::AppendAllText($logFile, "$pkg`t$stamp`n", (New-Object System.Text.UTF8Encoding($false)))
} catch {
    Write-Err "The TV DID turn off $pkg, but the undo log $logFile could not be written. To turn it back on, run: adb -s $($global:SERIAL) shell pm enable $pkg"
    exit 20
}
Write-Output "Turned off $pkg"
exit 0
