"""Check the startup banner and Socket warnings in ARM64 RetroArch with the card config."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

PROBE = r'''
import json, os, subprocess, time
from pathlib import Path
p = Path('/output')
env = dict(os.environ, SOCKET_RUN='/output', SOCKET_MENU_CONFIG='/output/menu.cfg',
           SOCKET_CORE_OPTIONS='/output/options.cfg', SOCKET_GAME_DESCRIPTOR='/output/game.descriptor',
           SOCKET_RESUME_MANIFEST='/output/resume-game', EGL_PLATFORM='surfaceless',
           LD_PRELOAD='/output/headless.so:/output/probe.so')
card = Path('/project/card/System/socket/retroarch')
# The card settings come first. The test overrides replace only devices and paths.
(p/'app.cfg').write_text((card/'gba.cfg').read_text() + (p/'overrides.cfg').read_text())
log = (p/'runtime.log').open('w')
process = subprocess.Popen(['/project/work/RetroArch/retroarch', '--verbose',
    '--config', str(card/'retroarch.cfg'), '--appendconfig', '/output/app.cfg',
    '-L', '/output/core.so', '/output/probe.bin', '--max-frames', '420'],
    env=env, stdout=log, stderr=log)
def until(predicate):
    deadline = time.monotonic() + 15
    while not predicate():
        if process.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError('Runtime ended or condition timed out')
        time.sleep(.005)
def odd_pixels():
    (p/'capture').touch()
    until(lambda: not (p/'capture').exists())
    frame = (p/'frame.rgba').read_bytes()
    return sum(frame[i:i+3] != b'\x64\x78\x8c' for i in range(0, len(frame), 4))
try:
    until(lambda: (p/'audio.csv').exists())
    startup = []
    for _ in range(12):
        startup.append(odd_pixels())
        time.sleep(.15)
    # The probe core has no save states, so the sleep save fails.
    (p/'sleep.request').write_text('7001\n')
    until(lambda: 'Sleep save failed.' in (p/'runtime.log').read_text())
    time.sleep(.2)
    warning = odd_pixels()
    process.wait(timeout=20)
    print(json.dumps(dict(returncode=process.returncode, startup=startup, warning=warning)))
finally:
    if process.poll() is None:
        process.kill(); process.wait()
    log.close()
'''


@unittest.skipUnless(os.environ.get('RETROARCH_STARTUP_OSD_SMOKE') == '1',
                     'Set RETROARCH_STARTUP_OSD_SMOKE=1 for ARM64 runtime tests')
class StartupOsdRuntimeTests(unittest.TestCase):
    def run_case(self, extra=''):
        with tempfile.TemporaryDirectory(prefix='ra-startup-osd-') as directory:
            output = Path(directory)
            (output/'states').mkdir()
            (output/'saves').mkdir()
            (output/'probe.py').write_text(PROBE)
            (output/'probe.bin').write_bytes(bytes(16))
            (output/'game.descriptor').write_text('socket-resume-v1\nprobe\n/output/probe.bin\ngba\n')
            (output/'input.json').write_text('[{"frame":0,"action":0}]')
            (output/'joypad.json').write_text(json.dumps([dict(frame=0, action=1, param_num=0,
                param_str='(0000:0000) Socket startup OSD test')]))
            overrides = {'video_context_driver':'mali-fbdev', 'video_vsync':'false',
                'audio_device':'null', 'input_driver':'test', 'input_joypad_driver':'test',
                'test_input_file_general':'/output/input.json', 'test_input_file_joypad':'/output/joypad.json',
                'libretro_directory':'/output', 'system_directory':'/output',
                'savefile_directory':'/output/saves', 'savestate_directory':'/output/states',
                'video_font_path':'/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'}
            (output/'overrides.cfg').write_text('\n' + extra +
                ''.join(f'{k} = "{v}"\n' for k, v in overrides.items()))
            script = '''set -eu
cc -shared -fPIC /project/tests/retroarch_headless_egl.c -o /output/headless.so -ldl -lEGL
cc -shared -fPIC /project/tests/retroarch_controls_probe.c -o /output/probe.so -ldl -lEGL -lGLESv2 -lasound
cc -shared -fPIC -I/project/work/RetroArch/libretro-common/include /project/tests/retroarch_controls_core.c -o /output/core.so
python3 /output/probe.py
'''
            result = subprocess.run(['docker', 'run', '--rm', '--platform', 'linux/arm64',
                '-v', f'{ROOT}:/project:ro', '-v', f'{output}:/output', 'socket-baseos-godot',
                'sh', '-c', script], capture_output=True, text=True, timeout=90)
            log = (output/'runtime.log').read_text() if (output/'runtime.log').exists() else ''
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr + log)
            report = json.loads(result.stdout.strip().splitlines()[-1])
            self.assertEqual(report['returncode'], 0, log)
            return report

    def test_startup_has_no_banner_and_failure_warning_shows(self):
        report = self.run_case()
        self.assertEqual(report['startup'], [0] * 12, report)
        self.assertGreater(report['warning'], 100, report)

    def test_probe_detects_the_banner_when_enabled(self):
        report = self.run_case('menu_show_load_content_animation = "true"\n')
        self.assertGreater(max(report['startup']), 1000, report)


if __name__ == '__main__':
    unittest.main()
