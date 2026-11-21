# Installs the built cleanyourtv launcher (com.gathin.tvhome) on the TV through upstream's
# build-and-install.ps1, with SKIP_BUILD=1 and -StockLauncher none: upstream never disables anything here.
# The stock launcher is switched off later, separately, with scripts/disable-one.
# Before installing it records what Home is now in home-state.txt (stock_package=, stock_component=, ours=) and,
# after a good install, lists our package in installed-by-us.txt, both in the newest backup folder (the one
# disable-one and restore read). An existing home-state.txt is never overwritten: the stock values must survive.
# If ANY backup already has a home-state.txt (a second session), Home is not read or recorded again: by then it
# may already be our launcher, and the first record is the original stock launcher.
# If upstream fails, it still asks the TV whether our package got installed and, if so, lists it, so restore
# can always switch it off; if the TV can't answer (filtered and unfiltered package lists both fail) it lists it
# anyway, with a warning. Upstream's exit code is passed up either way.
# Optional, only when set in the environment: HOME_KEY_SERVICE and INPUT_KEY_SERVICE, each 0 or 1 (anything else
# is exit 2); 1 passes -HomeKeyService / -InputKeyService, 0 or unset passes nothing. RESTORE_KEY_SERVICES is not
# supported in v1: the child always gets RESTORE_KEY_SERVICES=0 and -RestoreKeyServices is never passed.
# Upstream gets -TvHost <TV_IP>:<TV_ADB_PORT>.
# STOCK_HOME_REDIRECT=1 (needs HOME_KEY_SERVICE=1): Google TV redirect mode, the same as install-launcher.sh: after
# upstream's 1, with our launcher installed and Home still on the stock launcher recorded in home-state.txt, it
# switches on HomeKeyService itself (TCL AUTO_START app-ops, then the accessibility list, then a read-back). Never
# disables anything, never touches the setup wizard. Exit 0 when the read-back lists the helper, 20 if it doesn't
# (or the current list holds anything but package/component characters), upstream's 1 otherwise.
# Exit: 0 installed, 2 bad arguments or a key-service switch that isn't 0/1, 3 setup missing (TV_IP, vendor or
#       its venv not fetched, APK missing or empty, Home already ours with no recorded stock launcher, Home
#       ambiguous, or Home isn't a normal launcher: the chooser, a setup/provisioning/recovery screen,
#       FallbackHome, or a protected or forbidden package), 13 no usable backup, 20 Home could not be read,
#       21 unreachable, 22 unauthorized; otherwise upstream's own exit code.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

if ($args.Count -gt 0) {
    [Console]::Error.WriteLine('Usage: install-launcher.ps1 (no arguments)')
    exit 2
}
Import-Module (Join-Path $PSScriptRoot 'lib/TvEnv.psm1') -Force
Import-TvEnv
# Checked after Import-TvEnv, which may set them from the owner's settings file.
foreach ($var in @('HOME_KEY_SERVICE', 'INPUT_KEY_SERVICE')) {
    $val = [Environment]::GetEnvironmentVariable($var)
    if (-not [string]::IsNullOrEmpty($val) -and $val -cne '0' -and $val -cne '1') {
        [Console]::Error.WriteLine("$var must be 0 or 1 (it is '$val'). Nothing was changed.")
        exit 2
    }
}
$redirectVal = [Environment]::GetEnvironmentVariable('STOCK_HOME_REDIRECT')
if (-not [string]::IsNullOrEmpty($redirectVal) -and $redirectVal -cne '0' -and $redirectVal -cne '1') {
    [Console]::Error.WriteLine("STOCK_HOME_REDIRECT must be 0 or 1 (it is '$redirectVal'). Nothing was changed.")
    exit 2
}
$redirect = $redirectVal -ceq '1'
[Environment]::SetEnvironmentVariable('STOCK_HOME_REDIRECT', $null)   # ours only: upstream never sees it
if ($redirect -and [Environment]::GetEnvironmentVariable('HOME_KEY_SERVICE') -cne '1') {
    [Console]::Error.WriteLine('STOCK_HOME_REDIRECT=1 needs HOME_KEY_SERVICE=1 (the helper that sends Home to the new launcher). Nothing was changed.')
    exit 2
}

$ours = 'com.gathin.tvhome'
$pkgRe = '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+\z'
$compRe = '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+/[A-Za-z0-9_.$]+\z'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$backup = Get-TvLatestBackup
if (-not $backup) {
    [Console]::Error.WriteLine('No backup found. Run scripts/backup first. Nothing was changed. Stopping.')
    exit 13
}

$vendor = Join-Path $global:REPO_ROOT 'vendor/cleanyourtv'
$launcher = Join-Path $vendor 'launcher'
$upstream = Join-Path $launcher 'build-and-install.ps1'
if (-not (Test-Path -LiteralPath $upstream -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $vendor 'tools/venv') -PathType Container)) {
    [Console]::Error.WriteLine('cleanyourtv is not fetched yet (or its Python environment is missing). Run scripts/fetch-tools.ps1 first.')
    exit 3
}
$apk = Join-Path $launcher 'app/build/outputs/apk/release/app-release.apk'
if (-not (Test-Path -LiteralPath $apk -PathType Leaf) -or (Get-Item -LiteralPath $apk).Length -le 0) {
    [Console]::Error.WriteLine('The launcher is not built yet (no APK, or an empty one). Run scripts/build-launcher.ps1 first.')
    exit 3
}

$rc = Test-TvReachable
switch ($rc) {
    0 { }
    22 { [Console]::Error.WriteLine("Accept 'Allow debugging?' on the TV, then run this again"); exit 22 }
    21 { [Console]::Error.WriteLine("Can't reach the TV at $($global:TV_IP)"); exit 21 }
    default { exit $rc }
}

# Is there a home-state.txt already (in the newest backup, or in any older one)?
$state = Join-Path $backup 'home-state.txt'
$recorded = ''
foreach ($folder in @(Get-TvBackups)) {
    # newest first: the last hit is the oldest record
    $f = Join-Path $folder 'home-state.txt'
    if (Test-Path -LiteralPath $f -PathType Leaf) { $recorded = $f }
}

# Test-NotALauncher <component>: true if Home is something that must never be recorded as the launcher to restore to.
function Test-NotALauncher([string]$Comp) {
    $low = $Comp.ToLowerInvariant()
    $lowPkg = $low
    if ($low.Contains('/')) { $lowPkg = $low.Substring(0, $low.IndexOf('/')) }
    if ($lowPkg -ceq 'android') { return $true }
    foreach ($w in @('setupwizard', 'provision', 'initsetup', 'setupwraith')) {
        if ($lowPkg.Contains($w)) { return $true }
    }
    foreach ($w in @('recoveryactivity', 'fallbackhome', 'resolveractivity', 'chooser')) {
        if ($low.Contains($w)) { return $true }
    }
    if (-not $Comp.Contains('/')) { return $false }
    $pkg = $Comp.Substring(0, $Comp.IndexOf('/'))
    if (Test-TvMatches $pkg (Join-Path $global:REPO_ROOT 'config/protected-packages.txt')) { return $true }
    if (Test-TvMatches $pkg (Join-Path $global:REPO_ROOT 'config/forbidden-packages.txt')) { return $true }
    return $false
}

if (Test-Path -LiteralPath $state -PathType Leaf) {
    Write-Output "Keeping the Home screen record already in $state"
} elseif ($recorded) {
    Write-Output "The original Home screen is already recorded in $recorded, so the current Home is not recorded again."
} else {
    $lines = @(Invoke-TvShell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>$null)
    $shellRc = $LASTEXITCODE
    $comp = ''
    $nComp = 0
    foreach ($l in $lines) {
        $t = ([string]$l).Trim()
        if ($t.Length -gt 0) {
            $comp = $t
            if ($t -cmatch $compRe) { $nComp++ }
        }
    }
    $stock = ''
    if ($comp.Contains('/')) { $stock = $comp.Substring(0, $comp.IndexOf('/')) }
    if ($shellRc -ne 0) {
        [Console]::Error.WriteLine('The TV did not say which launcher is the Home screen. Nothing was changed. Stopping.')
        exit 20
    }
    if ($nComp -gt 1) {
        [Console]::Error.WriteLine("The TV named more than one Home screen, so it isn't clear which launcher to restore to. Nothing was changed. Stopping.")
        exit 3
    }
    # Never record something that is not a real launcher as the one to restore to.
    if (Test-NotALauncher $comp) {
        [Console]::Error.WriteLine("Home isn't a normal launcher right now ($comp), so it is not a real launcher to restore to: it is Android's chooser, a setup, provisioning or recovery screen, or a system app. Nothing was changed. Stopping.")
        exit 3
    }
    if ($comp -cnotmatch $compRe -or $stock -cnotmatch $pkgRe) {
        [Console]::Error.WriteLine('The TV did not say which launcher is the Home screen. Nothing was changed. Stopping.')
        exit 20
    }
    if ($stock -ceq $ours) {
        [Console]::Error.WriteLine('Home is already our launcher and no original launcher was recorded, so there is nothing to restore to. Nothing was changed. Stopping.')
        exit 3
    } else {
        $tmp = "$state.tmp"
        try {
            [System.IO.File]::WriteAllText($tmp, "stock_package=$stock`nstock_component=$comp`nours=$ours`n", $utf8)
            Move-Item -LiteralPath $tmp -Destination $state -Force
        } catch {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            [Console]::Error.WriteLine("Can't write $state. Nothing was changed. Stopping.")
            exit 3
        }
        Write-Output "Recorded the current Home screen ($comp) in $state"
    }
}

# Native call: relax 'Stop' so upstream's stderr and non-zero exit pass through instead of throwing.
$ErrorActionPreference = 'Continue'
$env:SKIP_BUILD = '1'
# RESTORE_KEY_SERVICES is unsupported in v1: force it off for the child, whatever the owner's environment says.
$env:RESTORE_KEY_SERVICES = '0'
# TV_HOST is IP:port (upstream's tools/tv.py accepts that form), so a custom TV_ADB_PORT reaches the TV.
$env:TV_HOST = $global:SERIAL
$shell = (Get-Process -Id $PID).Path
$childArgs = @('-NoProfile')
if ([System.IO.Path]::DirectorySeparatorChar -eq '\') { $childArgs += @('-ExecutionPolicy', 'Bypass') }
$childArgs += @('-File', $upstream, '-TvHost', $global:SERIAL, '-StockLauncher', 'none')
if ([Environment]::GetEnvironmentVariable('HOME_KEY_SERVICE') -eq '1') { $childArgs += '-HomeKeyService' }
if ([Environment]::GetEnvironmentVariable('INPUT_KEY_SERVICE') -eq '1') { $childArgs += '-InputKeyService' }
# Upstream resolves its venv and app/ relative to launcher/.
Push-Location -LiteralPath $launcher
try {
    & $shell @childArgs
    $rc = $LASTEXITCODE
} finally {
    Pop-Location
}
$ErrorActionPreference = 'Stop'

$mine = Join-Path $backup 'installed-by-us.txt'
# Save-Ours: list our package in installed-by-us.txt once (deduplicated).
function Save-Ours {
    $found = $false
    if (Test-Path -LiteralPath $mine -PathType Leaf) {
        foreach ($l in [System.IO.File]::ReadAllLines($mine)) {
            if ($l.TrimEnd("`r") -ceq $ours) { $found = $true; break }
        }
    }
    if (-not $found) {
        $prefix = ''
        if (Test-Path -LiteralPath $mine -PathType Leaf) {
            $text = [System.IO.File]::ReadAllText($mine)
            if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $prefix = "`n" }
        }
        [System.IO.File]::AppendAllText($mine, "$prefix$ours`n", $utf8)
    }
}
# Get-TvHasOurs: 0 if the TV lists our package (exact line), 1 if not, 2 if it could not answer (the filtered
# list failed, and so did the unfiltered one).
function Get-TvHasOurs {
    $ErrorActionPreference = 'Continue'
    $lines = @(Invoke-TvShell pm list packages $ours 2>$null)
    if ($LASTEXITCODE -ne 0) {
        $lines = @(Invoke-TvShell pm list packages 2>$null)
        if ($LASTEXITCODE -ne 0) { return 2 }
    }
    foreach ($l in $lines) {
        if (([string]$l).Trim() -ceq "package:$ours") { return 0 }
    }
    return 1
}

# Read-Services: the accessibility service list, trimmed ("null" when none is set); $null if the TV can't answer.
function Read-Services {
    $ErrorActionPreference = 'Continue'
    $lines = @(Invoke-TvShell settings get secure enabled_accessibility_services 2>$null)
    if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) { return $null }
    return ([string]$lines[0]).Trim()
}
# Invoke-Redirect: STOCK_HOME_REDIRECT=1 after upstream's 1 (see the header). Returns 0, 1 or 20.
function Invoke-Redirect {
    $ErrorActionPreference = 'Continue'
    $svc = "$ours/.HomeKeyService"
    $hs = $state
    if (-not (Test-Path -LiteralPath $hs -PathType Leaf)) { $hs = $recorded }
    $stock = ''
    if ($hs -and (Test-Path -LiteralPath $hs -PathType Leaf)) {
        foreach ($l in [System.IO.File]::ReadAllLines($hs)) {
            $t = $l.TrimEnd("`r")
            if ($t.StartsWith('stock_package=')) { $stock = $t.Substring(14); break }
        }
    }
    if ($stock -cnotmatch $pkgRe) {
        [Console]::Error.WriteLine('No recorded original launcher, so redirect mode is not switched on. Home is unchanged.')
        return 1
    }
    $homeNow = ''
    foreach ($l in @(Invoke-TvShell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>$null)) {
        $t = ([string]$l).Trim()
        if ($t -cmatch $compRe) { $homeNow = $t }
    }
    $homeNowPkg = $homeNow
    if ($homeNow.Contains('/')) { $homeNowPkg = $homeNow.Substring(0, $homeNow.IndexOf('/')) }
    if ($homeNowPkg -cne $stock) {
        $shown = if ($homeNow) { $homeNow } else { 'unknown' }
        [Console]::Error.WriteLine("Home is $shown, not the recorded launcher ($stock), so redirect mode is not switched on. Run restore --home-only and stop.")
        return 1
    }
    Write-Output "Home stays on $stock, as Google TV insists. Switching on the Home helper so it sends Home to the new launcher."
    # TCL firmware only binds an accessibility service of an app allowed to auto-start; other TVs ignore these ops.
    $null = Invoke-TvShell cmd appops set $ours AUTO_START allow 2>$null
    $null = Invoke-TvShell cmd appops set $ours APP_AUTO_START allow 2>$null
    $null = Invoke-TvShell appops write-settings 2>$null
    $cur = Read-Services
    if ($null -eq $cur) { $cur = '?' }
    if ($cur -cne 'null' -and $cur.Length -gt 0 -and $cur -cnotmatch '^[A-Za-z0-9_.$/:]+\z') {
        [Console]::Error.WriteLine("The TV's accessibility list holds something unexpected, so it is left alone and the Home helper is not switched on. Run restore --home-only and stop.")
        return 20
    }
    if ((":${cur}:").Contains(":${svc}:")) {
        # listed already but maybe not bound: clear it, then write it back
        $new = $cur
        $null = Invoke-TvShell settings put secure enabled_accessibility_services "''" 2>$null
        $null = Invoke-TvShell settings put secure accessibility_enabled 0 2>$null
    } elseif ($cur -ceq 'null' -or $cur.Length -eq 0) {
        $new = $svc
    } else {
        $new = "$($cur):$svc"
    }
    $null = Invoke-TvShell settings put secure enabled_accessibility_services $new 2>$null
    $null = Invoke-TvShell settings put secure accessibility_enabled 1 2>$null
    $cur = Read-Services
    if ($null -ne $cur -and (":${cur}:").Contains(":${svc}:")) {
        Write-Output "Redirect mode is on: Home stays $stock, and the Home helper sends it to the new launcher. Push the theme next (it holds stock_home_redirect)."
        return 0
    }
    $shown = if ($cur) { $cur } else { 'nothing' }
    [Console]::Error.WriteLine("The TV did not switch on the Home helper (its list reads '$shown'). Run restore --home-only and stop.")
    return 20
}

if ($rc -ne 0) {
    [Console]::Error.WriteLine("The launcher install failed (exit $rc).")
    $has = Get-TvHasOurs
    if ($has -eq 0) {
        Save-Ours
        [Console]::Error.WriteLine("Our launcher ($ours) is on the TV anyway, so it is listed in $mine and restore can switch it off.")
        if ($rc -eq 1 -and $redirect) {
            $out = @(Invoke-Redirect)
            $code = $out[-1]
            if ($out.Count -gt 1) { $out[0..($out.Count - 2)] | ForEach-Object { Write-Output $_ } }
            exit $code
        }
    } elseif ($has -eq 2) {
        Save-Ours
        [Console]::Error.WriteLine("Warning: the TV could not say whether our launcher ($ours) got installed. It is listed in $mine anyway, so restore will try to switch it off.")
    }
    exit $rc
}

Save-Ours
Write-Output "Our launcher is installed. Follow PROMPT.md Phase 6 for the next step."
exit 0
