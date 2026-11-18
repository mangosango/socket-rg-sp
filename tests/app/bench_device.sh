#!/bin/sh
# Opt-in render benchmark on the RG SP with the engine and the pack of the card.
# The card build does not include this file. Not tested on the RG SP:
# tests/app/run_bench_render.sh runs this file in Docker with Mesa GLES.
#
# Install, on demand: make a folder `Benchmark` on the card, copy this file
# and bench_render.gd into it, and make an empty file `Benchmark/run`.
# Run: System/launch_frontend.sh calls this file from the card root, after the
# hardware daemon is ready and before it starts Socket. The benchmark runs one
# time (it removes `run`), then Socket starts as usual.
# Results: Benchmark/results-<n>/results.jsonl and godot.log. Summarize on the
# computer with tests/app/bench_report.py.
#
# The run uses the environment of the launcher, the engine options of the card
# and the appearance settings from the card. The fixture library, its ROM
# files and the shader cache go to a new folder in /tmp on the device (memory).
# They are not written to the card, and the saves do not change. The shader
# cache starts empty, so each run compiles the shaders first.
#
# Options: a file `Benchmark/options` with one NAME=value on each line, for
# example SOCKET_BENCH_ONLY=as_started,base,linear. bench_render.gd lists the
# names. This file is read as data, not as shell code. The edge-quality captures
# and the frame images are off by default here: they do not depend on the GPU
# and are slow on the device.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SYS="${SOCKET_SYSTEM:-$HERE/../System/socket}"
rm -f "${HERE:?}/run"
{ [ -f "$HERE/bench_render.gd" ] && [ -f "$SYS/godot" ] && [ -f "$SYS/socket.pck" ]; } || exit 1
n=1
while [ -e "$HERE/results-$n" ]; do n=$((n + 1)); done
OUT="$HERE/results-$n"
TMP="$(mktemp -d /tmp/socket-bench.XXXXXX)" || exit 1
trap 'rm -rf "${TMP:?}"' EXIT
mkdir -p "$OUT" "$TMP/data/godot/app_userdata/Socket" "$TMP/roms" "$TMP/run" || exit 1
SETTINGS="${XDG_DATA_HOME:-$HERE/../Saves/socket}/godot/app_userdata/Socket/settings.cfg"
fixture="$TMP/data/godot/app_userdata/Socket/settings.cfg"
printf '[General]\nui_sounds_enabled=false\nhas_seen_warning=true\nhas_seen_control_style_prompt=true\ncontrol_layout_revision=1\nconfirm_joy_button=0\n' > "$fixture"
if [ -f "$SETTINGS" ]; then
	awk '/^\[/ { general = ($0 == "[General]") } general && /^(dark_mode|background_pattern|background_gradient|render_scale_3d|max_fps)=/' "$SETTINGS" >> "$fixture"
fi
export SOCKET_BENCH_QUALITY=0 SOCKET_BENCH_IMAGES=0
if [ -f "$HERE/options" ]; then
	while IFS='=' read -r name value || [ -n "$name" ]; do
		value="$(printf '%s' "$value" | tr -d '\r')"
		case "$name" in
			SOCKET_BENCH_ONLY|SOCKET_BENCH_FRAMES|SOCKET_BENCH_ROUNDS|SOCKET_BENCH_QUALITY|SOCKET_BENCH_IMAGES|SOCKET_BENCH_SYNC|SOCKET_BENCH_VSYNC) ;;
			*) continue ;;
		esac
		case "$value" in
			*[!A-Za-z0-9_.,-]*) continue ;;
		esac
		export "$name=$value"
	done < "$HERE/options"
fi
# A resume record must not start a game in this run.
unset SOCKET_RESUME_BOOT
SOCKET_RUN="$TMP/run" XDG_DATA_HOME="$TMP/data" SOCKET_TEST_ROOT="$TMP/roms" SOCKET_EVIDENCE="$OUT" \
	/lib/ld-linux-aarch64.so.1 "$SYS/godot" --main-pack "$SYS/socket.pck" \
	--display-driver fbdev --rendering-method gl_compatibility --render-thread safe \
	--rendering-driver opengl3_es --audio-driver ALSA --script "$HERE/bench_render.gd" > "$OUT/godot.log" 2>&1
status=$?
sync
exit "$status"
