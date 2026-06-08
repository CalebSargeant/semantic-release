# AGENTS.md

This repository publishes the `Diatreme` GitHub Marketplace composite action.
Keep it intentionally small: root `action.yml`, the scripts the action invokes,
Marketplace-facing docs, release metadata, and validation for that surface.

## Repository Boundary

- Marketplace metadata stays here. Keep exactly one root action metadata file:
  `action.yml` or `action.yaml`.
- The public implementation service behind hosted token brokering, Copilot quota
  checks, signing, dispatch, and webhooks lives in
  [github.com/MagmaMoose/platform](https://github.com/MagmaMoose/platform) (`/apps/diatreme`).
- Proprietary dashboards and private UX belong in
  [github.com/MagmaMoose/platform-pro](https://github.com/MagmaMoose/platform-pro).
- Do not copy platform or platform-pro source back into this distribution repo.

## Required Files

- `action.yml`: published composite action metadata and inline orchestration.
- `scripts/*.sh`: runtime helpers called by `action.yml`.
- `README.md`: Marketplace user guide with usage, inputs, outputs, permissions,
  examples, and release notes.
- `CHANGELOG.md`, `LICENSE`, `pyproject.toml`: release metadata for this action.
- `.github/workflows/ci.yaml`: validates the distribution repo.
- `.github/workflows/release.yaml`: publishes this action and updates floating
  major tags.

## Local Validation

Run from repository root:

```bash
ruby -e 'require "yaml"; YAML.load_file("action.yml")'
actionlint -color=false
shellcheck -S warning scripts/*.sh
bats tests/bats
```

`actionlint`, `shellcheck`, and `bats` must be available on `PATH`. CI installs
them directly instead of using npm, pnpm, or a worker workspace.

## Architecture Notes

- `mode: ci` optionally enforces branch naming, can require Copilot review, and
  builds/pushes Docker Bake targets as `pr-<number>` tags.
- `mode: release` resolves auth, determines the target environment, delegates
  versioning to the selected backend, normalizes outputs, optionally promotes
  Docker images, publishes GitHub Releases, and can create promotion PRs.
- `mode: enable-auto-merge` enables native GitHub auto-merge for a specific PR.
- Auth selection is centralized in `scripts/resolve-auth-token.sh`.
- Public App token exchange is requested by
  `scripts/request-public-app-token.sh`; the broker service source belongs in
  platform.

## Editing Rules

- Preserve action input names, output names, defaults, and behavior unless the
  user explicitly approves a breaking change.
- Keep README examples aligned with `action.yml`.
- Do not add npm/yarn, MkDocs, generated docs, worker code, build output, caches,
  `.env*`, vendored code, or private/pro code.
- Shell scripts must remain executable in Git.
