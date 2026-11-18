"""Check the framebuffer count of the 3D MSAA view in the BaseOS engine on Mesa GLES.

Usage: python3 tests/app/run_msaa_fbo.py <pack.pck> <evidence-directory> [engine]
Requires the socket-baseos-godot Docker image. The default engine is the built
Godot template. Give a different engine to compare, for example a saved binary.
A preloaded helper counts the framebuffer calls and emulates tile MSAA.
"""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
pack = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
engine = Path(sys.argv[3]).resolve() if len(sys.argv) > 3 else ROOT / "work/godot/bin/godot.linuxbsd.template_release.arm64"
if output.exists() and any(output.iterdir()):
    raise SystemExit("Choose a new or empty evidence directory.")
output.mkdir(parents=True, exist_ok=True)

SCRIPT = r'''
set -eu
cc -shared -fPIC /repo/tests/app/test_msaa_fbo_egl.c -o /tmp/fbo.so -ldl -lEGL -lGLESv2 -lasound
printf 'pcm.!default { type null }\n' > /tmp/alsa.conf
mkdir -p /tmp/data/godot/app_userdata/Socket /tmp/roms
printf '[General]\nui_sounds_enabled=false\nhas_seen_warning=true\nhas_seen_control_style_prompt=true\ncontrol_layout_revision=1\nconfirm_joy_button=0\n' > /tmp/data/godot/app_userdata/Socket/settings.cfg
EGL_PLATFORM=surfaceless LD_PRELOAD=/tmp/fbo.so ALSA_CONFIG_PATH=/tmp/alsa.conf XDG_DATA_HOME=/tmp/data \
SOCKET_RUN=/tmp SOCKET_TEST_ROOT=/tmp/roms SOCKET_FBO_COUNTS=/output/fbo-counts \
/engine --display-driver fbdev --rendering-driver opengl3_es \
	--rendering-method gl_compatibility --audio-driver ALSA --main-pack /app.pck \
	--script /repo/tests/app/test_msaa_fbo_render.gd --quit-after 9000 > /output/godot.log 2>&1
'''

result = subprocess.run(["docker", "run", "--rm", "--network", "none", "--platform", "linux/arm64",
    "-v", f"{ROOT}:/repo:ro", "-v", f"{pack}:/app.pck:ro", "-v", f"{engine}:/engine:ro", "-v", f"{output}:/output",
    "socket-baseos-godot", "sh", "-c", SCRIPT], capture_output=True, text=True, timeout=900)
log = (output / "godot.log").read_text() if (output / "godot.log").exists() else ""
# Android exports have no desktop (BPTC) textures. The device loads ASTC.
print("\n".join(line for line in log.splitlines() if "bptc" not in line))
if result.returncode != 0 or "\nPASS: " not in log or "FAIL:" in log or "SCRIPT ERROR:" in log:
    raise SystemExit(result.stdout + result.stderr + "MSAA framebuffer test failed")
