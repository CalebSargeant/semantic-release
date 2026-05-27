#!/usr/bin/env bash
set -euo pipefail

branch="${GITHUB_HEAD_REF:-}"
PROMOTE_PREFIX="${PROMOTE_BRANCH_PREFIX:-promote}"
allowed="^(feat|fix|chore|hotfix|docs|refactor|perf|test|ci|style|${PROMOTE_PREFIX})/"
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
  echo "::error::Allowed types: feat, fix, chore, hotfix, docs, refactor, perf, test, ci, style"
  exit 1
fi
