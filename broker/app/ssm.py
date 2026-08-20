"""Read the broker's secrets from SSM Parameter Store, once per execution environment.

Standard-tier ``SecureString`` parameters are free — storage *and* ``GetParameter``
calls — which is why this is not Secrets Manager ($0.40/secret/month). The parameters
are seeded by hand, never by Terraform: a secret in a Terraform resource is a secret
in Terraform state, and the infra repo is public.

Why not just put the PEM in a Lambda environment variable: anything holding
``lambda:GetFunctionConfiguration`` can read it, and it would be visible in the
console. SSM keeps it behind its own IAM statement and behind the KMS grant.
"""

from __future__ import annotations

import time
from typing import Any

#: Built once per execution environment and reused. A warm invocation pays nothing.
_clients: dict[str, Any] = {}

#: ``{path: {field: value}}`` for the life of this execution environment.
_cache: dict[str, dict[str, str]] = {}

#: Monotonic deadline before which a previously-failed path is not retried.
_negative_until: dict[str, float] = {}

#: How long a failed lookup is remembered. SSM Standard throughput is 40 TPS and is
#: shared account-wide, so hammering it on every request during an IAM misconfiguration
#: is how one broken deployment becomes a throttled account.
NEGATIVE_TTL_SECONDS = 30.0


def client(service: str) -> Any:
    """A boto3 client, built once per execution environment and then reused.

    LAZY RATHER THAN MODULE-LEVEL. ``import boto3`` at module scope would make this
    module unimportable without a configured region, so plain ``pytest`` collection
    would depend on AWS environment variables — and it would break
    ``test_lambda_package.py``'s poisoned-``sys.modules`` run, which proves the zip
    does not secretly rely on anything the Lambda runtime happens to supply.
    """
    if service not in _clients:
        import boto3

        _clients[service] = boto3.client(service)
    return _clients[service]


def _field_name(parameter_name: str) -> str:
    """``/chargate/prod/private-key`` -> ``private_key``.

    The basename with hyphens turned into underscores, so parameter names read
    naturally in the console and still land on ``BrokerConfig`` field names.
    """
    return parameter_name.rsplit("/", 1)[-1].replace("-", "_")


def secrets(path: str) -> dict[str, str]:
    """Every parameter under ``path``, keyed by :func:`_field_name`.

    Cached per execution environment. Failures are negative-cached for
    :data:`NEGATIVE_TTL_SECONDS` and then retried, so a transient SSM outage or a
    late-seeded parameter recovers without a redeploy.
    """
    cached = _cache.get(path)
    if cached is not None:
        return cached

    blocked_until = _negative_until.get(path)
    if blocked_until is not None and time.monotonic() < blocked_until:
        raise RuntimeError(f"SSM lookup for {path} failed recently; not retried yet")

    try:
        resolved = _fetch(path)
    except Exception:
        _negative_until[path] = time.monotonic() + NEGATIVE_TTL_SECONDS
        raise

    _negative_until.pop(path, None)
    _cache[path] = resolved
    return resolved


def _fetch(path: str) -> dict[str, str]:
    """One paginated ``get_parameters_by_path``.

    FOLLOWS ``NextToken``. The page size is 10, so a stack that grows past ten
    parameters would otherwise silently lose the eleventh — a missing secret that
    presents as a 503 with nothing in the logs pointing at pagination.
    """
    ssm = client("ssm")
    resolved: dict[str, str] = {}
    token: str | None = None

    while True:
        kwargs: dict[str, Any] = {"Path": path, "Recursive": True, "WithDecryption": True}
        if token:
            kwargs["NextToken"] = token
        page = ssm.get_parameters_by_path(**kwargs)

        for parameter in page.get("Parameters", []):
            resolved[_field_name(parameter["Name"])] = parameter["Value"]

        token = page.get("NextToken")
        if not token:
            return resolved


def reset_cache() -> None:
    """Drop every cache. Tests only — nothing in the request path calls this."""
    _cache.clear()
    _negative_until.clear()
    _clients.clear()
