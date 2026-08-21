# Common mistakes (footguns)

- **One root action file.** Exactly one `action.yml` at repo root; CI fails otherwise.
  Input/output **names, defaults and behaviour are frozen** — consumers pin by SHA, so a
  change breaks repos that cannot be updated. Keep README examples aligned.
- **Shell scripts need the exec bit in Git.** `core.fileMode=false`, so a new `scripts/*.sh`
  ships `100644` and breaks CI: `git update-index --chmod=+x scripts/<f>.sh`. `.mjs` run via
  `node` don't need it; `tests/bats/*.bats` are run *by* bats — leave those `100644`.
- **Keep the worker self-contained**: only runtime dep is `jose`. Don't couple it to
  `scripts/`, and never vendor code from the private `MagmaMoose/diatreme-pro`.
- **`bats tests/bats` fails only `action-shell-syntax` locally** on macOS system Ruby 2.6
  (`YAML.safe_load_file` missing). Not a real failure; it passes on CI.
- **`createRemoteJWKSet` does NOT self-heal a key rotation** — don't "simplify" the forced
  reload or the cooldown in `worker/`. Mechanics in `.claude/INFRA_NOTES.md`.
- **Never swallow an error with a bare `catch {}` on the /token path.** That turned a JWKS
  outage into a permanent, unfalsifiable `invalid_oidc_token` (#147). Classify on jose's
  `.code`, never `instanceof JOSEError` (all jose errors extend it). A *retrieval* fault is
  503, never 401.
- **The broker fallback must never fire on 4xx.** A rejected token is an answer, not an
  outage. Connection failure and 5xx only; `tests/bats/request-public-app-token.bats` pins it.
- **Copilot/triage/quota features were removed** and the KV binding that served them is gone.
  Don't reintroduce either.
- **Never commit** secrets, `.dev.vars`, or caches (`node_modules/`, `.wrangler/`,
  `coverage/`, `site/`, `broker/.venv/`).
- After editing `scripts/`, run `shellcheck -S warning scripts/*.sh` and `actionlint`.

Broker internals, infrastructure, DNS and TLS: `.claude/INFRA_NOTES.md`.
