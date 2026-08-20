"""Last-known-good JWKS snapshots, in DynamoDB.

The AWS equivalent of the Cloudflare KV store added in #150. When an issuer's JWKS
endpoint is unreachable, the broker verifies against the last key set it successfully
fetched rather than rejecting every genuine token — the failure mode that blocked
releases across every consumer repository for hours.

**Why DynamoDB and not the obvious alternatives.** ``/tmp`` is scoped to one
execution environment, which the in-process cache already covers, and is empty on
exactly the cold start where the rescue is needed. SSM Parameter Store is free but
Standard tier caps values at 4 KB — a silent future failure the day GitHub publishes
another key — and it pollutes the secret path the IAM policy is scoped to. S3 has no
always-free tier past the first year and puts 20-40 ms on the success path. DynamoDB
provisioned at 1 RCU / 1 WCU sits inside the always-free 25/25 allowance, does
single-digit-millisecond writes, and has a native TTL attribute reproducing KV's
``expirationTtl`` exactly. Note ON-DEMAND is *not* in the always-free tier.

The security boundaries live in ``broker.py``, not here: this module only stores and
retrieves. It never decides whether a snapshot may be used.
"""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Any

_log = logging.getLogger("diatreme.jwks_store")

SNAPSHOT_TTL_S = 30 * 24 * 60 * 60
# On Cloudflare a handful of colos wrote occasionally. On Lambda every execution
# environment would write on every success, and there are far more of them, so the
# same code would multiply write volume by orders of magnitude for no benefit. The
# snapshot is at most this much staler, against a 24h usability ceiling.
WRITE_MIN_INTERVAL_S = 300.0

_clients: dict[str, Any] = {}
_last_write: dict[str, float] = {}


def client(service: str) -> Any:
    """Lazy boto3 — importing this module must not pull boto3 into a local run."""
    if service not in _clients:
        import boto3

        _clients[service] = boto3.client(service)
    return _clients[service]


def reset_cache() -> None:
    """Tests only."""
    _clients.clear()
    _last_write.clear()


def _key(issuer: str) -> str:
    return f"jwks:{issuer}"


def load(table: str, issuer: str) -> dict[str, Any] | None:
    """Return ``{"jwks": {...}, "uat": <epoch ms>}`` or None.

    Any failure returns None rather than raising: this is a rescue path reached only
    when something is already broken, and a DynamoDB problem must not replace the
    real retrieval error with a less useful one.
    """
    if not table:
        return None
    try:
        response = client("dynamodb").get_item(
            TableName=table, Key={"pk": {"S": _key(issuer)}}, ConsistentRead=False
        )
    except Exception as exc:
        _log.warning({"event": "jwks_snapshot_read_failed", "err_name": type(exc).__name__})
        return None

    item = response.get("Item")
    if not item:
        return None
    try:
        return {"jwks": json.loads(item["jwks"]["S"]), "uat": int(item["uat"]["N"])}
    except (KeyError, ValueError, TypeError):
        _log.warning({"event": "jwks_snapshot_malformed", "issuer": issuer})
        return None


def save(table: str, issuer: str, jwks: dict[str, Any]) -> None:
    """Best-effort write. A failure here must never fail a successful verification."""
    if not table:
        return
    keys = jwks.get("keys")
    if not isinstance(keys, list) or not keys:
        return

    now = time.monotonic()
    if now - _last_write.get(issuer, 0.0) < WRITE_MIN_INTERVAL_S:
        return
    _last_write[issuer] = now

    try:
        client("dynamodb").put_item(
            TableName=table,
            Item={
                "pk": {"S": _key(issuer)},
                "jwks": {"S": json.dumps(jwks, separators=(",", ":"))},
                "uat": {"N": str(int(time.time() * 1000))},
                "expires_at": {"N": str(int(time.time()) + SNAPSHOT_TTL_S)},
            },
        )
    except Exception as exc:
        _log.warning({"event": "jwks_snapshot_write_failed", "err_name": type(exc).__name__})


def table_name() -> str:
    return os.environ.get("JWKS_TABLE_NAME", "").strip()
