# Design

> **Purpose:** Design principles, patterns, and conventions across the system.
>
> **Last updated:** 2026-11-19

The full design is [design-docs/2026-11-19-tv-cleanup-and-home-screen.md](design-docs/2026-11-19-tv-cleanup-and-home-screen.md). Conventions:

- **Two entry points:** the owner pastes `PROMPT.md`; the AI acts only through `scripts/`.
- **One script, two shells:** every owner-run script is `.sh` and `.ps1` with identical arguments, exit codes and adb calls. Bash must run on macOS bash 3.2; PowerShell on Windows PowerShell 5.1.
- **One chokepoint:** `disable-one.*` is the only thing that disables a package, so every safety check lives in one place.
- **Config in plain files:** safety lists in `config/*.txt` (one fnmatch glob per line), settings in `.env` read as plain `KEY=VALUE`, never sourced.
- **Exit codes are the API:** the same table is in `PROMPT.md` and the scripts.
- **Reuse upstream:** the launcher comes from cleanyourtv, pinned and hash-checked, not forked.
