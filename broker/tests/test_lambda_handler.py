"""The API Gateway adapter — routing and marshalling only."""

from __future__ import annotations

import json
from base64 import b64encode

from app import lambda_handler


def event(method: str, path: str, body: str | None = None, b64: bool = False) -> dict:
    return {
        "requestContext": {"http": {"method": method, "path": path}, "stage": "$default"},
        "body": body,
        "isBase64Encoded": b64,
    }


def test_healthz_needs_no_configuration():
    result = lambda_handler.handler(event("GET", "/healthz"))
    assert result["statusCode"] == 200  # nosec B101
    assert json.loads(result["body"]) == {"ok": True}  # nosec B101


def test_unknown_path_is_404():
    assert lambda_handler.handler(event("GET", "/nope"))["statusCode"] == 404  # nosec B101


def test_wrong_method_is_405_not_404():
    assert lambda_handler.handler(event("GET", "/token"))["statusCode"] == 405  # nosec B101


def test_unparseable_body_is_400_invalid_json():
    result = lambda_handler.handler(event("POST", "/token", "{not json"))
    assert result["statusCode"] == 400  # nosec B101
    assert json.loads(result["body"]) == {"error": "invalid_json"}  # nosec B101


def test_base64_bodies_are_decoded_before_parsing():
    payload = json.dumps({"owner": "octo-org"})
    result = lambda_handler.handler(
        event("POST", "/token", b64encode(payload.encode()).decode(), b64=True)
    )
    # Decoded and parsed, so it reaches the field check rather than failing as JSON.
    assert json.loads(result["body"]) == {"error": "missing_required_fields"}  # nosec B101


def test_trailing_slash_and_stage_prefix_route_the_same():
    stage_event = {
        "requestContext": {"http": {"method": "GET", "path": "/prod/healthz"}, "stage": "prod"},
        "body": None,
    }
    assert lambda_handler.handler(stage_event)["statusCode"] == 200  # nosec B101
    assert lambda_handler.handler(event("GET", "/healthz/"))["statusCode"] == 200  # nosec B101


def test_an_unexpected_error_becomes_a_json_500_not_a_bare_502(monkeypatch):
    """API Gateway turns an escaped exception into a 502 with an empty body, which the
    caller cannot tell from a broker outage."""

    async def explode(*args, **kwargs):
        raise RuntimeError("boom")

    monkeypatch.setattr(lambda_handler, "_dispatch", explode)
    result = lambda_handler.handler(event("GET", "/healthz"))
    assert result["statusCode"] == 500  # nosec B101
    assert json.loads(result["body"]) == {"error": "internal_error"}  # nosec B101
