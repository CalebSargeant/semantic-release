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
  grep -Fq "context=Release Runner / Require Copilot Review" "${STATUS_LOG}"
  grep -Fq "description=Copilot has not reviewed this pull request yet." "${STATUS_LOG}"
}
