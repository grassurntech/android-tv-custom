# Fetches adb (Google platform-tools) and cleanyourtv at the pinned commit. No arguments, safe to re-run.
# Exit: 0 done, 3 a tool or download is missing, 30 the upstream copy does not match the pinned commit.
# Env: CLEANYOURTV_URL/TAG/COMMIT override config/upstream.env. FETCH_OFFLINE=1 skips downloads and pip
# (the git clone still runs). FETCH_SKIP_ADB=1 skips only the adb download. Does not need TV_IP or .env.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

if ($args.Count -gt 0) {
    [Console]::Error.WriteLine('Usage: fetch-tools.ps1 (no arguments)')
    exit 2
}
$RepoRoot = Split-Path -Parent $PSScriptRoot

# Run a native command; returns its exit code. Windows PowerShell 5.1 turns native stderr into
# terminating errors under 'Stop', so relax that here. Output is passed through to the console.
function Invoke-Native {
    param([string]$File, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    & $File @Arguments 2>&1 | ForEach-Object { $_.ToString() } | Write-Host
    return $LASTEXITCODE
}

# Read config/upstream.env as plain KEY=VALUE lines. Variables already set win.
$upstream = Join-Path $RepoRoot 'config/upstream.env'
if (-not (Test-Path -LiteralPath $upstream -PathType Leaf)) {
    [Console]::Error.WriteLine('Missing config/upstream.env (the pinned cleanyourtv version)')
    exit 3
}
foreach ($raw in [System.IO.File]::ReadAllLines($upstream)) {
    $line = $raw.TrimStart([char]0xFEFF).TrimEnd("`r")
    if ($line -match '^(CLEANYOURTV_TAG|CLEANYOURTV_COMMIT|CLEANYOURTV_URL)=(.*)$') {
        if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($Matches[1]))) {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2])
        }
    }
}
$Tag = [Environment]::GetEnvironmentVariable('CLEANYOURTV_TAG')
$Commit = [Environment]::GetEnvironmentVariable('CLEANYOURTV_COMMIT')
$Url = [Environment]::GetEnvironmentVariable('CLEANYOURTV_URL')
if ([string]::IsNullOrEmpty($Tag) -or [string]::IsNullOrEmpty($Commit) -or [string]::IsNullOrEmpty($Url)) {
    [Console]::Error.WriteLine('config/upstream.env must set CLEANYOURTV_TAG, CLEANYOURTV_COMMIT and CLEANYOURTV_URL')
    exit 3
}

$Offline = ([Environment]::GetEnvironmentVariable('FETCH_OFFLINE') -eq '1')
$SkipAdb = ([Environment]::GetEnvironmentVariable('FETCH_SKIP_ADB') -eq '1')

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    [Console]::Error.WriteLine('Git is not installed. Install Git (https://git-scm.com), then run this again.')
    exit 3
}
$GitExe = $git.Source

# Step 1: adb
$localAdb = Join-Path $RepoRoot 'tools/platform-tools/adb.exe'
if ((-not $Offline) -and (-not $SkipAdb) -and (-not (Test-Path -LiteralPath $localAdb -PathType Leaf)) `
        -and (-not (Get-Command adb -ErrorAction SilentlyContinue))) {
    $toolsDir = Join-Path $RepoRoot 'tools'
    New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
    $zip = Join-Path $toolsDir 'platform-tools.zip'
    Write-Host 'Downloading adb (platform-tools)...'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile $zip
        Expand-Archive -LiteralPath $zip -DestinationPath $toolsDir -Force
    } catch {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        [Console]::Error.WriteLine('Could not download or unpack adb. Check your internet connection and run this again.')
        exit 3
    }
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
}

# Step 2 and 3: cleanyourtv at the pinned commit. Never pulled or upgraded.
$Vendor = Join-Path $RepoRoot 'vendor/cleanyourtv'
function Test-Pin {
    $ErrorActionPreference = 'Continue'
    $head = (& $GitExe -C $Vendor rev-parse HEAD 2>$null | ForEach-Object { $_.ToString() }) -join ''
    if ($head.Trim() -ne $Commit) {
        Remove-Item -LiteralPath $Vendor -Recurse -Force -ErrorAction SilentlyContinue
        [Console]::Error.WriteLine("The downloaded cleanyourtv is not the pinned version ($Commit), so it was deleted. Nothing was installed.")
        exit 30
    }
}
if (-not (Test-Path -LiteralPath $Vendor)) {
    New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot 'vendor') | Out-Null
    Write-Host "Cloning cleanyourtv $Tag..."
    $rc = Invoke-Native $GitExe @('-c', 'advice.detachedHead=false', 'clone', '--quiet', '--depth', '1', '--branch', $Tag, $Url, $Vendor)
    if ($rc -ne 0) {
        Remove-Item -LiteralPath $Vendor -Recurse -Force -ErrorAction SilentlyContinue
        [Console]::Error.WriteLine('Could not download cleanyourtv. Check your internet connection and run this again.')
        exit 3
    }
}
Test-Pin

# Step 4: Python environments (network)
if (-not $Offline) {
    $py = $null
    $pyArgs = @()
    foreach ($cand in @(@('py', '-3'), @('python'))) {
        $cmd = Get-Command $cand[0] -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        $extra = @()
        if ($cand.Count -gt 1) { $extra = @($cand[1]) }
        # the Microsoft Store "python" stub exists but fails to run; require a working interpreter
        $rc = Invoke-Native $cmd.Source ($extra + @('-c', 'import sys'))
        if ($rc -eq 0) { $py = $cmd.Source; $pyArgs = $extra; break }
    }
    if (-not $py) {
        [Console]::Error.WriteLine('Python 3 is not installed. Install Python 3 (https://www.python.org), then run this again.')
        exit 3
    }
    $upstreamReq = Join-Path $Vendor 'tools/requirements.txt'
    if (-not (Test-Path -LiteralPath $upstreamReq -PathType Leaf)) {
        [Console]::Error.WriteLine('cleanyourtv has no tools/requirements.txt at the pinned version')
        exit 3
    }
    $envs = @(
        @{ Dir = (Join-Path $Vendor 'tools/venv'); Req = $upstreamReq; Name = "cleanyourtv's" },
        @{ Dir = (Join-Path $RepoRoot '.venv'); Req = (Join-Path $RepoRoot 'requirements.txt'); Name = 'the' }
    )
    foreach ($e in $envs) {
        $venvPy = Join-Path $e.Dir 'Scripts/python.exe'
        if (-not (Test-Path -LiteralPath $venvPy -PathType Leaf)) {
            $rc = Invoke-Native $py ($pyArgs + @('-m', 'venv', $e.Dir))
            if ($rc -ne 0) {
                [Console]::Error.WriteLine("Could not create the Python environment for $($e.Name) packages")
                exit 3
            }
        }
        $rc = Invoke-Native $venvPy @('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', '-r', $e.Req)
        if ($rc -ne 0) {
            [Console]::Error.WriteLine("Could not install $($e.Name) Python packages. Check your internet connection.")
            exit 3
        }
    }
}

Write-Host 'Tools are ready.'
exit 0
