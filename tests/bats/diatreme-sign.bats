#!/usr/bin/env bats

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/diatreme-sign.py"

setup() {
  REPO="$(mktemp -d)"
  cd "${REPO}"
  git init -q
  git config user.email t@t.co
  git config user.name t
  printf 'old-a\n' > a.txt
  printf 'bbb\n' > b.txt
  git add -A && git commit -qm base
  BASE="$(git rev-parse HEAD)"
}

teardown() {
  rm -rf "${REPO}"
}

@test "dry-run payload captures additions, deletions and the head oid" {
  printf 'new-a\n' > a.txt   # modified
  printf 'ccc\n' > c.txt     # added
  rm b.txt                   # deleted

  run python3 "${SCRIPT}" --repo o/r --branch br --message "fix: x" --dry-run
  [ "$status" -eq 0 ]

  printf '%s' "$output" | BASE="${BASE}" python3 -c '
import base64, json, os, sys
p = json.load(sys.stdin)
assert p["expected_head_oid"] == os.environ["BASE"], p["expected_head_oid"]
assert {a["path"] for a in p["additions"]} == {"a.txt", "c.txt"}
assert {d["path"] for d in p["deletions"]} == {"b.txt"}
a = next(a for a in p["additions"] if a["path"] == "a.txt")
assert base64.b64decode(a["contents"]).decode().strip() == "new-a"
assert p["repo"] == "o/r" and p["branch"] == "br"
assert p["message"]["headline"] == "fix: x"
'
}

@test "exits non-zero when there are no changes" {
  run python3 "${SCRIPT}" --repo o/r --branch br --message noop --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"no working-tree changes"* ]]
}

@test "requires worker env when actually signing" {
  printf 'more\n' >> a.txt
  run env -u DIATREME_BASE_URL -u DIATREME_SIGN_TOKEN -u DIATREME_USER \
    python3 "${SCRIPT}" --repo o/r --branch br --message m
  [ "$status" -eq 2 ]
}
