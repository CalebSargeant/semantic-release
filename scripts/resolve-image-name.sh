#!/usr/bin/env bash
# Resolve the base image name for Diatreme's image workflows (CI image build,
# image scan, and release image promotion).
#
# `image_name` is optional. Diatreme already infers the release environment
# from the deployment model / branch-map; this does the same for the image
# name so callers don't have to bolt on a bespoke pre-step just to compute it.
#
# Precedence:
#   1. Explicit INPUT_IMAGE_NAME wins, verbatim — historical behavior, unchanged.
#   2. Otherwise, when a Docker Bake file exists, derive the base image name
#      from the first non-empty target tag rendered by `docker buildx bake
#      --print` (the same bake file + target the build/promote steps use).
#   3. Otherwise (no explicit name, no bake file) leave it empty — versioning-
#      only / non-image workflows are unaffected because the consuming steps
#      gate on a non-empty resolved name and simply skip.
#
# A bake file that exists but yields no tags is a hard error: Diatreme never
# silently falls back to the repository name.
#
# Required env:
#   INPUT_BAKE_FILE   - path to the Docker Bake file (e.g. docker-bake.hcl).
#   INPUT_BAKE_TARGET - bake target or group to inspect (e.g. default).
#
# Optional env:
#   INPUT_IMAGE_NAME  - explicit base image name; wins when non-empty.
#   BAKE_GITHUB_TOKEN - inherited by `docker buildx bake --print` so the printed
#                       target set matches the build/promote steps (only matters
#                       if the bake file gates targets on that secret).
#
# Side effects:
#   Writes `image_name=<value>` to $GITHUB_OUTPUT (value may be empty).
#
# Exit codes:
#   0 - resolved (the value may be empty when there is nothing to resolve)
#   1 - a bake file exists but no image tag could be derived from it

set -euo pipefail

INPUT_IMAGE_NAME="${INPUT_IMAGE_NAME:-}"
INPUT_BAKE_FILE="${INPUT_BAKE_FILE:-docker-bake.hcl}"
INPUT_BAKE_TARGET="${INPUT_BAKE_TARGET:-default}"

emit() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "image_name=$1" >> "${GITHUB_OUTPUT}"
  fi
}

# 1) Explicit input wins, verbatim — resolve before touching the bake file so
#    an explicit name works even when no docker-bake.hcl is present.
if [ -n "${INPUT_IMAGE_NAME}" ]; then
  echo "image_name provided explicitly: '${INPUT_IMAGE_NAME}'."
  emit "${INPUT_IMAGE_NAME}"
  exit 0
fi

# 2) No explicit name and no bake file — nothing to detect. Preserve existing
#    behavior for versioning-only / non-image workflows.
if [ ! -f "${INPUT_BAKE_FILE}" ]; then
  echo "No image_name provided and no bake file at '${INPUT_BAKE_FILE}' — leaving image_name empty (non-image workflow)."
  emit ""
  exit 0
fi

echo "No image_name provided — detecting from Docker Bake (file '${INPUT_BAKE_FILE}', target '${INPUT_BAKE_TARGET}')."

# Render the bake definition. `--print` evaluates the HCL and prints JSON; it
# never builds, so it needs no builder instance. BAKE_GITHUB_TOKEN is inherited
# from the environment so the printed targets match the build/promote steps.
BAKE_ERR="$(mktemp)"
trap 'rm -f "${BAKE_ERR}"' EXIT
if ! BAKE_JSON="$(docker buildx bake -f "${INPUT_BAKE_FILE}" "${INPUT_BAKE_TARGET}" --print 2>"${BAKE_ERR}")"; then
  echo "::error::Could not evaluate Docker Bake file '${INPUT_BAKE_FILE}' (target '${INPUT_BAKE_TARGET}') to detect image_name. Pass image_name explicitly, or fix the bake file. Details: $(tr '\n' ' ' < "${BAKE_ERR}" | head -c 300)"
  exit 1
fi

# First non-empty tag across every rendered target.
FIRST_TAG="$(printf '%s' "${BAKE_JSON}" | jq -r '[ (.target // {})[].tags[]? | select(. != null and . != "") ] | .[0] // empty' 2>/dev/null || true)"

if [ -z "${FIRST_TAG}" ]; then
  echo "::error::Docker Bake file '${INPUT_BAKE_FILE}' (target '${INPUT_BAKE_TARGET}') produced no image tags, so image_name cannot be detected. Add a tag to the bake target, or pass image_name explicitly. Diatreme does not fall back to the repository name."
  exit 1
fi

# Reduce a full image reference to its base name, e.g.
#   ghcr.io/org/app:tag@sha256:...  ->  app
# Strip the digest, then the tag (only when the ':' is in the final path
# segment, so a registry port like localhost:5000 is preserved), then the
# registry host, then the owner/org prefix. Mirrors the ref derivation in
# scripts/scan-image.sh so the two stay consistent.
NO_DIGEST="${FIRST_TAG%%@*}"
FINAL_SEG="${NO_DIGEST##*/}"
if [[ "${FINAL_SEG}" == *:* ]]; then
  REPO_PATH="${NO_DIGEST%:*}"
else
  REPO_PATH="${NO_DIGEST}"
fi
HOST_SEG="${REPO_PATH%%/*}"
if [[ "${HOST_SEG}" == *.* || "${HOST_SEG}" == *:* || "${HOST_SEG}" == "localhost" ]]; then
  NAME_PATH="${REPO_PATH#*/}"
else
  NAME_PATH="${REPO_PATH}"
fi
BASE_NAME="${NAME_PATH##*/}"

if [ -z "${BASE_NAME}" ]; then
  echo "::error::Detected an image tag ('${FIRST_TAG}') in '${INPUT_BAKE_FILE}' but could not derive a base image name from it. Pass image_name explicitly."
  exit 1
fi

echo "Detected image_name '${BASE_NAME}' from bake tag '${FIRST_TAG}'."
emit "${BASE_NAME}"
