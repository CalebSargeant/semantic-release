# Limits and lifetimes

<!-- sources: broker/app, worker/src/index.ts -->

Caps, timeouts and TTLs built into the broker. None of these are configurable
per request. They're here so you can tell a limit from a bug.

## Token lifetimes

| Thing | Value | Set by |
| --- | --- | --- |
| Installation token returned by `/token` | GitHub's own lifetime, currently one hour | GitHub. The broker passes `expires_at` through and never computes it. |
| App JWT used internally | 9 minutes, backdated 60 seconds | The broker, to absorb clock skew between it and GitHub. Never leaves the broker. |
| OIDC token accepted by `/token` | Whatever the runner minted | GitHub Actions. |

If you need a token to outlive a job, you don't: request a new one. Diatreme
mints per run, not per repository.

## JWKS retrieval

The key sets used to verify OIDC tokens.

| Behaviour | Value |
| --- | --- |
| Cached key set is reused for | 5 minutes (jose's default is 10) |
| Fetch timeout | 5 seconds |
| Throttle between unmatched-key reloads | 30 seconds |
| Minimum interval between forced reloads | 5 seconds |
| Last-known-good snapshot is usable for | 24 hours |
| Snapshot is retained in KV for | 30 days |

A token whose `kid` isn't in the cached set triggers one forced re-fetch, rate
limited to once every 5 seconds across the whole broker. That's what recovers
from a GitHub key rotation. When retrieval fails outright, verification falls
back to the snapshot if one exists and is under 24 hours old. Past that age the
snapshot is refused and the request gets `503 oidc_key_fetch_failed`, because
serving from a key set that may have been rotated out is worse than failing
loudly.

!!! warning "Don't shorten the 30 second throttle"
    It looks like a knob for faster rotation recovery. It isn't. Lowering it
    widens the window in which jose's own unthrottled reload fires, and the
    result is more upstream fetches per rotation, not fewer. Recovery comes from
    the throttled explicit reload instead.

## Releases aggregate

`GET /releases` walks the App's installations, so it's bounded to stay inside
the platform's subrequest budget.

| Cap | Value |
| --- | --- |
| Installations traversed | 10 |
| Repositories per installation | 40 |
| Cache TTL | 5 minutes |

Hitting either cap sets `truncated: true` in the response. The list is never
silently shortened. A `cached: true` response can be up to 5 minutes stale.

## Auto-update webhook

| Cap | Value |
| --- | --- |
| Open pull requests updated per push | 100 |

Only applies when `AUTO_UPDATE_BRANCHES` is enabled, which it isn't on the
hosted deployment.

## Logging

Every field in a structured log line is truncated to 128 characters. Tokens are
never logged, in whole or in part, and neither is the underlying library's error
message, which can embed claim values.

## Related

- [Broker API](broker-api.md)
- [Configuration](configuration.md) for the things that are configurable.
