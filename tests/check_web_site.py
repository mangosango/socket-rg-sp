"""Check the actual Pages artifact, not the source tree. Usage: check_web_site.py SITE"""
import argparse
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def check(site, require_source=False):
    if not __debug__:
        raise RuntimeError('artifact verification requires Python assertions (disable -O)')
    web = 'index.html style.css app.js worker.js departure.woff2 departure-license.txt'.split()
    runtime = 'pyodide.mjs pyodide.asm.mjs pyodide.asm.wasm pyodide-lock.json python_stdlib.zip'.split()
    licenses = 'index.txt GPL-3.0.txt control-icons.txt runtime.txt openssl.txt'.split()
    expected = set(web + ['card-runtime.zip', 'converter.zip', 'unpack.js', 'unpack-wasm.js', 'unpack-wasm.wasm'])
    expected.update('runtime/' + name for name in runtime)
    expected.update('licenses/' + name for name in licenses)
    has_source = (site / 'card-runtime-source.zip').exists()
    if require_source or has_source:
        expected.add('card-runtime-source.zip')
    actual = set()
    for path in site.rglob('*'):
        assert not path.is_symlink(), path
        if not path.is_dir():
            assert path.is_file() and path.stat().st_size, path
            actual.add(path.relative_to(site).as_posix())
    assert expected == actual, expected ^ actual
    subprocess.run([sys.executable, ROOT / 'tools/build-card-runtime.py', '--verify', site / 'card-runtime.zip'], check=True)
    if has_source:
        subprocess.run([sys.executable, ROOT / 'tools/build-card-runtime.py', '--verify-source', site / 'card-runtime-source.zip'], check=True)
        assert '../card-runtime-source.zip' in (site / 'licenses/index.txt').read_text()
    for name in web:
        assert (site / name).read_bytes() == (ROOT / 'web' / name).read_bytes(), name
    for name in runtime:
        assert (site / 'runtime' / name).read_bytes() == (ROOT / 'web/node_modules/pyodide' / name).read_bytes(), name

    # Catch both an accidental extra archive member and forgetting an overlay on a future edit.
    overlays = subprocess.check_output(['git', 'ls-files', '-z', 'overlay/'], cwd=ROOT).decode().split('\0')[:-1]
    members = set(overlays + ['convert.py', 'tools/build_pack.py', 'tools/gdc2gd.py', 'tools/patch-socket.py', 'tools/pack.py'])
    with zipfile.ZipFile(site / 'converter.zip') as archive:
        names = archive.namelist()
        assert len(names) == len(members) and set(names) == members, set(names) ^ members
        for name in names:
            path = ROOT / ('web/convert.py' if name == 'convert.py' else name)
            assert archive.read(name) == path.read_bytes(), name
    for name, original in [('GPL-3.0.txt', 'LICENSE'), ('runtime.txt', 'tools/build-web.NOTICES.txt'),
                           ('control-icons.txt', 'overlay/addons/FrontendPlugin/controls/LICENSE.txt')]:
        assert (site / 'licenses' / name).read_bytes() == (ROOT / original).read_bytes(), name
    assert 'Apache License' in (site / 'licenses/openssl.txt').read_text()
    print('Verified the Pages file allowlist, notices, runtime and converter archives.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('site', type=Path)
    parser.add_argument('--require-source', action='store_true', help='release check: reject a preview without corresponding source')
    args = parser.parse_args()
    check(args.site, args.require_source)
