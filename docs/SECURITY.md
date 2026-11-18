# Security

> **Purpose:** Secrets policy, safety rules for changes made to users' TVs, and how to report a vulnerability.
>
> **Last updated:** 2026-11-18

This is a **public, forkable** repo. Treat everything committed as published to the world, permanently.

## Secrets & config
- **Never commit** API keys, tokens, passwords, signing keystores (`*.jks`, `*.keystore`), `local.properties` or `.env` files.
- **All config comes from environment variables** loaded from a local `.env` (git-ignored). `.env.example` holds placeholders only.
- **No personal data in the repo:** users' photos, names, TV serials or network details. These stay in git-ignored local folders.
- Release signing keys, if we ever have them, live in GitHub Actions encrypted secrets and never in files.

## Guardrails (keep all of these on)
| Layer | What it does |
|---|---|
| `.gitignore` | Keeps `.env`, keystores, build output and personal content out of git |
| `scripts/hooks/pre-commit` | Blocks secret files from being committed, and runs gitleaks if installed |
| `.github/workflows/secret-scan.yml` | Scans the full history with gitleaks on every push and PR |
| `.claude/settings.json` | Stops Claude Code from reading `.env` and keystore files |
| GitHub secret scanning + push protection | Enable in repo **Settings → Code security** (free for public repos) |

## TV safety
- Every change made to a user's TV must be **reversible**, with the restore command documented next to it.
- ADB over the network gives full control of the TV. The docs must tell users to switch off network debugging after setup.
- Never ship anything that sends user data off the TV. No telemetry, no analytics.

## If a secret is committed
1. **Rotate or revoke it first.** Assume it is already compromised.
2. Remove it from history, using `git filter-repo` or GitHub's guidance on removing sensitive data, then force-push.
3. Open an issue describing what happened, without the secret itself.

## Reporting a vulnerability
Please don't open a public issue. Use GitHub's **Security → Report a vulnerability** (private advisory) on this repo.
