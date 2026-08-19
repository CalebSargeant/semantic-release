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
| `OIDC_AUDIENCE` | no (default `diatreme`, plus legacy `release-runner`) | Accepted OIDC audience(s) for `/token`. Trimmed and comma-separated; blank or whitespace-only falls back to the defaults. |
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

## `/token` failure responses

Every failure carries a stable `error` string plus a coarse, non-sensitive
`reason` naming *which* check failed. The action prints both, and the worker logs
one structured `oidc_verify_failed` line per verification failure.

| Status | `error` | `reason` | Meaning |
| --- | --- | --- | --- |
| 400 | `invalid_json` / `invalid_request` / `missing_required_fields` | — | Malformed request body. |
| 401 | `invalid_oidc_token` | `malformed_token` | Not a decodable JWT. |
| 401 | `invalid_oidc_token` | `kid_not_found` | No signing key for the token's `kid`, even after a forced JWKS re-fetch. |
| 401 | `invalid_oidc_token` | `signature_invalid` | Signature did not verify. |
| 401 | `invalid_oidc_token` | `audience_mismatch` | `aud` is not in the accepted list (see `OIDC_AUDIENCE`). |
| 401 | `invalid_oidc_token` | `issuer_mismatch` | `iss` is not a trusted issuer. |
| 401 | `invalid_oidc_token` | `token_expired` / `token_not_yet_valid` | `exp` / `nbf` outside the window. |
| 401 | `invalid_oidc_token` | `key_ambiguous` / `claim_invalid` / `alg_unsupported` / `unknown` | Other verification failures. |
| 403 | `repo_mismatch` | — | The token's `repository` claim does not match `owner`/`repo`. |
| 403 | `repo_not_allowed` | — | Repository is outside `ALLOWED_REPOSITORIES`. |
| 404 | `app_not_installed` | — | The App is not installed on that repository. |
| 503 | `oidc_key_fetch_failed` | `jwks_unavailable` | The broker could not retrieve the issuer's JWKS (timeout, non-200, network). Retryable — this is broker/upstream unavailability, **not** a bad token. |

To read the log line for a failure:

```bash
npx wrangler tail diatreme --format json --search oidc_verify_failed
```

It carries the classified `reason`, jose's error code, the token's `kid`, `iss`,
`aud`, `repository`, `iat` and `exp`, and the audience/issuers the broker expected
— never the token itself.

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
