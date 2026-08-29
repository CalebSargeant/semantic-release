# Releasing several packages from one repository

<!-- sources: action.yml, scripts/ -->

One repository, several independently versioned packages. `tag-prefix` is what keeps
their version histories apart.

!!! danger "A wrong `tag-prefix` ships the wrong version, silently"

    Nothing errors. The release succeeds, the tag is created, the artifact publishes —
    it just carries a version computed from another package's history. This is the one
    setting on this page worth double-checking before a first release.

Diatreme releases **one versioned unit per job**. To release more than one
package out of a single repository, run one job per package, each pointed at
that package's directory and its own tag series.

The versioning tools do the path filtering; Diatreme's part is to keep every
tag lookup scoped to the package being released.

## `tag-prefix` is what scopes the release

Give each package a distinct tag series and tell Diatreme about it:

```yaml
jobs:
  release-core:
    steps:
      - uses: actions/checkout@v5
        with: { fetch-depth: 0, fetch-tags: true }
      - uses: MagmaMoose/diatreme@v2
        with:
          working-directory: packages/core
          tag-prefix: 'core-v'          # ← tags are core-v1.2.3
          publish-package: 'true'
          package-ecosystem: pip
          package-path: packages/core
```

**This input is not cosmetic here.** Diatreme resolves "what was the last
release?" from the repository's tags. Unscoped, that question is answered by
whichever package released most recently — and the answer is a real version
attached to a real tag, so nothing errors. The wrong number simply flows into
the image tag, the published package and the GitHub Release. Every tag lookup
in the action is scoped by `tag-prefix`; leave it at the default `v` in a
multi-package repo and the packages will read each other's versions.

`tag-prefix` must agree with the tag format the versioning tool writes. Diatreme
cannot read that out of your tool's config, so the two are set independently and
it is on you to keep them in step.

## Python — `python-semantic-release`

PSR has had a monorepo commit parser since **v10.4.0**. Configure it in the
package's own `pyproject.toml`; Diatreme runs PSR with `working-directory` as
its cwd, so this is the file it reads:

```toml
[tool.semantic_release]
commit_parser = "conventional-monorepo"
tag_format = "core-v{version}"          # ← must match tag-prefix above

[tool.semantic_release.commit_parser_options]
path_filters = ["."]                    # only commits touching this directory
scope_prefix = "core-"                  # optional: also match feat(core-api):
```

`path_filters` accepts negated patterns prefixed with `!`.

## Node — `semantic-release-monorepo`

semantic-release has no built-in equivalent; the community shareable config does
the filtering. Declare it in the package's `.releaserc.json`:

```json
{
  "extends": "semantic-release-monorepo",
  "plugins": ["@semantic-release/commit-analyzer", "@semantic-release/github"]
}
```

Diatreme installs whatever your config declares — including `extends`, which it
must, because `semantic-release-monorepo` is only ever referenced there and
never appears under `plugins`. A shareable config that is not installed fails at
config load with `MODULE_NOT_FOUND`, before any release logic runs.

## Checkout depth

Path filtering needs history, and comparing against the previous release needs
tags. `fetch-depth: 0` and `fetch-tags: true` on the checkout are required —
with a shallow clone the parsers see a truncated commit range and quietly
under-report what changed.
