"""Exercise the ARM64 audio path and GL HUD without card writes or fonts."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

PROBE = r'''
import json
from pathlib import Path
import subprocess
import time
import socket
p = Path('/output')
controls = p / 'controls'
def publish(line):
    (p / 'next').write_text(line)
    (p / 'next').replace(controls)
publish('2 7 40 4 0 1\n')
env = dict(__import__('os').environ, SOCKET_RUN='/output', EGL_PLATFORM='surfaceless',
           LD_PRELOAD='/output/headless.so:/output/probe.so')
log = (p / 'runtime.log').open('w')
process = subprocess.Popen(['/project/work/RetroArch/retroarch', '--verbose', '--config',
                            '/output/test.cfg', '-L', '/output/core.so', '--max-frames', '600'],
                           env=env, stdout=log, stderr=log)
def capture():
    (p / 'capture').touch()
    deadline = time.monotonic() + 10
    while (p / 'capture').exists():
        if process.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError('Runtime stopped or no GL frame')
        time.sleep(.01)
    return (p / 'frame.rgba').read_bytes()
def pixel(frame, x, y):
    offset = ((479-y)*720+x)*4
    return list(frame[offset:offset+3])
def peaks(since):
    return [float(line.split()[1]) for line in (p / 'audio.csv').read_text().splitlines()
            if float(line.split()[0]) >= since]
def wait_audio():
    deadline = time.monotonic()+10
    while not (p/'audio.csv').exists():
        if process.poll() is not None or time.monotonic()>deadline: raise RuntimeError('No ALSA output')
        time.sleep(.02)
try:
    wait_audio()
    time.sleep(.15)
    initial = capture()
    startup_peaks = peaks(0)
    results = {'initial': pixel(initial, 10, 10), 'startup_peak': max(startup_peaks)}
    publish('2 8 50 4 0 1\n')
    time.sleep(.15)
    volume = capture()
    since = time.monotonic()
    time.sleep(.12)
    results.update(volume_bg=pixel(volume,10,10), volume_fill=pixel(volume,210,19),
                   volume_track=pixel(volume,500,19), gain50=peaks(since),
                   right_bg=pixel(volume,719,10), below_hud=pixel(volume,719,40),
                   left_outside=pixel(volume,199,19), left_edge=pixel(volume,200,19),
                   right_edge=pixel(volume,519,19), right_outside=pixel(volume,520,19),
                   icon_pixels=sum(pixel(volume,x,y)!=pixel(volume,10,10)
                                   for x in range(164,190) for y in range(7,33)))
    publish('2 9 50 9 0 2\n')
    time.sleep(.15)
    brightness=capture()
    results['brightness_fill']=pixel(brightness,510,19)
    # Reject an invalid full line, including a valid-looking prefix.
    for line in ['2 10 100 0 0 1\njunk', '2 10 101 9 0 1\n', '1 10 100 9 1\n',
                 '2 -10 100 9 0 1\n', '2 10 100 10 0 1\n', '2 10 100 9 10 1\n', '2 10 100 9 0 4\n']:
        publish(line)
        time.sleep(.08)
    results['invalid_fill']=pixel(capture(),510,19)
    since=time.monotonic()
    time.sleep(.1)
    results['invalid_gain']=peaks(since)
    publish('2 10 0 9 0 1\n')
    time.sleep(.2)
    zero=capture()
    since=time.monotonic()
    time.sleep(.1)
    results.update(zero_fill=pixel(zero,210,19), zero_gain=peaks(since))
    time.sleep(.9)
    publish('2 11 0 9 0 1\n')
    time.sleep(.2)
    results['clamp_bg']=pixel(capture(),10,10)
    time.sleep(1.13)
    results['fade_bg']=pixel(capture(),10,10)
    time.sleep(.3)
    results['hidden_bg']=pixel(capture(),10,10)
    sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    sock.sendto(b'MENU_TOGGLE\n', ('127.0.0.1',55355))
    time.sleep(.25)
    menu=capture()
    publish('2 12 0 9 0 2\n')
    time.sleep(.15)
    results['menu_fill']=pixel(capture(),510,19)
    sock.sendto(b'MENU_TOGGLE\n', ('127.0.0.1',55355))
    time.sleep(.2)
    sock.sendto(b'PAUSE_TOGGLE\n', ('127.0.0.1',55355))
    time.sleep(.15)
    publish('2 13 0 9 0 2\n')
    time.sleep(.15)
    results['paused_fill']=pixel(capture(),510,19)
    time.sleep(1.65)
    results['paused_hidden']=pixel(capture(),510,19)
    # Slot temperature multiplies the game frame and the HUD.
    publish('2 14 0 9 9 3\n')
    time.sleep(.15)
    warm=capture()
    results.update(warm_game=pixel(warm,10,300), warm_fill=pixel(warm,510,19),
                   warm_icon=sum(pixel(warm,x,y)!=pixel(warm,10,10)
                                 for x in range(164,190) for y in range(7,33)))
    time.sleep(1.65)
    results['warm_hidden']=pixel(capture(),10,300)
    publish('2 15 0 9 0 3\n')
    time.sleep(1.8)
    results['neutral']=pixel(capture(),10,300)
    sock.close()
    print(json.dumps(results))
finally:
    process.terminate()
    try: process.wait(timeout=10)
    except subprocess.TimeoutExpired: process.kill(); process.wait()
    log.close()
'''

@unittest.skipUnless(os.environ.get('RETROARCH_CONTROLS_SMOKE') == '1',
                     'Set RETROARCH_CONTROLS_SMOKE=1 to test ARM64 GL and ALSA')
class ControlsRuntimeTests(unittest.TestCase):
    def test_shared_controls_render_and_scale_actual_pcm(self):
        with tempfile.TemporaryDirectory(prefix='ra-controls-') as directory:
            output = Path(directory)
            (output / 'probe.py').write_text(PROBE)
            config = (ROOT / 'card/System/socket/retroarch/retroarch.cfg').read_text()
            keys = {'audio_device': 'null', 'video_shader_enable': 'false',
                    'video_vsync': 'false', 'audio_sync': 'false', 'menu_driver': 'rgui', 'network_cmd_enable': 'true', 'network_cmd_port': '55355',
                    'audio_driver': 'alsa', 'video_font_enable': 'false', 'savestate_auto_load': 'false',
                    'rewind_enable': 'false', 'aspect_ratio_index': '22', 'audio_rate_control': 'false',
                    'frontend_log_level': '0'}
            config = '\n'.join(line for line in config.splitlines() if line.split(' = ', 1)[0] not in keys)
            config += '\n' + '\n'.join(f'{key} = "{value}"' for key, value in keys.items()) + '\n'
            (output / 'test.cfg').write_text(config)
            script = '''set -eu
cc -shared -fPIC /project/tests/retroarch_headless_egl.c -o /output/headless.so -ldl -lEGL
cc -shared -fPIC /project/tests/retroarch_controls_probe.c -o /output/probe.so -ldl -lEGL -lGLESv2 -lasound
cc -shared -fPIC -I/project/work/RetroArch/libretro-common/include /project/tests/retroarch_controls_core.c -o /output/core.so
python3 /output/probe.py
'''
            result = subprocess.run(['docker', 'run', '--rm', '--platform', 'linux/arm64',
                                     '-v', f'{ROOT}:/project:ro', '-v', f'{output}:/output',
                                     'socket-baseos-godot', 'sh', '-c', script],
                                    capture_output=True, text=True, timeout=90)
            log = (output / 'runtime.log').read_text() if (output / 'runtime.log').exists() else ''
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr + log)
            import json
            data = json.loads(result.stdout)
            self.assertIn('Using FLOAT_LE sample format', log)
            self.assertEqual(data['initial'], [100, 120, 140], data)
            # The sinc resampler can overshoot the initial DC edge.
            self.assertTrue(.079 <= data['startup_peak'] <= .09, data)
            self.assertEqual(data['volume_bg'], [28, 33, 39], data)
            self.assertEqual(data['volume_fill'], [245, 242, 239], data)
            self.assertEqual(data['right_bg'], data['volume_bg'], data)
            self.assertEqual(data['below_hud'], data['initial'], data)
            self.assertEqual(data['left_outside'], data['volume_bg'], data)
            self.assertEqual(data['left_edge'], data['volume_fill'], data)
            self.assertEqual(data['right_edge'], data['volume_track'], data)
            self.assertEqual(data['right_outside'], data['volume_bg'], data)
            self.assertGreater(data['icon_pixels'], 100, data)
            self.assertTrue(65 <= data['volume_track'][0] <= 71, data)
            self.assertEqual(data['brightness_fill'], [245, 242, 239], data)
            self.assertEqual(data['invalid_fill'], data['brightness_fill'], data)
            for key in ('gain50', 'invalid_gain'):
                self.assertTrue(data[key], data)
                for peak in data[key]: self.assertAlmostEqual(peak, .125, delta=.002)
            self.assertEqual(data['zero_gain'], [0.0] * len(data['zero_gain']), data)
            self.assertTrue(data['zero_gain'], data)
            self.assertEqual(data['zero_fill'], data['volume_track'], data)
            self.assertEqual(data['clamp_bg'], data['volume_bg'], data)
            self.assertTrue(28 < data['fade_bg'][0] < 100, data)
            self.assertEqual(data['hidden_bg'], data['initial'], data)
            self.assertEqual(data['menu_fill'], [245, 242, 239], data)
            self.assertEqual(data['paused_fill'], [245, 242, 239], data)
            self.assertEqual(data['paused_hidden'], data['initial'], data)
        warm = [100, round(120 * .82), round(140 * .62)]
        for key in ('warm_game', 'warm_hidden'):
            for actual, expected in zip(data[key], warm): self.assertAlmostEqual(actual, expected, delta=2, msg=data)
        for actual, expected in zip(data['warm_fill'], [245, 242 * .82, 239 * .62]):
            self.assertAlmostEqual(actual, expected, delta=2, msg=data)
        self.assertGreater(data['warm_icon'], 100, data)
        self.assertEqual(data['neutral'], data['initial'], data)

if __name__ == '__main__': unittest.main()
