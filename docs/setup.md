# Setup

## Use the action

Pin to the floating major tag:

```yaml
- uses: MagmaMoose/diatreme@v2
  with:
    mode: release
    environment: prod
```

### Required permissions

The default `auth-mode: public-app` exchanges an Actions OIDC token for a
short-lived GitHub App installation token through the hosted worker, so the job
needs:

```yaml
permissions:
  id-token: write   # mint the OIDC token for the broker
  contents: write   # create tags / releases
  pull-requests: write   # promotion PRs / auto-merge
```

It also needs the hosted **[Diatreme GitHub App](https://github.com/apps/diatreme)**
installed on the repository. See the
[repository README](https://github.com/MagmaMoose/diatreme#readme) for the full
per-mode permission matrix and alternative auth modes (`github-token`, `app`).

## Local development

This repo has two toolchains. Validate the surface you touched.

### Action surface (repo root)

```bash
ruby -e 'require "yaml"; YAML.load_file("action.yml")'   # parse metadata
actionlint -color=false
shellcheck -S warning scripts/*.sh
bats tests/bats
```

!!! warning "macOS local bats quirk"
    Running `bats tests/bats` on macOS system Ruby (2.6) fails **only**
    `action-shell-syntax` because `YAML.safe_load_file` is unavailable there. That
    suite passes on CI — it is not a real failure.

New shell scripts must be executable in Git (`core.fileMode` is off here):

```bash
git update-index --chmod=+x scripts/<new-script>.sh
```

### Worker surface (`cd worker/`)

```bash
npm ci
npm run typecheck   # tsc --noEmit
npm test            # vitest
npm run check       # typecheck + tests + wrangler dry-run
wrangler dev        # run locally against .dev.vars
```

Copy `worker/.dev.vars.example` to `worker/.dev.vars` (gitignored) for local secrets.

## Build these docs

```bash
pip install mkdocs-material
mkdocs serve   # preview at http://127.0.0.1:8000
mkdocs build   # render to ./site (gitignored)
```
