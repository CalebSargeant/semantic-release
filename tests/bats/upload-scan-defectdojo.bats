#!/usr/bin/env bats

# Behaviour coverage for scripts/upload-scan-defectdojo.sh.
#
# curl is replaced with a PATH stub that logs its argv and returns a
# configurable HTTP code, so we can assert the import endpoint, token auth, and
# multipart fields without a DefectDojo server.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/upload-scan-defectdojo.sh"

setup() {
  WORK=$(mktemp -d)
  BIN="${WORK}/bin"
  mkdir -p "${BIN}"
  export STUB_LOG="${WORK}/stub.log"
  : > "${STUB_LOG}"

  cat > "${BIN}/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "${STUB_LOG}"
out=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2; continue;;
    --config|-K) cfg="$2"; shift 2; continue;;
    *) shift;;
  esac
done
if [ -n "${out}" ]; then echo "${STUB_BODY:-ok}" > "${out}"; fi
if [ -n "${cfg}" ] && [ -f "${cfg}" ]; then
  sed 's/^/cfg: /' "${cfg}" >> "${STUB_LOG}"
fi
printf '%s' "${STUB_HTTP:-201}"
EOF
  chmod +x "${BIN}/curl"
  export PATH="${BIN}:${PATH}"

  REPORT="${WORK}/trivy.json"
  echo '{"Results":[]}' > "${REPORT}"
}

teardown() {
  rm -rf "${WORK}"
}

@test "no DEFECTDOJO_URL -> skips silently, exit 0, no curl" {
  run env REPORT_FILE="${REPORT}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "skipping findings import"
  [ ! -s "${STUB_LOG}" ]
}

@test "imports into an explicit engagement id with token auth" {
  run env DEFECTDOJO_URL=https://dd.example.com/ \
    DEFECTDOJO_API_KEY=dd-key REPORT_FILE="${REPORT}" \
    ENGAGEMENT=42 "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Eq 'curl .*-X POST https://dd.example.com/api/v2/import-scan/' "${STUB_LOG}"
  grep -Fq 'Authorization: Token dd-key' "${STUB_LOG}"
  grep -Fq 'scan_type=Trivy Scan' "${STUB_LOG}"
  grep -Eq "file=@${REPORT};type=application/json" "${STUB_LOG}"
  grep -Fq 'engagement=42' "${STUB_LOG}"
  # No auto-create fields on the explicit-engagement path.
  ! grep -Fq 'auto_create_context' "${STUB_LOG}"
}

@test "auto-create-context path when only a product name is given" {
  run env DEFECTDOJO_URL=https://dd.example.com \
    DEFECTDOJO_API_KEY=dd-key REPORT_FILE="${REPORT}" \
    PRODUCT_NAME="My App" ENGAGEMENT_NAME="PR scan" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq 'product_name=My App' "${STUB_LOG}"
  grep -Fq 'engagement_name=PR scan' "${STUB_LOG}"
  grep -Fq 'auto_create_context=true' "${STUB_LOG}"
}

@test "no engagement and no product name -> non-blocking (warn, exit 0)" {
  run env DEFECTDOJO_URL=https://dd.example.com \
    DEFECTDOJO_API_KEY=dd-key REPORT_FILE="${REPORT}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "DEFECTDOJO_ENGAGEMENT"
}

@test "missing report file is non-blocking (warn, exit 0)" {
  run env DEFECTDOJO_URL=https://dd.example.com \
    DEFECTDOJO_API_KEY=dd-key REPORT_FILE="${WORK}/nope.json" ENGAGEMENT=1 "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "missing or empty"
}

@test "a 500 from the server is non-blocking by default (exit 0)" {
  run env STUB_HTTP=500 DEFECTDOJO_URL=https://dd.example.com \
    DEFECTDOJO_API_KEY=dd-key REPORT_FILE="${REPORT}" ENGAGEMENT=1 "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "HTTP 500"
}

@test "a 500 under STRICT fails the gate (exit 1)" {
  run env STUB_HTTP=500 STRICT=true DEFECTDOJO_URL=https://dd.example.com \
    DEFECTDOJO_API_KEY=dd-key REPORT_FILE="${REPORT}" ENGAGEMENT=1 "${SCRIPT}"
  [ "$status" -eq 1 ]
}

@test "URL set but API key missing -> exit 1 (misconfig)" {
  run env DEFECTDOJO_URL=https://dd.example.com REPORT_FILE="${REPORT}" ENGAGEMENT=1 "${SCRIPT}"
  [ "$status" -eq 1 ]
}

@test "the API token is passed off curl argv via a --config file" {
  run env DEFECTDOJO_URL=https://dd.example.com \
    DEFECTDOJO_API_KEY=dd-key REPORT_FILE="${REPORT}" ENGAGEMENT=1 "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq 'cfg: header = "Authorization: Token dd-key"' "${STUB_LOG}"
  ! grep -Eq 'curl .*Authorization' "${STUB_LOG}"
}

@test "a non-https URL warns about cleartext (still imports)" {
  run env DEFECTDOJO_URL=http://dd.example.com \
    DEFECTDOJO_API_KEY=dd-key REPORT_FILE="${REPORT}" ENGAGEMENT=1 "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "not https"
  grep -Eq 'curl .*-X POST http://dd.example.com/api/v2/import-scan/' "${STUB_LOG}"
}
