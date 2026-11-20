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
        # A quoted value ends at its closing quote (anything after, like "# my tv", is dropped);
        # an unquoted value ends before a whitespace-led "#" comment. Mirrors tv-env.sh.
        if ($val.Length -ge 1 -and ($val[0] -eq [char]'"' -or $val[0] -eq [char]"'")) {
            $close = $val.IndexOf($val[0], 1)
            if ($close -ge 1) { $val = $val.Substring(1, $close - 1) }
        } elseif ($val -match '^(.*?)\s#') {
            $val = $Matches[1].Trim()
        }
        $current = [Environment]::GetEnvironmentVariable($key)
        if ([string]::IsNullOrEmpty($current)) {
            [Environment]::SetEnvironmentVariable($key, $val)
        }
    }
}

# Warns (stderr only, never fails) when the backup folder is inside the repo but not under backups/:
# backups hold serial numbers, and only backups/ is git-ignored. Mirrors _tv_check_backup_dir in tv-env.sh
function Test-TvBackupDirPlace([string]$Backup) {
    try {
        $sep = [string][System.IO.Path]::DirectorySeparatorChar
        $full = [System.IO.Path]::GetFullPath($Backup).TrimEnd('\', '/') + $sep
        $root = [System.IO.Path]::GetFullPath($script:TvRepoRoot).TrimEnd('\', '/') + $sep
    } catch {
        return
    }
    # "Inside the project" compares case-insensitively (macOS and Windows file systems are); "under backups/"
    # compares exactly, because git's ignore rule is case-sensitive on Linux. Symlinks are not resolved here.
    $inside = $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
    $underBackups = $inside -and $full.Substring($root.Length).StartsWith('backups' + $sep, [System.StringComparison]::Ordinal)
    if ($inside -and -not $underBackups) {
        [Console]::Error.WriteLine("Warning: TV_BACKUP_DIR ($Backup) is inside the project folder but not under backups/, so git may not ignore it. Backups hold serial numbers: move it outside the project or under backups/.")
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
    # A host name, an IPv4 address or a [bracketed] IPv6 address; never a port, spaces or shell characters.
    if (($ip -cnotmatch '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\z') -and ($ip -cnotmatch '^\[[0-9A-Fa-f:.]+\]\z')) {
        [Console]::Error.WriteLine("TV_IP doesn't look like an address: '$ip'. Set it in .env to the TV's IP address only (for example 192.168.1.50; the port goes in TV_ADB_PORT).")
        exit 3
    }
    if (($port -cnotmatch '^[0-9]{1,5}\z') -or ([int]$port -lt 1) -or ([int]$port -gt 65535)) {
        [Console]::Error.WriteLine("TV_ADB_PORT doesn't look like a port number: '$port'. Set it in .env (usually 5555).")
        exit 3
    }
    $backup = [Environment]::GetEnvironmentVariable('TV_BACKUP_DIR')
    if ([string]::IsNullOrEmpty($backup)) { $backup = 'backups' }
    while ($backup.Length -gt 1 -and ($backup.EndsWith('/') -or $backup.EndsWith('\')) -and $backup -notmatch '^[A-Za-z]:[\\/]$') {
        $backup = $backup.Substring(0, $backup.Length - 1)
    }
    if (-not [System.IO.Path]::IsPathRooted($backup)) { $backup = Join-Path $script:TvRepoRoot $backup }
    Test-TvBackupDirPlace $backup
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

# Get-TvListPatterns <listfile>: the list's glob patterns, lower-cased. Fails closed (exit 3) when the list
# is missing, unreadable, UTF-16 (BOM or NUL bytes) or has no patterns. Mirrors _tv_list_patterns in tv-env.sh:
# a line starting with # is a comment; anything after the first space, tab or # on a pattern line is a comment;
# LF, CRLF and CR-only line ends and a UTF-8 BOM are fine.
function Get-TvListPatterns([string]$ListFile) {
    if (-not (Test-Path -LiteralPath $ListFile -PathType Leaf)) {
        [Console]::Error.WriteLine("Missing list file: $ListFile. Nothing was changed. Stopping.")
        exit 3
    }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($ListFile)
    } catch {
        [Console]::Error.WriteLine("Can't read the list file $ListFile. Nothing was changed. Stopping.")
        exit 3
    }
    $utf16 = ($bytes.Length -ge 2) -and ((($bytes[0] -eq 0xFF) -and ($bytes[1] -eq 0xFE)) -or (($bytes[0] -eq 0xFE) -and ($bytes[1] -eq 0xFF)))
    if ($utf16 -or ([Array]::IndexOf($bytes, [byte]0) -ge 0)) {
        [Console]::Error.WriteLine("The list file $ListFile is not plain UTF-8 text (it looks like UTF-16). Save it as UTF-8. Nothing was changed. Stopping.")
        exit 3
    }
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
    $patterns = New-Object 'System.Collections.Generic.List[string]'
    foreach ($raw in ($text -split "`r`n|`r|`n")) {
        $line = $raw.TrimStart([char]0xFEFF).Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
        $line = ($line -split '[\s#]', 2)[0]
        if ($line.Length -eq 0) { continue }
        $patterns.Add($line.ToLowerInvariant())
    }
    if ($patterns.Count -eq 0) {
        [Console]::Error.WriteLine("The list file $ListFile has no patterns in it. Nothing was changed. Stopping.")
        exit 3
    }
    return ,$patterns.ToArray()
}

# Test-TvMatches <pkg> <listfile>: $true if the package matches any glob line (case-insensitive).
# Exits 3 if the list is missing, unreadable, UTF-16 or empty (see Get-TvListPatterns).
function Test-TvMatches {
    param([string]$Package, [string]$ListFile)
    $patterns = Get-TvListPatterns $ListFile
    foreach ($pat in $patterns) {
        if ($Package -like $pat) { return $true }   # -like is case-insensitive
    }
    return $false
}

# Files every backup folder must hold (backup writes all of them).
$script:TvBackupFiles = @('packages-all.txt', 'packages-disabled.txt', 'getprop.txt', 'settings-global.txt', 'settings-secure.txt', 'settings-system.txt', 'home-activity.txt')

# $true if the name is a real YYYY-MM-DD_HHMMSS time (same ranges as tv-env.sh) that is not in the future.
function Test-TvValidStamp([string]$Name) {
    if ($Name -cnotmatch '^[0-9]{4}-([0-9]{2})-([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})\z') { return $false }
    $mo = [int]$Matches[1]; $d = [int]$Matches[2]; $h = [int]$Matches[3]; $mi = [int]$Matches[4]; $sec = [int]$Matches[5]
    if ($mo -lt 1 -or $mo -gt 12 -or $d -lt 1 -or $d -gt 31 -or $h -gt 23 -or $mi -gt 59 -or $sec -gt 59) { return $false }
    $now = (Get-Date).ToString('yyyy-MM-dd_HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    return ([string]::CompareOrdinal($Name, $now) -le 0)
}

# $true if the folder is a finished backup: valid timestamp name, every backup file present, and
# packages-all.txt holding at least one package: line. Mirrors tv_backup_valid in tv-env.sh.
function Test-TvBackupValid([string]$Dir) {
    if (-not (Test-TvValidStamp (Split-Path -Leaf $Dir))) { return $false }
    foreach ($f in $script:TvBackupFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $Dir $f) -PathType Leaf)) { return $false }
    }
    try {
        foreach ($raw in [System.IO.File]::ReadAllLines((Join-Path $Dir 'packages-all.txt'))) {
            if ($raw.TrimStart([char]0xFEFF).TrimStart().StartsWith('package:', [System.StringComparison]::Ordinal)) { return $true }
        }
    } catch {
        return $false
    }
    return $false
}

# Prints every usable backup directory (see Test-TvBackupValid), newest first (ordinal name order).
# Never a leftover .partial, a junk folder or a future-dated one.
function Get-TvBackups {
    if (-not (Test-Path -LiteralPath $global:TV_BACKUP_DIR -PathType Container)) { return }
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($d in Get-ChildItem -LiteralPath $global:TV_BACKUP_DIR -Directory) {
        if (Test-TvBackupValid $d.FullName) { $names.Add($d.Name) }
    }
    $names.Sort([System.StringComparer]::Ordinal)
    $names.Reverse()
    foreach ($n in $names) { Join-Path $global:TV_BACKUP_DIR $n }
}

# Prints the newest usable backup directory (see Get-TvBackups); nothing if there is none.
function Get-TvLatestBackup {
    $all = @(Get-TvBackups)
    if ($all.Count -gt 0) { $all[0] }
}

# Exits 3 if any backup-named folder holds a file this tool reads that can't be read
# (an unreadable file must never look like "no backup" or "nothing to restore").
function Assert-TvBackupsReadable {
    if (-not (Test-Path -LiteralPath $global:TV_BACKUP_DIR -PathType Container)) { return }
    $files = $script:TvBackupFiles + @('tv-id.txt', 'disabled-by-us.txt', 'installed-by-us.txt', 'home-state.txt', 'restored.txt')
    foreach ($d in Get-ChildItem -LiteralPath $global:TV_BACKUP_DIR -Directory) {
        if (-not (Test-TvValidStamp $d.Name)) { continue }
        foreach ($f in $files) {
            $path = Join-Path $d.FullName $f
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            try {
                $fs = [System.IO.File]::OpenRead($path)
                $fs.Dispose()
            } catch {
                [Console]::Error.WriteLine("Can't read $path. Fix its permissions, then run this again. Nothing was changed. Stopping.")
                exit 3
            }
        }
    }
}

# Get-TvListState <lines> <pkg>: reads `pm list packages ...` output. 0 the exact package:<pkg> line is there,
# 1 it is not (every line is a package: line, or there is no output), 2 a line is not a package: line
# (an error message), so the answer can't be trusted. Mirrors tv_list_state in tv-env.sh.
function Get-TvListState([string[]]$Lines, [string]$Name) {
    $found = 1
    foreach ($l in $Lines) {
        if ($null -eq $l) { continue }
        $t = $l.Trim()
        if ($t.Length -eq 0) { continue }
        if (-not $t.StartsWith('package:', [System.StringComparison]::Ordinal)) { return 2 }
        if ($t -ceq "package:$Name") { $found = 0 }
    }
    return $found
}

# Invoke-TvAdbLines <args...>: runs `adb -s SERIAL shell <args>` and returns its stdout lines as one array
# (assign it directly; don't wrap the call in @()). stderr is dropped, never parsed. Get-TvAdbRc gives adb's
# exit code. Windows PowerShell 5.1 turns native stderr into terminating errors under 'Stop', so relax it here.
$script:TvAdbRc = 0
function Invoke-TvAdbLines([string[]]$Cmd) {
    $ErrorActionPreference = 'Continue'
    $out = & $global:ADB -s $global:SERIAL shell @Cmd 2>$null
    $script:TvAdbRc = $LASTEXITCODE
    # foreach, not a pipeline: empty output ($null) must not reach ToString() on 5.1.
    $lines = @()
    foreach ($o in $out) { if ($null -ne $o) { $lines += $o.ToString() } }
    return ,$lines
}
function Get-TvAdbRc { return $script:TvAdbRc }

# Get-TvIdentity: which TV this is, into $global:TV_ID: ro.serialno, else ro.boot.serialno, else "adb:<SERIAL>".
# Returns 0, or 2 if the TV didn't answer. Mirrors tv_identity in tv-env.sh.
function Get-TvIdentity {
    $global:TV_ID = ''
    foreach ($key in @('ro.serialno', 'ro.boot.serialno')) {
        $lines = Invoke-TvAdbLines @('getprop', $key)
        if ($script:TvAdbRc -ne 0) { return 2 }
        $v = (($lines -join '') -replace "`r", '').Trim()
        if ($v -cmatch '^[A-Za-z0-9._:-]{1,64}\z') {
            $global:TV_ID = $v
            return 0
        }
    }
    $global:TV_ID = "adb:$($global:SERIAL)"
    return 0
}

# Get-TvBackupId <dir>: the TV identity in that backup's tv-id.txt ('' if none). Exits 3 if it can't be read.
function Get-TvBackupId([string]$Dir) {
    $f = Join-Path $Dir 'tv-id.txt'
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return '' }
    try {
        $lines = [System.IO.File]::ReadAllLines($f)
    } catch {
        [Console]::Error.WriteLine("Can't read $f. Nothing was changed. Stopping.")
        exit 3
    }
    if ($lines.Count -eq 0) { return '' }
    return $lines[0].TrimStart([char]0xFEFF).Trim()
}

# Assert-TvIdentity <backupdir>: the backup must have been taken on the connected TV. Exits 20 if the TV
# didn't say who it is, 13 if the backup has no identity or another TV's. Sets $global:TV_ID.
function Assert-TvIdentity([string]$Backup) {
    if ((Get-TvIdentity) -ne 0) {
        [Console]::Error.WriteLine("The TV didn't say which TV it is, so the backup can't be checked. Nothing was changed. Stopping.")
        exit 20
    }
    $want = Get-TvBackupId $Backup
    if ($want.Length -eq 0) {
        [Console]::Error.WriteLine("The latest backup ($Backup) doesn't say which TV it came from. Run scripts/backup on this TV first. Nothing was changed. Stopping.")
        exit 13
    }
    if ($want -cne $global:TV_ID) {
        [Console]::Error.WriteLine("The backup is from a different TV (the latest backup, $Backup, was not taken on the TV at $($global:TV_IP)). Run scripts/backup on this TV first. Nothing was changed. Stopping.")
        exit 13
    }
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
    # Case-sensitive, like tv-env.sh: substring "unauthorized", exact "device".
    if ($out -cmatch 'unauthorized') { return 22 }
    if ($code -eq 0 -and $out.Trim() -ceq 'device') { return 0 }
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
    $fs = [System.IO.File]::Create($File)
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardOutput.BaseStream.CopyTo($fs)
    } finally {
        $fs.Dispose()
        if ($null -ne $proc) { $proc.WaitForExit() }
    }
    return $proc.ExitCode
}

Export-ModuleMember -Function Save-TvShellOutput, Read-TvDotEnv, Import-TvEnv, Get-TvListPatterns, Test-TvMatches, Test-TvValidStamp, Test-TvBackupValid, Get-TvBackups, Get-TvLatestBackup, Assert-TvBackupsReadable, Get-TvListState, Invoke-TvAdbLines, Get-TvAdbRc, Get-TvIdentity, Get-TvBackupId, Assert-TvIdentity, Test-TvReachable, Invoke-TvShell
