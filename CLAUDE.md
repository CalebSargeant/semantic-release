# Diatreme

Release/deployment orchestrator. Two surfaces, talking over HTTP, neither importing
the other: a Marketplace **composite action** (`action.yml` + `scripts/*.sh`, bash,
bats) and the **hosted GitHub-App broker** it calls (`worker/`, TypeScript, vitest).
Consumers pin by SHA, so action inputs and broker wire responses are frozen API
surface — changing one breaks repos nobody can reach. `AGENTS.md` is canonical for
contributor rules; edit it and this file together.

@.claude/QUICK_START.md
@.claude/ARCHITECTURE_MAP.md
@.claude/COMMON_MISTAKES.md

## Finding code

- **Before locating unfamiliar code, read `./PROJECT_INDEX.json`** (modules,
  callgraph, hotspots) instead of grepping blind.
- `AGENTS.md` = editing rules + local validation. `README.md` = Marketplace guide.
  `worker/README.md` = broker endpoints/config.
- Cloudflare, AWS, DNS or a hostname: read `.claude/INFRA_NOTES.md` first.
- `.claude/*.md` = terse agent context, unpublished. `./docs` = human docs, published.
- Load `.claude/decisions/` and `.claude/sessions/` ONLY when the task relates to
  them, never by default.

## [tooling]

- Prefer targeted line-range reads over whole files; use `PROJECT_INDEX.json` to
  find the location. Never read `action.yml` whole.
- grep/find/glob: return matching paths and matched lines only.
- Flooding commands: pipe through `head`/`tail`/`grep`, or redirect to
  `.claude/last_output.txt` and read ranges. Never paste thousands of lines.
- After a successful write/edit, trust it; don't re-read just to "verify".

## [maintenance]

- Bug that took >1h: append to `.claude/COMMON_MISTAKES.md` (infra/DNS/TLS ones to
  `.claude/INFRA_NOTES.md`).
- Architectural decision: run `/adr` (writes to `.claude/decisions/`).
- Public behaviour/API/config/setup changed: run `/update-docs`.
- `PROJECT_INDEX.json` stale (new module, big refactor): regenerate the affected
  modules section only, and update `generated`.
- Keep this file under ~500 tokens; push detail into on-demand `.claude/` files.
