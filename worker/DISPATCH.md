# Diatreme dispatch → Claude Code on the Web

`POST /dispatch` hands an autonomous code-writing task to **Claude Code on the
Web** by firing a [Routine](https://code.claude.com/docs/en/routines) via its
API. The routine's session clones the repo, implements the task, and opens a
pull request.

```
caller (Zoey issue→dispatch, triage "fix", or you)
   │  POST /dispatch  { repo, instruction, issue?, pr?, user? }   Bearer PROCESS_TRIGGER_SECRET
   ▼
Diatreme worker
   │  enqueue task in KV  +  POST {text:<brief>} to the routine fire URL
   │     headers: Authorization: Bearer <routine token>, anthropic-beta: experimental-cc-routine-2026-04-01
   ▼
Claude Code routine session  → clone → implement → open PR
   │  (returns claude_code_session_id + url, stored on the task)
   ▼
(optional) signed commits: the session POSTs its file changes to /sign, which
   creates a GitHub-signed, you-attributed commit via createCommitOnBranch.
```

## One-time setup

1. **Create the routine** at <https://claude.ai/code/routines>:
   - Give it access to the target repo(s).
   - Paste the **routine prompt** below.
   - Add an **API trigger** → **Generate token** → copy the fire URL and token
     *immediately* (the token can't be retrieved later).
2. **Set the worker secrets / vars:**
   ```bash
   cd worker
   wrangler secret put DISPATCH_ROUTINE_TOKEN   # the per-routine bearer token
   # DISPATCH_TRIGGER_URL is the fire URL; set as a var or secret:
   #   https://api.anthropic.com/v1/claude_code/routines/<routine_id>/fire
   ```
   - `PROCESS_TRIGGER_SECRET` already gates `/dispatch` (and `/process`, `/sign`).
   - Without `DISPATCH_TRIGGER_URL`, `/dispatch` only queues (status
     `queued_no_trigger`). Without `DISPATCH_ROUTINE_TOKEN` but with a URL, it
     falls back to a plain webhook POST (for a self-hosted runner).

## Routine prompt (paste into the routine)

```
You are Diatreme's autonomous implementer. The user message is a task brief:
a repository, an optional issue/PR number, an instruction, and a Diatreme
dispatch id.

1. Work in the repository named in the brief.
2. Create a branch named diatreme/dispatch-<first 8 chars of the dispatch id>.
3. Implement the instruction. Keep the change focused; follow the repo's
   CLAUDE.md and conventions; run the repo's tests if it has them.
4. Open a pull request against the default branch. In the PR body include a
   short summary, the line "Diatreme dispatch: <dispatch id>", and a link to
   this Claude Code session.
5. If the task is ambiguous or can't be completed safely, open a DRAFT PR (or a
   comment) explaining what's blocked — do not guess.

Never modify CI secrets or workflow permissions, and never force-push a shared
branch.
```

## Signed, attributed commits (optional layer)

Sessions run with no secrets store, so the signing credential must not live in
the session. For GitHub-**Verified**, you-attributed commits, the session (or a
follow-up step) POSTs its file changes to the worker's `POST /sign`, which calls
`createCommitOnBranch` with your stored OAuth user token — GitHub then signs the
commit and attributes it to you. This requires the GitHub App to grant
**Contents: write as a user permission** (a re-authorisation). Until that's
wired, dispatched PRs carry the session's own commits.
