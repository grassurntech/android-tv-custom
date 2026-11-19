# Builds the cleanyourtv launcher in Docker, signed with this owner's own key kept in user-content/keystore/
# (git-ignored). The first build creates debug.keystore there; later builds reuse it, so an install over the
# launcher already on the TV keeps working. No arguments. Does not touch the TV.
# Exit: 0 APK built, 2 bad arguments, 3 setup missing (Docker not running, vendor not fetched),
#       1 the build produced no APK; otherwise the upstream build's own exit code.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

if ($args.Count -gt 0) {
    [Console]::Error.WriteLine('Usage: build-launcher.ps1 (no arguments)')
    exit 2
}
$repo = Split-Path -Parent $PSScriptRoot
$upstream = Join-Path $repo 'vendor/cleanyourtv/tools/docker-build.ps1'
$apk = Join-Path $repo 'vendor/cleanyourtv/launcher/app/build/outputs/apk/release/app-release.apk'
$keydir = Join-Path $repo 'user-content/keystore'

if (-not (Test-Path -LiteralPath $upstream -PathType Leaf)) {
    [Console]::Error.WriteLine('cleanyourtv is not fetched yet. Run scripts/fetch-tools.ps1 first.')
    exit 3
}
# docker not installed at all is the same setup problem as docker not running (matches the sh twin).
$dockerOk = $false
if (Get-Command docker -ErrorAction SilentlyContinue) {
    # Native call: relax 'Stop' so docker's stderr is judged by exit code.
    $ErrorActionPreference = 'Continue'
    $null = & docker info 2>&1
    $dockerOk = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = 'Stop'
}
if (-not $dockerOk) {
    [Console]::Error.WriteLine('Docker is not running. Open Docker Desktop and wait until it says running, then run this again.')
    exit 3
}
try {
    $null = New-Item -ItemType Directory -Force -Path $keydir
} catch {
    [Console]::Error.WriteLine("Can't create $keydir")
    exit 3
}
$keydir = (Resolve-Path -LiteralPath $keydir).Path
$env:HOST_KEY_DIR = $keydir

$ErrorActionPreference = 'Continue'
$shell = (Get-Process -Id $PID).Path
$childArgs = @('-NoProfile')
if ([System.IO.Path]::DirectorySeparatorChar -eq '\') { $childArgs += @('-ExecutionPolicy', 'Bypass') }
$childArgs += @('-File', $upstream)
& $shell @childArgs
$rc = $LASTEXITCODE
if ($rc -ne 0) {
    [Console]::Error.WriteLine("The launcher build failed (exit $rc).")
    exit $rc
}
if (-not (Test-Path -LiteralPath $apk -PathType Leaf)) {
    [Console]::Error.WriteLine("The build finished but there is no APK at $apk")
    exit 1
}
Write-Host "Built $apk"
exit 0
