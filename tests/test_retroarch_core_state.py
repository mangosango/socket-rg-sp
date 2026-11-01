"""Optional real-core automatic state round trips with read-only card content."""

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CARD = Path(os.environ.get("RETROARCH_CORE_SMOKE_ROOT", "/Volumes/BASEOS"))


@unittest.skipUnless(os.environ.get("RETROARCH_CORE_SMOKE") == "1",
                     "Set RETROARCH_CORE_SMOKE=1 with Docker and read-only GB/GBC/GBA content")
class CoreStateTests(unittest.TestCase):
    def test_automatic_save_and_load(self):
        core = CARD / "System/socket/cores/mgba_libretro.so"
        self.assertTrue(core.is_file(), str(core))
        for platform in ("GB", "GBC", "GBA"):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory(prefix="ra-state-") as directory:
                roms = sorted(path for path in (CARD / "Games" / platform).glob(f"*.{platform.lower()}")
                              if not path.name.startswith("._"))
                self.assertTrue(roms, f"No {platform} fixture in {CARD}")
                rom = roms[0]
                output = Path(directory)
                (output / "states").mkdir()
                (output / "saves").mkdir()
                config = '''video_driver = "null"
video_context_driver = "null"
audio_driver = "null"
input_driver = "udev"
input_joypad_driver = "udev"
menu_driver = "null"
rgui_show_start_screen = "false"
config_save_on_exit = "false"
libretro_log_level = "0"
log_verbosity = "true"
savestate_directory = "/output/states"
savefile_directory = "/output/saves"
system_directory = "/output"
savestate_thumbnail_enable = "false"
savestate_file_compression = "true"
savestate_auto_load = "true"
sort_savefiles_enable = "false"
sort_savestates_enable = "false"
sort_savefiles_by_content_enable = "false"
sort_savestates_by_content_enable = "false"
'''

                def launch(save):
                    (output / "test.cfg").write_text(config + f'savestate_auto_save = "{str(save).lower()}"\n')
                    result = subprocess.run([
                        "docker", "run", "--rm", "--platform", "linux/arm64",
                        "-v", f"{ROOT}:/project:ro", "-v", f"{CARD}:/card:ro",
                        "-v", f"{output}:/output", "socket-baseos-godot",
                        "/project/work/RetroArch/retroarch", "--verbose", "--config", "/output/test.cfg",
                        "-L", "/card/" + str(core.relative_to(CARD)),
                        "/card/" + str(rom.relative_to(CARD)), "--max-frames", "120",
                    ], capture_output=True, text=True, timeout=60)
                    log = result.stdout + result.stderr
                    self.assertEqual(result.returncode, 0, log)
                    return log

                # Teardown calls the same blocking auto-save function as MENU hold.
                saved = launch(True)
                self.assertRegex(saved, r'Auto save state to .*succeeded')
                states = list((output / "states").rglob("*.state.auto"))
                self.assertEqual(len(states), 1, saved)
                state = states[0]
                self.assertGreater(state.stat().st_size, 64)
                self.assertFalse(list((output / "states").rglob("*.tmp")))
                checksum = hashlib.sha256(state.read_bytes()).hexdigest()
                restored = launch(False)
                self.assertRegex(restored, r'Auto-loading save state from .*succeeded')
                self.assertIn('[State] Loading state', restored)
                self.assertIn('Savestate: Loading savedata', restored)
                self.assertNotIn('Failed to load state', restored)
                self.assertEqual(hashlib.sha256(state.read_bytes()).hexdigest(), checksum)
                # A corrupt state must fail in the deserialize callback, which
                # runs after the initial automatic-load success message.
                state.write_bytes(b"invalid state")
                rejected = launch(False)
                self.assertIn('Failed to load state', rejected)
                print(f"{platform}: {rom.name}: auto-state {checksum[:12]} saved, loaded, corrupt state rejected")


if __name__ == "__main__":
    unittest.main()
