"""Exercise the sleep protocol against the ARM64 RetroArch binary."""
import os
import unittest

import test_retroarch_quick_menu_runtime as menu_runtime


PROBE = r'''
import json, os, signal, subprocess, time
from pathlib import Path
p = Path('/output')
mode = (p/'mode').read_text()
env = dict(os.environ, SOCKET_RUN='/output', SOCKET_GAME_DESCRIPTOR='/output/game.descriptor',
    SOCKET_RESUME_MANIFEST='/output/resume-game', EGL_PLATFORM='surfaceless',
    LD_PRELOAD='/output/headless.so:/output/probe.so')
args = ['/project/work/RetroArch/retroarch','--verbose','--config','/output/test.cfg',
        '-L','/output/core.so','/output/probe.bin','--max-frames','520']
log = (p/'runtime.log').open('w')
process = subprocess.Popen(args,env=env,stdout=log,stderr=log)
def until(predicate):
    deadline=time.monotonic()+15
    while not predicate():
        if process.poll() is not None or time.monotonic()>deadline:
            raise RuntimeError('Runtime ended or condition timed out: '+mode)
        time.sleep(.01)
def request(name,token):
    (p/'request.tmp').write_text(token+'\n')
    (p/'request.tmp').replace(p/(name+'.request'))
def ack(name,token,result='ok'):
    until(lambda: (p/(name+'.ack')).exists() and
        (p/(name+'.ack')).read_text()==token+' '+result+'\n')
def runs(): return int((p/'runs').read_text() or '0')
def stop():
    process.send_signal(signal.SIGTERM)
    process.wait(timeout=10)
try:
    until(lambda: (p/'runs').exists() and runs()>20)
    original_auto=(p/'states/probe.state.auto').read_bytes()
    original_slot=(p/'states/probe.state').read_bytes()
    if mode in ('quietoff','quietfail'):
        # The helper resumes a stopped game for a timed save. It must stay silent.
        def peaks(since):
            return [float(line.split()[1]) for line in (p/'audio.csv').read_text().splitlines()
                    if float(line.split()[0]) >= since]
        heard=time.monotonic(); time.sleep(.3)
        assert max(peaks(heard))>0, 'game audio is audible before sleep'
        # As the helper does: a sleep request first. Its save fails, so the game is not held.
        (p/'states/probe.state.sleep.pending.tmp').mkdir()
        asked=time.monotonic()
        request('sleep','01001'); ack('sleep','01001','error')
        acked=time.monotonic()
        process.send_signal(signal.SIGSTOP); stopped=time.monotonic(); time.sleep(.3)
        if mode=='quietoff': (p/'states/probe.state.sleep.pending.tmp').rmdir()
        request('poweroff','01003')
        resumed=time.monotonic()
        process.send_signal(signal.SIGCONT)
        if mode=='quietoff':
            ack('poweroff','01003')
            process.wait(timeout=10)
            assert (p/'resume-game').exists()
            assert all(peak==0 for peak in peaks(resumed)), (asked, acked, stopped, resumed,
                [line for line in (p/'audio.csv').read_text().splitlines() if float(line.split()[0]) >= asked - .05])
            print(json.dumps(dict(returncode=process.returncode, quiet_writes=len(peaks(resumed)))))
            raise SystemExit(0)
        ack('poweroff','01003','error')
        before=runs(); until(lambda: runs()>before+10)
        assert all(peak==0 for peak in peaks(resumed)), peaks(resumed)
        (p/'states/probe.state.sleep.pending.tmp').rmdir()
        request('wake','01002'); ack('wake','01002')
        woke=time.monotonic(); time.sleep(.3)
        assert max(peaks(woke))>0, 'wake restores game audio'
        stop()
        print(json.dumps(dict(returncode=process.returncode)))
        raise SystemExit(0)
    if mode in ('savefail','cancelwake','ackfail'):
        if mode=='ackfail': (p/'sleep.ack.tmp').mkdir()
        before=runs()
        request('sleep','01001')
        if mode!='ackfail': ack('sleep','01001','error')
        else: until(lambda: runs()>before+10 and (p/'states/probe.state.sleep').read_bytes()!=b'old sleep')
        before=runs()
        until(lambda: runs()>before+5)
        assert not (p/'resume-game').exists()
        if mode!='ackfail': assert (p/'states/probe.state.sleep').read_bytes()==b'old sleep'
        else: (p/'sleep.ack.tmp').rmdir()
        if mode=='cancelwake':
            request('wake','01002'); ack('wake','01002')
            before=runs(); until(lambda: runs()>before+5)
            assert not (p/'restored').exists()
        stop()
    else:
        if mode in ('timeout','retoken'):
            (p/'delay').touch()
            request('sleep','01001')
            until(lambda: (p/'serializing').exists())
            if mode=='timeout': (p/'sleep.request').unlink()
            else: request('sleep','01004')
        else: request('sleep','01001')
        if mode=='timeout':
            request('wake','01002'); ack('wake','01002')
            before=runs(); until(lambda: runs()>before+5)
            assert not (p/'restored').exists()
            assert not (p/'resume-game').exists()
            stop()
            print(json.dumps(dict(returncode=process.returncode)))
            raise SystemExit(0)
        ack('sleep','01004' if mode=='retoken' else '01001')
        (p/'sleep.request').unlink()
        saved=(p/'states/probe.state.sleep').read_bytes()
        assert saved and saved!=b'old sleep'
        assert (p/'resume-game').read_bytes()==(p/'game.descriptor').read_bytes()
        before=runs(); time.sleep(.15); assert runs()==before
        request('sleep','01005'); ack('sleep','01005','error')
        (p/'sleep.request').unlink()
        assert runs()==before
        assert (p/'resume-game').exists()
        if mode in ('boot','bootfail','corruptboot'):
            stop()
            (p/'runs').unlink()
            if mode=='bootfail': (p/'reject-load').touch()
            if mode=='corruptboot': (p/'states/probe.state.sleep').write_bytes(b'corrupt')
            env['SOCKET_RESUME_LOAD']='1'
            process=subprocess.Popen(args,env=env,stdout=log,stderr=log)
            ack('resume','0','error' if mode in ('bootfail','corruptboot') else 'ok')
        elif mode=='off':
            request('poweroff','01003'); ack('poweroff','01003')
            process.wait(timeout=10)
            assert (p/'resume-game').exists()
        else:
            if mode=='offfail':
                (p/'states/probe.state.sleep.pending.tmp').mkdir()
                request('poweroff','01003'); ack('poweroff','01003','error')
                assert (p/'resume-game').exists()
                assert runs()==before
                (p/'states/probe.state.sleep.pending.tmp').rmdir()
            if mode=='wakefail': (p/'states/probe.state.sleep').write_bytes(b'corrupt')
            request('wake','01002'); ack('wake','01002')
        if mode in ('bootfail','corruptboot'):
            assert not (p/'resume-game').exists()
            until(lambda: 'Resume failed. Game is paused.' in (p/'runtime.log').read_text())
            # The core cannot run while the failure menu is visible.
            before=(p/'runs').read_text() if (p/'runs').exists() else None
            time.sleep(1.2)
            assert ((p/'runs').read_text() if (p/'runs').exists() else None)==before
            assert (p/'states/probe.state.sleep').read_bytes()==(b'corrupt' if mode=='corruptboot' else saved)
            assert (p/'saves/probe.srm').read_bytes()==b'good sram'
            request('wake','01006'); ack('wake','01006','error')
            time.sleep(.1)
            assert not (p/'runs').exists()
            stop()
        elif mode!='off':
            assert not (p/'resume-game').exists()
            if mode=='boot':
                assert (p/'restored').exists()
                restored=int((p/'restored').read_text())
                assert restored==before, (restored,before)
            else:
                assert not (p/'restored').exists()
            until(lambda: runs()>before+5)
            assert (p/'states/probe.state.sleep').read_bytes()==(b'corrupt' if mode=='wakefail' else saved)
            stop()
    assert (p/'states/probe.state.auto').read_bytes()==original_auto
    assert (p/'states/probe.state').read_bytes()==original_slot
    assert (p/'saves/probe.srm').read_bytes()==b'good sram'
    assert not list(p.rglob('*.pending'))
    print(json.dumps(dict(returncode=process.returncode)))
finally:
    if process.poll() is None: process.kill(); process.wait()
    log.close()
'''


@unittest.skipUnless(os.environ.get('RETROARCH_QUICK_MENU_SMOKE') == '1',
                     'Set RETROARCH_QUICK_MENU_SMOKE=1 for ARM64 runtime tests')
class ResumeRuntimeTests(unittest.TestCase):
    run_case = menu_runtime.QuickMenuRuntimeTests.run_case

    def check_mode(self, mode, fail=False):
        def prepare(output):
            (output/'saves').mkdir()
            (output/'saves/probe.srm').write_bytes(b'good sram')
            config=output/'test.cfg'
            config.write_text(config.read_text()+'savefile_directory = "/output/saves"\nautosave_interval = "1"\nsort_savefiles_enable = "false"\nsort_savefiles_by_content_enable = "false"\n')
            (output/'game.descriptor').write_text('socket-resume-v1\nprobe\n/output/probe.bin\ngba\n')
            (output/'states/probe.state.auto').write_bytes(b'previous auto')
            (output/'states/probe.state').write_bytes(b'previous slot')
            (output/'states/probe.state.sleep').write_bytes(b'old sleep')
            if mode=='off':
                config=output/'test.cfg'
                config.write_text(config.read_text().replace('savestate_auto_save = "false"',
                                                           'savestate_auto_save = "true"'))
            core=output/'core.c'
            source=core.read_text().replace('static unsigned runs;', 'static unsigned runs; static char sram[9];').replace(
                '(void)id; return 0;', 'return id==RETRO_MEMORY_SAVE_RAM ? sram : NULL;', 1).replace(
                '(void)id; return 0;', 'return id==RETRO_MEMORY_SAVE_RAM ? sizeof(sram) : 0;', 1).replace('if(n!=64) return false; memset(p,0,n);',
                'if(n!=64) return false; if(access("/output/delay",F_OK)==0) {'
                'FILE *f=fopen("/output/serializing","w"); fclose(f); usleep(400000); } memset(p,0,n);')
            core.write_text(source.replace(
                'memcpy(&runs,p,sizeof(runs)); return true;',
                'if(access("/output/reject-load",F_OK)==0) { memcpy(sram,"bad! sram",9); return false; } '
                'memcpy(&runs,p,sizeof(runs)); FILE *f=fopen("/output/restored","w"); '
                'fprintf(f,"%u",runs); fclose(f); return true;'))
        data=self.run_case(mode=mode,fail=fail,probe_script=PROBE,prepare=prepare)
        if mode in ('wake','boot'):
            self.assertIn('[Socket] Sleep state restored.' if mode=='boot' else '[Socket] Sleep state resumed.',data['log'])
            # Success does not show a toast. Failure messages use socket_menu_message.
            self.assertNotIn('[Socket Menu] Sleep state',data['log'])
        return data

    def test_sleep_wake_continues_frozen_state(self): self.check_mode('wake')
    def test_cold_boot_restores_dedicated_state(self): self.check_mode('boot')
    def test_poweroff_saves_dedicated_state(self): self.check_mode('off')
    def test_save_failure_keeps_game_running_and_old_state(self): self.check_mode('savefail',True)
    def test_cancel_wake_after_failed_save_does_not_load_old_state(self): self.check_mode('cancelwake',True)
    def test_timeout_does_not_hold_or_restore_old_state(self): self.check_mode('timeout')
    def test_changed_token_during_save_is_not_acked_with_old_result(self): self.check_mode('retoken')
    def test_wake_does_not_read_corrupt_state_file(self): self.check_mode('wakefail')
    def test_sleep_ack_failure_releases_core_and_clears_manifest(self): self.check_mode('ackfail')
    def test_failed_poweroff_while_held_can_wake(self): self.check_mode('offfail')
    def test_timed_poweroff_of_stopped_game_is_silent(self): self.check_mode('quietoff')
    def test_failed_timed_poweroff_stays_silent_until_wake(self): self.check_mode('quietfail')
    def test_corrupt_boot_stays_paused(self): self.check_mode('corruptboot')
    def test_failed_boot_stays_paused_and_preserves_sram(self): self.check_mode('bootfail')


if __name__=='__main__': unittest.main()
