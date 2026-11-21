# Reliability

> **Purpose:** Uptime/perf targets, failure modes, monitoring, and incident learnings.
>
> **Last updated:** 2026-11-20

There is no service to monitor. Reliability means the TV never ends up unusable.

## Rules (in `PROMPT.md`)
- **Stop rule:** if Home is still wrong after `restore --home-only`, or `restore` ends non-zero, or the TV is unreachable for the Home check, stop everything and tell the owner to leave the TV on. Write `SUMMARY.md` in the backup folder.
- **Home invariant:** Home must be our launcher or the original one. Check after every step that touches Home.
- **Reboot gate:** never reboot unless the Home check passes. Wait 15 seconds after the last change (Android saves settings lazily), run `shell sync`, then reboot once.
- On the setup wizard's recovery screen a reboot has forced a factory reset on some TVs, so the gate is not optional.

## Known failure modes
| Exit | Failure | What happens |
|---|---|---|
| 3 | `.env`/`TV_IP` missing, Docker off, tools not fetched | Nothing changed; fix and rerun |
| 10 / 11 / 12 | Package protected (or the current Home app) / streaming / forbidden | Refused, nothing changed |
| 13 / 14 | No backup, or a backup from a different TV / package not in backup | Refused, nothing changed |
| 20 | TV refused, didn't answer, or didn't confirm the change | Refused: nothing changed, no retry. Didn't confirm: the package is already in the undo log; stop and offer `restore` |
| 21 / 22 | TV unreachable / debugging not allowed | `connect` once, then stop |
| 21 (causes) | Seen on the first TCL session: the TV's IP isn't on its network screen, or `.env` points to another device; on macOS, Local Network privacy blocks the downloaded `adb` ("No route to host") while `ping`/`nc` still work | Diagnose once (PROMPT Phase 2, step 6): find the TV by its Cast name; owner allows the app in Local Network, or starts `adb` from Terminal |
| — | Volume keys stopped working once on the first TCL session (OT-05), after a reboot followed by more live disables; not reproduced | `restore --packages-only` brought it back. Ask about volume in every owner check, not only the remote's arrows |
| 23 | `connect --check-off` only: debugging is still on | Owner turns off Network debugging; never press Allow |
| 30 | Upstream download doesn't match the pinned commit | Deleted, nothing used |
