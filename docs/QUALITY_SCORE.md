# Quality Score

> **Purpose:** Per-area quality grades (A–F) with the reason and next step to raise each grade.
>
> **Last updated:** 2026-11-20

| Area | Grade | Why | Next step |
|---|---|---|---|
| Bash scripts | B+ | 519-test suite against a fake adb, hardened in QA round 1 (undo log written before each change, TV identity check, unreadable lists stop the script). Never run on a real TV yet. | First on-TV session |
| PowerShell scripts | C | Never run on a real machine; first run is CI on Windows PowerShell 5.1. | Green Windows CI, then a Windows contributor |
| Safety lists | C | Seed lists from standard Android names; not verified on a TCL. | Verify with `pm list packages` on the TV |
| Safety hook | B+ | About 270 adversarial cases; allowlist, and blocks anything it can't parse. Only covers commands Claude runs. | Keep scripts as the real layer |
| Theme / photo tool | B | Unit-tested (size, EXIF, crop); not seen on a TV. | Check on the TV |
| Google TV Home flow | D | Unverified: replacing and restoring Home is untested on hardware. | Test on TV, including restore |
| `PROMPT.md` | B | Static checks plus 114 live single-turn runs: 98 correct, none unsafe (Sonnet 54/57, Haiku 44/57). Never run end to end. | Full run by a non-coder; multi-turn tests |
| Docs | B | Short and current; checked by `tests/test_docs.py`. | Refresh after each PR |
