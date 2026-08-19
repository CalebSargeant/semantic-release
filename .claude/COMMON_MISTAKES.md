# Common mistakes (footguns)

- **One root action file.** Keep exactly one `action.yml` at repo root; CI fails
  otherwise. Preserve input/output **names, defaults, and behavior**; changing them
  is a breaking change for every consumer. Keep README examples aligned with it.
- **Shell scripts need the exec bit in Git.** `core.fileMode=false` here, so a new
  `scripts/*.sh` ships `100644` and breaks CI. Run
  `git update-index --chmod=+x scripts/<f>.sh`. (`.mjs` run via `node` don't need it.)
- **Keep the worker self-contained**: only runtime dep is `jose`. Don't couple it
  to `scripts/`, and never vendor code from the private `MagmaMoose/diatreme-pro`.
- **`bats tests/bats` fails only `action-shell-syntax` locally** on macOS system Ruby
  2.6 (`YAML.safe_load_file` missing). Not a real failure; it passes on CI.
- **Legacy name, not a bug:** the KV binding `COPILOT_QUOTA_KV` (+ `COPILOT_QUOTA_KV_ID`
  deploy var) now just caches `/releases`. Copilot/triage/quota features were removed;
  don't reintroduce them.
- **`createRemoteJWKSet` does NOT reliably self-heal a key rotation.** jose only
  refetches on a `kid` miss when its cooldown (30s) has lapsed, and its own
  freshness refetch arms that cooldown in the same call — so a miss inside that
  window is terminal for the request. `worker/src/index.ts` forces one reload
  itself, cache-bypassing and throttled per issuer. Its *other* JWKS fetches
  deliberately ride a 30s colo TTL: jose's reloads are unthrottled and it disables
  its own in-flight dedupe on Workers, so without a cache a burst of unknown-`kid`
  tokens becomes one GitHub subrequest each. Don't collapse the two policies, and
  don't shorten `cooldownDuration` — that only widens the unthrottled path.
  `test/jwks-rotation.test.ts` guards all of it.
- **Never swallow an error with a bare `catch {}` on the /token path.** That is
  what turned a JWKS outage into a permanent, unfalsifiable `invalid_oidc_token`
  (issue #147). Classify on jose's `.code` — never `instanceof JOSEError` (every
  jose error extends it) — and log one structured line.
- **Never commit** secrets, `.dev.vars`, or caches (`node_modules/`, `.wrangler/`,
  `coverage/`, `site/`).
- After editing `scripts/`, run `shellcheck -S warning scripts/*.sh` and `actionlint`.
