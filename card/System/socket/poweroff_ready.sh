#!/bin/sh
# A game shutdown requires the acknowledgment for this request, not an old save.
run="${SOCKET_RUN:-/tmp/socket}"
read_request() {
	IFS= read -r token || return 1
	extra=
	if IFS= read -r extra || [ -n "$extra" ]; then return 1; fi
}
read_request 2>/dev/null < "$run/poweroff.request" || exit 1
if [ "$token" = idle ] && [ "${1:-}" = frontend ]; then
	pid=$(cat "$run/game.active" 2>/dev/null)
	app=$(cat "$run/app.pid" 2>/dev/null)
	case "$pid" in
		''|*[!0-9]*) ;;
		*) if [ "$pid" -gt 1 ] && [ "$pid" = "$app" ] && kill -0 "$pid" 2>/dev/null; then exit 1; fi ;;
	esac
	exit 0
fi
case "$token" in ''|*[!0-9]*) exit 1 ;; esac
[ "${#token}" -le 31 ] || exit 1
read_ack() {
	IFS= read -r ack || return 1
	[ "$ack" = "$token ok" ] || return 1
	extra=
	if IFS= read -r extra || [ -n "$extra" ]; then return 1; fi
}
read_ack 2>/dev/null < "$run/poweroff.ack"
