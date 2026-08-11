"""Bearer-token credential lifecycle (D-08, D-24, ADR 0003).

Generated once by `make install-server` (or the regenerate CLI). Long-lived
and unrotated for this release - single-user scope, D-24. Regenerating
invalidates the previous token immediately; there is no grace period, because
a leaked token must stop working the moment the operator reacts.

The token is the only credential: the server speaks plain HTTP and relies on
the operator's trusted private network (Tailscale or a trusted LAN) for
transport privacy (ADR 0003). There is no certificate, key, or fingerprint.

Layout under `config.credentials_dir`, each file 0600:

    token    - the bearer token, one line, no trailing newline
"""

from __future__ import annotations

import hashlib
import secrets
import stat
import sys
from dataclasses import dataclass
from pathlib import Path

TOKEN_BYTES = 32


@dataclass(frozen=True)
class Credentials:
    token: str


def _write_private_file(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_bytes(content)
    path.chmod(stat.S_IRUSR | stat.S_IWUSR)


def generate(credentials_dir: Path) -> Credentials:
    """Creates a fresh token, overwriting any existing one. Any client paired
    against the previous token must re-pair with the new one."""
    token = secrets.token_urlsafe(TOKEN_BYTES)
    _write_private_file(credentials_dir / "token", token.encode("ascii"))
    return Credentials(token=token)


class CredentialsMissing(RuntimeError):
    pass


def load(credentials_dir: Path) -> Credentials:
    token_path = credentials_dir / "token"
    if not token_path.is_file():
        raise CredentialsMissing(f"no server credentials at {credentials_dir}; run install-server first")
    return Credentials(token=token_path.read_text(encoding="ascii").strip())


def token_matches(candidate: str, expected: str) -> bool:
    return secrets.compare_digest(candidate.encode("utf-8"), expected.encode("utf-8"))


def token_digest(token: str) -> str:
    """A non-secret identifier for logging/diagnostics - never log the raw token."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:12]


def main() -> int:
    import argparse
    import json

    from .config import default_credentials_dir

    parser = argparse.ArgumentParser(description="Damso server credential lifecycle (D-08, D-24)")
    parser.add_argument("action", choices=["generate", "regenerate", "show"])
    parser.add_argument("--credentials-dir", type=Path, default=None)
    arguments = parser.parse_args()
    credentials_dir = arguments.credentials_dir or default_credentials_dir()

    if arguments.action == "show":
        try:
            credentials = load(credentials_dir)
        except CredentialsMissing as error:
            print(str(error))
            return 1
        print(json.dumps({"tokenDigest": token_digest(credentials.token), "credentialsDir": str(credentials_dir)}, indent=2))
        return 0

    if arguments.action == "generate" and (credentials_dir / "token").exists():
        print(f"credentials already exist at {credentials_dir}; use 'regenerate' to replace them")
        return 1

    credentials = generate(credentials_dir)
    print(json.dumps({"token": credentials.token, "credentialsDir": str(credentials_dir)}, indent=2))
    print(
        "Save the token now - it is not printed again. Any client paired with the previous "
        "token must re-pair.",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
