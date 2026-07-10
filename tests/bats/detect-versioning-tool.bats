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

# The `config=` output: the GitVersion config path handed to gittools as
# configFilePath. Empty for every non-gitversion tool. Matched with sed rather
# than `cut -d=` so a path is never truncated at an '=' inside it.
emitted_config() {
  grep '^config=' "${GITHUB_OUTPUT}" | sed 's/^config=//'
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

@test "relative gitversion-config is scoped to working-directory, not CWD" {
  # Regression: gitversion-config defaults to a *relative* 'GitVersion.yml',
  # which the old code resolved against the step's CWD (repo root) rather than
  # working-directory. A stray root GitVersion.yml then manufactured a false
  # tier-1 conflict against a subdir that unambiguously uses another tool.
  mkdir -p "${WORK}/service"
  printf '[tool.semantic_release]\n' > "${WORK}/service/pyproject.toml"  # tier-1 python, in WD
  echo 'mode: ContinuousDelivery' > "${WORK}/GitVersion.yml"            # stray config at "repo root"
  cd "${WORK}"                                                          # CWD = repo root
  run env INPUT_VERSIONING_TOOL=auto WORKING_DIRECTORY="service" \
      GITVERSION_CONFIG="GitVersion.yml" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "semantic-release-python" ]
}

# ── Robustness ───────────────────────────────────────────────────────────────

@test "auto: many .csproj files resolve without a SIGPIPE crash" {
  # Regression: `find ... | head -n1` under `set -euo pipefail` aborted the
  # script (exit 141) once find's output exceeded the ~64 KB pipe buffer and
  # head closed the pipe early. `find -print -quit` stops at the first match.
  local pad i
  pad="$(printf 'x%.0s' {1..120})"
  for i in $(seq 1 700); do
    echo '<Project/>' > "${WORK}/proj_${pad}_${i}.csproj"
  done
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "gitversion" ]
}

# ── The `config` output (configFilePath for gittools) ────────────────────────
#
# gittools resolves configFilePath against the workspace root, because the
# action never sets targetPath, while detection is scoped to working-directory.
# The emitted path therefore carries the ${WD} prefix so the two agree.

@test "config: discovered GitVersion.yml is emitted with its working-directory prefix" {
  echo 'mode: ContinuousDelivery' > "${WORK}/GitVersion.yml"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "gitversion" ]
  [ "$(emitted_config)" = "${WORK}/GitVersion.yml" ]
}

@test "config: the GitVersion.yaml spelling is discovered too" {
  echo 'mode: ContinuousDelivery' > "${WORK}/GitVersion.yaml"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(emitted_config)" = "${WORK}/GitVersion.yaml" ]
}

@test "config: a subdirectory GitVersion.yml keeps its working-directory prefix" {
  # Regression: Execute GitVersion runs at the workspace root, so a bare
  # 'GitVersion.yml' would miss a config living under working-directory and
  # silently fall back to GitVersion's built-in defaults.
  mkdir -p "${WORK}/service"
  echo 'mode: ContinuousDelivery' > "${WORK}/service/GitVersion.yml"
  cd "${WORK}"
  run env INPUT_VERSIONING_TOOL=auto WORKING_DIRECTORY="service" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "gitversion" ]
  [ "$(emitted_config)" = "service/GitVersion.yml" ]
}

@test "config: a gitversion repo with no config emits empty" {
  # The *.csproj-only case: nothing to point gittools at, so GitVersion runs on
  # its built-in defaults instead of erroring on a missing file.
  echo '<Project/>' > "${WORK}/app.csproj"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "gitversion" ]
  [ -z "$(emitted_config)" ]
}

@test "config: explicit gitversion-config is emitted even when the file is missing" {
  # A bad explicit path must reach gittools so it fails loudly, rather than
  # being swallowed into a silent built-in-defaults run.
  cd "${WORK}"
  run env INPUT_VERSIONING_TOOL=gitversion WORKING_DIRECTORY="." \
      GITVERSION_CONFIG="build/absent.yml" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(emitted_config)" = "build/absent.yml" ]
}

@test "config: a relative gitversion-config is joined onto working-directory" {
  mkdir -p "${WORK}/service/build"
  echo 'mode: ContinuousDelivery' > "${WORK}/service/build/gv.yml"
  cd "${WORK}"
  run env INPUT_VERSIONING_TOOL=gitversion WORKING_DIRECTORY="service" \
      GITVERSION_CONFIG="build/gv.yml" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(emitted_config)" = "service/build/gv.yml" ]
}

@test "config: an absolute gitversion-config is passed through unchanged" {
  echo 'mode: ContinuousDelivery' > "${WORK}/gv.yml"
  run env INPUT_VERSIONING_TOOL=gitversion WORKING_DIRECTORY="${WORK}" \
      GITVERSION_CONFIG="${WORK}/gv.yml" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(emitted_config)" = "${WORK}/gv.yml" ]
}

@test "config: working-directory '.' does not leak a './' prefix" {
  echo 'mode: ContinuousDelivery' > "${WORK}/GitVersion.yml"
  cd "${WORK}"
  run env INPUT_VERSIONING_TOOL=auto WORKING_DIRECTORY="." "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(emitted_config)" = "GitVersion.yml" ]
}

@test "config: a non-gitversion tool emits an empty config" {
  # No GITVERSION_CONFIG here: an existing one would be a second tier-1 signal
  # and the run would fail as a conflict rather than reach the emit.
  printf '[tool.semantic_release]\n' > "${WORK}/pyproject.toml"
  detect_auto
  [ "$status" -eq 0 ]
  [ "$(resolved)" = "semantic-release-python" ]
  [ -z "$(emitted_config)" ]
}
