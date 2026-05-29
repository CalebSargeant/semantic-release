# AGENTS.md

This file provides guidance to AI coding agents (GitHub Copilot, Warp AI, etc.) when working with code in this repository.

## Repository purpose
This repo publishes a composite GitHub Action (`action.yml`) that orchestrates semantic releases for TBD/BBD workflows and optionally promotes Docker images in GHCR.  
It also contains a Cloudflare Worker (`worker/`) used as a token broker for the public GitHub App auth mode.

## Core development commands
Run from repository root unless noted.

- Install JS dependencies (root + `worker/` workspace):
  - `npm ci`
- Full local validation (matches CI intent):
  - `npm run ci`
- Action/shell/docs checks individually:
  - `npm run lint:actions`
  - `npm run lint:markdown`
  - `npm run test:bake`
  - `npm run test:shell`
  - `npm run worker:check`

### Targeted test commands
- Run only Bats tests for auth-token script:
  - `bats tests/bats/resolve-auth-token.bats`
- Run one Bats test by name:
  - `bats tests/bats/resolve-auth-token.bats -f "github-token mode uses default workflow token"`
- Run worker tests only:
  - `npm run test:worker`
- Run one worker test file:
  - `npm --workspace worker test -- test/index.test.ts`
- Run worker test(s) by name:
  - `npm --workspace worker test -- -t "creates a repo-scoped installation token"`

### Worker-specific commands
- Typecheck worker:
  - `npm run typecheck:worker`
- Worker check pipeline (typecheck + tests + wrangler dry-run deploy):
  - `npm run worker:check`
- Deploy broker worker (requires Cloudflare auth/secrets), from repo root:
  - `npm --workspace worker run deploy`

### Docs commands
- Regenerate action input/output reference from `action.yml`:
  - `python scripts/generate-action-reference.py`
  - The generator groups inputs into sections (Core, Versioning tool, Deployment model, Authentication, Docker, CI checks, GitVersion, release-please) and renders enumerated values as Markdown tables.
  - When adding or renaming an input in `action.yml`, also add it to the `INPUT_GROUPS` list in the generator script so it appears in the correct section.
- Build docs site locally:
  - `python -m pip install -r requirements-docs.txt`
  - `mkdocs build --strict`

## High-level architecture
### 1) Composite action pipeline (`action.yml`)
`action.yml` is the product. The action has two runtime branches:

- `mode: ci`
  - Optional branch-name enforcement via `scripts/check-branch-naming.sh`.
  - Docker Buildx build/push of `pr-<number>` tags.
  - Multi-target bake groups are expanded via `docker buildx bake --print`, then built with per-target cache scopes.

- `mode: release`
  - Auth token is resolved first (`scripts/request-public-app-token.sh` + `scripts/resolve-auth-token.sh`).
  - Environment resolution (`tbd`, `tbd-pr`, `bbd`) computes prerelease/stable behavior.
  - Versioning is delegated to one selected tool:
    - `python-semantic-release`
    - `semantic-release` (npm)
    - `GitVersion`
    - `release-please`
  - Outputs are normalized into common `version`, `tag`, `released`, etc.
  - If Docker is enabled and a release was produced, image promotion runs:
    - Primary retag: `docker buildx imagetools create` (preserves multi-arch).
    - Referrers-index fallback: `docker pull/tag/push` when imagetools fails
      with the GHE Packages referrers parse error (single-arch only on this path).
    - Fresh-build fallback: `buildx bake --push` when both retag paths fail.
  - Optional `tbd-pr` promotion PR creation writes a marker file under `.github/promotions/` and opens the next env PR.

- Repository release publication flows:
  - `.github/workflows/release.yaml` self-releases this action via `uses: ./` (prod-only environment), then force-updates the floating major tag (`v1`, `v2`, ...) using a broker token from `scripts/request-public-app-token.sh`.

### 2) Auth/token model
- `scripts/resolve-auth-token.sh` is the single token-selection gate used by the action:
  - Chooses among `public-app`, `private-app`, `github-token`, or `auto`.
  - In CI mode, `public-app` can fall back to workflow token; in release mode it requires broker exchange.
- `scripts/request-public-app-token.sh` performs OIDC token retrieval from GitHub Actions, posts to broker `/token`, and emits short-lived installation token outputs.

### 3) Token broker worker (`worker/`)
- Entrypoint: `worker/src/index.ts` (`handleRequest`), only serves `POST /token`.
- Main flow:
  - Parse and validate request (`oidcToken`, `owner`, `repo`).
  - Verify GitHub OIDC JWT (`issuer` + expected audience).
  - Enforce repository claim match and optional allow-list (`ALLOWED_REPOSITORIES`).
  - Create GitHub App JWT from `GITHUB_APP_ID` + `GITHUB_APP_PRIVATE_KEY`.
  - Discover installation and mint repo-scoped installation token with configured permissions.
- Security/error handling behavior is heavily unit-tested in `worker/test/index.test.ts`, including non-leakage of upstream token payloads on failures.

### 4) Tests and validation layout
- `tests/bake-print.sh` validates Docker Bake examples render.
- `tests/bats/resolve-auth-token.bats` covers shell auth-token decision logic.
- `worker/test/index.test.ts` validates broker request validation, OIDC checks, installation lookup, token creation, and key-format handling.

### 5) Docs generation coupling
- `docs/reference/action-inputs-outputs.md` is generated from `action.yml` by `scripts/generate-action-reference.py`.
  - Inputs are grouped into labeled sections; the order and grouping are controlled by the `INPUT_GROUPS` constant in the generator.
  - Inputs whose `action.yml` description contains indented `value  description` lines are automatically rendered as allowed-values tables.
  - Outputs are rendered without internal implementation details (no `Value:` step references).
  - Update generated docs by running `python scripts/generate-action-reference.py` after changing action inputs/outputs.
- `mkdocs.yml` + `requirements-docs.txt` define docs build used by the Pages workflow.
- `docs/diatreme-logo.png` is used as the MkDocs theme logo/favicon and displayed in the docs index and README.

### 6) README conventions
- The README is scoped to the GitHub Marketplace action; detailed guides live in `docs/`.
- The first line must be an H1 heading (`# Diatreme`) to satisfy the MD041 markdownlint rule.
- Badges (CI, Release, Docs, Marketplace, License) and logo follow the heading.
- Docs links in the README must match actual MkDocs heading anchors (e.g., `#release-write-token`, `#branch-protection-checklist`, `#2-choose-docker-or-version-only`).
- Inline links are preferred over standalone "see the docs" sentences.

## Important repository conventions
- The root CI workflow installs external tools (`shellcheck`, `actionlint`) before running `npm run ci`; local `lint:actions` requires `actionlint` to be available on PATH.
- `npm run test:bake` expects Docker Buildx support locally; CI explicitly provisions Buildx before running repository checks.
- For release behavior changes, keep `README.md` usage examples and `action.yml` inputs/outputs aligned.
- Shell scripts (`scripts/*.sh`, `tests/*.sh`) must have executable permissions (`100755`) in Git. On Windows, use `git update-index --chmod=+x <file>` and set `git config core.filemode false` to prevent the working tree from reverting permissions.
- `npm run lint:markdown` checks `README.md` and `CHANGELOG.md` with markdownlint; avoid consecutive blank lines (MD012) and ensure the first line is an H1 (MD041).
