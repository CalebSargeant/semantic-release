#!/usr/bin/env bats

setup() {
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github-output"
  : > "${GITHUB_OUTPUT}"
}

@test "auto prefers private app token when present" {
  run env AUTH_MODE=auto PRIVATE_APP_TOKEN=app DEFAULT_GITHUB_TOKEN=gh bash scripts/resolve-auth-token.sh

  [ "$status" -eq 0 ]
  grep -q "token=app" "${GITHUB_OUTPUT}"
  grep -q "source=private-app" "${GITHUB_OUTPUT}"
  grep -q "registry-token=gh" "${GITHUB_OUTPUT}"
}

@test "public app requires broker token" {
  run env AUTH_MODE=public-app DEFAULT_GITHUB_TOKEN=gh bash scripts/resolve-auth-token.sh

  [ "$status" -eq 1 ]
  [[ "$output" == *"auth-mode public-app requires"* ]]
}

@test "public app falls back to workflow token for ci mode" {
  run env ACTION_MODE=ci AUTH_MODE=public-app DEFAULT_GITHUB_TOKEN=gh bash scripts/resolve-auth-token.sh

  [ "$status" -eq 0 ]
  grep -q "token=gh" "${GITHUB_OUTPUT}"
  grep -q "source=github-token" "${GITHUB_OUTPUT}"
}

@test "github-token mode uses default workflow token" {
  run env AUTH_MODE=github-token DEFAULT_GITHUB_TOKEN=gh bash scripts/resolve-auth-token.sh

  [ "$status" -eq 0 ]
  grep -q "token=gh" "${GITHUB_OUTPUT}"
  grep -q "source=github-token" "${GITHUB_OUTPUT}"
}

@test "public app falls back to workflow token for enable-auto-merge mode" {
  run env ACTION_MODE=enable-auto-merge AUTH_MODE=public-app DEFAULT_GITHUB_TOKEN=gh bash scripts/resolve-auth-token.sh

  [ "$status" -eq 0 ]
  grep -q "token=gh" "${GITHUB_OUTPUT}"
  grep -q "source=github-token" "${GITHUB_OUTPUT}"
}
