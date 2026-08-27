# Broker configuration

<!-- sources: broker/app, broker/scripts/build_lambda_zip.py, worker/src/index.ts, worker/wrangler.jsonc, worker/.dev.vars.example, .github/workflows/deploy-worker.yaml -->

Everything the broker reads at runtime. You only need this page if you self-host
a broker or operate the hosted one. Consumers of the action configure nothing
here: they set action inputs, which are documented in the
[repository README](https://github.com/MagmaMoose/diatreme#inputs).

All of these are read per request from the runtime environment, so changing one
takes effect on the next request after a redeploy. None of them are read from a
file at boot.

On Cloudflare, secrets are set with `wrangler secret put <NAME>` and the KV
namespaces are bound at deploy time. On AWS they come from SSM Parameter Store
and the Lambda environment. See [Deployment](../operations/deployment.md).

## Required

| Name | Type | Default | Secret | Effect |
| --- | --- | --- | --- | --- |
| `GITHUB_APP_ID` | string | none | no | Numeric App ID of the github.com GitHub App the broker acts as. Without it, `/token` and `/sign` cannot mint anything and `/releases` returns `503 app_unconfigured`. |
| `GITHUB_APP_PRIVATE_KEY` | string (PEM) | none | yes | The App's private key. Accepts a real multi-line PEM or a single line with literal `\n` escapes. |

```text
GITHUB_APP_ID=<your-app-id>
GITHUB_APP_PRIVATE_KEY=<your-app-private-key-pem>
```

## Optional

### `OIDC_AUDIENCE`

Comma-separated list of OIDC audiences `/token` accepts. Entries are trimmed and
empties dropped.

| | |
| --- | --- |
| Type | comma-separated string |
| Default | `diatreme,release-runner` |
| Secret | no |

Blank or whitespace-only falls back to the default pair rather than accepting
nothing. `release-runner` is the pre-rename audience, still accepted so
long-pinned consumers keep working. A token whose `aud` isn't in the list fails
with `401 invalid_oidc_token` and `reason: audience_mismatch`.

The action sends whatever its `oidc-audience` input says, defaulting to
`diatreme`. Change one without the other and every release in every repository
pinned to that version breaks, so treat this list as append-only.

### `ALLOWED_REPOSITORIES`

Comma-separated `owner/name` allowlist for `/token`.

| | |
| --- | --- |
| Type | comma-separated string |
| Default | unset, meaning every repository the App is installed on is allowed |
| Secret | no |

```text
ALLOWED_REPOSITORIES=MagmaMoose/diatreme,MagmaMoose/chargate
```

Matching is exact string equality after trimming. There's no globbing, so
`MagmaMoose/*` matches nothing. A repository outside the list gets
`403 repo_not_allowed`.

### `TOKEN_PERMISSIONS`

Permissions stamped on the installation tokens `/token` mints.

| | |
| --- | --- |
| Type | JSON object, or a comma-separated `key=value` / `key:value` list |
| Default | `contents: write`, `pull_requests: write` |
| Secret | no |

```text
TOKEN_PERMISSIONS={"contents":"write","pull_requests":"write","packages":"write"}
TOKEN_PERMISSIONS=contents=write,pull_requests=write
```

Keys must be lowercase with underscores, matching GitHub's App permission names.
Values must be exactly `read` or `write`. Anything else, including a value of
`admin` or an empty parse result, makes `/token` return
`400 invalid_token_permissions` for every request. Blank or unset gives you the
default pair.

`/sign` ignores this and always mints with `contents: write` only.

!!! warning "You cannot grant what the App doesn't have"
    This narrows or names permissions on the token. It can't exceed what the
    GitHub App itself was granted at install time. Asking for a permission the
    App lacks gets you a token without it, not an error.

### `PROCESS_TRIGGER_SECRET`

Bearer token gating `POST /sign` and `GET /releases`.

| | |
| --- | --- |
| Type | string |
| Default | unset |
| Secret | yes |

Unset means both routes return `503` (`sign_disabled`, `releases_disabled`) and
neither can be reached. Compared in constant time. The hosted broker sets it;
a self-hosted broker that only needs `/token` can leave it out.

### `GITHUB_WEBHOOK_SECRET`

HMAC-SHA256 secret for `POST /webhook`, matching the secret configured on the
GitHub App.

| | |
| --- | --- |
| Type | string |
| Default | unset |
| Secret | yes |

Unset means `/webhook` returns `503 webhook_disabled`.

### `AUTO_UPDATE_BRANCHES`

Enables the push auto-update behaviour behind `/webhook`.

| | |
| --- | --- |
| Type | string flag |
| Default | unset, disabled |
| Secret | no |

Enabled only by the exact values `1`, `true`, `yes` or `on`, case-insensitive
after trimming. Every other value, including `enabled`, leaves it off. With it
off, verified webhook deliveries are accepted and do nothing.

## GitHub Enterprise

All five are opt-in and only meaningful together. Setting `GHE_OIDC_ISSUER` is
what turns GHE support on: `/token` then trusts two issuers instead of one, and
mints against whichever one actually signed the token.

| Name | Required for GHE | Secret | Effect |
| --- | --- | --- | --- |
| `GHE_OIDC_ISSUER` | yes | no | The tenant's OIDC issuer, for example `https://token.actions.example.ghe.com`. Trailing slashes and stray whitespace are stripped. |
| `GHE_API_BASE` | yes | no | The tenant's REST base, for example `https://example.ghe.com/api/v3`. |
| `GHE_GITHUB_APP_ID` | yes | no | App ID of the duplicate App registered on the tenant. |
| `GHE_GITHUB_APP_PRIVATE_KEY` | yes | yes | That App's private key. |
| `GHE_GITHUB_APP_INSTALLATION_ID` | no | no | Skips the per-repo installation lookup, saving one API call. Ignored unless it parses to a positive integer. |

A github.com token is still verified against github.com and minted with the
github.com App. The issuer is pinned before its key set is selected, so a forged
`iss` can't make the broker verify against the wrong tenant's keys.

## KV namespaces (Cloudflare only)

Both are optional. Neither is hard-coded in `wrangler.jsonc`, so a self-hosted
deploy without them still works.

| Binding | Purpose | Without it |
| --- | --- | --- |
| `DIATREME_JWKS_CACHE` | Last-known-good JWKS snapshot per issuer, written after each successful verification. | The broker has no fallback when an issuer's key endpoint is unreachable, and returns `503 oidc_key_fetch_failed` instead of rescuing the request. |
| `COPILOT_QUOTA_KV` | Caches the `GET /releases` aggregate. | `/releases` recomputes on every call. Nothing else changes. |

Create and bind them:

```bash
wrangler kv namespace create DIATREME_JWKS_CACHE
wrangler kv namespace create COPILOT_QUOTA_KV
```

The deploy workflow injects the IDs from the `DIATREME_JWKS_CACHE_ID` and
`COPILOT_QUOTA_KV_ID` Actions variables, so the namespace IDs never land in the
repository. Set neither and the injection step is skipped entirely.

!!! note "COPILOT_QUOTA_KV is a legacy name"
    The Copilot features that namespace was created for were removed. The
    binding name is kept because `env.COPILOT_QUOTA_KV` is what the code reads,
    and renaming it would orphan the cached data for no benefit. It has nothing
    to do with Copilot now.

## Local development

Copy the example and fill it in:

```bash
cp worker/.dev.vars.example worker/.dev.vars
```

`.dev.vars` is gitignored. `wrangler dev` reads it. The example file covers the
App credentials and the GHE block; add any of the optional variables above by
hand if you're working on those paths.

## Related

- [Broker API](broker-api.md) for the routes these settings govern.
- [Limits](limits.md) for the caps and TTLs that aren't configurable.
