"""Test the card Bluetooth worker with simulated BaseOS and BlueZ tools."""

import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest


SYSTEM = Path(__file__).resolve().parents[1] / "card/System/socket"
MAC = "AA:BB:CC:DD:EE:FF"
ADAPTER = """   array [
      dict entry(
         object path "/org/bluez/hci0"
         array [
            dict entry(
               string "org.bluez.Adapter1"
               array [
                  dict entry(
                     string "Powered"
                     variant                         boolean %s
                  )
"""


def script(path, body):
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o700)


class BluetoothWorkerTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.run = self.root / "run"
        self.fake = self.root / "fake"
        bins = self.root / "bin"
        self.logs = self.root / "logs"
        self.lock = self.root / "attach.lock"
        for folder in (self.run, self.fake, bins, self.logs):
            folder.mkdir()
        self.pref = self.root / "bluetooth.cfg"
        self.attach = self.root / "setBluetooth.sh"
        # As setBluetooth.sh of BaseOS: no second attach while the lock is there.
        # A soft block stops the attach, and the lock stays.
        script(self.attach, """
[ -e "$LOCK" ] && exit 0
touch "$LOCK"
echo "attach $1" >> "$FAKE/radio"
[ -e "$FAKE/soft-blocked" ] || echo "$1" >> "$FAKE/attach"
""")
        script(bins / "sleep", 'exec /bin/sleep .02\n')
        script(bins / "timeout", 'shift 3\nexec "$@"\n')
        script(bins / "pidof", 'exit 1\n')
        script(bins / "systemctl", '[ -e "$FAKE/attach" ] && [ ! -e "$FAKE/no-adapter" ] && touch "$FAKE/adapter"\n')
        script(bins / "dbus-send", """
case "$*" in *Properties.Set*)
	[ ! -e "$FAKE/power-error" ] || { cat "$FAKE/power-error" >&2; exit 1; }
	case "$*" in
		*boolean:true) echo "power on $4" >> "$FAKE/commands"; touch "$FAKE/powered" ;;
		*) echo "power off $4" >> "$FAKE/commands"; rm -f "$FAKE/powered" ;;
	esac
	exit 0 ;;
esac
echo x >> "$FAKE/polls"
[ ! -e "$FAKE/slow-adapter" ] || [ "$(wc -l < "$FAKE/polls")" -lt 15 ] || touch "$FAKE/adapter"
[ -e "$FAKE/adapter" ] || exit 1
if [ -e "$FAKE/powered" ]; then value=true; else value=false; fi
printf "$ADAPTER" "$value"
""")
        # A tool that needs a terminal must not be in the power path.
        script(bins / "bluetoothctl", 'echo "bluetoothctl $*" >> "$FAKE/commands"\n')
        script(bins / "rfkill", """
[ ! -e "$FAKE/rfkill-fails" ] || exit 1
echo "rfkill $*" >> "$FAKE/radio"
[ "$*" != "unblock bluetooth" ] || rm -f "$FAKE/soft-blocked"
""")
        script(bins / "hciconfig", """
echo "hciconfig $*" >> "$FAKE/radio"
[ "$*" = "hci0 up" ] && [ -e "$FAKE/hciconfig-works" ] && touch "$FAKE/powered"
exit 0
""")
        self.worker = self.root / "bluetooth.sh"
        self.worker.write_text((SYSTEM / "bluetooth.sh").read_text().replace("/lib/ld-linux-aarch64.so.1 ", ""))
        script(self.root / "socket-bluetooth-agent", """
echo $$ >> "$FAKE/ctl.pids"
echo ready
while IFS= read -r line; do echo "$line" >> "$FAKE/commands"; done
""")
        script(bins / "bluealsa", 'echo "$$ $*" >> "$FAKE/bluealsa"\ntrap "exit 0" TERM\nwhile :; do /bin/sleep .02; done\n')
        script(bins / "bluealsa-aplay", '[ "$1" = -L ] && cat "$FAKE/pcms" 2>/dev/null\n')
        self.env = dict(os.environ, SOCKET_RUN=str(self.run), SOCKET_SYSTEM=str(self.root), FAKE=str(self.fake), ADAPTER=ADAPTER,
                        SOCKET_BLUETOOTH_SETTINGS=str(self.pref), SOCKET_BLUETOOTH_ATTACH=str(self.attach),
                        SOCKET_BLUETOOTH_SCAN_TICKS="6", SOCKET_LOGS=str(self.logs),
                        SOCKET_BLUETOOTH_ATTACH_LOCK=str(self.lock), LOCK=str(self.lock), PATH=str(bins) + ":" + os.environ["PATH"])
        self.sequence = 0

    def start(self):
        proc = subprocess.Popen(["sh", str(self.worker), "run"], env=self.env, start_new_session=True)
        self.addCleanup(self.kill, proc)
        return proc

    def kill(self, proc):
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()

    def until(self, predicate, message="the simulated Bluetooth state"):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.02)
        self.fail("Timed out waiting for " + message)

    def request(self, text):
        self.sequence += 1
        temp = self.run / "bluetooth.tmp-request"
        temp.write_text(text + "\n")
        temp.rename(self.run / f"bluetooth.request.{self.sequence:014d}")

    def read(self, name, folder=None):
        path = (folder or self.run) / name
        return path.read_text() if path.exists() else ""

    def status(self, value):
        self.until(lambda: self.read("bluetooth.status") == value + "\n", "status " + value)

    def commands(self):
        return self.read("commands", self.fake).split("\n")[:-1]

    def sent(self, command):
        self.until(lambda: command in self.commands(), command)

    def pids(self):
        return list(map(int, self.read("ctl.pids", self.fake).split()))

    def test_radio_panel_requests_route_sleep_and_stop(self):
        proc = self.start()
        self.status("off")
        self.assertFalse((self.fake / "attach").exists())
        self.assertEqual(self.read("bluetooth.asound"), "\n")
        # The panel can open before the radio is on. No tool starts yet.
        self.request("open")
        self.request("on")
        self.status("on")
        self.assertEqual(self.read("attach", self.fake), "init\n")
        self.until(lambda: self.read("bluetooth.cfg", self.root) == "1\n", "radio preference saved")
        self.assertEqual(self.commands()[0], "power on /org/bluez/hci0")
        self.assertFalse((self.run / "bluetooth.error").exists())
        self.assertEqual(self.read("socket-bluetooth.log", self.logs), "")
        self.until(lambda: self.read("bluealsa", self.fake).endswith(" -p a2dp-source\n"))
        self.until(lambda: self.read("bluetooth.log").endswith("\nready\n"))
        self.assertIn('string "org.bluez.Adapter1"', self.read("bluetooth.state"))
        first_log = self.read("bluetooth.log").split("\n")[0]
        self.assertRegex(first_log, r"^# \d+ 1$")

        # Only commands in the fixed vocabulary reach the agent.
        for bad in ("pair aa:bb:cc:dd:ee:ff", f"pair {MAC} extra", f"pair {MAC}\nremove {MAC}", "answer yes;no",
                    "answer " + "1" * 17, "answer ", "menu gatt", "power off", f"block {MAC}", ""):
            self.request(bad)
        for good in (f"pair {MAC}", "answer 123456", "answer yes", f"trust {MAC}", f"connect {MAC}",
                     f"disconnect {MAC}", f"remove {MAC}"):
            self.request(good)
        self.sent(f"remove {MAC}")
        self.assertEqual(self.commands()[1:], [f"pair {MAC}", f"pair {MAC}", "answer 123456", "answer yes", f"trust {MAC}",
                                               f"connect {MAC}", f"disconnect {MAC}", f"remove {MAC}"])

        # Discovery stops at the limit without a request from the panel.
        self.request("scan on")
        self.sent("scan off")
        self.assertEqual(self.commands()[-2:], ["scan on", "scan off"])

        # A headset PCM becomes the Godot device and the default ALSA device.
        (self.fake / "pcms").write_text(f"bluealsa:SRV=org.bluealsa,DEV={MAC},PROFILE=sco\n"
                                        f"bluealsa:SRV=org.bluealsa,DEV={MAC},PROFILE=a2dp\n    Headset, playback\n")
        self.until(lambda: self.read("bluetooth.audio") == MAC + "\n")
        route = self.read("bluetooth.asound")
        self.assertIn(f'pcm.plughw_socket_bluetooth {{\n\ttype plug\n\tslave.pcm {{ type bluealsa device "{MAC}" profile "a2dp" }}', route)
        self.assertTrue(route.endswith('pcm.!default "plughw_socket_bluetooth"\n'))
        (self.fake / "pcms").write_text("")
        self.until(lambda: not (self.run / "bluetooth.audio").exists())
        self.until(lambda: self.read("bluetooth.asound") == "\n")

        # Reset replaces the agent. BlueZ then cancels its discovery and pairing.
        self.request("reset")
        self.until(lambda: len(self.pids()) == 2)
        self.until(lambda: self.read("bluetooth.log").startswith(first_log[:-1] + "2\n"))
        with self.assertRaises(ProcessLookupError):
            os.kill(self.pids()[0], 0)

        # Sleep drops the agent. Wake starts a new one for the open panel.
        (self.run / "shallow.sleep").touch()
        self.until(lambda: self.gone(self.pids()[1]))
        time.sleep(.2)
        self.assertEqual(len(self.pids()), 2)
        (self.run / "shallow.sleep").unlink()
        self.until(lambda: len(self.pids()) == 3)
        self.request("close")
        self.until(lambda: self.gone(self.pids()[2]))
        time.sleep(.2)
        self.assertEqual(len(self.pids()), 3)
        self.request("scan on")

        self.request("off")
        self.status("off")
        self.assertEqual(self.commands()[-1], "power off /org/bluez/hci0")
        self.assertEqual(self.pref.read_text(), "0\n")
        self.until(lambda: self.gone(int(self.read("bluealsa", self.fake).split()[0])))
        self.assertFalse((self.run / "bluetooth.state").exists())

        self.assertEqual(subprocess.run(["sh", str(self.worker), "stop"], env=self.env, timeout=5).returncode, 0)
        self.assertEqual(proc.wait(timeout=5), 0)
        self.assertEqual(sorted(path.name for path in self.run.iterdir()), ["bluetooth.asound"])

    def gone(self, pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        return False

    def test_saved_preference_starts_the_radio_and_one_worker_runs(self):
        self.pref.write_text("1\n")
        first = self.start()
        self.status("on")
        self.assertEqual(self.start().wait(timeout=5), 0)
        self.assertEqual(self.read("bluetooth.status"), "on\n")
        # A killed worker leaves its lock. The next worker replaces it.
        self.kill(first)
        (self.run / "bluetooth.status").unlink()
        second = self.start()
        self.until(lambda: self.read("bluetooth.worker/pid") == f"{second.pid}\n")
        self.status("on")
        second.terminate()
        self.assertEqual(second.wait(timeout=5), 0)
        self.assertFalse((self.run / "bluetooth.worker").exists())

    def test_missing_adapter_or_tools_report_unavailable(self):
        (self.fake / "no-adapter").touch()
        self.start()
        self.status("off")
        self.request("on")
        self.status("unavailable")
        # A new On that fails is not saved: the next boot does not try again.
        self.assertFalse(self.pref.exists())
        self.assertEqual(self.commands(), [])
        for missing in (self.attach, self.root / "socket-bluetooth-agent"):
            subprocess.run(["sh", str(self.worker), "stop"], env=self.env, timeout=5)
            saved = missing.read_text()
            missing.unlink()
            (self.fake / "no-adapter").unlink(missing_ok=True)
            self.pref.write_text("1\n")
            self.start()
            self.status("unavailable")
            self.request("off")
            self.status("off")
            self.assertEqual(self.commands(), [])
            script(missing, saved[saved.index("\n") + 1:])

    def test_stop_during_power_up_and_the_bluealsad_name(self):
        # The adapter does not appear. A stop request ends the wait for it.
        (self.fake / "no-adapter").touch()
        script(self.root / "bin/sleep", 'exec /bin/sleep .3\n')
        self.pref.write_text("1\n")
        proc = self.start()
        self.status("starting")
        started = time.monotonic()
        self.assertEqual(subprocess.run(["sh", str(self.worker), "stop"], env=self.env, timeout=5).returncode, 0)
        self.assertEqual(proc.wait(timeout=5), 0)
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(self.commands(), [])
        # A newer BlueALSA has the daemon name bluealsad.
        (self.fake / "no-adapter").unlink()
        script(self.root / "bin/sleep", 'exec /bin/sleep .02\n')
        script(self.root / "bin/bluealsad", 'echo "$*" >> "$FAKE/bluealsad"\nexec /bin/sleep 30\n')
        self.start()
        self.status("on")
        self.until(lambda: self.read("bluealsad", self.fake) == "-p a2dp-source\n")
        self.assertFalse((self.fake / "bluealsa").exists())

    def test_agent_that_cannot_register_is_not_started_in_a_loop(self):
        script(self.root / "socket-bluetooth-agent", 'echo $$ >> "$FAKE/ctl.pids"\n')
        self.pref.write_text("1\n")
        self.start()
        self.status("on")
        self.request("open")
        self.status("unavailable")
        self.error("The pairing service did not start.")
        time.sleep(.3)
        self.assertEqual(len(self.pids()), 1)
        # The retry of the user starts it one more time.
        self.request("on")
        self.until(lambda: len(self.pids()) == 2)
        self.status("unavailable")
        time.sleep(.3)
        self.assertEqual(len(self.pids()), 2)

    def radio(self):
        # The failure report also reads the adapter with "hciconfig -a".
        return [line for line in self.read("radio", self.fake).split("\n")[:-1] if line != "hciconfig -a"]

    def error(self, text):
        self.until(lambda: text in self.read("bluetooth.error"), "error " + text)

    def test_power_failure_names_the_bluez_error_and_a_retry_clears_it(self):
        (self.fake / "power-error").write_text("Error org.bluez.Error.Blocked: Blocked through rfkill\n")
        self.start()
        self.status("off")
        self.request("on")
        self.status("unavailable")
        self.assertEqual(self.read("bluetooth.error"),
                         "The Bluetooth radio did not turn on (org.bluez.Error.Blocked). Restart the device, then try again.\n")
        # The stock method was tried before the worker stopped.
        self.assertEqual(self.read("radio", self.fake).split("\n")[:4],
                         ["rfkill unblock bluetooth", "attach init", "rfkill unblock bluetooth", "hciconfig hci0 up"])
        self.assertFalse(self.pref.exists())
        log = self.read("socket-bluetooth.log", self.logs)
        self.assertIn("power on: Error org.bluez.Error.Blocked: Blocked through rfkill\n", log)
        self.assertIn("processes: dbus-daemon=down bluetoothd=down rtk_hciattach=down\n", log)
        self.assertFalse((self.fake / "bluealsa").exists())
        self.assertEqual(self.commands(), [])
        (self.fake / "power-error").unlink()
        self.request("on")
        self.status("on")
        self.until(lambda: self.read("bluetooth.cfg", self.root) == "1\n")
        self.assertFalse((self.run / "bluetooth.error").exists())
        self.assertEqual(self.read("socket-bluetooth.log", self.logs), "")

    def test_soft_block_is_removed_before_the_attach_and_wifi_stays(self):
        # The attach works only after the unblock. Without rfkill it fails.
        (self.fake / "soft-blocked").touch()
        (self.fake / "rfkill-fails").touch()
        self.start()
        self.status("off")
        self.request("on")
        self.status("unavailable")
        self.error("The Bluetooth radio did not start.")
        self.assertEqual(self.radio(), ["attach init"])
        self.assertFalse(self.pref.exists())
        (self.fake / "rfkill-fails").unlink()
        self.request("on")
        self.status("on")
        self.until(lambda: self.read("bluetooth.cfg", self.root) == "1\n")
        radio = self.radio()
        self.assertEqual(radio, ["attach init", "rfkill unblock bluetooth", "attach init"])
        # Only the Bluetooth type: no command changes Wi-Fi.
        self.assertEqual([line for line in radio if line.startswith("rfkill")], ["rfkill unblock bluetooth"])

    def test_hciconfig_starts_a_radio_that_bluez_does_not_power(self):
        (self.fake / "power-error").write_text("Error org.bluez.Error.Failed: Failed\n")
        (self.fake / "hciconfig-works").touch()
        self.pref.write_text("1\n")
        self.start()
        self.status("on")
        self.assertEqual(self.read("socket-bluetooth.log", self.logs), "power on: Error org.bluez.Error.Failed: Failed\n")

    def test_stale_attach_lock_and_slow_adapter(self):
        # rtk_hciattach stopped, but the lock of setBluetooth.sh stays.
        self.lock.touch()
        (self.fake / "slow-adapter").touch()
        script(self.root / "bin/systemctl", '[ -e "$FAKE/attach" ] || touch "$FAKE/no-attach"\n')
        self.pref.write_text("1\n")
        self.start()
        self.status("on")
        self.assertEqual(self.read("attach", self.fake), "init\n")
        self.assertFalse((self.fake / "no-attach").exists())
        self.assertGreaterEqual(len(self.read("polls", self.fake).split()), 15)

    def test_each_failure_gives_its_cause(self):
        (self.fake / "no-adapter").touch()
        self.pref.write_text("1\n")
        self.start()
        self.error("The Bluetooth radio did not start.")
        self.status("unavailable")
        # A saved preference stays after a failure at boot and after a retry.
        self.assertEqual(self.pref.read_text(), "1\n")
        self.request("on")
        time.sleep(.5)
        self.status("unavailable")
        self.assertEqual(self.pref.read_text(), "1\n")
        for change, text in ((lambda: self.attach.unlink(), "no Bluetooth support. Update BaseOS."),
                             (lambda: self.env.update(BASEOS_BLUETOOTH="0"), "This device has no Bluetooth radio.")):
            subprocess.run(["sh", str(self.worker), "stop"], env=self.env, timeout=5)
            self.assertFalse((self.run / "bluetooth.error").exists())
            change()
            self.start()
            self.error(text)
        self.assertIn("error: This device has no Bluetooth radio.\n", self.read("socket-bluetooth.log", self.logs))


if __name__ == "__main__":
    unittest.main()
