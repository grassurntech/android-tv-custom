# Core Beliefs

> **Purpose:** The non-negotiable engineering and product principles that guide every decision.
>
> **Last updated:** 2026-11-19

Short form. The full rules are in `CLAUDE.md` and [SECURITY.md](../SECURITY.md).

1. **The TV stays a TV.** HDMI, tuner, remote, Bluetooth, keyboard, Play Store, Settings and streaming apps are never touched.
2. **Disable, never uninstall.** Every change can be undone with `pm enable`. No root, no flashing.
3. **Back up before the first change.** No backup, no change.
4. **Stop when the TV refuses.** Report it. Never retry in a loop or look for another way.
5. **Product code enforces the rules itself.** Scripts must not rely on a Claude hook; the hook is a second layer.
6. **Public and forkable.** No secrets, no personal data, config only in `.env`, a fresh clone must work.
7. **Owner data stays local.** Photos, backups and screenshots are never uploaded or committed.
8. **Tests before trust.** Every refusal case is tested against both script versions.
