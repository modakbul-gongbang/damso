"""Server process configuration: store root, bind address, credentials location."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

# D-19: one fixed default so local and remote modes agree on "the" port
# unless the operator overrides it; local mode auto-reselects on conflict
# (see server/lifecycle notes in the Swift client), remote mode requires the
# operator to pick a free one and record it for the client's pairing step.
DEFAULT_PORT = 8787

LOOPBACK_HOST = "127.0.0.1"


@dataclass(frozen=True)
class ServerConfig:
    store_root: Path
    host: str
    port: int
    credentials_dir: Path

    @property
    def loopback_only(self) -> bool:
        """R1: local mode never leaves the loopback interface, so it never
        needs token auth (D-08) - only a non-loopback bind does."""
        return self.host in {LOOPBACK_HOST, "localhost", "::1"}

    @classmethod
    def from_environment(cls, environment: dict[str, str] | None = None) -> "ServerConfig":
        environment = environment if environment is not None else os.environ
        store_value = environment.get("DAMSO_STORE")
        if not store_value:
            raise ValueError("DAMSO_STORE is required")
        store_root = Path(store_value).expanduser().resolve()
        host = environment.get("DAMSO_SERVER_HOST", LOOPBACK_HOST)
        port = int(environment.get("DAMSO_SERVER_PORT", DEFAULT_PORT))
        credentials_value = environment.get("DAMSO_SERVER_CREDENTIALS_DIR")
        credentials_dir = (
            Path(credentials_value).expanduser().resolve()
            if credentials_value
            else default_credentials_dir()
        )
        return cls(store_root=store_root, host=host, port=port, credentials_dir=credentials_dir)


def default_credentials_dir() -> Path:
    # Deliberately a sibling of the canonical store, not inside it: the store
    # is what `damso.migration` copies/backs up, and credentials must never
    # ride along with a store export (D-24).
    return Path.home() / "Library" / "Application Support" / "Damso" / ".server-credentials"
