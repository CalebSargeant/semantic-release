#!/usr/bin/env bats

# Behaviour coverage for the force-bump handling of the `Run semantic-release
# (npm)` composite step. The step lives inline in action.yml, so each test
# extracts its `run:` block with ruby (YAML.load_file works on macOS system
# ruby 2.6 as well as CI's 3.x) and executes it inside a throwaway clone +
# bare-origin fixture, with the npm toolchain stubbed out:
#
#   - `${GITHUB_ACTION_PATH}` points at a fixture dir whose scripts/ carries
#     the real force-bump-version.sh + push-release-tag.sh but a stub
#     semantic-release-deps.sh (no node, no network).
#   - `npm` is a PATH stub; `node_modules/.bin/semantic-release` is a stub
#     that records its invocation, so tests can assert semantic-release is
#     bypassed when force-bump is set and still runs when it is not.
#
# The block's inline tag pushes resolve `git remote get-url origin`, which
# applies the clone's `url.<bare>.insteadOf` rewrites, so pushes land in the
# local bare repo. push-release-tag.sh reads the raw remote.origin.url
# instead, then synthesises a token-prefixed URL — the second insteadOf rule
# maps that form to the bare repo too.

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
  command -v ruby >/dev/null 2>&1 || skip "ruby not available"

  WORK=$(mktemp -d)
  BARE="${WORK}/origin.git"
  CLONE="${WORK}/clone"
  export GITHUB_OUTPUT="${WORK}/output"
  : > "${GITHUB_OUTPUT}"

  # Hermetic: ignore the dev's global/system gitconfig (tag.gpgsign etc.).
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  unset GITHUB_HEAD_REF || true

  # Extract the step's run block from action.yml.
  BLOCK="${WORK}/semrel-npm-block.sh"
  ACTION_YML="${REPO_ROOT}/action.yml" BLOCK="${BLOCK}" ruby -e '
    require "yaml"
    doc = YAML.load_file(ENV.fetch("ACTION_YML"))
    step = doc.fetch("runs").fetch("steps")
      .find { |s| s["name"] == "Run semantic-release (npm)" }
    abort "step Run semantic-release (npm) not found" unless step
    File.write(ENV.fetch("BLOCK"), step.fetch("run"))
  '

  # Fixture action path: real helpers, stubbed dependency resolution.
  ACTION_PATH="${WORK}/action-path"
  mkdir -p "${ACTION_PATH}/scripts"
  cp "${REPO_ROOT}/scripts/force-bump-version.sh" \
     "${REPO_ROOT}/scripts/push-release-tag.sh" \
     "${REPO_ROOT}/scripts/latest-tag.sh" \
     "${ACTION_PATH}/scripts/"
  printf '#!/usr/bin/env bash\necho "semantic-release"\n' \
    > "${ACTION_PATH}/scripts/semantic-release-deps.sh"
  chmod +x "${ACTION_PATH}/scripts/"*.sh

  # PATH stub so `npm install` is a no-op.
  STUBS="${WORK}/stubs"
  mkdir -p "${STUBS}"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS}/npm"
  chmod +x "${STUBS}/npm"
  export PATH="${STUBS}:${PATH}"

  git init --bare --initial-branch=main "${BARE}" >/dev/null

  git -C "${WORK}" init --initial-branch=main clone >/dev/null
  git -C "${CLONE}" config user.name tester
  git -C "${CLONE}" config user.email t@example.com

  # History: a released commit carrying the stable + rc tags, then a
  # non-qualifying commit on top (the "promotion merge noise" shape that
  # motivates force-bump).
  git -C "${CLONE}" commit --allow-empty -m "feat: first" >/dev/null
  git -C "${CLONE}" tag v1.0.1
  git -C "${CLONE}" tag v1.0.1-rc.1
  git -C "${CLONE}" commit --allow-empty -m "chore: merge noise" >/dev/null

  git -C "${CLONE}" remote add origin "https://example.invalid/origin.git"
  git -C "${CLONE}" config --add "url.${BARE}.insteadOf" "https://example.invalid/origin.git"
  git -C "${CLONE}" config --add "url.${BARE}.insteadOf" "https://x-access-token:fake@example.invalid/origin.git"

  # Stub semantic-release binary where the block expects it; records
  # every invocation (dry-run or real) so tests can assert bypass.
  mkdir -p "${CLONE}/node_modules/.bin"
  printf '#!/usr/bin/env bash\ntouch "%s/semrel-invoked"\nexit 0\n' "${WORK}" \
    > "${CLONE}/node_modules/.bin/semantic-release"
  chmod +x "${CLONE}/node_modules/.bin/semantic-release"
}

teardown() {
  rm -rf "${WORK}"
}

# run_block <is_prerelease> <force_bump>
run_block() {
  cd "${CLONE}"
  DETECT_IS_PRERELEASE="$1" \
  INPUT_FORCE_BUMP="$2" \
  DETECT_IDENTIFIER=rc \
  INPUT_TAG_PREFIX=v \
  INPUT_PROMOTE_PREFIX=promote \
  GITHUB_TOKEN=fake \
  GITHUB_ACTION_PATH="${ACTION_PATH}" \
  bash "${BLOCK}"
}

@test "prerelease + force-bump=patch cuts the next rc despite no qualifying commits" {
  run run_block true patch
  [ "$status" -eq 0 ]
  # The no-qualifying-commits pre-check must be bypassed, not tripped.
  # (if/false instead of `! pipeline`: negated pipelines are exempt from
  # errexit, so a bare `!` mid-test would never fail the test.)
  if echo "$output" | grep -Fq "No qualifying commits"; then
    echo "pre-check was not bypassed: $output"
    false
  fi
  git -C "${BARE}" tag -l | grep -Fxq "v1.0.2-rc.1"
  grep -Fxq "latest_tag=v1.0.2-rc.1" "${GITHUB_OUTPUT}"
  grep -Fxq "released=true" "${GITHUB_OUTPUT}"
  grep -Fxq "release_notes=Pre-release rc.1 for version 1.0.2" "${GITHUB_OUTPUT}"
  # semantic-release (incl. its dry-run) must not have been consulted.
  [ ! -f "${WORK}/semrel-invoked" ]
}

@test "prerelease + force-bump=minor bumps the minor line" {
  run run_block true minor
  [ "$status" -eq 0 ]
  git -C "${BARE}" tag -l | grep -Fxq "v1.1.0-rc.1"
  grep -Fxq "released=true" "${GITHUB_OUTPUT}"
}

@test "prerelease + force-bump continues an existing prerelease line" {
  git -C "${CLONE}" tag v1.0.2-rc.2
  run run_block true patch
  [ "$status" -eq 0 ]
  git -C "${BARE}" tag -l | grep -Fxq "v1.0.2-rc.3"
  grep -Fxq "latest_tag=v1.0.2-rc.3" "${GITHUB_OUTPUT}"
}

@test "prerelease without force-bump still skips on no qualifying commits (regression)" {
  run run_block true ""
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "No qualifying commits since v1.0.1-rc.1"
  grep -Fxq "latest_tag=v1.0.1-rc.1" "${GITHUB_OUTPUT}"
  grep -Fxq "released=false" "${GITHUB_OUTPUT}"
  [ -z "$(git -C "${BARE}" tag -l)" ]
}

@test "stable + force-bump=patch tags directly, bypassing semantic-release" {
  run run_block false patch
  [ "$status" -eq 0 ]
  git -C "${BARE}" tag -l | grep -Fxq "v1.0.2"
  # Annotated tag via the shared race-safe push helper.
  [ "$(git -C "${BARE}" cat-file -t v1.0.2)" = "tag" ]
  grep -Fxq "latest_tag=v1.0.2" "${GITHUB_OUTPUT}"
  grep -Fxq "released=true" "${GITHUB_OUTPUT}"
  [ ! -f "${WORK}/semrel-invoked" ]
}

@test "stable + force-bump when the tag already exists on origin is a no-op release" {
  # A parallel run already cut v1.0.2 on the remote (clone doesn't know).
  git -C "${CLONE}" tag v1.0.2
  git -C "${CLONE}" push origin v1.0.2 >/dev/null 2>&1
  git -C "${CLONE}" tag -d v1.0.2 >/dev/null

  run run_block false patch
  [ "$status" -eq 0 ]
  grep -Fxq "latest_tag=v1.0.2" "${GITHUB_OUTPUT}"
  grep -Fxq "released=false" "${GITHUB_OUTPUT}"
  if grep -Fxq "released=true" "${GITHUB_OUTPUT}"; then
    echo "race no-op must not report released=true"
    false
  fi
}

@test "stable without force-bump still runs semantic-release (regression)" {
  run run_block false ""
  [ "$status" -eq 0 ]
  [ -f "${WORK}/semrel-invoked" ]
  # The stub creates no tag, so the step reports no release.
  grep -Fxq "released=false" "${GITHUB_OUTPUT}"
}

@test "prerelease + invalid force-bump value fails the step" {
  run run_block true banana
  [ "$status" -ne 0 ]
  [ -z "$(git -C "${BARE}" tag -l)" ]
}
