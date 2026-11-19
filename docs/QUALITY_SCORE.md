# Quality Score

> **Purpose:** Per-area quality grades (A–F) with the reason and next step to raise each grade.
>
> **Last updated:** 2026-11-19

| Area | Grade | Why | Next step |
|---|---|---|---|
| Bash scripts | B+ | Tested in CI against a fake adb, with a shared refusal table. Never run on a real TV yet. | First on-TV session |
| PowerShell scripts | C | Never run on a real machine; first run is CI on Windows PowerShell 5.1. | Green Windows CI, then a Windows contributor |
| Safety lists | C | Seed lists from standard Android names; not verified on a TCL. | Verify with `pm list packages` on the TV |
| Safety hook | B | Tested, but only covers commands Claude runs. | Keep scripts as the real layer |
| Theme / photo tool | B | Unit-tested (size, EXIF, crop); not seen on a TV. | Check on the TV |
| Google TV Home flow | D | Unverified: replacing and restoring Home is untested on hardware. | Test on TV, including restore |
| `PROMPT.md` | B | Tested for rule and exit-code coverage; never run end to end. | Full run by a non-coder |
| Docs | B | Short and current; checked by `tests/test_docs.py`. | Refresh after each PR |
