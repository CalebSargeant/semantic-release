#!/usr/bin/env bash
# Push a release tag to origin with race-safe handling.
#
# Used by the gitversion-tag and version-override-tag steps in action.yml.
# Encapsulates the authenticated-URL resolution + tag-already-exists
# pre-check + create/push/race-recovery loop that those two steps share.
#
# Required env:
#   TAG           - the tag to publish (e.g., v1.2.3)
#   GITHUB_TOKEN  - auth token; embedded into the HTTPS remote URL
#
# Optional env:
#   MESSAGE       - annotated-tag message. If unset/empty, a lightweight
#                   tag is created instead.
#   RELEASE_NOTES - when set, emitted as the `release_notes` output ONLY on a
#                   real release (released=true) — never on a no-op/race skip.
#   GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL  - identity for `git config`; default
#                   to the github-actions bot.
#
# Side effects:
#   - Configures git user.name / user.email only when each is not already
#     set in the local git config. A caller that pre-configures their own
#     identity is preserved.
#   - Writes `latest_tag=${TAG}` and `released=true|false` to $GITHUB_OUTPUT
#     when that variable is set (always set inside an Actions step), plus
#     `release_notes=${RELEASE_NOTES}` on a real release when RELEASE_NOTES is
#     set. The caller is responsible for any other tool-specific outputs.
#   - Writes git push stderr to a per-invocation temp file under
#     ${RUNNER_TEMP:-/tmp} and removes it on exit via a trap, so
#     concurrent invocations in the same job don't read each other's
#     diagnostics.
#
# Exit codes:
#   0 - tag is on remote (either we pushed it, or a concurrent run did)
#   1 - unsupported remote URL, or push failed for a non-race reason
#
# Race semantics:
#   - If the remote already has TAG when we start, we treat that as a
#     no-op release (released=false) and exit 0.
#   - If we create the tag locally and the push fails, we re-check the
#     remote. If TAG now exists, we lost a race between check and push;
#     drop the local tag and exit 0 with released=false.
#   - Otherwise we surface the first 3 lines of git push stderr and
#     exit 1 so the workflow can diagnose auth / ruleset / network issues.

set -euo pipefail

: "${TAG:?TAG is required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"

# Only set git identity when the caller hasn't already configured one.
# `git config --get` exits non-zero when the key is unset.
if ! git config --get user.name >/dev/null 2>&1; then
  git config user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
fi
if ! git config --get user.email >/dev/null 2>&1; then
  git config user.email "${GIT_AUTHOR_EMAIL:-github-actions[bot]@users.noreply.github.com}"
fi

# Read the raw remote.origin.url config rather than `git remote get-url`
# so any caller-side `insteadOf` rewrites don't change what we see — we
# want the URL the caller actually wrote, so we can synthesise a
# matching token-prefixed form. Git applies any rewrites again when it
# pushes, so the eventual target is unchanged.
REMOTE_URL=$(git config --get remote.origin.url)
if [[ "${REMOTE_URL}" =~ ^https:// ]]; then
  AUTHED_URL="https://x-access-token:${GITHUB_TOKEN}@${REMOTE_URL#https://}"
elif [[ "${REMOTE_URL}" =~ ^git@([^:]+):(.+)$ ]]; then
  AUTHED_URL="https://x-access-token:${GITHUB_TOKEN}@${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
else
  echo "::error::Unsupported git remote URL format for authenticated tag push: ${REMOTE_URL}"
  exit 1
fi

# Per-invocation stderr capture, cleaned up on exit. Two concurrent
# invocations in the same job (e.g. a matrix run) would otherwise
# read each other's diagnostics from a shared /tmp path.
PUSH_ERR=$(mktemp "${RUNNER_TEMP:-/tmp}/tag_push.err.XXXXXX")
trap 'rm -f "${PUSH_ERR}"' EXIT

emit() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >> "${GITHUB_OUTPUT}"
  fi
}

# Pre-check: a parallel run may have already published this tag.
if git ls-remote --tags "${AUTHED_URL}" "refs/tags/${TAG}" 2>/dev/null | grep -Fq "refs/tags/${TAG}"; then
  echo "::notice::Tag ${TAG} already exists on remote — a parallel run published it. Treating this run as a no-op release."
  emit latest_tag "${TAG}"
  emit released "false"
  exit 0
fi

# Create the tag (annotated when MESSAGE is provided, lightweight otherwise).
if [ -n "${MESSAGE:-}" ]; then
  git tag -a "${TAG}" -m "${MESSAGE}"
else
  git tag "${TAG}"
fi

# Push, with race recovery: if the push fails and the tag has since
# appeared on the remote, treat as a clean race loss.
if ! git push "${AUTHED_URL}" "${TAG}" 2>"${PUSH_ERR}"; then
  if git ls-remote --tags "${AUTHED_URL}" "refs/tags/${TAG}" 2>/dev/null | grep -Fq "refs/tags/${TAG}"; then
    echo "::notice::Tag ${TAG} now exists on remote (parallel run won the race between check and push). Skipping."
    git tag -d "${TAG}" 2>/dev/null || true
    emit latest_tag "${TAG}"
    emit released "false"
    exit 0
  fi
  echo "::error::Failed to push tag ${TAG}: $(head -3 "${PUSH_ERR}" 2>/dev/null)"
  exit 1
fi

emit latest_tag "${TAG}"
emit released "true"
if [ -n "${RELEASE_NOTES:-}" ]; then
  emit release_notes "${RELEASE_NOTES}"
fi
