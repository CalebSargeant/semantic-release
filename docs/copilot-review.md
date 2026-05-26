# Require Copilot Review

Release Runner can publish a deterministic PR gate that requires GitHub Copilot
PR Review to have run against the current pull request head.

The default required status name is:

```text
Release Runner / Require Copilot Review
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
then use Release Runner to enforce that a completed review exists.

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
      - uses: magmamoose/release-runner@v1
        with:
          mode: ci
          enforce_branch_naming: 'false'
          require-copilot-review: 'true'
```

If your existing PR CI job already uses Release Runner with `mode: ci`, add
`require-copilot-review: 'true'` to that step and grant `statuses: write`.

## Configuration

```yaml
- uses: magmamoose/release-runner@v1
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
| `copilot-review-check-name` | `Release Runner / Require Copilot Review` | Required status context or check-run name. |

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

Release Runner prefers the deterministic GitHub review `commit_id`. When a
submitted Copilot review has `commit_id` equal to the current PR head SHA, the
gate passes. When the latest matching Copilot review points at an older SHA,
the gate fails with:

```text
Copilot reviewed this pull request, but new commits were pushed afterwards.
```

If GitHub does not expose `commit_id` for a review, Release Runner falls back to
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
`/release-runner recheck` is not implemented yet.

## Known Limitations

- Copilot must be requested by GitHub or by a user; Release Runner only checks
  for a completed review.
- The gate does not parse Copilot's comments or decide whether the code is
  good. It only verifies that review happened for the current PR state.
- Pending and dismissed reviews do not satisfy the gate.
- If the check runs before Copilot finishes, it fails until Copilot submits a
  review and the workflow re-runs.
- Bot identities can differ across environments. Keep
  `copilot-review-fail-on-unknown-identity: 'true'` for strict enforcement, or
  configure `copilot-review-allowed-logins` for your environment.
