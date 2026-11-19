"""Worker-local APK reader. Only trusted converter modules are on sys.path."""
import shutil
import stat
import struct
import zipfile
import zlib
from pathlib import Path
from tempfile import TemporaryDirectory

MIB = 1024 * 1024
MAX_APK = 256 * MIB
MAX_ENTRIES = 20_000
MAX_ASSET = 16 * MIB
MAX_ASSETS = 192 * MIB
MAX_LIBRARY = 128 * MIB
LIBRARY = 'lib/arm64-v8a/libgodot_android.so'
CONFIG = 'assets/project.binary'
SKIP = {'assets.sparsepck', '_cl_', 'dexopt'}


class ConversionError(ValueError):
    """Messages safe to show to the user (no input names or tool logs)."""


def check_directory(stream):
    # ZipFile loads its whole central directory before exposing infolist().
    stream.seek(0, 2)
    if stream.tell() > MAX_APK:
        raise ConversionError('APK exceeds the 256 MiB browser limit. Use the desktop converter.')
    end = zipfile._EndRecData(stream)
    if (not end or end[zipfile._ECD_SIZE] > 4 * MIB or
            end[zipfile._ECD_ENTRIES_TOTAL] > MAX_ENTRIES):
        raise ConversionError('Invalid or oversized APK directory. Choose an original Socket APK.')


def select_entries(archive):
    if len(archive.filelist) > MAX_ENTRIES:
        raise ConversionError('APK has too many entries. Use the desktop converter.')
    seen, assets, total = set(), [], 0
    has_library = False
    for entry in archive.infolist():
        name = entry.orig_filename
        path = name.removesuffix('/')
        parts = path.split('/')
        kind = stat.S_IFMT(entry.external_attr >> 16)
        if (path in seen or len(path) > 512 or len(parts) > 32 or
                any(c in name for c in ('\\', ':', '\0')) or not name.isprintable() or
                any(p in ('', '.', '..') for p in parts) or
                kind not in (0, stat.S_IFDIR if entry.is_dir() else stat.S_IFREG)):
            raise ConversionError('APK contains unsafe or duplicate paths. Choose an original Socket APK.')
        seen.add(path)
        if entry.is_dir():
            continue
        is_asset = len(parts) > 1 and parts[0] == 'assets' and parts[1] not in SKIP
        if not is_asset and name != LIBRARY:
            continue
        if name == LIBRARY:
            has_library = True
        limit = MAX_ASSET if is_asset else MAX_LIBRARY
        if (entry.flag_bits & 1 or entry.compress_type not in (zipfile.ZIP_DEFLATED, zipfile.ZIP_STORED)
                or entry.file_size > limit or entry.compress_size > limit + MIB):
            raise ConversionError('APK entry is unsupported or too large. Use the desktop converter.')
        if is_asset:
            assets.append(entry)
            total += entry.file_size
    if total > MAX_ASSETS:
        raise ConversionError('APK assets exceed the browser limit. Use the desktop converter.')
    if not has_library or not any(e.filename == CONFIG for e in assets):
        raise ConversionError('Missing Socket resources. Choose the original arm64 Socket APK.')
    return assets


def read_entry(archive, info):
    # ZipExtFile silently clips DEFLATE output to the central directory's claim.
    # Check the raw stream instead, including its actual end, size and checksum.
    def invalid():
        raise ConversionError('Corrupt APK entry. Choose an intact Socket APK.')

    src = archive.fp
    src.seek(info.header_offset)
    header = src.read(30)
    if len(header) != 30:
        invalid()
    sig, _, flags, method, _, _, crc, compressed, size, nlen, extra = struct.unpack('<4s5H3I2H', header)
    expected = (info.CRC, info.compress_size, info.file_size)
    local = (crc, compressed, size)
    descriptor = flags & 8
    if (sig != b'PK\x03\x04' or flags != info.flag_bits or flags & ~0x80e or method != info.compress_type
            or any(value != want and not (descriptor and value == 0) for value, want in zip(local, expected))
            or (method == zipfile.ZIP_STORED and info.compress_size != info.file_size)
            or src.read(nlen) != info.orig_filename.encode('utf-8' if flags & 0x800 else 'cp437')):
        invalid()
    src.seek(extra, 1)
    if src.tell() + info.compress_size + (12 if descriptor else 0) > info._end_offset:
        invalid()

    decoder = zlib.decompressobj(-15) if method == zipfile.ZIP_DEFLATED else None
    data = bytearray()
    remaining = info.compress_size
    chunk = 256 * 1024
    while remaining:
        block = src.read(min(chunk, remaining))
        if not block:
            invalid()
        remaining -= len(block)
        if decoder is None:
            data.extend(block)
        else:
            while block:
                data.extend(decoder.decompress(block, min(chunk, info.file_size - len(data) + 1)))
                if len(data) > info.file_size or decoder.unused_data:
                    invalid()
                block = decoder.unconsumed_tail
    if (decoder is not None and not decoder.eof) or len(data) != info.file_size or zlib.crc32(data) != info.CRC:
        invalid()
    if descriptor:
        record = src.read(12)
        if record[:4] == b'PK\x07\x08':
            record = record[4:] + src.read(4)
        if src.tell() > info._end_offset or record != struct.pack('<III', *expected):
            invalid()
    return data


def decompress(data, size):
    from compression import zstd
    if not 0 < size <= MAX_ASSET:
        raise ValueError('oversized compressed script')
    decoder = zstd.ZstdDecompressor(options={zstd.DecompressionParameter.window_log_max: 24})
    result = decoder.decompress(data, max_length=size + 1)
    if len(result) != size or not decoder.eof or decoder.unused_data:
        raise ValueError('invalid compressed script')
    return result


PCK_PATH = 'System/socket/socket.pck'


class CardTail:
    """Non-seekable ZIP output following the unchanged local records in a Blob."""
    def __init__(self, offset, append):
        self.offset, self.append = offset, append

    def tell(self):
        return self.offset

    def write(self, data):
        if data:
            self.append(data)
            self.offset += len(data)
        return len(data)

    def flush(self):
        pass


def write_card(runtime, pack, prefix, append, options=None):
    options = options or {}
    configs = {}
    for path, keys in [('Config/wifi.txt', ('ssid', 'psk')),
                       ('Config/retroachievements.txt', ('username', 'password'))]:
        if not any(key in options for key in keys):
            continue
        for key in keys:
            value = options.get(key, '')
            size = len(value.encode())
            limit = {'ssid': 32, 'psk': 64, 'username': 31, 'password': 255}[key]
            if (not 0 < size <= limit or value != value.strip()
                    or any(ord(c) < 32 or ord(c) == 127 for c in value)
                    or key == 'psk' and (size < 8 or size == 64 and
                        any(c not in '0123456789abcdefABCDEF' for c in value))):
                raise ConversionError('Invalid port options. Check the enabled fields.')
        configs[path] = ''.join(f'{key} = {options[key]}\n' for key in keys)

    with zipfile.ZipFile(runtime) as base:
        if PCK_PATH in base.namelist():
            raise ValueError('Card runtime already contains the pack')
        prefix(base.start_dir)
        with zipfile.ZipFile(CardTail(base.start_dir, append), 'w') as result:
            # The prefix retains the original local offsets. Reuse their directory
            # records (including Unix modes) without reading the compressed files.
            result.filelist.extend(base.infolist())
            for path, contents in configs.items():
                if path in base.namelist():
                    raise ValueError('Unexpected credential file in card runtime')
                result.writestr(path, contents)
            info = zipfile.ZipInfo(PCK_PATH)
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | 0o644) << 16
            with pack.open('rb') as src, result.open(info, 'w') as dest:
                shutil.copyfileobj(src, dest, MIB)


def convert(apk, out, overlay, start, decrypt, build_pack, validate_version, stage):
    with TemporaryDirectory() as folder:
        res = Path(folder) / 'res'
        stage('Checking APK', 0)
        with Path(apk).open('rb') as stream:
            check_directory(stream)
            with zipfile.ZipFile(stream) as archive:
                assets = select_entries(archive)
                stage('Opening Socket resources', 20)
                cfg = read_entry(archive, archive.getinfo(CONFIG))
                start(read_entry(archive, archive.getinfo(LIBRARY)), cfg)
                res.mkdir()
                project = res / 'project.binary'
                project.write_bytes(decrypt(cfg))
                del cfg
                try:
                    validate_version(project)
                except ValueError:
                    raise ConversionError('Unsupported Socket release. Check the supported versions.') from None
                assets = [info for info in assets if info.filename != CONFIG]
                total = sum(info.file_size for info in assets)
                processed, percent = 0, 40
                stage('Converting assets', percent)
                for info in assets:
                    dest = res / info.filename.removeprefix('assets/')
                    data = decrypt(read_entry(archive, info))
                    if len(data) > info.file_size:
                        raise ConversionError('Invalid Socket resource. Choose an intact APK.')
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    with dest.open('xb') as target:
                        target.write(data)
                    processed += info.file_size
                    next_percent = 40 + 20 * processed // max(1, total)
                    if next_percent > percent:
                        percent = next_percent
                        stage('Converting assets', percent)
                    del data
        stage('Patching and packing Socket', 60)
        build_pack(res, overlay, out, decompress=decompress)


def worker_convert():
    from js import startUnpack, decryptAsset, converterStage, cardPrefix, cardAppend, portOptions
    from pyodide.ffi import to_js
    from build_pack import build_pack, validate_version

    try:
        pack = Path('/tmp/socket.pck')
        convert('/input/input.apk', pack, Path('/converter/overlay'),
                lambda lib, cfg: startUnpack(to_js(lib), to_js(cfg)),
                lambda data: decryptAsset(to_js(data)).to_py(), build_pack, validate_version, converterStage)
        converterStage('Creating download', 80)
        write_card('/card/runtime.zip', pack, cardPrefix, lambda data: cardAppend(to_js(data)), portOptions.to_py())
    except ConversionError as error:
        return str(error)
    except SystemExit:
        return 'Unsupported Socket release or resource layout. Check the supported versions.'
    except Exception:
        return 'Conversion failed. Choose an intact, supported Socket APK or use the desktop converter.'
    return None
