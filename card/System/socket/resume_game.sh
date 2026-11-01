#!/bin/sh
# Read the saved game descriptor without evaluating it as shell code.
SYS="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
record="${SOCKET_RESUME_MANIFEST:-/mnt/sdcard/Saves/socket/resume-game}"
logs="${SOCKET_LOGS:-/mnt/sdcard/Logs}"
# The frontend starts this script. Keep its messages in the resume log.
if [ -d "$logs" ] && [ -w "$logs" ]; then exec 2>> "$logs/socket-resume.log"; fi
[ -f "$record" ] || exit 0
[ "$(wc -c < "$record")" -le 4096 ] || exit 1
read_record() {
	IFS= read -r version && IFS= read -r core && IFS= read -r rom && IFS= read -r platform || return 1
	[ "$version" = socket-resume-v1 ] || return 1
	case "$core" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
	case "$platform" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
	case "$rom" in /*) ;; *) return 1 ;; esac
	case "$rom" in *"$(printf '\r')"*) return 1 ;; esac
	extra=
	if IFS= read -r extra || [ -n "$extra" ]; then return 1; fi
	[ -f "$rom" ] && [ -f "$SYS/cores/${core}_libretro.so" ]
}
if ! read_record < "$record"; then
	echo 'socket: resume record is invalid or its game/core is missing; opening launcher' >&2
	exit 1
fi
# Attempt this record only once, even if the core crashes during restore.
mv -f "$record" "$record.attempt" || exit 1
sync
export SOCKET_RESUME_LOAD=1
exec sh "$SYS/play_game.sh" "$core" "$rom" "$platform"
