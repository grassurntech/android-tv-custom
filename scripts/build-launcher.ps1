# Builds the cleanyourtv launcher in Docker, signed with this owner's own key kept in user-content/keystore/
# (git-ignored). The first build creates debug.keystore there; later builds reuse it, so an install over the
# launcher already on the TV keeps working. If the key is missing but an earlier install is recorded
# (installed-by-us.txt in a backup folder), it warns loudly: an app signed with a new key can't update the one on
# the TV. No arguments. Does not touch the TV.
# The APK must be (re)written by this build: an old one is set aside first and put back only if the build fails.
# (The 700/600 permissions of the sh twin are not set here: Windows uses the user profile's ACLs.)
# Exit: 0 APK built, 2 bad arguments, 3 setup missing (Docker not installed or not running, vendor not fetched),
#       1 the build produced no APK (or an empty one); otherwise the upstream build's own exit code.
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
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine("Docker isn't installed. Install Docker Desktop, open it and wait until it says running, then run this again.")
    exit 3
}
# Native call: relax 'Stop' so docker's stderr is judged by exit code.
$ErrorActionPreference = 'Continue'
$null = & docker info 2>&1
$dockerOk = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = 'Stop'
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

# A new key can't update an app the TV already has from an earlier build.
if (-not (Test-Path -LiteralPath (Join-Path $keydir 'debug.keystore') -PathType Leaf)) {
    Import-Module (Join-Path $PSScriptRoot 'lib/TvEnv.psm1') -Force
    Read-TvDotEnv
    $bd = [Environment]::GetEnvironmentVariable('TV_BACKUP_DIR')
    if ([string]::IsNullOrEmpty($bd)) { $bd = 'backups' }
    if (-not [System.IO.Path]::IsPathRooted($bd)) { $bd = Join-Path $repo $bd }
    if (Test-Path -LiteralPath $bd -PathType Container) {
        foreach ($d in @(Get-ChildItem -LiteralPath $bd -Directory)) {
            $f = Join-Path $d.FullName 'installed-by-us.txt'
            if (Test-Path -LiteralPath $f -PathType Leaf) {
                [Console]::Error.WriteLine("WARNING: there is no signing key in $keydir, but our launcher was installed on a TV before ($f).")
                [Console]::Error.WriteLine('WARNING: this build makes a NEW key. The TV will refuse it as an update to the launcher it already has.')
                [Console]::Error.WriteLine('WARNING: if you still have the old user-content/keystore folder, put it back and build again.')
                break
            }
        }
    }
}

# Set the old APK aside, so only an APK written by this build counts.
$old = "$apk.previous"
Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $apk -PathType Leaf) {
    try {
        Move-Item -LiteralPath $apk -Destination $old -Force
    } catch {
        [Console]::Error.WriteLine("Can't move the old APK out of the way ($apk).")
        exit 3
    }
}

$env:HOST_KEY_DIR = $keydir
$ErrorActionPreference = 'Continue'
$shell = (Get-Process -Id $PID).Path
$childArgs = @('-NoProfile')
if ([System.IO.Path]::DirectorySeparatorChar -eq '\') { $childArgs += @('-ExecutionPolicy', 'Bypass') }
$childArgs += @('-File', $upstream)
& $shell @childArgs
$rc = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$built = (Test-Path -LiteralPath $apk -PathType Leaf) -and ((Get-Item -LiteralPath $apk).Length -gt 0)
if ($rc -ne 0 -or -not $built) {
    if (-not $built) { Remove-Item -LiteralPath $apk -Force -ErrorAction SilentlyContinue }
    if ((Test-Path -LiteralPath $old -PathType Leaf) -and -not (Test-Path -LiteralPath $apk -PathType Leaf)) {
        Move-Item -LiteralPath $old -Destination $apk -Force
    }
    if ($rc -ne 0) {
        [Console]::Error.WriteLine("The launcher build failed (exit $rc).")
        exit $rc
    }
    [Console]::Error.WriteLine("The build finished but produced no APK at $apk (build produced no APK).")
    exit 1
}
Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
Write-Output "Built $apk"
exit 0
