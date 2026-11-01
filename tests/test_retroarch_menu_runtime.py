"""Run raw joypad input through the launcher, RetroArch, and a real core."""

import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CARD = Path(os.environ.get("RETROARCH_CORE_SMOKE_ROOT", "/Volumes/BASEOS"))

# This probe runs inside Docker. Card files and project files are read-only.
PROBE = r"""
import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time

binary, rom, platform = sys.argv[1:]
output = Path('/output')
system = Path('/mnt/sdcard/System/socket')
(system / 'retroarch').mkdir(parents=True, exist_ok=True)
(system / 'cores').mkdir(exist_ok=True)
for path in Path('/project/card/System/socket/retroarch').glob('*.cfg'):
    shutil.copy(path, system / 'retroarch' / path.name)
core = system / 'cores/mgba_libretro.so'
if not core.exists():
    core.symlink_to('/card/System/socket/cores/mgba_libretro.so')
info = system / 'info'
info.mkdir(exist_ok=True)
(info / 'mgba_libretro.info').write_text('display_name = "mGBA"\nsystemid = "gb"\nsupported_extensions = "gb|gbc|gba"\n')
config = system / 'retroarch/retroarch.cfg'
overrides = '''
video_driver = "null"
video_context_driver = "null"
video_threaded = "false"
libretro_info_path = "/mnt/sdcard/System/socket/info"
audio_driver = "null"
input_driver = "test"
input_joypad_driver = "test"
input_autodetect_enable = "false"
test_input_file_general = "/output/input.json"
test_input_file_joypad = "/output/joypad.json"
vrr_runloop_enable = "true"
fastforward_ratio = "1.0"
frontend_log_level = "0"
network_cmd_enable = "true"
network_cmd_port = "55355"
menu_pause_libretro = "true"
savestate_directory = "/output/states"
savefile_directory = "/output/saves"
savestate_thumbnail_enable = "false"
sort_savefiles_enable = "false"
sort_savestates_enable = "false"
sort_savefiles_by_content_enable = "false"
sort_savestates_by_content_enable = "false"
''' + (output / 'extra.cfg').read_text()
keys = {line.split(' = ', 1)[0] for line in overrides.splitlines() if ' = ' in line}
config.write_text('\n'.join(line for line in config.read_text().splitlines()
                            if line.split(' = ', 1)[0] not in keys) + '\n' + overrides)
launcher = system / 'launch_game.sh'
launcher.write_text(Path('/project/card/System/socket/launch_game.sh').read_text().replace(
    '/lib/ld-linux-aarch64.so.1 "$SYS/retroarch/retroarch"', binary + ' --max-frames 180'))
statuses = set()
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(.05)
with (output / 'runtime.log').open('w') as log:
    process = subprocess.Popen(['sh', str(launcher), 'mgba', rom, platform], stdout=log, stderr=log)
    deadline = time.monotonic() + 20
    while process.poll() is None and time.monotonic() < deadline:
        sock.sendto(b'GET_STATUS\n', ('127.0.0.1', 55355))
        try:
            statuses.add(sock.recv(2048).decode())
        except socket.timeout:
            pass
        time.sleep(.01)
    if process.poll() is None:
        process.kill()
        process.wait()
        raise RuntimeError('RetroArch did not exit before the timeout')
sock.close()
print(json.dumps({'returncode': process.returncode, 'statuses': sorted(statuses)}))
"""


@unittest.skipUnless(os.environ.get("RETROARCH_MENU_SMOKE") == "1",
                     "Set RETROARCH_MENU_SMOKE=1 with Docker and read-only GB/GBC/GBA content")
class MenuRuntimeTests(unittest.TestCase):
    def run_case(self, platform, events, *, fail=False, extra="", baseline=False, restore=False):
        roms = sorted(path for path in (CARD / "Games" / platform.upper()).glob(f"*.{platform}")
                      if not path.name.startswith("._"))
        self.assertTrue(roms, f"No {platform} fixture in {CARD}")
        rom = roms[0]
        with tempfile.TemporaryDirectory(prefix="ra-menu-") as directory:
            output = Path(directory)
            states = output / "states"
            states.mkdir()
            (output / "saves").mkdir()
            state = states / f"{rom.stem}.state.auto"
            if fail:
                state.write_bytes(b"previous state")
            (output / "input.json").write_text('[{"frame":0,"action":0}]')
            (output / "joypad.json").write_text(json.dumps([
                {"frame": 0, "action": 1, "param_num": 0, "param_str": "(0000:0000) MENU test"},
                *[{"frame": frame, "action": action, "param_num": buttons}
                  for frame, action, buttons in events],
            ]))
            (output / "extra.cfg").write_text(extra)
            (output / "probe.py").write_text(PROBE)
            binary = "/baseline/retroarch" if baseline else "/project/work/RetroArch/retroarch"
            command = ["docker", "run", "--rm", "--platform", "linux/arm64",
                       "-v", f"{ROOT}:/project:ro", "-v", f"{CARD}:/card:ro",
                       "-v", f"{output}:/output"]
            if baseline:
                command += ["-v", f"{Path(os.environ['RETROARCH_MENU_BASELINE']).resolve()}:/baseline/retroarch:ro"]
            if fail:
                command += ["-v", f"{states}:/output/states:ro"]
            command += ["socket-baseos-godot", "python3", "/output/probe.py", binary,
                        "/card/" + str(rom.relative_to(CARD)), platform]
            result = subprocess.run(command, capture_output=True, text=True, timeout=40)
            log = (output / "runtime.log").read_text() if (output / "runtime.log").exists() else ""
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr + log)
            report = json.loads(result.stdout)
            self.assertEqual(report["returncode"], 0, log)
            self.assertIn('Found input driver: "test"', log)
            self.assertIn('Found joypad driver: "test"', log)
            self.assertIn("Pressing device 0 buttons", log)
            self.assertTrue(report["statuses"], log)
            statuses = "\n".join(report["statuses"])
            if restore:
                self.assertTrue(state.is_file(), log)
                checksum = hashlib.sha256(state.read_bytes()).hexdigest()
                (output / "joypad.json").write_text('[{"frame":0,"action":1,"param_num":0,"param_str":"(0000:0000) MENU test"}]')
                restored = subprocess.run(command, capture_output=True, text=True, timeout=40)
                restored_log = (output / "runtime.log").read_text()
                self.assertEqual(restored.returncode, 0, restored.stdout + restored.stderr + restored_log)
                self.assertRegex(restored_log, r"Auto-loading save state from .*succeeded")
                self.assertNotIn("Failed to load state", restored_log)
                self.assertEqual(hashlib.sha256(state.read_bytes()).hexdigest(), checksum)
            data = state.read_bytes() if state.exists() else None
            self.assertFalse(list(states.glob("*.tmp")), log)
            return log, statuses, data

    def core_seconds(self, log):
        # Menu pause stops core runtime without setting the GET_STATUS PAUSED flag.
        match = re.search(r"Content ran for a total of: (\d+) hours, (\d+) minutes, (\d+) seconds", log)
        self.assertIsNotNone(match, log)
        hours, minutes, seconds = map(int, match.groups())
        return hours * 3600 + minutes * 60 + seconds

    def test_under_one_second_hold_opens_menu_without_saving(self):
        log, _, data = self.run_case("gb", [(10, 16, 256), (60, 32, 256)])
        self.assertNotIn("Auto save state to", log)
        self.assertIsNone(data)
        self.assertEqual(self.core_seconds(log), 1, log)

    def test_second_tap_closes_menu_and_resumes_core(self):
        log, _, data = self.run_case("gb", [(10, 16, 256), (20, 32, 256),
                                           (80, 16, 256), (90, 32, 256)])
        self.assertNotIn("Auto save state to", log)
        self.assertIsNone(data)
        self.assertEqual(self.core_seconds(log), 1, log)

    def test_hold_saves_quits_and_restores_each_core_platform(self):
        for platform in ("gb", "gbc", "gba"):
            with self.subTest(platform=platform):
                log, statuses, data = self.run_case(platform, [(10, 16, 256), (150, 32, 256)], restore=True)
                self.assertRegex(log, r"Auto save state to .*succeeded")
                self.assertGreater(len(data), 64)
                self.assertNotIn("Releasing device 0 buttons 100", log,
                                 "Hold must quit before MENU is released")

    def test_tap_opens_menu_without_saving(self):
        log, statuses, data = self.run_case("gb", [(10, 16, 256), (20, 32, 256)])
        self.assertEqual(self.core_seconds(log), 0, log)
        self.assertNotIn("Auto save state to", log)
        self.assertIsNone(data)

    def test_other_hotkey_cancels_hold_and_release_menu(self):
        log, statuses, data = self.run_case("gb", [(10, 16, 256), (20, 16, 1024),
                                                       (70, 32, 1024), (80, 32, 256)])
        self.assertIn("Releasing device 0 buttons 100", log)
        self.assertGreaterEqual(self.core_seconds(log), 2, log)
        self.assertNotIn("Auto save state to", log)
        self.assertIsNone(data)

    def test_failed_save_preserves_state_and_keeps_game_running_after_release(self):
        log, statuses, data = self.run_case("gb", [(10, 16, 256), (150, 32, 256)], fail=True)
        self.assertRegex(log, r"Auto save state to .*failed")
        self.assertEqual(log.count("[State] Auto save state to"), 1)
        self.assertIn("Releasing device 0 buttons 100", log)
        self.assertEqual(self.core_seconds(log), 3, log)
        self.assertEqual(data, b"previous state")

    def test_remapped_menu_button_still_saves(self):
        log, _, data = self.run_case("gb", [(10, 16, 8192), (150, 32, 8192)],
                                    extra='input_menu_toggle_btn = "13"\n')
        self.assertRegex(log, r"Auto save state to .*succeeded")
        self.assertGreater(len(data), 64)

    @unittest.skipUnless(os.environ.get("RETROARCH_MENU_BASELINE"),
                         "Set RETROARCH_MENU_BASELINE to the previous MENU binary")
    def test_previous_binary_reproduces_hold_failure(self):
        log, statuses, data = self.run_case("gb", [(10, 16, 256), (150, 32, 256)], baseline=True)
        self.assertNotIn("Auto save state to", log)
        self.assertIn("Releasing device 0 buttons 100", log)
        self.assertEqual(self.core_seconds(log), 2, log)
        self.assertIsNone(data)


if __name__ == "__main__":
    unittest.main()
