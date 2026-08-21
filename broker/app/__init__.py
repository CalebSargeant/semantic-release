"""Diatreme token broker.

Exchanges a GitHub Actions OIDC token for a short-lived, repo-scoped GitHub App
installation token. Replaces the Cloudflare Worker at ``worker/src/index.ts``.

Nothing is re-exported here on purpose: ``app.broker`` is the only module that makes
decisions, and both adapters (``app.lambda_handler`` in production, ``app.main`` for
local dev and tests) import from it directly.
"""
