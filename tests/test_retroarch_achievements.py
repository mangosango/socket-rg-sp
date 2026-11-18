"""Check the card account parser and password-to-token update with dummy values."""
from pathlib import Path
import subprocess
import tempfile
import unittest


class AchievementsTests(unittest.TestCase):
    def test_account(self):
        with tempfile.TemporaryDirectory() as directory:
            probe = Path(directory) / "account-test"
            source = Path(__file__).with_name("retroarch_achievements_account.c")
            subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", str(source), "-o", str(probe)], check=True)
            subprocess.run([str(probe), str(probe.with_name("account.txt"))], check=True)
