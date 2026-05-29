# Concepts

This page explains the ideas behind Diatreme. Use the README when you
only need a workflow snippet.

## What Diatreme Does

Diatreme is a composite GitHub Action that runs inside your workflow. In
release mode it:

1. gets a token that can write release artifacts
2. checks out the repository with full history and tags
3. resolves the target environment
4. runs one selected versioning tool
5. exposes normalized outputs such as `version`, `tag`, and `released`
6. promotes or rebuilds Docker images when `image_name` is set
7. optionally opens the next promotion PR for trunk-based promotion flows

In CI mode it only builds pull request Docker images tagged as `pr-<number>`.

## Version Creation

Diatreme does not decide version numbers by parsing commits itself. It
delegates that work to the selected versioning tool.

| Tool | How versions are decided |
|---|---|
| `semantic-release-python` | python-semantic-release reads commits and `pyproject.toml` |
| `semantic-release-npm` | semantic-release reads commits and its release config |
| `release-please` | release-please reads commits and its release config |
| `gitversion` | GitVersion reads branch history and `GitVersion.yml` |

The bundled semantic-release and release-please examples use
[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

| Commit | Release result |
|---|---|
| `fix: handle empty response` | Patch, for example `1.0.1` |
| `feat: add export endpoint` | Minor, for example `1.1.0` |
| `feat!: change API shape` | Major, for example `2.0.0` |
| Commit body with `BREAKING CHANGE:` | Major, for example `2.0.0` |

If you use GitVersion, the branch rules in `GitVersion.yml` control the version
increment.

### Forcing A Bump

Set `force-bump` to `patch`, `minor`, or `major` to override the tool's
own decision. Useful from `workflow_dispatch` when no qualifying
conventional commits exist since the last release but you still want
to cut a new version — the typical "no_release / Released: false"
outcome.

```yaml
on:
  workflow_dispatch:
    inputs:
      bump:
        type: choice
        options: ['', patch, minor, major]
        default: ''

jobs:
  release:
    steps:
      - uses: magmamoose/diatreme@v1
        with:
          force-bump: ${{ github.event.inputs.bump }}
```

Honoured by `semantic-release-python` (forwarded as the upstream
`force` input) and `gitversion` (passed as `/overrideconfig
increment=Major|Minor|Patch`). Ignored by `semantic-release-npm` and
`release-please` — those tools have no clean equivalent.

## Release Models

Diatreme supports two release models.

### Trunk-Based Development

Trunk-Based Development, or TBD, means one branch creates release tags. That
branch is usually `main`.

The same branch can create tags for multiple environments. The selected
environment decides whether the version is a prerelease or stable.

Example with three environments:

| Environment | Tag example | Meaning |
|---|---|---|
| `dev` | `v1.2.3-dev.1` | prerelease |
| `staging` | `v1.2.3-rc.1` | prerelease candidate |
| `prod` | `v1.2.3` | stable release |

There are two TBD variants:

- explicit environment: pass `deployment-model: tbd` and `environment`
- promotion PRs: pass `deployment-model: tbd-pr` and let merged
  `promote/...` branches select the next environment

`tbd-pr` is not a separate release model. It is the action input used for the
promotion-PR variant of TBD.

### Branch-Based Development

Branch-Based Development, or BBD, means long-lived branches represent
environments. The action uses `branch-map` to select the environment.

Example:

| Branch | Environment | Tag example |
|---|---|---|
| `dev` | `dev` | `v1.2.3-dev.1` |
| `staging` | `staging` | `v1.2.3-rc.1` |
| `main` | `prod` | `v1.2.3` |

Use BBD when your repository already promotes work by merging between
environment branches.

`branch-map` keys can be exact branch names *or* globs (any key containing
`*`). Globs are anchored at both ends and dots are escaped, so
`{"release/*": "staging"}` matches `release/1.0` but not `release.1.0`.
This is what enables strict GitFlow on top of BBD — see
[Branching strategies](branching-strategies.md) for the GitFlow mapping.

## Environment Order

The `environments` input is ordered. The last environment is stable. Every
earlier environment is a prerelease and must have an entry in
`prerelease-identifiers`.

```yaml
environments: '["dev", "staging", "prod"]'
prerelease-identifiers: '{"dev": "dev", "staging": "rc"}'
```

This means:

- `dev` creates tags like `v1.2.3-dev.1`
- `staging` creates tags like `v1.2.3-rc.1`
- `prod` creates tags like `v1.2.3`

For production-only repositories:

```yaml
environment: prod
environments: '["prod"]'
prerelease-identifiers: '{}'
```

## Docker Promotion

Docker support is enabled by setting `image_name`.

In CI mode, Diatreme builds your Docker Bake target or group and pushes
images tagged as `pr-<number>`.

In release mode, the semantic version becomes the image tag. For example:

```text
ghcr.io/my-org/my-app:v1.2.3
```

Release mode tries to retag an existing image before rebuilding:

| Flow | Source image |
|---|---|
| First TBD environment | the merged pull request image, such as `pr-42` |
| Later TBD environments | the previous environment's release image |
| BBD | the pull request image associated with the branch release |

If the source image cannot be found, the action runs a fresh Docker Bake build
and pushes the release tag. Stable releases also get `latest`.

## Persisting The Version In A Tracked File

Some apps need to know their own version at runtime — a .NET service
that displays "v1.2.3" in its footer reads it from `appsettings.json`,
a Node service from a generated `version.json`, a Helm chart from
`Chart.yaml`'s `appVersion`. Set `version-file` (and optionally the
path input) and Diatreme will:

1. Inject the resolved version into the file at the given path.
2. Commit with `[skip ci]`.
3. Push back to the active branch using the resolved release token, so
   the push bypasses branch-protection rulesets.

Works with every versioning tool. Off by default. The file format is
detected from its extension: `.yaml`/`.yml` files are processed with
`yq`; all other files are processed with `jq`. The commit lands *after*
the release tag, so the tag itself does not include the version-file
change — that's deliberate, the tag is your release boundary.

**JSON example** — inject into `appsettings.json`:

```yaml
with:
  version-file: src/MyApp.Web/appsettings.json
  version-file-json-path: .Application.Version
```

**YAML/Helm example** — update `appVersion` in `Chart.yaml` so the
chart's default `image.tag` (set to `{{ .Chart.AppVersion }}`) always
matches the released container image:

```yaml
with:
  version-file: charts/my-app/Chart.yaml
  # version-file-yaml-path defaults to .appVersion — no override needed
  # for the standard Helm use-case
```

## GitHub Projects Integration

Two optional toggles, both off by default.

`aggregate-github-projects: true` — after a release publishes, Release
Runner walks commits in the release range and the PRs they came from,
collects issue/PR refs (`#NNN`), looks up Projects v2 membership for
each, and appends a `## GitHub Project items` section to the release
notes (and any open promotion PR body for this tag). Grouped by Project,
showing each item's current Status when available.

`move-github-projects-on-release: true` — same ref collection, but
instead of just listing them it moves every linked Projects v2 item to
`github-projects-target-status` (default `Released`). Restricted to the
production environment by default, widen with
`github-projects-move-on-environments`.

Both require token scopes that go beyond the Diatreme App's
defaults — see the input documentation in
[Action reference](reference/action-inputs-outputs.md).

## Concurrency Safety

Two release runs on the same branch racing each other is the single
biggest source of "tag already exists" / "non-fast-forward" failures
this action sees in the wild. Typical sources:

- A `feat:` push to `develop` triggers a run; the version-file commit
  the action pushes back triggers a *second* run before the first
  finishes its Docker promotion.
- A maintainer hits **Run workflow** while a push-triggered run is
  still in flight.
- For TBD-PR setups, a promotion-PR merge fires both
  `pull_request:closed` *and* `push` — both legitimate entry points for
  the same release event.

Diatreme gives you two layers of defence:

### 1. The reusable workflow wrapper (the actual lock)

A composite action like Diatreme runs *inside* a job that the
caller defines, so it can't declare workflow-level `concurrency:`
itself. To get GitHub-enforced serialisation in a single line, call
the bundled reusable workflow instead of the action:

```yaml
jobs:
  release:
    uses: magmamoose/diatreme/.github/workflows/diatreme.yaml@v1
    permissions:
      contents: read
      id-token: write
    with:
      versioning-tool: gitversion
      deployment-model: bbd
      branch-map: '{"develop": "dev", "master": "prod"}'
      # ... same inputs as the direct-action call
    secrets:
      app-private-key: ${{ secrets.SEMANTIC_RELEASE_APP_PRIVATE_KEY }}
```

The wrapper declares:

```yaml
concurrency:
  group: diatreme-${{ github.event.pull_request.base.ref || github.ref_name }}
  cancel-in-progress: false
```

Group key resolution:

| Trigger | Resolves to |
|---|---|
| Push to `develop` | `diatreme-develop` |
| `workflow_dispatch` on `develop` | `diatreme-develop` |
| `pull_request:closed` targeting `main` | `diatreme-main` |

So a promotion-PR merge that fires both `pull_request:closed` *and*
`push` ends up in the same group — the second event waits for the
first to finish. `cancel-in-progress: false` is FIFO: no run is
killed mid-tag-publish.

Override via `concurrency-group` (string input) if you need a
different key, or `cancel-in-progress: true` if you genuinely want
later runs to win. The defaults are right for most setups.

### 2. Defensive race handling in the action

The reusable wrapper closes the workflow-level race; the action also
defends itself for the case where you call it directly without the
wrapper, or where commits land on the branch from outside the
concurrency group (Flux image bumps, dependabot, hotfix pushes from
another tool):

- **Tag creation** (gitversion + semantic-release-npm manual paths)
  pre-checks the remote for the target tag. If it already exists, the
  step exits cleanly with `released=false` rather than failing the
  workflow. A second check after a failed push catches the race
  window between check and push.
- **Version-file push-back** uses a 5-attempt rebase + push loop with
  exponential backoff. Non-fast-forward rejections trigger a fresh
  fetch + rebase; non-recoverable failures (auth errors, ruleset
  blocks) surface as a warning and let the rest of the release flow
  finish.

When in doubt, use the reusable workflow — it's the same set of
inputs and one less failure mode to think about.

## Release Write Token

Release mode needs a token because it may write Git tags, GitHub Releases,
release commits, promotion PR branches, and GHCR images.

Most repositories should use the default `auth-mode: public-app`, which uses
the Diatreme GitHub App. Use `auth-mode: github-token` only when
`GITHUB_TOKEN` is allowed to perform the required writes. Use
`auth-mode: private-app` when your organization owns the GitHub App.

## Manual-Release Guardrail

Manual `workflow_dispatch` runs in `mode: release` can be restricted to repo
admins, scoped to a threshold environment and everything downstream of it in
`environments`. Push and promotion-PR-merge triggers are unaffected — only
`workflow_dispatch` goes through this gate.

The check runs after the action has resolved which environment this run is
targeting. For TBD callers that's `inputs.environment`; for BBD callers it's
the env mapped from the branch via `branch-map`. The action then calls
`GET /repos/{owner}/{repo}/collaborators/{user}/permission` and only
`permission == admin` proceeds.

### Default: production is protected

`admin-required-from` defaults to **`@last`**, which resolves at runtime to
the last entry of `environments`. With every common naming scheme — `prod`,
`prd`, `production`, `live` — the production environment ends up gated
without the caller having to repeat the literal name. This applies in both
TBD and BBD modes.

Production protection by default means an out-of-the-box install of this
action does not let a non-admin force a production release, regardless of
naming. To make this work, the auth token needs
`Repository: Administration: Read`. With `auth-mode: public-app` (the
default), grant that permission on the Diatreme App and accept it on
each consuming installation. If the auth token can't read the permission,
the run fails loudly with a pointer to this section.

### Tightening or relaxing the threshold

| `admin-required-from` | Behaviour with `environments = ["dev","staging","prod"]` |
|---|---|
| `'@last'` (default) | Only manual prod releases require admin. |
| `prod` | Same as `@last` here — only prod. |
| `staging` | Manual staging and prod releases require admin. |
| `dev` | All manual releases require admin. |
| `''` | **No enforcement** — anyone with workflow access can manually release any environment. Use only when you have other gates (e.g. environment protection rules with required reviewers). |

The same threshold semantics apply to any environment list — for example
`["dev","tst","acc","prd"]` with `admin-required-from: acc` gates `acc` and
`prd`.

### TBD vs BBD

In **TBD** the env is whatever the caller picked from the
`workflow_dispatch` dropdown.

In **BBD** the env is the one `branch-map` maps the branch to (the
`workflow_dispatch` UI's "Use workflow from" dropdown picks the branch).
Branch-map authors should put the production env last in `environments` so
`@last` resolves correctly — that's already the convention this action
documents, and the version-decision logic relies on the same ordering.

> Default-on protection means upgrading to a version of the action that ships
> this guardrail will start failing manual prod releases for non-admin actors.
> Either grant the actor admin, mint the auth token from a source that has
> `Administration: Read`, or set `admin-required-from: ''` to opt out.

## ClickUp Integration

ClickUp's native GitHub integration runs the other direction: GitHub events
flow into ClickUp tasks. Diatreme adds the missing reverse direction:
when `aggregate-clickup-tickets` is `true`, after a release is published the
action scans the commits in the release range and the bodies of any PRs
referenced from those commits for `https://app.clickup.com/t/...` URLs. Any
matches are appended as a `## ClickUp tickets` section to the GitHub Release
notes and to the auto-opened promotion PR body when one exists.

Developers do not need to change how they work — as long as ClickUp links
land in PR descriptions or commit bodies, every release downstream surfaces
them automatically.

If no ClickUp links appear in the range, the step logs that and exits
quietly. Errors editing the release notes never fail the release.
