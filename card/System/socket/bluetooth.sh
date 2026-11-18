#!/bin/sh
# Bluetooth session worker. Usage: bluetooth.sh run | stop
# BaseOS owns the UART attach, D-Bus and bluetoothd. This worker owns only the
# socket-bluetooth-agent and bluealsa processes that it starts.
#
# Files in SOCKET_RUN:
#   bluetooth.request.N  in: one command from the settings panel, lowest N first
#   bluetooth.status     out: off | starting | on | unavailable
#   bluetooth.error      out: the cause of "unavailable", one line for the panel
#   bluetooth.state      out: BlueZ object dump from dbus-send, while the panel is open
#   bluetooth.log        out: socket-bluetooth-agent events, while the panel is open.
#                        Line 1 identifies the agent instance.
#   bluetooth.audio      out: address of the connected headset. Absent without one.
#   bluetooth.asound     out: ALSA route to that headset. Empty without one.
#
# SOCKET_LOGS/socket-bluetooth.log keeps the details of the last failed start.
umask 077
run=${SOCKET_RUN:-/tmp/socket}
system=${SOCKET_SYSTEM:-/mnt/sdcard/System/socket}
settings=${SOCKET_SETTINGS:-/mnt/sdcard/Saves/socket/controls.cfg}
# The radio preference has its own file. It survives power cycles.
pref=${SOCKET_BLUETOOTH_SETTINGS:-${settings%/*}/bluetooth.cfg}
attach=${SOCKET_BLUETOOTH_ATTACH:-/mnt/vendor/ctrl/setBluetooth.sh}
# rtk_hciattach is gone when this lock of setBluetooth.sh is stale.
lock=${SOCKET_BLUETOOTH_ATTACH_LOCK:-/tmp/.init_bt}
log=${SOCKET_LOGS:-/mnt/sdcard/Logs}/socket-bluetooth.log
[ -d "${log%/*}" ] || log=/dev/null
scan_limit=${SOCKET_BLUETOOTH_SCAN_TICKS:-120}
# Seconds to wait for the adapter. The UART firmware download is slow.
adapter_limit=${SOCKET_BLUETOOTH_ADAPTER_TICKS:-20}
work=$run/bluetooth.worker

if [ "${1:-}" = stop ]; then
	[ -d "$work" ] || exit 0
	: > "$run/bluetooth.stop"
	n=0
	while [ -d "$work" ] && [ "$n" -lt 50 ]; do sleep .1; n=$((n + 1)); done
	exit 0
fi
[ "${1:-}" = run ] || exit 1

parent=$PPID
state='' open='' ctl='' alsa='' route='' scan=0 session=0 tick=0

stopping() {
	[ -e "$run/bluetooth.stop" ] || ! kill -0 "$parent" 2>/dev/null
}
publish() {
	printf '%s\n' "$2" > "$work/new" && mv -f "$work/new" "$run/bluetooth.$1"
}
status() {
	[ "$1" = unavailable ] || rm -f "$run/bluetooth.error"
	[ "$1" = "$state" ] || { state=$1; publish status "$1"; }
}
note() {
	printf '%s\n' "$*" 2>/dev/null >> "$log"
}
# Show the cause in the panel and keep the system state for a report.
fail() {
	publish error "$1"
	note "error: $1"
	note "processes:$(for name in dbus-daemon bluetoothd rtk_hciattach; do
		if pidof "$name" >/dev/null 2>&1; then printf ' %s=up' "$name"; else printf ' %s=down' "$name"; fi; done)"
	for node in /sys/class/rfkill/rfkill*; do
		[ -r "$node/soft" ] || continue
		note "rfkill: $(cat "$node/type" "$node/name" "$node/soft" "$node/hard" 2>/dev/null | tr '\n' ' ')"
	done
	# The address is not necessary for a diagnosis. Do not put it on the card.
	note "$(timeout -k 1 3 hciconfig -a 2>&1 | sed -n '1,4{s/\([0-9A-F][0-9A-F]:\)\{5\}[0-9A-F][0-9A-F]/<address>/;p;}')"
	status unavailable
	return 1
}
send() {
	[ -z "$ctl" ] || printf '%s\n' "$1" >&3
}
stop_ctl() {
	[ -n "$ctl" ] || return 0
	# The exit of the agent makes BlueZ stop its discovery and cancel its
	# pending pairing and prompt.
	kill -KILL "$ctl" 2>/dev/null
	wait "$ctl" 2>/dev/null
	exec 3>&-
	ctl='' scan=0
}
start_ctl() {
	rm -f "$work/in"
	mkfifo "$work/in" || return 1
	session=$((session + 1))
	# shortcut: the log grows while the panel is open. Rotate it if panels stay open for hours.
	publish log "# $$ $session"
	/lib/ld-linux-aarch64.so.1 "$system/socket-bluetooth-agent" < "$work/in" >> "$run/bluetooth.log" 2> "$work/agent.err" &
	ctl=$!
	exec 3> "$work/in"
}
snapshot() {
	timeout -k 1 3 dbus-send --system --print-reply --dest=org.bluez / \
		org.freedesktop.DBus.ObjectManager.GetManagedObjects > "$work/new" 2>/dev/null || : > "$work/new"
	mv -f "$work/new" "$run/bluetooth.state"
}
powered() {
	grep -A1 '^ *string "Powered"$' "$run/bluetooth.state" 2>/dev/null | grep -q 'boolean true$'
}
adapter() {
	sed -n 's|^ *object path "\(/org/bluez/hci[0-9]*\)"$|\1|p' "$run/bluetooth.state" 2>/dev/null | head -n 1
}
# Set the radio power: true or false. Print the D-Bus error of a failure.
# dbus-send gives the reply of BlueZ. bluetoothctl needs a terminal on old
# BlueZ versions and hides the error.
# shellcheck disable=SC2069
power() {
	timeout -k 1 10 dbus-send --system --print-reply --dest=org.bluez "$(adapter)" \
		org.freedesktop.DBus.Properties.Set string:org.bluez.Adapter1 string:Powered "variant:boolean:$1" 2>&1 >/dev/null
}
set_route() {
	[ "$1" != "$route" ] || return 0
	route=$1
	if [ -n "$1" ]; then
		# Godot lists only names that start with "plughw". New ALSA clients,
		# such as RetroArch, use the default device.
		publish asound "pcm.plughw_socket_bluetooth {
	type plug
	slave.pcm { type bluealsa device \"$1\" profile \"a2dp\" }
	hint { show on description \"Bluetooth headset\" }
}
pcm.!default \"plughw_socket_bluetooth\"" && publish audio "$1"
	else
		rm -f "$run/bluetooth.audio"
		publish asound ''
	fi
}
find_route() {
	command -v bluealsa-aplay >/dev/null 2>&1 || return 0
	set_route "$(timeout -k 1 3 bluealsa-aplay -L 2>/dev/null |
		sed -n 's/^bluealsa:.*DEV=\([0-9A-F:]\{17\}\).*PROFILE=a2dp.*/\1/p' | head -n 1)"
}
bring_up() {
	status starting
	printf '' 2>/dev/null > "$log"
	[ "${BASEOS_BLUETOOTH:-1}" != 0 ] || { fail 'This device has no Bluetooth radio.'; return 1; }
	[ -f "$attach" ] || { fail 'This BaseOS version has no Bluetooth support. Update BaseOS.'; return 1; }
	[ -f "$system/socket-bluetooth-agent" ] ||
		{ fail 'A Socket file is missing from the card. Install Socket again.'; return 1; }
	for tool in dbus-send systemctl; do
		command -v "$tool" >/dev/null 2>&1 || { fail "BaseOS has no $tool. Update BaseOS."; return 1; }
	done
	# Each step has a time limit, and a stop request ends the sequence
	# between steps. A shutdown during power-up thus waits for one step only.
	# setBluetooth.sh does not attach again while its lock is there.
	pidof rtk_hciattach >/dev/null 2>&1 || rm -f "$lock"
	# A soft block can stop the attach of the combo chip. Unblock only the
	# Bluetooth type: the Wi-Fi state stays as it is.
	rfkill unblock bluetooth >/dev/null 2>&1
	timeout -k 1 10 sh "$attach" init >/dev/null 2>&1
	stopping || timeout -k 1 15 systemctl start bluetooth >/dev/null 2>&1
	n=0
	while :; do
		! stopping || { status unavailable; return 1; }
		snapshot
		[ -z "$(adapter)" ] || break
		[ "$n" -lt "$adapter_limit" ] ||
			{ fail 'The Bluetooth radio did not start. Restart the device, then try again.'; return 1; }
		n=$((n + 1))
		sleep 1
	done
	why=$(power true)
	snapshot
	if ! powered && ! stopping; then
		# The stock firmware starts the radio with hciconfig. Do the same,
		# then wait: BlueZ reports the change after a short time.
		note "power on: ${why:-no reply}"
		rfkill unblock bluetooth >/dev/null 2>&1
		name=$(adapter)
		timeout -k 1 10 hciconfig "${name##*/}" up >/dev/null 2>&1
		n=0
		while ! powered && ! stopping && [ "$n" -lt 5 ]; do
			sleep 1
			again=$(power true)
			why=${again:-$why}
			snapshot
			n=$((n + 1))
		done
	fi
	! stopping || { status unavailable; return 1; }
	if ! powered; then
		why=$(printf '%s' "$why" | sed -n 's/^Error \([A-Za-z0-9.]*\).*/\1/p' | head -n 1)
		fail "The Bluetooth radio did not turn on (${why:-no reply from BlueZ}). Restart the device, then try again."
		return 1
	fi
	# The BaseOS systemctl shim does not start the audio service. BlueALSA 4.2
	# and later name the daemon bluealsad.
	for daemon in bluealsad bluealsa; do
		command -v "$daemon" >/dev/null 2>&1 || continue
		if ! pidof "$daemon" >/dev/null 2>&1; then
			"$daemon" -p a2dp-source >/dev/null 2>&1 &
			alsa=$!
		fi
		break
	done
	status on
}
bring_down() {
	stop_ctl
	set_route ''
	if [ -n "$alsa" ]; then kill "$alsa" 2>/dev/null; wait "$alsa" 2>/dev/null; alsa=''; fi
	if [ "$state" = on ]; then power false >/dev/null; fi
	rm -f "$run/bluetooth.state"
	status off
}
set_pref() {
	[ "$(cat "$pref" 2>/dev/null)" = "$1" ] && return 0
	printf '%s\n' "$1" > "$pref.new" && mv -f "$pref.new" "$pref"
}

hex='[0-9A-F][0-9A-F]'
mac="$hex:$hex:$hex:$hex:$hex:$hex"
handle() {
	# The patterns are the trust boundary. The agent gets no other text.
	# shellcheck disable=SC2254
	case "$1" in
		# Save the preference only when the radio is on. A failed start
		# keeps the saved value: a failure at boot can be temporary.
		on) if [ "$state" = on ] || bring_up; then set_pref 1; fi ;;
		off) set_pref 0; bring_down ;;
		open) open=1 ;;
		close) open=''; stop_ctl ;;
		# Cancel everything in progress. The loop starts a new agent.
		reset) stop_ctl ;;
		'scan on') send "$1"; scan=$scan_limit ;;
		'scan off') send "$1"; scan=0 ;;
		pair\ $mac|trust\ $mac|connect\ $mac|disconnect\ $mac|remove\ $mac) send "$1" ;;
		answer\ ?*)
			value=${1#answer }
			case "$value" in *[!0-9a-z]*|?????????????????*) ;; *) send "$1" ;; esac ;;
	esac
}

cleanup() {
	stop_ctl
	set_route ''
	if [ -n "$alsa" ]; then kill "$alsa" 2>/dev/null; fi
	rm -f "$run/bluetooth.status" "$run/bluetooth.error" "$run/bluetooth.state" "$run/bluetooth.log" "$run/bluetooth.audio" \
		"$run"/bluetooth.request.* "$run/bluetooth.stop"
	rm -rf "$work"
}
# One worker for each session. Replace the lock of a worker that was killed.
# shortcut: a reused PID keeps a stale lock until the next boot clears /tmp.
if ! mkdir "$work" 2>/dev/null; then
	old=$(cat "$work/pid" 2>/dev/null)
	case "$old" in ''|*[!0-9]*) ;; *) ! kill -0 "$old" 2>/dev/null || exit 0 ;; esac
	rm -rf "$work"
	mkdir "$work" || exit 1
fi
printf '%s\n' "$$" > "$work/pid"
rm -f "$run"/bluetooth.request.* "$run/bluetooth.stop" "$run/bluetooth.error" "$run/bluetooth.state" "$run/bluetooth.log" "$run/bluetooth.audio"
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
# A write to an agent that died must not kill the worker.
trap '' PIPE

publish asound ''
if [ "$(cat "$pref" 2>/dev/null)" = 1 ]; then bring_up; else status off; fi

while ! stopping; do
	for file in "$run"/bluetooth.request.*; do
		[ -f "$file" ] || continue
		line=''
		IFS= read -r line < "$file"
		rm -f "$file"
		handle "$line"
	done
	if [ -e "$run/shallow.sleep" ]; then
		stop_ctl
	elif [ "$state" = on ]; then
		if [ -n "$open" ]; then
			if [ -z "$ctl" ]; then
				start_ctl
			elif ! kill -0 "$ctl" 2>/dev/null; then
				stop_ctl
				# An agent that stops before it is ready cannot register with
				# BlueZ. Do not start it in a loop. The panel offers a retry,
				# which sends "on".
				if ! grep -q '^ready$' "$run/bluetooth.log" 2>/dev/null; then
					printf '' 2>/dev/null > "$log"
					note "agent: $(head -n 3 "$work/agent.err" 2>/dev/null | tr '\n' ' ')"
					fail 'The pairing service did not start. Restart the device, then try again.'
				fi
			fi
			# Discovery has a limit, also when the panel stops responding.
			if [ "$scan" -gt 0 ]; then
				scan=$((scan - 1))
				[ "$scan" -gt 0 ] || send 'scan off'
			fi
			[ $((tick % 2)) -ne 0 ] || snapshot
		fi
		[ $((tick % 8)) -ne 0 ] || find_route
	fi
	tick=$((tick + 1))
	# shortcut: polling. A closed panel costs one wakeup each second.
	if [ -n "$open" ]; then sleep .25; else sleep 1; fi
done
