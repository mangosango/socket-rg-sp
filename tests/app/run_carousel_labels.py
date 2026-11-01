"""Render the real cartridge carousel labels with Godot 4.7 on Mesa GLES.

Usage: python3 tests/app/run_carousel_labels.py <pack.pck> <evidence-directory>
Requires the socket-baseos-godot Docker image and the built Godot template.
Mesa does not measure Mali speed. Check the brightness on the device too.
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
cc -shared -fPIC /repo/tests/app/test_resident_egl.c -o /tmp/resident.so -ldl -lEGL -lGLESv2 -lasound
printf 'pcm.!default { type null }\n' > /tmp/alsa.conf
mkdir -p /tmp/data/godot/app_userdata/Socket /tmp/roms
printf '[General]\nui_sounds_enabled=false\nhas_seen_warning=true\nhas_seen_control_style_prompt=true\ncontrol_layout_revision=1\nconfirm_joy_button=0\n' > /tmp/data/godot/app_userdata/Socket/settings.cfg
touch /tmp/roms/One.gba /tmp/roms/Two.gba
EGL_PLATFORM=surfaceless LD_PRELOAD=/tmp/resident.so ALSA_CONFIG_PATH=/tmp/alsa.conf XDG_DATA_HOME=/tmp/data \
SOCKET_RUN=/tmp SOCKET_TEST_ROOT=/tmp/roms SOCKET_LABEL_EVIDENCE=/output \
/repo/work/godot/bin/godot.linuxbsd.template_release.arm64 --display-driver fbdev --rendering-driver opengl3_es \
	--rendering-method gl_compatibility --audio-driver ALSA --main-pack /app.pck \
	--script /repo/tests/app/test_carousel_labels_render.gd --quit-after 20000 > /output/godot.log 2>&1
'''

result = subprocess.run(["docker", "run", "--rm", "--platform", "linux/arm64",
    "-v", f"{ROOT}:/repo:ro", "-v", f"{pack}:/app.pck:ro", "-v", f"{output}:/output",
    "socket-baseos-godot", "sh", "-c", SCRIPT], capture_output=True, text=True, timeout=400)
log = (output / "godot.log").read_text() if (output / "godot.log").exists() else ""
print(log)
if result.returncode != 0 or "PASS: carousel labels" not in log or "FAIL:" in log or "SCRIPT ERROR:" in log:
    raise SystemExit(result.stdout + result.stderr + "carousel label render failed")
