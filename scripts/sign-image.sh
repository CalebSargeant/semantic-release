#!/usr/bin/env bash
# Sign released container images with cosign (keyless / Sigstore) by IMMUTABLE
# DIGEST, and record the primary image's subject so the caller can attach SLSA
# build provenance (GitHub Artifact Attestations). Invoked by the release flow
# (mode: release) after images are promoted/built, when `image-sign: true`.
#
# Signing by digest (never the mutable tag) means a later retag can't invalidate
# the signature, and it covers whatever the promote step shipped — a retag of the
# verified pr-<N> image OR a fresh release build.
#
# Input  (env): IMAGE_REFS — newline-separated repo:tag references (released tags).
# Output ($GITHUB_OUTPUT): primary_subject, primary_digest, signed_count.
set -euo pipefail

: "${IMAGE_REFS:?IMAGE_REFS (newline-separated repo:tag) is required}"

primary_subject=""
primary_digest=""
signed=0

while IFS= read -r ref; do
  [ -n "${ref}" ] || continue
  repo="${ref%:*}"
  # Parse the default imagetools output for portability across buildx versions.
  digest="$(docker buildx imagetools inspect "${ref}" 2>/dev/null | awk '/^Digest:/{print $2; exit}')"
  if [ -z "${digest}" ]; then
    echo "::warning::could not resolve a digest for ${ref}; skipping signing"
    continue
  fi
  echo "Signing ${repo}@${digest}"
  cosign sign --yes "${repo}@${digest}"
  signed=$((signed + 1))
  if [ -z "${primary_digest}" ]; then
    primary_subject="${repo}"
    primary_digest="${digest}"
  fi
done <<< "${IMAGE_REFS}"

echo "cosign: signed ${signed} image(s)"
if [ "${signed}" -eq 0 ]; then
  echo "::error::no images were signed — all digest lookups failed. Check registry auth and that the released tags are reachable."
  exit 1
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "primary_subject=${primary_subject}"
    echo "primary_digest=${primary_digest}"
    echo "signed_count=${signed}"
  } >> "${GITHUB_OUTPUT}"
fi
