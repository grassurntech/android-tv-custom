# Shared helpers for the TV scripts (Windows PowerShell 5.1 compatible).
#   Import-Module (Join-Path $PSScriptRoot 'lib/TvEnv.psm1') -Force
# Reads .env as plain KEY=VALUE lines, never dot-sources it. Mirrors lib/tv-env.sh.
Set-StrictMode -Version 2
# Module functions do not inherit the caller's preference; set it here. Functions that run native
# adb relax it locally, so adb's stderr maps to the exit-code table instead of throwing.
$ErrorActionPreference = 'Stop'

$script:TvLibDir = $PSScriptRoot
$script:TvRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Read-TvDotEnv {
    $file = Join-Path $script:TvRepoRoot '.env'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return }
    foreach ($raw in [System.IO.File]::ReadAllLines($file)) {
        $line = $raw.TrimStart([char]0xFEFF).Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') { continue }
        $key = $Matches[1]
        $val = $Matches[2].Trim()
        if ($val.Length -ge 2) {
            $first = $val.Substring(0, 1)
            $last = $val.Substring($val.Length - 1, 1)
            if ($first -eq $last -and ($first -eq '"' -or $first -eq "'")) {
                $val = $val.Substring(1, $val.Length - 2)
            }
        }
        $current = [Environment]::GetEnvironmentVariable($key)
        if ([string]::IsNullOrEmpty($current)) {
            [Environment]::SetEnvironmentVariable($key, $val)
        }
    }
}

# Sets global REPO_ROOT, TV_IP, TV_ADB_PORT, TV_BACKUP_DIR (absolute), ADB, SERIAL. Exits 3 if TV_IP is empty.
function Import-TvEnv {
    Read-TvDotEnv
    $global:REPO_ROOT = $script:TvRepoRoot
    $ip = [Environment]::GetEnvironmentVariable('TV_IP')
    if ([string]::IsNullOrEmpty($ip)) {
        [Console]::Error.WriteLine('Create .env from .env.example and set TV_IP')
        exit 3
    }
    $port = [Environment]::GetEnvironmentVariable('TV_ADB_PORT')
    if ([string]::IsNullOrEmpty($port)) { $port = '5555' }
    $backup = [Environment]::GetEnvironmentVariable('TV_BACKUP_DIR')
    if ([string]::IsNullOrEmpty($backup)) { $backup = 'backups' }
    while ($backup.Length -gt 1 -and ($backup.EndsWith('/') -or $backup.EndsWith('\')) -and $backup -notmatch '^[A-Za-z]:[\\/]$') {
        $backup = $backup.Substring(0, $backup.Length - 1)
    }
    if (-not [System.IO.Path]::IsPathRooted($backup)) { $backup = Join-Path $script:TvRepoRoot $backup }
    $adb = [Environment]::GetEnvironmentVariable('ADB')
    if ([string]::IsNullOrEmpty($adb)) {
        $adb = 'adb'
        foreach ($name in @('adb.exe', 'adb')) {
            $local = Join-Path $script:TvRepoRoot "tools/platform-tools/$name"
            if (Test-Path -LiteralPath $local -PathType Leaf) { $adb = $local; break }
        }
    }
    $global:TV_IP = $ip
    $global:TV_ADB_PORT = $port
    $global:TV_BACKUP_DIR = $backup
    $global:ADB = $adb
    $global:SERIAL = "${ip}:${port}"
    # Child processes (docker, upstream tools) see the same values bash exports.
    $env:TV_IP = $ip
    $env:TV_ADB_PORT = $port
    $env:TV_BACKUP_DIR = $backup
    $env:ADB = $adb
    $env:SERIAL = $global:SERIAL
}

# Test-TvMatches <pkg> <listfile>: $true if the package matches any glob line. Exits 3 if the list is missing.
function Test-TvMatches {
    param([string]$Package, [string]$ListFile)
    if (-not (Test-Path -LiteralPath $ListFile -PathType Leaf)) {
        [Console]::Error.WriteLine("Missing list file: $ListFile")
        exit 3
    }
    foreach ($raw in [System.IO.File]::ReadAllLines($ListFile)) {
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
        if ($Package -like $line) { return $true }   # -like is case-insensitive
    }
    return $false
}

# Prints the newest backup directory (ordinal max name) whose packages-all.txt is non-empty; nothing if none.
function Get-TvLatestBackup {
    if (-not (Test-Path -LiteralPath $global:TV_BACKUP_DIR -PathType Container)) { return }
    $best = $null
    foreach ($d in Get-ChildItem -LiteralPath $global:TV_BACKUP_DIR -Directory) {
        # only finished backups (YYYY-MM-DD_HHMMSS); never a leftover .partial
        if ($d.Name -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$') { continue }
        $pkgs = Join-Path $d.FullName 'packages-all.txt'
        if (-not (Test-Path -LiteralPath $pkgs -PathType Leaf)) { continue }
        if ((Get-Item -LiteralPath $pkgs).Length -le 0) { continue }
        if ($null -eq $best -or [string]::CompareOrdinal($d.Name, $best.Name) -gt 0) { $best = $d }
    }
    if ($null -ne $best) { $best.FullName }
}

# Returns 0 if the TV is a usable device, 22 if unauthorized, 21 if unreachable, 3 if adb is missing.
function Test-TvReachable {
    if (-not (Get-Command $global:ADB -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine("adb not found ($($global:ADB)). Run scripts/fetch-tools or install platform-tools.")
        return 3
    }
    # Windows PowerShell 5.1 turns native stderr into terminating errors under 'Stop'.
    $ErrorActionPreference = 'Continue'
    $null = & $global:ADB connect $global:SERIAL 2>&1
    $out = (& $global:ADB -s $global:SERIAL get-state 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
    $code = $LASTEXITCODE
    if ($out -match 'unauthorized') { return 22 }
    if ($code -eq 0 -and $out.Trim() -eq 'device') { return 0 }
    return 21
}

# Invoke-TvShell <cmd...>: run a command on the TV. Check $LASTEXITCODE afterwards.
function Invoke-TvShell {
    $ErrorActionPreference = 'Continue'
    & $global:ADB -s $global:SERIAL shell @args
}

# Save-TvShellOutput <file> <cmd...>: run a command on the TV and write its stdout to <file> byte for byte
# (no console code page decoding, no newline changes), like bash's `adb shell ... > file`.
# Returns adb's exit code. stderr passes through to the console.
function Save-TvShellOutput {
    param([string]$File, [string[]]$Command)
    $adbPath = $global:ADB
    $cmdInfo = Get-Command $global:ADB -ErrorAction SilentlyContinue
    if ($cmdInfo -and $cmdInfo.Source) { $adbPath = $cmdInfo.Source }
    $parts = @('-s', $global:SERIAL, 'shell') + $Command
    $quoted = foreach ($a in $parts) {
        if ($a -match '[\s"]' -or $a.Length -eq 0) { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $adbPath
    $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $fs = [System.IO.File]::Create($File)
    try {
        $proc.StandardOutput.BaseStream.CopyTo($fs)
    } finally {
        $fs.Dispose()
    }
    $proc.WaitForExit()
    return $proc.ExitCode
}

Export-ModuleMember -Function Save-TvShellOutput, Import-TvEnv, Test-TvMatches, Get-TvLatestBackup, Test-TvReachable, Invoke-TvShell
