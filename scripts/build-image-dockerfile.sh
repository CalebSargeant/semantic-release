#!/usr/bin/env bash
# Build (and push) a single image directly from a Dockerfile with
# `docker buildx build`. This is Diatreme's fallback for repos that have a
# Dockerfile but no Docker Bake file — the bake path (`docker buildx bake`) can't
# run without a bake file, so this mirrors the same knobs Diatreme passes to bake
# (platforms, tags, provenance labels, GHA cache, the github_token build secret,
# --push) using plain `buildx build`.
#
# Reused by two call sites in action.yml:
#   - mode: ci      — build & push the pr-<N> image (with provenance labels so
#                     release-mode promotion can verify the source).
#   - mode: release — the fresh-build fallback when a pr-<N> image can't be
#                     promoted by retag.
#
# Multi-arch: a plain Dockerfile has nowhere to declare a default platform set,
# so with PLATFORMS empty this builds for the builder's default (single) platform.
# Set PLATFORMS (e.g. linux/amd64,linux/arm64) to produce a multi-arch manifest,
# exactly like bake would.
#
# Required env:
#   TAGS       - newline-separated fully-qualified image refs to tag, e.g.
#                ghcr.io/owner/app:pr-12. At least one is required.
#
# Optional env:
#   DOCKERFILE - path to the Dockerfile (default "Dockerfile").
#   CONTEXT    - build context (default ".").
#   PLATFORMS  - comma-separated platforms. Empty ⇒ builder default (single-arch).
#   CACHE_SCOPE- when set, adds GHA cache-from/cache-to at this scope.
#   LABELS     - newline-separated key=value pairs, each added as --label.
#   BUILD_GITHUB_TOKEN - when set, passed as --secret id=github_token,env=... so a
#                Dockerfile using --mount=type=secret,id=github_token can read it.
#   PUSH       - "true" (default) pushes; any other value builds without pushing.
#
# Side effects:
#   Runs `docker buildx build`. On PUSH=true the tagged refs are pushed.

set -euo pipefail

: "${TAGS:?TAGS (newline-separated image refs) is required}"

DOCKERFILE="${DOCKERFILE:-Dockerfile}"
CONTEXT="${CONTEXT:-.}"
PLATFORMS="${PLATFORMS:-}"
CACHE_SCOPE="${CACHE_SCOPE:-}"
LABELS="${LABELS:-}"
BUILD_GITHUB_TOKEN="${BUILD_GITHUB_TOKEN:-}"
PUSH="${PUSH:-true}"

# Strip leading/trailing whitespace — TAGS/LABELS are often passed as YAML
# block-scalar text, which can leave indentation on continuation lines.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

args=(buildx build -f "${DOCKERFILE}")

# Platforms — omit entirely when empty so buildx uses the builder default
# (never pass an empty --platform, which would be an invalid platform).
if [ -n "${PLATFORMS}" ]; then
  args+=(--platform "${PLATFORMS}")
fi

# Tags — one --tag per non-empty line.
tag_count=0
while IFS= read -r tag; do
  tag="$(trim "${tag}")"
  [ -n "${tag}" ] || continue
  args+=(--tag "${tag}")
  tag_count=$((tag_count + 1))
done <<< "${TAGS}"
if [ "${tag_count}" -eq 0 ]; then
  echo "::error::TAGS contained no non-empty image refs." >&2
  exit 1
fi

# Provenance / OCI labels — one --label per non-empty key=value line.
if [ -n "${LABELS}" ]; then
  while IFS= read -r label; do
    label="$(trim "${label}")"
    [ -n "${label}" ] || continue
    args+=(--label "${label}")
  done <<< "${LABELS}"
fi

# GitHub Actions cache — same type=gha cache the bake path uses, scoped per build.
if [ -n "${CACHE_SCOPE}" ]; then
  args+=(--cache-from "type=gha,scope=${CACHE_SCOPE}")
  args+=(--cache-to "type=gha,mode=max,scope=${CACHE_SCOPE}")
fi

# Build secret — the same github_token secret bake consumers wire via
# --mount=type=secret,id=github_token. `env=` reads it from this environment.
if [ -n "${BUILD_GITHUB_TOKEN}" ]; then
  args+=(--secret "id=github_token,env=BUILD_GITHUB_TOKEN")
fi

if [ "${PUSH}" = "true" ]; then
  args+=(--push)
fi

args+=("${CONTEXT}")

echo "docker ${args[*]}"
docker "${args[@]}"
