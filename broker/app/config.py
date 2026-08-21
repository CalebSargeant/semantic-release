"""Broker configuration — the Diatreme GitHub App identity + OIDC policy.

Two runtimes, one settings class:

* **AWS Lambda** (production) — non-secret values arrive as function environment
  variables; the App ids and private keys come from SSM Parameter Store under
  ``SECRET_PATH`` and are overlaid on top of ``os.environ`` by :func:`load_config`.
* **Local / CI** — everything is in the process environment, ``SECRET_PATH`` is
  unset, the overlay is empty, and nothing imports boto3 at all.

**No pydantic**, for the reason chargate documents: ``pydantic`` + ``pydantic_core``
is ~5 MB of zip and the dominant cold-start term, to validate a handful of strings.

Two things differ from chargate, and both are load-bearing:

1. **The audience is a LIST.** The Worker accepted ``["diatreme", "release-runner"]``
   — the legacy value is still minted by older pinned action versions, and consumers
   pin by SHA, so dropping it silently breaks repositories that cannot be updated.
   A blank or whitespace-only ``OIDC_AUDIENCE`` falls back to both rather than
   becoming an audience nothing can ever match (that bug shipped once already; see
   ``parseAudience`` in ``worker/src/index.ts``).
2. **GitHub Enterprise is a second, optional identity.** A GHE tenant mints OIDC
   tokens from its own issuer with its own JWKS, and needs a distinct App and API
   base. Both halves must switch on the token's *verified* issuer.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, fields
from typing import Any

GITHUB_OIDC_ISSUER = "https://token.actions.githubusercontent.com"
GITHUB_OIDC_JWKS = f"{GITHUB_OIDC_ISSUER}/.well-known/jwks"
GITHUB_API_URL = "https://api.github.com"

DEFAULT_AUDIENCE = "diatreme"
# Accepted during the release-runner → diatreme migration so OIDC tokens minted by
# older pinned action versions still verify. Removing this breaks consumers who
# cannot bump; see #147 for what "consumers cannot bump" costs.
LEGACY_AUDIENCE = "release-runner"


class ConfigError(Exception):
    """Configuration is missing or malformed.

    Raised instead of pydantic's ``ValidationError``. ``/token`` turns this into a
    503 ``config_unavailable`` and ``/readyz`` into a 503 — a deployment that was
    never finished, not a broker bug.
    """


def _normalize_pem(value: str) -> str:
    if "\\n" in value and "-----BEGIN" in value:
        return value.replace("\\n", "\n")
    return value


def parse_audience(configured: str) -> list[str]:
    """Trim and comma-split a configured audience, falling back to the defaults.

    A whitespace-only value is truthy, and on the Worker it silently replaced the
    accept-list with an audience nothing could ever match — a global, permanent 401
    with nothing in the logs. Blank in, defaults out.
    """
    parsed = [entry.strip() for entry in (configured or "").split(",")]
    parsed = [entry for entry in parsed if entry]
    return parsed or [DEFAULT_AUDIENCE, LEGACY_AUDIENCE]


def _normalize_base_url(value: str) -> str:
    """Trim and strip trailing slashes.

    Deployer-supplied GHE endpoints arrive with copy-paste formatting (a trailing
    slash, a stray newline) that would otherwise break issuer comparison and produce
    double-slashed API URLs.
    """
    return (value or "").strip().rstrip("/")


@dataclass(frozen=True)
class BrokerConfig:
    """The App identity and the policy applied to every mint request."""

    # From SSM (production) or the environment (local).
    app_id: str
    private_key: str

    # The OIDC `aud` the consumer's action requests. Comma-separated; see parse_audience.
    oidc_audience: str = ""
    # Optional comma-separated owner/repo allowlist. Empty = allow any repo the App
    # is installed on.
    allowed_repositories: str = ""
    github_api_url: str = GITHUB_API_URL
    token_permissions_json: str = '{"contents": "write", "pull_requests": "write"}'

    # GitHub Enterprise (ghe.com / GHES) — opt-in. When ghe_oidc_issuer is set the
    # broker also accepts OIDC tokens from that issuer and mints via the GHE App
    # against ghe_api_base.
    ghe_oidc_issuer: str = ""
    ghe_api_base: str = ""
    ghe_app_id: str = ""
    ghe_private_key: str = ""
    ghe_installation_id: str = ""

    # Bearer gating POST /sign and GET /releases. Unset disables both endpoints.
    process_trigger_secret: str = ""

    # DynamoDB table holding last-known-good JWKS snapshots. Unset disables the
    # rescue path entirely and the broker behaves as it did before #150.
    jwks_table_name: str = ""

    def __post_init__(self) -> None:
        # frozen=True blocks plain assignment even here, so go through object.
        object.__setattr__(self, "private_key", _normalize_pem(self.private_key))
        object.__setattr__(self, "ghe_private_key", _normalize_pem(self.ghe_private_key))
        object.__setattr__(self, "ghe_oidc_issuer", _normalize_base_url(self.ghe_oidc_issuer))
        object.__setattr__(self, "ghe_api_base", _normalize_base_url(self.ghe_api_base))
        try:
            json.loads(self.token_permissions_json)
        except json.JSONDecodeError as exc:
            raise ValueError(f"TOKEN_PERMISSIONS_JSON is not valid JSON: {exc}") from exc

    def audiences(self) -> list[str]:
        return parse_audience(self.oidc_audience)

    def allowed(self) -> set[str]:
        return {entry.strip() for entry in self.allowed_repositories.split(",") if entry.strip()}

    def permissions(self) -> dict[str, Any]:
        return json.loads(self.token_permissions_json)

    def trusted_issuers(self) -> list[str]:
        """github.com always; the GHE tenant only when it is configured.

        The list is the trust boundary: an unverified ``iss`` may only select a JWKS
        if it appears here, and the chosen issuer is then pinned in verification so a
        forged ``iss`` can never reach a foreign key set.
        """
        if self.ghe_oidc_issuer:
            return [GITHUB_OIDC_ISSUER, self.ghe_oidc_issuer]
        return [GITHUB_OIDC_ISSUER]

    def is_ghe(self, issuer: str) -> bool:
        return bool(self.ghe_oidc_issuer) and issuer == self.ghe_oidc_issuer


def _ssm_overlay() -> dict[str, str]:
    path = os.environ.get("SECRET_PATH", "").strip()
    if not path:
        return {}
    # Imported inside the function so nothing pulls boto3 in locally or in CI.
    from app.ssm import secrets

    return secrets(path)


def load_config() -> BrokerConfig:
    """Resolve configuration per request, not at import.

    Per-request so a Lambda whose SSM parameters are seeded *after* the first deploy
    recovers without a redeploy. The SSM overlay wins over the environment so a
    leaked env var cannot beat Parameter Store.
    """
    names = {f.name for f in fields(BrokerConfig)}
    values: dict[str, str] = {}
    for name in names:
        env_value = os.environ.get(name.upper())
        if env_value is not None:
            values[name] = env_value
    values.update({k: v for k, v in _ssm_overlay().items() if k in names})

    missing = [name for name in ("app_id", "private_key") if not values.get(name)]
    if missing:
        raise ConfigError(f"missing required configuration: {', '.join(sorted(missing))}")
    return BrokerConfig(**values)
