"""Check resident process ownership, return status, and safe shutdown."""

import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


def script(path, source):
    path.write_text("#!/bin/sh\n" + source)
    path.chmod(0o755)


class ResidentLauncherTests(unittest.TestCase):
    def test_terminating_game_wrapper_stops_its_emulator(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            (root / "play_game.sh").write_text((ROOT / "card/System/socket/play_game.sh").read_text())
            script(root / "launch_game.sh", "exec sleep 30\n")
            process = subprocess.Popen(["sh", str(root / "play_game.sh")],
                                       env=dict(os.environ, SOCKET_RUN=str(run), SOCKET_LOGS=str(root / "logs")))
            try:
                deadline = time.monotonic() + 3
                while not (run / "app.pid").exists() and time.monotonic() < deadline:
                    time.sleep(.01)
                child = int((run / "app.pid").read_text())
                process.terminate()
                self.assertEqual(process.wait(timeout=3), 1)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child, 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

    def test_game_status_log_and_pid_restore(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            bins = root / "bin"
            bins.mkdir()
            script(bins / "sync", "exit 0\n")
            (root / "play_game.sh").write_text((ROOT / "card/System/socket/play_game.sh").read_text())
            script(root / "launch_game.sh", 'sleep .1\ncat "$SOCKET_RUN/app.pid"\nprintf "args:%s:%s:%s\\n" "$1" "$2" "$3"\nexit 7\n')
            env = dict(os.environ, SOCKET_RUN=str(run), SOCKET_LOGS=str(root / "logs"),
                       SOCKET_FRONTEND_PID=str(os.getpid()), PATH=str(bins) + ":" + os.environ["PATH"])
            result = subprocess.run(["sh", str(root / "play_game.sh"), "mgba", "/games/a b.gba", "gba"],
                                    env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 7, result.stderr)
            self.assertEqual((run / "app.pid").read_text().strip(), str(os.getpid()))
            self.assertGreaterEqual(int((run / "session_seconds").read_text()), 0)
            lines = (root / "logs/socket-game.log").read_text().splitlines()
            # Uptime stamps mark each return stage for device timing.
            stamps = [line.split(" ", 2)[2] for line in lines if line.startswith("socket: uptime=")]
            self.assertEqual(stamps, ["game start", "game exited with status 7", "cleanup start", "cleanup done"])
            log = [line for line in lines if not line.startswith("socket: uptime=")]
            self.assertTrue(log[0].isdigit())
            self.assertNotEqual(log[0], str(os.getpid()))
            self.assertIn("args:mgba:/games/a b.gba:gba", log)


    def test_poweroff_unloads_wifi_first_with_a_bounded_wait(self):
        for hang in (False, True):
            with self.subTest(hang=hang), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                bins = root / "bin"
                bins.mkdir()
                script(bins / "sync", 'echo sync >> "$LOG"\n')
                script(bins / "rmmod", 'echo "rmmod $*" >> "$LOG"\n' + ('exec sleep 30\n' if hang else ''))
                script(bins / "poweroff", 'echo poweroff >> "$LOG"\n')
                log = root / "log"
                started = time.monotonic()
                result = subprocess.run(["sh", str(ROOT / "card/System/socket/poweroff.sh")],
                                        env=dict(os.environ, PATH=str(bins) + ":" + os.environ["PATH"], LOG=str(log)),
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(log.read_text().split("\n")[:4], ["sync", "rmmod 8821cs", "sync", "poweroff"])
                self.assertLess(time.monotonic() - started, 8 if hang else 2)

    def test_supervisor_only_powers_off_after_clean_exit_with_request(self):
        for request, status, orphan in ((False, 0, False), (True, 0, False), (True, 1, False), (False, 1, True)):
            with self.subTest(request=request, status=status, orphan=orphan), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                system = root / "System/socket"
                system.mkdir(parents=True)
                (system / "poweroff_ready.sh").write_text((ROOT / "card/System/socket/poweroff_ready.sh").read_text())
                (system / "poweroff.sh").write_text((ROOT / "card/System/socket/poweroff.sh").read_text())
                run = root / "run"
                bins = root / "bin"
                bins.mkdir()
                script(bins / "sync", "exit 0\n")
                script(bins / "poweroff", '[ -e "$SOCKET_RUN/wifi-unloaded" ] || exit 8\ntouch "$SOCKET_RUN/powered-off"\n')
                script(bins / "rmmod", '[ "$*" = 8821cs ] && touch "$SOCKET_RUN/wifi-unloaded"\n')
                script(system / "socket-hardware", 'touch "$SOCKET_RUN/hardware.ready"\ntrap "exit 0" TERM INT\nwhile :; do sleep .05; done\n')
                script(system / "test-game", 'trap \'touch "$SOCKET_RUN/game-stopped"; exit 0\' TERM\nwhile :; do sleep .05; done\n')
                crash_child = ('sleep .1\nsh "$SOCKET_SYSTEM/test-game" &\n'
                               'child=$!\nprintf "%s\\n" "$child" > "$SOCKET_RUN/app.pid"\nsleep .1\n') if orphan else ''
                script(system / "godot", 'printf "%s\\n" "$@" > "$SOCKET_RUN/args"\n' + crash_child +
                       ('printf "idle\\n" > "$SOCKET_RUN/poweroff.request"\n' if request else '') + f"exit {status}\n")
                launcher = root / "launch_frontend.sh"
                launcher.write_text((ROOT / "card/System/launch_frontend.sh").read_text()
                                    .replace("/tmp/socket", str(run))
                                    .replace("/lib/ld-linux-aarch64.so.1", "/bin/sh"))
                result = subprocess.run(["sh", str(launcher)], cwd=root,
                                        env=dict(os.environ, PATH=str(bins) + ":" + os.environ["PATH"]),
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual((run / "powered-off").exists(), request and status == 0)
                self.assertFalse((run / "app.pid").exists())
                self.assertFalse((run / "hardware.ready").exists())
                self.assertIn("--render-thread\nsafe\n", (run / "args").read_text())
                if orphan:
                    deadline = time.monotonic() + 2
                    while not (run / "game-stopped").exists() and time.monotonic() < deadline:
                        time.sleep(.01)
                    self.assertTrue((run / "game-stopped").exists(), "Stop the emulator when its frontend crashes")


if __name__ == "__main__":
    unittest.main()
