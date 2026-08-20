"""The privacy contract on the failure log line.

The line exists so an incident is diagnosable in seconds instead of hours (#147). It
must never become an exfiltration channel for the credential it is describing, and it
must stay bounded no matter what a hostile token contains.
"""

from __future__ import annotations

import logging

import jwt
import pytest

from app import oidc
from tests.conftest import GITHUB_ISSUER, Signer


def _line(caplog) -> dict:
    records = [r for r in caplog.records if isinstance(r.msg, dict)]
    assert records, "expected exactly one structured line"
    return records[0].msg


def test_logs_decoded_claims_but_never_the_token(caplog, signer: Signer):
    caplog.set_level(logging.WARNING)
    token = signer.mint()
    signature = token.rsplit(".", 1)[1]

    oidc.log_verify_failure(
        token, "token_expired", jwt.ExpiredSignatureError(), ["diatreme"], [GITHUB_ISSUER]
    )

    line = _line(caplog)
    assert line["event"] == "oidc_verify_failed"
    assert line["reason"] == "token_expired"
    assert line["decodable"] == "true"
    assert line["header_kid"] == "kid-a"
    assert line["claim_repository"] == "octo-org/octo-repo"
    # The whole point: enough to diagnose, never the credential itself.
    assert token not in caplog.text
    assert signature not in caplog.text


def test_an_undecodable_token_still_produces_a_line(caplog):
    caplog.set_level(logging.WARNING)

    oidc.log_verify_failure(
        "header.payload.signature-do-not-log",
        "malformed_token",
        jwt.DecodeError(),
        ["diatreme"],
        [GITHUB_ISSUER],
    )

    line = _line(caplog)
    assert line["decodable"] == "false"
    assert "signature-do-not-log" not in caplog.text


def test_hostile_claim_values_are_truncated(caplog):
    """A token is attacker-controlled; the log line must stay bounded regardless."""
    caplog.set_level(logging.WARNING)
    hostile = Signer("k" * 5000)
    token = hostile.mint(repository="x" * 5000)

    oidc.log_verify_failure(
        token, "signature_invalid", jwt.InvalidSignatureError(), ["diatreme"], [GITHUB_ISSUER]
    )

    line = _line(caplog)
    assert len(line["header_kid"]) == oidc.LOG_FIELD_MAX
    assert len(line["claim_repository"]) == oidc.LOG_FIELD_MAX


def test_retrieval_faults_carry_the_upstream_status(caplog):
    caplog.set_level(logging.WARNING)
    error = oidc.JwksUnavailable("non-200", status=525, content_type="text/plain")

    oidc.log_verify_failure("not.a.jwt", error.reason, error, ["diatreme"], [GITHUB_ISSUER])

    line = _line(caplog)
    assert line["jwks_status"] == 525
    assert line["jwks_content_type"] == "text/plain"


@pytest.mark.parametrize(
    ("error", "expected"),
    [
        (jwt.ExpiredSignatureError(), "token_expired"),
        (jwt.ImmatureSignatureError(), "token_not_yet_valid"),
        (jwt.InvalidAudienceError(), "audience_mismatch"),
        (jwt.InvalidIssuerError(), "issuer_mismatch"),
        (jwt.InvalidSignatureError(), "signature_invalid"),
        (jwt.InvalidAlgorithmError(), "alg_unsupported"),
        (jwt.DecodeError(), "malformed_token"),
        (oidc.KidNotFound("k"), "kid_not_found"),
        (oidc.KeyAmbiguous(), "key_ambiguous"),
        (oidc.JwksUnavailable("x"), "jwks_unavailable"),
        (RuntimeError("?"), "unknown"),
    ],
)
def test_classification_table(error, expected):
    """InvalidSignatureError subclasses DecodeError in PyJWT, so ordering matters:
    a naive ladder reports a forged token as malformed and loses the one distinction
    an operator actually needs."""
    assert oidc.classify_error(error) == expected
