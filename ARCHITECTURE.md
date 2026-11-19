# Architecture

> **Purpose:** High-level system map: components, data flow, boundaries, and key dependencies of the TCL TV software.
>
> **Last updated:** 2026-11-19

## Components

```
 owner ──> AI tool (Claude Code, Cursor, ...) ──reads──> PROMPT.md
                         │
                         ▼  runs only these
              scripts/*.sh | *.ps1  ──reads──> config/*.txt (protected, streaming, forbidden, junk)
              (+ scripts/lib, make_theme.py)   .env (TV_IP ...)
                 │            │
                 │            └──> vendor/cleanyourtv (pinned tag + commit) ──Docker──> launcher APK
                 ▼
               adb ──Wi-Fi──> TV  (pm disable-user, install APK, push theme)
```

| Component | Role |
|---|---|
| `PROMPT.md` | The one prompt owners paste. Phases, rules and the exit-code table for the AI. |
| `scripts/` | The only way the TV is changed. Each exists as `.sh` and `.ps1` with the same arguments, exit codes and adb calls. `disable-one.*` enforces every safety rule; `restore.*` undoes. |
| `config/*.txt` | Safety lists (protected, streaming apps, forbidden) and vetted junk candidates. `upstream.env` pins cleanyourtv. |
| `.claude/hooks/tv-safety.py` | Blocks unsafe commands when Claude runs them directly. Does not cover other AI tools, so the scripts enforce the same rules. |
| cleanyourtv launcher | Upstream launcher (`com.gathin.tvhome`), fetched into git-ignored `vendor/` and built in Docker. See [references/cleanyourtv.md](docs/references/cleanyourtv.md). |
| Theme | `scripts/make_theme.py` turns the owner's photos plus `themes/template/config.json` into `user-content/theme/`. Home and remote-key settings are its flags too; each run rebuilds the theme from scratch, so nobody edits `config.json` by hand. |
| `tests/` | `unittest` suite; one shared refusal table is run against both script versions with a fake adb. |

## Data flow
1. **Clean-up:** owner → AI tool → `disable-one` (checks lists and backup) → adb → TV. Each disable is logged in `backups/<date>/disabled-by-us.txt`.
2. **Launcher:** `fetch-tools` (hash-checked) → `build-launcher` (Docker) → APK → `install-launcher` → adb → TV.
3. **Theme:** owner's photos → `make_theme.py` (1920×1080 JPEG, EXIF stripped) → `push-theme` → TV.
4. **Undo:** `restore` reads the backup log → adb → TV.

Photos, backups, `.env` and the signing key never leave the computer.
