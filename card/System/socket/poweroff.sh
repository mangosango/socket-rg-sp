#!/bin/sh
# Power off as Slot does: sync, unload the WiFi driver, sync, then poweroff.
# Slot unloads 8821cs first because the driver can stop poweroff on BaseOS.
# The unload wait is 5 seconds at most.
RMMOD="${SOCKET_RMMOD:-rmmod}"
POWEROFF="${SOCKET_POWEROFF:-poweroff}"
sync
$RMMOD 8821cs 2>/dev/null &
waited=0
while kill -0 $! 2>/dev/null && [ "$waited" -lt 5 ]; do
	sleep 1
	waited=$((waited + 1))
done
sync
exec $POWEROFF
