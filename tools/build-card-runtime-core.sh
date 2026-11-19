#!/bin/sh
# Run in the arm64 Bullseye toolchain with a read-only, pinned /src and writable /out.
set -eu
export SOURCE_DATE_EPOCH=1789611180
printf '%s\n' 'cmake==3.31.6 --hash=sha256:42d9883b8958da285d53d5f69d40d9650c2d1bcf922d82b3ebdceb2b3a7d4521' >/tmp/cmake.req
pip3 install --timeout 120 --disable-pip-version-check --no-cache-dir --require-hashes --only-binary=:all: --no-deps -r /tmp/cmake.req
cmake -S /src -B /tmp/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_SKIP_RPATH=ON -DBUILD_LIBRETRO=ON -DBUILD_QT=OFF -DBUILD_SDL=OFF -DSKIP_LIBRARY=ON -DBUILD_GL=OFF -DBUILD_GLES2=OFF -DSKIP_GIT=ON
cmake --build /tmp/build --target mgba_libretro --parallel "$(nproc)"
strip -o /out/mgba_libretro.so /tmp/build/mgba_libretro.so
python3 - <<'PY'
import ctypes as c
class Info(c.Structure):
    _fields_ = [('name', c.c_char_p), ('version', c.c_char_p), ('extensions', c.c_char_p), ('fullpath', c.c_bool), ('block_extract', c.c_bool)]
core = c.CDLL('/out/mgba_libretro.so')
info = Info()
core.retro_get_system_info(c.byref(info))
assert core.retro_api_version() == 1 and info.name == b'mGBA'
assert {b'gb', b'gbc', b'gba'} <= set(info.extensions.split(b'|'))
print(info.name, info.version, info.extensions)
PY
