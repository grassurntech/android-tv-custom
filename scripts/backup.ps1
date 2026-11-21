# Backs up the TV's package lists, properties and settings to TV_BACKUP_DIR/<YYYY-MM-DD_HHMMSS>/.
# Read-only on the TV. Prints the backup folder as the last stdout line. Also records which TV it is
# (tv-id.txt) so disable-one and restore never use one TV's backup on another.
# Exit: 0 done, 2 bad arguments, 3 setup missing or the backup folder can't be written,
#       20 TV refused / empty or error result (no folder kept), 21 unreachable, 22 unauthorized.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/TvEnv.psm1') -Force

if ($args.Count -gt 0) {
    [Console]::Error.WriteLine('Usage: backup.ps1 (no arguments)')
    exit 2
}
Import-TvEnv
$rc = Test-TvReachable
if ($rc -eq 22) {
    [Console]::Error.WriteLine("Accept 'Allow debugging?' on the TV, then run this again")
    exit 22
}
if ($rc -eq 21) {
    [Console]::Error.WriteLine("Can't reach the TV at $($global:TV_IP)")
    exit 21
}
if ($rc -ne 0) { exit $rc }

$final = Join-Path $global:TV_BACKUP_DIR ((Get-Date).ToString('yyyy-MM-dd_HHmmss', [System.Globalization.CultureInfo]::InvariantCulture))
$partial = "$final.partial"
if ((Test-Path -LiteralPath $final) -or (Test-Path -LiteralPath $partial)) {
    [Console]::Error.WriteLine("A backup for this second already exists: $final. Wait a moment and run again.")
    exit 20
}

# Runs one command on the TV and writes its raw stdout into the partial folder.
# Returns $false when the TV refused or failed.
function Save-TvOutput {
    param([string]$File, [string[]]$Command)
    $exit = Save-TvShellOutput (Join-Path $partial $File) $Command
    if ($exit -ne 0) {
        [Console]::Error.WriteLine("The TV refused or failed: $($Command -join ' ')")
        return $false
    }
    return $true
}

# $true if every non-empty line is a package: line (and, with -NeedOne, there is at least one).
function Test-ListFileOk([string]$File, [bool]$NeedOne) {
    $lines = [System.IO.File]::ReadAllLines($File)
    if ((Get-TvListState $lines '-') -eq 2) { return $false }
    if (-not $NeedOne) { return $true }
    foreach ($l in $lines) { if ($l.TrimStart([char]0xFEFF).Trim().StartsWith('package:', [System.StringComparison]::Ordinal)) { return $true } }
    return $false
}

try {
    $null = New-Item -ItemType Directory -Path $partial -Force
} catch {
    [Console]::Error.WriteLine("Can't create the backup folder $partial. Check TV_BACKUP_DIR and its permissions.")
    exit 3
}

$code = 0
try {
    $steps = @(
        @('packages-disabled.txt', @('pm', 'list', 'packages', '-d')),
        @('getprop.txt', @('getprop')),
        @('settings-global.txt', @('settings', 'list', 'global')),
        @('settings-secure.txt', @('settings', 'list', 'secure')),
        @('settings-system.txt', @('settings', 'list', 'system')),
        @('home-activity.txt', @('cmd', 'package', 'resolve-activity', '--brief', '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.HOME')),
        @('packages-all.txt', @('pm', 'list', 'packages'))
    )
    foreach ($step in $steps) {
        if (-not (Save-TvOutput $step[0] $step[1])) { $code = 20; break }
    }
    if ($code -eq 0) {
        if (-not (Test-ListFileOk (Join-Path $partial 'packages-all.txt') $true)) {
            [Console]::Error.WriteLine('The TV returned an empty package list or an error message instead of one; no backup was kept.')
            $code = 20
        }
    }
    if ($code -eq 0) {
        if (-not (Test-ListFileOk (Join-Path $partial 'packages-disabled.txt') $false)) {
            [Console]::Error.WriteLine("The TV returned an error message instead of its list of switched-off apps; no backup was kept.")
            $code = 20
        }
    }
    if ($code -eq 0) {
        if ((Get-TvIdentity) -ne 0) {
            [Console]::Error.WriteLine("The TV didn't say which TV it is; no backup was kept.")
            $code = 20
        }
    }
    if ($code -eq 0) {
        try {
            # UTF-8 without BOM, LF line ending: byte-identical to the shell version.
            [System.IO.File]::WriteAllText((Join-Path $partial 'tv-id.txt'), "$($global:TV_ID)`n", (New-Object System.Text.UTF8Encoding($false)))
        } catch {
            [Console]::Error.WriteLine("Can't write $partial/tv-id.txt; no backup was kept.")
            $code = 3
        }
    }
    if ($code -eq 0) {
        try {
            Move-Item -LiteralPath $partial -Destination $final
        } catch {
            [Console]::Error.WriteLine("Can't finish the backup folder $final.")
            $code = 3
        }
    }
} catch {
    [Console]::Error.WriteLine("Backup failed: $($_.Exception.Message)")
    $code = 20
} finally {
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($code -ne 0) { exit $code }
Write-Output 'Backup saved'
Write-Output $final
exit 0
