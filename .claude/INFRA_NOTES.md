# Infrastructure notes (on demand)

Read before touching Cloudflare, AWS, DNS or a broker hostname. Every entry below cost
real time on 2026-08-19/20.

## Checking the broker is alive

```bash
curl -sS https://api.diatreme.magmamoose.com/healthz     # 200 {"ok":true} = AWS is serving
gh workflow run broker-smoke-aws.yml --repo MagmaMoose/diatreme   # mints a real token
```

`/healthz` exists only on the AWS broker; the Cloudflare Worker never had the route, so a
404 there means the hostname is still on Cloudflare.

## Broker code: the JWKS rotation trap

`createRemoteJWKSet` refetches on a `kid` miss only once its 30s cooldown has lapsed, and
its own freshness refetch arms that cooldown in the same call — so a miss inside the window
is terminal for the request. `worker/` therefore forces one reload itself, cache-bypassing
and throttled per issuer. Do not shorten `cooldownDuration`; that only widens the
unthrottled path. `worker/test/jwks-rotation.test.ts` guards all of it.

## Hostnames are API surface

`api.diatreme.magmamoose.com` is the default `token-broker-url` baked into every published
action version, and consumers pin by SHA. It can be **re-pointed but never retired**. A
redirect does not substitute: the pinned client does not pass `curl -L`, and curl downgrades
POST to GET on a 3xx anyway.

## Universal SSL covers the apex and ONE label

`api.diatreme.magmamoose.com` is **two labels deep**, so free Universal SSL does not cover
it. It worked only because a Workers Custom Domain silently provisions an Advanced
Certificate for its hostname — deleting that Custom Domain takes the edge certificate with
it, and a proxied record then fails every request with `sslv3 alert handshake failure`.

Fix without buying ACM: grey-cloud it, so Cloudflare does not terminate TLS and the client
reaches the origin's own certificate. Cost: no proxy, so the origin throttle and the account
budget are the only bounds left on that hostname.

## Cloudflare post-quantum key exchange can break origin TLS

"Automatic key exchange" (SSL/TLS → Origin connection) leads the Cloudflare→origin handshake
with a post-quantum algorithm. An origin that refuses it yields **525**, which surfaces three
layers downstream as an unrelated application error — in #147, as `invalid_oidc_token` on
every consumer's release for hours. It is zone-wide and applies to Worker subrequests to
third-party hosts, contradicting Cloudflare's own Workers/Page-Rules matrix.

Symptoms: deterministic (not intermittent), same zone, healthy from outside Cloudflare.

## Verify DNS with DoH, not the system resolver

macOS negative-caches NXDOMAIN, so a freshly created record reads as absent long after it
exists. Query `https://cloudflare-dns.com/dns-query?name=<h>&type=A` with
`accept: application/dns-json`, or `curl --resolve`. Two wrong conclusions were drawn from
the local resolver in one session.

## AWS broker (terraform in magmamoose/infra)

- Account `628088981780`, `eu-west-1`, profile `mm-prd-diatreme`. Leaves under
  `terraform/aws/diatreme/`, module `terraform/aws/modules/diatreme-broker`.
- **`certificate_arn` means "a certificate managed elsewhere, so do not request one."**
  Setting it to the module's *own* certificate ARN plans to destroy that certificate.
  Leave it empty and set `enable_custom_domain`.
- Custom domains are two-phase: publish the ACM validation CNAME **grey** (a proxied one
  answers with Cloudflare's value and never validates), wait for ISSUED, then enable.
  Close `disable_default_endpoint` only after the custom domain is verified serving.
- DynamoDB must stay **PROVISIONED** 1/1 — the always-free 25/25 allowance does not cover
  on-demand, which bills from the first request.
- Secrets are seeded by hand from OCI Vault into SSM; never through Terraform, because the
  infra repo is public and a secret in a resource is a secret in state.
