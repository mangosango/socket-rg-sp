"""Fast, offline checks of the card publication boundary (no ROMs, Docker or cached builds)."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('card_runtime', ROOT / 'tools/build-card-runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


def fixture_elf(name):
    # An ELF envelope with the expected identity strings, not an executable or a ROM.
    payload = b' '.join(runtime.MARKERS[name])
    return struct.pack('<16sHHIQQQIHHHHHH', b'\x7fELF\x02\x01\x01', 3, 183, 1, 0, 64,
                       64 + 56 + len(payload), 0, 64, 56, 1, 64, 1, 0) + bytes(56) + payload + bytes(64)


class CardRuntimeTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name).resolve()
        self.path = self.tmp / 'arbitrary.zip'
        # Keep the real member allowlist; substitute tiny public upstream notices and sources.
        for field, mapping in [('NOTICE_HASH', runtime.LICENSES), ('SOURCE_HASH', runtime.PINS)]:
            self.enter_patch(field, {n: runtime.sha(n.encode()) for n in mapping})
        self.enter_patch('CA_HASH', runtime.sha(b'CA notice'))
        self.enter_patch('CREDITS_HASH', runtime.sha(b'credits'))
        self.files = runtime.runtime_local() | {runtime.SYS + n: fixture_elf(n) for n in runtime.BIN}
        self.files.update({runtime.SYS + 'licenses/' + n: n.encode() for n in runtime.LICENSES})
        self.files[runtime.SYS + 'licenses/' + runtime.CA] = b'CA notice'
        self.files[runtime.SYS + 'licenses/RetroArch-dependencies.txt'] = b'credits'

    def enter_patch(self, name, value):
        mock = patch.object(runtime, name, value)
        mock.start()
        self.addCleanup(mock.stop)

    def test_positive_and_reproducible(self):
        self.assertIn('System/socket/cores/mgba_libretro.so', self.files)
        self.assertIn('System/socket/first-boot.sh', self.files)
        self.assertEqual({n for n in self.files if n.startswith('Config/')},
                         {'Config/wifi.txt.example', 'Config/retroachievements.txt.example'})
        runtime.pack(self.path, self.files)
        runtime.verify(self.path)
        first = self.path.read_bytes()
        runtime.pack(self.path, dict(reversed(list(self.files.items()))))
        self.assertEqual(first, self.path.read_bytes())
        with zipfile.ZipFile(self.path) as z:
            self.assertTrue(z.getinfo('Games/GBA/').is_dir())
            self.assertEqual(z.getinfo('System/launch_frontend.sh').external_attr >> 16, 0o100755)

    def test_unexpected_missing_or_substituted_runtime(self):
        for name, value in [('System/socket/socket.pck', b'x'), ('Config/wifi.txt', b'x'),
                            ('Games/GB/private.gb', b'x'), ('Saves/data', b'x'), ('../LICENSE', b'x'),
                            ('System/socket/godot', None), ('System/socket/godot', fixture_elf('godot') + b'pack'),
                            ('System/socket/retroarch/retroarch', fixture_elf('godot')),
                            ('System/socket/launch_game.sh', b'changed'), ('Config/wifi.txt.example', b'changed')]:
            with self.subTest(name=name):
                files = self.files.copy()
                if value is None:
                    del files[name]
                else:
                    files[name] = value
                runtime.pack(self.path, files)
                with self.assertRaises(ValueError):
                    runtime.verify(self.path)

    def test_source_byte_identity(self):
        sources = runtime.source_local() | {n + '.tar': n.encode() for n in runtime.PINS} | {runtime.CA: b'CA notice'}
        runtime.pack(self.path, sources)
        runtime.verify(self.path, source=True)
        sources['mgba.tar'] = b'unreviewed extra fixtures'
        runtime.pack(self.path, sources)
        with self.assertRaisesRegex(ValueError, 'mgba.tar'):
            runtime.verify(self.path, source=True)

    def test_local_input_refuses_symlinked_parent(self):
        (self.tmp / 'outside').mkdir()
        (self.tmp / 'outside/private').write_text('not input')
        (self.tmp / 'input').symlink_to(self.tmp / 'outside', target_is_directory=True)
        with self.assertRaises(ValueError):
            runtime.local(self.tmp, 'input/private')


if __name__ == '__main__':
    unittest.main()
