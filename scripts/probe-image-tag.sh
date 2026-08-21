#!/usr/bin/env bash
# Ask the registry whether an image tag already exists, so `mode: release` can
# skip promote work that is provably already done.
#
# Why this exists: re-running a release whose images were already published
# repeats the whole promote — and, whenever the provenance check on the pr-<N>
# source image no longer passes, a full fresh build on top of it. Neither
# produces anything the registry does not already hold. A multi-target promote
# that died half way is the sharper case: the re-run redoes every target that
# already landed before it reaches the one that did not, so the longer the
# matrix the more of the re-run is waste.
#
# The probe is deliberately one-sided. Only a positive, successful answer — the
# manifest came back — may skip work. Absence, a registry outage, an expired
# credential and an unparseable reply all mean "do the work". Skipping on an
# unproven answer would leave the release tag pointing at the previous
# release's code with nothing in the log to say so, which is far worse than an
# unnecessary retag.
#
# Reads the manifest instead of pulling: `imagetools inspect` is a registry API
# call that transfers no layers, and it answers for a manifest list (multi-arch)
# exactly as it does for a single image — `docker pull` would do neither.
#
# It reports the manifest DIGEST rather than a bare yes/no, because a tag is a
# mutable pointer and anyone holding `packages: write` on the registry can make
# one exist. "A tag with this name exists" is therefore not a reason to skip
# anything; only "this tag already points at the exact manifest we were about to
# point it at" is, and that comparison needs digests. The caller does the
# comparing — see the skip gate in `action.yml`'s promote step.
#
# Required env:
#   IMAGE_REF   - fully-qualified ref to probe, e.g. ghcr.io/acme/app:v1.2.3.
#
# Optional env:
#   DIGEST_FILE - path to write the resolved manifest digest to on success.
#                 Written only on exit 0, and always a complete `sha256:…`.
#
# Exit codes:
#   0 - the tag resolves to a manifest, whose digest is in DIGEST_FILE.
#   1 - absent, indeterminate, or IMAGE_REF unset; the caller must do the work.
#       Anything that is not a plain "not found" also emits `::warning::`, so an
#       operator who wonders why the gate never fires can see the reason.

set -euo pipefail

IMAGE_REF="${IMAGE_REF:-}"
DIGEST_FILE="${DIGEST_FILE:-}"

if [ -z "${IMAGE_REF}" ]; then
  echo "::warning::probe-image-tag: IMAGE_REF is required — cannot probe; treating the tag as absent."
  exit 1
fi

# `.Manifest.Digest` is the top-level descriptor for both a single image and a
# manifest list, so one call settles existence and identity together.
STATUS=0
OUTPUT=$(docker buildx imagetools inspect "${IMAGE_REF}" --format '{{.Manifest.Digest}}' 2>&1) || STATUS=$?

if [ "${STATUS}" -eq 0 ]; then
  DIGEST=$(printf '%s' "${OUTPUT}" | tr -d '[:space:]')
  # A zero exit that yields no digest — or something that is not one — is not
  # proof of anything, so it joins the fault path below rather than being read
  # as "present". An older buildx that does not know the format verb lands here
  # too, which is the safe direction: the gate stops firing, nothing is skipped.
  if printf '%s' "${DIGEST}" | grep -qE '^sha256:[0-9a-f]{64}$'; then
    echo "probe-image-tag: ${IMAGE_REF} resolves to ${DIGEST}."
    [ -z "${DIGEST_FILE}" ] || printf '%s' "${DIGEST}" > "${DIGEST_FILE}"
    exit 0
  fi
  OUTPUT="the registry returned no usable manifest digest for ${IMAGE_REF} (got '${OUTPUT}')"
fi

# Absence is the ordinary answer — every first release takes this path — so it
# stays quiet. Registries word it differently and some answer a permission
# problem with a 404; misreading one of those costs only the warning, since
# both outcomes return 1 either way.
if printf '%s' "${OUTPUT}" | grep -qiE 'not found|not_found|manifest unknown|manifest_unknown|no such manifest|name unknown|name_unknown|404'; then
  echo "probe-image-tag: ${IMAGE_REF} is not in the registry."
  exit 1
fi

# Collapsed to one line: `::warning::` only renders its first line as an
# annotation, and registry clients are fond of multi-line errors.
DETAIL="${OUTPUT//$'\n'/ }"
[ -n "${DETAIL}" ] || DETAIL="the registry returned an empty manifest"
echo "::warning::probe-image-tag: could not determine whether ${IMAGE_REF} exists (${DETAIL}) — proceeding as if it does not."
exit 1
