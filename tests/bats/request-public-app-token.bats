#!/usr/bin/env bats
#
# The broker fallback exists because a single hostname losing egress blocks releases
# in every repository pinned to every published version, and no change we ship can
# redirect those pins (see #147). These tests pin when the fallback fires — and, just
# as importantly, when it must not.

setup() {
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github-output"
  : > "${GITHUB_OUTPUT}"
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${STUB_BIN}"
  export CALL_LOG="${BATS_TEST_TMPDIR}/curl-calls"
  : > "${CALL_LOG}"

  # OIDC minting: first curl call (has an Authorization header) returns the token JSON.
  # Broker calls: driven per-test by PRIMARY_* / FALLBACK_* env.
  cat > "${STUB_BIN}/curl" <<'STUB'
#!/usr/bin/env bash
url="${@: -1}"
out=""; want_out=0
for a in "$@"; do
  if [[ "${want_out}" == 1 ]]; then out="$a"; want_out=0; fi
  [[ "$a" == "-o" ]] && want_out=1
done
if [[ "${url}" == *"idtoken"* ]]; then
  printf '{"value":"header.payload.signature"}'
  exit 0
fi
echo "${url}" >> "${CALL_LOG}"
if [[ "${url}" == "${PRIMARY_URL}"* ]]; then
  code="${PRIMARY_CODE}"; body="${PRIMARY_BODY:-{\}}"
else
  code="${FALLBACK_CODE}"; body="${FALLBACK_BODY:-{\}}"
fi
[[ "${code}" == "000" ]] && exit 7
[[ -n "${out}" ]] && printf '%s' "${body}" > "${out}"
printf '%s' "${code}"
STUB
  chmod +x "${STUB_BIN}/curl"

  export PATH="${STUB_BIN}:${PATH}"
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://idtoken.example.com/token?x=1"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="req-token"
  export GITHUB_REPOSITORY="octo-org/octo-repo"
  export TOKEN_BROKER_URL="https://primary.example.com"
  export TOKEN_BROKER_FALLBACK_URL="https://fallback.example.com"
  export PRIMARY_URL="https://primary.example.com"
}

ok_body='{"token":"ghs_x","expires_at":"2026-01-01T00:00:00Z","repository":"octo-org/octo-repo"}'

@test "primary succeeds: fallback is never called" {
  run env PRIMARY_CODE=200 PRIMARY_BODY="${ok_body}" FALLBACK_CODE=200 \
    bash scripts/request-public-app-token.sh

  [ "$status" -eq 0 ]
  [ "$(grep -c fallback.example.com "${CALL_LOG}")" -eq 0 ]
  grep -q "token=ghs_x" "${GITHUB_OUTPUT}"
}

@test "primary 5xx: falls back and succeeds" {
  run env PRIMARY_CODE=503 FALLBACK_CODE=200 FALLBACK_BODY="${ok_body}" \
    bash scripts/request-public-app-token.sh

  [ "$status" -eq 0 ]
  [ "$(grep -c fallback.example.com "${CALL_LOG}")" -eq 1 ]
  [[ "$output" == *"trying fallback"* ]]
  grep -q "token=ghs_x" "${GITHUB_OUTPUT}"
}

@test "primary unreachable: falls back and succeeds" {
  run env PRIMARY_CODE=000 FALLBACK_CODE=200 FALLBACK_BODY="${ok_body}" \
    bash scripts/request-public-app-token.sh

  [ "$status" -eq 0 ]
  [ "$(grep -c fallback.example.com "${CALL_LOG}")" -eq 1 ]
}

@test "primary 4xx: does NOT fall back — a rejected token is an answer, not an outage" {
  run env PRIMARY_CODE=401 PRIMARY_BODY='{"error":"invalid_oidc_token","reason":"kid_not_found"}' \
    FALLBACK_CODE=200 FALLBACK_BODY="${ok_body}" \
    bash scripts/request-public-app-token.sh

  [ "$status" -eq 1 ]
  [ "$(grep -c fallback.example.com "${CALL_LOG}")" -eq 0 ]
  [[ "$output" == *"kid_not_found"* ]]
}

@test "empty fallback disables the second attempt" {
  run env TOKEN_BROKER_FALLBACK_URL="" PRIMARY_CODE=503 \
    bash scripts/request-public-app-token.sh

  [ "$status" -eq 1 ]
  [ "$(wc -l < "${CALL_LOG}")" -eq 1 ]
}

@test "fallback identical to primary is not retried" {
  run env TOKEN_BROKER_FALLBACK_URL="https://primary.example.com" PRIMARY_CODE=503 \
    bash scripts/request-public-app-token.sh

  [ "$status" -eq 1 ]
  [ "$(wc -l < "${CALL_LOG}")" -eq 1 ]
}

@test "both fail: reports the broker actually used" {
  run env PRIMARY_CODE=503 FALLBACK_CODE=503 FALLBACK_BODY='{"error":"oidc_key_fetch_failed","reason":"jwks_unavailable"}' \
    bash scripts/request-public-app-token.sh

  [ "$status" -eq 1 ]
  [[ "$output" == *"jwks_unavailable"* ]]
  [[ "$output" == *"fallback.example.com"* ]]
}
