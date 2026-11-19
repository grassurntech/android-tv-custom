# Pushes the owner's theme (user-content/theme, made by make_theme.py) to the TV through cleanyourtv's
# own theme.ps1. No arguments.
# Exit: 0 pushed, 2 bad arguments, 3 TV_IP unset, vendor not fetched or no theme made yet; otherwise
#       theme.ps1's own exit code (1 push failed, 2 refused before anything was sent).
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

if ($args.Count -gt 0) {
    [Console]::Error.WriteLine('Usage: push-theme.ps1 (no arguments)')
    exit 2
}
Import-Module (Join-Path $PSScriptRoot 'lib/TvEnv.psm1') -Force
Import-TvEnv

$upstream = Join-Path $global:REPO_ROOT 'vendor/cleanyourtv/tools/theme.ps1'
$theme = Join-Path $global:REPO_ROOT 'user-content/theme'
if (-not (Test-Path -LiteralPath $upstream -PathType Leaf)) {
    [Console]::Error.WriteLine('cleanyourtv is not fetched yet. Run scripts/fetch-tools.ps1 first.')
    exit 3
}
if (-not (Test-Path -LiteralPath (Join-Path $theme 'config.json') -PathType Leaf)) {
    [Console]::Error.WriteLine('No theme yet (user-content/theme/config.json). Run scripts/make_theme.py first.')
    exit 3
}

# Native call: relax 'Stop' so upstream's stderr and non-zero exit pass through instead of throwing.
$ErrorActionPreference = 'Continue'
$shell = (Get-Process -Id $PID).Path
$childArgs = @('-NoProfile')
if ([System.IO.Path]::DirectorySeparatorChar -eq '\') { $childArgs += @('-ExecutionPolicy', 'Bypass') }
$childArgs += @('-File', $upstream, '-TvHost', $global:SERIAL, $theme)
& $shell @childArgs
exit $LASTEXITCODE
