#!/usr/bin/env bash
# Render what the run resolved into the GitHub job summary.
#
# WHY THIS EXISTS. A release run decides a great deal on the consumer's behalf
# — which environment the branch maps to, which versioning backend answered,
# what version and tag came out of it, whether the image was promoted or
# rebuilt, what the scanner counted — and until now it wrote every one of those
# answers to the step log and nowhere else. The log is hundreds of lines spread
# over ~40 steps, most of which are skipped, so "what did this release actually
# ship?" is a question every consumer answers by scrolling. The job summary is
# the one surface GitHub renders at the top of the run page; that is where the
# answer belongs.
#
# This is a reporter, not a gate. It decides nothing, writes no outputs, and
# cannot fail. Its caller runs `if: always()`, so a failed run still shows what
# it managed to resolve before it died — which is exactly when the summary
# earns its keep. Two rules follow from that:
#
#   1. Every value is optional. A run that died before `Detect environment` has
#      no environment, no version and no tag; each missing value drops its row
#      instead of rendering an empty one, so the summary never implies that
#      something was resolved to nothing.
#   2. It always exits 0. Turning a green run red — or worse, masking a red one
#      — in order to report on it would be an absurd trade.
#
# The shape (heading, `·`-separated headline, `| Metric | Value |` table of
# populated rows, one status line) is deliberately the same shape the other
# tools in this pipeline emit, so a run page that carries several of them reads
# as one report rather than three dialects.
#
# Env — all optional; an absent value drops its row:
#   MODE                    ci | release | enable-auto-merge.
#   VERSION, TAG            released version and its git tag.
#   ENVIRONMENT             resolved target environment.
#   IS_PRERELEASE           "true"/"false".
#   RELEASED                "true"/"false". EMPTY is NOT "false": it means the
#                           run never reached normalisation, and is reported as
#                           an incomplete run rather than as "nothing to do".
#   VERSIONING_TOOL         backend that produced the version.
#   REGISTRY, OWNER,        parts of the image reference; whichever are
#   IMAGE_NAME              supplied are joined into one pullable ref.
#   PR_NUMBER               PR the run is about (ci, enable-auto-merge).
#   IMAGES_PROMOTED,        promote tallies. The row appears whenever the
#   IMAGES_SKIPPED,         promote ran, zeros included — "0 rebuilt" is the
#   IMAGES_REBUILT          reassuring half of that row.
#   VERSION_FILES_UPDATED   tracked files the version was injected into.
#   PACKAGE_PUBLISHED       "true"/"false".
#   IMAGE_SCANNED,          scan outcome. The severity filter is folded into
#   IMAGE_FINDINGS,         the row label: "3 findings" says nothing without
#   IMAGE_SCAN_SEVERITY     the band it was counted at.
#   IMAGES_SIGNED           number of released images cosign-signed.
#   AUTO_MERGE_METHOD       merge method enabled (enable-auto-merge).
#   BUILD_OUTCOME,          the `steps.<id>.outcome` of the ci image build and
#   AUTO_MERGE_OUTCOME      of the auto-merge step. Those two modes have no
#                           equivalent of RELEASED to key off, and every other
#                           value they are handed is resolved before the work
#                           happens — so without an outcome the summary would
#                           claim a push, or an enabled auto-merge, on runs
#                           where the step failed. Absent ⇒ no success claim.
#   GITHUB_STEP_SUMMARY     file to append to. Unset/empty ⇒ silent no-op,
#                           which is also what makes this testable.
#
# Exit codes:
#   0 - always. See rule 2 above.

set -euo pipefail

# No summary file means nowhere to report and nothing to report to — off a
# runner, or on one that provides no summary. Leaving is the whole behaviour.
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-}"
[ -n "${SUMMARY_FILE}" ] || exit 0

MODE="${MODE:-}"
VERSION="${VERSION:-}"
TAG="${TAG:-}"
ENVIRONMENT="${ENVIRONMENT:-}"
IS_PRERELEASE="${IS_PRERELEASE:-}"
RELEASED="${RELEASED:-}"
VERSIONING_TOOL="${VERSIONING_TOOL:-}"
REGISTRY="${REGISTRY:-}"
OWNER="${OWNER:-}"
IMAGE_NAME="${IMAGE_NAME:-}"
PR_NUMBER="${PR_NUMBER:-}"
IMAGES_PROMOTED="${IMAGES_PROMOTED:-}"
IMAGES_SKIPPED="${IMAGES_SKIPPED:-}"
IMAGES_REBUILT="${IMAGES_REBUILT:-}"
VERSION_FILES_UPDATED="${VERSION_FILES_UPDATED:-}"
PACKAGE_PUBLISHED="${PACKAGE_PUBLISHED:-}"
IMAGE_SCANNED="${IMAGE_SCANNED:-}"
IMAGE_FINDINGS="${IMAGE_FINDINGS:-}"
IMAGE_SCAN_SEVERITY="${IMAGE_SCAN_SEVERITY:-}"
IMAGES_SIGNED="${IMAGES_SIGNED:-}"
AUTO_MERGE_METHOD="${AUTO_MERGE_METHOD:-}"
BUILD_OUTCOME="${BUILD_OUTCOME:-}"
AUTO_MERGE_OUTCOME="${AUTO_MERGE_OUTCOME:-}"

LINES=()      # the rendered document, one Markdown line per entry
ROWS=()       # metric table rows that had a value
HEADLINE=""   # the ` · `-separated identity line

# ─── Rendering primitives ────────────────────────────────────────────────────

emit() { LINES+=("$1"); }

# A backticked value, or nothing at all — so a caller that hands us an empty
# value gets an omitted row rather than a blank pair of backticks.
tick() {
  [ -n "$1" ] || return 0
  printf "\`%s\`" "$1"
}

# One `**Label:** `value`` fact appended to the headline. Silent when empty.
fact() {
  [ -n "$2" ] || return 0
  local part
  part="**$1:** $(tick "$2")"
  if [ -z "${HEADLINE}" ]; then HEADLINE="${part}"; else HEADLINE="${HEADLINE} · ${part}"; fi
}

# One metric row. Silent when empty, which is the whole omit-the-row contract.
row() {
  [ -n "$2" ] || return 0
  ROWS+=("| $1 | $2 |")
}

# "true"/"false" as the summary says it. Anything else — including empty —
# renders nothing, so an unset flag never reads as a decided "no".
yesno() {
  case "$1" in
    true) printf 'yes' ;;
    false) printf 'no' ;;
    *) : ;;
  esac
}

# ─── The image reference this run worked with ────────────────────────────────
# `image_name` is a bare leaf name (`app`); the pushed ref is
# registry/owner/name:tag. Join whichever parts the caller supplied rather than
# inventing the missing ones, so a partially-wired caller prints a short ref
# instead of a wrong one.
image_ref() {
  local repo="${IMAGE_NAME}" tag=""
  [ -n "${repo}" ] || return 0

  case "${repo}" in
    */*) ;;  # already carries a path — the owner is in there
    *) [ -z "${OWNER}" ] || repo="${OWNER}/${repo}" ;;
  esac
  [ -z "${REGISTRY}" ] || repo="${REGISTRY}/${repo}"

  # Registries reject uppercase in the repository part, so the build steps
  # lowercase the owner before pushing. Echoing the mixed-case form would print
  # a reference that does not pull.
  repo=$(printf '%s' "${repo}" | tr '[:upper:]' '[:lower:]')

  case "${MODE}" in
    ci)
      # ci publishes the mutable pr-<N> tag, unless a version override renamed it.
      if [ -n "${VERSION}" ]; then tag="${VERSION}"
      elif [ -n "${PR_NUMBER}" ]; then tag="pr-${PR_NUMBER}"
      fi
      ;;
    *)
      if [ -n "${TAG}" ]; then tag="${TAG}"; else tag="${VERSION}"; fi
      ;;
  esac

  if [ -n "${tag}" ]; then printf '%s:%s' "${repo}" "${tag}"; else printf '%s' "${repo}"; fi
}

IMAGE_REF=$(image_ref)

# ─── The single status line ──────────────────────────────────────────────────
# One verdict per run, and it must not overstate: an incomplete run is marked
# as an incomplete run (blockquote, the shape the sibling tools use for a tool
# error) rather than dressed up as a clean "nothing to release".
status_line() {
  local ref target
  case "${MODE}" in
    release)
      # A released run without a tag is not a state normalisation can produce,
      # but the dash keeps the sentence honest if one ever reaches us.
      ref="${TAG:-${VERSION:-—}}"
      if [ "${RELEASED}" = "true" ]; then
        if [ -n "${ENVIRONMENT}" ]; then
          printf "✅ Released %s to \`%s\`." "$(tick "${ref}")" "${ENVIRONMENT}"
        else
          printf '✅ Released %s.' "$(tick "${ref}")"
        fi
      elif [ "${RELEASED}" = "false" ]; then
        printf '📋 No new version — nothing to release from these commits.'
      else
        printf '> ❌ **Run did not complete** — no version was resolved. See the failing step above.'
      fi
      ;;
    ci)
      # Never claim the push from IMAGE_REF alone: the image name is resolved
      # long before the build runs, so it is just as populated on a run whose
      # build failed. Only the step's own outcome can settle it.
      if [ "${BUILD_OUTCOME}" = "failure" ]; then
        printf '> ❌ **Run did not complete** — the image build failed. See the failing step above.'
      elif [ "${BUILD_OUTCOME}" = "success" ] && [ -n "${IMAGE_REF}" ]; then
        printf "✅ Pushed \`%s\`." "${IMAGE_REF}"
      elif [ -n "${IMAGE_REF}" ]; then
        # Cancelled, skipped, or an outcome that was never wired through.
        printf "📋 No image was pushed for \`%s\`." "${IMAGE_REF}"
      else
        printf '📋 Versioning-only run — no image built.'
      fi
      ;;
    enable-auto-merge)
      target="the pull request"
      [ -z "${PR_NUMBER}" ] || target="#${PR_NUMBER}"
      # Same reasoning as ci: the method is an input, present whether or not
      # the helper succeeded.
      if [ "${AUTO_MERGE_OUTCOME}" = "failure" ]; then
        printf '> ❌ **Run did not complete** — auto-merge could not be enabled on %s. See the failing step above.' "${target}"
      elif [ "${AUTO_MERGE_OUTCOME}" != "success" ]; then
        printf '📋 Auto-merge was not enabled on %s.' "${target}"
      elif [ -n "${AUTO_MERGE_METHOD}" ]; then
        printf "✅ Auto-merge (\`%s\`) enabled on %s." "${AUTO_MERGE_METHOD}" "${target}"
      else
        printf '✅ Auto-merge enabled on %s.' "${target}"
      fi
      ;;
    *)
      # No mode, no verdict to reach. The facts above still stand on their own.
      :
      ;;
  esac
}

# ─── Assemble ────────────────────────────────────────────────────────────────

# Fixed, bare and identical on every mode. `<Tool>: <Discipline>` is the
# convention the sibling tools in this pipeline heading their own sections with,
# and a run page carrying several of them only reads as one report if none of
# them decorates its heading. No glyph, and no mode suffix — the mode is the
# first fact on the headline line below, so the suffix said nothing twice.
emit "## Diatreme: Release Orchestration"
emit ""

fact "Mode" "${MODE}"
case "${MODE}" in
  release)
    fact "Environment" "${ENVIRONMENT}"
    fact "Version" "${VERSION}"
    ;;
  ci)
    if [ -n "${IMAGE_REF}" ]; then
      fact "Image" "${IMAGE_REF}"
    else
      fact "PR" "${PR_NUMBER:+#${PR_NUMBER}}"
    fi
    ;;
  enable-auto-merge)
    fact "PR" "${PR_NUMBER:+#${PR_NUMBER}}"
    fact "Method" "${AUTO_MERGE_METHOD}"
    ;;
esac
if [ -n "${HEADLINE}" ]; then
  emit "${HEADLINE}"
  emit ""
fi

row "Version" "${VERSION:+**${VERSION}**}"
row "Tag" "$(tick "${TAG}")"
row "Environment" "$(tick "${ENVIRONMENT}")"
row "Prerelease" "$(yesno "${IS_PRERELEASE}")"
row "Versioning tool" "$(tick "${VERSIONING_TOOL}")"
row "Image" "$(tick "${IMAGE_REF}")"
# Any one of the three present means the promote step ran and tallied; report
# all three then, so "0 skipped" and "0 rebuilt" are visible facts.
if [ -n "${IMAGES_PROMOTED}${IMAGES_SKIPPED}${IMAGES_REBUILT}" ]; then
  row "Images promoted / skipped / rebuilt" \
    "${IMAGES_PROMOTED:-0} / ${IMAGES_SKIPPED:-0} / ${IMAGES_REBUILT:-0}"
fi
row "Version files updated" "${VERSION_FILES_UPDATED}"
row "Package published" "$(yesno "${PACKAGE_PUBLISHED}")"
if [ -n "${IMAGE_FINDINGS}" ] || [ "${IMAGE_SCANNED}" = "true" ]; then
  row "Scan findings${IMAGE_SCAN_SEVERITY:+ (${IMAGE_SCAN_SEVERITY})}" "${IMAGE_FINDINGS:-0}"
fi
row "Images signed" "${IMAGES_SIGNED}"

if [ "${#ROWS[@]}" -gt 0 ]; then
  emit "| Metric | Value |"
  emit "|--------|-------|"
  for entry in "${ROWS[@]}"; do emit "${entry}"; done
  emit ""
fi

STATUS=$(status_line)
if [ -n "${STATUS}" ]; then
  emit "${STATUS}"
  emit ""
fi

# A summary that cannot be written is worth a warning and nothing more: the
# release itself succeeded or failed on its own merits, not on this.
printf '%s\n' "${LINES[@]}" >> "${SUMMARY_FILE}" \
  || echo "::warning::write-job-summary: could not append to ${SUMMARY_FILE}; the run is unaffected."

exit 0
