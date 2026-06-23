#!/usr/bin/env bash
# Upload a CycloneDX SBOM to a Dependency-Track server.
#
# Called by scripts/scan-image.sh (the "Scan image and report" step in
# action.yml, mode: ci) once per assembled image. Dependency-Track is the
# SBOM/component sink for the Magma Moose pipeline: it ingests the CycloneDX
# BOM and re-derives component CVEs itself, so a plain component inventory is
# enough — we never push "findings" here (that is DefectDojo's job).
#
# This is the *assembled-image* SBOM project, deliberately distinct from the
# *source-dependency* SBOM that Chargate pushes for the same repo. They are two
# projects on one server: the source SBOM only sees declared dependencies, the
# image SBOM also sees base-image packages and anything the Dockerfile added.
#
# Failure-isolated by default (rule: any reporting backend can be down without
# failing the PR gate). A DT outage logs a ::warning:: and exits 0; set
# STRICT=true to make upload failure fatal.
#
# Required env:
#   DEPENDENCY_TRACK_URL      - DT base URL, e.g. https://dtrack.example.com
#                               (no trailing /api). Empty → skip silently.
#   DEPENDENCY_TRACK_API_KEY  - DT API key with BOM_UPLOAD permission.
#   BOM_FILE                  - path to the CycloneDX JSON to upload.
#   PROJECT_NAME              - DT project name (the assembled-image project).
#   PROJECT_VERSION           - DT project version (e.g. the pr-<N> tag).
#
# Optional env:
#   AUTO_CREATE - true | false. Create the project on first upload. Default true.
#   STRICT      - true | false. Treat an upload error as fatal. Default false.
#
# Side effects:
#   - Masks DEPENDENCY_TRACK_API_KEY in the workflow log.
#
# Exit codes:
#   0 - uploaded, skipped (no URL), or upload failed while not STRICT
#   1 - misconfiguration, or upload failed while STRICT=true

set -euo pipefail

DT_URL="${DEPENDENCY_TRACK_URL:-}"
STRICT="${STRICT:-false}"

# No server configured → this sink is simply off. Not an error.
if [ -z "${DT_URL}" ]; then
  echo "Dependency-Track: no DEPENDENCY_TRACK_URL set — skipping SBOM upload."
  exit 0
fi

if [ -n "${DEPENDENCY_TRACK_API_KEY:-}" ]; then
  echo "::add-mask::${DEPENDENCY_TRACK_API_KEY}"
fi

# Treat an upload problem as failure-isolated (warn + exit 0) unless STRICT.
sink_fail() {
  if [ "${STRICT}" = "true" ]; then
    echo "::error::Dependency-Track: $1"
    exit 1
  fi
  echo "::warning::Dependency-Track: $1 (sink failure is non-blocking; set STRICT=true to fail the gate)."
  exit 0
}

: "${DEPENDENCY_TRACK_API_KEY:?DEPENDENCY_TRACK_API_KEY is required when DEPENDENCY_TRACK_URL is set}"
: "${PROJECT_NAME:?PROJECT_NAME is required}"
: "${PROJECT_VERSION:?PROJECT_VERSION is required}"

if [ ! -s "${BOM_FILE:-}" ]; then
  sink_fail "BOM_FILE '${BOM_FILE:-}' is missing or empty — nothing to upload"
fi

# Trim a trailing slash so we build a clean /api/v1/bom path.
DT_URL="${DT_URL%/}"
ENDPOINT="${DT_URL}/api/v1/bom"

# A plaintext endpoint would put the API key on the wire in the clear.
case "${DT_URL}" in
  https://*) ;;
  *) echo "::warning::Dependency-Track URL is not https (${DT_URL}) — the API key will be sent in cleartext." ;;
esac

# autoCreate is interpolated into JSON via jq --argjson, which requires a JSON
# literal. Normalize up front so an off-label value (yes, 1, …) yields an
# actionable error rather than a generic "payload assembly failed".
AUTO_CREATE="${AUTO_CREATE:-true}"
case "${AUTO_CREATE}" in
  true|false) ;;
  *) sink_fail "AUTO_CREATE must be 'true' or 'false', got '${AUTO_CREATE}'" ;;
esac

# DT's PUT /api/v1/bom accepts a JSON envelope with the BOM base64-encoded.
# Build it with jq --rawfile so arbitrary BOM bytes are encoded safely (no
# shell interpolation of the SBOM contents).
PAYLOAD="$(mktemp)"
BODY="$(mktemp)"
ERR="$(mktemp)"
# Keep the API key off curl's argv (it would be world-readable via the process
# table on a persistent/multi-tenant self-hosted runner). curl reads it from a
# --config file with 0600 perms instead.
CURL_CFG="$(mktemp)"
chmod 600 "${CURL_CFG}"
trap 'rm -f "${PAYLOAD}" "${BODY}" "${ERR}" "${CURL_CFG}"' EXIT
printf 'header = "X-Api-Key: %s"\n' "${DEPENDENCY_TRACK_API_KEY}" > "${CURL_CFG}"

if ! jq -cn \
  --arg name "${PROJECT_NAME}" \
  --arg version "${PROJECT_VERSION}" \
  --argjson autoCreate "${AUTO_CREATE}" \
  --rawfile bom "${BOM_FILE}" \
  '{projectName:$name, projectVersion:$version, autoCreate:$autoCreate, bom:($bom|@base64)}' \
  > "${PAYLOAD}"; then
  sink_fail "failed to assemble the upload payload from '${BOM_FILE}'"
fi

echo "Dependency-Track: uploading image SBOM → project '${PROJECT_NAME}' @ '${PROJECT_VERSION}' (${ENDPOINT})"

HTTP_CODE="$(curl -sS --config "${CURL_CFG}" -o "${BODY}" -w '%{http_code}' \
  -X PUT "${ENDPOINT}" \
  -H 'Content-Type: application/json' \
  --data @"${PAYLOAD}" 2>"${ERR}" || true)"

if ! printf '%s' "${HTTP_CODE}" | grep -qE '^2[0-9][0-9]$'; then
  cat "${ERR}" >&2 || true
  head -c 500 "${BODY}" >&2 2>/dev/null || true
  sink_fail "upload returned HTTP ${HTTP_CODE:-000}"
fi

echo "Dependency-Track: SBOM accepted (HTTP ${HTTP_CODE})."
