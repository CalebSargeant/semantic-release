#!/usr/bin/env bash
# Scan assembled PR images and route the results to their sinks.
#
# Called by the "Scan image and report" step in action.yml (mode: ci), once the
# pr-<N> image(s) have been built and pushed. This is Diatreme's slice of the
# Magma Moose pipeline beyond build+promote: it inspects the *assembled* image
# (base-image packages and whatever the Dockerfile added — things the source
# dependency scan never sees) and routes two artifact categories:
#
#   - CycloneDX SBOM  → Dependency-Track  (the assembled-image project; DT
#                       re-derives component CVEs from the SBOM)
#   - scan findings   → DefectDojo        (optional; OS CVEs, misconfigs, and
#                       secrets in layers — what SBOM matching misses)
#
# Reporting is visibility-first: by default the scan never fails the PR. A scan
# that cannot run at all is a different thing — a broken scanner is a *tool
# error* (build red), never reported as "0 findings". The optional SCAN_GATE
# turns net findings into a blocking check (a blunt severity threshold for now;
# net-new diffing against the base image is the intended direction).
#
# Required env:
#   IMAGE_REFS - newline-separated, fully-qualified image refs to scan, e.g.
#                ghcr.io/owner/app:pr-12. Produced by the action from the bake
#                targets that were just pushed.
#
# Optional env (scan):
#   SCAN_SEVERITY - Trivy --severity filter for findings. Default CRITICAL,HIGH.
#   SCANNERS      - Trivy --scanners. Default vuln,secret,misconfig.
#   SCAN_GATE     - true | false. Fail (exit 1) when net findings exist at/above
#                   SCAN_SEVERITY. Default false (non-blocking, visibility only).
#
# Optional env (Dependency-Track sink — skipped unless URL is set):
#   DEPENDENCY_TRACK_URL, DEPENDENCY_TRACK_API_KEY
#   DEPENDENCY_TRACK_PROJECT_NAME    - overrides the per-image default (the
#                                      image repository path).
#   DEPENDENCY_TRACK_PROJECT_VERSION - overrides the per-image default (the
#                                      image tag, e.g. pr-12).
#
# Optional env (DefectDojo sink — skipped unless URL is set):
#   DEFECTDOJO_URL, DEFECTDOJO_API_KEY
#   DEFECTDOJO_ENGAGEMENT       - numeric engagement id, OR
#   DEFECTDOJO_PRODUCT_NAME     - with auto_create_context (engagement created)
#   DEFECTDOJO_ENGAGEMENT_NAME  - engagement name for the auto-create path.
#
# Side effects:
#   - Writes `scanned=true|false` and `image-findings=<count>` to $GITHUB_OUTPUT.
#
# Exit codes:
#   0 - scanned (sinks are failure-isolated; finding counts don't block unless
#       SCAN_GATE=true)
#   1 - a scanner/tool error (build red), or SCAN_GATE=true with net findings

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCAN_SEVERITY="${SCAN_SEVERITY:-CRITICAL,HIGH}"
SCANNERS="${SCANNERS:-vuln,secret,misconfig}"
SCAN_GATE="${SCAN_GATE:-false}"

emit() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >> "${GITHUB_OUTPUT}"
  fi
}

# Collapse blank lines and surrounding whitespace from IMAGE_REFS.
mapfile -t REFS < <(printf '%s\n' "${IMAGE_REFS:-}" | sed 's/[[:space:]]//g' | grep -v '^$' || true)

if [ "${#REFS[@]}" -eq 0 ]; then
  echo "::warning::image scanning is enabled but no image refs were resolved — nothing to scan."
  emit scanned false
  emit image-findings 0
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -f "${SBOM:-}" "${REPORT:-}"; rm -rf "${WORK}"' EXIT

TOTAL_FINDINGS=0

for REF in "${REFS[@]}"; do
  echo "── Scanning ${REF} ────────────────────────────────────────────────"

  # Derive a Dependency-Track project name/version from the ref. Strip any
  # digest, split off the tag, then drop the registry host so the project name
  # is the image repository path (e.g. owner/app). The tag becomes the version.
  NO_DIGEST="${REF%%@*}"
  FINAL_SEG="${NO_DIGEST##*/}"
  if [[ "${FINAL_SEG}" == *:* ]]; then
    REF_TAG="${FINAL_SEG##*:}"
    REPO_PATH="${NO_DIGEST%:*}"
  else
    REF_TAG="latest"
    REPO_PATH="${NO_DIGEST}"
  fi
  HOST_SEG="${REPO_PATH%%/*}"
  if [[ "${HOST_SEG}" == *.* || "${HOST_SEG}" == *:* || "${HOST_SEG}" == "localhost" ]]; then
    NAME_PATH="${REPO_PATH#*/}"
  else
    NAME_PATH="${REPO_PATH}"
  fi

  if [ -n "${DEPENDENCY_TRACK_PROJECT_NAME:-}" ]; then
    DT_PROJECT_NAME="${DEPENDENCY_TRACK_PROJECT_NAME}"
    # When the caller pins one project name but several images are built, keep
    # the projects distinct by appending the image's leaf name.
    if [ "${#REFS[@]}" -gt 1 ]; then
      DT_PROJECT_NAME="${DEPENDENCY_TRACK_PROJECT_NAME}/${NAME_PATH##*/}"
    fi
  else
    # Default to the image repository path with an "(image)" discriminator, so
    # the assembled-image SBOM is a DISTINCT Dependency-Track project from any
    # source-dependency SBOM project for the same repo (Chargate defaults its
    # source project to the bare repo path). This preserves the pipeline's
    # "two projects under one server" invariant without operator coordination.
    DT_PROJECT_NAME="${NAME_PATH} (image)"
  fi
  DT_PROJECT_VERSION="${DEPENDENCY_TRACK_PROJECT_VERSION:-${REF_TAG}}"

  SBOM="${WORK}/$(echo "${NAME_PATH}" | tr '/:' '__').cdx.json"
  REPORT="${WORK}/$(echo "${NAME_PATH}" | tr '/:' '__').trivy.json"

  # 1) CycloneDX SBOM (full component inventory) for Dependency-Track.
  if ! trivy image --quiet --format cyclonedx --output "${SBOM}" "${REF}"; then
    echo "::error::Trivy failed to generate an SBOM for ${REF}. A scanner that cannot run is a tool error (build red), not a finding."
    exit 1
  fi

  # 2) Findings report (vuln/secret/misconfig at the configured severity) for
  #    DefectDojo and the gate. --exit-code 0 so findings never set the exit
  #    status — we decide blocking ourselves below.
  if ! trivy image --quiet --format json --exit-code 0 \
      --scanners "${SCANNERS}" --severity "${SCAN_SEVERITY}" \
      --output "${REPORT}" "${REF}"; then
    echo "::error::Trivy failed to scan ${REF}. A scanner that cannot run is a tool error (build red), not a finding."
    exit 1
  fi

  COUNT="$(jq '[ .Results[]? | ((.Vulnerabilities // [])[], (.Secrets // [])[], ((.Misconfigurations // [])[] | select(.Status == "FAIL"))) ] | length' "${REPORT}" 2>/dev/null || echo 0)"
  # Collapse empty / null / any non-integer to 0 so a parsing surprise can't
  # abort a healthy scan via `set -u` arithmetic (bare word treated as a name).
  [[ "${COUNT}" =~ ^[0-9]+$ ]] || COUNT=0
  echo "Findings (${SCAN_SEVERITY}, ${SCANNERS}) in ${REF}: ${COUNT}"
  TOTAL_FINDINGS=$((TOTAL_FINDINGS + COUNT))

  # 3) Route to sinks. Both uploaders are failure-isolated and no-op when their
  #    URL is unset, so a sink outage never blocks the gate.
  BOM_FILE="${SBOM}" \
  PROJECT_NAME="${DT_PROJECT_NAME}" \
  PROJECT_VERSION="${DT_PROJECT_VERSION}" \
  AUTO_CREATE="${DEPENDENCY_TRACK_AUTO_CREATE:-true}" \
    "${SCRIPT_DIR}/upload-sbom-dependency-track.sh"

  REPORT_FILE="${REPORT}" \
  ENGAGEMENT="${DEFECTDOJO_ENGAGEMENT:-}" \
  PRODUCT_NAME="${DEFECTDOJO_PRODUCT_NAME:-}" \
  PRODUCT_TYPE_NAME="${DEFECTDOJO_PRODUCT_TYPE:-}" \
  ENGAGEMENT_NAME="${DEFECTDOJO_ENGAGEMENT_NAME:-}" \
  CLOSE_OLD="${DEFECTDOJO_CLOSE_OLD:-true}" \
    "${SCRIPT_DIR}/upload-scan-defectdojo.sh"
done

emit scanned true
emit image-findings "${TOTAL_FINDINGS}"
echo "Image scan complete — ${TOTAL_FINDINGS} finding(s) at/above ${SCAN_SEVERITY} across ${#REFS[@]} image(s)."

if [ "${SCAN_GATE}" = "true" ] && [ "${TOTAL_FINDINGS}" -gt 0 ]; then
  echo "::error::image-scan-gate is on and ${TOTAL_FINDINGS} finding(s) at/above ${SCAN_SEVERITY} were found — failing the build."
  exit 1
fi
