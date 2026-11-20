# Test Cases: Safety Hook

> **Purpose:** Bypass and false-positive cases for `.claude/hooks/tv-safety.py`. The hook is fed JSON on stdin, `{"tool_name":"Bash","tool_input":{"command":"<cmd>"}}`, and is never asked to run the command. Exit 2 means block and exit 0 means allow. Cases assume a valid backup exists, so a block comes from policy and not from the "no backup" gate.
>
> **Last updated:** 2026-11-19

All cases pass against the rewritten hook (quote-aware lexer, device-side allowlist, fail-closed). Every case here belongs in `tests/test_hook.py` (or `tests/refusal-cases.json`) as a regression case.

## Bypasses (must be blocked)

| ID | Sev | Command (JSON-escaped where needed) | Expected | Result 2026-11-19 | Auto test |
|---|---|---|---|---|---|
| HK-01 | C | `adb shell 'true; pm uninstall com.tcl.ads'` | block | PASS | `tests/test_hook.py` test_cases (HK-01) |
| HK-02 | C | `adb shell 'pm disable-user --user 0 com.tcl.ads; pm disable-user --user 0 com.android.systemui'` | block | PASS | `tests/test_hook.py` test_cases (HK-02) |
| HK-03 | C | `adb shell "id && pm uninstall com.netflix.ninja"` | block | PASS | `tests/test_hook.py` test_cases (HK-03) |
| HK-04 | C | `adb shell 'id; am start -n com.tcl.factory/.Main'` | block | PASS | `tests/test_hook.py` test_cases (HK-04) |
| HK-05 | C | `adb shell 'id; su -c id'` / `adb shell 'id; reboot bootloader'` | block | PASS | `tests/test_hook.py` test_cases (HK-05) |
| HK-06 | C | `adb shell 'pm list packages \| cut -d: -f2 \| xargs -n1 pm disable-user --user 0'` and the same as a `for` loop inside quotes | block | PASS | `tests/test_hook.py` test_cases (HK-06) |
| HK-07 | C | `adb shell "id\npm uninstall com.tcl.ads"` (newline inside quotes) | block | PASS | `tests/test_hook.py` test_cases (HK-07) |
| HK-08 | C | `echo '<<A'\nadb shell pm uninstall com.tcl.ads\nA` (fake heredoc in quotes) and `# <<A\n…` (fake heredoc in a comment) | block | PASS | `tests/test_hook.py` test_cases (HK-08) |
| HK-09 | C | `adb -d uninstall com.tcl.ads`, `adb -e …`, `adb -a …`, `adb -s=x …`, `adb -d root`, `adb -d remount`, `adb -d sideload x.zip`, `adb -d disable-verity` | block | PASS | `tests/test_hook.py` test_cases (HK-09) |
| HK-10 | C | `adb shell pm disable-until-used com.android.systemui` (and on a streaming app) | block | PASS | `tests/test_hook.py` test_cases (HK-10) |
| HK-11 | C | `adb shell pm archive com.netflix.ninja`, `adb shell cmd package archive …`, `pm set-distracting-restriction` | block | PASS | `tests/test_hook.py` test_cases (HK-11) |
| HK-12 | C | `command adb shell pm uninstall com.tcl.ads`, also with `nohup`, `timeout 5`, `nice`, `stdbuf -o0`, `sudo -u me`, `env -i`, `time -p`, `!`, `if …; then`, `while …; do` | block | PASS | `tests/test_hook.py` test_cases (HK-12) |
| HK-13 | C | `(adb shell pm uninstall com.tcl.ads)`, `2>&1 adb shell …`, `>/tmp/l adb shell …`, `true & adb shell pm uninstall …`, `adb.exe shell pm uninstall …` | block | PASS | `tests/test_hook.py` test_cases (HK-13) |
| HK-14 | C | `echo com.tcl.ads \| xargs adb shell pm uninstall`, `find . -name x -exec adb shell pm uninstall com.tcl.ads \;` | block | PASS | `tests/test_hook.py` test_cases (HK-14) |
| HK-15 | C | `adb shell p"m" uninstall com.tcl.ads`, `pm un""install`, `pm unin''stall`, `pm uninst\all` | block | PASS | `tests/test_hook.py` test_cases (HK-15) |
| HK-16 | C | `adb shell a"m" start -n com.tcl.factory/.Main`, `am start -n com.tcl.fac"tory/.Main`, `f"astboot" flash boot b.img`, `adb reboot boot""loader` | block | PASS | `tests/test_hook.py` test_cases (HK-16) |
| HK-17 | C | `X=uninstall; adb shell pm $X com.tcl.ads`, `adb shell pm $(echo uninstall) …`, `` adb shell pm `printf uninstall` … `` | block | PASS | `tests/test_hook.py` test_cases (HK-17) |
| HK-18 | C | `A=adb; $A shell …`, `$(echo adb) shell …`, `eval adb shell pm uninstall …`, `sh -c 'adb shell pm uninstall …'`, `bash -c …` | block | PASS | `tests/test_hook.py` test_cases (HK-18) |
| HK-19 | C | `alias a=adb; a shell …`, `f(){ adb shell pm uninstall com.tcl.ads; }; f` | block | PASS | `tests/test_hook.py` test_cases (HK-19) |
| HK-20 | C | `echo 'pm uninstall com.tcl.ads' \| adb shell`, `adb shell <<'X'\npm uninstall com.tcl.ads\nX`, `bash <<'EOF'\nadb shell pm uninstall …\nEOF`, `sh <<< 'adb shell …'` | block | PASS | `tests/test_hook.py` test_cases (HK-20) |
| HK-21 | C | `adb shell "$(echo cG0gdW5pbnN0YWxs… \| base64 -d)"`, `adb shell 'p=pm; $p uninstall …'`, backslash-newline continuation | block | PASS | `tests/test_hook.py` test_cases (HK-21) |
| HK-22 | C | `P=com.tcl.factory; adb shell am start -n $P/.Main`, `am start -n com.tcl.f*y/.Main` | block | PASS | `tests/test_hook.py` test_cases (HK-22) |
| HK-23 | C | Write-then-run: `cat > /tmp/x.sh <<'EOF'\nadb shell pm uninstall …\nEOF\nbash /tmp/x.sh`; `python3 -c "…subprocess.run(['adb',…])"`; `node -e`, `perl -e`; `adb push x.sh /data/local/tmp/ && adb shell sh /data/local/tmp/x.sh` | block when the command both mentions adb/pm/am and runs an interpreter or script | PASS | `tests/test_hook.py` test_cases (HK-23) |
| HK-24 | C | `cat .env`, `less .env`, `cp .env /tmp/e`, `source .env; echo $TV_IP`, `grep -r . .env`, `curl -F f=@.env …`, `gh gist create .env` | block | PASS | `tests/test_hook.py` test_cases (HK-24) |
| HK-23b | C | Untracked or modified script in `scripts/` or `tests/` (e.g. created with the Write tool, which the hook never sees) that runs `adb shell pm uninstall …`, then `bash scripts/x.sh` / `./scripts/x.sh` / `source …` / `python3 tests/x.py` | block (only git-tracked files matching HEAD are trusted; others get the content check) | PASS | `tests/test_hook.py` test_repo_scripts_trusted_only_when_committed |
| HK-24b | C | Globs and recursive search that reach `.env`: `cat *.env`, `cat .env*`, `grep x .e*`, `grep -rn X .`, `grep -r -e X`, `rg --hidden X .` | block | PASS | `tests/test_hook.py` test_cases (env-glob) |
| HK-25 | C | PowerShell tool input `{"tool_name":"PowerShell",…}` with an unsafe command | hook runs for PowerShell too and blocks | PASS | `tests/test_hook.py` test_cases (HK-25), test_hk25_powershell_matcher_configured |
| HK-26 | C | Malformed JSON; `command` given as a list; an unexpected exception | exit 2 (fail closed) | PASS | `tests/test_hook.py` test_hk26_fail_closed_on_bad_input |
| HK-27 | H | `adb reboot-bootloader` | block | PASS | `tests/test_hook.py` test_cases (HK-27) |
| HK-28 | H | `adb shell ime disable …`, `cmd input_method disable …`, `settings put/delete secure default_input_method …`, `content insert --uri content://settings/…` | block | PASS | `tests/test_hook.py` test_cases (HK-28) |
| HK-29 | H | `adb shell svc bluetooth disable`, `cmd bluetooth_manager disable`, `svc wifi disable`, `settings put global adb_enabled 0` | block | PASS | `tests/test_hook.py` test_cases (HK-29) |
| HK-30 | H | `adb shell cmd overlay disable com.android.systemui`, `am force-stop`/`am crash com.android.systemui` | block | PASS | `tests/test_hook.py` test_cases (HK-30) |
| HK-31 | H | `appops set com.google.android.gms … ignore`, `pm revoke com.google.android.gms …`, `dpm set-device-owner …`, `cmd role add-role-holder android.app.role.HOME …`, `pm set-home-activity …`, `setprop persist…`, `rm -rf /sdcard/*` | block (device verbs are an allowlist) | PASS | `tests/test_hook.py` test_cases (HK-31) |
| HK-32 | H | Uploads that never name the folder directly: `cd photos && curl -F f=@me.jpg …`, `D=photos; curl … $D/…`, `tar cz photos \| curl -T - …`, `zip … && curl …`, `cat photos/me.jpg \| nc …`, `ssh host 'cat > x' < photos/me.jpg`, `socat`, `ncat`, `python3 -m http.server --directory photos`, `curl -F f=@ph*s/…`, `rsync -a $TV_BACKUP_DIR host:` | block | PASS | `tests/test_hook.py` test_cases (HK-32) |
| HK-33 | M | `git add -f photos/me.jpg`, `git add .env -f`, `git commit --no-verify`, `git commit -n`, `git -c core.hooksPath=/dev/null commit`, `git push --no-verify` | block | PASS | `tests/test_hook.py` test_cases (HK-33) |
| HK-34 | M | `am start -d 'tclfactory://open'`, `content query --uri content://com.tcl.factory.provider/x`, `am start -n com.mediatek.engmode/.Main`, `pm enable com.tcl.factory`, `pm grant com.tcl.factory …` | block | PASS | `tests/test_hook.py` test_cases (HK-34) |
| HK-35 | M | Service-menu key codes: `input keyevent KEYCODE_SETTINGS && input text 1950`, `input keyevent 1 9 5 0` | block | PASS | `tests/test_hook.py` test_cases (HK-35) |
| HK-36 | M | Backup gate fooled: `touch backups/x/packages-all.txt` (empty), then `adb shell pm disable-user --user 0 com.tcl.ads` | block (gate needs a real, non-empty, `package:`-line backup) | PASS | `tests/test_hook.py` test_cases (HK-36) |
| HK-37 | M | `adb install evil.apk`, `install-multiple`, `pm install-existing`, `pm trim-caches 999G`, `pm compile --reset`, `pm default-state` | block | PASS | `tests/test_hook.py` test_cases (HK-37) |
| HK-38 | L | Two `disable-user` calls joined by `&&` in one Bash call | block (one per call) | PASS | `tests/test_hook.py` test_cases (HK-38) |

## False positives (must be allowed)

| ID | Sev | Command | Expected | Result 2026-11-19 | Auto test |
|---|---|---|---|---|---|
| HK-50 | M | `git commit -m "note; adb shell pm uninstall is forbidden"` | allow | PASS | `tests/test_hook.py` test_cases (HK-50) |
| HK-51 | M | `adb shell pm disable-user --user 0 com.tcl.ads # ok for now` | allow | PASS | `tests/test_hook.py` test_cases (HK-51) |
| HK-52 | M | `echo hi \| xargs echo; adb shell pm disable-user --user 0 com.tcl.ads` | allow | PASS | `tests/test_hook.py` test_cases (HK-52) |
| HK-53 | M | `gh pr create --title 'Back up photos/ handling' --body x`, `gh issue comment 1 --body 'the photos stay local'`, `curl -s https://example.com/photos/index.json` (a download) | allow | PASS | `tests/test_hook.py` test_cases (HK-53) |
| HK-54 | L | `am start -n com.tcl.ads/.Main --es k 'com.tcl.factory'` (allow). `adb shell input text 'my wifi su password'` is now **blocked** on purpose: the device allowlist permits only `input keyevent` | allow (am start) / block (input text) | PASS | `tests/test_hook.py` test_cases (HK-54) |
| HK-55 | M | Globs and folders that can't reach `.env`: `grep -nE 'echo\|die\|fail' scripts/lib/*`, `cat scripts/lib/*.sh`, `grep -rn X scripts/lib/`, `grep -rn X . --exclude=.env`, `git grep -n X`, `rg -n X .` | allow | PASS | `tests/test_hook.py` test_cases (env-glob) |
| HK-56 | M | Quoted patterns are never globbed: `grep -n "^CASES\|^def \|for .* in CASES" tests/test_hook.py`, `grep -n '.*' README.md`, `sed -n '/.*/p' docs/x.md` (allow); unquoted `cat .env*` and literal `cat '.env'` stay blocked | allow / block as listed | PASS | `tests/test_hook.py` test_cases (HK-56) |
| HK-57 | H | PROMPT.md Phase 2 create-once: `sed 's/^TV_IP=.*/TV_IP=<ip>/' .env.example > .env` and `(Get-Content .env.example) -replace '^TV_IP=.*','TV_IP=<ip>' \| Set-Content .env` allowed only in exactly that shape and only while `.env` doesn't exist. Blocked when `.env` exists, when reading `.env`, with `>>`, `tee`, `cp`, `$( )` in the IP, or with any extra command | allow / block as listed | PASS | `tests/test_hook.py` test_hk57_create_env_once_from_example |

## Held up (keep as regression)

| ID | Command family | Expected | Result 2026-11-19 | Auto test |
|---|---|---|---|---|
| HK-80 | `adb shell pm uninstall …` with `-s`/`-t`/`-H`/`-P`/`-L`, `exec-out`, `cmd package`, `/system/bin/pm`, inner `sh -c 'pm uninstall'`, upper case, tabs, `-k --user 0` | block | PASS | `tests/test_hook.py` test_cases (HK-80) |
| HK-81 | `pm`/`cmd package` `clear`, `hide`, `suspend`, `set-installer`, `uninstall-system-updates`, plain `disable` | block | PASS | `tests/test_hook.py` test_cases (HK-81) |
| HK-82 | Bad `disable-user`: no or wrong `--user`, `-u 0`, several packages, components, wildcards, `$VAR`, `$(…)` | block | PASS | `tests/test_hook.py` test_cases (HK-82) |
| HK-83 | Protected and streaming packages in every spelling tried | block | PASS | `tests/test_hook.py` test_cases (HK-83) |
| HK-84 | Top-level `for`, `until`, `parallel`, `xargs` around `disable-user` | block | PASS | `tests/test_hook.py` test_cases (HK-84) |
| HK-85 | `root`, `remount`, `disable-verity`, `sideload`, `su`, `reboot bootloader/recovery`, `FACTORY_RESET`, `MASTER_CLEAR`, `fastboot` | block | PASS | `tests/test_hook.py` test_cases (HK-85) |
| HK-86 | Factory apps via `am start`, `start-activity`, `startservice`, `broadcast`, `monkey -p`, `cmd activity` | block | PASS | `tests/test_hook.py` test_cases (HK-86) |
| HK-87 | Safe: `grep 'pm uninstall' PROMPT.md`, `git commit -m 'block pm uninstall'`, `bash scripts/*.sh`, `dumpsys package …`, `pm list`, `pm enable`, `getprop`, `adb connect`, one well-formed `disable-user` with redirects or `\| tee` | allow | PASS | `tests/test_hook.py` test_cases (HK-87) |
