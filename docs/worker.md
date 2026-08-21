# The broker

<!-- sources: worker/src/index.ts, worker/wrangler.jsonc, worker/README.md -->

The GitHub App backend behind `https://api.diatreme.magmamoose.com`. It exists so
callers don't have to register and run their own GitHub App: the action's default
`auth-mode: public-app` exchanges an Actions OIDC token here for a short-lived
installation token.

This page explains how the implementation works and how to run it. The exhaustive
tables live elsewhere so they can't drift apart:

- [Broker API](reference/broker-api.md): every route, parameter and status code.
- [Broker configuration](reference/configuration.md): every variable.
- [Errors](reference/errors.md): every failure and its fix.
- [Limits](reference/limits.md): caps, TTLs and lifetimes.

!!! warning "This code is not what serves production today"
    Both broker hostnames answer from AWS Lambda. `worker/` is the code of
    record in this repository, what CI validates, and the rollback target, but a
    change merged here does not reach consumers. See
    [Deployment](operations/deployment.md).

## Shape of the implementation

`worker/src/index.ts` is a single file exporting `default { fetch }`. Its only
runtime dependency is [`jose`](https://github.com/panva/jose), which keeps the
attack surface and the cold start small. Requests are routed by an exact
pathname switch, and anything unmatched is `404 not_found`.

Four routes: `/token`, `/sign`, `/releases`, `/webhook`. Only `/token` is on the
path of a normal release.

Verification order for `/token` matters and is deliberate:

1. Parse the body. Missing fields fail before any crypto runs.
2. Verify the OIDC token against the pinned issuer's key set.
3. Compare the token's `repository` claim to the requested `owner/repo`.
4. Check the deployment's repository allowlist.
5. Mint against the same GitHub host the token came from.

Steps 3 and 4 come after verification because an unverified claim is worth
nothing. Step 5 is what makes GitHub Enterprise work: a token from a configured
GHE issuer mints through the GHE App against that tenant's REST base, and a
github.com token never does.

## Surviving a JWKS outage

The broker can't verify anything without GitHub's public keys, so how it handles
not having them is most of its reliability story.

Two failure modes, handled differently:

**A key rotation.** GitHub signs with a `kid` the cached key set doesn't contain.
The library does not self-heal this on its own, so the broker forces one
re-fetch, throttled to once every 5 seconds across the whole deployment. Don't
"simplify" that throttle or the cooldown around it. Shortening the cooldown
widens the window in which the library's own unthrottled reload fires and
produces more upstream fetches per rotation, not fewer.

**A retrieval fault.** The key endpoint times out, answers non-200, or returns
something that isn't JSON. Every successful verification writes the key set to
KV as a last-known-good snapshot, and a retrieval fault falls back to that
snapshot rather than rejecting genuine tokens. The snapshot only ever supplies
keys: every other claim check still runs against the real token, and a snapshot
over 24 hours old is refused rather than trusted.

With no usable snapshot the request gets `503 oidc_key_fetch_failed`, never a
401. That distinction is the whole point. A 401 says the broker reached a verdict
and your token lost. A 503 says it never reached one. Collapsing the two turned
an upstream outage into a permanent, unfalsifiable "bad token"
([#147](https://github.com/MagmaMoose/diatreme/issues/147)).

## Develop

```bash
cd worker
npm ci
npm run typecheck   # tsc --noEmit
npm test            # vitest
npm run check       # typecheck + tests + wrangler dry run
wrangler dev        # run locally against .dev.vars
```

Copy `worker/.dev.vars.example` to `worker/.dev.vars` (gitignored) and fill in
the App credentials.

The test suite covers the router and the two hard parts separately:
`test/index.test.ts` for routing and handlers, `test/verify-oidc.test.ts` for the
verification ladder, and `test/jwks-rotation.test.ts` for rotation and snapshot
rescue.

## Deploy

Pushes to `main` touching `worker/**` deploy automatically. Full pipeline,
required secrets, rollback and the end-to-end smoke test are in
[Deployment](operations/deployment.md).

## Read the logs

```bash
npx wrangler tail diatreme --format json --search oidc_verify_failed
```

One structured line per verification failure, carrying the classified reason,
the underlying error code, the token's claims and the values the broker
expected. Never the token itself. See
[Errors](reference/errors.md#getting-more-detail).
