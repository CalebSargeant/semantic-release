<!-- PR title must follow Conventional Commits: <type>(scope): summary -->
<!-- The squash-merge title becomes the release commit, so semantic-release reads it. -->

## Summary

<!-- What does this change and why? Link the issue it closes. -->

Closes #

## Surface touched

- [ ] Composite action (`action.yml` / `scripts/`)
- [ ] Cloudflare Worker (`worker/`)
- [ ] Docs / CI / metadata only

## Validation

- [ ] `actionlint -color=false` passes
- [ ] `shellcheck -S warning scripts/*.sh` passes
- [ ] `bats tests/bats` passes (CI is source of truth; the macOS `action-shell-syntax` quirk is expected)
- [ ] `cd worker && npm run check` passes (if the worker changed)

## Compatibility & hygiene

- [ ] No action **input/output name, default, or behavior** change without an explicit breaking-change note
- [ ] `README.md`, `docs/`, and `worker/README.md` updated to match any user-facing change
- [ ] New shell scripts are executable in Git (`git update-index --chmod=+x`)
- [ ] No secrets, `.dev.vars`, build output, or `node_modules/` committed
