#!/usr/bin/env bats

# Behaviour coverage for scripts/check-release-actor.sh — the gate that decides
# whether the actor driving a run may cut a release to the current environment.
#
# `gh` is stubbed so the team-membership API can be driven from the test:
# STUB_ACTIVE_TEAMS / STUB_PENDING_TEAMS list `org/slug/login` triples that
# resolve to those states, anything else answers 404 the way the real API does,
# and STUB_GH_ERROR forces an arbitrary non-404 failure. The stub logs its argv
# to STUB_LOG, so a test can assert that no API call happened at all — which is
# the whole point of the login-only and below-threshold paths.
#
# The load-bearing distinction throughout: a 404 is a normal "not a member" and
# lets the next entry be tried, while every other fault must deny the release.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/check-release-actor.sh"

# Ordered upstream → production, so '@last' is 'prod'.
ENVS='["test","acc","prod"]'

setup() {
  WORK=$(mktemp -d)
  BIN="${WORK}/bin"
  mkdir -p "${BIN}"
  export STUB_LOG="${WORK}/stub.log"
  : > "${STUB_LOG}"

  cat > "${BIN}/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "${STUB_LOG}"
if [ -n "${STUB_GH_ERROR:-}" ]; then
  echo "${STUB_GH_ERROR}" >&2
  exit 1
fi
# argv: api /orgs/<org>/teams/<slug>/memberships/<login> --jq .state
key="${2#/orgs/}"
org="${key%%/*}"
rest="${key#*/teams/}"
slug="${rest%%/*}"
login="${rest##*/}"
for t in ${STUB_ACTIVE_TEAMS:-}; do
  [ "${t}" = "${org}/${slug}/${login}" ] && { echo active; exit 0; }
done
for t in ${STUB_PENDING_TEAMS:-}; do
  [ "${t}" = "${org}/${slug}/${login}" ] && { echo pending; exit 0; }
done
echo "gh: Not Found (HTTP 404)" >&2
exit 1
EOF
  chmod +x "${BIN}/gh"
  export PATH="${BIN}:${PATH}"
}

teardown() {
  rm -rf "${WORK}"
}

# Six variables have to be present for every case and only one or two vary, so
# the defaults live here; `env` applies assignments left to right, which makes
# any trailing NAME=VALUE argument an override.
check() {
  run env ACTOR=alice OWNER=acme THRESHOLD='@last' CURRENT_ENV=prod \
    ENVIRONMENTS="${ENVS}" "$@" "${SCRIPT}"
}

# ── inert until configured ──────────────────────────────────────────────────

@test "an empty allowlist leaves releases unrestricted (exit 0)" {
  check ALLOWED_ACTORS=""
  [ "$status" -eq 0 ]
  [[ "$output" == *"unrestricted"* ]]
  [ ! -s "${STUB_LOG}" ]
}

@test "a whitespace-only allowlist is unrestricted too" {
  check ALLOWED_ACTORS=$' \n\t '
  [ "$status" -eq 0 ]
  [[ "$output" == *"unrestricted"* ]]
}

@test "an empty allowlist stays inert even when the environments are misconfigured" {
  # The gate must not turn a config it never consults into a failed release.
  check ALLOWED_ACTORS="" ENVIRONMENTS='[]' CURRENT_ENV=""
  [ "$status" -eq 0 ]
}

# ── login matching ──────────────────────────────────────────────────────────

@test "a listed login is allowed without any API call" {
  check ALLOWED_ACTORS="bob,alice,carol"
  [ "$status" -eq 0 ]
  [[ "$output" == *"named in allowed-release-actors"* ]]
  [ ! -s "${STUB_LOG}" ]
}

@test "login matching is case-insensitive" {
  check ACTOR=Alice ALLOWED_ACTORS="ALICE"
  [ "$status" -eq 0 ]
}

@test "a login may be written with a leading @" {
  # '@alice' is tried as a login before it is tried as a team, so the common
  # habit of @-prefixing people costs no API call and needs no org permission.
  check ALLOWED_ACTORS="@alice"
  [ "$status" -eq 0 ]
  [ ! -s "${STUB_LOG}" ]
}

@test "a JSON array allowlist is accepted" {
  check ALLOWED_ACTORS='["bob", "alice"]'
  [ "$status" -eq 0 ]
}

@test "entries may be newline-separated" {
  check ALLOWED_ACTORS=$'bob\nalice\n'
  [ "$status" -eq 0 ]
}

@test "commas, newlines and stray whitespace may be mixed" {
  check ALLOWED_ACTORS=$'  bob ,  carol\n  alice  \n'
  [ "$status" -eq 0 ]
}

# ── threshold ───────────────────────────────────────────────────────────────

@test "an environment upstream of the threshold is not gated, and asks gh nothing" {
  check CURRENT_ENV=acc ALLOWED_ACTORS="bob"
  [ "$status" -eq 0 ]
  [[ "$output" == *"upstream of threshold"* ]]
  [ ! -s "${STUB_LOG}" ]
}

@test "@last resolves to the final environment" {
  check ALLOWED_ACTORS="bob"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'@last' resolved to 'prod'"* ]]
}

@test "an explicit threshold gates that environment and everything downstream" {
  check THRESHOLD=acc CURRENT_ENV=acc ALLOWED_ACTORS="bob"
  [ "$status" -eq 1 ]
  check THRESHOLD=acc CURRENT_ENV=test ALLOWED_ACTORS="bob"
  [ "$status" -eq 0 ]
}

@test "@last against an empty environments array is a configuration error" {
  check ENVIRONMENTS='[]' ALLOWED_ACTORS="alice"
  [ "$status" -eq 1 ]
  [[ "$output" == *"environments is empty"* ]]
}

@test "a threshold that is not an environment is a configuration error" {
  check THRESHOLD=nope ALLOWED_ACTORS="alice"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not in environments"* ]]
}

@test "an unknown CURRENT_ENV is a configuration error" {
  check CURRENT_ENV=staging ALLOWED_ACTORS="alice"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'staging' is not in environments"* ]]
}

@test "an empty CURRENT_ENV is a configuration error" {
  check CURRENT_ENV="" ALLOWED_ACTORS="alice"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not resolve current environment"* ]]
}

# ── team membership ─────────────────────────────────────────────────────────

@test "an active team membership allows the release" {
  check ALLOWED_ACTORS="@acme/release-managers" \
    STUB_ACTIVE_TEAMS="acme/release-managers/alice"
  [ "$status" -eq 0 ]
  [[ "$output" == *"active member of @acme/release-managers"* ]]
  grep -Fq "gh api /orgs/acme/teams/release-managers/memberships/alice" "${STUB_LOG}"
}

@test "a team written without an org resolves against the repository owner" {
  check ALLOWED_ACTORS="@release-managers" \
    STUB_ACTIVE_TEAMS="acme/release-managers/alice"
  [ "$status" -eq 0 ]
  grep -Fq "/orgs/acme/teams/release-managers/" "${STUB_LOG}"
}

@test "a team in another org is looked up in that org" {
  check ALLOWED_ACTORS="@partner/release-managers" \
    STUB_ACTIVE_TEAMS="partner/release-managers/alice"
  [ "$status" -eq 0 ]
  grep -Fq "/orgs/partner/teams/release-managers/" "${STUB_LOG}"
}

@test "a 404 means 'not a member' and the next entry is still tried" {
  check ALLOWED_ACTORS="@acme/oncall,@acme/release-managers" \
    STUB_ACTIVE_TEAMS="acme/release-managers/alice"
  [ "$status" -eq 0 ]
  grep -Fq "/teams/oncall/" "${STUB_LOG}"
  grep -Fq "/teams/release-managers/" "${STUB_LOG}"
}

@test "404s on every team deny the release" {
  check ALLOWED_ACTORS="@acme/oncall,@acme/release-managers"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed to cut a release"* ]]
  # A plain negative, not an error about the lookup itself.
  [[ "$output" != *"Could not check"* ]]
}

@test "a pending team invitation is not membership" {
  check ALLOWED_ACTORS="@acme/release-managers" \
    STUB_PENDING_TEAMS="acme/release-managers/alice"
  [ "$status" -eq 1 ]
  [[ "$output" == *"state='pending'"* ]]
}

@test "a team entry naming no team is a configuration error" {
  check ALLOWED_ACTORS="@acme/"
  [ "$status" -eq 1 ]
  [[ "$output" == *"names no team"* ]]
}

@test "a bare @team with no owner to resolve it against is a configuration error" {
  check OWNER="" ALLOWED_ACTORS="@release-managers"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no organization"* ]]
}

# ── fail closed ─────────────────────────────────────────────────────────────

@test "a non-404 membership failure denies the release" {
  check ALLOWED_ACTORS="@acme/release-managers" \
    STUB_GH_ERROR="gh: Resource not accessible by integration (HTTP 403)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::Could not check whether alice is a member of @acme/release-managers"* ]]
  [[ "$output" == *"Members: Read"* ]]
}

@test "a broken lookup stops the check rather than falling through to later entries" {
  # Falling through would end in the generic denial, telling the operator their
  # actor is not on the list when the truth is that nobody could be checked.
  check ALLOWED_ACTORS="@acme/release-managers,@acme/oncall" \
    STUB_GH_ERROR="gh: API rate limit exceeded (HTTP 403)"
  [ "$status" -eq 1 ]
  ! grep -Fq "/teams/oncall/" "${STUB_LOG}"
}

@test "a 5xx whose body mentions 'not found' is still an error, not a negative" {
  # The 404 test is on the status, never on prose the upstream happens to emit.
  check ALLOWED_ACTORS="@acme/release-managers" \
    STUB_GH_ERROR="gh: HTTP 502: upstream service not found (https://api.github.com)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not check"* ]]
}

@test "gh being unavailable denies the release rather than reading as a 404" {
  # The shell's own "command not found" lands on the same stderr the 404 test
  # reads, so a loose match there would turn a missing CLI into "not a member"
  # — a silent negative instead of a loud failure.
  check ALLOWED_ACTORS="@acme/release-managers" \
    STUB_GH_ERROR="check-release-actor.sh: line 1: gh: command not found"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not check"* ]]
}

@test "an unparseable JSON array is refused, not read as an empty list" {
  check ALLOWED_ACTORS='["alice"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a parseable JSON array"* ]]
}

@test "an allowlist of nothing but separators is refused" {
  check ALLOWED_ACTORS=" , , "
  [ "$status" -eq 1 ]
  [[ "$output" == *"no usable entries"* ]]
}

@test "an unresolvable actor is denied, never matched against an empty entry" {
  check ACTOR="" ALLOWED_ACTORS="alice"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not resolve the actor"* ]]
}

# ── denial message ──────────────────────────────────────────────────────────

@test "the denial names the actor, the environment and the configured allowlist" {
  check ALLOWED_ACTORS="bob,carol"
  [ "$status" -eq 1 ]
  [[ "$output" == *"alice is not allowed to cut a release to 'prod'"* ]]
  [[ "$output" == *"allowed-release-actors is set to: bob,carol"* ]]
}

@test "a multi-line allowlist is echoed back on one line in the annotation" {
  # ::error:: annotations are single-line; an unflattened value would show the
  # operator only its first entry.
  check ALLOWED_ACTORS=$'bob\ncarol\n'
  [ "$status" -eq 1 ]
  [[ "$output" == *"allowed-release-actors is set to: bob carol"* ]]
}

# ── re-runs cannot launder the actor ────────────────────────────────────────
#
# `github.actor` on a re-run is the person who started the ORIGINAL run, not
# whoever pressed re-run. Checking it alone would leave the gate open to one
# click: anyone with write access could re-run an allowed person's failed
# release and thereby cut production under their name, with the log recording a
# clean pass. `github.triggering_actor` is who pressed the button, so both have
# to clear the list.

@test "a re-run by someone not on the list is refused" {
  check ALLOWED_ACTORS="alice" TRIGGERING_ACTOR=mallory
  [ "$status" -eq 1 ]
  [[ "$output" == *"triggered by mallory on behalf of alice"* ]]
  [[ "$output" == *"::error::mallory is not allowed to cut a release to 'prod'"* ]]
}

@test "a re-run by someone who is also on the list is allowed" {
  check ALLOWED_ACTORS="alice,bob" TRIGGERING_ACTOR=bob
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ alice is named in allowed-release-actors"* ]]
  [[ "$output" == *"✓ bob is named in allowed-release-actors"* ]]
}

@test "an allowed re-runner cannot carry a disallowed original actor through" {
  # The converse direction: the initiator is checked too, so re-running is not
  # a way to launder a release someone unlisted started.
  check ACTOR=mallory ALLOWED_ACTORS="alice" TRIGGERING_ACTOR=alice
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::mallory is not allowed to cut a release to 'prod'"* ]]
}

@test "the ordinary case — both logins identical — costs no extra work" {
  check ALLOWED_ACTORS="alice" TRIGGERING_ACTOR=alice
  [ "$status" -eq 0 ]
  [[ "$output" != *"on behalf of"* ]]
}

@test "a differing triggering actor is compared case-insensitively" {
  check ALLOWED_ACTORS="alice" TRIGGERING_ACTOR=Alice
  [ "$status" -eq 0 ]
  [[ "$output" != *"on behalf of"* ]]
}

@test "an unset triggering actor leaves the original behaviour intact" {
  check ALLOWED_ACTORS="alice"
  [ "$status" -eq 0 ]
  [[ "$output" != *"on behalf of"* ]]
}
