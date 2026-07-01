#!/usr/bin/env bats

# Behaviour coverage for scripts/detect-versioning-tool.sh — the `auto`
# resolution behind `versioning-tool`. Each test builds a throwaway working
# directory with the markers under test and asserts the resolved tool (written
# to $GITHUB_OUTPUT as `tool=<value>`) plus the exit code.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/detect-versioning-tool.sh"

setup() {
  WORK=$(mktemp -d)
  export GITHUB_OUTPUT="${WORK}/output"
  : > "${GITHUB_OUTPUT}"
  unset GITVERSION_CONFIG RELEASE_PLEASE_CONFIG_FILE || true
}

teardown() {
  rm -rf "${WORK}"
}

# Resolve with auto against $WORK. Extra `KEY=VALUE` args are exported for the run.
detect_auto() {
  run env INPUT_VERSIONING_TOOL=auto WORKING_DIRECTORY="${WORK}" "$@" "${SCRIPT}"
}

resolved() {
  grep '^tool=' "${GITHUB_OUTPUT}" | cut -d= -f2
}

# ── Explicit passthrough ─────────────────────────────────────────────────────

@test "explicit tool is passed through unchanged" {
  for tool in semantic-release-python semantic-release-npm gitversion release-please; do
    : > "${GITHUB_OUTPUT}"
    run env INPUT_VERSIONING_TOOL="${tool}" WORKING_DIRECTORY="${WORK}" "${SCRIPT}"
    [ "$status" -eq 0 ]
    [ "$(resolved)" = "${tool}" ]
  done
}

@test "unrecognised explicit tool errors" {
  run env INPUT_VERSIONING_TOOL=maven-release WORKING_DIRECTORY="${WORK}" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not recognised"* ]]
}

@test "unset input defaults to auto detection" {
  printf '[tool.semantic_release]\nversion = "1.0.0"\n' > "${WORK}/pyproject.toml"
  run env WORKING_DIRECTORY="${WORK}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "semantic-release-python" ]
}

# ── Tier 1: authoritative release-tool config ────────────────────────────────

@test "auto: pyproject with [tool.semantic_release] -> semantic-release-python" {
  printf '[tool.semantic_release]\nversion = "1.0.0"\n' > "${WORK}/pyproject.toml"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "semantic-release-python" ]
}

@test "auto: pyproject with a [tool.semantic_release.*] subtable also matches" {
  printf '[tool.semantic_release.branches.main]\nmatch = "main"\n' > "${WORK}/pyproject.toml"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "semantic-release-python" ]
}

@test "auto: .releaserc.json -> semantic-release-npm" {
  echo '{}' > "${WORK}/.releaserc.json"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "semantic-release-npm" ]
}

@test "auto: release.config.js -> semantic-release-npm" {
  echo 'module.exports = {}' > "${WORK}/release.config.js"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "semantic-release-npm" ]
}

@test "auto: GitVersion.yml -> gitversion" {
  echo 'mode: ContinuousDelivery' > "${WORK}/GitVersion.yml"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "gitversion" ]
}

@test "auto: GitVersion.yaml -> gitversion" {
  echo 'mode: ContinuousDelivery' > "${WORK}/GitVersion.yaml"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "gitversion" ]
}

@test "auto: custom gitversion-config path -> gitversion" {
  mkdir -p "${WORK}/build"
  echo 'mode: ContinuousDelivery' > "${WORK}/build/gv.yml"
  detect_auto GITVERSION_CONFIG="${WORK}/build/gv.yml"
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "gitversion" ]
}

@test "auto: release-please-config.json -> release-please" {
  echo '{}' > "${WORK}/release-please-config.json"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "release-please" ]
}

@test "auto: .release-please-manifest.json -> release-please" {
  echo '{}' > "${WORK}/.release-please-manifest.json"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "release-please" ]
}

# ── Tier 2: ecosystem manifests ──────────────────────────────────────────────

@test "auto: bare pyproject.toml (no config table) -> semantic-release-python" {
  printf '[project]\nname = "x"\n' > "${WORK}/pyproject.toml"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "semantic-release-python" ]
}

@test "auto: setup.py -> semantic-release-python" {
  touch "${WORK}/setup.py"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "semantic-release-python" ]
}

@test "auto: package.json only -> semantic-release-npm" {
  echo '{"name":"x"}' > "${WORK}/package.json"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "semantic-release-npm" ]
}

@test "auto: nested .csproj -> gitversion" {
  mkdir -p "${WORK}/src/App"
  echo '<Project/>' > "${WORK}/src/App/App.csproj"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "gitversion" ]
}

@test "auto: .sln at root -> gitversion" {
  echo '' > "${WORK}/Solution.sln"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "gitversion" ]
}

# ── Precedence ───────────────────────────────────────────────────────────────

@test "tier 1 config beats a tier 2 manifest of another tool" {
  # pyproject config table (tier 1 python) + package.json (tier 2 npm) -> python.
  printf '[tool.semantic_release]\n' > "${WORK}/pyproject.toml"
  echo '{"name":"x"}' > "${WORK}/package.json"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "semantic-release-python" ]
}

@test "tier 2 tie broken by precedence: bare pyproject + package.json -> python" {
  printf '[project]\nname = "x"\n' > "${WORK}/pyproject.toml"
  echo '{"name":"x"}' > "${WORK}/package.json"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "semantic-release-python" ]
  [[ "$output" == *"multiple ecosystem manifests"* ]]
}

@test "tier 2 tie broken by precedence: package.json + .csproj -> npm" {
  echo '{"name":"x"}' > "${WORK}/package.json"
  echo '<Project/>' > "${WORK}/App.csproj"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "semantic-release-npm" ]
}

# ── Errors ───────────────────────────────────────────────────────────────────

@test "conflicting tier 1 configs error" {
  printf '[tool.semantic_release]\n' > "${WORK}/pyproject.toml"
  echo 'mode: ContinuousDelivery' > "${WORK}/GitVersion.yml"
  detect_auto
  [ "$status" -eq 1 ]
  [[ "$output" == *"conflicting release configs"* ]]
  [ -z "$(resolved)" ]
}

@test "no markers at all errors" {
  detect_auto
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not detect a versioning tool"* ]]
  [ -z "$(resolved)" ]
}

# ── Isolation ────────────────────────────────────────────────────────────────

@test "detection is scoped to working-directory" {
  # A marker outside WORKING_DIRECTORY must not leak into the result.
  mkdir -p "${WORK}/app"
  echo '{"name":"x"}' > "${WORK}/app/package.json"
  printf '[tool.semantic_release]\n' > "${WORK}/pyproject.toml"
  run env INPUT_VERSIONING_TOOL=auto WORKING_DIRECTORY="${WORK}/app" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "semantic-release-npm" ]
}
