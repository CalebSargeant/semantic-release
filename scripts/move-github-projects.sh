#!/usr/bin/env bash
# Move every Projects v2 item linked to issues/PRs in the release range to
# a target Status value. Opt-in via `move-github-projects-on-release`.
#
# Inputs (env):
#   GH_TOKEN              token with org Projects v2 write scope
#   OWNER, REPO           repository identity
#   TAG                   tag of the published release
#   PRERELEASE_IDENTIFIER (optional) prerelease identifier — used when
#                         picking the previous tag of the same series
#   TARGET_STATUS         the Status name to move items to (must exist
#                         on the project's Status field as a single-select
#                         option)
#
# Behaviour:
#   - Walks commits ${PREV_TAG}..${TAG}, gathers issue/PR numbers.
#   - For each ref, looks up its Projects v2 items.
#   - For each item, finds the target Status option ID on its parent
#     project and updates it via updateProjectV2ItemFieldValue.
#   - Skips items where the project has no matching status option (logs
#     a warning, never fails the run).

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${REPO:?REPO is required}"
: "${TAG:?TAG is required}"
: "${TARGET_STATUS:?TARGET_STATUS is required}"
PRERELEASE_IDENTIFIER="${PRERELEASE_IDENTIFIER:-}"
TAG_PREFIX="${TAG_PREFIX:-}"

log() { echo "::notice::[projects-move] $*"; }
warn() { echo "::warning::[projects-move] $*"; }

# ─── 1. Resolve commit range — same logic as append-github-projects.sh ───
# "${TAG_PREFIX}*" scopes the lookup to one package's tag series; an empty
# prefix widens the glob to every tag rather than matching none.
PREV_TAG=""
if [ -n "${PRERELEASE_IDENTIFIER}" ]; then
  PREV_TAG=$(git tag -l "${TAG_PREFIX}*" --sort=-v:refname \
    | grep -E "\\-${PRERELEASE_IDENTIFIER}\\.[0-9]+$" \
    | grep -v "^${TAG}$" \
    | head -1 || true)
fi
if [ -z "${PREV_TAG}" ]; then
  PREV_TAG=$(git tag -l "${TAG_PREFIX}*" --sort=-v:refname \
    | grep -vE -- "-[a-zA-Z][^.]*\\.[0-9]+$" \
    | grep -v "^${TAG}$" \
    | head -1 || true)
fi

if [ -z "${PREV_TAG}" ]; then
  COMMIT_RANGE="${TAG}"
else
  COMMIT_RANGE="${PREV_TAG}..${TAG}"
fi
log "Resolving refs in ${COMMIT_RANGE}."

# ─── 2. Collect issue/PR numbers ───────────────────────────────────────────
TMP_REFS=$(mktemp)
trap 'rm -f "${TMP_REFS}"' EXIT

# Same collection logic as append-github-projects.sh:
#   1. #NNN refs in commit messages
#   2. PRs landed in the range, plus #NNN refs in their bodies
git log --pretty=format:'%B' "${COMMIT_RANGE}" 2>/dev/null \
  | grep -oE '#[0-9]+' \
  | tr -d '#' \
  | sort -un \
  >> "${TMP_REFS}" || true

COMMIT_SHAS=$(git log --pretty=format:'%H' "${COMMIT_RANGE}" 2>/dev/null || true)
for SHA in ${COMMIT_SHAS}; do
  PR_NUMS=$(gh api "repos/${OWNER}/${REPO}/commits/${SHA}/pulls" \
    --jq '.[].number' 2>/dev/null || true)
  for PR in ${PR_NUMS}; do
    echo "${PR}" >> "${TMP_REFS}"
    PR_BODY=$(gh api "repos/${OWNER}/${REPO}/pulls/${PR}" --jq '.body // ""' 2>/dev/null || echo "")
    echo "${PR_BODY}" \
      | grep -oE '#[0-9]+' \
      | tr -d '#' \
      >> "${TMP_REFS}" || true
  done
done

REFS=$(sort -un "${TMP_REFS}")
if [ -z "${REFS}" ]; then
  log "No issue/PR refs in range — nothing to move."
  exit 0
fi
log "Will check $(echo "${REFS}" | wc -l | tr -d ' ') refs for project items."

# ─── 3. For each ref, fetch project items + their parent Status field ─────
ITEM_QUERY='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) { ...Items }
    pullRequest(number: $number) { ...Items }
  }
}
fragment Items on Node {
  ... on Issue {
    projectItems(first: 20) { nodes { ...Item } }
  }
  ... on PullRequest {
    projectItems(first: 20) { nodes { ...Item } }
  }
}
fragment Item on ProjectV2Item {
  id
  project {
    id
    title
    field(name: "Status") {
      ... on ProjectV2SingleSelectField {
        id
        options { id name }
      }
    }
  }
}
'

MOVED=0
SKIPPED=0

for NUM in ${REFS}; do
  # See append-github-projects.sh for why we don't use `|| echo "{}"`:
  # the GraphQL response returns BOTH data and a NOT_FOUND error when the
  # number is an issue but not a PR (or vice versa). The `||` fallback
  # would concatenate `{}` onto valid stdout and produce a multi-document
  # JSON stream that breaks downstream jq.
  RESPONSE=$(gh api graphql \
    -f query="${ITEM_QUERY}" \
    -F owner="${OWNER}" \
    -F repo="${REPO}" \
    -F number="${NUM}" 2>/dev/null) || true
  [ -z "${RESPONSE}" ] && RESPONSE='{}'

  NODE=$(echo "${RESPONSE}" | jq -c '.data.repository.issue // .data.repository.pullRequest // null')
  if [ "${NODE}" = "null" ] || [ -z "${NODE}" ]; then
    continue
  fi

  ITEM_COUNT=$(echo "${NODE}" | jq '(.projectItems.nodes // []) | length')
  if [ "${ITEM_COUNT:-0}" -eq 0 ] 2>/dev/null; then
    continue
  fi

  # Process substitution keeps the loop in the parent shell so MOVED /
  # SKIPPED increments survive past the loop body. (`echo ... | while`
  # would put the loop in a subshell and the counters would always
  # report 0 in the final summary.)
  while read -r ITEM; do
    PROJECT_ID=$(echo "${ITEM}" | jq -r '.project.id')
    PROJECT_TITLE=$(echo "${ITEM}" | jq -r '.project.title')
    ITEM_ID=$(echo "${ITEM}" | jq -r '.id')
    FIELD_ID=$(echo "${ITEM}" | jq -r '.project.field.id // empty')
    OPTION_ID=$(echo "${ITEM}" | jq -r --arg s "${TARGET_STATUS}" '
      .project.field.options // [] | map(select(.name == $s)) | (.[0].id // empty)
    ')

    if [ -z "${FIELD_ID}" ] || [ -z "${OPTION_ID}" ]; then
      warn "Skipping #${NUM} on '${PROJECT_TITLE}' — no Status option named '${TARGET_STATUS}'."
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    UPDATE='
mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: $projectId,
    itemId: $itemId,
    fieldId: $fieldId,
    value: { singleSelectOptionId: $optionId }
  }) { projectV2Item { id } }
}'
    if gh api graphql \
        -f query="${UPDATE}" \
        -F projectId="${PROJECT_ID}" \
        -F itemId="${ITEM_ID}" \
        -F fieldId="${FIELD_ID}" \
        -F optionId="${OPTION_ID}" >/dev/null 2>&1; then
      log "Moved #${NUM} on '${PROJECT_TITLE}' to '${TARGET_STATUS}'."
      MOVED=$((MOVED + 1))
    else
      warn "Failed to move #${NUM} on '${PROJECT_TITLE}' — token missing 'Projects: Write'?"
      SKIPPED=$((SKIPPED + 1))
    fi
  done < <(echo "${NODE}" | jq -c '.projectItems.nodes[]')
done

log "Done. Moved=${MOVED}, Skipped=${SKIPPED}."
