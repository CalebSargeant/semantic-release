# Repository Setup

Use this checklist after the organization-level app and ruleset setup is done.
If the release models are new to you, read [Concepts](concepts.md) first.

## 1. Add A Versioning Config

Pick one release tool and commit its config.

| `versioning-tool` | Required config |
|---|---|
| `semantic-release-python` | `pyproject.toml` |
| `semantic-release-npm` | `.releaserc.json` or `package.json` |
| `gitversion` | `GitVersion.yml` |
| `release-please` | `release-please-config.json` |

Template files live in `examples/config/` in the repository.

## 2. Choose Docker Or Version-Only

If Diatreme should only create versions, tags, and GitHub Releases, do not set `image_name`.

If Diatreme should build and promote container images, add:

- a Docker Bake file, usually `docker-bake.hcl`
- a PR workflow using `mode: ci`
- `image_name` in the release workflow
- `packages: write` permissions

Single-image Bake target:

```hcl
variable "VERSION"    { default = "latest" }
variable "REGISTRY"   { default = "ghcr.io" }
variable "IMAGE_NAME" { default = "my-org/my-app" }
variable "PLATFORMS"  { default = "linux/amd64" }

target "default" {
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = split(",", PLATFORMS)
  tags       = ["${REGISTRY}/${IMAGE_NAME}:${VERSION}"]
}
```

For multiple images, make `default` a Bake group and give each target its own tag.

### Authenticate to a non-GHCR registry

The action's defaults — `registry: ghcr.io`, login as `github.actor` with the
workflow's auth token — work for GHCR on github.com. For any other registry,
set `registry`, `registry-username`, and `registry-password` to credentials
the registry actually accepts.

This is the right path for:

- GitHub Enterprise Server's container registry (`containers.<ghes-host>`)
- Harbor, JFrog Artifactory, Nexus
- Azure Container Registry, AWS ECR (with an access token), GCP Artifact Registry
- Any internal registry behind basic auth

Add these inputs to **both** your CI workflow (Section 3) and your release
workflow (Section 4), and store the credentials as repo or org secrets:

```yaml
- uses: magmamoose/diatreme@v1
  with:
    mode: release   # or ci
    image_name: my-app
    registry: containers.ghes.example.com
    registry-username: ${{ secrets.REGISTRY_USERNAME }}
    registry-password: ${{ secrets.REGISTRY_PASSWORD }}
```

Make sure the `${REGISTRY}` default in your `docker-bake.hcl` matches the
registry you log in to, otherwise the push will succeed-then-fail with a
hostname mismatch:

```hcl
variable "REGISTRY" { default = "containers.ghes.example.com" }
```

Leave `registry-username` and `registry-password` blank to keep the GHCR
defaults.

### Fetch git submodules

Diatreme runs its own `actions/checkout` internally before any
build step, so adding `actions/checkout` with `submodules: recursive`
in the caller workflow doesn't help — diatreme's checkout
overwrites it. Use the `submodules` input instead:

```yaml
- uses: magmamoose/diatreme@v1
  with:
    mode: release   # or ci
    image_name: my-app
    submodules: recursive
    auth-mode: private-app
    app-id: '12345'
    app-private-key: ${{ secrets.RELEASE_RUNNER_APP_PRIVATE_KEY }}
```

When `submodules` is non-`false` under `auth-mode: private-app` or
`auto`, the App installation token is broadened from current-repo
scope to owner scope, so submodules from sibling repos in the same
org are fetchable in one call. The App must be installed on the
submodule repo for that to actually grant access.

For `auth-mode: github-token` / `public-app`, supply a token (via
`github-token`) that has read access to the submodule repo. The action
doesn't issue a separate one in those modes.

## 3. Add CI For Docker Repositories

Skip this section for version-only releases.

TBD pull request CI:

```yaml
name: CI

on:
  pull_request:
    branches: [main]
    types: [opened, synchronize, reopened]

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      pull-requests: read
    steps:
      - uses: magmamoose/diatreme@v1
        with:
          mode: ci
          image_name: my-app
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

BBD pull request CI:

```yaml
name: CI

on:
  pull_request:
    branches: [dev, staging, main]
    types: [opened, synchronize, reopened]

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      pull-requests: read
    steps:
      - uses: magmamoose/diatreme@v1
        with:
          mode: ci
          image_name: my-app
          enforce_branch_naming: 'false'
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

## 4. Optional: Require Copilot Review

Diatreme can publish a merge gate that requires GitHub Copilot PR Review
to have reviewed the current PR head.

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

Then add `Diatreme / Require Copilot Review` as a required status check
in branch protection or repository rulesets. Configure GitHub automatic
Copilot review separately if you want Copilot to be requested automatically.

See [Require Copilot Review](copilot-review.md) for bot identity, freshness,
bypass, and permission options.

## 5. Add The Release Workflow

### Production-Only

Use this when every release from `main` is stable.

```yaml
name: Release

on:
  push:
    branches: [main]

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: magmamoose/diatreme@v1
        id: release
        with:
          mode: release
          environment: prod
          environments: '["prod"]'
          prerelease-identifiers: '{}'
```

Add `packages: write` and `image_name` when Docker promotion is enabled.

### Trunk-Based Promotion PRs

Use this when a merge to `main` releases to the first environment and the
action opens promotion PRs for the next environments. This is still a
Trunk-Based Development flow; `deployment-model: tbd-pr` enables promotion PR
detection.

```yaml
name: Release

on:
  push:
    branches: [main]
    paths-ignore: ['**.md', '.gitignore', 'LICENSE', 'CHANGELOG.md']
  pull_request:
    types: [closed]
    branches: [main]

jobs:
  release:
    if: |
      github.event_name == 'push' ||
      (
        github.event.pull_request.merged == true &&
        startsWith(github.head_ref, 'promote/')
      )
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      id-token: write
    steps:
      - uses: magmamoose/diatreme@v1
        id: release
        with:
          mode: release
          deployment-model: tbd-pr
          environment: ${{ github.event_name == 'push' && 'dev' || '' }}
          environments: '["dev", "staging", "prod"]'
          prerelease-identifiers: '{"dev": "dev", "staging": "rc"}'
          image_name: my-app
          create-promotion-pr: 'true'
```

Remove `packages: write` and `image_name` for a version-only flow.

### Branch-Based Development

Use this when each environment has its own long-lived branch.

```yaml
name: Release

on:
  push:
    branches: [dev, staging, main]

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      id-token: write
    steps:
      - uses: magmamoose/diatreme@v1
        id: release
        with:
          mode: release
          deployment-model: bbd
          branch-map: '{"dev": "dev", "staging": "staging", "main": "prod"}'
          environments: '["dev", "staging", "prod"]'
          prerelease-identifiers: '{"dev": "dev", "staging": "rc"}'
          image_name: my-app
```

Remove `packages: write` and `image_name` for a version-only flow.

## 6. Use Outputs In Later Jobs

Later jobs can consume Diatreme outputs such as `tag`, `version`, and
`released`.

```yaml
jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    outputs:
      version: ${{ steps.release.outputs.version }}
      tag: ${{ steps.release.outputs.tag }}
      released: ${{ steps.release.outputs.released }}
    steps:
      - uses: magmamoose/diatreme@v1
        id: release
        with:
          mode: release
          environment: prod
          environments: '["prod"]'
          prerelease-identifiers: '{}'

  next:
    needs: release
    if: needs.release.outputs.released == 'true'
    runs-on: ubuntu-latest
    steps:
      - run: echo "Released ${{ needs.release.outputs.tag }}"
```

## 7. Validate The First Run

Before relying on the workflow:

1. Open a PR and confirm Docker CI publishes `pr-<number>` when Docker is enabled.
2. If `require-copilot-review` is enabled, confirm the required status fails
   before Copilot reviews and passes after Copilot reviews the current head.
3. Merge a commit that your selected versioning tool should release.
4. Confirm the selected versioning tool updates only expected files.
5. Confirm a promotion PR is created when using `tbd-pr`.
6. Confirm later jobs read `tag`, `version`, and `released` correctly.
