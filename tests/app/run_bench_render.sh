#!/bin/sh
# Run the render benchmark in Docker with Mesa GLES in place of the panel.
# Usage: sh tests/app/run_bench_render.sh <pack.pck> <new-directory> [NAME=value ...]
# Each NAME=value is one line of the options file, for example
# SOCKET_BENCH_ONLY=base,linear SOCKET_BENCH_QUALITY=1 SOCKET_BENCH_IMAGES=1,
# or SOCKET_BENCH_LABEL_COMPARE=66 for the 0.66-scale translucent GBA comparison.
# A NAME that starts with SOCKET_3D_ or SOCKET_UI_ goes to the launcher
# environment, as card/System/launch_frontend.sh sets it.
#
# This builds a card-like folder and runs tests/app/bench_device.sh, the launcher
# of the device, with the settings of the RG SP card (dark theme, moving dots).
# It fails if the engine does not exit with status 0, or if the card-like folder
# gets a file that is not a result. Mesa does not measure Mali speed.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PACK="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mkdir "$2"
OUT="$(cd "$2" && pwd)"
shift 2
ENVS=""
: > "$OUT/options"
for pair in "$@"; do
	case "$pair" in
		SOCKET_3D_*|SOCKET_UI_*) ENVS="$ENVS -e $pair" ;;
		*) printf '%s\n' "$pair" >> "$OUT/options" ;;
	esac
done
# shellcheck disable=SC2086
docker run --rm --network none --platform linux/arm64 $ENVS -v "$ROOT:/repo:ro" -v "$PACK:/app.pck:ro" -v "$OUT:/output" socket-baseos-godot sh -c '
set -eu
helper=test_resident_egl
# Exercise the same auto-AA decision as Mali. Refractive MSAA uses a real explicit resolve.
if grep -qx SOCKET_BENCH_LABEL_COMPARE=66 /output/options; then helper=test_msaa_fbo_egl; fi
cc -shared -fPIC /repo/tests/app/$helper.c -o /tmp/resident.so -ldl -lEGL -lGLESv2 -lasound
printf "pcm.!default { type null }\n" > /tmp/alsa.conf
SAVES=/card/Saves/socket/godot/app_userdata/Socket
mkdir -p /card/System/socket /card/Benchmark "$SAVES" /tmp/run
ln -s /repo/work/godot/bin/godot.linuxbsd.template_release.arm64 /card/System/socket/godot
ln -s /app.pck /card/System/socket/socket.pck
cp /repo/tests/app/bench_device.sh /repo/tests/app/bench_render.gd /output/options /card/Benchmark/
printf "[General]\nui_sounds_enabled=false\nhas_seen_warning=true\nhas_seen_control_style_prompt=true\ncontrol_layout_revision=1\nconfirm_joy_button=0\ndark_mode=true\nbackground_pattern=\"dots\"\nbackground_gradient=\"palette\"\nrender_scale_3d=0.75\nmax_fps=60\n" > "$SAVES/settings.cfg"
cp "$SAVES/settings.cfg" /tmp/saved-settings.cfg
touch /card/Benchmark/run
find /card /tmp -name "socket-bench.*" -o -type f -path "/card/*" | sort > /tmp/before
cd /card
status=0
EGL_PLATFORM=surfaceless LD_PRELOAD=/tmp/resident.so ALSA_CONFIG_PATH=/tmp/alsa.conf SOCKET_RUN=/tmp/run \
	SOCKET_SYSTEM=/card/System/socket XDG_DATA_HOME=/card/Saves/socket SOCKET_RESUME_BOOT=1 \
	sh /card/Benchmark/bench_device.sh || status=$?
cp -R /card/Benchmark/results-1/. /output/
for log in /output/godot.log /output/*/godot.log; do
	[ -f "$log" ] || continue
	grep -av "bptc" "$log" | grep -a "FAIL:\|SCRIPT ERROR\|SHADER ERROR\|^ERROR\|Segmentation\|^PASS" || true
done
test "$status" -eq 0 || { echo "FAIL: engine exit status $status"; exit 1; }
if [ -f /output/godot.log ]; then
	set -- /output/godot.log
else
	set -- /output/*/godot.log
fi
for log do
	grep -aq "^PASS: benchmark" "$log"
	if grep -aq "FAIL:\|SCRIPT ERROR\|SHADER ERROR\|^ERROR" "$log"; then exit 1; fi
done
# The card gets the results folder only. The run marker and the temporary folder are gone.
cmp -s /tmp/saved-settings.cfg "$SAVES/settings.cfg" || { echo "FAIL: saved settings changed"; exit 1; }
find /card /tmp -name "socket-bench.*" -o -type f -path "/card/*" | sort | diff /tmp/before - | grep "^[<>]" | grep -v "^< /card/Benchmark/run$" | grep -v "^> /card/Benchmark/results-1/" && { echo "FAIL: unexpected files"; exit 1; }
echo "PASS: launcher and benchmark exit clean"
'
python3 "$ROOT/tests/app/bench_report.py" "$OUT"
