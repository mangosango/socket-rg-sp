"""Run a packed-app render test with Godot 4.7 on Mesa GLES.

Usage: python3 tests/app/run_render.py <pack.pck> <test.gd> <evidence-directory> [NAME=value ...]
Requires the socket-baseos-godot Docker image and the built Godot template.
Each NAME=value goes to the app environment, for example SOCKET_3D_CAP=0.8334.
The test script gets the evidence directory in SOCKET_EVIDENCE.
Mesa does not measure Mali speed. Use the frame-rate log on the device for speed.
"""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
pack = Path(sys.argv[1]).resolve()
script = Path(sys.argv[2]).resolve()
output = Path(sys.argv[3]).resolve()
if output.exists() and any(output.iterdir()):
    raise SystemExit("Choose a new or empty evidence directory.")
output.mkdir(parents=True, exist_ok=True)

SCRIPT = r'''
set -eu
cc -shared -fPIC /repo/tests/app/test_resident_egl.c -o /tmp/resident.so -ldl -lEGL -lGLESv2 -lasound
printf 'pcm.!default { type null }\n' > /tmp/alsa.conf
mkdir -p /tmp/data/godot/app_userdata/Socket /tmp/roms
printf '[General]\nui_sounds_enabled=false\nhas_seen_warning=true\nhas_seen_control_style_prompt=true\ncontrol_layout_revision=1\nconfirm_joy_button=0\n' > /tmp/data/godot/app_userdata/Socket/settings.cfg
if [ "${SOCKET_TEST_DARK:-0}" = 1 ]; then
    printf 'dark_mode=true\n' >> /tmp/data/godot/app_userdata/Socket/settings.cfg
fi
touch /tmp/roms/One.gba /tmp/roms/Two.gba
EGL_PLATFORM=surfaceless LD_PRELOAD=/tmp/resident.so ALSA_CONFIG_PATH=/tmp/alsa.conf XDG_DATA_HOME=/tmp/data \
SOCKET_RUN=/tmp SOCKET_TEST_ROOT=/tmp/roms SOCKET_EVIDENCE=/output \
/repo/work/godot/bin/godot.linuxbsd.template_release.arm64 --display-driver fbdev --rendering-driver opengl3_es \
	--rendering-method gl_compatibility --audio-driver ALSA --main-pack /app.pck \
	--script /test.gd --quit-after 60000 > /output/godot.log 2>&1
'''

settings = [arg for pair in sys.argv[4:] for arg in ("-e", pair)]
result = subprocess.run(["docker", "run", "--rm", "--network", "none", "--platform", "linux/arm64", *settings,
    "-v", f"{ROOT}:/repo:ro", "-v", f"{pack}:/app.pck:ro", "-v", f"{script}:/test.gd:ro", "-v", f"{output}:/output",
    "socket-baseos-godot", "sh", "-c", SCRIPT], capture_output=True, text=True, timeout=900)
log = (output / "godot.log").read_text() if (output / "godot.log").exists() else ""
# Android exports have no desktop (BPTC) textures. The device loads ASTC.
print("\n".join(line for line in log.splitlines() if "bptc" not in line))
if result.returncode != 0 or "\nPASS: " not in log or "FAIL:" in log or "SCRIPT ERROR:" in log or "SHADER ERROR" in log:
    raise SystemExit(result.stdout + result.stderr + "render test failed")
