#!/usr/bin/env bats

# Behaviour coverage for scripts/resolve-image-name.sh plus structural
# assertions on the action.yml wiring.
#
# `docker` is stubbed to emit a `docker buildx bake --print` JSON document
# (STUB_BAKE_JSON), or to fail (STUB_DOCKER_FAIL), so the detection path runs
# end-to-end without Docker or a real bake file. The bake file itself only has
# to *exist* for detection to be attempted — its contents are irrelevant to the
# stub.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/resolve-image-name.sh"
ACTION_YML="${BATS_TEST_DIRNAME}/../../action.yml"

setup() {
  WORK=$(mktemp -d)
  BIN="${WORK}/bin"
  mkdir -p "${BIN}"
  export STUB_LOG="${WORK}/stub.log"
  : > "${STUB_LOG}"
  export GITHUB_OUTPUT="${WORK}/output"
  : > "${GITHUB_OUTPUT}"

  # A bake file that merely has to exist; the docker stub ignores its content.
  export BAKE_FILE="${WORK}/docker-bake.hcl"
  : > "${BAKE_FILE}"

  # docker stub: log argv; honour STUB_DOCKER_FAIL; otherwise print the bake
  # --print JSON from STUB_BAKE_JSON (default: an empty target set).
  cat > "${BIN}/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "${STUB_LOG}"
if [ -n "${STUB_DOCKER_FAIL:-}" ]; then
  echo "ERROR: failed to solve: bake definition invalid" >&2
  exit 1
fi
printf '%s' "${STUB_BAKE_JSON:-{\"target\":{}}}"
EOF
  chmod +x "${BIN}/docker"
  export PATH="${BIN}:${PATH}"
}

teardown() {
  rm -rf "${WORK}"
}

# ── precedence: explicit input wins ─────────────────────────────────────────

@test "explicit image_name wins verbatim and does not touch docker" {
  run env INPUT_IMAGE_NAME="my-app" INPUT_BAKE_FILE="${BAKE_FILE}" \
    STUB_BAKE_JSON='{"target":{"app":{"tags":["ghcr.io/acme/other:latest"]}}}' "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "image_name=my-app" "${GITHUB_OUTPUT}"
  # No detection attempted when an explicit value is present.
  [ ! -s "${STUB_LOG}" ]
}

@test "explicit image_name works even with no bake file present" {
  run env INPUT_IMAGE_NAME="my-app" INPUT_BAKE_FILE="${WORK}/nope.hcl" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "image_name=my-app" "${GITHUB_OUTPUT}"
  [ ! -s "${STUB_LOG}" ]
}

# ── opt-out: detect-image-name=false ────────────────────────────────────────

@test "detect-image-name=false skips detection even with a tagged bake file" {
  run env INPUT_BAKE_FILE="${BAKE_FILE}" DETECT_IMAGE_NAME="false" \
    STUB_BAKE_JSON='{"target":{"app":{"tags":["ghcr.io/acme/app:latest"]}}}' "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fxq "image_name=" "${GITHUB_OUTPUT}"   # empty → image steps skip
  [ ! -s "${STUB_LOG}" ]                        # no bake --print attempted
}

@test "explicit image_name still wins when detect-image-name=false" {
  run env INPUT_IMAGE_NAME="my-app" INPUT_BAKE_FILE="${BAKE_FILE}" DETECT_IMAGE_NAME="false" \
    STUB_BAKE_JSON='{"target":{"app":{"tags":["ghcr.io/acme/app:latest"]}}}' "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "image_name=my-app" "${GITHUB_OUTPUT}"
  [ ! -s "${STUB_LOG}" ]
}

# ── detection from Docker Bake ──────────────────────────────────────────────

@test "detects base name from a GHCR tag with an org prefix" {
  run env INPUT_BAKE_FILE="${BAKE_FILE}" \
    STUB_BAKE_JSON='{"target":{"app":{"tags":["ghcr.io/platform1-systems/backend:latest"]}}}' "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "image_name=backend" "${GITHUB_OUTPUT}"
}

@test "detects base name preserving hyphens (camera-probe-propagator)" {
  run env INPUT_BAKE_FILE="${BAKE_FILE}" \
    STUB_BAKE_JSON='{"target":{"app":{"tags":["ghcr.io/platform1-systems/camera-probe-propagator:v1"]}}}' "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "image_name=camera-probe-propagator" "${GITHUB_OUTPUT}"
}

@test "detects base name from owner/image format (no registry host)" {
  run env INPUT_BAKE_FILE="${BAKE_FILE}" \
    STUB_BAKE_JSON='{"target":{"app":{"tags":["platform1-systems/admin-frontend:latest"]}}}' "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "image_name=admin-frontend" "${GITHUB_OUTPUT}"
}

@test "picks the first NON-EMPTY tag across targets" {
  run env INPUT_BAKE_FILE="${BAKE_FILE}" \
    STUB_BAKE_JSON='{"target":{"a":{"tags":[]},"b":{"tags":["ghcr.io/acme/svc:latest"]}}}' "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "image_name=svc" "${GITHUB_OUTPUT}"
}

@test "strips a digest from a tagless-but-digested ref" {
  run env INPUT_BAKE_FILE="${BAKE_FILE}" \
    STUB_BAKE_JSON='{"target":{"app":{"tags":["ghcr.io/acme/app@sha256:deadbeef"]}}}' "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "image_name=app" "${GITHUB_OUTPUT}"
}

@test "strips a registry host:port and a nested path down to the leaf" {
  run env INPUT_BAKE_FILE="${BAKE_FILE}" \
    STUB_BAKE_JSON='{"target":{"app":{"tags":["localhost:5000/acme/team/app:pr-2"]}}}' "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "image_name=app" "${GITHUB_OUTPUT}"
}

@test "passes the configured bake file and target to docker" {
  run env INPUT_BAKE_FILE="${BAKE_FILE}" INPUT_BAKE_TARGET="release" \
    STUB_BAKE_JSON='{"target":{"app":{"tags":["ghcr.io/acme/app:latest"]}}}' "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Eq "docker buildx bake -f ${BAKE_FILE} release --print" "${STUB_LOG}"
}

# ── skip / failure behaviour ────────────────────────────────────────────────

@test "no image_name and no bake file -> empty, exit 0, no docker" {
  run env INPUT_IMAGE_NAME="" INPUT_BAKE_FILE="${WORK}/nope.hcl" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "image_name=" "${GITHUB_OUTPUT}"
  [ ! -s "${STUB_LOG}" ]
}

@test "bake file present but no tags -> hard error, exit 1" {
  run env INPUT_BAKE_FILE="${BAKE_FILE}" \
    STUB_BAKE_JSON='{"target":{"app":{"tags":[]}}}' "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "produced no image tags"
  # Never falls back to the repository name.
  ! grep -q "^image_name=" "${GITHUB_OUTPUT}"
}

@test "bake file present, targets but no tags key at all -> hard error, exit 1" {
  run env INPUT_BAKE_FILE="${BAKE_FILE}" \
    STUB_BAKE_JSON='{"target":{"app":{}}}' "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "produced no image tags"
}

@test "bake evaluation failure -> hard error, exit 1" {
  run env INPUT_BAKE_FILE="${BAKE_FILE}" STUB_DOCKER_FAIL=1 "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "Could not evaluate Docker Bake file"
}

# ── action.yml wiring ───────────────────────────────────────────────────────

@test "action.yml runs the resolver early for ci and release" {
  grep -Eq "id: resolve-image" "${ACTION_YML}"
  grep -Eq "resolve-image-name.sh" "${ACTION_YML}"
  grep -Eq "if: inputs.mode == 'ci' \|\| inputs.mode == 'release'" "${ACTION_YML}"
}

@test "action.yml resolver reads the raw image_name input" {
  grep -Eq "INPUT_IMAGE_NAME: \\\$\{\{ inputs.image_name \}\}" "${ACTION_YML}"
}

@test "action.yml gates image steps on the resolved name, not the raw input" {
  # The raw input is only read by the resolver step itself; every gate uses the
  # resolved output.
  grep -Eq "inputs.mode == 'ci' && steps.resolve-image.outputs.image_name != ''" "${ACTION_YML}"
  grep -Eq "inputs.mode == 'release' && steps.resolve-image.outputs.image_name != '' && steps.normalize.outputs.released == 'true'" "${ACTION_YML}"
  ! grep -q "inputs.image_name != ''" "${ACTION_YML}"
}

@test "action.yml exposes the resolved-image-name output" {
  grep -Eq "^  resolved-image-name:" "${ACTION_YML}"
}

@test "action.yml exposes detect-image-name and wires it into the resolver" {
  grep -Eq "^  detect-image-name:" "${ACTION_YML}"
  grep -Eq "DETECT_IMAGE_NAME: \\\$\{\{ inputs.detect-image-name \}\}" "${ACTION_YML}"
}
