"""GitHub App authentication and installation-token minting.

Everything here runs *after* the OIDC token has been verified and the repository
claim matched, so the inputs are trusted. The App private key never leaves this
process; only the short-lived, repo-scoped installation token is returned to the
caller.

The Worker hand-rolled a PKCS#1 -> PKCS#8 DER wrapper because WebCrypto only accepts
PKCS#8, and GitHub hands out PKCS#1. That code is deleted rather than ported:
``cryptography`` reads both formats, so the whole class of bug goes with it.
"""

from __future__ import annotations

import time
from typing import Any

import httpx
import jwt

GITHUB_API_VERSION = "2022-11-28"
REQUEST_TIMEOUT_S = 10.0


class GitHubError(Exception):
    """A GitHub API call failed. ``code`` is the wire error string, ``status`` the HTTP status."""

    def __init__(self, status: int, code: str) -> None:
        super().__init__(code)
        self.status = status
        self.code = code


def app_jwt(app_id: str, private_key: str, now: float | None = None) -> str:
    """Mint the short-lived JWT that authenticates as the App itself.

    ``iat`` is backdated 60s because GitHub rejects a JWT whose ``iat`` is in the
    future, and runner/Lambda clocks drift. ``exp`` is 9 minutes: GitHub's ceiling is
    10, and the margin absorbs the same drift on the other side.
    """
    issued = int(now if now is not None else time.time())
    return jwt.encode(
        {"iat": issued - 60, "exp": issued + 9 * 60, "iss": app_id},
        private_key,
        algorithm="RS256",
    )


def _headers(token: str) -> dict[str, str]:
    return {
        "authorization": f"Bearer {token}",
        "accept": "application/vnd.github+json",
        "x-github-api-version": GITHUB_API_VERSION,
        "user-agent": "diatreme-broker",
    }


async def find_installation_id(
    client: httpx.AsyncClient, token: str, owner: str, repo: str, api_base: str
) -> int:
    """Resolve the App's installation on a repository.

    A 404 means the App is not installed — actionable by the consumer, so it gets its
    own status rather than being folded into a generic failure.
    """
    response = await client.get(
        f"{api_base}/repos/{owner}/{repo}/installation", headers=_headers(token)
    )
    if response.status_code == 404:
        raise GitHubError(404, "app_not_installed")
    if response.status_code >= 400:
        raise GitHubError(500, "github_installation_lookup_failed")
    body = response.json()
    installation_id = body.get("id") if isinstance(body, dict) else None
    if not isinstance(installation_id, int):
        raise GitHubError(500, "github_installation_lookup_failed")
    return installation_id


async def mint_installation_token(
    client: httpx.AsyncClient,
    token: str,
    installation_id: int,
    repo: str,
    permissions: dict[str, Any],
    api_base: str,
) -> dict[str, Any]:
    """Mint a token scoped to one repository with the configured permissions.

    Scoped down deliberately: the installation may cover many repositories, and the
    caller proved control of exactly one.
    """
    response = await client.post(
        f"{api_base}/app/installations/{installation_id}/access_tokens",
        headers=_headers(token),
        json={"repositories": [repo], "permissions": permissions},
    )
    if response.status_code >= 400:
        # The body can contain the token on some error shapes; never surface it.
        raise GitHubError(500, "github_token_create_failed")
    body = response.json()
    if not isinstance(body, dict) or not isinstance(body.get("token"), str):
        raise GitHubError(500, "github_token_create_failed")
    return {"token": body["token"], "expires_at": body.get("expires_at")}
