#!/usr/bin/env bats

# Behaviour coverage for scripts/build-image-dockerfile.sh — the no-bake
# `docker buildx build` fallback. `docker` is stubbed to log its argv (one arg
# per line to ARGV_LOG) so we can assert the exact flags without a real builder.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/build-image-dockerfile.sh"

setup() {
  WORK=$(mktemp -d)
  BIN="${WORK}/bin"
  mkdir -p "${BIN}"
  export ARGV_LOG="${WORK}/argv"
  : > "${ARGV_LOG}"

  cat > "${BIN}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${ARGV_LOG}"
EOF
  chmod +x "${BIN}/docker"
  export PATH="${BIN}:${PATH}"
}

teardown() {
  rm -rf "${WORK}"
}

# Assert a flag is immediately followed by an expected value in the argv log.
flag_value_is() {
  local flag="$1" want="$2"
  awk -v flag="${flag}" -v want="${want}" '
    prev == flag && $0 == want { found = 1 }
    { prev = $0 }
    END { exit found ? 0 : 1 }
  ' "${ARGV_LOG}"
}

count_flag() {
  # `--` stops grep option parsing so flag names like "--push" aren't read as options.
  grep -cxF -- "$1" "${ARGV_LOG}" || true
}

@test "requires TAGS" {
  run env DOCKERFILE="Dockerfile" "${SCRIPT}"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "TAGS"
}

@test "empty TAGS (only blank lines) errors before invoking docker" {
  run env TAGS=$'\n \n' "${SCRIPT}"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "no non-empty image refs"
  [ ! -s "${ARGV_LOG}" ]
}

@test "CI-style build: platform, single tag, both provenance labels, cache, secret, push, context" {
  run env \
    TAGS="ghcr.io/acme/app:pr-12" \
    DOCKERFILE="Dockerfile" \
    PLATFORMS="linux/amd64,linux/arm64" \
    CACHE_SCOPE="bk-dockerfile-feat-x" \
    LABELS=$'org.opencontainers.image.revision=abc\ncom.magmamoose.diatreme.git-tree=def' \
    BUILD_GITHUB_TOKEN="tok" \
    "${SCRIPT}"
  [ "$status" -eq 0 ]
  # buildx build with the configured Dockerfile.
  grep -qxF -- "buildx" "${ARGV_LOG}"
  grep -qxF -- "build" "${ARGV_LOG}"
  flag_value_is "-f" "Dockerfile"
  # Multi-arch platforms are forwarded verbatim.
  flag_value_is "--platform" "linux/amd64,linux/arm64"
  # The computed pr-<N> tag.
  flag_value_is "--tag" "ghcr.io/acme/app:pr-12"
  # Both provenance labels that release-mode promotion verifies.
  flag_value_is "--label" "org.opencontainers.image.revision=abc"
  flag_value_is "--label" "com.magmamoose.diatreme.git-tree=def"
  # GHA cache in both directions at the given scope.
  flag_value_is "--cache-from" "type=gha,scope=bk-dockerfile-feat-x"
  flag_value_is "--cache-to" "type=gha,mode=max,scope=bk-dockerfile-feat-x"
  # github_token build secret read from the environment.
  flag_value_is "--secret" "id=github_token,env=BUILD_GITHUB_TOKEN"
  # Pushed, with '.' as the last (context) argument.
  grep -qxF -- "--push" "${ARGV_LOG}"
  [ "$(tail -n1 "${ARGV_LOG}")" = "." ]
}

@test "release-style build: two tags (version + latest), no platforms, no labels" {
  run env \
    TAGS=$'ghcr.io/acme/app:1.2.3\nghcr.io/acme/app:latest' \
    DOCKERFILE="Dockerfile" \
    PLATFORMS="" \
    CACHE_SCOPE="buildkit-dockerfile" \
    "${SCRIPT}"
  [ "$status" -eq 0 ]
  flag_value_is "--tag" "ghcr.io/acme/app:1.2.3"
  flag_value_is "--tag" "ghcr.io/acme/app:latest"
  [ "$(count_flag "--tag")" -eq 2 ]
  # Empty PLATFORMS ⇒ no --platform at all (builder default, single-arch).
  [ "$(count_flag "--platform")" -eq 0 ]
  [ "$(count_flag "--label")" -eq 0 ]
}

@test "leading whitespace on tag/label lines (YAML block scalar) is trimmed" {
  run env \
    TAGS=$'ghcr.io/acme/app:1.2.3\n        ghcr.io/acme/app:latest' \
    DOCKERFILE="Dockerfile" \
    LABELS=$'        org.opencontainers.image.revision=abc' \
    "${SCRIPT}"
  [ "$status" -eq 0 ]
  flag_value_is "--tag" "ghcr.io/acme/app:latest"
  flag_value_is "--label" "org.opencontainers.image.revision=abc"
}

@test "no BUILD_GITHUB_TOKEN ⇒ no --secret flag" {
  run env TAGS="ghcr.io/acme/app:pr-1" DOCKERFILE="Dockerfile" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(count_flag "--secret")" -eq 0 ]
}

@test "PUSH=false builds without --push" {
  run env TAGS="ghcr.io/acme/app:pr-1" DOCKERFILE="Dockerfile" PUSH="false" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(count_flag "--push")" -eq 0 ]
}

@test "custom DOCKERFILE and CONTEXT are honoured" {
  run env TAGS="ghcr.io/acme/app:pr-1" DOCKERFILE="build/app.Dockerfile" CONTEXT="./svc" "${SCRIPT}"
  [ "$status" -eq 0 ]
  flag_value_is "-f" "build/app.Dockerfile"
  [ "$(tail -n1 "${ARGV_LOG}")" = "./svc" ]
}
