# Errors

<!-- sources: broker/app, worker/src/index.ts, scripts/request-public-app-token.sh, scripts/detect-versioning-tool.sh, scripts/build-image-dockerfile.sh -->

Every failure a Diatreme run can surface, what causes it, and what to do. The
action fails hard: any broker fault exits the step non-zero, so a broken broker
is a red X on the release rather than a silent skip.

## Reading a broker failure in the run log

The action prints the HTTP status, the `error` code, the `reason` when there is
one, and which broker answered:

```text
Error: Token broker request failed with HTTP 401: invalid_oidc_token (audience_mismatch) [https://api.diatreme.magmamoose.com]
```

The hostname in brackets matters. If it's the fallback rather than the primary,
the primary was unreachable or returned 5xx and you have two problems, not one.
A preceding `::warning::` line names the primary's status.

## Token verification failures

All of these are `401 invalid_oidc_token` unless noted. The `reason` is what
tells you which check failed.

| `reason` | What it means | What to do |
| --- | --- | --- |
| `malformed_token` | The value sent as `oidcToken` isn't a decodable JWT. | Almost always a broken OIDC mint upstream of the broker. Check the `Request public GitHub App token` step actually received a token, and that `id-token: write` is granted. |
| `audience_mismatch` | The token's `aud` isn't in the broker's accepted list. | Your `oidc-audience` input and the broker's `OIDC_AUDIENCE` disagree. Leave the input at its default unless you run your own broker. |
| `issuer_mismatch` | The token's `iss` isn't a trusted issuer. | Expected on a GitHub Enterprise runner talking to a broker without `GHE_OIDC_ISSUER` configured. See [Configuration](configuration.md#github-enterprise). |
| `token_expired` | `exp` is in the past. | The token is minted seconds before use, so this means real clock skew or a job that stalled for an hour between mint and exchange. Re-run. |
| `token_not_yet_valid` | `nbf` is in the future. | Clock skew on the broker side. Re-run, and if it persists, report it. |
| `signature_invalid` | The signature didn't verify against a key that matched. | Not something a caller can cause with a genuine token. Report it. |
| `kid_not_found` | No signing key matched the token's `kid`, even after a forced re-fetch. | Usually a GitHub key rotation the broker hasn't caught up with. Retry once. If it persists past a few minutes, report it. |
| `key_ambiguous` | More than one key matched the `kid`. | Report it. Not caller-fixable. |
| `alg_unsupported` | The token's algorithm isn't allowed. | Report it. |
| `claim_invalid` | A claim other than `aud`, `iss` or `nbf` failed validation. | Report it with the run URL. |
| `unknown` | The failure carried no classifiable code. | Report it with the run URL. |

### `403 repo_mismatch`

The token's `repository` claim isn't the `owner`/`repo` the request asked for.
The broker will not mint a token for a repository other than the one whose
runner minted the OIDC token, which is the property that makes a public broker
safe. Seeing this from an unmodified action means something rewrote the request.

### `403 repo_not_allowed`

The repository is outside the broker's `ALLOWED_REPOSITORIES`. On a self-hosted
broker, add it. On the hosted broker this shouldn't happen; report it.

### `404 app_not_installed`

The Diatreme GitHub App isn't installed on the repository. Install it from
[github.com/apps/diatreme](https://github.com/apps/diatreme) and re-run. This is
the single most common first-run failure.

### `400 invalid_repository`

`owner` or `repo` contains a character outside `A-Za-z0-9_.-`. Not reachable
through the action, which derives both from `GITHUB_REPOSITORY`.

## Availability failures

### `503 oidc_key_fetch_failed` with `reason: jwks_unavailable`

The broker could not retrieve the issuer's key set, so it never reached a
verdict on your token. This is broker or upstream unavailability, not a bad
token, and it is worth retrying.

Causes seen in practice: a timeout or connection reset reaching
`token.actions.githubusercontent.com`, a non-200 from that endpoint, or a
response that doesn't parse as JSON.

What to do: re-run the job. The broker keeps a last-known-good key set and will
rescue the request from it when one is available and fresh enough, so a
persistent 503 means both the live fetch and the snapshot are unusable.

!!! note "Why this isn't a 401"
    It used to be. A bare catch turned every retrieval fault into
    `invalid_oidc_token`, which sent people hunting for a bad token during what
    was actually an outage, with no way to tell the two apart
    ([#147](https://github.com/MagmaMoose/diatreme/issues/147)). Retrieval
    faults are 503 now, and only 503.

### `500 github_installation_lookup_failed`

GitHub answered the installation lookup with something the broker couldn't use.
Transient. Re-run, and check [GitHub's status page](https://www.githubstatus.com/)
if it repeats.

### `502 installation_token_failed` / `502 sign_failed`

Only on `/sign`. The first means no token could be minted for that repository,
the second that GitHub rejected the commit. The usual cause of `sign_failed` is
a stale `expected_head_oid`: the branch moved between reading the head and
writing the commit. Re-read the head and retry.

### `503 sign_disabled` / `503 releases_disabled` / `503 webhook_disabled`

The relevant secret isn't configured on that deployment. See
[Configuration](configuration.md). On a self-hosted broker this is your answer.
On the hosted one, report it.

## Client-side action failures

These come from the action's own scripts, before or instead of a broker call.

| Message | Cause | Fix |
| --- | --- | --- |
| `auth-mode public-app requires token-broker-url.` | `token-broker-url` was explicitly set to an empty string. | Leave it unset to get the default, or give it a real URL. |
| `OIDC request environment is unavailable. Grant 'id-token: write' to this job.` | The job has no OIDC permission, so no token can be minted at all. | Add `permissions: id-token: write` to the job. See [Setup](../setup.md#required-permissions). |
| `GITHUB_REPOSITORY must be owner/repo.` | The environment variable is missing or malformed. | Only reachable outside a normal Actions run. |
| `Token broker request failed with HTTP <status>: <error>` | The broker answered non-200. | Find the `error` and `reason` in the tables above. |

## Getting more detail

On the Cloudflare deployment, every verification failure logs one structured
line:

```bash
npx wrangler tail diatreme --format json --search oidc_verify_failed
```

It carries the classified `reason`, the underlying error name and code, the
token's `kid`, `iss`, `aud`, `repository`, `iat` and `exp`, the audiences and
issuers the broker expected, and for a retrieval fault the upstream HTTP status
and content type. It never carries the token itself. Field values are truncated,
so a hostile token can't flood the log.

## Related

- [Broker API](broker-api.md) for the full status table per route.
- [Configuration](configuration.md) for the settings these errors point at.
