# Contributing

The authoritative contributor guide is [`AGENTS.md`](https://github.com/MagmaMoose/diatreme/blob/main/AGENTS.md)
at the repo root. This page is a short orientation; `AGENTS.md` has the full rules.

## Repository boundary

- Keep exactly **one** root action metadata file: `action.yml` (or `action.yaml`).
  CI fails otherwise.
- The worker is **self-contained** under `worker/`; its only runtime dependency is
  `jose`. Do not couple it to the action scripts or vendor code from the private
  `MagmaMoose/diatreme-pro` dashboard repo.

## Editing rules

- **Preserve action input names, output names, defaults, and behaviour** unless a
  breaking change is explicitly approved — every consumer pins to this contract.
- Keep `README.md` examples aligned with `action.yml`.
- Shell scripts must stay executable in Git (`git update-index --chmod=+x`).
- Never commit secrets, `.dev.vars`, build output, or caches.

## Local validation

Action surface (repo root):

```bash
ruby -e 'require "yaml"; YAML.load_file("action.yml")'
actionlint -color=false
shellcheck -S warning scripts/*.sh
bats tests/bats
```

Worker surface (`cd worker/`):

```bash
npm ci && npm run check   # typecheck + vitest + wrangler dry-run
```

## CI gates

- `ci.yaml` — validates both surfaces (actionlint, shellcheck, bats, a
  python-semantic-release pin smoke-test; worker typecheck + tests).
- `release.yaml` — dogfoods `uses: ./` to release the action and moves the floating
  major tag.
- `deploy-worker.yaml` — deploys `worker/` to Cloudflare.
- `security.yml` — the org Chargate security gate.
