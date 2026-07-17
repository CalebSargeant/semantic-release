#!/usr/bin/env bats

# Behaviour coverage for scripts/verify-promote-source.sh — the provenance
# gate that stops `mode: release` from promoting a stale pr-<N> image (a PR
# merged while behind the branch tip keeps a CI image built from old code).
#
# A real throwaway git repo provides commits/trees; `docker` is stubbed to
# return the `imagetools inspect --format '{{json .Image}}'` payload
# (STUB_IMAGE_JSON) and `gh` is stubbed for the commits-API tree fallback
# (STUB_GH_TREE / STUB_GH_FAIL). Exit 0 = verified (promote), exit 1 = not
# verified (caller falls back to a fresh build).

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/verify-promote-source.sh"

TREE_LABEL="com.magmamoose.diatreme.git-tree"
REV_LABEL="org.opencontainers.image.revision"

setup() {
  WORK=$(mktemp -d)
  BIN="${WORK}/bin"
  mkdir -p "${BIN}"
  export STUB_LOG="${WORK}/stub.log"
  : > "${STUB_LOG}"

  cat > "${BIN}/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "${STUB_LOG}"
if [ -n "${STUB_DOCKER_FAIL:-}" ]; then
  echo "ERROR: no such manifest" >&2
  exit 1
fi
printf '%s' "${STUB_IMAGE_JSON:-}"
EOF
  cat > "${BIN}/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "${STUB_LOG}"
if [ -n "${STUB_GH_FAIL:-}" ] || [ -z "${STUB_GH_TREE:-}" ]; then
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
fi
printf '%s\n' "${STUB_GH_TREE}"
EOF
  chmod +x "${BIN}/docker" "${BIN}/gh"
  export PATH="${BIN}:${PATH}"

  # Throwaway repo: two content states (distinct trees) plus an amended
  # commit that shares COMMIT2's tree — the squash-merge shape, where the
  # image's build commit and the release commit differ but their trees match.
  REPO="${WORK}/repo"
  git init -q "${REPO}"
  cd "${REPO}"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  echo one > app.txt
  git add app.txt
  git commit -qm c1
  COMMIT1=$(git rev-parse HEAD)
  TREE1=$(git rev-parse 'HEAD^{tree}')
  echo two > app.txt
  git commit -aqm c2
  COMMIT2=$(git rev-parse HEAD)
  TREE2=$(git rev-parse 'HEAD^{tree}')
  git commit -q --amend -m c2-amended
  COMMIT2B=$(git rev-parse HEAD)
  export COMMIT1 TREE1 COMMIT2 TREE2 COMMIT2B

  # A well-formed SHA that exists nowhere in the fixture repo.
  export GHOST_SHA="1111111111111111111111111111111111111111"
}

teardown() {
  rm -rf "${WORK}"
}

single_platform_json() {
  # $1 = Labels object JSON (e.g. {"key":"value"})
  printf '{"architecture":"amd64","os":"linux","config":{"Labels":%s}}' "$1"
}

# ── tree label: the direct comparison ────────────────────────────────────────

@test "tree label matching the release commit's tree verifies (exit 0)" {
  cd "${REPO}"
  run env SOURCE="ghcr.io/acme/app:pr-30" RELEASE_COMMIT="${COMMIT2}" \
    STUB_IMAGE_JSON="$(single_platform_json "{\"${TREE_LABEL}\":\"${TREE2}\"}")" \
    "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified"* ]]
}

@test "tree label from an older commit is stale (exit 1)" {
  cd "${REPO}"
  run env SOURCE="ghcr.io/acme/app:pr-30" RELEASE_COMMIT="${COMMIT2}" \
    STUB_IMAGE_JSON="$(single_platform_json "{\"${TREE_LABEL}\":\"${TREE1}\"}")" \
    "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"STALE"* ]]
}

@test "multi-platform inspect payload (platform→config map) still finds the label" {
  cd "${REPO}"
  MULTI=$(printf '{"linux/amd64":%s,"linux/arm64":%s}' \
    "$(single_platform_json "{\"${TREE_LABEL}\":\"${TREE2}\"}")" \
    "$(single_platform_json "{\"${TREE_LABEL}\":\"${TREE2}\"}")")
  run env SOURCE="ghcr.io/acme/app:pr-30" RELEASE_COMMIT="${COMMIT2}" \
    STUB_IMAGE_JSON="${MULTI}" "${SCRIPT}"
  [ "$status" -eq 0 ]
}

# ── revision label fallback: resolve the commit to its tree ─────────────────

@test "revision label whose tree matches verifies — the squash-merge shape" {
  # Image built from COMMIT2, release cut as COMMIT2B (amend = different SHA,
  # identical tree): exactly what a squash/rebase merge of an up-to-date PR
  # looks like.
  cd "${REPO}"
  run env SOURCE="ghcr.io/acme/app:pr-30" RELEASE_COMMIT="${COMMIT2B}" \
    STUB_IMAGE_JSON="$(single_platform_json "{\"${REV_LABEL}\":\"${COMMIT2}\"}")" \
    "${SCRIPT}"
  [ "$status" -eq 0 ]
}

@test "revision label from an older commit is stale (exit 1)" {
  cd "${REPO}"
  run env SOURCE="ghcr.io/acme/app:pr-30" RELEASE_COMMIT="${COMMIT2}" \
    STUB_IMAGE_JSON="$(single_platform_json "{\"${REV_LABEL}\":\"${COMMIT1}\"}")" \
    "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"STALE"* ]]
}

@test "tree label wins over a contradictory revision label" {
  cd "${REPO}"
  run env SOURCE="ghcr.io/acme/app:pr-30" RELEASE_COMMIT="${COMMIT2}" \
    STUB_IMAGE_JSON="$(single_platform_json "{\"${TREE_LABEL}\":\"${TREE2}\",\"${REV_LABEL}\":\"${COMMIT1}\"}")" \
    "${SCRIPT}"
  [ "$status" -eq 0 ]
}

@test "revision not in the local checkout resolves via the commits API" {
  # The synthetic refs/pull/N/merge commit is never fetched by the release
  # checkout; the API is the only way to learn its tree.
  cd "${REPO}"
  run env SOURCE="ghcr.io/acme/app:pr-30" RELEASE_COMMIT="${COMMIT2}" \
    REPO_FULL="acme/app" STUB_GH_TREE="${TREE2}" \
    STUB_IMAGE_JSON="$(single_platform_json "{\"${REV_LABEL}\":\"${GHOST_SHA}\"}")" \
    "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -q "gh api repos/acme/app/git/commits/${GHOST_SHA}" "${STUB_LOG}"
}

@test "revision unresolvable locally and via the API is not verified (exit 1)" {
  cd "${REPO}"
  run env SOURCE="ghcr.io/acme/app:pr-30" RELEASE_COMMIT="${COMMIT2}" \
    REPO_FULL="acme/app" STUB_GH_FAIL=1 \
    STUB_IMAGE_JSON="$(single_platform_json "{\"${REV_LABEL}\":\"${GHOST_SHA}\"}")" \
    "${SCRIPT}"
  [ "$status" -eq 1 ]
}

# ── safe-by-default: anything unverifiable falls back to a fresh build ──────

@test "an image with no provenance labels is not verified (exit 1)" {
  cd "${REPO}"
  run env SOURCE="ghcr.io/acme/app:pr-30" RELEASE_COMMIT="${COMMIT2}" \
    STUB_IMAGE_JSON="$(single_platform_json '{"maintainer":"someone"}')" \
    "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot verify"* ]]
}

@test "an uninspectable source image is not verified (exit 1)" {
  cd "${REPO}"
  run env SOURCE="ghcr.io/acme/app:pr-30" RELEASE_COMMIT="${COMMIT2}" \
    STUB_DOCKER_FAIL=1 "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not inspect"* ]]
}

@test "a missing RELEASE_COMMIT is not verified (exit 1), never a hard failure" {
  cd "${REPO}"
  run env SOURCE="ghcr.io/acme/app:pr-30" \
    STUB_IMAGE_JSON="$(single_platform_json "{\"${TREE_LABEL}\":\"${TREE2}\"}")" \
    "${SCRIPT}"
  [ "$status" -eq 1 ]
}

@test "an unresolvable release commit is not verified (exit 1)" {
  cd "${REPO}"
  run env SOURCE="ghcr.io/acme/app:pr-30" RELEASE_COMMIT="${GHOST_SHA}" \
    STUB_IMAGE_JSON="$(single_platform_json "{\"${TREE_LABEL}\":\"${TREE2}\"}")" \
    "${SCRIPT}"
  [ "$status" -eq 1 ]
}
