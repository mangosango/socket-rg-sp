#!/bin/sh
# udhcpc executes this copy from RAM. The frontend card can be mounted noexec.
[ "${interface:-}" = wlan0 ] || exit 1
# Keep this callback in its own session directory if the worker restarts.
cd "$SOCKET_RUN/wifi.worker" || exit 0
current() { [ -n "${SOCKET_WIFI_WORKER:-}" ] && [ "$(cat owner 2>/dev/null)" = "$SOCKET_WIFI_WORKER" ]; }
current || exit 0
case "$1" in
	deconfig|nak|leasefail) rm -f lease "$SOCKET_RUN/wifi.ready" ;;
esac
(umask 022; exec "${SOCKET_DHCP_HOOK:-/usr/share/udhcpc/default.script}" "$@") || exit 1
current || exit 0
case "$1" in
	bound|renew) : > lease ;;
esac
