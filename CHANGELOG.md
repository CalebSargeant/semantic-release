# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Removed

- **Scoped Diatreme to release/deployment orchestration only.** Removed the
  Copilot review gate (the `require-copilot-review` / `copilot-review-*` inputs
  and `scripts/require-copilot-review.sh`), and from the worker: Copilot-comment
  triage, the inline LLM fixer, CodeQL/GHAS alert triage, Claude Code agent
  dispatch, the `/copilot-quota` endpoint and its billing cron, the OAuth
  user-attribution flow, and the `TRIAGE_LLM_*` / `DISPATCH_*` config. The worker
  is now just the GitHub App backend for releases: the OIDC **token broker** and
  the **App/bot-attributed commit/tag signer** (`/sign` now mints an App
  installation token instead of a user OAuth token), plus `/releases` and the
  push auto-update webhook.

### Added

- **Image scanning and SBOMs (`mode: ci`).** After the `pr-<N>` image is built,
  Diatreme can scan the assembled image with Trivy and route the results to two
  sinks: a CycloneDX **SBOM → Dependency-Track** (its own assembled-image
  project, distinct from any source-dependency SBOM for the repo) and, optionally,
  **findings → DefectDojo** (OS CVEs, image misconfigurations, secrets in layers
  — what SBOM matching misses). Opt-in via `image-scan: true`. New inputs:
  `image-scan`, `image-scan-severity`, `image-scan-scanners`, `image-scan-gate`,
  `image-scan-strict`,
  `dependency-track-url` / `-api-key` / `-project-name` / `-project-version` /
  `-auto-create`,
  `defectdojo-url` / `-api-key` / `-engagement` / `-product-name` /
  `-product-type` / `-engagement-name` / `-close-old`. New outputs:
  `image-scanned`, `image-findings`. Reporting is visibility-first — a
  successful scan never blocks the PR unless `image-scan-gate` is on, and both
  sinks are failure-isolated (an outage logs a warning, never fails the build).
  A scanner that cannot run is a build error, not "0 findings". The scanned
  `pr-<N>` image is the exact artifact release promotes by digest, so what is
  scanned is what ships. The upload wire format matches Chargate's known-working
  clients: the SBOM is `POST`ed to Dependency-Track `/api/v1/bom` as a multipart
  raw file (UTF-8 BOM stripped, identifying User-Agent), and DefectDojo imports
  via `reimport-scan` (idempotent across PR re-runs, `close_old_findings`).
- Shared public GitHub App auth through the Cloudflare Worker token broker.
- Repository CI for action metadata parsing, actionlint, ShellCheck, and Bats tests.
- `registry-username` and `registry-password` inputs so callers can target
  container registries that don't accept GHCR-style `github.actor` +
  workflow-token auth — GHES `containers.<host>`, Harbor, Artifactory,
  Nexus, ACR, etc. Defaults to current behaviour when both are blank.
- `submodules` input passed through to the internal `actions/checkout`
  step. When set non-false under `auth-mode: private-app` / `auto`,
  the App installation token is broadened from current-repo scope to
  owner scope so sibling-repo submodules in the same org can be fetched.
  Default `false` keeps existing behaviour.

### Changed

- The action surface (root metadata, runtime scripts, Marketplace README,
  release metadata, validation) and the Cloudflare Worker backend (`worker/`)
  now live together in this repository and deploy independently. CI validates
  both surfaces.
- The repository release workflow now dogfoods this action directly.

### Fixed

- `versioning-tool: semantic-release-npm` no longer crashes with
  `Cannot find module '@semantic-release/changelog'` (or `/git`,
  `/github`) when the consumer's `.releaserc.json` configures
  non-bundled plugins. semantic-release and its plugins are now
  installed into the same `node_modules` and the locally-installed
  binary is run directly, instead of `npx semantic-release` resolving
  semantic-release from an isolated `_npx/<hash>` cache where the
  plugins were not on the resolve path. The plugin set is derived from
  the consumer's config (plus a baseline) so any plugin they configure
  is installed, not just a hard-coded list.
- `gh` CLI calls (`gh release create`, `gh api`, etc.) now use the
  GitHub host the workflow is actually running on. Previously they
  defaulted to github.com, which broke `Publish GitHub Release` and
  the ClickUp / Projects v2 metadata steps on GHE Server runners
  with `none of the git remotes configured for this repository
  point to a known GitHub host`.
- The image-promotion retag now falls back from `docker buildx
  imagetools create` to a plain `docker pull/tag/push` sequence when
  (and only when) the registry returns the GHE Packages
  referrers-index parse error (`failed to decode referrers index:
  invalid character '<' looking for beginning of value`). `imagetools
  create` remains the primary path on every registry that implements
  the OCI referrers spec — it preserves multi-arch manifest lists,
  which `docker pull/tag/push` collapses to the runner's platform.
  The existing fresh-build fallback still runs when both retag paths
  fail.

<!-- semantic-release will append entries above this line -->
