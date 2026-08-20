# Architecture map

Two independent surfaces, talking over HTTP. Neither imports the other.

- **Composite action** — `action.yml` (~2740 lines, ~83 inputs, ~44 steps) + `scripts/*.sh`.
  Marketplace-published, runs on the runner. Modes: `ci`, `release`, `enable-auto-merge`.
  Thin glue; logic is bash in `scripts/`, bats-tested.
- **Hosted broker** — the GitHub-App backend called for `auth-mode: public-app`. `/token`
  (OIDC → App installation token), `/sign`, `/releases`, `/webhook`. GHE opt-in via `GHE_*`.

## Where the broker actually runs (changed 2026-08-20)

`worker/` (TypeScript, Cloudflare) is the code of record on `main`, **but it no longer
serves any hostname.** `api.diatreme.magmamoose.com` and `broker-diatreme.magmamoose.com`
both resolve to an AWS Lambda broker behind API Gateway. A Python port is in flight; until
it merges `worker/` is what to read, what CI validates, and the rollback.

**An edit to `worker/` does not change production.** See `.claude/INFRA_NOTES.md`.

Diatreme **fails hard** — the client exits non-zero on any broker fault, so a broken broker
is a red X on every consumer's release.

Detail: `PROJECT_INDEX.json` (modules, callgraph), `AGENTS.md` (rules).
