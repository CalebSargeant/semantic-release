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
2. Create branch  diatreme/dispatch-<first 8 chars of the dispatch id>  from the
   default branch and push it immediately, empty, at the base:
       git push origin HEAD
3. Implement the instruction in the working tree — but DO NOT run `git commit`.
   Keep the change focused; follow the repo's CLAUDE.md; run its tests if any.
4. Create the commit THROUGH Diatreme so GitHub signs it and attributes it to
   the user (not the session). Download and run the signer:
       curl -fsSL https://raw.githubusercontent.com/magmamoose/diatreme/main/scripts/diatreme-sign.py -o /tmp/diatreme-sign.py
       python3 /tmp/diatreme-sign.py --repo <owner/name> --branch <branch> --message "<conventional-commit headline>"
5. Open a pull request against the default branch (the branch now carries your
   signed commit). In the PR body include a short summary, the line
   "Diatreme dispatch: <dispatch id>", and a link to this Claude Code session.
6. If the task is ambiguous or can't be completed safely, open a DRAFT PR (or a
   comment) explaining what's blocked — do not guess.

Never modify CI secrets or workflow permissions, and never force-push a shared
branch.
```

## Signed, attributed commits (the default)

Step 4 above creates the commit via `scripts/diatreme-sign.py`, which POSTs the
working-tree changes to the worker's `POST /sign` → `createCommitOnBranch` with
your stored OAuth token, so GitHub signs the commit and attributes it to **you**
("Verified"). The signing credential never enters the (secret-less) session.

Set these on the **routine's environment** (env vars). Note they are *not* the
signing key — that stays in the worker; the session only needs the worker URL,
the trigger bearer, and the login to attribute to:

    DIATREME_BASE_URL    https://api.diatreme.magmamoose.com
    DIATREME_SIGN_TOKEN  <the worker's PROCESS_TRIGGER_SECRET>
    DIATREME_USER        <your GitHub login>

**Prereq:** the Diatreme App must grant **Contents: write as a *user*
permission** and you must have authorised it via `/oauth/connect` — that's what
lets `createCommitOnBranch` write as you. Without it, `/sign` returns
`409 user_not_connected` and the session should fall back to a draft PR.
