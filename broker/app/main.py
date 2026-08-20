"""FastAPI shell — local development and the test suite ONLY.

Excluded from the Lambda zip by name. Production is ``app.lambda_handler``, where
API Gateway is the HTTP layer; shipping FastAPI would add ~7 MB and most of the cold
start to route four paths.

It exists so the ladder can be exercised over real HTTP semantics — status codes,
JSON bodies, method handling — without an AWS emulator in the loop.
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from app import broker

app = FastAPI(title="diatreme-broker", docs_url=None, redoc_url=None)


def _json(result: broker.Response) -> JSONResponse:
    status, body = result
    return JSONResponse(status_code=status, content=body)


@app.get("/healthz")
async def healthz() -> JSONResponse:
    return _json(broker.handle_healthz())


@app.get("/readyz")
async def readyz() -> JSONResponse:
    return _json(broker.handle_readyz())


@app.post("/token")
async def token(request: Request) -> JSONResponse:
    try:
        body: Any = await request.json()
    except Exception:
        return JSONResponse(status_code=400, content={"error": "invalid_json"})
    return _json(await broker.handle_token(body))
