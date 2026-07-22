#!/usr/bin/env bash
# Resolve, for Diatreme's image workflows (CI image build, image scan, and
# release image promotion), BOTH:
#   1. the base image name (image_name), and
#   2. the build strategy — how the image is actually built.
#
# `image_name` is optional. Diatreme already infers the release environment
# from the deployment model / branch-map; this does the same for the image
# name so callers don't have to bolt on a bespoke pre-step just to compute it.
#
# Build strategy (emitted as `strategy`, with the resolved `bake_file`):
#   - bake       — a Docker Bake file exists (docker-bake.hcl, or docker-bake.json
#                  when the default file name is in play). Build via
#                  `docker buildx bake` — historical behaviour, unchanged.
#   - dockerfile — no bake file, but a Dockerfile exists. Build it directly with
#                  `docker buildx build`. This is the zero-config path for the
#                  simplest consumer (one Dockerfile, no bake file); a warning
#                  nudges them toward a bake file for multi-target / multi-arch
#                  builds and local↔CI parity.
#   - none       — neither a bake file nor a Dockerfile. Nothing to build.
#
# image_name precedence:
#   1. Explicit INPUT_IMAGE_NAME wins, verbatim — historical behavior, unchanged.
#   2. Otherwise, if detection is opted out (DETECT_IMAGE_NAME != "true") leave
#      it empty — the image steps skip, exactly as before this feature existed.
#      This is the escape hatch for a repo that keeps a tagged docker-bake.hcl
#      but runs Diatreme for versioning only (no image build/promotion).
#   3. Otherwise, strategy=bake: derive the base image name from the first
#      non-empty target tag rendered by `docker buildx bake --print` (the same
#      bake file + target the build/promote steps use).
#   4. Otherwise, strategy=dockerfile: fall back to the repository's own short
#      name (lowercased) as the base image name — the natural default when there
#      is no bake file to template tags from.
#   5. Otherwise (strategy=none) leave it empty — versioning-only / non-image
#      workflows are unaffected because the consuming steps gate on a non-empty
#      resolved name and simply skip.
#
# A bake file that exists but yields no tags is a hard error (when detection is
# on): Diatreme never silently falls back to the repository name for the *bake*
# path — a tagless bake target is a misconfiguration, not a zero-config repo.
# The repository-name fallback (rule 4) applies only when there is genuinely no
# bake file and a Dockerfile is present.
#
# Required env:
#   INPUT_BAKE_FILE   - path to the Docker Bake file (e.g. docker-bake.hcl).
#   INPUT_BAKE_TARGET - bake target or group to inspect (e.g. default).
#
# Optional env:
#   INPUT_IMAGE_NAME  - explicit base image name; wins when non-empty.
#   INPUT_DOCKERFILE  - path to the Dockerfile for the no-bake fallback
#                       (default "Dockerfile").
#   INPUT_REPO_FULL   - "owner/name" (github.repository); the repository-name
#                       fallback derives the base name from "name".
#   DETECT_IMAGE_NAME - "true" (default) to auto-detect from the bake file /
#                       repository name when INPUT_IMAGE_NAME is empty; any other
#                       value opts out of detection (image_name stays empty,
#                       image steps skip).
#   DIATREME_DOCS_URL - docs link surfaced in the no-bake warning.
#   BAKE_GITHUB_TOKEN - inherited by `docker buildx bake --print` so the printed
#                       target set matches the build/promote steps (only matters
#                       if the bake file gates targets on that secret).
#
# Side effects:
#   Writes `image_name=<value>` (value may be empty), `strategy=<bake|dockerfile|none>`,
#   and `bake_file=<effective bake file>` to $GITHUB_OUTPUT. Emits a GitHub
#   Actions warning when the Dockerfile path is taken.
#
# Exit codes:
#   0 - resolved (the value may be empty when there is nothing to resolve)
#   1 - a bake file exists but no image tag could be derived from it

set -euo pipefail

INPUT_IMAGE_NAME="${INPUT_IMAGE_NAME:-}"
INPUT_BAKE_FILE="${INPUT_BAKE_FILE:-docker-bake.hcl}"
INPUT_BAKE_TARGET="${INPUT_BAKE_TARGET:-default}"
INPUT_DOCKERFILE="${INPUT_DOCKERFILE:-Dockerfile}"
INPUT_REPO_FULL="${INPUT_REPO_FULL:-}"
DETECT_IMAGE_NAME="${DETECT_IMAGE_NAME:-true}"
DIATREME_DOCS_URL="${DIATREME_DOCS_URL:-https://magmamoose.github.io/diatreme/action/#docker-build-definition}"

emit() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >> "${GITHUB_OUTPUT}"
  fi
}

# ── Resolve the build strategy + effective bake file (from files on disk) ─────
# Match buildx's own lookup order for the two file names Diatreme supports: the
# configured bake file first, then docker-bake.json when the *default* file name
# is in play and the .hcl is absent. A caller that set an explicit bake_file gets
# exactly that file (no json guessing). File checks only — no Docker needed.
STRATEGY="none"
BAKE_FILE="${INPUT_BAKE_FILE}"
if [ -f "${INPUT_BAKE_FILE}" ]; then
  STRATEGY="bake"
  BAKE_FILE="${INPUT_BAKE_FILE}"
elif [ "${INPUT_BAKE_FILE}" = "docker-bake.hcl" ] && [ -f "docker-bake.json" ]; then
  STRATEGY="bake"
  BAKE_FILE="docker-bake.json"
elif [ -f "${INPUT_DOCKERFILE}" ]; then
  STRATEGY="dockerfile"
fi

emit strategy "${STRATEGY}"
emit bake_file "${BAKE_FILE}"

# Repository short name (lowercased) — the base image name for the no-bake
# Dockerfile fallback. Docker repository names must be lowercase.
REPO_NAME="${INPUT_REPO_FULL##*/}"
REPO_NAME="$(printf '%s' "${REPO_NAME}" | tr '[:upper:]' '[:lower:]')"

warn_dockerfile() {
  echo "::warning title=No docker-bake.hcl::No Docker Bake file found; building '${INPUT_DOCKERFILE}' directly with 'docker buildx build'. This is fine for a single-image, single-Dockerfile repo. Add a docker-bake.hcl for multi-target builds, tag templating, multi-arch defaults, and local↔CI build parity (docker buildx bake). See ${DIATREME_DOCS_URL}"
}

# 1) Explicit input wins, verbatim — even with detection opted out, and even
#    when there is no bake file. Strategy is still emitted above so the build
#    steps know whether to bake or build the Dockerfile.
if [ -n "${INPUT_IMAGE_NAME}" ]; then
  echo "image_name provided explicitly: '${INPUT_IMAGE_NAME}'."
  emit image_name "${INPUT_IMAGE_NAME}"
  [ "${STRATEGY}" = "dockerfile" ] && warn_dockerfile
  exit 0
fi

# 2) Detection opted out — leave image_name empty so image steps skip, exactly
#    as before auto-detection existed. Escape hatch for repos that keep a tagged
#    bake file but use Diatreme for versioning only.
if [ "${DETECT_IMAGE_NAME}" != "true" ]; then
  echo "No image_name provided and detect-image-name is '${DETECT_IMAGE_NAME}' (not 'true') — leaving image_name empty (image steps skipped)."
  emit image_name ""
  exit 0
fi

# 3) No explicit name, no bake file. When a Dockerfile is present, fall back to
#    the repository's short name; otherwise there is nothing to build.
if [ "${STRATEGY}" != "bake" ]; then
  if [ "${STRATEGY}" = "dockerfile" ]; then
    if [ -z "${REPO_NAME}" ]; then
      echo "::error::A Dockerfile ('${INPUT_DOCKERFILE}') is present but no image_name was given and the repository name could not be derived (INPUT_REPO_FULL empty). Pass image_name explicitly."
      exit 1
    fi
    echo "No image_name provided and no bake file — using repository name '${REPO_NAME}' for the Dockerfile build."
    emit image_name "${REPO_NAME}"
    warn_dockerfile
    exit 0
  fi
  echo "No image_name provided, no bake file at '${INPUT_BAKE_FILE}', and no Dockerfile at '${INPUT_DOCKERFILE}' — leaving image_name empty (non-image workflow)."
  emit image_name ""
  exit 0
fi

echo "No image_name provided — detecting from Docker Bake (file '${BAKE_FILE}', target '${INPUT_BAKE_TARGET}')."

# Render the bake definition. `--print` evaluates the HCL and prints JSON; it
# never builds, so it needs no builder instance. BAKE_GITHUB_TOKEN is inherited
# from the environment so the printed targets match the build/promote steps.
BAKE_ERR="$(mktemp)"
trap 'rm -f "${BAKE_ERR}"' EXIT
if ! BAKE_JSON="$(docker buildx bake -f "${BAKE_FILE}" "${INPUT_BAKE_TARGET}" --print 2>"${BAKE_ERR}")"; then
  echo "::error::Could not evaluate Docker Bake file '${BAKE_FILE}' (target '${INPUT_BAKE_TARGET}') to detect image_name. Pass image_name explicitly, or fix the bake file. Details: $(tr '\n' ' ' < "${BAKE_ERR}" | head -c 300)"
  exit 1
fi

# First non-empty tag across every rendered target. For a multi-target bake
# group with distinct images this resolves to whichever target sorts first in
# `bake --print`, yielding a single base name — consistent with Diatreme's
# single-IMAGE_NAME model (an explicit image_name was single too). The resolved
# name only gates the image steps and sets the IMAGE_NAME bake var; the scan and
# promote steps still enumerate every target from the bake tags directly, so
# multi-image builds are not collapsed to one image downstream.
FIRST_TAG="$(printf '%s' "${BAKE_JSON}" | jq -r '[ (.target // {})[].tags[]? | select(. != null and . != "") ] | .[0] // empty' 2>/dev/null || true)"

if [ -z "${FIRST_TAG}" ]; then
  echo "::error::Docker Bake file '${BAKE_FILE}' (target '${INPUT_BAKE_TARGET}') produced no image tags, so image_name cannot be detected. Add a tag to the bake target, or pass image_name explicitly. Diatreme does not fall back to the repository name."
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
  echo "::error::Detected an image tag ('${FIRST_TAG}') in '${BAKE_FILE}' but could not derive a base image name from it. Pass image_name explicitly."
  exit 1
fi

echo "Detected image_name '${BASE_NAME}' from bake tag '${FIRST_TAG}'."
emit image_name "${BASE_NAME}"
