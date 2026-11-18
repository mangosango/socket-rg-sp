#!/bin/sh
# Run the Device Settings panel with a desktop Godot build. No helper is used.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PLUGIN="$WORK/addons/FrontendPlugin"
mkdir -p "$PLUGIN" "$WORK/run"
cp "$HERE/../../overlay/addons/FrontendPlugin/"*.gd "$PLUGIN/"
cp -R "$HERE/../../overlay/addons/FrontendPlugin/controls" "$PLUGIN/controls"
# Use a small Wi-Fi page with the subpanel contract. Bluetooth is missing.
rm -f "$PLUGIN/bluetooth_settings.gd"
cat > "$PLUGIN/wifi_settings.gd" <<'PAGE'
extends VBoxContainer
signal back_requested
var backs := 0
func _ready() -> void:
	for index in 30:
		var button := Button.new()
		button.name = "Network%d" % index
		button.text = button.name
		add_child(button)
func go_back() -> void:
	backs += 1
	back_requested.emit()
PAGE
cp "$HERE/test_device_settings.gd" "$WORK/"
printf 'config_version=5\n' > "$WORK/project.godot"
status=0
SOCKET_RUN="$WORK/run" "${GODOT:-godot}" --headless --log-file "$WORK/godot.log" --path "$WORK" --script test_device_settings.gd --quit-after 6000 > "$WORK/output" 2>&1 || status=$?
cat "$WORK/output"
test "$status" -eq 0
grep -q '^PASS: Device Settings' "$WORK/output"
if grep -Eq 'ERROR:|FAIL:|Assertion failed' "$WORK/output"; then exit 1; fi
