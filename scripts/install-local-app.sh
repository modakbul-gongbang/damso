#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"

swift build --product Damso
binary="$(swift build --show-bin-path)/Damso"
[[ -x "$binary" ]] || { print -u2 "Damso build product was not found."; exit 1; }

destination="$HOME/Applications/Damso.app"
stage="$(mktemp -d "${TMPDIR:-/tmp}/damso-app.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Damso.app"
contents="$app/Contents"
macos="$contents/MacOS"
mkdir -p "$macos"
cp "$binary" "$macos/Damso"

resources="$contents/Resources"
mkdir -p "$resources"
module_bundle="$(swift build --show-bin-path)/Damso_Damso.bundle"
if [[ -d "$module_bundle" ]]; then
  cp -R "$module_bundle" "$resources/"
fi

# Generate the token-drawn app icon from the binary itself so the bundle icon
# always matches the in-app Dock/menu-bar identity.
icon_png="$stage/damso-icon.png"
if "$binary" --export-icon "$icon_png" && [[ -f "$icon_png" ]]; then
  iconset="$stage/AppIcon.iconset"
  mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$icon_png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$resources/AppIcon.icns"
fi

plist="$contents/Info.plist"
plutil -create xml1 "$plist"
plutil -insert CFBundleDevelopmentRegion -string en "$plist"
plutil -insert CFBundleDisplayName -string "Damso" "$plist"
plutil -insert CFBundleExecutable -string Damso "$plist"
plutil -insert CFBundleIdentifier -string com.yansfil.damso "$plist"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
plutil -insert CFBundleName -string "Damso" "$plist"
plutil -insert CFBundlePackageType -string APPL "$plist"
plutil -insert CFBundleShortVersionString -string 0.1.0 "$plist"
plutil -insert CFBundleVersion -string 1 "$plist"
plutil -insert LSMinimumSystemVersion -string 15.0 "$plist"
if [[ -f "$resources/AppIcon.icns" ]]; then
  plutil -insert CFBundleIconFile -string AppIcon "$plist"
fi
plutil -insert NSMicrophoneUsageDescription -string "Damso records approved meeting microphone audio locally on this Mac." "$plist"
plutil -insert NSScreenCaptureUsageDescription -string "Damso captures approved system audio locally while recording a meeting." "$plist"
plutil -insert NSCalendarsFullAccessUsageDescription -string "Damso adds dated meeting action items to the calendar you choose, only when you confirm them." "$plist"
# Without this key macOS silently denies Apple Events (no prompt), which
# breaks the AppleScript tab checks used for Chrome/Safari meeting detection.
plutil -insert NSAppleEventsUsageDescription -string "Damso checks browser tabs for an active meeting only while that browser is using the microphone." "$plist"
plutil -lint "$plist" >/dev/null

mkdir -p "$HOME/Applications"
if [[ -e "$destination" ]]; then
  rm -rf "$destination"
fi
mv "$app" "$destination"

# Keep the local development app's designated requirement stable across
# rebuilds so macOS TCC permissions remain attached to this bundle identity.
codesign --force --sign - \
  --identifier com.yansfil.damso \
  --requirements '=designated => identifier "com.yansfil.damso"' \
  "$destination"
codesign --verify --deep --strict "$destination"
designated_requirement="$(codesign -dr - "$destination" 2>&1)"
if [[ "$designated_requirement" != *'designated => identifier "com.yansfil.damso"'* ]]; then
  print -u2 "Damso local code-signing identity is not stable."
  exit 1
fi

lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$lsregister" ]]; then
  "$lsregister" -f "$destination"
fi
mdimport "$destination" >/dev/null 2>&1 || true
open "$destination"
print "Installed and launched: $destination"
