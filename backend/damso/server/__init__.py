"""Damso HTTP server: the canonical store owner and processing coordinator.

Supersedes the SSH stdio transport (`damso.serve`, `damso.mcp` over ssh). One
FastAPI process now serves the /v1 write/read API, the processing queue, and
the MCP Streamable HTTP endpoint, all behind the same auth boundary. See
docs/adr/0002-http-client-server.md for the rationale.
"""
