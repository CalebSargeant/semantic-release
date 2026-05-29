# Choose Your Setup

This page maps common release flows to action inputs. Read
[Concepts](concepts.md) first if TBD, BBD, or Docker promotion are new to you.

> **Tip:** call the reusable workflow at
> `magmamoose/diatreme/.github/workflows/diatreme.yaml@v1`
> instead of the action directly to opt into a workflow-level
> `concurrency:` lock. Same inputs; serialises runs on the same target
> branch automatically. See [Concepts → Concurrency Safety](concepts.md#concurrency-safety).

## 1. Choose A Release Model

### Trunk-Based Development

Use Trunk-Based Development when one branch, usually `main`, creates release
tags.

Production-only:

```yaml
with:
  mode: release
  environment: prod
  environments: '["prod"]'
  prerelease-identifiers: '{}'
```

Explicit prerelease environment:

```yaml
with:
  mode: release
  deployment-model: tbd
  environment: dev
  environments: '["dev", "staging", "prod"]'
  prerelease-identifiers: '{"dev": "dev", "staging": "rc"}'
```

Promotion PRs from one branch:

```yaml
with:
  mode: release
  deployment-model: tbd-pr
  environment: ${{ github.event_name == 'push' && 'dev' || '' }}
  environments: '["dev", "staging", "prod"]'
  prerelease-identifiers: '{"dev": "dev", "staging": "rc"}'
  create-promotion-pr: 'true'
```

Promotion flow:

| Trigger | Environment | Tag |
|---|---|---|
| Push to `main` | `dev` | `v1.2.3-dev.1` |
| Merge `promote/staging/...` | `staging` | `v1.2.3-rc.1` |
| Merge `promote/prod/...` | `prod` | `v1.2.3` |

`tbd-pr` is the action input for the promotion-PR variant of TBD. It is not a
third release model.

### Branch-Based Development

Use Branch-Based Development when long-lived branches represent environments.

```yaml
with:
  mode: release
  deployment-model: bbd
  branch-map: '{"dev": "dev", "staging": "staging", "main": "prod"}'
  environments: '["dev", "staging", "prod"]'
  prerelease-identifiers: '{"dev": "dev", "staging": "rc"}'
```

Branch mapping:

| Branch | Environment | Tag |
|---|---|---|
| `dev` | `dev` | `v1.2.3-dev.1` |
| `staging` | `staging` | `v1.2.3-rc.1` |
| `main` | `prod` | `v1.2.3` |

For BBD pull request CI, set `enforce_branch_naming: 'false'` because the
target branches are environment names.

### GitFlow (strict)

Strict GitFlow has dynamic branch families: `release/*` for stabilization
and `hotfix/*` for emergency patches. Map them with branch globs in the
BBD model:

```yaml
with:
  mode: release
  deployment-model: bbd
  branch-map: |
    {
      "develop":   "dev",
      "release/*": "staging",
      "hotfix/*":  "prod",
      "main":      "prod"
    }
  environments: '["dev", "staging", "prod"]'
  prerelease-identifiers: '{"dev": "dev", "staging": "rc"}'
  enforce_branch_naming: 'false'
```

Branch mapping:

| Branch | Environment | Tag |
|---|---|---|
| `develop` | `dev` | `v1.2.3-dev.1` |
| `release/X.Y` | `staging` | `v1.2.3-rc.1` |
| `hotfix/X.Y.Z` | `prod` | `v1.2.3` |
| `main` | `prod` | `v1.2.3` |

See [Branching strategies](branching-strategies.md) for when to use
GitFlow vs. TBD or plain BBD, and the versioning-tool config you'll need
on each branch family.

## 2. Choose A Versioning Tool

| Tool | Input | Config file |
|---|---|---|
| python-semantic-release | `semantic-release-python` | `pyproject.toml` |
| semantic-release for Node.js | `semantic-release-npm` | `.releaserc.json` or `package.json` |
| GitVersion | `gitversion` | `GitVersion.yml` |
| release-please | `release-please` | `release-please-config.json` |

Example:

```yaml
with:
  mode: release
  versioning-tool: semantic-release-python
```

If the config file lives below the repository root, set `working-directory`.

```yaml
with:
  mode: release
  working-directory: services/api
```

The semantic-release and release-please example configs use Conventional
Commits. GitVersion uses the rules in `GitVersion.yml`.

## 3. Choose Docker Behavior

### Version Only

Do not set `image_name`.

```yaml
with:
  mode: release
  environment: prod
  environments: '["prod"]'
  prerelease-identifiers: '{}'
```

### Single Image

Add PR CI:

```yaml
with:
  mode: ci
  image_name: my-app
  github-token: ${{ secrets.GITHUB_TOKEN }}
```

Add release image promotion:

```yaml
with:
  mode: release
  image_name: my-app
```

The Bake target should emit one image tag based on `REGISTRY`, `IMAGE_NAME`,
and `VERSION`.

### Multiple Images

Set `bake_target` to a Bake group. Each target in the group must have its own
tag.

```yaml
with:
  mode: ci
  image_name: my-app
  bake_target: default
  github-token: ${{ secrets.GITHUB_TOKEN }}
```

Diatreme expands the group and builds or promotes every target.

## 4. Choose A Release Write Token

Release mode needs a token that can perform the writes required by your setup.

| Choice | Inputs | Use when |
|---|---|---|
| Diatreme GitHub App | default `auth-mode: public-app` | You use the hosted app |
| Private GitHub App | `auth-mode: private-app`, `app-id`, `app-private-key` | Your organization owns the app |
| Workflow token | `auth-mode: github-token`, `github-token` | `GITHUB_TOKEN` can write release artifacts |

Diatreme GitHub App example:

```yaml
permissions:
  contents: read
  id-token: write

steps:
  - uses: magmamoose/diatreme@v1
    with:
      mode: release
```

Workflow token example:

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

## Common Combinations

| Goal | Required inputs |
|---|---|
| Production-only, version-only | `environment`, `environments`, `prerelease-identifiers` |
| Production-only with Docker | production-only inputs plus `image_name` and PR CI |
| TBD promotion PRs, version-only | `deployment-model: tbd-pr`, environment inputs, `create-promotion-pr` |
| TBD promotion PRs with Docker | TBD promotion PR inputs plus `image_name` and PR CI |
| BBD with Docker | `deployment-model: bbd`, `branch-map`, environment inputs, `image_name`, BBD PR CI |

## 5. (Optional) Auto-Merge Feature PRs

Opt non-promotion PRs into native GitHub auto-merge so they land as soon as
required checks pass and required reviews approve. Promotion PRs are
unaffected — this is for ordinary feature/dependabot/fix PRs.

**Repo prerequisites (GitHub-side, one-time):**

- Settings → General → Pull Requests → **Allow auto-merge** is on.
- The target branch (usually `main`) has a branch protection rule with at
  least one required status check. GitHub refuses to engage auto-merge on
  unprotected branches.

**Caller workflow:**

```yaml
name: Auto-merge PR

on:
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review]

permissions:
  contents: read
  pull-requests: write

jobs:
  enable-auto-merge:
    if: ${{ !github.event.pull_request.draft }}
    runs-on: ubuntu-latest
    steps:
      - uses: magmamoose/diatreme@v1
        with:
          mode: enable-auto-merge
          pr-number: ${{ github.event.pull_request.number }}
          auto-merge-method: squash   # squash (default) | merge | rebase
```

The job exits 0 even when the repo isn't fully set up for auto-merge (logs
a `::warning::` instead). PRs remain mergeable manually.

Pairs naturally with `require-copilot-review` as a required status check:
once Copilot has approved the head commit and CI is green, the PR
auto-merges with no human in the loop.
