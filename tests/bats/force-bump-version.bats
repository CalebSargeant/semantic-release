#!/usr/bin/env bats

# Behaviour coverage for scripts/force-bump-version.sh — the helper the
# semantic-release-npm paths use when the `force-bump` input is set. It
# must bump the latest *stable* tag (prerelease and junk tags never become
# the base), honour the tag prefix as a literal string, and fall back to
# 0.0.0 in a repo with no stable tag yet.
#
# Success cases capture stdout directly (stderr silenced), mirroring the
# `NEXT_VER=$(...)` callsites in action.yml: stdout must carry exactly the
# bumped version and nothing else.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/force-bump-version.sh"

setup() {
  WORK=$(mktemp -d)
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  git -C "${WORK}" init --initial-branch=main repo >/dev/null
  REPO="${WORK}/repo"
  git -C "${REPO}" -c user.name=tester -c user.email=t@example.com \
    commit --allow-empty -m "initial" >/dev/null
  cd "${REPO}"
}

teardown() {
  rm -rf "${WORK}"
}

tag() { git -C "${REPO}" tag "$1"; }

bumped() {
  env FORCE_BUMP="$1" TAG_PREFIX="${2-v}" "${SCRIPT}" 2>/dev/null
}

@test "patch bump from the latest stable tag" {
  tag v1.2.3
  [ "$(bumped patch)" = "1.2.4" ]
}

@test "minor bump resets patch" {
  tag v1.2.3
  [ "$(bumped minor)" = "1.3.0" ]
}

@test "major bump resets minor and patch" {
  tag v1.2.3
  [ "$(bumped major)" = "2.0.0" ]
}

@test "prerelease tags are never the bump base" {
  tag v1.2.3
  tag v1.2.4-rc.1
  tag v1.3.0-dev.7
  [ "$(bumped patch)" = "1.2.4" ]
}

@test "junk and non-semver tags are ignored" {
  tag v1.2.3
  tag v1.2
  tag v1.2.3.4
  tag very-old-tag
  [ "$(bumped patch)" = "1.2.4" ]
}

@test "versions sort numerically, not lexically" {
  tag v1.9.0
  tag v1.10.0
  [ "$(bumped patch)" = "1.10.1" ]
}

@test "a tag without the prefix is not considered when a prefix is set" {
  tag v1.2.3
  tag 9.9.9
  [ "$(bumped patch)" = "1.2.4" ]
}

@test "empty prefix bumps bare X.Y.Z tags" {
  tag 2.5.9
  [ "$(bumped minor "")" = "2.6.0" ]
}

@test "no stable tag yet bumps from 0.0.0" {
  tag v1.0.0-rc.1
  [ "$(bumped patch)" = "0.0.1" ]
  [ "$(bumped minor)" = "0.1.0" ]
  [ "$(bumped major)" = "1.0.0" ]
}

@test "unsupported FORCE_BUMP value fails with an actionable error" {
  run env FORCE_BUMP=banana TAG_PREFIX=v "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "force-bump 'banana' is not supported"
}

@test "missing FORCE_BUMP fails" {
  run "${SCRIPT}"
  [ "$status" -ne 0 ]
}
