#!/bin/zsh
set -euo pipefail

# Runs backend/damso/mcp.py on the Mac mini over ssh stdio (R11/T11), for an
# MCP client on this Mac configured to use this script as its server command
# instead of `make mcp` directly. Mirrors CommandLauncher.swift's remote argv
# construction exactly, since the same two pitfalls apply here:
#
# - ssh joins every argument after the host into one string and hands it to
#   the remote shell to re-tokenize, so a store path containing spaces (the
#   real default, `~/Library/Application Support/Damso`) needs each argument
#   individually single-quoted or it silently splits (FACT-ssh-remote-arg-space-splitting).
# - a non-interactive ssh shell's PATH is only `/usr/bin:/bin:/usr/sbin:/sbin`,
#   so the interpreter is always an absolute path regardless (D-B1).
#
# Required environment (set these in the MCP client's server config, not in
# a shell profile - most MCP clients spawn this with a minimal environment):
#   DAMSO_REMOTE_HOST         ssh config alias or hostname for the mini
#   DAMSO_REMOTE_INTERPRETER  absolute python path on the mini
#   DAMSO_REMOTE_STORE        absolute canonical store root path on the mini

: "${DAMSO_REMOTE_HOST:?Set DAMSO_REMOTE_HOST to the mini's ssh host}"
: "${DAMSO_REMOTE_INTERPRETER:?Set DAMSO_REMOTE_INTERPRETER to the mini's absolute python path}"
: "${DAMSO_REMOTE_STORE:?Set DAMSO_REMOTE_STORE to the mini's absolute store root path}"

shell_quote() {
  local arg=$1
  print -r -- "'${arg//\'/\'\\\'\'}'"
}

remote_path_prefix="PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
remote_python=$(shell_quote "$DAMSO_REMOTE_INTERPRETER")
remote_module=$(shell_quote "-m")
remote_target=$(shell_quote "damso.mcp")
remote_flag=$(shell_quote "--store")
remote_store=$(shell_quote "$DAMSO_REMOTE_STORE")

exec ssh -o ConnectTimeout=5 -o BatchMode=yes "$DAMSO_REMOTE_HOST" \
  "$remote_path_prefix" "$remote_python" "$remote_module" "$remote_target" "$remote_flag" "$remote_store"
