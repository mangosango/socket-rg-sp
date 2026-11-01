"""Test menu pixels, raw-pad navigation, pause, state I/O, and shutdown in ARM64 RetroArch."""
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
            border=pixel(menu,44,100), panel=pixel(menu,10,50),
            text_pixels=sum(pixel(menu,x,y)!=pixel(menu,10,50)
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
        data['warning_pixels']=sum(pixel(warning,x,y)!=pixel(warning,10,415)
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
        with tempfile.TemporaryDirectory(prefix='ra-quick-menu-') as directory:
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
        data=self.run_case([down,down,right,down,ok,down,ok,ok,down,ok,menu,up,ok])
        self.assertIn('[Socket Menu] Open.',data['log'])
        self.assertIn('succeeded',data['log'])
        self.assertIn('[Socket Menu] State loaded.',data['log'])
        self.assertEqual(data['render']['border'],[255,255,255])
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
        data=self.run_case([down,ok,right,back,*([down]*6),ok,right,down,down,right,back,
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
        data=self.run_case([32,32,32,256,16,16,16,16,256],fail=True)
        self.assertIn('[Socket Menu] Save failed. Game is still running.',data['log'])
        self.assertGreater(data['render']['warning_pixels'],100)
        self.assertIn('[Socket Menu] Save failed. Previous state was kept.',data['log'])
        self.assertEqual(data['files']['states/probe.state'],b'previous slot')
        self.assertEqual(data['files']['states/probe.state.auto'],b'previous state')

    def test_load_confirmation_resets_on_navigation(self):
        down,up,right,ok,menu=32,16,128,256,32768
        data=self.run_case([down,down,right,down,ok,down,ok,down,up,ok,menu])
        self.assertEqual(data['log'].count('[Socket Menu] Load this state?'),2)
        self.assertNotIn('[Socket Menu] State loaded.',data['log'])
        self.assertNotIn('[State] Loading state',data['log'])

    def test_corrupt_load_reports_failure_and_keeps_running_state(self):
        data=self.run_case([32,32,128,32,32,256,256,32768],corrupt=True)
        self.assertIn('[Socket Menu] Load failed. Game is still running.',data['log'])
        self.assertEqual(data['render']['before'],data['render']['corrupt_count'])
        self.assertGreater(int(data['files']['runs']),100)
        self.assertEqual(data['files']['states/probe.state1'],b'bad state data')

    def test_settings_write_failure_keeps_previous_file(self):
        data=self.run_case([32,32,128,32768],fail_settings=True)
        self.assertIn('[Socket Menu] Settings could not be saved.',data['log'])
        self.assertEqual(data['files']['menu.cfg'],b'state_slot = "7"\n')
        self.assertFalse(any(name.endswith('.tmp') for name in data['files']))

    def test_missing_font_uses_builtin_fallback(self):
        data=self.run_case([32768],extra='video_font_path = "/missing/socket-font.otf"\n')
        self.assertGreater(data['render']['text_pixels'],20)
        self.assertEqual(data['render']['border'],[255,255,255])

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
