"""JWKS resolution: rotation recovery, the throttle that bounds it, and retrieval faults.

Ported 1:1 from ``worker/test/jwks-rotation.test.ts`` — that suite is the behavioural
spec, and every case here failed against the Worker before #150.
"""

from __future__ import annotations

import httpx
import jwt
import pytest

from app import oidc
from tests.conftest import AUDIENCE, GHE_ISSUER, GITHUB_ISSUER, Signer


async def test_good_token_verifies_with_a_single_fetch(signer, jwks):
    claims = await oidc.verify_token(signer.mint(), AUDIENCE, [GITHUB_ISSUER])

    assert claims["repository"] == "octo-org/octo-repo"  # nosec B101
    assert jwks.calls == 1  # nosec B101


async def test_recovers_from_rotation_with_exactly_one_extra_fetch(signer, jwks):
    await oidc.verify_token(signer.mint(), AUDIENCE, [GITHUB_ISSUER])
    assert jwks.calls == 1  # nosec B101

    # GitHub rotates. The cached set is still inside its TTL and inside the cooldown,
    # so without the forced reload this token is unverifiable here — which is exactly
    # the #147 shape: a genuine, freshly minted token that cannot be verified.
    rotated = Signer("kid-b")
    jwks.serve([rotated.jwk])

    claims = await oidc.verify_token(rotated.mint(), AUDIENCE, [GITHUB_ISSUER])
    assert claims["repository"] == "octo-org/octo-repo"  # nosec B101
    assert jwks.calls == 2, "expected exactly one forced reload, not a loop"  # nosec B101


async def test_throttles_the_forced_reload(signer, jwks):
    await oidc.verify_token(signer.mint(), AUDIENCE, [GITHUB_ISSUER])
    unknown = Signer("kid-nope")

    # First unknown kid: one forced reload, still no match.
    with pytest.raises(oidc.KidNotFound):
        await oidc.verify_token(unknown.mint(), AUDIENCE, [GITHUB_ISSUER])
    assert jwks.calls == 2  # nosec B101

    # Second inside the throttle window: rejected without touching the issuer. This
    # is what stops unauthenticated junk tokens becoming an amplification vector.
    with pytest.raises(oidc.KidNotFound):
        await oidc.verify_token(unknown.mint(), AUDIENCE, [GITHUB_ISSUER])
    assert jwks.calls == 2  # nosec B101


async def test_non_200_carries_the_upstream_status(signer, jwks):
    jwks.status = 525  # the actual #147 failure: Cloudflare could not reach GitHub

    with pytest.raises(oidc.JwksUnavailable) as caught:
        await oidc.verify_token(signer.mint(), AUDIENCE, [GITHUB_ISSUER])

    assert caught.value.reason == "jwks_unavailable"  # nosec B101
    assert caught.value.status == 525  # nosec B101
    assert caught.value.content_type == "text/plain"  # nosec B101


async def test_transport_failure_is_a_retrieval_fault_not_a_bad_token(monkeypatch, signer):
    """Exercises the REAL _fetch_jwks, not the fixture that replaces it.

    The translation from a transport exception to JwksUnavailable is the whole point:
    without it a DNS/TLS failure surfaces as an opaque error and the caller is told
    its token is bad. Patching httpx keeps the real try/except in the path.
    """

    async def boom(self, *args, **kwargs):
        raise httpx.ConnectError("connection reset")

    monkeypatch.setattr(httpx.AsyncClient, "get", boom)

    with pytest.raises(oidc.JwksUnavailable) as caught:
        await oidc.verify_token(signer.mint(), AUDIENCE, [GITHUB_ISSUER])
    assert caught.value.reason == "jwks_unavailable"  # nosec B101
    # No status: nothing answered, so there is nothing to report but the class.
    assert caught.value.status is None  # nosec B101


async def test_real_fetch_translates_a_non_200(monkeypatch, signer):
    """Also the real _fetch_jwks: a non-200 must carry status and content-type."""

    async def not_ok(self, *args, **kwargs):
        return httpx.Response(525, text="handshake failed", headers={"content-type": "text/plain"})

    monkeypatch.setattr(httpx.AsyncClient, "get", not_ok)

    with pytest.raises(oidc.JwksUnavailable) as caught:
        await oidc.verify_token(signer.mint(), AUDIENCE, [GITHUB_ISSUER])
    assert caught.value.status == 525  # nosec B101
    assert caught.value.content_type == "text/plain"  # nosec B101


async def test_real_fetch_rejects_a_body_that_is_not_a_key_set(monkeypatch, signer):
    async def wrong_shape(self, *args, **kwargs):
        return httpx.Response(200, json={"not": "a jwks"})

    monkeypatch.setattr(httpx.AsyncClient, "get", wrong_shape)

    with pytest.raises(oidc.JwksUnavailable):
        await oidc.verify_token(signer.mint(), AUDIENCE, [GITHUB_ISSUER])


async def test_forged_issuer_cannot_select_a_foreign_key_set(signer, jwks):
    # Signed with a key the broker holds, but claiming an untrusted issuer. The
    # issuer pins to github.com, so the iss claim check must reject it.
    token = signer.mint(iss="https://evil.example.com")

    with pytest.raises(jwt.InvalidIssuerError):
        await oidc.verify_token(token, AUDIENCE, [GITHUB_ISSUER])


async def test_ghe_issuer_accepted_only_when_trusted(signer, jwks):
    token = signer.mint(iss=GHE_ISSUER)

    claims = await oidc.verify_token(token, AUDIENCE, [GITHUB_ISSUER, GHE_ISSUER])
    assert claims["iss"] == GHE_ISSUER  # nosec B101

    with pytest.raises(jwt.InvalidIssuerError):
        await oidc.verify_token(signer.mint(iss=GHE_ISSUER), AUDIENCE, [GITHUB_ISSUER])


async def test_wrong_audience_is_rejected(signer, jwks):
    with pytest.raises(jwt.InvalidAudienceError):
        await oidc.verify_token(signer.mint(aud="someone-else"), AUDIENCE, [GITHUB_ISSUER])


async def test_legacy_audience_still_accepted_alongside_the_current_one(signer, jwks):
    # Older pinned action versions still mint `release-runner`, and consumers pin by
    # SHA, so dropping it would break repositories that cannot be updated.
    claims = await oidc.verify_token(
        signer.mint(aud="release-runner"), ["diatreme", "release-runner"], [GITHUB_ISSUER]
    )
    assert claims["aud"] == "release-runner"  # nosec B101


async def test_expired_token_is_rejected(signer, jwks):
    with pytest.raises(jwt.ExpiredSignatureError):
        await oidc.verify_token(signer.mint(exp_delta=-60), AUDIENCE, [GITHUB_ISSUER])


async def test_snapshot_key_set_still_enforces_every_claim(signer, jwks):
    """The rescue path supplies keys and nothing else."""
    key_set = {"keys": [signer.jwk]}

    ok = await oidc.verify_token(signer.mint(), AUDIENCE, [GITHUB_ISSUER], key_set=key_set)
    assert ok["repository"] == "octo-org/octo-repo"  # nosec B101
    assert jwks.calls == 0, "the snapshot path must not touch the network"  # nosec B101

    with pytest.raises(jwt.InvalidAudienceError):
        await oidc.verify_token(
            signer.mint(aud="someone-else"), AUDIENCE, [GITHUB_ISSUER], key_set=key_set
        )
    with pytest.raises(jwt.InvalidIssuerError):
        await oidc.verify_token(
            signer.mint(iss="https://evil.example.com"),
            AUDIENCE,
            [GITHUB_ISSUER],
            key_set=key_set,
        )
    with pytest.raises(jwt.ExpiredSignatureError):
        await oidc.verify_token(
            signer.mint(exp_delta=-60), AUDIENCE, [GITHUB_ISSUER], key_set=key_set
        )
