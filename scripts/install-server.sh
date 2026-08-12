#!/bin/zsh
set -euo pipefail

# D-11: the server install unit. Prepares the Python package (processing +
# HTTP daemon), generates an access token if none exists yet,
# and - only when DAMSO_SERVER_RESIDENT=1 (a genuinely remote deployment,
# not a local-mode combined machine) - registers a launchd job so the daemon
# survives logout/reboot. Needs no Xcode and no git checkout beyond this
# repository; the operator runs this directly on the machine that will own
# the canonical store.

repo_root="${0:A:h:h}"
cd "$repo_root"

: "${DAMSO_STORE:?Set DAMSO_STORE to the canonical store root, e.g. \"$HOME/Library/Application Support/Damso\"}"
python3_path="${PYTHON:-$(command -v python3)}"

print "Installing the processing + server package..."
"$python3_path" -m pip install -e '.[local-processing,server]'

print "Checking local models..."
if ! "$python3_path" -m damso.model_setup --status | grep -q '"ok": *true'; then
  print "Installing local models (this can take a while)..."
  "$python3_path" -m damso.model_setup --install
fi

print "Checking server credentials..."
credentials_dir="${DAMSO_SERVER_CREDENTIALS_DIR:-$HOME/Library/Application Support/Damso/.server-credentials}"
if [[ ! -f "$credentials_dir/token" ]]; then
  print "Generating access token..."
  "$python3_path" -m damso.server.credentials generate --credentials-dir "$credentials_dir"
  print "Save the printed token now - the client's pairing screen needs it, and it will not be printed again."
else
  print "Credentials already exist at $credentials_dir. Run 'make regenerate-server-credentials' to replace them."
fi

if [[ "${DAMSO_SERVER_RESIDENT:-0}" == "1" ]]; then
  label="com.yansfil.damso.server"
  plist_path="$HOME/Library/LaunchAgents/$label.plist"
  log_dir="$HOME/Library/Logs/Damso"
  mkdir -p "$HOME/Library/LaunchAgents" "$log_dir"
  host="${DAMSO_SERVER_HOST:-0.0.0.0}"
  port="${DAMSO_SERVER_PORT:-8787}"
  # launchd starts the service with the bare system PATH
  # (/usr/bin:/bin:/usr/sbin:/sbin), which is where neither Homebrew tools
  # nor the claude/codex CLIs live - and `agent_boundary` discovers those
  # CLIs via `shutil.which`, so without this every summary job fails with
  # agent_cli_missing under the service even though the same command works
  # in an interactive shell on that machine (found via a real two-machine
  # run). Capture the installing user's login-shell
  # PATH, then force-prepend ~/.local/bin: the claude CLI installs there,
  # and on a real server Mac that entry came only from the *interactive* rc
  # file, so the login-shell PATH alone still missed it.
  service_path="$(command -p env - HOME="$HOME" USER="$USER" "$SHELL" -lc 'printf %s "$PATH"' 2>/dev/null || true)"
  [[ -n "$service_path" ]] || service_path="$PATH"
  [[ ":$service_path:" == *":$HOME/.local/bin:"* ]] || service_path="$HOME/.local/bin:$service_path"
  cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$python3_path</string>
        <string>-m</string>
        <string>damso.server.main</string>
        <string>--store</string>
        <string>$DAMSO_STORE</string>
        <string>--host</string>
        <string>$host</string>
        <string>--port</string>
        <string>$port</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>DAMSO_SERVER_CREDENTIALS_DIR</key>
        <string>$credentials_dir</string>
        <key>PATH</key>
        <string>$service_path</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>$log_dir/server.log</string>
    <key>StandardErrorPath</key>
    <string>$log_dir/server.error.log</string>
</dict>
</plist>
PLIST
  plutil -lint "$plist_path" >/dev/null
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist_path"
  launchctl kickstart "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  print "Background service registered and started ($label)."
else
  print "DAMSO_SERVER_RESIDENT=1 not set: skipping the background service."
  print "Local mode does not need one - the app spawns its own loopback daemon."
fi

print "Server install complete."
