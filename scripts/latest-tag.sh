#!/usr/bin/env bash
# Print the most recent tag reachable from HEAD, scoped to a tag prefix.
#
# WHY THIS EXISTS. Four places in action.yml called bare
#
#   git describe --tags --abbrev=0
#
# to answer "what was the last release?". In a single-package repo that is
# correct. In a repo that releases more than one package it is not: the tags
# `magmamoose-core-v1.4.0` and `magmamoose-ui-v0.2.0` live in the same
# namespace, and a bare describe returns whichever is nearest in history
# REGARDLESS of which package it belongs to. The failure is silent and
# specific — the version is a real version and the tag is a real tag, they
# just belong to somebody else's package — so the release completes, the
# GitHub Release is created, and a package gets published under a number
# derived from an unrelated one.
#
# Scoping the lookup with --match confines it to one package's tag series.
#
# THE EMPTY-PREFIX TRAP. `git describe --match ""` matches NOTHING and exits
# non-zero — it does not mean "match anything". So the prefix must be tested
# before --match is added, or every caller that leaves tag-prefix empty
# silently starts reporting "no previous release" and every release looks
# like a first release. Hence the branch below rather than an interpolated
# flag.
#
# Env:
#   PREFIX  tag prefix to scope to (e.g. `v`, `magmamoose-core-v`). When
#           empty, falls back to the unscoped lookup — the historical
#           behaviour, correct for a single-package repo.
#
# Output: the tag on stdout, or an empty line when there is no matching tag.
# Always exits 0; "no tag yet" is a normal state on a first release, not an
# error.
set -euo pipefail

PREFIX="${PREFIX:-}"

if [ -n "${PREFIX}" ]; then
  git describe --tags --abbrev=0 --match "${PREFIX}*" 2>/dev/null || echo ""
else
  git describe --tags --abbrev=0 2>/dev/null || echo ""
fi
