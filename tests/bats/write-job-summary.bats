#!/usr/bin/env bats

# Behaviour coverage for scripts/write-job-summary.sh — the run report rendered
# into GitHub's job summary.
#
# Nothing needs stubbing: the script's only side effect is appending Markdown to
# the file named by GITHUB_STEP_SUMMARY, so a temp file makes it fully testable.
# Two properties matter more than any single line of output and are asserted
# throughout: it never exits non-zero (its caller runs `if: always()`, where a
# failure would turn a green run red or mask a red one), and a value it was not
# given drops its row rather than rendering blank.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/write-job-summary.sh"

setup() {
  WORK=$(mktemp -d)
  export GITHUB_STEP_SUMMARY="${WORK}/summary.md"
  : > "${GITHUB_STEP_SUMMARY}"
}

teardown() {
  rm -rf "${WORK}"
}

# Assert an exact rendered line (use single quotes: the Markdown is full of
# backticks).
has_line() {
  grep -Fxq "$1" "${GITHUB_STEP_SUMMARY}" \
    || { echo "missing line: $1"; echo "--- rendered ---"; cat "${GITHUB_STEP_SUMMARY}"; false; }
}

no_line() {
  ! grep -Fxq "$1" "${GITHUB_STEP_SUMMARY}" \
    || { echo "unexpected line: $1"; echo "--- rendered ---"; cat "${GITHUB_STEP_SUMMARY}"; false; }
}

# ── no-op when there is no summary to write ─────────────────────────────────

@test "unset GITHUB_STEP_SUMMARY is a silent no-op" {
  run env -u GITHUB_STEP_SUMMARY MODE=release VERSION=1.4.0 RELEASED=true "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "${GITHUB_STEP_SUMMARY}" ]
}

@test "empty GITHUB_STEP_SUMMARY is a silent no-op" {
  run env GITHUB_STEP_SUMMARY="" MODE=release VERSION=1.4.0 RELEASED=true "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "${GITHUB_STEP_SUMMARY}" ]
}

@test "an entirely empty environment still exits 0 and renders only the heading" {
  run env "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line "## Diatreme: Release Orchestration"
  # No table, no invented verdict.
  no_line "| Metric | Value |"
}

# ── the heading ─────────────────────────────────────────────────────────────

@test "the heading is exactly '## Diatreme: Release Orchestration', on every mode" {
  # Pinned deliberately, and byte for byte. The sibling tools sharing a run page
  # use the same `<Tool>: <Discipline>` heading and none of them asserted its
  # own, which is exactly how the three drifted into three dialects. It carries
  # no glyph and no mode suffix: the mode is the first fact on the headline line
  # below it, and the status lines further down carry the outcome markers.
  local mode
  for mode in release ci enable-auto-merge ""; do
    : > "${GITHUB_STEP_SUMMARY}"
    run env MODE="${mode}" VERSION=1.4.0 TAG=v1.4.0 RELEASED=true "${SCRIPT}"
    [ "$status" -eq 0 ]
    [ "$(sed -n '1p' "${GITHUB_STEP_SUMMARY}")" = "## Diatreme: Release Orchestration" ]
  done
}

# ── release mode ────────────────────────────────────────────────────────────

@test "a released run renders heading, headline, table and status" {
  run env MODE=release VERSION=1.4.0 TAG=v1.4.0 ENVIRONMENT=prod IS_PRERELEASE=false \
    RELEASED=true VERSIONING_TOOL=semantic-release-npm "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line "## Diatreme: Release Orchestration"
  has_line '**Mode:** `release` · **Environment:** `prod` · **Version:** `1.4.0`'
  has_line "| Metric | Value |"
  has_line "|--------|-------|"
  has_line '| Version | **1.4.0** |'
  has_line '| Tag | `v1.4.0` |'
  has_line '| Environment | `prod` |'
  has_line "| Prerelease | no |"
  has_line '| Versioning tool | `semantic-release-npm` |'
  has_line '✅ Released `v1.4.0` to `prod`.'
}

@test "a prerelease renders Prerelease yes" {
  run env MODE=release VERSION=1.4.0-rc.1 TAG=v1.4.0-rc.1 ENVIRONMENT=acc \
    IS_PRERELEASE=true RELEASED=true "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line "| Prerelease | yes |"
  has_line '✅ Released `v1.4.0-rc.1` to `acc`.'
}

@test "released=false reports nothing to release, not a failure" {
  run env MODE=release RELEASED=false ENVIRONMENT=prod VERSIONING_TOOL=gitversion "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line "📋 No new version — nothing to release from these commits."
  no_line "> ❌ **Run did not complete** — no version was resolved. See the failing step above."
}

@test "an empty RELEASED is an incomplete run, NOT 'nothing to release'" {
  # The run died before normalisation, so there is no verdict to report — the
  # blockquote says so instead of implying the commits held no release.
  run env MODE=release ENVIRONMENT=prod "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line "> ❌ **Run did not complete** — no version was resolved. See the failing step above."
  no_line "📋 No new version — nothing to release from these commits."
}

@test "a released run with no environment drops the 'to <env>' clause" {
  run env MODE=release VERSION=1.4.0 TAG=v1.4.0 RELEASED=true "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line '✅ Released `v1.4.0`.'
}

# ── ci mode ─────────────────────────────────────────────────────────────────

@test "a ci run with an image headlines and reports the pushed ref" {
  run env MODE=ci BUILD_OUTCOME=success REGISTRY=ghcr.io OWNER=owner IMAGE_NAME=app PR_NUMBER=12 "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line "## Diatreme: Release Orchestration"
  has_line '**Mode:** `ci` · **Image:** `ghcr.io/owner/app:pr-12`'
  has_line '| Image | `ghcr.io/owner/app:pr-12` |'
  has_line '✅ Pushed `ghcr.io/owner/app:pr-12`.'
}

@test "a ci run without an image reports a versioning-only run" {
  run env MODE=ci PR_NUMBER=12 "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line '**Mode:** `ci` · **PR:** `#12`'
  has_line "📋 Versioning-only run — no image built."
  no_line "| Metric | Value |"
}

@test "the image ref is lowercased so it is one a reader can actually pull" {
  # Registries reject uppercase in the repository part; github.repository_owner
  # keeps whatever case the org was created with.
  run env MODE=ci BUILD_OUTCOME=success REGISTRY=ghcr.io OWNER=MixedCaseOrg IMAGE_NAME=App PR_NUMBER=7 "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line '✅ Pushed `ghcr.io/mixedcaseorg/app:pr-7`.'
}

@test "an owner-qualified IMAGE_NAME is not double-prefixed" {
  run env MODE=ci BUILD_OUTCOME=success REGISTRY=ghcr.io OWNER=owner IMAGE_NAME=owner/app PR_NUMBER=7 "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line '✅ Pushed `ghcr.io/owner/app:pr-7`.'
}

# ── enable-auto-merge mode ──────────────────────────────────────────────────

@test "enable-auto-merge names the method and the PR" {
  run env MODE=enable-auto-merge AUTO_MERGE_OUTCOME=success PR_NUMBER=42 AUTO_MERGE_METHOD=squash "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line "## Diatreme: Release Orchestration"
  has_line '**Mode:** `enable-auto-merge` · **PR:** `#42` · **Method:** `squash`'
  has_line '✅ Auto-merge (`squash`) enabled on #42.'
}

# ── only-populated rows ─────────────────────────────────────────────────────

@test "rows with no value are omitted entirely, never rendered blank" {
  run env MODE=release VERSION=1.4.0 RELEASED=true "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line '| Version | **1.4.0** |'
  # Every unsupplied value is absent as a row rather than present and empty.
  ! grep -q "^| Tag |" "${GITHUB_STEP_SUMMARY}"
  ! grep -q "^| Environment |" "${GITHUB_STEP_SUMMARY}"
  ! grep -q "^| Prerelease |" "${GITHUB_STEP_SUMMARY}"
  ! grep -q "^| Versioning tool |" "${GITHUB_STEP_SUMMARY}"
  ! grep -q "^| Image |" "${GITHUB_STEP_SUMMARY}"
  ! grep -q "^| Images promoted" "${GITHUB_STEP_SUMMARY}"
  ! grep -q "^| Version files updated |" "${GITHUB_STEP_SUMMARY}"
  ! grep -q "^| Package published |" "${GITHUB_STEP_SUMMARY}"
  ! grep -q "^| Scan findings" "${GITHUB_STEP_SUMMARY}"
  ! grep -q "^| Images signed |" "${GITHUB_STEP_SUMMARY}"
  ! grep -qE '\|\s*\|\s*$' "${GITHUB_STEP_SUMMARY}"
}

@test "an unset boolean does not render as a decided 'no'" {
  run env MODE=release VERSION=1.4.0 RELEASED=true IS_PRERELEASE="" PACKAGE_PUBLISHED="" "${SCRIPT}"
  [ "$status" -eq 0 ]
  no_line "| Prerelease | no |"
  no_line "| Package published | no |"
}

# ── promote tallies ─────────────────────────────────────────────────────────

@test "the promote row renders promoted / skipped / rebuilt" {
  run env MODE=release VERSION=1.4.0 RELEASED=true \
    IMAGES_PROMOTED=2 IMAGES_SKIPPED=1 IMAGES_REBUILT=0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line "| Images promoted / skipped / rebuilt | 2 / 1 / 0 |"
}

@test "the promote row appears with zeros as soon as the promote ran at all" {
  # "0 rebuilt" is the reassuring half of that row — it has to be visible.
  run env MODE=release VERSION=1.4.0 RELEASED=true IMAGES_PROMOTED=0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line "| Images promoted / skipped / rebuilt | 0 / 0 / 0 |"
}

# ── scan reporting ──────────────────────────────────────────────────────────

@test "the scan row label carries the severity filter it was counted at" {
  run env MODE=ci BUILD_OUTCOME=success REGISTRY=ghcr.io OWNER=owner IMAGE_NAME=app PR_NUMBER=12 \
    IMAGE_SCANNED=true IMAGE_FINDINGS=3 IMAGE_SCAN_SEVERITY=CRITICAL,HIGH "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line "| Scan findings (CRITICAL,HIGH) | 3 |"
}

@test "a clean scan still reports, so a scanned image is distinguishable from an unscanned one" {
  run env MODE=ci BUILD_OUTCOME=success REGISTRY=ghcr.io OWNER=owner IMAGE_NAME=app PR_NUMBER=12 \
    IMAGE_SCANNED=true IMAGE_SCAN_SEVERITY=HIGH "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line "| Scan findings (HIGH) | 0 |"
}

@test "a severity filter alone does not conjure a scan row" {
  run env MODE=ci BUILD_OUTCOME=success REGISTRY=ghcr.io OWNER=owner IMAGE_NAME=app PR_NUMBER=12 \
    IMAGE_SCAN_SEVERITY=CRITICAL,HIGH "${SCRIPT}"
  [ "$status" -eq 0 ]
  ! grep -q "^| Scan findings" "${GITHUB_STEP_SUMMARY}"
}

# ── file handling ───────────────────────────────────────────────────────────

@test "appends to the summary rather than replacing what is already there" {
  echo "## Something else" > "${GITHUB_STEP_SUMMARY}"
  run env MODE=release VERSION=1.4.0 TAG=v1.4.0 RELEASED=true "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line "## Something else"
  has_line "## Diatreme: Release Orchestration"
}

@test "the block is blank-line separated and ends with a blank line" {
  # Consecutive tool summaries land in one file; without the trailing blank the
  # next tool's heading would glue onto this one's status line.
  run env MODE=release VERSION=1.4.0 TAG=v1.4.0 ENVIRONMENT=prod RELEASED=true "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "${GITHUB_STEP_SUMMARY}")" = "## Diatreme: Release Orchestration" ]
  [ -z "$(sed -n '2p' "${GITHUB_STEP_SUMMARY}")" ]
  [ -z "$(tail -n 1 "${GITHUB_STEP_SUMMARY}")" ]
  [ -n "$(tail -n 2 "${GITHUB_STEP_SUMMARY}" | head -n 1)" ]
}

@test "an unwritable summary path warns but still exits 0" {
  run env GITHUB_STEP_SUMMARY="${WORK}/no/such/dir/summary.md" \
    MODE=release VERSION=1.4.0 RELEASED=true "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::write-job-summary"* ]]
}

# ── never claim work that did not happen ────────────────────────────────────
#
# The caller runs this under `if: always()`, so every fact it is handed is just
# as present on a run that died as on one that worked. `release` mode keys its
# verdict off `released`; `ci` and `enable-auto-merge` have no equivalent, and
# an earlier revision printed "✅ Pushed …" and "✅ Auto-merge enabled" straight
# from an image name and a merge method — both of which are resolved before the
# work is attempted. A summary that asserts a push at the top of a red run is
# worse than no summary, so the success line now requires the step's outcome.

@test "a failed ci build reports the failure, never a push" {
  run env GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY}" \
    MODE=ci BUILD_OUTCOME=failure REGISTRY=ghcr.io OWNER=owner IMAGE_NAME=app PR_NUMBER=12 "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line '> ❌ **Run did not complete** — the image build failed. See the failing step above.'
  ! grep -q '✅' "${GITHUB_STEP_SUMMARY}"
}

@test "a ci run with no build outcome makes no success claim" {
  # Cancelled, skipped, or an outcome that was never wired through: the image
  # name proves nothing on its own.
  run env GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY}" \
    MODE=ci REGISTRY=ghcr.io OWNER=owner IMAGE_NAME=app PR_NUMBER=12 "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line '📋 No image was pushed for `ghcr.io/owner/app:pr-12`.'
  ! grep -q '✅' "${GITHUB_STEP_SUMMARY}"
}

@test "a failed enable-auto-merge reports the failure, never an enablement" {
  run env GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY}" \
    MODE=enable-auto-merge AUTO_MERGE_OUTCOME=failure PR_NUMBER=42 AUTO_MERGE_METHOD=squash "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line '> ❌ **Run did not complete** — auto-merge could not be enabled on #42. See the failing step above.'
  ! grep -q '✅' "${GITHUB_STEP_SUMMARY}"
}

@test "an enable-auto-merge run with no outcome makes no success claim" {
  run env GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY}" \
    MODE=enable-auto-merge PR_NUMBER=42 AUTO_MERGE_METHOD=squash "${SCRIPT}"
  [ "$status" -eq 0 ]
  has_line '📋 Auto-merge was not enabled on #42.'
  ! grep -q '✅' "${GITHUB_STEP_SUMMARY}"
}
