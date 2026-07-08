#!/usr/bin/env bash
set -euo pipefail

branch="${GITHUB_HEAD_REF:-}"
PROMOTE_PREFIX="${PROMOTE_BRANCH_PREFIX:-promote}"

# Baseline TBD types plus the common operational prefixes teams reach for
# (deploy/, release/, build/, revert/). The check is meant to keep branch
# names sane, not to police a minimal Conventional-Commit set, so the default
# leans permissive. Repos that need more can widen it without editing this
# script via EXTRA_BRANCH_PREFIXES (action input `extra-branch-prefixes`).
default_prefixes="feat|fix|chore|hotfix|docs|refactor|perf|test|ci|style|build|revert|deploy|release"

# EXTRA_BRANCH_PREFIXES accepts a comma-, space-, or pipe-separated list.
# Normalise any of those separators to a single `|` and trim empties so the
# alternation stays well-formed no matter how the caller spelled the list.
extra="$(printf '%s' "${EXTRA_BRANCH_PREFIXES:-}" | tr -s ' \t\n,|' '|')"
extra="${extra#|}"
extra="${extra%|}"

prefixes="${default_prefixes}|${PROMOTE_PREFIX}"
if [[ -n "${extra}" ]]; then
  prefixes="${prefixes}|${extra}"
fi
allowed="^(${prefixes})/"

# Bot-generated PR branches follow each bot's own naming convention
# (e.g. `dependabot/github_actions/actions/upload-artifact-7`,
# `renovate/npm-foo-1.x`) and do not fit the TBD <type>/<description>
# shape. Skip the check rather than trying to bend the regex around them.
bot_prefixes="^(dependabot|renovate)/"

if [[ -z "${branch}" ]]; then
  echo "::error::GITHUB_HEAD_REF is empty; branch naming can only be checked on pull_request events."
  exit 1
fi

if [[ "${branch}" =~ ${bot_prefixes} ]]; then
  echo "Branch '${branch}' is a bot-generated branch; skipping TBD naming check."
  exit 0
fi

if [[ "${branch}" =~ ${allowed} ]]; then
  echo "Branch '${branch}' follows TBD naming convention."
else
  echo "::error::Branch '${branch}' does not follow TBD naming convention."
  echo "::error::Expected format: <type>/<description>"
  echo "::error::Allowed types: ${prefixes//|/, }"
  exit 1
fi
