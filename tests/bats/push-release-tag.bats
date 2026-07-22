#!/usr/bin/env bats

# Behaviour coverage for scripts/push-release-tag.sh.
#
# Each test sets up a temporary work tree + bare repo as origin. The
# script only accepts https:// or git@ remotes, so we point the clone's
# origin at a fake https URL and use git's `url.<base>.insteadOf` to
# rewrite both the bare URL and the token-prefixed URL (which the script
# synthesises) to the local bare repo path.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/push-release-tag.sh"

setup() {
  WORK=$(mktemp -d)
  BARE="${WORK}/origin.git"
  CLONE="${WORK}/clone"
  export GITHUB_OUTPUT="${WORK}/output"
  : > "${GITHUB_OUTPUT}"

  # Hermetic: ignore the dev's global/system gitconfig (e.g. tag.gpgsign=true
  # would make `git tag <name>` fail with "no tag message?"). CI runners
  # don't have either set, but local developers might.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  git init --bare --initial-branch=main "${BARE}" >/dev/null

  git -C "${WORK}" init --initial-branch=main clone >/dev/null
  git -C "${CLONE}" -c user.name=tester -c user.email=t@example.com \
    commit --allow-empty -m "initial" >/dev/null

  # Origin URL the script will see when it runs `git config --get
  # remote.origin.url`. Rewriting rules below map both this URL and the
  # token-prefixed form the script synthesises to the local bare repo,
  # so the actual push/ls-remote land in our fixture.
  git -C "${CLONE}" remote add origin "https://example.invalid/origin.git"
  git -C "${CLONE}" config --add "url.${BARE}.insteadOf" "https://example.invalid/origin.git"
  git -C "${CLONE}" config --add "url.${BARE}.insteadOf" "https://x-access-token:fake@example.invalid/origin.git"

  export GITHUB_TOKEN=fake
  unset RUNNER_TEMP || true
  unset MESSAGE || true
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL || true
}

teardown() {
  rm -rf "${WORK}"
}

@test "push creates and pushes a lightweight tag, emits released=true" {
  cd "${CLONE}"
  run env TAG=v1.0.0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "released=true" "${GITHUB_OUTPUT}"
  git -C "${BARE}" tag -l | grep -Fq "v1.0.0"
}

@test "push creates an annotated tag when MESSAGE is set" {
  cd "${CLONE}"
  run env TAG=v1.0.1 MESSAGE="chore(release): v1.0.1" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "released=true" "${GITHUB_OUTPUT}"
  obj_type=$(git -C "${BARE}" cat-file -t "v1.0.1")
  [ "${obj_type}" = "tag" ]
}

@test "pre-check: tag already exists on remote → released=false, exit 0" {
  cd "${CLONE}"
  # Pre-populate the bare repo with the tag.
  git -C "${CLONE}" tag v2.0.0
  git -C "${CLONE}" push origin v2.0.0 >/dev/null
  git -C "${CLONE}" tag -d v2.0.0

  run env TAG=v2.0.0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "released=false" "${GITHUB_OUTPUT}"
  ! grep -Fq "released=true" "${GITHUB_OUTPUT}"
}

@test "unsupported remote URL → exit 1" {
  cd "${CLONE}"
  git -C "${CLONE}" remote set-url origin "ssh://weird.example.com/path.git"
  run env TAG=v3.0.0 "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "Unsupported git remote URL format"
}

@test "git identity left alone when caller pre-set it" {
  cd "${CLONE}"
  git -C "${CLONE}" config user.name "Caller Identity"
  git -C "${CLONE}" config user.email "caller@example.com"
  run env TAG=v4.0.0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(git -C "${CLONE}" config --get user.name)" = "Caller Identity" ]
  [ "$(git -C "${CLONE}" config --get user.email)" = "caller@example.com" ]
}

@test "git identity defaults to github-actions[bot] when caller did not set it" {
  cd "${CLONE}"
  git -C "${CLONE}" config --unset user.name 2>/dev/null || true
  git -C "${CLONE}" config --unset user.email 2>/dev/null || true
  run env TAG=v5.0.0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(git -C "${CLONE}" config --get user.name)" = "github-actions[bot]" ]
  [ "$(git -C "${CLONE}" config --get user.email)" = "github-actions[bot]@users.noreply.github.com" ]
}

@test "emits latest_tag on a successful push" {
  cd "${CLONE}"
  run env TAG=v7.1.0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "latest_tag=v7.1.0" "${GITHUB_OUTPUT}"
  grep -Fq "released=true" "${GITHUB_OUTPUT}"
}

@test "emits latest_tag on a no-op (tag already on remote), released=false" {
  cd "${CLONE}"
  git -C "${CLONE}" tag v7.2.0
  git -C "${CLONE}" push origin v7.2.0 >/dev/null
  git -C "${CLONE}" tag -d v7.2.0

  run env TAG=v7.2.0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "latest_tag=v7.2.0" "${GITHUB_OUTPUT}"
  grep -Fq "released=false" "${GITHUB_OUTPUT}"
}

@test "emits release_notes only on a real release when RELEASE_NOTES is set" {
  cd "${CLONE}"
  run env TAG=v7.3.0 RELEASE_NOTES="Pre-release rc.1 for version 7.3.0" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "release_notes=Pre-release rc.1 for version 7.3.0" "${GITHUB_OUTPUT}"
}

@test "does NOT emit release_notes on a no-op even when RELEASE_NOTES is set" {
  cd "${CLONE}"
  git -C "${CLONE}" tag v7.4.0
  git -C "${CLONE}" push origin v7.4.0 >/dev/null
  git -C "${CLONE}" tag -d v7.4.0

  run env TAG=v7.4.0 RELEASE_NOTES="should not appear" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "released=false" "${GITHUB_OUTPUT}"
  ! grep -Fq "release_notes=" "${GITHUB_OUTPUT}"
}

@test "no RELEASE_NOTES set → success still exits 0 (no dangling release_notes)" {
  cd "${CLONE}"
  run env TAG=v7.5.0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  ! grep -Fq "release_notes=" "${GITHUB_OUTPUT}"
}

@test "stderr capture file is cleaned up under RUNNER_TEMP" {
  cd "${CLONE}"
  export RUNNER_TEMP="${WORK}/runner-tmp"
  mkdir -p "${RUNNER_TEMP}"

  run env TAG=v6.0.0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  # The trap should clean the per-invocation temp file on exit.
  leftover=$(find "${RUNNER_TEMP}" -name 'tag_push.err.*' 2>/dev/null | wc -l | tr -d ' ')
  [ "${leftover}" = "0" ]
}
