"""Test menu pixels, raw-pad navigation, pause, state I/O, and shutdown in ARM64 RetroArch."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
# Set SOCKET_RETROARCH_SOURCE to test a RetroArch tree outside work/.
SOURCE = os.environ.get('SOCKET_RETROARCH_SOURCE')

# The first frames only record the audio route. Each later change of
# bluetooth.audio opens the audio device again, one time.
ROUTE_PROBE = r'''
import json, os, signal, subprocess, time
from pathlib import Path
p = Path('/output')
env = dict(os.environ, SOCKET_RUN='/output', EGL_PLATFORM='surfaceless',
           LD_PRELOAD='/output/headless.so:/output/probe.so')
(p/'controls').write_text('2 0 40 4 0 0\n')
if (p/'mode').read_text() == 'headset': (p/'bluetooth.audio').write_text('00:11:22:33:44:55\n')
log = (p/'runtime.log').open('w')
process = subprocess.Popen(['/project/work/RetroArch/retroarch', '--verbose', '--config', '/output/test.cfg',
    '-L', '/output/core.so', '/output/probe.bin'], env=env, stdout=log, stderr=log)
def changes(): return (p/'runtime.log').read_text().count('[Socket] Audio route changed')
def until(predicate):
    deadline = time.monotonic()+15
    while not predicate():
        if process.poll() is not None or time.monotonic()>deadline:
            raise RuntimeError('Runtime ended or condition timed out')
        time.sleep(.01)
try:
    until(lambda: (p/'runs').exists())
    time.sleep(1.2)
    assert changes() == 0, 'no reinit at start'
    if (p/'bluetooth.audio').exists(): (p/'bluetooth.audio').unlink()
    else: (p/'bluetooth.audio').write_text('00:11:22:33:44:55\n')
    until(lambda: changes() == 1)
    time.sleep(1.2)
    assert changes() == 1, 'one reinit for one change'
    # The core replaces the file for each frame. An empty read is not a frame count.
    def runs(): return int((p/'runs').read_text() or '0')
    before = runs()
    until(lambda: runs() > before + 10)
    process.send_signal(signal.SIGTERM)
    process.wait(timeout=10)
    print(json.dumps(dict(returncode=process.returncode, request=False)))
finally:
    if process.poll() is None:
        process.kill(); process.wait()
    log.close()
'''

# This probe has the role of the launcher. It answers the open request with a
# frame, then selects the Game row.
OVERLAY_PROBE = r'''
import json, os, signal, struct, subprocess, time
from pathlib import Path
p = Path('/output')
env = dict(os.environ, SOCKET_RUN='/output', SOCKET_FRONTEND_PID=str(os.getpid()), SOCKET_GAME_OVERLAY_EGL='1', EGL_PLATFORM='surfaceless',
           LD_PRELOAD='/output/headless.so:/output/probe.so')
(p/'controls').write_text('2 0 40 4 0 0\n')
log = (p/'runtime.log').open('w')
process = subprocess.Popen(['/project/work/RetroArch/retroarch', '--verbose', '--config', '/output/test.cfg',
    '-L', '/output/core.so', '/output/probe.bin'], env=env, stdout=log, stderr=log)
def until(predicate):
    deadline = time.monotonic()+15
    while not predicate():
        if process.poll() is not None or time.monotonic()>deadline:
            raise RuntimeError('Runtime ended or condition timed out')
        time.sleep(.01)
def capture():
    (p/'capture').touch()
    until(lambda: not (p/'capture').exists())
    return (p/'frame.rgba').read_bytes()
def pixel(frame,x,y):
    offset=((479-y)*720+x)*4
    return list(frame[offset:offset+3])
def lines(): return (p/'menu.input').read_text().splitlines() if (p/'menu.input').exists() else []
def put(name, data):
    (p/(name+'.new')).write_bytes(data)
    (p/(name+'.new')).replace(p/name)
def runs(): return int((p/'runs').read_text() or '0')
try:
    until(lambda: 'open 1' in lines())
    stopped = runs()
    dimmed = pixel(capture(),100,100)
    # Top half: an opaque color. Bottom half: black at half strength. The
    # color has the alpha in it.
    put('menu.frame', b'SKMF'+struct.pack('<6I',1,1,1,720,480,1)+bytes([10,200,30,255])*(720*240)+bytes([0,0,0,128])*(720*240))
    time.sleep(.3)
    frame = capture()
    until(lambda: 'pad down 1' in lines())
    # Longer than the wait for the first frame.
    time.sleep(1.5)
    quiet = pixel(capture(),100,100)
    # A level change shows no bar of RetroArch above the scene.
    put('controls', b'2 1 60 4 0 1\n')
    time.sleep(.15)
    level = pixel(capture(),210,19)
    put('menu.theme', b'1 204060 f0e0d0 137 67 446 346 18\n')
    put('menu.event', b'1 1 game\n')
    until(lambda: 'pad down 0' in lines())
    time.sleep(.2)
    native = capture()
    paused = runs()
    put('menu.event', b'1 2 close\n')
    time.sleep(.3)
    still_native = pixel(capture(),30,60)
    (p/'render.json').write_text(json.dumps(dict(dimmed=dimmed, top=pixel(frame,100,100), bottom=pixel(frame,100,400),
        quiet=quiet, level=level, native=pixel(native,30,60), outline=pixel(native,44,110), still_native=still_native, stopped=stopped, paused=paused,
        lines=lines())))
    process.send_signal(signal.SIGTERM)
    process.wait(timeout=10)
    print(json.dumps(dict(returncode=process.returncode, request=False)))
finally:
    if process.poll() is None:
        process.kill(); process.wait()
    log.close()
'''

# This probe has the role of a launcher with menu.theme version 2. RetroArch
# keeps the pad on its pages and the probe draws them: one frame for each
# view line and root line.
VIEW_PROBE = OVERLAY_PROBE[:OVERLAY_PROBE.index("try:")] + r'''
def frame(serial, color):
    put('menu.frame', b'SKMF'+struct.pack('<6I',1,1,serial+1,720,480,1|serial<<8)+bytes(color+[255])*(720*480))
def shown(): return pixel(capture(),100,100)
def text(word): return bytes.fromhex(word).decode()
try:
    until(lambda: 'open 1' in lines())
    stopped = runs()
    frame(0, [10,200,30])
    put('menu.theme', b'2 204060 f0e0d0 137 67 446 346 18\n')
    put('menu.event', b'1 1 game\n')
    until(lambda: len(lines()) == 3)
    # The frame of Device Settings is not the Game page.
    waiting = shown()
    frame(1, [200,10,30])
    time.sleep(.3)
    game = shown()
    size = (p/'menu.input').stat().st_size
    # Down at frame 240.
    until(lambda: len(lines()) == 4)
    frame(2, [30,10,200])
    # Longer than the wait for a frame: a page without a change needs no frame and no line.
    time.sleep(1.8)
    moved = shown()
    # The scene shows no levels during a view: the bar of RetroArch is above it.
    put('controls', b'2 1 60 4 0 1\n')
    time.sleep(.15)
    level = pixel(capture(),210,19)
    quiet = (p/'menu.input').stat().st_size
    # Down at frames 480 and 540, then A on "Save state" at frame 600.
    for serial in (3, 4, 5):
        until(lambda: len(lines()) == serial + 2)
        frame(serial, [30,10,200])
    time.sleep(.3)
    status = capture()
    # B at frame 720.
    until(lambda: len(lines()) == 8)
    back = shown()
    frame(6, [10,200,30])
    time.sleep(.3)
    root = shown()
    until(lambda: 'pad down 1' in lines())
    (p/'render.json').write_text(json.dumps(dict(waiting=waiting, game=game, moved=moved, level=level, back=back, root=root,
        stopped=stopped, paused=runs(), status=text(lines()[6].split()[6]),
        osd=sum(pixel(status,x,y) != [30,10,200] for x in range(0,720,2) for y in range(0,480,2)), idle=size == len('\n'.join(lines()[:3]))+1, quiet=quiet-size, lines=lines(),
        views=[[*line.split()[:5], *map(text, [w for w in line.split()[5:] if w != '-'])] for line in lines()[2:4]])))
    process.send_signal(signal.SIGTERM)
    process.wait(timeout=10)
    print(json.dumps(dict(returncode=process.returncode, request=False)))
finally:
    if process.poll() is None:
        process.kill(); process.wait()
    log.close()
'''

# This probe has no launcher that can draw the scene. RetroArch shows its
# native pages in the first menu frame.
PROBE = r'''
import json, os, subprocess, time
from pathlib import Path
p = Path('/output')
env = dict(os.environ, SOCKET_RUN='/output', SOCKET_MENU_CONFIG='/output/menu.cfg',
           SOCKET_CORE_OPTIONS='/output/options.cfg', SOCKET_GAME_DESCRIPTOR='/output/game.descriptor',
           SOCKET_RESUME_MANIFEST='/output/resume-game', EGL_PLATFORM='surfaceless',
           LD_PRELOAD='/output/headless.so:/output/probe.so')
(p/'controls').write_text('2 0 40 4 0 0\n')
log = (p/'runtime.log').open('w')
args = ['/project/work/RetroArch/retroarch', '--verbose', '--config', '/output/test.cfg',
        '-L', '/output/core.so', '/output/probe.bin', '--max-frames', '520']
if (p/'shader').exists(): args += ['--set-shader', '/project/card/System/socket/retroarch/shaders/grid.glslp']
process = subprocess.Popen(args, env=env, stdout=log, stderr=log)
def until(predicate):
    deadline = time.monotonic()+15
    while not predicate():
        if process.poll() is not None or time.monotonic()>deadline:
            raise RuntimeError('Runtime ended or condition timed out')
        time.sleep(.01)
def capture(name):
    (p/'capture').touch()
    until(lambda: not (p/'capture').exists())
    data = (p/'frame.rgba').read_bytes()
    (p/(name+'.rgba')).write_bytes(data)
    return data
def pixel(frame,x,y):
    offset=((479-y)*720+x)*4
    return list(frame[offset:offset+3])
try:
    until(lambda: (p/'runs').exists())
    mode = (p/'mode').read_text()
    if mode == 'shutdown':
        (p/'poweroff.request').write_text('9001\n')
    else:
        until(lambda: '[Socket Menu] Open.' in (p/'runtime.log').read_text())
        time.sleep(.2)
        before = int((p/'runs').read_text())
        menu = capture('menu')
        (p/'next').write_text('2 1 60 4 0 1\n')
        (p/'next').replace(p/'controls')
        time.sleep(.15)
        hud = capture('hud')
        time.sleep(.3)
        after = int((p/'runs').read_text())
        (p/'render.json').write_text(json.dumps(dict(before=before, after=after,
            border=pixel(menu,44,220), panel=pixel(menu,30,60),
            text_pixels=sum(pixel(menu,x,y)!=pixel(menu,30,60)
                for x in range(60,175) for y in range(100,125)),
            hud=pixel(hud,210,19))))
    if (p/'corrupt').exists():
        until(lambda: 'Load failed. Game is still running.' in (p/'runtime.log').read_text())
        data=json.loads((p/'render.json').read_text())
        data['corrupt_count']=int((p/'runs').read_text())
        (p/'render.json').write_text(json.dumps(data))
    if mode == 'menu' and (p/'fail').exists():
        until(lambda: 'Save failed.' in (p/'runtime.log').read_text())
        warning = capture('warning')
        data=json.loads((p/'render.json').read_text())
        data['warning_pixels']=sum(pixel(warning,x,y)!=pixel(warning,30,415)
                for x in range(60,650) for y in range(415,435))
        (p/'render.json').write_text(json.dumps(data))
    try: process.wait(timeout=20)
    except subprocess.TimeoutExpired: raise RuntimeError('Menu process did not exit')
    print(json.dumps(dict(returncode=process.returncode,
          request=(p/'poweroff.request').exists())))
finally:
    if process.poll() is None:
        process.kill(); process.wait()
    log.close()
if (p/'relaunch').exists():
    import shutil
    system=Path('/mnt/sdcard/System/socket')
    (system/'retroarch').mkdir(parents=True)
    (system/'cores').mkdir()
    for path in Path('/project/card/System/socket/retroarch').glob('*.cfg'):
        shutil.copy(path,system/'retroarch'/path.name)
    shutil.copytree('/project/card/System/socket/retroarch/shaders',system/'retroarch/shaders')
    (system/'retroarch/retroarch').symlink_to('/project/work/RetroArch/retroarch')
    (system/'cores/mgba_libretro.so').symlink_to('/output/core.so')
    (system/'retroarch/retroarch.cfg').write_text((p/'test.cfg').read_text())
    preferences=Path('/mnt/sdcard/Saves/socket/retroarch')
    preferences.mkdir(parents=True)
    shutil.copy(p/'menu.cfg',preferences/'gba.cfg')
    with (preferences/'mgba-gba-options.cfg').open('w') as f:
        f.write((p/'options.cfg').read_text().replace('mgba_force_gbp = "OFF"','mgba_force_gbp = "ON"'))
    content=bytearray(400)
    content[172]=77
    (p/'probe.gba').write_bytes(content)
    (p/'joypad.json').write_text('[{"frame":0,"action":1,"param_num":0,"param_str":"(0000:0000) Persisted menu test"}]')
    launcher=system/'launch_game.sh'
    launcher.write_text(Path('/project/card/System/socket/launch_game.sh').read_text().replace(
        '"$SYS/retroarch/retroarch"','"$SYS/retroarch/retroarch" --max-frames 60'))
    (p/'runs').unlink()
    with (p/'relaunch.log').open('w') as logfile:
        process=subprocess.Popen(['sh',str(launcher),'mgba','/output/probe.gba','gba'],env=env,stdout=logfile,stderr=logfile)
        try:
            until(lambda: (p/'runs').exists())
            frame=capture('relaunch')
            results=dict(pixel=pixel(frame,719,479),options=json.loads((p/'seen-options.json').read_text()))
            process.wait(timeout=15)
            results['returncode']=process.returncode
            (p/'relaunch.json').write_text(json.dumps(results))
        finally:
            if process.poll() is None: process.kill(); process.wait()
''' 


def presses(sequence, start=120, step=10):
    events = []
    for index, button in enumerate(sequence):
        frame = start + index * step
        events += [dict(frame=frame, action=16, param_num=button),
                   dict(frame=frame+3, action=32, param_num=button)]
    return events


@unittest.skipUnless(os.environ.get('RETROARCH_QUICK_MENU_SMOKE') == '1',
                     'Set RETROARCH_QUICK_MENU_SMOKE=1 for ARM64 runtime tests')
class QuickMenuRuntimeTests(unittest.TestCase):
    def run_case(self, sequence=(), *, mode='menu', fail=False, shader=False, extra='', relaunch=False, fail_settings=False, corrupt=False, probe_script=PROBE, prepare=None):
        # Docker can hold a read-only mount for a moment after the container stops.
        with tempfile.TemporaryDirectory(prefix='ra-quick-menu-',ignore_cleanup_errors=True) as directory:
            output = Path(directory)
            core = (ROOT/'tests/retroarch_controls_core.c').read_text()
            core = core.replace('static retro_environment_t environment;', 'static unsigned runs;\nstatic retro_environment_t environment;')
            core = core.replace('void retro_init(void) {', '''void retro_init(void) {
   static struct retro_variable options[] = {
      {"mgba_color_correction", "Color correction; disabled|enabled"},
      {"probe_quality", "Quality; Low|High"},
      {"mgba_force_gbp", "Force GBP; OFF|ON"}, {NULL,NULL}};
   environment(RETRO_ENVIRONMENT_SET_VARIABLES, options);''')
            core = core.replace('   static uint32_t pixels[720 * 480];', '''   FILE *file = fopen("/output/runs", "w");
   fprintf(file, "%u", ++runs); fclose(file);
   struct retro_variable color = {"mgba_color_correction", NULL};
   struct retro_variable gbp = {"mgba_force_gbp", NULL};
   environment(RETRO_ENVIRONMENT_GET_VARIABLE, &color);
   environment(RETRO_ENVIRONMENT_GET_VARIABLE, &gbp);
   file = fopen("/output/seen-options.json", "w");
   fprintf(file, "{\\"color\\":\\"%s\\",\\"gbp\\":\\"%s\\"}", color.value, gbp.value); fclose(file);
   static uint32_t pixels[720 * 480];''')
            core = core.replace('#include <unistd.h>', '#include <unistd.h>\n#include <stdio.h>')
            core = core.replace('size_t retro_serialize_size(void) { return 0; }', 'size_t retro_serialize_size(void) { return 64; }')
            core = core.replace('(void)p; (void)n; return false;', 'if(n!=64) return false; memset(p,0,n); memcpy(p,&runs,sizeof(runs)); return true;', 1)
            core = core.replace('(void)p; (void)n; return false;', 'if(n!=64) return false; memcpy(&runs,p,sizeof(runs)); return true;', 1)
            (output/'core.c').write_text(core)
            (output/'probe.py').write_text(probe_script)
            (output/'input.json').write_text('[{"frame":0,"action":0}]')
            events = [dict(frame=0, action=1, param_num=0, param_str='(0000:0000) Socket quick menu test')]
            if mode == 'menu':
                events += presses([32768], 10)
                # L2 and R2 cannot run the core while the menu is open.
                events += [dict(frame=25,action=16,param_num=1536), dict(frame=80,action=32,param_num=1536)]
                events += presses(sequence)
            (output/'joypad.json').write_text(json.dumps(events))
            (output/'mode').write_text(mode)
            (output/'game.descriptor').write_text('socket-resume-v1\nprobe\n/output/probe.bin\ngba\n')
            (output/'probe.bin').write_bytes(bytes(16))
            (output/'states').mkdir()
            (output/'shots').mkdir()
            if fail:
                (output/'states/probe.state.auto').write_bytes(b'previous state')
                (output/'states/probe.state').write_bytes(b'previous slot')
            if shader: (output/'shader').touch()
            if relaunch: (output/'relaunch').touch()
            if fail: (output/'fail').touch()
            if corrupt:
                (output/'corrupt').touch()
                (output/'states/probe.state1').write_bytes(b'bad state data')
            if fail_settings: (output/'menu.cfg').write_text('state_slot = \"7\"\n')
            settings = {'video_driver':'gl', 'video_context_driver':'mali-fbdev', 'video_threaded':'false',
                'video_shader_enable':str(shader).lower(), 'video_vsync':'false', 'audio_sync':'false',
                'video_font_enable':'true', 'video_font_size':'20', 'video_font_path':'/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
                'video_msg_color':'ffffff', 'video_msg_pos_x':'0.05', 'video_msg_pos_y':'0.95',
                'audio_driver':'alsa','audio_device':'null','audio_rate_control':'false',
                'input_driver':'test','input_joypad_driver':'test','input_autodetect_enable':'false',
                'test_input_file_general':'/output/input.json', 'test_input_file_joypad':'/output/joypad.json',
                'savestate_directory':'/output/states','screenshot_directory':'/output/shots',
                'savestate_auto_load':'false','savestate_auto_save':'false','savestate_file_compression':'false',
                'savestate_thumbnail_enable':'false','sort_savestates_enable':'false',
                'sort_savestates_by_content_enable':'false','rewind_enable':'false','menu_pause_libretro':'true',
                'menu_driver':'rgui','frontend_log_level':'0','aspect_ratio_index':'22',
                'config_save_on_exit':'false','input_player1_a_btn':'8','input_player1_b_btn':'0',
                'input_player1_up_btn':'4','input_player1_down_btn':'5','input_player1_left_btn':'6',
                'input_player1_right_btn':'7','input_menu_toggle_btn':'15','input_rewind_btn':'9',
                'input_hold_fast_forward_btn':'10','fastforward_ratio':'4.0'}
            font = os.environ.get('SOCKET_QUICK_MENU_FONT')
            if font:
                import shutil
                shutil.copy(font, output/'menu-font.otf')
                settings['video_font_path'] = '/output/menu-font.otf'
            (output/'test.cfg').write_text('\n'.join(f'{k} = "{v}"' for k,v in settings.items())+'\n')
            if extra: (output/'test.cfg').write_text(extra+'\n'+(output/'test.cfg').read_text())
            if prepare: prepare(output)
            script = '''set -eu
cc -shared -fPIC /project/tests/retroarch_headless_egl.c -o /output/headless.so -ldl -lEGL
cc -shared -fPIC /project/tests/retroarch_controls_probe.c -o /output/probe.so -ldl -lEGL -lGLESv2 -lasound
cc -shared -fPIC -I/project/work/RetroArch/libretro-common/include /output/core.c -o /output/core.so
python3 /output/probe.py
'''
            command = ['docker','run','--rm','--platform','linux/arm64','-v',f'{ROOT}:/project:ro','-v',f'{output}:/output']
            if SOURCE: command += ['-v',f'{SOURCE}:/project/work/RetroArch:ro']
            if fail: command += ['-v',f'{output}/states:/output/states:ro']
            if fail_settings: command += ['-v',f'{output}/menu.cfg:/output/menu.cfg:ro']
            command += ['socket-baseos-godot','sh','-c',script]
            result = subprocess.run(command,capture_output=True,text=True,timeout=50)
            log = (output/'runtime.log').read_text() if (output/'runtime.log').exists() else ''
            self.assertEqual(result.returncode,0,result.stdout+result.stderr+log)
            capture = os.environ.get('SOCKET_QUICK_MENU_CAPTURE')
            if capture and (output/'menu.rgba').exists():
                import struct, zlib
                rgba = (output/'menu.rgba').read_bytes()
                rows = b''.join(b'\0'+rgba[y*720*4:(y+1)*720*4] for y in range(479,-1,-1))
                def chunk(kind, data):
                    return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data))
                Path(capture).write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!2I5B',720,480,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b''))
            report = json.loads(result.stdout)
            self.assertEqual(report['returncode'],0,log)
            return dict(log=log, report=report,
                relaunch=json.loads((output/'relaunch.json').read_text()) if (output/'relaunch.json').exists() else {},
                render=json.loads((output/'render.json').read_text()) if (output/'render.json').exists() else {},
                files={str(path.relative_to(output)):path.read_bytes() for path in output.rglob('*')
                    if path.is_file() and path.suffix not in ('.so','.rgba')})

    def test_navigation_state_screenshot_and_save_exit(self):
        down, up, right, ok, menu = 32, 16, 128, 256, 32768
        data=self.run_case([ok,down,down,right,down,ok,down,ok,ok,down,ok,menu,ok,up,ok])
        self.assertIn('[Socket Menu] Open.',data['log'])
        self.assertIn('succeeded',data['log'])
        self.assertIn('[Socket Menu] State loaded.',data['log'])
        self.assertEqual(data['render']['border'],[208,208,208])
        self.assertEqual(data['render']['panel'],[33,33,33])
        self.assertGreater(data['render']['text_pixels'],20)
        self.assertEqual(data['render']['hud'],[245,242,239])
        self.assertEqual(data['render']['before'],data['render']['after'])
        states={name:contents for name,contents in data['files'].items() if name.startswith('states/')}
        self.assertTrue(any('state1' in name for name in states),states)
        self.assertTrue(any('.auto' in name for name in states),states)
        self.assertTrue(any(name.startswith('shots/') for name in data['files']),data['files'].keys())
        self.assertIn(b'state_slot = "1"',data['files']['menu.cfg'])
        self.assertFalse(any(name.endswith('.tmp') for name in data['files']))

    def test_core_and_gameplay_settings_persist(self):
        down,right,ok,back,menu=32,128,256,1,32768
        # Core option, then Screen shader/scaling, then Gameplay speed/sound/rewind.
        data=self.run_case([ok,down,ok,right,back,*([down]*6),ok,right,down,down,right,back,
                           *([down]*7),ok,right,down,right,down,right,back,menu],shader=True,relaunch=True)
        config=data['files']['menu.cfg'].decode()
        for line in ('video_shader_enable = "false"','fastforward_ratio = "5.000000"',
                     'audio_fastforward_mute = "true"','rewind_enable = "true"','video_scale_integer = "true"'):
            self.assertIn(line,config)
        options=data['files']['options.cfg'].decode()
        self.assertIn('mgba_color_correction = "enabled"',options)
        self.assertIn('probe_quality = "Low"',options)
        self.assertNotIn('audio_driver',config)
        self.assertEqual(data['relaunch']['returncode'],0,data['files']['relaunch.log'].decode())
        self.assertEqual(data['relaunch']['options'],dict(color='enabled',gbp='OFF'))
        self.assertEqual(data['relaunch']['pixel'],[100,120,140])
        self.assertFalse(any(name.endswith('.tmp') for name in data['files']))

    def test_failed_save_exit_shows_status_and_preserves_state(self):
        data=self.run_case([256,32,32,32,256,16,16,16,16,256],fail=True)
        self.assertIn('[Socket Menu] Save failed. Game is still running.',data['log'])
        self.assertGreater(data['render']['warning_pixels'],100)
        self.assertIn('[Socket Menu] Save failed. Previous state was kept.',data['log'])
        self.assertEqual(data['files']['states/probe.state'],b'previous slot')
        self.assertEqual(data['files']['states/probe.state.auto'],b'previous state')

    def test_load_confirmation_resets_on_navigation(self):
        down,up,right,ok,menu=32,16,128,256,32768
        data=self.run_case([ok,down,down,right,down,ok,down,ok,down,up,ok,menu])
        self.assertEqual(data['log'].count('[Socket Menu] Load this state?'),2)
        self.assertNotIn('[Socket Menu] State loaded.',data['log'])
        self.assertNotIn('[State] Loading state',data['log'])

    def test_corrupt_load_reports_failure_and_keeps_running_state(self):
        data=self.run_case([256,32,32,128,32,32,256,256,32768],corrupt=True)
        self.assertIn('[Socket Menu] Load failed. Game is still running.',data['log'])
        self.assertEqual(data['render']['before'],data['render']['corrupt_count'])
        self.assertGreater(int(data['files']['runs']),100)
        self.assertEqual(data['files']['states/probe.state1'],b'bad state data')

    def test_settings_write_failure_keeps_previous_file(self):
        data=self.run_case([256,32,32,128,32768],fail_settings=True)
        self.assertIn('[Socket Menu] Settings could not be saved.',data['log'])
        self.assertEqual(data['files']['menu.cfg'],b'state_slot = "7"\n')
        self.assertFalse(any(name.endswith('.tmp') for name in data['files']))

    def test_missing_font_uses_builtin_fallback(self):
        data=self.run_case([32768],extra='video_font_path = "/missing/socket-font.otf"\n')
        self.assertGreater(data['render']['text_pixels'],20)
        self.assertEqual(data['render']['border'],[208,208,208])

    def test_device_settings_root_opens_and_closes_pages(self):
        down,up,ok,back,menu=32,16,256,1,32768
        # Game and back. Then Wi-Fi and back. Then Bluetooth, and MENU closes its page.
        data=self.run_case([ok,back,up,up,ok,back,down,ok,menu])
        log=data['log']
        game=log.index('[Socket Menu] Game row 0.')
        closed=log.index('[Socket Menu] Page closed.',game)
        self.assertLess(closed,log.index('[Socket Menu] Device Settings row 2.'))
        self.assertEqual(data['log'].count('[Socket Menu] Page closed.'),2)
        self.assertGreater(int(data['files']['runs']),data['render']['after'])

    def test_launcher_scene_is_the_root_page(self):
        menu,down=32768,32
        def prepare(output):
            # MENU opens the menu. Down stays pressed from frame 60.
            (output/'joypad.json').write_text(json.dumps([
                dict(frame=0,action=1,param_num=0,param_str='(0000:0000) Socket quick menu test'),
                dict(frame=10,action=16,param_num=menu),dict(frame=13,action=32,param_num=menu),
                dict(frame=60,action=16,param_num=down)]))
        data=self.run_case(mode='overlay',probe_script=OVERLAY_PROBE,prepare=prepare)
        render=data['render']
        # Before the first frame: the game below the dimmer, and no native panel.
        self.assertEqual(render['dimmed'],[40,48,56])
        self.assertEqual(render['top'],[10,200,30])
        for channel,expected in zip(render['bottom'],[50,60,70]):
            self.assertAlmostEqual(channel,expected,delta=2)
        self.assertEqual(render['quiet'],[10,200,30])
        self.assertEqual(render['level'],[10,200,30])
        # The Game row gives the native page with the colors of the scene. The game stays paused.
        self.assertEqual(render['native'],[0x20,0x40,0x60])
        self.assertEqual(render['outline'],[0xf0,0xe0,0xd0])
        self.assertEqual(render['stopped'],render['paused'])
        # An event of the scene has no effect while a native page has the pad.
        self.assertEqual(render['still_native'],[0x20,0x40,0x60])
        self.assertRegex(render['lines'][0],r'^session \d+-\d+ 2$')
        self.assertEqual(render['lines'][1:],['open 1','pad down 1','pad down 0'])
        self.assertNotIn('The launcher did not show',data['log'])

    def test_version_2_launcher_draws_the_game_page(self):
        menu,down,back=32768,32,1
        def prepare(output):
            events=[dict(frame=0,action=1,param_num=0,param_str='(0000:0000) Socket quick menu test')]
            for at,button in ((10,menu),(240,down),(480,down),(540,down),(600,256),(720,back),(900,down)):
                events+=[dict(frame=at,action=16,param_num=button),dict(frame=at+3,action=32,param_num=button)]
            (output/'joypad.json').write_text(json.dumps(events))
        data=self.run_case(mode='overlay',probe_script=VIEW_PROBE,prepare=prepare)
        render=data['render']
        self.assertEqual(render['waiting'],[40,48,56])
        self.assertEqual(render['game'],[200,10,30])
        self.assertEqual(render['moved'],[30,10,200])
        self.assertEqual(render['level'],[245,242,239])
        # The scene shows the status of the view. RetroArch does not show it again.
        self.assertEqual(render['status'],'State saved.')
        self.assertEqual(render['osd'],0)
        self.assertEqual(render['back'],[40,48,56])
        self.assertEqual(render['root'],[10,200,30])
        self.assertEqual(render['stopped'],render['paused'])
        # One line for each page change, and none while the page stays the same.
        self.assertTrue(render['idle'])
        self.assertEqual(render['quiet'],len(render['lines'][3])+1)
        rows=['Resume','Core options','State slot                 0','Save state','Load state','Screenshot']
        self.assertEqual(render['views'],[['view','1','0','0','10','Game',*rows],['view','1','1','0','10','Game',*rows]])
        self.assertRegex(render['lines'][0],r'^session \d+-\d+ 2$')
        self.assertEqual(render['lines'][1],'open 1')
        self.assertEqual(render['lines'][7:],['root 1','pad down 1','pad down 0'][:len(render['lines'])-7])
        self.assertNotIn('The launcher did not show',data['log'])

    def test_audio_route_change_opens_audio_again_one_time(self):
        for mode,route in (('speaker','Bluetooth'),('headset','the speaker')):
            with self.subTest(mode):
                data=self.run_case(mode=mode,probe_script=ROUTE_PROBE)
                self.assertEqual(data['log'].count('[Socket] Audio route changed to '+route+'.'),1)

    def test_timed_shutdown_saves_before_clean_exit(self):
        data=self.run_case(mode='shutdown')
        self.assertTrue(data['report']['request'])
        self.assertEqual(data['files']['poweroff.ack'],b'9001 ok\n')
        self.assertIn('resume-game',data['files'])
        self.assertTrue(any(name.startswith('states/') and name.endswith('.sleep') for name in data['files']))

    def test_failed_timed_save_reports_error_and_runs(self):
        data=self.run_case(mode='shutdown',fail=True)
        self.assertTrue(data['report']['request'])
        self.assertEqual(data['files']['poweroff.ack'],b'9001 error\n')
        self.assertIn('failed',data['log'])
        self.assertEqual(data['files']['states/probe.state.auto'],b'previous state')
        self.assertGreater(int(data['files']['runs']),100)

if __name__=='__main__': unittest.main()
