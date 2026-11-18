"""Run the packed resident frontend and the real patched RetroArch together.

Usage: python3 tests/app/run_shared_menu.py <pack.pck> <evidence-directory>
Requires the socket-baseos-godot Docker image and built Godot and RetroArch.
Set SOCKET_RETROARCH_SOURCE to use a RetroArch tree outside work/.

One game runs on Mesa GLES. The RetroArch test joypad gives the pad: MENU
opens Device Settings (the launcher scene, with dark_mode=true), A opens Game,
the pad changes a core option and toggles a cheat, B goes back, MENU resumes the game, and
MENU opens and closes the menu again. The probe reads the RetroArch
framebuffer and the core frame count. Mali and the real pad need the device.
"""
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import zlib

ROOT = Path(__file__).resolve().parents[2]
SOURCE = os.environ.get("SOCKET_RETROARCH_SOURCE")
pack = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
if output.exists() and any(output.iterdir()):
    raise SystemExit("Choose a new or empty evidence directory.")
output.mkdir(parents=True, exist_ok=True)

# Reuse the press schedule of the RetroArch menu test.
spec = importlib.util.spec_from_file_location("quick_menu", ROOT / "tests/test_retroarch_quick_menu_runtime.py")
quick_menu = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quick_menu)
down, right, ok, back, menu = 32, 128, 256, 1, 32768
# RetroArch shows 60 frames or fewer in one second, also with the menu open.
# 150 frames are 2.5 s or more for the launcher scene and for the probe.
SEQUENCE = [menu, ok, down, ok, right, back, back, down, ok, down, down, down, down, ok, back, menu, menu, menu]
events = [dict(frame=0, action=1, param_num=0, param_str="(0000:0000) Socket shared menu test")]
events += quick_menu.presses(SEQUENCE, start=30, step=150)
(output / "joypad.json").write_text(json.dumps(events))
(output / "input.json").write_text('[{"frame":0,"action":0}]')

# The core of the menu test: it counts its frames in /output/runs.
core = (ROOT / "tests/retroarch_controls_core.c").read_text()
for old, new in (("#include <unistd.h>", "#include <unistd.h>\n#include <stdio.h>"),
                 ("   static uint32_t pixels[720 * 480];", '''   static unsigned runs;
   FILE *file = fopen("/output/runs.new", "w");
   fprintf(file, "%u", ++runs); fclose(file); rename("/output/runs.new", "/output/runs");
   static uint32_t pixels[720 * 480];''')):
    assert old in core
    core = core.replace(old, new)
core = core.replace("void retro_init(void) {", """void retro_init(void) {
   static struct retro_variable options[] = {{"probe_quality", "Quality; Low|High"}, {NULL, NULL}};
   environment(RETRO_ENVIRONMENT_SET_VARIABLES, options);""")
(output / "core.c").write_text(core)
active_cheats = output / "cheats/Socket controls probe/probe.cht"
active_cheats.parent.mkdir(parents=True)
active_cheats.write_text('cheats = 1\ncheat0_desc = "Infinite Lives"\ncheat0_code = "AAAA1111"\ncheat0_enable = false\n')

settings = {
    "cheat_database_path": "/output/cheats", "apply_cheats_after_load": "true",
    "notification_show_cheats_applied": "false",
    "video_driver": "gl", "video_context_driver": "mali-fbdev", "video_threaded": "false",
    "video_shader_enable": "false", "video_vsync": "false", "audio_sync": "false",
    "video_font_enable": "true", "video_font_size": "20",
    "video_font_path": "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "audio_driver": "alsa", "audio_device": "null", "audio_rate_control": "false", "midi_driver": "null",
    "input_driver": "test", "input_joypad_driver": "test", "input_autodetect_enable": "false",
    "test_input_file_general": "/output/input.json", "test_input_file_joypad": "/output/joypad.json",
    "savestate_directory": "/output/states", "savestate_auto_load": "false", "savestate_auto_save": "false",
    "rewind_enable": "false", "menu_pause_libretro": "true", "menu_driver": "rgui", "frontend_log_level": "0",
    "aspect_ratio_index": "22", "config_save_on_exit": "false", "input_player1_a_btn": "8",
    "input_player1_b_btn": "0", "input_player1_up_btn": "4", "input_player1_down_btn": "5",
    "input_player1_left_btn": "6", "input_player1_right_btn": "7", "input_menu_toggle_btn": "15",
}
(output / "test.cfg").write_text("".join(f'{key} = "{value}"\n' for key, value in settings.items()))

# play_game.sh runs this probe. It starts RetroArch and looks at each menu state.
(output / "probe.py").write_text(r'''
import json, os, signal, struct, subprocess, time
from pathlib import Path
p = Path('/output')
env = dict(os.environ, SOCKET_MENU_CONFIG='/output/menu.cfg', SOCKET_CORE_OPTIONS='/output/options.cfg',
           SOCKET_GAME_DESCRIPTOR='/output/game.descriptor', SOCKET_RESUME_MANIFEST='/output/resume-game',
           SOCKET_GAME_PLATFORM='gba', LD_PRELOAD='/output/headless.so:/output/probe.so')
log = (p/'runtime.log').open('w')
process = subprocess.Popen(['/repo/work/RetroArch/retroarch', '--verbose', '--config', '/output/test.cfg',
    '-L', '/output/core.so', '/output/probe.bin'], env=env, stdout=log, stderr=log)
def until(predicate, what):
    deadline = time.monotonic()+20
    while not predicate():
        if process.poll() is not None or time.monotonic()>deadline:
            raise RuntimeError('RetroArch ended or timed out: '+what)
        time.sleep(.01)
def capture(name):
    (p/'capture').touch()
    until(lambda: not (p/'capture').exists(), 'capture '+name)
    (p/'frame.rgba').replace(p/(name+'.rgba'))
def lines(): return (p/'menu.input').read_text().splitlines() if (p/'menu.input').exists() else []
def at_page(title, label):
    changes = [line.split() for line in lines() if line.startswith(("view ", "root "))]
    if not changes or changes[-1][0] != "view": return False
    fields = changes[-1]
    if bytes.fromhex(fields[5]).decode() != title or label.encode().hex() not in fields[7:]: return False
    frame = p / "menu.frame"
    if not frame.exists(): return False
    with frame.open("rb") as stream: header = stream.read(28)
    return len(header) == 28 and struct.unpack_from("<I", header, 24)[0] >> 8 == len(changes)
def shared_page(title, label, name):
    until(lambda: at_page(title, label), name)
    shown(name)
    (p / (name + ".shared")).write_bytes((p / "menu.frame").read_bytes())
def text(): return (p/'runtime.log').read_text()
last = 0
def runs():
    # The shared folder of Docker can hide the file for a moment in a replace.
    global last
    try: last = int((p/'runs').read_text() or last)
    except FileNotFoundError: pass
    return last
def shown(name):
    # The next press is 2.5 s or more after this one.
    time.sleep(.8)
    capture(name)
result = {}
try:
    until(lambda: runs() > 10, 'the game runs')
    capture('game-before')
    until(lambda: 'open 1' in lines(), 'MENU opens the scene')
    until(lambda: (p/'menu.frame').exists(), 'the launcher gives a frame')
    result['stopped'] = runs()
    # The launcher removes this file when the menu closes.
    result['theme'] = (p/'menu.theme').read_text()
    shown('root')
    until(lambda: 'pad a 1' in lines(), 'A goes to the scene')
    shared_page('Game', 'Core options', 'game-page')
    shared_page('Core options', 'Quality: High', 'core-page')
    until(lambda: 'pad down 1' in lines(), 'B gives the pad back to the scene')
    shown('root-cheats-row')
    until(lambda: lines().count('pad a 1') == 2, 'A on the Cheats row')
    shared_page('Cheats', '[On] Infinite Lives', 'cheats-page')
    until(lambda: '[Socket Menu] Page closed.' in text(), 'B closes the Cheats page')
    shown('root-after-cheats')
    result['paused'] = runs()
    until(lambda: 'close 1' in lines(), 'MENU closes the menu')
    until(lambda: runs() > result['paused'] + 10, 'the game resumes')
    capture('game-resumed')
    until(lambda: 'open 2' in lines(), 'MENU opens the scene again')
    result['stopped_again'] = runs()
    shown('root-again')
    result['paused_again'] = runs()
    until(lambda: 'close 2' in lines(), 'MENU closes the menu again')
    until(lambda: runs() > result['paused_again'] + 10, 'the game resumes again')
    result['lines'] = lines()
    process.send_signal(signal.SIGTERM)
    process.wait(timeout=10)
    result['returncode'] = process.returncode
    (p/'render.json').write_text(json.dumps(result))
    (p/'child-ok').write_text('ok\n')
finally:
    if process.poll() is None:
        process.kill(); process.wait()
    log.close()
''')

SCRIPT = r'''
set -eu
cc -shared -fPIC /repo/tests/app/test_resident_egl.c -o /output/resident.so -ldl -lEGL -lGLESv2 -lasound
cc -shared -fPIC /repo/tests/retroarch_headless_egl.c -o /output/headless.so -ldl -lEGL
cc -shared -fPIC /repo/tests/retroarch_controls_probe.c -o /output/probe.so -ldl -lEGL -lGLESv2 -lasound
cc -shared -fPIC -I/repo/work/RetroArch/libretro-common/include /output/core.c -o /output/core.so
mkdir -p /output/system /output/states /output/data/godot/app_userdata/Socket
cp /repo/card/System/socket/poweroff_ready.sh /output/system/
printf 'pcm.!default { type null }\npcm.null { type null }\n' > /output/alsa.conf
printf '[General]\ndark_mode=true\nui_sounds_enabled=false\nhas_seen_warning=true\nhas_seen_control_style_prompt=true\ncontrol_layout_revision=1\nconfirm_joy_button=0\n' > /output/data/godot/app_userdata/Socket/settings.cfg
printf 'socket-resume-v1\nprobe\n/output/probe.bin\ngba\n' > /output/game.descriptor
head -c 16 /dev/zero > /output/probe.bin
printf '2 0 40 4 0 0\n' > /output/controls
: > /output/egl.trace
printf '#!/bin/sh\nexec python3 /output/probe.py >> /output/probe.log 2>&1\n' > /output/system/play_game.sh
sed -i "s/^dark_mode=true$/dark_mode=$SOCKET_TEST_DARK/" /output/data/godot/app_userdata/Socket/settings.cfg
export EGL_PLATFORM=surfaceless LD_PRELOAD=/output/resident.so SOCKET_EGL_TRACE=/output/egl.trace ALSA_CONFIG_PATH=/output/alsa.conf XDG_DATA_HOME=/output/data SOCKET_SYSTEM=/output/system SOCKET_RUN=/output
/repo/work/godot/bin/godot.linuxbsd.template_release.arm64 --display-driver fbdev --rendering-driver opengl3_es --rendering-method gl_compatibility --render-thread safe --audio-driver ALSA --main-pack /app.pck --script /repo/tests/app/test_shared_menu.gd --quit-after 10000000 > /output/frontend.log 2>&1
'''

dark = os.environ.get("SOCKET_TEST_DARK", "true")
assert dark in ("true", "false")
command = ["docker", "run", "--rm", "--network", "none", "--platform", "linux/arm64", "-e", f"SOCKET_TEST_DARK={dark}",
           "-v", f"{ROOT}:/repo:ro", "-v", f"{pack}:/app.pck:ro", "-v", f"{output}:/output"]
if SOURCE:
    command += ["-v", f"{SOURCE}:/repo/work/RetroArch:ro"]
result = subprocess.run(command + ["socket-baseos-godot", "sh", "-c", SCRIPT], capture_output=True, text=True, timeout=240)


def read(name):
    return (output / name).read_text() if (output / name).exists() else ""


frontend, runtime = read("frontend.log"), read("runtime.log")
context = "\n".join([result.stdout, result.stderr, frontend, read("probe.log"), runtime[-3000:]])
assert result.returncode == 0, context
assert "PASS: shared menu launcher" in frontend, context
assert "ERROR:" not in frontend and "FAIL:" not in frontend, context
assert "[ERROR]" not in runtime, context
assert "The launcher did not show" not in runtime, context


def frame(name):
    """Return the rows of a capture, top row first, and save a PNG of it."""
    data = (output / f"{name}.rgba").read_bytes()
    rows = [data[y * 2880:(y + 1) * 2880] for y in range(479, -1, -1)]

    def chunk(kind, body):
        return struct.pack("!I", len(body)) + kind + body + struct.pack("!I", zlib.crc32(kind + body))
    (output / f"{name}.png").write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!2I5B", 720, 480, 8, 6, 0, 0, 0))
                                        + chunk(b"IDAT", zlib.compress(b"".join(b"\0" + row for row in rows))) + chunk(b"IEND", b""))
    (output / f"{name}.rgba").unlink()
    return rows


def count(rows, color):
    return sum(all(abs(row[x * 4 + i] - color[i]) <= 2 for i in range(3)) for row in rows[::4] for x in range(0, 720, 4))


render = json.loads(read("render.json"))
surface = json.loads(read("expected.json"))["surface"]
GAME = [100, 120, 140]
# The launcher advertises support for shared subpages in menu.theme.
theme = render["theme"].split()
ink = list(bytes.fromhex(theme[2]))
assert theme[0] == "2" and list(bytes.fromhex(theme[1])) == surface and len(theme) == 8, theme
frames = {name: frame(name) for name in ("game-before", "root", "game-page", "core-page", "root-cheats-row", "cheats-page",
                                         "root-after-cheats", "game-resumed", "root-again")}
counts = {name: dict(surface=count(rows, surface), game=count(rows, GAME), ink=count(rows, ink)) for name, rows in frames.items()}
report = dict(surface=surface, ink=ink, counts=counts, render=render,
              pages=[line.split("[Socket Menu] ", 1)[1] for line in runtime.splitlines() if "[Socket Menu] " in line])
(output / "report.json").write_text(json.dumps(report, indent=1))
print(json.dumps(report, indent=1))
assert (sum(surface) < sum(ink)) == (dark == "true"), (surface, ink)
roots = ("root", "root-cheats-row", "root-after-cheats", "root-again")
for name in ("game-before", "game-resumed"):
    assert counts[name]["game"] == 120 * 180 and counts[name]["surface"] == 0, (name, counts[name])
for name in roots:
    assert counts[name]["surface"] > 2000 and counts[name]["game"] == 0, (name, counts[name])
# The focus moved from Game to Cheats: the scene drew a new frame.
assert frames["root"] != frames["root-cheats-row"] and frames["root"] == frames["root-again"], counts
# Compare the opaque pixels of the launcher panel to the real RetroArch framebuffer.
for name in ("game-page", "core-page", "cheats-page"):
    packet = (output / (name + ".shared")).read_bytes()
    assert struct.unpack_from("<2I", packet, 16) == (720, 480)
    pixels = memoryview(packet)[28:]
    compared = 0
    for y in range(0, 480, 4):
        for x in range(0, 720, 4):
            i = 4 * (y * 720 + x)
            if pixels[i + 3] == 255:
                assert all(abs(frames[name][y][4 * x + k] - pixels[i + k]) <= 2 for k in range(3)), (name, x, y)
                compared += 1
    assert compared > 2000 and counts[name]["ink"] > 20, name
    assert all(frames[name] != frames[other] for other in roots), name
assert 'cheat0_enable = "true"' in active_cheats.read_text()
assert 'probe_quality = "High"' in (output / "options.cfg").read_text()
# The core does not run while the menu is open, and runs after each close.
assert render["paused"] - render["stopped"] <= 1 and render["paused_again"] - render["stopped_again"] <= 1, render
assert render["returncode"] == 0, render
lines = render["lines"]
assert lines[0].startswith("session ") and [line for line in lines[1:] if not line.startswith(("pad ", "view ", "root "))] == [
    "open 1", "close 1", "open 2", "close 2"], lines
assert [line for line in lines if line.startswith("pad ")] == [
    "pad a 1", "pad a 0", "pad down 1", "pad down 0", "pad a 1", "pad a 0"], lines
assert report["pages"].count("Page closed.") == 1, report["pages"]
print(frontend.strip().splitlines()[-1])
print("PASS: real RetroArch displayed the shared Game, Core options and Cheats pages, saved both changes and resumed the core")
