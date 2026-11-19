#!/bin/sh
# Build socket.pck for BaseOS from your own copy of the Socket APK.
#
#   tools/build-pack.sh <socket.apk> <out.pck>
#
# Needs: cc, OpenSSL libcrypto, python3, zstd, unzip.
# The APK's assets stay on your computer; this repository ships none of them.
set -eu

APK="$1"
OUT="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
OVERLAY="$HERE/../overlay"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CRYPTO="$(pkg-config --cflags --libs libcrypto 2>/dev/null)" || {
	SSL="$(brew --prefix openssl 2>/dev/null)" && CRYPTO="-I$SSL/include -L$SSL/lib -lcrypto"
} || { echo "build-pack: OpenSSL libcrypto not found" >&2; exit 1; }
# shellcheck disable=SC2086
cc -O2 -o "$WORK/godot-unpack" "$HERE/godot-unpack.c" $CRYPTO

unzip -q "$APK" 'assets/*' 'lib/arm64-v8a/libgodot_android.so' -d "$WORK/apk"
ASSETS="$WORK/apk/assets"

# Android-only files that are not part of the encrypted project.
rm -rf "$ASSETS/assets.sparsepck" "$ASSETS/_cl_" "$ASSETS/dexopt"
RES="$WORK/res"
"$WORK/godot-unpack" extract "$WORK/apk/lib/arm64-v8a/libgodot_android.so" "$ASSETS" "$RES"

python3 -I "$HERE/build_pack.py" "$RES" "$OVERLAY" "$OUT"
echo "build-pack: wrote $OUT"
