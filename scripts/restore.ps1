# Undoes what this tool changed on the TV. Never uninstalls anything.
#   restore.ps1 [--home-only | --packages-only]     (default: both, Home first)
# Home:     turn the stock launcher back on, make it Home again, then switch OUR launcher off
#           (through disable-one.ps1, the only script that disables anything).
# Packages: turn back on every package listed in each backup's disabled-by-us.txt that is not yet in
#           that folder's restored.txt, one `pm enable` at a time, newest backup first. A TV refusal stops it.
# Exit: 0 done (or nothing to do), 2 bad arguments, 3 setup missing or a file is unreadable,
#       13 no usable backup, 20 TV refused, 21 unreachable, 22 unauthorized; a failed Home disable
#       passes disable-one's own exit code up unchanged.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/TvEnv.psm1') -Force

function Write-Err([string]$Text) { [Console]::Error.WriteLine($Text) }

$OurLauncher = 'com.gathin.tvhome'
$PkgRe = '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+\z'
$CompRe = '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+/[A-Za-z0-9_.$]+\z'

# 1. Arguments.
$doHome = $true
$doPkgs = $true
if ($args.Count -eq 1 -and [string]$args[0] -ceq '--home-only') {
    $doPkgs = $false
} elseif ($args.Count -eq 1 -and [string]$args[0] -ceq '--packages-only') {
    $doHome = $false
} elseif ($args.Count -ne 0) {
    Write-Err 'Usage: restore.ps1 [--home-only | --packages-only]'
    exit 2
}

# 2. Config, then at least one usable backup.
Import-TvEnv
$backups = @(Get-TvBackups | Where-Object { $_ })
if ($backups.Count -eq 0) {
    Write-Err 'No backup found, so there is nothing to restore from. Nothing was changed. Stopping.'
    exit 13
}

# 3. The TV must be reachable.
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

# The text before the first tab, trimmed, without a BOM.
function Get-FirstField([string]$Line) {
    $t = $Line.TrimStart([char]0xFEFF)
    return $t.Split("`t")[0].Trim()
}

# $true if the pkg is already a line of that restored.txt.
function Test-InRestored([string]$File, [string]$Name) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $false }
    foreach ($raw in [System.IO.File]::ReadAllLines($File)) {
        if ((Get-FirstField $raw) -ceq $Name) { return $true }
    }
    return $false
}

# The value of the first `key=value` line, or $null.
function Get-StateValue([string]$File, [string]$Key) {
    foreach ($raw in [System.IO.File]::ReadAllLines($File)) {
        $line = $raw.TrimStart([char]0xFEFF).Trim()
        if ($line.StartsWith("$Key=", [System.StringComparison]::Ordinal)) {
            return $line.Substring($Key.Length + 1).Trim()
        }
    }
    return $null
}

$script:ours = $OurLauncher

# ---- Home ------------------------------------------------------------------------------------
function Restore-Home {
    $hs = $null
    foreach ($folder in $backups) {
        $candidate = Join-Path ([string]$folder) 'home-state.txt'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $hs = $candidate; break }
    }
    if ($null -eq $hs) {
        Write-Output 'No home-state.txt in any backup, so the Home screen was never changed. Skipping the Home step.'
        return
    }
    $stockPkg = [string](Get-StateValue $hs 'stock_package')
    $stockComp = [string](Get-StateValue $hs 'stock_component')
    $oursVal = [string](Get-StateValue $hs 'ours')
    if ($oursVal.Length -gt 0) { $script:ours = $oursVal }
    if (($stockPkg -cnotmatch $PkgRe) -or ($stockComp -cnotmatch $CompRe) -or ($script:ours -cnotmatch $PkgRe)) {
        Write-Err "$hs is missing or has a bad stock_package, stock_component or ours line. Nothing was changed. Stopping."
        exit 3
    }

    $null = Invoke-Adb @('pm', 'enable', $stockPkg)
    if ((Get-DisabledState $stockPkg) -ne 1) {
        Write-Err "The TV would not turn the original launcher ($stockPkg) back on. Home was left as it was and nothing else was restored. Stopping."
        exit 20
    }
    $null = Invoke-Adb @('cmd', 'package', 'set-home-activity', '--user', '0', $stockComp)
    if ($script:AdbRc -ne 0) {
        Write-Err "The original launcher ($stockPkg) is on again, but the TV would not make it the Home screen. Our launcher was left on and nothing else was restored. Stopping."
        exit 20
    }
    Write-Output "The original launcher ($stockPkg) is back as the Home screen."

    # Child process, so disable-one's own exit code comes back to us unchanged.
    $ErrorActionPreference = 'Continue'
    $psExe = (Get-Process -Id $PID).Path
    $childArgs = @('-NoProfile')
    if ([System.IO.Path]::DirectorySeparatorChar -eq '\') { $childArgs += @('-ExecutionPolicy', 'Bypass') }
    $childArgs += @('-File', (Join-Path $PSScriptRoot 'disable-one.ps1'), $script:ours)
    & $psExe @childArgs
    $childRc = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($childRc -ne 0) {
        Write-Err "The original launcher is back, but our launcher ($($script:ours)) could not be switched off. Packages were not restored. Stopping."
        exit $childRc
    }
}

# ---- Packages --------------------------------------------------------------------------------
function Restore-Packages {
    $n = 0
    $skipped = 0
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    foreach ($folder in $backups) {
        $log = Join-Path ([string]$folder) 'disabled-by-us.txt'
        $res = Join-Path ([string]$folder) 'restored.txt'
        if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { continue }
        $lineno = 0
        foreach ($raw in [System.IO.File]::ReadAllLines($log)) {
            $lineno++
            $pkg = Get-FirstField $raw
            if ($pkg.Length -eq 0) { continue }
            if ($pkg -cnotmatch $PkgRe) {
                Write-Err "Line $lineno of $log is not a package name. Restored $n so far; stopping before changing anything else."
                exit 3
            }
            if (Test-InRestored $res $pkg) { continue }
            # Our own launcher stays switched off (it is never re-enabled by a restore).
            if (($pkg -ceq $OurLauncher) -or ($pkg -ceq $script:ours)) { $skipped++; continue }
            $state = Get-DisabledState $pkg
            if ($state -eq 2) {
                Write-Err "The TV didn't answer when asked about $pkg. Restored $n so far. Not restored: $pkg and everything after it. Stopping."
                exit 20
            }
            if ($state -eq 0) {
                $null = Invoke-Adb @('pm', 'enable', $pkg)
                if ((Get-DisabledState $pkg) -ne 1) {
                    Write-Err "The TV refused to turn $pkg back on. Restored $n so far. Not restored: $pkg and everything after it in the log. Stopping."
                    exit 20
                }
                Write-Output "Turned $pkg back on"
            } else {
                Write-Output "$pkg was already on."
            }
            $stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
            try {
                # UTF-8 without BOM, LF line ending: byte-identical to the shell version.
                [System.IO.File]::AppendAllText($res, "$pkg`t$stamp`n", $utf8)
            } catch {
                Write-Err "The TV DID turn $pkg back on, but $res could not be written. Restored $n so far. Stopping."
                exit 20
            }
            $n++
        }
    }
    if ($skipped -gt 0) {
        Write-Output "Left our own launcher ($OurLauncher) switched off, as intended."
    }
    if ($n -eq 0) {
        Write-Output 'No apps needed turning back on.'
    } else {
        Write-Output "Turned $n app(s) back on."
    }
}

if ($doHome) { Restore-Home }
if ($doPkgs) { Restore-Packages }
exit 0
