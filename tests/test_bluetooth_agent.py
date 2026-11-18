"""Check socket-bluetooth-agent and the card worker with real D-Bus tools in Docker.

Set SOCKET_TEST_BLUETOOTH_DOCKER=1 to run it. It needs Docker and a network connection.
"""

import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
MAC = "AA:BB:CC:DD:EE:FF"


@unittest.skipUnless(os.environ.get("SOCKET_TEST_BLUETOOTH_DOCKER") == "1", "Set SOCKET_TEST_BLUETOOTH_DOCKER=1")
class BluetoothAgentTests(unittest.TestCase):
    def test_agent_and_worker_with_a_fake_bluez(self):
        output = subprocess.run(["docker", "run", "--rm", "-v", f"{ROOT}:/repo:ro", "ubuntu:22.04", "sh",
                                 "/repo/tests/bluetooth_agent_check.sh"], capture_output=True, text=True, timeout=600).stdout
        agent, fake, worker, worker_fake = (part.strip().split("\n") for part in output.split("--- ")[1:])
        ok = f"result pair {MAC} ok"
        self.assertEqual(agent[1:], [
            "ready",
            # A request for another device is rejected. The target continues.
            "# stranger", "rejected /org/bluez/hci0/dev_11_22_33_44_55_66 RequestConfirmation",
            "rejected /org/bluez/hci0/dev_11_22_33_44_55_66 RequestAuthorization", f"prompt confirm {MAC} 123456", ok,
            "# pin", f"prompt pin {MAC}", ok,
            "# passkey", f"prompt passkey {MAC}", ok,
            "# display", f"prompt display {MAC} 654321", f"prompt display {MAC} 4321", ok,
            "# authorize", ok,
            "# service", ok,
            "# after", ok,
            "# hang", f"prompt confirm {MAC} 111111", "canceled",
            "# reject", f"prompt confirm {MAC} 123456", f"result pair {MAC} error org.bluez.Error.AuthenticationFailed",
            "# commands", f"result trust {MAC} ok", f"result connect {MAC} error org.bluez.Error.Failed",
            f"result disconnect {MAC} ok", f"result remove {MAC} ok", "result scan on ok", "result scan off ok",
            "# end of input", f"prompt pin {MAC}", "rejected sender RequestAuthorization"])
        self.assertEqual(output.split("\n")[:2], ["foreign-sender=org.bluez.Error.Rejected", "agent-exit=0"])
        self.assertIn("FAKE register /socket/agent KeyboardDisplay", fake)
        self.assertIn("FAKE default /socket/agent", fake)
        self.assertEqual([line for line in fake if "stranger" in line.lower()],
                         ["FAKE pair stranger", "FAKE stranger-refused org.bluez.Error.Rejected",
                          "FAKE stranger-auth-refused org.bluez.Error.Rejected"])
        # The target stays selected after Pair, for a request before Connect.
        self.assertIn("FAKE after-pair-authorized", fake)
        self.assertIn("FAKE agent-reply (dbus.String('0000'),)", fake)
        self.assertIn("FAKE agent-reply (dbus.UInt32(123456),)", fake)
        # The agent exits at end of input and gives no code to a pending prompt.
        # The withdrawn request of "hang" also ends without a reply.
        self.assertEqual(fake[-3:], ["FAKE pair pin"] + ["FAKE agent-error org.freedesktop.DBus.Error.NoReply"] * 2)

        self.assertEqual(worker[1], "status=on")
        self.assertRegex(worker[2], r"^# \d+ 2$")
        self.assertEqual(worker[3:], ["ready", f"prompt passkey {MAC}", ok, "state-devices=1",
                                      "left=bluetooth.asound", "stderr="])
        # Reset during the PIN prompt cancels it. BlueZ gets no code.
        self.assertEqual(worker_fake[1:], [
            "FAKE set Powered 1", "FAKE register /socket/agent KeyboardDisplay", "FAKE default /socket/agent",
            "FAKE pair confirm", "FAKE agent-reply ()", "FAKE pair pin",
            "FAKE agent-error org.freedesktop.DBus.Error.NoReply",
            "FAKE register /socket/agent KeyboardDisplay", "FAKE default /socket/agent",
            "FAKE pair passkey", "FAKE agent-reply (dbus.UInt32(123456),)"])


if __name__ == "__main__":
    unittest.main()
