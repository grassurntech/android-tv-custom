# Test Cases: Integration, Regression, Mutation and Parity

> **Purpose:** End-to-end runs on a simulated TCL Google TV (fake adb plus docker and upstream shims), checks that every past `fix:` commit is guarded by a test, mutation spot-checks of safety lines, and `.sh` vs `.ps1` parity.
>
> **Last updated:** 2026-11-20

## End-to-end (fake TV)

The fake TV has 13 protected packages (including `*tvinput*`/`*hdmi*`), 5 streaming apps, 2 factory apps, 7 junk candidates, 3 unknowns, one package the owner had already disabled, and the stock launcher `launcherx`.

Every flow runs connect → backup → disable-one for each junk package (one per call) → build → install → push-theme → set Home → restore.

| ID | Sev | Case | Expected | Result 2026-11-19 | Auto test |
|---|---|---|---|---|---|
| IN-01 | — | Full flow, then `restore` | Home and package list identical to the start; disabled list = original + `com.gathin.tvhome` | PASS | — |
| IN-02 | — | Restore twice and three times | idempotent | PASS | — |
| IN-03 | — | Run dies after 3 disables; upstream install fails (exit 9) after installing; only a `.partial` backup exists (13) | exact restore / exit 13 | PASS | — |
| IN-04 | — | Owner re-enabled an app themselves; owner disabled another app themselves; app already off | correct message; restore leaves the owner's own change alone; not logged | PASS | — |
| IN-05 | — | TV refuses a disable (20, not logged); refuses an enable (restore stops; re-run is exact once the TV accepts) | as stated | PASS | — |
| IN-06 | — | Offline mid-run (21), unauthorized (22), then reconnect and restore | exact | PASS | — |
| IN-07 | — | `resolve_home` mismatch (20 with the stay-on warning); `refuse_home` (20, ours disabled, stock on) | as stated | PASS | — |
| IN-08 | — | `--packages-only` then `--home-only`; two backups; Google TV path with `HOME_KEY_SERVICE=1` | exact | PASS | — |
| IN-09 | H | TV goes offline right after a `pm disable-user` (same as SC-12) | the package is in the undo log and `restore` turns it back on | PASS (sh) | `refusal-cases.json` "IN-09 SC-12" (two-step case) |
| IN-10 | M | `config/junk-packages.txt` is empty, so E2E uses an invented junk set | a seeded junk list, or the E2E fixture checked in under `tests/` | PASS 2026-11-20: seeded with 16 names verified on a real TCL; never overlaps the safety lists | `tests/test_lists.py` |

## On-TV runs (real TV, by hand)

First session 2026-11-20: TCL Google TV 11, R51MT05, software V8-R51MT05-LF1V812, macOS host.

| ID | Case | Expected | Result |
|---|---|---|---|
| OT-01 | `connect` → `backup` | connected; backup with 138 packages, 0 already disabled | PASS (after the IP and macOS Local Network fixes in README) |
| OT-02 | `disable-one` on the remote Bluetooth service, Netflix, the factory app and the current Home | 10 / 11 / 12 / 10, nothing sent to the TV | PASS |
| OT-03 | disable the e-manual, owner check, `restore --packages-only` | off, TV fine, back on, 0 disabled | PASS |
| OT-04 | the 16 packages in `config/junk-packages.txt`, in four batches, owner check after each, then reboot | all stay disabled; Home, Wi-Fi, tuner, HDMI/AV, volume and remote work | PASS (two reboots) |
| OT-06 | New home screen on Google TV: `install-launcher` (upstream stops with 1, Home stays launcherx), then `STOCK_HOME_REDIRECT=1 HOME_KEY_SERVICE=1`, theme with `--key-filter false` | Home lands on ours | FAIL with `key_filter: false`: the helper redirected, then Google TV's home came back within 0.5 s; a Home press on Google TV's home stayed there (upstream #2779) |
| OT-07 | Same, theme with `--key-filter true --consume-volume-keys` | Home lands on ours; held volume ramps; Netflix/YouTube/Prime, Input and Settings work | PASS; after a restart and after standby it lands on ours too (Google TV's home shows for about 2 s at boot, a split second on wake) |
| OT-05 | Volume keys stopped working in every app after: 7 packages off → reboot → 5 more switched off live | — | NOT REPRODUCED: `restore` brought volume back; the same 12 off with and without a reboot, and all 16 off after a reboot, kept volume working. Watch for it; if it recurs, run `restore` and note the exact order |

## Regression: every past fix must have a test that fails when it is reverted

| ID | Sev | Fix commit / hunk | Guard | Result 2026-11-19 | Auto test |
|---|---|---|---|---|---|
| RG-01 | — | fba892c BOM in `.env` and empty-env fallback | yes | PASS | C5, C6 |
| RG-02 | — | 345280f partial-name gate and stdout contract | yes | PASS | `test_bash_ignores_partial`, B3 |
| RG-03 | — | 44da775 log pre-check and stray-log cleanup | yes | PASS | D25, D16 |
| RG-04 | — | 58db088 "restored.txt decides" | yes | PASS | R18 |
| RG-05 | — | 20a828a read-back, is_installed, stock skip, Home set last | yes | PASS | R5, R13, R14, R20, R21, R23, R24, R25 |
| RG-06 | — | 91543e6 TV_HOST in install and push; RESTORE_KEY_SERVICES | yes (bash) | PASS | L4, L12, P4, P6, L13 |
| RG-07 | — | ab06b43 backup-dir warning and `..` normalisation | yes | PASS | C7, C9, C10 |
| RG-08 | — | e9fe898 recording on failure and on success | yes | PASS | L9b, L4, L5b, L7b |
| RG-09 | — | 5aafc40 chooser and FallbackHome | yes | PASS | L8c, L8f |
| RG-10 | — | 6770b7f dirty vendor checkout and untracked files | yes | PASS | F7, F8 |
| RG-11 | L | 345280f "packages-all captured last" | no guard (the gate covers it) | GAP | — |
| RG-12 | L | 58db088 `seen` dedupe in restore | no guard (count only) | GAP | — |
| RG-13 | L | 345280f ps1 encoding: B3 strips `\r`, so CRLF output from ps1 would pass | assert exact bytes | ACCEPTED: every reader (sh, ps1, hook, make_theme) now strips CR, so CRLF backup files are harmless; UTF-16 and BOM are still caught | — |
| RG-14 | M | 91543e6 ps1: `$env:RESTORE_KEY_SERVICES` is inherited, not forced to 0 | ps1 forces it to 0, with a test | PASS (ps1 fix unverified until Windows CI) | `cases-launcher.json` RG-14 |
| RG-15 | H | 5aafc40 near-variant: setup-wizard Home accepted (same as TH-50) | refused | PASS (sh) | `cases-launcher.json` TH-50 |
| RG-16 | L | ab06b43 near-variant: repo named with different case, or reached through a symlink (same as SC-42) | warns | PASS (sh); ps1 handles case, not symlinks | `tests/test_helpers.py` SC-42 |

## Mutation spot-check (each mutant must be killed by the suite)

| ID | Sev | Mutant | Result 2026-11-19 | Auto test |
|---|---|---|---|---|
| MU-01 | — | 18 safety mutants killed: protected check inverted; streaming or forbidden refusal deleted; backup gate removed; lower-casing removed; refusal exit changed to 0; weak Home read-back; restore continuing past a refusal; substring list_has; argument regex removed; home-state overwritten; ours re-enabled; empty packages-all accepted; empty backup list; stock-on check removed; already-off fall-through; unknown is_installed; failed Home disable exits 0; literal glob match | PASS | existing suite |
| MU-02 | M | Delete the "TV didn't answer before the change" check in `disable-one` | killed: fake adb gained `fail_list_disabled` / `list_junk` | `refusal-cases.json` SC-13 |
| MU-03 | M | Delete the "didn't confirm" branch after the change | killed: the message is asserted | `refusal-cases.json` SC-11 |
| MU-04 | L | `tv_reachable` stops checking that get-state printed `device` | survives | — |

## sh / ps1 parity

| ID | Sev | Difference | Expected | Result 2026-11-19 | Auto test |
|---|---|---|---|---|---|
| PA-01 | M | Unreadable log or home-state: sh skips silently (0) or exits 3, ps1 throws (1) | both exit 3 | sh PASS; ps1 fixed, unverified until Windows CI | `refusal-cases.json` SC-30, PA-01 |
| PA-02 | M | Unreadable `packages-all.txt` in `disable-one`: sh 14, ps1 1 | both exit 3 | sh PASS; ps1 fixed, unverified | SC-16 PA-02 |
| PA-03 | M | `Invoke-Adb` merges stderr (`2>&1`); sh ignores stderr. A stderr warning can fail the Home read-back in ps1 only | ps1 ignores stderr for parsed output | sh PASS; ps1 drops stderr, unverified | PA-03 (fake adb `stderr_noise`) |
| PA-04 | L | `unauthorized`/`device` matched case-insensitively in ps1, case-sensitively in sh | same rule both sides | PASS by review (both case-sensitive) | — |
| PA-05 | M | `HOME_KEY_SERVICE`/`INPUT_KEY_SERVICE`: sh passes any value, ps1 only `1` | both accept only `0`/`1`, else exit 2 | sh PASS; ps1 unverified | `cases-launcher.json` PA-05 |
| PA-06 | M | `RESTORE_KEY_SERVICES`: sh forces 0, ps1 inherits (same as RG-14) | both force 0 | PASS (ps1 unverified) | `cases-launcher.json` RG-14 |
| PA-07 | L | Backup-dir warning compares case-insensitively only on Windows (ps1); sh is always case-sensitive | case-insensitive on macOS and Windows | PASS (see SC-42) | `tests/test_helpers.py` SC-42 |
| PA-08 | L | `install-launcher.ps1`/`build-launcher.ps1` use `Write-Host`; sh prints to stdout | `Write-Output` | PASS by review (ps1 unverified) | — |
| PA-09 | M | No macOS CI job (bash 3.2, BSD tools) | a `macos-latest` job in `.github/workflows/tests.yml` | ADDED; first run on the next push | `.github/workflows/tests.yml` job `macos` |
| PA-10 | M | Without Pillow, all `make_theme` tests skip and the run still says OK | strict in CI via `TV_TEST_REQUIRE_PILLOW=1` | ACCEPTED: CI (Ubuntu, macOS, Windows) fails if Pillow is missing; locally the skip reason is printed with `-v` | — |
