#!/usr/bin/env bats

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/require-copilot-review.sh"

setup() {
  WORK="${BATS_TEST_TMPDIR}/copilot-review"
  FIXTURE_DIR="${WORK}/fixtures"
  BIN_DIR="${WORK}/bin"
  STATUS_LOG="${WORK}/statuses.log"
  mkdir -p "${FIXTURE_DIR}" "${BIN_DIR}"
  : > "${STATUS_LOG}"

  cat > "${BIN_DIR}/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" != "api" ]; then
  echo "unexpected gh command: $*" >&2
  exit 9
fi
shift

method="GET"
paginate="false"
endpoint=""
fields=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --paginate)
      paginate="true"
      shift
      ;;
    -X|--method)
      method="$2"
      shift 2
      ;;
    -f|-F)
      fields+=("$2")
      shift 2
      ;;
    --jq)
      shift 2
      ;;
    *)
      if [ -z "${endpoint}" ]; then
        endpoint="$1"
      else
        fields+=("$1")
      fi
      shift
      ;;
  esac
done

case "${endpoint}" in
  repos/octo/repo/pulls/42)
    cat "${FIXTURE_DIR}/pr.json"
    ;;
  repos/octo/repo/pulls/42/commits\?per_page=100)
    for file in "${FIXTURE_DIR}"/commits-*.json; do
      cat "${file}"
      echo
    done
    ;;
  repos/octo/repo/pulls/42/reviews\?per_page=100)
    for file in "${FIXTURE_DIR}"/reviews-*.json; do
      cat "${file}"
      echo
    done
    ;;
  repos/octo/repo/pulls/42/files\?per_page=100)
    for file in "${FIXTURE_DIR}"/files-*.json; do
      cat "${file}"
      echo
    done
    ;;
  repos/octo/repo/statuses/*)
    {
      echo "method=${method}"
      echo "endpoint=${endpoint}"
      for field in "${fields[@]}"; do
        echo "${field}"
      done
    } >> "${STATUS_LOG}"
    echo '{}'
    ;;
  repos/octo/repo/commits/*/check-runs)
    echo '{"check_runs":[]}'
    ;;
  repos/octo/repo/check-runs)
    echo '{"id":123}'
    ;;
  *)
    echo "unexpected endpoint: ${endpoint}" >&2
    exit 9
    ;;
esac
MOCK
  chmod +x "${BIN_DIR}/gh"

  # Mock curl so the quota-check fallback can be exercised without
  # standing up a worker. The test sets CURL_MOCK_RESPONSE / CURL_MOCK_EXIT
  # in the environment; the mock echoes whichever is configured. The
  # requested URL is captured into CURL_URL_LOG so tests can assert
  # query-parameter wiring.
  CURL_URL_LOG="${WORK}/curl-urls.log"
  : > "${CURL_URL_LOG}"
  export CURL_URL_LOG
  cat > "${BIN_DIR}/curl" <<'MOCK'
#!/usr/bin/env bash
set -e
# Last positional arg is the URL after the flags.
for arg in "$@"; do
  case "${arg}" in
    http*|https*) echo "${arg}" >> "${CURL_URL_LOG}" ;;
  esac
done
if [ -n "${CURL_MOCK_EXIT:-}" ]; then
  echo "${CURL_MOCK_STDERR:-mock curl: forced failure}" >&2
  exit "${CURL_MOCK_EXIT}"
fi
if [ -n "${CURL_MOCK_RESPONSE:-}" ]; then
  printf '%s' "${CURL_MOCK_RESPONSE}"
fi
MOCK
  chmod +x "${BIN_DIR}/curl"

  export PATH="${BIN_DIR}:${PATH}"
  export FIXTURE_DIR STATUS_LOG
  export GH_TOKEN="fake-token"
  export OWNER="octo"
  export REPO="repo"
  export PR_NUMBER="42"
  export COPILOT_REVIEW_REPORTER="none"
  export GITHUB_SERVER_URL="https://github.example.test"
  export GITHUB_REPOSITORY="octo/repo"
  export GITHUB_RUN_ID="1001"

  write_pr "false" "alice" "[]"
  write_commits '[{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","commit":{"committer":{"date":"2026-05-26T10:00:00Z"},"author":{"date":"2026-05-26T10:00:00Z"}}}]'
  write_reviews_page 1 '[]'
  write_files_page 1 '[{"filename":"src/app.js"}]'
}

write_pr() {
  local draft="$1"
  local author="$2"
  local labels="$3"
  jq -n \
    --arg sha "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    --arg author "${author}" \
    --argjson draft "${draft}" \
    --argjson labels "${labels}" \
    '{head:{sha:$sha}, draft:$draft, user:{login:$author}, labels: ($labels | map({name:.}))}' \
    > "${FIXTURE_DIR}/pr.json"
}

write_commits() {
  printf '%s\n' "$1" > "${FIXTURE_DIR}/commits-1.json"
}

write_reviews_page() {
  local page="$1"
  local json="$2"
  printf '%s\n' "${json}" > "${FIXTURE_DIR}/reviews-${page}.json"
}

write_files_page() {
  local page="$1"
  local json="$2"
  printf '%s\n' "${json}" > "${FIXTURE_DIR}/files-${page}.json"
}

run_policy() {
  run "${SCRIPT}"
}

@test "fails when no Copilot review exists" {
  run_policy

  [ "$status" -eq 1 ]
  [[ "$output" == *"Copilot has not reviewed this pull request yet."* ]]
}

@test "passes when a Copilot review targets the current head sha" {
  write_reviews_page 1 '[
    {
      "user": {"login": "copilot-pull-request-reviewer[bot]"},
      "state": "COMMENTED",
      "submitted_at": "2026-05-26T10:15:00Z",
      "commit_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  ]'

  run_policy

  [ "$status" -eq 0 ]
  [[ "$output" == *"Copilot reviewed this pull request after the latest commit."* ]]
  [[ "$output" == *"copilot-pull-request-reviewer[bot] at 2026-05-26T10:15:00Z"* ]]
}

@test "fails when the latest Copilot review is stale" {
  write_reviews_page 1 '[
    {
      "user": {"login": "copilot-pull-request-reviewer[bot]"},
      "state": "COMMENTED",
      "submitted_at": "2026-05-26T09:45:00Z",
      "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  ]'

  run_policy

  [ "$status" -eq 1 ]
  [[ "$output" == *"Copilot reviewed this pull request, but new commits were pushed afterwards."* ]]
  [[ "$output" == *"covered aaaaaaaaaaaa; current head is bbbbbbbbbbbb"* ]]
}

@test "passes when a newer review is fresh after an older stale review" {
  write_reviews_page 1 '[
    {
      "user": {"login": "copilot-pull-request-reviewer[bot]"},
      "state": "COMMENTED",
      "submitted_at": "2026-05-26T09:45:00Z",
      "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    {
      "user": {"login": "copilot-pull-request-reviewer[bot]"},
      "state": "COMMENTED",
      "submitted_at": "2026-05-26T10:20:00Z",
      "commit_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  ]'

  run_policy

  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-05-26T10:20:00Z"* ]]
}

@test "passes with timestamp freshness fallback when review commit id is absent" {
  write_reviews_page 1 '[
    {
      "user": {"login": "copilot-pull-request-reviewer[bot]"},
      "state": "COMMENTED",
      "submitted_at": "2026-05-26T10:15:00Z"
    }
  ]'

  run_policy

  [ "$status" -eq 0 ]
  [[ "$output" == *"Copilot reviewed this pull request after the latest commit."* ]]
}

@test "fails closed when review identity does not match configured Copilot logins" {
  write_reviews_page 1 '[
    {
      "user": {"login": "not-copilot[bot]"},
      "state": "COMMENTED",
      "submitted_at": "2026-05-26T10:15:00Z",
      "commit_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  ]'

  run_policy

  [ "$status" -eq 1 ]
  [[ "$output" == *"Unable to identify a valid Copilot review for the current head commit."* ]]
}

@test "reads paginated review results" {
  write_reviews_page 1 '[]'
  write_reviews_page 2 '[
    {
      "user": {"login": "copilot-pull-request-reviewer[bot]"},
      "state": "COMMENTED",
      "submitted_at": "2026-05-26T10:15:00Z",
      "commit_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  ]'

  run_policy

  [ "$status" -eq 0 ]
  [[ "$output" == *"Copilot reviewed this pull request after the latest commit."* ]]
}

@test "can skip draft pull requests" {
  write_pr "true" "alice" "[]"

  run_policy

  [ "$status" -eq 0 ]
  [[ "$output" == *"Draft pull request ignored by Require Copilot Review policy."* ]]
}

@test "can skip pull requests where all files match ignored path patterns" {
  write_files_page 1 '[{"filename":"docs/setup.md"},{"filename":"README.md"}]'

  run env COPILOT_REVIEW_IGNORE_PATHS='["docs/*","*.md"]' "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"All changed files match Require Copilot Review ignored path patterns."* ]]
}

@test "reports the stable commit status context" {
  write_reviews_page 1 '[]'

  run env COPILOT_REVIEW_REPORTER=commit-status "${SCRIPT}"

  [ "$status" -eq 1 ]
  grep -Fq "state=failure" "${STATUS_LOG}"
  grep -Fq "context=Diatreme / Require Copilot Review" "${STATUS_LOG}"
  grep -Fq "description=Copilot has not reviewed this pull request yet." "${STATUS_LOG}"
}

@test "quota check: bypasses no-review failure when worker reports rate_limited:true" {
  run env \
    COPILOT_REVIEW_QUOTA_CHECK_URL="https://broker.example.test/copilot-quota" \
    CURL_MOCK_RESPONSE='{"rate_limited":true,"source":"manual","resets_at":"2026-06-01T00:00:00Z","checked_at":"2026-05-26T10:00:00Z"}' \
    "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"rate-limited"* ]]
  [[ "$output" == *"resets at 2026-06-01T00:00:00Z"* ]]
}

@test "quota check: bypasses stale-review failure when worker reports rate_limited:true" {
  write_reviews_page 1 '[
    {
      "user": {"login": "copilot-pull-request-reviewer[bot]"},
      "state": "COMMENTED",
      "submitted_at": "2026-05-26T09:45:00Z",
      "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  ]'

  run env \
    COPILOT_REVIEW_QUOTA_CHECK_URL="https://broker.example.test/copilot-quota" \
    CURL_MOCK_RESPONSE='{"rate_limited":true,"source":"github-billing-api","resets_at":"2026-06-01T00:00:00Z"}' \
    "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"github-billing-api"* ]]
}

@test "quota check: falls through to strict failure when worker reports rate_limited:false" {
  run env \
    COPILOT_REVIEW_QUOTA_CHECK_URL="https://broker.example.test/copilot-quota" \
    CURL_MOCK_RESPONSE='{"rate_limited":false,"source":"default","checked_at":"2026-05-26T10:00:00Z"}' \
    "${SCRIPT}"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Copilot has not reviewed this pull request yet."* ]]
}

@test "quota check: tolerates worker unreachable (exits 1) and stays strict" {
  run env \
    COPILOT_REVIEW_QUOTA_CHECK_URL="https://broker.example.test/copilot-quota" \
    CURL_MOCK_EXIT=22 \
    CURL_MOCK_STDERR="HTTP/1.1 500 Internal Server Error" \
    "${SCRIPT}"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Copilot quota check"* ]]
  [[ "$output" == *"Falling through to strict gate"* ]]
}

@test "quota check: tolerates malformed JSON from worker and stays strict" {
  run env \
    COPILOT_REVIEW_QUOTA_CHECK_URL="https://broker.example.test/copilot-quota" \
    CURL_MOCK_RESPONSE='not valid json at all' \
    "${SCRIPT}"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Copilot has not reviewed this pull request yet."* ]]
}

@test "quota check: appends owner correctly to URLs with existing query string" {
  # Setting the URL with a pre-existing query string shouldn't break
  # parsing. The mock captures the URL into CURL_URL_LOG so we can
  # verify both branches.
  run env \
    COPILOT_REVIEW_QUOTA_CHECK_URL="https://broker.example.test/copilot-quota?foo=bar" \
    CURL_MOCK_RESPONSE='{"rate_limited":true,"source":"manual"}' \
    "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  # `&owner=...` (not `?owner=...`) because the URL already had a query.
  grep -q 'broker.example.test/copilot-quota?foo=bar&owner=octo' "${CURL_URL_LOG}"
}

@test "quota check: appends requester=<pr author> to the URL" {
  # Per-user Copilot premium-request quotas are tracked at the user level;
  # the worker uses `requester` to look up user-scoped billing in
  # addition to org-scoped billing. The script reads the PR author from
  # the PR JSON.
  write_pr "false" "calebsargeant" "[]"
  run env \
    COPILOT_REVIEW_QUOTA_CHECK_URL="https://broker.example.test/copilot-quota" \
    CURL_MOCK_RESPONSE='{"rate_limited":true,"source":"github-billing-api"}' \
    "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  grep -q 'owner=octo&requester=calebsargeant' "${CURL_URL_LOG}"
}

@test "body-pattern: bypasses with warning when Copilot posts a quota decline review" {
  # The exact wording observed on diatreme PR #39: Copilot was
  # requested as a reviewer, the user's quota was exhausted, Copilot
  # posted a real review on the head commit with this body.
  write_reviews_page 1 '[
    {
      "user": {"login": "copilot-pull-request-reviewer[bot]"},
      "state": "COMMENTED",
      "submitted_at": "2026-05-26T22:17:19Z",
      "commit_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "body": "Copilot was unable to review this pull request because the user who requested the review has reached their quota limit."
    }
  ]'

  run "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"Copilot declined to review"* ]]
  [[ "$output" == *"quota"* ]]
  # Crucially: must NOT report "Copilot reviewed this pull request after the
  # latest commit." — that's the false-positive we're fixing.
  [[ "$output" != *"Copilot reviewed this pull request after the latest commit"* ]]
}

@test "body-pattern: matches case-insensitively" {
  write_reviews_page 1 '[
    {
      "user": {"login": "copilot-pull-request-reviewer[bot]"},
      "state": "COMMENTED",
      "submitted_at": "2026-05-26T22:17:19Z",
      "commit_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "body": "COPILOT WAS UNABLE TO REVIEW because the QUOTA is gone."
    }
  ]'

  run "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
}

@test "body-pattern: matches the UI banner verbatim wording" {
  write_reviews_page 1 '[
    {
      "user": {"login": "copilot-pull-request-reviewer[bot]"},
      "state": "COMMENTED",
      "submitted_at": "2026-05-26T22:17:19Z",
      "commit_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "body": "You have reached your monthly limit for premium requests for Copilot code review."
    }
  ]'

  run "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
}

@test "body-pattern: real Copilot review with code feedback still passes as success" {
  # A real review body must not accidentally trip the quota-decline
  # detector, even if it mentions tangentially related words. The
  # detector requires both "unable to review" AND "quota", or one of
  # the more specific banner phrases.
  write_reviews_page 1 '[
    {
      "user": {"login": "copilot-pull-request-reviewer[bot]"},
      "state": "COMMENTED",
      "submitted_at": "2026-05-26T10:15:00Z",
      "commit_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "body": "Looks good overall. Consider extracting the parser into its own module — it would be hard to review changes if it grows further."
    }
  ]'

  run "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Copilot reviewed this pull request after the latest commit."* ]]
  [[ "$output" != *"Copilot declined to review"* ]]
}

@test "body-pattern: short-circuits the worker quota check" {
  # When Copilot's own body says quota-decline, we should never need to
  # consult the worker. The curl mock would emit a noisy stderr if it
  # were invoked with no fixture configured; here we set it explicitly
  # to a "false" response to prove the worker is NOT consulted.
  write_reviews_page 1 '[
    {
      "user": {"login": "copilot-pull-request-reviewer[bot]"},
      "state": "COMMENTED",
      "submitted_at": "2026-05-26T22:17:19Z",
      "commit_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "body": "Copilot was unable to review this pull request because the user who requested the review has reached their quota limit."
    }
  ]'

  run env \
    COPILOT_REVIEW_QUOTA_CHECK_URL="https://broker.example.test/copilot-quota" \
    CURL_MOCK_RESPONSE='{"rate_limited":false,"source":"default"}' \
    "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Copilot declined to review"* ]]
  # If the worker had been consulted and the gate fell through to its
  # `false` verdict, the output would say "Copilot has not reviewed".
  [[ "$output" != *"Copilot has not reviewed this pull request yet"* ]]
}
