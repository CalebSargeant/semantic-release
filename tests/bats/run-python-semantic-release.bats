#!/usr/bin/env bats

# Behaviour coverage for scripts/run-python-semantic-release.sh.
#
# The script replaces the upstream Docker-based python-semantic-release
# action, so the thing worth pinning down is the argv it hands to the
# `semantic-release` CLI: those flags are what reproduce the action inputs
# action.yml used to pass. Each test points PSR_BIN at a stub that records
# its arguments and environment, which also keeps the suite off PyPI.
#
# The tail of the file guards the version pin itself. Dropping the Docker action
# also dropped the only ecosystem that watched its version, so the tests assert
# that the pin lives in scripts/psr-requirements.txt as an exact `==`, that
# action.yml holds no competing literal, and that .github/dependabot.yml still
# points a `pip` entry at it — the tracking is the feature, and it fails silently.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/run-python-semantic-release.sh"
REQUIREMENTS_FILE="${BATS_TEST_DIRNAME}/../../scripts/psr-requirements.txt"
ACTION_YML="${BATS_TEST_DIRNAME}/../../action.yml"
DEPENDABOT_YML="${BATS_TEST_DIRNAME}/../../.github/dependabot.yml"

setup() {
  WORK=$(mktemp -d)
  export ARGS_FILE="${WORK}/args"
  export TOKEN_FILE="${WORK}/token"

  # Hermetic: a developer's global gitconfig must not decide whether the
  # script thinks user.name is already set.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  # Hermetic: the venv the install path builds must land under WORK, not in the
  # real /tmp that `RUNNER_TEMP:-/tmp` would otherwise fall back to.
  export RUNNER_TEMP="${WORK}/runner-temp"
  mkdir -p "${RUNNER_TEMP}"

  REPO="${WORK}/repo"
  git init --initial-branch=main "${REPO}" >/dev/null
  cd "${REPO}" || return 1

  # Kept in its own variable so the install-path test, which must unset PSR_BIN
  # to exercise the venv, can still plant this stub as the installed CLI.
  export PSR_STUB="${WORK}/semantic-release"
  cat > "${PSR_STUB}" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${ARGS_FILE}"
printf '%s' "${GH_TOKEN:-<unset>}" > "${TOKEN_FILE}"
exit "${STUB_EXIT:-0}"
STUB
  chmod +x "${PSR_STUB}"
  export PSR_BIN="${PSR_STUB}"

  export GH_TOKEN=fake-token
  export INPUT_GIT_COMMITTER_NAME="github-actions[bot]"
  unset INPUT_PRERELEASE INPUT_PRERELEASE_TOKEN INPUT_FORCE INPUT_CHANGELOG || true
  unset PYTHON_BIN STUB_EXIT || true
}

teardown() {
  cd / || true
  rm -rf "${WORK}"
}

# Recorded argv, one arg per line, flattened to a single space-separated line.
psr_args() {
  tr '\n' ' ' < "${ARGS_FILE}"
}

@test "always passes the flags action.yml pinned on the Docker action" {
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(psr_args)" = "-v version --commit --no-vcs-release --skip-build " ]
}

@test "exports GH_TOKEN to semantic-release" {
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(cat "${TOKEN_FILE}")" = "fake-token" ]
}

@test "refuses to run without GH_TOKEN" {
  unset GH_TOKEN
  run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GH_TOKEN is required"* ]]
  [ ! -f "${ARGS_FILE}" ]
}

@test "prerelease=true maps to --as-prerelease, not --prerelease" {
  export INPUT_PRERELEASE=true
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$(psr_args)" == *" --as-prerelease "* ]]
  [[ "$(psr_args)" != *" --prerelease "* ]]
}

@test "prerelease=false omits the flag entirely" {
  export INPUT_PRERELEASE=false
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$(psr_args)" != *"prerelease"* ]]
}

@test "prerelease token is passed as a separate argument" {
  export INPUT_PRERELEASE=true INPUT_PRERELEASE_TOKEN=dev
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$(psr_args)" == *"--prerelease-token dev "* ]]
}

@test "prerelease token is dropped when empty" {
  export INPUT_PRERELEASE=true INPUT_PRERELEASE_TOKEN=""
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$(psr_args)" != *"--prerelease-token"* ]]
}

@test "changelog=true maps to --changelog" {
  export INPUT_CHANGELOG=true
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$(psr_args)" == *" --changelog "* ]]
}

@test "changelog=false maps to --no-changelog" {
  export INPUT_CHANGELOG=false
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$(psr_args)" == *" --no-changelog "* ]]
}

@test "a non-boolean changelog value is an error" {
  export INPUT_CHANGELOG=yes
  run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::Invalid value for changelog"* ]]
  [ ! -f "${ARGS_FILE}" ]
}

@test "a non-boolean prerelease value is an error" {
  export INPUT_PRERELEASE=1
  run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::Invalid value for prerelease"* ]]
  [ ! -f "${ARGS_FILE}" ]
}

@test "each supported force-bump level becomes its own flag" {
  for level in prerelease patch minor major; do
    export INPUT_FORCE="${level}"
    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$(psr_args)" == *" --${level} "* ]]
  done
}

@test "an unrecognised force-bump warns and releases anyway" {
  export INPUT_FORCE=bogus
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::Ignoring force-bump:"* ]]
  [[ "$output" == *"force-bump was: bogus"* ]]
  [[ "$(psr_args)" != *"bogus"* ]]
  [[ "$(psr_args)" == *"version"* ]]
}

@test "an unrecognised force-bump cannot forge a workflow command" {
  # A workflow_dispatch input can carry newlines. The runner only treats a line
  # that *starts* with `::` as a command, so the guarantee to assert is that no
  # emitted line begins with the forged one — `printf %q` escapes the newline,
  # keeping the value on a single line.
  export INPUT_FORCE='bogus
::error::forged'
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  refuted=0
  while IFS= read -r emitted; do
    [[ "${emitted}" == "::error::forged"* ]] && refuted=1
  done <<< "$output"
  [ "${refuted}" -eq 0 ]
}

@test "an empty force-bump adds no flag" {
  export INPUT_FORCE=""
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(psr_args)" = "-v version --commit --no-vcs-release --skip-build " ]
}

@test "sets the committer name when the repo has none" {
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(git config --get user.name)" = "github-actions[bot]" ]
}

@test "keeps a committer name the caller already configured" {
  git config user.name "release-bot"
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(git config --get user.name)" = "release-bot" ]
}

@test "configures no committer name when the input is empty" {
  export INPUT_GIT_COMMITTER_NAME=""
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  run git config --get user.name
  [ "$status" -ne 0 ]
}

@test "propagates the semantic-release exit code" {
  export STUB_EXIT=2
  run bash "${SCRIPT}"
  [ "$status" -eq 2 ]
}

@test "demands an interpreter when it has to install semantic-release" {
  unset PSR_BIN
  run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PYTHON_BIN is required"* ]]
}

@test "installs from the requirements file, resolved next to the script" {
  unset PSR_BIN
  export PIP_ARGS_FILE="${WORK}/pip-args"
  export PYTHON_BIN="${WORK}/python"

  # A stub interpreter. `-m venv <dir>` is all the script asks of PYTHON_BIN, so
  # the stub lays down the two executables it then reaches for: a `python` that
  # records the pip argv, and the semantic-release stub as the installed CLI.
  # This exercises the real install path without touching PyPI.
  cat > "${PYTHON_BIN}" <<'PY'
#!/usr/bin/env bash
[ "$1" = "-m" ] && [ "$2" = "venv" ] || { echo "unexpected python argv: $*" >&2; exit 1; }
mkdir -p "$3/bin"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$@" >> "${PIP_ARGS_FILE}"' > "$3/bin/python"
chmod +x "$3/bin/python"
cp "${PSR_STUB}" "$3/bin/semantic-release"
PY
  chmod +x "${PYTHON_BIN}"

  # cwd is the test repo, not the script's directory: a script that resolved the
  # requirements file relative to cwd would fail here, exactly as it would under
  # action.yml's `working-directory:`.
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]

  # pip was pointed at the real requirements file by absolute path...
  pip_args=$(tr '\n' ' ' < "${PIP_ARGS_FILE}")
  [[ "${pip_args}" == *"-m pip install "* ]]
  [[ "${pip_args}" == *"--requirement "* ]]
  [[ "${pip_args}" == *"/scripts/psr-requirements.txt"* ]]

  # ...and the CLI the venv produced is what actually ran.
  [ "$(psr_args)" = "-v version --commit --no-vcs-release --skip-build " ]
}

@test "reports the pin it is installing" {
  unset PSR_BIN
  export PYTHON_BIN="${WORK}/python"
  cat > "${PYTHON_BIN}" <<'PY'
#!/usr/bin/env bash
# Guard the argv before touching "$3": an empty $3 would make the lines below
# write to /bin/python, and `mkdir -p /bin` succeeds silently because it exists.
[ "$1" = "-m" ] && [ "$2" = "venv" ] || { echo "unexpected python argv: $*" >&2; exit 1; }
mkdir -p "$3/bin"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$3/bin/python"
chmod +x "$3/bin/python"
cp "${PSR_STUB}" "$3/bin/semantic-release"
PY
  chmod +x "${PYTHON_BIN}"

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  # The exact pin belongs in the release log; comments must not be echoed with it.
  [[ "$output" == *"python-semantic-release=="* ]]
  [[ "$output" != *"# The python-semantic-release CLI"* ]]
}

# Lay out a setup-python-style interpreter under $1: <prefix>/bin/python beside a
# <prefix>/lib dir. The stub records the LD_LIBRARY_PATH it was invoked with to
# ${LD_PATH_FILE}, then services the `-m venv <dir>` call the script makes by
# planting the venv's python (a no-op) and the semantic-release stub it execs.
make_shared_python() {
  local prefix="$1"
  mkdir -p "${prefix}/bin" "${prefix}/lib"
  export PYTHON_BIN="${prefix}/bin/python"
  cat > "${PYTHON_BIN}" <<'PY'
#!/usr/bin/env bash
printf '%s' "${LD_LIBRARY_PATH:-<unset>}" > "${LD_PATH_FILE}"
[ "$1" = "-m" ] && [ "$2" = "venv" ] || { echo "unexpected python argv: $*" >&2; exit 1; }
mkdir -p "$3/bin"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$3/bin/python"
chmod +x "$3/bin/python"
cp "${PSR_STUB}" "$3/bin/semantic-release"
PY
  chmod +x "${PYTHON_BIN}"
}

@test "puts the interpreter's lib dir on LD_LIBRARY_PATH so a shared-library CPython can start" {
  # actions/setup-python's --enable-shared CPython loads libpython from a sibling
  # lib/ dir; update-environment:false means the action never exports that path,
  # and some self-hosted runners ignore the build's RPATH, so a direct call dies
  # with "error while loading shared libraries: libpython...". The export reaches
  # the base interpreter (asserted here), and thereby the venv and CLI it spawns.
  unset PSR_BIN LD_LIBRARY_PATH
  export LD_PATH_FILE="${WORK}/ld-path"
  make_shared_python "${WORK}/py"

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(cat "${LD_PATH_FILE}")" = "${WORK}/py/lib" ]
}

@test "prepends the lib dir to an existing LD_LIBRARY_PATH instead of replacing it" {
  unset PSR_BIN
  export LD_PATH_FILE="${WORK}/ld-path"
  export LD_LIBRARY_PATH=/preexisting/lib
  make_shared_python "${WORK}/py"

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(cat "${LD_PATH_FILE}")" = "${WORK}/py/lib:/preexisting/lib" ]
}

@test "leaves LD_LIBRARY_PATH untouched when the interpreter has no sibling lib dir" {
  # A statically linked interpreter (no <prefix>/lib beside it) needs no loader
  # help and must not be handed a path that does not exist.
  unset PSR_BIN LD_LIBRARY_PATH
  export LD_PATH_FILE="${WORK}/ld-path"
  mkdir -p "${WORK}/nolib/bin"
  export PYTHON_BIN="${WORK}/nolib/bin/python"
  cat > "${PYTHON_BIN}" <<'PY'
#!/usr/bin/env bash
printf '%s' "${LD_LIBRARY_PATH:-<unset>}" > "${LD_PATH_FILE}"
[ "$1" = "-m" ] && [ "$2" = "venv" ] || { echo "unexpected python argv: $*" >&2; exit 1; }
mkdir -p "$3/bin"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$3/bin/python"
chmod +x "$3/bin/python"
cp "${PSR_STUB}" "$3/bin/semantic-release"
PY
  chmod +x "${PYTHON_BIN}"

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(cat "${LD_PATH_FILE}")" = "<unset>" ]
}

# Run a copy of the script beside a requirements file with the given content.
# A copy, because the script resolves the file relative to its own location.
run_with_requirements() {
  local content="$1" dir="${WORK}/scripts-$2"
  mkdir -p "${dir}"
  cp "${SCRIPT}" "${dir}/"
  printf '%s' "${content}" > "${dir}/psr-requirements.txt"
  run bash "${dir}/$(basename "${SCRIPT}")"
}

@test "fails loudly when the requirements file holds only comments" {
  # `pip install -r` on an all-comments file succeeds and installs nothing; the
  # gap would otherwise surface as a missing binary several lines later.
  unset PSR_BIN
  export PYTHON_BIN="${WORK}/python"
  : > "${PYTHON_BIN}"
  chmod +x "${PYTHON_BIN}"

  run_with_requirements '# nothing but a comment

' comments
  [ "$status" -ne 0 ]
  [[ "$output" == *"names no requirement to install"* ]]
}

@test "fails loudly when the requirements file holds only pip options" {
  # `--index-url` alone is not a requirement: pip would install nothing and exit 0.
  # A guard that only skipped comments would wave this through.
  unset PSR_BIN
  export PYTHON_BIN="${WORK}/python"
  : > "${PYTHON_BIN}"
  chmod +x "${PYTHON_BIN}"

  run_with_requirements '# options, but nothing to install
--index-url https://pypi.org/simple
--no-binary :all:
' options
  [ "$status" -ne 0 ]
  [[ "$output" == *"names no requirement to install"* ]]
}

@test "an option line alongside a real requirement is accepted" {
  # The guard must not reject a legitimate file that carries both.
  unset PSR_BIN
  export PYTHON_BIN="${WORK}/python"
  cat > "${PYTHON_BIN}" <<'PY'
#!/usr/bin/env bash
[ "$1" = "-m" ] && [ "$2" = "venv" ] || { echo "unexpected python argv: $*" >&2; exit 1; }
mkdir -p "$3/bin"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$3/bin/python"
chmod +x "$3/bin/python"
cp "${PSR_STUB}" "$3/bin/semantic-release"
PY
  chmod +x "${PYTHON_BIN}"

  run_with_requirements '--index-url https://pypi.org/simple
python-semantic-release==10.6.1
' mixed
  [ "$status" -eq 0 ]
  [[ "$output" == *"python-semantic-release=="* ]]
}

@test "fails loudly when the requirements file is missing" {
  unset PSR_BIN
  export PYTHON_BIN="${WORK}/python"
  : > "${PYTHON_BIN}"
  chmod +x "${PYTHON_BIN}"

  fake_scripts="${WORK}/scripts-bare"
  mkdir -p "${fake_scripts}"
  cp "${SCRIPT}" "${fake_scripts}/"

  run bash "${fake_scripts}/$(basename "${SCRIPT}")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing"* ]]
  [[ "$output" == *"psr-requirements.txt"* ]]
}

@test "every requirement is an exact pin, python-semantic-release included" {
  # `==` on every line: psr writes consumers' changelogs, tags and version
  # files, so a range would make releases irreproducible. The rule covers the
  # whole file, not just psr, because the file may also carry a pin for one of
  # psr's own dependencies — an unpinned transitive dep is what broke every
  # consumer release when GitPython 3.1.60 dropped `Actor.name_email_regex`.
  [ -f "${REQUIREMENTS_FILE}" ]
  run grep -vE '^[[:space:]]*(#|$)' "${REQUIREMENTS_FILE}"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -ge 1 ]

  local line psr_pins=0
  for line in "${lines[@]}"; do
    [[ "${line}" =~ ^[A-Za-z0-9._-]+==[0-9]+\.[0-9]+\.[0-9]+$ ]]
    if [[ "${line}" == python-semantic-release==* ]]; then
      psr_pins=$((psr_pins + 1))
    fi
  done
  [ "${psr_pins}" -eq 1 ]
}

@test "action.yml carries no hand-maintained version pin for psr" {
  # Scoped to a *literal* value: action.yml legitimately sets
  # `PSR_VERSION: ${{ steps.psr.outputs.version }}` on a later step, and that
  # must keep working. What must never come back is a version baked in here,
  # which no Dependabot ecosystem can see.
  run grep -nE "PSR_VERSION:[[:space:]]*['\"]?[0-9]" "${ACTION_YML}"
  [ "$status" -ne 0 ]
}

@test "dependabot tracks the requirements file, and only from /scripts" {
  # The regression this guards: as a `uses:` the version was tracked by the
  # github-actions ecosystem; as a pip pin it is tracked only while this entry
  # exists. Drop the entry and the pin rots silently.
  #
  # Asserting the pip directories are *exactly* ["/scripts"] also pins the
  # scoping: Dependabot fetches manifests relative to `directory`, so a pip entry
  # at `/` would pick up the root pyproject.toml — which is psr's own release
  # metadata, not a dependency manifest.
  #
  # awk rather than a YAML load: `YAML.safe_load_file` needs Ruby >= 3.0, which
  # macOS system Ruby (2.6) lacks — the same reason action-script-refs.bats
  # stays grep-based.
  run awk '
    /^[[:space:]]*-[[:space:]]*package-ecosystem:/ {
      eco = $0
      sub(/.*package-ecosystem:[[:space:]]*/, "", eco)
      gsub(/["'"'"']/, "", eco)
      next
    }
    /^[[:space:]]*directory:/ {
      dir = $0
      sub(/.*directory:[[:space:]]*/, "", dir)
      gsub(/["'"'"']/, "", dir)
      if (eco == "pip") print dir
    }
  ' "${DEPENDABOT_YML}"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "/scripts" ]

  # And the pin actually sits in the directory dependabot is pointed at.
  [ -f "${BATS_TEST_DIRNAME}/../..${lines[0]}/psr-requirements.txt" ]
}

@test "action.yml no longer references the Docker-based upstream action" {
  # Guards the regression this script exists to fix: a `uses:` on a Docker
  # action makes every release run build the image during job setup, even
  # when the step is skipped. Matched loosely so a re-add with different
  # spacing can't slip past.
  run grep -nE "uses:[[:space:]]*python-semantic-release/" "${ACTION_YML}"
  [ "$status" -ne 0 ]
}
