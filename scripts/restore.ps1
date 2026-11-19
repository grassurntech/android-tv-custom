# Undoes what this tool changed on the TV. Never uninstalls anything.
#   restore.ps1 [--home-only | --packages-only]     (default: both, Home first)
# Home:     turn the stock launcher back on, switch OUR launcher off (through disable-one.ps1, the only
#           script that disables anything; skipped if it was never installed), make the stock launcher
#           Home, then read Home back. Only a matching read-back counts as done.
# Packages: turn back on every package listed in any backup's disabled-by-us.txt that the TV currently
#           shows as disabled (each distinct package once; restored.txt is only a record), one `pm enable` at a time, newest backup first. A TV refusal stops it.
#           Our launcher and the stock launcher from home-state.txt are skipped: the Home step owns both.
# Exit: 0 done (or nothing to do), 2 bad arguments, 3 setup missing or a file is unreadable,
#       13 no usable backup, 20 TV refused (or Home did not read back as the stock launcher),
#       21 unreachable, 22 unauthorized; a failed Home disable passes disable-one's own exit code up unchanged.
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
$StayOn = "Please leave the TV switched on. Don't unplug it or restart it."

# Returns 0 if the TV lists $Name (exact line), 1 if not, 2 if the TV could not answer.
function Get-InstalledState([string]$Name) {
    $lines = @(Invoke-Adb @('pm', 'list', 'packages', $Name))
    if ($script:AdbRc -ne 0) { return 2 }
    foreach ($l in $lines) {
        if ($l.Trim() -ceq "package:$Name") { return 0 }
    }
    return 1
}

# The newest backup's home-state.txt, or $null.
function Find-HomeState {
    foreach ($folder in $backups) {
        $candidate = Join-Path ([string]$folder) 'home-state.txt'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

# ---- Home ------------------------------------------------------------------------------------
# Order: stock launcher on, ours off, stock made Home, then read Home back. Switching ours off changes
# the set of Home apps, which makes Android drop the Home choice, so Home is set only after that.
function Restore-Home {
    $hs = Find-HomeState
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

    # 1. The stock launcher back on.
    $null = Invoke-Adb @('pm', 'enable', $stockPkg)
    if ((Get-DisabledState $stockPkg) -ne 1) {
        Write-Err "The TV would not turn the original launcher ($stockPkg) back on. Home was left as it was and nothing else was restored. Stopping."
        exit 20
    }
    Write-Output "The original launcher ($stockPkg) is on again."

    # 2. Our launcher off, through disable-one (skipped when it never got installed).
    $installed = Get-InstalledState $script:ours
    if ($installed -eq 2) {
        Write-Err "The original launcher is on again, but the TV didn't say whether our launcher ($($script:ours)) is installed, so its state is unknown. Home was not changed and packages were not restored. Stopping."
        exit 20
    }
    if ($installed -eq 1) {
        Write-Output "Our launcher ($($script:ours)) is not installed on the TV, so there is nothing to switch off."
    } else {
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
            # Say what the TV really looks like now (disable-one may have switched it off before failing to log).
            $now = Get-DisabledState $script:ours
            if ($now -eq 0) {
                Write-Err "The original launcher is on again and our launcher ($($script:ours)) is off, but disable-one reported a problem afterwards. Home was not set and packages were not restored. $StayOn Stopping."
            } elseif ($now -eq 1) {
                Write-Err "The original launcher is on again, but our launcher ($($script:ours)) is still on, so Home was not changed. Packages were not restored. Stopping."
            } else {
                Write-Err "The original launcher is on again, but the TV didn't say whether our launcher ($($script:ours)) is off, so its state is unknown. Home was not set and packages were not restored. $StayOn Stopping."
            }
            exit $childRc
        }
    }

    # 3. Make the stock launcher Home.
    $null = Invoke-Adb @('cmd', 'package', 'set-home-activity', '--user', '0', $stockComp)
    if ($script:AdbRc -ne 0) {
        Write-Err "The TV would not make the original launcher ($stockComp) the Home screen. Packages were not restored. $StayOn Stopping."
        exit 20
    }

    # 4. Read Home back: the last non-empty line must be the stock component.
    $lines = @(Invoke-Adb @('cmd', 'package', 'resolve-activity', '--brief', '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.HOME'))
    $readRc = $script:AdbRc
    $comp = ''
    foreach ($l in $lines) {
        $t = $l.Trim()
        if ($t.Length -gt 0) { $comp = $t }
    }
    if (($readRc -ne 0) -or ($comp -cne $stockComp)) {
        $said = $comp
        if ($said.Length -eq 0) { $said = 'nothing' }
        Write-Err "The TV did not confirm the original launcher as the Home screen (it says: $said). Packages were not restored. $StayOn Stopping."
        exit 20
    }
    Write-Output "The original launcher ($stockPkg) is back as the Home screen."
}

# ---- Packages --------------------------------------------------------------------------------
function Restore-Packages {
    $n = 0
    $skipped = 0
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    # Ordinal (case-sensitive) like the shell version: a.B.c and a.b.c are different packages.
    $seen = New-Object System.Collections.Hashtable([System.StringComparer]::Ordinal)
    # The stock launcher belongs to the Home step: switching it on while ours is Home can drop the Home choice.
    $stock = ''
    $leftStock = $false
    $hsFile = Find-HomeState
    if ($null -ne $hsFile) {
        $stock = [string](Get-StateValue $hsFile 'stock_package')
        if ($stock -cnotmatch $PkgRe) {
            Write-Err "$hsFile is missing or has a bad stock_package line. Nothing was changed. Stopping."
            exit 3
        }
    }
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
            # Each distinct package once. The TV's state decides, not restored.txt (which is only a record).
            if ($seen.ContainsKey($pkg)) { continue }
            $seen[$pkg] = $true
            # Our own launcher stays switched off (it is never re-enabled by a restore).
            if (($pkg -ceq $OurLauncher) -or ($pkg -ceq $script:ours)) { $skipped++; continue }
            if (($stock.Length -gt 0) -and ($pkg -ceq $stock)) { $leftStock = $true; continue }
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
                if (Test-InRestored $res $pkg) { continue }
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
    if ($leftStock -and (-not $doHome)) {
        Write-Output "The original launcher ($stock) is handled by the Home step, so --packages-only did not change it."
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
