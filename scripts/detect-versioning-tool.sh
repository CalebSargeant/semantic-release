#!/usr/bin/env bash
# Resolve the versioning tool for `mode: release`.
#
# When `versioning-tool` is one of the four concrete tools, echo it back
# unchanged. When it is `auto` (the default), inspect the repository under
# `working-directory` for release-tooling markers and pick the tool.
#
# Detection runs in two tiers so an incidental ecosystem file (a Python repo
# that also ships a package.json for docs/tooling, say) never masks the repo's
# real release configuration:
#
#   Tier 1 — authoritative release-tool config. Each marker maps 1:1 to a tool:
#     semantic-release-python  pyproject.toml with a [tool.semantic_release] table
#     semantic-release-npm     .releaserc* / release.config.*
#     gitversion               GitVersion.yml|.yaml (or the configured gitversion-config)
#     release-please           release-please-config.json / .release-please-manifest.json
#                              (or the configured release-please-config-file)
#     Exactly one match wins. Two or more distinct tools means the repo carries
#     conflicting release configs — error and ask the caller to set
#     versioning-tool explicitly.
#
#   Tier 2 — ecosystem manifests (heuristic), consulted only when tier 1 is empty:
#     semantic-release-python  pyproject.toml / setup.py / setup.cfg
#     semantic-release-npm     package.json
#     gitversion               *.csproj / *.sln
#     Exactly one match wins. When several match, a fixed precedence
#     (python -> npm -> gitversion) breaks the tie with a notice. This keeps the
#     common "Python service that also has a package.json" case working, which
#     is what makes flipping the default to `auto` safe for existing consumers.
#
# When nothing matches at all, error with the marker list so the caller knows
# what to add or which value to set.
#
# Required env:
#   INPUT_VERSIONING_TOOL       the versioning-tool input (a concrete tool or `auto`)
# Optional env:
#   WORKING_DIRECTORY           dir to inspect for markers (default `.`)
#   GITVERSION_CONFIG           GitVersion config path (extra tier-1 gitversion signal)
#   RELEASE_PLEASE_CONFIG_FILE  release-please config path (extra tier-1 signal)
#
# Output:
#   Writes `tool=<resolved>` and `config=<gitversion config path>` to
#   $GITHUB_OUTPUT when set; always prints the resolution to stdout.
#
#   `config` is the path the Execute GitVersion step passes to gittools as
#   configFilePath. It carries the ${WORKING_DIRECTORY} prefix, because
#   detection is scoped to working-directory while gittools resolves the path
#   against the workspace root. Empty for every non-gitversion tool, and for a
#   gitversion repo with no config at all (GitVersion then uses its defaults).
#
# Exit codes:
#   0 - a tool was resolved (passthrough or detected)
#   1 - unrecognised explicit tool, conflicting tier-1 configs, or nothing matched

set -euo pipefail

TOOL="${INPUT_VERSIONING_TOOL:-auto}"
WD="${WORKING_DIRECTORY:-.}"
GITVERSION_CONFIG="${GITVERSION_CONFIG:-}"
RELEASE_PLEASE_CONFIG_FILE="${RELEASE_PLEASE_CONFIG_FILE:-}"

VALID="semantic-release-python semantic-release-npm gitversion release-please"

# Join a ${WD}-relative path onto ${WD}. Detection is scoped to
# working-directory, but gittools resolves configFilePath against the workspace
# root, so the path we hand it has to carry the ${WD} prefix. A default WD of
# '.' would otherwise produce './GitVersion.yml'; strip that so the emitted
# value stays the plain 'GitVersion.yml' callers expect to see in logs.
join_wd() {
  local joined="${WD%/}/$1"
  printf '%s' "${joined#./}"
}

# The GitVersion config path to hand to gittools, or empty for "no /config".
#
#   explicit gitversion-config  forwarded even when missing (absolute as-is,
#                               relative joined onto ${WD}), so gittools raises
#                               its own error on a bad path — an explicitly
#                               configured file that does not exist is a bug in
#                               the caller's config, not something to paper over.
#   otherwise                   the discovered root marker under ${WD}, or empty
#                               so GitVersion falls back to its built-in defaults.
resolve_gitversion_config() {
  if [ -n "${GITVERSION_CONFIG}" ]; then
    case "${GITVERSION_CONFIG}" in
      /*) printf '%s' "${GITVERSION_CONFIG}" ;;
      *)  join_wd "${GITVERSION_CONFIG}" ;;
    esac
    return 0
  fi
  if [ -f "${WD}/GitVersion.yml" ]; then
    join_wd "GitVersion.yml"
  elif [ -f "${WD}/GitVersion.yaml" ]; then
    join_wd "GitVersion.yaml"
  fi
}

emit() {
  # $1 = resolved tool
  local config=""
  if [ "$1" = "gitversion" ]; then
    config="$(resolve_gitversion_config)"
  fi
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "tool=$1" >> "${GITHUB_OUTPUT}"
    echo "config=${config}" >> "${GITHUB_OUTPUT}"
  fi
  echo "Resolved versioning-tool: $1"
  if [ "$1" = "gitversion" ]; then
    if [ -n "${config}" ]; then
      echo "GitVersion config: ${config}"
    else
      echo "GitVersion config: none — GitVersion will use its built-in defaults."
    fi
  fi
}

# ── Explicit tool: validate against the known set and pass through unchanged ──
if [ "${TOOL}" != "auto" ]; then
  for v in ${VALID}; do
    if [ "${TOOL}" = "${v}" ]; then
      emit "${TOOL}"
      exit 0
    fi
  done
  echo "::error::versioning-tool '${TOOL}' is not recognised. Expected one of: ${VALID// /, }, or auto."
  exit 1
fi

echo "versioning-tool: auto — detecting from markers in '${WD}'"

# True if a caller-supplied config path exists. A relative path is resolved
# against ${WD} (not the step's CWD, which is the repo root) so an explicit
# gitversion-config / release-please-config-file honours working-directory
# scoping exactly like the fixed-name markers do; an absolute path is used as-is.
config_exists_in_wd() {
  case "$1" in
    /*) [ -f "$1" ] ;;
    *)  [ -f "${WD}/$1" ] ;;
  esac
}

# pyproject.toml declaring a [tool.semantic_release] table (or subtable).
has_psr_config() {
  [ -f "${WD}/pyproject.toml" ] \
    && grep -Eq '^[[:space:]]*\[tool\.semantic_release(\.|\])' "${WD}/pyproject.toml"
}

# A dedicated semantic-release (npm) config file. A package.json-embedded
# "release" key is intentionally not treated as authoritative here — it is
# covered by the tier-2 package.json signal — because detecting it reliably
# needs a JSON parser and a bare grep collides with a `scripts.release` entry.
has_semrel_npm_config() {
  local f
  for f in .releaserc .releaserc.json .releaserc.yaml .releaserc.yml \
           .releaserc.js .releaserc.cjs .releaserc.mjs \
           release.config.js release.config.cjs release.config.mjs; do
    [ -f "${WD}/${f}" ] && return 0
  done
  return 1
}

has_gitversion_config() {
  [ -f "${WD}/GitVersion.yml" ] && return 0
  [ -f "${WD}/GitVersion.yaml" ] && return 0
  [ -n "${GITVERSION_CONFIG}" ] && config_exists_in_wd "${GITVERSION_CONFIG}" && return 0
  return 1
}

has_release_please_config() {
  [ -f "${WD}/release-please-config.json" ] && return 0
  [ -f "${WD}/.release-please-manifest.json" ] && return 0
  [ -n "${RELEASE_PLEASE_CONFIG_FILE}" ] && config_exists_in_wd "${RELEASE_PLEASE_CONFIG_FILE}" && return 0
  return 1
}

# ── Tier 1: authoritative release-tool config (1:1 with a tool) ──
tier1=()
has_psr_config            && tier1+=("semantic-release-python")
has_semrel_npm_config     && tier1+=("semantic-release-npm")
has_gitversion_config     && tier1+=("gitversion")
has_release_please_config && tier1+=("release-please")

if [ "${#tier1[@]}" -eq 1 ]; then
  echo "Matched release config in '${WD}' -> ${tier1[0]}"
  emit "${tier1[0]}"
  exit 0
fi
if [ "${#tier1[@]}" -gt 1 ]; then
  echo "::error::versioning-tool: auto found conflicting release configs (${tier1[*]}) in '${WD}'. Set versioning-tool explicitly to one of: ${VALID// /, }."
  exit 1
fi

# ── Tier 2: ecosystem manifests (heuristic), precedence python -> npm -> gitversion ──
tier2=()
if [ -f "${WD}/pyproject.toml" ] || [ -f "${WD}/setup.py" ] || [ -f "${WD}/setup.cfg" ]; then
  tier2+=("semantic-release-python")
fi
[ -f "${WD}/package.json" ] && tier2+=("semantic-release-npm")
dotnet_project="$(find "${WD}" -maxdepth 3 \( -name '*.csproj' -o -name '*.sln' \) -print -quit 2>/dev/null || true)"
[ -n "${dotnet_project}" ] && tier2+=("gitversion")

if [ "${#tier2[@]}" -eq 1 ]; then
  echo "Matched ecosystem manifest in '${WD}' -> ${tier2[0]}"
  emit "${tier2[0]}"
  exit 0
fi
if [ "${#tier2[@]}" -gt 1 ]; then
  # A repo can legitimately carry more than one ecosystem manifest (a Python
  # service with a package.json for front-end tooling). Break the tie by fixed
  # precedence instead of failing, so the default-`auto` flip is non-breaking.
  for pref in semantic-release-python semantic-release-npm gitversion; do
    for t in "${tier2[@]}"; do
      if [ "${t}" = "${pref}" ]; then
        echo "::notice::versioning-tool: auto found multiple ecosystem manifests (${tier2[*]}) in '${WD}'; choosing '${pref}' by precedence. Set versioning-tool explicitly to override."
        emit "${pref}"
        exit 0
      fi
    done
  done
fi

echo "::error::versioning-tool: auto could not detect a versioning tool in '${WD}'. Looked for: pyproject.toml [tool.semantic_release] / setup.py / setup.cfg (semantic-release-python), .releaserc* / release.config.* / package.json (semantic-release-npm), GitVersion.yml / *.csproj / *.sln (gitversion), release-please-config.json / .release-please-manifest.json (release-please). Set versioning-tool explicitly to one of: ${VALID// /, }."
exit 1
