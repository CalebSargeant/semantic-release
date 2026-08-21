#!/usr/bin/env bats

# Behaviour coverage for scripts/probe-image-tag.sh — the registry probe that
# lets `mode: release` skip promoting a tag that is already published.
#
# `docker` is stubbed to log its argv and then either print a digest
# (STUB_MANIFEST) or fail with a registry error (STUB_DOCKER_ERR, exiting
# STUB_DOCKER_STATUS). The asymmetry is the whole point of the suite: exit 0
# means "resolved to this exact manifest", and *every* other outcome — absent,
# broken, unauthenticated, unset input, a reply that is not a digest — must be
# exit 1 so the caller still does the work.
#
# The probe reports a DIGEST rather than a yes/no because a tag is a mutable
# pointer that anyone with registry write access can create; only the digest
# tells the caller whether what is published is what it was about to publish.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/probe-image-tag.sh"

DIGEST='sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

setup() {
  WORK=$(mktemp -d)
  BIN="${WORK}/bin"
  mkdir -p "${BIN}"
  export STUB_LOG="${WORK}/stub.log"
  : > "${STUB_LOG}"

  cat > "${BIN}/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "${STUB_LOG}"
if [ -n "${STUB_DOCKER_ERR:-}" ]; then
  printf '%s\n' "${STUB_DOCKER_ERR}" >&2
  exit "${STUB_DOCKER_STATUS:-1}"
fi
printf '%s' "${STUB_MANIFEST:-}"
EOF
  chmod +x "${BIN}/docker"
  export PATH="${BIN}:${PATH}"
}

teardown() {
  rm -rf "${WORK}"
}

# ── present: the only outcome allowed to skip work ──────────────────────────

@test "a digest that comes back means present (exit 0)" {
  run env IMAGE_REF="ghcr.io/acme/app:v1.2.3" STUB_MANIFEST="${DIGEST}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolves to ${DIGEST}"* ]]
  [[ "$output" != *"::warning::"* ]]
}

@test "probes the manifest only — never pulls the image" {
  run env IMAGE_REF="ghcr.io/acme/app:v1.2.3" STUB_MANIFEST="${DIGEST}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "docker buildx imagetools inspect ghcr.io/acme/app:v1.2.3 --format {{.Manifest.Digest}}" "${STUB_LOG}"
  ! grep -q "docker pull" "${STUB_LOG}"
}

@test "the resolved digest is written to DIGEST_FILE" {
  # The caller compares this against the digest of the source it was about to
  # retag; without it the gate would be back to trusting a tag's mere existence.
  run env IMAGE_REF="ghcr.io/acme/app:v1.2.3" STUB_MANIFEST="${DIGEST}" \
      DIGEST_FILE="${WORK}/digest" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(cat "${WORK}/digest")" = "${DIGEST}" ]
}

@test "surrounding whitespace in the registry's reply is stripped" {
  run env IMAGE_REF="ghcr.io/acme/app:v1.2.3" STUB_MANIFEST="  ${DIGEST}"$'\n' \
      DIGEST_FILE="${WORK}/digest" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(cat "${WORK}/digest")" = "${DIGEST}" ]
}

@test "a zero exit that is not a digest is indeterminate, not present" {
  # An older buildx that does not know the format verb lands here. Reading its
  # reply as "present" would skip a promote on the strength of a shrug.
  run env IMAGE_REF="ghcr.io/acme/app:v1.2.3" STUB_MANIFEST="unknown flag: --format" \
      DIGEST_FILE="${WORK}/digest" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::warning::"* ]]
  [ ! -f "${WORK}/digest" ]
}

@test "DIGEST_FILE is not written when the tag is absent" {
  run env IMAGE_REF="ghcr.io/acme/app:v1.2.3" \
      STUB_DOCKER_ERR="ghcr.io/acme/app:v1.2.3: not found" STUB_DOCKER_STATUS=1 \
      DIGEST_FILE="${WORK}/digest" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [ ! -f "${WORK}/digest" ]
}

# ── absent: expected on every first release, so no annotation ───────────────

@test "a not-found error means absent (exit 1) and stays quiet" {
  run env IMAGE_REF="ghcr.io/acme/app:v1.2.3" \
    STUB_DOCKER_ERR="ERROR: ghcr.io/acme/app:v1.2.3: not found" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not in the registry"* ]]
  [[ "$output" != *"::warning::"* ]]
}

@test "a manifest-unknown error is also just absent" {
  # Registries word absence differently; the distributed OCI wording must not
  # be mistaken for a fault and warned about on every first release.
  run env IMAGE_REF="ghcr.io/acme/app:v1.2.3" \
    STUB_DOCKER_ERR='failed to resolve reference: unexpected status: MANIFEST_UNKNOWN' "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" != *"::warning::"* ]]
}

# ── faults: still exit 1, but loudly ───────────────────────────────────────

@test "an authentication failure warns and does not skip (exit 1)" {
  run env IMAGE_REF="ghcr.io/acme/app:v1.2.3" \
    STUB_DOCKER_ERR="ERROR: unauthorized: authentication required" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"ghcr.io/acme/app:v1.2.3"* ]]
  [[ "$output" == *"unauthorized"* ]]
}

@test "a registry outage warns and does not skip (exit 1)" {
  run env IMAGE_REF="ghcr.io/acme/app:v1.2.3" \
    STUB_DOCKER_ERR="ERROR: unexpected status from HEAD request: 503 Service Unavailable" \
    STUB_DOCKER_STATUS=125 "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::warning::"* ]]
}

@test "docker's own exit status never leaks — the caller only ever sees 0 or 1" {
  run env IMAGE_REF="ghcr.io/acme/app:v1.2.3" \
    STUB_DOCKER_ERR="ERROR: something novel" STUB_DOCKER_STATUS=127 "${SCRIPT}"
  [ "$status" -eq 1 ]
}

@test "a multi-line registry error collapses into a single annotation" {
  # `::warning::` renders only its first line as an annotation, and registry
  # clients are fond of wrapping their errors.
  run env IMAGE_REF="ghcr.io/acme/app:v1.2.3" \
    STUB_DOCKER_ERR=$'ERROR: failed to authorize\ncaused by: token refresh failed' "${SCRIPT}"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"failed to authorize"* ]]
  [[ "${lines[0]}" == *"token refresh failed"* ]]
}

@test "a successful but empty inspect is not proof of presence (exit 1)" {
  run env IMAGE_REF="ghcr.io/acme/app:v1.2.3" STUB_MANIFEST="" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::warning::"* ]]
}

# ── misconfiguration: never a hard failure, never a skip ────────────────────

@test "a missing IMAGE_REF warns, exits 1, and never reaches the registry" {
  run env -u IMAGE_REF "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"IMAGE_REF is required"* ]]
  [ ! -s "${STUB_LOG}" ]
}

@test "an empty IMAGE_REF is treated the same as an unset one" {
  run env IMAGE_REF="" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [ ! -s "${STUB_LOG}" ]
}
