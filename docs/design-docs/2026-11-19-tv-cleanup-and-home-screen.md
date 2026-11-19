# Design: TV cleanup and personal home screen

> **Status:** accepted (approved 2026-11-19)
>
> **Last updated:** 2026-11-19

## 1. Intent

The TCL Android TV's stock software fills the screen with ads, recommendation rows and preinstalled apps nobody asked for. This project gives the owner back a calm TV:

1. **Turn off the junk and ads** that the TV's own software shows.
2. **Swap the home screen** for one that shows the owner's photos, a small clock, their name and their four favourite apps.

It's open source. Anyone with an Android TV can fork it and run it on their own set by pasting **one prompt** into an AI coding tool (Claude Code, Cursor, Codex, Antigravity or similar). The AI does the work step by step and asks the owner whenever a choice is theirs.

We build and test it on one TCL TV first, then turn what worked into the public prompt.

## 2. Who it's for

Someone who **knows no code**. They can install an app (Docker Desktop, an AI tool), follow on-screen steps on the TV, and answer questions in plain words. They can't read a stack trace and shouldn't have to.

## 3. Goals, non-goals, anti-goals

**Goals**
- The TV's own ads, recommendation rows and telemetry are switched off.
- Home shows the owner's photos as the background, a small clock, their name and four app tiles.
- **Streaming apps (Netflix, Prime Video, Disney+, YouTube and the rest) keep working exactly as before:** they open, play, stay signed in and update through the Play Store as usual (see §7).
- Every change can be undone, and the owner gets the steps to undo it.
- A non-coder finishes in one sitting with one prompt.

**Non-goals**
- Ads *inside* streaming apps (such as Prime Video's ad tier). Those come from the app itself, and we don't touch the apps.
- Network-wide ad blocking (Pi-hole, DNS), rooting, custom firmware.
- Samsung, LG, Roku and Fire TV. Android TV and Google TV only.
- An app store or remote control of the TV after setup.

**Anti-goals (a failure even if everything else works)**
- The TV stops being a TV: HDMI, the tuner, the remote, Bluetooth, the keyboard, Settings or the Play Store break.
- A streaming app stops opening, playing, signing in or updating.
- Anything is uninstalled, or anything can't be undone with `pm enable`.
- The owner's photos, backups, name or network details end up anywhere except their computer and their TV.
- The TV is left open on the network after setup.

## 4. Constraints

- **TV safety rules** in [CLAUDE.md](../../CLAUDE.md) come first: disable, never uninstall, one package at a time; back up before the first change; protected and forbidden package lists; stop when the TV refuses. Product scripts must enforce these themselves. The Claude hook is only a backstop.
- **Public-repo rules:** no secrets, all config in a git-ignored `.env`, no personal data in git, fork-friendly.
- **Hardware:** these TVs have about 1 GB of RAM. The home screen must stay light: no video, no blur, no network polling.
- **No screenshots.** The agent checks its work with text output from the TV (`dumpsys`, `pm list packages`, `uiautomator dump`, `logcat` lines). Whenever something has to look right, the owner says what they see.
- **Building with Docker.** End users build the home-screen app inside Docker, so they need no Java or Android SDK. During development we may build locally.
- **Mac, Linux and Windows in v1.** Every script owners run ships as a Bash version (`.sh`, Mac and Linux) and a native PowerShell version (`.ps1`, Windows 10/11, no WSL or Git Bash needed). Both read the same `config/` lists and must pass one shared table of refusal test cases, so the two can't drift apart on safety. *(Decided by the owner. Native PowerShell is our call, because it avoids an extra setup step for non-coders.)*

## 5. Approaches considered

| | Approach | Trade-off |
|---|---|---|
| 1 | Point users at cleanyourtv's own prompt unchanged | Least work, but its safety rules are softer than ours (it allows small batches, screenshots and its own judgement), and it doesn't do the photos-and-name theme the way we want. |
| **2** | **Our own prompt, guardrails and theme on top of cleanyourtv's tools and launcher, pinned to a tested version** | **Chosen.** We reuse a launcher and debloat tools that have been tested on many sets, and add the stricter safety layer, the non-coder flow and our theme. The cost is tracking upstream on purpose (we only move the pin after a test). |
| 3 | Write our own launcher and tools from scratch | Full control, but months of work re-learning what cleanyourtv already found on real hardware (key handling, HDMI picture bleed, setup-wizard takeovers). |

## 6. What the owner ends up with

```
┌──────────────────────────────────────────────────────────┐
│  (owner's photo, full screen, slowly rotating)            │
│                                                          │
│                                            10:42         │
│  Good evening, Sam                                       │
│                                                          │
│     ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐          │
│     │Netflix │ │ Prime  │ │Disney+ │ │YouTube │          │
│     └────────┘ └────────┘ └────────┘ └────────┘          │
└──────────────────────────────────────────────────────────┘
        Press Down → every other installed app, in a grid
```

- **Background:** the owner's photos, pushed to the TV as a theme (cleanyourtv's `theme.sh`). They can be changed later without a rebuild.
- **Clock:** small, in the corner. 12- or 24-hour, the owner's choice.
- **Name:** a greeting with the owner's name (`greeting_name`, `show_greeting`).
- **Four favourite apps** in the dock (`dock_apps`, `columns` = 4).
- **Everything else** sits in a grid that appears only when the owner presses Down, so the home screen itself shows nothing beyond the items above. *(Our call: this keeps every installed app reachable without crowding the home screen.)*

## 7. Streaming apps stay normal

The owner's streaming apps are part of the experience, not part of the cleanup.

- **Never disabled by us.** Major streaming apps go on a third config list, `config/streaming-apps.txt` (Netflix, Prime Video, Disney+, YouTube, Hotstar/JioHotstar, Apple TV, Max, Paramount+, Peacock, Hulu, Plex, Spotify and similar, as package-name patterns). `disable-one.sh` and the Claude hook refuse to disable anything on it, the same way they treat protected packages. If an owner wants a preinstalled streaming app gone, they turn it off themselves in TV Settings → Apps. *(Our call: it keeps the rule simple and stops the AI from guessing what someone watches.)*
- **Updates and sign-in untouched.** The Play Store, Play Services and the account services they need are already protected, so apps keep updating and stay signed in. We never clear app data.
- **Launch from Home.** Any of them can be one of the four dock apps, and all of them appear in the Down grid.
- **Remote buttons.** On Google TV, the stock launcher is what answers the remote's Netflix, YouTube and Prime buttons. After the new Home is in place, the prompt asks the owner to press each app button. Any that do nothing get remapped through the launcher's key service (`app_keys`). On TCL Google TV builds that service can stop held buttons from repeating (holding volume up moves it one step), so the prompt explains that trade-off and lets the owner choose before switching it on.
- **What owners lose, said up front:** Google TV's "Continue watching" and recommendation rows belong to the stock home screen, so they go when it does. Each app's own "continue watching" row inside the app is unaffected.

## 8. How the one prompt runs

Each phase ends with a short plain-language summary. The agent only moves on after the owner says yes.

0. **Get the project.** If the AI tool isn't already inside a copy of this repo, the prompt's first step clones it (the owner's fork, or the main repo), then asks the owner to reopen the AI tool in that folder before any TV command runs. *(Our call.)* Most AI tools never load our Claude hook, so `disable-one.sh` and `restore.sh` must assume nothing else is guarding them.
1. **Check the computer.** AI tool, Docker running, Git, Python 3, disk space. Download Google's official Android platform-tools (`adb`) into a git-ignored folder if it's missing. Walk the owner through anything else that's missing.
2. **Connect to the TV.** Read `TV_IP` and `TV_ADB_PORT` from `.env` (the agent helps the owner create `.env` from `.env.example`). Guide them through developer mode and the "Allow debugging?" prompt.
3. **Identify the TV.** Model, Android version, Google TV or older Android TV, which stock launcher it uses, and whether cleanyourtv has notes for that exact model in its `examples/` or `docs/devices/`.
4. **Back up.** Write to `backups/<date>/`: `packages-all.txt`, the already-disabled list, `getprop`, and `settings list global/secure/system`. Nothing is changed before this exists.
5. **Clean up.** Sort installed packages into telemetry, ads and recommendations, background extras, preinstalled apps, and streaming apps. The proposed list comes from vetted sources first: cleanyourtv's `examples/` entry for this exact model, plus our own `config/junk-packages.txt` (seeded from our TCL and grown with each tested set). The agent may add a package from neither source only after reading `dumpsys package <name>`, and it marks that package as "my guess" for the owner. *(Our call.)* Show the owner the proposed list in plain words and get a yes. Then call `scripts/disable-one.sh <package>` once per package. It refuses protected, streaming and forbidden packages, refuses without a backup, and appends each change to `backups/<date>/disabled-by-us.txt`. After every few packages, the agent checks the TV still responds (`dumpsys`) and asks the owner whether TV, HDMI and the remote still work. When finished, wait about 15 seconds, sync, reboot once, and check that what we disabled is still disabled.
6. **Build the home screen.** Ask for the photos folder, the name and the four apps. Fetch cleanyourtv at the pinned tag, build the launcher APK with its `docker-build.sh`, install it, and make it Home (`cmd package set-home-activity`). Then turn off the stock launcher the way the matching `examples/` entry says. **The Google TV setup wizard (`setupwraith`) stays protected and is never disabled by us.** If it takes over Home anyway, the agent first tries the launcher's own redirect (`stock_home_redirect` with the home-key service). If Home still isn't ours, it stops, explains, and leaves the TV on the stock home screen. *(Our call: disabling setupwraith can delete the Wi-Fi network and cut ADB, so we only revisit it with evidence from a real set.)* The launcher is signed with a per-owner key kept in git-ignored `user-content/keystore/`, created on the first build and reused for every rebuild, so updates install over the old version (`adb install -r`) without uninstalling. The summary tells the owner to keep that folder. Without it, a rebuilt launcher can't replace the installed one, and the old one simply keeps working. *(Our call.)* Scale the photos to the TV's resolution on the computer, then push our theme (`config.json` plus wallpapers). Reboot once, and ask the owner what Home shows and whether each remote app button works (§7).
7. **Finish.** Write a summary of everything changed and how to undo it to `backups/<date>/SUMMARY.md`. Turn off network debugging, and USB debugging too unless the owner wants it kept. Confirm it's off.

**Stop rule:** if the TV refuses a command, or something doesn't come back after a reboot, the agent stops, says what happened in plain words, and points to the undo steps. It never retries in a loop.

## 9. Undoing it

- **Clean-up:** `pm enable` each package in `disabled-by-us.txt`, one at a time (a `restore` script reads the log).
- **Home screen:** re-enable the stock launcher, `pm disable-user --user 0` our launcher (skipped if it was never installed), make the stock launcher Home, then read Home back; anything but the stock launcher stops with exit 20. **Our app stays installed but switched off. It's never uninstalled.** It can be switched back on later with `pm enable`.
- The undo steps go in `SUMMARY.md` and the README, so the owner can run them without the original AI session.

## 10. Repo layout

| Path | What | In git? |
|---|---|---|
| `PROMPT.md` | The one prompt owners paste | Yes |
| `scripts/disable-one.sh` + `.ps1` | The only way product code disables a package. Enforces every TV safety rule. | Yes |
| `scripts/restore.sh` + `.ps1` | Undoes clean-up and Home from the log | Yes |
| `tests/refusal-cases.*` | One shared table of cases that every script version must refuse or allow | Yes |
| `config/protected-packages.txt`, `forbidden-packages.txt`, `streaming-apps.txt` | Safety lists | Yes |
| `config/junk-packages.txt` | Vetted clean-up candidates, grown per tested TV model | Yes |
| `user-content/keystore/` | The owner's launcher signing key | No |
| `docs/images/home-mockup.png` | README picture from a CC0 sample photo | Yes |
| `.github/ISSUE_TEMPLATE/`, `CODE_OF_CONDUCT.md` | Visitor-facing repo extras (§11) | Yes |
| `themes/template/config.json` | Our theme with placeholder name, apps and clock | Yes |
| `vendor/cleanyourtv/` | cleanyourtv fetched at the pinned tag and commit hash | No (git-ignored) |
| `user-content/theme/`, `photos/` | The owner's real theme and photos | No |
| `backups/<date>/` | Backups, log, summary | No |

*(Our call: fetching cleanyourtv into a git-ignored `vendor/` folder at a pinned tag, with its commit hash checked, rather than a git submodule. A plain `git clone` works without extra flags, and our repo doesn't carry their code.)*

## 11. What a visitor sees (part of v1)

Someone who finds the repo should know within seconds what it does, whether it works on their TV, how to start and how to undo it.

**README, top to bottom**
1. **Picture of the result:** a mock-up of the finished home screen (`docs/images/home-mockup.png`), made from a public-domain or CC0 sample photo with a placeholder name. Never a capture from anyone's real TV. The licence of the source photo is credited.
2. **Quick start:** three lines right under the picture: open `PROMPT.md`, copy it all, paste it into your AI tool.
3. **What it does / what it doesn't** (streaming apps untouched, no ads removed inside apps).
4. **Tested on:** a table of model, Android version, Google TV yes/no, status and date. It starts with our TCL. Contributors add rows through PRs.
5. **Before you start:** the existing prerequisites, Docker and developer-mode sections, kept as reference further down.
6. **Undo it:** the restore command for Mac/Linux and Windows, plus what it does. Linked from the top.
7. Built on · Contributing · Security · License · Disclaimer.

**Repo extras**
- `.github/ISSUE_TEMPLATE/`: a "My TV did something unexpected" form (model, Android version, which step, what you saw) that warns people not to paste their IP address, serial number, photos or backups. Also a "Tested on my TV" form that feeds the table, and a feature-request form.
- `CODE_OF_CONDUCT.md` (Contributor Covenant).
- GitHub **About** box: description, topics (`android-tv`, `google-tv`, `debloat`, `launcher`, `tcl`, `ai-agent`), MIT licence. Set in GitHub's settings, not in a file.
- A tagged **`v1.0` release** once the Mac run works end-to-end on our TV. `PROMPT.md` names the release it belongs to.
- **Placeholder docs:** before v1, every doc either has real content or is removed. No placeholder stubs are left on the public page. See §12.

## 12. Placeholder docs before v1

| Doc | Plan |
|---|---|
| `ARCHITECTURE.md` | Fill: components (prompt, scripts, lists, hook, cleanyourtv launcher, theme) and how they connect |
| `docs/design-docs/core-beliefs.md` | Fill: the TV safety and public-repo beliefs in short form |
| `docs/PRODUCT_SENSE.md` | Fill: non-coder first, streaming apps untouched, ask before choices |
| `docs/FRONTEND.md` | Fill: the theme, remote focus, the 1 GB RAM budget |
| `docs/RELIABILITY.md` | Fill: the stop rule, reboot wait, known failure modes |
| `docs/product-specs/new-user-onboarding.md` + `index.md` | Fill: the prompt's run from the owner's point of view |
| `docs/DESIGN.md`, `docs/PLANS.md`, `docs/QUALITY_SCORE.md` | Fill, briefly |
| `docs/generated/db-schema.md` | **Remove:** there's no database |
| `docs/references/nixpacks-llms.txt`, `uv-llms.txt` | **Remove:** we use neither |
| `docs/references/design-system-reference-llms.txt` | **Remove.** The look comes from cleanyourtv's launcher. `docs/references/` instead gets a short `cleanyourtv.md` listing the upstream docs and version we rely on. |

Removals also update `CLAUDE.md`'s table of contents. *(Proposed: the owner confirms the removals when approving this design.)*

## 13. To confirm on the TV (first session)

- Model number, Android version and Google TV vs Android TV.
- That `protected-packages.txt` and `streaming-apps.txt` match the real package names on this set. This closes the tech-debt item.
- Which stock launcher and setup-wizard packages it has.
- Whether the firmware opens Live TV at power-on (`power_on_home` vs `boot_to_live_tv`).
- Whether the remote's app buttons need remapping, and the key-repeat trade-off.

## 14. Left to the builder

- Exact theme keys and defaults beyond those named here (glass, glow, animation and similar look-and-feel settings), within the 1 GB RAM budget.
- How photos are scaled (tool and quality), as long as it runs on the owner's computer and needs no account.
- The wording of each prompt step, as long as it stays plain-language and asks before every owner choice.
- Test approach for `disable-one.sh`/`.ps1` and the hook. Every refusal case gets a test, run against both script versions. CI runs the Bash tests on Linux and the PowerShell tests on a Windows runner.
- Windows is tested on CI and, for the parts that need a TV, by a contributor with a Windows PC after the Mac run works. Our own TV sessions use the Mac.
