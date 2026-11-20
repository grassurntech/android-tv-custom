# Test Cases Index

> **Purpose:** The master list of QA test cases, by category. These are the cases to re-run after every fix round. Each case has an ID, the attack or input, the expected result, the latest result, and the automated test that guards it.
>
> **Last updated:** 2026-11-20

## How to use these files

- **Result** is the latest run. `FAIL` means a bug that was reproduced, `PASS` means the case held up, and `GAP` means a test is missing even though the code may be right.
- **Sev** shows how bad a `FAIL` is:
  - **C** (critical): it can disable a protected or streaming app, delete owner files, or leak `.env`.
  - **H** (high): it can leave the TV or the undo record in a wrong state.
  - **M** (medium)
  - **L** (low)
- In this fix round, C, H and M are fixed. L items go to the [tech-debt-tracker](../exec-plans/tech-debt-tracker.md).
- **Auto test** names the test that runs in CI (`python3 -m unittest discover -s tests`). A case with no automated test is checked by hand or by a prompt run.
- When a case is fixed, change its Result to `PASS`, fill in the Auto test, and bump the date.

## Baseline (2026-11-19, `ab06b43`)

On macOS, 283 tests ran: all passed and 133 were skipped. The skips are the pwsh twins, plus the Pillow tests when Pillow is missing.

## After fix round 1 (2026-11-19, uncommitted on `feat/v1-tv-cleanup`)

- **Suite:** 508 tests, all passing on macOS. 197 skipped with Pillow and 236 without; the skips are the pwsh twins and the Pillow tests.
- **Fixed:** every C, H and M case now passes (bash) or is accepted or deferred with a reason in its row.
- **Still open:**
  - Every `.ps1` change waits on Windows and Ubuntu CI, because PowerShell wasn't installed.
  - The `PROMPT.md` live cases (PF-4x/5x, PI) need a re-run with the full prompt.
  - Deferred items are in the [tech-debt-tracker](../exec-plans/tech-debt-tracker.md).

## First on-TV session (2026-11-20, TCL Google TV 11)

- **Suite:** 546 tests on macOS, all passing (pwsh twins skipped). New: SC-44 (real TCL package names) and `tests/test_lists.py` (IN-10).
- **On the TV:** OT-01 to OT-04 pass; 16 packages off and kept after reboots. OT-05 (volume keys stopped once) was not reproduced.

## Categories

| File | Covers | IDs |
|---|---|---|
| [hook.md](hook.md) | Claude safety hook `.claude/hooks/tv-safety.py`: bypasses and false positives | HK |
| [scripts.md](scripts.md) | `connect`, `backup`, `disable-one`, `restore`, `lib/tv-env`: unit and adversarial cases | SC |
| [theme-launcher.md](theme-launcher.md) | `make_theme.py`, `push-theme`, `build-launcher`, `install-launcher` | TH |
| [integration-regression.md](integration-regression.md) | End-to-end runs on a fake TV, regression of past fixes, mutation checks, sh/ps1 parity, runs on a real TV | IN, RG, MU, PA, OT |
| [prompt.md](prompt.md) | `PROMPT.md`: owner-side flow, exit-code handling, prompt injection | PF, PI |
