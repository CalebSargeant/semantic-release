#!/usr/bin/env bats

# Behaviour coverage for scripts/semantic-release-deps.sh (and the
# extract-semrel-plugins.mjs helper it shells out to).
#
# Regression guard for the "Cannot find module '@semantic-release/changelog'"
# failure: a consumer whose .releaserc.json lists the changelog + git plugins
# must have those packages included in the install set, so they land in the
# same node_modules as semantic-release and resolve at runtime.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/semantic-release-deps.sh"

setup() {
  command -v node >/dev/null 2>&1 || skip "node not available"
  WORK=$(mktemp -d)
}

teardown() {
  rm -rf "${WORK}"
}

@test "baseline set is emitted when there is no config" {
  cd "${WORK}"
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  for pkg in semantic-release @semantic-release/changelog \
    @semantic-release/commit-analyzer @semantic-release/git \
    @semantic-release/github @semantic-release/release-notes-generator; do
    echo "$output" | grep -qw -- "$pkg" || { echo "missing $pkg in: $output"; false; }
  done
}

@test "changelog + git from a .releaserc.json are included (the regression)" {
  cd "${WORK}"
  cat > .releaserc.json <<'JSON'
{
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    ["@semantic-release/changelog", { "changelogFile": "CHANGELOG.md" }],
    ["@semantic-release/git", { "assets": ["CHANGELOG.md"] }],
    "@semantic-release/github"
  ]
}
JSON
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qw -- "@semantic-release/changelog"
  echo "$output" | grep -qw -- "@semantic-release/git"
}

@test "third-party plugins from config are added; local paths are skipped" {
  cd "${WORK}"
  cat > .releaserc.json <<'JSON'
{
  "plugins": [
    "@semantic-release/commit-analyzer",
    ["@semantic-release/exec", { "publishCmd": "true" }],
    "./local-plugin.js"
  ]
}
JSON
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qw -- "@semantic-release/exec"
  ! echo "$output" | grep -q -- "./local-plugin.js"
}

@test "plugins from a package.json release key are included" {
  cd "${WORK}"
  cat > package.json <<'JSON'
{
  "name": "consumer",
  "release": { "plugins": ["semantic-release-slack-bot"] }
}
JSON
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qw -- "semantic-release-slack-bot"
}

@test "a shareable config in \"extends\" is installed (semantic-release-monorepo)" {
  # semantic-release-monorepo — the standard way to scope an npm release to one
  # package of a repo — is consumed via "extends" and never appears under
  # "plugins". Missing it means MODULE_NOT_FOUND at config load, before any
  # release logic runs.
  cd "${WORK}"
  cat > .releaserc.json <<'JSON'
{
  "extends": "semantic-release-monorepo",
  "plugins": ["@semantic-release/commit-analyzer"]
}
JSON
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qw -- "semantic-release-monorepo"
}

@test "\"extends\" also accepts an array, and local paths are still skipped" {
  cd "${WORK}"
  cat > .releaserc.json <<'JSON'
{ "extends": ["semantic-release-monorepo", "./local-config.js"] }
JSON
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qw -- "semantic-release-monorepo"
  ! echo "$output" | grep -q -- "./local-config.js"
}

@test "\"extends\" in a package.json release key is included" {
  cd "${WORK}"
  cat > package.json <<'JSON'
{
  "name": "consumer",
  "release": { "extends": "semantic-release-monorepo" }
}
JSON
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qw -- "semantic-release-monorepo"
}

@test "no duplicate packages in the output" {
  cd "${WORK}"
  cat > .releaserc.json <<'JSON'
{ "plugins": ["@semantic-release/changelog", "@semantic-release/git"] }
JSON
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  # changelog appears in both the baseline and the config; expect it once.
  count=$(echo "$output" | tr ' ' '\n' | grep -c -- "^@semantic-release/changelog$")
  [ "$count" -eq 1 ]
}
