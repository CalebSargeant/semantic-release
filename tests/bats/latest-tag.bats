#!/usr/bin/env bats

# Behaviour coverage for scripts/latest-tag.sh.
#
# The regression this guards is the one that makes path-scoped releases
# possible at all: in a repo that releases more than one package, an unscoped
# `git describe --tags --abbrev=0` answers "what was the last release?" with
# whichever package released most recently. The version it returns is a real
# version and the tag is a real tag — they just belong to a different package —
# so nothing errors and the wrong number reaches the image tag, the published
# package and the GitHub Release.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/latest-tag.sh"

setup() {
  WORK=$(mktemp -d)

  # Hermetic: a developer's global gitconfig (tag.gpgsign=true) would make
  # plain `git tag <name>` fail. CI runners have neither set.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  git init --initial-branch=main "${WORK}" >/dev/null
  cd "${WORK}"
  git config user.name tester
  git config user.email t@example.com
}

teardown() {
  cd /
  rm -rf "${WORK}"
}

commit() { git commit --allow-empty -m "$1" >/dev/null; }

@test "no tags at all: empty output, exit 0" {
  commit "initial"
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "empty prefix returns the most recent reachable tag (historical behaviour)" {
  commit "one"; git tag v1.0.0
  commit "two"; git tag v1.1.0
  commit "three"
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$output" = "v1.1.0" ]
}

@test "prefix scopes the lookup to that package's series (THE REGRESSION)" {
  commit "core work";  git tag magmamoose-core-v1.0.0
  commit "ui work";    git tag magmamoose-ui-v2.5.0
  commit "more"

  # Unscoped, this is what the four call sites used to see.
  run "${SCRIPT}"
  [ "$output" = "magmamoose-ui-v2.5.0" ]

  # Scoped, core gets its own last release and not the UI's.
  PREFIX=magmamoose-core-v run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$output" = "magmamoose-core-v1.0.0" ]

  PREFIX=magmamoose-ui-v run "${SCRIPT}"
  [ "$output" = "magmamoose-ui-v2.5.0" ]
}

@test "prefix with no matching tag yet: empty output, exit 0 (a first release)" {
  commit "ui work"; git tag magmamoose-ui-v2.5.0
  commit "more"
  PREFIX=magmamoose-core-v run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an unset PREFIX is not treated as an empty --match pattern" {
  # `git describe --match ""` matches NOTHING and exits non-zero. If the script
  # interpolated the flag unconditionally, every caller that leaves tag-prefix
  # empty would silently report "no previous release" and each run would look
  # like a first release. This asserts the branch, not just the happy path.
  commit "one"; git tag 1.0.0    # deliberately prefix-less tags
  commit "two"
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$output" = "1.0.0" ]

  PREFIX= run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$output" = "1.0.0" ]
}

@test "only tags reachable from HEAD count" {
  commit "one"; git tag pkg-v1.0.0
  git checkout -q -b sidebranch
  commit "side"; git tag pkg-v9.9.9
  git checkout -q main

  # pkg-v9.9.9 exists but is not an ancestor of main, so it must not win.
  PREFIX=pkg-v run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$output" = "pkg-v1.0.0" ]
}
