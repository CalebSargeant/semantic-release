#!/usr/bin/env bats

# Behaviour coverage for scripts/publish-package.sh plus a few structural
# assertions on the action.yml wiring.
#
# The real toolchains (dotnet / python / npm) are replaced with PATH stubs
# that record their invocations to ${STUB_LOG} and create the minimum
# artifacts the script globs for. This lets us assert the exact pack/build/
# publish commands without installing any SDK.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/publish-package.sh"
ACTION_YML="${BATS_TEST_DIRNAME}/../../action.yml"

setup() {
  WORK=$(mktemp -d)
  BIN="${WORK}/bin"
  mkdir -p "${BIN}"
  export STUB_LOG="${WORK}/stub.log"
  : > "${STUB_LOG}"
  export GITHUB_OUTPUT="${WORK}/output"
  : > "${GITHUB_OUTPUT}"

  # dotnet stub: log every call; on `pack`, drop a .nupkg into --output so
  # the script's nullglob find succeeds (unless STUB_NO_PKG is set).
  cat > "${BIN}/dotnet" <<'EOF'
#!/usr/bin/env bash
echo "dotnet $*" >> "${STUB_LOG}"
if [ "${1:-}" = "pack" ]; then
  out=""
  while [ $# -gt 0 ]; do [ "$1" = "--output" ] && out="${2:-}"; shift; done
  if [ -n "${out}" ] && [ -z "${STUB_NO_PKG:-}" ]; then : > "${out}/Sample.nupkg"; fi
fi
exit 0
EOF

  # python stub: log calls; on `-m build`, drop an artifact into --outdir.
  cat > "${BIN}/python" <<'EOF'
#!/usr/bin/env bash
echo "python $*" >> "${STUB_LOG}"
if [ "${1:-}" = "-m" ] && [ "${2:-}" = "build" ]; then
  out=""; shift 2
  while [ $# -gt 0 ]; do [ "$1" = "--outdir" ] && out="${2:-}"; shift; done
  if [ -n "${out}" ]; then mkdir -p "${out}"; : > "${out}/sample-1.0.0.tar.gz"; fi
fi
exit 0
EOF

  # npm stub: just record the call.
  cat > "${BIN}/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm $*" >> "${STUB_LOG}"
exit 0
EOF

  chmod +x "${BIN}/dotnet" "${BIN}/python" "${BIN}/npm"
  export PATH="${BIN}:${PATH}"

  export TOKEN="s3cr3t-token"
  unset STUB_NO_PKG || true
}

teardown() {
  rm -rf "${WORK}"
}

# ── nuget ────────────────────────────────────────────────────────────────

@test "nuget: derives the GitHub Packages feed from OWNER when feed-url is empty" {
  run env ECOSYSTEM=nuget VERSION=1.2.3 OWNER=MagmaMoose PACKAGE_PATH="${WORK}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "https://nuget.pkg.github.com/magmamoose/index.json" "${STUB_LOG}"
  grep -Fq "published=true" "${GITHUB_OUTPUT}"
}

@test "nuget: pack carries the diatreme version and push targets the feed with the token" {
  run env ECOSYSTEM=nuget VERSION=2.0.0-rc.1 \
    FEED_URL=https://nuget.example.com/org/index.json \
    PACKAGE_PATH="${WORK}/proj.csproj" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Eq 'dotnet pack .*-p:PackageVersion=2.0.0-rc.1' "${STUB_LOG}"
  grep -Eq 'dotnet nuget push .*--source https://nuget.example.com/org/index.json' "${STUB_LOG}"
  grep -Eq 'dotnet nuget push .*--api-key s3cr3t-token' "${STUB_LOG}"
  grep -Eq 'dotnet nuget push .*--skip-duplicate' "${STUB_LOG}"
}

@test "nuget: no .nupkg produced -> exit 1, no published output" {
  run env STUB_NO_PKG=1 ECOSYSTEM=nuget VERSION=1.2.3 OWNER=acme PACKAGE_PATH="${WORK}" "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "produced no .nupkg"
  ! grep -Fq "published=true" "${GITHUB_OUTPUT}"
}

# ── pip ──────────────────────────────────────────────────────────────────

@test "pip: builds then twine-uploads to the configured index with --skip-existing" {
  run env ECOSYSTEM=pip VERSION=3.4.5 \
    FEED_URL=https://pypi.example.com/simple/ \
    PACKAGE_PATH="${WORK}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Eq 'python -m build --outdir .*/dist' "${STUB_LOG}"
  grep -Eq 'python -m twine upload .*--skip-existing' "${STUB_LOG}"
  grep -Eq 'python -m twine upload .*--repository-url https://pypi.example.com/simple/' "${STUB_LOG}"
  grep -Fq "published=true" "${GITHUB_OUTPUT}"
}

@test "pip: empty feed-url uploads to PyPI (no --repository-url)" {
  run env ECOSYSTEM=pip VERSION=3.4.5 PACKAGE_PATH="${WORK}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Eq 'python -m twine upload' "${STUB_LOG}"
  ! grep -Eq -- '--repository-url' "${STUB_LOG}"
}

# ── npm ──────────────────────────────────────────────────────────────────

@test "npm: prerelease publishes under the identifier dist-tag and writes an auth .npmrc" {
  PKG="${WORK}/pkg"; mkdir -p "${PKG}"; echo '{"name":"@acme/x","version":"0.0.0"}' > "${PKG}/package.json"
  run env ECOSYSTEM=npm VERSION=1.0.0-dev.2 IS_PRERELEASE=true PRERELEASE_IDENTIFIER=dev \
    FEED_URL=https://npm.pkg.github.com PACKAGE_PATH="${PKG}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Eq 'npm version 1.0.0-dev.2 --no-git-tag-version --allow-same-version' "${STUB_LOG}"
  grep -Eq 'npm publish --registry https://npm.pkg.github.com --tag dev' "${STUB_LOG}"
  grep -Fq "//npm.pkg.github.com/:_authToken=s3cr3t-token" "${PKG}/.npmrc"
  grep -Fq "published=true" "${GITHUB_OUTPUT}"
}

@test "npm: stable publishes on the default latest tag (no --tag)" {
  PKG="${WORK}/pkg"; mkdir -p "${PKG}"; echo '{"name":"@acme/x","version":"0.0.0"}' > "${PKG}/package.json"
  run env ECOSYSTEM=npm VERSION=1.0.0 IS_PRERELEASE=false \
    FEED_URL=https://registry.npmjs.org PACKAGE_PATH="${PKG}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Eq 'npm publish --registry https://registry.npmjs.org' "${STUB_LOG}"
  ! grep -Eq -- '--tag' "${STUB_LOG}"
}

# ── validation ───────────────────────────────────────────────────────────

@test "empty ecosystem -> exit 1 with actionable message" {
  run env ECOSYSTEM='' VERSION=1.2.3 "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "package-ecosystem is empty"
}

@test "unknown ecosystem -> exit 1" {
  run env ECOSYSTEM=maven VERSION=1.2.3 "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "Unsupported package-ecosystem 'maven'"
}

@test "missing VERSION -> exit 1" {
  run env ECOSYSTEM=nuget "${SCRIPT}"
  [ "$status" -eq 1 ]
}

# ── action.yml wiring ────────────────────────────────────────────────────

@test "action.yml gates the publish step on publish-package and released" {
  grep -Eq "inputs.publish-package == 'true'" "${ACTION_YML}"
  grep -Eq "publish-package.sh" "${ACTION_YML}"
  grep -Eq "package-published:" "${ACTION_YML}"
}

@test "action.yml SHA-pins the new setup actions" {
  grep -Fq "actions/setup-dotnet@9a946fdbd5fb07b82b2f5a4466058b876ab72bb2" "${ACTION_YML}"
  grep -Fq "actions/setup-python@a309ff8b426b58ec0e2a45f0f869d46889d02405" "${ACTION_YML}"
  grep -Fq "actions/setup-node@48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e" "${ACTION_YML}"
  # No setup-node left pinned to a floating major tag.
  ! grep -Eq "actions/setup-node@v[0-9]" "${ACTION_YML}"
}
