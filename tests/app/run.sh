#!/bin/sh
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/addons/FrontendPlugin" "$WORK/roms/nested"
cp "$HERE/../../overlay/addons/FrontendPlugin/"*.gd "$WORK/addons/FrontendPlugin/"
cp -R "$HERE/../../overlay/addons/FrontendPlugin/controls" "$WORK/addons/FrontendPlugin/controls"
cp "$HERE/test_bridge.gd" "$WORK/test_bridge.gd"
cp "$HERE/test_controls.gd" "$WORK/test_controls.gd"
cp "$HERE/test_controls_render.gd" "$WORK/test_controls_render.gd"
cp "$HERE/test_settings.gd" "$WORK/test_settings.gd"
cp "$HERE/input_probe.gd" "$WORK/input_probe.gd"
printf 'config_version=5\n' > "$WORK/project.godot"
touch "$WORK/roms/Game One.gba" "$WORK/roms/nested/Game Two.gba"
printf 'nested ROM' > "$WORK/roms/nested/Game Two.gba"
ln -s .. "$WORK/roms/nested/loop"
if test "$#" -gt 0; then
	python3 -I "$HERE/test_pack.py" "$1" "$WORK/scan_prefix.gd"
fi
status=0
SOCKET_RUN="$WORK" SOCKET_TEST_ROOT="$WORK/roms" "${GODOT:-godot}" --headless --log-file "$WORK/godot.log" --path "$WORK" --script test_bridge.gd --quit-after 180 > "$WORK/output" 2>&1 || status=$?
cat "$WORK/output"
test "$status" -eq 0
grep -q '^PASS:' "$WORK/output"

if grep -Eq "SCRIPT ERROR:|Assertion failed|Unicode parsing error" "$WORK/output"; then
	exit 1
fi
if test "$#" -gt 0; then
	grep -q "^PASS: startup audio mute" "$WORK/output"
fi

if test -n "${SOCKET_HUD_SCREENSHOT:-}"; then
	SOCKET_RUN="$WORK" "${GODOT:-godot}" --path "$WORK" --rendering-method gl_compatibility --script test_controls_render.gd --quit-after 120 > "$WORK/render-output" 2>&1
	cat "$WORK/render-output"
	grep -q '^PASS: rendered native HUD' "$WORK/render-output"
	if grep -Eq 'SCRIPT ERROR:|Assertion failed' "$WORK/render-output"; then exit 1; fi
fi
