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
# Results: Benchmark/results-<n> (results.jsonl and godot.log per process).
# Summarize with python3 tests/app/bench_report.py Benchmark/results-<n>.
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
# and are slow on the device. SOCKET_BENCH_LABEL_COMPARE=1 runs only the four
# opaque GBA trials, each in a fresh process with its own temporary settings.
# It ignores ONLY and QUALITY, fixes requested MSAA off, and optionally captures
# the final composited frames with SOCKET_BENCH_IMAGES=1. Use 66 instead of 1
# for the 0.66-scale translucent GBA trials (single/off, split/off, 2x, auto).
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
mkdir -p "$OUT" || exit 1
SETTINGS="${XDG_DATA_HOME:-$HERE/../Saves/socket}/godot/app_userdata/Socket/settings.cfg"
fixture="$TMP/settings.cfg"
printf '[General]\nui_sounds_enabled=false\nhas_seen_warning=true\nhas_seen_control_style_prompt=true\ncontrol_layout_revision=1\nconfirm_joy_button=0\n' > "$fixture"
if [ -f "$SETTINGS" ]; then
	awk '/^\[/ { general = ($0 == "[General]") } general && /^(dark_mode|background_pattern|background_gradient|render_scale_3d|max_fps)=/' "$SETTINGS" >> "$fixture"
fi
export SOCKET_BENCH_QUALITY=0 SOCKET_BENCH_IMAGES=0
if [ -f "$HERE/options" ]; then
	while IFS='=' read -r name value || [ -n "$name" ]; do
		value="$(printf '%s' "$value" | tr -d '\r')"
		case "$name" in
			SOCKET_BENCH_ONLY|SOCKET_BENCH_FRAMES|SOCKET_BENCH_ROUNDS|SOCKET_BENCH_QUALITY|SOCKET_BENCH_IMAGES|SOCKET_BENCH_SYNC|SOCKET_BENCH_VSYNC|SOCKET_BENCH_LABEL_COMPARE) ;;
			*) continue ;;
		esac
		case "$value" in
			*[!A-Za-z0-9_.,-]*) continue ;;
		esac
		export "$name=$value"
	done < "$HERE/options"
fi
run_trial() (
	state="$TMP"
	evidence="$OUT"
	unset SOCKET_BENCH_LABEL_TRIAL
	if [ "$#" -gt 0 ]; then
		state="$TMP/$1"
		evidence="$OUT/$1"
		export SOCKET_BENCH_LABEL_TRIAL="$1" SOCKET_BENCH_BODY_SCALE="$2"
		export SOCKET_3D_SPLIT_LABEL="$3" SOCKET_3D_CAP=1 SOCKET_3D_MSAA="${4:-0}" SOCKET_FPS_DIAGNOSTICS=0
	fi
	profile="$state/data/godot/app_userdata/Socket"
	mkdir -p "$evidence" "$profile" "$state/roms" "$state/run" || exit 1
	if [ "$#" -gt 0 ]; then
		awk '!/^render_scale_3d=/' "$fixture" > "$profile/settings.cfg" || exit 1
		printf 'render_scale_3d=%s\nnew_game_reveal_enabled=false\n' "$2" >> "$profile/settings.cfg" || exit 1
	else
		cp "$fixture" "$profile/settings.cfg" || exit 1
	fi
	# A resume record must not start a game in this run.
	unset SOCKET_RESUME_BOOT
	SOCKET_RUN="$state/run" XDG_DATA_HOME="$state/data" SOCKET_TEST_ROOT="$state/roms" SOCKET_EVIDENCE="$evidence" \
		/lib/ld-linux-aarch64.so.1 "$SYS/godot" --main-pack "$SYS/socket.pck" \
		--display-driver fbdev --rendering-method gl_compatibility --render-thread safe \
		--rendering-driver opengl3_es --audio-driver ALSA --script "$HERE/bench_render.gd" > "$evidence/godot.log" 2>&1
)
if [ "${SOCKET_BENCH_LABEL_COMPARE:-0}" = 66 ]; then
	# Match the handheld trace: three carts, refractive plastic, linear upscale, one sun.
	export SOCKET_BENCH_FINISH=translucent SOCKET_3D_FILTER=linear SOCKET_3D_SHADOWS=orthogonal
	run_trial single_066 0.66 0 0 &&
	run_trial split_066_off 0.66 1 0 &&
	run_trial split_066_msaa2 0.66 1 2 &&
	run_trial split_066_auto 0.66 1 auto
elif [ "${SOCKET_BENCH_LABEL_COMPARE:-0}" = 1 ]; then
	run_trial native_single 1.0 0 &&
	run_trial single_075 0.75 0 &&
	run_trial single_060 0.60 0 &&
	run_trial split_060 0.60 1
else
	run_trial
fi
status=$?
sync
exit "$status"
