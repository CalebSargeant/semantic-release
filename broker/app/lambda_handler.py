"""AWS Lambda entrypoint — API Gateway HTTP API, payload format 2.0.

The production adapter. It does routing and marshalling and nothing else: every
decision lives in ``app.broker``, so what runs here is the same ladder the tests
exercise.

FastAPI is deliberately absent from this path. It is ~7 MB of zip and roughly
two-thirds of the cold start, to route four paths.
"""

from __future__ import annotations

import json
import logging
from base64 import b64decode
from typing import Any

from app import broker

logging.getLogger().setLevel(logging.INFO)
_log = logging.getLogger("diatreme.handler")


def _response(status: int, body: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body, separators=(",", ":")),
    }


def _read_body(event: dict[str, Any]) -> Any:
    """Decode the request body, honouring isBase64Encoded before any parsing."""
    raw = event.get("body")
    if raw is None:
        return None
    if event.get("isBase64Encoded"):
        try:
            raw = b64decode(raw).decode("utf-8")
        except Exception:
            return _INVALID
    try:
        return json.loads(raw)
    except ValueError:
        return _INVALID


class _Invalid:
    """Distinguishes "body was unparseable" from "body was absent"."""


_INVALID = _Invalid()


def _route(event: dict[str, Any]) -> tuple[str, str]:
    ctx = event.get("requestContext", {}) or {}
    http = ctx.get("http", {}) or {}
    method = (http.get("method") or event.get("httpMethod") or "").upper()
    path = http.get("path") or event.get("rawPath") or "/"
    # API Gateway stage prefixes are stripped so the same paths work behind a custom
    # domain and the execute-api URL.
    stage = ctx.get("stage")
    if stage and stage != "$default" and path.startswith(f"/{stage}"):
        path = path[len(stage) + 1 :] or "/"
    return method, path.rstrip("/") or "/"


async def _dispatch(event: dict[str, Any], request_id: str | None) -> broker.Response:
    method, path = _route(event)

    if path == "/healthz":
        return (
            broker.handle_healthz() if method == "GET" else (405, {"error": "method_not_allowed"})
        )
    if path == "/readyz":
        return broker.handle_readyz() if method == "GET" else (405, {"error": "method_not_allowed"})
    if path == "/token":
        if method != "POST":
            return 405, {"error": "method_not_allowed"}
        body = _read_body(event)
        if isinstance(body, _Invalid):
            return 400, {"error": "invalid_json"}
        return await broker.handle_token(body, request_id)
    return 404, {"error": "not_found"}


def handler(event: dict[str, Any], context: Any = None) -> dict[str, Any]:
    import asyncio

    request_id = getattr(context, "aws_request_id", None)
    try:
        status, body = asyncio.run(_dispatch(event, request_id))
    except Exception:
        # Never let an exception escape: API Gateway would turn it into a 502 whose
        # body says nothing, and the caller cannot tell that from a broker outage.
        _log.exception({"event": "unhandled_error", "request_id": request_id})
        status, body = 500, {"error": "internal_error"}
    return _response(status, body)
