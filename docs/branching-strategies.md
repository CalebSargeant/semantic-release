# Branching Strategies

Diatreme is opinionated about *when* a release runs, not about *how*
your team commits and merges. This page maps the four common branching
strategies onto Diatreme inputs so you can pick what fits your team.

If you only care about the action knobs, jump straight to
[Configuration cheat sheet](#configuration-cheat-sheet).

## At A Glance

| Strategy | Long-lived branches | Where releases tag from | Diatreme mode |
|---|---|---|---|
| Trunk-Based Development (TBD) | one (`main`) | `main` | `deployment-model: tbd` or `tbd-pr` |
| GitHub Flow | one (`main`) | every merge to `main` | `deployment-model: tbd` |
| Branch-Based Development (BBD) | one per environment | each long-lived branch | `deployment-model: bbd` |
| GitFlow (strict) | `main` + `develop` + `release/*` + `hotfix/*` | `develop`, `release/*`, `main`, `hotfix/*` | `deployment-model: bbd` with branch globs |

## Trunk-Based Development

Origin: [trunkbaseddevelopment.com](https://trunkbaseddevelopment.com/)

Everyone integrates into one branch — `main` — at least daily. Feature
branches are short-lived (hours to a couple of days). Releases happen by
tagging a commit on `main`. Multiple environments are served by tagging
the same commit with different prerelease identifiers and promoting the
same image.

Best for: high-trust teams, fast CI, healthy test coverage, feature flags
in place to ship in-progress work safely.

Avoid when: you need a long stabilization window for compliance or QA, or
your team can't keep `main` always-green.

```text
            ─── pr-12 ─── pr-13 ──── pr-14 ───────── pr-15 ───
                  ↘         ↘          ↘                ↘
main:  ───●─────●──●────●───●─────●────●──────●──●──●────●────●──→
                              │                          │
                              ▼                          ▼
                     v1.2.3-dev.1 → dev          v1.2.4 → prod
                     v1.2.3-rc.1  → staging
                     v1.2.3       → prod
```

Two flavours in Diatreme:

- **Explicit env**: each workflow_dispatch picks an environment
  (`deployment-model: tbd`, pass `environment` from the dropdown). Cleanest
  audit trail, but requires manual triggers between envs.
- **Promotion PRs**: the first push to `main` cuts a `dev` prerelease and
  opens a `promote/staging/...` PR. Merging that PR cuts a `staging`
  prerelease and opens the next promotion PR. Merging the final
  `promote/prod/...` PR cuts the stable tag (`deployment-model: tbd-pr`,
  `create-promotion-pr: true`).

  Only one open promotion PR per target environment exists at a time. If
  another dev push happens before someone merges the existing
  `promote/staging/...` PR, the action refreshes the open PR's title and
  body to the latest tag instead of opening a second one. Reviewers click
  **Update Branch** on the existing PR before merging so the cut reflects
  the latest commits on the target branch.

```yaml
# TBD with promotion PRs
with:
  deployment-model: tbd-pr
  environment: ${{ github.event_name == 'push' && 'dev' || '' }}
  environments: '["dev", "staging", "prod"]'
  prerelease-identifiers: '{"dev": "dev", "staging": "rc"}'
  create-promotion-pr: 'true'
```

## GitHub Flow

Origin: [GitHub Flow guide](https://docs.github.com/en/get-started/using-github/github-flow)

Functionally a stripped-down TBD: only `main` is long-lived, every merge
to `main` is potentially deployable, no separate prerelease channels. Each
release goes straight to production.

Best for: SaaS apps with continuous deployment, libraries with no
prerelease gating.

Avoid when: you need explicit dev/staging/prod stages with different
versions on each.

```yaml
with:
  deployment-model: tbd
  environment: prod
  environments: '["prod"]'
  prerelease-identifiers: '{}'
```

## Branch-Based Development

Long-lived branches *are* the environments. Code moves through
environments by merging from one branch to the next:

```text
develop  ──●──●──●──●──●──→  (dev)
              \         \
staging  ──────●─────────●──→  (staging)
                          \
main     ──────────────────●──→  (prod)
```

Best for: teams that already think in long-lived branches, monorepos with
heavy cross-team sync, regulated environments where the branch-per-env
trail matches change-management policy.

Avoid when: you want one tag promoting through environments — BBD cuts a
*new* tag on every merge, so the prod tag is not the same commit that
`staging` tested. Use TBD with promotion if that's a problem.

```yaml
with:
  deployment-model: bbd
  branch-map: '{"develop": "dev", "staging": "staging", "main": "prod"}'
  environments: '["dev", "staging", "prod"]'
  prerelease-identifiers: '{"dev": "dev", "staging": "rc"}'
```

For the BBD PR build, set `enforce_branch_naming: 'false'` because feature
branches don't need to follow `feat/*` etc. — they target environment
branches by name.

## GitFlow (strict)

Origin: [Vincent Driessen, 2010](https://nvie.com/posts/a-successful-git-branching-model/) ·
[Atlassian summary](https://www.atlassian.com/git/tutorials/comparing-workflows/gitflow-workflow)

The "classic" model. Two long-lived branches (`main` for production
history, `develop` for next-release integration) plus three families of
short-lived branches:

- `feature/*` branches off `develop`, merges back to `develop`
- `release/X.Y` branches off `develop` for stabilization, merges to `main`
  *and* back to `develop`. Tagged on `main`.
- `hotfix/X.Y.Z` branches off `main` for emergency patches, merges to
  `main` *and* `develop`. Tagged on `main`.

```text
                                         ┌───── tag v1.0.0 ─────────────── tag v1.0.1 ──┐
main:    ●──────────────────────────────●───────────────────────────────●────────────────●──→
                                       /│                              /
                                      / │                             /
release/1.0:        ●────●────●──────● │                             │
                   /              ↑    │                             │
                  /          (merge to │                             │
                 /              develop)                             │
develop: ───●──●────●──●──●──●──●──●──●─────●──●──●──●──●──●──●──●──●─────────────────────────→
              \   \         /          \                  ↑           \
               \   \       /            \           (merge back        \
       feature/*   feature/*             \           from hotfix)       \
                                          \                              \
hotfix/1.0.1:                              │                              ●──●──●──→
                                                                          │
                                                                       (merge to main + develop)
```

Best for: shipped products with explicit stabilization windows, teams that
need a long-lived "next release" branch separate from production, anywhere
hotfix branches must be auditable.

Avoid when: you ship continuously. The `release/*` and `develop` overhead
is dead weight if `main` is always shippable. The strategy was popularized
in 2010 for software with discrete releases; the original author has since
[recommended TBD or GitHub Flow for web apps](https://nvie.com/posts/a-successful-git-branching-model/#note-of-reflection-march-5-2020).

### Mapping GitFlow onto Diatreme

Every active branch in GitFlow can map to an environment via the BBD model
with branch globs:

| Branch | Environment | Tag pattern |
|---|---|---|
| `develop` | `dev` | `v1.2.3-dev.N` |
| `release/X.Y` | `staging` | `v1.2.3-rc.N` |
| `main` | `prod` | `v1.2.3` |
| `hotfix/X.Y.Z` | `prod` | `v1.2.3` |

```yaml
with:
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

Keys with `*` in `branch-map` are matched as anchored globs. Exact matches
always win; among glob matches the longest key wins so a more specific
pattern like `release/hotfix/*` beats `release/*`.

`master` and `main` are interchangeable in the exact-match step. The map
above uses `"main"` and works unchanged on a repo whose default branch is
still `master` — the resolver falls back to the alias when no exact entry
exists. Add an explicit entry for either name to override.

### Versioning notes for strict GitFlow

The release tool is responsible for picking the next version on each
branch. For `python-semantic-release` (the default) the relevant config is:

```toml
[tool.semantic_release.branches.main]
match = "(main|master)"
prerelease = false

[tool.semantic_release.branches.develop]
match = "develop"
prerelease = true
prerelease_token = "dev"

[tool.semantic_release.branches.release]
match = "release/.*"
prerelease = true
prerelease_token = "rc"

[tool.semantic_release.branches.hotfix]
match = "hotfix/.*"
prerelease = false
```

Diatreme overrides `prerelease` and `prerelease_token` at runtime
based on `branch-map` → `prerelease-identifiers`, so the action's view
always wins.

For GitVersion users, configure equivalent rules in `GitVersion.yml`:

```yaml
branches:
  develop:
    label: dev
    increment: Minor
  release:
    label: rc
    increment: Patch
  hotfix:
    label: ""
    increment: Patch
  main:
    label: ""
    increment: Patch
```

### When the rebuilt-from-source vs. retag distinction matters

GitFlow ships discrete releases through a stabilization branch. If your
`appsettings.json` (or any other build artifact) needs to embed the
release version, set `version-file` so Diatreme injects the version
post-tag and pushes the change back to the active branch. The Release
Runner App is in your branch protection bypass list (see
[Setup → Organization](organization-setup.md#branch-protection-checklist)),
so the push works even on `main` and `develop`.

The Docker image is *retagged* from the merged-PR image (`pr-N`) to the
release tag — it is not rebuilt. If you need a freshly-built image with
the version baked in, build it in a separate job that runs after the
release publishes, and let Diatreme only handle the tag/release.

## Configuration cheat sheet

| You want… | `deployment-model` | Key extras |
|---|---|---|
| Single branch → single env | `tbd` | `environment: prod`, single-entry `environments` |
| Single branch → multiple envs (manual) | `tbd` | dropdown picks `environment` |
| Single branch → multiple envs (PRs) | `tbd-pr` | `create-promotion-pr: 'true'` |
| One branch per env | `bbd` | exact `branch-map` |
| Strict GitFlow | `bbd` | `branch-map` with `release/*`, `hotfix/*` globs |

See [Concepts](concepts.md) for what's happening under the hood, and
[Choose your setup](choose-your-setup.md) for paste-ready snippets.
