"""Exercise the shared pack pipeline with generated Godot tokens and repo overlays."""
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import build_pack as pipeline

TOKENS = bytes(16)  # Empty identifier, constant, line and token tables.


def gdc(payload, size=0):
    return b"GDSC" + struct.pack("<II", 101, size) + payload


def put(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


class BuildPackTests(unittest.TestCase):
    def test_untrusted_token_tables(self):
        decoder = pipeline.gdc2gd
        cases = [
            struct.pack("<4I", 0, 0, 0, decoder.MAX_ITEMS + 1),
            struct.pack("<5I", 1, 0, 0, 0, 0xffffffff),
            struct.pack("<6I", 0, 1, 0, 0, 4, 64) + b"short",
            bytes(16) + b"trailing",
        ]
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp) / "script.gdc"
            for buf in cases:
                with self.subTest(buf=buf):
                    file.write_bytes(gdc(buf))
                    with self.assertRaises(ValueError):
                        decoder.load_tokens(file)
            cb = Mock()
            file.write_bytes(gdc(b"compressed", decoder.MAX_BUFFER + 1))
            with self.assertRaisesRegex(ValueError, "size limit"):
                decoder.load_tokens(file, cb)
            cb.assert_not_called()

    def test_source_limits_before_line_column_and_token_expansion(self):
        decoder = pipeline.gdc2gd
        for coords in ((0xffffffff, 1), (1, 0xffffffff)):
            with self.assertRaisesRegex(ValueError, "line or column"):
                decoder.render([(decoder.NEWLINE, coords)])
        for kind in (decoder.IDENT, decoder.LIT):
            tokens = [(kind, "é" * 16)] * 3
            text = decoder.render(tokens, 99)
            self.assertEqual(len(text.encode()), 99)
            with self.assertRaisesRegex(ValueError, "source size"):
                decoder.render(tokens, 98)
        with self.assertRaisesRegex(ValueError, "source size"):
            decoder.render([(decoder.NEWLINE, (10, 3)), (decoder.IDENT, "x")], 12)

    @unittest.skipUnless(shutil.which("zstd"), "native zstd unavailable")
    def test_native_decompress_rejects_more_output_than_declared(self):
        with tempfile.TemporaryDirectory() as tmp:
            packed = subprocess.check_output(["zstd", "-c"], input=bytes(256 * 1024))
            script = Path(tmp) / "oversize.gdc"
            script.write_bytes(gdc(packed, 16))
            with self.assertRaisesRegex(ValueError, "decompressed GDSC size"):
                pipeline.gdc2gd.load_tokens(script)

    def test_decompress_size_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / "bad.gdc"
            script.write_bytes(gdc(b"compressed", len(TOKENS)))
            with self.assertRaisesRegex(ValueError, "size"):
                pipeline.gdc2gd.load_tokens(script, lambda data, size: b"")

    def test_build_with_and_without_optional_resources(self):
        for optional in (False, True):
            with self.subTest(optional=optional), tempfile.TemporaryDirectory() as tmp:
                res = Path(tmp) / "res"
                out = Path(tmp) / "socket.pck"
                romm = "scripts/autoload/romm.gd"
                include = "scenes/paper_sticker_body.gdshaderinc"
                for rel in pipeline.SCRIPTS + ([romm] if optional else []):
                    put((res / rel).with_suffix(".gdc"), gdc(TOKENS))
                    put(res / (rel + ".remap"), b"remap")
                put(res / "scenes/main.gdc", gdc(b"compressed", len(TOKENS)))
                for rel in pipeline.SHADERS + ([include] if optional else []):
                    put(res / rel, b"shader")
                plugin = res / pipeline.PLUGIN
                put(plugin / "controls/existing", b"keep")
                put(plugin / "shader_startup.gdc", b"compiled")
                put(plugin / "shader_startup.gd.remap", b"remap")
                put(res / "addons/AynThor/bin/thor.so", b"extension")
                cfg = res / ".godot/extension_list.cfg"
                put(cfg, b"other\naddons/AynThor/thor\n")

                def apply(src, project):
                    self.assertEqual(project, res / "project.binary")
                    self.assertEqual((src / "scenes/main.gd").read_bytes(), b"\n")
                    (src / "scenes/main.gd").write_bytes(b"patched")
                    self.assertEqual((src / romm).exists(), optional)
                    self.assertEqual((src / include).exists(), optional)
                    if optional:
                        (src / include).write_bytes(b"patched shader")
                    return "0.10.1" if optional else "0.3.2"

                with patch.object(pipeline, "MAX_DECODED", 1):
                    with self.assertRaisesRegex(ValueError, "source size"):
                        pipeline.build_pack(res, ROOT / "overlay", out, lambda data, size: TOKENS)
                self.assertFalse(out.exists())
                decompress = Mock(return_value=TOKENS)
                with patch.object(pipeline.patch_socket, "main", apply):
                    pipeline.build_pack(res, ROOT / "overlay", out, decompress)
                decompress.assert_called_once_with(b"compressed", len(TOKENS))
                self.assertEqual((res / "scenes/main.gd").read_bytes(), b"patched")
                self.assertFalse((res / "scenes/main.gdc").exists())
                self.assertFalse((res / "scenes/main.gd.remap").exists())
                self.assertTrue((res / "scripts/game.gd.remap").is_file())
                self.assertTrue((res / "scripts/game.gdc").is_file())
                self.assertFalse((res / "scripts/game.gd").exists())
                if optional:
                    self.assertEqual((res / include).read_bytes(), b"patched shader")
                for file in (ROOT / "overlay").rglob("*"):
                    if file.is_file() and not file.name.startswith("."):
                        packed = res / file.relative_to(ROOT / "overlay")
                        if not optional and file.name.startswith("split_label_"):
                            self.assertFalse(packed.exists())
                        else:
                            self.assertEqual(packed.read_bytes(), file.read_bytes())
                self.assertFalse((plugin / "controls/controls").exists())
                self.assertEqual((plugin / "controls/existing").read_bytes(), b"keep")
                self.assertFalse((plugin / "shader_startup.gdc").exists())
                self.assertFalse((plugin / "shader_startup.gd.remap").exists())
                self.assertEqual(cfg.read_bytes(), b"other\n")
                self.assertFalse((res / "addons/AynThor/bin").exists())
                self.assertEqual(out.read_bytes()[:4], b"GDPC")


if __name__ == "__main__":
    unittest.main()
