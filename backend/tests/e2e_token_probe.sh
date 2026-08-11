#!/bin/bash
# V4: end-to-end proof that a non-loopback Damso daemon is reachable exactly
# the way an external client (an MCP client, curl, anything) sees it after
# ADR 0003 - plain HTTP, bearer token, no certificate to trust and no host
# alias to invent.
#
# Everything here runs against a throwaway store, a throwaway credentials
# directory, and a freshly generated synthetic token; the operator's real
# store, real token, and real server are never touched.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="$(mktemp -d)"
store="$scratch/store"
credentials_dir="$scratch/creds"
mkdir -p "$store/Plaud/recordings"

export PYTHONPATH="$repo_root/backend"
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

server_pid=""
cleanup() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null
  [[ -n "$server_pid" ]] && wait "$server_pid" 2>/dev/null
  rm -rf "$scratch"
}
trap cleanup EXIT

failures=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   %-58s %s\n' "$label" "$actual"
  else
    printf 'FAIL %-58s expected %s, got %s\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

token="$(python3 -m damso.server.credentials generate --credentials-dir "$credentials_dir" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
[[ -n "$token" ]] || { echo "FAIL: no token generated"; exit 1; }

# The credentials directory must hold a token and nothing certificate-shaped.
leftovers="$(ls "$credentials_dir" | grep -vc '^token$' || true)"
check "credentials dir holds only the token" "0" "$leftovers"

DAMSO_SERVER_CREDENTIALS_DIR="$credentials_dir" python3 -m damso.server.main \
  --store "$store" --host 0.0.0.0 --port "$port" >"$scratch/server.log" 2>&1 &
server_pid=$!

for _ in $(seq 1 100); do
  if curl -fsS -m 2 "http://127.0.0.1:$port/v1/health" >/dev/null 2>&1; then break; fi
  sleep 0.2
done

base="http://127.0.0.1:$port"
status() { curl -s -o /dev/null -w '%{http_code}' -m 5 "$@"; }

# Exactly two paths answer without a token: a client checking "is a server
# here, and what does it speak" during pairing has no token yet. `/docs` and
# `/openapi.json` used to be exempt as well and are not anymore - no flow
# needs them and the exemption published the whole route list to anyone who
# could reach the port.
check "http /v1/health without a token" "200" "$(status "$base/v1/health")"
check "http /v1/version without a token" "200" "$(status "$base/v1/version")"
check "http /openapi.json without a token" "401" "$(status "$base/openapi.json")"
check "http /docs without a token" "401" "$(status "$base/docs")"
check "http /openapi.json with the real token" "200" "$(status -H "Authorization: Bearer $token" "$base/openapi.json")"
check "http /v1/changes without a token" "401" "$(status "$base/v1/changes")"
check "http /v1/changes with a wrong token" "401" "$(status -H 'Authorization: Bearer wrong' "$base/v1/changes")"
check "http /v1/changes with the real token" "200" "$(status -H "Authorization: Bearer $token" "$base/v1/changes")"

# R7/AC7: an MCP client needs only the URL and the header. `-k` is deliberate
# on the https probe: even with certificate checking disabled entirely, there
# is no TLS listener to talk to, which is the point.
#
# `initialize` is the first call any MCP client makes - it is what decides
# whether the client attaches at all - so it is probed on its own before
# `tools/list` proves the session then works.
mcp_initialize='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"damso-e2e-probe","version":"0"}}}'
check "http /mcp initialize with the real token" "200" "$(status -X POST \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data "$mcp_initialize" "$base/mcp")"
check "http /mcp initialize without a token" "401" "$(status -X POST \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data "$mcp_initialize" "$base/mcp")"

mcp_body='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
check "http /mcp tools/list with the real token" "200" "$(status -X POST \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data "$mcp_body" "$base/mcp")"
check "http /mcp without a token" "401" "$(status -X POST \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data "$mcp_body" "$base/mcp")"

https_status="$(curl -sk -o /dev/null -w '%{http_code}' -m 5 "https://127.0.0.1:$port/v1/health" || true)"
check "https /v1/health finds no TLS listener" "000" "$https_status"

mcp_tools="$(curl -s -m 5 -X POST \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data "$mcp_body" "$base/mcp" \
  | python3 -c 'import json,sys; print(",".join(sorted(t["name"] for t in json.load(sys.stdin)["result"]["tools"])))')"
check "mcp exposes the four read-only tools" "get_meeting,get_speaker,search_meetings,search_people" "$mcp_tools"

if [[ "$failures" -eq 0 ]]; then
  echo "PASS: plain-HTTP + bearer-token contract holds end to end on port $port"
  exit 0
fi
echo "FAILED: $failures check(s)"
exit 1
