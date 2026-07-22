# Architecture map

Two independent surfaces in one repo, talking over HTTP (neither imports the other):

- **Composite action** — `action.yml` (~2740 lines, 83 inputs, 44 steps) + `scripts/*.sh`.
  Published to the GitHub Marketplace (`uses: MagmaMoose/diatreme@v2`). Runs on the
  runner. Modes: `ci` (build/push `pr-<N>` image, branch-naming gate, optional
  Trivy scan → SBOM/findings sinks), `release` (versioning → GitHub Release → image
  promotion → promotion PRs), `enable-auto-merge`. `action.yml` is thin glue; real
  logic lives in `scripts/` (bash) and is bats-tested.
- **Cloudflare Worker** — `worker/src/index.ts` (TypeScript, `export default { fetch }`,
  only dep `jose`). Hosted GitHub App backend at `api.diatreme.magmamoose.com`.
  Endpoints: `/token` (OIDC→installation-token broker), `/sign` (App/bot-attributed
  signed commits), `/releases` (KV-cached aggregate), `/webhook` (push auto-update).

The action calls the worker at `/token` (public-app auth) and `/sign`. GitHub
Enterprise (ghe.com/GHES) is opt-in in the worker via `GHE_*` env.

Full detail: read `PROJECT_INDEX.json` (modules/callgraph) and `AGENTS.md` (rules).
