"""Test the Cheats page in ARM64 RetroArch: a core gets the cheats that the menu turns on."""
import os
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import test_retroarch_quick_menu_runtime as menu  # noqa: E402

# The ROM is probe.bin. Only the platform gives the Game Boy Advance folder.
PROBE = menu.PROBE.replace("SOCKET_RUN='/output',", "SOCKET_RUN='/output', SOCKET_GAME_PLATFORM='gba',", 1)
CONFIG = 'cheat_database_path = "/output/cheats"\napply_cheats_after_load = "true"'
SYSTEM = 'cheats/Nintendo - Game Boy Advance'
ACTIVE = 'cheats/Socket controls probe/probe.cht'
GOOD = ('cheats = 2\n\ncheat0_desc = "Infinite Lives"\ncheat0_code = "AAAA1111+BBBB2222"\ncheat0_enable = false\n\n'
        'cheat1_desc = "Max Money"\ncheat1_code = "CCCC3333"\ncheat1_enable = true\n')
DOWN, UP, OK, BACK, MENU = 32, 16, 256, 1, 32768


def record_cheats(output):
    """Make the test core write each cheat call to a file."""
    core = (output/'core.c').read_text()
    for old, new in (
            ('void retro_cheat_reset(void) {}',
             'void retro_cheat_reset(void) { FILE *f = fopen("/output/core-cheats.log", "a"); fputs("reset\\n", f); fclose(f); }'),
            ('void retro_cheat_set(unsigned i, bool b, const char *c) { (void)i; (void)b; (void)c; }',
             'void retro_cheat_set(unsigned i, bool b, const char *c) { FILE *f = fopen("/output/core-cheats.log", "a");'
             ' fprintf(f, "set %u %d %s\\n", i, b, c); fclose(f); }')):
        assert old in core
        core = core.replace(old, new)
    (output/'core.c').write_text(core)


@unittest.skipUnless(os.environ.get('RETROARCH_QUICK_MENU_SMOKE') == '1',
                     'Set RETROARCH_QUICK_MENU_SMOKE=1 for ARM64 runtime tests')
class CheatsRuntimeTests(unittest.TestCase):
    def run_case(self, sequence, prepare, probe=PROBE):
        def setup(output):
            record_cheats(output)
            prepare(output)
        return menu.QuickMenuRuntimeTests.run_case(self, sequence, extra=CONFIG, probe_script=probe, prepare=setup)

    def test_menu_loads_a_file_and_the_core_gets_each_enabled_cheat(self):
        def prepare(output):
            folder = output/SYSTEM
            folder.mkdir(parents=True)
            (folder/'Probe (USA) (GameShark).cht').write_text(GOOD)
            # RetroArch would allocate memory for this count.
            (folder/'Probe (Europe) (Bad).cht').write_text('cheats = 4000000000\ncheat0_code = "FFFF"\n')
            (folder/'Aaa Other Game (USA).cht').write_text(GOOD)
        # Cheats, Cheat files, the bad file, the good file, cheat 0 on,
        # cheat 1 on and off, Apply cheats again, back, close.
        data = self.run_case([DOWN, OK, OK, OK, DOWN, OK, OK, DOWN, OK, OK, UP, UP, OK, BACK, MENU], prepare)
        self.assertIn('[Socket Menu] This cheat file is not complete or not correct.', data['log'])
        self.assertIn('[Socket Menu] Loaded 2 cheats. All are off.', data['log'])
        self.assertIn('[Socket Menu] Cheats applied.', data['log'])
        self.assertEqual(data['files']['core-cheats.log'].decode().split('\n'), [
            'reset',                                                              # Launch. No cheats.
            'reset',                                                              # Loaded. The file had cheat 1 on.
            'reset', 'set 0 1 AAAA1111+BBBB2222',                                 # Cheat 0 on.
            'reset', 'set 0 1 AAAA1111+BBBB2222', 'set 1 1 CCCC3333',             # Cheat 1 on.
            'reset', 'set 0 1 AAAA1111+BBBB2222',                                 # Cheat 1 off.
            'reset', 'set 0 1 AAAA1111+BBBB2222',                                 # Apply cheats again.
            ''])
        active = data['files'][ACTIVE].decode()
        self.assertIn('cheat0_enable = "true"', active)
        self.assertIn('cheat1_enable = "false"', active)
        self.assertIn('cheat1_code = "CCCC3333"', active)
        self.assertEqual(data['files'][SYSTEM+'/Probe (USA) (GameShark).cht'].decode(), GOOD)
        self.assertFalse(any(name.endswith('.tmp') for name in data['files']))
        self.assertGreater(int(data['files']['runs']), data['render']['after'])

    def test_saved_cheats_apply_at_launch_and_download_needs_wifi(self):
        def prepare(output):
            folder = output/ACTIVE
            folder.parent.mkdir(parents=True)
            folder.write_text(GOOD.replace('cheat0_enable = false', 'cheat0_enable = true')
                              .replace('cheat1_enable = true', 'cheat1_enable = false'))
        # Cheats, then the two download rows without wifi.ready, then cheat 0 off.
        data = self.run_case([DOWN, OK, DOWN, OK, DOWN, OK, DOWN, DOWN, OK, BACK, MENU], prepare)
        self.assertEqual(data['log'].count('[Socket Menu] Offline. Saved cheats still work.'), 2)
        self.assertEqual(data['files']['core-cheats.log'].decode().split('\n'),
                         ['reset', 'set 0 1 AAAA1111+BBBB2222', 'reset', ''])
        self.assertIn('cheat0_enable = "false"', data['files'][ACTIVE].decode())
        self.assertNotIn(SYSTEM, ' '.join(data['files']))

    def test_a_second_press_is_necessary_to_replace_the_cheats_in_use(self):
        saved = GOOD.replace('cheat0_enable = false', 'cheat0_enable = true').replace('cheat1_enable = true', 'cheat1_enable = false')
        def prepare(output):
            (output/ACTIVE).parent.mkdir(parents=True)
            (output/ACTIVE).write_text(saved)
            (output/SYSTEM).mkdir(parents=True)
            (output/SYSTEM/'Probe (Europe).cht').write_text(GOOD)
            (output/SYSTEM/'Probe (USA).cht').write_text('cheats = 1\ncheat0_desc = "Other"\ncheat0_code = "DDDD4444"\n')
        # Cheats, Cheat files, one press on a file, then B. The cheats stay.
        data = self.run_case([DOWN, OK, OK, OK, BACK, BACK, MENU], prepare)
        self.assertEqual(data['log'].count('[Socket Menu] This file replaces the cheats in use for this game.'), 1)
        self.assertNotIn('[Socket Menu] Loaded', data['log'])
        # RetroArch writes the cheats in use again at exit, in its format.
        active = data['files'][ACTIVE].decode()
        self.assertIn('cheats = "2"', active)
        self.assertIn('cheat0_code = "AAAA1111+BBBB2222"', active)
        self.assertIn('cheat0_enable = "true"', active)
        self.assertEqual(data['files']['core-cheats.log'].decode().split('\n'), ['reset', 'set 0 1 AAAA1111+BBBB2222', ''])
        # A move to a different row cancels the question. Two presses on one row load the file.
        data = self.run_case([DOWN, OK, OK, OK, DOWN, OK, OK, BACK, MENU], prepare)
        self.assertEqual(data['log'].count('[Socket Menu] This file replaces the cheats in use for this game.'), 2)
        self.assertIn('[Socket Menu] Loaded 1 cheats. All are off.', data['log'])
        self.assertIn('cheat0_code = "DDDD4444"', data['files'][ACTIVE].decode())
        self.assertEqual(data['files']['core-cheats.log'].decode().split('\n'), ['reset', 'set 0 1 AAAA1111+BBBB2222', 'reset', ''])

    def test_other_platform_shows_only_its_folder_and_has_no_download(self):
        def prepare(output):
            (output/'cheats/nes').mkdir(parents=True)
            (output/'cheats/nes/My game.cht').write_text('cheats = 1\ncheat0_desc = "Lives"\ncheat0_code = "SXIOPO"\n')
            # The cheats in use for other games, and files of a different system.
            for folder in ('cheats/Other Core', SYSTEM, 'cheats'):
                (output/folder).mkdir(parents=True, exist_ok=True)
                (output/folder/'Aaa.cht').write_text(GOOD)
        # Cheats, Cheat files, the only file, then the cheat. It is row 2: there are no download rows.
        data = self.run_case([DOWN, OK, OK, OK, OK, BACK, MENU], prepare,
                             PROBE.replace("SOCKET_GAME_PLATFORM='gba'", "SOCKET_GAME_PLATFORM='nes'"))
        self.assertIn('[Socket Menu] Loaded 1 cheats. All are off.', data['log'])
        self.assertNotIn('Offline', data['log'])
        self.assertEqual(data['files']['core-cheats.log'].decode().split('\n'), ['reset', 'reset', 'reset', 'set 0 1 SXIOPO', ''])

    @unittest.skipUnless(os.environ.get('SOCKET_CHEATS_NETWORK') == '1',
                         'Set SOCKET_CHEATS_NETWORK=1 to download from github.com/libretro/libretro-database')
    def test_download_adds_missing_files_and_keeps_a_file_that_the_user_changed(self):
        title = '007 - The World Is Not Enough (USA, Europe)'
        folder = 'cheats/Nintendo - Game Boy Color'
        def prepare(output):
            (output/(title+'.bin')).write_bytes(bytes(16))
            (output/'wifi.ready').touch()
            (output/folder).mkdir(parents=True)
            (output/folder/(title+' (GameShark).cht')).write_text(GOOD)
        probe = PROBE.replace("SOCKET_GAME_PLATFORM='gba'", "SOCKET_GAME_PLATFORM='gbc'")
        probe = probe.replace("'/output/probe.bin', '--max-frames', '520'", f"'/output/{title}.bin', '--max-frames', '900'")
        self.assertNotEqual(probe.count(title), 0)
        slow = menu.presses
        # Cheats, Download cheats for this game, then time for the transfers.
        with mock.patch.object(menu, 'presses', lambda sequence, start=120, step=10: slow(sequence, start, 10 if start == 10 else 120)):
            data = self.run_case([DOWN, OK, DOWN, OK, MENU], prepare, probe)
        self.assertIn('[Socket Menu] Cheat files: 2 new, 1 on the card and not changed, 0 failed.', data['log'])
        self.assertEqual(data['files'][f'{folder}/{title} (GameShark).cht'].decode(), GOOD)
        for name in (f'{title} (Game Genie).cht', f'{title}.cht'):
            self.assertIn(b'cheat0_code', data['files'][f'{folder}/{name}'])
        # A download does not load a file or turn on a cheat.
        self.assertEqual(data['files']['core-cheats.log'].decode().split('\n'), ['reset', ''])
        self.assertFalse(any(name.endswith('.tmp') for name in data['files']))


if __name__ == '__main__':
    unittest.main()
