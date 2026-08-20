"""Shared fixtures.

The key generation is deliberately real RSA rather than a stub: the whole point of
these suites is that verification does the cryptography, so a fake key would test
the plumbing and none of the security.
"""

from __future__ import annotations

import time
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from app import oidc

GITHUB_ISSUER = "https://token.actions.githubusercontent.com"
GHE_ISSUER = "https://token.actions.acme.ghe.com"
AUDIENCE = ["diatreme"]


class Signer:
    """An RSA keypair plus the JWK the broker would fetch for it."""

    def __init__(self, kid: str) -> None:
        self.kid = kid
        self._key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.pem = self._key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        ).decode()
        numbers = self._key.public_key().public_numbers()
        jwk = jwt.algorithms.RSAAlgorithm.to_jwk(self._key.public_key(), as_dict=True)
        jwk.update({"kid": kid, "alg": "RS256", "use": "sig"})
        self.jwk = jwk
        self._numbers = numbers

    def mint(
        self,
        *,
        iss: str = GITHUB_ISSUER,
        aud: str = "diatreme",
        repository: str = "octo-org/octo-repo",
        exp_delta: int = 300,
        iat_delta: int = 0,
    ) -> str:
        now = int(time.time())
        return jwt.encode(
            {
                "iss": iss,
                "aud": aud,
                "repository": repository,
                "iat": now + iat_delta,
                "exp": now + exp_delta,
            },
            self.pem,
            algorithm="RS256",
            headers={"kid": self.kid},
        )


@pytest.fixture
def signer() -> Signer:
    return Signer("kid-a")


@pytest.fixture(autouse=True)
def _clean_oidc_cache():
    oidc.reset_cache()
    yield
    oidc.reset_cache()


class FakeJwksEndpoint:
    """Stands in for the issuer's JWKS endpoint, counting fetches.

    Counting matters: the rotation fix is "exactly one extra fetch", and the throttle
    is "and no more than that". Both are assertions about call counts, not outcomes.
    """

    def __init__(self, keys: list[dict[str, Any]]) -> None:
        self.keys = keys
        self.calls = 0
        self.status = 200
        self.raise_error: Exception | None = None

    def serve(self, keys: list[dict[str, Any]]) -> None:
        self.keys = keys

    async def __call__(self, issuer: str) -> dict[str, Any]:
        self.calls += 1
        if self.raise_error is not None:
            raise self.raise_error
        if self.status != 200:
            raise oidc.JwksUnavailable(
                "jwks fetch returned non-200",
                status=self.status,
                content_type="text/plain",
            )
        return {"keys": self.keys}


@pytest.fixture
def jwks(monkeypatch, signer: Signer) -> FakeJwksEndpoint:
    endpoint = FakeJwksEndpoint([signer.jwk])
    monkeypatch.setattr(oidc, "_fetch_jwks", endpoint)
    return endpoint
