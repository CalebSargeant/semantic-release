#!/usr/bin/env bash
# Enable native GitHub auto-merge on a pull request.
#
# Looks up the PR's GraphQL node id and calls the enablePullRequestAutoMerge
# mutation with the requested merge method. The repository must have:
#   - "Allow auto-merge" enabled in Settings → General → Pull Requests
#   - At least one branch protection rule on the target branch with a
#     required status check (GitHub refuses to engage auto-merge on
#     unprotected branches)
# Both are upstream GitHub prerequisites, not Diatreme ones.
#
# Required env:
#   GH_TOKEN     - auth token with `pull-requests: write` on the repo
#   OWNER        - repository owner (e.g., MagmaMoose)
#   REPO         - repository name (e.g., diatreme)
#   PR_NUMBER    - pull request number
#
# Optional env:
#   MERGE_METHOD - squash (default) | merge | rebase
#
# Exit codes:
#   0  - auto-merge enabled, or already enabled, or PR already merged/closed
#        (also warn-and-exit-0 for known repo-prerequisite GraphQL errors:
#        "Allow auto-merge" disabled, target branch unprotected with zero
#        required checks)
#   1  - invalid input (bad MERGE_METHOD, missing required env, PR lookup
#        failed, token lacks permissions, or an unrecognised GraphQL error)
#
# Warn-and-continue policy:
#   The repo-level prerequisites above (allow-auto-merge off, no branch
#   protection, target branch has zero required status checks) are
#   configuration issues outside this script's control. They surface as a
#   GraphQL error from enablePullRequestAutoMerge. The script logs an
#   actionable ::warning:: with the upstream error text and exits 0 — the
#   caller's PR workflow stays green and the PR is still mergeable manually.
#
# All other GraphQL errors (e.g. permission denied, bad PR id, API outage)
# and empty responses cause exit 1 so the workflow can react.

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
  error "PR #${PR_NUMBER} payload has no node_id; token may lack pull-requests:read."
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
  # Known repo-prerequisite errors: "Allow auto-merge" off, target branch
  # unprotected, no required status checks. These are repo-configuration
  # issues — warn and exit 0 so the caller workflow stays green. Patterns
  # are matched against the lowercased error text. Keep them aligned with
  # GitHub's actual wording, which uses "Auto merge" (two words, no
  # hyphen) and may say "not protected" instead of "branch protection".
  # All other errors (permissions denied, bad node id, API outage) are
  # genuine failures — exit 1 so the workflow can react.
  PREREQ_PATTERNS=(
    "auto merge is not allowed"
    "auto-merge is not allowed"
    "branch protection"
    "not protected"
    "required status check"
  )
  is_prereq=false
  lower_errors=$(printf '%s' "${GQL_ERRORS}" | tr '[:upper:]' '[:lower:]')
  for pat in "${PREREQ_PATTERNS[@]}"; do
    if [[ "${lower_errors}" == *"${pat}"* ]]; then
      is_prereq=true
      break
    fi
  done

  if [ "${is_prereq}" = true ]; then
    warn "GitHub refused to enable auto-merge on PR #${PR_NUMBER}: ${GQL_ERRORS}. Check that the repository has 'Allow auto-merge' enabled and the target branch is protected with at least one required status check. PR can still be merged manually."
    exit 0
  else
    error "Unexpected GraphQL error enabling auto-merge on PR #${PR_NUMBER}: ${GQL_ERRORS}"
    exit 1
  fi
fi

if [ -z "${RESPONSE}" ]; then
  error "enablePullRequestAutoMerge returned no response for PR #${PR_NUMBER}: ${CURL_ERR}. This may indicate a permissions or API issue."
  exit 1
fi

# Validate that the response contains the expected mutation result.
# This catches non-JSON responses and missing/incorrect data fields.
AUTO_MERGE_RESULT=$(printf '%s' "${RESPONSE}" | jq -r '.data.enablePullRequestAutoMerge.pullRequest.autoMergeRequest.mergeMethod // empty' 2>/dev/null || echo "")
if [ -z "${AUTO_MERGE_RESULT}" ]; then
  error "enablePullRequestAutoMerge response is missing or malformed. Response: $(head -c 500 <<<"${RESPONSE}")"
  exit 1
fi

log "Auto-merge enabled on PR #${PR_NUMBER} with method ${METHOD}."
