#!/usr/bin/env bash
# Compute a forced next version by bumping the latest stable tag.
#
# Used by the semantic-release-npm paths in action.yml when the
# `force-bump` input is set: semantic-release has no per-run force knob,
# so instead of letting commit analysis decide (which yields "no release"
# when there are no qualifying conventional commits), the requested
# patch/minor/major increment is applied to the most recent stable
# (non-prerelease) tag directly.
#
# Required env:
#   FORCE_BUMP  - bump level: patch | minor | major
#
# Optional env:
#   TAG_PREFIX  - tag prefix the repository releases under (e.g. "v").
#                 Only tags that start with this prefix and parse as a
#                 bare X.Y.Z after stripping it are considered, so
#                 prerelease tags (v1.2.3-rc.1) and unrelated tags never
#                 become the bump base. Defaults to empty.
#
# Output:
#   Prints the bumped bare version (no prefix) to stdout, e.g. "1.2.4".
#   Callers capture stdout, so all diagnostics go to stderr.
#   When the repository has no stable tag yet the bump is applied to
#   0.0.0 (patch → 0.0.1, minor → 0.1.0, major → 1.0.0).
#
# Exit codes:
#   0 - bumped version printed
#   1 - FORCE_BUMP missing or not one of patch|minor|major

set -euo pipefail

: "${FORCE_BUMP:?FORCE_BUMP is required}"
PREFIX="${TAG_PREFIX:-}"

case "${FORCE_BUMP}" in
  patch|minor|major) ;;
  *)
    echo "::error::force-bump '${FORCE_BUMP}' is not supported; expected patch, minor, or major." >&2
    exit 1
    ;;
esac

# Latest stable tag: match the prefix as a glob, strip it as a literal
# string, and keep only exact X.Y.Z remainders. Semver-strict: a
# leading-zero component (v1.08.3) is junk, not a bump base — bash
# arithmetic would parse it as octal and quietly not bump. `sort -V`
# picks the highest so 1.10.0 beats 1.9.0 (lexical sort would not).
BASE=$(git tag -l "${PREFIX}*" | while IFS= read -r tag; do
  rest="${tag#"${PREFIX}"}"
  if [[ "${rest}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    printf '%s\n' "${rest}"
  fi
done | sort -V | tail -1)

if [ -z "${BASE}" ]; then
  BASE="0.0.0"
  echo "No stable tag matching '${PREFIX}X.Y.Z' found; bumping from 0.0.0." >&2
fi

IFS=. read -r MAJOR MINOR PATCH <<< "${BASE}"
case "${FORCE_BUMP}" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
esac

echo "Forced ${FORCE_BUMP} bump: ${BASE} → ${MAJOR}.${MINOR}.${PATCH}" >&2
echo "${MAJOR}.${MINOR}.${PATCH}"
