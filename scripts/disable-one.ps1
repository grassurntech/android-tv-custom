# Turns off ONE package on the TV with `pm disable-user --user 0 <package>`. Never uninstalls.
# This is the only way product code may disable a package; every safety check lives here.
# Exit: 0 done (or already off), 2 bad arguments, 3 setup missing or a local file can't be read/written
#       (a safety list that is missing, unreadable, UTF-16 or empty; an unreadable backup file; an undo log
#       that can't be written: all checked before any change), 10 protected (or the TV's current Home app),
#       11 streaming app, 12 forbidden, 13 no usable backup or the backup is from another TV,
#       14 not in the backup, 20 TV refused or didn't answer, 21 unreachable, 22 unauthorized.
# The undo log (disabled-by-us.txt) is written BEFORE the change, so a change can never go unrecorded.
# Mirrors disable-one.sh.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/TvEnv.psm1') -Force

function Write-Err([string]$Text) { [Console]::Error.WriteLine($Text) }
# Any unexpected PowerShell error (an unreadable file, say) is a local problem: exit 3, never 1.
trap {
    [Console]::Error.WriteLine("Unexpected local error: $($_.Exception.Message). Check the TV before doing anything else. Stopping.")
    exit 3
}

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

# 2. Config, then the three safety lists must exist, be readable and hold patterns (else exit 3).
Import-TvEnv
$cfg = Join-Path $global:REPO_ROOT 'config'
foreach ($list in @('protected-packages.txt', 'streaming-apps.txt', 'forbidden-packages.txt')) {
    $null = Get-TvListPatterns (Join-Path $cfg $list)
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

# 4. A backup must exist before the first change (every backup file readable, else exit 3).
Assert-TvBackupsReadable
$backups = @(Get-TvBackups | Where-Object { $_ })
if ($backups.Count -eq 0) {
    Write-Err 'No backup found. Run scripts/backup first. Nothing was changed. Stopping.'
    exit 13
}
$backup = [string]$backups[0]

# 5. The TV must be reachable.
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

# 6. The backup must come from this TV (sets $global:TV_ID).
Assert-TvIdentity $backup

# 7. The package must be in that backup's package list, or be one we installed ourselves (recorded in a
# usable backup of this same TV). Exact, case-sensitive match of a line, ignoring CR, spaces and a package: prefix.
function Test-ListHas([string]$File, [string]$Name) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $false }
    foreach ($raw in [System.IO.File]::ReadAllLines($File)) {
        $line = $raw.TrimStart([char]0xFEFF).Trim()
        if ($line.StartsWith('package:')) { $line = $line.Substring(8) }
        if ($line -ceq $Name) { return $true }
    }
    return $false
}
$known = Test-ListHas (Join-Path $backup 'packages-all.txt') $pkg
if (-not $known) {
    foreach ($folder in $backups) {
        if ((Get-TvBackupId ([string]$folder)) -cne $global:TV_ID) { continue }
        if (Test-ListHas (Join-Path ([string]$folder) 'installed-by-us.txt') $pkg) { $known = $true; break }
    }
}
if (-not $known) {
    Write-Err "$pkg is not in the backup and was not installed by us. Nothing was changed. Stopping."
    exit 14
}

# 8. Never switch off the app the TV currently uses as its Home screen (the TV would be left with none).
$homeLines = Invoke-TvAdbLines @('cmd', 'package', 'resolve-activity', '--brief', '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.HOME')
$homeRc = Get-TvAdbRc
$homeComp = ''
foreach ($l in $homeLines) {
    $t = $l.Trim()
    if ($t.Length -gt 0) { $homeComp = $t }
}
if (($homeRc -ne 0) -or ($homeComp -cnotmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)*/[A-Za-z0-9_.$]+\z')) {
    Write-Err "The TV didn't say which app is its Home screen, so $pkg was left alone. Nothing was changed. Stopping."
    exit 20
}
if ($homeComp.Split('/')[0] -ceq $pkg) {
    Write-Err "$pkg is the TV's current Home app, so it stays on. Nothing was changed. Stopping."
    exit 10
}

# Returns 0 if $Name is disabled, 1 if not, 2 if the TV could not answer (failed, or printed something that isn't a list).
function Get-DisabledState([string]$Name) {
    $lines = Invoke-TvAdbLines @('pm', 'list', 'packages', '-d')
    if ((Get-TvAdbRc) -ne 0) { return 2 }
    return (Get-TvListState $lines $Name)
}

# 9. Already off: nothing to do, nothing to log. No trustworthy answer: stop before changing anything.
$state = Get-DisabledState $pkg
if ($state -eq 0) {
    Write-Output "$pkg is already off. Nothing to do."
    exit 0
}
if ($state -ne 1) {
    Write-Err "The TV didn't answer when asked about $pkg. Nothing was changed. Stopping."
    exit 20
}

# 10. Write-ahead: record the package in the undo log BEFORE the change (append only). If that fails,
# nothing is sent to the TV.
$utf8 = New-Object System.Text.UTF8Encoding($false)
$logFile = Join-Path $backup 'disabled-by-us.txt'
$logExisted = Test-Path -LiteralPath $logFile
$stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
$entry = "$pkg`t$stamp"
try {
    $sep = ''
    if ((Test-Path -LiteralPath $logFile -PathType Leaf) -and ((Get-Item -LiteralPath $logFile).Length -gt 0)) {
        $bytes = [System.IO.File]::ReadAllBytes($logFile)
        if ($bytes[$bytes.Length - 1] -ne 10) { $sep = "`n" }
    }
    # UTF-8 without BOM, LF line ending: byte-identical to the shell version.
    [System.IO.File]::AppendAllText($logFile, "$sep$entry`n", $utf8)
} catch {
    Write-Err "Can't write the undo log $logFile. Nothing was changed. Stopping."
    exit 3
}

# Takes our own entry back out (only when the TV clearly did not change anything). Best effort: a stale entry
# is harmless, because restore reports a logged app that is still on as "already on".
function Remove-OurEntry {
    try {
        $kept = New-Object System.Text.StringBuilder
        $removed = $false
        foreach ($raw in [System.IO.File]::ReadAllLines($logFile)) {
            if ((-not $removed) -and ($raw -ceq $entry)) { $removed = $true; continue }
            if ($raw.Length -eq 0) { continue }
            $null = $kept.Append("$raw`n")
        }
        $tmp = "$logFile.tmp.$PID"
        [System.IO.File]::WriteAllText($tmp, $kept.ToString(), $utf8)
        Move-Item -LiteralPath $tmp -Destination $logFile -Force
        # A log this run created and that now holds nothing (no other run's records) goes again.
        if ((-not $logExisted) -and ((Get-Item -LiteralPath $logFile).Length -eq 0)) {
            Remove-Item -LiteralPath $logFile -Force
        }
        return $true
    } catch {
        return $false
    }
}

# 11. The one and only change. No retries.
$null = Invoke-TvAdbLines @('pm', 'disable-user', '--user', '0', $pkg)

# 12. Read it back.
$state = Get-DisabledState $pkg
if ($state -eq 0) {
    Write-Output "Turned off $pkg"
    exit 0
}
if ($state -eq 1) {
    if (Remove-OurEntry) {
        Write-Err "The TV refused to turn off $pkg. Nothing was changed. Stopping."
    } else {
        Write-Err "The TV refused to turn off $pkg, so nothing was changed on the TV (its line stays in $logFile; restore will report it as already on). Stopping."
    }
    exit 20
}
Write-Err "The TV didn't confirm whether $pkg was turned off, so it MAY be off. It is in the undo list ($logFile), so scripts/restore will turn it back on. Check before doing anything else. Stopping."
exit 20
