"""Check that a local card setup cannot add credentials to a release."""
from pathlib import Path
import subprocess
import tempfile
import unittest


class CardBuildTests(unittest.TestCase):
    def test_only_configuration_examples_ship(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory)
            (build / "build.sh").write_bytes((root / "build.sh").read_bytes())
            for tool in ("engine/build-engine.sh", "tools/build-retroarch.sh", "tools/build-pack.sh"):
                script = build / tool
                script.parent.mkdir(exist_ok=True)
                script.write_text("exit 0\n")
            for artifact in ("work/godot/bin/godot.linuxbsd.template_release.arm64", "work/socket-hardware",
                             "work/socket-wifi-config", "work/socket-bluetooth-agent", "work/RetroArch/retroarch"):
                path = build / artifact
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            (build / "card/System/socket/retroarch").mkdir(parents=True)
            config = build / "card/Config"
            config.mkdir()
            for item in ("wifi.txt", "retroachievements.txt"):
                (config / item).write_text("private test credentials")
                (config / (item + ".example")).write_text("example")
            subprocess.run(["sh", str(build / "build.sh"), "unused.apk"], check=True, capture_output=True)
            self.assertEqual(sorted(p.name for p in (build / "dist/Config").iterdir()),
                             ["retroachievements.txt.example", "wifi.txt.example"])
