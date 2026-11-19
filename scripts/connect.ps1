# Connects to the TV over adb. Exit: 0 connected, 21 unreachable, 22 unauthorized, 3 setup missing.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/TvEnv.psm1') -Force

if ($args.Count -gt 0) {
    [Console]::Error.WriteLine('Usage: connect.ps1 (no arguments)')
    exit 2
}
Import-TvEnv
$rc = Test-TvReachable
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
