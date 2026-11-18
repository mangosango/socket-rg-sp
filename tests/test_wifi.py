"""Test the card Wi-Fi worker with a simulated radio and DHCP lease."""

import hashlib
import os
from pathlib import Path
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SYSTEM = ROOT / "card/System/socket"


def script(path, body):
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o700)


class WifiBinaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.bin = Path(cls.temp.name) / "socket-wifi-config"
        if os.environ.get("SOCKET_TEST_WIFI_CONFIG"):
            cls.bin = Path(os.environ["SOCKET_TEST_WIFI_CONFIG"])
            return
        if not shutil.which("pkg-config") or subprocess.run(
                ["pkg-config", "--atleast-version=3.3", "mbedcrypto"]).returncode:
            raise unittest.SkipTest("Set SOCKET_TEST_WIFI_CONFIG or install mbedTLS 3 development files")
        flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "mbedcrypto"], text=True)
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", str(ROOT / "engine/wifi-config.c"),
                        "-o", str(cls.bin), *shlex.split(flags)], check=True)


class WifiConfigTests(WifiBinaryTests):
    def test_private_config_matches_wpa2_key(self):
        ssid = b'a "# = $HOME \\'
        for psk in (b'quote"# = $(false) \\ " ;', b'12345678', b'x' * 63, b'aB' * 32):
            with self.subTest(length=len(psk)), tempfile.TemporaryDirectory() as d:
                conf = Path(d) / "conf"
                result = subprocess.run([self.bin, conf, "/run/control"],
                                        input=b"# comment\r\n ssid = " + ssid + b"\r\npsk = " + psk,
                                        capture_output=True)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
                self.assertEqual(stat.S_IMODE(conf.stat().st_mode), 0o600)
                key = psk.decode() if len(psk) == 64 else hashlib.pbkdf2_hmac("sha1", psk, ssid, 4096, 32).hex()
                expected = (f"ctrl_interface=/run/control\nnetwork={{\n\tscan_ssid=1\n\tproto=RSN\n"
                            f"\tkey_mgmt=WPA-PSK\n\tssid={ssid.hex()}\n\tpsk={key}\n}}\n")
                self.assertTrue(conf.read_text() == expected, "The derived WPA2 configuration differs")

    def test_invalid_records_never_create_a_config(self):
        for ssid, psk in ((b"", b"12345678"), (b"x" * 33, b"12345678"), (b"x", b"1234567"),
                          (b"x", b"g" * 64), (b"x", b"a" * 65), (b"x", b"123\x0045678"),
                          (b"x", b"123\r45678"), (b"x", b"123\t45678")):
            with tempfile.TemporaryDirectory() as d:
                conf = Path(d) / "conf"
                result = subprocess.run([self.bin, conf, "/run/control"], input=b"ssid=" + ssid + b"\npsk=" + psk,
                                        capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((result.stdout, result.stderr), (b"", b""))
                self.assertFalse(conf.exists())


class WifiWorkerTests(WifiBinaryTests):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.run = self.root / "run"
        self.run.mkdir()
        self.net = self.root / "net"
        self.net.mkdir()
        self.wlan = self.net / "wlan0"
        self.bins = self.root / "bin"
        self.bins.mkdir()
        self.config = self.root / "wifi.txt"
        self.config.write_text("ssid=Example\npsk=example-passphrase\n")
        self.worker = self.root / "wifi.sh"
        self.worker.write_text((SYSTEM / "wifi.sh").read_text().replace("/lib/ld-linux-aarch64.so.1 ", ""))
        shutil.copy(SYSTEM / "wifi-lease.sh", self.root)
        shutil.copy(self.bin, self.root / "socket-wifi-config")
        script(self.bins / "sleep", 'case "$1" in 1) exec /bin/sleep .04;; .1) exec /bin/sleep .02;; esac\n')
        script(self.bins / "wpa_cli", """
if [ "$2" = /var/run/wpa_supplicant ]; then
    [ -f "$SOCKET_RUN/external" ] || exit 1
else
    [ -f "$SOCKET_RUN/supp.started" ] || exit 1
fi
case "$5" in
    scan) echo OK; exit 0 ;;
    scan_results)
        echo 'bssid / frequency / signal level / flags / ssid'
        [ ! -f "$SOCKET_RUN/aps" ] || cat "$SOCKET_RUN/aps"
        exit 0 ;;
    list_networks) [ ! -f "$SOCKET_RUN/wrong-key" ] || printf '0\tname\tany\t[TEMP-DISABLED]\n'; exit 0 ;;
esac
if [ -f "$SOCKET_RUN/join" ]; then echo wpa_state=COMPLETED; else echo wpa_state=SCANNING; fi
""")
        script(self.bins / "wpa_supplicant", """
sed -n 's/^\tssid=//p' "$5" > "$SOCKET_RUN/supp.ssid"
echo $$ >> "$SOCKET_RUN/supp.started"
trap 'exit 0' TERM
while :; do /bin/sleep .02; done
""")
        script(self.bins / "ip", """
case "$*" in
    '-4 addr show dev wlan0') [ ! -f "$SOCKET_RUN/address" ] || echo '    inet 192.0.2.1/24 scope global wlan0' ;;
    '-4 route show default') [ ! -f "$SOCKET_RUN/route" ] || echo "default via 192.0.2.254 dev $(cat "$SOCKET_RUN/route")" ;;
    *) exit 1 ;;
esac
""")
        script(self.bins / "udhcpc", """
[ "$*" = "-f -n -i wlan0 -t 4 -T 3 -s $SOCKET_RUN/wifi.worker/lease.sh" ] || exit 2
echo $$ >> "$SOCKET_RUN/dhcp.started"
trap 'exit 0' TERM
export interface=wlan0
hook=$SOCKET_RUN/wifi.worker/lease.sh
"$hook" deconfig || exit 3
while :; do
    [ ! -e "$SOCKET_RUN/no-lease" ] || exit 1
    if [ -e "$SOCKET_RUN/offer" ]; then
        rm -f "$SOCKET_RUN/offer"
        "$hook" bound || exit 4
    fi
    if [ -e "$SOCKET_RUN/renew" ]; then
        rm -f "$SOCKET_RUN/renew"
        "$hook" renew || exit 5
    fi
    /bin/sleep .02
done
""")
        script(self.bins / "lease-hook", """
echo "$1" >> "$SOCKET_RUN/hook.calls"
case "$1" in
    bound|renew) touch "$SOCKET_RUN/address" ;;
    deconfig) rm -f "$SOCKET_RUN/address" ;;
esac
""")
        script(self.bins / "date", 'if [ -f "$SOCKET_RUN/bad-clock" ]; then echo 1970; else echo 2026; fi\n')
        script(self.bins / "pidof", 'exit 1\n')
        script(self.bins / "ntpd", 'echo $$ >> "$SOCKET_RUN/ntp.started"\n'
               'if [ -f "$SOCKET_RUN/ntp-result" ]; then exit "$(cat "$SOCKET_RUN/ntp-result")"; fi\n'
               'exec /bin/sleep 300\n')
        self.env = dict(os.environ, SOCKET_RUN=str(self.run), SOCKET_SYSTEM=str(self.root),
                        BASEOS_NTP_SYNC_FILE=str(self.run / "baseos-ntp-synchronized"),
                        BASEOS_NTP_PID_FILE=str(self.run / "baseos-ntp.pid"),
                        SOCKET_NET_SYS=str(self.net), SOCKET_WIFI_PREF=str(self.root / "wifi.off"), SOCKET_DHCP_HOOK=str(self.bins / "lease-hook"),
                        PATH=str(self.bins) + ":" + os.environ["PATH"])
        self.ready = self.run / "wifi.ready"
        self.log = self.root / "output"

    def start(self):
        with self.log.open("ab") as output:
            proc = subprocess.Popen(["sh", str(self.worker), self.config], env=self.env,
                                    stdout=output, stderr=output, start_new_session=True)
        self.addCleanup(self.stop, proc)
        return proc

    def stop(self, proc):
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                raise

    def until(self, predicate):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.02)
        self.fail("Timed out waiting for the simulated network state")

    def mark(self, name):
        (self.run / name).touch()

    def starts(self, name):
        path = self.run / (name + ".started")
        return list(map(int, path.read_text().split())) if path.exists() else []

    def test_late_interface_lease_renewal_lid_and_link_loss(self):
        self.start()
        self.until(lambda: (self.run / "wifi.worker/conf").exists())
        self.assertEqual(self.starts("supp"), [])
        self.wlan.mkdir()
        self.until(lambda: self.starts("supp"))
        self.assertEqual(self.start().wait(timeout=1), 0)
        self.assertFalse(self.ready.exists())
        self.mark("join")
        self.until(lambda: self.starts("dhcp"))
        self.mark("offer")
        self.until(lambda: (self.run / "wifi.worker/lease").exists())
        (self.run / "route").write_text("wlan01")
        time.sleep(.2)
        self.assertFalse(self.ready.exists())
        (self.run / "route").write_text("wlan0")
        self.until(self.ready.exists)
        self.assertEqual(stat.S_IMODE(self.ready.stat().st_mode), 0o600)
        self.mark("renew")
        self.until(lambda: "renew" in (self.run / "hook.calls").read_text().splitlines())
        self.mark("shallow.sleep")
        self.until(lambda: not self.ready.exists())
        time.sleep(.2)
        self.assertTrue((self.run / "address").exists())
        (self.run / "shallow.sleep").unlink()
        self.until(self.ready.exists)
        self.assertEqual(len(self.starts("supp")), 1)
        self.assertEqual(len(self.starts("dhcp")), 1)
        (self.run / "join").unlink()
        self.until(lambda: not self.ready.exists() and not (self.run / "wifi.worker/lease").exists())
        self.mark("join")
        self.until(lambda: len(self.starts("dhcp")) == 2)
        self.assertFalse(self.ready.exists())
        self.mark("offer")
        self.until(self.ready.exists)
        self.assertNotIn(self.config.read_text().split("psk=")[1].strip(), self.log.read_text())

    def test_failed_join_retries_pause_and_stop_before_driver_unload(self):
        self.wlan.mkdir()
        proc = self.start()
        self.until(lambda: len(self.starts("supp")) == 2)
        self.mark("shallow.sleep")
        time.sleep(1.6)
        self.assertEqual(len(self.starts("supp")), 2)
        (self.run / "shallow.sleep").unlink()
        self.until(lambda: len(self.starts("supp")) == 3)
        shutil.copy(SYSTEM / "poweroff.sh", self.root)
        script(self.bins / "sync", "exit 0\n")
        script(self.bins / "rmmod", '[ "$1" = 8821cs ] && [ ! -d "$SOCKET_RUN/wifi.worker" ] && touch "$SOCKET_RUN/unloaded"\n')
        script(self.bins / "poweroff", '[ -f "$SOCKET_RUN/unloaded" ]\n')
        subprocess.run(["sh", self.root / "poweroff.sh"], env=self.env, check=True, timeout=3)
        self.assertEqual(proc.wait(timeout=1), 0)
        self.assertFalse(self.ready.exists())
        for pid in self.starts("supp"):
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
        self.assertEqual(self.starts("dhcp"), [])

    def test_borrowed_connection_and_bounded_clock_failure(self):
        self.config.unlink()
        self.wlan.mkdir()
        self.mark("join")
        self.mark("external")
        self.mark("address")
        # The simulated date is plausible, but BaseOS has not synchronized it.
        (self.run / "route").write_text("wlan0")
        proc = self.start()
        self.until(self.ready.exists)
        self.until(lambda: (self.run / "wifi.clock-error").exists())
        self.assertEqual(len(self.starts("ntp")), 1)
        with self.assertRaises(ProcessLookupError):
            os.kill(self.starts("ntp")[0], 0)
        (self.run / "ntp-result").write_text("0")
        (self.run / "join").unlink()
        self.until(lambda: not self.ready.exists())
        self.mark("join")
        self.until(self.ready.exists)
        self.until(lambda: not (self.run / "wifi.clock-error").exists())
        self.assertEqual(len(self.starts("ntp")), 2)
        self.stop(proc)
        self.assertFalse(self.ready.exists())
        self.assertTrue((self.run / "address").exists())
        self.assertEqual(self.starts("supp") + self.starts("dhcp"), [])

    def connect(self):
        self.wlan.mkdir()
        self.mark("join")
        self.mark("offer")
        (self.run / "route").write_text("wlan0")

    def test_existing_time_supervisor_gets_the_deadline(self):
        self.connect()
        script(self.bins / "baseos-ntp", "while :; do /bin/sleep .05; done\n")
        supervisor = subprocess.Popen([self.bins / "baseos-ntp"])
        self.addCleanup(supervisor.wait)
        self.addCleanup(supervisor.terminate)
        (self.run / "baseos-ntp.pid").write_text(f"{supervisor.pid}\n")
        self.start()
        self.until(self.ready.exists)
        self.until(lambda: (self.run / "wifi.clock-error").exists())
        self.assertTrue(self.ready.exists())
        self.assertIsNone(supervisor.poll())
        self.assertEqual(self.starts("ntp"), [])

    def test_clock_confirmation_and_one_shot_success(self):
        self.connect()
        (self.run / "baseos-ntp-synchronized").write_text("1794960000\n")
        first = self.start()
        self.until(self.ready.exists)
        self.stop(first)
        self.assertEqual(self.starts("ntp"), [])
        (self.run / "baseos-ntp-synchronized").unlink()
        (self.run / "ntp-result").write_text("0")
        self.mark("offer")
        self.start()
        self.until(lambda: self.starts("ntp"))
        time.sleep(1.3)
        self.assertTrue(self.ready.exists())
        self.assertEqual(len(self.starts("ntp")), 1)
        self.assertFalse((self.run / "wifi.clock-error").exists())

    @staticmethod
    def dead(pid):
        # Container init can retain a zombie after its parent dies.
        try:
            return Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].startswith("Z ")
        except FileNotFoundError:
            return True

    @unittest.skipUnless(sys.platform.startswith("linux"), "BaseOS uses the Linux parent-death signal")
    def test_launcher_death_releases_worker_and_clients(self):
        self.connect()
        with self.log.open("ab") as output:
            parent = subprocess.Popen(["sh", "-c", 'SOCKET_WIFI_PARENT=$$ sh "$1" "$2" & wait',
                                       "sh", self.worker, self.config], env=self.env, stdout=output,
                                      stderr=output, start_new_session=True)
        self.addCleanup(self.stop, parent)
        self.until(lambda: self.starts("ntp") and self.ready.exists())
        worker = int((self.run / "wifi.worker/owner").read_text())
        clients = [self.starts(role)[0] for role in ("supp", "dhcp", "ntp")]
        parent.kill()
        parent.wait(timeout=2)
        self.until(lambda: all(self.dead(pid) for pid in [worker, *clients]))
        self.mark("offer")
        replacement = self.start()
        self.until(lambda: len(self.starts("dhcp")) == 2 and self.ready.exists())
        self.stop(replacement)
        self.assertFalse(self.ready.exists())

    @unittest.skipUnless(sys.platform.startswith("linux"), "BaseOS uses the Linux parent-death signal")
    def test_killed_worker_restarts_and_stop_recovers_stale_state(self):
        self.connect()
        unrelated = subprocess.Popen(["/bin/sleep", "300"])
        self.addCleanup(unrelated.wait)
        self.addCleanup(unrelated.terminate)
        proc = self.start()
        for generation in (1, 2):
            self.until(lambda: len(self.starts("ntp")) == generation and self.ready.exists())
            self.assertEqual(self.start().wait(timeout=1), 0)
            self.assertTrue(self.ready.exists())
            clients = []
            for role in ("supp", "dhcp", "ntp"):
                started = self.starts(role)
                self.assertEqual(len(started), generation)
                clients.append(started[-1])
            proc.kill()
            proc.wait(timeout=2)
            self.until(lambda: all(self.dead(pid) for pid in clients))
            if generation == 1:
                (self.run / "join").unlink()
                old_worker = proc.pid
                proc = self.start()
                self.until(lambda: len(self.starts("supp")) == 2)
                self.assertFalse(self.ready.exists())
                hook = self.run / "wifi.worker/lease.sh"
                subprocess.run([hook, "renew"], env=dict(self.env, interface="wlan0",
                               SOCKET_WIFI_WORKER=str(old_worker)), timeout=2, check=True)
                self.assertFalse((self.run / "wifi.worker/lease").exists())
                self.mark("join")
                self.mark("offer")
            self.assertIsNone(unrelated.poll())
        subprocess.run(["sh", self.worker, "stop"], env=self.env, check=True, timeout=2)
        self.assertFalse(self.ready.exists())
        self.assertFalse((self.run / "wifi.worker").exists())
        self.assertIsNone(unrelated.poll())

    def test_frontend_and_game_run_while_radio_starts(self):
        card = self.root / "card"
        system = card / "System/socket"
        system.mkdir(parents=True)
        (card / "Config").mkdir()
        shutil.copy(self.config, card / "Config/wifi.txt")
        for name in ("wifi.sh", "wifi-lease.sh", "socket-wifi-config"):
            shutil.copy(self.root / name, system)
        for name in ("play_game.sh", "poweroff_ready.sh"):
            shutil.copy(SYSTEM / name, system)
        script(system / "socket-hardware", """
touch "$SOCKET_RUN/hardware.ready"
trap 'exit 0' TERM
while :; do /bin/sleep .05; done
""")
        script(system / "godot", 'sh "$SOCKET_SYSTEM/play_game.sh"\n')
        script(system / "launch_game.sh", """
touch "$SOCKET_RUN/playing"
while [ ! -e "$SOCKET_RUN/quit-game" ]; do /bin/sleep .05; done
""")
        script(self.bins / "sync", "exit 0\n")
        launcher = card / "launch_frontend.sh"
        launcher.write_text((ROOT / "card/System/launch_frontend.sh").read_text()
                            .replace("/lib/ld-linux-aarch64.so.1", "/bin/sh")
                            .replace("/tmp/socket", str(self.run)))
        with self.log.open("ab") as output:
            proc = subprocess.Popen(["sh", launcher], cwd=card, env=self.env,
                                    stdout=output, stderr=output, start_new_session=True)
        self.addCleanup(self.stop, proc)
        self.until(lambda: (self.run / "playing").exists())
        self.assertFalse(self.ready.exists())
        self.wlan.mkdir()
        self.mark("join")
        self.mark("offer")
        (self.run / "route").write_text("wlan0")
        self.until(self.ready.exists)
        self.assertEqual(len(self.starts("dhcp")), 1)
        if sys.platform.startswith("linux"):
            (self.run / "join").unlink()
            os.kill(int((self.run / "wifi.worker/owner").read_text()), signal.SIGKILL)
            self.until(lambda: len(self.starts("supp")) == 2)
            self.assertFalse(self.ready.exists())
            self.mark("join")
            self.mark("offer")
            self.until(self.ready.exists)
        self.mark("quit-game")
        self.assertEqual(proc.wait(timeout=5), 0)
        self.assertFalse(self.ready.exists())
        self.assertFalse((self.run / "wifi.worker").exists())

    def request(self, number, action, candidate=None):
        if candidate is not None:
            (self.run / "wifi.candidate").write_text(candidate)
        (self.run / "wifi.request.new").write_text(f"{number} {action}\n")
        os.replace(self.run / "wifi.request.new", self.run / "wifi.request")

    def status(self):
        try:
            return dict(line.split("=", 1) for line in (self.run / "wifi.status").read_text().splitlines())
        except FileNotFoundError:
            return {}

    def result(self, number, action, candidate=None):
        self.request(number, action, candidate)
        self.until(lambda: self.status().get("id") == str(number) and self.status()["result"] != "pending")
        return self.status()["result"]

    def supplicant_ssid(self):
        return bytes.fromhex((self.run / "supp.ssid").read_text().strip()).decode()

    def test_no_config_waits_idle_without_starting_clients(self):
        self.config.unlink()
        self.wlan.mkdir()
        proc = self.start()
        self.until(lambda: self.status().get("state") == "idle")
        time.sleep(.3)
        self.assertEqual(self.starts("supp") + self.starts("dhcp"), [])
        self.stop(proc)
        self.assertEqual(proc.returncode, 0)
        self.assertFalse((self.run / "wifi.worker").exists())
        self.assertFalse((self.run / "wifi.status").exists())

    def test_fresh_card_scans_joins_and_reconnects_after_restart(self):
        self.config = self.root / "Config/wifi.txt"
        self.wlan.mkdir()
        proc = self.start()
        self.until(lambda: self.status().get("state") == "idle")
        self.request(1, "scan")
        self.until(lambda: self.starts("supp"))
        self.assertEqual((self.run / "supp.ssid").read_text(), "")
        # The radio reports its results after the first poll.
        self.until(lambda: self.status() == {"id": "1", "result": "pending", "state": "idle", "saved": ""})
        aps = "02:00:00:00:00:01\t2437\t-50\t[WPA2-PSK-CCMP][ESS]\tCaf\\xc3\\xa9 net\n"
        (self.run / "aps").write_text(aps)
        self.until(lambda: self.status() == {"id": "1", "result": "ok", "state": "idle", "saved": ""})
        self.assertEqual((self.run / "wifi.scan").read_text().splitlines()[1:], aps.splitlines())
        ssid, psk = "Café net", 'pass word "#= $HOME'
        candidate = f"ssid={ssid}\npsk={psk}\n"
        self.request(2, "join", candidate)
        self.until(lambda: len(self.starts("supp")) == 2)
        self.assertEqual(self.supplicant_ssid(), ssid)
        self.assertFalse(self.config.exists())
        self.assertFalse((self.run / "wifi.candidate").exists())
        self.mark("join")
        self.mark("offer")
        (self.run / "route").write_text("wlan0")
        self.until(lambda: self.status() == {"id": "2", "result": "ok", "state": "connected", "saved": ssid})
        self.assertTrue(self.ready.exists())
        self.assertTrue(self.config.read_text().endswith(candidate))
        self.assertFalse((self.run / "wifi.worker/candidate").exists())
        self.assertEqual(list(self.config.parent.iterdir()), [self.config])
        # A cancel request that arrives after the commit changes nothing.
        self.assertEqual(self.result(3, "cancel"), "ok")
        self.assertEqual(self.status(), {"id": "3", "result": "ok", "state": "connected", "saved": ssid})
        self.assertTrue(self.ready.exists() and self.config.read_text().endswith(candidate))
        self.stop(proc)
        self.mark("offer")
        self.start()
        self.until(self.ready.exists)
        self.assertEqual(self.supplicant_ssid(), ssid)
        self.assertNotIn(psk, self.log.read_text())

    def test_failed_canceled_and_unsaved_joins_keep_the_previous_network(self):
        self.config = self.root / "Config/wifi.txt"
        self.config.parent.mkdir()
        saved = "ssid=Example\npsk=example-passphrase\n"
        self.config.write_text(saved)
        self.connect()
        self.start()
        self.until(self.ready.exists)
        other = "ssid=Other\npsk=other-passphrase\n"
        number = 0
        for invalid in ("ssid=Other \npsk=12345678\n", "ssid=Other\npsk= 12345678\n", "ssid=Other\npsk=1234567\n",
                        "ssid=Other\npsk=12345678\nssid=Third\n", "ssid=" + "x" * 33 + "\npsk=12345678\n",
                        "psk=12345678\nssid=Other\n", None):
            number += 1
            self.assertEqual(self.result(number, "join", invalid), "invalid")
            self.assertFalse((self.run / "wifi.candidate").exists())
        self.assertEqual(len(self.starts("supp")), 1)
        self.assertTrue(self.ready.exists())

        def attempt(prepare, expected):
            nonlocal number
            started = len(self.starts("supp"))
            (self.run / "join").unlink()
            number += 1
            self.request(number, "join", other)
            self.until(lambda: len(self.starts("supp")) == started + 1)
            self.assertEqual(self.supplicant_ssid(), "Other")
            self.assertFalse(self.ready.exists())
            prepare()
            self.until(lambda: self.status()["id"] == str(number) and self.status()["result"] != "pending")
            self.assertEqual(self.status()["result"], expected)
            for name in ("wrong-key", "no-lease", "shallow.sleep"):
                (self.run / name).unlink(missing_ok=True)
            self.assertEqual(self.config.read_text(), saved)
            self.assertFalse((self.run / "wifi.worker/candidate").exists())
            # The worker returns to the saved network without a request.
            self.until(lambda: len(self.starts("supp")) == started + 2)
            self.assertEqual(self.supplicant_ssid(), "Example")
            self.mark("join")
            self.mark("offer")
            self.until(lambda: self.ready.exists() and self.status()["saved"] == "Example")

        attempt(lambda: self.mark("wrong-key"), "auth")
        attempt(lambda: None, "notfound")
        attempt(lambda: (self.mark("no-lease"), self.mark("join")), "dhcp")
        attempt(lambda: self.mark("shallow.sleep"), "canceled")

        def cancel():
            nonlocal number
            number += 1
            self.request(number, "cancel")
        attempt(cancel, "ok")
        if os.geteuid():
            self.config.parent.chmod(0o500)
            self.addCleanup(self.config.parent.chmod, 0o700)
            attempt(lambda: (self.mark("join"), self.mark("offer")), "save")
        self.assertNotIn("passphrase", self.log.read_text())

    def test_off_survives_restart_and_forget_removes_the_network(self):
        self.connect()
        proc = self.start()
        self.until(self.ready.exists)
        self.assertEqual(self.result(1, "off"), "ok")
        self.assertEqual(self.status()["state"], "off")
        self.assertFalse(self.ready.exists())
        self.assertTrue((self.root / "wifi.off").exists())
        self.assertTrue(self.config.exists())
        for pid in self.starts("supp") + self.starts("dhcp"):
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
        self.assertEqual(self.result(2, "scan"), "off")
        self.stop(proc)
        self.start()
        self.until(lambda: self.status().get("state") == "off")
        time.sleep(.3)
        self.assertEqual(len(self.starts("supp")), 1)
        self.mark("offer")
        self.assertEqual(self.result(3, "on"), "ok")
        self.until(self.ready.exists)
        self.assertFalse((self.root / "wifi.off").exists())
        self.assertEqual(self.result(4, "forget"), "ok")
        self.until(lambda: self.status()["state"] == "idle")
        self.assertEqual(self.status()["saved"], "")
        self.assertFalse(self.config.exists())
        self.assertFalse(self.ready.exists())
        with self.assertRaises(ProcessLookupError):
            os.kill(self.starts("supp")[-1], 0)

    def test_borrowed_connection_refuses_requests(self):
        self.wlan.mkdir()
        self.mark("join")
        self.mark("external")
        self.mark("address")
        (self.run / "baseos-ntp-synchronized").write_text("1794960000\n")
        (self.run / "route").write_text("wlan0")
        self.start()
        self.until(self.ready.exists)
        for number, action in enumerate(("scan", "join", "forget", "off"), 1):
            self.assertEqual(self.result(number, action, "ssid=Other\npsk=12345678\n"), "external")
        self.assertEqual(self.status()["state"], "external")
        self.assertTrue(self.ready.exists() and self.config.exists())
        self.assertEqual(self.starts("supp"), [])


if __name__ == "__main__":
    unittest.main()
