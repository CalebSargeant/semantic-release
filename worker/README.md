# Diatreme Worker

The Cloudflare Worker behind the hosted Diatreme broker at
`https://api.diatreme.magmamoose.com`. It is the **GitHub App backend** for the
[Diatreme composite action](../README.md)'s release flows, so callers don't have
to register and run their own GitHub App. Its whole job is release/deployment
orchestration:

- **Token broker**: exchange a GitHub Actions OIDC token for a short-lived App
  **installation** token (this is what `auth-mode: public-app` uses).
- **Commit/tag signer**: create GitHub-signed, **App/bot-attributed** release
  commits (version bumps, tags) via `createCommitOnBranch`.
- **Release history**: aggregate releases for the dashboard.

Self-contained: the only runtime dependency is [`jose`](https://github.com/panva/jose)
(JWT signing for GitHub App auth). Entry point is `src/index.ts`
(`export default { fetch }`).

## Endpoints

| Method + path | Purpose | Auth |
| --- | --- | --- |
| `POST /token` | Exchange a GitHub Actions OIDC token for a short-lived App installation token. | OIDC (`id-token: write`) |
| `POST /sign` | Create a GitHub-signed, **App/bot-attributed** commit (release version bumps / tags) via `createCommitOnBranch`. | `Bearer PROCESS_TRIGGER_SECRET` |
| `GET /releases` | Aggregated release history (for the dashboard). | `Bearer PROCESS_TRIGGER_SECRET` |
| Webhook `push` | Fast-forward open PRs targeting the pushed branch (opt-in via `AUTO_UPDATE_BRANCHES`). | HMAC (`GITHUB_WEBHOOK_SECRET`) |

## Configuration

Secrets are set with `wrangler secret put <NAME>` (never committed). For local
`wrangler dev`, copy [`.dev.vars.example`](.dev.vars.example) to `.dev.vars`
(gitignored) and fill it in.

| Secret / var | Required | Purpose |
| --- | --- | --- |
| `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY` | yes | The github.com App that `/token` and `/sign` act as. |
| `OIDC_AUDIENCE` | no (default `diatreme`) | Expected OIDC audience for `/token`. |
| `PROCESS_TRIGGER_SECRET` | for `/sign`, `/releases` | Bearer that gates the signer and the release aggregate. |
| `GITHUB_WEBHOOK_SECRET` | for push auto-update | HMAC secret for the webhook receiver. |
| `AUTO_UPDATE_BRANCHES` | no | Opt-in flag; when truthy, a `push` webhook fast-forwards open PRs targeting the pushed branch. |
| `ALLOWED_REPOSITORIES` | no | Comma-separated allowlist of `owner/repo` for `/token`; empty allows any repo the App is installed on. |
| `GHE_OIDC_ISSUER`, `GHE_API_BASE`, `GHE_GITHUB_APP_ID`, `GHE_GITHUB_APP_PRIVATE_KEY`, `GHE_GITHUB_APP_INSTALLATION_ID` | opt-in | GitHub Enterprise (ghe.com / GHES) support. |

**KV binding**: `COPILOT_QUOTA_KV` (legacy name) caches the aggregated `/releases`
response. The namespace ID is not committed; CI injects it from the
`COPILOT_QUOTA_KV_ID` Actions variable (see
[`../.github/workflows/deploy-worker.yaml`](../.github/workflows/deploy-worker.yaml)).
Without it, `/releases` just recomputes.

## Develop

```bash
npm install
npm run typecheck   # tsc --noEmit
npm test            # vitest
npm run check       # typecheck + tests + wrangler dry-run deploy
wrangler dev        # run locally against .dev.vars
wrangler deploy     # ship to Cloudflare
```

## Deploy

Pushes to `main` that touch `worker/**` deploy automatically via
[`deploy-worker.yaml`](../.github/workflows/deploy-worker.yaml) (needs
`CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` repo secrets). Or deploy by hand
with `wrangler deploy`.

The private observability dashboard for this worker (release history, run history)
is the separate [`MagmaMoose/diatreme-pro`](https://github.com/MagmaMoose/diatreme-pro)
repo.
