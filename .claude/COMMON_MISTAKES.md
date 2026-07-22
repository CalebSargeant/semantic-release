# Common mistakes (footguns)

- **One root action file.** Keep exactly one `action.yml` at repo root; CI fails
  otherwise. Preserve input/output **names, defaults, and behavior**; changing them
  is a breaking change for every consumer. Keep README examples aligned with it.
- **Shell scripts need the exec bit in Git.** `core.fileMode=false` here, so a new
  `scripts/*.sh` ships `100644` and breaks CI. Run
  `git update-index --chmod=+x scripts/<f>.sh`. (`.mjs` run via `node` don't need it.)
- **Keep the worker self-contained**: only runtime dep is `jose`. Don't couple it
  to `scripts/`, and never vendor code from the private `MagmaMoose/diatreme-pro`.
- **`bats tests/bats` fails only `action-shell-syntax` locally** on macOS system Ruby
  2.6 (`YAML.safe_load_file` missing). Not a real failure; it passes on CI.
- **Legacy name, not a bug:** the KV binding `COPILOT_QUOTA_KV` (+ `COPILOT_QUOTA_KV_ID`
  deploy var) now just caches `/releases`. Copilot/triage/quota features were removed;
  don't reintroduce them.
- **Never commit** secrets, `.dev.vars`, or caches (`node_modules/`, `.wrangler/`,
  `coverage/`, `site/`).
- After editing `scripts/`, run `shellcheck -S warning scripts/*.sh` and `actionlint`.
