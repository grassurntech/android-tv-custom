# Test Cases: TV Scripts

> **Purpose:** Unit and adversarial cases for `connect`, `backup`, `disable-one`, `restore` and `scripts/lib/tv-env`. Each runs against `tests/fake_adb.py` with a fresh repo copy and backup. Expected behaviour is the same for `.sh` and `.ps1` unless a row says otherwise.
>
> **Last updated:** 2026-11-20
>
> **Result column:** "PASS (sh)" means the bash run passed locally; the same JSON case runs the `.ps1` in CI (Windows PowerShell 5.1 and pwsh on Ubuntu). pwsh is not installed on the dev machine, so every ps1 result below is unverified until CI runs. Cases that `chmod` a file are skipped on Windows and as root.

## Safety lists

| ID | Sev | Case | Expected | Result 2026-11-19 | Auto test |
|---|---|---|---|---|---|
| SC-01 | C | `config/streaming-apps.txt` unreadable (`chmod 000`), then `disable-one com.netflix.ninja` | exit 3, nothing sent to the TV | PASS (sh) | `refusal-cases.json` SC-01 |
| SC-02 | C | UTF-8 BOM before the first pattern line (`\xef\xbb\xbfcom.netflix.*`) | the pattern still matches, so exit 11 | PASS (sh) | SC-02 |
| SC-03 | C | Inline comment in a list: `com.netflix.*   # Netflix` | pattern still matches (comment stripped) | PASS (sh) | SC-03 |
| SC-04 | C | Tab-separated reason after a pattern | pattern still matches | PASS (sh) | SC-04 |
| SC-05 | C | List file with CR-only line endings | patterns still match | PASS (sh) | SC-05 |
| SC-06 | C | List file saved as UTF-16 | exit 3 (unreadable list), never "no match" | PASS (sh) | SC-06 (with and without BOM) |
| SC-07 | C | List file empty, or with no pattern lines | exit 3 | PASS (sh) | SC-07 (empty, comments only) |
| SC-08 | M | `com.google.android.katniss`, `com.google.android.gms.*` sub-packages, `com.android.inputdevices`, `com.tcl.tv` (Live TV), `com.tcl.xian.StartandroidService` | refused as protected | PASS (sh) | SC-08 (five cases) |
| SC-09 | — | Case variants (`COM.NETFLIX.NINJA`), CRLF lists, missing list, list is a directory, list is a `/dev/null` symlink | 11 / match / 3 / 3 / 3 | PASS | `tests/script_cases.py` |
| SC-44 | H | Real TCL Google TV 11 (R51MT05) names from the first on-TV session: remote Bluetooth service `com.tcl.tcl_bt_rcu_service`, `com.tcl.autopair`, `com.tcl.system.server`, `com.tvos`, Chromecast built-in, an `overlay.modules` part, `com.tcl.keyhelp`, `com.tcl.suspension`, `com.tcl.guard`; streaming `com.graymatrix.did` (ZEE5), `com.tubitv`, `com.esaba.downloader` | 10 for the nine protected, 11 for the three streaming | PASS (sh) 2026-11-20 | SC-44 (twelve cases) |

## disable-one

| ID | Sev | Case | Expected | Result 2026-11-19 | Auto test |
|---|---|---|---|---|---|
| SC-10 | H | Disable the package that Home currently resolves to (stock launcher, or ours while it is Home) | refused with a clear message, TV unchanged | PASS (sh): exit 10 "is the TV's current Home app, so it stays on"; an unreadable Home answer exits 20 | SC-10 (two cases) |
| SC-11 | H | `pm disable-user` succeeds, then `pm list packages -d` returns junk with exit 0 | package logged in `disabled-by-us.txt` (logged before the change); message never says "Nothing was changed" | PASS (sh) | SC-11 |
| SC-12 | H | `pm disable-user` succeeds, then the TV goes offline before the read-back | package logged; exit 20 with "didn't confirm, may be off"; `restore` turns it back on | PASS (sh) | IN-09 SC-12 (two-step case) |
| SC-13 | M | `pm list packages -d` fails *before* the change (TV didn't answer) | exit 20 or 21, no `pm disable-user` sent | PASS (sh): exit 20 | SC-13 (fails; prints junk) |
| SC-14 | M | Two `disable-one` runs at once both creating the log | both records kept | PASS (sh): no writability probe any more; the record itself is the append, and only this run's exact line is ever taken back out | SC-14 (refusal keeps other records; append after a line with no newline) |
| SC-15 | M | `installed-by-us.txt` placed in `backups/junk/` or a `.partial` folder | ignored; only real backup folders count | PASS (sh) | SC-15 |
| SC-16 | L | `packages-all.txt` unreadable | exit 3 | PASS (sh) | SC-16 PA-02 |
| SC-17 | — | Name injection: empty, spaces, CR, tab, newline, `--user`, `-x.y`, `*`, `[d]`, `;`, `$(…)`, backticks, dotless-i lookalike, `com..tcl`, leading or trailing dot | exit 2, no adb call | PASS | `tests/script_cases.py` |

## Backup gate

| ID | Sev | Case | Expected | Result 2026-11-19 | Auto test |
|---|---|---|---|---|---|
| SC-20 | H | Backup taken on TV A (getprop serial A), then `disable-one` against TV B | refused: the backup doesn't match this TV (exit 13) | PASS (sh): backup writes `tv-id.txt` (`ro.serialno`, else `ro.boot.serialno`, else `adb:<IP:port>`); disable-one and restore exit 13 on a mismatch or a missing identity | SC-20 (six cases) |
| SC-21 | M | `backup` when `pm list packages` prints an error message and exits 0 | exit 20, no backup folder kept | PASS (sh) | SC-21 |
| SC-22 | M | Backup folder whose `packages-all.txt` has no `package:` lines, or has no getprop/settings/disabled files | not accepted as a backup (exit 13) | PASS (sh) | SC-22, `tests/test_helpers.py` |
| SC-23 | M | A future-dated folder (`9999-99-99_999999`) under `backups/` | ignored (bad timestamp) | PASS (sh) | SC-23, `tests/test_helpers.py` |
| SC-24 | L | `TV_BACKUP_DIR` not writable, then `backup` | exit 3 | PASS (sh) | SC-24 |
| SC-25 | — | `.partial` folders ignored; a mid-backup refusal leaves no `.partial`; same-second runs don't clobber each other | as stated | PASS | `tests/script_cases.py`, `tests/test_helpers.py` |

## restore

| ID | Sev | Case | Expected | Result 2026-11-19 | Auto test |
|---|---|---|---|---|---|
| SC-30 | H | `disabled-by-us.txt` unreadable | exit 3 | PASS (sh) | SC-30 |
| SC-31 | H | TV refuses `pm enable`, and `pm list packages -d` returns error text | exit 20, package not recorded as restored | PASS (sh) | SC-31 |
| SC-32 | H | `restore --home-only` when the stock launcher named in `home-state.txt` is no longer installed | refuses to disable ours (exit 20 with a clear message); a Home launcher stays enabled | PASS (sh) | SC-32 |
| SC-33 | M | `restored.txt` not writable | TV restore still completes; a local file error exits 3, never 20 | PASS (sh) | SC-33 |
| SC-34 | L | TV goes offline right after `pm enable` | exit 21 "can't reach" | PASS (sh) | SC-34 |
| SC-35 | L | A logged package that has since been uninstalled | reported as "no longer installed", not counted as turned on | PASS (sh) | SC-35 (two cases) |
| SC-36 | — | Round trip, dedupe, CRLF or BOM log lines, a non-package log line (exit 3), ignored `.partial` log, `home-state.txt` naming a streaming app as ours (exit 11), malformed `home-state.txt` (exit 3) | as stated | PASS | `tests/script_cases.py` |
| PF-02 | H | `home-state.txt` in more than one backup, the newest naming our own launcher as stock | the oldest record is used; one line says so when they disagree | PASS (sh) | PF-02 |

## connect, tv-env and .env

| ID | Sev | Case | Expected | Result 2026-11-19 | Auto test |
|---|---|---|---|---|---|
| SC-40 | L | `TV_IP=10.0.0.9:5555`, whitespace-only, spaces, `;`, unbracketed IPv6; `TV_ADB_PORT=abc` | exit 3 with "TV_IP doesn't look like an address" | PASS (sh) | SC-40 (seven cases) |
| SC-41 | L | `.env` line `TV_IP="10.0.0.9" # my tv` | value `10.0.0.9` | PASS (sh) | SC-41 (quoted, unquoted) |
| SC-42 | L | `TV_BACKUP_DIR` naming the repo with different letter case, or a symlink into the repo | warning shown | PASS (sh); ps1 handles letter case but does not resolve symlinks | `tests/test_helpers.py` (bash only) |
| SC-43 | — | Unauthorized gives 22, offline gives 21, missing adb gives 3, extra arguments give 2 (all four scripts); shell metacharacters in `TV_IP` or `.env` never execute | as stated | PASS | `tests/script_cases.py` |

## sh / ps1 parity

| ID | Sev | Case | Expected | Result 2026-11-19 | Auto test |
|---|---|---|---|---|---|
| PA-01 | M | Unreadable log or home-state | both exit 3 | sh PASS; ps1 fixed (explicit catches plus a trap that turns any unexpected error into 3), unverified | SC-30, PA-01 |
| PA-02 | M | Unreadable `packages-all.txt` in `disable-one` | both exit 3 | sh PASS; ps1 fixed, unverified | SC-16 PA-02 |
| PA-03 | M | A stderr warning from adb must not change parsed output | ps1 ignores stderr for parsed output | sh PASS; ps1 now drops stderr (`2>$null`) in every parsed adb call, unverified | PA-03 (restore Home, disable-one) |
| PA-04 | L | `unauthorized`/`device` matching | same rule both sides | fixed by review: both case-sensitive (substring `unauthorized`, exact `device`); no fake-adb switch can tell them apart | — |
