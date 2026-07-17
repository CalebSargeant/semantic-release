#!/usr/bin/env bash
# Verify that a pr-<N> CI image was built from the code being released before
# `mode: release` promotes (retags) it to the release tag.
#
# Why this exists: a PR whose branch is behind the target branch keeps the CI
# image built from its last synthetic merge. Merging that PR and promoting its
# pr-<N> image blesses weeks-old code with a brand-new release tag (a stale
# dependabot PR shipped v1.4.0-era code as v1.6.1 in magmamoose/nievah on
# 2026-07-17). Promotion is an optimization; correctness requires proof that
# the image matches the release commit.
#
# How: `mode: ci` stamps every image with
#   org.opencontainers.image.revision        the commit the image was built from
#   com.magmamoose.diatreme.git-tree         that commit's git tree hash
# The git tree is the comparison that actually matters: a squash/merge/rebase
# merge of an up-to-date PR produces a commit whose *tree* equals the tree of
# the synthetic merge CI built from, even though the commit SHAs differ. A PR
# merged behind the branch tip produces a different tree, which is exactly the
# stale case.
#
# Decision:
#   - git-tree label present  → compare against the release commit's tree.
#   - only revision label     → resolve that commit's tree (local git first,
#     then the commits API — the synthetic PR merge commit is usually not in
#     the release checkout) and compare.
#   - no labels / unresolvable / uninspectable → NOT verified. Images built by
#     a pre-provenance Diatreme CI take the fresh-build fallback once; their
#     next CI build carries the labels.
#
# Required env:
#   SOURCE          - image ref to verify (e.g. ghcr.io/acme/app:pr-30).
#   RELEASE_COMMIT  - commit SHA the release is being cut for (the merged PR's
#                     commit on the target branch).
#
# Optional env:
#   REPO_FULL       - owner/repo, enables the commits-API fallback.
#   GH_TOKEN        - token for that fallback.
#
# Exit codes:
#   0 - verified: the image was built from a tree identical to the release
#       commit's tree; safe to promote.
#   1 - not verified (stale, unlabelled, or uninspectable): the caller must
#       fall back to a fresh build. Never fails the release itself.

set -euo pipefail

SOURCE="${SOURCE:-}"
RELEASE_COMMIT="${RELEASE_COMMIT:-}"
REPO_FULL="${REPO_FULL:-}"

TREE_LABEL="com.magmamoose.diatreme.git-tree"
REVISION_LABEL="org.opencontainers.image.revision"

if [ -z "${SOURCE}" ] || [ -z "${RELEASE_COMMIT}" ]; then
  echo "::warning::verify-promote-source: SOURCE and RELEASE_COMMIT are required — cannot verify; falling back to a fresh build."
  exit 1
fi

# Resolve a commit SHA to its git tree hash: the release checkout first, then
# the commits API (synthetic refs/pull/N/merge commits are not fetched by
# actions/checkout, but GitHub can still serve the object).
resolve_tree() {
  local sha="$1" tree=""
  tree=$(git rev-parse --verify --quiet "${sha}^{tree}" 2>/dev/null || true)
  if [ -z "${tree}" ] && [ -n "${REPO_FULL}" ]; then
    tree=$(gh api "repos/${REPO_FULL}/git/commits/${sha}" --jq '.tree.sha' 2>/dev/null || true)
  fi
  printf '%s' "${tree}"
}

RELEASE_TREE=$(resolve_tree "${RELEASE_COMMIT}")
if [ -z "${RELEASE_TREE}" ]; then
  echo "::warning::verify-promote-source: could not resolve the tree of release commit ${RELEASE_COMMIT} — cannot verify ${SOURCE}; falling back to a fresh build."
  exit 1
fi

# Pull the image config off the registry. `{{json .Image}}` is the OCI image
# config for a single-platform image, or a platform→config map for a manifest
# list; the label lookup below handles both shapes.
if ! CONFIG_JSON=$(docker buildx imagetools inspect "${SOURCE}" --format '{{json .Image}}' 2>/dev/null) \
  || [ -z "${CONFIG_JSON}" ]; then
  echo "::warning::verify-promote-source: could not inspect ${SOURCE} — cannot verify its provenance; falling back to a fresh build."
  exit 1
fi

label_value() {
  printf '%s' "${CONFIG_JSON}" | jq -r --arg key "$1" \
    '[.. | objects | .[$key]? | select(type == "string" and . != "")] | .[0] // empty' \
    2>/dev/null || true
}

IMAGE_TREE=$(label_value "${TREE_LABEL}")
IMAGE_REVISION=$(label_value "${REVISION_LABEL}")

# Prefer the tree label — a direct statement of what the image was built from.
if [ -z "${IMAGE_TREE}" ] && [ -n "${IMAGE_REVISION}" ]; then
  IMAGE_TREE=$(resolve_tree "${IMAGE_REVISION}")
  if [ -z "${IMAGE_TREE}" ]; then
    echo "::warning::verify-promote-source: ${SOURCE} was built from ${IMAGE_REVISION}, but that commit's tree could not be resolved (locally or via the API) — cannot verify; falling back to a fresh build."
    exit 1
  fi
fi

if [ -z "${IMAGE_TREE}" ]; then
  echo "::warning::verify-promote-source: ${SOURCE} carries neither ${TREE_LABEL} nor ${REVISION_LABEL} (built by a pre-provenance Diatreme CI, or the bake file overrides labels) — cannot verify; falling back to a fresh build."
  exit 1
fi

if [ "${IMAGE_TREE}" == "${RELEASE_TREE}" ]; then
  echo "verify-promote-source: ${SOURCE} verified — built from tree ${IMAGE_TREE}, matching release commit ${RELEASE_COMMIT}."
  exit 0
fi

echo "::warning::verify-promote-source: ${SOURCE} is STALE — built from tree ${IMAGE_TREE}${IMAGE_REVISION:+ (commit ${IMAGE_REVISION})}, but release commit ${RELEASE_COMMIT} has tree ${RELEASE_TREE}. The PR was likely merged while behind the branch tip; falling back to a fresh build so the release tag matches the released code."
exit 1
