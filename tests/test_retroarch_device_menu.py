"""Test the in-game Device Settings pages on the host.

The mock tests take the role of socket-hardware and the radio workers. The
worker tests use the card workers with the simulated radio tools of
test_wifi.py and test_bluetooth.py.
"""

import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import test_bluetooth  # noqa: E402
import test_wifi  # noqa: E402

MAC = "AA:BB:CC:DD:EE:FF"
OTHER = "11:22:33:44:55:66"
LETTERS = ["1234567890", "qwertyuiop", "asdfghjkl'", "zxcvbnm,.-"]
SYMBOLS = ["1234567890", "!@#$%&*()?", "_+=/\\:;\"~|", "[]{}<>^`,."]
SCAN_HEADER = "bssid / frequency / signal level / flags / ssid\n"
build = None


def setUpModule():
    """Compile the harness with the header names that the RetroArch build uses."""
    global build
    build = tempfile.TemporaryDirectory()
    unittest.addModuleCleanup(build.cleanup)
    include = Path(build.name)
    (include / "features").mkdir()
    (include / "features/features_cpu.h").write_text(
        "#pragma once\n#include <stdint.h>\ntypedef int64_t retro_time_t;\nretro_time_t cpu_features_get_time_usec(void);\n")
    shutil.copy(ROOT / "tools/retroarch-controls.h", include / "socket_controls.h")
    shutil.copy(ROOT / "tools/retroarch-device-menu.h", include / "socket_device_menu.h")
    subprocess.run(["cc", "-std=gnu99", "-Wall", "-Wextra", "-Werror", f"-I{include}",
                    str(ROOT / "tests/retroarch_device_menu_harness.c"), "-o", str(include / "harness")], check=True)


def put(path, text):
    """Replace a file in one step, as the workers do."""
    temporary = path.with_name(path.name + ".test")
    temporary.write_text(text)
    os.replace(temporary, path)


def prop(name, value):
    return f'                  dict entry(\n                     string "{name}"\n                     variant                         {value}\n                  )\n'


def flag(value):
    return "boolean true" if value else "boolean false"


def entry(path, interface, body):
    return (f'      dict entry(\n         object path "{path}"\n         array [\n            dict entry(\n'
            f'               string "{interface}"\n               array [\n{body}               ]\n            )\n         ]\n      )\n')


def device(address, name="", paired=False, connected=False, rssi=True):
    """Return the dbus-send text of one BlueZ device and of its media endpoint."""
    path = "/org/bluez/hci0/dev_" + address.replace(":", "_")
    body = prop("Address", f'string "{address}"') + prop("Alias", f'string "{name or address.replace(":", "-")}"')
    if name:
        body += prop("Name", f'string "{name}"')
    if rssi:
        body += prop("RSSI", "int16 -50")
    body += prop("Paired", flag(paired)) + prop("Connected", flag(connected))
    body += prop("Adapter", 'object path "/org/bluez/hci0"')
    body += prop("UUIDs", 'array [\n                           string "0000110b-0000-1000-8000-00805f9b34fb"\n                        ]')
    return entry(path, "org.bluez.Device1", body) + entry(path + "/sep1", "org.bluez.MediaEndpoint1", prop("Connected", flag(True)))


def bluez(devices="", discovering=False):
    adapter = entry("/org/bluez/hci0", "org.bluez.Adapter1", prop("Powered", flag(True)) + prop("Discovering", flag(discovering)))
    return "method return time=1.0 sender=:1.2 -> destination=:1.9 serial=5 reply_serial=2\n   array [\n" + adapter + devices + "   ]\n"


class Menu:
    """Operate the harness. Each command returns the screen that follows it."""

    def __init__(self, run):
        self.run = run
        # The text that RetroArch writes to its log: status messages and page titles.
        self.messages = []
        self.process = subprocess.Popen([str(Path(build.name) / "harness")], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        text=True, encoding="utf-8", env=dict(os.environ, SOCKET_RUN=str(run)))

    def stop(self):
        self.process.stdin.close()
        self.process.wait(timeout=5)
        self.process.stdout.close()

    def do(self, command):
        self.process.stdin.write(command + "\n")
        self.process.stdin.flush()
        screen = dict(open=False, levels=[], title="", status="", rows=[], selected=None)
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError("The harness stopped")
            kind, text = line[:-1].partition(" ")[::2]
            if kind == "end":
                self.screen = screen
                return screen
            if kind == "message":
                self.messages.append(text)
            elif kind == "open":
                screen["open"] = text == "1"
            elif kind == "level":
                screen["levels"].append(text)
            elif kind.startswith("row"):
                if line[3] == "*":
                    screen["selected"] = len(screen["rows"])
                screen["rows"].append(line[4:-1])
            else:
                screen[kind] = text
                if kind == "title":
                    self.messages.append(text)

    def press(self, *commands):
        for command in commands:
            self.do(command)
        return self.screen

    def poll(self):
        """Move the clock past the poll interval of the page."""
        return self.do("advance 0.3")

    def goto(self, row):
        """Select a row by its number or by the start of its text."""
        rows = self.screen["rows"]
        if isinstance(row, str):
            row = next(index for index, text in enumerate(rows) if text.startswith(row))
        for _ in range((row - self.screen["selected"]) % len(rows)):
            self.do("down")

    def choose(self, row):
        self.goto(row)
        return self.do("ok")

    def type(self, text):
        """Type on the keyboard page. Rows: text, 4 key rows, Caps, symbols, Space."""
        for character in text:
            if character == " ":
                self.choose(7)
                continue
            symbols = not any(character.lower() in row for row in LETTERS)
            if symbols != (self.screen["rows"][6] == "abc"):
                self.choose(6)
            if not symbols and character.isalpha() and character.isupper() != (self.screen["rows"][5] == "CAPS"):
                self.choose(5)
            layout = SYMBOLS if symbols else LETTERS
            row = next(index for index, keys in enumerate(layout) if character.lower() in keys)
            self.goto(1 + row)
            text = self.screen["rows"][1 + row]
            column = next(index for index in range(10) if text[3 * index] == "[" and text[3 * index + 2] == "]")
            for _ in range((layout[row].index(character.lower()) - column) % 10):
                self.do("right")
            self.do("ok")


class MenuCase(unittest.TestCase):
    def menu(self, run):
        menu = Menu(run)
        self.addCleanup(menu.stop)
        return menu

    def wait(self, menu, predicate, message="the screen"):
        """Poll the page until the screen agrees. A worker changes files in real time."""
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if predicate(menu.do("advance 0.26")):
                return
            time.sleep(.03)
        self.fail(f"Timed out waiting for {message}: {menu.screen}")


class MockCase(MenuCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.run = Path(temp.name)
        self.m = self.menu(self.run)

    def read(self, name):
        path = self.run / name
        return path.read_text() if path.exists() else None

    def take(self, name):
        text = self.read(name)
        (self.run / name).unlink()
        return text


class LevelTests(MockCase):
    def levels(self):
        return [text.split()[-1] for text in self.m.do("advance 0.06")["levels"]]

    def request(self, name, value):
        token, actual_name, actual_value = re.fullmatch(r"(\d{1,19}) ([a-z]+) (\d+)\n", self.take("controls.set")).groups()
        self.assertEqual((actual_name, actual_value), (name, str(value)))
        self.assertFalse((self.run / "controls.set.tmp").exists())
        return token

    def test_levels_follow_the_helper_snapshot_and_replies(self):
        self.assertEqual(self.levels(), ["6", "40"])
        put(self.run / "controls", "2 7 40 4 0 0\n")
        self.assertEqual(self.levels(), ["5", "40"])
        # One request at a time. The label shows the level that the helper applied.
        self.m.press("step brightness 1", "step brightness 1", "step volume -1")
        token = self.request("brightness", 6)
        self.assertEqual(self.levels(), ["5", "40"])
        self.assertIsNone(self.read("controls.set"))
        put(self.run / "controls.ack", f"{token} ok 6\n")
        self.assertEqual(self.levels(), ["6", "40"])
        self.assertIsNone(self.read("controls.ack"))
        second = self.request("brightness", 7)
        self.assertGreater(int(second), int(token))
        # A reply for another request changes nothing.
        put(self.run / "controls.ack", f"{token} ok 9\n")
        self.assertEqual(self.levels(), ["6", "40"])
        # An error reply has the level in effect. The next row continues.
        put(self.run / "controls.ack", f"{second} error 6\n")
        self.assertEqual(self.levels(), ["6", "40"])
        put(self.run / "controls.ack", f"{self.request('volume', 35)} ok 35\n")
        self.assertEqual(self.levels(), ["6", "35"])
        self.assertIsNone(self.read("controls.set"))
        # The volume buttons change the snapshot. Zero shows as muted.
        put(self.run / "controls", "2 9 0 9 0 1\n")
        self.assertEqual(self.levels(), ["10", "Muted"])
        self.m.press("step brightness 1", "step volume -1")
        self.assertIsNone(self.read("controls.set"))
        # Without a helper, the labels keep the applied levels.
        self.m.press("step volume 1", "step volume 1")
        self.request("volume", 5)
        self.m.do("advance 0.6")
        self.assertEqual(self.levels(), ["10", "Muted"])
        self.assertIsNone(self.read("controls.set"))
        self.m.do("step volume 1")
        self.request("volume", 5)


class WifiMockTests(MockCase):
    def status(self, number, result, state, saved=""):
        put(self.run / "wifi.status", f"id={number}\nresult={result}\nstate={state}\nsaved={saved}\n")
        return self.m.poll()

    def networks(self):
        put(self.run / "wifi.scan", SCAN_HEADER +
            "02:00:00:00:00:01\t2437\t-70\t[WPA2-PSK-CCMP][ESS]\tCaf\\xc3\\xa9 net\n"
            "02:00:00:00:00:02\t2437\t-40\t[WPA2-PSK-CCMP][ESS]\tCaf\\xc3\\xa9 net\n"
            "02:00:00:00:00:03\t2437\t-50\t[WPA2-SAE-CCMP][ESS]\tNew\n"
            "02:00:00:00:00:04\t2437\t-45\t[ESS]\tFree\\tWiFi\n"
            "02:00:00:00:00:05\t2437\t-30\t[WPA2-PSK-CCMP][ESS]\t\n"
            "02:00:00:00:00:06\t2437\t-30\t[WPA2-PSK-CCMP][ESS]\t\\x00\\x00\n"
            "02:00:00:00:00:07\t2437\n")

    def open_networks(self):
        self.status(4, "ok", "idle")
        screen = self.m.do("open 0")
        self.assertEqual((screen["title"], screen["status"]), ("Wi-Fi", "Wi-Fi is on. No network is saved."))
        self.assertEqual(screen["rows"], ["Wi-Fi                     On", "Choose a network", "Back"])
        screen = self.m.choose("Choose a network")
        # The number is higher than each number that the worker has seen.
        self.assertEqual(self.take("wifi.request"), "5 scan\n")
        self.assertEqual((screen["status"], screen["rows"]), ("Searching for networks...", ["Cancel"]))
        self.networks()
        return self.status(5, "ok", "idle")

    def test_scan_keyboard_join_and_results(self):
        screen = self.open_networks()
        self.assertEqual(screen["rows"], ["Café net  (WPA2)", "Free?WiFi  (Open, not supported)", "New  (WPA3, not supported)",
                                          "Enter network name", "Search again", "Back"])
        self.assertEqual(self.m.choose("New")["status"], "This device joins WPA2-Personal networks only.")
        screen = self.m.choose("Café net")
        self.assertEqual((screen["title"], screen["rows"]), ("Join a network", ["Network: Café net", "Password: ", "Join", "Back"]))
        # A password that the card cannot store stays on the device.
        self.assertIn("8 to 63 characters", self.m.choose("Join")["status"])
        self.assertIsNone(self.read("wifi.request"))
        screen = self.m.choose("Password")
        self.assertEqual((screen["title"], screen["rows"][0], screen["selected"]), ("Password", "_", 2))
        password = 'pa5s Word "#= $HOME'
        self.m.type(password + "x")
        self.assertEqual(self.m.do("back")["rows"][0], "*" * len(password) + "_")
        screen = self.m.choose("Done")
        self.assertEqual((screen["rows"][1], screen["selected"]), ("Password: " + "*" * len(password), 1))
        screen = self.m.choose("Join")
        self.assertEqual(self.take("wifi.request"), "6 join\n")
        candidate = self.run / "wifi.candidate"
        self.assertEqual(candidate.read_text(), f"ssid=Café net\npsk={password}\n")
        self.assertEqual(stat.S_IMODE(candidate.stat().st_mode), 0o600)
        self.assertEqual((screen["status"], screen["rows"]), ("Joining...", ["Network: Café net", "Cancel"]))
        # A failed join keeps the typed password and offers the saved network.
        screen = self.status(6, "auth", "connecting", "Home")
        self.assertEqual(screen["status"], "The network rejected the password.")
        self.assertEqual(screen["rows"], ["Network: Café net", "Password: " + "*" * len(password), "Join", "Reconnect to Home", "Back"])
        self.m.choose("Join")
        self.assertEqual(self.take("wifi.request"), "7 join\n")
        # Back asks the worker to cancel. The result shows if the join was complete.
        self.m.do("back")
        self.assertEqual(self.take("wifi.request"), "8 cancel\n")
        screen = self.status(8, "ok", "connecting", "Home")
        self.assertEqual((screen["status"], screen["rows"][1]), ("Canceled.", "Password: " + "*" * len(password)))
        self.m.choose("Join")
        self.m.do("back")
        self.assertEqual(self.take("wifi.request"), "10 cancel\n")
        screen = self.status(10, "ok", "connected", "Café net")
        self.assertEqual(screen["status"], "Connected.")
        self.assertEqual(screen["rows"], ["Wi-Fi                     On", "Network: Café net", "Choose a network", "Forget Café net", "Back"])
        # The password is not in a message or in a row after the join.
        self.assertFalse(any("Word" in text for text in self.m.messages))
        self.m.choose("Choose a network")
        self.status(11, "ok", "connected", "Café net")
        self.assertEqual(self.m.choose("Café net")["rows"][1], "Password: ")

    def test_hidden_network_forget_power_and_external(self):
        self.open_networks()
        screen = self.m.choose("Enter network name")
        self.assertEqual((screen["title"], screen["rows"]), ("Join a hidden network", ["Network name: ", "Password: ", "Join", "Back"]))
        self.m.choose("Network name")
        self.m.type("My [Net] 2")
        self.assertEqual(self.m.choose(0)["rows"][0], "Network name: My [Net] 2")
        self.m.choose("Password")
        self.m.type("g" * 70)
        self.assertEqual(self.m.choose("Done")["rows"][1], "Password: " + "*" * 64)
        self.assertIn("64 characters must be a key", self.m.choose("Join")["status"])
        self.m.choose("Password")
        self.m.press(*["back"] * 64)
        self.m.type("12345678")
        self.m.choose("Done")
        self.m.choose("Join")
        self.assertEqual(self.read("wifi.candidate"), "ssid=My [Net] 2\npsk=12345678\n")
        screen = self.status(6, "ok", "connected", "My [Net] 2")
        self.assertEqual(screen["rows"][1:4:2], ["Network: My [Net] 2", "Forget My [Net] 2"])
        # Forget needs a confirmation. The selection starts on Cancel.
        screen = self.m.choose("Forget")
        self.assertEqual((screen["rows"], screen["selected"]), (["Network: My [Net] 2", "Cancel", "Forget"], 1))
        self.take("wifi.request")
        self.m.choose("Cancel")
        self.assertIsNone(self.read("wifi.request"))
        self.m.choose("Forget")
        self.m.choose("Forget")
        self.assertEqual(self.take("wifi.request"), "7 forget\n")
        screen = self.status(7, "ok", "idle")
        self.m.choose("Wi-Fi")
        self.assertEqual(self.take("wifi.request"), "8 off\n")
        screen = self.status(8, "ok", "off", "Home")
        self.assertEqual((screen["status"], screen["rows"]), ("Wi-Fi is off.", ["Wi-Fi                     Off", "Saved network: Home", "Back"]))
        self.m.choose("Wi-Fi")
        self.assertEqual(self.take("wifi.request"), "9 on\n")
        screen = self.status(9, "ok", "connecting", "Home")
        self.assertEqual(screen["rows"], ["Wi-Fi                     On", "Network: Home", "Choose a network", "Retry", "Forget Home", "Back"])
        self.m.choose("Retry")
        self.assertEqual(self.take("wifi.request"), "10 reconnect\n")
        for state, text in (("external", "BaseOS manages Wi-Fi on this device."), ("", "Wi-Fi is not available.")):
            screen = self.status(10, "ok", state)
            self.assertEqual((screen["status"], screen["rows"]), (text, ["Back"]))
        self.assertFalse(self.m.do("ok")["open"])

    def test_back_menu_sleep_and_timeout_clean_up(self):
        def typed():
            self.m.choose("Café net")
            self.m.choose("Password")
            self.m.type("secret-pass")
            self.m.choose("Done")

        self.open_networks()
        typed()
        # Back from the form discards the password.
        self.assertEqual(self.m.do("back")["title"], "Choose a network")
        self.assertEqual(self.m.choose("Café net")["rows"][1], "Password: ")
        # MENU during a join: the menu closes the page.
        self.m.do("back")
        typed()
        self.m.choose("Join")
        self.take("wifi.request")
        self.m.do("close")
        self.assertEqual(self.take("wifi.request"), "7 cancel\n")
        self.assertIsNone(self.read("wifi.candidate"))
        self.m.do("close")
        self.assertIsNone(self.read("wifi.request"))
        # Sleep on the keyboard page: back to the first page, no typed text.
        self.status(7, "canceled", "idle")
        self.m.do("open 0")
        self.m.choose("Choose a network")
        self.networks()
        self.status(8, "ok", "idle")
        typed()
        self.m.choose("Password")
        (self.run / "shallow.sleep").touch()
        screen = self.m.poll()
        self.assertEqual((screen["title"], screen["rows"][0]), ("Wi-Fi", "Wi-Fi                     On"))
        (self.run / "shallow.sleep").unlink()
        self.m.choose("Choose a network")
        self.status(9, "ok", "idle")
        self.assertEqual(self.m.choose("Café net")["rows"][1], "Password: ")
        # A scan that gets no answer stops. So does a join, and its password file goes.
        self.m.press("back", "back")
        self.m.choose("Choose a network")
        self.assertEqual(self.take("wifi.request"), "10 scan\n")
        screen = self.m.do("advance 31")
        self.assertEqual((screen["title"], screen["status"]), ("Wi-Fi", "Wi-Fi did not answer. Try again. Wi-Fi is on. No network is saved."))
        self.assertEqual(self.take("wifi.request"), "11 cancel\n")
        self.m.choose("Choose a network")
        self.status(12, "ok", "idle")
        typed()
        self.m.choose("Join")
        screen = self.m.do("advance 91")
        self.assertEqual((screen["title"], screen["status"]), ("Join a network", "Wi-Fi did not answer. Try again."))
        self.assertIsNone(self.read("wifi.candidate"))
        # A late result of the join that timed out changes nothing.
        self.assertEqual(self.status(13, "ok", "connected", "Café net")["title"], "Join a network")
        # Back from the first page closes it.
        self.m.press("back", "back")
        self.assertFalse(self.m.do("back")["open"])
        self.assertFalse(any("secret" in text for text in self.m.messages))


class BluetoothMockTests(MockCase):
    def setUp(self):
        super().setUp()
        put(self.run / "bluetooth.status", "on\n")
        put(self.run / "bluetooth.log", "# 100 1\nready\n")
        self.paired = device(OTHER, "Pad", paired=True, rssi=False)
        self.near = device(MAC, "Buds") + device("00:00:00:00:00:01") + device("00:00:00:00:00:02", "Far", rssi=False)
        put(self.run / "bluetooth.state", bluez(self.paired))

    def requests(self):
        """Return and remove the requests, in the sequence that the worker uses."""
        files = sorted(self.run.glob("bluetooth.request.*"))
        lines = [path.read_text() for path in files]
        for path in files:
            path.unlink()
        self.assertTrue(all(line.endswith("\n") and line.count("\n") == 1 for line in lines), lines)
        return [line[:-1] for line in lines]

    def event(self, text):
        with (self.run / "bluetooth.log").open("a") as log:
            log.write(text + "\n")
        return self.m.poll()

    def confirm(self):
        """Open the page, find the accessory and stop at the Pair question."""
        screen = self.m.do("open 1")
        self.assertEqual(self.requests(), ["open"])
        self.assertEqual((screen["title"], screen["status"]), ("Bluetooth", "Bluetooth is on."))
        self.assertEqual(screen["rows"], ["Bluetooth                 On", "Pad (55:66): Paired", "Add accessory", "Back"])
        self.m.choose("Add accessory")
        screen = self.m.poll()
        self.assertEqual(self.requests(), ["scan on"])
        self.assertEqual((screen["status"], screen["rows"]), ("Searching... Put the accessory in pairing mode.", ["Cancel"]))
        put(self.run / "bluetooth.state", bluez(self.paired + self.near, discovering=True))
        # Only a named accessory that is in range and not paired is in the list.
        self.assertEqual(self.m.poll()["rows"], ["Buds (EE:FF)", "Cancel"])
        screen = self.m.choose("Buds")
        # The selection names the target. It sends nothing.
        self.assertEqual((screen["status"], screen["rows"]), ("Pair with this accessory?", ["Buds (EE:FF)", "Pair", "Cancel"]))
        self.assertEqual(self.requests(), [])

    def pair(self):
        self.confirm()
        screen = self.m.choose("Pair")
        self.assertEqual(self.requests(), ["scan off", f"pair {MAC}"])
        self.assertEqual((screen["status"], screen["rows"]), ("Pairing...", ["Buds (EE:FF)", "Cancel"]))

    def test_pair_with_code_confirmation_and_connect(self):
        self.pair()
        # A prompt or a result for another accessory changes nothing.
        for line in (f"prompt confirm {OTHER} 111111", f"result pair {OTHER} ok", f"result connect {MAC} ok",
                     f"prompt menu {MAC} 1", "prompt confirm", f"prompt confirm {MAC}", "x" * 600 + f" prompt confirm {MAC} 5"):
            self.assertEqual(self.event(line)["rows"], ["Buds (EE:FF)", "Cancel"], line)
        self.assertEqual(self.requests(), [])
        screen = self.event(f"prompt confirm {MAC} 123456")
        self.assertEqual(screen["status"], "Does the accessory show this code?")
        # The first row has no action, so a press that is too early accepts nothing.
        self.assertEqual((screen["rows"], screen["selected"]), (["Buds (EE:FF)", "Code: 123456", "Accept", "Reject", "Cancel"], 0))
        self.m.do("ok")
        self.assertEqual(self.requests(), [])
        self.assertEqual(self.m.choose("Accept")["rows"], ["Buds (EE:FF)", "Cancel"])
        self.assertEqual(self.requests(), ["answer yes"])
        screen = self.event(f"result pair {MAC} ok")
        self.assertEqual(self.requests(), [f"trust {MAC}", f"connect {MAC}"])
        self.assertEqual(screen["status"], "Connecting...")
        put(self.run / "bluetooth.state", bluez(self.paired + device(MAC, "Buds", paired=True, connected=True)))
        screen = self.event(f"result connect {MAC} ok")
        self.assertEqual((screen["title"], screen["status"]), ("Accessory", "Connected."))
        self.assertEqual((screen["rows"], screen["selected"]), (["Buds (EE:FF)", "Disconnect", "Forget", "Back"], 1))
        self.m.choose("Disconnect")
        self.assertEqual(self.requests(), [f"disconnect {MAC}"])
        # Forget needs a confirmation. The selection starts on Cancel.
        self.assertEqual(self.m.choose("Forget")["rows"], ["Buds (EE:FF)", "Cancel", "Forget"])
        self.m.do("ok")
        self.assertEqual(self.requests(), [])
        self.m.choose("Forget")
        self.assertIn("Buds (EE:FF): Connected", self.m.choose("Forget")["rows"])
        self.assertEqual(self.requests(), [f"remove {MAC}"])
        # The pairing code is on a row only.
        self.assertFalse(any("123456" in text for text in self.m.messages))

    def test_code_entry_reject_and_failures(self):
        self.pair()
        screen = self.event(f"prompt passkey {MAC}")
        self.assertEqual(screen["rows"], ["Buds (EE:FF)", "Code: _", " 0  1  2  3  4  5  6  7  8  9 ", "Cancel"])
        self.m.goto(2)
        self.m.press("ok", "left", "ok", "right", "right", "ok", "ok", "ok", "ok", "ok", "ok")
        # A passkey has 6 digits. B deletes one digit.
        self.assertEqual(self.m.screen["rows"][1], "Code: 091111_")
        self.assertEqual(self.m.do("back")["rows"], ["Buds (EE:FF)", "Code: 09111_", " 0 [1] 2  3  4  5  6  7  8  9 ", "Submit", "Cancel"])
        self.assertEqual(self.m.choose("Submit")["rows"], ["Buds (EE:FF)", "Cancel"])
        self.assertEqual(self.requests(), ["answer 09111"])
        self.assertFalse(any("09111" in text for text in self.m.messages))
        screen = self.event(f"result pair {MAC} error org.bluez.Error.AuthenticationFailed")
        self.assertEqual((screen["status"], screen["rows"]), ("The code was wrong or the accessory refused.", ["Buds (EE:FF)", "Cancel"]))
        # Display and reject.
        self.m.choose("Buds")
        self.m.choose("Pair")
        screen = self.event(f"prompt display {MAC} 654321")
        self.assertEqual((screen["status"], screen["rows"]), ("Type this code on the accessory. Then press Enter on it.", ["Buds (EE:FF)", "Code: 654321", "Cancel"]))
        self.assertEqual(self.event("canceled")["rows"], ["Buds (EE:FF)", "Cancel"])
        self.event(f"prompt confirm {MAC} 000001")
        self.m.choose("Reject")
        self.requests()
        self.assertEqual(self.event(f"result pair {MAC} error org.bluez.Error.Failed")["status"], "Pairing failed.")
        # An accessory with a bond goes on to connect. A failed connection offers Connect.
        self.m.choose("Buds")
        self.m.choose("Pair")
        self.requests()
        self.event(f"result pair {MAC} error org.bluez.Error.AlreadyExists")
        self.assertEqual(self.requests(), [f"trust {MAC}", f"connect {MAC}"])
        screen = self.event(f"result connect {MAC} error org.bluez.Error.Failed")
        self.assertEqual((screen["status"], screen["rows"]), ("Could not connect.", ["Buds (EE:FF)", "Connect", "Forget", "Back"]))
        self.m.choose("Connect")
        self.assertEqual(self.requests(), [f"connect {MAC}"])

    def test_back_menu_sleep_and_timeout_clean_up(self):
        self.pair()
        self.event(f"prompt pin {MAC}")
        self.m.goto(2)
        self.m.do("ok")
        # Back with an empty code cancels the attempt: the worker replaces the agent.
        self.m.do("back")
        self.assertEqual(self.requests(), [])
        screen = self.m.do("back")
        self.assertEqual(self.requests(), ["reset"])
        self.assertEqual((screen["status"], screen["rows"]), ("Canceled.", ["Buds (EE:FF)", "Cancel"]))
        # A result of the canceled attempt changes nothing.
        self.assertEqual(self.event(f"result pair {MAC} ok")["rows"], ["Buds (EE:FF)", "Cancel"])
        self.assertEqual(self.requests(), [])
        # A new agent ends the attempt of the agent before it.
        self.m.choose("Buds")
        self.m.choose("Pair")
        self.requests()
        put(self.run / "bluetooth.log", "# 100 2\nready\n")
        self.assertEqual(self.m.poll()["status"], "Interrupted.")
        # No answer from the accessory.
        self.m.choose("Buds")
        self.m.choose("Pair")
        self.requests()
        self.assertEqual(self.m.do("advance 61")["status"], "The accessory did not respond.")
        self.assertEqual(self.requests(), ["reset"])
        # Back from the search stops it.
        self.m.do("back")
        self.assertEqual(self.requests(), ["scan off"])
        # MENU during pairing: the worker stops the agent.
        self.m.choose("Add accessory")
        self.m.poll()
        self.m.choose("Buds")
        self.m.choose("Pair")
        self.event(f"prompt confirm {MAC} 123456")
        self.requests()
        self.m.do("close")
        self.assertEqual(self.requests(), ["close"])
        self.m.do("close")
        self.assertEqual(self.requests(), [])
        # Sleep during pairing: one cleanup, and the page shows its first view.
        self.m.do("open 1")
        self.m.choose("Add accessory")
        self.m.poll()
        self.m.choose("Buds")
        self.m.choose("Pair")
        self.requests()
        (self.run / "shallow.sleep").touch()
        self.assertEqual(self.m.poll()["rows"][0], "Bluetooth                 On")
        self.m.poll()
        self.assertEqual(self.requests(), ["close", "open"])
        (self.run / "shallow.sleep").unlink()
        # Back from the first view closes the page.
        self.assertFalse(self.m.do("back")["open"])
        self.assertEqual(self.requests(), ["close"])

    def test_power_states(self):
        put(self.run / "bluetooth.status", "off\n")
        screen = self.m.do("open 1")
        self.assertEqual((screen["status"], screen["rows"]), ("Bluetooth is off.", ["Bluetooth                 Off", "Back"]))
        self.m.do("ok")
        self.assertEqual(self.requests(), ["open", "on"])
        put(self.run / "bluetooth.status", "starting\n")
        self.assertEqual(self.m.poll()["rows"], ["Bluetooth                 Turning on...", "Back"])
        put(self.run / "bluetooth.status", "unavailable\n")
        screen = self.m.poll()
        self.assertEqual((screen["status"], screen["rows"]), ("Bluetooth is unavailable.", ["Try again", "Back"]))
        # The worker gives the cause. The rows show all of it. Try again stays.
        cause = "The Bluetooth radio did not turn on (org.bluez.Error.Blocked). Restart the device, then try again."
        put(self.run / "bluetooth.error", cause + "\n")
        put(self.run / "bluetooth.status", "starting\n")
        self.m.poll()
        put(self.run / "bluetooth.status", "unavailable\n")
        screen = self.m.poll()
        self.assertEqual(screen["status"], "Bluetooth is unavailable. The cause is also in Logs/socket-bluetooth.log.")
        self.assertEqual(" ".join(screen["rows"][:-2]), cause)
        self.assertTrue(all(len(row) <= 48 for row in screen["rows"]), screen["rows"])
        self.assertEqual((screen["rows"][-2:], screen["selected"]), (["Try again", "Back"], len(screen["rows"]) - 2))
        put(self.run / "bluetooth.error", "x" * 300 + "\u0007 y\n")
        self.assertEqual(self.m.poll()["rows"], ["x" * 48] * 3 + ["x" * 16, "Try again", "Back"])
        self.m.do("ok")
        self.assertEqual(self.requests(), ["on"])
        put(self.run / "bluetooth.status", "on\n")
        self.m.poll()
        self.m.choose("Add accessory")
        # The radio stops while a subpage is open.
        (self.run / "bluetooth.status").unlink()
        screen = self.m.poll()
        self.assertEqual((screen["status"], screen["rows"]), ("Bluetooth is unavailable.", ["Back"]))


class PrivacyTests(MockCase):
    def test_user_data_stays_out_of_the_retroarch_log(self):
        """Show each view that has user data. Only rows can have it."""
        seen = []

        def look(screen):
            seen.extend(screen["rows"])
            return screen

        put(self.run / "wifi.status", "id=1\nresult=ok\nstate=connected\nsaved=SENTINEL-HOME\n")
        look(self.m.do("open 0"))
        look(self.m.choose("Forget"))
        self.m.do("back")
        self.m.choose("Choose a network")
        put(self.run / "wifi.scan", SCAN_HEADER + "02:00:00:00:00:01\t2437\t-40\t[WPA2-PSK-CCMP][ESS]\tSENTINEL-NET\n"
            "02:00:00:00:00:02\t2437\t-50\t[ESS]\tSENTINEL-OPEN\n")
        put(self.run / "wifi.status", "id=2\nresult=ok\nstate=connected\nsaved=SENTINEL-HOME\n")
        look(self.m.poll())
        look(self.m.choose("SENTINEL-OPEN"))
        look(self.m.choose("SENTINEL-NET"))
        self.m.choose("Password")
        self.m.type("SENTINEL-KEY")
        look(self.m.screen)
        self.m.choose("Done")
        look(self.m.choose("Join"))
        self.assertEqual(self.read("wifi.candidate"), "ssid=SENTINEL-NET\npsk=SENTINEL-KEY\n")
        put(self.run / "wifi.status", "id=3\nresult=auth\nstate=connecting\nsaved=SENTINEL-HOME\n")
        look(self.m.poll())
        self.m.choose("Join")
        look(self.m.do("advance 91"))
        for state in ("off", "connecting"):
            put(self.run / "wifi.status", f"id=9\nresult=ok\nstate={state}\nsaved=SENTINEL-HOME\n")
            self.m.do("close")
            look(self.m.do("open 0"))
        self.m.do("close")

        put(self.run / "bluetooth.status", "on\n")
        put(self.run / "bluetooth.log", "# 100 1\nready\n")
        put(self.run / "bluetooth.state", bluez(device(OTHER, "SENTINEL-PAD", paired=True) + device(MAC, "SENTINEL-BUDS"), True))
        look(self.m.do("open 1"))
        look(self.m.choose("SENTINEL-PAD"))
        look(self.m.choose("Forget"))
        self.m.press("back", "back")
        self.m.choose("Add accessory")
        look(self.m.poll())
        look(self.m.choose("SENTINEL-BUDS"))
        look(self.m.choose("Pair"))
        for prompt in (f"prompt confirm {MAC} 424242", f"prompt display {MAC} 424242", f"prompt passkey {MAC}"):
            with (self.run / "bluetooth.log").open("a") as log:
                log.write(prompt + "\n")
            look(self.m.poll())
        self.m.goto(2)
        self.m.press("right", "right", "right", "right", "ok", "left", "left", "ok", "right", "right", "ok", "left", "left", "ok")
        look(self.m.screen)
        look(self.m.choose("Submit"))
        with (self.run / "bluetooth.log").open("a") as log:
            log.write(f"result pair {MAC} error org.bluez.Error.AuthenticationFailed\n")
        look(self.m.poll())
        put(self.run / "bluetooth.status", "unavailable\n")
        put(self.run / "bluetooth.error", "SENTINEL-CAUSE\n")
        look(self.m.poll())
        self.m.do("close")
        self.assertIn("answer 4242\n", [path.read_text() for path in self.run.glob("bluetooth.request.*")])
        # The views did show the data, and the log text has none of it.
        for text in ("SENTINEL-HOME", "SENTINEL-NET", "SENTINEL-OPEN", "SENTINEL-PAD (55:66)", "SENTINEL-BUDS (EE:FF)",
                     "Code: 424242", "Code: 4242_", "SENTINEL-CAUSE"):
            self.assertTrue(any(text in row for row in seen), text)
        self.assertFalse(any("SENTINEL-KEY" in row for row in seen))
        self.assertGreater(len(self.m.messages), 30)
        for text in self.m.messages:
            for private in ("SENTINEL", "55:66", "EE:FF", "4242"):
                self.assertNotIn(private, text)


class WifiWorkerTests(MenuCase):
    @classmethod
    def setUpClass(cls):
        test_wifi.WifiWorkerTests.setUpClass()
        cls.addClassCleanup(test_wifi.WifiWorkerTests.doClassCleanups)

    def test_scan_join_wrong_password_and_cancel(self):
        radio = test_wifi.WifiWorkerTests("setUp")
        radio.setUp()
        self.addCleanup(radio.doCleanups)
        radio.config = radio.root / "Config/wifi.txt"
        radio.wlan.mkdir()
        radio.start()
        m = self.menu(radio.run)
        m.do("open 0")
        self.wait(m, lambda screen: screen["status"] == "Wi-Fi is on. No network is saved.")
        m.choose("Choose a network")
        radio.until(lambda: radio.starts("supp"))
        (radio.run / "aps").write_text("02:00:00:00:00:01\t2437\t-50\t[WPA2-PSK-CCMP][ESS]\tCaf\\xc3\\xa9 net\n"
                                       "02:00:00:00:00:02\t2437\t-60\t[WPA2-PSK-CCMP][ESS]\tOther\n")
        self.wait(m, lambda screen: screen["rows"][:2] == ["Café net  (WPA2)", "Other  (WPA2)"])

        def join(network, password):
            m.choose(network)
            m.choose("Password")
            m.type(password)
            m.choose("Done")
            started = len(radio.starts("supp"))
            m.choose("Join")
            radio.until(lambda: len(radio.starts("supp")) == started + 1)
            self.assertEqual(radio.supplicant_ssid(), network)

        password = 'pass word "#= $HOME'
        join("Café net", password)
        self.assertFalse(radio.config.exists())
        radio.mark("join")
        radio.mark("offer")
        (radio.run / "route").write_text("wlan0")
        self.wait(m, lambda screen: screen["status"] == "Connected." and "Network: Café net" in screen["rows"])
        saved = radio.config.read_text()
        self.assertTrue(saved.endswith(f"ssid=Café net\npsk={password}\n"))
        self.assertFalse((radio.run / "wifi.candidate").exists())

        # A wrong password for another network keeps the saved network.
        m.choose("Choose a network")
        self.wait(m, lambda screen: "Other  (WPA2)" in screen["rows"])
        (radio.run / "join").unlink()
        join("Other", "wrong-password")
        radio.mark("wrong-key")
        self.wait(m, lambda screen: screen["status"] == "The network rejected the password.")
        self.assertEqual(m.screen["rows"][3], "Reconnect to Café net")
        (radio.run / "wrong-key").unlink()
        # A canceled join also keeps it. The worker returns to the saved network.
        started = len(radio.starts("supp"))
        m.choose("Join")
        radio.until(lambda: len(radio.starts("supp")) == started + 1)
        m.do("back")
        self.wait(m, lambda screen: screen["status"] == "Canceled.")
        radio.until(lambda: radio.supplicant_ssid() == "Café net")
        # MENU during a join stops it.
        started = len(radio.starts("supp"))
        m.choose("Join")
        radio.until(lambda: len(radio.starts("supp")) == started + 1 and radio.supplicant_ssid() == "Other")
        m.do("close")
        radio.until(lambda: radio.supplicant_ssid() == "Café net")
        radio.mark("join")
        radio.mark("offer")
        radio.until(radio.ready.exists)
        self.assertEqual(radio.config.read_text(), saved)
        self.assertFalse((radio.run / "wifi.candidate").exists())
        # Forget removes the saved network.
        m.do("open 0")
        self.wait(m, lambda screen: screen["status"] == "Connected." and "Network: Café net" in screen["rows"])
        m.choose("Forget")
        m.choose("Forget")
        self.wait(m, lambda screen: screen["status"] == "Wi-Fi is on. No network is saved.")
        self.assertFalse(radio.config.exists())
        for secret in (password, "wrong-password"):
            self.assertNotIn(secret, radio.log.read_text())
            self.assertFalse(any(secret in text for text in m.messages))


class BluetoothWorkerTests(MenuCase):
    def test_pair_connect_and_cleanup(self):
        radio = test_bluetooth.BluetoothWorkerTests("setUp")
        radio.setUp()
        self.addCleanup(radio.doCleanups)
        # The simulated BlueZ has one accessory in range.
        radio.env["ADAPTER"] = (test_bluetooth.ADAPTER + "               ]\n            )\n         ]\n      )\n"
                                + device(MAC, "Buds") + "   ]\n")
        radio.start()
        radio.status("off")
        m = self.menu(radio.run)
        log = radio.run / "bluetooth.log"

        def event(text):
            with log.open("a") as file:
                file.write(text + "\n")

        def sent(command):
            self.wait(m, lambda screen: command in radio.commands(), command)

        self.assertEqual(m.do("open 1")["rows"], ["Bluetooth                 Off", "Back"])
        m.do("ok")
        self.wait(m, lambda screen: screen["rows"][0] == "Bluetooth                 On")
        m.choose("Add accessory")
        sent("scan on")
        self.wait(m, lambda screen: screen["rows"][0] == "Buds (EE:FF)")
        m.choose("Buds")
        time.sleep(.3)
        self.assertNotIn(f"pair {MAC}", radio.commands())
        m.choose("Pair")
        sent(f"pair {MAC}")
        event(f"prompt confirm {MAC} 123456")
        self.wait(m, lambda screen: screen["rows"][1] == "Code: 123456")
        m.choose("Accept")
        sent("answer yes")
        event(f"result pair {MAC} ok")
        sent(f"connect {MAC}")
        self.assertEqual(radio.commands()[-5:], ["scan off", f"pair {MAC}", "answer yes", f"trust {MAC}", f"connect {MAC}"])
        event(f"result connect {MAC} ok")
        self.wait(m, lambda screen: screen["status"] == "Connected.")
        # Back during an attempt replaces the agent.
        m.choose("Connect")
        self.assertEqual(len(radio.pids()), 1)
        m.do("back")
        radio.until(lambda: len(radio.pids()) == 2 and radio.gone(radio.pids()[0]))
        self.wait(m, lambda screen: screen["status"] == "Canceled.")
        # MENU during an attempt stops the agent.
        m.choose("Connect")
        radio.until(lambda: radio.commands()[-1] == f"connect {MAC}")
        m.do("close")
        radio.until(lambda: radio.gone(radio.pids()[1]))
        time.sleep(.2)
        self.assertEqual(len(radio.pids()), 2)
        def discover():
            scans = radio.commands().count("scan on")
            m.choose("Add accessory")
            self.wait(m, lambda screen: radio.commands().count("scan on") == scans + 1, "scan on")
            return scans + 1

        # The agent owns the discovery in BlueZ. Sleep during a search stops the agent.
        m.do("open 1")
        radio.until(lambda: len(radio.pids()) == 3)
        scans = discover()
        (radio.run / "shallow.sleep").touch()
        radio.until(lambda: radio.gone(radio.pids()[2]))
        self.assertEqual(m.do("advance 0.3")["title"], "Bluetooth")
        (radio.run / "shallow.sleep").unlink()
        radio.until(lambda: len(radio.pids()) == 4)
        # After wake, the new agent gets no search request until the user starts one.
        self.wait(m, lambda screen: screen["rows"][0] == "Bluetooth                 On")
        time.sleep(.3)
        m.poll()
        self.assertEqual(radio.commands().count("scan on"), scans)
        # MENU during a search stops the agent also.
        discover()
        m.do("close")
        radio.until(lambda: radio.gone(radio.pids()[3]))
        time.sleep(.2)
        self.assertEqual(len(radio.pids()), 4)
        m.do("open 1")
        radio.until(lambda: len(radio.pids()) == 5)
        m.choose("Bluetooth")
        radio.status("off")
        self.wait(m, lambda screen: screen["rows"] == ["Bluetooth                 Off", "Back"])


if __name__ == "__main__":
    unittest.main()
