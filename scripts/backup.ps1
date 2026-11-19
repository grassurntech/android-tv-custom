# Backs up the TV's package lists, properties and settings to TV_BACKUP_DIR/<YYYY-MM-DD_HHMMSS>/.
# Read-only on the TV. Prints the backup folder as the last stdout line.
# Exit: 0 done, 2 bad arguments, 3 setup missing, 20 TV refused / empty result, 21 unreachable, 22 unauthorized.
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

$code = 0
try {
    $null = New-Item -ItemType Directory -Path $partial -Force
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
        $pkgFile = Join-Path $partial 'packages-all.txt'
        if ((Get-Item -LiteralPath $pkgFile).Length -le 0) {
            [Console]::Error.WriteLine('The TV returned an empty package list; no backup was kept.')
            $code = 20
        }
    }
    if ($code -eq 0) {
        Move-Item -LiteralPath $partial -Destination $final
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
