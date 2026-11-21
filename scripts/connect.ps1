# Connects to the TV over adb. Exit: 0 connected, 21 unreachable, 22 unauthorized, 3 setup missing.
# connect.ps1 --check-off (Phase 7): checks debugging is now OFF. Exit 0 = off (the TV no longer answers),
# 23 = still on (the TV answered, whether or not it trusts this computer), 3 = setup missing.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/TvEnv.psm1') -Force

$mode = 'connect'
if ($args.Count -eq 1 -and $args[0] -eq '--check-off') {
    $mode = 'check-off'
} elseif ($args.Count -gt 0) {
    [Console]::Error.WriteLine('Usage: connect.ps1 [--check-off]')
    exit 2
}
Import-TvEnv
$rc = Test-TvReachable
if ($mode -eq 'check-off') {
    if ($rc -eq 21) {
        Write-Output 'Debugging is OFF: the TV no longer answers this computer. Done.'
        exit 0
    }
    if ($rc -eq 0 -or $rc -eq 22) {
        [Console]::Error.WriteLine('Debugging is still ON: the TV still answers over Wi-Fi. Ask the owner to turn off Network debugging (and Wireless debugging) in Settings > System > Developer options. Do not press Allow.')
        exit 23
    }
    exit $rc
}
if ($rc -eq 0) {
    Write-Output 'Connected to the TV'
    exit 0
}
if ($rc -eq 22) {
    [Console]::Error.WriteLine("Accept 'Allow debugging?' on the TV, then run this again")
    exit 22
}
if ($rc -eq 21) {
    [Console]::Error.WriteLine("Can't reach the TV at $($global:TV_IP)")
    exit 21
}
exit $rc
