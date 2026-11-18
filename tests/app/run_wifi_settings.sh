#!/bin/sh
# Run the Wi-Fi settings page with a desktop Godot build. No radio is used.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/addons/FrontendPlugin" "$WORK/run"
cp "$HERE/../../overlay/addons/FrontendPlugin/wifi_settings.gd" "$WORK/addons/FrontendPlugin/"
cp "$HERE/test_wifi_settings.gd" "$WORK/"
printf 'config_version=5\n' > "$WORK/project.godot"
status=0
SOCKET_RUN="$WORK/run" "${GODOT:-godot}" --headless --log-file "$WORK/godot.log" --path "$WORK" --script test_wifi_settings.gd --quit-after 3000 > "$WORK/output" 2>&1 || status=$?
cat "$WORK/output"
test "$status" -eq 0
grep -q '^PASS: Wi-Fi settings page' "$WORK/output"
if grep -Eq 'ERROR:|FAIL:|Assertion failed' "$WORK/output"; then exit 1; fi
