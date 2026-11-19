# Installs the built cleanyourtv launcher (com.gathin.tvhome) on the TV through upstream's
# build-and-install.ps1, with SKIP_BUILD=1 and -StockLauncher none: upstream never disables anything here.
# The stock launcher is switched off later, separately, with scripts/disable-one.
# Before installing it records what Home is now in home-state.txt (stock_package=, stock_component=, ours=) and,
# after a good install, lists our package in installed-by-us.txt, both in the newest backup folder (the one
# disable-one and restore read). An existing home-state.txt is never overwritten: the stock values must survive.
# If upstream fails, it still asks the TV whether our package got installed and, if so, lists it, so restore
# can always switch it off; upstream's exit code is passed up either way.
# Optional, only when set in the environment: HOME_KEY_SERVICE=1, INPUT_KEY_SERVICE=1 (passed to upstream).
# Exit: 0 installed, 2 bad arguments, 3 setup missing (TV_IP, vendor or its venv not fetched, Home already ours
#       with no recorded stock launcher), 13 no usable backup, 20 Home could not be read, 21 unreachable,
#       22 unauthorized; otherwise upstream's own exit code.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

if ($args.Count -gt 0) {
    [Console]::Error.WriteLine('Usage: install-launcher.ps1 (no arguments)')
    exit 2
}
Import-Module (Join-Path $PSScriptRoot 'lib/TvEnv.psm1') -Force
Import-TvEnv

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
if (-not (Test-Path -LiteralPath (Join-Path $launcher 'app/build/outputs/apk/release/app-release.apk') -PathType Leaf)) {
    [Console]::Error.WriteLine('The launcher is not built yet. Run scripts/build-launcher.ps1 first.')
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
$haveAny = $false
foreach ($folder in @(Get-TvBackups)) {
    if (Test-Path -LiteralPath (Join-Path $folder 'home-state.txt') -PathType Leaf) { $haveAny = $true; break }
}

if (Test-Path -LiteralPath $state -PathType Leaf) {
    Write-Host "Keeping the Home screen record already in $state"
} else {
    $lines = @(Invoke-TvShell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>$null)
    $shellRc = $LASTEXITCODE
    $comp = ''
    foreach ($l in $lines) {
        $t = ([string]$l).Trim()
        if ($t.Length -gt 0) { $comp = $t }
    }
    $stock = ''
    if ($comp.Contains('/')) { $stock = $comp.Substring(0, $comp.IndexOf('/')) }
    if ($shellRc -ne 0 -or $comp -cnotmatch $compRe -or $stock -cnotmatch $pkgRe) {
        [Console]::Error.WriteLine('The TV did not say which launcher is the Home screen. Nothing was changed. Stopping.')
        exit 20
    }
    if ($stock -ceq $ours) {
        if ($haveAny) {
            Write-Host 'Home is already our launcher; the original one is recorded in an earlier backup.'
        } else {
            [Console]::Error.WriteLine('Home is already our launcher and no original launcher was recorded, so there is nothing to restore to. Nothing was changed. Stopping.')
            exit 3
        }
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
        Write-Host "Recorded the current Home screen ($comp) in $state"
    }
}

# Native call: relax 'Stop' so upstream's stderr and non-zero exit pass through instead of throwing.
$ErrorActionPreference = 'Continue'
$env:SKIP_BUILD = '1'
$env:TV_HOST = $global:TV_IP
$shell = (Get-Process -Id $PID).Path
$childArgs = @('-NoProfile')
if ([System.IO.Path]::DirectorySeparatorChar -eq '\') { $childArgs += @('-ExecutionPolicy', 'Bypass') }
$childArgs += @('-File', $upstream, '-TvHost', $global:TV_IP, '-StockLauncher', 'none')
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
# Test-TvHasOurs: true if the TV lists our package (exact line), false if not or if it could not answer.
function Test-TvHasOurs {
    $ErrorActionPreference = 'Continue'
    $lines = @(Invoke-TvShell pm list packages $ours 2>$null)
    if ($LASTEXITCODE -ne 0) { return $false }
    foreach ($l in $lines) {
        if (([string]$l).Trim() -ceq "package:$ours") { return $true }
    }
    return $false
}

if ($rc -ne 0) {
    [Console]::Error.WriteLine("The launcher install failed (exit $rc).")
    if (Test-TvHasOurs) {
        Save-Ours
        [Console]::Error.WriteLine("Our launcher ($ours) is on the TV anyway, so it is listed in $mine and restore can switch it off.")
    }
    exit $rc
}

Save-Ours
Write-Host "Installed $ours. The original launcher is still on; turn it off with scripts/disable-one when you are ready."
exit 0
