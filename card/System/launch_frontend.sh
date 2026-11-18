#!/bin/sh
# BaseOS entry point for Socket. BaseOS runs it from the card root.
# Socket remains loaded while play_game.sh runs each emulator.
SD="$(pwd)"
SYS="$SD/System/socket"
LOGS="$SD/Logs"
export SOCKET_RUN=/tmp/socket
export SOCKET_CORES="$SYS/cores"
export SOCKET_SYSTEM="$SYS"
export SOCKET_LOGS="$LOGS"
export SOCKET_RESUME_MANIFEST="$SD/Saves/socket/resume-game"
# Volume, brightness and screen temperature survive power cycles.
export SOCKET_SETTINGS="$SD/Saves/socket/controls.cfg"
# Record frame rates for the RG SP performance check.
export SOCKET_FPS_DIAGNOSTICS=1
# The 3D render-scale setting selects a fraction of the physical panel size.
export SOCKET_3D_CAP="${SOCKET_3D_CAP:-1}"
export SOCKET_3D_FILTER="${SOCKET_3D_FILTER:-linear}"
export SOCKET_3D_SHADOWS="${SOCKET_3D_SHADOWS:-orthogonal}"
# Use 2x when the driver supports tile MSAA.
export SOCKET_3D_MSAA="${SOCKET_3D_MSAA:-auto}"
# Socket's user:// data goes to Saves/socket/godot/app_userdata/Socket.
export XDG_DATA_HOME="$SD/Saves/socket"
if ! mkdir -m 700 "$SOCKET_RUN" 2>/dev/null; then
	[ -d "$SOCKET_RUN" ] && [ ! -L "$SOCKET_RUN" ] || exit 1
	# BusyBox ash can check the directory owner before we reuse it.
	# shellcheck disable=SC3067
	[ -O "$SOCKET_RUN" ] && chmod 700 "$SOCKET_RUN" || exit 1
fi
mkdir -p "$LOGS" "$XDG_DATA_HOME"

# One input owner serves Socket and RetroArch. Fail if another daemon has the pad.
rm -f "$SOCKET_RUN/hardware.ready" "$SOCKET_RUN/app.pid" "$SOCKET_RUN/poweroff.request" \
	"$SOCKET_RUN/game.active" "$SOCKET_RUN/game.descriptor" \
	"$SOCKET_RUN/sleep.request" "$SOCKET_RUN/sleep.ack" "$SOCKET_RUN/wake.request" "$SOCKET_RUN/wake.ack" "$SOCKET_RUN/poweroff.ack" "$SOCKET_RUN/resume.ack"
/lib/ld-linux-aarch64.so.1 "$SYS/socket-hardware" > "$LOGS/socket-hardware.log" 2>&1 &
hardware_pid=$!
app_pid=
wifi_pid=
bluetooth_pid=
stop_device_app() {
	device_pid=$(cat "$SOCKET_RUN/app.pid" 2>/dev/null)
	case "$device_pid" in
		''|*[!0-9]*) ;;
		*) if [ "$device_pid" -gt 1 ] && [ "$device_pid" != "$app_pid" ]; then
			kill -CONT "$device_pid" 2>/dev/null
			kill "$device_pid" 2>/dev/null
		fi ;;
	esac
}
cleanup() {
	if [ -n "$bluetooth_pid" ]; then
		kill "$bluetooth_pid" 2>/dev/null
		wait "$bluetooth_pid" 2>/dev/null
	fi
	if [ "${wifi_started:-0}" = 1 ]; then
		sh "$SYS/wifi.sh" stop
		[ -z "$wifi_pid" ] || wait "$wifi_pid" 2>/dev/null
	fi
	stop_device_app
	if [ -n "$app_pid" ]; then
		kill -CONT "$app_pid" 2>/dev/null
		kill "$app_pid" 2>/dev/null
		wait "$app_pid" 2>/dev/null
	fi
	kill "$hardware_pid" 2>/dev/null
	wait "$hardware_pid" 2>/dev/null
	rm -f "$SOCKET_RUN/app.pid" "$SOCKET_RUN/hardware.ready"
}
trap cleanup EXIT
trap 'exit 0' INT TERM
tries=0
while [ ! -f "$SOCKET_RUN/hardware.ready" ]; do
	kill -0 "$hardware_pid" 2>/dev/null || exit 1
	tries=$((tries + 1))
	[ "$tries" -lt 100 ] || exit 1
	sleep 0.05
done

# The hardware lock now belongs to this session. Network waits run in parallel.
rm -f "$SOCKET_RUN/shallow.sleep" "$SOCKET_RUN/wifi.stop" "$SOCKET_RUN/wifi.ready" "$SOCKET_RUN/wifi.clock-error"
start_wifi() {
	wifi_started=1
	SOCKET_WIFI_PARENT=$$ sh "$SYS/wifi.sh" "$SD/Config/wifi.txt" >/dev/null 2>&1 &
	wifi_pid=$!
}
start_wifi

start_bluetooth() {
	sh "$SYS/bluetooth.sh" run >/dev/null 2>&1 &
	bluetooth_pid=$!
}

# Use the system mixer configuration and the current headset route.
if [ -f "$SYS/bluetooth.sh" ]; then
	: > "$SOCKET_RUN/bluetooth.asound" || exit 1
	if [ -n "${ALSA_CONFIG_PATH:-}" ] || [ -r /usr/share/alsa/alsa.conf ]; then
		export ALSA_CONFIG_PATH="${ALSA_CONFIG_PATH:-/usr/share/alsa/alsa.conf}:$SOCKET_RUN/bluetooth.asound"
	fi
	start_bluetooth
fi

run_app() {
	"$@" &
	app_pid=$!
	printf '%s\n' "$app_pid" > "$SOCKET_RUN/app.pid.new" && mv -f "$SOCKET_RUN/app.pid.new" "$SOCKET_RUN/app.pid"
	while kill -0 "$app_pid" 2>/dev/null; do
		kill -0 "$hardware_pid" 2>/dev/null || exit 1
		if [ -n "$wifi_pid" ] && ! kill -0 "$wifi_pid" 2>/dev/null; then
			wait "$wifi_pid"
			wifi_status=$?
			wifi_pid=
			if [ "$wifi_status" -gt 128 ] && [ ! -e "$SOCKET_RUN/wifi.stop" ]; then start_wifi; fi
		fi
		if [ -n "$bluetooth_pid" ] && ! kill -0 "$bluetooth_pid" 2>/dev/null; then
			wait "$bluetooth_pid"
			bluetooth_status=$?
			bluetooth_pid=
			if [ "$bluetooth_status" -gt 128 ] && [ ! -e "$SOCKET_RUN/bluetooth.stop" ]; then start_bluetooth; fi
		fi
		sleep 0.1
	done
	wait "$app_pid"
	app_status=$?
	# A crashed frontend can leave its emulator child running.
	stop_device_app
	app_pid=
	rm -f "$SOCKET_RUN/app.pid"
	return "$app_status"
}

# A pending resume record starts after the frontend loads. Leaving that game
# then returns to the resident frontend without a cold pack load.
if [ -f "$SOCKET_RESUME_MANIFEST" ]; then
	export SOCKET_RESUME_BOOT=1
elif [ -f "$SD/Benchmark/run" ] && [ -f "$SD/Benchmark/bench_device.sh" ]; then
	sh "$SD/Benchmark/bench_device.sh"
fi
[ -f "$LOGS/socket.log" ] && mv -f "$LOGS/socket.log" "$LOGS/socket.log.1"
run_app /lib/ld-linux-aarch64.so.1 "$SYS/godot" --main-pack "$SYS/socket.pck" \
	--display-driver fbdev --rendering-method gl_compatibility --render-thread safe \
	--rendering-driver opengl3_es --audio-driver ALSA > "$LOGS/socket.log" 2>&1
status=$?
sync
if [ "$status" -eq 0 ] && sh "$SYS/poweroff_ready.sh" frontend; then
	sh "$SYS/poweroff.sh"
fi
exit "$status"
