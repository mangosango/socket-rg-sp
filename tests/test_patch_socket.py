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
        before = (tmp / "project.binary").read_bytes()
        result = subprocess.run([sys.executable, "-I", str(ROOT / "tools/patch-socket.py"), str(tmp),
                                 str(tmp / "project.binary")], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((tmp / "project.binary").read_bytes(), before)
        for path in files:
            self.assertEqual((tmp / path).read_text(), STUB)
        return result.stderr

    def test_reads_version(self):
        with tempfile.TemporaryDirectory() as tmp:
            project_binary(Path(tmp) / "project.binary", "0.3.2")
            self.assertEqual(patch_socket.socket_version(Path(tmp) / "project.binary"), "0.3.2")

    def test_version_check_rejects_corrupt_or_unknown_versions_without_echoing_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "project.binary"
            project_binary(path, "private-text")
            unsupported = path.read_bytes()
            project_binary(path, "0.10.1")
            supported = path.read_bytes()
            self.assertEqual(patch_socket.validate_version(path), "0.10.1")
            # A version-shaped substring inside another value is not a version setting.
            nested = b"ECFG" + struct.pack("<II", 1, 1) + b"x" + struct.pack("<I", len(supported)) + supported
            for data in (unsupported, supported[:-1], supported[:8] + b"\xff" * 4, nested,
                         supported + bytes(1024 * 1024)):
                path.write_bytes(data)
                with self.assertRaisesRegex(ValueError, r"^Socket version is not supported; use 0\.10\.1 or 0\.8\.0 or 0\.3\.2$"):
                    patch_socket.validate_version(path)

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

    def patched(self, path, version, source):
        for edit_path, pattern, repl, count, flags, *versions in patch_socket.EDITS:
            if edit_path == path and (not versions or version in versions):
                source, matches = re.subn(pattern, repl, source, flags=flags)
                self.assertEqual(matches, count, pattern)
        return source

    def test_startup_hook_makes_small_text_clean_before_the_warmup(self):
        for version in patch_socket.VERSIONS:
            hook = self.patched("scenes/main.gd", version, 'extends Node\nfunc _ready() -> void:\n\tpass\n')
            self.assertTrue(hook.split("func _ready() -> void:\n", 1)[1].startswith('\tif OS.get_name() == "Linux":\n\t\tvar window: = get_tree().root\n'))
            for text in ('window.snap_2d_vertices_to_pixel = OS.get_environment("SOCKET_UI_SNAP") != "0"',
                         'if OS.get_environment("SOCKET_UI_FONT") != "0":', "load(path).oversampling = 0.0",
                         "window.oversampling_override = 2.0 * ui_scale if ui_scale < 1.0 else 0.0", "window.size_changed.connect(fit)"):
                self.assertLess(hook.index(text), hook.index("shader_startup.gd"), text)
            self.assertEqual(hook.count("DepartureMono-Regular."), 2)
            self.assertNotIn("    ", hook, "Socket sources use tabs")

    def test_render_candidates_keep_the_defaults_without_variables(self):
        modern = ("extends SubViewport\n\nfunc _ready() -> void:\n\t_display.texture = get_texture()\n\tmsaa_3d = Viewport.MSAA_2X\n\t_apply()\n\n"
                  "func _apply() -> void:\n\tvar pixels: = native if requested.x > native.x else requested\n")
        legacy = "extends SubViewport\n\nfunc _ready() -> void:\n\tpass\n\nfunc _apply(scale: float) -> void:\n\tpass\n"
        handler = "\nfunc _on_setting_changed(key: String, new_value: Variant) -> void:\n\tpass\n"
        for version in patch_socket.VERSIONS:
            with self.subTest(version=version):
                view = self.patched(patch_socket.RENDER_SCALE, version, (legacy if version == "0.3.2" else modern) + handler)
                self.assertIn("var _baseos_cap: = 1.0\n", view)
                self.assertIn("native * minf(", view)
                self.assertNotIn("2.0 / 3.0)", view)
                # Each candidate needs its variable. The shader define keeps its escape.
                for text in ('if cap.is_valid_float():\n\t\t_baseos_cap = clampf(cap.to_float(), 0.05, 1.0)',
                             '_baseos_apply_msaa(bool(SettingsManager.get_setting("cartridge_msaa")))',
                             # One shadow pass is the default. "0" removes the shadow map and "4" keeps four splits.
                             'var shadow_map: = shadows != "0"',
                             'if not shadow_map:\n\t\t\tlight.shadow_enabled = false',
                             'elif shadows != "4":\n',
                             'if OS.get_environment("SOCKET_3D_FILTER") == "linear":',
                             'linear.code = "#define DISPLAY_LINEAR\\n" + display_material.shader.code',
                             'display_material.shader = load("res://shaders/display_aa.gdshader")',
                             '"p95_frame_ms"', '"nav_p95_ms"', '"stall_ms"', '"new_shaders_3d"', '"shader_startup"', '"shader_cache_files_at_start"'):
                    self.assertIn(text, view)
                for name in patch_socket.BENCH_NAMES:
                    self.assertIn(name, view)
                # The separate tonemap pass exists only with the shadow map.
                self.assertEqual('if SettingsManager.get_setting("high_res_labels"):' in view, version == "0.10.1")
                self.assertEqual("world.environment.adjustment_enabled = shadow_map\n" in view, version != "0.3.2")
                self.assertNotIn("    ", view, "Socket sources use tabs")
        avoider = self.patched(patch_socket.KEYBOARD_AVOIDER, "0.3.2", STUB)
        self.assertIn('get_node("MainScreen/SubViewport").snap_2d_vertices_to_pixel = OS.get_environment("SOCKET_UI_SNAP") != "0"', avoider)
        self.assertIn('viewport.oversampling_override = 2.0 * pixels.x / container.size.x if OS.get_environment("SOCKET_UI_FONT") != "0" else 0.0', avoider)

    def test_light_ui_reads_no_screen_and_does_no_work_on_a_steady_frame(self):
        glass = ("uniform sampler2D screen_texture : hint_screen_texture, filter_linear, repeat_disable;\n"
                 "vec3 blurred_screen(vec2 uv) {\n\treturn texture(screen_texture, uv).rgb;\n}\n"
                 "void fragment() {\n\tvec3 bg = blurred_screen(warped_uv, chroma_offset, SCREEN_PIXEL_SIZE);\n}\n")
        for version in patch_socket.VERSIONS:
            with self.subTest(version=version):
                main = self.patched("scenes/main.gd", version, "extends Node\n\nfunc _ready() -> void:\n\tpass\n")
                self.assertEqual("func _baseos_light_ui()" in main, version == "0.10.1")
                if version != "0.10.1":
                    continue
                self.assertLess(main.index('if OS.get_environment("SOCKET_UI_LIGHT") != "0":\n\t\t\t_baseos_light_ui()'), main.index("shader_startup.gd"))
                sync = main[main.index("func _baseos_glass_sync()"):]
                # The guards and the compare come before each material write, and the frame path has no scene search.
                self.assertLess(sync.index("get_tree().paused"), sync.index("if inputs == _baseos_glass_inputs:\n\t\treturn"))
                self.assertLess(sync.index("if inputs == _baseos_glass_inputs:\n\t\treturn"), sync.index("set_shader_parameter"))
                self.assertNotIn("find_child", sync)
                self.assertNotIn("    ", main, "Socket sources use tabs")
                shader = self.patched("scenes/liquid_glass.gdshader", version, glass + "const int BLUR_TAPS = 8;\n")
                flat = re.sub(r"#ifdef GLASS_FLAT\n(.*?)(?:#else\n.*?)?#endif\n", r"\1", re.sub(r"#ifndef GLASS_FLAT\n.*?#endif\n", "", shader, flags=re.S), flags=re.S)
                self.assertNotIn("screen_texture", flat)
                self.assertIn("vec3 bg = mix(backdrop_color.rgb, fog.rgb, fog.a);", flat)
                screen = re.sub(r"#ifdef GLASS_FLAT\n.*?(?:#else\n(.*?))?#endif\n", r"\1", shader, flags=re.S).replace("#ifndef GLASS_FLAT\n", "").replace("#endif\n", "")
                # Without the define, the shader is the Socket shader with fewer blur taps.
                self.assertEqual(re.sub(r"// [^\n]*\n", "", screen).replace("BLUR_TAPS = 4", "BLUR_TAPS = 8"), glass + "const int BLUR_TAPS = 8;\n")

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
