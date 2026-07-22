# Contributing to Diatreme

Thanks for helping improve Diatreme! This repo has **two independent surfaces**.
Please validate the one you touch. The fuller contributor guide (repository
boundary, editing rules) is [`AGENTS.md`](AGENTS.md).

| Surface | Path | Toolchain |
| --- | --- | --- |
| Composite action (Marketplace) | `action.yml` + `scripts/*.sh` | Bash, `actionlint`, `shellcheck`, `bats` |
| Cloudflare Worker (backend) | `worker/` | TypeScript, `wrangler`, `vitest` |

## Local validation

**Action surface (repo root):**

```bash
ruby -e 'require "yaml"; YAML.load_file("action.yml")'   # parse metadata
actionlint -color=false
shellcheck -S warning scripts/*.sh
bats tests/bats
```

> **macOS quirk:** `bats tests/bats` fails only `action-shell-syntax` on macOS
> system Ruby (2.6, missing `YAML.safe_load_file`). That is a local-only false
> failure, **CI is the source of truth** and runs the full suite green.

**Worker surface (`cd worker/`):**

```bash
npm ci
npm run check     # typecheck + vitest + wrangler dry-run
```

## Ground rules

- **Conventional Commits.** PR titles and commits follow
  `<type>(scope): summary` (`feat`, `fix`, `docs`, `style`, `refactor`, `perf`,
  `test`, `build`, `ci`, `chore`, `revert`), semantic-release derives the version
  from them. Branches follow `<type>/<description>`.
- **Don't break the public contract.** Preserve action **input names, output
  names, defaults, and behavior** unless a breaking change is explicitly approved.
  Keep the `README.md` examples and `docs/` aligned with `action.yml`.
- **Keep shell scripts executable in Git** (`core.fileMode` is off here):
  `git update-index --chmod=+x scripts/<new-script>.sh`.
- **Keep the Worker self-contained**: its only runtime dependency is `jose`. Don't
  couple it to the action scripts or vendor code from the private `diatreme-pro`.
- **Never commit** secrets, `.dev.vars`, build output, or caches (`node_modules/`,
  `.wrangler/`, `coverage/`, `site/`).

## Reporting issues

- Bugs / features: use the [issue templates](.github/ISSUE_TEMPLATE/).
- **Security vulnerabilities:** do **not** open a public issue; follow
  [`SECURITY.md`](SECURITY.md).

By contributing you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
