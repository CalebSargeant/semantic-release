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
# `python - <host>` is the PyPI OIDC token-mint heredoc; emit a fake token on
# stdout (the real exchange needs network + id-token, unavailable under test).
if [ "${1:-}" = "-" ]; then echo "pypi-OIDC-MINTED-TOKEN"; exit 0; fi
if [ "${1:-}" = "-m" ] && [ "${2:-}" = "build" ]; then
  out=""; shift 2
  while [ $# -gt 0 ]; do [ "$1" = "--outdir" ] && out="${2:-}"; shift; done
  if [ -n "${out}" ]; then mkdir -p "${out}"; : > "${out}/sample-1.0.0.tar.gz"; fi
fi
exit 0
EOF

  # npm stub: record the call, plus the auth userconfig the script points us at
  # (so tests can assert the token is configured there, not left in the checkout).
  cat > "${BIN}/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm $*" >> "${STUB_LOG}"
if [ -n "${npm_config_userconfig:-}" ] && [ -f "${npm_config_userconfig}" ]; then
  sed 's/^/userconfig: /' "${npm_config_userconfig}" >> "${STUB_LOG}"
fi
exit 0
EOF

  # mvn stub: log calls; on deploy, record the generated settings.xml (so tests
  # can assert the credentials are there, off the project tree).
  cat > "${BIN}/mvn" <<'EOF'
#!/usr/bin/env bash
echo "mvn $*" >> "${STUB_LOG}"
s=""
while [ $# -gt 0 ]; do [ "$1" = "--settings" ] && s="${2:-}"; shift; done
if [ -n "${s}" ] && [ -f "${s}" ]; then sed 's/^/settings: /' "${s}" >> "${STUB_LOG}"; fi
exit 0
EOF

  # gradle stub: log the call + the credential env the script exported (off argv).
  cat > "${BIN}/gradle" <<'EOF'
#!/usr/bin/env bash
echo "gradle $*" >> "${STUB_LOG}"
echo "gradle-env: GITHUB_ACTOR=${GITHUB_ACTOR:-} GITHUB_TOKEN=${GITHUB_TOKEN:-}" >> "${STUB_LOG}"
exit 0
EOF

  # gem stub: on build, create the .gem the push glob expects; on push, record
  # the GEM_HOST_API_KEY env (auth off argv).
  cat > "${BIN}/gem" <<'EOF'
#!/usr/bin/env bash
echo "gem $*" >> "${STUB_LOG}"
if [ "${1:-}" = "build" ]; then
  out=""
  while [ $# -gt 0 ]; do [ "$1" = "--output" ] && out="${2:-}"; shift; done
  [ -n "${out}" ] && { mkdir -p "$(dirname "${out}")"; : > "${out}"; }
fi
[ "${1:-}" = "push" ] && echo "gem-env: GEM_HOST_API_KEY=${GEM_HOST_API_KEY:-}" >> "${STUB_LOG}"
exit 0
EOF

  # docker stub: log calls; on login, capture the token piped via --password-stdin.
  cat > "${BIN}/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "${STUB_LOG}"
if [ "${1:-}" = "login" ]; then read -r pw || true; echo "docker-login-stdin: ${pw}" >> "${STUB_LOG}"; fi
exit 0
EOF

  chmod +x "${BIN}/dotnet" "${BIN}/python" "${BIN}/npm" "${BIN}/mvn" "${BIN}/gradle" "${BIN}/gem" "${BIN}/docker"
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

@test "pip: trusted publishing mints a token via OIDC and uploads to PyPI without package-token" {
  # No TOKEN in the environment — auth comes entirely from the (stubbed) mint.
  run env -u TOKEN ECOSYSTEM=pip VERSION=3.4.5 PYPI_TRUSTED_PUBLISHING=true \
    ACTIONS_ID_TOKEN_REQUEST_URL=https://example/oidc \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN=req-token \
    PACKAGE_PATH="${WORK}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Eq 'python - pypi.org' "${STUB_LOG}"          # mint call for public PyPI
  grep -Eq 'python -m twine upload' "${STUB_LOG}"
  ! grep -Eq -- '--repository-url' "${STUB_LOG}"       # PyPI default endpoint
  grep -Fq "published=true" "${GITHUB_OUTPUT}"
}

@test "pip: trusted publishing targets TestPyPI when feed is test.pypi.org" {
  # TestPyPI path: mint host derives to test.pypi.org and twine gets an explicit
  # --repository-url (unlike the public-PyPI default above).
  run env -u TOKEN ECOSYSTEM=pip VERSION=3.4.5 PYPI_TRUSTED_PUBLISHING=true \
    FEED_URL=https://test.pypi.org/legacy/ \
    ACTIONS_ID_TOKEN_REQUEST_URL=https://example/oidc \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN=req-token \
    PACKAGE_PATH="${WORK}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Eq 'python - test.pypi.org' "${STUB_LOG}"                       # mint host = TestPyPI
  grep -Eq -- '--repository-url https://test.pypi.org/legacy/' "${STUB_LOG}"
  grep -Fq "published=true" "${GITHUB_OUTPUT}"
}

@test "pip: trusted publishing refuses a private/non-PyPI index" {
  run env -u TOKEN ECOSYSTEM=pip VERSION=3.4.5 PYPI_TRUSTED_PUBLISHING=true \
    FEED_URL=https://nexus.example.com/repository/pypi/ \
    PACKAGE_PATH="${WORK}" "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "only supported for public PyPI"
  ! grep -Fq "published=true" "${GITHUB_OUTPUT}"
}

# ── npm ──────────────────────────────────────────────────────────────────

@test "npm: prerelease publishes under the identifier dist-tag and auths via a throwaway userconfig" {
  PKG="${WORK}/pkg"; mkdir -p "${PKG}"; echo '{"name":"@acme/x","version":"0.0.0"}' > "${PKG}/package.json"
  run env ECOSYSTEM=npm VERSION=1.0.0-dev.2 IS_PRERELEASE=true PRERELEASE_IDENTIFIER=dev \
    FEED_URL=https://npm.pkg.github.com PACKAGE_PATH="${PKG}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Eq 'npm version 1.0.0-dev.2 --no-git-tag-version --allow-same-version' "${STUB_LOG}"
  grep -Eq 'npm publish --registry https://npm.pkg.github.com --tag dev' "${STUB_LOG}"
  # Token configured via the throwaway userconfig, not a .npmrc in the checkout.
  grep -Fq "userconfig: //npm.pkg.github.com/:_authToken=s3cr3t-token" "${STUB_LOG}"
  [ ! -f "${PKG}/.npmrc" ]
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

@test "npm: provenance adds --provenance for npmjs when id-token is present" {
  PKG="${WORK}/pkg"; mkdir -p "${PKG}"; echo '{"name":"@acme/x","version":"0.0.0"}' > "${PKG}/package.json"
  run env ECOSYSTEM=npm VERSION=1.0.0 IS_PRERELEASE=false NPM_PROVENANCE=true \
    FEED_URL=https://registry.npmjs.org \
    ACTIONS_ID_TOKEN_REQUEST_URL=https://example/oidc \
    PACKAGE_PATH="${PKG}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Eq 'npm publish --registry https://registry.npmjs.org --provenance' "${STUB_LOG}"
  grep -Fq "published=true" "${GITHUB_OUTPUT}"
}

@test "npm: provenance refuses a non-npmjs (GitHub Packages) feed" {
  PKG="${WORK}/pkg"; mkdir -p "${PKG}"; echo '{"name":"@acme/x","version":"0.0.0"}' > "${PKG}/package.json"
  run env -u ACTIONS_ID_TOKEN_REQUEST_URL ECOSYSTEM=npm VERSION=1.0.0 NPM_PROVENANCE=true \
    FEED_URL=https://npm.pkg.github.com PACKAGE_PATH="${PKG}" "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "only supported when publishing to the public npm registry"
  ! grep -Fq "published=true" "${GITHUB_OUTPUT}"
}

@test "npm: provenance requires id-token: write" {
  PKG="${WORK}/pkg"; mkdir -p "${PKG}"; echo '{"name":"@acme/x","version":"0.0.0"}' > "${PKG}/package.json"
  run env -u ACTIONS_ID_TOKEN_REQUEST_URL ECOSYSTEM=npm VERSION=1.0.0 NPM_PROVENANCE=true \
    FEED_URL=https://registry.npmjs.org PACKAGE_PATH="${PKG}" "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "id-token: write"
}

# ── maven ────────────────────────────────────────────────────────────────

@test "maven: sets the version and deploys to the derived GitHub Packages feed with creds in a temp settings.xml" {
  POM="${WORK}/pom.xml"; echo '<project/>' > "${POM}"
  run env ECOSYSTEM=maven VERSION=1.2.3 REPOSITORY=acme/widget PACKAGE_PATH="${POM}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq 'versions:set -DnewVersion=1.2.3' "${STUB_LOG}"
  grep -Fq -- '-DaltDeploymentRepository=github::https://maven.pkg.github.com/acme/widget' "${STUB_LOG}"
  grep -Fq '<password>s3cr3t-token</password>' "${STUB_LOG}"   # token in the settings.xml, not on argv
  [ ! -f "${WORK}/settings.xml" ]                              # not written into the project tree
  grep -Fq 'published=true' "${GITHUB_OUTPUT}"
}

# ── gradle ───────────────────────────────────────────────────────────────

@test "gradle: publishes with the version and credentials passed via env" {
  PROJ="${WORK}/proj"; mkdir -p "${PROJ}"; : > "${PROJ}/build.gradle"
  run env ECOSYSTEM=gradle VERSION=4.5.6 PACKAGE_PATH="${PROJ}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq 'gradle --no-daemon publish -Pversion=4.5.6' "${STUB_LOG}"
  grep -Fq 'gradle-env: GITHUB_ACTOR=x-access-token GITHUB_TOKEN=s3cr3t-token' "${STUB_LOG}"
  grep -Fq 'published=true' "${GITHUB_OUTPUT}"
}

# ── rubygems ─────────────────────────────────────────────────────────────

@test "rubygems: builds the gemspec and pushes to the derived host with the key in env" {
  PROJ="${WORK}/proj"; mkdir -p "${PROJ}"; : > "${PROJ}/widget.gemspec"
  run env ECOSYSTEM=rubygems VERSION=2.0.0 OWNER=Acme PACKAGE_PATH="${PROJ}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq 'gem build widget.gemspec' "${STUB_LOG}"
  grep -Fq 'gem push --host https://rubygems.pkg.github.com/acme' "${STUB_LOG}"
  grep -Fq 'gem-env: GEM_HOST_API_KEY=Bearer s3cr3t-token' "${STUB_LOG}"
  grep -Fq 'published=true' "${GITHUB_OUTPUT}"
}

# ── container ────────────────────────────────────────────────────────────

@test "container: builds and pushes to ghcr with the token via --password-stdin" {
  CTX="${WORK}/ctx"; mkdir -p "${CTX}"; echo 'FROM scratch' > "${CTX}/Dockerfile"
  run env ECOSYSTEM=container VERSION=1.0.0 REPOSITORY=Acme/Widget PACKAGE_PATH="${CTX}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq 'docker login ghcr.io --username x-access-token --password-stdin' "${STUB_LOG}"
  grep -Fq 'docker-login-stdin: s3cr3t-token' "${STUB_LOG}"   # token via stdin, not argv
  grep -Fq 'docker build --tag ghcr.io/acme/widget:1.0.0' "${STUB_LOG}"
  grep -Fq 'docker push ghcr.io/acme/widget:1.0.0' "${STUB_LOG}"
  grep -Fq 'published=true' "${GITHUB_OUTPUT}"
}

# ── validation ───────────────────────────────────────────────────────────

@test "empty ecosystem -> exit 1 with actionable message" {
  run env ECOSYSTEM='' VERSION=1.2.3 "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "package-ecosystem is empty"
}

@test "unknown ecosystem -> exit 1" {
  run env ECOSYSTEM=cargo VERSION=1.2.3 "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "Unsupported package-ecosystem 'cargo'"
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
  # Assert the pinning discipline, not the specific commits: Dependabot moves
  # these SHAs, so naming them here turns every routine bump into a failure.
  for action in actions/setup-dotnet actions/setup-python actions/setup-node \
                actions/setup-java ruby/setup-ruby; do
    grep -Eq "${action}@[0-9a-f]{40} # v[0-9]" "${ACTION_YML}"
  done
  # No setup action left pinned to a floating major tag.
  ! grep -Eq "actions/setup-(node|java)@v[0-9]" "${ACTION_YML}"
  ! grep -Eq "ruby/setup-ruby@v[0-9]" "${ACTION_YML}"
}

@test "action.yml wires Java/Ruby setup for the JVM/Ruby ecosystems" {
  grep -Fq "inputs.package-ecosystem == 'maven' || inputs.package-ecosystem == 'gradle'" "${ACTION_YML}"
  grep -Fq "actions/setup-java@" "${ACTION_YML}"
  grep -Fq "ruby/setup-ruby@" "${ACTION_YML}"
}

# ── s3 ─────────────────────────────────────────────────────────────────────
#
# The aws CLI is stubbed the same way dotnet/python/npm are above: it logs every
# invocation and answers head-object from a marker file, so the publish/skip
# decision is asserted without a bucket.

s3_stub() {
  cat > "${BIN}/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >> "${STUB_LOG}"
case "${1:-}" in
  sts)
    [ -n "${STUB_NO_SESSION:-}" ] && exit 255
    echo '{"Account":"000000000000"}'
    ;;
  s3api)
    case "${2:-}" in
      head-object)
        [ -n "${STUB_OBJECT_EXISTS:-}" ] && exit 0
        if [ -n "${STUB_ACCESS_DENIED:-}" ]; then
          echo "An error occurred (AccessDenied) when calling the HeadObject operation" >&2
          exit 254
        fi
        exit 254
        ;;
      put-object)  echo '{"ETag":"\"abc\""}' ;;
    esac
    ;;
esac
exit 0
EOF
  chmod +x "${BIN}/aws"
}

@test "s3: uploads the artifact under a version-scoped key" {
  s3_stub
  printf 'zip bytes' > "${WORK}/edge.zip"
  run env PATH="${BIN}:${PATH}" ECOSYSTEM=s3 VERSION=1.2.3 \
    FEED_URL="s3://my-bucket/edge" PACKAGE_PATH="${WORK}/edge.zip" \
    AWS_ROLE_TO_ASSUME="arn:aws:iam::000000000000:role/publisher" \
    bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -q -- "--key edge/1.2.3.zip" "${STUB_LOG}"
  grep -q -- "--bucket my-bucket" "${STUB_LOG}"
  # A checksum so a consumer can verify without downloading.
  grep -q -- "--checksum-algorithm SHA256" "${STUB_LOG}"
}

@test "s3: an existing key is a no-op, never an overwrite" {
  # STRICTER THAN THE OTHER ECOSYSTEMS ON PURPOSE. nuget skips duplicates and docker
  # overwrites a mutable tag; here the key is what a downstream Terraform pins, so
  # replacing its bytes would swap the code under a version someone already reviewed.
  s3_stub
  printf 'zip bytes' > "${WORK}/edge.zip"
  run env PATH="${BIN}:${PATH}" STUB_OBJECT_EXISTS=1 ECOSYSTEM=s3 VERSION=1.2.3 \
    FEED_URL="s3://my-bucket/edge" PACKAGE_PATH="${WORK}/edge.zip" \
    AWS_ROLE_TO_ASSUME="arn:aws:iam::000000000000:role/publisher" \
    bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  ! grep -q "put-object" "${STUB_LOG}"
  grep -q "published=false" "${GITHUB_OUTPUT}"
}

@test "s3: a missing OIDC session fails with an actionable message, not a 403" {
  s3_stub
  printf 'zip bytes' > "${WORK}/edge.zip"
  run env PATH="${BIN}:${PATH}" STUB_NO_SESSION=1 ECOSYSTEM=s3 VERSION=1.2.3 \
    FEED_URL="s3://my-bucket/edge" PACKAGE_PATH="${WORK}/edge.zip" \
    AWS_ROLE_TO_ASSUME="arn:aws:iam::000000000000:role/publisher" \
    bash "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"configure-aws-credentials"* ]]
  [[ "$output" == *"id-token: write"* ]]
}

@test "s3: package-path must be a file, not a directory" {
  s3_stub
  run env PATH="${BIN}:${PATH}" ECOSYSTEM=s3 VERSION=1.2.3 \
    FEED_URL="s3://my-bucket/edge" PACKAGE_PATH="${WORK}" \
    AWS_ROLE_TO_ASSUME="arn:aws:iam::000000000000:role/publisher" \
    bash "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be the built artifact FILE"* ]]
}

@test "s3: a bucket with no prefix works" {
  s3_stub
  printf 'zip bytes' > "${WORK}/edge.zip"
  run env PATH="${BIN}:${PATH}" ECOSYSTEM=s3 VERSION=9.9.9 \
    FEED_URL="s3://flat-bucket" PACKAGE_PATH="${WORK}/edge.zip" \
    AWS_ROLE_TO_ASSUME="arn:aws:iam::000000000000:role/publisher" \
    bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -q -- "--key 9.9.9.zip" "${STUB_LOG}"
}

@test "action.yml threads the role through to the publish step" {
  grep -q "aws-role-to-assume:" "${ACTION_YML}"
  grep -q "AWS_ROLE_TO_ASSUME: " "${ACTION_YML}"
}

@test "s3: extensionless artifact produces a key with no dot suffix" {
  s3_stub
  printf 'binary bytes' > "${WORK}/myapp"
  run env PATH="${BIN}:${PATH}" ECOSYSTEM=s3 VERSION=2.0.0 \
    FEED_URL="s3://my-bucket/edge" PACKAGE_PATH="${WORK}/myapp" \
    AWS_ROLE_TO_ASSUME="arn:aws:iam::000000000000:role/publisher" \
    bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -qE "\-\-key edge/2\.0\.0( |$)" "${STUB_LOG}"
}

@test "s3: AccessDenied on head-object blocks the write and names the required permission" {
  s3_stub
  printf 'zip bytes' > "${WORK}/edge.zip"
  run env PATH="${BIN}:${PATH}" STUB_ACCESS_DENIED=1 ECOSYSTEM=s3 VERSION=1.2.3 \
    FEED_URL="s3://my-bucket/edge" PACKAGE_PATH="${WORK}/edge.zip" \
    AWS_ROLE_TO_ASSUME="arn:aws:iam::000000000000:role/publisher" \
    bash "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"s3:GetObject"* ]] || [[ "$output" == *"s3:ListBucket"* ]]
  ! grep -q "put-object" "${STUB_LOG}"
}
