"""Standalone Compatibility/GLES split-label pixel proof (no pack required).

python3 tests/app/run_split_label_depth.py work/label-depth/evidence
Uses the socket-baseos-godot image, Mesa GLES, and the built ARM64 Godot.
The resolve runs exercise real multisample coverage at Godot's 2x setting.
Tile emulates the Mali framebuffer path and a lost depth attachment, but
its texture attachment has only one sample. No hardware is certified.
The occlusion gate is independent of color differences at adjusted MSAA
edges: this test measures those because GLES tonemaps after resolve.
"""
import argparse
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ENGINE = ROOT / "work/godot/bin/godot.linuxbsd.template_release.arm64"

SCRIPT = r'''
set -eu
export EGL_PLATFORM=surfaceless SOCKET_EVIDENCE=/proof
if [ "$1" = tile ]; then
    export SOCKET_FBO_COUNTS=/proof/fbo-counts SOCKET_TILE_DISCARD=0
    helper=test_msaa_fbo_egl.c
else
    helper=test_resident_egl.c
fi
cc -shared -fPIC "/repo/tests/app/$helper" -o /tmp/display.so -ldl -lEGL -lGLESv2 -lasound
LD_PRELOAD=/tmp/display.so /engine --display-driver fbdev --rendering-driver opengl3_es \
    --rendering-method gl_compatibility --audio-driver Dummy --path /proof \
    --script res://test_split_label_depth.gd --quit-after 600
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--engine", type=Path, default=DEFAULT_ENGINE)
    args = parser.parse_args()
    output = args.evidence.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("choose a new or empty evidence directory")
    if not args.engine.is_file():
        parser.error(f"engine not found: {args.engine}")

    for mode in ("resolve", "resolve-prepass", "tile"):
        proof = output / mode
        (proof / "shaders").mkdir(parents=True)
        (proof / ".godot").mkdir()
        (proof / ".godot/global_script_class_cache.cfg").write_text("list=[]\n")
        (proof / "project.godot").write_text(
            'config_version=5\n[application]\nconfig/name="Split label depth proof"\n'
            '[rendering]\nrenderer/rendering_method="gl_compatibility"\n'
            f'driver/depth_prepass/enable={"true" if mode == "resolve-prepass" else "false"}\n'
        )
        shutil.copyfile(ROOT / "tests/app/test_split_label_depth.gd", proof / "test_split_label_depth.gd")
        shutil.copyfile(ROOT / "overlay/shaders/split_label_occluder.gdshader", proof / "shaders/split_label_occluder.gdshader")
        log = proof / "godot.log"
        with log.open("w") as stream:
            result = subprocess.run([
                "docker", "run", "--rm", "--network", "none", "--platform", "linux/arm64",
                "-v", f"{ROOT}:/repo:ro", "-v", f"{proof}:/proof", "-v", f"{args.engine.resolve()}:/engine:ro",
                "socket-baseos-godot", "sh", "-c", SCRIPT, "split-label-depth", mode,
            ], stdout=stream, stderr=subprocess.STDOUT, timeout=120)
        evidence = log.read_text()
        print(f"{mode} ({log})\n{evidence}", end="", flush=True)
        if result.returncode or "\nPASS: " not in evidence or any(marker in evidence for marker in ("FAIL:", "ERROR:", "SHADER ERROR")):
            raise SystemExit(f"{mode}: split label depth proof failed")


if __name__ == "__main__":
    main()
