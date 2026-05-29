# Organization Setup

Do this once before onboarding repositories.

## Recommended Auth: Diatreme GitHub App

Most repositories should use the default `auth-mode: public-app`.

For users, this means:

1. Install the [Diatreme GitHub App](https://github.com/apps/diatreme/installations/new) on the organization or selected repository.
2. Allow the app through branch protection or repository rulesets if releases write protected refs.
3. Grant release jobs `id-token: write`.
4. Keep the default auth inputs.

Workflow permissions:

```yaml
permissions:
  contents: read
  id-token: write
  packages: write
```

Use `packages: write` only when Docker image build or promotion is enabled.
Use `statuses: write` when enabling
[Require Copilot Review](copilot-review.md) with the default commit-status
reporter, or `checks: write` when using its check-run reporter.

Release job:

```yaml
steps:
  - uses: magmamoose/diatreme@v1
    with:
      mode: release
```

## When To Use Another Auth Mode

| Auth mode | Use it when | What users configure |
|---|---|---|
| `public-app` | You install the Diatreme GitHub App | App installation and `id-token: write` |
| `private-app` | Your organization owns the GitHub App | App ID and private key secrets |
| `github-token` | Branch protection allows `GITHUB_TOKEN` to release | `contents: write` and optional `pull-requests: write` |
| `auto` | You want private app auth when secrets exist, otherwise workflow token | Private app secrets or workflow token permissions |

## Private GitHub App

Use this when your organization does not want to use the Diatreme GitHub App.

Create a GitHub App with repository permissions:

| Permission | Access |
|---|---|
| Contents | Read and write |
| Pull requests | Read and write |
| Commit statuses | Write, only for Require Copilot Review with commit-status reporting |
| Checks | Write, only for Require Copilot Review with check-run reporting |
| Metadata | Read-only |

Add `Workflows: Read and write` only if your release process intentionally edits workflow files.

Then:

1. Install the app on target repositories.
2. Save the app ID as `SEMANTIC_RELEASE_APP_ID`.
3. Generate a private key and save the full PEM as `SEMANTIC_RELEASE_APP_PRIVATE_KEY`.
4. Allow the app in any branch protection or rulesets that would otherwise block release writes.

Workflow input:

```yaml
- uses: magmamoose/diatreme@v1
  with:
    mode: release
    auth-mode: private-app
    app-id: ${{ secrets.SEMANTIC_RELEASE_APP_ID }}
    app-private-key: ${{ secrets.SEMANTIC_RELEASE_APP_PRIVATE_KEY }}
```

## Workflow Token

Use `auth-mode: github-token` only when the repository allows `GITHUB_TOKEN` to create everything your release requires.

```yaml
permissions:
  contents: write
  pull-requests: write
  packages: write

steps:
  - uses: magmamoose/diatreme@v1
    with:
      mode: release
      auth-mode: github-token
      github-token: ${{ secrets.GITHUB_TOKEN }}
```

This mode is useful for simple repositories, but it commonly fails with strict protected branches or rulesets.

## Branch Protection Checklist

Confirm the selected release actor can:

- create and push tags
- create GitHub Releases
- push release commits when the versioning tool updates files
- push `promote/<environment>/<version>` branches when promotion PRs are enabled
- open promotion pull requests

If rulesets require signed commits, status checks, linear history, or specific bypass actors, configure the selected app or token actor before enabling releases.
