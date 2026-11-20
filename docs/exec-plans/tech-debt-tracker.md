# Tech Debt Tracker

> **Purpose:** Running list of known shortcuts and debt: item, impact, owner, target fix.
>
> **Last updated:** 2026-11-20

| Item | Impact | Owner | Target fix |
|---|---|---|---|
| The safety lists are verified on one TCL set only (Google TV 11, R51MT05, 2026-11-20; SC-44). Other TCL platforms and brands may use different system package names | A TCL or vendor core package on another model could go unprotected | Maintainers | Each new model: compare its package list with the lists before any disable, and add names via the "Tested on my TV" form |
| Redirect mode (`STOCK_HOME_REDIRECT=1`) adds our HomeKeyService to the accessibility list; `restore --home-only` switches our launcher off but leaves that entry | A dead entry in the list (harmless: Android skips a disabled app's service) | Maintainers | Have `restore --home-only` drop our entry from `enabled_accessibility_services` |
| Volume keys stopped once after a reboot plus more live disables on the first TCL session (OT-05); not reproduced, cause unknown | A rare state where the owner loses volume until `restore` | Maintainers | If it recurs: record the exact order and `logcat -b events -d`, then bisect with reboots |
| Every `.ps1` change from the 2026-11-19 QA fix round was written without PowerShell installed | Windows behaviour is unproven until CI runs | Maintainers | Green Windows and Ubuntu (pwsh) CI before merge |
| `disable-one` takes back its own undo-log line on a refusal by rewriting the log; a second run appending at that exact moment could lose its line (SC-14 edge) | Rare lost undo record if two runs overlap | Maintainers | Lock file around the log, or keep refusals as a separate "refused" line |
| ps1 backup-dir warning handles letter case but not symlinks (SC-42) | A symlinked backup dir inside the repo isn't warned about on Windows | Maintainers | Resolve the link target in `TvEnv.psm1` |
| `PROMPT.md` gets 44/57 live cases right on Haiku (54/57 on Sonnet). The misses are wording and missed notes, not safety (`docs/test-cases/prompt.md`). Only single-turn scenarios exist | Smaller models may mislead the owner or skip `SUMMARY.md` notes | Maintainers | Tighten the failing rows; add multi-turn scenarios |
| The safety hook only trusts scripts in `scripts/` and `tests/` that git tracks and that match HEAD | Running a modified script directly from Claude is blocked until it's committed | Maintainers | Accepted trade-off; commit before running scripts by hand |
| `connect` reports every failure as 21 "can't reach". On macOS it can't tell Local Network privacy blocking the downloaded `adb` ("No route to host") from a TV that's off or a wrong IP | The owner gets the wrong advice until the AI runs the PROMPT Phase 2 step 6 checks | Maintainers | Have `connect` read the connect error and print a Mac-specific hint (or a new exit code) |
