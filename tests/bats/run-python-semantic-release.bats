#!/usr/bin/env bats

# Behaviour coverage for scripts/run-python-semantic-release.sh.
#
# The script replaces the upstream Docker-based python-semantic-release
# action, so the thing worth pinning down is the argv it hands to the
# `semantic-release` CLI: those flags are what reproduce the action inputs
# action.yml used to pass. Each test points PSR_BIN at a stub that records
# its arguments and environment, which also keeps the suite off PyPI.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/run-python-semantic-release.sh"

setup() {
  WORK=$(mktemp -d)
  export ARGS_FILE="${WORK}/args"
  export TOKEN_FILE="${WORK}/token"

  # Hermetic: a developer's global gitconfig must not decide whether the
  # script thinks user.name is already set.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  REPO="${WORK}/repo"
  git init --initial-branch=main "${REPO}" >/dev/null
  cd "${REPO}" || return 1

  export PSR_BIN="${WORK}/semantic-release"
  cat > "${PSR_BIN}" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${ARGS_FILE}"
printf '%s' "${GH_TOKEN:-<unset>}" > "${TOKEN_FILE}"
exit "${STUB_EXIT:-0}"
STUB
  chmod +x "${PSR_BIN}"

  export GH_TOKEN=fake-token
  export INPUT_GIT_COMMITTER_NAME="github-actions[bot]"
  unset INPUT_PRERELEASE INPUT_PRERELEASE_TOKEN INPUT_FORCE INPUT_CHANGELOG || true
  unset PSR_VERSION PYTHON_BIN STUB_EXIT || true
}

teardown() {
  cd / || true
  rm -rf "${WORK}"
}

# Recorded argv, one arg per line, flattened to a single space-separated line.
psr_args() {
  tr '\n' ' ' < "${ARGS_FILE}"
}

@test "always passes the flags action.yml pinned on the Docker action" {
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(psr_args)" = "-v version --commit --no-vcs-release --skip-build " ]
}

@test "exports GH_TOKEN to semantic-release" {
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(cat "${TOKEN_FILE}")" = "fake-token" ]
}

@test "refuses to run without GH_TOKEN" {
  unset GH_TOKEN
  run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GH_TOKEN is required"* ]]
  [ ! -f "${ARGS_FILE}" ]
}

@test "prerelease=true maps to --as-prerelease, not --prerelease" {
  export INPUT_PRERELEASE=true
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$(psr_args)" == *" --as-prerelease "* ]]
  [[ "$(psr_args)" != *" --prerelease "* ]]
}

@test "prerelease=false omits the flag entirely" {
  export INPUT_PRERELEASE=false
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$(psr_args)" != *"prerelease"* ]]
}

@test "prerelease token is passed as a separate argument" {
  export INPUT_PRERELEASE=true INPUT_PRERELEASE_TOKEN=dev
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$(psr_args)" == *"--prerelease-token dev "* ]]
}

@test "prerelease token is dropped when empty" {
  export INPUT_PRERELEASE=true INPUT_PRERELEASE_TOKEN=""
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$(psr_args)" != *"--prerelease-token"* ]]
}

@test "changelog=true maps to --changelog" {
  export INPUT_CHANGELOG=true
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$(psr_args)" == *" --changelog "* ]]
}

@test "changelog=false maps to --no-changelog" {
  export INPUT_CHANGELOG=false
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$(psr_args)" == *" --no-changelog "* ]]
}

@test "a non-boolean changelog value is an error" {
  export INPUT_CHANGELOG=yes
  run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::Invalid value for changelog"* ]]
  [ ! -f "${ARGS_FILE}" ]
}

@test "a non-boolean prerelease value is an error" {
  export INPUT_PRERELEASE=1
  run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::Invalid value for prerelease"* ]]
  [ ! -f "${ARGS_FILE}" ]
}

@test "each supported force-bump level becomes its own flag" {
  for level in prerelease patch minor major; do
    export INPUT_FORCE="${level}"
    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$(psr_args)" == *" --${level} "* ]]
  done
}

@test "an unrecognised force-bump warns and releases anyway" {
  export INPUT_FORCE=bogus
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::Ignoring force-bump 'bogus'"* ]]
  [[ "$(psr_args)" != *"bogus"* ]]
  [[ "$(psr_args)" == *"version"* ]]
}

@test "an empty force-bump adds no flag" {
  export INPUT_FORCE=""
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(psr_args)" = "-v version --commit --no-vcs-release --skip-build " ]
}

@test "sets the committer name when the repo has none" {
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(git config --get user.name)" = "github-actions[bot]" ]
}

@test "keeps a committer name the caller already configured" {
  git config user.name "release-bot"
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(git config --get user.name)" = "release-bot" ]
}

@test "configures no committer name when the input is empty" {
  export INPUT_GIT_COMMITTER_NAME=""
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  run git config --get user.name
  [ "$status" -ne 0 ]
}

@test "propagates the semantic-release exit code" {
  export STUB_EXIT=2
  run bash "${SCRIPT}"
  [ "$status" -eq 2 ]
}

@test "demands a pinned version when it has to install semantic-release" {
  unset PSR_BIN
  run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PSR_VERSION is required"* ]]
}

@test "demands an interpreter when it has to install semantic-release" {
  unset PSR_BIN
  export PSR_VERSION=10.4.1
  run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PYTHON_BIN is required"* ]]
}

@test "action.yml no longer references the Docker-based upstream action" {
  # Guards the regression this script exists to fix: a `uses:` on a Docker
  # action makes every release run build the image during job setup, even
  # when the step is skipped.
  run grep -n "uses: python-semantic-release/" "${BATS_TEST_DIRNAME}/../../action.yml"
  [ "$status" -ne 0 ]
}
