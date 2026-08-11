"""MCP Streamable HTTP mount (D-07): the same four read-only tools
`damso.mcp` already serves over stdio, now reachable at one POST endpoint
under the same auth boundary as the rest of the API - local or remote, an
MCP client points at one URL."""

from __future__ import annotations

from fastapi import APIRouter, Request, Response
from starlette.responses import JSONResponse

from .. import mcp

router = APIRouter()


@router.post("/mcp")
async def mcp_endpoint(request: Request) -> Response:
    store: mcp.ReadOnlyStore = request.app.state.mcp_store
    body = await request.json()
    response = mcp.dispatch(store, body)
    if response is None:
        # A notification has no reply. Streamable HTTP says answer it with
        # 202 and an empty body; returning a JSON-RPC envelope with a null id
        # instead makes a strict client treat it as a malformed response.
        return Response(status_code=202)
    return JSONResponse(response)
