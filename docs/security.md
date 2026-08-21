# Security

<!-- sources: SECURITY.md, worker/src/index.ts, worker/wrangler.jsonc, scripts/request-public-app-token.sh -->

Diatreme holds a GitHub App private key and mints short-lived, write-scoped
installation tokens for other people's repositories. This page describes how it
protects that, and what you're responsible for.

To report a vulnerability, use
[private vulnerability reporting](https://github.com/MagmaMoose/diatreme/security/advisories/new).
Don't open a public issue. The full policy, scope and response targets are in
[`SECURITY.md`](https://github.com/MagmaMoose/diatreme/blob/main/SECURITY.md).

## What stops one repository minting another's token

`/token` takes an OIDC token and a repository. It mints only for the repository
in the token's own `repository` claim: if the body asks for a different one, the
request is refused with `403 repo_mismatch`. The claim comes from GitHub, not
from the caller, so a repository cannot ask for a token it wasn't issued for.

Verification pins the issuer before selecting its key set, so a token with a
forged `iss` can't steer the broker into verifying against a different tenant's
keys. Audience is checked against an explicit list. Expiry and not-before are
enforced.

Self-hosted deployments can narrow further with
[`ALLOWED_REPOSITORIES`](reference/configuration.md#allowed_repositories).

## Token scope and lifetime

Minted tokens carry `contents: write` and `pull_requests: write` by default, and
are scoped to a single repository. They inherit GitHub's lifetime, currently one
hour. A deployment can narrow the permission set with
[`TOKEN_PERMISSIONS`](reference/configuration.md#token_permissions), but nothing
can widen a token past what the App itself was granted at install time.

The action masks the token with `::add-mask::` the moment it arrives, so it's
redacted in the run log.

## Secret handling

- The App private key, the bearer secret and the webhook secret live in the
  platform's secret store. None are in the repository, and none appear in
  `wrangler.jsonc`.
- `.dev.vars` is gitignored. Only `.dev.vars.example`, with placeholders, is
  tracked.
- The bearer on `/sign` and `/releases` is compared in constant time.
- `/webhook` verifies an HMAC-SHA256 over the raw request body before parsing
  it, so an unsigned payload is never interpreted.
- Nothing logs a token, or any slice of one. Failure logs carry claim metadata
  and the classified reason, never the credential, and every field is truncated
  so a hostile token can't flood the log.

## Attack surface kept deliberately small

`workers_dev` and `preview_urls` are off. Either would expose a second publicly
reachable hostname for a live token minter, inheriting production secrets and
bypassing the rules bound to the custom domain. The custom domain is the only
intended door.

Repository owner and name are validated against `A-Za-z0-9_.-` before they're
interpolated into any API URL.

## What you're responsible for

**Pin by SHA for strict supply-chain reproducibility.** `@v2` is a floating tag
this repository force-updates after every stable release, so it moves under you
by design. `uses: MagmaMoose/diatreme@<sha>` doesn't.

**Grant the job only the permissions it needs.** `id-token: write` is required
for the OIDC exchange. `contents: write` and `pull-requests: write` are needed
only for the modes that use them. See [Setup](setup.md#required-permissions).

**Treat the broker hostname as part of your trust boundary.** Overriding
`token-broker-url` points your OIDC tokens at someone else's server. Those tokens
are short-lived and repository-scoped, but they are still credentials. Don't
override it unless you run the broker.

## Supported versions

| Version | Supported |
| --- | --- |
| `v2.x` | Yes |
| `v1.x` and earlier | No, end of life. Move to `@v2`. |

## Related

- [Broker API](reference/broker-api.md) for the auth model per route.
- [Configuration](reference/configuration.md) for every secret the broker reads.
