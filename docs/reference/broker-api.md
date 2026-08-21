# Broker API

<!-- sources: worker/src/index.ts, worker/README.md, scripts/request-public-app-token.sh -->

The broker is the GitHub App backend the action calls when `auth-mode` is
`public-app`. Four routes, all on the same origin. Anything else returns
`404 not_found`.

Base URL for the hosted broker:

```text
https://api.diatreme.magmamoose.com
```

`https://broker-diatreme.magmamoose.com` serves the same application and is the
fallback the action tries when the primary is unreachable. See
[Deployment](../operations/deployment.md) for which infrastructure answers each
name.

Every response is JSON. Every failure carries a stable `error` string, and
`/token` verification failures also carry a coarse `reason`. Neither is
localised and neither changes shape between versions, so you can match on them.

## POST /token

Exchange a GitHub Actions OIDC token for a short-lived GitHub App installation
token. This is the route `auth-mode: public-app` uses on every release.

**Auth:** the OIDC token in the body. The calling job needs `id-token: write`.
There is no API key.

### Request

`Content-Type: application/json`

| Field | Type | Required | Effect |
| --- | --- | --- | --- |
| `oidcToken` | string | yes | The Actions OIDC JWT, minted for the `oidc-audience` the broker accepts. |
| `owner` | string | yes | Repository owner. Must match the token's `repository` claim. |
| `repo` | string | yes | Repository name. Must match the token's `repository` claim. |
| `ref` | string | no | Recorded for logging only. Never authorises anything. |
| `runId` | string | no | Recorded for logging only. |
| `sha` | string | no | Recorded for logging only. |

```bash
curl -sS -X POST https://api.diatreme.magmamoose.com/token \
  -H 'Content-Type: application/json' \
  --data '{"oidcToken":"<jwt>","owner":"MagmaMoose","repo":"diatreme"}'
```

### Success

`200 OK`

```json
{
  "token": "ghs_xxxxxxxxxxxxxxxxxxxx",
  "expires_at": "2026-08-20T13:00:00Z",
  "repository": "MagmaMoose/diatreme"
}
```

The token is a GitHub App installation token scoped to that one repository. Its
permissions default to `contents: write` and `pull_requests: write`, overridable
per deployment with [`TOKEN_PERMISSIONS`](configuration.md#token_permissions).
GitHub sets the lifetime, currently one hour, and the broker passes
`expires_at` through unchanged rather than computing it.

The action masks the token in the run log and writes it to the step outputs
`token`, `expires-at` and `repository`.

### Failures

| Status | `error` | When |
| --- | --- | --- |
| 400 | `invalid_json` | Body isn't parseable JSON. |
| 400 | `invalid_request` | Body parsed but isn't a JSON object. |
| 400 | `missing_required_fields` | One of `oidcToken`, `owner`, `repo` is absent or empty. |
| 400 | `invalid_token_permissions` | The deployment's `TOKEN_PERMISSIONS` is set but parses to nothing usable. A broker misconfiguration, not a caller error. |
| 401 | `invalid_oidc_token` | The token failed verification. Carries a `reason`. |
| 403 | `repo_mismatch` | The token's `repository` claim isn't `owner/repo`. |
| 403 | `repo_not_allowed` | The repository is outside the deployment's `ALLOWED_REPOSITORIES`. |
| 404 | `app_not_installed` | The Diatreme App isn't installed on that repository. |
| 405 | `method_not_allowed` | Anything other than POST. |
| 500 | `github_installation_lookup_failed` | GitHub answered the installation lookup with something unusable. |
| 503 | `oidc_key_fetch_failed` | The broker couldn't retrieve the issuer's key set. Retryable. Carries `reason: jwks_unavailable`. |

The split between 401 and 503 is deliberate and load-bearing. A 401 means the
broker reached GitHub's key set and your token failed against it. A 503 means
the broker never got a verdict. Retrying a 401 will not help. Retrying a 503
often will. Every `reason` value and its fix is in
[Errors](errors.md#token-verification-failures).

## POST /sign

Create a GitHub-signed, App-attributed commit on a branch through
`createCommitOnBranch`. Diatreme uses it so version bumps and release commits
show as verified and attributed to the App rather than to a person.

**Auth:** `Authorization: Bearer <PROCESS_TRIGGER_SECRET>`. Returns
`503 sign_disabled` when that secret isn't configured, so a deployment that
doesn't set it simply has no signer.

### Request

| Field | Type | Required | Effect |
| --- | --- | --- | --- |
| `repo` | string | yes | `owner/name`. |
| `branch` | string | yes | Branch to commit on. |
| `expected_head_oid` | string | yes | The commit SHA the branch must currently point at. GitHub rejects the write if it moved, which is what makes this safe to retry. |
| `message.headline` | string | yes | Commit subject. |
| `message.body` | string | no | Commit body. |
| `additions` | array | one of the two | `[{ "path": "...", "contents": "<base64>" }]`. |
| `deletions` | array | one of the two | `[{ "path": "..." }]`. |
| `user` | string | no | Accepted and ignored. Commits are App-attributed. |

At least one of `additions` or `deletions` must be non-empty.

### Success

`200 OK` with `{ "ok": true, "commit": { ... } }`, carrying GitHub's commit
object.

### Failures

| Status | `error` | When |
| --- | --- | --- |
| 400 | `invalid_json` / `invalid_request` | Malformed body. |
| 400 | `missing_required_fields` | `repo`, `branch`, `expected_head_oid` or `message.headline` absent. |
| 400 | `no_file_changes` | Both `additions` and `deletions` are empty. |
| 400 | `invalid_repo` | `repo` isn't `owner/name`. |
| 401 | `unauthorized` | Bearer missing or wrong. Compared in constant time. |
| 405 | `method_not_allowed` | Anything other than POST. |
| 502 | `installation_token_failed` | The broker couldn't mint a token for that repo. |
| 502 | `sign_failed` | GitHub rejected the commit, commonly because `expected_head_oid` is stale. |
| 503 | `sign_disabled` | `PROCESS_TRIGGER_SECRET` isn't set on this deployment. |

## GET /releases

Latest release per repository, aggregated across the App's installations. It
backs the private dashboard, not the action.

**Auth:** `Authorization: Bearer <PROCESS_TRIGGER_SECRET>`.

### Success

`200 OK`

```json
{
  "generated_at": "2026-08-20T09:00:00.000Z",
  "repos": [
    {
      "repo": "MagmaMoose/diatreme",
      "latest": {
        "tag": "v2.4.6",
        "name": "v2.4.6",
        "published_at": "2026-08-20T01:15:00Z",
        "url": "https://github.com/MagmaMoose/diatreme/releases/tag/v2.4.6",
        "draft": false,
        "prerelease": false
      }
    }
  ],
  "truncated": false,
  "cached": true
}
```

`latest` is `null` for a repository with no releases. `cached: true` means the
response came from the KV cache rather than a fresh crawl. `truncated: true`
means the aggregate hit a traversal cap, so the list is incomplete. The caps are
in [Limits](limits.md#releases-aggregate). They are always reported, never
applied silently.

### Failures

| Status | `error` | When |
| --- | --- | --- |
| 401 | `unauthorized` | Bearer missing or wrong. |
| 405 | `method_not_allowed` | Anything other than GET. |
| 503 | `releases_disabled` | `PROCESS_TRIGGER_SECRET` isn't set. |
| 503 | `app_unconfigured` | `GITHUB_APP_ID` or `GITHUB_APP_PRIVATE_KEY` isn't set. |

## POST /webhook

Receiver for the Diatreme App's webhook deliveries. Only `push` is acted on: it
fast-forwards every open pull request targeting the branch that was pushed, via
GitHub's update-branch API. Every other event is acknowledged with
`{ "ok": true, "ignored": "<event>" }` so GitHub stops retrying it.

**Auth:** HMAC-SHA256 over the raw body in `X-Hub-Signature-256`, checked
against `GITHUB_WEBHOOK_SECRET`.

The behaviour is opt-in twice over. Without `GITHUB_WEBHOOK_SECRET` the route
returns `503 webhook_disabled`. With the secret but without
`AUTO_UPDATE_BRANCHES` set to a true value, deliveries verify and then do
nothing.

| Status | `error` | When |
| --- | --- | --- |
| 400 | `invalid_json` / `invalid_request` | Malformed body. |
| 401 | `invalid_signature` | HMAC didn't match. |
| 405 | `method_not_allowed` | Anything other than POST. |
| 503 | `webhook_disabled` | `GITHUB_WEBHOOK_SECRET` isn't set. |

!!! note "The hosted App doesn't need this configured"
    Auto-update is off on the hosted deployment. If you self-host and want it,
    point the App's webhook at `<your-broker>/webhook` and set both secrets.

## Related

- [Configuration](configuration.md) for every variable named above.
- [Errors](errors.md) for what to do about each failure.
- [Limits](limits.md) for caps, TTLs and lifetimes.
