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
	rm -f "$ready" "$run/wifi.clock-error" "$work/conf" "$work/lease" "$work/owner" "$work/lease.sh" "$work/ready" "$work/ctrl/wlan0" \
		"$run/wifi.status" "$run/wifi.scan" "$run/wifi.request" "$run/wifi.request.new" "$run/wifi.candidate" "$run/wifi.candidate.new" \
		"$work/status" "$work/scan" "$work/request" "$work/candidate" "$work/conf.new"
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

config=$1
# The Off preference survives power cycles. It is not a shutdown marker.
pref=${SOCKET_WIFI_PREF:-${XDG_DATA_HOME:-${config%/*}}/wifi.off}
# Loop ticks before a scan or a join attempt fails. Tune these on the device.
scan_wait=12
join_wait=30
tab=$(printf '\t')
cr=$(printf '\r')
mkdir "$work/ctrl" && cp "$system/wifi-lease.sh" "$work/lease.sh" && chmod 700 "$work/lease.sh" || exit 1

# Without a valid saved network, the supplicant gets a scan-only configuration.
load_profile() {
	rm -f "$work/conf"
	configured=false
	saved=
	if [ -f "$config" ] && /lib/ld-linux-aarch64.so.1 "$system/socket-wifi-config" "$work/conf" "$work/ctrl" < "$config"; then
		configured=true
		saved=$(sed -n 's/^[[:blank:]]*ssid[[:blank:]]*=[[:blank:]]*//p' "$config" | sed -n 's/[[:space:]]*$//; $p')
	else
		printf 'ctrl_interface=%s\n' "$work/ctrl" > "$work/conf"
	fi
}
load_profile
off=false
[ ! -e "$pref" ] || off=true

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
# The settings panel sends "<number> <action>" in wifi.request. wifi.status
# gives the result for the newest request number. An older request has no result.
req_id=0 req_result=ok published=
need=false joining=false join_ticks=0 join_seen=notfound scan='' scan_at=''
publish() {
	if "$off"; then link=off
	elif [ -z "$supp" ] && "$observed"; then link=external
	elif [ -f "$ready" ]; then link=connected
	elif "$joining" || "$configured"; then link=connecting
	else link=idle
	fi
	new="id=$req_id
result=$req_result
state=$link
saved=$saved"
	[ "$new" != "$published" ] || return 0
	printf '%s\n' "$new" > "$work/status" && mv -f "$work/status" "$run/wifi.status" && published=$new
}
# Stop the clients of this worker and go back to the saved network.
reset_link() {
	stop_clients "$dhcp" "$supp"
	dhcp='' supp=''
	rm -f "$work/lease" "$work/candidate" "$work/conf.new" "$ready"
	joining=false
	load_profile
	waiting=0 delay=0 backoff=2
}
# $1 is the result of the scan or join that stops here.
abort_pending() {
	if [ -n "$scan" ]; then
		scan='' scan_at=''
		rm -f "$work/scan"
		req_result=$1
	fi
	if "$joining"; then
		reset_link
		req_result=$1
	fi
}
# The panel writes "ssid=" and "psk=" lines. The card parser removes outer
# blanks, so a value with outer blanks cannot be saved and read back.
shaped() {
	[ "$(wc -l < "$1")" -eq 2 ] || return 1
	{ IFS= read -r name && IFS= read -r key; } < "$1" || return 1
	shape=0
	case "$name" in "ssid= "*|"ssid=$tab"*|*" "|*"$tab"|*"$cr") shape=1 ;; ssid=?*) ;; *) shape=1 ;; esac
	case "$key" in "psk= "*|"psk=$tab"*|*" "|*"$tab"|*"$cr") shape=1 ;; psk=?*) ;; *) shape=1 ;; esac
	name='' key=''
	return "$shape"
}
# The candidate replaces the card file only after its link and lease are confirmed.
save_candidate() {
	mkdir -p "${config%/*}" 2>/dev/null
	{ printf '# Saved on the device. The card stores the password in plain text.\n' && cat "$work/candidate"; } \
		> "$config.new" 2>/dev/null && mv -f "$config.new" "$config" 2>/dev/null || { rm -f "$config.new" 2>/dev/null; return 1; }
	sync
	rm -f "$work/candidate"
	joining=false
	load_profile
	"$configured"
}
request() {
	mv -f "$run/wifi.request" "$work/request" 2>/dev/null || return 0
	id='' action=''
	read -r id action < "$work/request"
	rm -f "$work/request"
	case "$id" in ''|*[!0-9]*) return 0 ;; esac
	abort_pending canceled
	req_id=$id req_result=ok
	if [ "$action" = cancel ]; then
		:
	elif [ -z "$supp" ] && "$observed"; then
		# BaseOS owns this connection.
		req_result=external
	else
		case "$action" in
			scan)
				if "$off"; then
					req_result=off
				else
					rm -f "$run/wifi.scan"
					need=true scan=0 scan_at='' delay=0 req_result=pending
				fi ;;
			join)
				if "$off"; then
					req_result=off
				elif mv -f "$run/wifi.candidate" "$work/candidate" 2>/dev/null && shaped "$work/candidate" &&
					/lib/ld-linux-aarch64.so.1 "$system/socket-wifi-config" "$work/conf.new" "$work/ctrl" < "$work/candidate"; then
					stop_clients "$dhcp" "$supp"
					dhcp='' supp=''
					rm -f "$work/lease" "$ready"
					mv -f "$work/conf.new" "$work/conf"
					need=true joining=true join_ticks=0 join_seen=notfound waiting=0 delay=0 req_result=pending
				else
					rm -f "$work/candidate" "$work/conf.new"
					req_result=invalid
				fi ;;
			forget)
				rm -f "$config" "$config.new" 2>/dev/null
				if [ -e "$config" ]; then req_result=save; else sync; reset_link; fi ;;
			reconnect) reset_link ;;
			off)
				: 2>/dev/null > "$pref" || req_result=save
				off=true need=false
				reset_link
				if [ -n "$ntp" ]; then stop_clients "$ntp"; ntp=; fi
				clock_ticks=0 ;;
			on)
				rm -f "$pref" 2>/dev/null
				[ ! -e "$pref" ] || req_result=save
				off=false delay=0 ;;
			*) req_result=invalid ;;
		esac
	fi
	rm -f "$run/wifi.candidate"
}
scan_tick() {
	[ -n "$scan" ] || return 0
	scan=$((scan + 1))
	if [ -z "$scan_at" ]; then
		if [ -n "$supp" ] && timeout -k 1 2 wpa_cli -p "$work/ctrl" -i wlan0 scan 2>/dev/null | grep -Eq '^(OK|FAIL-BUSY)$'; then
			scan_at=$scan
		fi
	elif [ $((scan - scan_at)) -ge 2 ]; then
		timeout -k 1 2 wpa_cli -p "$work/ctrl" -i wlan0 scan_results > "$work/scan" 2>/dev/null
		# The first line is the column header.
		if [ "$(wc -l < "$work/scan")" -gt 1 ] || [ "$scan" -ge "$scan_wait" ]; then
			if mv -f "$work/scan" "$run/wifi.scan"; then req_result=ok; else req_result=timeout; fi
			scan='' scan_at=''
			return 0
		fi
	fi
	if [ "$scan" -ge "$scan_wait" ]; then
		scan='' scan_at=''
		rm -f "$work/scan"
		req_result=timeout
	fi
}
publish
while [ ! -e "$run/wifi.stop" ]; do
	if [ -e "$run/shallow.sleep" ]; then
		if ! "$asleep"; then
			abort_pending canceled
			publish
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
	fi
	if "$asleep"; then
		:
	elif request && "$off"; then
		:
	elif [ "$delay" -gt 0 ] && [ -z "$scan" ] && ! "$joining"; then
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
			elif [ -z "$wpa_state" ] && [ -z "$supp" ] && [ ! -S "$ctrl/wlan0" ] && { "$configured" || "$need"; }; then
				owned wpa_supplicant -i wlan0 -Dnl80211 -c "$work/conf" >/dev/null 2>&1 &
				supp=$!
				waiting=0
			fi
		fi
		# Only the private supplicant has the candidate. Its only network is the
		# candidate, and the lease file comes from the DHCP client of this attempt.
		if "$linked" && "$joining" && { [ -z "$supp" ] || [ ! -f "$work/lease" ]; }; then
			linked=false
		fi
		if "$linked" && "$joining" && ! save_candidate; then
			reset_link
			req_result=save
			linked=false
		elif "$linked" && [ "$req_result" = pending ] && [ -z "$scan" ]; then
			req_result=ok
		fi
		if "$linked"; then
			if [ ! -f "$ready" ] && [ ! -e "$run/shallow.sleep" ] && [ ! -e "$run/wifi.stop" ]; then
				: > "$work/ready" && mv -f "$work/ready" "$ready"
			fi
			waiting=0
			backoff=2
			check_clock
			[ "$clock_ticks" -gt 0 ] || delay=3
		else
			rm -f "$ready"
			if [ -n "$ntp" ]; then stop_clients "$ntp"; ntp=; fi
			clock_ticks=0
			if "$joining"; then
				join_ticks=$((join_ticks + 1))
				case "$wpa_state" in
					AUTHENTICATING|ASSOCIATING|ASSOCIATED|4WAY_HANDSHAKE|GROUP_HANDSHAKE) join_seen=auth ;;
					COMPLETED) join_seen=dhcp ;;
				esac
				# The supplicant disables a network when the access point rejects the key.
				if [ -n "$supp" ] && [ "$wpa_state" != COMPLETED ] &&
					timeout -k 1 1 wpa_cli -p "$work/ctrl" -i wlan0 list_networks 2>/dev/null | grep -q 'TEMP-DISABLED'; then
					join_seen=auth
					join_ticks=$join_wait
				fi
				if [ "$join_ticks" -ge "$join_wait" ] || { [ -n "$supp" ] && ! ours "$supp"; } ||
					{ [ -n "$dhcp" ] && ! ours "$dhcp"; }; then
					code=$join_seen
					reset_link
					req_result=$code
				fi
			elif ! "$configured"; then
				# A scan-only supplicant has no link to wait for.
				if [ -n "$supp" ] && ! ours "$supp"; then supp=; fi
				delay=3
			fi
			waiting=$((waiting + 1))
			if "$joining" || ! "$configured"; then
				waiting=0
			elif [ "$waiting" -ge 25 ] || { [ -n "$supp" ] && ! ours "$supp"; } ||
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
	if ! "$asleep"; then
		scan_tick
		publish
	fi
	[ ! -e "$run/wifi.stop" ] || break
	sleep 1
done
