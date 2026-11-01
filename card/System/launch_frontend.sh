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
# Socket's user:// data goes to Saves/socket/godot/app_userdata/Socket.
export XDG_DATA_HOME="$SD/Saves/socket"
mkdir -p "$SOCKET_RUN" "$LOGS" "$XDG_DATA_HOME"

# One input owner serves Socket and RetroArch. Fail if another daemon has the pad.
rm -f "$SOCKET_RUN/hardware.ready" "$SOCKET_RUN/app.pid" "$SOCKET_RUN/poweroff.request" \
	"$SOCKET_RUN/game.active" "$SOCKET_RUN/game.descriptor" \
	"$SOCKET_RUN/sleep.request" "$SOCKET_RUN/sleep.ack" "$SOCKET_RUN/wake.request" "$SOCKET_RUN/wake.ack" "$SOCKET_RUN/poweroff.ack" "$SOCKET_RUN/resume.ack"
/lib/ld-linux-aarch64.so.1 "$SYS/socket-hardware" > "$LOGS/socket-hardware.log" 2>&1 &
hardware_pid=$!
app_pid=
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

run_app() {
	"$@" &
	app_pid=$!
	printf '%s\n' "$app_pid" > "$SOCKET_RUN/app.pid.new" && mv -f "$SOCKET_RUN/app.pid.new" "$SOCKET_RUN/app.pid"
	while kill -0 "$app_pid" 2>/dev/null; do
		kill -0 "$hardware_pid" 2>/dev/null || exit 1
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
