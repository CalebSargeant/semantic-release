# The Diatreme Worker

The Cloudflare Worker behind the hosted broker at `https://api.diatreme.magmamoose.com`.
It is the **GitHub App backend** for the action's release flows, so callers don't
have to register and run their own GitHub App. Entry point: `worker/src/index.ts`
(`export default { fetch }`); the only runtime dependency is `jose`.

Full source-of-truth reference: [`worker/README.md`](https://github.com/MagmaMoose/diatreme/blob/main/worker/README.md).

## Endpoints

| Method + path | Purpose | Auth |
| --- | --- | --- |
| `POST /token` | Exchange a GitHub Actions OIDC token for a short-lived App installation token (this is what `auth-mode: public-app` uses). | OIDC (`id-token: write`) |
| `POST /sign` | Create a GitHub-signed, App/bot-attributed commit (version bumps / tags) via `createCommitOnBranch`. | `Bearer PROCESS_TRIGGER_SECRET` |
| `GET /releases` | Aggregated latest-release history across the App's installations (KV-cached; caps surfaced via `truncated`, never silent). | `Bearer PROCESS_TRIGGER_SECRET` |
| Webhook `push` | Fast-forward every open PR targeting the pushed branch. | HMAC (`GITHUB_WEBHOOK_SECRET`) |

## Configuration

Secrets are set with `wrangler secret put <NAME>` and never committed.

| Secret / var | Required | Purpose |
| --- | --- | --- |
| `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY` | yes | The github.com App that `/token` and `/sign` act as. |
| `OIDC_AUDIENCE` | no (default `diatreme`) | Expected OIDC audience for `/token`. |
| `PROCESS_TRIGGER_SECRET` | for `/sign`, `/releases` | Bearer that gates the signer and release aggregate. |
| `GITHUB_WEBHOOK_SECRET` | for push auto-update | HMAC secret for the webhook receiver. |
| `AUTO_UPDATE_BRANCHES` | no | Opt-in flag; enables the push auto-update behaviour. |
| `ALLOWED_REPOSITORIES` | no | Comma-separated allowlist for `/token`. |
| `GHE_OIDC_ISSUER`, `GHE_API_BASE`, `GHE_GITHUB_APP_ID`, `GHE_GITHUB_APP_PRIVATE_KEY`, `GHE_GITHUB_APP_INSTALLATION_ID` | opt-in | GitHub Enterprise (ghe.com / GHES) support. |

!!! note "Legacy KV binding name"
    The KV namespace that caches the `/releases` aggregate is bound as
    `COPILOT_QUOTA_KV` (a legacy name kept for deploy compatibility after the
    Copilot features were removed) and its id is injected at deploy time from the
    `COPILOT_QUOTA_KV_ID` Actions variable. Without it, `/releases` just recomputes.

## Develop and deploy

```bash
cd worker
npm install
npm run check     # typecheck + tests + wrangler dry-run
wrangler dev      # run locally against .dev.vars
wrangler deploy   # ship to Cloudflare
```

Pushes to `main` touching `worker/**` deploy automatically via
`deploy-worker.yaml` (needs `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID`).
