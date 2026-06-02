# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- Shared public GitHub App auth through the Cloudflare Worker token broker.
- Repository CI for actionlint, markdownlint, Docker Bake validation, Bats shell tests, and Worker checks.
- `registry-username` and `registry-password` inputs so callers can target
  container registries that don't accept GHCR-style `github.actor` +
  workflow-token auth — GHES `containers.<host>`, Harbor, Artifactory,
  Nexus, ACR, etc. Defaults to current behaviour when both are blank.
- `submodules` input passed through to the internal `actions/checkout`
  step. When set non-false under `auth-mode: private-app` / `auto`,
  the App installation token is broadened from current-repo scope to
  owner scope so sibling-repo submodules in the same org can be fetched.
  Default `false` keeps existing behaviour.
- Copilot comment triage is now configurable on the broker worker: the
  deploy workflow uploads `TRIAGE_LLM_API_KEY` to the Worker when the
  same-named Actions secret is set (skipped when unset, so triage stays
  opt-in and existing deploys are unaffected). The triage secrets are
  documented in `worker/wrangler.jsonc`, `worker/.dev.vars.example`, and
  the Copilot review guide. Without a key the worker still reports
  `triage disabled (no LLM key configured on the worker)`.
- Comment-triage `fix` verdicts are now routed by an LLM-estimated effort:
  a small/localized fix is applied inline — a stronger fixer LLM
  (`TRIAGE_FIX_LLM_MODEL`, e.g. `deepseek-v4-pro`) rewrites the one file and
  the change is committed to the PR branch via `createCommitOnBranch`
  (App-attributed, GitHub-signed) — while a large fix goes to the Claude
  Code dispatch routine. The inline fixer is off unless
  `TRIAGE_FIX_LLM_MODEL` is set; it is single-file, size-capped, drops
  no-op rewrites, and falls back to dispatch on any failure.

### Changed

- The repository release workflow now dogfoods this action directly.
- Convenience reusable workflows pin the root action at `v1` instead of `main`.

### Fixed

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
