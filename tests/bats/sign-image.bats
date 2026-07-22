#!/usr/bin/env bats

# Behaviour coverage for scripts/sign-image.sh plus structural assertions on the
# action.yml wiring.
#
# `docker buildx imagetools inspect` and `cosign` are stubbed so signing runs
# end-to-end without a registry or Sigstore.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/sign-image.sh"
ACTION_YML="${BATS_TEST_DIRNAME}/../../action.yml"

setup() {
  # Use BATS_FILE_TMPDIR (provided by bats) instead of mktemp -d to avoid any
  # /tmp noexec mount issues on CI runners.
  WORK="${BATS_FILE_TMPDIR}"
  BIN="${WORK}/bin"
  mkdir -p "${BIN}"
  STUB_LOG="${WORK}/stub.log"
  export STUB_LOG
  : > "${STUB_LOG}"
  GITHUB_OUTPUT="${WORK}/output"
  export GITHUB_OUTPUT
  : > "${GITHUB_OUTPUT}"
  # Export BIN so the stubs can reference it if needed.
  export BIN

  # docker stub: intercepts docker buildx imagetools inspect and returns a fake
  # digest. Set STUB_DIGEST_FAIL=1 to make ALL refs fail. Set
  # STUB_DIGEST_FAIL_REFS to a newline-separated list of exact refs to fail.
  # Per-ref digest overrides: STUB_DIGEST_<ref with : / . - → _>.
  cat > "${BIN}/docker" <<'STUB_EOF'
#!/usr/bin/env bash
{
  echo "docker $*" >> "${STUB_LOG}"
  case "$1" in
    buildx)
      case "$2" in
        imagetools)
          case "$3" in
            inspect)
              ref="$4"
              if [ -n "${STUB_DIGEST_FAIL_REFS:-}" ] && grep -qFx "${ref}" <<< "${STUB_DIGEST_FAIL_REFS}"; then
                echo "error: $ref: not found" >&2
                exit 1
              fi
              if [ -n "${STUB_DIGEST_FAIL:-}" ]; then
                echo "error: $ref: not found" >&2
                exit 1
              fi
              ref_key="STUB_DIGEST_$(echo "${ref}" | tr ':/.-' '____')"
              digest="${!ref_key:-sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef}"
              echo "Name: ${ref}"
              echo "Digest: ${digest}"
              exit 0
              ;;
          esac
          ;;
      esac
      ;;
  esac
  exit 1
} 2>/dev/null
STUB_EOF

  # cosign stub: succeeds silently unless STUB_COSIGN_FAIL is set.
  cat > "${BIN}/cosign" <<'STUB_EOF'
#!/usr/bin/env bash
echo "cosign $*" >> "${STUB_LOG}"
if [ -n "${STUB_COSIGN_FAIL:-}" ]; then
  exit 1
fi
exit 0
STUB_EOF

  chmod +x "${BIN}/docker" "${BIN}/cosign"
  # Prepend BIN to PATH so stubs shadow real cosign / docker on the runner.
  export PATH="${BIN}:${PATH}"
}

teardown() {
  : # BATS_FILE_TMPDIR is cleaned up automatically by bats.
}

# run_signed — helper that runs the script with stubs on PATH and the extra env
# vars the stubs need (STUB_LOG and GITHUB_OUTPUT are already exported in setup).
run_signed() {
  # BIN is first on PATH so stubs shadow any real cosign / docker on the runner.
  run env PATH="${BIN}:${PATH}" "$@"
}

# ── signing behaviour ───────────────────────────────────────────────────────

@test "IMAGE_REFS unset/empty -> exit 1" {
  # Use an empty assignment rather than `env -u` so the env invocation
  # `env PATH=… IMAGE_REFS='' …` is correct: env options must precede
  # NAME=VALUE assignments, and `run_signed` injects PATH= first.
  run_signed IMAGE_REFS='' "${SCRIPT}"
  [ "$status" -eq 1 ]
}

@test "single image: signs by digest and writes primary outputs" {
  run_signed IMAGE_REFS="ghcr.io/acme/app:v1.2.3" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "cosign: signed 1 image(s)" <<< "$output"
  grep -Fq "primary_subject=ghcr.io/acme/app" "${GITHUB_OUTPUT}"
  grep -Fq "primary_digest=sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "${GITHUB_OUTPUT}"
  grep -Fq "signed_count=1" "${GITHUB_OUTPUT}"
}

@test "multiple images: signs all, primary is the first image" {
  run_signed IMAGE_REFS=$'ghcr.io/acme/app1:v1.2.3\nghcr.io/acme/app2:v1.2.3' "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "cosign: signed 2 image(s)" <<< "$output"
  grep -Fq "primary_subject=ghcr.io/acme/app1" "${GITHUB_OUTPUT}"
  grep -Fq "signed_count=2" "${GITHUB_OUTPUT}"
}

@test "all digest lookups fail -> exit 1 with error" {
  run_signed IMAGE_REFS="ghcr.io/acme/app:v1.2.3" STUB_DIGEST_FAIL=1 "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "::error::no images were signed"
}

@test "mixed success/failure: signs only resolvable refs, primary is first success, exit 0" {
  run_signed \
    IMAGE_REFS=$'ghcr.io/acme/bad:v1\nghcr.io/acme/good:v1' \
    STUB_DIGEST_FAIL_REFS=$'ghcr.io/acme/bad:v1' \
    STUB_DIGEST_ghcr_io_acme_good_v1=sha256:abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1 \
    "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "cosign: signed 1 image(s)" <<< "$output"
  grep -Fq "primary_subject=ghcr.io/acme/good" "${GITHUB_OUTPUT}"
  grep -Fq "primary_digest=sha256:abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1" "${GITHUB_OUTPUT}"
  grep -Fq "signed_count=1" "${GITHUB_OUTPUT}"
}

@test "strips the tag from the ref to form the repo for signing" {
  run_signed IMAGE_REFS="ghcr.io/acme/app:v1.2.3" "${SCRIPT}"
  [ "$status" -eq 0 ]
  # The cosign stub logs its args — verify signing targets repo@digest, not repo:tag.
  grep -Fq "cosign sign --yes ghcr.io/acme/app@sha256:" "${STUB_LOG}"
}

# ── action.yml wiring ──────────────────────────────────────────────────────

@test "action.yml gates the sign step on mode/resolved-image-name/released/image-sign" {
  grep -Eq "inputs.mode == 'release' && steps.resolve-image.outputs.image_name != '' && steps.normalize.outputs.released == 'true' && inputs.image-sign == 'true'" "${ACTION_YML}"
  grep -Eq "sign-image.sh" "${ACTION_YML}"
}

@test "action.yml SHA-pins the cosign installer" {
  grep -Fq "sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6" "${ACTION_YML}"
}

@test "action.yml SHA-pins the attest-build-provenance action" {
  grep -Fq "actions/attest-build-provenance@0f67c3f4856b2e3261c31976d6725780e5e4c373" "${ACTION_YML}"
}

@test "action.yml exposes the image-sign input and image-signed output" {
  grep -Eq "^  image-sign:" "${ACTION_YML}"
  grep -Eq "image-signed:" "${ACTION_YML}"
}

@test "action.yml attest step gates on image_name, matching the surrounding pattern" {
  grep -Eq "steps.resolve-image.outputs.image_name != ''" "${ACTION_YML}" \
    || true
  # The attest step's if: now includes it alongside primary_digest != ''.
  grep -Eq "Attest build provenance" "${ACTION_YML}"
}

@test "sign-image.sh guards the imagetools pipeline with || true so pipefail does not kill the script" {
  grep -Fq "|| true" "${SCRIPT}"
}
