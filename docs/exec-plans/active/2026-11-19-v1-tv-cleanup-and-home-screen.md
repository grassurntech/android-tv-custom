# v1: TV Cleanup and Personal Home Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship v1 of android-tv-custom: safety-enforcing scripts (Bash + PowerShell), the cleanyourtv-based launcher with a photos/clock/name/four-app theme, the one-paste `PROMPT.md`, and a visitor-ready repo, proven end-to-end on our TCL TV.

**Architecture:** A non-coder pastes `PROMPT.md` into an AI tool. The agent drives the TV only through our scripts in `scripts/`, which enforce every TV safety rule themselves, and through cleanyourtv's pinned build/install/theme tools in git-ignored `vendor/cleanyourtv/`. All personal data (photos, keystore, backups, `.env`) stays in git-ignored folders.

**Tech Stack:** Bash (macOS/Linux), Windows PowerShell 5.1+ (Windows), Python 3 stdlib `unittest` for tests, Pillow for photo scaling, Android platform-tools `adb`, Docker (cleanyourtv's `tools/docker-build.*`), GitHub Actions.

**Spec:** [docs/design-docs/2026-11-19-tv-cleanup-and-home-screen.md](../../design-docs/2026-11-19-tv-cleanup-and-home-screen.md) (accepted). Read it before any task.

## Global Constraints

- Disable only with `pm disable-user --user 0 <package>`, one package per command, through `scripts/disable-one.*`. Never uninstall, `pm clear/hide/suspend`, root or flash.
- No change to the TV before a backup with a non-empty `packages-all.txt` exists in `backups/<YYYY-MM-DD_HHMMSS>/`.
- Never disable anything matching `config/protected-packages.txt`, `config/streaming-apps.txt` or `config/forbidden-packages.txt`. Never launch anything matching `forbidden-packages.txt`.
- On refusal from the TV: stop, report, no retry.
- Every owner-run script exists as `scripts/<name>.sh` **and** `scripts/<name>.ps1` with identical arguments, exit codes, files written and adb calls. PowerShell must run on Windows PowerShell 5.1 (`powershell -NoProfile -ExecutionPolicy Bypass -File ...`).
- Scripts read `.env` as plain `KEY=VALUE` lines (never `source`/dot-source it). Already-set environment variables win. Variables: `TV_IP`, `TV_ADB_PORT` (default `5555`), `TV_BACKUP_DIR` (default `backups`), `ADB` (default: `tools/platform-tools/adb` if present, else `adb` on PATH).
- Scripts must work from a repo path containing spaces (the dev checkout is under `Claude Code/`).
- Upstream pin, in `config/upstream.env`: `CLEANYOURTV_TAG=v3.5.0`, `CLEANYOURTV_COMMIT=d11bd68c9ac45b2fb38480941586d17930137e9d`, `CLEANYOURTV_URL=https://github.com/Gathin23/cleanyourtv.git`. Our launcher package: `com.gathin.tvhome`.
- Theme: `columns` = 4, `greeting_name`, `show_greeting: true`, `dock_apps` (4 packages), `clock_format` `"12"` or `"24"`, wallpapers 1920×1080 JPEG under 300 KB each, EXIF stripped.
- Git-ignored, never committed: `.env`, `backups/`, `photos/`, `user-content/` (theme, keystore), `screenshots/`, `vendor/`, `tools/platform-tools/`, `.venv/`.
- Nothing personal in committed files: placeholder name and apps only; sample images CC0/public domain with credits.
- Never read `.env` from Claude; never `--no-verify`; if the tv-safety hook blocks something, stop and tell the user.
- Work on a branch (`feat/v1-...`), PR into `main`; the user pushes. After each merged PR, run the CLAUDE.md doc-update rule.

## Exit codes (shared by all scripts)

| Code | Meaning |
|---|---|
| 0 | Done (or nothing to do) |
| 2 | Bad arguments |
| 3 | Setup missing (`TV_IP` unset, config list missing, Docker not running, vendor not fetched) |
| 10 / 11 / 12 | Package is protected / streaming / forbidden |
| 13 | No usable backup |
| 14 | Package not in the backup and not installed by us |
| 20 | TV refused (state unchanged after the command) |
| 21 | TV unreachable / offline |
| 22 | TV says unauthorized (accept "Allow debugging?") |
| 30 | Upstream fetch doesn't match the pinned commit |

## Review Focus

1. **TV drops off Wi-Fi mid-run**: every script exits 21 with a plain message, writes no log line for an unconfirmed change, and leaves no half-written backup folder. Tests D15, B2, R6.
2. **Config lists edited on Windows (CRLF line endings, trailing spaces)**: protection still matches. Test D19.
3. **Re-running after a crash or twice in a row**: no duplicate log lines, restore is idempotent. Tests D18, R4.
4. **Missing or empty `.env` / `TV_IP`**: clear "create .env" message, exit 3, zero adb calls. Tests D5, B1, C4.
5. **Repo path with spaces and mixed-case package names**: the test runner always runs from a temp root named `tv repo/`; `com.Netflix.ninja` is still streaming-protected. Tests D9 and the runner itself.

---

## Milestone A: Safety core (no TV needed)

### Task 1: Lists, hook update and test harness

**Files:**
- Create: `config/streaming-apps.txt`, `config/junk-packages.txt`, `config/upstream.env`
- Create: `tests/fake_adb.py`, `tests/script_cases.py`, `tests/refusal-cases.json`, `tests/test_hook.py`
- Modify: `.claude/hooks/tv-safety.py` (load `streaming-apps.txt`, treat like protected)
- Modify: `.gitignore` (add `/vendor/`, `/tools/platform-tools/`, `/.venv/`)

**Interfaces:**
- Produces: `fake_adb.py`: an adb stand-in. Reads JSON state from `$FAKE_ADB_STATE`, appends each argv (joined by spaces) as one line to `$FAKE_ADB_LOG`, and writes state changes back. State keys: `state` (`device|unauthorized|offline`), `packages` [str], `disabled` [str], `refuse` [str] (disable/enable has no effect), `home` (component string), `getprop` (str). Handles: `connect H:P`, `-s S get-state`, `-s S shell pm list packages [-d|-e]` (prints `package:<name>` lines), `pm disable-user --user 0 P`, `pm enable P`, `getprop`, `settings list global|secure|system`, `cmd package resolve-activity --brief ... HOME` (prints two lines, the second `home`), and `cmd package set-home-activity --user 0 C`. Offline → stderr `error: device offline`, exit 1.
- Produces: `script_cases.py`: a `unittest` module that loads `tests/refusal-cases.json` and, for every case, runs it against each available implementation: Bash (when `bash` exists and the OS isn't Windows) and PowerShell (`pwsh`, or `powershell` on Windows). Each run copies `scripts/` and `config/` into a fresh temp dir named `tv repo/`, writes the case's `files`, puts an `adb` shim to `fake_adb.py` first on PATH and in `ADB`, and checks `expect`.
- Case schema: `{"script": "disable-one|backup|restore|connect|install-launcher|build-launcher", "name": str, "args": [str], "env": {k: str|null}, "files": {relpath: text}, "tv": {state}, "expect": {"exit": int, "adb_calls_include": [substr], "adb_calls_exclude": [substr], "adb_call_count": {substr: n}, "files_contain": {relpath: [line]}, "files_absent": [relpath], "stderr_contains": str}}`. A `null` env value means unset.

- [ ] **Step 1: Write `tests/test_hook.py`.** Port the 33 cases from the scratchpad `test_tv_safety.py`, plus: `adb shell pm disable-user --user 0 com.netflix.ninja` blocked with "streaming"; `com.amazon.amazonvideo.livingroom` blocked. Expected: the new cases FAIL.
- [ ] **Step 2: Create `config/streaming-apps.txt`** with globs: `com.netflix.*`, `com.amazon.amazonvideo.*`, `com.amazon.avod*`, `com.disney.*`, `com.google.android.youtube.tv*`, `com.google.android.youtube.tvkids`, `com.google.android.youtube.tvmusic`, `in.startv.hotstar*`, `com.jio.*`, `com.apple.atve.*`, `com.wbd.*`, `com.hbo.*`, `com.cbs.*`, `com.paramount.*`, `com.peacocktv.*`, `com.hulu.*`, `com.plexapp.*`, `com.spotify.*`, `tv.twitch.*`, `com.sonyliv*`, `com.zee5*`, `com.primevideo*`. Header comment: the owner switches these off themselves in TV Settings → Apps.
- [ ] **Step 3: Create `config/junk-packages.txt`** (header only: one package per line, a `# reason` comment each, seeded on our TV in Task 10) and **`config/upstream.env`** with the three pin values from Global Constraints.
- [ ] **Step 4: Update the hook** to load `streaming-apps.txt` (missing → block, like the other lists) and block with "`<pkg>` is a streaming app. Owners turn these off themselves in TV Settings."
- [ ] **Step 5: Run** `python3 -m unittest tests.test_hook -v`. Expected: all PASS.
- [ ] **Step 6: Write `fake_adb.py`, `script_cases.py` and an empty `refusal-cases.json` (`[]`).** Run `python3 -m unittest discover -s tests -v`. Expected: PASS (0 script cases).
- [ ] **Step 7: Commit** `feat: streaming-app protection, test harness with fake adb`.

### Task 2: Shared helpers and `connect`

**Files:**
- Create: `scripts/lib/tv-env.sh`, `scripts/lib/TvEnv.psm1`, `scripts/connect.sh`, `scripts/connect.ps1`
- Modify: `tests/refusal-cases.json`, `.env.example` (document optional `TV_BACKUP_DIR` and `ADB` with safe defaults)

**Interfaces:**
- Produces (Bash, sourced from `scripts/lib/tv-env.sh`; PowerShell, `Import-Module` of the `.psm1`, `Verb-Noun` equivalents):
  - `tv_load_env`: sets `REPO_ROOT`, `TV_IP`, `TV_ADB_PORT`, `TV_BACKUP_DIR` (absolute), `ADB`, `SERIAL="$TV_IP:$TV_ADB_PORT"`. Exits 3 with "Create .env from .env.example and set TV_IP" when `TV_IP` is empty.
  - `tv_matches <pkg> <listfile>`: case-insensitive glob match; strips `\r` and whitespace, skips `#` and blank lines; exits 3 if the list is missing.
  - `tv_latest_backup`: prints the newest `TV_BACKUP_DIR/*/` (lexical max) whose `packages-all.txt` is non-empty; prints nothing if none.
  - `tv_reachable`: runs `adb connect $SERIAL` then `adb -s $SERIAL get-state`. Returns 0 for device, 22 for unauthorized, 21 otherwise.
  - `tv_shell <cmd...>`: `"$ADB" -s "$SERIAL" shell <cmd...>`.
- Produces: `connect.sh` / `connect.ps1` (no args). Exit 0 with "Connected to the TV", 22 with "Accept 'Allow debugging?' on the TV", or 21 with "Can't reach the TV at <ip>".

- [ ] **Step 1: Add cases C1–C4** to `refusal-cases.json`: C1 state `device` → exit 0; C2 `unauthorized` → 22; C3 `offline` → 21; C4 `TV_IP` null and no `.env` → 3, `adb_call_count` 0 for every call. Run the tests. Expected: FAIL (scripts missing).
- [ ] **Step 2: Implement the helpers and `connect` in both languages.**
- [ ] **Step 3: Run** `python3 -m unittest discover -s tests -v`. Expected: C1–C4 PASS for every available shell.
- [ ] **Step 4: Commit** `feat: tv-env helpers and connect script (sh + ps1)`.

### Task 3: `backup`

**Files:**
- Create: `scripts/backup.sh`, `scripts/backup.ps1`
- Modify: `tests/refusal-cases.json`

**Interfaces:**
- Consumes: Task 2 helpers.
- Produces: `backup.*` (no args). Creates `TV_BACKUP_DIR/<YYYY-MM-DD_HHMMSS>/` with `packages-all.txt` (`pm list packages`), `packages-disabled.txt` (`-d`), `getprop.txt`, `settings-global.txt`, `settings-secure.txt`, `settings-system.txt` and `home-activity.txt` (resolve-activity HOME). Prints the folder path as the last stdout line. Exit 0. Work happens in a `.partial` folder that is renamed at the end. On any failure the partial folder is deleted.

- [ ] **Step 1: Add cases B1–B4**: B1 `TV_IP` unset → 3; B2 offline → 21 and no folder under `backups/`; B3 happy → 0, all 7 files present, `packages-all.txt` contains `package:com.android.systemui`; B4 `packages: []` → 20, no folder left. Run. Expected: FAIL.
- [ ] **Step 2: Implement both versions.**
- [ ] **Step 3: Run the tests.** Expected: B1–B4 PASS.
- [ ] **Step 4: Commit** `feat: backup script (sh + ps1)`.

### Task 4: `disable-one`

**Files:**
- Create: `scripts/disable-one.sh`, `scripts/disable-one.ps1`
- Modify: `tests/refusal-cases.json`

**Interfaces:**
- Consumes: Task 2 helpers. Task 3 backup layout. `installed-by-us.txt` (one package per line, written by Task 9).
- Produces: `disable-one.* <package>`. Checks run in this order, each stopping on failure:
  1. Exactly one arg matching `^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$` (else 2).
  2. `tv_load_env`, then the three lists exist (else 3).
  3. Protected → 10, streaming → 11, forbidden → 12.
  4. `tv_latest_backup` empty → 13.
  5. The package is in that backup's `packages-all.txt` or any `installed-by-us.txt` (else 14).
  6. `tv_reachable` (21/22).
  7. Already in `pm list packages -d` → exit 0, "already off", no log line.
  8. `pm disable-user --user 0 <pkg>`, once.
  9. Verify it's in `-d`. If yes, append `<pkg>\t<UTC ISO-8601>` to `<latest backup>/disabled-by-us.txt` and exit 0. If not, exit 20 "The TV refused to turn off <pkg>. Nothing was changed. Stopping."

- [ ] **Step 1: Add cases D1–D20.** The default fixture is one backup `backups/2026-11-19_100000/packages-all.txt` listing `com.tcl.ad.service`, `com.android.systemui`, `com.netflix.ninja`, and TV `state: device`.
  - D1 no args → 2. D2 two args → 2. D3 `com.foo.*` → 2. D4 `com.foo;reboot` → 2. All four: zero adb calls.
  - D5 `TV_IP` null → 3, zero adb calls.
  - D6 `com.android.systemui` → 10. D7 `com.tcl.hdmi.service` → 10. D8 `com.netflix.ninja` → 11. D9 `com.Netflix.ninja` → 11. D10 `com.tcl.factory.view` → 12. D6–D10: no `disable-user` call.
  - D11 no `backups/` → 13. D12 empty `packages-all.txt` → 13. D13 `com.unknown.app` → 14.
  - D14 `com.gathin.tvhome` listed only in `installed-by-us.txt` → 0, one `disable-user` call.
  - D15 offline → 21, no log file. D16 `refuse: [com.tcl.ad.service]` → 20, `adb_call_count {"disable-user": 1}`, no log file.
  - D17 happy `com.tcl.ad.service` → 0, exactly one `shell pm disable-user --user 0 com.tcl.ad.service`, and `disabled-by-us.txt` contains `com.tcl.ad.service`.
  - D18 already disabled → 0, zero `disable-user` calls, log unchanged.
  - D19 `protected-packages.txt` rewritten with CRLF endings → `com.android.systemui` still 10.
  - D20 two backup folders → the log is written to the newest.
- [ ] **Step 2: Run the tests.** Expected: D1–D20 FAIL.
- [ ] **Step 3: Implement both versions.**
- [ ] **Step 4: Run the tests.** Expected: all PASS in Bash and PowerShell.
- [ ] **Step 5: Run** `python3 -m unittest tests.test_hook -v` to confirm the hook still passes.
- [ ] **Step 6: Commit** `feat: disable-one enforcing TV safety rules (sh + ps1)`.

### Task 5: `restore`

**Files:**
- Create: `scripts/restore.sh`, `scripts/restore.ps1`
- Modify: `tests/refusal-cases.json`

**Interfaces:**
- Consumes: `disabled-by-us.txt`, `restored.txt`, `home-state.txt` (`stock_package=`, `stock_component=`, `ours=` lines, written by Task 9), and `disable-one.*`.
- Produces: `restore.* [--home-only | --packages-only]` (default: both, Home first).
  - **Home:** `pm enable <stock_package>`, then `cmd package set-home-activity --user 0 <stock_component>`, then run `disable-one <ours>`. If there's no `home-state.txt`, skip Home with a note.
  - **Packages:** for every backup folder (newest first), every line of `disabled-by-us.txt` not already in that folder's `restored.txt`. Run `pm enable <pkg>` once, verify it's no longer in `-d`, then append to `restored.txt`. The first refusal → exit 20 immediately.
  - No backups at all → 13.

- [ ] **Step 1: Add cases R1–R6.**
  - R1 no backups → 13.
  - R2 the log has `a.b.c` and `d.e.f` disabled → 0, one `pm enable` each, and `restored.txt` has both.
  - R3 `refuse: [a.b.c]`, log order `a.b.c`, `d.e.f` → 20, and no `pm enable d.e.f` call.
  - R4 run R2's end state again → 0, zero `pm enable` calls.
  - R5 `--home-only` with `home-state.txt` → the calls `pm enable com.google.android.apps.tv.launcherx`, `set-home-activity --user 0 com.google.android.apps.tv.launcherx/.MainActivity` and `disable-user --user 0 com.gathin.tvhome`, in that order. Exit 0.
  - R6 offline → 21.

  Run. Expected: FAIL.
- [ ] **Step 2: Implement both versions.**
- [ ] **Step 3: Run the tests.** Expected: R1–R6 PASS.
- [ ] **Step 4: Commit** `feat: restore script for packages and Home (sh + ps1)`.

### Task 6: CI for scripts and hook

**Files:**
- Create: `.github/workflows/tests.yml`

- [ ] **Step 1: Write the workflow.** On push and pull_request, with two jobs:
  - `ubuntu-latest`: `python3 -m unittest discover -s tests -v`. Runs Bash and `pwsh`, which is preinstalled.
  - `windows-latest`: the same command. Runs `powershell` 5.1.

  Pin `actions/checkout` and `actions/setup-python` to full commit SHAs, with a version comment.
- [ ] **Step 2: Push the branch** (the user runs the push). Expected: both jobs green on the PR.
- [ ] **Step 3: Commit** `ci: run script and hook tests on Linux and Windows`.

---

## Milestone B: Launcher and theme (build needs Docker, no TV)

### Task 7: Fetch tools (adb, cleanyourtv at the pin)

**Files:**
- Create: `scripts/fetch-tools.sh`, `scripts/fetch-tools.ps1`, `requirements.txt` (`Pillow==11.0.0`)
- Modify: `tests/refusal-cases.json`

**Interfaces:**
- Produces: `fetch-tools.*` (no args, idempotent):
  1. If neither `adb` nor `tools/platform-tools/adb` exists, download `https://dl.google.com/android/repository/platform-tools-latest-<darwin|linux|windows>.zip` and unzip it to `tools/`.
  2. If `vendor/cleanyourtv` is missing, `git clone --depth 1 --branch $CLEANYOURTV_TAG $CLEANYOURTV_URL vendor/cleanyourtv`.
  3. `git -C vendor/cleanyourtv rev-parse HEAD` must equal `CLEANYOURTV_COMMIT`. If not, delete the folder and exit 30.
  4. Create `vendor/cleanyourtv/tools/venv` and install `tools/requirements.txt` into it. Create `.venv` and install our `requirements.txt` into it.
- `CLEANYOURTV_URL` may be overridden by env (tests point it at a local fixture repo).

- [ ] **Step 1: Add case F1**: `CLEANYOURTV_URL` points to a temp git repo whose tag `v3.5.0` points at a different commit → 30, and `vendor/cleanyourtv` is absent afterwards. Mark the network steps (adb download, pip) as skipped when `FETCH_OFFLINE=1`. Run. Expected: FAIL.
- [ ] **Step 2: Implement both versions.** Run the tests. Expected: F1 PASS.
- [ ] **Step 3: Run it for real once** (`bash scripts/fetch-tools.sh`). Expected: `vendor/cleanyourtv` at the pinned commit, `tools/platform-tools/adb version` prints, and `git status` is clean (everything is ignored).
- [ ] **Step 4: Commit** `feat: fetch adb and pinned cleanyourtv (sh + ps1)`.

### Task 8: Theme template, photo prep and push

**Files:**
- Create: `themes/template/config.json`, `scripts/make_theme.py`, `tests/test_make_theme.py`, `scripts/push-theme.sh`, `scripts/push-theme.ps1`

**Interfaces:**
- Produces: `themes/template/config.json` with `columns: 4`, `show_greeting: true`, `greeting_name: "Your Name"`, `dock_apps` of 4 placeholder streaming packages, `clock_format: "24"`, `wallpaper: true`, `wallpaper_rotation_minutes: 30`, `wallpaper_order: "shuffle"`, `wallpaper_dim: 30`, `rows_below_dock: 0`, `fill_dock: false`. Other look-and-feel keys are left to the builder within the 1 GB budget.
- Produces: `python make_theme.py --photos DIR --name STR --apps p1,p2,p3,p4 --clock 12|24 --out DIR`. Writes `out/config.json` (the template plus the overrides) and `out/wallpapers/NN.jpg`, cover-cropped to 1920×1080. JPEG quality steps down until the file is under 300 KB. EXIF is stripped. Names match `^[0-9]{2}\.jpg$`. Exit 2 if `--apps` isn't exactly 4 or no images are found.
- Produces: `push-theme.*` runs `TV_HOST=$TV_IP vendor/cleanyourtv/tools/theme.sh user-content/theme` (`theme.ps1` on Windows). Exit 3 if vendor or the theme folder is missing. Otherwise passes through `theme.sh`'s exit code.

- [ ] **Step 1: Write tests in `test_make_theme.py`**:
  - `test_writes_config_with_overrides`: `greeting_name == "Sam"`, `dock_apps` length 4, `columns == 4`, `clock_format == "12"`.
  - `test_wallpapers_1080p_under_300kb`: a 4000×3000 noise image comes out 1920×1080 and ≤ 307200 bytes.
  - `test_exif_gps_stripped`: an input with a GPS EXIF tag comes out with no EXIF.
  - `test_rejects_three_apps`: exit 2.
  - `test_rejects_empty_photo_folder`: exit 2.

  Run. Expected: FAIL.
- [ ] **Step 2: Implement `make_theme.py` and the template.** Run. Expected: PASS.
- [ ] **Step 3: Implement `push-theme.*`.** Add case P1: vendor missing → 3.
- [ ] **Step 4: Commit** `feat: theme template, photo prep and push`.

### Task 9: Build and install the launcher

**Files:**
- Create: `scripts/build-launcher.sh`, `scripts/build-launcher.ps1`, `scripts/install-launcher.sh`, `scripts/install-launcher.ps1`
- Modify: `tests/refusal-cases.json` (cases use a stub `vendor/cleanyourtv` written via `files`, and a stub `docker` on PATH)

**Interfaces:**
- Produces: `build-launcher.*`.
  1. `docker info` must succeed (else 3, "Open Docker Desktop and wait until it says running").
  2. Create `user-content/keystore/` if needed.
  3. Run `vendor/cleanyourtv/tools/docker-build.sh` with `HOST_KEY_DIR=<absolute path to user-content/keystore>` (`docker-build.ps1` on Windows).
  4. Exit 0 when `vendor/cleanyourtv/launcher/app/build/outputs/apk/release/app-release.apk` exists.
- Produces: `install-launcher.*`.
  1. Requires a latest backup (else 13).
  2. Writes `home-state.txt` in it from `cmd package resolve-activity --brief ... HOME`: `stock_component=<line 2>`, `stock_package=<before />`, `ours=com.gathin.tvhome`.
  3. Runs `vendor/cleanyourtv/launcher/build-and-install.sh` (cwd `launcher/`) with `SKIP_BUILD=1 STOCK_LAUNCHER=none TV_HOST=$TV_IP` (`.ps1 -TvHost` on Windows).
  4. On success, adds `com.gathin.tvhome` to `installed-by-us.txt` (deduplicated). Passes through upstream's exit code.

  `HOME_KEY_SERVICE` and `INPUT_KEY_SERVICE` are passed through to upstream only when the caller sets them. The prompt sets them in Task 12 Step 2/4, never by default.

  The stock launcher is then disabled separately by the prompt through `disable-one <stock_package>`. Upstream never disables anything in our flow.

- [ ] **Step 1: Add cases.**
  - L1 build: docker stub fails → 3.
  - L2 build: the stub `docker-build.sh` records its env. `HOST_KEY_DIR` must be absolute and an existing directory under `user-content/keystore`. Exit 0.
  - L3 install: no backup → 13, and the stub was never run.
  - L4 install: the stub records `STOCK_LAUNCHER=none` and `SKIP_BUILD=1`. `home-state.txt` has all three keys and `installed-by-us.txt` has `com.gathin.tvhome`.
  - L5 install twice → `installed-by-us.txt` has one line.

  Run. Expected: FAIL.
- [ ] **Step 2: Implement both scripts in both versions.** Run. Expected: PASS.
- [ ] **Step 3: Run a real Docker build** with `bash scripts/build-launcher.sh`. Expected: the APK exists, `user-content/keystore/debug.keystore` exists, and a second build reuses the same key (`keytool -list -v` SHA-256 unchanged).
- [ ] **Step 4: Commit** `feat: build and install launcher with per-owner key (sh + ps1)`.

---

## Milestone C: On our TV (Mac; owner present; text checks only)

These tasks are guided sessions, not TDD. Each step's "Expected" is something the agent checks from text output, or the owner confirms by looking at the TV.

### Task 10: First session: identify, back up, verify lists

**Files:**
- Modify: `config/protected-packages.txt`, `config/streaming-apps.txt`, `config/junk-packages.txt`, `docs/exec-plans/tech-debt-tracker.md`
- Create: `docs/devices/tcl-<model>.md` (model, Android version, Google TV yes/no, stock launcher and setup-wizard packages, nothing personal)

- [ ] **Step 1:** The owner fills `.env` (`TV_IP`) and enables debugging. Run `bash scripts/connect.sh`. Expected: exit 0.
- [ ] **Step 2:** Run `bash scripts/backup.sh`. Expected: a backup folder exists.
- [ ] **Step 3:** Read the model from `getprop.txt` (`ro.product.model`) and find the matching `vendor/cleanyourtv/examples/tcl-*` and `docs/devices/tcl-*` entries.
- [ ] **Step 4:** Compare `packages-all.txt` with the protected and streaming globs. Run `dumpsys package <name>` for any TV-critical package the globs miss (HDMI, tuner, input, remote, keyboard) and add it. Confirm every installed streaming app matches. Expected: no TV-critical package unprotected.
- [ ] **Step 5:** Seed `junk-packages.txt` from the matching upstream `debloat.txt`, minus anything our lists protect, with a `# reason` per line. The owner reviews the list.
- [ ] **Step 6:** Close the tech-debt row (lists verified on `<model>`). Commit `chore: verify safety lists on TCL <model>`.

### Task 11: Clean-up on our TV

- [ ] **Step 1:** For each `junk-packages.txt` entry the owner approved, run `bash scripts/disable-one.sh <pkg>`. After every 3 packages, run `dumpsys activity activities | grep mResumedActivity` and ask the owner whether TV, HDMI and the remote still work. Stop on any non-zero exit other than 0.
- [ ] **Step 2:** Run `adb shell sync`, wait 15 s, reboot, then reconnect. Expected: every package in `disabled-by-us.txt` appears in `pm list packages -d`.
- [ ] **Step 3:** Owner check: every streaming app opens and plays. Expected: yes.

### Task 12: Home screen on our TV, plus an undo rehearsal

- [ ] **Step 1:** Run `make_theme.py` with the owner's photos, name and apps into `user-content/theme`. Run `bash scripts/build-launcher.sh`, then `bash scripts/install-launcher.sh`. Expected: exit 0, and Home resolves to `com.gathin.tvhome`.
- [ ] **Step 2:** Run `bash scripts/disable-one.sh <stock_package from home-state.txt>`. If the setup wizard takes Home, apply `stock_home_redirect` with `HOME_KEY_SERVICE=1` per spec §8. If Home still isn't ours, stop and run `restore --home-only`.
- [ ] **Step 3:** Run `bash scripts/push-theme.sh`, then reboot. Expected: the owner sees photos, clock, name and 4 apps, and Down shows all apps.
- [ ] **Step 4:** Ask the owner to press each remote app button, then check power-on behaviour (`logcat -b events -d | grep wm_set_resumed_activity`). Remap with `app_keys` only after explaining the key-repeat trade-off. Record the findings in `docs/devices/tcl-<model>.md`.
- [ ] **Step 5: Undo rehearsal.** Run `bash scripts/restore.sh`. Expected: stock Home back, every logged package enabled, and the owner confirms. Then re-apply Tasks 11–12 using the same scripts. Expected: the same end state.
- [ ] **Step 6:** Commit `docs: TCL <model> device notes`.

---

## Milestone D: Prompt and public face

### Task 13: `PROMPT.md`

**Files:**
- Create: `PROMPT.md`, `tests/test_prompt.py`

**Interfaces:**
- Consumes: every script above, with the exact names and exit codes from the table.

- [ ] **Step 1: Write `test_prompt.py`.** The test asserts that `PROMPT.md`:
  - names `scripts/<name>.sh` and `scripts/<name>.ps1` for `connect`, `backup`, `disable-one`, `restore`, `fetch-tools`, `build-launcher`, `install-launcher` and `push-theme`
  - contains "never uninstall" and "one package at a time"
  - contains "stop" next to "refuse"
  - names the release tag `v1.0`
  - names `restore`

  Run. Expected: FAIL.
- [ ] **Step 2: Write `PROMPT.md`** following spec §8 phases 0–7 in plain language. It covers:
  - asking before every owner choice
  - what each exit code means and what to say to the owner
  - the streaming-apps checklist (default keep all)
  - the setup-wizard rule
  - turning network debugging off at the end and confirming it
  - writing `SUMMARY.md` with the undo commands for the owner's OS
  - marking any clean-up package not on a vetted list as "my guess", with what `dumpsys` showed
  - telling the owner up front that Google TV's "Continue watching" row goes with the stock home screen
  - warning that a second "Allow debugging?" box may appear when cleanyourtv's own tools connect

  It never tells the agent to read `.env`. Run the tests. Expected: PASS.
- [ ] **Step 3:** Owner dry read: is it understandable without coding knowledge? Fix what they flag.
- [ ] **Step 4:** Commit `feat: one-paste PROMPT.md`.

### Task 14: README for visitors

**Files:**
- Modify: `README.md`
- Create: `docs/images/home-mockup.png`, `docs/images/CREDITS.md`, `scripts/dev/make_mockup.py`

- [ ] **Step 1:** Write `make_mockup.py`. It renders a 1920×1080 mock-up: a CC0 or public-domain photo (source and licence in `CREDITS.md`), the clock "10:42", "Good evening, Sam" and 4 tiles. Output PNG ≤ 500 KB.
- [ ] **Step 2: Reorder the README** per spec §11:
  1. picture
  2. Quick start (3 lines)
  3. What it does / doesn't
  4. Tested on table (our model)
  5. Before you start (the existing sections)
  6. Undo it (Mac/Linux and Windows commands)
  7. Built on, Contributing, Security, License, Disclaimer

  Status line: v1.0.
- [ ] **Step 3:** Check that every link and anchor resolves (`grep -o '](#[^)]*)'` against the headings). Commit `docs: visitor-ready README with mock-up, quick start, undo`.

### Task 15: Repo extras and placeholder docs

**Files:**
- Create: `.github/ISSUE_TEMPLATE/tv-problem.yml`, `tested-on-my-tv.yml`, `feature-request.yml`, `config.yml` (blank issues off), `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1, contact via GitHub private reporting), `docs/references/cleanyourtv.md`
- Fill: `ARCHITECTURE.md`, `docs/design-docs/core-beliefs.md`, `docs/PRODUCT_SENSE.md`, `docs/FRONTEND.md`, `docs/RELIABILITY.md`, `docs/product-specs/new-user-onboarding.md`, `docs/product-specs/index.md`, `docs/DESIGN.md`, `docs/PLANS.md`, `docs/QUALITY_SCORE.md`
- Delete: `docs/generated/db-schema.md`, `docs/references/nixpacks-llms.txt`, `docs/references/uv-llms.txt`, `docs/references/design-system-reference-llms.txt`
- Modify: `CLAUDE.md` (TOC: removals, new docs, `streaming-apps.txt` in the TV-safety rule, Status), `docs/SECURITY.md` (streaming list, scripts as the enforcement layer)

- [ ] **Step 1:** Write the issue forms. `tv-problem.yml` fields: model, Android version, Google TV?, OS of computer, which step, what happened. The top text warns: "Don't paste your IP address, serial number, photos or backup files."
- [ ] **Step 2:** Fill or delete each doc per spec §12. Each filled doc is short and replaces the placeholder text. Check with a grep for the placeholder marker. Expected: no output.
- [ ] **Step 3:** Update the CLAUDE.md TOC and run `grep -o '](docs/[^)]*)' CLAUDE.md`. Expected: every linked file exists.
- [ ] **Step 4:** Commit `docs: repo extras, fill or remove placeholder docs`.
- [ ] **Step 5 (owner, on GitHub):** Set the About description and the topics `android-tv`, `google-tv`, `debloat`, `launcher`, `tcl`, `ai-agent`. Turn on secret scanning and push protection.

### Task 16: Acceptance run and v1.0

- [ ] **Step 1:** Run `restore.sh` on our TV to get back to stock.
- [ ] **Step 2:** Make a fresh clone into a new folder, open it in Claude Code, and paste `PROMPT.md` as a non-coder would. Expected: it reaches the same end state as Task 12, with every owner choice asked, network debugging off at the end, and `SUMMARY.md` written.
- [ ] **Step 3:** Fix anything the run exposed (each fix goes back through its task's tests).
- [ ] **Step 4:** Add the Tested-on row with the date. Merge to `main`. The owner tags `v1.0` and creates the GitHub release with notes: what it does, tested TVs, how to undo.
- [ ] **Step 5:** Move this plan to `docs/exec-plans/completed/` and run the CLAUDE.md doc-update rule.

**Windows note:** CI covers the PowerShell scripts in Tasks 1–9. A Windows-PC run on a real TV is a contributor follow-up after v1.0, tracked as a row in `tech-debt-tracker.md` in Task 16.
