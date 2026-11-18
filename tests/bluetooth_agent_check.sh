#!/bin/sh
# Run in an ubuntu:22.04 container with the repository at /repo.
# Build socket-bluetooth-agent and drive it, then the card worker under
# BusyBox sh, with the real D-Bus tools and a fake org.bluez service.
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq --no-install-recommends gcc libc6-dev libdbus-1-dev \
	pkg-config dbus bluez busybox python3-dbus python3-gi >/dev/null 2>&1 || { echo APT-FAILED; exit 1; }
# shellcheck disable=SC2046
gcc -std=c11 -D_DEFAULT_SOURCE -Wall -Wextra -Werror -O2 /repo/engine/bluetooth-agent.c -o /agent \
	$(pkg-config --cflags --libs dbus-1) || exit 1
mkdir -p /run/dbus; dbus-uuidgen > /etc/machine-id; dbus-daemon --system; sleep .5
python3 /repo/tests/bluetooth_fake_bluez.py >> /fake.log 2>&1 &
sleep 1.5
M=AA:BB:CC:DD:EE:FF
mkfifo /in; /agent < /in >> /out & pid=$!; exec 3> /in
sleep .5
for mode in stranger pin passkey display authorize service after hang; do
	echo "# $mode" >> /out; echo $mode > /tmp/mode
	echo "pair $M" >&3; sleep .7
	case $mode in stranger) echo "answer yes" >&3 ;; pin) echo "answer 0000" >&3 ;; passkey) echo "answer 123456" >&3 ;; hang) sleep 1.2 ;; esac
	sleep .8
done
echo "# reject" >> /out
echo confirm > /tmp/mode; echo "pair $M" >&3; sleep .7; echo "answer no" >&3; sleep .5
echo "# commands" >> /out
for line in "answer yes" "trust $M" "connect $M" "disconnect $M" "remove $M" "scan on" "scan off" "pair nonsense" "pair AA:BB:CC:DD:EE:F" bogus; do
	echo "$line" >&3; sleep .2
done
echo "# end of input" >> /out
echo pin > /tmp/mode; echo "pair $M" >&3; sleep .7
# Another program calls the agent for the selected target. Only BlueZ can.
dbus-send --system --print-reply --dest="$(cat /tmp/agent-name)" /socket/agent org.bluez.Agent1.RequestAuthorization \
	objpath:/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF 2>&1 | grep -o 'org.bluez.Error.Rejected' | sed 's/^/foreign-sender=/'
exec 3>&-; wait $pid; echo "agent-exit=$?"
sleep .5
echo "--- agent"; cat /out; echo "--- fake"; grep '^FAKE' /fake.log

# The worker, with BusyBox applets as on the card. This BusyBox has no "timeout -k".
mkdir /bb /card /tmp/socket; echo WORKER >> /fake.log
for applet in sh grep sed sleep cat rm mv mkdir mkfifo head pidof kill; do ln -s /bin/busybox /bb/$applet; done
printf '#!/bin/sh\nexit 0\n' > /bb/systemctl; chmod +x /bb/systemctl; echo : > /card/attach; echo 1 > /card/pref
sed 's|/lib/ld-linux-aarch64.so.1 ||' /repo/card/System/socket/bluetooth.sh > /card/bluetooth.sh; cp /agent /card/socket-bluetooth-agent
export PATH="/bb:$PATH" SOCKET_RUN=/tmp/socket SOCKET_SYSTEM=/card SOCKET_BLUETOOTH_SETTINGS=/card/pref SOCKET_BLUETOOTH_ATTACH=/card/attach
/bb/sh /card/bluetooth.sh run 2> /worker.err &
R=/tmp/socket; n=0
request() { n=$((n + 1)); echo "$1" > $R/bluetooth.tmp-request; mv $R/bluetooth.tmp-request "$R/bluetooth.request.$(printf %014d $n)"; }
sleep 2; echo "--- worker"; echo "status=$(cat $R/bluetooth.status)"
request open; sleep 1.5
echo confirm > /tmp/mode; request "pair $M"; sleep 1; request "answer yes"; sleep 1
echo pin > /tmp/mode; request "pair $M"; sleep 1; request reset; sleep 1.5
echo passkey > /tmp/mode; request "pair $M"; sleep 1; request "answer 123456"; sleep 1
cat $R/bluetooth.log; echo "state-devices=$(grep -c 'org.bluez.Device1' $R/bluetooth.state)"
/bb/sh /card/bluetooth.sh stop; sleep .5; echo "left=$(ls $R)"; echo "stderr=$(cat /worker.err)"
echo "--- fake"; sed -n '/^WORKER/,$p' /fake.log | grep '^FAKE'
