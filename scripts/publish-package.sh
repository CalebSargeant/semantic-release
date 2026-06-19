#!/usr/bin/env bash
# Pack and publish a language package to a configurable feed.
#
# Called by the "Publish package" step in action.yml (mode: release), gated on
# `released == 'true'`, after Docker image promotion and before the GitHub
# Release is published — so a downstream `release:published` listener finds the
# package already available in the feed (same ordering rationale as the image
# promote step).
#
# The published version is the one diatreme already computed (VERSION). The
# prerelease/stable distinction is encoded in that string (e.g. 1.2.3-rc.1) and
# each diatreme run targets a single environment, so environment/branch gating
# is inherited from the caller's versioning gate — dev/staging runs publish
# prerelease versions, prod runs publish stable versions, all on `released`.
#
# Required env:
#   ECOSYSTEM   - nuget | pip | npm
#   VERSION     - semver to publish (e.g. 1.2.3 or 1.2.3-rc.1)
#   TOKEN       - auth token / API key for the feed
#
# Optional env:
#   FEED_URL              - feed/registry URL. Defaults per-ecosystem (GitHub
#                           Packages NuGet for OWNER / PyPI / npmjs.org).
#   PACKAGE_PATH          - project file or directory to pack/build/publish.
#                           Defaults to WORKING_DIRECTORY, then '.'.
#   WORKING_DIRECTORY     - base directory (the action's working-directory).
#   USERNAME              - feed username (pip/twine only). Defaults to
#                           '__token__'. Ignored by nuget and npm.
#   OWNER                 - repo owner, used to derive GitHub Packages URLs.
#   IS_PRERELEASE         - true | false (selects the npm dist-tag).
#   PRERELEASE_IDENTIFIER - e.g. dev, rc; npm dist-tag for prereleases
#                           (falls back to 'next').
#
# Side effects:
#   - Writes `published=true|false` to $GITHUB_OUTPUT when that var is set.
#   - Masks TOKEN in the workflow log.
#
# Exit codes:
#   0 - package published (re-runs are idempotent: nuget --skip-duplicate,
#       twine --skip-existing, npm tolerates an already-published version)
#   1 - misconfiguration or a publish error

set -euo pipefail

# ECOSYSTEM is validated by the case statement below (the '' branch gives an
# actionable message) so an empty package-ecosystem input doesn't trip the
# generic `set -u` unbound-variable error first.
: "${VERSION:?VERSION is required}"

# Mask the token in any log output before we do anything with it.
if [ -n "${TOKEN:-}" ]; then
  echo "::add-mask::${TOKEN}"
fi

emit_published() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "published=$1" >> "${GITHUB_OUTPUT}"
  fi
}

OWNER_LOWER="$(printf '%s' "${OWNER:-}" | tr '[:upper:]' '[:lower:]')"
BASE_DIR="${WORKING_DIRECTORY:-.}"
[ -z "${BASE_DIR}" ] && BASE_DIR="."
TARGET="${PACKAGE_PATH:-}"
IS_PRERELEASE="${IS_PRERELEASE:-false}"

case "${ECOSYSTEM:-}" in
  nuget)
    : "${TOKEN:?TOKEN is required for nuget publishing}"
    FEED="${FEED_URL:-}"
    if [ -z "${FEED}" ]; then
      if [ -z "${OWNER_LOWER}" ]; then
        echo "::error::package-feed-url is empty and the repository owner is unknown; cannot derive a GitHub Packages NuGet feed."
        exit 1
      fi
      FEED="https://nuget.pkg.github.com/${OWNER_LOWER}/index.json"
      echo "No package-feed-url set — defaulting to GitHub Packages: ${FEED}"
    fi

    PROJECT="${TARGET:-${BASE_DIR}}"
    OUT_DIR="$(mktemp -d)"

    echo "dotnet pack '${PROJECT}' → ${VERSION}"
    dotnet pack "${PROJECT}" \
      --configuration Release \
      -p:Version="${VERSION}" \
      -p:PackageVersion="${VERSION}" \
      --output "${OUT_DIR}"

    shopt -s nullglob
    PKGS=("${OUT_DIR}"/*.nupkg)
    shopt -u nullglob
    if [ "${#PKGS[@]}" -eq 0 ]; then
      echo "::error::dotnet pack produced no .nupkg files in ${OUT_DIR}. Check that '${PROJECT}' is a packable project (<IsPackable> not false)."
      exit 1
    fi

    for pkg in "${PKGS[@]}"; do
      echo "dotnet nuget push '$(basename "${pkg}")' → ${FEED}"
      # --skip-duplicate makes re-runs (or a parallel run that already
      # pushed this version) a no-op instead of a hard failure.
      dotnet nuget push "${pkg}" \
        --source "${FEED}" \
        --api-key "${TOKEN}" \
        --skip-duplicate
    done
    ;;

  pip)
    : "${TOKEN:?TOKEN is required for pip publishing}"
    FEED="${FEED_URL:-}"          # empty → PyPI default
    USER="${USERNAME:-}"
    [ -z "${USER}" ] && USER="__token__"
    SRC_DIR="${TARGET:-${BASE_DIR}}"
    # Build into a fresh temp dir (not ${SRC_DIR}/dist) so only this run's
    # artifacts are uploaded — a pre-existing/checked-in dist/ would otherwise
    # get swept up by the glob below. Mirrors the nuget path's mktemp -d.
    DIST_DIR="$(mktemp -d)/dist"

    echo "python -m build '${SRC_DIR}'"
    python -m pip install --upgrade build twine >/dev/null
    # The built version comes from the project metadata (pyproject.toml /
    # setup.py). semantic-release-python bumps and commits that before this
    # step, so the build matches VERSION; with other tools, persist VERSION
    # into the project (e.g. the action's `version-file` input) first.
    python -m build --outdir "${DIST_DIR}" "${SRC_DIR}"

    shopt -s nullglob
    DISTS=("${DIST_DIR}"/*)
    shopt -u nullglob
    if [ "${#DISTS[@]}" -eq 0 ]; then
      echo "::error::python -m build produced no artifacts in ${DIST_DIR}."
      exit 1
    fi

    UPLOAD_ARGS=(upload --non-interactive --skip-existing)
    if [ -n "${FEED}" ]; then
      UPLOAD_ARGS+=(--repository-url "${FEED}")
      echo "twine upload → ${FEED}"
    else
      echo "twine upload → PyPI"
    fi
    UPLOAD_ARGS+=("${DISTS[@]}")
    # Credentials via env so they never appear in argv/process listings.
    TWINE_USERNAME="${USER}" TWINE_PASSWORD="${TOKEN}" \
      python -m twine "${UPLOAD_ARGS[@]}"
    ;;

  npm)
    : "${TOKEN:?TOKEN is required for npm publishing}"
    FEED="${FEED_URL:-}"
    [ -z "${FEED}" ] && FEED="https://registry.npmjs.org"
    PKG_DIR="${TARGET:-${BASE_DIR}}"
    # Accept a package.json path as well as a directory.
    if [ -f "${PKG_DIR}" ]; then
      PKG_DIR="$(dirname "${PKG_DIR}")"
    fi
    cd "${PKG_DIR}" || { echo "::error::npm package directory '${PKG_DIR}' not found."; exit 1; }

    # Strip the scheme to the //host/path form npm uses for _authToken, and
    # drop any trailing slash so the key matches the registry npm computes.
    REG_KEY="$(printf '%s' "${FEED}" | sed -E 's#^[a-zA-Z]+:##; s#/+$##')"
    # Write auth to a throwaway userconfig outside the working tree (removed on
    # exit) instead of appending it to a .npmrc in the package dir — the latter
    # leaves the token on disk in the checkout and could clobber an existing
    # .npmrc.
    NPMRC="$(mktemp)"
    trap 'rm -f "${NPMRC}"' EXIT
    {
      echo "registry=${FEED}"
      echo "${REG_KEY}/:_authToken=${TOKEN}"
    } > "${NPMRC}"
    export npm_config_userconfig="${NPMRC}"

    # Align package.json with the released version (no-op if already there).
    npm version "${VERSION}" --no-git-tag-version --allow-same-version >/dev/null

    PUBLISH_ARGS=(publish --registry "${FEED}")
    if [ "${IS_PRERELEASE}" = "true" ]; then
      # Keep prereleases off the default `latest` dist-tag so consumers don't
      # pick them up implicitly. Use the environment's prerelease identifier
      # (dev, rc, …) as the tag, falling back to `next`.
      DIST_TAG="${PRERELEASE_IDENTIFIER:-next}"
      [ -z "${DIST_TAG}" ] && DIST_TAG="next"
      PUBLISH_ARGS+=(--tag "${DIST_TAG}")
      echo "npm publish → ${FEED} (dist-tag: ${DIST_TAG})"
    else
      echo "npm publish → ${FEED} (dist-tag: latest)"
    fi
    # npm publish isn't natively idempotent — it errors if the version already
    # exists — so tolerate that specific conflict to match the nuget
    # (--skip-duplicate) and twine (--skip-existing) re-run behaviour.
    PUBLISH_ERR="$(mktemp)"
    NPM_STATUS=0
    npm "${PUBLISH_ARGS[@]}" 2>"${PUBLISH_ERR}" || NPM_STATUS=$?
    cat "${PUBLISH_ERR}" >&2
    if [ "${NPM_STATUS}" -ne 0 ]; then
      if grep -qiE 'cannot publish over|previously published|EPUBLISHCONFLICT' "${PUBLISH_ERR}"; then
        echo "npm: version ${VERSION} already published — idempotent re-run, treating as success."
      else
        rm -f "${PUBLISH_ERR}"
        exit 1
      fi
    fi
    rm -f "${PUBLISH_ERR}"
    ;;

  '')
    echo "::error::publish-package is true but package-ecosystem is empty. Set package-ecosystem to nuget, pip, or npm."
    exit 1
    ;;

  *)
    echo "::error::Unsupported package-ecosystem '${ECOSYSTEM}'. Use nuget, pip, or npm."
    exit 1
    ;;
esac

echo "Published ${ECOSYSTEM} package version ${VERSION}."
emit_published "true"
