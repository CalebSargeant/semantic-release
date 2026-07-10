#!/usr/bin/env bats

# Every `${GITHUB_ACTION_PATH}/scripts/*.sh` that action.yml invokes must exist
# and be executable in the tree we publish.
#
# This repo runs with `core.fileMode=false`, so a new script is committed 100644
# unless the author remembers `git update-index --chmod=+x`. Nothing else catches
# it: actionlint, shellcheck and the rest of the bats suite all pass on a
# non-executable script, and the failure only surfaces at runtime in a consumer's
# release job as "Permission denied".
#
# Deliberately grep-based rather than a YAML walk: `YAML.safe_load_file` needs
# Ruby >= 3.0, which macOS system Ruby (2.6) does not have. That already makes
# action-shell-syntax.bats CI-only; this guard is cheap enough to run everywhere.

ACTION_YML="${BATS_TEST_DIRNAME}/../../action.yml"
REPO_ROOT="${BATS_TEST_DIRNAME}/../.."

# Every distinct script path action.yml refers to, one per line.
referenced_scripts() {
  grep -oE '\$\{GITHUB_ACTION_PATH\}/[A-Za-z0-9_./-]+\.sh' "${ACTION_YML}" \
    | sed 's|^\${GITHUB_ACTION_PATH}/||' \
    | sort -u
}

@test "action.yml references at least one script" {
  # Guards the guard: a silently-empty match set would make the tests below vacuous.
  run referenced_scripts
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -gt 0 ]
}

@test "every script action.yml invokes exists" {
  missing=()
  while IFS= read -r script; do
    [ -f "${REPO_ROOT}/${script}" ] || missing+=("${script}")
  done < <(referenced_scripts)
  [ "${#missing[@]}" -eq 0 ] || { echo "missing: ${missing[*]}"; false; }
}

@test "every script action.yml invokes is executable" {
  not_exec=()
  while IFS= read -r script; do
    [ -x "${REPO_ROOT}/${script}" ] || not_exec+=("${script}")
  done < <(referenced_scripts)
  [ "${#not_exec[@]}" -eq 0 ] || {
    echo "not executable: ${not_exec[*]}"
    echo "fix with: git update-index --chmod=+x ${not_exec[*]}"
    false
  }
}

@test "every script action.yml invokes is committed with the exec bit" {
  # `core.fileMode=false` means a local chmod is invisible to git. Assert the
  # mode recorded in the index, which is what actually ships.
  command -v git >/dev/null || skip "git not available"
  bad=()
  while IFS= read -r script; do
    mode=$(git -C "${REPO_ROOT}" ls-files -s -- "${script}" | cut -d' ' -f1)
    [ "${mode}" = "100755" ] || bad+=("${script} (${mode:-untracked})")
  done < <(referenced_scripts)
  [ "${#bad[@]}" -eq 0 ] || { echo "wrong index mode: ${bad[*]}"; false; }
}
