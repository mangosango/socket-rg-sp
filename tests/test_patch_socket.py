"""patch-socket.py must stop without changing files when it cannot apply every edit."""
import re
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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

    def test_version_scopes(self):
        edit = ("file", "pattern", "replacement", 1, 0)
        self.assertEqual(patch_socket.only(patch_socket.MODERN, edit)[5:], ("0.10.1", "0.8.0"))
        self.assertEqual(patch_socket.only(patch_socket.V032, edit)[5:], ("0.3.2",))
        for version in patch_socket.VERSIONS:
            paths = set()
            for path, _, _, _, _, *versions in patch_socket.EDITS:
                if not versions or version in versions:
                    paths.add(path)
            self.assertEqual("scenes/paper_sticker_body.gdshaderinc" in paths, version == "0.10.1")
            self.assertEqual(patch_socket.STICKER in paths, version != "0.10.1")

    def test_scrape_reset_keeps_its_existing_reload(self):
        for field in ("support_texture_path", "game_info_path"):
            edit = next(edit for edit in patch_socket.EDITS if f"game\\.{field}" in edit[1])
            reset = f'\tgame.{field} = ""\n\tgame.reload_scraped_data()\n'
            source = reset + f'\tgame.{field} = cached_path\n\tgame.{field} = downloaded_path\n'
            _, pattern, repl, count, flags = edit
            result, matches = re.subn(pattern, repl, source, flags=flags)
            self.assertEqual(matches, count)
            self.assertTrue(result.startswith(reset))

    def test_0101_folder_pickers_use_the_selected_folder(self):
        edit = next(edit for edit in patch_socket.EDITS
                    if edit[0] == patch_socket.EDIT_PLATFORM and edit[5:] == ("0.10.1",))
        _, pattern, repl, count, flags, *_ = edit
        source = '\tif OS.get_name() == "Android":\n\t\tFrontendBridge.open_folder_picker()\n'
        result, matches = re.subn(pattern, repl, source * 2, flags=flags)
        self.assertEqual(matches, count)
        self.assertEqual(result.count('open_folder_picker(save_folder_path if _picking_saves_folder else rom_folder_path)'), 2)
        self.assertEqual(result.count('or OS.get_name() == "Linux"'), 2)

    def test_modern_shader_warmup_guard_is_linux_only(self):
        edit = next(edit for edit in patch_socket.EDITS if "_warm_up_shaders" in edit[1])
        path, pattern, repl, count, flags, *versions = edit
        self.assertEqual(path, "scenes/cartridge_carousel.gd")
        self.assertEqual(versions, list(patch_socket.MODERN))
        self.assertEqual(count, 1)
        source = 'func _warm_up_shaders(cart: Cartridge) -> void:\n\twarmup_probe(cart)\n'
        for version in patch_socket.VERSIONS:
            with self.subTest(version=version):
                result = source
                if version in versions:
                    result, matches = re.subn(pattern, repl, source, flags=flags)
                    self.assertEqual(matches, count)
                expected = source
                if version in patch_socket.MODERN:
                    expected = source.replace('\n', '\n\tif OS.get_name() == "Linux":\n\t\treturn\n', 1)
                self.assertEqual(result, expected)
        for invalid in (STUB, source + source):
            _, matches = re.subn(pattern, repl, invalid, flags=flags)
            self.assertNotEqual(matches, count)

    def test_startup_hook_precedes_existing_ready_work_in_every_version(self):
        edits = [edit for edit in patch_socket.EDITS if edit[0] == "scenes/main.gd"]
        self.assertTrue(edits, "startup must patch main on legacy and modern Socket")
        for version in patch_socket.VERSIONS:
            with self.subTest(version=version):
                source = 'extends Node\nfunc _ready() -> void:\n\tawait _show_warning_prompt()\n'
                for _, pattern, repl, count, flags, *versions in edits:
                    if not versions or version in versions:
                        source, matches = re.subn(pattern, repl, source, flags=flags)
                        self.assertEqual(matches, count)
                self.assertEqual(source.count('shader_startup.gd'), 1)
                self.assertLess(source.index('shader_startup.gd'), source.index('await _show_warning_prompt()'))
                self.assertIn('await ', source.split('shader_startup.gd')[0].splitlines()[-1])

    def test_platform_warmup_guard_is_modern_only(self):
        edit = next(edit for edit in patch_socket.EDITS if "warm_up_platforms" in edit[1])
        path, pattern, repl, count, flags, *versions = edit
        self.assertEqual(path, "scenes/cartridge_carousel.gd")
        self.assertEqual(versions, list(patch_socket.MODERN))
        source = 'func warm_up_platforms(platforms: Array[Platform]) -> void:\n\twarmup_probe(platforms)\n'
        result, matches = re.subn(pattern, repl, source, flags=flags)
        self.assertEqual(matches, count)
        self.assertEqual(result, source.replace('\n', '\n\tif OS.get_name() == "Linux":\n\t\treturn\n', 1))
        for invalid in (STUB, source + source):
            _, matches = re.subn(pattern, repl, invalid, flags=flags)
            self.assertNotEqual(matches, count)

    def test_shader_anchor_failure_is_atomic_after_an_earlier_valid_edit(self):
        shader_edits = [edit for edit in patch_socket.EDITS if edit[0] == "scenes/main.gd"]
        self.assertTrue(shader_edits)
        for version in patch_socket.VERSIONS:
            for bad_source in ('extends Node\n', STUB + STUB):
                with self.subTest(version=version, duplicate=bad_source == STUB + STUB):
                    with tempfile.TemporaryDirectory() as tmp:
                        root = Path(tmp)
                        (root / "scenes").mkdir()
                        (root / "early.gd").write_text("unchanged")
                        (root / "scenes/main.gd").write_text(bad_source)
                        project_binary(root / "project.binary", version)
                        edits = [("early.gd", "unchanged", "changed", 1, 0), *shader_edits]
                        with patch.object(patch_socket, "EDITS", edits):
                            with self.assertRaisesRegex(SystemExit, "expected"):
                                patch_socket.main(root, root / "project.binary")
                        self.assertEqual((root / "early.gd").read_text(), "unchanged")
                        self.assertEqual((root / "scenes/main.gd").read_text(), bad_source)

    def test_unmatched_anchor_changes_no_files(self):
        for version in patch_socket.VERSIONS:
            self.assertIn("expected", self.run_patch(version))

    def test_unsupported_version_changes_no_files(self):
        self.assertIn("not supported", self.run_patch("9.9.9"))


if __name__ == "__main__":
    unittest.main()
