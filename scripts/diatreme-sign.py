#!/usr/bin/env python3
"""Turn the current working-tree changes into a GitHub-signed commit.

Run inside a checked-out repo, on a branch that already exists on the remote at
the current HEAD. This collects the working-tree changes (vs HEAD), and POSTs
them to the Diatreme worker's ``/sign`` endpoint, which creates the commit via
GitHub's ``createCommitOnBranch`` mutation using the configured user's OAuth
token — so GitHub signs the commit (web-flow GPG key) and attributes it to that
user. The result is a "Verified", you-attributed commit on the branch, without
any signing credential ever living in the (secret-less) Claude Code session.

Intended flow inside a dispatched session:

    git checkout -b diatreme/dispatch-XXXX origin/<default-branch>
    git push origin HEAD                       # remote branch sits at the base
    ...make the code changes (do NOT commit)...
    diatreme-sign.py --repo owner/name --branch diatreme/dispatch-XXXX \
        --message "fix: thing"
    gh pr create --head diatreme/dispatch-XXXX --base <default-branch> ...

Environment:
    DIATREME_BASE_URL    e.g. https://api.diatreme.magmamoose.com
    DIATREME_SIGN_TOKEN  the worker's PROCESS_TRIGGER_SECRET (Bearer)
    DIATREME_USER        the GitHub login to attribute/sign as (must have
                         authorised the Diatreme App via /oauth/connect)
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request


def _git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], check=True, capture_output=True, text=True
    ).stdout


def _git_bytes(*args: str) -> bytes:
    return subprocess.run(["git", *args], check=True, capture_output=True).stdout


def collect_changes() -> tuple[list[dict], list[dict]]:
    """Stage everything, then classify changes vs HEAD into createCommitOnBranch
    fileChanges. additions carry the full new file contents (base64)."""
    _git("add", "-A")
    raw = _git_bytes("diff", "--cached", "--name-status", "-z", "HEAD")
    tokens = raw.split(b"\x00")
    additions: list[dict] = []
    deletions: list[dict] = []
    i = 0
    while i < len(tokens):
        status = tokens[i].decode()
        if not status:
            i += 1
            continue
        code = status[0]
        if code in ("R", "C"):  # rename/copy: old, new follow
            old_path = tokens[i + 1].decode()
            new_path = tokens[i + 2].decode()
            i += 3
            if code == "R":
                deletions.append({"path": old_path})
            additions.append(_addition(new_path))
        else:
            path = tokens[i + 1].decode()
            i += 2
            if code == "D":
                deletions.append({"path": path})
            else:  # A, M, T
                additions.append(_addition(path))
    return additions, deletions


def _addition(path: str) -> dict:
    with open(path, "rb") as fh:
        contents = base64.b64encode(fh.read()).decode("ascii")
    return {"path": path, "contents": contents}


def main() -> int:
    ap = argparse.ArgumentParser(description="Sign working-tree changes via Diatreme /sign")
    ap.add_argument("--repo", required=True, help="owner/name")
    ap.add_argument("--branch", required=True, help="existing remote branch to commit onto")
    ap.add_argument("--message", required=True, help="commit headline")
    ap.add_argument("--body", default="", help="commit body")
    ap.add_argument("--dry-run", action="store_true", help="print the payload, don't POST")
    args = ap.parse_args()

    base_url = (os.environ.get("DIATREME_BASE_URL") or "").rstrip("/")
    token = os.environ.get("DIATREME_SIGN_TOKEN") or ""
    user = os.environ.get("DIATREME_USER") or ""
    if not args.dry_run and not (base_url and token and user):
        print(
            "error: set DIATREME_BASE_URL, DIATREME_SIGN_TOKEN and DIATREME_USER",
            file=sys.stderr,
        )
        return 2

    expected_head_oid = _git("rev-parse", "HEAD").strip()
    additions, deletions = collect_changes()
    if not additions and not deletions:
        print("error: no working-tree changes to sign", file=sys.stderr)
        return 1

    payload = {
        "user": user,
        "repo": args.repo,
        "branch": args.branch,
        "expected_head_oid": expected_head_oid,
        "message": {"headline": args.message, "body": args.body},
        "additions": additions,
        "deletions": deletions,
    }

    if args.dry_run:
        print(json.dumps(payload, indent=2))
        return 0

    req = urllib.request.Request(
        f"{base_url}/sign",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as resp:
            body = json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        print(f"sign failed: HTTP {exc.code} {exc.read().decode()[:300]}", file=sys.stderr)
        return 1
    except urllib.error.URLError as exc:
        print(f"sign request failed: {exc}", file=sys.stderr)
        return 1

    commit = body.get("commit") or {}
    print(f"signed commit {commit.get('oid', '?')} on {args.branch}: {commit.get('url', '')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
