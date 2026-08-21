#!/usr/bin/env bash
# Decide whether the actor driving this run may cut a release to the current
# environment.
#
# Why this exists: without it, "who may ship to production" is whatever the
# workflow token happens to permit — in practice, anyone who can push to or
# merge into the release branch. The existing repo-admin guardrail is a poor
# substitute for a release-manager list: it only fires on workflow_dispatch, so
# a push or a merged promotion PR walks straight past it, and the thing it
# demands — repo admin — also hands over settings, secrets and branch
# protection. Most teams want the opposite shape: a short list of named people
# (and teams) who need no elevated repository rights at all.
#
# So this gate is trigger-agnostic (a push and a merged promotion PR are
# checked exactly like a manual dispatch), it names principals directly, and it
# is inert until `allowed-release-actors` is populated. It applies only from
# `allowed-release-actors-from` onwards, so pre-production environments stay
# open to everyone while production is closed.
#
# FAIL CLOSED. The only "no" this script trusts is a clean 404 from the team
# membership API, which is how that API spells "not a member". Every other
# fault — a missing scope, a rate limit, a 5xx, `gh` not being on PATH — is a
# check that did not happen, and a check that did not happen must never be read
# as approval. An allowlist that quietly opens itself during an API outage is
# worse than no allowlist, because nobody is watching the door they believe is
# locked.
#
# Required env:
#   ACTOR          - login the run is attributed to (github.actor). On a re-run
#                    this is the ORIGINAL initiator, not whoever re-ran it.
#   ALLOWED_ACTORS - raw `allowed-release-actors` input (grammar below).
#   THRESHOLD      - raw `allowed-release-actors-from` input; '@last' resolves
#                    to the final entry of ENVIRONMENTS (production only).
#   CURRENT_ENV    - environment this run is releasing to.
#   ENVIRONMENTS   - JSON array of environments, ordered upstream → production.
#
# Optional env:
#   TRIGGERING_ACTOR - login that started THIS run (github.triggering_actor),
#                    which on a re-run is the person who pressed re-run. When it
#                    differs from ACTOR both must be allowed, so re-running
#                    somebody else's failed release cannot be a way around the
#                    list. Equal to ACTOR on an ordinary run, and then free.
#   OWNER          - repository owner; the org that an entry written without an
#                    org part (`@release-managers`) is resolved against.
#   GH_TOKEN       - read by `gh`. Team entries need it to be able to read org
#                    team membership; an allowlist of plain logins needs no
#                    extra permission and makes no API call at all.
#
# Allowlist grammar: comma- and/or newline-separated, or a JSON array. An entry
# is a login (`octocat`, or `@octocat`) or a team (`@org/release-managers`, or
# `@release-managers` for a team in OWNER's org). Matching is case-insensitive.
# `@name` is ambiguous by design: it is tried as a login first, then as a team
# in OWNER's org, so operators need not know which spelling we expect.
#
# Exit codes:
#   0 - allowed: the allowlist is empty, this environment is upstream of the
#       threshold, or the actor matched a login or an active team membership.
#   1 - denied, or the decision could not be made (misconfigured threshold or
#       environment, unusable allowlist, failed membership lookup). Both are a
#       red X on the release, deliberately: see FAIL CLOSED above.

set -euo pipefail

ACTOR="${ACTOR:-}"
TRIGGERING_ACTOR="${TRIGGERING_ACTOR:-}"
OWNER="${OWNER:-}"
ALLOWED_ACTORS="${ALLOWED_ACTORS:-}"
RAW_THRESHOLD="${THRESHOLD:-@last}"
CURRENT_ENV="${CURRENT_ENV:-}"
ENVIRONMENTS="${ENVIRONMENTS:-}"

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Workflow annotations are single-line, so a newline-separated allowlist would
# be truncated to its first entry in exactly the message an operator reads to
# work out why they were refused. Flatten it once, up front.
ALLOWED_DISPLAY=$(printf '%s' "${ALLOWED_ACTORS}" | tr '\n' ' ' | tr -s ' ')
ALLOWED_DISPLAY=$(trim "${ALLOWED_DISPLAY}")

if [ -z "${ALLOWED_ACTORS//[[:space:]]/}" ]; then
  echo "allowed-release-actors is empty — releases are unrestricted; allowlist not applied."
  exit 0
fi

# Threshold resolution is deliberately identical to the repo-admin guardrail's:
# both inputs index into the same `environments` array, and an operator who
# learned one should not have to learn the other.
if [ "${RAW_THRESHOLD}" = "@last" ]; then
  THRESHOLD=$(echo "${ENVIRONMENTS}" | jq -r '.[-1] // empty')
  if [ -z "${THRESHOLD}" ]; then
    echo "::error::allowed-release-actors-from='@last' but environments is empty."
    exit 1
  fi
  echo "Threshold '@last' resolved to '${THRESHOLD}' (last entry of ${ENVIRONMENTS})."
else
  THRESHOLD="${RAW_THRESHOLD}"
fi

THRESHOLD_IDX=$(echo "${ENVIRONMENTS}" | jq -r --arg e "${THRESHOLD}" 'index($e) // empty')
if [ -z "${THRESHOLD_IDX}" ]; then
  echo "::error::allowed-release-actors-from='${THRESHOLD}' is not in environments=${ENVIRONMENTS}."
  exit 1
fi
if [ -z "${CURRENT_ENV}" ]; then
  echo "::error::Could not resolve current environment for the run."
  exit 1
fi
CURRENT_IDX=$(echo "${ENVIRONMENTS}" | jq -r --arg e "${CURRENT_ENV}" 'index($e) // empty')
if [ -z "${CURRENT_IDX}" ]; then
  echo "::error::Resolved environment '${CURRENT_ENV}' is not in environments=${ENVIRONMENTS}."
  exit 1
fi

if [ "${CURRENT_IDX}" -lt "${THRESHOLD_IDX}" ]; then
  echo "Current env '${CURRENT_ENV}' is upstream of threshold '${THRESHOLD}' — allowlist not applied."
  exit 0
fi

# From here the gate is live, so an actor we cannot identify is a denial, not
# an empty string that might coincidentally match an empty allowlist entry.
if [ -z "${ACTOR}" ]; then
  echo "::error::Could not resolve the actor for the run; releases to '${CURRENT_ENV}' are restricted by allowed-release-actors."
  exit 1
fi

TRIMMED=$(trim "${ALLOWED_ACTORS}")
if [ "${TRIMMED:0:1}" = "[" ]; then
  # A JSON array that will not parse is a typo, not an empty allowlist: refuse
  # rather than silently degrading to "nobody is on the list, deny everyone",
  # which reads in the log like a permissions problem with the actor.
  if ! RAW_ENTRIES=$(printf '%s' "${TRIMMED}" | jq -r '.[]' 2>/dev/null); then
    echo "::error::allowed-release-actors starts with '[' but is not a parseable JSON array: ${ALLOWED_DISPLAY}"
    exit 1
  fi
else
  RAW_ENTRIES=$(printf '%s' "${ALLOWED_ACTORS}" | tr ',' '\n')
fi

ENTRIES=()
while IFS= read -r raw; do
  entry=$(trim "${raw}")
  [ -n "${entry}" ] || continue
  ENTRIES+=("${entry}")
done <<< "${RAW_ENTRIES}"

if [ "${#ENTRIES[@]}" -eq 0 ]; then
  echo "::error::allowed-release-actors contains no usable entries: ${ALLOWED_DISPLAY}"
  exit 1
fi

TMPDIR="${RUNNER_TEMP:-/tmp}"
WORKDIR=$(mktemp -d "${TMPDIR}/check-release-actor.XXXXXX")
trap 'rm -rf "${WORKDIR}"' EXIT
MEMBERSHIP_ERR="${WORKDIR}/membership.err"

# Returns 0 when this login is named in the allowlist or belongs to a listed
# team; 1 when it is simply not allowed. Exits 1 outright — never returns — when
# a membership check could not be completed, because a check that did not run is
# not a pass.
actor_allowed() {
  local who="$1"
  local who_lc entry candidate SPEC ORG SLUG STATE

  who_lc=$(lower "${who}")

  # Logins first, and in full: matching one costs nothing, while every team entry
  # costs an API call that can fail. A list of plain logins therefore needs no
  # token permission beyond the one the release already has.
  for entry in "${ENTRIES[@]}"; do
    candidate="${entry#@}"
    case "${candidate}" in */*) continue ;; esac
    if [ "$(lower "${candidate}")" = "${who_lc}" ]; then
      echo "✓ ${who} is named in allowed-release-actors."
      return 0
    fi
  done

  for entry in "${ENTRIES[@]}"; do
    case "${entry}" in @*) ;; *) continue ;; esac

    SPEC="${entry#@}"
    case "${SPEC}" in
      */*) ORG="${SPEC%%/*}"; SLUG="${SPEC#*/}" ;;
      *)   ORG="${OWNER}";    SLUG="${SPEC}"    ;;
    esac
    if [ -z "${SLUG}" ]; then
      echo "::error::allowed-release-actors entry '${entry}' names no team."
      exit 1
    fi
    if [ -z "${ORG}" ]; then
      echo "::error::allowed-release-actors entry '${entry}' has no organization and none could be inferred; write it as '@org/${SLUG}'."
      exit 1
    fi

    : > "${MEMBERSHIP_ERR}"
    if STATE=$(gh api "/orgs/${ORG}/teams/${SLUG}/memberships/${who}" --jq '.state' 2>"${MEMBERSHIP_ERR}"); then
      if [ "${STATE}" = "active" ]; then
        echo "✓ ${who} is an active member of @${ORG}/${SLUG}."
        return 0
      fi
      # A pending invitation is not membership; the person has not accepted yet.
      echo "${who} is not an active member of @${ORG}/${SLUG} (state='${STATE:-none}')."
      continue
    fi

    # Match on the status, not on the words: bash's own "command not found" and
    # any 5xx body quoting a "not found" upstream would otherwise be mistaken for
    # a clean negative, which is the one misreading this gate cannot afford.
    if grep -qE 'HTTP 404|^gh: Not Found' "${MEMBERSHIP_ERR}"; then
      echo "${who} is not a member of @${ORG}/${SLUG}."
      continue
    fi

    echo "::error::Could not check whether ${who} is a member of @${ORG}/${SLUG}: $(head -3 "${MEMBERSHIP_ERR}" 2>/dev/null | tr '\n' ' ')"
    echo "::error::The auth token needs Organization: Members: Read on '${ORG}'. With auth-mode: public-app, grant that permission on the Diatreme App and accept it on the installation. The release is refused rather than allowed, because a membership check that did not complete is not a pass."
    exit 1
  done

  return 1
}

# EVERY login that had a hand in this run must be allowed, not just the first.
# `github.actor` is the initiator of the ORIGINAL run and is what a re-run
# inherits; `github.triggering_actor` is whoever pressed re-run. Checking only
# the former would let anyone with write access re-run an allowed person's
# failed release and thereby cut production themselves — one click, and the gate
# reports a pass. They are the same login on an ordinary run, so the second
# check costs nothing in the common case.
CHECK=("${ACTOR}")
if [ -n "${TRIGGERING_ACTOR}" ] && [ "$(lower "${TRIGGERING_ACTOR}")" != "$(lower "${ACTOR}")" ]; then
  CHECK+=("${TRIGGERING_ACTOR}")
  echo "This run was triggered by ${TRIGGERING_ACTOR} on behalf of ${ACTOR}; both must be allowed."
fi

for who in "${CHECK[@]}"; do
  if ! actor_allowed "${who}"; then
    echo "::error::${who} is not allowed to cut a release to '${CURRENT_ENV}' (threshold: '${THRESHOLD}')."
    echo "::error::allowed-release-actors is set to: ${ALLOWED_DISPLAY}. Add ${who} (or a team they belong to), or clear the input to leave releases unrestricted."
    exit 1
  fi
done

echo "Release to '${CURRENT_ENV}' allowed."
exit 0
