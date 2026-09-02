# AGENTS.md

This repository is **Diatreme**: a GitHub Marketplace composite action plus the
hosted broker that backs it. It has two independent surfaces in one repo:

| Surface | Path | Toolchain |
| --- | --- | --- |
| Composite action (Marketplace) | `action.yml` + `scripts/*.sh` | Bash, `actionlint`, `shellcheck`, `bats` |
| Python/Lambda broker (active backend) | `broker/app/` | Python, `pytest`, AWS Lambda + API Gateway |
| Cloudflare Worker (retired — rollback target) | `worker/` | TypeScript, `wrangler`, `vitest` |

The action is published to the Marketplace from the repo root (exactly one
`action.yml`). The broker runs on AWS Lambda and is reached by the action over
HTTP at `api.diatreme.magmamoose.com` (fallback: `broker-diatreme.magmamoose.com`).
The Cloudflare Worker (`worker/`) is no longer serving any hostname as of
2026-08-20; it stays in the repo as a rollback target and code reference.
Neither surface imports the other.

## Repository Boundary

- Keep exactly one root action metadata file: `action.yml` (or `action.yaml`).
- The broker is self-contained under `broker/app/`; do not couple it to the
  action scripts or to any external/monorepo package.
- The worker is self-contained under `worker/`; its only runtime dependency is
  `jose`. It is retired and not serving traffic, but its CI still validates
  TypeScript and guards the wire contract.
- The proprietary observability dashboard for this broker lives in the separate
  private repo `MagmaMoose/diatreme-pro`. Do not copy that code here.

## Required Files

Action surface:
- `action.yml`: published composite action metadata and inline orchestration.
- `scripts/*.sh`: runtime helpers called by `action.yml`.
- `README.md`: Marketplace user guide (usage, inputs, outputs, permissions, examples).
- `CHANGELOG.md`, `LICENSE`, `pyproject.toml`: release metadata for the action.
- `.github/workflows/ci.yaml`: validates the action, broker, and worker surfaces.
- `.github/workflows/release.yaml`: publishes the action and updates floating major tags.

Broker surface (active):
- `broker/app/broker.py`: framework-free `(status, body)` decision functions.
- `broker/app/lambda_handler.py`: AWS Lambda + API Gateway adapter.
- `broker/app/main.py`: FastAPI shell for local dev only (excluded from Lambda zip).
- `broker/tests/`: pytest suites covering the full mint ladder, routing, and JWKS rescue.

Worker surface (retired — rollback target only):
- `worker/src/index.ts`: the Worker entry (`default.fetch` request router).
- `worker/README.md`: endpoint and configuration reference.
- `worker/wrangler.jsonc`: Cloudflare deploy config (kept to enable fast rollback).
- `worker/test/index.test.ts`: vitest suite — still run in CI to guard wire contract.

## Local Validation

Action (from repo root):

```bash
ruby -e 'require "yaml"; YAML.load_file("action.yml")'
actionlint -color=false
shellcheck -S warning scripts/*.sh
bats tests/bats
```

Broker (from `broker/`):

```bash
pip install -r requirements-dev.txt
pytest
```

Worker (from `worker/`, retired — still validated in CI):

```bash
npm install
npm run typecheck
npm test
npm run check   # typecheck + tests + wrangler dry-run
```

## Architecture Notes

- `mode: ci` optionally enforces branch naming and builds/pushes Docker Bake
  targets as `pr-<number>` tags.
- `mode: ci` can also scan the assembled `pr-<N>` image (Trivy) and route a
  CycloneDX SBOM to Dependency-Track and optional findings to DefectDojo, via
  `scripts/scan-image.sh` and the `scripts/upload-*-{dependency-track,defectdojo}.sh`
  uploaders. Reporting is visibility-first (non-blocking unless
  `image-scan-gate`); sinks are failure-isolated; a scanner that cannot run is a
  build error, not a finding.
- `mode: release` resolves auth, determines the target environment, delegates
  versioning to the selected backend, normalizes outputs, optionally promotes
  Docker images, publishes GitHub Releases, and can create promotion PRs.
  Before promoting a `pr-<N>` image it verifies the image's provenance labels
  (stamped by `mode: ci`) against the release commit's git tree via
  `scripts/verify-promote-source.sh`; stale or unverifiable images are rebuilt
  from the release checkout instead of promoted.
- `mode: enable-auto-merge` enables native GitHub auto-merge for a specific PR.
- Auth selection is centralized in `scripts/resolve-auth-token.sh`; public-App
  token exchange is requested by `scripts/request-public-app-token.sh`, which
  calls the broker's `/token` endpoint.
- The broker (Python/Lambda, `broker/app/`) exposes `POST /token` (OIDC → App
  installation-token), `GET /healthz`, and `GET /readyz`. The retired Cloudflare
  Worker additionally implemented `/sign`, `/releases`, and a push webhook;
  those endpoints are not present in the Lambda broker.
- The Lambda broker verifies OIDC tokens using a DynamoDB-backed JWKS snapshot
  rescue: a JWKS retrieval fault returns 503, never 401 (issue #147 lesson).
- `broker/app/config.py` loads config from AWS SSM Parameter Store in production
  and environment variables locally.

## Editing Rules

- Preserve action input names, output names, defaults, and behavior unless the
  user explicitly approves a breaking change.
- Keep README examples aligned with `action.yml`.
- Keep the worker self-contained (only `jose`); do not vendor pro/private code.
- Shell scripts must remain executable in Git.
- Never commit secrets, `.dev.vars`, build output, or caches (`node_modules/`,
  `.wrangler/`, `coverage/`).
