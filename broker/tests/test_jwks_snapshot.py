"""The last-known-good JWKS rescue — and, more importantly, its boundaries.

Ported from ``worker/test/jwks-rotation.test.ts``. Each boundary here is the
difference between "an outage is survivable" and "a stale key set quietly widens what
the broker will accept", so they are asserted individually rather than as one path.
"""

from __future__ import annotations

import json
import time
from typing import Any

import pytest

from app import broker, jwks_store, oidc
from app.config import load_config
from tests.conftest import GITHUB_ISSUER, Signer

SNAPSHOT_KEY = f"jwks:{GITHUB_ISSUER}"


class FakeDynamo:
    def __init__(self) -> None:
        self.items: dict[str, dict[str, Any]] = {}
        self.puts = 0

    def get_item(self, TableName: str, Key: dict, ConsistentRead: bool = False) -> dict:
        item = self.items.get(Key["pk"]["S"])
        return {"Item": item} if item else {}

    def put_item(self, TableName: str, Item: dict) -> dict:
        self.puts += 1
        self.items[Item["pk"]["S"]] = Item
        return {}

    def seed(self, issuer: str, keys: list[dict], age_ms: int = 0) -> None:
        self.items[f"jwks:{issuer}"] = {
            "pk": {"S": f"jwks:{issuer}"},
            "jwks": {"S": json.dumps({"keys": keys})},
            "uat": {"N": str(int(time.time() * 1000) - age_ms)},
        }


@pytest.fixture
def dynamo(monkeypatch):
    fake = FakeDynamo()
    jwks_store.reset_cache()
    monkeypatch.setattr(jwks_store, "client", lambda service: fake)
    yield fake
    jwks_store.reset_cache()


@pytest.fixture
def env(monkeypatch, signer: Signer):
    monkeypatch.setenv("APP_ID", "12345")
    monkeypatch.setenv("PRIVATE_KEY", signer.pem)
    monkeypatch.setenv("OIDC_AUDIENCE", "diatreme")
    monkeypatch.setenv("JWKS_TABLE_NAME", "diatreme-broker-cache")
    monkeypatch.delenv("SECRET_PATH", raising=False)
    monkeypatch.delenv("ALLOWED_REPOSITORIES", raising=False)


async def test_successful_verification_snapshots_the_key_set(env, jwks, dynamo, signer):
    await broker._verify_with_snapshot_rescue(signer.mint(), load_config(), None)

    stored = json.loads(dynamo.items[SNAPSHOT_KEY]["jwks"]["S"])
    assert [k["kid"] for k in stored["keys"]] == ["kid-a"]


async def test_rescues_a_genuine_token_when_retrieval_fails(env, jwks, dynamo, signer, caplog):
    dynamo.seed(GITHUB_ISSUER, [signer.jwk])
    jwks.status = 525  # the real #147 failure

    claims = await broker._verify_with_snapshot_rescue(signer.mint(), load_config(), None)

    assert claims["repository"] == "octo-org/octo-repo"
    # Degraded mode must never pass unnoticed.
    assert "oidc_verified_from_stale_jwks" in caplog.text


async def test_does_not_rescue_kid_not_found(env, jwks, dynamo, signer):
    """The fetch worked and the key is genuinely not published — a stale set is worse
    than an honest failure, so this must still reject."""
    dynamo.seed(GITHUB_ISSUER, [signer.jwk])
    unknown = Signer("kid-nope")

    with pytest.raises(oidc.KidNotFound):
        await broker._verify_with_snapshot_rescue(unknown.mint(), load_config(), None)


async def test_refuses_a_snapshot_past_the_age_ceiling(env, jwks, dynamo, signer, caplog):
    dynamo.seed(GITHUB_ISSUER, [signer.jwk], age_ms=25 * 60 * 60 * 1000)
    jwks.status = 525

    with pytest.raises(oidc.JwksUnavailable):
        await broker._verify_with_snapshot_rescue(signer.mint(), load_config(), None)
    assert "jwks_snapshot_too_old" in caplog.text


async def test_snapshot_still_enforces_audience_and_issuer(env, jwks, dynamo, signer):
    """The snapshot supplies keys, not permission.

    Both cases must surface the ORIGINAL retrieval fault, not a claim error:
    reporting the snapshot's failure would tell the caller its token is bad when the
    broker is the thing that is broken.
    """
    dynamo.seed(GITHUB_ISSUER, [signer.jwk])
    jwks.status = 525

    with pytest.raises(oidc.JwksUnavailable):
        await broker._verify_with_snapshot_rescue(
            signer.mint(aud="someone-else"), load_config(), None
        )
    with pytest.raises(oidc.JwksUnavailable):
        await broker._verify_with_snapshot_rescue(
            signer.mint(iss="https://evil.example.com"), load_config(), None
        )


async def test_no_table_configured_behaves_exactly_as_before(monkeypatch, jwks, signer):
    monkeypatch.setenv("APP_ID", "12345")
    monkeypatch.setenv("PRIVATE_KEY", signer.pem)
    monkeypatch.delenv("JWKS_TABLE_NAME", raising=False)
    monkeypatch.delenv("SECRET_PATH", raising=False)
    jwks.status = 525

    with pytest.raises(oidc.JwksUnavailable):
        await broker._verify_with_snapshot_rescue(signer.mint(), load_config(), None)


async def test_writes_are_throttled_per_execution_environment(env, jwks, dynamo, signer):
    """Every environment writing on every success would multiply write volume for
    nothing; the snapshot is at most WRITE_MIN_INTERVAL_S staler."""
    config = load_config()
    for _ in range(5):
        oidc.reset_cache()
        await broker._verify_with_snapshot_rescue(signer.mint(), config, None)

    assert dynamo.puts == 1


async def test_a_write_failure_never_fails_a_successful_verification(env, jwks, dynamo, signer):
    def explode(*args, **kwargs):
        raise RuntimeError("dynamo is down")

    dynamo.put_item = explode

    claims = await broker._verify_with_snapshot_rescue(signer.mint(), load_config(), None)
    assert claims["repository"] == "octo-org/octo-repo"
