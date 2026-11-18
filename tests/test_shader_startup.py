"""Source contracts only; actual GPU shader efficacy requires target hardware."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "overlay/addons/FrontendPlugin/shader_startup.gd"


class ShaderStartupContracts(unittest.TestCase):
    def test_headless_returns_before_rendering_or_input_gate(self):
        source = HELPER.read_text()
        run = source.split("static func run(", 1)[1].split("\nfunc ", 1)[0]
        skip = run.index('DisplayServer.get_name() == "headless"')
        gate = run.index("main.process_mode = Node.PROCESS_MODE_DISABLED")
        self.assertLess(skip, run.index("\n\t\treturn", skip))
        self.assertLess(run.index("\n\t\treturn", skip), gate)
        self.assertLess(gate, run.index("await "))
        self.assertLess(run.index("tree.paused = true"), run.index("await "))
        self.assertIn("main.tree_exiting.connect(startup.queue_free, CONNECT_ONE_SHOT)", run)
        self.assertNotIn('"socket_shader_startup_warmed", true', run[:gate])

    def test_render_replay_is_not_resource_loading_or_a_persistent_marker(self):
        source = HELPER.read_text()
        self.assertIn('label.text = "Compiling shaders"', source)
        self.assertIn("await RenderingServer.frame_post_draw", source)
        self.assertIn("SubViewport.UPDATE_ALWAYS", source)
        self.assertIn("for platform_id in Manager.db.platforms:", source)
        self.assertIn("script.get_script_constant_map()", source)
        self.assertIn('scene.resource_path + ":" + str(model.is_disc_shaped)', source)
        self.assertIn("seen.has(key)", source)
        self.assertIn("seen[key] = true", source)
        self.assertNotIn("added_platforms", source)
        for disk_api in ("FileAccess.", "DirAccess.", "ResourceSaver.", "OS.execute("):
            self.assertNotIn(disk_api, source, "warmup must not delete cache or save a done marker")

    def test_status_uses_palette_and_native_scaling_not_hardware_brightness(self):
        source = HELPER.read_text()
        ui = source.split("func _ready()", 1)[1].split("func _input(", 1)[0]
        self.assertIn('ResourceLoader.exists("res://scripts/theme_palette.gd")', ui)
        self.assertIn('palette.has_method("recolor_surface")', ui)
        self.assertIn('palette.has_method("recolor_ink")', ui)
        self.assertIn('theme_manager.has_method("get_active_theme")', ui)
        self.assertEqual(ui.count('set_meta("socket_adaptive_surface", true)'), 2)
        self.assertIn('get_stretch_transform().affine_inverse()', ui)
        self.assertIn('_font_oversampling = _window.is_using_font_oversampling()', ui)
        self.assertIn('_window.set_use_font_oversampling(false)', ui)
        teardown = source.split('func _exit_tree()', 1)[1]
        self.assertIn('_window.set_use_font_oversampling(_font_oversampling)', teardown)
        self.assertIn('add_theme_font_size_override("font_size", 24)', ui)
        self.assertNotIn("brightness", source)
        self.assertNotIn("SettingsManager", source)
        self.assertNotIn("ThemePalette.", source, "legacy releases must not statically require palette APIs")

    def test_synthetic_materials_do_not_modify_shared_defaults_or_obey_gilding(self):
        source = HELPER.read_text()
        duplicate = source.index("cart.default_label_material = cart.default_label_material.duplicate()")
        self.assertLess(duplicate, source.index("cart.set_game(game)"))
        self.assertIn("CartFinishBank.build(finish.id, finish.fallback_color, cart.casing_maps())", source)
        self.assertNotIn("cart.update_material(", source)

    def test_build_installs_helper_and_decodes_main(self):
        source = (ROOT / "tools/build-pack.sh").read_text()
        self.assertIn("scenes/main.gd", source)
        self.assertIn("use_source addons/FrontendPlugin/shader_startup.gd", source)


if __name__ == "__main__":
    unittest.main()
