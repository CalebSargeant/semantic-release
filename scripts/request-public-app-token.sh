#!/usr/bin/env bash
set -euo pipefail

broker_url="${TOKEN_BROKER_URL:-https://api.diatreme.magmamoose.com}"
audience="${OIDC_AUDIENCE:-diatreme}"
request_url="${ACTIONS_ID_TOKEN_REQUEST_URL:-}"
request_token="${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}"
repository="${GITHUB_REPOSITORY:-}"

if [[ -z "${broker_url}" ]]; then
  echo "::error::auth-mode public-app requires token-broker-url."
  exit 1
fi

if [[ -z "${request_url}" || -z "${request_token}" ]]; then
  echo "::error::OIDC request environment is unavailable. Grant 'id-token: write' to this job."
  exit 1
fi

if [[ "${repository}" != */* ]]; then
  echo "::error::GITHUB_REPOSITORY must be owner/repo."
  exit 1
fi

owner="${repository%%/*}"
repo="${repository#*/}"
encoded_audience="$(jq -rn --arg value "${audience}" '$value | @uri')"
oidc_response="$(
  curl -fsS \
    -H "Authorization: bearer ${request_token}" \
    "${request_url}&audience=${encoded_audience}"
)"
oidc_token="$(jq -er '.value' <<<"${oidc_response}")"

payload="$(
  jq -n \
    --arg oidcToken "${oidc_token}" \
    --arg owner "${owner}" \
    --arg repo "${repo}" \
    --arg ref "${GITHUB_REF:-}" \
    --arg runId "${GITHUB_RUN_ID:-}" \
    --arg sha "${GITHUB_SHA:-}" \
    '{
      oidcToken: $oidcToken,
      owner: $owner,
      repo: $repo,
      ref: $ref,
      runId: $runId,
      sha: $sha
    }'
)"

body_file="$(mktemp)"
trap 'rm -f "${body_file}"' EXIT

status="$(
  curl -sS \
    -o "${body_file}" \
    -w '%{http_code}' \
    -X POST \
    -H 'Content-Type: application/json' \
    --data "${payload}" \
    "${broker_url%/}/token"
)"

if [[ "${status}" != "200" ]]; then
  error_code="$(jq -r '.error // "token_broker_error"' "${body_file}" 2>/dev/null || echo "token_broker_error")"
  echo "::error::Token broker request failed with HTTP ${status}: ${error_code}"
  exit 1
fi

installation_token="$(jq -er '.token' "${body_file}")"
expires_at="$(jq -r '.expires_at // ""' "${body_file}")"
broker_repository="$(jq -r '.repository // ""' "${body_file}")"

echo "::add-mask::${installation_token}"
{
  echo "token=${installation_token}"
  echo "expires-at=${expires_at}"
  echo "repository=${broker_repository}"
} >> "${GITHUB_OUTPUT}"

echo "Received short-lived public GitHub App token for ${broker_repository}."
