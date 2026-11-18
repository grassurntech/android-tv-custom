# Contributing

Thanks for helping. This repo is **public**, so every contribution must be safe to publish.

## Setup
1. Fork, then clone your fork.
2. `cp .env.example .env` and fill in your values. `.env` is git-ignored.
3. `git config core.hooksPath scripts/hooks` turns on the pre-commit secret check.
4. Optional but recommended: install [gitleaks](https://github.com/gitleaks/gitleaks#installing) so the hook can also scan file contents.

## Making a change
1. Branch from `main`: `feat/…`, `fix/…`, `docs/…` or `chore/…`.
2. Keep each PR focused on one thing.
3. Open a PR into `main` and complete the checklist in the template.
4. CI runs a secret scan. PRs can't merge until it passes.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).

## The non-negotiables
- **No secrets, ever:** API keys, tokens, passwords, signing keys, or personal data.
- **Config goes in `.env`.** Every new variable gets a safe placeholder and a one-line comment in `.env.example`.
- **No hardcoded personal details:** IPs, names, device serials, file paths, account IDs.
- **Only publishable assets.** Sample photos, icons and fonts must be ones you have the right to share. Note where they came from in the PR.
- **Never use `--no-verify`** to skip the hooks.

## Committed a secret by accident?
Deleting it in a new commit is **not** enough, because it stays in the history. First rotate or revoke the secret. Then follow [docs/SECURITY.md](docs/SECURITY.md#if-a-secret-is-committed).
