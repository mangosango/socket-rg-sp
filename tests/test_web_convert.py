"""Worker filesystem and resource bounds, without a real APK or browser."""
import io
from pathlib import Path
import stat
import struct
import zlib
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'web'))
import convert


def fixture(extra=()):
    data = io.BytesIO()
    with zipfile.ZipFile(data, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, body in [(convert.CONFIG, b'project'), (convert.LIBRARY, b'library'), *extra]:
            archive.writestr(name, body)
    return data


class WorkerReaderTest(unittest.TestCase):
    def test_pipeline_adds_pack_without_repacking_runtime(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            apk, out = root / 'input.apk', root / 'socket.pck'
            apk.write_bytes(fixture([('assets/dexopt/skip', b'x'), ('assets/_cl_', b'x'),
                                     ('unrelated', b'x'), ('assets/path/script', b'script')]).getvalue())
            stages = []

            def start(lib, cfg):
                self.assertEqual((lib, cfg), (b'library', b'project'))

            def build(res, overlay, pack, decompress):
                self.assertEqual(sorted(p.relative_to(res).as_posix() for p in res.rglob('*') if p.is_file()),
                                 ['path/script', 'project.binary'])
                self.assertEqual(overlay, root)
                self.assertIs(decompress, convert.decompress)
                pack.write_bytes((res / 'path/script').read_bytes())

            convert.convert(apk, out, root, start, bytearray.upper, build,
                            lambda path: self.assertEqual(path.read_bytes(), b'PROJECT'), lambda *event: stages.append(event))
            self.assertEqual(stages, [('Checking APK', 0), ('Opening Socket resources', 20),
                                      ('Converting assets', 40), ('Converting assets', 60),
                                      ('Patching and packing Socket', 60)])
            runtime = io.BytesIO()
            launcher = zipfile.ZipInfo('System/launch_frontend.sh')
            launcher.external_attr = (stat.S_IFREG | 0o755) << 16
            launcher.compress_type = zipfile.ZIP_DEFLATED
            with zipfile.ZipFile(runtime, 'w') as base:
                base.writestr(launcher, b'launcher')
                base.writestr('Games/GB/', b'')
            parts = []
            convert.write_card(runtime, out, lambda n: parts.append(runtime.getvalue()[:n]), parts.append)
            with zipfile.ZipFile(io.BytesIO(b''.join(parts))) as result:
                self.assertEqual(result.namelist(), [launcher.filename, 'Games/GB/', convert.PCK_PATH])
                self.assertEqual(result.read(launcher.filename), b'launcher')
                self.assertEqual(result.getinfo(launcher.filename).external_attr, launcher.external_attr)
                self.assertEqual(result.getinfo(launcher.filename).compress_type, zipfile.ZIP_DEFLATED)
                self.assertEqual(result.read(convert.PCK_PATH), b'SCRIPT')
                self.assertEqual(result.getinfo(convert.PCK_PATH).external_attr >> 16, stat.S_IFREG | 0o644)
            parts.clear()
            options = dict(ssid='my network', psk='sample=key', username='player', password='example')
            convert.write_card(runtime, out, lambda n: parts.append(runtime.getvalue()[:n]), parts.append, options)
            with zipfile.ZipFile(io.BytesIO(b''.join(parts))) as result:
                self.assertEqual(result.read('Config/wifi.txt'), b'ssid = my network\npsk = sample=key\n')
                self.assertEqual(result.read('Config/retroachievements.txt'), b'username = player\npassword = example\n')
            with self.assertRaises(convert.ConversionError):
                convert.write_card(runtime, out, None, None, dict(ssid='a\nb', psk='password'))

    def test_unsupported_version_stops_before_other_resources(self):
        with tempfile.TemporaryDirectory() as folder:
            apk, out = Path(folder) / 'in', Path(folder) / 'out'
            apk.write_bytes(fixture([('assets/unused', b'should not be decrypted')]).getvalue())
            seen = []

            def decrypt(data):
                seen.append(bytes(data))
                return data

            def unsupported(project):
                raise ValueError('private version from input')

            with self.assertRaisesRegex(convert.ConversionError, '^Unsupported Socket release'):
                convert.convert(apk, out, None, lambda *_: None, decrypt, self.fail, unsupported, lambda *_: None)
            self.assertEqual(seen, [b'project'])
            self.assertFalse(out.exists())

    def test_unsafe_paths_and_symlinks_even_outside_assets(self):
        link = zipfile.ZipInfo('assets/link')
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        for name in ['assets/../outside', '/outside', 'x\\y', './x', 'x//y', 'C:/x', link, 'assets/project.binary/']:
            with self.subTest(name=name), zipfile.ZipFile(fixture([(name, b'x')])) as archive:
                with self.assertRaisesRegex(convert.ConversionError, 'unsafe or duplicate'):
                    convert.select_entries(archive)

    def test_budget_and_required_entries(self):
        for limit in ['MAX_LIBRARY', 'MAX_ASSET', 'MAX_ASSETS', 'MAX_ENTRIES']:
            with self.subTest(limit=limit), patch.object(convert, limit, 1), zipfile.ZipFile(fixture()) as archive:
                with self.assertRaises(convert.ConversionError):
                    convert.select_entries(archive)
        with zipfile.ZipFile(io.BytesIO(), 'w') as archive:
            with self.assertRaisesRegex(convert.ConversionError, 'Missing'):
                convert.select_entries(archive)
        with patch.object(convert, 'MAX_APK', 1), self.assertRaisesRegex(convert.ConversionError, '256 MiB'):
            convert.check_directory(fixture())
        with self.assertRaisesRegex(convert.ConversionError, 'Invalid'):
            convert.check_directory(io.BytesIO(b'invalid'))

    def test_corrupted_selected_entry_never_creates_output(self):
        with tempfile.TemporaryDirectory() as folder:
            apk, out = Path(folder) / 'in', Path(folder) / 'out'
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.writestr(convert.CONFIG, b'original')
                archive.writestr(convert.LIBRARY, b'lib')
            apk.write_bytes(apk.read_bytes().replace(b'original', b'modified'))
            with self.assertRaises(convert.ConversionError):
                convert.convert(apk, out, None, self.fail, self.fail, self.fail, self.fail, lambda *_: None)
            self.assertFalse(out.exists())

    def test_rejects_forged_sizes_prefix_crc_and_trailing_compressed_data(self):
        plain = b'A' * 600000
        for method in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            original = io.BytesIO()
            with zipfile.ZipFile(original, 'w', compression=method) as archive:
                archive.writestr('test', plain)
            for attack in ('prefix', 'local-only', 'wrong-method', 'trailing'):
                with self.subTest(method=method, attack=attack):
                    raw = bytearray(original.getvalue())
                    central = raw.index(b'PK\x01\x02')
                    if attack == 'trailing':
                        raw[central:central] = b'x'
                        central += 1
                        length = struct.unpack_from('<I', raw, 18)[0] + 1
                        struct.pack_into('<I', raw, 18, length)
                        struct.pack_into('<I', raw, central + 20, length)
                        struct.pack_into('<I', raw, len(raw) - 6, central)
                    elif attack == 'wrong-method':
                        struct.pack_into('<H', raw, 8, 99)
                    else:
                        struct.pack_into('<I', raw, 22, 17)
                        if attack == 'prefix':
                            crc = zlib.crc32(plain[:17])
                            struct.pack_into('<I', raw, 14, crc)
                            struct.pack_into('<I', raw, central + 16, crc)
                            struct.pack_into('<I', raw, central + 24, 17)
                    with zipfile.ZipFile(io.BytesIO(raw)) as archive, self.assertRaises(convert.ConversionError):
                        convert.read_entry(archive, archive.getinfo('test'))

    def test_streamed_zip_data_descriptor(self):
        class Sink(io.BytesIO):
            def seek(self, *args):
                raise OSError('stream')
        stream = Sink()
        data = b'A' * 700000
        with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('data', data)
        raw = stream.getvalue()
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            self.assertEqual(convert.read_entry(archive, archive.getinfo('data')), data)
        tampered = bytearray(raw)
        tampered[tampered.index(b'PK\x07\x08') + 4] ^= 128
        with zipfile.ZipFile(io.BytesIO(tampered)) as archive, self.assertRaises(convert.ConversionError):
            convert.read_entry(archive, archive.getinfo('data'))

    def test_bounded_zstd(self):
        try:
            from compression import zstd
        except ImportError:
            self.skipTest('requires the worker Python 3.14 stdlib')
        data = zstd.compress(b'x' * 8192)
        self.assertEqual(convert.decompress(data, 8192), b'x' * 8192)
        for frame, size in [(data, 2), (data, 8193), (data, convert.MAX_ASSET + 1),
                            (data[:-1], 8192), (data + data, 8192)]:
            with self.subTest(size=size), self.assertRaises((ValueError, zstd.ZstdError)):
                convert.decompress(frame, size)


if __name__ == '__main__':
    unittest.main()
