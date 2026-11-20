# Tech Debt Tracker

> **Purpose:** Running list of known shortcuts and debt: item, impact, owner, target fix.
>
> **Last updated:** 2026-11-19

| Item | Impact | Owner | Target fix |
|---|---|---|---|
| `config/protected-packages.txt` and `forbidden-packages.txt` are seed lists from standard Android names, not yet verified on a real TCL TV | A TCL-specific core package could go unprotected, or a factory app could go unlisted | Maintainers | First on-device session: run `pm list packages` and `dumpsys package`, add the TCL names |
| `config/junk-packages.txt` is empty, so end-to-end tests use an invented junk set (IN-10) | E2E can't prove the real TCL clean-up list | Maintainers | First on-device session: seed it from `pm list packages` |
| Every `.ps1` change from the 2026-11-19 QA fix round was written without PowerShell installed | Windows behaviour is unproven until CI runs | Maintainers | Green Windows and Ubuntu (pwsh) CI before merge |
| `disable-one` takes back its own undo-log line on a refusal by rewriting the log; a second run appending at that exact moment could lose its line (SC-14 edge) | Rare lost undo record if two runs overlap | Maintainers | Lock file around the log, or keep refusals as a separate "refused" line |
| ps1 backup-dir warning handles letter case but not symlinks (SC-42) | A symlinked backup dir inside the repo isn't warned about on Windows | Maintainers | Resolve the link target in `TvEnv.psm1` |
| `PROMPT.md` live behaviour cases (`docs/test-cases/prompt.md`) were run once per model on a shortened prompt, before the fixes | Prompt fixes are only checked statically | Maintainers | Re-run the saved scenarios with the full prompt on Sonnet and Haiku |
| The safety hook only trusts scripts in `scripts/` and `tests/` that git tracks and that match HEAD | Running a modified script directly from Claude is blocked until it's committed | Maintainers | Accepted trade-off; commit before running scripts by hand |
