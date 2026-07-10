#!/usr/bin/env bash
# Run python-semantic-release's `version` command from a throwaway venv.
#
# Why not `uses: python-semantic-release/python-semantic-release@<sha>`?
# Upstream ships only a *Docker* action whose image is built from a Dockerfile
# in their repo (`runs.image: src/gh_action/Dockerfile`) — they publish no
# pre-built image, so `docker://` is not an option. GitHub Actions builds the
# image of every Docker action a composite action references during job setup:
# before any step runs, and regardless of the step's `if:` condition. Every
# Diatreme release run therefore spent ~1 minute on a `Build
# python-semantic-release/python-semantic-release@...` step, even on repos that
# resolve to gitversion / release-please and skip the psr step entirely.
#
# This reproduces upstream's entrypoint (src/gh_action/action.sh) for exactly
# the inputs action.yml passed it. The CLI itself writes the GitHub Actions
# outputs (released, version, tag, is_prerelease, link, previous_version,
# commit_sha, release_notes) to $GITHUB_OUTPUT whenever that variable is set,
# so the calling step exposes the same outputs the Docker action did.
#
# Required env:
#   GH_TOKEN                 token psr uses to push commits/tags and call the API
#   PSR_VERSION              python-semantic-release version to install
#   PYTHON_BIN               interpreter used to create the venv
#
# Optional env (named after the upstream action inputs they replace):
#   INPUT_PRERELEASE         'true' → --as-prerelease; 'false'/'' → omitted
#   INPUT_PRERELEASE_TOKEN   non-empty → --prerelease-token <value>
#   INPUT_FORCE              prerelease|patch|minor|major → --<value>; '' → omitted
#   INPUT_CHANGELOG          'true' → --changelog; 'false' → --no-changelog
#   INPUT_GIT_COMMITTER_NAME committer name for the repo's git config
#   PSR_BIN                  path to an existing `semantic-release`; skips the
#                            venv + pip install. Used by the bats suite to
#                            assert the argv this script builds.
#
# Three flags are fixed rather than plumbed through, matching the `commit`,
# `vcs_release` and `build` values action.yml pinned on the Docker action:
#   --commit          stage + commit the version bump and changelog
#   --no-vcs-release  the Publish GitHub Release step creates the release later,
#                     after image promotion, so `release:published` listeners
#                     see the versioned image in the registry
#   --skip-build      Diatreme builds and publishes packages itself
# `--tag` and `--push` are left at psr's defaults (both on), so the tag still
# lands on the remote for the rest of the pipeline to work with.
#
# Exit code: whatever `semantic-release version` returns.

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

# psr reads the token from $GH_TOKEN; it must be in the child's environment.
export GH_TOKEN

# Convert a 'true'/'false'/'' action input into a CLI flag. An empty value
# yields nothing, leaving psr's own default in charge.
bool_flag() {
  local name="$1" value="$2" if_true="$3" if_false="$4"
  case "${value}" in
    "")      : ;;
    true)    printf '%s' "${if_true}"  ;;
    false)   printf '%s' "${if_false}" ;;
    *)
      echo "::error::Invalid value for ${name}: '${value}' is not 'true' or 'false'" >&2
      return 1
      ;;
  esac
  return 0
}

if [ -z "${PSR_BIN:-}" ]; then
  : "${PSR_VERSION:?PSR_VERSION is required}"
  : "${PYTHON_BIN:?PYTHON_BIN is required}"

  # A venv keeps the install off the runner's Python, which on recent Ubuntu
  # images is PEP 668 externally-managed and rejects a bare `pip install`.
  VENV_DIR="${RUNNER_TEMP:-/tmp}/diatreme-psr-venv"
  echo "Installing python-semantic-release==${PSR_VERSION} into ${VENV_DIR}"
  "${PYTHON_BIN}" -m venv "${VENV_DIR}"
  "${VENV_DIR}/bin/python" -m pip install --disable-pip-version-check --quiet \
    "python-semantic-release==${PSR_VERSION}"
  PSR_BIN="${VENV_DIR}/bin/semantic-release"
fi

# Upstream's entrypoint sets `git config --global user.name`. Local repo config
# outranks global, so writing it locally *only when unset* is the faithful
# emulation: a caller who configured their own identity keeps it either way.
# psr overrides both anyway for the commits and tags it makes — it exports
# GIT_AUTHOR_NAME/GIT_COMMITTER_NAME from its own `commit_author` setting.
if [ -n "${INPUT_GIT_COMMITTER_NAME:-}" ] && ! git config --get user.name >/dev/null 2>&1; then
  git config user.name "${INPUT_GIT_COMMITTER_NAME}"
fi

# `-v` is the root-level verbosity psr's action defaults to (verbosity: 1).
ARGS=(-v version --commit --no-vcs-release --skip-build)

# psr renamed this flag in v10: the action's `prerelease` input maps to
# `--as-prerelease` ("release the next version as a prerelease"), not to
# `--prerelease` (which is a forced prerelease-revision bump, see INPUT_FORCE).
PRERELEASE_FLAG=$(bool_flag prerelease "${INPUT_PRERELEASE:-}" "--as-prerelease" "")
if [ -n "${PRERELEASE_FLAG}" ]; then
  ARGS+=("${PRERELEASE_FLAG}")
fi

CHANGELOG_FLAG=$(bool_flag changelog "${INPUT_CHANGELOG:-}" "--changelog" "--no-changelog")
if [ -n "${CHANGELOG_FLAG}" ]; then
  ARGS+=("${CHANGELOG_FLAG}")
fi

# An unrecognised force level is a caller typo, not a reason to abort a release:
# warn and let the commit messages decide the bump, as upstream's entrypoint does.
case "${INPUT_FORCE:-}" in
  "")                           : ;;
  prerelease|patch|minor|major) ARGS+=("--${INPUT_FORCE}") ;;
  *)
    echo "::warning::Ignoring force-bump '${INPUT_FORCE}': expected one of prerelease, patch, minor, major"
    ;;
esac

if [ -n "${INPUT_PRERELEASE_TOKEN:-}" ]; then
  ARGS+=(--prerelease-token "${INPUT_PRERELEASE_TOKEN}")
fi

echo "\$ ${PSR_BIN} ${ARGS[*]}"
exec "${PSR_BIN}" "${ARGS[@]}"
