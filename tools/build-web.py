#!/usr/bin/env python3
"""Assemble NEW_DIR after building work/web-card-runtime.zip, npm ci and emsdk activation."""
import argparse
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WEB = ('index.html', 'style.css', 'app.js', 'worker.js', 'departure.woff2', 'departure-license.txt')
RUNTIME = ('pyodide.mjs', 'pyodide.asm.mjs', 'pyodide.asm.wasm', 'pyodide-lock.json', 'python_stdlib.zip')
TOOLS = ('build_pack.py', 'gdc2gd.py', 'patch-socket.py', 'pack.py')
PLUGIN = 'overlay/addons/FrontendPlugin/'
OVERLAY = [PLUGIN + name + '.gd' for name in (
    'artwork', 'bluetooth_audio', 'bluetooth_settings', 'controller_dialog', 'controls_hud',
    'device_settings', 'emulation_settings', 'settings_form', 'folder_picker', 'frontend_bridge', 'game_overlay', 'shader_startup', 'split_label_view', 'split_label_surfaces', 'wifi_settings',
)] + [PLUGIN + 'controls/' + name for name in (
    'LICENSE.txt', 'README.txt', 'brightness.png', 'temperature.png', 'volume-zero.png', 'volume.png',
)] + ['overlay/shaders/display_aa.gdshader', 'overlay/shaders/split_label_occluder.gdshader']


def source(path):
    if path.resolve(strict=True) != path or not path.is_file():
        raise ValueError(f'Expected regular file (no symlinks): {path}')
    return path


def assemble(root, unpack, site):
    site.mkdir()
    (site / 'runtime').mkdir()
    (site / 'licenses').mkdir()
    for name in WEB:
        shutil.copyfile(source(root / 'web' / name), site / name)
    for name in RUNTIME:
        shutil.copyfile(source(root / 'web/node_modules/pyodide' / name), site / 'runtime' / name)
    for name in ('unpack-wasm.js', 'unpack-wasm.wasm', 'unpack.js'):
        shutil.copyfile(source(unpack / name), site / name)

    # Only the explicitly named, verified archives may leave work/. Never scan dist/ or a card.
    source_notice = 'Local preview without the corresponding source archive; do not redistribute.'
    for name, verify in [('card-runtime.zip', '--verify'), ('card-runtime-source.zip', '--verify-source')]:
        path = root / 'work' / ('web-' + name)
        if verify == '--verify-source' and not (path.exists() or path.is_symlink()):
            continue
        staged = site / name
        shutil.copyfile(source(path), staged)
        subprocess.run([sys.executable, root / 'tools/build-card-runtime.py', verify, staged], check=True)
        if verify == '--verify-source':
            source_notice = 'Corresponding source download: ../card-runtime-source.zip (not needed on the SD card).'

    # No directory copies: local APKs, new overlays, caches and unpack build byproducts stay private.
    with zipfile.ZipFile(site / 'converter.zip', 'w') as archive:
        members = {f'tools/{n}': root / 'tools' / n for n in TOOLS}
        members.update({n: root / n for n in OVERLAY})
        members['convert.py'] = root / 'web/convert.py'
        for name, path in sorted(members.items()):
            archive.writestr(zipfile.ZipInfo(name), source(path).read_bytes(), zipfile.ZIP_DEFLATED)

    for path, name in [(root / 'LICENSE', 'GPL-3.0.txt'),
                       (root / PLUGIN / 'controls/LICENSE.txt', 'control-icons.txt'),
                       (root / 'tools/build-web.NOTICES.txt', 'runtime.txt'),
                       (unpack / 'openssl-LICENSE.txt', 'openssl.txt')]:
        shutil.copyfile(source(path), site / 'licenses' / name)
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    (site / 'licenses/index.txt').write_text(f'''Socket BaseOS converter: GNU GPL version 3 or later; see GPL-3.0.txt.
Source and build scripts: https://github.com/mangosango/socket-rg-sp/tree/{revision}
Departure Mono by Helena Zhang: SIL OFL 1.1; see ../departure-license.txt.
Control icons: Nerd Fonts (MIT); see control-icons.txt.
Unpacker: OpenSSL 3.5.9 (Apache-2.0); see openssl.txt.
Source: https://github.com/openssl/openssl/tree/openssl-3.5.9
Pyodide 314.0.8 (MPL-2.0), CPython 3.14.2 and runtime dependencies: see runtime.txt.
Pyodide source and build recipes: https://github.com/pyodide/pyodide/tree/314.0.8
Card runtime: see the component licenses in card-runtime.zip under System/socket/licenses/.
{source_notice}
Socket APKs and generated assets are not included or licensed by this site.
''', encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path, help='new site directory (must not exist)')
    dest = parser.parse_args().destination.absolute()
    if dest.exists() or dest.is_symlink():
        parser.error(f'refusing to overwrite {dest}')
    if not (ROOT / 'work/web-card-runtime.zip').is_file():
        parser.error('missing work/web-card-runtime.zip; first run: python3 tools/build-card-runtime.py work/web-card-runtime.zip')
    dest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=dest.parent.resolve()) as tmp:
        unpack, site = Path(tmp) / 'unpack', Path(tmp) / 'site'
        subprocess.run(['bash', ROOT / 'tools/build-web-unpack.sh', unpack], check=True)
        assemble(ROOT, unpack, site)
        site.rename(dest)


if __name__ == '__main__':
    main()
