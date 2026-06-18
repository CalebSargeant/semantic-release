# Diatreme

[![CI](https://github.com/magmamoose/diatreme/actions/workflows/ci.yaml/badge.svg)](https://github.com/magmamoose/diatreme/actions/workflows/ci.yaml)
[![Release](https://github.com/magmamoose/diatreme/actions/workflows/release.yaml/badge.svg)](https://github.com/magmamoose/diatreme/actions/workflows/release.yaml)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Diatreme-purple?logo=github)](https://github.com/marketplace/actions/diatreme)
[![License](https://img.shields.io/github/license/magmamoose/diatreme)](https://github.com/magmamoose/diatreme/blob/main/LICENSE)

Diatreme is a composite GitHub Action for semantic release orchestration across TBD and BBD workflows. It can run release-only flows, build PR Docker images, promote already-built GHCR images by retagging, open promotion PRs, enforce Copilot review gates, and normalize release outputs across multiple versioning tools.

This repository is intentionally thin for GitHub Marketplace: the root `action.yml`, the shell helpers it calls, a small validation suite, and release metadata. The Cloudflare Worker that backs public GitHub App auth and Copilot quota checks is owned in [MagmaMoose/platform `apps/diatreme`](https://github.com/MagmaMoose/platform/tree/0acafb2cb991d84e772be412a60c08b7dda3a44e/apps/diatreme). Marketplace metadata stays here.

## Quickstart

Production-only release from `main`, using the hosted Diatreme GitHub App token broker:

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

Install the [Diatreme GitHub App](https://github.com/apps/diatreme/installations/new) on the repository or organization. With the default `versioning-tool: semantic-release-python`, add a `pyproject.toml` semantic-release config and merge conventional commits. Diatreme writes the tag, GitHub Release, changelog, and normalized outputs.

## Required Permissions

For the default `auth-mode: public-app`, the workflow needs `id-token: write` so Diatreme can exchange GitHub OIDC for a short-lived installation token. Keep `contents: read` for checkout. Add only the permissions needed by the selected features:

| Feature | Additional workflow permissions |
| --- | --- |
| Docker PR image push or release promotion | `packages: write` |
| Package publishing to a GitHub Packages feed (`publish-package`) | `packages: write` |
| Promotion PR creation | handled by the Diatreme App token; use `pull-requests: write` only when using `auth-mode: github-token` |
| Copilot review gate with commit statuses | `statuses: write`, `pull-requests: read` |
| Copilot review gate with check runs | `checks: write`, `pull-requests: read` |
| `auth-mode: github-token` release writes | `contents: write`, plus `pull-requests: write` when creating PRs |

## Examples

PR Docker image build:

```yaml
name: CI

on:
  pull_request:

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      pull-requests: read
    steps:
      - uses: magmamoose/diatreme@v1
        with:
          mode: ci
          image_name: my-app
```

Multi-environment TBD with promotion PRs:

```yaml
name: Release

on:
  push:
    branches: [main]
  pull_request:
    types: [closed]

jobs:
  release:
    if: github.event_name == 'push' || github.event.pull_request.merged == true
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
      packages: write
    steps:
      - uses: magmamoose/diatreme@v1
        with:
          mode: release
          deployment-model: tbd-pr
          environment: dev
          environments: '["dev", "staging", "prod"]'
          prerelease-identifiers: '{"dev": "dev", "staging": "rc"}'
          create-promotion-pr: 'true'
          image_name: my-app
```

Branch-based development:

```yaml
steps:
  - uses: magmamoose/diatreme@v1
    with:
      deployment-model: bbd
      branch-map: '{"develop": "dev", "release/*": "staging", "main": "prod"}'
```

## Publishing language packages

Set `publish-package: true` and pick a `package-ecosystem` to pack and push a
library package using the version Diatreme just computed — instead of bolting a
separate `pack`/`push` step onto your release workflow. Publishing is opt-in,
runs only when a new version was released (`released == true`), and inherits the
same environment gating as versioning: dev/staging runs publish the prerelease
version (e.g. `1.2.3-rc.1`), prod runs publish the stable version. The package
is pushed before the GitHub Release is published, so a `release:published`
listener finds it already in the feed.

Supported ecosystems:

- `nuget` — `dotnet pack` + `dotnet nuget push`.
- `pip` — `python -m build` + `twine upload`.
- `npm` — `npm publish` (prereleases go to a non-`latest` dist-tag named after
  the environment's prerelease identifier).

Publish a NuGet package to a private GitHub Enterprise feed, with versioning and
publishing in a single Diatreme call:

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
      packages: write
    steps:
      - uses: magmamoose/diatreme@v1
        with:
          versioning-tool: gitversion
          environment: prod
          environments: '["prod"]'
          prerelease-identifiers: '{}'
          publish-package: 'true'
          package-ecosystem: nuget
          package-path: src/MyLibrary/MyLibrary.csproj
          package-feed-url: https://nuget.example.ghe.com/my-org/index.json
          package-token: ${{ secrets.NUGET_FEED_TOKEN }}
```

For the repository owner's GitHub Packages NuGet feed, omit `package-feed-url`
and `package-token` — they default to `https://nuget.pkg.github.com/<owner>/index.json`
and the workflow `GITHUB_TOKEN` (which needs `packages: write`).

> When `package-ecosystem: npm`, let Diatreme do the publish — set
> `npmPublish: false` on `@semantic-release/npm` so versioning and publishing
> don't both push the package.

## Inputs

All inputs are optional unless noted. Defaults match `action.yml`.

| Input | Default | Purpose |
| --- | --- | --- |
| `mode` | `release` | `ci`, `release`, or `enable-auto-merge`. |
| `auth-mode` | `public-app` | Token source: hosted public App, private App, workflow token, or auto. |
| `token-broker-url` | `https://api.diatreme.magmamoose.com` | Hosted broker base URL override. |
| `oidc-audience` | `diatreme` | OIDC audience used for public App auth. |
| `versioning-tool` | `semantic-release-python` | `semantic-release-python`, `semantic-release-npm`, `gitversion`, or `release-please`. |
| `deployment-model` | `tbd` | `tbd`, `bbd`, or `tbd-pr`. |
| `branch-map` | `''` | JSON branch-to-environment map for BBD. |
| `promote-branch-prefix` | `promote` | Branch prefix for `tbd-pr` promotion PRs. |
| `promote-target-branch` | `main` | Target branch for promotion PRs. |
| `create-promotion-pr` | `false` | Open or refresh the next environment promotion PR after prerelease. |
| `environment` | `''` | Target environment, required for plain `tbd`. |
| `environments` | `["dev", "staging", "prod"]` | Ordered environment list; last entry is stable production. |
| `prerelease-identifiers` | `{"dev": "dev", "staging": "rc"}` | Environment-to-prerelease suffix map. |
| `tag-prefix` | `v` | Version tag prefix. |
| `github-token` | `''` | Override token for GHCR login and github-token auth mode. |
| `app-id` | `''` | Private GitHub App ID. |
| `app-private-key` | `''` | Private GitHub App PEM. |
| `submodules` | `false` | Pass-through to checkout: `false`, `true`, or `recursive`. |
| `image_name` | `''` | Image name without registry or owner. Required for `mode: ci`. |
| `bake_file` | `docker-bake.hcl` | Docker Bake file. |
| `bake_target` | `default` | Docker Bake target or group. |
| `registry` | `ghcr.io` | Container registry. |
| `registry-username` | `''` | Explicit registry login username. |
| `registry-password` | `''` | Explicit registry login password or token. |
| `platforms` | `linux/amd64` | Target platforms for CI builds and fallback fresh builds. |
| `build-github-token` | `''` | Docker Bake secret `github_token` for private package installs. |
| `publish-package` | `false` | Pack and push a language package to `package-feed-url` after versioning. Opt-in. |
| `package-ecosystem` | `''` | `nuget`, `pip`, or `npm`. Required when `publish-package` is true. |
| `package-path` | `''` | Project/path to pack/build/publish. Defaults to `working-directory`. |
| `package-feed-url` | `''` | Feed/registry URL. Defaults to the owner's GitHub Packages NuGet feed for `nuget`. |
| `package-token` | `''` | Feed auth token. Defaults to the workflow `GITHUB_TOKEN` (GitHub Packages). |
| `package-username` | `''` | Feed username for `pip`/twine. Defaults to `__token__`. Ignored by nuget/npm. |
| `dotnet-version` | `8.0.x` | .NET SDK version for `package-ecosystem: nuget`. |
| `python-version` | `3.x` | Python version for `package-ecosystem: pip`. |
| `node-version` | `20` | Node.js version for `package-ecosystem: npm`. |
| `enforce_branch_naming` | `true` | Enforce TBD PR branch naming in `mode: ci`. |
| `require-copilot-review` | `false` | Require a fresh Copilot PR review before CI passes. |
| `copilot-review-freshness` | `after_latest_commit` | Freshness rule for Copilot review acceptance. |
| `copilot-review-allowed-logins` | `["copilot-pull-request-reviewer[bot]"]` | JSON list of accepted reviewer logins. |
| `copilot-review-allow-login-pattern` | `false` | Treat allowed logins as patterns. |
| `copilot-review-fail-on-unknown-identity` | `true` | Fail when reviewer identity cannot be resolved. |
| `copilot-review-ignore-drafts` | `true` | Pass draft PRs without requiring Copilot review. |
| `copilot-review-ignore-labels` | `[]` | JSON labels that bypass the Copilot review gate. |
| `copilot-review-ignore-authors` | `[]` | JSON author logins that bypass the Copilot review gate. |
| `copilot-review-ignore-paths` | `[]` | JSON path globs that bypass the Copilot review gate. |
| `copilot-review-reporter` | `commit-status` | Report as `commit-status` or `check-run`. |
| `copilot-review-check-name` | `Diatreme / Require Copilot Review` | Status/check name to protect. |
| `copilot-review-quota-check-url` | `''` | Optional Copilot quota endpoint. Public App mode derives this from the broker URL. |
| `aggregate-github-projects` | `false` | Append linked Projects v2 items to release docs. |
| `move-github-projects-on-release` | `false` | Move linked Projects v2 items after release. |
| `github-projects-target-status` | `Released` | Target Projects v2 status. |
| `github-projects-move-on-environments` | `@last` | Environments where Projects movement runs. |
| `admin-required-from` | `@last` | Environments where manual production releases require repo admin. |
| `working-directory` | `.` | Repository subdirectory where versioning runs. |
| `create-release` | `true` | Create GitHub Release when the backend supports it. |
| `changelog` | `true` | Let supported backends update changelogs. |
| `force-bump` | `''` | Force semantic-release-python bump level. |
| `version-override` | `''` | Create this exact version instead of deriving one. |
| `version-file` | `''` | Tracked file to update with the released version. |
| `version-file-json-path` | `.Application.Version` | JSON path for version-file injection. |
| `version-file-yaml-path` | `.appVersion` | YAML path for version-file injection. |
| `aggregate-clickup-tickets` | `false` | Append ClickUp ticket links from the release range. |
| `gitversion-spec` | `6.x` | GitVersion action version spec. |
| `gitversion-config` | `GitVersion.yml` | GitVersion config file. |
| `gitversion-appsettings-file` | `''` | Deprecated; use `version-file`. |
| `gitversion-appsettings-version-path` | `''` | Deprecated; use `version-file-json-path`. |
| `release-please-release-type` | `simple` | release-please release type. |
| `release-please-config-file` | `release-please-config.json` | release-please config file. |
| `pr-number` | `''` | PR number for `mode: enable-auto-merge`. |
| `auto-merge-method` | `squash` | Auto-merge method: `squash`, `merge`, or `rebase`. |

## Outputs

| Output | Description |
| --- | --- |
| `version` | Semver version string without prefix, such as `1.2.3` or `1.2.3-rc.1`. |
| `tag` | Full git tag with prefix, such as `v1.2.3`. |
| `is-prerelease` | `true` when this environment produces a prerelease. |
| `released` | `true` when a new version was created and published. |
| `prerelease-identifier` | Prerelease identifier, or empty for production. |
| `resolved-environment` | The resolved environment name. |
| `package-published` | `true` when a language package was packed and pushed to the configured feed. |

## Release Notes

Use immutable tags or SHAs for strict reproducibility. `@v1` is the floating major tag that this repository updates after each stable release. The root release workflow dogfoods `uses: ./`, then force-updates the matching major tag after semantic-release publishes a stable version.

Docker promotion prefers `docker buildx imagetools create` so multi-arch manifests are preserved. For the known GitHub Enterprise Packages referrers-index parse error, Diatreme falls back to pull/tag/push for single-arch images, then to a fresh Docker Bake build if retagging cannot work.

A Magma Moose product.
