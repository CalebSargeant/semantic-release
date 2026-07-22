# Quick start (most-run commands)

**Action surface (repo root):**
```bash
ruby -e 'require "yaml"; YAML.load_file("action.yml")'   # parse metadata
actionlint -color=false                                   # lint workflows/action
shellcheck -S warning scripts/*.sh                        # lint scripts
bats tests/bats                                           # run shell tests
git update-index --chmod=+x scripts/<file>.sh             # mark a new script exec
```

**Worker surface (`cd worker/`):**
```bash
npm ci
npm run typecheck        # tsc --noEmit
npm test                 # vitest
npm run check            # typecheck + tests + wrangler dry-run
wrangler dev             # run locally against .dev.vars
```

**Docs (repo root):**
```bash
pip install mkdocs-material   # one-time (build/serve dep)
mkdocs serve                  # preview at :8000
mkdocs build                  # render to ./site (gitignored)
```
