#!/usr/bin/env bats

# Behaviour coverage for scripts/scan-image.sh plus structural assertions on the
# action.yml wiring.
#
# `trivy` is stubbed to emit a CycloneDX SBOM and a Trivy JSON report with a
# configurable number of findings (STUB_FINDINGS); `curl` is stubbed so the real
# sink uploaders run end-to-end without a Dependency-Track / DefectDojo server.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/scan-image.sh"
ACTION_YML="${BATS_TEST_DIRNAME}/../../action.yml"

setup() {
  WORK=$(mktemp -d)
  BIN="${WORK}/bin"
  mkdir -p "${BIN}"
  export STUB_LOG="${WORK}/stub.log"
  : > "${STUB_LOG}"
  export GITHUB_OUTPUT="${WORK}/output"
  : > "${GITHUB_OUTPUT}"

  # trivy stub: log argv; honour STUB_TRIVY_FAIL; write an SBOM for cyclonedx and
  # a report with STUB_FINDINGS vulnerabilities for json.
  cat > "${BIN}/trivy" <<'EOF'
#!/usr/bin/env bash
echo "trivy $*" >> "${STUB_LOG}"
[ -n "${STUB_TRIVY_FAIL:-}" ] && exit 1
fmt=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --format) fmt="$2"; shift 2; continue;;
    --output) out="$2"; shift 2; continue;;
    *) shift;;
  esac
done
case "${fmt}" in
  cyclonedx) echo '{"bomFormat":"CycloneDX","specVersion":"1.5","components":[]}' > "${out}";;
  json)
    # Fail only the findings pass (exercises the SECOND tool-error guard).
    [ -n "${STUB_TRIVY_FAIL_JSON:-}" ] && exit 1
    if [ "${STUB_REPORT_MODE:-}" = "mixed" ]; then
      # 1 vuln + 1 secret + 1 FAIL misconfig + 1 PASS misconfig → count must be 3.
      cat > "${out}" <<'JSON'
{"Results":[
  {"Target":"os","Class":"os-pkgs","Vulnerabilities":[{"VulnerabilityID":"CVE-1","Severity":"HIGH"}]},
  {"Target":"secret","Class":"secret","Secrets":[{"RuleID":"aws-key","Severity":"CRITICAL"}]},
  {"Target":"cfg","Class":"config","Misconfigurations":[{"ID":"DS001","Status":"FAIL"},{"ID":"DS002","Status":"PASS"}]}
]}
JSON
    else
      n="${STUB_FINDINGS:-0}"
      jq -n --argjson n "${n}" '{Results:[{Target:"img",Class:"os-pkgs",Vulnerabilities:[range($n)|{VulnerabilityID:("CVE-0000-\(.)"),Severity:"HIGH"}]}]}' > "${out}"
    fi
    ;;
esac
exit 0
EOF

  # curl stub: log argv, the --config secret header, and the --data payload;
  # write -o body; print HTTP code.
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
if [ -n "${cfg}" ] && [ -f "${cfg}" ]; then sed 's/^/cfg: /' "${cfg}" >> "${STUB_LOG}"; fi
if [ "${data#@}" != "${data}" ] && [ -f "${data#@}" ]; then
  sed 's/^/payload: /' "${data#@}" >> "${STUB_LOG}"
fi
printf '%s' "${STUB_HTTP:-201}"
EOF

  chmod +x "${BIN}/trivy" "${BIN}/curl"
  export PATH="${BIN}:${PATH}"
}

teardown() {
  rm -rf "${WORK}"
}

# ── scan behaviour ─────────────────────────────────────────────────────────

@test "no image refs -> scanned=false, exit 0, no trivy" {
  run env IMAGE_REFS="" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "scanned=false" "${GITHUB_OUTPUT}"
  grep -Fq "image-findings=0" "${GITHUB_OUTPUT}"
  [ ! -s "${STUB_LOG}" ]
}

@test "scans the ref: trivy SBOM + findings with the configured severity/scanners" {
  run env IMAGE_REFS="ghcr.io/acme/app:pr-3" \
    SCAN_SEVERITY=CRITICAL SCANNERS=vuln,secret "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Eq 'trivy image .*--format cyclonedx' "${STUB_LOG}"
  grep -Eq 'trivy image .*--format json .*--scanners vuln,secret .*--severity CRITICAL' "${STUB_LOG}"
  grep -Fq "scanned=true" "${GITHUB_OUTPUT}"
}

@test "uploads the SBOM to Dependency-Track with a project name/version derived from the ref" {
  run env IMAGE_REFS="ghcr.io/acme/app:pr-7" \
    DEPENDENCY_TRACK_URL=https://dt.example.com DEPENDENCY_TRACK_API_KEY=dt-key "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Eq 'curl .*-X PUT https://dt.example.com/api/v1/bom' "${STUB_LOG}"
  # Registry host stripped; "(image)" suffix keeps it distinct from a source SBOM project.
  grep -Fq '"projectName":"acme/app (image)"' "${STUB_LOG}"
  grep -Fq '"projectVersion":"pr-7"' "${STUB_LOG}"    # tag becomes the version
}

@test "ref derivation: a digest ref strips the digest and versions as latest" {
  run env IMAGE_REFS="ghcr.io/acme/app@sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    DEPENDENCY_TRACK_URL=https://dt.example.com DEPENDENCY_TRACK_API_KEY=dt-key "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq '"projectName":"acme/app (image)"' "${STUB_LOG}"
  grep -Fq '"projectVersion":"latest"' "${STUB_LOG}"
}

@test "ref derivation: a tagless ref versions as latest" {
  run env IMAGE_REFS="ghcr.io/acme/app" \
    DEPENDENCY_TRACK_URL=https://dt.example.com DEPENDENCY_TRACK_API_KEY=dt-key "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq '"projectVersion":"latest"' "${STUB_LOG}"
}

@test "ref derivation: a host-less ref keeps the full path as the name" {
  run env IMAGE_REFS="acme/app:pr-9" \
    DEPENDENCY_TRACK_URL=https://dt.example.com DEPENDENCY_TRACK_API_KEY=dt-key "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq '"projectName":"acme/app (image)"' "${STUB_LOG}"
  grep -Fq '"projectVersion":"pr-9"' "${STUB_LOG}"
}

@test "ref derivation: a registry with a port strips host:port, keeps the tag" {
  run env IMAGE_REFS="localhost:5000/acme/app:pr-2" \
    DEPENDENCY_TRACK_URL=https://dt.example.com DEPENDENCY_TRACK_API_KEY=dt-key "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq '"projectName":"acme/app (image)"' "${STUB_LOG}"
  grep -Fq '"projectVersion":"pr-2"' "${STUB_LOG}"
}

@test "imports findings into DefectDojo when configured" {
  run env IMAGE_REFS="ghcr.io/acme/app:pr-7" STUB_FINDINGS=2 \
    DEFECTDOJO_URL=https://dd.example.com DEFECTDOJO_API_KEY=dd-key DEFECTDOJO_ENGAGEMENT=9 "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Eq 'curl .*-X POST https://dd.example.com/api/v2/import-scan/' "${STUB_LOG}"
  grep -Fq 'engagement=9' "${STUB_LOG}"
}

@test "counts findings into the image-findings output" {
  run env IMAGE_REFS="ghcr.io/acme/app:pr-7" STUB_FINDINGS=3 "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "image-findings=3" "${GITHUB_OUTPUT}"
}

@test "gate off (default): findings present but exit 0" {
  run env IMAGE_REFS="ghcr.io/acme/app:pr-7" STUB_FINDINGS=5 "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "image-findings=5" "${GITHUB_OUTPUT}"
}

@test "gate on: findings present -> exit 1" {
  run env IMAGE_REFS="ghcr.io/acme/app:pr-7" STUB_FINDINGS=4 SCAN_GATE=true "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "image-scan-gate is on"
}

@test "gate on: zero findings -> exit 0" {
  run env IMAGE_REFS="ghcr.io/acme/app:pr-7" STUB_FINDINGS=0 SCAN_GATE=true "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "image-findings=0" "${GITHUB_OUTPUT}"
}

@test "trivy failure is a tool error (build red, exit 1)" {
  run env IMAGE_REFS="ghcr.io/acme/app:pr-7" STUB_TRIVY_FAIL=1 "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "tool error (build red)"
}

@test "a findings-pass-only trivy failure is also a tool error (second guard)" {
  run env IMAGE_REFS="ghcr.io/acme/app:pr-7" STUB_TRIVY_FAIL_JSON=1 "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "failed to scan"
}

@test "counting includes vulns + secrets + FAIL misconfigs, excludes PASS misconfigs" {
  run env IMAGE_REFS="ghcr.io/acme/app:pr-7" STUB_REPORT_MODE=mixed "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "image-findings=3" "${GITHUB_OUTPUT}"   # 1 vuln + 1 secret + 1 FAIL (PASS excluded)
}

@test "multiple refs with a pinned DT project name stay distinct" {
  run env IMAGE_REFS=$'ghcr.io/acme/app1:pr-5\nghcr.io/acme/app2:pr-5' \
    DEPENDENCY_TRACK_URL=https://dt.example.com DEPENDENCY_TRACK_API_KEY=dt-key \
    DEPENDENCY_TRACK_PROJECT_NAME=acme-images "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq '"projectName":"acme-images/app1"' "${STUB_LOG}"
  grep -Fq '"projectName":"acme-images/app2"' "${STUB_LOG}"
}

@test "a Dependency-Track outage does not fail the scan" {
  run env IMAGE_REFS="ghcr.io/acme/app:pr-7" STUB_HTTP=500 \
    DEPENDENCY_TRACK_URL=https://dt.example.com DEPENDENCY_TRACK_API_KEY=dt-key "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "scanned=true" "${GITHUB_OUTPUT}"
}

# ── action.yml wiring ──────────────────────────────────────────────────────

@test "action.yml gates the scan step on mode/image_name/image-scan" {
  grep -Eq "inputs.mode == 'ci' && inputs.image_name != '' && inputs.image-scan == 'true'" "${ACTION_YML}"
  grep -Eq "scan-image.sh" "${ACTION_YML}"
}

@test "action.yml SHA-pins the Trivy installer" {
  grep -Fq "aquasecurity/setup-trivy@81e514348e19b6112ce2a7e3ecbafe19c1e1f567" "${ACTION_YML}"
}

@test "action.yml exposes the image-scan inputs and outputs" {
  grep -Eq "^  image-scan:" "${ACTION_YML}"
  grep -Eq "^  image-scan-strict:" "${ACTION_YML}"
  grep -Eq "^  dependency-track-url:" "${ACTION_YML}"
  grep -Eq "^  defectdojo-url:" "${ACTION_YML}"
  grep -Eq "image-scanned:" "${ACTION_YML}"
  grep -Eq "image-findings:" "${ACTION_YML}"
}

@test "action.yml wires the strict sink override into the scan step env" {
  grep -Eq "STRICT: \\\$\{\{ inputs.image-scan-strict \}\}" "${ACTION_YML}"
}
