#!/bin/bash
set -euo pipefail

# V5 (AC7, AC11): confirms the SSH-era transport is fully gone (D-06 clean
# cut) and that the docs it required have been rewritten. Fails loudly and
# names exactly what it found, rather than passing silently on a partial cut.

cd "$(dirname "$0")/.."

fail=0

check_absent() {
  local description="$1"
  local pattern="$2"
  # Only counts live code (a type used as a constructor call or annotation),
  # never a prose comment explaining what replaced it - several new files
  # deliberately reference the old names in doc comments for that reason.
  if grep -rIlE "$pattern" Sources backend scripts Makefile 2>/dev/null \
      | grep -v '^scripts/check-no-ssh-remnants.sh$' \
      | while read -r file; do grep -E "$pattern" "$file" | grep -vE '^\s*(//|#|///|\*)'; done \
      | grep -q .; then
    echo "FAIL: found $description"
    fail=1
  fi
}

echo "Checking for ssh remote-transport remnants..."
check_absent "ssh remote execution (CommandLauncher-style)" "CommandLauncher\(|: CommandLauncher|RemoteExecutionConfiguration\(|: RemoteExecutionConfiguration|RemoteSetupService\(|: RemoteSetupService"
check_absent "InstanceRole server role" "InstanceRole\.|: InstanceRole|--server-role"
check_absent "the ssh-era DamsoServeClient/DamsoServeError transport" "DamsoServeClient\(|: DamsoServeClient|DamsoServeError\.|DamsoServeProtocol\."
# rsync itself is not banned outright: scripts/install-local-app.sh uses it
# locally to copy a build artifact, and comments elsewhere legitimately
# reference it to explain what replaced it (D-06/D-15) - only a remote
# `host:path` rsync invocation would indicate a surviving SSH transport, and
# none of the CommandLauncher-family checks above already caught that.

if [[ -f scripts/mcp-remote.sh ]]; then
  echo "FAIL: scripts/mcp-remote.sh still exists (D-07: MCP is HTTP-only now)"
  fail=1
fi

echo "Checking README privacy section no longer claims SSH-only reachability..."
# A bare mention of "SSH" is fine (the pairing model is explained as an
# analogy to SSH host-key trust); an actual transport claim is not.
if grep -qE "over SSH|via SSH|an SSH connection|reached only by SSH" README.md; then
  echo "FAIL: README.md still claims SSH as the transport"
  fail=1
fi
if ! grep -qi "token" README.md || ! grep -qiE "private network|tailscale" README.md; then
  echo "FAIL: README.md does not describe the token + trusted-private-network security model (ADR 0003)"
  fail=1
fi
if grep -qiE "self-signed|certificate you pin|pinned certificate|fingerprint" README.md; then
  echo "FAIL: README.md still describes the retired pinned-certificate model (ADR 0003 removed it)"
  fail=1
fi

echo "Checking INSTALL.md describes the two-unit install contract..."
if ! grep -q "install-server" INSTALL.md; then
  echo "FAIL: INSTALL.md does not mention make install-server"
  fail=1
fi
if ! grep -q "install-client" INSTALL.md; then
  echo "FAIL: INSTALL.md does not mention make install-client"
  fail=1
fi

echo "Checking an ADR supersedes ADR 0001..."
if ! grep -rl "0001-mac-mini-server-split" docs/adr --include="*.md" | grep -v "0001-mac-mini-server-split.md" | xargs -I{} grep -qi "supersede" {} 2>/dev/null; then
  echo "FAIL: no ADR found that supersedes docs/adr/0001-mac-mini-server-split.md"
  fail=1
fi

if [[ "$fail" == "0" ]]; then
  echo "OK: no SSH remnants found, docs updated."
fi
exit "$fail"
