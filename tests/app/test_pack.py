"""Check the patched application sources in a built pack."""
import hashlib
from pathlib import Path
import struct
import re
import sys


with Path(sys.argv[1]).open("rb") as pack:
    pack.seek(24)
    base, directory = struct.unpack("<QQ", pack.read(16))
    pack.seek(directory)
    entries = {}
    for _ in range(struct.unpack("<I", pack.read(4))[0]):
        length = struct.unpack("<I", pack.read(4))[0]
        name = pack.read(length).rstrip(b"\0").decode()
        offset, size = struct.unpack("<QQ", pack.read(16))
        digest = pack.read(16)
        pack.read(4)
        entries[name] = (offset, size, digest)

    def source(name):
        assert name + ".remap" not in entries
        assert name.removesuffix(".gd") + ".gdc" not in entries
        offset, size, digest = entries[name]
        pack.seek(base + offset)
        data = pack.read(size)
        assert hashlib.md5(data).digest() == digest
        return data.decode()

    manager = source("scripts/autoload/manager.gd")
    scan = manager.split("func scan_platform_in_user(", 1)[1].split("\nfunc ", 1)[0]
    # The open failure must return before the first library change.
    guard = '\tif OS.get_name() == "Linux" and not platform.rom_folder_path.is_empty() and DirAccess.open(platform.rom_folder_path) == null:\n\t\tprint("BaseOS: cannot open ROM folder: ", platform.rom_folder_path)\n\t\treturn\n'
    assert guard in scan
    assert scan.index(guard) < scan.index("platform.games.clear()")
    assert scan.index(guard) < scan.index("FrontendBridge.get_files_in_dir(")
    assert 'FrontendBridge.open_folder_picker(rom_folder_path)' in source("scenes/screen_edit_platform.gd")
    sound = source("scripts/autoload/theme_manager.gd")
    screen = source("scripts/screens/screen.gd")
    label = source("scenes/paper_sticker.gdshader")
    bump = label.split("vec3 gloss_bump_normal(", 1)[1].split("vec3 fake_gloss(", 1)[0]
    assert bump.index("height = h;") < bump.index("if (fade == 0.0)") < bump.index("vec2 grad")
    assert "return normalize(n);" in bump
    assert label.index("if (enable_diffraction) {") < label.index("vec3 grating_axis =")
    assert label.index("if (enable_diffraction) {") < label.index("vec3 view_tilted =")
    assert "noise_tex.rgb * 2.0" not in label
    shell = source("materials/frosted_glass.gdshader")
    blur = shell.split("vec3 gaussian_blur(", 1)[1].split("\n}", 1)[0]
    assert blur.count("textureLod(") == 5
    assert "Five taps retain the bright center" in shell
    assert "const int BLUR_TAPS = 4;" in source("scenes/liquid_glass.gdshader")
    assert "set_process(OS.get_environment(\"SOCKET_FPS_DIAGNOSTICS\") == \"1\")" in source("scenes/render_scale_3d.gd")

    display_aa = source("shaders/display_aa.gdshader")
    assert display_aa == (Path(__file__).resolve().parents[2] / "overlay/shaders/display_aa.gdshader").read_text()
    assert 'load("res://shaders/display_aa.gdshader")' in source("scenes/render_scale_3d.gd")

    def method(text, name):
        return "func " + name + "(" + re.split(r"\n(?:static )?func ", text.split("func " + name + "(", 1)[1], maxsplit=1)[0]

    if len(sys.argv) > 2:
        work = Path(sys.argv[2]).parent
        scanner = """extends RefCounted
signal user_updated
var FrontendBridge
var saved = 0
class Game:
    var rom_name
    var rom_path
    var platform_id
    var is_new
    var added_at
func _get_app_by_id(_model, _app_id) -> Dictionary:
    return {"acceptedFilenameRegex": "[.]gba$"}
func _filter_duplicate_games(games): return games
func scrape_platform_in_user(_user, _platform): pass
func save_user(): saved += 1
"""
        scanner += method(manager, "scan_platform_in_user").replace("user: User, platform: Platform", "user, platform").replace("OS.get_name()", '\"Linux\"')
        # Only the Linux branch runs in this test.
        scanner = re.sub(r"var all_paths: = _list_files_recursive\(.*\)", "var all_paths: Array[String] = []", scanner)
        for name in ("_compile_filename_regex", "_get_cue_titles", "_is_rom_file"):
            scanner += "\n" + method(manager, name)
        Path(sys.argv[2]).write_text(scanner.replace("    ", "\t"))
        audio = "extends Node\nvar SettingsManager\n" + method(sound, "_enter_tree") + "\n" + method(sound, "_apply_ui_sounds_enabled")
        (work / "sound.gd").write_text(audio)
        focus = "extends Control\nvar _screens: Array = []\nvar _disabled_focus_controls: Array[Control] = []\nvar _audio: AudioStreamPlayer\n"
        for name in ("_enter_tree", "_disable_background_focus", "_collect_and_disable_focus", "_restore_background_focus"):
            focus += "\n" + method(screen, name).replace("node is Screen", "node.get_script() == get_script()")
        (work / "screen_focus.gd").write_text(focus)
        editor = "extends RefCounted\nvar Manager\nvar ScreenDialog\nvar platform\nvar rom_folder_path = \"\"\nvar scan_subfolders_toggle\nvar hide_duplicates_toggle\nfunc _get_selected_app_id(): return \"selected.core\"\n"
        editor += "\n" + method(source("scenes/screen_edit_platform.gd"), "_on_button_scan_pressed")
        (work / "scan_editor.gd").write_text(editor)
        for name in ("default_bus_layout.tres.remap",):
            offset, size, _ = entries[name]
            pack.seek(base + offset)
            remap = pack.read(size).decode()
            target = remap.split('path="res://', 1)[1].split('"', 1)[0]
            offset, size, _ = entries[target]
            pack.seek(base + offset)
            (work / "bus_layout.res").write_bytes(pack.read(size))
    for script in ("frontend_bridge.gd", "folder_picker.gd", "controls_hud.gd"):
        name = "addons/FrontendPlugin/" + script
        assert source(name) == (Path(__file__).resolve().parents[2] / "overlay" / name).read_text()
    bridge = source("addons/FrontendPlugin/frontend_bridge.gd")
    assert "RenderingServer.directional_shadow_atlas_set_size(1024, true)" in method(bridge, "_enter_tree")
    assert "get_file_as_string" not in method(bridge, "_read_sys")
    assert "get_line()" in method(bridge, "_read_sys")

print("PASS: packed sources, hashes, scan-open failure guard, picker caller and runtime test sources")
