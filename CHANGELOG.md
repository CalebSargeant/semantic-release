# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

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

- Leaned the Marketplace repository down to the published action surface:
  root metadata, runtime scripts, Marketplace README, release metadata, and
  action validation. The Diatreme Worker source now lives only in the
  MagmaMoose platform monorepo.
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
