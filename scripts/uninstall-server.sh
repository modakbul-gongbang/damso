#!/bin/zsh
set -euo pipefail

# D-27: removes the daemon, its background service, and its credentials -
# never the canonical store. Store deletion is a separate, explicit action
# the operator takes themselves; this script cannot even name the store root
# on purpose, so there is no path by which it could touch it.

label="com.yansfil.damso.server"
plist_path="$HOME/Library/LaunchAgents/$label.plist"

if [[ -f "$plist_path" ]]; then
  print "Stopping and removing the background service..."
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  rm -f "$plist_path"
else
  print "No background service was registered."
fi

credentials_dir="${DAMSO_SERVER_CREDENTIALS_DIR:-$HOME/Library/Application Support/Damso/.server-credentials}"
if [[ -d "$credentials_dir" ]]; then
  print "Removing server credentials at $credentials_dir..."
  rm -rf "$credentials_dir"
fi

print "Server uninstalled. Your canonical store is untouched - it was never named by this script."
print "If you want to remove it too, delete it yourself; damso never does that automatically."
