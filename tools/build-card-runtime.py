#!/usr/bin/env python3
"""Build an RG SP runtime ZIP and sibling -source.zip. No mounted card or APK needed.

python3 tools/build-card-runtime.py work/web-card-runtime.zip
python3 tools/build-card-runtime.py --cached work/web-card-runtime.zip  # known local build only
python3 tools/build-card-runtime.py --verify work/web-card-runtime.zip
python3 tools/build-card-runtime.py --verify-source work/web-card-runtime-source.zip

Requires Python 3.10+, git, patch and Docker with linux/arm64 support (native preferred).
Verification uses the release checkout but does not need network, Docker or work/.
"""
import argparse
import hashlib
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'work'
SYS = 'System/socket/'
PINS = {
    'godot': ('godotengine/godot', 'a13da4feb8d8aefc283c3763d33a2f170a18d541'),
    'RetroArch': ('libretro/RetroArch', '69a4f0ea1e8aaf442ae4858f2e7f2b31a1776576'),
    'mgba': ('libretro/mgba', '7a12d6d4b9acb14c0ae62c9166b6a2f3d08007f6'),
}
# Only paths needed for these native targets. Never archive a working tree.
PATHS = {
    'godot': ':(top,glob)*.py SConstruct LICENSE.txt COPYRIGHT.txt AUTHORS.md DONORS.md core drivers main modules platform/SCsub platform/platform_builders.py platform/register_platform_apis.h :(glob)platform/*/*.py :(glob)platform/*/api/* :(glob)platform/*/export/export.cpp :(glob)platform/*/export/*.svg platform/linuxbsd scene servers thirdparty misc/utility misc/scripts editor doc/classes',
    'RetroArch': ':(top,glob)*.c :(top,glob)*.h Makefile Makefile.common version.all configure qb COPYING README.md ai audio bluetooth camera cheevos cores deps frontend gfx griffin input intl led libretro-common libretro-db location memory menu midi misc network record tasks ui',
    'mgba': 'CMakeLists.txt version.cmake LICENSE README.md CHANGES include src res/licenses tools/debian',
}
EXCLUDE = {
    'godot': 'modules/gdscript/tests modules/zip/tests',
    'RetroArch': 'deps/bearssl-0.6 deps/glslang/glslang/Test deps/game_ai_lib/games gfx/include/userland/host_applications libretro-common/test libretro-common/samples',
    'mgba': 'src/platform/3ds src/platform/psp2 src/platform/qt src/platform/wii src/platform/windows src/third-party/libpng/contrib src/third-party/zlib/contrib/puff',
}
CARD = ('Config/wifi.txt.example Config/retroachievements.txt.example System/launch_frontend.sh'.split()
        + [SYS + n for n in ('first-boot.sh bluetooth.sh launch_game.sh play_game.sh poweroff.sh poweroff_ready.sh resume_game.sh wifi-lease.sh wifi.sh cores/README.txt').split()]
        + [SYS + 'retroarch/' + n for n in ('core-options.cfg gb-core-options.cfg gb.cfg gba.cfg gbc.cfg retroarch.cfg shaders/COPYING shaders/NOTICE.txt shaders/grid.glslp shaders/lcd3x.glslp shaders/slot-lcd.glsl').split()])
GAMES = ['Games/' + s + '/' for s in ('GB', 'GBC', 'GBA')]
# The source download also carries every instruction, patch, header and helper in the build.
RECIPES = (['engine/' + s for s in ('Dockerfile GODOT-LICENSE.txt bluetooth-agent.c build-engine.sh godot-fbdev-msaa.patch godot-fbdev.patch godot-gles3-msaa-copy.patch godot-gles3-msaa-reuse.patch wifi-config.c').split()]
           + ['engine/fbdev/' + s for s in ('display_server_fbdev.cpp display_server_fbdev.h hardware.c hardware_input.h test_hardware.c test_hardware_input.c').split()]
           + ['tools/' + s for s in ('build-retroarch.sh retroarch-achievements.h retroarch-achievements.patch retroarch-ca.py retroarch-cheats-menu.h retroarch-control-icons.h retroarch-controls.h retroarch-controls.patch retroarch-device-menu.h retroarch-device-menu.patch retroarch-mali-rgb.patch retroarch-menu-hold.patch retroarch-menu-input.patch retroarch-menu-overlay.h retroarch-menu-overlay.patch retroarch-quick-menu.h retroarch-quick-menu.patch retroarch-sleep.patch').split()])
DRIVER = ['tools/build-card-runtime' + s for s in ('.py', '.Dockerfile', '-core.sh')]
BIN = {'godot': 'godot/bin/godot.linuxbsd.template_release.arm64', 'retroarch/retroarch': 'RetroArch/retroarch',
       'cores/mgba_libretro.so': 'card-runtime-core/mgba_libretro.so',
       **{n: n for n in ('socket-hardware', 'socket-wifi-config', 'socket-bluetooth-agent')}}
# Opt-in cache only: reject renamed, stale or local replacement binaries, not just wrong arch.
CACHED = dict(zip(BIN, '''d587078ed82a2ebe737e9beb67e92b7a66fa90e73b44eda19df4dc4b5eb1e170
cbcb82157884386084b2af3cdabd13427721fff6d28d488fd4f5fd429443676c
0454bdf8131da51b37fe996a885133312961ceec6b4f3fcc133bd2a6ed7a0d8c
078fd6531dc262862440d867b99107e223e3c758861623c6bbfbda8270e86ce6
51cc78e6faeac1d4d85dd692f4ffc670e74c4b5d4d73458902890911352600b5
4601c7a43412846939b324ba9253c9a18777f19018659379b2e66a89e68f06a6'''.split()))
LICENSES = {'godot-LICENSE.txt': ('godot', 'LICENSE.txt'), 'godot-COPYRIGHT.txt': ('godot', 'COPYRIGHT.txt'),
            'RetroArch-COPYING.txt': ('RetroArch', 'COPYING'), 'Apache-2.0.txt': ('RetroArch', 'deps/SPIRV-Cross/LICENSES/Apache-2.0.txt'),
            'mgba-LICENSE.txt': ('mgba', 'LICENSE'), 'mgba-copyright.txt': ('mgba', 'tools/debian/copyright'),
            'rcheevos-LICENSE.txt': ('RetroArch', 'deps/rcheevos/LICENSE')}
# Additional notices embedded in dependencies, alongside the full annotated sources.
CREDITS = {'deps/7zip/7z.h': b'\n#ifndef', 'deps/glslang/glslang/glslang/MachineIndependent/Versions.cpp': b'\n\n',
           'deps/ibxm/licence.txt': None, 'deps/libFLAC/COPYING.Xiph': None, 'deps/xxHash/LICENSE': None,
           'deps/zstd/LICENSE': None, 'deps/yxml/yxml.c': b'\n#include', 'deps/switchres/switchres.cpp': b'#include',
           'libretro-common/include/compat/zlib/zlib.h': b'\n#ifndef ZLIB_H'}


def credits(work):
    parts = []
    for path, end in CREDITS.items():
        text = upstream(work, 'RetroArch', path)
        parts.append(path.encode() + b'\n' + (text.partition(end)[0] if end else text).strip())
    return b'\n\n'.join(parts) + b'\n'


# Hashes of normalized, fixture-free upstream source, and notices copied from those revisions.
SOURCE_HASH = {'godot': '6308dbe47a6e15a4bcd1b4026936d250619748fea067c8c48a0af2050c535fca',
               'RetroArch': '817c0f1c1a912d4199b88db5b028669b8ab2c9932f04171c739fff767579854f',
               'mgba': '0651ff2a7d9f4973f46ca9eb8b361eff386f423072619324696e1376424bad19'}
NOTICE_HASH = dict(zip(LICENSES, '''b0435e3b3e4e55238f05f4b306f30524a1b2e20147810d436eaa554fa6855c80
cb1980c88089573bcacd7221d777c689bb8bbd778799f24c27fca0fe5f774d6d
8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903
44b0a56e80b41a1b0a6bd1292515e806539fd97b30be54c2719e6c763190ab57
fab3dd6bdab226f1c08630b1dd917e11fcb4ec5e1e020e2c16f83a0a13863e85
8d7d5231c3a39495f8bf543629915664f3127d48b52f7e68502c22e01f4f5819
bf820c034966a3b6be050bb85f94ec841a0b972bd5d477e362337d0574b5c219'''.split()))
RECIPE_HASH = '3133b1cdf5b00dd40635f91499becdc7f4c1efe6634eac05861408aadbd402ba'
CA_HASH = 'e85e1bcad3a915dc7e6f41412bc5bdeba275cadd817896ea0451f2140a93967c'
CREDITS_HASH = '8dbfa6015735559aa5b803a8a58eb67706ce395e084d1f032993718bc160ecd3'
CA = 'debian-ca-certificates-copyright.txt'
IMAGE = 'socket-card-runtime-build'
README = ('''Socket frontend runtime for BaseOS on RG SP (not a bootable OS).
Supply your own Socket pack and games. mGBA handles GB, GBC and GBA without an external BIOS.
No ROMs, BIOS dump, personal configuration, Socket assets or credentials are supplied.
BaseOS supplies its Mali EGL/GLES stack, glibc loader, ALSA, udev, D-Bus and system utilities.
Do not replace those libraries with desktop Mesa or a different libc.

Get the separate corresponding-source ZIP from the same installer page (card-runtime-source.zip).
It contains source tar files, local modifications, build recipes, scripts and licenses.
From the project checkout with Python 3.10+, git, patch, Docker for linux/arm64 and internet:
    python3 tools/build-card-runtime.py work/web-card-runtime.zip
The build fetches exact revisions, uses the Bullseye arm64 toolchain and needs no private inputs.
The tar files are pristine source for these Linux targets; the engine/ and tools/ recipes apply
our patches and copy the supplied fbdev sources and socket_* headers before compilation.
See the licenses directory, shader NOTICE/COPYING and upstream notices in the source trees.
''' + ''.join(f'{n}: https://github.com/{r}/tree/{c}\n' for n, (r, c) in PINS.items())).encode()


def check(ok, message):
    if not ok:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def local(root, name):
    p = root / name
    check(p.resolve(strict=True) == p and p.is_file(), f'Not an ordinary file: {p}')
    return p


def run(*args, **kw):
    return subprocess.run(args, check=True, **kw)


def capture(*args):
    return subprocess.check_output(args)


def upstream(work, name, path):
    return capture('git', '-C', work / name, 'show', PINS[name][1] + ':' + path)


def source_tar(work, name, dest):
    # Normalize tar metadata independently of the host's git, UID and clock.
    args = ['git', '-C', work / name, 'archive', '--format=tar', PINS[name][1], '--', *PATHS[name].split(),
            *[':(exclude)' + p for p in EXCLUDE[name].split()]]
    with subprocess.Popen(args, stdout=subprocess.PIPE) as proc, tarfile.open(fileobj=proc.stdout, mode='r|') as src, tarfile.open(dest, 'w') as out:
        for entry in src:
            if entry.isdir():
                continue
            check(entry.isfile(), f'unexpected upstream link: {entry.name}')
            item = tarfile.TarInfo(entry.name)
            item.mode = 0o755 if entry.mode & 0o111 else 0o644
            item.size = entry.size
            out.addfile(item, src.extractfile(entry))
        check(proc.wait() == 0, f'git archive failed: {name}')


def clean_build(stage):
    work = stage / 'work'
    for name, (repo, pin) in PINS.items():
        path = work / name
        run('git', 'init', '-q', path)
        run('git', '-C', path, 'fetch', '--depth=1', 'https://github.com/' + repo + '.git', pin)
        run('git', '-C', path, 'update-ref', '--no-deref', 'HEAD', pin)
        run('git', '-C', path, 'read-tree', pin)
        # Compile the exact source we publish, not a checkout with extra fixtures or assets.
        tar = stage / (name + '.tar')
        source_tar(work, name, tar)
        with tar.open('rb') as stream:
            check(digest(stream) == SOURCE_HASH[name], f'Source mismatch: {name}')
        with tarfile.open(tar) as src:
            src.extractall(path, filter='data')
    for n in RECIPES:
        dst = stage / n
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(local(ROOT, n), dst)
    shutil.copyfile(local(ROOT, DRIVER[1]), stage / 'engine/Dockerfile')
    run('git', '-C', work / 'godot', 'apply', stage / 'engine/godot-fbdev.patch')
    for n in ('engine/build-engine.sh', 'tools/build-retroarch.sh'):
        # Delegate flags and patch order to the existing build; isolate its Docker tag.
        path = stage / n
        path.write_text(path.read_text().replace('socket-baseos-godot', IMAGE).replace('docker run --rm', 'docker run --rm --user "$(id -u):$(id -g)"'))
        run('sh', path)
    (work / 'card-runtime-core').mkdir()
    run('docker', 'run', '--rm', '--platform', 'linux/arm64', '-v', f'{work}/mgba:/src:ro', '-v', f'{work}/card-runtime-core:/out',
        '-v', f'{local(ROOT, DRIVER[2])}:/build.sh:ro', IMAGE, 'sh', '/build.sh')
    return work


def card_files():
    files = {n: local(ROOT / 'card', n) for n in CARD}
    # Never publish credentials someone entered into an example instead of copying it.
    for name, expected in {'wifi': '84635742bc90466407eee8f574f5b292e695d0785aeb93ad4c4295826a121d76',
                           'retroachievements': 'ca2fc9dcffe3060dcb2000cd65b7cfa07f3ab2dc0f9658ae22c715eb024e5324'}.items():
        check(sha(files[f'Config/{name}.txt.example'].read_bytes()) == expected, 'Edited credential example: ' + name)
    return files


def recipe_hash():
    return sha(b''.join(n.encode() + b'\0' + local(ROOT, n).read_bytes() for n in sorted(RECIPES + [DRIVER[2]])))


def source_local():
    return {**{'card/' + n: p for n, p in card_files().items()}, **{n: local(ROOT, n) for n in ['LICENSE', 'overlay/addons/FrontendPlugin/controls/LICENSE.txt', *RECIPES, *DRIVER]}, 'README.txt': README}


def runtime_local():
    return {**card_files(), **dict.fromkeys(GAMES, b''), SYS + 'licenses/control-icons.txt': local(ROOT, 'overlay/addons/FrontendPlugin/controls/LICENSE.txt'), SYS + 'licenses/Socket-COPYING.txt': local(ROOT, 'LICENSE'), SYS + 'source/README.txt': README}


def digest(stream):
    h = hashlib.sha256()
    while data := stream.read(1024 * 1024):
        h.update(data)
    return h.hexdigest()


def pack(path, files):
    with zipfile.ZipFile(path, 'w') as z:
        for n, value in sorted(files.items()):
            item = zipfile.ZipInfo(n)  # fixed 1980 timestamp, no host metadata
            item.create_system = 3
            mode = 0o755 if n.endswith(('.sh', '/')) or n in {SYS + s for s in BIN} else 0o644
            item.external_attr = ((mode | (stat.S_IFDIR if n.endswith('/') else stat.S_IFREG)) << 16) | (16 if n.endswith('/') else 0)
            item.compress_type = zipfile.ZIP_DEFLATED if not n.endswith('/') else zipfile.ZIP_STORED
            with z.open(item, 'w') as dst:
                if isinstance(value, Path):
                    with value.open('rb') as src:
                        shutil.copyfileobj(src, dst, 1024 * 1024)
                else:
                    dst.write(value)


MARKERS = {'godot': [b'a13da4feb', b'4.7.1.stable', b'SOCKET_GAME_OVERLAY_EGL', b'fbdev'],
           'retroarch/retroarch': [b'69a4f0e', b'1.22.2', b'SOCKET_GAME_OVERLAY_EGL', b'fbdev'],
           'cores/mgba_libretro.so': [b'retro_get_system_info\0', b'retro_load_game\0', b'mGBA\0', b'mgba_gb_model'],
           'socket-hardware': [b'hardware.ready'], 'socket-wifi-config': [b'--session\0', b'--child\0'],
           'socket-bluetooth-agent': [b'org.bluez.Agent1']}


def verify_elf(data, name):
    check(len(data) >= 64 and data[:7] == b'\x7fELF\x02\x01\x01', f'Not an ELF64 binary: {name}')
    kind, arch, version, _, phoff, shoff, _, ehsize, phsize, phnum, shsize, shnum, _ = struct.unpack_from('<HHIQQQIHHHHHH', data, 16)
    check(kind == 3 and arch == 183 and version == 1 and ehsize == 64 and phsize == 56 and shsize == 64 and
          phoff >= 64 and phnum and phoff + phsize * phnum <= shoff and shnum and shoff + shnum * shsize == len(data),
          f'Invalid AArch64 ELF or appended content: {name}')
    check(all(marker in data for marker in MARKERS[name]), f'Unexpected runtime binary: {name}')


def verify(path, source=False):
    fixed = source_local() if source else runtime_local()
    hashes = ({n + '.tar': h for n, h in SOURCE_HASH.items()} | {CA: CA_HASH} if source else
              {SYS + 'licenses/' + n: h for n, h in (NOTICE_HASH | {CA: CA_HASH, 'RetroArch-dependencies.txt': CREDITS_HASH}).items()})
    elfs = set() if source else {SYS + n for n in BIN}
    with zipfile.ZipFile(path) as z:
        expected = fixed.keys() | hashes.keys() | elfs
        check(sorted(z.namelist()) == sorted(expected), f'Unexpected, missing or duplicate ZIP members: {path}')
        for i in z.infolist():
            n = i.filename
            check(stat.S_IFMT(i.external_attr >> 16) == (stat.S_IFDIR if n.endswith('/') else stat.S_IFREG), f'Not ordinary: {n}')
            check(i.file_size < 512 * 1024 * 1024, f'Oversize member: {n}')
            with z.open(i) as src:
                if n in elfs:
                    verify_elf(src.read(), n[len(SYS):])
                else:
                    wanted = hashes.get(n)
                    if n in fixed:
                        x = fixed[n]
                        wanted = sha(x.read_bytes() if isinstance(x, Path) else x)
                    check(digest(src) == wanted, f'Content mismatch: {n}')


def build(output, cached):
    check(output.suffix.lower() == '.zip', 'Output path must end in .zip')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        stage = Path(temp).resolve()
        work = WORK if cached else clean_build(stage)
        runtime, sources = runtime_local(), source_local()
        if cached:
            check(recipe_hash() == RECIPE_HASH, 'Cached binary inputs changed; rebuild from source')
        for n, p in BIN.items():
            path = local(work, p)
            if cached:
                with path.open('rb') as f:
                    check(digest(f) == CACHED[n], f'Cached binary mismatch: {p}')
            runtime[SYS + n] = path
        for name in PINS:
            tar = stage / (name + '.tar')
            if cached:
                source_tar(work, name, tar)
            sources[tar.name] = tar
        ca = capture('docker', 'run', '--rm', '--platform', 'linux/arm64', 'socket-baseos-godot' if cached else IMAGE,
                     'cat', '/usr/share/doc/ca-certificates/copyright')
        sources[CA] = runtime[SYS + 'licenses/' + CA] = ca
        runtime[SYS + 'licenses/RetroArch-dependencies.txt'] = credits(work)
        for n, (name, p) in LICENSES.items():
            runtime[SYS + 'licenses/' + n] = upstream(work, name, p)
        for name, files, is_source in [('source.zip', sources, True), ('runtime.zip', runtime, False)]:
            pack(stage / name, files)
            verify(stage / name, is_source)
        (stage / 'source.zip').replace(output.with_name(output.stem + '-source.zip'))
        (stage / 'runtime.zip').replace(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group()
    for flag in ('--verify', '--verify-source', '--cached'):
        group.add_argument(flag, action='store_true')
    parser.add_argument('zip', type=Path)
    args = parser.parse_args()
    if args.verify or args.verify_source:
        verify(args.zip, args.verify_source)
    else:
        build(args.zip, args.cached)
    print(args.zip)
