#!/usr/bin/env bats

# Behaviour-level assertions for the image-promotion retag flow. Loose
# patterns (not full-line greps) so refactors that preserve semantics
# don't break the test.

@test "imagetools create is the primary retag path (preserves multi-arch)" {
  grep -Eq 'docker buildx imagetools create.*--tag.*NEW_TAG.*SOURCE' action.yml
}

@test "stable promotion also tags :latest via imagetools create" {
  grep -Eq 'docker buildx imagetools create.*--tag.*NEW_TAG.*--tag.*IMAGE.*:latest.*SOURCE' action.yml
}

@test "pull/tag/push fallback is gated on the referrers-index parse error" {
  grep -Eq 'failed to decode referrers index' action.yml
}

@test "pull/tag/push fallback runs all four steps for prerelease retag" {
  grep -Eq 'docker pull "?\$\{?SOURCE' action.yml
  grep -Eq 'docker tag "?\$\{?SOURCE.*\$\{?NEW_TAG' action.yml
  grep -Eq 'docker push "?\$\{?NEW_TAG' action.yml
}

@test "pull/tag/push fallback handles :latest for stable retag" {
  grep -Eq 'docker tag "?\$\{?SOURCE.*\$\{?IMAGE.*:latest' action.yml
  grep -Eq 'docker push "?\$\{?IMAGE.*:latest' action.yml
}

@test "pull/tag/push fallback warns about losing multi-arch" {
  grep -Eq 'multi-arch' action.yml
}

# ── stale pr-<N> promotion guard ─────────────────────────────────────────────
# A PR merged while behind the branch tip keeps a CI image built from old
# code; promoting it ships that old code under the new release tag. The CI
# build must stamp provenance labels and the promote step must verify them.

@test "CI build stamps the OCI revision label on every bake target" {
  grep -Fq '*.labels.org.opencontainers.image.revision=${BUILD_REVISION}' action.yml
}

@test "CI build stamps the git-tree provenance label on every bake target" {
  grep -Fq '*.labels.com.magmamoose.diatreme.git-tree=${BUILD_TREE}' action.yml
}

@test "promote verifies pr-<N> provenance via verify-promote-source.sh" {
  grep -Eq 'RELEASE_COMMIT=.*verify-promote-source\.sh|verify-promote-source\.sh' action.yml
  # The gate feeds the retag decision: an unverified source must not retag.
  grep -Eq 'SOURCE_TAG_SUFFIX.*&&.*VERIFIED' action.yml
}

@test "provenance gate applies to first-env (pr-<N>) sources only" {
  # Later environments intentionally promote the previous environment's
  # artifact — their trees never match the new release commit.
  grep -Eq 'SOURCE_TAG_SUFFIX.*&&.*IS_FIRST_ENV' action.yml
}

# ── no-bake Dockerfile fallback ──────────────────────────────────────────────
# When there is no bake file but a Dockerfile, the build/scan/promote/sign steps
# branch on the resolver's strategy and build directly with `docker buildx build`
# (via scripts/build-image-dockerfile.sh) instead of `docker buildx bake`.

@test "CI build branches to the Dockerfile builder when strategy=dockerfile" {
  grep -Eq 'STRATEGY.*=.*"dockerfile"' action.yml
  grep -Fq 'scripts/build-image-dockerfile.sh' action.yml
}

@test "Dockerfile CI build stamps the same provenance labels bake stamps" {
  # verify-promote-source.sh compares these labels, so the fallback must set them
  # too or every Dockerfile-built pr-<N> image would fail promotion verification.
  grep -Fq 'org.opencontainers.image.revision=%s' action.yml
  grep -Fq 'com.magmamoose.diatreme.git-tree=%s' action.yml
}

@test "promote fresh-build falls back to the Dockerfile builder, not bake" {
  # Inside the fresh-build branch, the dockerfile path rebuilds at the release
  # tag via the build script; the version tag + :latest are passed together.
  grep -Fq 'CACHE_SCOPE="buildkit-dockerfile"' action.yml
  grep -Eq 'FRESH_TAGS=.*NEW_TAG' action.yml
}

@test "the Dockerfile builder script exists and is referenced" {
  [ -x scripts/build-image-dockerfile.sh ]
}
