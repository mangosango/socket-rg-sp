"""Launch a real GBA game with mGBA through launch_game.sh on ARM64 RetroArch.

Checks: no load banner at startup, sleep ack writes an mGBA resume record, and a
cold boot restores the sleep state. The card is mounted read-only.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CARD = Path(os.environ.get("RETROARCH_CORE_SMOKE_ROOT", "/Volumes/BASEOS"))

# Save the GL frame at the listed frame numbers.
CAPTURE = r'''
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
static unsigned frame;
EGLBoolean eglSwapBuffers(EGLDisplay d, EGLSurface s) {
   static EGLBoolean (*real)(EGLDisplay, EGLSurface);
   const char *list = getenv("CAPTURE_FRAMES");
   char key[32], all[256];
   if (!real) real = dlsym(RTLD_NEXT, "eglSwapBuffers");
   snprintf(key, sizeof key, ",%u,", ++frame);
   snprintf(all, sizeof all, ",%s,", list ? list : "");
   if (strstr(all, key)) {
      static unsigned char pixels[720 * 480 * 4];
      char path[256];
      FILE *file;
      glReadPixels(0, 0, 720, 480, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
      snprintf(path, sizeof path, "%s/f%u.rgba", getenv("CAPTURE_DIR"), frame);
      file = fopen(path, "wb");
      fwrite(pixels, 1, sizeof pixels, file);
      fclose(file);
   }
   return real(d, s);
}
'''

PROBE = r'''
import json, os, shutil, signal, subprocess, sys, time
from pathlib import Path
p = Path('/output'); rom = sys.argv[1]
system = Path('/mnt/sdcard/System/socket')
shutil.copytree('/project/card/System/socket', system, symlinks=True)
(system / 'retroarch/retroarch').symlink_to('/project/work/RetroArch/retroarch')
(system / 'cores').mkdir(exist_ok=True)
(system / 'cores/mgba_libretro.so').symlink_to('/card/System/socket/cores/mgba_libretro.so')
card_config = (system / 'retroarch/retroarch.cfg').read_text()
env = dict(os.environ, SOCKET_RUN='/output', SOCKET_RESUME_MANIFEST='/output/resume-game',
           EGL_PLATFORM='surfaceless', LD_PRELOAD='/output/headless.so:/output/capture.so',
           CAPTURE_FRAMES='20,40,80,160')
def launch(name, extra='', resume=False):
    # RetroArch keeps the first key, so the test devices come first.
    (system / 'retroarch/retroarch.cfg').write_text(
        'video_context_driver = "mali-fbdev"\nvideo_vsync = "false"\naudio_device = "null"\n'
        'input_driver = "null"\ninput_joypad_driver = "null"\n' + extra + card_config)
    (p / name).mkdir()
    run_env = dict(env, CAPTURE_DIR=str(p / name), SOCKET_RESUME_LOAD='1' if resume else '0')
    log = (p / (name + '.log')).open('w')
    return subprocess.Popen(['sh', str(system / 'launch_game.sh'), 'mgba', rom, 'gba'],
                            env=run_env, stdout=log, stderr=log), name
def until(process, predicate, seconds=20):
    deadline = time.monotonic() + seconds
    while not predicate():
        if process.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError('RetroArch ended or timed out')
        time.sleep(.02)
def stop(process):
    process.send_signal(signal.SIGTERM); process.wait(timeout=15)
result = {}
for name, extra in (('first', ''), ('banner', 'menu_show_load_content_animation = "true"\n'), ('again', '')):
    process, _ = launch(name, extra)
    try:
        until(process, lambda: (p / name / 'f160.rgba').exists())
        if name == 'first':
            time.sleep(.5)
            (p / 'sleep.request').write_text('000777\n')
            until(process, lambda: (p / 'sleep.ack').exists())
            result['sleep_ack'] = (p / 'sleep.ack').read_text()
            result['manifest'] = (p / 'resume-game').read_text().splitlines()
            result['sleep_states'] = [str(path) for path in Path('/mnt/sdcard/Saves/retroarch').rglob('*.sleep')]
        stop(process)
    finally:
        if process.poll() is None: process.kill(); process.wait()
    if name == 'first':
        (p / 'sleep.request').unlink()
        process, _ = launch('resume', resume=True)
        try:
            until(process, lambda: (p / 'resume.ack').exists())
            result['resume_ack'] = (p / 'resume.ack').read_text()
            result['manifest_after'] = (p / 'resume-game').exists()
            stop(process)
        finally:
            if process.poll() is None: process.kill(); process.wait()
def frames(name):
    return {frame: (p / name / f'f{frame}.rgba').read_bytes() for frame in (20, 40, 80, 160)}
first, banner, again = frames('first'), frames('banner'), frames('again')
result['repeatable'] = all(first[f] == again[f] for f in first)
result['banner_differs'] = sum(first[f] != banner[f] for f in first)
result['options'] = Path('/output/retroarch-core-options.cfg').read_text()
print(json.dumps(result))
'''


@unittest.skipUnless(os.environ.get("RETROARCH_CORE_SMOKE") == "1",
                     "Set RETROARCH_CORE_SMOKE=1 with Docker and the read-only card")
class MgbaLaunchTests(unittest.TestCase):
    def test_gba_launch_sleep_resume_and_no_banner(self):
        rom = CARD / "Games/GBA/Pokemon - Sapphire Version (USA, Europe) (Rev 2).gba"
        self.assertTrue(rom.is_file(), rom)
        with tempfile.TemporaryDirectory(prefix="ra-mgba-launch-") as directory:
            output = Path(directory)
            (output / "capture.c").write_text(CAPTURE)
            (output / "probe.py").write_text(PROBE)
            script = '''set -eu
cc -shared -fPIC /project/tests/retroarch_headless_egl.c -o /output/headless.so -ldl -lEGL
cc -shared -fPIC /output/capture.c -o /output/capture.so -ldl -lEGL -lGLESv2
python3 /output/probe.py "$1"
'''
            result = subprocess.run(["docker", "run", "--rm", "--platform", "linux/arm64",
                "-v", f"{ROOT}:/project:ro", "-v", f"{CARD}:/card:ro", "-v", f"{output}:/output",
                "socket-baseos-godot", "sh", "-c", script, "sh", "/card/" + str(rom.relative_to(CARD))],
                capture_output=True, text=True, timeout=240)
            logs = "".join(path.read_text(errors="replace")[-3000:] for path in output.glob("*.log"))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr + logs)
            data = json.loads(result.stdout.strip().splitlines()[-1])
            print({key: value for key, value in data.items() if key != "options"})
            self.assertEqual(data["sleep_ack"], "000777 ok\n")
            self.assertEqual(data["manifest"][:2], ["socket-resume-v1", "mgba"])
            self.assertEqual(data["manifest"][3], "gba")
            self.assertTrue(any("/mGBA/" in path for path in data["sleep_states"]), data)
            self.assertEqual(data["resume_ack"], "0 ok\n")
            self.assertFalse(data["manifest_after"])
            self.assertTrue(data["repeatable"], "same frames without the banner")
            self.assertGreater(data["banner_differs"], 0, "the probe sees the banner when it is on")
            self.assertIn('mgba_frameskip = "auto"', data["options"])
            self.assertIn('mgba_color_correction = "Auto"', data["options"])


if __name__ == "__main__":
    unittest.main()
