#!/usr/bin/env bats

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/check-branch-naming.sh"

setup() {
  unset GITHUB_HEAD_REF PROMOTE_BRANCH_PREFIX EXTRA_BRANCH_PREFIXES || true
}

@test "accepts allowed TBD type prefix" {
  run env GITHUB_HEAD_REF="feat/new-thing" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"follows TBD naming convention"* ]]
}

@test "accepts every documented TBD type prefix" {
  for prefix in feat fix chore hotfix docs refactor perf test ci style build revert deploy release; do
    run env GITHUB_HEAD_REF="${prefix}/some-change" "${SCRIPT}"
    [ "$status" -eq 0 ]
  done
}

@test "accepts default promote/ prefix" {
  run env GITHUB_HEAD_REF="promote/staging/1.2.3-dev.1" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"follows TBD naming convention"* ]]
}

@test "accepts custom PROMOTE_BRANCH_PREFIX" {
  run env GITHUB_HEAD_REF="release/staging/1.2.3" PROMOTE_BRANCH_PREFIX="release" "${SCRIPT}"
  [ "$status" -eq 0 ]
}

@test "accepts a single EXTRA_BRANCH_PREFIXES entry" {
  run env GITHUB_HEAD_REF="spike/poc" EXTRA_BRANCH_PREFIXES="spike" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"follows TBD naming convention"* ]]
}

@test "accepts EXTRA_BRANCH_PREFIXES given as a comma/space list" {
  run env GITHUB_HEAD_REF="wip/experiment" EXTRA_BRANCH_PREFIXES="spike, wip" "${SCRIPT}"
  [ "$status" -eq 0 ]
  run env GITHUB_HEAD_REF="spike/poc" EXTRA_BRANCH_PREFIXES="spike wip" "${SCRIPT}"
  [ "$status" -eq 0 ]
}

@test "does not accept a prefix outside the extras list" {
  run env GITHUB_HEAD_REF="wip/experiment" EXTRA_BRANCH_PREFIXES="spike" "${SCRIPT}"
  [ "$status" -eq 1 ]
}

@test "error message lists the resolved allowed types" {
  run env GITHUB_HEAD_REF="wip/experiment" EXTRA_BRANCH_PREFIXES="spike" "${SCRIPT}"
  [[ "$output" == *"Allowed types: "* ]]
  [[ "$output" == *"deploy"* ]]
  [[ "$output" == *"spike"* ]]
}

@test "rejects disallowed prefix" {
  run env GITHUB_HEAD_REF="wip/some-thing" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not follow TBD naming convention"* ]]
}

@test "rejects branch with no slash" {
  run env GITHUB_HEAD_REF="feature-branch" "${SCRIPT}"
  [ "$status" -eq 1 ]
}

@test "errors when GITHUB_HEAD_REF is empty" {
  run env GITHUB_HEAD_REF="" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"GITHUB_HEAD_REF is empty"* ]]
}

@test "bypasses dependabot/ branches" {
  run env GITHUB_HEAD_REF="dependabot/github_actions/actions/upload-artifact-7" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bot-generated branch"* ]]
}

@test "bypasses renovate/ branches" {
  run env GITHUB_HEAD_REF="renovate/npm-foo-1.x" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bot-generated branch"* ]]
}

@test "bot bypass only matches at start of branch name" {
  run env GITHUB_HEAD_REF="feat/add-dependabot/config" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"follows TBD naming convention"* ]]
}
