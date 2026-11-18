#!/bin/sh
# Own only the supplicant, DHCP client and clock process started here.
umask 077
export SOCKET_RUN="${SOCKET_RUN:-/tmp/socket}"
run=$SOCKET_RUN
work=$run/wifi.worker
ready=$run/wifi.ready
system=${SOCKET_SYSTEM:-/mnt/sdcard/System/socket}
if [ "${1:-}" != --locked ]; then
	[ "$#" -eq 1 ] || exit 1
	if [ "$1" = stop ]; then
		[ -d "$run" ] || exit 0
		: > "$run/wifi.stop"
		rm -f "$ready"
		[ -d "$work" ] || exit 0
	fi
	exec /lib/ld-linux-aarch64.so.1 "$system/socket-wifi-config" --session "$run/wifi.lock" "$0" "$1"
fi
shift

clear_state() {
	rm -f "$ready" "$run/wifi.clock-error" "$work/conf" "$work/lease" "$work/owner" "$work/lease.sh" "$work/ready" "$work/ctrl/wlan0"
	if [ -d "$work/ctrl" ]; then rmdir "$work/ctrl"; fi
	if [ -d "$work" ]; then rmdir "$work"; fi
}
# Only the session lock owner removes files left by a killed worker.
clear_state || exit 1
[ "$1" != stop ] && [ ! -e "$run/wifi.stop" ] || exit 0
mkdir "$work" || exit 1
export SOCKET_WIFI_WORKER="$$"
printf '%s\n' "$$" > "$work/owner" || exit 1

owned() {
	exec /lib/ld-linux-aarch64.so.1 "$system/socket-wifi-config" --child "$$" "$@"
}
supp='' dhcp='' ntp=''
ours() {
	[ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
	# A child can exit before cleanup and the kernel can reuse its PID.
	if [ -d /proc/self ]; then
		[ "$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$1/status" 2>/dev/null)" = "$$" ]
	else
		jobs -p | grep -qx "$1"
	fi
}
stop_clients() {
	for pid in "$@"; do
		ours "$pid" || continue
		kill -TERM "$pid" 2>/dev/null
		kill -CONT "$pid" 2>/dev/null
	done
	for pid in "$@"; do
		[ -n "$pid" ] || continue
		n=0
		while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 5 ]; do sleep .1; n=$((n + 1)); done
		ours "$pid" && kill -KILL "$pid" 2>/dev/null
		wait "$pid" 2>/dev/null
	done
}
cleanup() {
	stop_clients "$ntp" "$dhcp" "$supp"
	clear_state
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM

configured=false
if [ -f "$1" ] && mkdir "$work/ctrl" && \
	/lib/ld-linux-aarch64.so.1 "$system/socket-wifi-config" "$work/conf" "$work/ctrl" < "$1" && \
	cp "$system/wifi-lease.sh" "$work/lease.sh" && chmod 700 "$work/lease.sh"; then
	configured=true
fi

state() {
	# status can contain the network name. Keep only the state.
	timeout -k 1 1 wpa_cli -p "$1" -i wlan0 status 2>/dev/null | sed -n 's/^wpa_state=//p'
}
has_route() {
	timeout -k 1 1 ip -4 addr show dev wlan0 | grep -Eq '^[[:space:]]*inet [^ ]+.* scope global' &&
		[ ! -e "$run/wifi.stop" ] && timeout -k 1 1 ip -4 route show default | grep -Eq '^default .*dev wlan0([[:space:]]|$)'
}
clock_ticks=0
time_supervisor() {
	pid=
	read -r pid 2>/dev/null < "${BASEOS_NTP_PID_FILE:-/run/baseos-ntp.pid}" || return 1
	case "$pid" in ''|0|1|*[!0-9]*) return 1 ;; esac
	kill -0 "$pid" 2>/dev/null || return 1
	if [ -d /proc/self ]; then
		tr '\000' '\n' 2>/dev/null < "/proc/$pid/cmdline" | grep -Eq '(^|/)baseos-ntp$'
	fi
}
check_clock() {
	if [ -s "${BASEOS_NTP_SYNC_FILE:-/run/baseos-ntp-synchronized}" ]; then
		if [ -n "$ntp" ]; then stop_clients "$ntp"; ntp=; fi
		[ ! -e "$run/wifi.clock-error" ] || rm -f "$run/wifi.clock-error"
		clock_ticks=-1
	elif [ "$clock_ticks" -eq 0 ]; then
		if ! time_supervisor && ! pidof ntpd >/dev/null 2>&1; then
			owned ntpd -n -q -p pool.ntp.org >/dev/null 2>&1 &
			ntp=$!
		fi
		clock_ticks=15
	elif [ "$clock_ticks" -gt 0 ]; then
		if [ -n "$ntp" ]; then
			if ! ours "$ntp"; then
				# BusyBox -q exits successfully after it checks or sets the clock.
				if wait "$ntp"; then
					rm -f "$run/wifi.clock-error"
				else
					: > "$run/wifi.clock-error"
				fi
				ntp=
				clock_ticks=-1
				return
			elif time_supervisor; then
				stop_clients "$ntp"
				ntp=
			fi
		fi
		clock_ticks=$((clock_ticks - 1))
		if [ "$clock_ticks" -eq 0 ]; then
			stop_clients "$ntp"
			ntp=
			: > "$run/wifi.clock-error"
			clock_ticks=-1
		fi
	fi
}

asleep=false
observed=false
backoff=2
delay=0
waiting=0
while [ ! -e "$run/wifi.stop" ]; do
	if [ -e "$run/shallow.sleep" ]; then
		if ! "$asleep"; then
			rm -f "$ready"
			for pid in "$supp" "$dhcp" "$ntp"; do ours "$pid" && kill -STOP "$pid" 2>/dev/null; done
			asleep=true
		fi
	elif "$asleep"; then
		for pid in "$supp" "$dhcp" "$ntp"; do ours "$pid" && kill -CONT "$pid" 2>/dev/null; done
		asleep=false
		delay=0
		waiting=0
		continue
	elif [ "$delay" -gt 0 ]; then
		delay=$((delay - 1))
	else
		linked=false
		ctrl=/var/run/wpa_supplicant
		[ -z "$supp" ] || ctrl=$work/ctrl
		if [ -d "${SOCKET_NET_SYS:-/sys/class/net}/wlan0" ]; then
			if [ -n "$dhcp" ] && ! ours "$dhcp"; then
				rm -f "$work/lease"
			fi
			wpa_state=$(state "$ctrl")
			[ ! -e "$run/wifi.stop" ] || break
			[ ! -e "$run/shallow.sleep" ] || continue
			if [ -z "$supp" ] && [ -n "$wpa_state" ]; then observed=true; fi
			if [ "$wpa_state" = COMPLETED ]; then
				if { [ -z "$supp" ] || [ -f "$work/lease" ]; } && has_route; then
					linked=true
				elif [ -n "$supp" ] && [ -z "$dhcp" ]; then
					owned udhcpc -f -n -i wlan0 -t 4 -T 3 -s "$work/lease.sh" >/dev/null 2>&1 &
					dhcp=$!
					waiting=0
				fi
			elif [ -n "$dhcp" ]; then
				stop_clients "$dhcp"
				dhcp=
				rm -f "$work/lease"
				waiting=0
			elif [ -z "$wpa_state" ] && [ -z "$supp" ] && [ ! -S "$ctrl/wlan0" ] && "$configured"; then
				owned wpa_supplicant -i wlan0 -Dnl80211 -c "$work/conf" >/dev/null 2>&1 &
				supp=$!
				waiting=0
			fi
		fi
		if "$linked"; then
			if [ ! -f "$ready" ] && [ ! -e "$run/shallow.sleep" ] && [ ! -e "$run/wifi.stop" ]; then
				: > "$work/ready" && mv -f "$work/ready" "$ready"
			fi
			waiting=0
			backoff=2
			observed=true
			check_clock
			[ "$clock_ticks" -gt 0 ] || delay=3
		else
			rm -f "$ready"
			if [ -n "$ntp" ]; then stop_clients "$ntp"; ntp=; fi
			clock_ticks=0
			"$configured" || "$observed" || exit 0
			waiting=$((waiting + 1))
			if [ "$waiting" -ge 25 ] || { [ -n "$supp" ] && ! ours "$supp"; } ||
				{ [ -n "$dhcp" ] && ! ours "$dhcp"; }; then
				stop_clients "$dhcp" "$supp"
				dhcp='' supp=''
				rm -f "$work/lease"
				waiting=0
				delay=$backoff
				backoff=$((backoff * 2))
				[ "$backoff" -le 60 ] || backoff=60
			fi
		fi
	fi
	[ ! -e "$run/wifi.stop" ] || break
	sleep 1
done
