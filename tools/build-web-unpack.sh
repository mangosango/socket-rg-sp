#!/usr/bin/env bash
# With emsdk active: tools/build-web-unpack.sh work/web-unpack
set -euo pipefail
[[ $# == 1 ]] || { echo 'usage: build-web-unpack.sh OUTPUT_DIR' >&2; exit 64; }
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$1"
out=$(cd "$1" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
version=3.5.9
sha=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
curl -fsSL --retry 3 "https://github.com/openssl/openssl/releases/download/openssl-$version/openssl-$version.tar.gz" -o openssl.tar.gz
printf '%s  openssl.tar.gz\n' "$sha" | shasum -a 256 -c -
tar -xzf openssl.tar.gz
cd "openssl-$version"
CC=emcc AR=emar RANLIB=emranlib ./Configure linux-generic32 no-shared no-asm no-threads no-tests no-module no-dso no-sock no-ui-console no-secure-memory no-afalgeng no-engine no-hw -Os
make -j"${JOBS:-8}" build_generated
# Build just the portable AES-CFB and MD5 primitives, not providers/TLS.
emcc -O3 -ffunction-sections -I. -Iinclude -Icrypto/modes \
  crypto/aes/{aes_core,aes_cfb}.c crypto/modes/cfb128.c crypto/md5/md5_dgst.c crypto/mem_clr.c \
  "$here/godot-unpack.c" --no-entry \
  -sMODULARIZE -sEXPORT_ES6=1 -sEXPORT_NAME=createUnpackModule -sENVIRONMENT=worker \
  -sFILESYSTEM=0 -sALLOW_MEMORY_GROWTH -sMAXIMUM_MEMORY=536870912 -sABORTING_MALLOC=0 \
  -sEXPORTED_FUNCTIONS=_malloc,_free,_reset_unpack,_start_unpack,_decrypt_asset \
  -sEXPORTED_RUNTIME_METHODS=HEAPU8 -o "$tmp/unpack-wasm.js"
cp "$tmp/unpack-wasm.js" "$tmp/unpack-wasm.wasm" "$here/../web/unpack.js" "$out/"
cp LICENSE.txt "$out/openssl-LICENSE.txt"
