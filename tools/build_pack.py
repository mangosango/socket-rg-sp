"""Patch an extracted Socket resource tree in place, then write its BaseOS pack."""
import shutil
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

if __name__ == "__main__":  # The native CLI uses python -I.
    sys.path.insert(0, str(Path(__file__).resolve().parent))

import gdc2gd
import pack

patch_socket = __import__("patch-socket")
validate_version = patch_socket.validate_version

SCRIPTS = """scenes/main.gd scripts/game.gd scripts/autoload/manager.gd
scripts/autoload/settings_manager.gd scenes/screen_apps.gd scenes/screen_edit_platform.gd
scripts/autoload/theme_manager.gd scripts/screens/screen.gd scenes/focus_overlay.gd
scripts/cartridge.gd scenes/render_scale_3d.gd scenes/cartridge_carousel.gd
scenes/keyboard_avoider.gd scripts/models/scrapers/scraper_games_db.gd
scripts/autoload/retro_achievements.gd scripts/screens/screen_customize.gd""".split()
SHADERS = ["scenes/liquid_glass.gdshader", "materials/frosted_glass.gdshader", "scenes/paper_sticker.gdshader"]
MAX_DECODED = 8 * 1024 * 1024
PLUGIN = Path("addons/FrontendPlugin")
PLUGIN_SCRIPTS = """frontend_bridge folder_picker controller_dialog controls_hud artwork shader_startup
                    device_settings settings_form emulation_settings wifi_settings bluetooth_settings bluetooth_audio game_overlay""".split()


def use_source(dest, source):
    dest.with_suffix(".gd.remap").unlink(missing_ok=True)
    dest.with_suffix(".gdc").unlink(missing_ok=True)
    shutil.copyfile(source, dest)


def build_pack(res: Path, overlay: Path, out: Path, decompress=None):
    """Use a fresh extracted res tree. decompress(data, expected_size) defaults to native zstd."""
    scripts = SCRIPTS.copy()
    if (res / "scripts/autoload/romm.gdc").is_file():
        scripts.append("scripts/autoload/romm.gd")
    shaders = SHADERS.copy()
    if (res / "scenes/paper_sticker_body.gdshaderinc").is_file():
        shaders.append("scenes/paper_sticker_body.gdshaderinc")

    with TemporaryDirectory() as tmp:
        src = Path(tmp)
        decoded = {}
        remaining = MAX_DECODED
        for script in scripts:
            dest = src / script
            dest.parent.mkdir(parents=True, exist_ok=True)
            tokens = gdc2gd.load_tokens((res / script).with_suffix(".gdc"), decompress)
            decoded[script] = gdc2gd.render(tokens, min(remaining, gdc2gd.MAX_SOURCE)).encode("utf-8")
            remaining -= len(decoded[script])
            dest.write_bytes(decoded[script])
        for shader in shaders:
            (src / shader).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(res / shader, src / shader)
        patch_socket.main(src, res / "project.binary")
        for shader in shaders:
            shutil.copyfile(src / shader, res / shader)
        for script in scripts:
            if (src / script).read_bytes() != decoded[script]:
                use_source(res / script, src / script)

    for name in PLUGIN_SCRIPTS:
        script = PLUGIN / f"{name}.gd"
        use_source(res / script, overlay / script)
    controls = res / PLUGIN / "controls"
    shutil.copytree(overlay / PLUGIN / "controls", controls, dirs_exist_ok=True)
    (res / "shaders").mkdir(exist_ok=True)
    shutil.copyfile(overlay / "shaders/display_aa.gdshader", res / "shaders/display_aa.gdshader")

    # The second-screen extension has no Linux AArch64 build.
    thor = res / "addons/AynThor/bin"
    if thor.exists():
        shutil.rmtree(thor)
    cfg = res / ".godot/extension_list.cfg"
    lines = cfg.read_bytes().splitlines(keepends=True) if cfg.exists() else []
    cfg.write_bytes(b"".join(line for line in lines if b"AynThor" not in line))
    pack.main(res, out)


if __name__ == "__main__":
    build_pack(*(Path(arg) for arg in sys.argv[1:]))
