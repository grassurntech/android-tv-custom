# Pushes the owner's theme (user-content/theme, made by make_theme.py) to the TV through cleanyourtv's
# own theme.ps1. No arguments. Before anything is sent it checks the theme (the same rules as
# make_theme.py --check-theme): config.json must parse to an object, wallpapers/ must hold a .jpg unless "wallpaper" is false, and no
# package named anywhere in config.json may match config/forbidden-packages.txt.
# Exit: 0 pushed, 2 bad arguments or a theme that fails the check (nothing pushed), 3 TV_IP unset, vendor not
#       fetched, no theme made yet or a package list unreadable; otherwise theme.ps1's own exit code
#       (1 push failed, 2 refused before anything was sent).
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

# Check the theme before anything is sent.
$pkgRe = '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+\z'
function Get-JsonStrings($Value) {
    if ($null -eq $Value) { return }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Value.PSObject.Properties) { Get-JsonStrings $p.Value }
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($x in $Value) { Get-JsonStrings $x }
    }
}
$cfg = $null
try {
    $text = [System.IO.File]::ReadAllText((Join-Path $theme 'config.json'), [System.Text.Encoding]::UTF8)
    $cfg = ConvertFrom-Json -InputObject $text
} catch {
    $cfg = $null
}
# Must be one JSON object, like make_theme.py --check-theme demands (pwsh 7 would unwrap a one-item array).
if ($null -eq $cfg -or $cfg -isnot [System.Management.Automation.PSCustomObject] -or -not $text.TrimStart([char]0xFEFF).TrimStart().StartsWith('{')) {
    [Console]::Error.WriteLine("The theme's config.json is not valid ($theme). Run make_theme.py again. Nothing was pushed.")
    exit 2
}
$wall = Join-Path $theme 'wallpapers'
$jpgs = @()
if (Test-Path -LiteralPath $wall) {
    $wallItem = Get-Item -LiteralPath $wall -Force
    if ($wallItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        [Console]::Error.WriteLine("The theme's wallpapers folder is a symbolic link. Run make_theme.py again. Nothing was pushed.")
        exit 2
    }
    if ($wallItem.PSIsContainer) {
        $jpgs = @(Get-ChildItem -LiteralPath $wall -File -Force | Where-Object { $_.Extension -ieq '.jpg' })
    }
}
# "wallpaper": false is a theme with no photos yet (make_theme.py without --photos): no .jpg needed.
$noPhotos = $null -ne $cfg.PSObject.Properties['wallpaper'] -and $cfg.wallpaper -is [bool] -and -not $cfg.wallpaper
if ($jpgs.Count -eq 0 -and -not $noPhotos) {
    [Console]::Error.WriteLine('The theme has no wallpapers (wallpapers/*.jpg). Run make_theme.py again. Nothing was pushed.')
    exit 2
}
$forbiddenList = Join-Path $global:REPO_ROOT 'config/forbidden-packages.txt'
$patterns = @()
try {
    foreach ($raw in ([System.IO.File]::ReadAllText($forbiddenList, [System.Text.Encoding]::UTF8) -split "`n")) {
        $line = $raw.TrimStart([char]0xFEFF).Replace("`r", '')
        $hash = $line.IndexOf('#')
        if ($hash -ge 0) { $line = $line.Substring(0, $hash) }
        $line = $line.Trim()
        if ($line.Length -gt 0) { $patterns += $line }
    }
} catch {
    [Console]::Error.WriteLine("Can't read the package list forbidden-packages.txt. Nothing was pushed.")
    exit 3
}
if ($patterns.Count -eq 0) {
    [Console]::Error.WriteLine('The package list forbidden-packages.txt has no patterns. Nothing was pushed.')
    exit 3
}
foreach ($s in @(Get-JsonStrings $cfg)) {
    $whole = ([string]$s).Trim()
    $tail = $whole
    if ($whole.Contains(':')) { $tail = $whole.Substring($whole.LastIndexOf(':') + 1).Trim() }
    foreach ($cand in @($whole, $tail)) {
        if ($cand -cnotmatch $pkgRe) { continue }
        foreach ($pat in $patterns) {
            if ($cand -like $pat) {
                [Console]::Error.WriteLine("The theme names $cand, a factory or service-menu app (config/forbidden-packages.txt). Nothing was pushed.")
                exit 2
            }
        }
    }
}

# Native call: relax 'Stop' so upstream's stderr and non-zero exit pass through instead of throwing.
$ErrorActionPreference = 'Continue'
$shell = (Get-Process -Id $PID).Path
$childArgs = @('-NoProfile')
if ([System.IO.Path]::DirectorySeparatorChar -eq '\') { $childArgs += @('-ExecutionPolicy', 'Bypass') }
$childArgs += @('-File', $upstream, '-TvHost', $global:SERIAL, $theme)
& $shell @childArgs
exit $LASTEXITCODE
