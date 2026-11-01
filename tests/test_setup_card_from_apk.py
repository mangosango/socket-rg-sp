"""Check APK extraction without real credentials or network access."""

import contextlib
import io
import json
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile


SPEC = importlib.util.spec_from_file_location("setup_apk", Path(__file__).resolve().parents[1] / "tools/setup-card-from-apk.py")
tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tool)


class ApkTests(unittest.TestCase):
    def test_extracts_only_required_files_and_cleans_temporary_data(self):
        with tempfile.TemporaryDirectory() as folder:
            apk = Path(folder) / "socket.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                for name in ("lib/arm64-v8a/libgodot_android.so", "assets/project.binary", "assets/" + tool.SCRAPER):
                    archive.writestr(name, b"fixture")
                archive.writestr("../../escape", b"must not extract")
            card = Path(folder) / "card"
            (card / "System/socket").mkdir(parents=True)
            roots = []
            source_text = '@export var api_key: String = "fixture-api-key"\n'

            def run(command, *, input=None):
                if command[0] == "pkg-config":
                    return b"-lcrypto"
                if "gdc2gd.py" in str(command):
                    decoded = Path(command[-1])
                    roots.append(decoded.parent)
                    self.assertFalse((decoded.parent / "escape").exists())
                    decoded.write_text(source_text)
                return b""

            with patch.object(tool, "run", side_effect=run), patch.object(tool.setup_card, "setup", return_value={"failures": []}) as setup:
                self.assertEqual(tool.setup_from_apk(apk, card), {"failures": []})
                setup.assert_called_once_with(card.resolve(), api_key="fixture-api-key")
            for source_text in ("", '@export var api_key: String = ""\n',
                                '@export var api_key: String = "bad\\nkey"\n',
                                source_text * 2):
                with self.subTest(source=source_text), patch.object(tool, "run", side_effect=run), self.assertRaises(ValueError):
                    tool.setup_from_apk(apk, card)
            self.assertTrue(roots)
            self.assertFalse(roots[0].exists())

    def test_cli_keeps_credential_out_of_output_and_card(self):
        for rejected in (False, True):
            with self.subTest(rejected=rejected), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                card = root / "card"
                (card / "System/socket").mkdir(parents=True)
                (card / "System/mgba_libretro.so").write_bytes(b"core")
                (card / "Games/GB").mkdir(parents=True)
                (card / "Games/GB/Test.gb").write_bytes(b"ROM")
                apk = root / "socket.apk"
                with zipfile.ZipFile(apk, "w") as archive:
                    for name in ("lib/arm64-v8a/libgodot_android.so", "assets/project.binary", "assets/" + tool.SCRAPER):
                        archive.writestr(name, b"fixture")
                sentinel = "private-fixture-credential"
                temporary_roots = []

                def run(command):
                    self.assertNotIn(sentinel, str(command))
                    if "gdc2gd.py" in str(command):
                        target = Path(command[-1])
                        temporary_roots.append(target.parent)
                        target.write_text('@export var api_key: String = "' + sentinel + '"\n')
                    return b"-lcrypto" if command[0] == "pkg-config" else b""

                def request(url, key):
                    self.assertEqual(key, sentinel)
                    if rejected:
                        raise tool.setup_card.AuthenticationError("HTTP 401: credential rejected")
                    return b'{"matched": false}'

                stdout, stderr = io.StringIO(), io.StringIO()
                with patch.object(tool, "run", side_effect=run), \
                        patch.object(tool.setup_card, "request", side_effect=request), \
                        patch.object(tool.sys, "argv", ["setup-card-from-apk.py", str(apk), str(card)]), \
                        contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    self.assertEqual(tool.main(), rejected)
                self.assertEqual(bool(json.loads(stdout.getvalue())["failures"]), rejected)
                self.assertNotIn(sentinel, stdout.getvalue() + stderr.getvalue())
                for path in card.rglob("*"):
                    if path.is_file():
                        self.assertNotIn(sentinel.encode(), path.read_bytes())
                self.assertTrue(temporary_roots)
                self.assertFalse(temporary_roots[0].exists())

    def test_missing_apk_member_fails_before_running_tools(self):
        with tempfile.TemporaryDirectory() as folder:
            apk = Path(folder) / "empty.apk"
            with zipfile.ZipFile(apk, "w"):
                pass
            card = Path(folder) / "card"
            (card / "System/socket").mkdir(parents=True)
            with patch.object(tool, "run") as run, self.assertRaises(KeyError):
                tool.setup_from_apk(apk, card)
            run.assert_not_called()

    def test_cli_failure_does_not_print_subprocess_credentials(self):
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / "System/socket").mkdir(parents=True)
            self.check_cli_failure(folder)

    def check_cli_failure(self, folder):
        with patch.object(tool, "setup_from_apk", side_effect=subprocess.CalledProcessError(1, ["private-key"])), \
                patch.object(tool.sys, "argv", ["setup-card-from-apk.py", "socket.apk", folder]), \
                patch.object(tool.sys, "stderr") as stderr:
            with self.assertRaises(SystemExit):
                tool.main()
            self.assertNotIn("private-key", str(stderr.write.call_args_list))

    def test_invalid_card_reports_cause_before_apk_extraction(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(tool, "run") as extract, \
                patch.object(tool.sys, "argv", ["setup-card-from-apk.py", "socket.apk", folder]), \
                patch.object(tool.sys, "stderr") as stderr:
            with self.assertRaises(SystemExit):
                tool.main()
            extract.assert_not_called()
            self.assertIn("System/socket is missing", str(stderr.write.call_args_list))


if __name__ == "__main__":
    unittest.main()
