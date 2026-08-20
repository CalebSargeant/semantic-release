"""The /token ladder, 1:1 with worker/test/index.test.ts.

Consumers pin the action by SHA, so every status and error string asserted here is
frozen API surface for versions that can never be updated. A renamed error is a
broken consumer, which is why these read as a contract rather than a smoke test.
"""

from __future__ import annotations

import json
from typing import Any

import httpx
import pytest

from app import broker
from tests.conftest import Signer


@pytest.fixture
def env(monkeypatch, signer: Signer):
    monkeypatch.setenv("APP_ID", "12345")
    monkeypatch.setenv("PRIVATE_KEY", signer.pem)
    monkeypatch.setenv("OIDC_AUDIENCE", "diatreme,release-runner")
    monkeypatch.delenv("SECRET_PATH", raising=False)
    monkeypatch.delenv("ALLOWED_REPOSITORIES", raising=False)
    monkeypatch.delenv("JWKS_TABLE_NAME", raising=False)
    monkeypatch.delenv("GHE_OIDC_ISSUER", raising=False)
    return None


class FakeGitHub:
    """Stands in for the GitHub REST API, recording what the broker asked for."""

    def __init__(self) -> None:
        self.installation_status = 200
        self.token_status = 201
        self.requests: list[tuple[str, str, Any]] = []

    async def handle(self, request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content) if request.content else None
        self.requests.append((request.method, str(request.url), body))
        if request.url.path.endswith("/installation"):
            if self.installation_status != 200:
                return httpx.Response(self.installation_status, json={})
            return httpx.Response(200, json={"id": 42})
        if self.installation_status == 200 and "access_tokens" in request.url.path:
            if self.token_status >= 400:
                return httpx.Response(self.token_status, json={"token": "do-not-leak"})
            return httpx.Response(
                201, json={"token": "ghs_minted", "expires_at": "2026-01-01T00:00:00Z"}
            )
        return httpx.Response(404, json={})


@pytest.fixture
def gh(monkeypatch) -> FakeGitHub:
    fake = FakeGitHub()
    real_client = httpx.AsyncClient

    def build(*args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(fake.handle)
        return real_client(*args, **kwargs)

    monkeypatch.setattr(broker.httpx, "AsyncClient", build)
    return fake


async def test_missing_fields_are_rejected_before_anything_else(env):
    assert await broker.handle_token({"owner": "octo-org"}) == (
        400,
        {"error": "missing_required_fields"},
    )


async def test_non_object_body_is_rejected(env):
    assert await broker.handle_token("nope") == (400, {"error": "invalid_request"})


async def test_path_traversal_in_repo_parts_is_rejected(env):
    status, body = await broker.handle_token(
        {"oidcToken": "x", "owner": "octo-org", "repo": "../../etc"}
    )
    assert (status, body) == (400, {"error": "invalid_request"})


async def test_happy_path_mints_a_repo_scoped_token(env, jwks, gh, signer):
    status, body = await broker.handle_token(
        {"oidcToken": signer.mint(), "owner": "octo-org", "repo": "octo-repo"}
    )

    assert status == 200
    assert body == {
        "token": "ghs_minted",
        "expires_at": "2026-01-01T00:00:00Z",
        "repository": "octo-org/octo-repo",
    }
    # Scoped to the one repository the caller proved control of, not the whole
    # installation.
    mint = next(r for r in gh.requests if "access_tokens" in r[1])
    assert mint[2]["repositories"] == ["octo-repo"]
    assert mint[2]["permissions"] == {"contents": "write", "pull_requests": "write"}


async def test_repo_claim_mismatch_is_403(env, jwks, gh, signer):
    token = signer.mint(repository="octo-org/other-repo")
    status, body = await broker.handle_token(
        {"oidcToken": token, "owner": "octo-org", "repo": "octo-repo"}
    )
    assert (status, body) == (403, {"error": "repo_mismatch"})


async def test_allowlist_is_enforced(env, jwks, gh, signer, monkeypatch):
    monkeypatch.setenv("ALLOWED_REPOSITORIES", "octo-org/allowed-repo")
    status, body = await broker.handle_token(
        {"oidcToken": signer.mint(), "owner": "octo-org", "repo": "octo-repo"}
    )
    assert (status, body) == (403, {"error": "repo_not_allowed"})


async def test_app_not_installed_is_404(env, jwks, gh, signer):
    gh.installation_status = 404
    status, body = await broker.handle_token(
        {"oidcToken": signer.mint(), "owner": "octo-org", "repo": "octo-repo"}
    )
    assert (status, body) == (404, {"error": "app_not_installed"})


async def test_token_creation_failure_never_leaks_the_body(env, jwks, gh, signer):
    gh.token_status = 500
    status, body = await broker.handle_token(
        {"oidcToken": signer.mint(), "owner": "octo-org", "repo": "octo-repo"}
    )
    assert (status, body) == (500, {"error": "github_token_create_failed"})
    assert "do-not-leak" not in json.dumps(body)


@pytest.mark.parametrize(
    ("mutate", "expected_reason"),
    [
        (lambda s: s.mint(aud="someone-else"), "audience_mismatch"),
        (lambda s: s.mint(iss="https://evil.example.com"), "issuer_mismatch"),
        (lambda s: s.mint(exp_delta=-60), "token_expired"),
        (lambda s: "not.a.jwt", "malformed_token"),
    ],
)
async def test_verification_failures_are_401_with_a_reason(
    env, jwks, gh, signer, mutate, expected_reason
):
    status, body = await broker.handle_token(
        {"oidcToken": mutate(signer), "owner": "octo-org", "repo": "octo-repo"}
    )
    assert status == 401
    assert body["error"] == "invalid_oidc_token"
    assert body["reason"] == expected_reason


async def test_retrieval_fault_is_503_not_401(env, jwks, gh, signer):
    """The #147 distinction: our unavailability is not the caller's bad token."""
    jwks.status = 525
    status, body = await broker.handle_token(
        {"oidcToken": signer.mint(), "owner": "octo-org", "repo": "octo-repo"}
    )
    assert status == 503
    assert body == {"error": "oidc_key_fetch_failed", "reason": "jwks_unavailable"}


async def test_unknown_kid_is_401_not_503(env, jwks, gh, signer):
    """The fetch worked; the key is genuinely not published. That is the caller's problem."""
    unknown = Signer("kid-nope")
    status, body = await broker.handle_token(
        {"oidcToken": unknown.mint(), "owner": "octo-org", "repo": "octo-repo"}
    )
    assert status == 401
    assert body["reason"] == "kid_not_found"


async def test_missing_config_is_503_not_500(env, jwks, gh, signer, monkeypatch):
    monkeypatch.delenv("PRIVATE_KEY", raising=False)
    status, body = await broker.handle_token(
        {"oidcToken": signer.mint(), "owner": "octo-org", "repo": "octo-repo"}
    )
    assert (status, body) == (503, {"error": "config_unavailable"})
