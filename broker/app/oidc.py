"""GitHub Actions OIDC verification.

This module is the trust boundary. Everything downstream mints a credential, so a
mistake here hands one to the wrong repository.

It is deliberately NOT a port of chargate's ``oidc.py``. That one is a plain
"fetch JWKS, verify" resolver; treating it as a drop-in would regress two incidents
this broker already survived:

* **#147** — a JWKS *retrieval* failure was indistinguishable from a bad token. Every
  consumer saw ``401 invalid_oidc_token`` while the real fault was Cloudflare failing
  a TLS handshake to GitHub. Retrieval faults are a separate, retryable class here
  (``jwks_unavailable`` -> 503), and the upstream HTTP status is carried into the log
  because the JWT library discards it.
* **#150** — a signing-key rotation, or any retrieval outage, failed every genuine
  token. A last-known-good snapshot rescues that, under strict boundaries.

Four invariants, each with a test:

1. The issuer is chosen from the trusted list *before* verification and then pinned,
   so a forged ``iss`` can never select a foreign key set.
2. The snapshot supplies **keys only**. Signature, pinned issuer, audience and expiry
   are all re-checked against it — a stale set can never admit a token a fresh set
   would reject, only one signed by a since-retired key.
3. The snapshot is consulted **only** for a retrieval fault, never for
   ``kid_not_found``: there the fetch worked and the key genuinely is not published,
   so a stale set is strictly worse than an honest failure.
4. Nothing attacker-controlled reaches the log untruncated, and the token never
   reaches it at all.
"""

from __future__ import annotations

import contextlib
import logging
import time
from typing import Any

import httpx
import jwt
from jwt import PyJWK, PyJWKSet

from app.config import GITHUB_OIDC_ISSUER

_log = logging.getLogger("diatreme.oidc")

# How long a fetched key set is served without revalidation.
JWKS_CACHE_TTL_S = 300.0
# After any fetch, suppress implicit refetches for this long. Bounds an
# unauthenticated caller's ability to drive traffic at the issuer.
JWKS_COOLDOWN_S = 30.0
# An explicit reload bypasses the cooldown, so it needs its own bound: one forced
# reload per issuer per interval, per execution environment.
FORCED_RELOAD_MIN_INTERVAL_S = 5.0
JWKS_TIMEOUT_S = 5.0

# Longest attacker-controlled string that may reach a log line.
LOG_FIELD_MAX = 128

# Keyed only by trusted-issuer strings, never by caller input, so neither can grow
# unboundedly. Execution-environment scoped, which is the Lambda analogue of the
# Worker's module-scope isolate state.
_jwks_cache: dict[str, dict[str, Any]] = {}
_last_forced_reload: dict[str, float] = {}


class OidcError(Exception):
    """Base for every verification failure, carrying a coarse machine-readable reason."""

    def __init__(self, reason: str, message: str = "") -> None:
        super().__init__(message or reason)
        self.reason = reason


class JwksUnavailable(OidcError):
    """The key set could not be retrieved. Our unavailability, not a bad token.

    ``status`` and ``content_type`` are carried because JWT libraries collapse any
    non-200 into a generic error and discard them — which is precisely what made #147
    undiagnosable. 403 (egress blocked), 429 (throttled) and 525 (handshake failed)
    need opposite responses and were indistinguishable without this.
    """

    def __init__(
        self,
        message: str,
        *,
        status: int | None = None,
        content_type: str | None = None,
    ) -> None:
        super().__init__("jwks_unavailable", message)
        self.status = status
        self.content_type = content_type


class KidNotFound(OidcError):
    def __init__(self, kid: str | None) -> None:
        super().__init__("kid_not_found", f"no signing key for kid {kid!r}")
        self.kid = kid


class KeyAmbiguous(OidcError):
    def __init__(self) -> None:
        super().__init__("key_ambiguous", "multiple signing keys matched")


def reset_cache() -> None:
    """Tests only."""
    _jwks_cache.clear()
    _last_forced_reload.clear()


def cached_key_set(issuer: str) -> dict[str, Any] | None:
    """The key set currently held for an issuer, if any.

    Exposed so the snapshot writer can persist exactly what verification used,
    without reaching into module internals.
    """
    entry = _jwks_cache.get(issuer)
    return entry["jwks"] if entry else None


def _jwks_url(issuer: str) -> str:
    return f"{issuer.rstrip('/')}/.well-known/jwks"


async def _fetch_jwks(issuer: str) -> dict[str, Any]:
    """Fetch a key set, tagging any non-200 with the status the caller needs.

    ``follow_redirects=False`` on purpose: a redirect on this endpoint is a
    misconfiguration or an interception, not something to chase silently.
    """
    url = _jwks_url(issuer)
    try:
        async with httpx.AsyncClient(timeout=JWKS_TIMEOUT_S, follow_redirects=False) as client:
            response = await client.get(
                url, headers={"accept": "application/json, application/jwk-set+json"}
            )
    except httpx.HTTPError as exc:  # DNS, TLS, timeout, reset
        raise JwksUnavailable(f"jwks fetch failed: {type(exc).__name__}") from exc

    if response.status_code != 200:
        raise JwksUnavailable(
            "jwks fetch returned non-200",
            status=response.status_code,
            content_type=response.headers.get("content-type"),
        )
    try:
        payload = response.json()
    except ValueError as exc:
        raise JwksUnavailable("jwks response was not JSON") from exc
    if not isinstance(payload, dict) or not isinstance(payload.get("keys"), list):
        raise JwksUnavailable("jwks response had no keys array")
    return payload


def _cached(issuer: str) -> dict[str, Any] | None:
    entry = _jwks_cache.get(issuer)
    if not entry:
        return None
    if time.monotonic() - entry["fetched_at"] > JWKS_CACHE_TTL_S:
        return None
    return entry["jwks"]


def _cooling_down(issuer: str) -> bool:
    entry = _jwks_cache.get(issuer)
    return bool(entry) and (time.monotonic() - entry["fetched_at"]) < JWKS_COOLDOWN_S


def _may_force_reload(issuer: str) -> bool:
    now = time.monotonic()
    if now - _last_forced_reload.get(issuer, 0.0) < FORCED_RELOAD_MIN_INTERVAL_S:
        return False
    _last_forced_reload[issuer] = now
    return True


def _select_key(jwks: dict[str, Any], kid: str | None, alg: str | None) -> PyJWK:
    """Exactly one key must match. Zero and many are different failures."""
    matches = [
        k
        for k in jwks["keys"]
        if (kid is None or k.get("kid") == kid)
        and (k.get("alg") is None or alg is None or k.get("alg") == alg)
        and k.get("use") in (None, "sig")
    ]
    if not matches:
        raise KidNotFound(kid)
    if len(matches) > 1:
        raise KeyAmbiguous()
    return PyJWKSet.from_dict({"keys": matches}).keys[0]


async def resolve_signing_key(issuer: str, kid: str | None, alg: str | None) -> PyJWK:
    """Resolve a signing key, forcing exactly one reload on a `kid` miss.

    The rotation case that #150 fixed: a cached-but-stale key set makes a genuine,
    freshly minted token unverifiable. The cooldown that protects the issuer from
    junk traffic is the same thing that would strand us on the old set, so the
    forced reload deliberately bypasses it — and is throttled separately so it
    cannot itself become an amplification vector.
    """
    jwks = _cached(issuer)
    if jwks is None:
        jwks = await _fetch_jwks(issuer)
        _jwks_cache[issuer] = {"jwks": jwks, "fetched_at": time.monotonic()}

    try:
        return _select_key(jwks, kid, alg)
    except KidNotFound:
        if _cooling_down(issuer) and not _may_force_reload(issuer):
            raise
        jwks = await _fetch_jwks(issuer)
        _jwks_cache[issuer] = {"jwks": jwks, "fetched_at": time.monotonic()}
        return _select_key(jwks, kid, alg)


def classify_error(error: BaseException) -> str:
    """Map a verification failure to the coarse reason surfaced to the caller.

    Ordered most-specific first. ``InvalidSignatureError`` subclasses
    ``DecodeError`` in PyJWT, so a naive isinstance ladder reports a forged token as
    malformed — which loses the one distinction an operator needs.
    """
    if isinstance(error, OidcError):
        return error.reason
    if isinstance(error, jwt.ExpiredSignatureError):
        return "token_expired"
    if isinstance(error, jwt.ImmatureSignatureError):
        return "token_not_yet_valid"
    if isinstance(error, jwt.InvalidAudienceError):
        return "audience_mismatch"
    if isinstance(error, jwt.InvalidIssuerError):
        return "issuer_mismatch"
    if isinstance(error, jwt.InvalidSignatureError):
        return "signature_invalid"
    if isinstance(error, jwt.InvalidAlgorithmError):
        return "alg_unsupported"
    if isinstance(error, jwt.MissingRequiredClaimError | jwt.InvalidIssuedAtError):
        return "claim_invalid"
    if isinstance(error, jwt.DecodeError):
        return "malformed_token"
    if isinstance(error, jwt.InvalidTokenError):
        return "claim_invalid"
    return "unknown"


def log_field(value: Any) -> str | None:
    """Truncate anything attacker-controlled before it reaches a log line."""
    if value is None:
        return None
    text = value if isinstance(value, str) else str(value)
    return text[:LOG_FIELD_MAX]


def log_verify_failure(
    token: str,
    reason: str,
    error: BaseException,
    audiences: list[str],
    trusted_issuers: list[str],
    request_id: str | None = None,
) -> None:
    """One structured line per failure. Never the token, never the library message.

    The library message is excluded on purpose: PyJWT embeds claim values in some of
    them. Unverified claims are logged individually, each truncated, so the line is
    bounded no matter what a hostile token contains.
    """
    claims: dict[str, Any] = {"decodable": "false"}
    try:
        header = jwt.get_unverified_header(token)
        payload = jwt.decode(token, options={"verify_signature": False})
        claims = {
            "decodable": "true",
            "header_kid": log_field(header.get("kid")),
            "header_alg": log_field(header.get("alg")),
            "claim_iss": log_field(payload.get("iss")),
            "claim_aud": log_field(payload.get("aud")),
            "claim_repository": log_field(payload.get("repository")),
            "claim_iat": log_field(payload.get("iat")),
            "claim_exp": log_field(payload.get("exp")),
        }
    except Exception:
        pass

    line: dict[str, Any] = {
        "event": "oidc_verify_failed",
        "reason": reason,
        "err_name": type(error).__name__,
        "expected_audience": ",".join(audiences),
        "trusted_issuers": ",".join(trusted_issuers),
        "now_epoch": int(time.time()),
        **claims,
    }
    if isinstance(error, JwksUnavailable):
        line["jwks_status"] = error.status
        line["jwks_content_type"] = log_field(error.content_type)
    if request_id:
        line["request_id"] = log_field(request_id)
    # .warning, not .exception: a traceback would render the library message this
    # line deliberately excludes. A 401 is also expected traffic, not an error.
    _log.warning(line)


async def verify_token(
    token: str,
    audiences: list[str],
    trusted_issuers: list[str],
    *,
    key_set: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Verify an Actions OIDC token and return its claims.

    ``key_set`` supplies keys directly, bypassing retrieval — that is the snapshot
    rescue path, and it changes nothing else: the pinned issuer, the audience list,
    the signature and the expiry are all still enforced below.
    """
    unverified_issuer = None
    # Leave it None on failure; the pinned default still applies and verification
    # fails honestly below rather than here.
    with contextlib.suppress(jwt.PyJWTError):
        unverified_issuer = jwt.decode(token, options={"verify_signature": False}).get("iss")

    # An unverified `iss` may only *select* a key set, and only from the trust list.
    # It is then pinned below, so a forged issuer can never reach a foreign key.
    issuer = unverified_issuer if unverified_issuer in trusted_issuers else GITHUB_OIDC_ISSUER

    header = jwt.get_unverified_header(token)
    if key_set is not None:
        signing_key = _select_key(key_set, header.get("kid"), header.get("alg"))
    else:
        signing_key = await resolve_signing_key(issuer, header.get("kid"), header.get("alg"))

    return jwt.decode(
        token,
        signing_key.key,
        algorithms=["RS256"],
        audience=audiences,
        issuer=issuer,
        options={"require": ["exp", "iat", "iss", "aud"]},
    )
