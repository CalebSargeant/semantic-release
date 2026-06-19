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
#   ECOSYSTEM   - nuget | pip | npm | maven | gradle | rubygems | container
#   VERSION     - semver to publish (e.g. 1.2.3 or 1.2.3-rc.1)
#   TOKEN       - auth token / API key for the feed
#
# Optional env:
#   FEED_URL              - feed/registry URL. Defaults per-ecosystem (GitHub
#                           Packages NuGet for OWNER / PyPI / npmjs.org).
#   PACKAGE_PATH          - project file or directory to pack/build/publish.
#                           Defaults to WORKING_DIRECTORY, then '.'.
#   WORKING_DIRECTORY     - base directory (the action's working-directory).
#   USERNAME              - feed/login username. pip/twine default '__token__';
#                           maven/gradle/rubygems/container login default
#                           'x-access-token'. Ignored by nuget and npm.
#   OWNER                 - repo owner, used to derive GitHub Packages URLs.
#   REPOSITORY            - owner/repo (github.repository). The default maven
#                           feed and container image name are derived from it.
#   PACKAGE_NAME          - container image name override (defaults to
#                           REPOSITORY lowercased). Ignored by the others.
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

# Run a publish command, treating an "already published / version exists"
# conflict as success — GitHub Packages (and npmjs) reject overwriting a
# released version, so a re-run must be a no-op, not a hard failure. $1 is an
# extended-regex of conflict messages to tolerate; the rest is the command.
run_publish() {
  local conflict_re="$1"; shift
  local err rc=0
  err="$(mktemp)"
  "$@" 2>"${err}" || rc=$?
  cat "${err}" >&2
  if [ "${rc}" -ne 0 ]; then
    if grep -qiE "${conflict_re}" "${err}"; then
      echo "Already published — idempotent re-run, treating as success."
    else
      rm -f "${err}"
      return "${rc}"
    fi
  fi
  rm -f "${err}"
  return 0
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
    # npm publish errors if the version already exists; tolerate that so re-runs
    # are idempotent like the nuget/twine paths.
    run_publish 'cannot publish over|previously published|EPUBLISHCONFLICT' \
      npm "${PUBLISH_ARGS[@]}"
    ;;

  maven)
    : "${TOKEN:?TOKEN is required for maven publishing}"
    POM="${TARGET:-${BASE_DIR}}"
    [ -d "${POM}" ] && POM="${POM%/}/pom.xml"
    if [ ! -f "${POM}" ]; then
      echo "::error::maven: no pom.xml at '${POM}'. Point package-path at the project dir or its pom.xml."
      exit 1
    fi
    FEED="${FEED_URL:-}"
    if [ -z "${FEED}" ]; then
      if [ -z "${REPOSITORY:-}" ]; then
        echo "::error::package-feed-url is empty and the repository (owner/repo) is unknown; cannot derive a GitHub Packages Maven feed."
        exit 1
      fi
      FEED="https://maven.pkg.github.com/${REPOSITORY}"
      echo "No package-feed-url set — defaulting to GitHub Packages: ${FEED}"
    fi
    # Per-run settings.xml with the feed credentials (server id 'github' matches
    # the altDeploymentRepository id below). Written outside the project tree and
    # removed on exit so the token isn't left on disk.
    SETTINGS="$(mktemp)"
    trap 'rm -f "${SETTINGS}"' EXIT
    cat > "${SETTINGS}" <<XML
<settings>
  <servers>
    <server>
      <id>github</id>
      <username>${USERNAME:-x-access-token}</username>
      <password>${TOKEN}</password>
    </server>
  </servers>
</settings>
XML
    echo "mvn deploy '${POM}' → ${FEED} (version ${VERSION})"
    mvn --batch-mode --no-transfer-progress -f "${POM}" \
      versions:set -DnewVersion="${VERSION}" -DgenerateBackupPoms=false
    # altDeploymentRepository in the 'id::url' form (Maven 3.9+, the runner default).
    run_publish '409|status code: ?409|already exists|cannot be deployed|Conflict' \
      mvn --batch-mode --no-transfer-progress -f "${POM}" --settings "${SETTINGS}" \
        -DskipTests -DaltDeploymentRepository="github::${FEED}" deploy
    ;;

  gradle)
    : "${TOKEN:?TOKEN is required for gradle publishing}"
    PROJECT_DIR="${TARGET:-${BASE_DIR}}"
    [ -f "${PROJECT_DIR}" ] && PROJECT_DIR="$(dirname "${PROJECT_DIR}")"
    cd "${PROJECT_DIR}" || { echo "::error::gradle project dir '${PROJECT_DIR}' not found."; exit 1; }
    GRADLE_BIN="gradle"
    [ -x ./gradlew ] && GRADLE_BIN="./gradlew"
    # Gradle publishing is defined by the project's maven-publish block. Pass the
    # version (-Pversion) and the credentials the GitHubPackages repository
    # conventionally reads — GITHUB_ACTOR/GITHUB_TOKEN and the gpr.* project
    # properties — via env so they never reach argv.
    echo "${GRADLE_BIN} publish (version ${VERSION}) → ${FEED_URL:-GitHub Packages (maven)}"
    run_publish '409|Conflict|already exists|received status code 409' \
      env GITHUB_ACTOR="${USERNAME:-x-access-token}" GITHUB_TOKEN="${TOKEN}" \
          ORG_GRADLE_PROJECT_gprUser="${USERNAME:-x-access-token}" \
          ORG_GRADLE_PROJECT_gprToken="${TOKEN}" \
          ORG_GRADLE_PROJECT_githubToken="${TOKEN}" \
        "${GRADLE_BIN}" --no-daemon publish -Pversion="${VERSION}"
    ;;

  rubygems)
    : "${TOKEN:?TOKEN is required for rubygems publishing}"
    FEED="${FEED_URL:-}"
    if [ -z "${FEED}" ]; then
      if [ -z "${OWNER_LOWER}" ]; then
        echo "::error::package-feed-url is empty and the repository owner is unknown; cannot derive a GitHub Packages RubyGems host."
        exit 1
      fi
      FEED="https://rubygems.pkg.github.com/${OWNER_LOWER}"
      echo "No package-feed-url set — defaulting to GitHub Packages: ${FEED}"
    fi
    SRC_DIR="${TARGET:-${BASE_DIR}}"
    [ -f "${SRC_DIR}" ] && SRC_DIR="$(dirname "${SRC_DIR}")"
    cd "${SRC_DIR}" || { echo "::error::rubygems project dir '${SRC_DIR}' not found."; exit 1; }
    shopt -s nullglob
    GEMSPECS=(*.gemspec)
    shopt -u nullglob
    if [ "${#GEMSPECS[@]}" -eq 0 ]; then
      echo "::error::rubygems: no .gemspec in '${SRC_DIR}'. The gemspec must carry the released version."
      exit 1
    fi
    GEM_OUT="$(mktemp -d)"
    for spec in "${GEMSPECS[@]}"; do
      echo "gem build '${spec}'"
      gem build "${spec}" --output "${GEM_OUT}/$(basename "${spec%.gemspec}").gem"
    done
    for gem in "${GEM_OUT}"/*.gem; do
      echo "gem push '$(basename "${gem}")' → ${FEED}"
      # API key via env (off argv); 'Bearer <token>' is what GitHub Packages wants.
      run_publish 'already exists|already been pushed|conflict|status: ?422' \
        env GEM_HOST_API_KEY="Bearer ${TOKEN}" gem push --host "${FEED}" "${gem}"
    done
    ;;

  container)
    : "${TOKEN:?TOKEN is required for container publishing}"
    REGISTRY="${FEED_URL:-ghcr.io}"
    REGISTRY="${REGISTRY#http://}"; REGISTRY="${REGISTRY#https://}"; REGISTRY="${REGISTRY%/}"
    IMAGE_NAME="${PACKAGE_NAME:-}"
    [ -z "${IMAGE_NAME}" ] && IMAGE_NAME="$(printf '%s' "${REPOSITORY:-${OWNER_LOWER}}" | tr '[:upper:]' '[:lower:]')"
    if [ -z "${IMAGE_NAME}" ]; then
      echo "::error::container: cannot determine the image name. Set package-name (or provide the repository)."
      exit 1
    fi
    CONTEXT="${TARGET:-${BASE_DIR}}"
    IMAGE_REF="${REGISTRY}/${IMAGE_NAME}:${VERSION}"
    echo "docker login ${REGISTRY}"
    printf '%s' "${TOKEN}" | docker login "${REGISTRY}" --username "${USERNAME:-x-access-token}" --password-stdin
    echo "docker build + push → ${IMAGE_REF}"
    docker build --tag "${IMAGE_REF}" "${CONTEXT}"
    # docker push overwrites a mutable tag, so a re-run is naturally idempotent.
    docker push "${IMAGE_REF}"
    ;;

  '')
    echo "::error::publish-package is true but package-ecosystem is empty. Set package-ecosystem to nuget, pip, npm, maven, gradle, rubygems, or container."
    exit 1
    ;;

  *)
    echo "::error::Unsupported package-ecosystem '${ECOSYSTEM}'. Use nuget, pip, npm, maven, gradle, rubygems, or container."
    exit 1
    ;;
esac

echo "Published ${ECOSYSTEM} package version ${VERSION}."
emit_published "true"
