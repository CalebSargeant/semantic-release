#!/usr/bin/env bats

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/enable-auto-merge.sh"

setup() {
  WORK="${BATS_TEST_TMPDIR}/enable-auto-merge"
  FIXTURE_DIR="${WORK}/fixtures"
  BIN_DIR="${WORK}/bin"
  CALL_LOG="${WORK}/gh-calls.log"
  mkdir -p "${FIXTURE_DIR}" "${BIN_DIR}"
  : > "${CALL_LOG}"

  cat > "${BIN_DIR}/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" != "api" ]; then
  echo "unexpected gh command: $*" >&2
  exit 9
fi
shift

method="GET"
endpoint=""
fields=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -X|--method) method="$2"; shift 2 ;;
    -f|-F)       fields+=("$2"); shift 2 ;;
    --jq)        shift 2 ;;
    --paginate)  shift ;;
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

{
  echo "method=${method}"
  echo "endpoint=${endpoint}"
  if [ "${#fields[@]}" -gt 0 ]; then
    for f in "${fields[@]}"; do
      echo "field=${f}"
    done
  fi
} >> "${CALL_LOG}"

case "${endpoint}" in
  repos/octo/repo/pulls/77)
    cat "${FIXTURE_DIR}/pr.json"
    ;;
  graphql)
    cat "${FIXTURE_DIR}/graphql.json"
    ;;
  *)
    echo "unexpected endpoint: ${endpoint}" >&2
    exit 9
    ;;
esac
MOCK
  chmod +x "${BIN_DIR}/gh"

  export PATH="${BIN_DIR}:${PATH}"
  export FIXTURE_DIR CALL_LOG
  export GH_TOKEN="fake-token"
  export OWNER="octo"
  export REPO="repo"
  export PR_NUMBER="77"

  write_pr_open
  write_graphql_success
}

write_pr_open() {
  cat > "${FIXTURE_DIR}/pr.json" <<'JSON'
{
  "node_id": "PR_node_id_1",
  "state": "open",
  "merged": false,
  "auto_merge": null
}
JSON
}

write_pr_merged() {
  cat > "${FIXTURE_DIR}/pr.json" <<'JSON'
{
  "node_id": "PR_node_id_1",
  "state": "closed",
  "merged": true,
  "auto_merge": null
}
JSON
}

write_pr_closed() {
  cat > "${FIXTURE_DIR}/pr.json" <<'JSON'
{
  "node_id": "PR_node_id_1",
  "state": "closed",
  "merged": false,
  "auto_merge": null
}
JSON
}

write_pr_auto_merge_enabled() {
  local method="$1"
  cat > "${FIXTURE_DIR}/pr.json" <<JSON
{
  "node_id": "PR_node_id_1",
  "state": "open",
  "merged": false,
  "auto_merge": { "merge_method": "${method}" }
}
JSON
}

write_pr_missing_node_id() {
  cat > "${FIXTURE_DIR}/pr.json" <<'JSON'
{
  "state": "open",
  "merged": false
}
JSON
}

write_graphql_success() {
  cat > "${FIXTURE_DIR}/graphql.json" <<'JSON'
{
  "data": {
    "enablePullRequestAutoMerge": {
      "pullRequest": {
        "number": 77,
        "autoMergeRequest": {
          "enabledAt": "2026-05-26T17:00:00Z",
          "mergeMethod": "SQUASH"
        }
      }
    }
  }
}
JSON
}

write_graphql_error() {
  local message="$1"
  cat > "${FIXTURE_DIR}/graphql.json" <<JSON
{
  "data": null,
  "errors": [ { "message": "${message}" } ]
}
JSON
}

@test "enables auto-merge with squash by default" {
  run "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Auto-merge enabled on PR #77 with method SQUASH."* ]]
  grep -Fq "endpoint=graphql" "${CALL_LOG}"
  grep -Fq "field=method=SQUASH" "${CALL_LOG}"
}

@test "honors merge method = merge" {
  run env MERGE_METHOD=merge "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"with method MERGE."* ]]
  grep -Fq "field=method=MERGE" "${CALL_LOG}"
}

@test "honors merge method = rebase" {
  run env MERGE_METHOD=rebase "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"with method REBASE."* ]]
  grep -Fq "field=method=REBASE" "${CALL_LOG}"
}

@test "merge method is case-insensitive" {
  run env MERGE_METHOD=SQUASH "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"with method SQUASH."* ]]
}

@test "rejects unsupported merge method" {
  run env MERGE_METHOD=fast-forward "${SCRIPT}"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Unsupported merge-method 'fast-forward'"* ]]
}

@test "skips PRs that are already merged" {
  write_pr_merged

  run "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do"* ]]
  ! grep -Fq "endpoint=graphql" "${CALL_LOG}"
}

@test "skips PRs that are closed without merging" {
  write_pr_closed

  run "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do"* ]]
  ! grep -Fq "endpoint=graphql" "${CALL_LOG}"
}

@test "is idempotent when auto-merge is already enabled with the same method" {
  write_pr_auto_merge_enabled "squash"

  run "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"already enabled"* ]]
  ! grep -Fq "endpoint=graphql" "${CALL_LOG}"
}

@test "re-enables when stored method differs from requested method" {
  write_pr_auto_merge_enabled "merge"

  run env MERGE_METHOD=squash "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Auto-merge enabled on PR #77 with method SQUASH."* ]]
  grep -Fq "endpoint=graphql" "${CALL_LOG}"
}

@test "warns and exits 0 when the repo has not enabled auto-merge" {
  write_graphql_error "Pull request Auto merge is not allowed for this repository"

  run "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"Allow auto-merge"* ]]
  [[ "$output" == *"Auto merge is not allowed"* ]]
}

@test "warns and exits 0 when branch protection is missing" {
  write_graphql_error "Branch is not protected by branch protection rules"

  run "${SCRIPT}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"branch protection"* ]]
}

@test "fails when GraphQL returns an unrecognized error (e.g. permission denied)" {
  write_graphql_error "Resource not accessible by integration"

  run "${SCRIPT}"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"Unexpected GraphQL error"* ]]
  [[ "$output" == *"Resource not accessible"* ]]
}

@test "fails when PR payload has no node_id" {
  write_pr_missing_node_id

  run "${SCRIPT}"

  [ "$status" -eq 1 ]
  [[ "$output" == *"node_id"* ]]
}

@test "fails when required env vars are missing" {
  run env -u PR_NUMBER "${SCRIPT}"

  [ "$status" -eq 1 ]
  [[ "$output" == *"PR_NUMBER"* ]]
}
