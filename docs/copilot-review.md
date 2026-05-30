# Require Copilot Review

Diatreme can publish a deterministic PR gate that requires GitHub Copilot
PR Review to have run against the current pull request head.

The default required status name is:

```text
Diatreme / Require Copilot Review
```

Add that exact status context to branch protection or repository rulesets when
you want the gate to block merges.

## What It Does

`require-copilot-review` runs in `mode: ci`. It:

- reads the pull request, changed files, commits, and submitted reviews through
  the GitHub API
- detects a configured Copilot reviewer identity
- verifies review freshness against the current PR head
- reports a stable commit status or check run
- fails with a clear reason when the review is missing, stale, or from an
  unexpected identity

It does not request Copilot review automatically. Configure GitHub's automatic
Copilot review separately in repository or organization rulesets or settings,
then use Diatreme to enforce that a completed review exists.

## Minimal Workflow

This creates only the Copilot review gate. It does not build Docker images.

```yaml
name: Copilot Review Gate

on:
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review]
  pull_request_review:
    types: [submitted]

jobs:
  copilot-review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read
      statuses: write
    steps:
      - uses: magmamoose/diatreme@v1
        with:
          mode: ci
          enforce_branch_naming: 'false'
          require-copilot-review: 'true'
```

If your existing PR CI job already uses Diatreme with `mode: ci`, add
`require-copilot-review: 'true'` to that step and grant `statuses: write`.

## Configuration

```yaml
- uses: magmamoose/diatreme@v1
  with:
    mode: ci
    require-copilot-review: 'true'
    copilot-review-freshness: after_latest_commit
    copilot-review-allowed-logins: '["copilot-pull-request-reviewer[bot]"]'
    copilot-review-fail-on-unknown-identity: 'true'
    copilot-review-ignore-drafts: 'true'
    copilot-review-ignore-labels: '["skip-copilot-review"]'
    copilot-review-ignore-authors: '["dependabot[bot]"]'
    copilot-review-ignore-paths: '["docs/*","*.md"]'
```

Important inputs:

| Input | Default | Purpose |
|---|---|---|
| `require-copilot-review` | `false` | Enables the policy in `mode: ci`. |
| `copilot-review-freshness` | `after_latest_commit` | Uses review `commit_id` when available, with a timestamp fallback. |
| `copilot-review-allowed-logins` | `["copilot-pull-request-reviewer[bot]"]` | Exact reviewer login allow-list. Override for GitHub Enterprise Server or changed bot names. |
| `copilot-review-allow-login-pattern` | `false` | Treat allowed logins as shell-style patterns. |
| `copilot-review-fail-on-unknown-identity` | `true` | Fail closed unless the reviewer identity is configured. |
| `copilot-review-ignore-drafts` | `true` | Skip draft PRs. |
| `copilot-review-ignore-labels` | `[]` | Skip PRs with configured labels. |
| `copilot-review-ignore-authors` | `[]` | Skip PRs from configured authors, such as Dependabot. |
| `copilot-review-ignore-paths` | `[]` | Skip PRs when every changed file matches a configured shell-style path pattern. |
| `copilot-review-reporter` | `commit-status` | Use `commit-status`, `check-run`, or `none`. |
| `copilot-review-check-name` | `Diatreme / Require Copilot Review` | Required status context or check-run name. |

## Required Permissions

For the default `commit-status` reporter:

```yaml
permissions:
  contents: read
  pull-requests: read
  statuses: write
```

For `copilot-review-reporter: check-run`, use `checks: write` instead of
`statuses: write`.

If the same job also builds and pushes PR Docker images, keep the existing
`packages: write` permission.

Fork pull requests can have read-only workflow tokens. In that case Release
Runner may be able to evaluate the policy but fail to publish the required
status. Use trusted branch workflows, a GitHub App token with the right
permissions, or `pull_request_target` only after reviewing the usual security
tradeoffs for untrusted fork code.

## Freshness

The default freshness mode is `after_latest_commit`.

Diatreme prefers the deterministic GitHub review `commit_id`. When a
submitted Copilot review has `commit_id` equal to the current PR head SHA, the
gate passes. When the latest matching Copilot review points at an older SHA,
the gate fails with:

```text
Copilot reviewed this pull request, but new commits were pushed afterwards.
```

If GitHub does not expose `commit_id` for a review, Diatreme falls back to
comparing the review `submitted_at` time with the latest PR commit timestamp.

Use `copilot-review-freshness: exact_head_sha` when you want to fail instead of
using that timestamp fallback.

## Rechecking

Add the `pull_request_review.submitted` trigger so the policy re-runs when
Copilot finishes a review:

```yaml
on:
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review]
  pull_request_review:
    types: [submitted]
```

Manual workflow reruns also refresh the status. A comment command such as
`/diatreme recheck` is not implemented yet.

## Known Limitations

- Copilot must be requested by GitHub or by a user; Diatreme only checks
  for a completed review.
- The gate does not parse Copilot's comments or decide whether the code is
  good. It only verifies that review happened for the current PR state.
- Pending and dismissed reviews do not satisfy the gate.
- If the check runs before Copilot finishes, it fails until Copilot submits a
  review and the workflow re-runs.
- Bot identities can differ across environments. Keep
  `copilot-review-fail-on-unknown-identity: 'true'` for strict enforcement, or
  configure `copilot-review-allowed-logins` for your environment.

## Premium Request Rate Limit Bypass

When a user exhausts their Copilot premium-request allowance, the GitHub UI
shows a banner like:

```text
You have reached your monthly limit for premium requests for Copilot code
review. Limit resets on Jun 1, 2026.
```

Copilot then refuses to review, so the strict gate fails indefinitely. The
banner is rendered from the user's private billing state and has no
programmatic signal on the PR (no review, no comment, no check-run, no
timeline event), so the gate cannot detect the rate limit on its own.

Diatreme handles this with two layers, in order of preference.

### Layer 1 — Copilot's own decline notice (zero-config)

When Copilot is explicitly requested as a reviewer on a PR but its
premium-request quota is exhausted, it posts a real review on the head
commit whose body explains the decline, for example:

```text
Copilot was unable to review this pull request because the user who
requested the review has reached their quota limit.
```

This review has `state: COMMENTED` and a fresh `commit_id`, so without
detection the strict gate would silently accept it as a real Copilot
review. The gate detects the decline wording (`"unable to review"` +
`"quota"`, `"monthly limit for premium request"`, `"reached your quota"`
— case-insensitive) and finishes as `success` with a `::warning::`
annotation that includes the original decline text. No configuration
required; this fires automatically whenever Copilot leaves the decline
review.

### Layer 2 — broker-worker quota endpoint

When Copilot is **not** requested as a reviewer (so no decline notice
exists) but the user is still rate-limited, the gate consults a
`/copilot-quota` endpoint on the broker worker.

`auth-mode: public-app` (the default) auto-derives the URL from
`token-broker-url`, so no configuration is required:

```yaml
- uses: magmamoose/diatreme@v1
  with:
    mode: ci
    require-copilot-review: 'true'
    # copilot-review-quota-check-url defaults to
    # `${token-broker-url}/copilot-quota` under auth-mode: public-app.
```

Self-hosted brokers (or callers using `auth-mode: private-app` /
`github-token`) opt in explicitly:

```yaml
- uses: magmamoose/diatreme@v1
  with:
    mode: ci
    require-copilot-review: 'true'
    copilot-review-quota-check-url: 'https://your-broker.example.com/copilot-quota'
```

When the URL is set (or auto-derived), the gate calls it before
reporting a failure for "no Copilot review" or "stale Copilot review".
If the worker responds `{"rate_limited": true, ...}`, the gate finishes
as `success` with a `::warning::` annotation that reports the reset
date and the source of the signal. If the worker is unreachable or
returns `rate_limited: false`, the gate falls back to strict mode.

The action passes two query parameters to the worker:

- `owner` — `${{ github.repository_owner }}`, the org or user that owns
  the repo. Always present.
- `requester` — `${{ github.event.pull_request.user.login }}`, the PR
  author. Present whenever the gate runs on a PR event. The worker uses
  it to additionally query *user-scoped* billing, because Copilot
  premium-request quotas are tracked per-user even on Copilot Business —
  so a personal account's exhaustion won't appear in the org-level
  billing usage at all.

The worker resolves the rate-limit state through a layered detection
chain. Positive signals short-circuit; a `rate_limited: false` is only
returned after every source has been consulted.

1. **Manual override** stored in KV — set via
   `POST /copilot-quota` with a `Bearer` token. Useful for flipping the
   flag the moment you see the UI banner; auto-expires at the next UTC
   month boundary (matching GitHub's reset cadence). Checked for both
   `owner` and `requester`, so flipping the flag on the user account
   suffices even when PRs land under multiple orgs.
2. **OAuth-backed user billing** — when the PR author (passed as
   `requester`) has connected to diatreme via
   `/oauth/connect`, the worker uses their stored refresh
   token to mint a user access token and queries
   `/users/{requester}/settings/billing/premium_request/usage`. This
   is the only direct, real-time signal for individual quota
   exhaustion. See the "OAuth User-Billing Setup" section below.
3. **GitHub Billing Usage API (org-scoped)** — when the broker App
   has billing permissions on the owner, the worker fetches
   `/orgs/{owner}/settings/billing/usage` and scans for a Copilot
   premium-request line item with zero remaining quota. Useful for
   Copilot Business orgs where premium-request usage shows up at the
   org level. A **Cloudflare Cron Trigger** (every 15 minutes)
   refreshes both caches proactively for any owner the worker has
   seen — so `GET /copilot-quota` stays single-digit-ms warm-path.
4. **Webhook-derived heuristic** — the broker App subscribes to
   `pull_request` (review_requested) and `pull_request_review`
   (submitted) events delivered to `POST /webhook`. The worker
   HMAC-verifies each delivery against `GITHUB_WEBHOOK_SECRET` and
   accumulates per-owner timestamps of Copilot review requests vs
   deliveries in KV. If a request has been outstanding longer than
   `COPILOT_WEBHOOK_REVIEW_GAP_SECONDS` (default 30 min) and no review
   came back, the worker infers Copilot is rate-limited. A subsequent
   Copilot review delivery clears the backlog automatically. Inferred
   purely from observed behavior — no extra App permissions beyond
   what PR/review event subscriptions already grant. Checked for
   both `owner` and `requester`. **Caveat**: GitHub's
   `copilot_code_review` ruleset auto-requests Copilot via a separate
   path that does NOT fire `review_requested` events, so this layer
   only helps for repos that *manually* request Copilot review (e.g.
   via a workflow that calls the request-review API).
5. **Copilot Metrics API** — falls through to
   `/orgs/{owner}/copilot/metrics` (and the user-scoped variant),
   which returns daily Copilot activity reports. If
   `total_engaged_users` for the latest day is 0 after a non-zero
   prior day, the worker reports a sudden activity drop as a softer
   rate-limit signal (`source: github-copilot-metrics`). Useful when
   the App has `copilot: read` but no billing permissions.
6. **Default `rate_limited: false`** when no source produced a
   positive verdict, so a misconfigured broker can never silently
   weaken the gate.

The action treats `rate_limited: false` as "no signal, stay strict" — the
worker never weakens enforcement, it only relaxes it on a positive
signal.

### OAuth User-Billing Setup (Layer 2, recommended)

The most reliable detection layer is OAuth-backed user billing. Each
contributor authorizes the broker once; from then on, every PR they
open gets quota-checked against the GitHub Billing API in real time.

**One-time deployer setup** (per broker):

1. Open the App's settings at
   `https://github.com/settings/apps/diatreme` (or your fork's
   slug if self-hosting).
2. Under **Identifying and authorizing users**, set
   - **User authorization callback URL**: `${broker-url}/oauth/callback`
     (e.g. `https://api.diatreme.magmamoose.com/oauth/callback`)
   - **Request user authorization (OAuth) during installation**:
     leave unchecked (we want a separate authorize flow per contributor)
   - **Enable Device Flow**: unchecked
3. Under **Client secrets**, click **Generate a new client secret**.
   Copy the secret.
4. Set the secret on the worker:
   ```bash
   wrangler secret put GITHUB_APP_CLIENT_SECRET   # paste when prompted
   wrangler secret put GITHUB_APP_CLIENT_ID       # paste the App's client ID (visible on the App settings page)
   ```
5. Redeploy: `wrangler deploy`.

**Per-contributor authorize** (any developer whose PRs hit the gate):

1. Visit `${broker-url}/oauth/connect` once.
2. GitHub shows an authorization page listing the App's User
   permission (`Plan: read`). Click **Authorize**.
3. Worker stores the refresh token in KV with a ~6-month TTL. The
   connection auto-renews each time the contributor opens a PR.

**Verify a connection**:

```bash
curl https://api.diatreme.magmamoose.com/oauth/status?user=CalebSargeant
# → {"connected":true,"user":"CalebSargeant","connected_at":"...","refresh_token_expires_at":"..."}
```

When a connected contributor opens a PR, the worker's response gains
the new layer:

```json
{"rate_limited":true,"source":"github-oauth-user-billing","resets_at":"2026-06-01T00:00:00Z",...}
```

If the contributor hasn't authorized, Layer 2 silently no-ops and the
chain falls through to org billing / webhook / metrics / default.

### Manual Override (Layer 1)

Set the manual flag from anywhere:

```bash
curl -fsSL -X POST \
  -H "Authorization: Bearer ${BROKER_OVERRIDE_SECRET}" \
  -H 'Content-Type: application/json' \
  -d '{"owner":"CalebSargeant","rate_limited":true}' \
  https://api.diatreme.magmamoose.com/copilot-quota
```

Clear it again with the same call and `"rate_limited": false`. The
manual override is the operator's emergency knob for the rare case
where Layer 2 is unavailable and the gate must pass for a specific
PR; the OAuth-backed Layer 2 is the right long-term path.

### Deployer setup

To enable the full detection chain on a self-hosted broker:

1. **Provision KV** — `wrangler kv namespace create COPILOT_QUOTA_KV` (+
   `--preview`). Paste the returned IDs into `wrangler.jsonc` under
   `kv_namespaces`.
2. **Set secrets** —
   - `COPILOT_QUOTA_OVERRIDE_SECRET` — bearer token for the manual
     override POST endpoint (optional).
   - `GITHUB_WEBHOOK_SECRET` — shared secret configured on the App's
     webhook URL (optional; webhook endpoint refuses requests until it
     is set).
3. **Grant App permissions** on the broker App:
   - `Plan: read` (organization permission) for org-scoped billing
     auto-detect on Copilot Business orgs.
   - `Plan: read` (account permission) for user-scoped billing
     auto-detect — this is the one that catches individual quota
     exhaustion. Requires the App to ALSO be installed on each
     contributor's personal account.
   - `Copilot: read` for the metrics-API fallback.
   - Subscribe to `Pull request` and `Pull request review` events
     under "Subscribe to events" if you want the webhook heuristic.
4. **Point the App webhook URL** at the broker's `/webhook` path. Existing
   installations need to accept the new permissions before any of the
   auto-detect signals can fire.
5. **Install on contributor accounts (optional)** — for the user-scoped
   billing layer to fire, each PR author who hits Copilot quota must
   have the broker App installed on their personal GitHub account.
   Without this, the worker falls back to org billing / webhook /
   metrics / manual.

Each layer is independent — you can deploy with only some of them
configured and the others degrade to neutral output.
