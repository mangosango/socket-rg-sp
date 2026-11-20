"""Compare fixed-pose labels on the final display of a packed Socket 0.10.1.

Usage: python3 tests/app/run_split_label_render.py <pack.pck> <evidence-directory>
Set SOCKET_3D_SPLIT_LABEL=1 to also run (and require) the split candidate.
Set SOCKET_3D_MSAA=2 to compare with cartridge edge smoothing enabled.
Like run_render.py, needs socket-baseos-godot and the arm64 Godot template.
This is a visual comparison on Mesa GLES, not a handheld performance test.
"""
import argparse
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = r'''
set -eu
cc -shared -fPIC /repo/tests/app/test_resident_egl.c -o /tmp/resident.so -ldl -lEGL -lGLESv2 -lasound
printf 'pcm.!default { type null }\n' > /tmp/alsa.conf
run_test() {
    phase=$1
    split=$2
    work=/tmp/$phase
    profile=$work/data/godot/app_userdata/Socket
    mkdir -p "$profile" "$work/roms"
    printf '[General]\nui_sounds_enabled=false\nhas_seen_warning=true\nhas_seen_control_style_prompt=true\ncontrol_layout_revision=1\nconfirm_joy_button=0\n' > "$profile/settings.cfg"
    touch "$work/roms/One.gba"
    EGL_PLATFORM=surfaceless LD_PRELOAD=/tmp/resident.so ALSA_CONFIG_PATH=/tmp/alsa.conf XDG_DATA_HOME="$work/data" \
    SOCKET_RUN="$work" SOCKET_TEST_ROOT="$work/roms" SOCKET_EVIDENCE=/output SOCKET_3D_SPLIT_LABEL="$split" \
    /repo/work/godot/bin/godot.linuxbsd.template_release.arm64 --display-driver fbdev --rendering-driver opengl3_es \
        --rendering-method gl_compatibility --audio-driver ALSA --fixed-fps 60 --main-pack /app.pck \
        --script /repo/tests/app/test_split_label_render.gd --quit-after 4000 > "/output/$phase.log" 2>&1
    grep -Fxq "PASS: split label $phase" "/output/$phase.log"
}
run_test controls 0
if [ "$1" = 1 ]; then
    run_test candidate 1
fi
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("pack", type=Path)
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    pack = args.pack.resolve()
    output = args.evidence.resolve()
    if not pack.is_file():
        parser.error(f"Pack not found: {pack}")
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error("Choose a new or empty evidence directory.")
    output.mkdir(parents=True, exist_ok=True)
    split = os.environ.get("SOCKET_3D_SPLIT_LABEL") == "1"
    result = subprocess.run([
        "docker", "run", "--rm", "--network", "none", "--platform", "linux/arm64", "-e", "SOCKET_3D_MSAA",
        "-v", f"{ROOT}:/repo:ro", "-v", f"{pack}:/app.pck:ro", "-v", f"{output}:/output",
        "socket-baseos-godot", "sh", "-c", SCRIPT, "run_split_label_render", str(int(split)),
    ], timeout=600)
    passed = result.returncode == 0
    for phase in ["controls", "candidate"] if split else ["controls"]:
        path = output / f"{phase}.log"
        if not path.exists():
            print(f"Missing log: {path}")
            passed = False
            continue
        log = path.read_text(errors="replace")
        lines = log.splitlines()
        print(f"{phase}: {path}")
        for line in lines:
            if any(token in line for token in ("RGB MAE", "body_pixels=", "PASS:", "FAIL:", "SCRIPT ERROR:", "SHADER ERROR")):
                print(line)
        passed &= f"PASS: split label {phase}" in lines and not any(
            token in log for token in ("FAIL:", "SCRIPT ERROR:", "SHADER ERROR")
        )
    if not passed:
        raise SystemExit(f"Split label render test failed; see {output}")


if __name__ == "__main__":
    main()
