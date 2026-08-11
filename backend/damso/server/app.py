"""FastAPI application factory: wires store, queue, auth, and version
handshake into one process (R1, R2, D-09)."""

from __future__ import annotations

from contextlib import asynccontextmanager
from importlib import metadata as importlib_metadata

from fastapi import FastAPI, Request
from starlette.responses import JSONResponse

from .. import mcp as mcp_module
from .. import serve
from .auth import TokenAuthMiddleware
from .config import ServerConfig
from .credentials import Credentials, CredentialsMissing, load as load_credentials
from . import mcp_http, routes_v1
from .queue import ProcessingQueue

VERSION_HEADER = "x-damso-protocol-version"


def server_version() -> str:
    try:
        return importlib_metadata.version("damso")
    except importlib_metadata.PackageNotFoundError:
        return "dev"


def create_app(config: ServerConfig) -> FastAPI:
    credentials: Credentials | None
    try:
        credentials = load_credentials(config.credentials_dir)
    except CredentialsMissing:
        if config.loopback_only:
            credentials = None  # R1: local mode never needs a token.
        else:
            raise

    store = serve.Store.at(config.store_root)
    if not mcp_module.index_path(store.root).is_file():
        mcp_module.build_index(store.root)
    mcp_store = mcp_module.ReadOnlyStore(store.root)
    queue = ProcessingQueue(config.store_root / ".processing-queue.sqlite3", store.root)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        queue.recover_incomplete_on_startup()
        queue.start()
        try:
            yield
        finally:
            queue.stop()

    app = FastAPI(title="Damso Server", version=server_version(), lifespan=lifespan)
    app.state.store = store
    app.state.mcp_store = mcp_store
    app.state.queue = queue
    app.state.config = config
    app.state.credentials = credentials

    app.add_middleware(TokenAuthMiddleware, credentials_dir=config.credentials_dir, loopback_only=config.loopback_only)

    @app.middleware("http")
    async def check_protocol_version(request: Request, call_next):
        if request.url.path.startswith("/v1/") and request.url.path not in {"/v1/health", "/v1/version"}:
            requested = request.headers.get(VERSION_HEADER)
            if requested is not None:
                try:
                    parsed = int(requested)
                except ValueError:
                    # A header that is not a number is a malformed request, not
                    # a version negotiation failure. Parsing it unguarded raised
                    # ValueError out of the middleware and answered with a 500
                    # and a stack trace, which any client could trigger with one
                    # junk header.
                    return JSONResponse(
                        {"detail": f"malformed {VERSION_HEADER} header"},
                        status_code=400,
                    )
                if parsed != serve.PROTOCOL_VERSION:
                    return JSONResponse(
                        {"detail": f"unsupported protocol version {requested}; server requires {serve.PROTOCOL_VERSION}"},
                        status_code=409,
                    )
        return await call_next(request)

    @app.get("/v1/health")
    def health() -> dict[str, bool]:
        return {"ok": True}

    @app.get("/v1/version")
    def version() -> dict[str, object]:
        return {
            "protocolVersion": serve.PROTOCOL_VERSION,
            "serverVersion": server_version(),
        }

    app.include_router(routes_v1.router)
    app.include_router(mcp_http.router)
    return app
