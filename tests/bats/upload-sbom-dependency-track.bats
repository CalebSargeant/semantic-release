#!/usr/bin/env bats

# Behaviour coverage for scripts/upload-sbom-dependency-track.sh.
#
# curl is replaced with a PATH stub that logs its argv (and the --data payload
# file) to ${STUB_LOG} and returns a configurable HTTP code, so we can assert
# the endpoint, auth header, and project envelope without a Dependency-Track
# server.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/upload-sbom-dependency-track.sh"

setup() {
  WORK=$(mktemp -d)
  BIN="${WORK}/bin"
  mkdir -p "${BIN}"
  export STUB_LOG="${WORK}/stub.log"
  : > "${STUB_LOG}"

  # curl stub: log argv; spill the --data @file payload into the log; write the
  # response body to -o; print the (stubbed) HTTP code on stdout like real curl
  # with -w '%{http_code}'.
  cat > "${BIN}/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "${STUB_LOG}"
out=""; data=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2; continue;;
    --data|-d) data="$2"; shift 2; continue;;
    --config|-K) cfg="$2"; shift 2; continue;;
    *) shift;;
  esac
done
if [ -n "${out}" ]; then echo "${STUB_BODY:-ok}" > "${out}"; fi
if [ -n "${cfg}" ] && [ -f "${cfg}" ]; then
  sed 's/^/cfg: /' "${cfg}" >> "${STUB_LOG}"
fi
if [ "${data#@}" != "${data}" ] && [ -f "${data#@}" ]; then
  sed 's/^/payload: /' "${data#@}" >> "${STUB_LOG}"
fi
printf '%s' "${STUB_HTTP:-201}"
EOF
  chmod +x "${BIN}/curl"
  export PATH="${BIN}:${PATH}"

  BOM="${WORK}/bom.cdx.json"
  echo '{"bomFormat":"CycloneDX","specVersion":"1.5","components":[]}' > "${BOM}"
}

teardown() {
  rm -rf "${WORK}"
}

@test "no DEPENDENCY_TRACK_URL -> skips silently, exit 0, no curl" {
  run env BOM_FILE="${BOM}" PROJECT_NAME=acme/app PROJECT_VERSION=pr-1 "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "skipping SBOM upload"
  [ ! -s "${STUB_LOG}" ]
}

@test "PUTs the BOM to /api/v1/bom with the API key and project envelope" {
  run env DEPENDENCY_TRACK_URL=https://dt.example.com/ \
    DEPENDENCY_TRACK_API_KEY=dt-key \
    BOM_FILE="${BOM}" PROJECT_NAME=acme/app PROJECT_VERSION=pr-7 "${SCRIPT}"
  [ "$status" -eq 0 ]
  # Endpoint + method, trailing slash trimmed.
  grep -Eq 'curl .*-X PUT https://dt.example.com/api/v1/bom' "${STUB_LOG}"
  grep -Fq 'X-Api-Key: dt-key' "${STUB_LOG}"
  # Envelope carries name/version/autoCreate and a base64 bom.
  grep -Fq '"projectName":"acme/app"' "${STUB_LOG}"
  grep -Fq '"projectVersion":"pr-7"' "${STUB_LOG}"
  grep -Fq '"autoCreate":true' "${STUB_LOG}"
  grep -Eq '"bom":"[A-Za-z0-9+/=]+"' "${STUB_LOG}"
}

@test "missing BOM file is non-blocking (warn, exit 0)" {
  run env DEPENDENCY_TRACK_URL=https://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key \
    BOM_FILE="${WORK}/nope.json" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "missing or empty"
}

@test "missing BOM file under STRICT fails the gate (exit 1)" {
  run env STRICT=true DEPENDENCY_TRACK_URL=https://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key \
    BOM_FILE="${WORK}/nope.json" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "::error::Dependency-Track"
}

@test "a 500 from the server is non-blocking by default (warn, exit 0)" {
  run env STUB_HTTP=500 DEPENDENCY_TRACK_URL=https://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key \
    BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "HTTP 500"
  echo "$output" | grep -Fq "non-blocking"
}

@test "a 500 under STRICT fails the gate (exit 1)" {
  run env STUB_HTTP=500 STRICT=true DEPENDENCY_TRACK_URL=https://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key \
    BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 1 ]
}

@test "URL set but API key missing -> exit 1 (misconfig)" {
  run env DEPENDENCY_TRACK_URL=https://dt.example.com \
    BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 1 ]
}

@test "the API key is passed off curl argv via a --config file" {
  run env DEPENDENCY_TRACK_URL=https://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 0 ]
  # Key arrives via the config file, never on the curl command line.
  grep -Fq 'cfg: header = "X-Api-Key: dt-key"' "${STUB_LOG}"
  ! grep -Eq 'curl .*X-Api-Key' "${STUB_LOG}"
}

@test "a non-boolean AUTO_CREATE is an actionable error, not a generic payload failure" {
  run env DEPENDENCY_TRACK_URL=https://dt.example.com STRICT=true \
    DEPENDENCY_TRACK_API_KEY=dt-key AUTO_CREATE=yes \
    BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "AUTO_CREATE must be 'true' or 'false'"
}

@test "a non-https URL warns about cleartext (still uploads)" {
  run env DEPENDENCY_TRACK_URL=http://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "not https"
  grep -Eq 'curl .*-X PUT http://dt.example.com/api/v1/bom' "${STUB_LOG}"
}
