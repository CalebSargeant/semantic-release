#!/usr/bin/env bats

# Behaviour coverage for scripts/inject-version-files.sh — the step that writes
# the released version back into the manifests that carry it and pushes that
# commit to the release branch.
#
# Nothing is stubbed. A throwaway workspace repo with a real bare repo as
# `origin` exercises the genuine add/commit/fetch/rebase/push path, including
# the race and rejection branches: a second clone pushing first produces the
# rebase case, and an origin whose branch is checked out produces a push
# rejection that is *not* a race. `jq` is assumed present (the rest of the
# suite already assumes it); YAML tests skip when `yq` is absent.
#
# The script must never fail the release, so almost every assertion here pairs
# a warning with `status -eq 0`.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/inject-version-files.sh"

# Lifted verbatim from the inline `Inject version into tracked file` step in
# action.yml as it stood before this script replaced it:
#   git commit -m "chore(release): persist version ${VERSION} in $(basename "${FILE}") [skip ci]"
# Existing consumers filter their history on this exact text, so the one-file
# case is pinned against it rather than against the new script's own wording.
LEGACY_ONE_FILE_SUBJECT='chore(release): persist version %s in %s [skip ci]'

setup() {
  WORK=$(mktemp -d)
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

  REPO="${WORK}/repo"
  git init -q "${REPO}"
  cd "${REPO}"
  echo seed > README.md
  git add README.md
  git commit -qm seed

  # Whatever `git init` called the default branch — the fixture must not care.
  BRANCH=$(git symbolic-ref --short HEAD)
  REMOTE="${WORK}/remote.git"
  git clone -q --bare "${REPO}" "${REMOTE}"
  git remote add origin "${REMOTE}"
  git fetch -q origin

  export GITHUB_REF_NAME="${BRANCH}"
  export GITHUB_TOKEN="t0ken"
  export GITHUB_OUTPUT="${WORK}/output"
  : > "${GITHUB_OUTPUT}"
  export NORMALIZE_VERSION="1.4.0"
  export INPUT_VERSION_FILE_JSON_PATH=".Application.Version"
  export INPUT_VERSION_FILE_YAML_PATH=".appVersion"
}

teardown() {
  cd /
  rm -rf "${WORK}"
}

# A JSON manifest of the shape the .NET appsettings use ($2 = current version).
write_json() {
  mkdir -p "$(dirname "$1")"
  printf '{\n  "Application": {\n    "Name": "app",\n    "Version": "%s"\n  }\n}\n' "${2:-0.0.0}" > "$1"
}

# Make the fixtures tracked, as they are in a real consumer's checkout.
track() {
  git add -A
  git commit -qm fixtures
}

json_version() {
  jq -r '.Application.Version' "$1"
}

remote_subject() {
  git -C "${REMOTE}" log -1 --pretty=%s "${BRANCH}"
}

# ── the single-file case: unchanged from the inline step ────────────────────

@test "one JSON file is injected, committed and pushed" {
  write_json appsettings.json
  track
  run env INPUT_VERSION_FILE="appsettings.json" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(json_version appsettings.json)" = "1.4.0" ]
  [[ "$output" == *"Injected version 1.4.0 into appsettings.json at .Application.Version"* ]]
  [[ "$output" == *"on attempt 1/5"* ]]
  [ "$(remote_subject)" = "chore(release): persist version 1.4.0 in appsettings.json [skip ci]" ]
  grep -Fxq "updated_count=1" "${GITHUB_OUTPUT}"
}

@test "the one-file commit subject is byte-identical to the inline step's" {
  write_json config/appsettings.json
  track
  run env INPUT_VERSION_FILE="config/appsettings.json" "${SCRIPT}"
  [ "$status" -eq 0 ]
  # basename, not the path — the historical message used $(basename "${FILE}").
  diff <(printf "${LEGACY_ONE_FILE_SUBJECT}\n" "1.4.0" "appsettings.json") \
       <(git log -1 --pretty=%s)
}

@test "one YAML file is injected with yq at the YAML path" {
  command -v yq >/dev/null || skip "yq not installed"
  printf 'name: chart\nappVersion: 0.0.0\n' > Chart.yaml
  track
  run env INPUT_VERSION_FILE="Chart.yaml" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(yq '.appVersion' Chart.yaml)" = "1.4.0" ]
  [ "$(git log -1 --pretty=%s)" = "chore(release): persist version 1.4.0 in Chart.yaml [skip ci]" ]
  grep -Fxq "updated_count=1" "${GITHUB_OUTPUT}"
}

@test "the deprecated gitversion alias still injects and still warns" {
  write_json appsettings.json
  track
  run env INPUT_VERSION_FILE="" \
    INPUT_GITVERSION_APPSETTINGS_FILE="appsettings.json" \
    INPUT_GITVERSION_APPSETTINGS_VERSION_PATH=".Application.Version" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::gitversion-appsettings-file is deprecated; use version-file."* ]]
  [ "$(json_version appsettings.json)" = "1.4.0" ]
  grep -Fxq "updated_count=1" "${GITHUB_OUTPUT}"
}

# ── several files ───────────────────────────────────────────────────────────

@test "several newline-separated paths land in one commit" {
  write_json a/appsettings.json
  write_json b/appsettings.json
  write_json c/appsettings.json
  track
  before=$(git rev-parse HEAD)
  run env INPUT_VERSION_FILE=$'a/appsettings.json\nb/appsettings.json\nc/appsettings.json' "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(git rev-list --count "${before}"..HEAD)" -eq 1 ]
  [ "$(git log -1 --pretty=%s)" = "chore(release): persist version 1.4.0 in 3 files [skip ci]" ]
  for dir in a b c; do
    [ "$(json_version "${dir}/appsettings.json")" = "1.4.0" ]
  done
  grep -Fxq "updated_count=3" "${GITHUB_OUTPUT}"
}

@test "comma-separated paths are accepted and trimmed" {
  write_json a/appsettings.json
  write_json b/appsettings.json
  track
  run env INPUT_VERSION_FILE="a/appsettings.json ,  b/appsettings.json" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(json_version a/appsettings.json)" = "1.4.0" ]
  [ "$(json_version b/appsettings.json)" = "1.4.0" ]
  grep -Fxq "updated_count=2" "${GITHUB_OUTPUT}"
}

@test "JSON and YAML in one spec are dispatched per file and committed together" {
  command -v yq >/dev/null || skip "yq not installed"
  write_json appsettings.json
  printf 'name: chart\nappVersion: 0.0.0\n' > Chart.yaml
  track
  run env INPUT_VERSION_FILE=$'appsettings.json\nChart.yaml' "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(json_version appsettings.json)" = "1.4.0" ]
  [ "$(yq '.appVersion' Chart.yaml)" = "1.4.0" ]
  [ "$(git log -1 --pretty=%s)" = "chore(release): persist version 1.4.0 in 2 files [skip ci]" ]
}

@test "a glob expands to every matching workspace manifest" {
  write_json packages/api/package.json
  write_json packages/web/package.json
  write_json packages/web/other.json
  track
  run env INPUT_VERSION_FILE="packages/*/package.json" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(json_version packages/api/package.json)" = "1.4.0" ]
  [ "$(json_version packages/web/package.json)" = "1.4.0" ]
  # The glob is a filter, not a directory sweep.
  [ "$(json_version packages/web/other.json)" = "0.0.0" ]
  grep -Fxq "updated_count=2" "${GITHUB_OUTPUT}"
}

@test "** matches at any depth" {
  write_json services/api/manifest.json
  write_json services/api/nested/deep/manifest.json
  track
  run env INPUT_VERSION_FILE="services/**/manifest.json" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(json_version services/api/manifest.json)" = "1.4.0" ]
  [ "$(json_version services/api/nested/deep/manifest.json)" = "1.4.0" ]
  grep -Fxq "updated_count=2" "${GITHUB_OUTPUT}"
}

@test "a file named twice (explicitly and by a glob) is counted once" {
  write_json packages/api/package.json
  track
  run env INPUT_VERSION_FILE=$'packages/api/package.json\npackages/*/package.json' "${SCRIPT}"
  [ "$status" -eq 0 ]
  # De-duplicated back to one file, so the historical one-file subject applies.
  [ "$(git log -1 --pretty=%s)" = "chore(release): persist version 1.4.0 in package.json [skip ci]" ]
  grep -Fxq "updated_count=1" "${GITHUB_OUTPUT}"
}

# ── warn and skip: nothing here may fail the release ────────────────────────

@test "a missing path warns with the historical wording and exits 0" {
  before=$(git rev-parse HEAD)
  run env INPUT_VERSION_FILE="appsettings.json" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::version-file 'appsettings.json' not found — skipping injection."* ]]
  [ "$(git rev-parse HEAD)" = "${before}" ]
  grep -Fxq "updated_count=0" "${GITHUB_OUTPUT}"
}

@test "a glob matching nothing warns as a pattern and exits 0" {
  before=$(git rev-parse HEAD)
  run env INPUT_VERSION_FILE="packages/*/package.json" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"matched no files"* ]]
  [ "$(git rev-parse HEAD)" = "${before}" ]
  grep -Fxq "updated_count=0" "${GITHUB_OUTPUT}"
}

@test "a missing path does not stop the paths that do exist" {
  write_json b/appsettings.json
  track
  run env INPUT_VERSION_FILE=$'a/appsettings.json\nb/appsettings.json' "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::version-file 'a/appsettings.json' not found"* ]]
  [ "$(json_version b/appsettings.json)" = "1.4.0" ]
  [ "$(git log -1 --pretty=%s)" = "chore(release): persist version 1.4.0 in appsettings.json [skip ci]" ]
  grep -Fxq "updated_count=1" "${GITHUB_OUTPUT}"
}

@test "a file the path expression cannot be applied to is skipped, the rest commit" {
  write_json ok/appsettings.json
  mkdir -p bad
  printf '[1, 2, 3]\n' > bad/appsettings.json
  track
  run env INPUT_VERSION_FILE=$'bad/appsettings.json\nok/appsettings.json' "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::Failed to inject version into bad/appsettings.json at path '.Application.Version'"* ]]
  [ "$(json_version ok/appsettings.json)" = "1.4.0" ]
  [ "$(git log -1 --pretty=%s)" = "chore(release): persist version 1.4.0 in appsettings.json [skip ci]" ]
  grep -Fxq "updated_count=1" "${GITHUB_OUTPUT}"
}

@test "a path expression that is not valid jq skips every file without failing" {
  write_json a/appsettings.json
  write_json b/appsettings.json
  track
  before=$(git rev-parse HEAD)
  run env INPUT_VERSION_FILE=$'a/appsettings.json\nb/appsettings.json' \
    INPUT_VERSION_FILE_JSON_PATH=".Application[" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(git rev-parse HEAD)" = "${before}" ]
  grep -Fxq "updated_count=0" "${GITHUB_OUTPUT}"
}

@test "an unresolved version warns and skips" {
  write_json appsettings.json
  track
  run env INPUT_VERSION_FILE="appsettings.json" NORMALIZE_VERSION="" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::No version resolved — skipping injection."* ]]
  grep -Fxq "updated_count=0" "${GITHUB_OUTPUT}"
}

@test "a missing file is reported before an unresolved version" {
  # Ordering carried over from the inline step: the path complaint is the more
  # actionable of the two, and it is what consumers' logs already show.
  run env INPUT_VERSION_FILE="appsettings.json" NORMALIZE_VERSION="" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not found — skipping injection."* ]]
  [[ "$output" != *"No version resolved"* ]]
}

# ── idempotence ─────────────────────────────────────────────────────────────

@test "no commit when the file already carries the version" {
  write_json appsettings.json 1.4.0
  track
  before=$(git rev-parse HEAD)
  run env INPUT_VERSION_FILE="appsettings.json" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No changes to commit — file already at 1.4.0."* ]]
  [ "$(git rev-parse HEAD)" = "${before}" ]
  grep -Fxq "updated_count=0" "${GITHUB_OUTPUT}"
}

@test "no commit when every file already carries the version" {
  write_json a/appsettings.json 1.4.0
  write_json b/appsettings.json 1.4.0
  track
  before=$(git rev-parse HEAD)
  run env INPUT_VERSION_FILE=$'a/appsettings.json\nb/appsettings.json' "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No changes to commit — 2 files already at 1.4.0."* ]]
  [ "$(git rev-parse HEAD)" = "${before}" ]
  grep -Fxq "updated_count=0" "${GITHUB_OUTPUT}"
}

@test "a file already at the version is not counted alongside one that moved" {
  write_json a/appsettings.json 1.4.0
  write_json b/appsettings.json
  track
  run env INPUT_VERSION_FILE=$'a/appsettings.json\nb/appsettings.json' "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(git log -1 --pretty=%s)" = "chore(release): persist version 1.4.0 in appsettings.json [skip ci]" ]
  grep -Fxq "updated_count=1" "${GITHUB_OUTPUT}"
}

# ── the push loop ───────────────────────────────────────────────────────────

@test "a commit that landed on the branch first is rebased onto, not clobbered" {
  write_json appsettings.json
  track
  git push -q origin "${BRANCH}"

  # Another automation lands a commit between our checkout and our push.
  OTHER="${WORK}/other"
  git clone -q "${REMOTE}" "${OTHER}"
  echo bump > "${OTHER}/flux.yaml"
  git -C "${OTHER}" add flux.yaml
  git -C "${OTHER}" commit -qm "chore: image bump"
  git -C "${OTHER}" push -q origin "${BRANCH}"

  run env INPUT_VERSION_FILE="appsettings.json" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"on attempt 1/5"* ]]
  [ "$(remote_subject)" = "chore(release): persist version 1.4.0 in appsettings.json [skip ci]" ]
  # The other automation's commit survived underneath ours.
  [ "$(git -C "${REMOTE}" log -1 --pretty=%s "${BRANCH}~1")" = "chore: image bump" ]
}

@test "a push rejection that is not a race warns once and lets the release finish" {
  # An origin whose branch is checked out refuses the update — the shape of a
  # ruleset or auth rejection: not retryable, and not a reason to fail.
  NONBARE="${WORK}/nonbare"
  git clone -q "${REMOTE}" "${NONBARE}"
  git remote set-url origin "${NONBARE}"
  git fetch -q origin

  write_json appsettings.json
  track
  run env INPUT_VERSION_FILE="appsettings.json" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::Could not push appsettings.json commit:"* ]]
  [[ "$output" == *"Continuing release."* ]]
  # The commit was made, so it is counted even though it did not reach origin.
  [ "$(git log -1 --pretty=%s)" = "chore(release): persist version 1.4.0 in appsettings.json [skip ci]" ]
  grep -Fxq "updated_count=1" "${GITHUB_OUTPUT}"
}

@test "the multi-file push messages name the file count, not a path" {
  write_json a/appsettings.json
  write_json b/appsettings.json
  track
  run env INPUT_VERSION_FILE=$'a/appsettings.json\nb/appsettings.json' "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pushed 2 version files update for 1.4.0 to ${BRANCH} on attempt 1/5."* ]]
}

# ── output plumbing ─────────────────────────────────────────────────────────

@test "updated_count is written exactly once per run" {
  write_json appsettings.json
  track
  run env INPUT_VERSION_FILE="appsettings.json" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^updated_count=' "${GITHUB_OUTPUT}")" -eq 1 ]
}

@test "an unset GITHUB_OUTPUT is not a failure" {
  write_json appsettings.json
  track
  run env -u GITHUB_OUTPUT INPUT_VERSION_FILE="appsettings.json" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(json_version appsettings.json)" = "1.4.0" ]
}
