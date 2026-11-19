#!/bin/sh
# Run the complete pack with a compatible Godot release template.
#   run_packed.sh <socket.pck> [test script, default test_packed.gd]
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
data="$WORK/data"
if [ "${2:-}" = test_first_boot.gd ]; then
	(cd "$WORK" && sh "$HERE/../../card/System/socket/first-boot.sh")
	data="$WORK/Saves/socket"
	touch "$WORK/Games/GB/One.gb" "$WORK/Games/GBC/One.gbc" "$WORK/Games/GBA/One.gba"
fi
mkdir -p "$data/godot/app_userdata/Socket" "$WORK/roms" "$WORK/cores"
printf '[General]\nui_sounds_enabled=false\nhas_seen_warning=true\nhas_seen_control_style_prompt=true\ncontrol_layout_revision=1\nconfirm_joy_button=0\n' > "$data/godot/app_userdata/Socket/settings.cfg"
touch "$WORK/roms/One.gba" "$WORK/roms/Two.gba" "$WORK/cores/mgba_libretro.so"
status=0
XDG_DATA_HOME="$data" SOCKET_RUN="$WORK" SOCKET_TEST_ROOT="$WORK/roms" SOCKET_CORES="$WORK/cores" "${GODOT:-godot}" --headless --main-pack "$1" --script "$HERE/${2:-test_packed.gd}" --quit-after 6000 --log-file "$WORK/godot.log" > "$WORK/output" 2>&1 || status=$?
if grep -q "fixture-private-web-key" "$WORK/output"; then echo "FAIL: Web API key in output" >&2; exit 1; fi
cat "$WORK/output"
test "$status" -eq 0
case "${2:-test_packed.gd}" in
	test_packed.gd) grep -q '^PASS: packed app ' "$WORK/output" ;;
	test_packed_032.gd) grep -q '^PASS: Socket 0.3.2 pack ' "$WORK/output" ;;
	*) grep -q '^PASS: ' "$WORK/output" ;;
esac
# Android exports have no desktop (BPTC) textures. The device loads ASTC.
if grep -v 'Unable to open file: res://.godot/imported/.*[.]bptc[.]ctex' "$WORK/output" | grep -Eq 'SCRIPT ERROR:|FAIL:|ERROR:|Unicode parsing error'; then exit 1; fi

if test -n "${SOCKET_AA_EVIDENCE:-}"; then
	status=0
	XDG_DATA_HOME="$WORK/data" SOCKET_RUN="$WORK" SOCKET_TEST_ROOT="$WORK/roms" SOCKET_CORES="$WORK/cores" "${GODOT:-godot}" --main-pack "$1" --rendering-method gl_compatibility --script "$HERE/test_display_aa_render.gd" --quit-after 240 --log-file "$WORK/aa-godot.log" > "$WORK/aa-output" 2>&1 || status=$?
	cat "$WORK/aa-output"
	test "$status" -eq 0
	grep -q '^PASS: display AA' "$WORK/aa-output"
	if grep -Eq 'SCRIPT ERROR:|FAIL:|ERROR:' "$WORK/aa-output"; then exit 1; fi
fi

case "${2:-test_packed.gd}" in
	test_packed.gd|test_packed_032.gd)
		SOCKET_AA_EVIDENCE= sh "$HERE/run_packed.sh" "$1" test_wifi.gd
		;;
esac
