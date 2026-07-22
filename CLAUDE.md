# Diatreme

Release/deployment orchestrator with two independent surfaces in one repo: a
GitHub Marketplace **composite action** (`action.yml` + `scripts/*.sh`, bash,
bats-tested) and a **Cloudflare Worker** GitHub-App backend (`worker/`, TypeScript,
vitest). They talk over HTTP; neither imports the other. Most users only touch the
action. Full contributor rules live in `AGENTS.md` (read it before non-trivial edits).

@.claude/QUICK_START.md
@.claude/ARCHITECTURE_MAP.md
@.claude/COMMON_MISTAKES.md

## Finding code

- **Before locating unfamiliar code, read `./PROJECT_INDEX.json`** (modules,
  callgraph, hotspots) instead of grepping blind.
- `AGENTS.md` = full editing rules & local-validation commands. `README.md` =
  Marketplace user guide. `worker/README.md` = worker endpoints/config.
- Load `.claude/decisions/` (ADRs) and `.claude/sessions/` (summaries) ONLY when
  the task relates to them — never by default.

## [tooling]

- Prefer targeted line-range reads over whole files; use `PROJECT_INDEX.json` to
  find the location. `action.yml` is ~2740 lines — never read it whole.
- grep/find/glob: return matching paths and matched lines only.
- Commands that can flood output: pipe through `head`/`tail`/`grep` or redirect to
  `.claude/last_output.txt` and read ranges. Don't paste thousands of lines.
- After a successful write/edit, trust it; don't re-read just to "verify".

## [maintenance]

- Bug that took >1h: append to `.claude/COMMON_MISTAKES.md`.
- Architectural decision: run `/adr`.
- Public behaviour/API/config/setup changed: run `/update-docs`.
- `PROJECT_INDEX.json` stale (new module, big refactor): regenerate the affected
  modules section only.
- Keep this file under ~500 tokens; push detail into on-demand `.claude/` files.
