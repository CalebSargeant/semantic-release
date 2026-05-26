#!/usr/bin/env bash
# Build an enriched Markdown body for an auto-opened promotion PR.
#
# Inputs (env):
#   GH_TOKEN                authenticated for the target repo
#   OWNER, REPO             repository identity
#   TAG, VERSION            the prerelease tag we're promoting
#   ENV                     the source environment (current)
#   NEXT_ENV                the target environment (where the merge will release)
#   PRERELEASE_IDENTIFIER   identifier of the source env (e.g. "dev", "rc")
#                            — used to find the previous tag of the same series
#   PROMOTE_BRANCH_PREFIX   prefix of auto-generated promotion PR branches
#                            (default "promote"); PRs whose head ref starts
#                            with "${PROMOTE_BRANCH_PREFIX}/" are skipped so
#                            they don't clutter the list with action-bot
#                            plumbing.
#
# Output:
#   Writes the rendered Markdown to stdout. The action.yml caller pipes it
#   into `gh pr create --body-file -`.
#
# Behaviour:
#   - Finds the previous prerelease tag of the same identifier and uses it
#     as the range start. Falls back to "all commits in this release" when
#     no previous tag exists.
#   - Lists merged PRs landed in the range (deduped, most-recent-first),
#     each annotated with author and title. Promotion PRs (head ref starts
#     with the promote-branch-prefix) are filtered out — they're plumbing,
#     not reviewable changes.
#   - Lists the loose commits in the range that don't have an associated
#     PR (direct pushes, version-bump commits).
#   - Highlights the originating PR (most recent merged PR in range) at
#     the top of the body so reviewers see who/what triggered this
#     promotion at a glance.
#   - Caps each list at 15 entries and adds an "and N more" line.

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${REPO:?REPO is required}"
: "${TAG:?TAG is required}"
: "${ENV:?ENV is required}"
: "${NEXT_ENV:?NEXT_ENV is required}"
PRERELEASE_IDENTIFIER="${PRERELEASE_IDENTIFIER:-}"
PROMOTE_BRANCH_PREFIX="${PROMOTE_BRANCH_PREFIX:-promote}"

REPO_URL="https://github.com/${OWNER}/${REPO}"

# ─── 1. Find previous prerelease tag of same identifier ───────────────────
PREV_TAG=""
if [ -n "${PRERELEASE_IDENTIFIER}" ]; then
  PREV_TAG=$(git tag -l --sort=-v:refname \
    | grep -E "\\-${PRERELEASE_IDENTIFIER}\\.[0-9]+$" \
    | grep -v "^${TAG}$" \
    | head -1 || true)
fi

if [ -n "${PREV_TAG}" ]; then
  RANGE="${PREV_TAG}..${TAG}"
  RANGE_DESC="changes since [\`${PREV_TAG}\`](${REPO_URL}/releases/tag/${PREV_TAG})"
else
  RANGE="${TAG}"
  RANGE_DESC="all commits in this release (no previous \`${PRERELEASE_IDENTIFIER}\` tag)"
fi

# ─── 2. Walk commits, separate "PR-merged" from "loose" ───────────────────
TMP_PRS=$(mktemp)
TMP_LOOSE=$(mktemp)
trap 'rm -f "${TMP_PRS}" "${TMP_LOOSE}"' EXIT

# Cap at 50 commits — anything past that and the body becomes spammy.
COMMITS=$(git log "${RANGE}" --pretty=format:'%H|%h|%s' 2>/dev/null | head -50 || true)

while IFS='|' read -r SHA SHORT_SHA SUBJECT; do
  [ -z "${SHA}" ] && continue
  # `first(...) // empty` so a commit with zero matching PRs produces an
  # empty string instead of "null\tnull\tnull" — the previous `.[0] |
  # "..."` form rendered null fields literally and slipped past the
  # post-process guard.
  # Also skip auto-generated promotion PRs (head ref starts with the
  # configured promote-branch-prefix) — they're action-bot plumbing
  # and add noise to the reviewer's list of "what changed in this range".
  PR_LINE=$(gh api "repos/${OWNER}/${REPO}/commits/${SHA}/pulls" \
    --jq "first(
            .[]
            | select(.merged_at != null)
            | select((.head.ref // \"\") | startswith(\"${PROMOTE_BRANCH_PREFIX}/\") | not)
            | \"\(.number)\t\(.user.login)\t\(.title)\"
          ) // empty" \
    2>/dev/null || true)
  if [ -n "${PR_LINE}" ]; then
    echo "${PR_LINE}" >> "${TMP_PRS}"
  else
    # Skip the auto-version-bump commits (their subject is just the
    # version number) and the appsettings-persist commits — both add
    # noise without telling the reviewer anything new.
    case "${SUBJECT}" in
      *"[skip ci]"*|"chore(release):"*)
        continue
        ;;
      [0-9]*\.[0-9]*\.[0-9]*)
        # Plain "1.2.3" or "1.2.3-dev.1" subject from python-semantic-release
        continue
        ;;
    esac
    printf '%s\t%s\n' "${SHORT_SHA}" "${SUBJECT}" >> "${TMP_LOOSE}"
  fi
done <<< "${COMMITS}"

# Dedupe PRs (one PR can land via multiple commits when squashed-then-cherry-picked).
PRS=$(awk -F'\t' '!seen[$1]++' "${TMP_PRS}")
PR_COUNT=$(printf '%s\n' "${PRS}" | grep -c '^' || echo 0)
LOOSE_COUNT=$(grep -c '^' "${TMP_LOOSE}" 2>/dev/null || echo 0)

# Originating PR = most recent merged PR in the range (top of TMP_PRS).
ORIGIN_PR_LINE=""
if [ -n "${PRS}" ]; then
  FIRST_PR=$(printf '%s\n' "${PRS}" | head -1)
  PR_NUM=$(echo "${FIRST_PR}" | cut -f1)
  PR_LOGIN=$(echo "${FIRST_PR}" | cut -f2)
  PR_TITLE=$(echo "${FIRST_PR}" | cut -f3)
  ORIGIN_PR_LINE="- **Originating PR**: [#${PR_NUM}](${REPO_URL}/pull/${PR_NUM}) — _${PR_TITLE}_ by @${PR_LOGIN}"
fi

# ─── 3. Render Markdown ───────────────────────────────────────────────────
{
  echo "Merging this PR will trigger the **${NEXT_ENV}** release for [\`${TAG}\`](${REPO_URL}/releases/tag/${TAG})."
  echo
  echo "## Source"
  echo
  echo "- **Promotion**: \`${ENV}\` → **\`${NEXT_ENV}\`**"
  echo "- **Tag**: [\`${TAG}\`](${REPO_URL}/releases/tag/${TAG})"
  if [ -n "${PREV_TAG}" ]; then
    echo "- **Previous \`${PRERELEASE_IDENTIFIER}\` tag**: [\`${PREV_TAG}\`](${REPO_URL}/releases/tag/${PREV_TAG})"
  fi
  if [ -n "${ORIGIN_PR_LINE}" ]; then
    echo "${ORIGIN_PR_LINE}"
  fi
  echo
  echo "## Pull requests in this release"
  echo
  if [ -n "${PRS}" ]; then
    printf '%s\n' "${PRS}" | head -15 | while IFS=$'\t' read -r N L T; do
      echo "- [#${N}](${REPO_URL}/pull/${N}) — _${T}_ by @${L}"
    done
    if [ "${PR_COUNT}" -gt 15 ]; then
      echo "- _… and $((PR_COUNT - 15)) more_"
    fi
  else
    echo "_No merged PRs in this range._"
  fi
  if [ "${LOOSE_COUNT}" -gt 0 ]; then
    echo
    echo "## Direct commits"
    echo
    head -15 "${TMP_LOOSE}" | while IFS=$'\t' read -r SHORT SUBJ; do
      echo "- \`${SHORT}\` ${SUBJ}"
    done
    if [ "${LOOSE_COUNT}" -gt 15 ]; then
      echo "- _… and $((LOOSE_COUNT - 15)) more_"
    fi
  fi
  echo
  echo "_Range: ${RANGE_DESC}._"
}
