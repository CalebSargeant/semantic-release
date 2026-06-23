#!/usr/bin/env bash
# Import a Trivy image-scan report into DefectDojo.
#
# Called by scripts/scan-image.sh (the "Scan image and report" step in
# action.yml, mode: ci). DefectDojo is the *findings* aggregator for the Magma
# Moose pipeline. It is optional and complements the Dependency-Track SBOM feed:
# DT already derives component CVEs from the SBOM, so this feed only adds what
# SBOM matching misses — OS-level CVEs, image misconfigurations, and secrets
# baked into layers.
#
# Failure-isolated by default (rule: any reporting backend can be down without
# failing the PR gate). A DefectDojo outage logs a ::warning:: and exits 0; set
# STRICT=true to make import failure fatal.
#
# Required env:
#   DEFECTDOJO_URL      - DefectDojo base URL, e.g. https://dd.example.com
#                         (no trailing /api). Empty → skip silently.
#   DEFECTDOJO_API_KEY  - DefectDojo API v2 token.
#   REPORT_FILE         - path to the Trivy JSON report to import.
#
# Engagement targeting — provide EITHER:
#   ENGAGEMENT          - numeric engagement id to import into, OR
#   PRODUCT_NAME +      - with AUTO_CREATE_CONTEXT=true (default), DefectDojo
#   ENGAGEMENT_NAME       creates the product/engagement on demand.
#
# Optional env:
#   SCAN_TYPE           - DefectDojo parser name. Default 'Trivy Scan'.
#   AUTO_CREATE_CONTEXT - true | false. Default true (used with PRODUCT_NAME).
#   STRICT              - true | false. Treat an import error as fatal. Default false.
#
# Side effects:
#   - Masks DEFECTDOJO_API_KEY in the workflow log.
#
# Exit codes:
#   0 - imported, skipped (no URL), or import failed while not STRICT
#   1 - misconfiguration, or import failed while STRICT=true

set -euo pipefail

DD_URL="${DEFECTDOJO_URL:-}"
STRICT="${STRICT:-false}"

# No server configured → this sink is simply off. Not an error.
if [ -z "${DD_URL}" ]; then
  echo "DefectDojo: no DEFECTDOJO_URL set — skipping findings import."
  exit 0
fi

if [ -n "${DEFECTDOJO_API_KEY:-}" ]; then
  echo "::add-mask::${DEFECTDOJO_API_KEY}"
fi

sink_fail() {
  if [ "${STRICT}" = "true" ]; then
    echo "::error::DefectDojo: $1"
    exit 1
  fi
  echo "::warning::DefectDojo: $1 (sink failure is non-blocking; set STRICT=true to fail the gate)."
  exit 0
}

: "${DEFECTDOJO_API_KEY:?DEFECTDOJO_API_KEY is required when DEFECTDOJO_URL is set}"

if [ ! -s "${REPORT_FILE:-}" ]; then
  sink_fail "REPORT_FILE '${REPORT_FILE:-}' is missing or empty — nothing to import"
fi

DD_URL="${DD_URL%/}"
SCAN_TYPE="${SCAN_TYPE:-Trivy Scan}"
AUTO_CREATE_CONTEXT="${AUTO_CREATE_CONTEXT:-true}"
ENDPOINT="${DD_URL}/api/v2/import-scan/"

# A plaintext endpoint would put the API token on the wire in the clear.
case "${DD_URL}" in
  https://*) ;;
  *) echo "::warning::DefectDojo URL is not https (${DD_URL}) — the API token will be sent in cleartext." ;;
esac

# Build the multipart form. Either import into an explicit engagement id, or let
# DefectDojo create the product/engagement context from names.
FORM=(-F "scan_type=${SCAN_TYPE}" -F "file=@${REPORT_FILE};type=application/json")
if [ -n "${ENGAGEMENT:-}" ]; then
  FORM+=(-F "engagement=${ENGAGEMENT}")
  echo "DefectDojo: importing '${SCAN_TYPE}' into engagement ${ENGAGEMENT} (${ENDPOINT})"
elif [ -n "${PRODUCT_NAME:-}" ]; then
  FORM+=(-F "product_name=${PRODUCT_NAME}")
  FORM+=(-F "engagement_name=${ENGAGEMENT_NAME:-Diatreme image scan}")
  FORM+=(-F "auto_create_context=${AUTO_CREATE_CONTEXT}")
  echo "DefectDojo: importing '${SCAN_TYPE}' into product '${PRODUCT_NAME}' (auto_create_context=${AUTO_CREATE_CONTEXT}) (${ENDPOINT})"
else
  sink_fail "set DEFECTDOJO_ENGAGEMENT (id) or DEFECTDOJO_PRODUCT_NAME to choose where to import"
fi

BODY="$(mktemp)"
ERR="$(mktemp)"
# Keep the API token off curl's argv (world-readable via the process table on a
# persistent/multi-tenant self-hosted runner). curl reads it from a --config
# file with 0600 perms instead.
CURL_CFG="$(mktemp)"
chmod 600 "${CURL_CFG}"
trap 'rm -f "${BODY}" "${ERR}" "${CURL_CFG}"' EXIT
printf 'header = "Authorization: Token %s"\n' "${DEFECTDOJO_API_KEY}" > "${CURL_CFG}"

HTTP_CODE="$(curl -sS --config "${CURL_CFG}" -o "${BODY}" -w '%{http_code}' \
  -X POST "${ENDPOINT}" \
  "${FORM[@]}" 2>"${ERR}" || true)"

if ! printf '%s' "${HTTP_CODE}" | grep -qE '^2[0-9][0-9]$'; then
  cat "${ERR}" >&2 || true
  head -c 500 "${BODY}" >&2 2>/dev/null || true
  sink_fail "import returned HTTP ${HTTP_CODE:-000}"
fi

echo "DefectDojo: report imported (HTTP ${HTTP_CODE})."
