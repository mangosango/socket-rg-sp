"""Run with python3 -m unittest discover -s tests -p test_setup_card.py."""

import base64
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("setup_card", Path(__file__).resolve().parents[1] / "tools/setup-card.py")
tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tool)
IMAGE = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")


class CardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.card = Path(self.temporary.name)
        (self.card / "System/socket").mkdir(parents=True)
        (self.card / "System/mgba_libretro.so").write_bytes(b"fixture core")
        (self.card / "Games/GB").mkdir(parents=True)
        (self.card / "Games/GB/Test.gb").write_bytes(b"ROM")
        self.user = self.card / tool.USER_DIR
        self.user.mkdir(parents=True)
        self.library = self.user / "user_data.json"

    def save(self, value):
        self.library.write_text(json.dumps(value))

    def load(self):
        return json.loads(self.library.read_text())

    def test_scan_preserves_settings_games_metadata_and_emulators(self):
        game = {"rom_name": "Test", "rom_path": "/mnt/sdcard/Games/GB/Test.gb", "playtime": 91,
                "is_favorite": True, "custom_label_zoom": 2, "game_info_path": "user://custom.json"}
        missing = {"rom_name": "Removed", "playtime": 500}
        platform = {"model_id": "gb", "app_id": "custom", "rom_folder_path": "/mnt/sdcard/Games/GB",
                    "games": [game, missing], "camera_zoom": 3}
        original = {"added_platforms": [platform], "retro_achievements_username": "Sang", "extra": 12}
        self.save(original)
        old = self.library.read_bytes()
        settings = self.user / "settings.cfg"
        settings.write_text('[General]\nscrape_region="jp"\n')
        emulator = self.user / "emulators/gb.json"
        emulator.parent.mkdir()
        emulator.write_text('[{"custom": true}]')
        with patch.object(tool, "request", side_effect=AssertionError("Network used")):
            report = tool.setup(self.card, scan_only=True)
        self.assertEqual(report["scanned"], 1)
        self.assertEqual(self.load(), original)
        self.assertEqual(settings.read_text(), '[General]\nscrape_region="jp"\n')
        self.assertEqual(emulator.read_text(), '[{"custom": true}]')
        self.assertEqual(self.library.read_bytes(), old)
        self.assertEqual(list(self.user.glob("user_data.json.bak-*")), [])

    def test_new_library_and_atomic_backup(self):
        self.save({"added_platforms": [], "extra": "keep"})
        old = self.library.read_bytes()
        report = tool.setup(self.card, scan_only=True)
        game = self.load()["added_platforms"][0]["games"][0]
        self.assertEqual(report["added"], 1)
        self.assertEqual(game["rom_path"], "/mnt/sdcard/Games/GB/Test.gb")
        self.assertEqual(game["rom_name"], "Test")
        self.assertEqual(game["platform_id"], "gb")
        self.assertEqual(next(self.user.glob("user_data.json.bak-*")).read_bytes(), old)
        emulator = json.loads((self.user / "emulators/gb.json").read_text())[0]
        self.assertIn("-e LIBRETRO mgba -e ROM", emulator["amStartArguments"])

    def test_dry_run_has_no_writes_or_network(self):
        before = sorted(str(path.relative_to(self.card)) for path in self.card.rglob("*"))
        with patch.object(tool, "request", side_effect=AssertionError("Network used")):
            report = tool.setup(self.card, dry_run=True)
        self.assertEqual(report["added"], 1)
        self.assertEqual(before, sorted(str(path.relative_to(self.card)) for path in self.card.rglob("*")))

    def test_cached_metadata_resumes_only_image_download(self):
        info_path = self.user / "scraped_data/gb/Test.json"
        info_path.parent.mkdir(parents=True)
        info_path.write_text(json.dumps({"name": "Keep my title", "texture_url": "https://art.example/image"}))
        with patch.dict(os.environ, {"SOCKET_API_KEY": "authorized-test-key"}), \
                patch.object(tool, "request", return_value=IMAGE) as request, \
                patch.object(tool, "png_bytes", return_value=IMAGE):
            report = tool.setup(self.card)
        request.assert_called_once_with("https://art.example/image", "authorized-test-key")
        self.assertEqual(report["cached"], 1)
        self.assertEqual(json.loads(info_path.read_text())["name"], "Keep my title")
        game = self.load()["added_platforms"][0]["games"][0]
        self.assertEqual(game["game_info_path"], "user://scraped_data/gb/Test.json")
        self.assertEqual(game["support_texture_path"], "user://scraped_data/gb/Test_support.png")

    def test_auth_failure_happens_once_and_scan_finishes(self):
        (self.card / "Games/GB/Second.gb").write_bytes(b"other ROM")
        with patch.dict(os.environ, {"SOCKET_API_KEY": "test"}), \
                patch.object(tool, "request", side_effect=tool.AuthenticationError("Use --scan-only")) as request:
            report = tool.setup(self.card)
        self.assertEqual(request.call_count, 1)
        self.assertEqual(report["scanned"], 2)
        self.assertEqual(report["failures"], ["Use --scan-only"])
        self.assertEqual(len(self.load()["added_platforms"][0]["games"]), 2)

    def test_service_contract_and_region(self):
        (self.user / "settings.cfg").write_text('[General]\nscrape_region="jp"\n')
        response = {"matched": True, "method": "md5", "game": {"id": 3, "canonical_name": "Title",
                    "platform_slug": "nintendo-game-boy", "meta": {"color": "red"}},
                    "labels": [{"region": "us", "image_url": "https://art/us"},
                               {"region": "jp", "image_url": "https://art/jp"}]}
        with patch.dict(os.environ, {"SOCKET_API_KEY": "test"}), \
                patch.object(tool, "request", side_effect=[json.dumps(response).encode(), IMAGE]) as request, \
                patch.object(tool, "png_bytes", return_value=IMAGE):
            report = tool.setup(self.card)
        url = request.call_args_list[0].args[0]
        self.assertIn("md5=" + tool.hashlib.md5(b"ROM").hexdigest(), url)
        self.assertIn("platform=nintendo-game-boy", url)
        self.assertIn("filename=Test", url)
        self.assertEqual(request.call_args_list[1].args[0], "https://art/jp")
        info = json.loads((self.user / "scraped_data/gb/Test.json").read_text())
        self.assertEqual(info["name"], "Title")
        self.assertEqual(info["meta"], {"color": "red"})
        self.assertEqual(report["matched"], 1)

    def test_explicit_apk_key_overrides_environment_without_persistence(self):
        with patch.dict(os.environ, {"SOCKET_API_KEY": "environment-key"}), \
                patch.object(tool, "request", return_value=b'{"matched": false}') as request:
            tool.setup(self.card, api_key="apk-fixture-key")
            self.assertEqual(os.environ["SOCKET_API_KEY"], "environment-key")
        self.assertEqual(request.call_args.args[1], "apk-fixture-key")
        for path in self.card.rglob("*"):
            if path.is_file():
                self.assertNotIn(b"apk-fixture-key", path.read_bytes())

    def test_corrupt_json_and_escaped_path_do_not_overwrite(self):
        self.library.write_text("{broken")
        with self.assertRaises(ValueError):
            tool.setup(self.card, scan_only=True)
        self.assertEqual(self.library.read_text(), "{broken")
        self.save({"added_platforms": [{"model_id": "gb", "rom_folder_path": "/mnt/sdcard/../escape", "games": []}]})
        with self.assertRaisesRegex(ValueError, "leaves card"):
            tool.setup(self.card, scan_only=True)

    def test_symlink_outside_card_is_rejected(self):
        (self.card / "Games/GB/Test.gb").unlink()
        (self.card / "Games/GB/Test.gb").symlink_to(__file__)
        with self.assertRaises(ValueError):
            tool.setup(self.card, scan_only=True)

    def test_retries_and_credential_scope(self):
        busy = subprocess.CompletedProcess([], 0, b"busy\n503")
        response = subprocess.CompletedProcess([], 0, IMAGE + b"\n200")
        with patch.object(tool, "check_curl"), patch.object(tool.subprocess, "run", side_effect=[busy, busy, response]) as run, \
                patch.object(tool.time, "sleep") as sleep:
            self.assertEqual(tool.request("https://art.example/image", "secret"), IMAGE)
        self.assertEqual(run.call_count, 3)
        self.assertEqual(run.call_args.kwargs["input"], b"")
        self.assertEqual(run.call_args.kwargs["timeout"], 20)
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [1, 2])

    def test_rejected_credential_reports_status_without_key(self):
        for status, message in [(401, "credential rejected"), (403, "access denied")]:
            with self.subTest(status=status), patch.object(tool, "check_curl"), \
                    patch.object(tool.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, f"private-test-key\n{status}".encode())) as run:
                with self.assertRaises(tool.AuthenticationError) as raised:
                    tool.request(tool.SERVICE + "/v1/match", "private-test-key")
                self.assertIn(f"HTTP {status}: {message}", str(raised.exception))
                self.assertNotIn("private-test-key", str(raised.exception))
                if status == 403:
                    self.assertNotIn("credential rejected", str(raised.exception))
                self.assertEqual(run.call_count, 1)

    def test_curl_security_options_and_stdin_credential(self):
        key = 'private\\key"value'
        body = b"binary\x00\n404\n"
        with patch.object(tool, "check_curl"), patch.dict(os.environ, {"SOCKET_API_KEY": key}), \
                patch.object(tool.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, body + b"\n200")) as run:
            self.assertEqual(tool.request(tool.SERVICE + "/v1/match?filename=[a-b]", key), body)
        command = run.call_args.args[0]
        self.assertEqual(command[:2], ["curl", "-q"])
        self.assertIn("--globoff", command)
        self.assertNotIn("--location", command)
        for option, value in [("--proto", "=https"), ("--max-redirs", "0"), ("--max-time", "20"),
                              ("--max-filesize", str(32 * 1024 * 1024)), ("--config", "-")]:
            self.assertEqual(command[command.index(option) + 1], value)
        self.assertEqual(run.call_args.kwargs["input"], b'header = "X-API-Key: private\\\\key\\"value"\n')
        self.assertNotIn(key, repr(command))
        self.assertNotIn("SOCKET_API_KEY", run.call_args.kwargs["env"])
        self.assertEqual(run.call_args.kwargs["stderr"], subprocess.DEVNULL)

    def test_credentials_only_reach_exact_service_origin(self):
        urls = ["https://art.example/image", tool.SERVICE + ".evil.example/image",
                tool.SERVICE + ":444/image", tool.SERVICE.replace("https://", "https://www.") + "/image"]
        for url in urls:
            with self.subTest(url=url), patch.object(tool, "check_curl"), \
                    patch.object(tool.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"image\n200")) as run:
                self.assertEqual(tool.request(url, "private-test-key"), b"image")
                self.assertEqual(run.call_args.kwargs["input"], b"")

    def test_invalid_url_and_credential_controls_never_start_curl(self):
        pairs = [("http://example.com/image", ""), ("https://user:pass@example.com/image", ""),
                 ("https:///image", ""), (tool.SERVICE + "/image\nheader=x", ""),
                 (tool.SERVICE, "key\r\nheader=x"), (tool.SERVICE, "key\tvalue"), (tool.SERVICE, "key\x00")]
        with patch.object(tool.subprocess, "run") as run:
            for url, key in pairs:
                with self.subTest(url=url), self.assertRaises(ValueError):
                    tool.request(url, key)
        run.assert_not_called()

    def test_redirect_and_permanent_http_error_are_not_retried(self):
        for code in [301, 302, 307, 308, 404]:
            with self.subTest(code=code), patch.object(tool, "check_curl"), \
                    patch.object(tool.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, f"body\n{code}".encode())) as run:
                with self.assertRaisesRegex(OSError, f"HTTP {code}"):
                    tool.request(tool.SERVICE, "private-test-key")
                self.assertEqual(run.call_count, 1)

    def test_timeout_transport_failure_and_retry_exhaustion(self):
        failures = [subprocess.TimeoutExpired(["curl"], 20), subprocess.CompletedProcess([], 28, b"\n000"),
                    subprocess.CompletedProcess([], 0, b"busy\n429")]
        for failure in failures:
            with self.subTest(failure=type(failure).__name__), patch.object(tool, "check_curl"), \
                    patch.object(tool.subprocess, "run", side_effect=[failure] * 3) as run, patch.object(tool.time, "sleep"):
                with self.assertRaises(OSError) as raised:
                    tool.request(tool.SERVICE, "private-test-key")
                self.assertNotIn("private-test-key", str(raised.exception))
                self.assertEqual(run.call_count, 3)

    def test_oversize_is_rejected_without_retry(self):
        with patch.object(tool, "check_curl"), \
                patch.object(tool.subprocess, "run", return_value=subprocess.CompletedProcess([], 63, b"partial")) as run:
            with self.assertRaisesRegex(ValueError, "exceeds 32 MiB"):
                tool.request(tool.SERVICE)
        self.assertEqual(run.call_count, 1)

    def test_curl_version_must_enforce_unknown_response_size(self):
        for version, accepted in [(b"curl 8.3.0", False), (b"curl 8.4.0", True), (b"curl 8.7.1", True), (b"bad", False)]:
            tool.check_curl.cache_clear()
            with self.subTest(version=version), patch.dict(os.environ, {"SOCKET_API_KEY": "private-test-key"}), \
                    patch.object(tool.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, version)) as run:
                if accepted:
                    tool.check_curl()
                    tool.check_curl()
                else:
                    with self.assertRaisesRegex(OSError, "curl 8.4"):
                        tool.check_curl()
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.args[0], ["curl", "-q", "--version"])
                self.assertNotIn("SOCKET_API_KEY", run.call_args.kwargs["env"])
        tool.check_curl.cache_clear()

    def test_filename_and_bad_response(self):
        self.assertEqual(tool.filename('  A:B?%  '), "A_B__")
        with self.assertRaises(ValueError):
            tool.match_info({"matched": True, "game": None}, "Title", "us")

    @unittest.skipUnless(shutil.which("sips"), "macOS sips is unavailable")
    def test_real_png_decoder_rejects_truncated_image(self):
        self.assertTrue(tool.png_bytes(IMAGE).startswith(tool.PNG))
        with self.assertRaises(ValueError):
            tool.png_bytes(tool.PNG + b"not an image")


if __name__ == "__main__":
    unittest.main()
