import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SEED = Path(__file__).resolve().parents[1] / "card/System/socket/first-boot.sh"
USER = Path("Saves/socket/godot/app_userdata/Socket")


class FirstBoot(unittest.TestCase):
    def test_partial_install_and_second_boot_preserve_user_files(self):
        with tempfile.TemporaryDirectory() as directory:
            card = Path(directory)
            user = card / USER
            emulators = user / "emulators"
            emulators.mkdir(parents=True)
            custom = [emulators / "gb.json", user / "settings.cfg", card / "Saves/game.sav"]
            for path in custom:
                path.write_bytes(b"user bytes\x00")
            subprocess.run(["sh", SEED], cwd=card, check=True)
            records = json.loads((user / "user_data.json").read_text())["added_platforms"]
            self.assertEqual({p["model_id"] for p in records}, {"gb", "gbc", "gba"})
            for p in records:
                folder = f'Games/{p["model_id"].upper()}'
                self.assertEqual(p["rom_folder_path"], "/mnt/sdcard/" + folder)
                self.assertTrue((card / folder).is_dir())
                self.assertEqual(p["games"], [])
                if p["model_id"] != "gb":
                    entry, = json.loads((emulators / (p["model_id"] + ".json")).read_text())
                    self.assertEqual(entry["uniqueId"], p["app_id"])
            custom.append(user / "user_data.json")
            custom[-1].write_bytes(b"user bytes\x00")
            subprocess.run(["sh", SEED], cwd=card, check=True)
            for path in custom:
                self.assertEqual(path.read_bytes(), b"user bytes\x00")

    def test_does_not_seed_through_linked_save_directory(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            card = Path(directory)
            (card / "Saves").symlink_to(outside, target_is_directory=True)
            result = subprocess.run(["sh", SEED], cwd=card, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(Path(outside).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
