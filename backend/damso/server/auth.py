"""Bearer-token auth, required on every request except when the server is
bound to loopback only (R1, R2, D-08). The token is the only credential the
server has: the transport it travels over is plain HTTP, and its privacy is
the operator's own private network (ADR 0003). This module only checks the
`Authorization: Bearer <token>` header once the connection has been
accepted."""

from __future__ import annotations

from pathlib import Path

from fastapi import Request
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse

from .credentials import CredentialsMissing, load as load_credentials, token_matches

# Health/version must stay reachable without a token: a client checking
# "is a server even here, and what version" during pairing has no token yet.
# Nothing else belongs here. `/docs` and `/openapi.json` were exempt too, which
# handed the full route list to anyone who could reach the port - not required
# by any flow, just FastAPI's defaults surviving. They are token-gated now; in
# local mode the middleware short-circuits before this check, so browsing the
# schema on the machine that owns the store still works.
UNAUTHENTICATED_PATHS = frozenset({"/v1/health", "/v1/version"})


class TokenAuthMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, *, credentials_dir: Path, loopback_only: bool) -> None:
        super().__init__(app)
        self._credentials_dir = credentials_dir
        self._loopback_only = loopback_only

    async def dispatch(self, request: Request, call_next):
        if self._loopback_only:
            return await call_next(request)
        if request.url.path in UNAUTHENTICATED_PATHS:
            return await call_next(request)
        try:
            # D-24: reloaded per request (two small file reads) rather than
            # cached at startup, so `damso-server-credentials regenerate`
            # invalidates the old token immediately against an already-
            # running process, not only after a restart.
            credentials = load_credentials(self._credentials_dir)
        except CredentialsMissing:
            return JSONResponse({"detail": "server has no credentials configured"}, status_code=503)
        header = request.headers.get("authorization", "")
        if not header.startswith("Bearer "):
            return JSONResponse({"detail": "missing bearer token"}, status_code=401)
        candidate = header[len("Bearer "):]
        if not token_matches(candidate, credentials.token):
            return JSONResponse({"detail": "invalid bearer token"}, status_code=401)
        return await call_next(request)
