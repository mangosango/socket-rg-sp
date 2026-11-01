"""Check the one-time GBA move to mGBA on a temporary card."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools/migrate-gba-settings.py"
USER = '{\n\t"added_platforms": [\n\t\t{"app_id": "gba.ra64.gpsp", "title": "Pokémon"},\n\t\t{"app_id": "gb.ra64.mgba"}\n\t]\n}\n'


class MigrateGbaTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.card = self.root / "card"
        for folder in ("Saves/socket/godot/app_userdata/Socket", "Saves/socket/retroarch",
                       "Saves/retroarch/gpSP", "Saves/retroarch/mGBA", "Games/GBA"):
            (self.card / folder).mkdir(parents=True)
        self.user = self.card / "Saves/socket/godot/app_userdata/Socket/user_data.json"
        self.user.write_text(USER, encoding="utf-8")
        self.options = self.card / "Saves/socket/retroarch/gpsp-gba-options.cfg"
        self.options.write_text('gpsp_boot_mode = "bios"\ngpsp_frameskip = "disabled"\n')
        self.gpsp = self.card / "Saves/retroarch/gpSP"
        self.mgba = self.card / "Saves/retroarch/mGBA"
        self.game("Flash", b"FLASH1M_V103", b"\x01" * 70000 + b"\xff" * 61072)
        self.game("Eeprom", b"EEPROM_V122", b"\x02" * 1000 + b"\xff" * 130072)
        self.game("Small", b"EEPROM_V111", b"\x03" * 100 + b"\xff" * 130972)
        self.game("Empty", b"FLASH_V126", b"\xff" * 131072)
        (self.gpsp / "Flash.state.auto").write_bytes(b"gpsp state")
        (self.gpsp / "Empty.state.sleep").write_bytes(b"gpsp sleep")
        (self.mgba / "Zelda.state.auto").write_bytes(b"gb state")
        (self.card / "Saves/socket/resume-game.attempt").write_text("socket-resume-v1\ngpsp\n")

    def tearDown(self):
        self.directory.cleanup()

    def game(self, name, marker, save):
        (self.card / "Games/GBA" / (name + ".gba")).write_bytes(b"\0" * 64 + marker + b"\0" * 64)
        (self.gpsp / (name + ".srm")).write_bytes(save)

    def run_script(self, *args, check=True):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), str(self.card), *args],
                              capture_output=True, text=True, check=check)

    def test_plan_and_apply(self):
        plan_dir = self.root / "plan"
        self.run_script("--plan", str(plan_dir))
        plan = json.loads((plan_dir / "plan.json").read_text(encoding="utf-8"))
        actions = {(item["action"], item["path"]) for item in plan}
        self.assertEqual(actions, {
            ("edit", "Saves/socket/godot/app_userdata/Socket/user_data.json"),
            ("edit", "Saves/socket/retroarch/gpsp-gba-options.cfg"),
            ("copy", "Saves/retroarch/mGBA/Flash.srm"), ("copy", "Saves/retroarch/mGBA/Eeprom.srm"),
            ("copy", "Saves/retroarch/mGBA/Small.srm"),
            ("move", "Saves/retroarch/gpSP/Flash.state.auto"), ("move", "Saves/retroarch/gpSP/Empty.state.sleep"),
            ("move", "Saves/socket/resume-game.attempt")})
        self.assertEqual(self.user.read_text(encoding="utf-8"), USER)
        backup = self.root / "backup"
        self.run_script("--apply", str(plan_dir), "--backup", str(backup))
        self.assertEqual(self.user.read_text(encoding="utf-8"), USER.replace("gba.ra64.gpsp", "gba.ra64.mgba"))
        self.assertIn('gpsp_frameskip = "auto"', self.options.read_text())
        self.assertEqual((self.mgba / "Flash.srm").read_bytes(), b"\x01" * 70000 + b"\xff" * 61072)
        self.assertEqual((self.mgba / "Eeprom.srm").read_bytes(), b"\x02" * 1000 + b"\xff" * 7192)
        self.assertEqual((self.mgba / "Small.srm").read_bytes(), b"\x03" * 100 + b"\xff" * 412)
        self.assertFalse((self.mgba / "Empty.srm").exists())
        self.assertEqual(len((self.gpsp / "Eeprom.srm").read_bytes()), 131072)
        self.assertFalse((self.gpsp / "Flash.state.auto").exists())
        self.assertEqual((backup / "Saves/retroarch/gpSP/Flash.state.auto").read_bytes(), b"gpsp state")
        self.assertEqual((backup / "Saves/socket/resume-game.attempt").read_text(), "socket-resume-v1\ngpsp\n")
        self.assertEqual((self.mgba / "Zelda.state.auto").read_bytes(), b"gb state")
        self.assertIn("gba.ra64.gpsp", (backup / "Saves/socket/godot/app_userdata/Socket/user_data.json").read_text(encoding="utf-8"))
        result = self.run_script("--apply", str(plan_dir), "--backup", str(self.root / "again"), check=False)
        self.assertIn("Changed since the plan", result.stderr)

    def test_refusals(self):
        (self.card / "Saves/socket/resume-game").write_text("live")
        self.assertIn("resume-game exists", self.run_script("--plan", str(self.root / "a"), check=False).stderr)
        (self.card / "Saves/socket/resume-game").unlink()
        (self.mgba / "Flash.srm").write_bytes(b"mgba")
        self.assertIn("Flash.srm exists", self.run_script("--plan", str(self.root / "b"), check=False).stderr)
        (self.mgba / "Flash.srm").unlink()
        (self.gpsp / "Eeprom.srm").write_bytes(b"\x02" * 9000 + b"\xff" * 122072)
        self.assertIn("data past 8192", self.run_script("--plan", str(self.root / "c"), check=False).stderr)

    def test_apply_refuses_changed_card(self):
        plan_dir = self.root / "plan"
        self.run_script("--plan", str(plan_dir))
        (self.gpsp / "Flash.state.auto").write_bytes(b"newer")
        result = self.run_script("--apply", str(plan_dir), "--backup", str(self.root / "backup"), check=False)
        self.assertIn("Changed since the plan", result.stderr)
        self.assertEqual(self.user.read_text(encoding="utf-8"), USER)
        self.assertFalse((self.root / "backup").exists())


if __name__ == "__main__":
    unittest.main()
