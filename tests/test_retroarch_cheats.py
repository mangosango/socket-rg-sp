"""Check the cheat page helpers that do not need RetroArch."""
from pathlib import Path
import subprocess
import tempfile
import unittest


class CheatsTests(unittest.TestCase):
    def test_helpers(self):
        with tempfile.TemporaryDirectory() as directory:
            probe = Path(directory) / "cheats-test"
            source = Path(__file__).with_name("retroarch_cheats_menu.c")
            subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", str(source), "-o", str(probe)], check=True)
            subprocess.run([str(probe)], check=True)


if __name__ == "__main__":
    unittest.main()
