#!/usr/bin/env bash
# Persist the released version into the tracked file(s) that carry it, commit
# them together, and push that commit back to the release branch.
#
# Why write it back at all: the tag knows the version, but the running app and
# the packaged chart do not. A .NET service reads it from appsettings.json; a
# Helm chart advertises it as appVersion. Diatreme is what decided the number,
# so Diatreme is what writes it down — otherwise every consumer bolts on their
# own commit-back step and gets the concurrency wrong.
#
# Why more than one file: a repository that ships several deliverables carries
# the same version in several manifests. Updating one and leaving the rest to
# drift is worse than updating none — the drift is silent, and the manifest
# that lies is the one somebody eventually trusts. So the path spec takes
# several entries and globs, and everything it matches moves in a *single*
# commit: either the repository is consistent at this version, or the commit
# never landed and nothing half-changed.
#
# Nothing in here may fail the release. The tag is pushed and the GitHub
# Release is published before this runs; a mistyped path expression, a file
# somebody deleted last week, or a branch ruleset that rejects the push must
# warn and move on rather than turn a successful release red. Individual
# failures are per-file, so one bad manifest does not cost the others.
#
# Required env:
#   NORMALIZE_VERSION - the released version to persist (steps.normalize).
#   GITHUB_TOKEN      - resolved release auth token; embedded into the HTTPS
#                       remote so the push inherits the App's ruleset bypass.
#   GITHUB_REF_NAME   - branch the release was cut from; the push target.
#
# Optional env:
#   INPUT_VERSION_FILE - one path, or several separated by newlines and/or
#                        commas. Each entry may be a glob (`*`, `**`).
#   INPUT_VERSION_FILE_JSON_PATH - jq path assigned in non-YAML files.
#   INPUT_VERSION_FILE_YAML_PATH - yq path assigned in .yaml/.yml files.
#   INPUT_GITVERSION_APPSETTINGS_FILE         - deprecated alias for
#   INPUT_GITVERSION_APPSETTINGS_VERSION_PATH   the two above; consulted only
#                        when INPUT_VERSION_FILE is empty.
#   GITHUB_OUTPUT      - receives `updated_count`.
#
# Output ($GITHUB_OUTPUT):
#   updated_count - number of files committed (0 when nothing was written).
#
# Exit codes:
#   0 - injected and pushed, or there was nothing to do, or an individual file
#       or the push failed and was warned about. The normal outcome.
#   1 - only via `set -e`, when git itself fails in a way this script does not
#       tolerate — exactly as the inline step it replaced behaved.

set -euo pipefail

# Prefer the new generic input. Fall back to the deprecated gitversion-prefixed
# alias so existing callers keep working.
FILE_SPEC="${INPUT_VERSION_FILE:-}"
JSON_PATH="${INPUT_VERSION_FILE_JSON_PATH:-}"
YAML_PATH="${INPUT_VERSION_FILE_YAML_PATH:-}"
if [ -z "${FILE_SPEC}" ]; then
  FILE_SPEC="${INPUT_GITVERSION_APPSETTINGS_FILE:-}"
  if [ -n "${INPUT_GITVERSION_APPSETTINGS_VERSION_PATH:-}" ]; then
    JSON_PATH="${INPUT_GITVERSION_APPSETTINGS_VERSION_PATH}"
  fi
  echo "::notice::gitversion-appsettings-file is deprecated; use version-file."
fi

VERSION="${NORMALIZE_VERSION:-}"

# "Nothing to do" and "the push was rejected" are both ordinary outcomes with
# their own exits, and the job summary needs the count from every one of them.
# Reporting it from a trap is the only way to be sure no path forgets.
UPDATED_COUNT=0
emit_count() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "updated_count=${UPDATED_COUNT}" >> "${GITHUB_OUTPUT}"
  fi
}
trap emit_count EXIT

# `**` has to mean "at any depth" for a workspace layout to be expressible, and
# a pattern that matches nothing must vanish rather than survive as a literal
# path. globstar is bash 4+; on an older bash `**` degrades to a single-level
# `*` instead of aborting a release that has already been published.
shopt -s nullglob
shopt -s globstar 2>/dev/null || true

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

MATCHED=()

# Same file named twice (an explicit path plus a glob that covers it) is a
# natural way to write the spec, and must not be injected or counted twice.
remember() {
  local candidate="$1" seen
  for seen in ${MATCHED[@]+"${MATCHED[@]}"}; do
    if [ "${seen}" = "${candidate}" ]; then
      return 0
    fi
  done
  MATCHED+=("${candidate}")
}

expand_entry() {
  local entry="$1" hits=0 path
  # Split on newlines only, so a path containing spaces survives the unquoted
  # expansion below; the results of pathname expansion are never split again.
  local IFS=$'\n'
  # shellcheck disable=SC2086  # unquoted on purpose: this is the glob.
  for path in ${entry}; do
    [ -f "${path}" ] || continue
    hits=1
    remember "${path}"
  done
  if [ "${hits}" -eq 0 ]; then
    if [[ "${entry}" == *[*?[]* ]]; then
      echo "::warning::version-file pattern '${entry}' matched no files — skipping injection."
    else
      echo "::warning::version-file '${entry}' not found — skipping injection."
    fi
  fi
}

# Newlines are the readable form for a list of manifests; commas are what a
# single-line YAML scalar invites. Accept both rather than making the caller
# guess which one this action wanted.
while IFS= read -r raw_entry; do
  entry="$(trim "${raw_entry}")"
  [ -n "${entry}" ] || continue
  expand_entry "${entry}"
done < <(printf '%s\n' "${FILE_SPEC}" | tr ',' '\n')

if [ "${#MATCHED[@]}" -eq 0 ]; then
  exit 0
fi

if [ -z "${VERSION}" ]; then
  echo "::warning::No version resolved — skipping injection."
  exit 0
fi

# Detect file format by extension: .yaml/.yml → yq; anything else → jq.
# Tolerate a bad path expression or unexpected content rather than
# failing the release — version-file is opt-in plumbing and
# mis-configuring it should warn, not block the publish.
inject_version() {
  local file="$1" used_path tmp
  tmp=$(mktemp)
  if [[ "${file}" =~ \.(yaml|yml)$ ]]; then
    # Pass VERSION via env so it isn't interpolated into the expression.
    if ! _INJECT_VERSION="${VERSION}" yq "${YAML_PATH} = strenv(_INJECT_VERSION)" "${file}" > "${tmp}" 2>/tmp/yq.err; then
      echo "::warning::Failed to inject version into ${file} at path '${YAML_PATH}': $(cat /tmp/yq.err 2>/dev/null | head -1). Skipping."
      rm -f "${tmp}"
      return 1
    fi
    used_path="${YAML_PATH}"
  else
    if ! jq --arg v "${VERSION}" "${JSON_PATH} = \$v" "${file}" > "${tmp}" 2>/tmp/jq.err; then
      echo "::warning::Failed to inject version into ${file} at path '${JSON_PATH}': $(cat /tmp/jq.err 2>/dev/null | head -1). Skipping."
      rm -f "${tmp}"
      return 1
    fi
    used_path="${JSON_PATH}"
  fi
  if ! mv "${tmp}" "${file}"; then
    echo "::warning::Failed to write ${file} after injection — skipping."
    return 1
  fi
  echo "Injected version ${VERSION} into ${file} at ${used_path}"
}

INJECTED=()
for file in "${MATCHED[@]}"; do
  if inject_version "${file}"; then
    INJECTED+=("${file}")
  fi
done

if [ "${#INJECTED[@]}" -eq 0 ]; then
  exit 0
fi

git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add -- "${INJECTED[@]}"

# Stage first, then ask git which of those files actually moved: a re-run of a
# release, or a manifest whose version was already bumped by hand, leaves the
# content identical and must not produce an empty commit.
CHANGED=()
for file in "${INJECTED[@]}"; do
  if ! git diff --cached --quiet -- "${file}"; then
    CHANGED+=("${file}")
  fi
done

if [ "${#CHANGED[@]}" -eq 0 ]; then
  if [ "${#INJECTED[@]}" -eq 1 ]; then
    echo "No changes to commit — file already at ${VERSION}."
  else
    echo "No changes to commit — ${#INJECTED[@]} files already at ${VERSION}."
  fi
  exit 0
fi

# The one-file message is the historical text, character for character:
# repositories filter their history on it, and "in 1 files" would be a
# gratuitous change to every existing consumer's log.
if [ "${#CHANGED[@]}" -eq 1 ]; then
  LABEL="${CHANGED[0]}"
  git commit -m "chore(release): persist version ${VERSION} in $(basename "${CHANGED[0]}") [skip ci]"
else
  LABEL="${#CHANGED[@]} version files"
  git commit -m "chore(release): persist version ${VERSION} in ${#CHANGED[@]} files [skip ci]"
fi
UPDATED_COUNT="${#CHANGED[@]}"

# Concurrency-safe push loop: another run on the same branch may
# land a commit (Flux image bump, parallel release run, etc.)
# between our fetch and our push. We rebase, push, and on
# rejection re-fetch and retry up to MAX_ATTEMPTS times with
# short backoff. Callers that need workflow-level serialization
# should add their own `concurrency:` group; this loop covers
# concurrent commits from automation outside such a group.
BRANCH="${GITHUB_REF_NAME}"
REMOTE_URL=$(git remote get-url origin)
AUTHED_URL="${REMOTE_URL/https:\/\//https://x-access-token:${GITHUB_TOKEN}@}"
MAX_ATTEMPTS=5

for attempt in $(seq 1 "${MAX_ATTEMPTS}"); do
  git fetch origin "${BRANCH}" 2>&1 | tail -3 || true
  if ! git rebase "origin/${BRANCH}"; then
    git rebase --abort 2>/dev/null || true
    if [ "${attempt}" -eq "${MAX_ATTEMPTS}" ]; then
      echo "::warning::Could not rebase ${LABEL} commit onto latest ${BRANCH} after ${MAX_ATTEMPTS} attempts; skipping push."
      exit 0
    fi
    sleep $((attempt * 2))
    continue
  fi

  if git push "${AUTHED_URL}" "HEAD:${BRANCH}" 2>/tmp/push.err; then
    echo "Pushed ${LABEL} update for ${VERSION} to ${BRANCH} on attempt ${attempt}/${MAX_ATTEMPTS}."
    exit 0
  fi

  # Common race: another run pushed between our fetch and push.
  # Re-fetch and retry. Stop early if the failure is non-recoverable
  # (e.g. branch protection rejection without bypass).
  if grep -qiE "non-fast-forward|fetch first|stale" /tmp/push.err; then
    echo "Push attempt ${attempt}/${MAX_ATTEMPTS} lost a race; will rebase + retry"
    sleep $((attempt * 2))
    continue
  fi

  # Anything else (auth failure, ruleset block, etc.) — don't keep
  # banging on the door; surface it as a warning and move on so
  # the rest of the release flow still completes.
  echo "::warning::Could not push ${LABEL} commit: $(sed -E 's#x-access-token:[^@]*@#x-access-token:***@#g' /tmp/push.err | head -3). Continuing release."
  exit 0
done

echo "::warning::Exhausted ${MAX_ATTEMPTS} push attempts for ${LABEL} on ${BRANCH}; skipping push."
