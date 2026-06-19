# Diatreme Worker

The Cloudflare Worker behind the hosted Diatreme broker at
`https://api.diatreme.magmamoose.com`. It is the runtime backend the
[Diatreme composite action](../README.md) calls — so callers don't have to run
their own GitHub App — and the dispatch/signing engine for autonomous fixes.

Self-contained: the only runtime dependency is [`jose`](https://github.com/panva/jose)
(JWT signing for GitHub App auth). Entry point is `src/index.ts`
(`export default { fetch, scheduled }`).

## Endpoints

| Method + path | Purpose | Auth |
| --- | --- | --- |
| `POST /token` | Exchange a GitHub Actions OIDC token for a short-lived App installation token. | OIDC (`id-token: write`) |
| `POST /process` | Triage Copilot PR-review comments; route each to a fix or a dismissal. | `Bearer PROCESS_TRIGGER_SECRET` |
| `POST /sign` | Create a GitHub-signed, user-attributed commit via `createCommitOnBranch`. | `Bearer PROCESS_TRIGGER_SECRET` |
| `POST /dispatch` | Hand an autonomous coding task to Claude Code (see [`DISPATCH.md`](DISPATCH.md)). | `Bearer PROCESS_TRIGGER_SECRET` |
| `GET /copilot-quota` | Remaining Copilot review quota for the action's review gate. | — |
| `GET /oauth/connect` + callback | Authorize user-attributed signing for `/sign`. | GitHub OAuth |
| Scheduled (cron `*/15 * * * *`) | Refresh the Copilot billing cache for seen owners. | — |

## Configuration

Secrets are set with `wrangler secret put <NAME>` (never committed). For local
`wrangler dev`, copy [`.dev.vars.example`](.dev.vars.example) to `.dev.vars`
(gitignored) and fill it in.

| Secret / var | Required | Purpose |
| --- | --- | --- |
| `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY` | yes | The github.com App `/token` mints installation tokens with. |
| `OIDC_AUDIENCE` | no (default `diatreme`) | Expected OIDC audience. |
| `PROCESS_TRIGGER_SECRET` | for `/process` `/sign` `/dispatch` | Bearer that gates the privileged endpoints. |
| `TRIAGE_LLM_API_KEY`, `TRIAGE_LLM_PROVIDER`, `TRIAGE_LLM_MODEL` | for triage | LLM classifier for `/process` (e.g. `deepseek` / `deepseek-chat`). |
| `DISPATCH_TRIGGER_URL`, `DISPATCH_ROUTINE_TOKEN` | for `/dispatch` | Claude Code routine fire URL + token (see [`DISPATCH.md`](DISPATCH.md)). |
| `GHE_OIDC_ISSUER`, `GHE_API_BASE`, `GHE_GITHUB_APP_ID`, `GHE_GITHUB_APP_PRIVATE_KEY`, `GHE_GITHUB_APP_INSTALLATION_ID` | opt-in | GitHub Enterprise (ghe.com / GHES) support. |

**KV binding** — `COPILOT_QUOTA_KV` backs `/copilot-quota` (billing cache +
manual overrides) and the OAuth connect-state store. The namespace ID is not
committed; CI injects it from the `COPILOT_QUOTA_KV_ID` Actions variable (see
[`../.github/workflows/deploy-worker.yaml`](../.github/workflows/deploy-worker.yaml)).
Without it, those endpoints degrade gracefully.

## Develop

```bash
npm install
npm run typecheck   # tsc --noEmit
npm test            # vitest
npm run check       # typecheck + test + wrangler dry-run deploy
npm run coverage    # vitest with coverage
wrangler dev        # run locally against .dev.vars
wrangler deploy     # ship to Cloudflare
```

## Deploy

Pushes to `main` that touch `worker/**` deploy automatically via
[`deploy-worker.yaml`](../.github/workflows/deploy-worker.yaml) (needs
`CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` repo secrets). Or deploy by hand
with `wrangler deploy`.

The private observability dashboard for this worker (run history, manual trigger,
agent dispatches) is the separate
[`MagmaMoose/diatreme-pro`](https://github.com/MagmaMoose/diatreme-pro) repo.
