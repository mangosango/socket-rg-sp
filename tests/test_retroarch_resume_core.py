"""Save and restore dedicated sleep states with real mGBA and read-only ROMs."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CARD = Path(os.environ.get('RETROARCH_CORE_SMOKE_ROOT', '/Volumes/BASEOS'))

PROBE = r'''
import os, signal, subprocess, sys, time
from pathlib import Path
p=Path('/output')
rom,platform=sys.argv[1:]
env=dict(os.environ,SOCKET_RUN='/output',SOCKET_GAME_DESCRIPTOR='/output/game.descriptor',
    SOCKET_RESUME_MANIFEST='/output/resume-game')
(p/'game.descriptor').write_text('socket-resume-v1\nmgba\n'+rom+'\n'+platform+'\n')
args=['/project/work/RetroArch/retroarch','--verbose','--config','/output/test.cfg',
      '-L','/card/System/socket/cores/mgba_libretro.so',rom]
log=(p/'runtime.log').open('w')
process=subprocess.Popen(args,env=env,stdout=log,stderr=log)
def until(predicate):
    deadline=time.monotonic()+15
    while not predicate():
        if process.poll() is not None or time.monotonic()>deadline:
            raise RuntimeError('Core ended or protocol timed out')
        time.sleep(.01)
def stop():
    process.send_signal(signal.SIGTERM); process.wait(timeout=10)
    assert process.returncode==0
try:
    until(lambda: '[Video] Set video size' in (p/'runtime.log').read_text())
    time.sleep(.5)
    (p/'sleep.request').write_text('000123\n')
    until(lambda: (p/'sleep.ack').exists())
    assert (p/'sleep.ack').read_text()=='000123 ok\n'
    states=list((p/'states').glob('*.sleep'))
    assert len(states)==1,states
    saved=states[0].read_bytes(); assert len(saved)>100
    assert (p/'resume-game').read_bytes()==(p/'game.descriptor').read_bytes()
    stop(); (p/'sleep.request').unlink()
    env['SOCKET_RESUME_LOAD']='1'
    process=subprocess.Popen(args,env=env,stdout=log,stderr=log)
    until(lambda: (p/'resume.ack').exists())
    assert (p/'resume.ack').read_text()=='0 ok\n'
    assert not (p/'resume-game').exists()
    assert states[0].read_bytes()==saved
    time.sleep(.2); stop()
    for suffix,value in (('.auto',b'old automatic state'),('1',b'old numbered state')):
        assert (p/'states'/(Path(rom).stem+'.state'+suffix)).read_bytes()==value
finally:
    if process.poll() is None: process.kill(); process.wait()
    log.close()
'''


@unittest.skipUnless(os.environ.get('RETROARCH_CORE_SMOKE') == '1',
                     'Set RETROARCH_CORE_SMOKE=1 with Docker and read-only GB/GBC/GBA ROMs')
class ResumeCoreTests(unittest.TestCase):
    def test_real_core_sleep_save_and_cold_boot_load(self):
        self.assertTrue((CARD/'System/socket/cores/mgba_libretro.so').is_file())
        for platform in ('GB','GBC','GBA'):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory(prefix='ra-sleep-core-') as directory:
                roms=sorted(path for path in (CARD/'Games'/platform).glob('*.'+platform.lower())
                            if not path.name.startswith('._'))
                self.assertTrue(roms,platform)
                rom=roms[0]
                output=Path(directory)
                (output/'states').mkdir()
                (output/'saves').mkdir()
                for suffix,value in (('.auto',b'old automatic state'),('1',b'old numbered state')):
                    (output/'states'/(rom.stem+'.state'+suffix)).write_bytes(value)
                (output/'probe.py').write_text(PROBE)
                settings=dict(video_driver='null',audio_driver='null',input_driver='udev',
                    input_joypad_driver='udev',menu_driver='rgui',rgui_show_start_screen='false',
                    config_save_on_exit='false',savestate_auto_load='false',savestate_auto_save='false',
                    savestate_thumbnail_enable='false',savestate_file_compression='true',
                    savestate_directory='/output/states',savefile_directory='/output/saves',system_directory='/output',
                    sort_savestates_enable='false',sort_savestates_by_content_enable='false',
                    sort_savefiles_enable='false',sort_savefiles_by_content_enable='false')
                (output/'test.cfg').write_text(''.join(f'{key} = "{value}"\n' for key,value in settings.items()))
                result=subprocess.run(['docker','run','--rm','--platform','linux/arm64',
                    '-v',f'{ROOT}:/project:ro','-v',f'{CARD}:/card:ro','-v',f'{output}:/output',
                    'socket-baseos-godot','python3','/output/probe.py',
                    '/card/'+str(rom.relative_to(CARD)),platform.lower()],
                    capture_output=True,text=True,timeout=45)
                log=(output/'runtime.log').read_text() if (output/'runtime.log').exists() else ''
                self.assertEqual(result.returncode,0,result.stdout+result.stderr+log)
                self.assertIn('[Socket] Sleep state restored.',log)


if __name__=='__main__': unittest.main()
