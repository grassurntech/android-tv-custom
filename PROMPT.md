# Clean up your Android TV and give it your own home screen

This prompt belongs to release **v1.0** of this project. Copy everything from the line below to the end, and
paste it into an AI coding tool (Claude Code, Cursor, Codex, Antigravity or similar) on a computer that is on
the same Wi-Fi as your TV.

---

## For you, the TV owner

**What this does.** Your AI tool works on your TV step by step, and asks you before every choice that is yours.

- It switches off the ads, trackers and junk apps that came with the TV.
- It gives the TV a new home screen: your photos in the background, a greeting with your name, a clock, and
  your four favourite apps. Press Down on the remote to see every other app.

**What it never does.**

- It never deletes an app. It only switches apps off, so everything can be switched back on.
- It never touches the parts that make your TV a TV: HDMI, the tuner, the remote, Bluetooth, the keyboard,
  the Play Store and Settings.
- It never switches off your streaming apps (Netflix, Prime Video, Disney+, YouTube and the rest).
- Your photos, your backup and your settings file stay on your computer. Nothing is uploaded.

**Good to know before you start.**

- Google TV's "Continue watching" and recommendation rows belong to the old home screen, so they go with it.
  Each app's own "continue watching" inside the app still works.
- Ads inside streaming apps (YouTube, Prime Video and others) can't be removed. Those come from the apps.
- It works on Android TV and Google TV sets (TCL, Sony, Hisense, Philips, Xiaomi and others). It does not work on
  Samsung, LG, Roku or Fire TV.
- You'll need about an hour, the TV remote, and Docker Desktop installed on the computer.

---

## Instructions for the AI agent

You are helping someone who does not write code. Follow this prompt exactly, phase by phase.

### How to talk to the owner

- Lines that start with **Say:** are what you tell the owner. Put them in your own words if you like, but keep
  them short, warm and free of jargon. Everything else is an instruction for you.
- Never show the owner a command and ask them to understand it. Tell them what is happening and why.
- Ask before every choice that belongs to the owner. Never guess what they watch or use.
- At the end of every phase, give a plain summary of what happened, ask "Shall I go on?" and wait for a clear
  yes before you start the next phase.

### Rules you never break

1. **Change the TV only through this project's scripts** (the table below). Never type `pm disable-user`,
   `pm uninstall`, `pm clear`, `pm hide`, `pm suspend` or `pm enable` yourself. Never use root or
   fastboot, and never flash anything. Never install or start any app on the TV yourself.
2. **Never uninstall anything.** Apps are switched off, one package at a time, only with `disable-one`.
3. **Back up first.** No change to the TV before Phase 4 has made a backup.
4. **Never open a factory or service menu app, not even to look.** On some TVs, opening one flips a hidden
   factory switch that breaks the remote and inputs and can't be undone from a computer. To learn what a
   package is, read `dumpsys package <name>` instead. It never starts the app.
5. **If the TV refuses something, stop.** Say what happened in plain words and point to the undo. Never retry in a
   loop, and never look for another way to do the same thing.
6. **Never read `.env`.** The scripts read it themselves. You may create it once (Phase 2), never open it.
7. **Privacy.** Photos, backups, screenshots, `.env` and `user-content/` stay on this computer. Never upload them,
   never paste their contents anywhere online, and never commit them to git.
8. If a safety hook or guard on this computer blocks a command, do not work around it. Stop and tell the owner.

### Read-only commands you may run

Some checks need `adb` directly. Use `tools/platform-tools/adb` (Windows: `tools\platform-tools\adb.exe`) if it
exists, otherwise `adb`. Always pass `-s <TV IP>:<port>` with the IP and port the owner gave you (port 5555
unless they said otherwise). These are the only direct adb commands you may run:

- `shell getprop <key>` (model, Android version and similar; never quote serial numbers or IDs to anyone)
- `shell pm list packages` and `shell pm list packages -d` (lists only)
- `shell dumpsys package <name>`, `shell dumpsys activity activities`, `shell dumpsys wifi`
- `shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME`
- `shell logcat -b events -d`, `shell settings get <namespace> <key>`, `shell getevent -lt` (only while the
  owner presses a button, for at most 15 seconds)
- `shell sync` and `reboot`, only at the points this prompt says. Never `reboot bootloader` or `reboot recovery`.

Filter long output yourself on the computer. Never chain several TV commands into one.

### How to run the scripts

Run every script from the project folder. On a Mac or Linux use the left column. On Windows use the right one.

| Script | Mac / Linux | Windows |
|---|---|---|
| Download the tools | `bash scripts/fetch-tools.sh` | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fetch-tools.ps1` |
| Connect to the TV | `bash scripts/connect.sh` | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\connect.ps1` |
| Back up | `bash scripts/backup.sh` | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\backup.ps1` |
| Switch off one package | `bash scripts/disable-one.sh <package>` | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\disable-one.ps1 <package>` |
| Build the home screen app | `bash scripts/build-launcher.sh` | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-launcher.ps1` |
| Install the home screen app | `bash scripts/install-launcher.sh` | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-launcher.ps1` |
| Send the photos and settings | `bash scripts/push-theme.sh` | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\push-theme.ps1` |
| Undo everything | `bash scripts/restore.sh` | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\restore.ps1` |

`restore` also takes one option: `bash scripts/restore.sh --home-only` puts back only the original home screen,
`bash scripts/restore.sh --packages-only` only the apps (Windows: add the same option after `restore.ps1`). The photo tool is
`.venv/bin/python scripts/make_theme.py` (Windows: `.venv\Scripts\python scripts\make_theme.py`).

`install-launcher` reads two optional switches from the environment: `HOME_KEY_SERVICE=1` and
`INPUT_KEY_SERVICE=1`. On a Mac or Linux, put them in front: `HOME_KEY_SERVICE=1 bash scripts/install-launcher.sh`.
On Windows, set `$env:HOME_KEY_SERVICE='1'` in PowerShell, run the usual line, then `Remove-Item Env:HOME_KEY_SERVICE`.
Android switches these helpers off at every reinstall, so pass every switch that is on, every time you run it.

### What the exit codes mean

Every script ends with a number. Read it after every run, and act on it before doing anything else.

| Code | What it means | What you do and say |
|---|---|---|
| 0 | Done, or there was nothing to do | Carry on. |
| 1 | `build-launcher` made no app, or `push-theme` could not send the photos | Stop. **Say:** "That step didn't work. Nothing on the TV changed because of it." Show the owner the script's last message in plain words. |
| 2 | The command was typed wrong, or `make_theme` found no usable photo, or (`push-theme` only) cleanyourtv's theme tool refused before sending anything | Nothing changed. Check the command against this prompt and run the corrected one once. If it says 2 again, stop. **Say:** "I made a mistake typing that. Nothing on the TV changed." |
| 3 | Something on the computer isn't set up: no `.env` or `TV_IP`, Docker not running, tools not downloaded, or an undo note that can't be saved | Nothing changed. Tell the owner what is missing in plain words (the script's message names it), help them fix it, then run the script once more. |
| 10 | The package is protected: it keeps the TV working as a TV | Nothing changed. Take it off the list and go on. **Say:** "The TV needs that one, so I left it alone." |
| 11 | The package is a streaming app | Nothing changed. Take it off the list and go on. **Say:** "That's a streaming app, so I left it. You can switch it off yourself in Settings → Apps if you never use it." |
| 12 | The package is a factory or service app | Nothing changed. Take it off the list, never touch it in any other way, and go on. **Say:** "That's a factory tool. It's safest left alone." |
| 13 | There is no backup yet | Nothing changed. Go back to Phase 4. |
| 14 | The package isn't in the backup and wasn't installed by us (it may not exist on this TV) | Nothing changed. Take it off the list and go on. |
| 20 | The TV refused, or didn't confirm the change | Stop. **Say:** "The TV said no to that step, so I've stopped there. Nothing is broken, and everything I did so far can be undone." Never retry. Offer the undo (see "If something goes wrong"). |
| 20 (special) | `disable-one` says the TV DID turn the app off, but the undo log could not be written | The app is off, but the undo script won't know about it. Stop. Copy the package name and the script's whole message into `SUMMARY.md` (Phase 7). **Say:** "The TV switched that app off, but I couldn't save my undo note for it. I've written it down for you separately." |
| 21 | The TV can't be reached | **Say:** "I can't reach the TV. Is it switched on, on the same Wi-Fi as this computer, with debugging still on?" After the owner says yes, run `connect` once. If it still says 21, stop. |
| 22 | The TV hasn't allowed this computer yet | **Say:** "Look at the TV. There's a box asking 'Allow debugging?'. Tick 'Always allow from this computer' and choose Allow." Then run `connect` once. If it still says 22, stop. |
| 30 | The downloaded cleanyourtv doesn't match the tested version, so it was deleted | Stop. Never work around it. **Say:** "The download didn't match the version we tested, so I didn't use it. Nothing on the TV changed. Let's try again later." |
| Any other | A cleanyourtv tool (inside `build-launcher`, `install-launcher` or `push-theme`) failed with its own code | Stop. Explain its last message in plain words. If it mentions `INSTALL_FAILED_VERIFICATION_FAILURE` or `INSTALL_FAILED_OLDER_SDK`, this TV won't accept the new home screen: keep the clean-up, skip the rest of Phase 6. |

---

## Phase 0: Get the project

1. Check whether you are inside a copy of this project: `PROMPT.md`, `scripts/disable-one.sh` and
   `config/protected-packages.txt` must all exist in the current folder.
2. If they don't, ask the owner whether they have their own copy (a fork) of this project on GitHub. Clone
   theirs, or the main project `https://github.com/grassurntech/android-tv-custom` if they have none, at
   the release tag: `git clone --branch v1.0 <url>`. If that tag doesn't exist, clone without `--branch`
   and tell the owner which version they got.
3. **Say:** "I've downloaded the project into a folder called `android-tv-custom`. Please close me and open me
   again inside that folder, then paste this prompt again." Stop here until they do. Many AI tools only load
   the project's safety settings when they start inside its folder.

**End of phase:** summarise in one sentence and wait for yes.

## Phase 1: Check the computer

1. First, set expectations. **Say:** "Two things to know before we start. Google TV's 'Continue watching' row
   belongs to the old home screen, so it goes with it (each app still has its own). And ads inside streaming
   apps like YouTube can't be removed, because they come from the apps. Everything else I do can be undone."
2. Check, one at a time: Git (`git --version`), Python 3 (`python3 --version`, on Windows `py -3 --version`),
   Docker (`docker info` must answer without an error), and at least 10 GB of free disk space.
3. For anything missing, walk the owner through installing it in plain steps: Git from git-scm.com, Python from
   python.org, Docker Desktop from docker.com. For Docker, **say:** "Open Docker Desktop and wait until it says
   it's running."
4. Run `fetch-tools`. It downloads Google's `adb` tool and the cleanyourtv home screen at the tested version, and
   sets up Python. It changes nothing on the TV.

**End of phase:** **Say:** "Your computer is ready. Next we'll connect to the TV." Wait for yes.

## Phase 2: Connect to the TV

1. Ask what the TV is (brand and model, from the back label or Settings → System → About). If it is Samsung, LG,
   Roku or Fire TV, stop: **Say:** "Sorry, this only works on Android TV and Google TV sets."
2. Ask whether anything is plugged into the TV's USB ports, and whether its internet comes through a USB network
   adapter. **Say:** "Some TVs cut power to their USB ports while debugging is on, so a USB drive or adapter may
   stop working until we finish. Let's do the whole job in one sitting."
3. Guide the owner through turning on debugging, one step at a time, and wait after each:
   - **Say:** "On the TV, open Settings → System → About. Scroll to 'Android TV OS build' (or just 'Build') and
     press OK on it 7 times, until it says you're a developer."
   - **Say:** "Go back to Settings → System → Developer options. Turn on USB debugging, and also Network
     debugging or ADB debugging if you see it."
   - **Say:** "Now open Settings → Network & Internet, choose your Wi-Fi, and tell me the IP address. It looks
     like 192.168.1.23."
4. Set up `.env` without opening it. Check only whether it exists (`test -e .env`, on Windows `Test-Path .env`).
   - If it doesn't exist, offer two ways and let the owner pick. Either they copy `.env.example` to `.env` and
     change the `TV_IP=` line to their IP themselves, or you create it once from `.env.example` with only that
     line changed. Mac/Linux: `sed 's/^TV_IP=.*/TV_IP=<ip>/' .env.example > .env`. Windows:
     `(Get-Content .env.example) -replace '^TV_IP=.*','TV_IP=<ip>' | Set-Content .env`.
   - If it exists already, never overwrite it and never open it. Ask the owner to check its `TV_IP=` line.
5. **Say:** "Keep looking at the TV. A box saying 'Allow debugging?' will appear. Tick 'Always allow from this
   computer' and choose Allow." Then run `connect`. Expect 22 the first time. After the owner allows it, run it
   once more.
6. If it keeps saying 21 and Developer options only offers "Wireless debugging" with a pairing code, stop.
   **Say:** "This TV uses a newer kind of connection that this version doesn't handle yet. Nothing was changed."

**End of phase:** **Say:** "We're connected. Next I'll find out exactly which TV this is. That only reads
information." Wait for yes.

## Phase 3: Identify the TV

Read only. Change nothing.

1. Read `getprop` for `ro.product.manufacturer`, `ro.product.model`, `ro.product.device`,
   `ro.build.version.release` and `ro.build.version.sdk`.
2. Work out the TV type from `pm list packages`: `com.google.android.apps.tv.launcherx` means Google TV,
   `com.google.android.tvlauncher` means the older Android TV. Read which app is Home now with the
   `resolve-activity` command.
3. If `ro.build.version.sdk` is below 26, the new home screen can't be installed. **Say:** "Your TV is too old
   for the new home screen, but I can still clean it up." Skip Phase 6 later.
4. Look for notes on this exact model in cleanyourtv's folders: the first lines of
   `vendor/cleanyourtv/examples/*/debloat.txt` name the model and device, and `vendor/cleanyourtv/docs/devices/`
   has extra notes. Read every matching file fully, including what it says about Home, the setup wizard and the
   remote's buttons. If nothing matches the exact model, say so. Never use a list from a different model as if
   it were vetted.
5. If any package starts with `com.cvte.`, this TV uses a CVTE board: keep its own launcher switched on in
   Phase 6 unless the matching example for that exact board switches it off, and never turn on a remote-button
   helper in the same step as the Home change.

**End of phase:** **Say:** "Your TV is a <brand model>, running <Google TV / Android TV> <version>.
<I found tested notes for it / There are no tested notes for this exact model, so I'll be extra careful.>"
Wait for yes.

## Phase 4: Back up

1. **Say:** "Before I change anything, I'll save a full record of how your TV is set up now, on this computer.
   That's what lets us undo everything later."
2. Run `backup`. Its last line is the backup folder, `backups/<YYYY-MM-DD_HHMMSS>/`. Remember it: this prompt
   calls it the backup folder. Check that `packages-all.txt` in it is not empty.
3. Run `backup` only once. Later steps write their undo notes into this same folder.

**End of phase:** **Say:** "Your TV's setup is saved in <folder>. Next I'll suggest what to switch off. I won't
switch anything off until you say yes to the list." Wait for yes.

## Phase 5: Clean up

1. Build a proposed list from vetted sources first:
   - lines in `config/junk-packages.txt` (the part before `#`), and
   - the uncommented lines of the matching `vendor/cleanyourtv/examples/<model>/debloat.txt`.
   Keep only packages that are in the backup's `packages-all.txt`. Commented-out lines in `debloat.txt` are
   things upstream chose to keep: leave them out.
2. Remove from the list anything that matches `config/protected-packages.txt`, `config/streaming-apps.txt` or
   `config/forbidden-packages.txt` (glob patterns, any case), the setup wizard, the TV's current Home app (that
   comes in Phase 6), and firmware update services.
3. You may add a package from neither source only after reading `dumpsys package <name>`. Mark each one
   **"my guess"** and say in one plain line what `dumpsys` showed (for example: "my guess: it only runs a
   background service called AdReporter and has no screen"). If you can't tell what it does, leave it out.
4. Show the list in plain words, grouped as: tracking and data collection, ads and recommendations, background
   extras, apps that came preinstalled. For each, give the package name and what it does in a few words.
   Then add a "Kept" group with every streaming app found. **Say:** "I'm leaving all your streaming apps alone.
   If there's one you never use, you can switch it off yourself later in Settings → Apps."
5. **Say:** "Here's what I'd switch off. Everything can be switched back on. Tell me anything you want to keep,
   or say yes to go ahead." Remove whatever the owner wants kept. Never add anything they didn't see.
6. Switch off one package at a time: run `disable-one <package>` once per package, and read the exit code each
   time (see the table).
7. After every 3 packages, run `connect` to check the TV still answers, then ask: **Say:** "Quick check: does the
   TV still show a picture, do your HDMI inputs still work, and does the remote still work?" If anything is
   wrong, stop and go to "If something goes wrong".
8. When the list is done, wait 15 seconds (Android saves these changes about ten seconds later), run
   `shell sync`, then **say:** "I'm restarting the TV once to check everything sticks." Run `reboot`. When the
   owner says the TV is back, run `connect`.
9. Compare `pm list packages -d` with `disabled-by-us.txt` in the backup folder. Some TVs switch a few apps back
   on at every start. Note any that came back for the summary. Never switch them off again.

**End of phase:** **Say:** "I switched off <n> things. <Any that came back.> Next is your new home screen."
Wait for yes.

## Phase 6: Build the home screen

Skip this phase if Phase 3 found the TV too old.

**6.1 Ask the owner, one question at a time:**

- Which folder on this computer holds the photos they want in the background (landscape photos look best).
- The name for the greeting ("Good evening, <name>").
- Their four favourite apps, in order. Offer the installed streaming apps by name, and turn their choices into
  package names from `packages-all.txt`.
- A 12-hour clock (3:45 PM) or a 24-hour clock (15:45).

On a Mac, iPhone photos are often HEIC files, which the photo tool may skip. **Say:** "If your photos came from
an iPhone, export them from the Photos app as JPEG first, or I can convert copies for you." To convert, write
the copies into `photos/` (it stays on this computer): `sips -s format jpeg <photo.heic> --out photos/<name>.jpg`.
On Windows, ask the owner to export them as JPEG.

**6.2 Make the theme.**
`.venv/bin/python scripts/make_theme.py --photos "<folder>" --name "<name>" --apps <p1>,<p2>,<p3>,<p4> --clock <12|24> --out user-content/theme`
(Windows: `.venv\Scripts\python scripts\make_theme.py` with the same options). It resizes the photos and strips
their location data into `user-content/theme`. Exit 2 here usually means no usable photo: ask for another folder.
Running it again rewrites `config.json`, so any keys you add below (6.7, 6.9, 6.10) must be added again.

**6.3 Build the app.** **Say:** "Now I'm building your home screen app. The first time takes 10 to 20 minutes."
Run `build-launcher`. It signs the app with the owner's own key in `user-content/keystore/`.

**6.4 Install it.** **Say:** "Watch the TV: a second 'Allow debugging?' box may appear, because cleanyourtv's
own tool connects with its own key. Tick 'Always allow' and choose Allow again." Run `install-launcher`. It notes
the current Home app in `home-state.txt` in the backup folder, then installs the new one and makes it Home.

**6.5 Check Home is ours.** **Say:** "Press the Home button on the remote. What do you see?" Also read
`dumpsys activity activities` and look at `mFocusedApp` or `ResumedActivity`: it must show `com.gathin.tvhome`.
Some TVs say "Success" and still keep the old Home, so only these two checks count. If Home isn't ours, stop and
run `restore --home-only`.

**6.6 Switch the old home screen off.** Read the `stock_package=` line of `home-state.txt` in the backup folder
and run `disable-one <stock_package>` (skip this on a CVTE board unless its example says otherwise). Then
**say:** "Press Home again. What do you see now?" and check `dumpsys activity activities` again.

**6.7 The setup wizard rule.** The Google TV setup wizard (`setupwraith`) is never disabled, by you or anyone.
Why: the Wi-Fi network saved during the TV's first setup belongs to the wizard, and Android deletes it the moment
the wizard is switched off. The TV drops off Wi-Fi and this connection is cut. If the wizard (or anything else)
takes Home after 6.6:

1. Explain the remote trade-off first (see 6.9) and ask whether to try the fix.
2. If yes, add `"stock_home_redirect": "<the package that took Home>"` to `user-content/theme/config.json`, run
   `push-theme`, then run `install-launcher` with `HOME_KEY_SERVICE=1`.
3. Ask the owner to press Home again and check `dumpsys` again.
4. If Home still isn't ours, stop. **Say:** "Your TV won't let the new home screen take over, so I'm putting the
   original one back. Your clean-up stays." Run `restore --home-only`, then go to Phase 7.

**6.8 Send the photos and settings, then restart once.** Run `push-theme`. Wait 15 seconds, run `shell sync`,
**say:** "I'm restarting the TV once more," and run `reboot`. When it's back, run `connect`. **Say:** "What does
the TV show now? You should see your photo, your name, the clock and your four apps."

**6.9 Remote buttons.** On Google TV, the old home screen answered the app buttons on the remote.

1. **Say:** "Please press each app button on your remote (Netflix, YouTube, Prime Video and any others) and tell
   me which ones open their app and which do nothing."
2. If all work, skip to 6.10. For each dead button, find its code in the matching example or
   `vendor/cleanyourtv/docs/devices/` notes. If it's not there, run `shell getevent -lt` while the owner presses it.
3. Before switching anything on, explain the key-repeat trade-off. **Say:** "I can make those buttons work with a
   small helper. On some TVs, TCL especially, the helper has a side effect: holding a button stops repeating, so
   holding volume up moves it just one step each press. Would you like the buttons fixed anyway?"
4. If yes: **say:** "First, hold volume up for two seconds and tell me if it keeps going up." Add the `app_keys`
   entries (for example `"4062:com.netflix.ninja"`) to `user-content/theme/config.json`, run `push-theme`, then
   run `install-launcher` with `INPUT_KEY_SERVICE=1` (plus `HOME_KEY_SERVICE=1` if that is already on). Ask the
   owner to press the buttons again and to hold volume up again, and note the result for the summary.
5. If no, leave the helpers off and note which buttons don't work.

**6.10 What the TV opens at power-on.** Read `shell logcat -b events -d` and look at the
`wm_set_resumed_activity` lines from the restart in 6.8. If the TV opened its Live TV app by itself, ask:
**Say:** "When you turn the TV on, would you like to land on your new home screen, or on live TV?"

- Home: add `"power_on_home": true` to the theme, run `push-theme`, and run `install-launcher` with
  `HOME_KEY_SERVICE=1` (plus any switch already on). Explain the trade-off from 6.9 first if it isn't on yet.
- Live TV: add `"boot_to_live_tv": true` to the theme and run `push-theme`.
- Never set both. Then ask the owner to switch the TV off and on with the remote and say what appears.

**End of phase:** **Say:** "Your new home screen is set up. <What works, which buttons work, the power-on
choice.> Last step: I'll write down everything I did and close the connection." Wait for yes.

## Phase 7: Finish

1. Write `SUMMARY.md` in the backup folder, in plain words for the owner:
   - the TV model, the date, and that this was release v1.0
   - every app switched off (from `disabled-by-us.txt`) and what each did; any the TV switched back on by
     itself; any special-case app from exit code 20 with the script's message
   - the home screen: photos, name, apps, clock, which remote helpers are on and what that costs, the power-on choice
   - "Keep the `user-content/` folder. Its `keystore` is needed to update your home screen later."
   - how to change the photos later: run `make_theme` again with a new folder, add back any extra keys you set
     in 6.7, 6.9 or 6.10 (list them here), then `push-theme`
   - how to undo, for the owner's computer only. First, turn debugging back on (Phase 2's steps), then run one of
     these in the project folder. Mac: `bash scripts/restore.sh` (everything),
     `bash scripts/restore.sh --home-only` (only the home screen), `bash scripts/restore.sh --packages-only`
     (only the apps). Windows:
     `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\restore.ps1`, adding `--home-only` or
     `--packages-only` the same way.
   - how to bring back one app without a computer: Settings → Apps → See all apps → the app → Enable.
2. Close the connection. **Say:** "Last thing on the TV: open Settings → System → Developer options and turn
   off Network debugging (and Wireless debugging if you see it). Would you like to keep USB debugging on? Most
   people turn it off too. You can always switch it back on to undo things later." Also suggest "Revoke USB
   debugging authorisations" in the same menu.
3. Confirm it's off: run `connect`. It must end with 21. If it ends with 0, debugging is still on: ask the owner
   to check the switches again. Then ask them to restart the TV with the remote and run `connect` once more.
   Only `connect` saying it can't reach the TV counts.
4. Check `git status`. Nothing from `backups/`, `photos/`, `user-content/`, `screenshots/` or `.env` may be
   staged. Never commit or upload them.
5. **Say:** "All done. Everything I changed is listed in <backup folder>/SUMMARY.md, with how to undo it. You
   don't need me for that: on a Mac it's `bash scripts/restore.sh`, on Windows
   `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\restore.ps1`. Enjoy your TV!"

---

## If something goes wrong

- If the TV refuses a command, or doesn't come back after a restart, stop at once. Say what happened in
  plain words. Never retry and never try another way.
- If the TV doesn't come back after a restart: **Say:** "Please unplug the TV from the wall for 30 seconds,
  then plug it back in and turn it on." Then run `connect` once.
- If the picture, HDMI or remote stopped working after a clean-up batch, tell the owner which 3 packages were
  last, and offer `restore --packages-only`. Run it only after they say yes.
- If Home is wrong or black, offer `restore --home-only`. It puts the original home screen back and switches
  ours off. It never uninstalls anything.
- If a restore stops with 20, stop too. Its message says what was and wasn't put back. Write that into
  `SUMMARY.md` for the owner.
