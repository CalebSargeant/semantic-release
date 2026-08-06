#!/usr/bin/env bash
# Append a "GitHub Project items" section to the release notes (and the
# auto-opened promotion PR body, if one exists) listing every Projects v2
# item linked to issues or PRs that landed in the release range.
#
# Inputs (env):
#   GH_TOKEN             token with read access to issues, PRs, and
#                        organization Projects v2 (see docs)
#   OWNER, REPO          repository identity
#   TAG                  the tag of the release we just published
#   PRERELEASE_IDENTIFIER  (optional) prerelease identifier, used to find
#                          the previous tag of the same series
#   TAG_PREFIX           (optional) tag prefix to scope the previous-tag
#                        lookup to one package's tag series. Empty means
#                        "every tag in the repo", which is right for a
#                        single-package repo and wrong for a repo that
#                        releases several — there the previous tag would be
#                        whichever package released last, and the commit
#                        range would span someone else's work.
#
# Behaviour:
#   - Resolves the previous release tag (same prerelease series, or the
#     last stable for stable releases) and walks commits in TAG range.
#   - Collects issue/PR numbers referenced in commit messages and PR
#     bodies (#NNN, "Closes #NNN", "Fixes #NNN", etc.).
#   - For each ref, queries Projects v2 membership via GraphQL.
#   - Groups by project, then appends a "## GitHub Project items" section
#     to the GitHub Release body (and any open promotion PR body).
#
# This is purely additive — never fails the release. Errors are logged
# as workflow warnings.

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${REPO:?REPO is required}"
: "${TAG:?TAG is required}"
PRERELEASE_IDENTIFIER="${PRERELEASE_IDENTIFIER:-}"
TAG_PREFIX="${TAG_PREFIX:-}"

log() { echo "::notice::[github-projects] $*"; }
warn() { echo "::warning::[github-projects] $*"; }

# ─── 1. Find the previous tag in the same series ──────────────────────────
# Note "${TAG_PREFIX}*" and not "${TAG_PREFIX}": an empty prefix must widen
# the glob to every tag, not narrow it to none.
PREV_TAG=""
if [ -n "${PRERELEASE_IDENTIFIER}" ]; then
  # Same prerelease series, e.g. previous v1.2.3-rc.* before v1.2.3-rc.5
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
  log "No previous tag found — using full history of ${TAG}."
  COMMIT_RANGE="${TAG}"
else
  log "Walking commits ${PREV_TAG}..${TAG}."
  COMMIT_RANGE="${PREV_TAG}..${TAG}"
fi

# ─── 2. Collect issue/PR numbers from commits + linked PR bodies ──────────
TMP_REFS=$(mktemp)
trap 'rm -f "${TMP_REFS}"' EXIT

# Commit messages: scan for #NNN, "Closes/Fixes/Resolves #NNN"
git log --pretty=format:'%B' "${COMMIT_RANGE}" 2>/dev/null \
  | grep -oE '#[0-9]+' \
  | tr -d '#' \
  | sort -un \
  >> "${TMP_REFS}" || true

# Linked PRs: each commit may have an associated PR (merge or squash). Grab
# the PR body too and rescan.
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
  log "No issue/PR references found in ${COMMIT_RANGE} — nothing to aggregate."
  exit 0
fi
log "Collected $(echo "${REFS}" | wc -l | tr -d ' ') unique refs."

# ─── 3. Query Projects v2 membership per ref ───────────────────────────────
# We try issue first, then pullRequest. Both expose projectItems with the
# parent project's title and URL plus the item's ID and Status field value
# (when present). The query uses a fragment because both types share the
# projectItems field shape.
QUERY='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      ... ProjectFields
    }
    pullRequest(number: $number) {
      ... ProjectFields
    }
  }
}
fragment ProjectFields on Node {
  ... on Issue { number title url projectItems(first: 20) { nodes { ...Item } } }
  ... on PullRequest { number title url projectItems(first: 20) { nodes { ...Item } } }
}
fragment Item on ProjectV2Item {
  id
  project { title url number }
  fieldValueByName(name: "Status") {
    ... on ProjectV2ItemFieldSingleSelectValue { name }
  }
}
'

AGGREGATE=$(mktemp)
trap 'rm -f "${TMP_REFS}" "${AGGREGATE}"' EXIT
echo "[]" > "${AGGREGATE}"

for NUM in ${REFS}; do
  # Capture stdout cleanly. The GraphQL endpoint returns BOTH the data and
  # a NOT_FOUND error when one of the issue/pullRequest probes for a number
  # that exists as the other type — gh exits non-zero in that case but the
  # data is still present in the JSON payload. Don't use `|| echo "{}"` —
  # that concatenates the fallback onto the real JSON, producing a
  # multi-document stream that breaks downstream jq calls.
  RESPONSE=$(gh api graphql \
    -f query="${QUERY}" \
    -F owner="${OWNER}" \
    -F repo="${REPO}" \
    -F number="${NUM}" 2>/dev/null) || true
  [ -z "${RESPONSE}" ] && RESPONSE='{}'

  # Pick whichever node returned non-null (issue or pullRequest). `-c` so
  # we get a single-line value even when the JSON is pretty-printed.
  NODE=$(echo "${RESPONSE}" | jq -c '.data.repository.issue // .data.repository.pullRequest // null')
  if [ "${NODE}" = "null" ] || [ -z "${NODE}" ]; then
    # No node back from either probe — almost always missing token scope
    # (Issues / Pull requests: Read) or a ref that doesn't resolve. Surface
    # as a warning per the file header's "errors logged as workflow
    # warnings" contract; include the GraphQL errors block so callers can
    # diagnose without opening the Actions log.
    ERR=$(echo "${RESPONSE}" | jq -c '.errors // empty')
    warn "Ref #${NUM}: GraphQL returned no node. errors=${ERR:-<none>}"
    continue
  fi

  ITEM_COUNT=$(echo "${NODE}" | jq '(.projectItems.nodes // []) | length')
  if [ "${ITEM_COUNT:-0}" -eq 0 ] 2>/dev/null; then
    # Zero items is a normal state — most issues/PRs aren't on a Project
    # board. Only flag a likely scope problem when GraphQL also returned
    # errors for this ref (e.g. Projects: Read missing but Issues: Read
    # granted).
    ERR=$(echo "${RESPONSE}" | jq -c '.errors // empty')
    if [ -n "${ERR}" ]; then
      warn "Ref #${NUM}: 0 project items, GraphQL also reported errors=${ERR} (likely missing Projects: Read)."
    else
      log "Ref #${NUM}: 0 project items linked."
    fi
    continue
  fi
  log "Ref #${NUM}: ${ITEM_COUNT} project item(s) linked."

  # Append each project item with the ref's title/URL.
  ENRICHED=$(echo "${NODE}" | jq -c '
    .projectItems.nodes
    | map({
        project: .project,
        status: (.fieldValueByName.name // null),
        ref: { number: $node.number, title: $node.title, url: $node.url }
      })
  ' --argjson node "${NODE}")

  jq --argjson new "${ENRICHED}" '. + $new' "${AGGREGATE}" > "${AGGREGATE}.tmp"
  mv "${AGGREGATE}.tmp" "${AGGREGATE}"
done

ITEM_TOTAL=$(jq 'length' "${AGGREGATE}")
if [ "${ITEM_TOTAL}" -eq 0 ]; then
  log "No Projects v2 items linked to any ref in this range — nothing to append."
  exit 0
fi
log "Found ${ITEM_TOTAL} project item link(s) across this release."

# ─── 4. Render Markdown grouped by project ─────────────────────────────────
SECTION=$(jq -r '
  group_by(.project.url) | map({
    project: .[0].project,
    items: (map({status: .status, ref: .ref}) | unique_by(.ref.number))
  })
  | sort_by(.project.title)
  | map(
      "### [\(.project.title)](\(.project.url))\n\n"
      + (.items
         | map(
             "- [#\(.ref.number) \(.ref.title)](\(.ref.url))"
             + (if .status then " — _\(.status)_" else "" end)
           )
         | join("\n"))
    )
  | "## GitHub Project items\n\n" + join("\n\n")
' "${AGGREGATE}")

if [ -z "${SECTION}" ] || [ "${SECTION}" = "null" ]; then
  warn "Failed to render Markdown section — skipping."
  exit 0
fi

# ─── 5. Append to release notes (and any open promotion PR body) ──────────
# Treat an empty existing body as a valid starting point — append the
# section regardless. Skip only if the section is already present, to
# avoid duplicate appends on re-runs.
RELEASE_BODY=$(gh release view "${TAG}" --json body --jq '.body // ""' 2>/dev/null || echo "")
if echo "${RELEASE_BODY}" | grep -q "^## GitHub Project items"; then
  log "Release notes for ${TAG} already contain a Project items section — skipping."
else
  if [ -n "${RELEASE_BODY}" ]; then
    NEW_BODY=$(printf '%s\n\n%s\n' "${RELEASE_BODY}" "${SECTION}")
  else
    NEW_BODY="${SECTION}"
  fi
  if gh release edit "${TAG}" --notes "${NEW_BODY}" >/dev/null 2>&1; then
    log "Appended Project items to release notes for ${TAG}."
  else
    warn "Could not edit release notes for ${TAG} — token missing 'Releases: write'?"
  fi
fi

# Promotion PRs (if any) have a body that mentions the tag; append there too.
PR_NUMBERS=$(gh pr list --state open --search "in:title ${TAG}" --json number --jq '.[].number' 2>/dev/null || true)
for PR in ${PR_NUMBERS}; do
  PR_BODY=$(gh pr view "${PR}" --json body --jq '.body // ""' 2>/dev/null || echo "")
  if echo "${PR_BODY}" | grep -q "^## GitHub Project items"; then
    log "Promotion PR #${PR} already contains a Project items section — skipping."
    continue
  fi
  if [ -n "${PR_BODY}" ]; then
    NEW_PR_BODY=$(printf '%s\n\n%s\n' "${PR_BODY}" "${SECTION}")
  else
    NEW_PR_BODY="${SECTION}"
  fi
  if gh pr edit "${PR}" --body "${NEW_PR_BODY}" >/dev/null 2>&1; then
    log "Appended Project items to promotion PR #${PR}."
  else
    warn "Could not edit promotion PR #${PR} — token missing 'Pull requests: write'?"
  fi
done
