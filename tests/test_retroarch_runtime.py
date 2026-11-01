"""Check launcher settings and optional RetroArch startup and shaders in Docker."""

import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "card/System/socket/retroarch/retroarch.cfg"
LAUNCHER = ROOT / "card/System/socket/launch_game.sh"


class RetroArchLauncherTests(unittest.TestCase):
    def test_creates_configured_directories_before_exec_and_tags_only_proxy(self):
        with tempfile.TemporaryDirectory(prefix="retroarch-test-") as directory:
            root = Path(directory)
            sdcard = root / "sdcard"
            sys = root / "sys"
            udev = root / "udev"
            udev.mkdir()
            runtime = root / "run"
            (root / "retroarch").mkdir()
            for path in CONFIG.parent.glob("*.cfg"):
                (root / "retroarch" / path.name).write_text(path.read_text())
            # BTN_SOUTH is bit 48 of the fifth 64-bit word from the right.
            for index, name in enumerate(("physical pad", "Socket H700 Gamepad")):
                device = sys / f"event{index}/device"
                (device / "capabilities").mkdir(parents=True)
                (device / "name").write_text(name + "\n")
                (device / "capabilities/key").write_text("1000000000000 0 0 0 0\n")
                (device.parent / "dev").write_text(f"13:{index}\n")
                (udev / f"c13:{index}").write_text("E:ID_INPUT_JOYSTICK=1\n")

            checks = []
            for line in CONFIG.read_text().splitlines():
                if line.startswith(("savefile_directory =", "savestate_directory =", "screenshot_directory =")):
                    path = line.split('"')[1].replace("/mnt/sdcard", str(sdcard))
                    checks.append(f"[ -d {shlex.quote(path)} ] || exit 99")
            args = root / "args"
            loader = root / "loader"
            loader.write_text("#!/bin/sh\n" + "\n".join(checks) +
                              f"\nprintf '%s\\n' \"$@\" > {shlex.quote(str(args))}\n")
            loader.chmod(0o755)
            script = root / "launch_game.sh"
            script.write_text(LAUNCHER.read_text()
                              .replace("/mnt/sdcard", str(sdcard))
                              .replace("/sys/class/input", str(sys))
                              .replace("/run/udev/data", str(udev))
                              .replace('${SOCKET_RUN:-/tmp/socket}', str(runtime))
                              .replace("/lib/ld-linux-aarch64.so.1", shlex.quote(str(loader))))
            (root / "cores").mkdir()
            for name in ("mgba", "gpsp", "snes9x"):
                (root / "cores" / (name + "_libretro.so")).touch()
            rom = root / "test game.gba"
            rom.touch()
            command = ["sh", str(script), "mgba", str(rom), "gba"]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((udev / "c13:0").exists())
            self.assertEqual((runtime / "game.descriptor").read_text(),
                             f"socket-resume-v1\nmgba\n{rom}\ngba\n")
            self.assertTrue((runtime / "game.active").read_text().strip().isdigit())
            self.assertEqual((udev / "c13:1").read_text(), "E:ID_INPUT=1\nE:ID_INPUT_JOYSTICK=1\n")
            self.assertEqual(args.read_text().splitlines(), [
                str(root / "retroarch/retroarch"), "--verbose", "--config",
                str(root / "retroarch/retroarch.cfg"), "--appendconfig",
                str(runtime / "retroarch.cfg"), "--set-shader",
                str(root / "retroarch/shaders/lcd3x.glslp"), "-L",
                str(root / "cores/mgba_libretro.so"), str(rom),
            ])
            for core, platform, profile in (("mgba", "gb", "gb"), ("mgba", "gbc", "gbc"),
                                             ("gpsp", "gba", "gba"), ("snes9x", "snes", None),
                                             ("mgba", "../../outside", None)):
                with self.subTest(core=core, platform=platform):
                    result = subprocess.run(["sh", str(script), core, str(rom), platform],
                                            capture_output=True, text=True)
                    if platform == "../../outside":
                        self.assertNotEqual(result.returncode, 0)
                        continue
                    self.assertEqual(result.returncode, 0, result.stderr)
                    actual = args.read_text().splitlines()
                    self.assertEqual("--appendconfig" in actual, profile is not None)
                    if profile:
                        self.assertEqual(actual[actual.index("--appendconfig") + 1],
                                         str(runtime / "retroarch.cfg"))
                        shader = "lcd3x" if platform == "gba" else "grid"
                        self.assertEqual(actual[actual.index("--set-shader") + 1],
                                         str(root / f"retroarch/shaders/{shader}.glslp"))
                        profile_text = (runtime / "retroarch.cfg").read_text()
                        self.assertIn((CONFIG.parent / f"{profile}.cfg").read_text(), profile_text)
                    self.assertEqual(actual[-2:], [str(root / f"cores/{core}_libretro.so"),
                                                  str(rom)])
            result = subprocess.run(command, env=dict(os.environ, SOCKET_RESUME_LOAD="1"),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('savestate_auto_load = "false"', (runtime / "retroarch.cfg").read_text())
            args.unlink()
            (sdcard / "Screenshots").rmdir()
            (sdcard / "Screenshots").write_text("blocked path")
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(args.exists(), "Do not start RetroArch when output directories cannot be created")

    def test_core_options_follow_rom_header_and_leave_installed_options_unchanged(self):
        with tempfile.TemporaryDirectory(prefix="retroarch-settings-") as directory:
            root = Path(directory)
            run = root / "run"
            bios = root / "BIOS/gba_bios.bin"
            bios.parent.mkdir()
            bios.write_bytes(b"\x18" + bytes(16383))
            (root / "retroarch").mkdir()
            installed = {}
            for path in CONFIG.parent.glob("*.cfg"):
                installed[path.name] = path.read_text()
                (root / "retroarch" / path.name).write_text(path.read_text())
            script = root / "launch_game.sh"
            script.write_text(LAUNCHER.read_text()
                              .replace("/mnt/sdcard", str(root))
                              .replace("/sys/class/input", str(root / "input"))
                              .replace("/run/udev/data", str(root / "udev"))
                              .replace('${SOCKET_RUN:-/tmp/socket}', str(run))
                              .replace("/lib/ld-linux-aarch64.so.1", "true"))
            (root / "cores").mkdir()
            for name in ("mgba", "gpsp"):
                (root / "cores" / (name + "_libretro.so")).touch()
            rom = root / "header.gb"
            cases = (("mgba", "gb", 0, None, "Game Boy", "GBC", "Auto", None),
                     ("mgba", "gb", 128, None, "Autodetect", "GBC", "GBC Dark Green →A", None),
                     ("mgba", "gbc", 0, None, "Game Boy", "Auto", "Auto", None),
                     ("mgba", "gbc", 192, None, "Autodetect", "Auto", "GBC Dark Green →A", None),
                     ("mgba", "gba", 0, 65, "Autodetect", "Auto", "GBC Dark Green →A", "ON"),
                     ("mgba", "gba", 0, 77, "Autodetect", "Auto", "GBC Dark Green →A", "OFF"),
                     ("mgba", "gb", None, None, "Autodetect", "GBC", "GBC Dark Green →A", None),
                     ("mgba", "gb", -1, None, "Autodetect", "GBC", "GBC Dark Green →A", None),
                     ("mgba", "gba", None, None, "Autodetect", "Auto", "GBC Dark Green →A", "OFF"))
            for core, platform, cgb, code, model, correction, palette, gbp in cases:
                with self.subTest(platform=platform, cgb=cgb, code=code):
                    if cgb is None:
                        rom.unlink(missing_ok=True)
                    elif cgb == -1:
                        rom.write_bytes(b"short header")
                    else:
                        header = bytearray(0x150)
                        header[0x143] = cgb
                        header[0xAC] = code or 0
                        rom.write_bytes(header)
                    result = subprocess.run(["sh", str(script), core, str(rom), platform],
                                            capture_output=True, text=True)
                    if cgb is None:
                        self.assertNotEqual(result.returncode, 0)
                        continue
                    self.assertEqual(result.returncode, 0, result.stderr)
                    options = (run / "retroarch-core-options.cfg").read_text()
                    keys = [line.split("=", 1)[0].strip() for line in options.splitlines()
                            if "=" in line and not line.startswith("#")]
                    self.assertEqual(len(keys), len(set(keys)), "RetroArch uses the first duplicate key")
                    for key, value in (("mgba_gb_model", model), ("mgba_color_correction", correction),
                                       ("mgba_gb_colors", palette)):
                        self.assertIn(f'{key} = "{value}"\n', options)
                    if gbp:
                        self.assertIn(f'mgba_force_gbp = "{gbp}"\n', options)
            rom.write_bytes(bytes(0x150))
            for valid_bios in (True, False):
                if not valid_bios:
                    bios.write_bytes(b"invalid")
                result = subprocess.run(["sh", str(script), "gpsp", str(rom), "gba"],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual('gpsp_boot_mode = "bios"' in (run / "retroarch-core-options.cfg").read_text(),
                                 valid_bios)
            for name, content in installed.items():
                self.assertEqual((root / "retroarch" / name).read_text(), content)
            preferences = root / "Saves/socket/retroarch"
            (preferences / "gba.cfg").write_text('video_shader_enable = "false"\nfastforward_ratio = "2.0"\n')
            (preferences / "mgba-gba-options.cfg").write_text(
                'mgba_color_correction = "OFF"\nmgba_force_gbp = "ON"\n')
            header = bytearray(0x150)
            header[0xAC] = 77
            rom.write_bytes(header)
            result = subprocess.run(["sh", str(script), "mgba", str(rom), "gba"],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            options = (run / "retroarch-core-options.cfg").read_text()
            self.assertIn('mgba_color_correction = "OFF"', options)
            self.assertNotIn('mgba_color_correction = "Auto"', options)
            self.assertIn('mgba_force_gbp = "OFF"', options)
            self.assertNotIn('mgba_force_gbp = "ON"', options)
            profile = (run / "retroarch.cfg").read_text()
            self.assertIn('video_shader_enable = "false"', profile)
            self.assertNotIn('video_shader_enable = "true"', profile)
            (run / "retroarch-core-options.cfg").unlink()
            (run / "retroarch-core-options.cfg").mkdir()
            result = subprocess.run(["sh", str(script), "mgba", str(rom), "gb"],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, "Stop when runtime options cannot be written")

    def test_disables_keyboard_fallback(self):
        self.assertIn('rgui_show_start_screen = "false"', CONFIG.read_text().splitlines())

    def test_volume_buttons_preserve_game_bindings(self):
        settings = dict(line.split(" = ", 1) for line in CONFIG.read_text().splitlines()
                        if " = " in line and not line.startswith("#"))
        for name, button in (("hold_fast_forward", 10), ("rewind", 9)):
            self.assertEqual(settings[f"input_{name}_btn"], f'"{button}"')
        for name in ("volume_up", "volume_down"):
            self.assertEqual(settings[f"input_{name}_btn"], '"nul"')
        self.assertEqual(settings["audio_volume"], '"-20.0"')
        self.assertEqual(settings["input_enable_hotkey_btn"], '"nul"')

    def test_hides_startup_messages_without_hiding_warnings(self):
        settings = dict(line.split(" = ", 1) for line in CONFIG.read_text().splitlines()
                        if " = " in line and not line.startswith("#"))
        for key in ("autoconfig", "remap_load", "config_override_load", "save_state", "refresh_rate"):
            self.assertEqual(settings[f"notification_show_{key}"], '"false"')
        self.assertNotEqual(settings.get("video_font_enable"), '"false"')


class RetroArchSlotSettingsTests(unittest.TestCase):
    def test_slot_playback_and_handheld_profiles(self):
        def settings(path):
            return dict(line.split(" = ", 1) for line in path.read_text().splitlines()
                        if " = " in line and not line.startswith("#"))

        base = settings(CONFIG)
        for key, value in (("fastforward_ratio", "4.0"), ("audio_fastforward_mute", "false"),
                           ("savestate_auto_load", "true"), ("savestate_auto_save", "false"),
                           ("rewind_enable", "true"), ("input_menu_toggle_btn", "8"),
                           ("rewind_granularity", "2"), ("video_threaded", "false"),
                           ("aspect_ratio_index", "22")):
            self.assertEqual(base[key], f'"{value}"')
        for platform, shader, correction in (("gb", "grid", "GBC"), ("gbc", "grid", "Auto"),
                                              ("gba", "lcd3x", "Auto")):
            profile = base | settings(CONFIG.parent / f"{platform}.cfg")
            self.assertEqual(profile.get("video_scale_integer", '"false"'),
                             '"false"' if platform == "gba" else '"true"')
            options_path = CONFIG.parent / ("gb-core-options.cfg" if platform == "gb" else "core-options.cfg")
            options = settings(options_path)
            self.assertEqual(options["mgba_color_correction"], f'"{correction}"')
            self.assertEqual(options["mgba_interframe_blending"], '"OFF"')
            # DMG keeps every frame. Color and GBA skip a draw only before an audio underrun.
            self.assertEqual(options["mgba_frameskip"], '"disabled"' if platform == "gb" else '"auto"')
            self.assertEqual(options["mgba_sgb_borders"], '"OFF"')
            preset_path = CONFIG.parent / "shaders" / f"{shader}.glslp"
            self.assertNotIn("video_shader", profile)
            self.assertEqual(profile["game_specific_options"], '"false"')
            self.assertEqual(profile["global_core_options"], '"true"')
            self.assertEqual(profile["video_shader_enable"], '"true"')
            preset = settings(preset_path)
            self.assertTrue((preset_path.parent / preset["shader0"].strip('"')).is_file())
            self.assertEqual(preset["SLOT_GRID"], '"0.0"' if platform == "gba" else '"1.0"')
        self.assertEqual(settings(CONFIG.parent / "gb-core-options.cfg")["mgba_gb_colors"], '"Auto"')
        options = settings(CONFIG.parent / "core-options.cfg")
        self.assertEqual(options["gpsp_color_correction"], '"enabled"')
        self.assertEqual(options["gpsp_frameskip"], '"auto"')


@unittest.skipUnless(os.environ.get("RETROARCH_DOCKER_TEST") == "1",
                     "Set RETROARCH_DOCKER_TEST=1 to test the built ARM64 binary")
class RetroArchNoKeyboardTests(unittest.TestCase):
    def test_no_input_devices_before_and_after_config_fix(self):
        self.assertTrue((ROOT / "work/RetroArch/retroarch").is_file())
        script = r'''
set -eu
test ! -d /dev/input
mkdir -p /mnt/sdcard/Saves/retroarch /mnt/sdcard/Screenshots
sed "s/rgui_show_start_screen = \"false\"/rgui_show_start_screen = \"$1\"/" /project/card/System/socket/retroarch/retroarch.cfg > /tmp/test.cfg
cat > /tmp/headless.cfg <<'EOF'
video_driver = "null"
video_context_driver = "null"
audio_driver = "null"
menu_driver = "null"
EOF
exec /project/work/RetroArch/retroarch --verbose --config /tmp/test.cfg --appendconfig /tmp/headless.cfg --menu --max-frames 2
'''
        for start_screen in ("true", "false"):
            with self.subTest(start_screen=start_screen):
                result = subprocess.run([
                    "docker", "run", "--rm", "--platform", "linux/arm64",
                    "-v", f"{ROOT}:/project:ro", "socket-baseos-godot",
                    "sh", "-c", script, "sh", start_screen,
                ], capture_output=True, text=True, timeout=30)
                log = result.stdout + result.stderr
                self.assertIn("Couldn't open any keyboard, mouse or touchpad", log)
                if start_screen == "true":
                    self.assertNotEqual(result.returncode, 0, log)
                    self.assertIn("forcing fallback to linuxraw", log)
                    self.assertIn("Cannot initialize input driver", log)
                else:
                    self.assertEqual(result.returncode, 0, log)
                    self.assertIn('Found joypad driver: "udev"', log)
                    self.assertNotIn("forcing fallback to linuxraw", log)
                    self.assertNotIn("Cannot initialize input driver", log)
                    self.assertNotIn("is not a directory, ignoring", log)
                    self.assertNotIn("is not an existing directory, ignoring", log)


@unittest.skipUnless(os.environ.get("RETROARCH_SHADER_SMOKE") == "1",
                     "Set RETROARCH_SHADER_SMOKE=1 with Docker and read-only GB/GBC/GBA content")
class RetroArchShaderRuntimeTests(unittest.TestCase):
    def test_launcher_loads_presets_and_session_options(self):
        card = Path(os.environ.get("RETROARCH_CORE_SMOKE_ROOT", "/Volumes/BASEOS"))
        script = r'''
set -eu
cc -shared -fPIC /project/tests/retroarch_headless_egl.c -o /tmp/headless.so -ldl -lEGL
mkdir -p /mnt/sdcard/System/socket/retroarch /mnt/sdcard/System/socket/cores
cp /project/card/System/socket/retroarch/*.cfg /mnt/sdcard/System/socket/retroarch/
cp -r /project/card/System/socket/retroarch/shaders /mnt/sdcard/System/socket/retroarch/
ln -s /card/System/socket/cores/mgba_libretro.so /mnt/sdcard/System/socket/cores/mgba_libretro.so
ln -s /card/System/socket/cores/gpsp_libretro.so /mnt/sdcard/System/socket/cores/gpsp_libretro.so
sed 's|/lib/ld-linux-aarch64.so.1 "$SYS/retroarch/retroarch"|/project/work/RetroArch/retroarch --max-frames 120|' /project/card/System/socket/launch_game.sh > /mnt/sdcard/System/socket/launch_game.sh
cat >> /mnt/sdcard/System/socket/retroarch/retroarch.cfg <<'EOF'
video_shader_delay = "0"
audio_device = "null"
midi_driver = "null"
frontend_log_level = "0"
rgui_config_directory = "/tmp/config"
EOF
# Conflicting saved options must not override the session options.
mkdir -p /tmp/config/mGBA
for name in mGBA "$3" "$4"; do
    printf 'mgba_color_correction = "OFF"\nmgba_frameskip = "auto"\n' > "/tmp/config/mGBA/$name.opt"
done
if [ "$5" = before ]; then
    sed -i 's/--set-shader "$SYS\/retroarch\/shaders\/$shader.glslp"//' /mnt/sdcard/System/socket/launch_game.sh
    sed -i 's/game_specific_options = "false"/game_specific_options = "true"/; s/global_core_options = "true"/global_core_options = "false"/' /mnt/sdcard/System/socket/retroarch/"$2.cfg"
fi
EGL_PLATFORM=surfaceless LD_PRELOAD=/tmp/headless.so sh /mnt/sdcard/System/socket/launch_game.sh "$6" "$1" "$2"
'''
        for core, platform, mode in (("mgba", "gb", "before"), ("mgba", "gb", "after"),
                                     ("mgba", "gbc", "after"), ("mgba", "gba", "after"),
                                     ("gpsp", "gba", "after")):
            with self.subTest(core=core, platform=platform, mode=mode):
                roms = sorted(path for path in (card / "Games" / platform.upper()).glob(f"*.{platform}")
                              if not path.name.startswith("._"))
                self.assertTrue(roms, f"No {platform} fixture in {card}")
                rom = roms[0]
                result = subprocess.run([
                    "docker", "run", "--rm", "--platform", "linux/arm64",
                    "-v", f"{ROOT}:/project:ro", "-v", f"{card}:/card:ro",
                    "socket-baseos-godot", "sh", "-c", script, "sh",
                    "/card/" + str(rom.relative_to(card)), platform, rom.stem, platform.upper(), mode, core,
                ], capture_output=True, text=True, timeout=60)
                log = result.stdout + result.stderr
                self.assertEqual(result.returncode, 0, log)
                if mode == "before":
                    self.assertIn("Stock GLSL shaders will be used", log)
                    self.assertIn('GET_VARIABLE: mgba_color_correction = "OFF"', log)
                    self.assertNotIn('[Shaders] Load parameter value: "SLOT_GRID"', log)
                    self.assertIn('GET_VARIABLE: mgba_frameskip = "auto"', log)
                    self.assertIn("Setting audio latency to 128 ms", log)
                    continue
                grid = "0" if platform == "gba" else "1"
                self.assertIn(f'[Shaders] Load parameter value: "SLOT_GRID" = {grid}.000000', log)
                correction = "GBC" if platform == "gb" else "Auto"
                if core == "gpsp":
                    correction = "enabled"
                self.assertIn(f'GET_VARIABLE: {core}_color_correction = "{correction}"', log)
                self.assertNotIn("Stock GLSL shaders will be used", log)
                self.assertNotIn("[GLSL] Failed", log)
                self.assertIn("[GL] Loaded 1 program(s).", log)
                self.assertNotIn("Starting threaded video driver", log)
                self.assertIn(f'GET_VARIABLE: {core}_frameskip = "disabled"', log)
                self.assertNotIn("Setting audio latency to 128 ms", log)
                self.assertIn('Initialized PLAYBACK device "null"', log)
                self.assertIn("Buffer size: 3072 frames", log)
                self.assertNotIn("Buffer size: 6144 frames", log)
                self.assertIn('Saved core options file to "/tmp/socket/retroarch-core-options.cfg"', log)
                self.assertNotIn('specific core options found', log.lower())


if __name__ == "__main__":
    unittest.main()
