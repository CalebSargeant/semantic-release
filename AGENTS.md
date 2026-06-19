# AGENTS.md

This repository is **Diatreme** — a GitHub Marketplace composite action plus the
Cloudflare Worker that backs it. It has two independent surfaces in one repo:

| Surface | Path | Toolchain |
| --- | --- | --- |
| Composite action (Marketplace) | `action.yml` + `scripts/*.sh` | Bash, `actionlint`, `shellcheck`, `bats` |
| Cloudflare Worker (backend service) | `worker/` | TypeScript, `wrangler`, `vitest` |

The action is published to the Marketplace from the repo root (exactly one
`action.yml`). The worker is deployed to Cloudflare from `worker/`. They
communicate over HTTP — the action calls the worker at
`api.diatreme.magmamoose.com` — and neither imports the other.

## Repository Boundary

- Keep exactly one root action metadata file: `action.yml` (or `action.yaml`).
- The worker is self-contained under `worker/`; its only runtime dependency is
  `jose`. Do not couple it to the action scripts or to any external/monorepo
  package.
- The proprietary observability dashboard for this worker lives in the separate
  private repo `MagmaMoose/diatreme-pro`. Do not copy that code here.

## Required Files

Action surface:
- `action.yml` — published composite action metadata and inline orchestration.
- `scripts/*.sh` — runtime helpers called by `action.yml`.
- `README.md` — Marketplace user guide (usage, inputs, outputs, permissions, examples).
- `CHANGELOG.md`, `LICENSE`, `pyproject.toml` — release metadata for the action.
- `.github/workflows/ci.yaml` — validates both surfaces.
- `.github/workflows/release.yaml` — publishes the action and updates floating major tags.

Worker surface:
- `worker/src/index.ts` — the Worker entry (`default.fetch` request router + scheduled handler).
- `worker/README.md` — endpoint and configuration reference.
- `worker/DISPATCH.md` — Claude Code dispatch setup.
- `worker/wrangler.jsonc` — Cloudflare deploy config.
- `worker/test/index.test.ts` — vitest suite.

## Local Validation

Action (from repo root):

```bash
ruby -e 'require "yaml"; YAML.load_file("action.yml")'
actionlint -color=false
shellcheck -S warning scripts/*.sh
bats tests/bats
```

Worker (from `worker/`):

```bash
npm install
npm run typecheck
npm test
npm run check   # typecheck + tests + wrangler dry-run
```

## Architecture Notes

- `mode: ci` optionally enforces branch naming, can require Copilot review, and
  builds/pushes Docker Bake targets as `pr-<number>` tags.
- `mode: release` resolves auth, determines the target environment, delegates
  versioning to the selected backend, normalizes outputs, optionally promotes
  Docker images, publishes GitHub Releases, and can create promotion PRs.
- `mode: enable-auto-merge` enables native GitHub auto-merge for a specific PR.
- Auth selection is centralized in `scripts/resolve-auth-token.sh`; public-App
  token exchange is requested by `scripts/request-public-app-token.sh`, which
  calls the worker's broker endpoint.
- The worker exposes `/process` (Copilot triage), `/sign` (signed commits),
  `/dispatch` (Claude Code tasks), `/copilot-quota`, and OAuth connect/callback.

## Editing Rules

- Preserve action input names, output names, defaults, and behavior unless the
  user explicitly approves a breaking change.
- Keep README examples aligned with `action.yml`.
- Keep the worker self-contained (only `jose`); do not vendor pro/private code.
- Shell scripts must remain executable in Git.
- Never commit secrets, `.dev.vars`, build output, or caches (`node_modules/`,
  `.wrangler/`, `coverage/`).
