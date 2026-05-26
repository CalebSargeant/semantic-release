#!/usr/bin/env bash
# Enable native GitHub auto-merge on a pull request.
#
# Looks up the PR's GraphQL node id and calls the enablePullRequestAutoMerge
# mutation with the requested merge method. The repository must have:
#   - "Allow auto-merge" enabled in Settings → General → Pull Requests
#   - At least one branch protection rule on the target branch with a
#     required status check (GitHub refuses to engage auto-merge on
#     unprotected branches)
# Both are upstream GitHub prerequisites, not Release Runner ones.
#
# Required env:
#   GH_TOKEN     - auth token with `pull_requests: write` on the repo
#   OWNER        - repository owner (e.g., MagmaMoose)
#   REPO         - repository name (e.g., release-runner)
#   PR_NUMBER    - pull request number
#
# Optional env:
#   MERGE_METHOD - squash (default) | merge | rebase
#
# Exit codes:
#   0  - auto-merge enabled, or already enabled, or PR already merged/closed
#   1  - invalid input (bad MERGE_METHOD, missing required env, PR lookup
#        failed, or token lacks permissions)
#
# Warn-and-continue policy:
#   The repo-level prerequisites above (allow-auto-merge off, no branch
#   protection, target branch has zero required status checks) are
#   configuration issues outside this script's control. They surface as a
#   GraphQL error from enablePullRequestAutoMerge. The script logs an
#   actionable ::warning:: with the upstream error text and exits 0 — the
#   caller's PR workflow stays green and the PR is still mergeable manually.

set -euo pipefail

log()   { echo "::notice::[auto-merge] $*"; }
warn()  { echo "::warning::[auto-merge] $*"; }
error() { echo "::error::[auto-merge] $*"; }

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${REPO:?REPO is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"

METHOD_INPUT="${MERGE_METHOD:-squash}"
case "$(printf '%s' "${METHOD_INPUT}" | tr '[:upper:]' '[:lower:]')" in
  squash) METHOD="SQUASH" ;;
  merge)  METHOD="MERGE" ;;
  rebase) METHOD="REBASE" ;;
  *)
    error "Unsupported merge-method '${METHOD_INPUT}'. Use squash, merge, or rebase."
    exit 1
    ;;
esac

# Create a temporary directory for stderr logs and clean up on exit.
TMPDIR="${RUNNER_TEMP:-/tmp}"
WORKDIR=$(mktemp -d "${TMPDIR}/enable-auto-merge.XXXXXX")
trap 'rm -rf "${WORKDIR}"' EXIT
PR_FETCH_ERR="${WORKDIR}/pr-fetch.err"
AUTOMERGE_ERR="${WORKDIR}/automerge.err"

# Fetch PR metadata: node id (required by the GraphQL mutation), state
# (skip if already merged/closed), and current autoMergeRequest (skip if
# already enabled with the same method to keep this idempotent).
PR_JSON=$(gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}" 2>"${PR_FETCH_ERR}" || true)
if [ -z "${PR_JSON}" ]; then
  error "Could not fetch PR #${PR_NUMBER} on ${OWNER}/${REPO}: $(head -3 "${PR_FETCH_ERR}" 2>/dev/null | tr '\n' ' ')"
  exit 1
fi

PR_NODE_ID=$(printf '%s' "${PR_JSON}" | jq -r '.node_id // empty')
PR_STATE=$(printf '%s' "${PR_JSON}" | jq -r '.state // empty')
PR_MERGED=$(printf '%s' "${PR_JSON}" | jq -r '.merged // false')
PR_AUTO_METHOD=$(printf '%s' "${PR_JSON}" | jq -r '.auto_merge.merge_method // empty' | tr '[:lower:]' '[:upper:]')

if [ -z "${PR_NODE_ID}" ]; then
  error "PR #${PR_NUMBER} payload has no node_id; token may lack pull_requests:read."
  exit 1
fi

if [ "${PR_MERGED}" = "true" ] || [ "${PR_STATE}" = "closed" ]; then
  log "PR #${PR_NUMBER} is ${PR_STATE} (merged=${PR_MERGED}); nothing to do."
  exit 0
fi

if [ -n "${PR_AUTO_METHOD}" ] && [ "${PR_AUTO_METHOD}" = "${METHOD}" ]; then
  log "Auto-merge already enabled on PR #${PR_NUMBER} with method ${METHOD}."
  exit 0
fi

# shellcheck disable=SC2016 # $prId and $method are GraphQL variables, not shell.
MUTATION='mutation($prId: ID!, $method: PullRequestMergeMethod!) {
  enablePullRequestAutoMerge(input: { pullRequestId: $prId, mergeMethod: $method }) {
    pullRequest { number autoMergeRequest { enabledAt mergeMethod } }
  }
}'

RESPONSE=$(gh api graphql \
  -f "query=${MUTATION}" \
  -f "prId=${PR_NODE_ID}" \
  -f "method=${METHOD}" 2>"${AUTOMERGE_ERR}" || true)

# `gh api graphql` returns 200 even for GraphQL-level errors, so detect
# them in the response body before declaring success.
GQL_ERRORS=$(printf '%s' "${RESPONSE}" | jq -r '.errors // [] | map(.message) | join("; ")' 2>/dev/null || echo "")
CURL_ERR=$(head -3 "${AUTOMERGE_ERR}" 2>/dev/null | tr '\n' ' ')

if [ -n "${GQL_ERRORS}" ]; then
  warn "GitHub refused to enable auto-merge on PR #${PR_NUMBER}: ${GQL_ERRORS}. Check that the repository has 'Allow auto-merge' enabled and the target branch is protected with at least one required status check. PR can still be merged manually."
  exit 0
fi

if [ -z "${RESPONSE}" ]; then
  warn "enablePullRequestAutoMerge returned no response for PR #${PR_NUMBER}: ${CURL_ERR}. PR can still be merged manually."
  exit 0
fi

log "Auto-merge enabled on PR #${PR_NUMBER} with method ${METHOD}."
