#!/usr/bin/env bash
set -euo pipefail

# Print the space-separated list of npm packages to install for a
# semantic-release-npm run: semantic-release itself, this action's baseline
# plugin set, and any additional plugins the consumer declares in their
# config. Installing them together into one node_modules is what makes
# non-bundled plugins (@semantic-release/changelog, @semantic-release/git,
# @semantic-release/github) resolvable when the local semantic-release binary
# runs — otherwise they MODULE_NOT_FOUND.
#
# Run from the consumer's working directory (so config discovery sees their
# package.json / .releaserc).

# Baseline. semantic-release bundles commit-analyzer & release-notes-generator,
# but we install them explicitly so a config that lists only some plugins still
# has the full default toolchain available.
PACKAGES=(
  semantic-release
  @semantic-release/changelog
  @semantic-release/commit-analyzer
  @semantic-release/git
  @semantic-release/github
  @semantic-release/release-notes-generator
)

# Add whatever the consumer's config declares (covers third-party plugins and
# anything beyond the baseline). node is always present after setup-node.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v node >/dev/null 2>&1; then
  while IFS= read -r pkg; do
    [ -n "${pkg}" ] && PACKAGES+=("${pkg}")
  done < <(node "${SCRIPT_DIR}/extract-semrel-plugins.mjs" 2>/dev/null || true)
fi

# Dedupe while preserving first-seen order, emit space-separated on one line.
printf '%s\n' "${PACKAGES[@]}" | awk '!seen[$0]++ { printf "%s%s", sep, $0; sep=" " } END { print "" }'
