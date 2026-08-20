"""Every decision the broker makes, as framework-free ``(status, body)`` functions.

This module is the reason there is nothing to drift. Two adapters call it — the
Lambda handler in production, the FastAPI shell in dev and tests — so the deployed
code runs the same ladder the tests exercise rather than a copy of it.

**The evaluation order is load-bearing.** It is preserved from
``worker/src/index.ts``, and the wire contract with it: consumers pin the action by
SHA, so every status and error string here is frozen API surface for versions that
can never be updated. A renamed error is a broken consumer.
"""

from __future__ import annotations

import logging
import time
from typing import Any

import httpx

from app import github, jwks_store, oidc
from app.config import GITHUB_API_URL, BrokerConfig, ConfigError, load_config

_log = logging.getLogger("diatreme.broker")

# A retrieval fault is OUR unavailability, not a bad token. Reporting it as 401 is
# what made #147 unfalsifiable from the caller's side for hours.
JWKS_INFRA_REASONS = frozenset({"jwks_unavailable"})

# A snapshot older than this is refused outright. Long enough to ride out a real
# outage, short enough that a since-retired key cannot be honoured indefinitely.
SNAPSHOT_MAX_AGE_MS = 24 * 60 * 60 * 1000

Response = tuple[int, dict[str, Any]]


def _error(status: int, code: str, reason: str | None = None) -> Response:
    body: dict[str, Any] = {"error": code}
    if reason:
        body["reason"] = reason
    return status, body


def _repo_parts_valid(owner: str, repo: str) -> bool:
    """Reject anything that could escape the path it is interpolated into."""
    for part in (owner, repo):
        if not part or "/" in part or ".." in part or part.startswith("."):
            return False
    return True


async def _verify_with_snapshot_rescue(
    token: str,
    config: BrokerConfig,
    request_id: str | None,
) -> dict[str, Any]:
    """Verify, falling back to the last-known-good key set on a retrieval fault.

    The boundaries are the security surface:

    * Rescue applies **only** to ``jwks_unavailable``. On ``kid_not_found`` the fetch
      worked and the key genuinely is not published, so a stale set is strictly worse
      than an honest failure.
    * The snapshot supplies **keys only** — the retried verification re-checks the
      signature, the pinned issuer, the audience list and the expiry.
    * If the snapshot cannot rescue the token for *any* reason, the ORIGINAL
      retrieval error is re-raised. Surfacing the snapshot's failure instead would
      report a broker outage as "your token is bad", which is the exact confusion
      that cost hours in #147.
    """
    audiences = config.audiences()
    issuers = config.trusted_issuers()
    try:
        claims = await oidc.verify_token(token, audiences, issuers)
    except Exception as first_error:
        reason = oidc.classify_error(first_error)
        if reason != "jwks_unavailable" or not config.jwks_table_name:
            oidc.log_verify_failure(token, reason, first_error, audiences, issuers, request_id)
            raise

        issuer = _unverified_issuer(token, issuers)
        snapshot = jwks_store.load(config.jwks_table_name, issuer)
        rescued = _usable_snapshot(snapshot, issuer)
        if rescued is None:
            oidc.log_verify_failure(token, reason, first_error, audiences, issuers, request_id)
            raise

        try:
            claims = await oidc.verify_token(token, audiences, issuers, key_set=rescued["jwks"])
        except Exception:
            oidc.log_verify_failure(token, reason, first_error, audiences, issuers, request_id)
            raise first_error from None

        # Degraded mode must never pass unnoticed.
        _log.warning(
            {
                "event": "oidc_verified_from_stale_jwks",
                "issuer": issuer,
                "snapshot_age_seconds": int((time.time() * 1000 - rescued["uat"]) / 1000),
                "retrieval_reason": reason,
                "retrieval_jwks_status": getattr(first_error, "status", None),
                "repository": oidc.log_field(claims.get("repository")),
            }
        )
        return claims

    # Only a fully successful verification refreshes the snapshot.
    if config.jwks_table_name:
        issuer = claims.get("iss") or ""
        key_set = oidc.cached_key_set(issuer)
        if key_set:
            jwks_store.save(config.jwks_table_name, issuer, key_set)
    return claims


def _unverified_issuer(token: str, trusted: list[str]) -> str:
    """Which trusted issuer's snapshot to consult. Selection only, never trust."""
    import jwt as _jwt

    try:
        claimed = _jwt.decode(token, options={"verify_signature": False}).get("iss")  # nosemgrep: python.jwt.security.unverified-jwt-decode.unverified-jwt-decode
    except Exception:
        claimed = None
    return claimed if claimed in trusted else trusted[0]


def _usable_snapshot(snapshot: dict[str, Any] | None, issuer: str) -> dict[str, Any] | None:
    if not snapshot:
        return None
    age_ms = time.time() * 1000 - snapshot["uat"]
    if age_ms < 0 or age_ms > SNAPSHOT_MAX_AGE_MS:
        _log.warning(
            {
                "event": "jwks_snapshot_too_old",
                "issuer": issuer,
                "age_seconds": int(age_ms / 1000),
                "max_age_seconds": int(SNAPSHOT_MAX_AGE_MS / 1000),
            }
        )
        return None
    return snapshot


async def handle_token(body: Any, request_id: str | None = None) -> Response:
    """POST /token — OIDC token in, repo-scoped App installation token out."""
    if not isinstance(body, dict):
        return _error(400, "invalid_request")

    oidc_token = body.get("oidcToken")
    owner = body.get("owner")
    repo = body.get("repo")
    if not all(isinstance(v, str) and v for v in (oidc_token, owner, repo)):
        return _error(400, "missing_required_fields")
    if not _repo_parts_valid(owner, repo):
        return _error(400, "invalid_request")

    try:
        config = load_config()
    except ConfigError:
        # A deployment that was never finished, not a broker bug.
        return _error(503, "config_unavailable")

    try:
        claims = await _verify_with_snapshot_rescue(oidc_token, config, request_id)
    except Exception as error:
        reason = oidc.classify_error(error)
        if reason in JWKS_INFRA_REASONS:
            return _error(503, "oidc_key_fetch_failed", reason)
        return _error(401, "invalid_oidc_token", reason)

    repository = f"{owner}/{repo}"
    if claims.get("repository") != repository:
        return _error(403, "repo_mismatch")

    allowed = config.allowed()
    if allowed and repository not in allowed:
        return _error(403, "repo_not_allowed")

    is_ghe = config.is_ghe(claims.get("iss", ""))
    if is_ghe:
        app_id, private_key = config.ghe_app_id, config.ghe_private_key
        api_base = config.ghe_api_base
        if not (app_id and private_key and api_base):
            return _error(503, "config_unavailable")
    else:
        app_id, private_key, api_base = config.app_id, config.private_key, config.github_api_url

    try:
        assertion = github.app_jwt(app_id, private_key)
    except Exception:
        return _error(500, "github_app_private_key_invalid")

    async with httpx.AsyncClient(timeout=github.REQUEST_TIMEOUT_S) as client:
        try:
            installation_id = _explicit_installation(config) if is_ghe else None
            if installation_id is None:
                installation_id = await github.find_installation_id(
                    client, assertion, owner, repo, api_base
                )
            minted = await github.mint_installation_token(
                client, assertion, installation_id, repo, config.permissions(), api_base
            )
        except github.GitHubError as error:
            return _error(error.status, error.code)
        except httpx.HTTPError:
            return _error(502, "github_unreachable")

    return 200, {
        "token": minted["token"],
        "expires_at": minted["expires_at"],
        "repository": repository,
    }


def _explicit_installation(config: BrokerConfig) -> int | None:
    """A GHE App's secret carries its installation id, skipping the per-repo lookup."""
    raw = (config.ghe_installation_id or "").strip()
    if not raw:
        return None
    try:
        value = int(raw)
    except ValueError:
        return None
    return value if value > 0 else None


def handle_healthz() -> Response:
    """Liveness. Deliberately requires no configuration and touches no secret."""
    return 200, {"ok": True}


def handle_readyz() -> Response:
    """Readiness. 503 until the secrets exist, so a half-finished deploy is visible."""
    try:
        config = load_config()
    except ConfigError as error:
        return 503, {"ok": False, "error": "config_unavailable", "detail": str(error)}
    return 200, {
        "ok": True,
        "audiences": config.audiences(),
        "api": config.github_api_url or GITHUB_API_URL,
    }
