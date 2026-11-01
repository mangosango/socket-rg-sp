"""Run the packed resident frontend on real Mesa GLES and ALSA null devices.

Usage: python3 tests/app/run_resident.py <pack.pck> <evidence-directory>
Requires the socket-baseos-godot Docker image and built Godot and RetroArch.
The Mesa adapter delays old pbuffer destruction until its replacement exists.
Physical Mali window ownership must be checked on the device.
"""
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
pack = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
if output.exists() and any(output.iterdir()):
    raise SystemExit("Choose a new or empty evidence directory.")
output.mkdir(parents=True, exist_ok=True)

SCRIPT = r'''
set -eu
cc -Wall -Wextra -Wno-unused-parameter -shared -fPIC /repo/tests/app/test_resident_egl.c -o /output/resident.so -ldl -lEGL -lGLESv2 -lasound
cc -shared -fPIC -I/repo/work/RetroArch/libretro-common/include /repo/tests/retroarch_controls_core.c -o /output/core.so
mkdir -p /output/system /output/data/godot/app_userdata/Socket
cp /repo/card/System/socket/poweroff_ready.sh /output/system/
printf 'pcm.!default { type null }\npcm.null { type null }\n' > /output/alsa.conf
printf '[General]\nui_sounds_enabled=false\nhas_seen_warning=true\nhas_seen_control_style_prompt=true\ncontrol_layout_revision=1\nconfirm_joy_button=0\n' > /output/data/godot/app_userdata/Socket/settings.cfg
cat > /output/retroarch.cfg <<'EOF'
video_driver = "gl"
video_context_driver = "mali_fbdev"
video_threaded = "false"
video_vsync = "false"
video_fullscreen = "true"
audio_driver = "alsa"
audio_device = "null"
audio_sync = "false"
midi_driver = "null"
input_driver = "udev"
input_joypad_driver = "udev"
video_shader_enable = "false"
video_font_enable = "false"
menu_driver = "rgui"
rgui_show_start_screen = "false"
config_save_on_exit = "false"
savestate_auto_save = "false"
savestate_auto_load = "false"
EOF
printf resident > /output/fixture.gb
: > /output/egl.trace
: > /output/child.log
: > /output/child-ok
cat > /output/system/resume_game.sh <<'EOF'
#!/bin/sh
printf 'resumed\n' >> /output/resume-ran
printf '42\n' > /output/session_seconds
exit 0
EOF
cat > /output/system/play_game.sh <<'EOF'
#!/bin/sh
set -eu
if [ -n "${SOCKET_RESIDENT_RESULT:-}" ]; then
    printf '987\n' > /output/poweroff.request
    case "$SOCKET_RESIDENT_RESULT" in success|crashacked) printf '987 ok\n' > /output/poweroff.ack ;; esac
    case "$SOCKET_RESIDENT_RESULT" in failure|crashacked) exit 7 ;; esac
    exit 0
fi
/repo/work/RetroArch/retroarch --verbose --config /output/retroarch.cfg --max-frames 6 -L /output/core.so /output/fixture.gb >> /output/child.log 2>&1
printf '2 %s 80 4 0 1\n' "$(wc -l < /output/child-ok)" > /output/controls
printf 'ok\n' >> /output/child-ok
EOF
export EGL_PLATFORM=surfaceless LD_PRELOAD=/output/resident.so SOCKET_EGL_TRACE=/output/egl.trace ALSA_CONFIG_PATH=/output/alsa.conf XDG_DATA_HOME=/output/data SOCKET_SYSTEM=/output/system SOCKET_RUN=/output
/repo/work/godot/bin/godot.linuxbsd.template_release.arm64 --display-driver fbdev --rendering-driver opengl3_es --rendering-method gl_compatibility --render-thread safe --audio-driver ALSA --main-pack /app.pck --script /repo/tests/app/test_resident.gd --quit-after 600 > /output/resident.log 2>&1
'''

result = subprocess.run([
    "docker", "run", "--rm", "--platform", "linux/arm64",
    "-v", f"{ROOT}:/repo:ro", "-v", f"{pack}:/app.pck:ro",
    "-v", f"{output}:/output", "socket-baseos-godot", "sh", "-c", SCRIPT,
], capture_output=True, text=True, timeout=90)
log = (output / "resident.log").read_text() if (output / "resident.log").exists() else ""
assert result.returncode == 0, result.stdout + result.stderr + log
assert "PASS: resident fbdev bridge" in log, log
assert "ERROR:" not in log and "FAIL:" not in log, log
child = (output / "child.log").read_text()
assert "[ERROR]" not in child, child
assert child.count("[GL] Loaded 1 program(s).") == 3, child
assert (output / "child-ok").read_text().splitlines() == ["ok"] * 3
pid = (output / "app.pid").read_text().strip()
events = [line.split() for line in (output / "egl.trace").read_text().splitlines()]
parent = [event for event in events if event[0] == pid]
for operation, count in (("context_create", 1), ("surface_create", 4),
                         ("surface_destroy", 4), ("audio_open", 4), ("audio_close", 4)):
    assert sum(event[1] == operation for event in parent) == count, parent
contexts = {event[2] for event in parent if event[1] == "context_current" and event[2] != "(nil)"}
assert len(contexts) == 1, parent
assert not any(event[1].endswith("failed") for event in events), events
assert not any(event[1] == "surface_invalid" for event in events), events
pixels = [event for event in parent if event[1] == "window_pixels"]
expected = [345600, 0, 0, 719, 479, 0, 0]
# The startup splash may be blank. Compare the stable initial window and every resumed swap.
assert list(map(int, pixels[2][4:])) == expected, pixels
assert len(pixels) == 12, pixels
assert all(list(map(int, event[4:])) == expected for event in pixels[3:]), pixels
assert sum(event[1] == "deferred_surface_destroy" for event in parent) == 3, parent
audio = [(event[0] == pid, event[1]) for event in events if event[1] in ("audio_open", "audio_close")]
assert audio == [(True, "audio_open")] + [
    event for _ in range(3) for event in
    [(True, "audio_close"), (False, "audio_open"), (False, "audio_close"), (True, "audio_open")]
] + [(True, "audio_close")], audio
print(log.strip())
print("PASS: one retained EGL context, four valid surfaces, first resumed default framebuffer pixels, exclusive audio handoff and three successful GLES RetroArch children")

for mode in ("failure", "unacked", "success", "crashacked", "resume"):
    case = output / mode
    case.mkdir(exist_ok=True)
    result = subprocess.run([
        "docker", "run", "--rm", "--platform", "linux/arm64",
        "-e", f"SOCKET_RESIDENT_RESULT={mode}",
        *(["-e", "SOCKET_RESUME_BOOT=1"] if mode == "resume" else []),
        "-v", f"{ROOT}:/repo:ro", "-v", f"{pack}:/app.pck:ro",
        "-v", f"{case}:/output", "socket-baseos-godot", "sh", "-c", SCRIPT,
    ], capture_output=True, text=True, timeout=90)
    log = (case / "resident.log").read_text()
    assert result.returncode == 0 and "PASS: resident" in log, result.stdout + result.stderr + log
    expected = "ERROR: RetroArch exited with status 7; see Logs/socket-game.log"
    assert "SCRIPT ERROR:" not in log and "FAIL:" not in log, log
    assert log.count("ERROR:") == (1 if mode == "failure" else 0), log
    if mode == "failure":
        assert expected in log and not (case / "poweroff.request").exists(), log
    elif mode != "resume":
        assert (case / "poweroff.request").exists(), log
    if mode == "resume":
        # The frontend loads first, runs the record once, then restores display and audio.
        assert (case / "resume-ran").read_text() == "resumed\n", log
        assert not (case / "session_seconds").exists(), log
        trace = [line.split() for line in (case / "egl.trace").read_text().splitlines()]
        audio = [event[1] for event in trace if event[1] in ("audio_open", "audio_close")]
        assert audio[:3] == ["audio_open", "audio_close", "audio_open"], trace
    if mode in ("success", "crashacked"):
        # The frontend released audio for the game and never reopens it before poweroff.
        trace = [line.split() for line in (case / "egl.trace").read_text().splitlines()]
        opens = [event for event in trace if event[1] == "audio_open"]
        closes = [event for event in trace if event[1] == "audio_close"]
        assert len(opens) == 1 and len(closes) >= 1, trace
        assert trace.index(opens[0]) < trace.index(closes[0]), trace
        assert sum(event[1] == "surface_create" for event in trace) == 1, trace
    print(next(line for line in log.splitlines() if line.startswith("PASS:")))
