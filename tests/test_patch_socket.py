"""patch-socket.py must stop without changing files when it cannot apply every edit."""
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
patch_socket = __import__("patch-socket")
STUB = "func _ready() -> void:\n\tpass\n"


def project_binary(path, version):
    """Write the start of a binary project.godot with one version setting."""
    key = b"application/config/version"
    text = version.encode()
    value = struct.pack("<II", 4, len(text)) + text + b"\0" * (-len(text) % 4)
    path.write_bytes(b"ECFG" + struct.pack("<I", 1) + struct.pack("<I", len(key)) + key
                     + struct.pack("<I", len(value)) + value)


class PatchSocketTests(unittest.TestCase):
    def run_patch(self, version):
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        files = {path for path, *_ in patch_socket.EDITS}
        for path in files:
            (tmp / path).parent.mkdir(parents=True, exist_ok=True)
            (tmp / path).write_text(STUB)
        project_binary(tmp / "project.binary", version)
        result = subprocess.run([sys.executable, "-I", str(ROOT / "tools/patch-socket.py"), str(tmp),
                                 str(tmp / "project.binary")], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        for path in files:
            self.assertEqual((tmp / path).read_text(), STUB)
        return result.stderr

    def test_reads_version(self):
        with tempfile.TemporaryDirectory() as tmp:
            project_binary(Path(tmp) / "project.binary", "0.3.2")
            self.assertEqual(patch_socket.socket_version(Path(tmp) / "project.binary"), "0.3.2")

    def test_unmatched_anchor_changes_no_files(self):
        for version in patch_socket.VERSIONS:
            self.assertIn("expected", self.run_patch(version))

    def test_unsupported_version_changes_no_files(self):
        self.assertIn("not supported", self.run_patch("9.9.9"))


if __name__ == "__main__":
    unittest.main()
