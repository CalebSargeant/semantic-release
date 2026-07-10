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

- **Versioning-tool autodetection (`versioning-tool: auto`, now the default).**
  Diatreme resolves the versioning tool from repository markers under
  `working-directory` instead of requiring every caller to hardcode one, so a
  single shared release workflow serves repos on python-semantic-release,
  semantic-release (npm), GitVersion, or release-please. Detection is two-tier:
  a tool's own release config wins (`pyproject.toml` `[tool.semantic_release]`,
  `.releaserc*`/`release.config.*`, `GitVersion.yml`,
  `release-please-config.json`/`.release-please-manifest.json`), falling back to
  ecosystem manifests (`pyproject.toml`/`setup.py`, `package.json`,
  `*.csproj`/`*.sln`) with a fixed precedence
  (`semantic-release-python` → `semantic-release-npm` → `gitversion`) so a
  Python repo that also carries a `package.json` still resolves to
  `semantic-release-python`. Conflicting tier-1 configs, or no markers at all,
  fail with an actionable error. Passing an explicit `versioning-tool` skips
  detection and behaves exactly as before. New helper:
  `scripts/detect-versioning-tool.sh`.

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

- **python-semantic-release now runs from a pip install instead of the upstream
  Docker action, cutting ~1 minute off every release run.** GitHub Actions builds
  the image of any Docker action a composite action references during job setup —
  before any step runs, and regardless of that step's `if:` condition. Referencing
  `python-semantic-release/python-semantic-release` therefore made *every* Diatreme
  release run spend ~55s on a `Build python-semantic-release/...` step, including
  the majority of repos that resolve to `gitversion`, `release-please` or
  `semantic-release-npm` and then skip the step entirely. Upstream publishes no
  pre-built image, so a `docker://` reference was not an option. The new
  `scripts/run-python-semantic-release.sh` installs the pinned CLI into a
  throwaway venv (~5.7 MB of wheels, no compiler needed) and invokes it directly;
  because the CLI writes its own `$GITHUB_OUTPUT` keys, `steps.psr.outputs.*` and
  the `Normalize outputs` step are unchanged. Repos on another versioning tool now
  pay nothing at all. Requires the runner to reach PyPI, as the
  `semantic-release-npm` path already requires npm.
- **python-semantic-release is bumped `10.4.1` → `10.6.1`, and the pin moved to
  `scripts/psr-requirements.txt` where Dependabot tracks it.** The pin could
  previously not be raised: v10.5.0+ moved the action container to
  `python:3.14-slim-trixie`, whose `apt install ... cargo` layer breaks whenever
  Docker Hub rebuilds the mutable base, and the image was built from the action's
  Dockerfile so no SHA pin could avoid it. Diatreme no longer builds that image,
  so the constraint is gone — the default changelog templates are byte-identical
  across the two versions, and the `version` flags this action passes are
  unchanged. The Dependabot `ignore` rule that held the pin in place is removed
  with it, and a `pip` ecosystem entry scoped to `/scripts` replaces the
  `github-actions` coverage the `uses:` reference used to get. It is scoped to
  that directory rather than `/` so Dependabot does not treat the root
  `pyproject.toml` — python-semantic-release's own release metadata, which
  declares no dependencies — as a manifest to update.
- The action surface (root metadata, runtime scripts, Marketplace README,
  release metadata, validation) and the Cloudflare Worker backend (`worker/`)
  now live together in this repository and deploy independently. CI validates
  both surfaces.
- The repository release workflow now dogfoods this action directly.

### Fixed

- `versioning-tool: gitversion` no longer requires a `GitVersion.yml`. The
  `gitversion-config` input defaulted to the literal path `GitVersion.yml`,
  which Diatreme forwards to `gittools/actions/gitversion/execute` as
  `configFilePath` — an input that upstream treats as an *optional override*
  and hard-errors on (`GitVersion configuration file not found at
  GitVersion.yml`) when it names a missing file. Every GitVersion repo without
  that file failed, which under `versioning-tool: auto` meant any repo resolved
  to `gitversion` from a bare `*.csproj`/`*.sln` — exactly the repos that carry
  no GitVersion config. The default is now `''`, so GitVersion picks up a
  `GitVersion.yml`/`GitVersion.yaml` when present and otherwise runs on its
  built-in defaults. Setting `gitversion-config` explicitly still errors when
  the path is missing.

  `configFilePath` is now taken from `scripts/detect-versioning-tool.sh`
  (new `config` output) rather than the raw input. Diatreme never sets
  gittools' `targetPath`, so GitVersion runs at the workspace root while
  detection is scoped to `working-directory`; the detect step emits the config
  path with its `working-directory` prefix so the two agree. A subdirectory
  project whose `GitVersion.yml` lives under `working-directory` is now handed
  that file instead of silently falling back to GitVersion's defaults, and a
  relative `gitversion-config` is resolved against `working-directory` to match
  how autodetection scopes its markers.
- `versioning-tool: semantic-release-python` releases no longer break when
  Docker Hub rebuilds `python:3.14-slim-trixie`. The upstream action's
  container moved to that rolling base in v10.5.0, where its `apt install
  ... cargo` build step fails intermittently (apt exit 100). Diatreme no
  longer builds that container at all — it installs the CLI from PyPI (see
  Changed) — so the rolling base image is out of the release path entirely.
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
