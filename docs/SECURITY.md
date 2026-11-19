# Security

> **Purpose:** Secrets policy, safety rules for changes made to users' TVs, and how to report a vulnerability.
>
> **Last updated:** 2026-11-19

This is a **public, forkable** repo. Treat everything committed as published to the world, permanently.

## Secrets & config
- **Never commit** API keys, tokens, passwords, signing keystores (`*.jks`, `*.keystore`), `local.properties` or `.env` files.
- **All config comes from environment variables** loaded from a local `.env` (git-ignored). `.env.example` holds placeholders only.
- **No personal data in the repo:** users' photos, names, TV serials or network details. These stay in git-ignored local folders.
- Release signing keys, if we ever have them, live in GitHub Actions encrypted secrets and never in files.

## Guardrails (keep all of these on)
| Layer | What it does |
|---|---|
| `.gitignore` | Keeps `.env`, keystores, build output, photos, backups and screenshots out of git |
| `scripts/hooks/pre-commit` | Blocks secret files and user photos/backups/screenshots from being committed, and runs gitleaks if installed |
| `scripts/disable-one.*` | Product enforcement layer: refuses protected, streaming and forbidden packages and requires a backup. Works with any AI tool |
| `scripts/fetch-tools.*` | Refuses upstream code that doesn't match the pinned commit in `config/upstream.env` (exit 30) |
| `.github/workflows/tests.yml` | Runs the whole test suite, including every refusal case, on Linux and Windows for each push and PR |
| `.github/workflows/secret-scan.yml` | Scans the full history with gitleaks on every push and PR, and fails if user content is tracked |
| `.claude/settings.json` | Stops Claude Code from reading `.env`, keystores, photos and screenshots |
| `.claude/hooks/tv-safety.py` | Blocks unsafe TV commands before they run (see below) |
| GitHub secret scanning + push protection | Enable in repo **Settings → Code security** (free for public repos) |

## TV safety
The rules live in `CLAUDE.md` under "Rule: TV safety". They bind every script in this repo, not only Claude.
- **Disable, never uninstall:** `pm disable-user --user 0 <package>`, one at a time, always undoable with `pm enable`. No root, no flashing, no `pm clear/hide/suspend`.
- **Back up first:** save the full package list (`packages-all.txt`), the already-disabled list, `getprop` and settings to `backups/` before the first change, and keep a running log of everything turned off.
- **Protected packages** ([config/protected-packages.txt](../config/protected-packages.txt)) are never disabled. **Streaming apps** ([config/streaming-apps.txt](../config/streaming-apps.txt)) are never disabled. **Factory/service-menu apps** ([config/forbidden-packages.txt](../config/forbidden-packages.txt)) are never opened.
- **Unknown package?** Run `dumpsys package <name>` and ask the user before touching it.
- **TV refuses?** Stop and report it. No retry loops.
- ADB over the network gives full control of the TV, so the docs must tell users to switch off network debugging after setup.
- Never ship anything that sends user data off the TV or computer. No telemetry, no analytics.

**What `tv-safety.py` blocks:** uninstall, `pm clear/hide/suspend`, plain `pm disable`, root/`su`, fastboot and bootloader/recovery reboots, wipes, disabling more than one package or using loops, disabling a protected package, disabling before a backup exists, launching factory/service-menu apps, and uploading `photos/`, `backups/` or `screenshots/`. It only sees commands Claude runs directly, so product scripts enforce the same checks themselves (`scripts/disable-one.*`).

## If a secret is committed
1. **Rotate or revoke it first.** Assume it is already compromised.
2. Remove it from history, using `git filter-repo` or GitHub's guidance on removing sensitive data, then force-push.
3. Open an issue describing what happened, without the secret itself.

## Reporting a vulnerability
Please don't open a public issue. Use GitHub's **Security → Report a vulnerability** (private advisory) on this repo.
