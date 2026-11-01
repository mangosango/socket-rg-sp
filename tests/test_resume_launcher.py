"""Check persistent resume records and save acknowledgments at the shell boundary."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "card/System/socket"


class ResumeLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.run = self.root / "run"
        self.run.mkdir()
        self.system = self.root / "system"
        self.system.mkdir()
        (self.system / "cores").mkdir()
        (self.system / "cores/mgba_libretro.so").touch()
        self.rom = self.root / "Game with spaces.gba"
        self.rom.write_bytes(b"fixture")
        self.record = self.root / "resume-game"
        self.bins = self.root / "bin"
        self.bins.mkdir()
        (self.bins / "sync").write_text("#!/bin/sh\nexit 0\n")
        (self.bins / "sync").chmod(0o755)
        self.env = dict(os.environ, SOCKET_RUN=str(self.run),
                        SOCKET_RESUME_MANIFEST=str(self.record), SOCKET_LOGS=str(self.root / "logs"),
                        PATH=str(self.bins) + ":" + os.environ["PATH"])
        self.env.pop("SOCKET_FRONTEND_PID", None)
        for name in ("resume_game.sh", "play_game.sh", "poweroff_ready.sh"):
            (self.system / name).write_text((SCRIPTS / name).read_text())

    def invoke(self, name, *args):
        return subprocess.run(["sh", str(self.system / name), *args], env=self.env,
                              capture_output=True, text=True, timeout=5)

    def descriptor(self):
        return f"socket-resume-v1\nmgba\n{self.rom}\ngba\n"

    def test_boot_reads_data_once_without_shell_evaluation(self):
        self.rom = self.root / 'Game $(touch injected); name.gba'
        self.rom.touch()
        self.record.write_text(self.descriptor())
        (self.system / "play_game.sh").write_text(
            'printf "%s\\n" "$SOCKET_RESUME_LOAD" "$@" > "$SOCKET_RUN/args"\nexit 7\n')
        result = self.invoke("resume_game.sh")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual((self.run / "args").read_text().splitlines(), ["1", "mgba", str(self.rom), "gba"])
        self.assertFalse(self.record.exists())
        self.assertEqual(self.record.with_suffix(".attempt").read_text(), self.descriptor())
        (self.run / "args").unlink()
        self.assertEqual(self.invoke("resume_game.sh").returncode, 0)
        self.assertFalse((self.run / "args").exists(), "A failed restore must not loop on the next boot")
        self.assertFalse((self.root / "injected").exists())

    def test_bad_or_missing_content_record_does_not_launch(self):
        (self.system / "play_game.sh").write_text('touch "$SOCKET_RUN/launched"\n')
        good = self.descriptor()
        for value in (good.rstrip("\n"), good + "extra\n", good + "partial", good.replace("mgba", "../mgba"),
                      good.replace("gba\n", "gba\r\n"), good.replace(str(self.rom), "/missing.gba"),
                      good.replace("socket-resume-v1", "unknown"), "a" * 4097):
            with self.subTest(value=value[:60]):
                self.record.write_text(value)
                self.assertNotEqual(self.invoke("resume_game.sh").returncode, 0)
                self.assertFalse((self.run / "launched").exists())
                self.assertTrue(self.record.exists(), "Keep invalid data for diagnosis")

    def test_poweroff_requires_exact_current_ack(self):
        request = self.run / "poweroff.request"
        ack = self.run / "poweroff.ack"
        for value, response, valid in (("123\n", "123 ok\n", True), ("123\n", "122 ok\n", False),
                                      ("123\n", "123 error\n", False), ("123", "123 ok\n", False),
                                      ("123\nextra", "123 ok\n", False), ("123\n", "123 ok", False),
                                      ("123\n", "123 ok\nextra", False), ("idle\n", "idle ok\n", False)):
            with self.subTest(value=value, response=response):
                request.write_text(value)
                ack.write_text(response)
                self.assertEqual(self.invoke("poweroff_ready.sh", "game").returncode == 0, valid)
        request.write_text("idle\n")
        self.assertEqual(self.invoke("poweroff_ready.sh", "frontend").returncode, 0)
        (self.run / "game.active").write_text("99999999\n")
        self.assertEqual(self.invoke("poweroff_ready.sh", "frontend").returncode, 0)
        (self.run / "game.active").write_text(f"{os.getpid()}\n")
        (self.run / "app.pid").write_text(f"{os.getpid()}\n")
        self.assertNotEqual(self.invoke("poweroff_ready.sh", "frontend").returncode, 0)

    def test_exit_keeps_marker_only_for_acknowledged_durable_poweroff(self):
        for status, ack, keep in ((0, True, True), (0, False, False), (7, True, True)):
            with self.subTest(status=status, ack=ack):
                self.record.write_text(self.descriptor())
                (self.run / "poweroff.ack").unlink(missing_ok=True)
                (self.system / "launch_game.sh").write_text(
                    'printf "456\\n" > "$SOCKET_RUN/game.active"\n'
                    'printf "456\\n" > "$SOCKET_RUN/poweroff.request"\n' +
                    ('printf "456 ok\\n" > "$SOCKET_RUN/poweroff.ack"\n' if ack else '') +
                    f'exit {status}\n')
                self.assertEqual(self.invoke("play_game.sh", "mgba", str(self.rom), "gba").returncode, status)
                self.assertEqual(self.record.exists(), keep)
                self.assertFalse((self.run / "game.active").exists())
                self.assertFalse((self.run / "app.pid").exists())

    def test_new_game_removes_a_previous_poweroff_pair(self):
        self.record.write_text(self.descriptor())
        (self.run / "poweroff.request").write_text("123\n")
        (self.run / "poweroff.ack").write_text("123 ok\n")
        (self.system / "launch_game.sh").write_text(
            '[ ! -e "$SOCKET_RUN/poweroff.request" ] && [ ! -e "$SOCKET_RUN/poweroff.ack" ] || exit 9\n')
        self.assertEqual(self.invoke("play_game.sh", "mgba", str(self.rom), "gba").returncode, 0)
        self.assertFalse(self.record.exists())

    def test_frontend_starts_resume_record_and_handles_failed_poweroff(self):
        for request, poweroff_status in ((False, 0), (True, 0), (True, 1)):
            with self.subTest(request=request, poweroff_status=poweroff_status), tempfile.TemporaryDirectory() as directory:
                card = Path(directory)
                system = card / "System/socket"
                system.mkdir(parents=True)
                (system / "cores").mkdir()
                (system / "cores/mgba_libretro.so").touch()
                record = card / "Saves/socket/resume-game"
                record.parent.mkdir(parents=True)
                record.write_text(self.descriptor())
                run = card / "run"
                for name in ("resume_game.sh", "play_game.sh", "poweroff_ready.sh", "poweroff.sh"):
                    (system / name).write_text((SCRIPTS / name).read_text())
                (system / "socket-hardware").write_text(
                    'touch "$SOCKET_RUN/hardware.ready"\ntrap "exit 0" TERM INT\nwhile :; do sleep .05; done\n')
                (system / "launch_game.sh").write_text(
                    '[ "$SOCKET_RESUME_LOAD" = 1 ] || exit 9\n'
                    '[ -f "$SOCKET_RUN/hardware.ready" ] || exit 10\n'
                    'printf "%s\\n" "$@" > "$SOCKET_RUN/boot-game"\n' +
                    ('cp "$SOCKET_RESUME_MANIFEST.attempt" "$SOCKET_RESUME_MANIFEST"\n'
                     'printf "789\\n" > "$SOCKET_RUN/poweroff.request"\n'
                     'printf "789 ok\\n" > "$SOCKET_RUN/poweroff.ack"\n' if request else '') +
                    'exit 0\n')
                # The bridge starts the record after the frontend loads.
                (system / "godot").write_text('[ "$SOCKET_RESUME_BOOT" = 1 ] || exit 11\n'
                                              'touch "$SOCKET_RUN/frontend"\n'
                                              'sh "$SOCKET_SYSTEM/resume_game.sh"\nexit 0\n')
                poweroff = self.bins / "poweroff"
                poweroff.write_text(f'#!/bin/sh\ntouch "$SOCKET_RUN/poweroff-called"\nexit {poweroff_status}\n')
                poweroff.chmod(0o755)
                launcher = card / "launcher.sh"
                launcher.write_text((ROOT / "card/System/launch_frontend.sh").read_text()
                                    .replace("/tmp/socket", str(run)).replace("/lib/ld-linux-aarch64.so.1", "/bin/sh"))
                result = subprocess.run(["sh", str(launcher)], cwd=card, env=self.env,
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((run / "boot-game").read_text().splitlines(), ["mgba", str(self.rom), "gba"])
                self.assertEqual((run / "poweroff-called").exists(), request)
                self.assertTrue((run / "frontend").exists())
                self.assertEqual(record.exists(), request)
                self.assertTrue((card / "Logs/socket-resume.log").exists())


if __name__ == "__main__":
    unittest.main()
