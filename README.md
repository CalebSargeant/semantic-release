# Diatreme

<p align="center">
  <img src="docs/diatreme-logo.png" alt="Diatreme" width="200">
</p>

[![CI](https://github.com/magmamoose/diatreme/actions/workflows/ci.yaml/badge.svg)](https://github.com/magmamoose/diatreme/actions/workflows/ci.yaml)
[![Release](https://github.com/magmamoose/diatreme/actions/workflows/release.yaml/badge.svg)](https://github.com/magmamoose/diatreme/actions/workflows/release.yaml)
[![Docs](https://github.com/magmamoose/diatreme/actions/workflows/docs-pages.yaml/badge.svg)](https://docs.diatreme.magmamoose.com/)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Diatreme-purple?logo=github)](https://github.com/marketplace/actions/diatreme)
[![License](https://img.shields.io/github/license/magmamoose/diatreme)](https://github.com/magmamoose/diatreme/blob/main/LICENSE)

Instead of composing `cycjimmy/semantic-release-action` + `docker/metadata-action` + `cloudposse/github-action-docker-promote` + ~200 lines of glue YAML, use one action.

<!-- TODO: 30-second GIF showing PR→merge→release→Docker promotion -->

I run release management across three different orgs. I got tired of composing `cycjimmy/semantic-release-action` plus `docker/metadata-action` plus `cloudposse/github-action-docker-promote` plus 200 lines of glue YAML in every repo. So I built Diatreme — one action that consolidates the lot, with the multi-environment and promotion-PR patterns I actually needed in production.

Diatreme runs my production releases today. If you're managing release tooling across multiple repos or orgs and you're tired of the same dance every time, this is for you.

## 60-Second Quickstart

A production-only release from `main`, using the Diatreme GitHub App:

```yaml
name: Release

on:
  push:
    branches: [main]

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: magmamoose/diatreme@v1
        with:
          environment: prod
          environments: '["prod"]'
          prerelease-identifiers: '{}'
```

Install the [Diatreme GitHub App](https://github.com/apps/diatreme/installations/new) on the repo or org, add a `pyproject.toml` (default tool: `python-semantic-release`), and merge a conventional commit. You get a Git tag, a GitHub Release, and a `CHANGELOG.md` entry.

### Scale up

- **Docker image promotion** — add `packages: write` and `image_name: my-app`, plus a `docker-bake.hcl`. PR builds land at `pr-<N>`; merges retag to the release version, no rebuild.
- **Multiple environments** — switch to `environments: '["dev", "staging", "prod"]'`, set `prerelease-identifiers`, and run in `deployment-model: tbd-pr` with `create-promotion-pr: 'true'` so each release publish opens the promotion PR for the next environment. See [Choose your setup](https://docs.diatreme.magmamoose.com/choose-your-setup/) for the full caller workflow (the initial push trigger needs an explicit `environment` for the first env in the chain).
- **Concurrent triggers** (push + promotion-PR merges on the same branch) — swap the `uses:` line for the bundled reusable workflow:

  ```yaml
  jobs:
    release:
      uses: magmamoose/diatreme/.github/workflows/diatreme.yaml@v1
      permissions:
        contents: read
        id-token: write
      with:
        environment: prod
        environments: '["prod"]'
        prerelease-identifiers: '{}'
  ```

  Same inputs; adds an automatic `concurrency: diatreme-<target-branch>` lock with FIFO queueing.

## What You Get

- **Four versioning backends behind one input.** `versioning-tool: semantic-release-npm | semantic-release-python | gitversion | release-please` — swap without touching anything else.
- **Retag-not-rebuild Docker promotion.** The image that passed PR CI as `pr-42` becomes `v1.2.3` via registry retag. No fresh build, no binary drift between staging and prod. Falls back to a Docker Bake rebuild only when the source image is missing.
- **Per-environment prerelease identifiers.** `{"dev":"dev","staging":"rc"}` → tags land as `v1.2.3-dev.1`, `v1.2.3-rc.1`, `v1.2.3`. Production sheds the suffix.
- **Promotion PRs auto-open.** In `deployment-model: tbd-pr` with `create-promotion-pr: 'true'`, each release publish opens the promotion PR for the next environment. Merging `promote/staging/<version>` cuts the staging tag and opens `promote/prod/<version>`; merging that cuts the stable prod tag. The cascade chains through every entry in `environments`.
- **Require Copilot Review.** In `mode: ci`, Diatreme can publish `Diatreme / Require Copilot Review` as a required PR status that passes only after a configured Copilot reviewer has reviewed the current PR head.
- **ClickUp + GitHub Projects v2 in release notes.** Scans commits and PR bodies in the release range for `app.clickup.com/t/...` URLs and issue/PR refs (`#NNN`), appends grouped sections to the GitHub Release notes and to any open promotion PR body.
- **Production guardrail on by default.** `admin-required-from: '@last'` makes manual `workflow_dispatch` runs targeting production require `permission: admin` on the repository. Push and promotion-PR-merge triggers are unaffected.
- **Built-in concurrency lock.** The bundled reusable workflow declares `concurrency: diatreme-<target-branch>` with `cancel-in-progress: false`, so concurrent triggers on the same branch queue FIFO instead of racing the tag write. Composite actions can't do this on their own.

## Compared to Alternatives

| Action | Versioning | Docker build | Promote (retag) | Multi-env prerelease | Promotion PRs | ClickUp | Projects v2 | Admin gate | Concurrency lock |
|---|---|---|---|---|---|---|---|---|---|
| **Diatreme** | all 4 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| cycjimmy/semantic-release-action | semantic-release (npm) | — | — | — | — | — | — | — | — |
| codfish/semantic-release-action | semantic-release (npm) | — | — | — | — | — | — | — | — |
| googleapis/release-please-action | release-please | — | — | — | — | — | — | — | — |
| python-semantic-release publish action | python-semantic-release | — | — | — | — | — | — | — | — |
| gittools/actions | GitVersion | — | — | — | — | — | — | — | — |
| @codedependant/semantic-release-docker | sr-npm (plugin) | ✓ | — | — | — | — | — | — | — |
| cloudposse/github-action-docker-promote | — | — | ✓ | — | — | — | — | — | — |
| Nextdoor/docker-image-retag-action | — | — | ✓ | — | — | — | — | — | — |

<sub>Best-effort comparison as of 2026-05-12; corrections welcome via PR.</sub>

## Setup

- [Concepts](https://docs.diatreme.magmamoose.com/concepts/) — TBD vs BBD, promotion PRs, Docker retag, the auth-token model.
- [Choose your setup](https://docs.diatreme.magmamoose.com/choose-your-setup/) — paste-ready snippets for each release model.
- [Repository setup](https://docs.diatreme.magmamoose.com/repository-setup/) — versioning config, `docker-bake.hcl`, PR CI, release workflow.
- [Require Copilot Review](https://docs.diatreme.magmamoose.com/copilot-review/) — enforce completed Copilot PR Review as a required status check.
- [Organization setup](https://docs.diatreme.magmamoose.com/organization-setup/) — installing the App, branch-protection bypass, when to fall back to `GITHUB_TOKEN`.

Full input/output reference: [Action reference](https://docs.diatreme.magmamoose.com/reference/action-inputs-outputs/).

---

A Magma Moose product.
