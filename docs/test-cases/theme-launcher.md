# Test Cases: Theme and Launcher

> **Purpose:** Cases for `scripts/make_theme.py`, `push-theme`, `build-launcher` and `install-launcher`. Images are generated with Pillow in temp folders. Docker and the upstream tools are stood in for by shims that only log their arguments.
>
> **Results 2026-11-19:** the `.sh` cases ran; PowerShell was not installed, so the `.ps1` twins of TH-30..54 and TH-56 were mirrored by reading only and run wherever CI has PowerShell.
>
> **Last updated:** 2026-11-20

## make_theme.py: files and privacy

| ID | Sev | Case | Expected | Result 2026-11-19 | Auto test |
|---|---|---|---|---|---|
| TH-01 | C | `--photos X/wallpapers --out X` (output overlaps the photos), folder holds `IMG_0001.jpg`, `notes.txt`, `video.mov` | exit 2, nothing deleted | PASS (exit 2, nothing deleted) | `tests/test_make_theme.py` |
| TH-02 | C | `<out>/wallpapers` is a symlink to a folder holding `taxes.pdf` | exit 2, nothing deleted | PASS (exit 2; a symlinked `NN.jpg` is never followed) | `tests/test_make_theme.py` |
| TH-03 | H | `--out` is any existing folder with `wallpapers/` and `config.json` that we didn't create | refuse or replace only our own `NN.jpg` files | PASS (refused unless it holds our `.made-by-make_theme` marker; only our `NN.jpg` files are deleted) | `tests/test_make_theme.py` |
| TH-04 | C | Photo with a JPEG comment (`comment=b"Home: 12 Elm St"`), or a PNG `tEXt` comment | output JPEG has no comment and no `info` metadata | PASS (pixels copied into a fresh image) | `tests/test_make_theme.py` (comment, PNG text, XMP, ICC) |
| TH-05 | M | `--out themes/mine` (inside the repo, not git-ignored) | refuse, or warn that it isn't git-ignored and point to `user-content/` | PASS (exit 2, points to `user-content/theme`; without git, only `user-content/` counts) | `tests/test_make_theme.py` |
| TH-06 | M | `--out` is a file, or can't be written | exit 3 with a plain message | PASS (exit 3, plain message) | `tests/test_make_theme.py` |
| TH-07 | — | EXIF (including GPS), XMP and ICC are stripped | as stated | PASS | `tests/test_make_theme.py` (EXIF, XMP, ICC) |

## make_theme.py: inputs and flags

| ID | Sev | Case | Expected | Result 2026-11-19 | Auto test |
|---|---|---|---|---|---|
| TH-10 | M | `--apps` including `com.tcl.factory` (forbidden) or protected packages; `--app-key 190:com.tcl.factory`; `--live-tv-package com.tcl.factory.view` | exit 2 for forbidden packages anywhere | PASS (exit 2; lists read with the scripts' rules, fail closed with exit 3) | `tests/test_make_theme.py` |
| TH-11 | M | `--stock-home-redirect com.android.tv.settings` (protected, not a launcher) or `com.gathin.tvhome` (ours) | exit 2 | PASS | `tests/test_make_theme.py` |
| TH-60 | H | `install-launcher` with `STOCK_HOME_REDIRECT=1` (Google TV redirect mode) after upstream's 1: Home still the recorded launcher; another accessibility service already listed; ours already listed; no `HOME_KEY_SERVICE=1`; a bad value; Home on the wizard's RecoveryActivity; ours not installed; the TV drops the write; a list with `;` in it; another upstream code; mode off | 0 with the AUTO_START app-ops and the helper added (others kept, a listed one cleared and rewritten); 2; 2; 1 with nothing touched; 1; 20; 20 with no write; code passed through; 1 | PASS (sh) 2026-11-20; ps1 unverified until CI | `tests/cases-redirect.json` (11 cases) |
| TH-57 | M | `--apps` with 1, 3, 6 or 8 apps; 9 apps, a duplicate, an empty entry | 0 with `columns` = max(4, count); exit 2 for the rest | PASS 2026-11-20 | `tests/test_make_theme.py` |
| TH-58 | L | `--clock` left out, or `system` | `clock_format` = `system` (the owner sets it on the TV) | PASS 2026-11-20 | `tests/test_make_theme.py` |
| TH-59 | M | No `--photos`; photos added later; `wallpaper: false` theme pushed with no `.jpg`; `"false"` as a string; `wallpapers` symlink | plain theme passes the check and is pushed; a later run with photos fills it and a run without clears ours; the string still needs photos; symlink refused | PASS (sh) 2026-11-20; ps1 unverified until CI | `tests/test_make_theme.py`, `tests/cases-launcher.json` TH-59a/b |
| TH-12 | M | `--app-key` on Back, Home, Power, D-pad centre (`KEYCODE_BACK`, `3`, `KEYCODE_POWER`, `23`) | exit 2 | PASS (also Enter, Menu and their scan codes) | `tests/test_make_theme.py` |
| TH-13 | M | The same key mapped twice (`190:a.b` and `190:c.d`) | exit 2 | PASS | `tests/test_make_theme.py` |
| TH-14 | M | `--power-on live-tv` without `--live-tv-package` | exit 2 | PASS | `tests/test_make_theme.py` |
| TH-15 | L | `--key-filter false` together with `--app-key` | warning | PASS (warning) | `tests/test_make_theme.py` |
| TH-16 | L | 16-bit grayscale PNG | a correctly toned wallpaper | PASS | `tests/test_make_theme.py` |
| TH-17 | L | RGBA with fully transparent pixels | composited onto black | PASS | `tests/test_make_theme.py` |
| TH-18 | L | Name with DEL, C1 controls, U+202E, only zero-width characters, U+2028, or lone surrogates | exit 2 | PASS | `tests/test_make_theme.py` |
| TH-19 | L | `.gif`, `.tif` or hidden files in the photo folder | skipped with a warning | PASS (warning) | `tests/test_make_theme.py` |
| TH-20 | — | JSON escaping (quotes, backslashes, `</script>`, `{0}`, `%s`, emoji); exactly 4 apps; size limit and knob clamp; 100-photo cap; corrupt, truncated, zero-byte and bomb images skipped; CMYK, palette and WebP work; EXIF orientation applied; odd filenames; a failed run never touches the old theme | as stated | PASS | `tests/test_make_theme.py` |

## push-theme

| ID | Sev | Case | Expected | Result 2026-11-19 | Auto test |
|---|---|---|---|---|---|
| TH-30 | M | Theme folder with invalid `config.json`, or with no `wallpapers/` | exit 2, nothing pushed | PASS (`make_theme.py --check-theme`; ps1 checks natively) | `tests/cases-launcher.json`, `tests/test_make_theme.py` |
| TH-31 | M | Theme `config.json` naming a forbidden package (e.g. a `boot_to_live_tv` target) | exit 2, nothing pushed | PASS | `tests/cases-launcher.json`, `tests/test_make_theme.py` |
| TH-32 | M | ps1 parity: `config.json` is a one-object array (`[{...}]`), which pwsh 7's `ConvertFrom-Json` unwraps; and `build-launcher.ps1` must read the owner's settings file for `TV_BACKUP_DIR` before the TH-40 key warning | refused (exit 2) on both shells; warning found in a non-default backup folder | PASS (sh); ps1 fixed after review, unverified until CI | `tests/cases-launcher.json` TH-30d |

## build-launcher

| ID | Sev | Case | Expected | Result 2026-11-19 | Auto test |
|---|---|---|---|---|---|
| TH-40 | M | `user-content/keystore` deleted after a first install | loud warning that the new key won't update the installed app | PASS (warning; the build still runs) | `tests/cases-launcher.json` |
| TH-41 | M | Upstream build exits 0 but writes no new APK (an old one is still there) | exit non-zero, "build produced no APK" | PASS (old APK set aside first, put back if no new one) | `tests/cases-launcher.json` |
| TH-42 | L | Docker not installed at all | message says "Docker isn't installed" | PASS | `tests/cases-launcher.json` |
| TH-43 | L | Keystore folder and file permissions | 700 / 600 | PASS (sh; ps1 relies on Windows profile ACLs) | `tests/test_launcher_qa.py` |
| TH-44 | — | Keystore is git-ignored and never printed | as stated | PASS | `tests/script_cases.py` |

## install-launcher

| ID | Sev | Case | Expected | Result 2026-11-19 | Auto test |
|---|---|---|---|---|---|
| TH-50 | C | Home before install is a setup or provisioning screen: `com.google.android.setupwizard/.SetupWizardActivity`, `com.android.provision/.DefaultActivity`, `com.tcl.initsetup/.SetupActivity` | exit 3 "Home isn't a normal launcher"; no `home-state.txt` | PASS (also the chooser `ResolverActivity`) | `tests/cases-launcher.json` |
| TH-51 | M | Home before install is a forbidden or protected non-launcher (`com.tcl.factory.home/.FactoryHome`, `com.android.tv.settings/.MainSettings`) | exit 3, not recorded | PASS (protected or forbidden Home refused) | `tests/cases-launcher.json` |
| TH-52 | M | `resolve-activity` prints two component lines | exit 3 (ambiguous Home) | PASS | `tests/cases-launcher.json` |
| TH-53 | M | Upstream install exits 1 after installing, and `pm list packages <ours>` fails | `installed-by-us.txt` still written (fallback to the unfiltered list) or a loud warning | PASS (unfiltered list fallback; if the TV can't answer, listed with a warning) | `tests/cases-launcher.json` |
| TH-54 | M | 0-byte APK | exit 2 or 3, no install | PASS (exit 3) | `tests/cases-launcher.json` |
| TH-56 | M | Second session (PF-02): a home-state.txt already exists in an older backup; Home is now something else | Home not read or recorded again; the original record stands | PASS | `tests/cases-launcher.json` |
| TH-55 | — | No backup gives exit 13 before any adb call; `.partial` ignored; upstream always gets `STOCK_LAUNCHER=none`, `SKIP_BUILD=1`, `RESTORE_KEY_SERVICES=0`; FallbackHome, chooser and setupwraith refused | as stated | PASS | `tests/script_cases.py` |
