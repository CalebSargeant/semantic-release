#!/usr/bin/env bash
# Evaluate the "Require Copilot Review" pull request policy.
#
# The script intentionally keeps policy evaluation separate from the composite
# action wiring so future AI review gates can reuse the same shape:
#   1. read PR/review state from GitHub
#   2. detect provider-owned reviews
#   3. evaluate freshness against the current PR head
#   4. report a deterministic status/check name

set -euo pipefail

log() { echo "::notice::[copilot-review] $*"; }
error() { echo "::error::[copilot-review] $*"; }

TMP_FILES=()
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  rm -f "${TMP_FILES[@]}"
}
trap cleanup EXIT

tmp_file() {
  local file
  file="$(mktemp)"
  TMP_FILES+=("${file}")
  echo "${file}"
}

truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_array() {
  local raw="${1:-}"
  if [ -z "${raw}" ] || [ "${raw}" = "null" ]; then
    echo "[]"
    return
  fi

  if echo "${raw}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "${raw}" | jq -c '[.[] | tostring]'
    return
  fi

  jq -R -c 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))' <<<"${raw}"
}

array_contains() {
  local array_json="$1"
  local value="$2"
  echo "${array_json}" | jq -e --arg value "${value}" 'index($value) != null' >/dev/null
}

array_intersection_first() {
  local left_json="$1"
  local right_json="$2"
  jq -nr \
    --argjson left "${left_json}" \
    --argjson right "${right_json}" \
    '$left | map(select($right | index(.))) | .[0] // empty'
}

short_sha() {
  printf '%s' "$1" | cut -c 1-12
}

status_description() {
  printf '%s' "$1" | tr '\n' ' ' | cut -c 1-140
}

target_url() {
  if [ -n "${COPILOT_REVIEW_TARGET_URL:-}" ]; then
    echo "${COPILOT_REVIEW_TARGET_URL}"
    return
  fi

  local server="${GITHUB_SERVER_URL:-}"
  local repository="${GITHUB_REPOSITORY:-${OWNER:-}/${REPO:-}}"
  local run_id="${GITHUB_RUN_ID:-}"
  if [ -n "${server}" ] && [ "${repository}" != "/" ] && [ -n "${run_id}" ]; then
    echo "${server%/}/${repository}/actions/runs/${run_id}"
  fi
}

report_commit_status() {
  local state="$1"
  local title="$2"
  local summary="$3"
  local url
  local args

  url="$(target_url)"
  args=(
    -X POST
    "repos/${OWNER}/${REPO}/statuses/${HEAD_SHA}"
    -f "state=${state}"
    -f "context=${CHECK_NAME}"
    -f "description=$(status_description "${summary}")"
  )
  if [ -n "${url}" ]; then
    args+=(-f "target_url=${url}")
  fi

  gh api "${args[@]}" >/dev/null
  log "Reported commit status '${CHECK_NAME}' as ${state}: ${title}"
}

check_run_conclusion() {
  case "$1" in
    success) echo "success" ;;
    *) echo "failure" ;;
  esac
}

report_check_run() {
  local state="$1"
  local title="$2"
  local summary="$3"
  local conclusion
  local existing
  local now
  local get_response

  conclusion="$(check_run_conclusion "${state}")"
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  get_response="$(gh api -X GET "repos/${OWNER}/${REPO}/commits/${HEAD_SHA}/check-runs" \
    -f "check_name=${CHECK_NAME}" 2>/dev/null || echo '{}')"
  existing="$(echo "${get_response}" | jq -r --arg name "${CHECK_NAME}" '
    (.check_runs // [])
    | map(select(.name == $name))
    | sort_by(.started_at // .completed_at // "")
    | .[-1].id // empty
  ')"

  if [ -n "${existing}" ]; then
    gh api -X PATCH "repos/${OWNER}/${REPO}/check-runs/${existing}" \
      -f status=completed \
      -f "conclusion=${conclusion}" \
      -f "completed_at=${now}" \
      -f "output[title]=${title}" \
      -f "output[summary]=${summary}" >/dev/null
  else
    gh api -X POST "repos/${OWNER}/${REPO}/check-runs" \
      -f "name=${CHECK_NAME}" \
      -f "head_sha=${HEAD_SHA}" \
      -f status=completed \
      -f "conclusion=${conclusion}" \
      -f "completed_at=${now}" \
      -f "output[title]=${title}" \
      -f "output[summary]=${summary}" >/dev/null
  fi

  log "Reported check run '${CHECK_NAME}' as ${conclusion}: ${title}"
}

report_result() {
  local state="$1"
  local title="$2"
  local summary="$3"

  case "${REPORTER}" in
    none)
      return 0
      ;;
    commit-status)
      report_commit_status "${state}" "${title}" "${summary}"
      ;;
    check-run)
      report_check_run "${state}" "${title}" "${summary}"
      ;;
    *)
      error "Unsupported copilot-review-reporter '${REPORTER}'. Use commit-status, check-run, or none."
      return 1
      ;;
  esac
}

finish() {
  local state="$1"
  local exit_code="$2"
  local title="$3"
  local summary="$4"

  if [ "${state}" = "success" ]; then
    log "${summary}"
  else
    error "${summary}"
  fi

  if ! report_result "${state}" "${title}" "${summary}"; then
    error "Could not report '${CHECK_NAME}'. Check token permissions for statuses: write or checks: write."
    exit 1
  fi

  exit "${exit_code}"
}

fetch_json() {
  local path="$1"
  local label="$2"
  local err_file
  local response

  err_file="$(tmp_file)"
  if ! response="$(gh api "${path}" 2>"${err_file}")"; then
    error "Could not read ${label}: $(head -3 "${err_file}" | tr '\n' ' ')"
    return 1
  fi
  printf '%s\n' "${response}"
}

fetch_paginated_array() {
  local path="$1"
  local label="$2"
  local err_file
  local response

  err_file="$(tmp_file)"
  if ! response="$(gh api --paginate "${path}" 2>"${err_file}")"; then
    error "Could not read ${label}: $(head -3 "${err_file}" | tr '\n' ' ')"
    return 1
  fi

  if [ -z "${response}" ]; then
    echo "[]"
    return
  fi

  echo "${response}" | jq -s -c 'add // []'
}

login_matches_provider() {
  local login="$1"
  local entry
  local lower_login

  if truthy "${ALLOW_LOGIN_PATTERN}"; then
    while IFS= read -r entry; do
      [ -z "${entry}" ] && continue
      # shellcheck disable=SC2254 # Login patterns are opt-in globs.
      case "${login}" in
        ${entry}) return 0 ;;
      esac
    done < <(echo "${ALLOWED_LOGINS_JSON}" | jq -r '.[]')
  elif array_contains "${ALLOWED_LOGINS_JSON}" "${login}"; then
    return 0
  fi

  if ! truthy "${FAIL_ON_UNKNOWN_IDENTITY}"; then
    lower_login="$(printf '%s' "${login}" | tr '[:upper:]' '[:lower:]')"
    case "${lower_login}" in
      *copilot*) return 0 ;;
    esac
  fi

  return 1
}

append_candidate_review() {
  local review="$1"
  local target="$2"
  local tmp

  tmp="$(tmp_file)"
  jq --argjson review "${review}" '. + [$review]' "${target}" > "${tmp}"
  mv "${tmp}" "${target}"
}

path_matches_ignored_patterns() {
  local path="$1"
  local pattern

  while IFS= read -r pattern; do
    [ -z "${pattern}" ] && continue
    # shellcheck disable=SC2254 # Ignore paths are documented as globs.
    case "${path}" in
      ${pattern}) return 0 ;;
    esac
  done < <(echo "${IGNORE_PATHS_JSON}" | jq -r '.[]')

  return 1
}

review_is_fresh() {
  local review="$1"
  local commit_id
  local submitted_at

  commit_id="$(echo "${review}" | jq -r '.commit_id // empty')"
  submitted_at="$(echo "${review}" | jq -r '.submitted_at // empty')"

  case "${FRESHNESS}" in
    after_latest_commit)
      if [ -n "${commit_id}" ]; then
        [ "${commit_id}" = "${HEAD_SHA}" ]
        return
      fi
      [ -n "${submitted_at}" ] && [ -n "${HEAD_COMMIT_DATE}" ] && {
        [ "${submitted_at}" = "${HEAD_COMMIT_DATE}" ] || [[ "${submitted_at}" > "${HEAD_COMMIT_DATE}" ]]
      }
      ;;
    exact_head_sha)
      [ -n "${commit_id}" ] && [ "${commit_id}" = "${HEAD_SHA}" ]
      ;;
    *)
      error "Unsupported copilot-review-freshness '${FRESHNESS}'. Use after_latest_commit or exact_head_sha."
      return 2
      ;;
  esac
}

# Query the configured /copilot-quota worker endpoint and, if it reports
# the owner is rate-limited on Copilot premium requests, finish the gate
# as success with a warning. No-op when COPILOT_REVIEW_QUOTA_CHECK_URL is
# empty or the call fails — the caller falls through to strict mode.
#
# Args:
#   $1 - summary used in the success message (e.g. the reason the gate
#        was about to fail; included so the warning is self-describing)
maybe_pass_for_quota() {
  local fail_reason="$1"
  local url="${COPILOT_REVIEW_QUOTA_CHECK_URL:-}"
  [ -z "${url}" ] && return 0

  local separator="?"
  if [[ "${url}" == *"?"* ]]; then
    separator="&"
  fi
  local full_url="${url}${separator}owner=${OWNER}"

  # Pass the PR author as `requester` so the worker can additionally check
  # the user-scoped billing endpoint. Copilot premium-request quotas are
  # tracked per-user even on Copilot Business, so the org-billing path
  # alone misses individual exhaustion when the repo lives under an org.
  # `requester` is informational — the worker stays backward-compatible
  # when it's absent.
  if [ -n "${PR_AUTHOR:-}" ]; then
    full_url="${full_url}&requester=${PR_AUTHOR}"
  fi

  local response
  local err_file
  err_file="$(tmp_file)"
  if ! response="$(curl -fsSL --max-time 10 "${full_url}" 2>"${err_file}")"; then
    log "Copilot quota check at ${url} failed: $(head -2 "${err_file}" | tr '\n' ' '). Falling through to strict gate."
    return 0
  fi

  local rate_limited
  rate_limited="$(printf '%s' "${response}" | jq -r '.rate_limited // false' 2>/dev/null || echo "false")"
  if [ "${rate_limited}" != "true" ]; then
    return 0
  fi

  local source
  local resets_at
  source="$(printf '%s' "${response}" | jq -r '.source // "unknown"' 2>/dev/null || echo "unknown")"
  resets_at="$(printf '%s' "${response}" | jq -r '.resets_at // empty' 2>/dev/null || echo "")"

  local detail="Copilot premium-request quota reported exhausted (source: ${source}"
  if [ -n "${resets_at}" ]; then
    detail+="; resets at ${resets_at}"
  fi
  detail+="). Original gate reason: ${fail_reason}"

  warn "${detail}"

  finish "success" 0 \
    "Copilot review bypassed — rate limit" \
    "Copilot review gate passed gracefully because ${OWNER} is rate-limited on premium requests. ${detail}"
}

warn() { echo "::warning::[copilot-review] $*"; }

# Detect Copilot's own "I can't review because I'm rate-limited" notice.
#
# When Copilot is requested as a reviewer but its premium-request quota is
# exhausted, it does not silently skip — it posts a real PR review (state
# COMMENTED) on the current head commit with a body explaining the decline.
# That review otherwise satisfies the freshness check, so the strict gate
# would silently treat it as a real review. Detect the decline wording and
# treat the gate as bypassed-by-quota instead.
#
# Patterns are case-insensitive substring matches. Kept conservative so
# normal review bodies don't accidentally trigger:
#   - "unable to review" + "quota"           → Copilot's current wording
#   - "monthly limit for premium request"    → UI banner echo
#   - "reached (your|their) quota"           → variant wording
is_copilot_quota_decline_body() {
  local body="$1"
  local lower
  lower="$(printf '%s' "${body}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${lower}" == *"unable to review"* ]] && [[ "${lower}" == *"quota"* ]]; then
    return 0
  fi
  if [[ "${lower}" == *"monthly limit for premium request"* ]]; then
    return 0
  fi
  if [[ "${lower}" == *"reached your quota"* ]] || [[ "${lower}" == *"reached their quota"* ]]; then
    return 0
  fi
  return 1
}

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${REPO:?REPO is required}"

PR_NUMBER="${PR_NUMBER:-}"
if [ -z "${PR_NUMBER}" ]; then
  error "Require Copilot Review can only run for pull_request or pull_request_review events."
  exit 1
fi

FRESHNESS="${COPILOT_REVIEW_FRESHNESS:-after_latest_commit}"
REPORTER="${COPILOT_REVIEW_REPORTER:-commit-status}"
CHECK_NAME="${COPILOT_REVIEW_CHECK_NAME:-Diatreme / Require Copilot Review}"
ALLOW_LOGIN_PATTERN="${COPILOT_REVIEW_ALLOW_LOGIN_PATTERN:-false}"
FAIL_ON_UNKNOWN_IDENTITY="${COPILOT_REVIEW_FAIL_ON_UNKNOWN_IDENTITY:-true}"
IGNORE_DRAFTS="${COPILOT_REVIEW_IGNORE_DRAFTS:-true}"
ALLOWED_LOGINS_JSON="$(normalize_array "${COPILOT_REVIEW_ALLOWED_LOGINS:-[\"copilot-pull-request-reviewer[bot]\"]}")"
IGNORE_LABELS_JSON="$(normalize_array "${COPILOT_REVIEW_IGNORE_LABELS:-[]}")"
IGNORE_AUTHORS_JSON="$(normalize_array "${COPILOT_REVIEW_IGNORE_AUTHORS:-[]}")"
IGNORE_PATHS_JSON="$(normalize_array "${COPILOT_REVIEW_IGNORE_PATHS:-[]}")"

PR_JSON="$(fetch_json "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}" "pull request #${PR_NUMBER}")"
HEAD_SHA="$(echo "${PR_JSON}" | jq -r '.head.sha // empty')"
if [ -z "${HEAD_SHA}" ]; then
  HEAD_SHA="${PR_HEAD_SHA:-}"
fi
if [ -z "${HEAD_SHA}" ]; then
  error "Could not determine the current PR head SHA for #${PR_NUMBER}."
  exit 1
fi

case "${REPORTER}" in
  commit-status|check-run|none) ;;
  *)
    error "Unsupported copilot-review-reporter '${REPORTER}'. Use commit-status, check-run, or none."
    exit 1
    ;;
esac

case "${FRESHNESS}" in
  after_latest_commit|exact_head_sha) ;;
  *)
    finish "error" 1 \
      "Invalid Require Copilot Review freshness" \
      "Unsupported copilot-review-freshness '${FRESHNESS}'. Use after_latest_commit or exact_head_sha."
    ;;
esac

PR_DRAFT="$(echo "${PR_JSON}" | jq -r '.draft // false')"
PR_AUTHOR="$(echo "${PR_JSON}" | jq -r '.user.login // empty')"
PR_LABELS_JSON="$(echo "${PR_JSON}" | jq -c '[.labels[]?.name // empty]')"

if truthy "${IGNORE_DRAFTS}" && [ "${PR_DRAFT}" = "true" ]; then
  finish "success" 0 \
    "Require Copilot Review skipped" \
    "Draft pull request ignored by Require Copilot Review policy."
fi

if [ -n "${PR_AUTHOR}" ] && array_contains "${IGNORE_AUTHORS_JSON}" "${PR_AUTHOR}"; then
  finish "success" 0 \
    "Require Copilot Review skipped" \
    "Pull request author '${PR_AUTHOR}' ignored by Require Copilot Review policy."
fi

IGNORED_LABEL="$(array_intersection_first "${PR_LABELS_JSON}" "${IGNORE_LABELS_JSON}")"
if [ -n "${IGNORED_LABEL}" ]; then
  finish "success" 0 \
    "Require Copilot Review skipped" \
    "Label '${IGNORED_LABEL}' ignored by Require Copilot Review policy."
fi

if [ "$(echo "${IGNORE_PATHS_JSON}" | jq 'length')" -gt 0 ]; then
  FILES_JSON="$(fetch_paginated_array "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/files?per_page=100" "pull request #${PR_NUMBER} files")"
  CHANGED_FILES_JSON="$(echo "${FILES_JSON}" | jq -c '[.[].filename]')"
  CHANGED_FILE_COUNT="$(echo "${CHANGED_FILES_JSON}" | jq 'length')"
  IGNORED_FILE_COUNT=0

  while IFS= read -r path; do
    if path_matches_ignored_patterns "${path}"; then
      IGNORED_FILE_COUNT=$((IGNORED_FILE_COUNT + 1))
    fi
  done < <(echo "${CHANGED_FILES_JSON}" | jq -r '.[]')

  if [ "${CHANGED_FILE_COUNT}" -gt 0 ] && [ "${IGNORED_FILE_COUNT}" -eq "${CHANGED_FILE_COUNT}" ]; then
    finish "success" 0 \
      "Require Copilot Review skipped" \
      "All changed files match Require Copilot Review ignored path patterns."
  fi
fi

COMMITS_JSON="$(fetch_paginated_array "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/commits?per_page=100" "pull request #${PR_NUMBER} commits")"
HEAD_COMMIT_JSON="$(echo "${COMMITS_JSON}" | jq -c --arg sha "${HEAD_SHA}" 'map(select(.sha == $sha)) | .[-1] // .[-1] // null')"
if [ "${HEAD_COMMIT_JSON}" = "null" ]; then
  finish "error" 1 \
    "Unable to evaluate Copilot review freshness" \
    "Unable to identify the latest commit for pull request #${PR_NUMBER}."
fi

HEAD_SHA_FROM_COMMITS="$(echo "${HEAD_COMMIT_JSON}" | jq -r '.sha // empty')"
if [ -n "${HEAD_SHA_FROM_COMMITS}" ]; then
  HEAD_SHA="${HEAD_SHA_FROM_COMMITS}"
fi
HEAD_COMMIT_DATE="$(echo "${HEAD_COMMIT_JSON}" | jq -r '.commit.committer.date // .commit.author.date // empty')"

REVIEWS_JSON="$(fetch_paginated_array "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/reviews?per_page=100" "pull request #${PR_NUMBER} reviews")"
CANDIDATES_FILE="$(tmp_file)"
echo "[]" > "${CANDIDATES_FILE}"

while IFS= read -r review; do
  login="$(echo "${review}" | jq -r '.user.login // empty')"
  [ -z "${login}" ] && continue
  if login_matches_provider "${login}"; then
    append_candidate_review "${review}" "${CANDIDATES_FILE}"
  fi
done < <(echo "${REVIEWS_JSON}" | jq -c '
  .[]
  | select((.submitted_at // "") != "")
  | select((.state // "") != "PENDING")
  | select((.state // "") != "DISMISSED")
')

CANDIDATE_COUNT="$(jq 'length' "${CANDIDATES_FILE}")"
TOTAL_SUBMITTED_REVIEWS="$(echo "${REVIEWS_JSON}" | jq '[.[] | select((.submitted_at // "") != "")] | length')"

if [ "${CANDIDATE_COUNT}" -eq 0 ]; then
  if [ "${TOTAL_SUBMITTED_REVIEWS}" -eq 0 ]; then
    maybe_pass_for_quota "Copilot has not reviewed this pull request yet."
    finish "failure" 1 \
      "Copilot review missing" \
      "Copilot has not reviewed this pull request yet."
  fi

  finish "failure" 1 \
    "Copilot review identity not found" \
    "Unable to identify a valid Copilot review for the current head commit. Checked ${TOTAL_SUBMITTED_REVIEWS} submitted PR review(s); none matched the configured Copilot reviewer identities."
fi

VALID_REVIEW=""
LATEST_CANDIDATE=""
while IFS= read -r review; do
  if [ -z "${LATEST_CANDIDATE}" ]; then
    LATEST_CANDIDATE="${review}"
  fi
  if review_is_fresh "${review}"; then
    VALID_REVIEW="${review}"
    break
  fi
done < <(jq -c 'sort_by(.submitted_at // "") | reverse[]' "${CANDIDATES_FILE}")

if [ -n "${VALID_REVIEW}" ]; then
  REVIEW_LOGIN="$(echo "${VALID_REVIEW}" | jq -r '.user.login // "unknown"')"
  REVIEW_SUBMITTED_AT="$(echo "${VALID_REVIEW}" | jq -r '.submitted_at // "unknown"')"
  REVIEW_COMMIT_ID="$(echo "${VALID_REVIEW}" | jq -r '.commit_id // empty')"
  REVIEW_BODY="$(echo "${VALID_REVIEW}" | jq -r '.body // ""')"
  REVIEW_COMMIT_DETAIL=""
  if [ -n "${REVIEW_COMMIT_ID}" ]; then
    REVIEW_COMMIT_DETAIL=" Review commit: $(short_sha "${REVIEW_COMMIT_ID}")."
  fi

  # When Copilot was requested but couldn't actually review (quota
  # exhausted), it posts a fresh review whose body explains the decline.
  # Don't silently treat that as a real review — bypass the gate with a
  # ::warning:: so the autonomous flow continues but the rate-limit is
  # visible. The body-pattern signal is free (uses the review payload we
  # already fetched) and short-circuits the worker check below.
  if is_copilot_quota_decline_body "${REVIEW_BODY}"; then
    warn "Copilot declined to review PR #${PR_NUMBER} due to quota: ${REVIEW_BODY}"
    finish "success" 0 \
      "Copilot review bypassed — Copilot declined (quota)" \
      "Copilot review gate passed gracefully: Copilot was requested as reviewer but declined the review because the requester's quota is exhausted. Decline notice from ${REVIEW_LOGIN} at ${REVIEW_SUBMITTED_AT}: ${REVIEW_BODY}"
  fi

  finish "success" 0 \
    "Copilot reviewed current PR state" \
    "Copilot reviewed this pull request after the latest commit. Review detected from ${REVIEW_LOGIN} at ${REVIEW_SUBMITTED_AT}.${REVIEW_COMMIT_DETAIL}"
fi

LATEST_LOGIN="$(echo "${LATEST_CANDIDATE}" | jq -r '.user.login // "unknown"')"
LATEST_SUBMITTED_AT="$(echo "${LATEST_CANDIDATE}" | jq -r '.submitted_at // "unknown"')"
LATEST_COMMIT_ID="$(echo "${LATEST_CANDIDATE}" | jq -r '.commit_id // empty')"
if [ -n "${LATEST_COMMIT_ID}" ]; then
  STALE_DETAIL="Latest Copilot review from ${LATEST_LOGIN} at ${LATEST_SUBMITTED_AT} covered $(short_sha "${LATEST_COMMIT_ID}"); current head is $(short_sha "${HEAD_SHA}")."
else
  STALE_DETAIL="Latest Copilot review from ${LATEST_LOGIN} at ${LATEST_SUBMITTED_AT}; current head commit time is ${HEAD_COMMIT_DATE:-unknown}."
fi

maybe_pass_for_quota "Copilot reviewed this pull request, but new commits were pushed afterwards. ${STALE_DETAIL}"

finish "failure" 1 \
  "Copilot review is stale" \
  "Copilot reviewed this pull request, but new commits were pushed afterwards. ${STALE_DETAIL}"
