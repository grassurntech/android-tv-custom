# CLAUDE.md — TCL TV Software

This file is the **table of contents** for the project. It stays short: it points to where knowledge lives instead of holding it. Read the relevant linked doc before working in that area.

---

## Table of Contents

| Area | File | Read when… |
|---|---|---|
| System map | [ARCHITECTURE.md](ARCHITECTURE.md) | Touching components, data flow, or module boundaries |
| Design principles | [docs/DESIGN.md](docs/DESIGN.md) | Making design/pattern decisions |
| Frontend / TV UI | [docs/FRONTEND.md](docs/FRONTEND.md) | Building UI, focus/remote navigation, perf budgets |
| Plans process | [docs/PLANS.md](docs/PLANS.md) | Starting or finishing a multi-step piece of work |
| Product sense | [docs/PRODUCT_SENSE.md](docs/PRODUCT_SENSE.md) | Making product trade-offs |
| Quality grades | [docs/QUALITY_SCORE.md](docs/QUALITY_SCORE.md) | Assessing or improving an area's quality |
| Reliability | [docs/RELIABILITY.md](docs/RELIABILITY.md) | Perf targets, failure modes, monitoring |
| Security | [docs/SECURITY.md](docs/SECURITY.md) | Auth, secrets, anything user-data related |

### `docs/design-docs/`
- [index.md](docs/design-docs/index.md) — catalog of design docs + status
- [core-beliefs.md](docs/design-docs/core-beliefs.md) — non-negotiable principles

### `docs/exec-plans/`
- `active/` — plans in progress (one file per plan)
- `completed/` — finished plans, moved here when done
- [tech-debt-tracker.md](docs/exec-plans/tech-debt-tracker.md) — known debt

### `docs/generated/`
- [db-schema.md](docs/generated/db-schema.md) — generated from source; never hand-edit

### `docs/product-specs/`
- [index.md](docs/product-specs/index.md) — catalog of specs + status
- [new-user-onboarding.md](docs/product-specs/new-user-onboarding.md)

### `docs/references/` (external, read-only)
- `design-system-reference-llms.txt`, `nixpacks-llms.txt`, `uv-llms.txt`

**When adding a new doc:** add it to this TOC and to the matching `index.md` in the same change.

---

## Rule: Update docs after every successful commit + push of a PR

Run this every time a PR is successfully committed and pushed. Do not skip it, and do not update docs that weren't affected.

1. **Identify** — Read the PR diff and list the docs it actually affects (use the TOC above; e.g. new endpoint → ARCHITECTURE.md, UI change → FRONTEND.md, finished plan → move from `exec-plans/active/` to `completed/`, new shortcut → tech-debt-tracker.md, schema change → regenerate db-schema.md).
2. **Grade each candidate detail** before writing it down:
   - **Must** — changes how someone builds, runs, or reasons about the system (new component, changed contract, new constraint, decision + why). → Document.
   - **Should** — useful context that will still be true in a month. → Document in one line.
   - **Skip** — implementation trivia, anything obvious from the code or git history, temporary state. → Leave out.
3. **Update only those files**, with only Must/Should details. Edit in place; replace stale text rather than appending. Keep each update to the fewest lines that carry the fact. Bump the file's `Last updated` date.
4. **Keep the TOC true** — if a doc was added, renamed, or removed, update this file and the relevant `index.md`.
5. **Report** — in the wrap-up, list which docs were updated and which were checked but needed no change. Commit doc updates as a follow-up commit on the same branch (`docs: update after <PR title>`).

---

## Status

Project scaffold created 2026-11-18. No code yet. Git initialized on `main` (no remote yet).
