#!/bin/sh
# Keep the loaded frontend resident while the emulator owns the devices.
SYS="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
run="${SOCKET_RUN:-/tmp/socket}"
logs="${SOCKET_LOGS:-/mnt/sdcard/Logs}"
mkdir -p "$run" "$logs" || exit 1
rm -f "$run/poweroff.request" "$run/poweroff.ack"
exec > "$logs/socket-game.log" 2>&1
start=$(date +%s)
# Uptime stamps show where time goes when the game returns to the launcher.
stamp() {
	up=
	read -r up _ 2>/dev/null < /proc/uptime
	echo "socket: uptime=${up:-unknown} $*"
}
stamp "game start"
sh "$SYS/launch_game.sh" "$@" &
game_pid=$!
stop_game() {
	kill -CONT "$game_pid" 2>/dev/null
	kill "$game_pid" 2>/dev/null
	wait "$game_pid" 2>/dev/null
}
trap 'stop_game; exit 1' INT TERM
cleanup() {
	stamp "cleanup start"
	rm -f "$run/game.active" "$run/game.descriptor" "$run/sleep.request" "$run/sleep.ack" "$run/wake.request" "$run/wake.ack" "$run/resume.ack"
	if ! sh "$SYS/poweroff_ready.sh" game; then
		manifest="${SOCKET_RESUME_MANIFEST:-/mnt/sdcard/Saves/socket/resume-game}"
		if [ -e "$manifest" ]; then
			rm -f "$manifest" && sync
			stamp "resume record removed and synced"
		fi
	fi
	stamp "cleanup done"
}
trap cleanup EXIT
printf '%s\n' "$game_pid" > "$run/app.pid.new" && mv -f "$run/app.pid.new" "$run/app.pid"
wait "$game_pid"
status=$?
case "${SOCKET_FRONTEND_PID:-}" in
	''|*[!0-9]*) rm -f "$run/app.pid" ;;
	*) printf '%s\n' "$SOCKET_FRONTEND_PID" > "$run/app.pid.new" && mv -f "$run/app.pid.new" "$run/app.pid" ;;
esac
printf '%s\n' "$(($(date +%s) - start))" > "$run/session_seconds"
stamp "game exited with status $status"
# Flush in parallel with the first frontend frame. Shutdown also waits for sync.
sync > /dev/null 2>&1 &
exit "$status"
