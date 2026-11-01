#!/bin/sh
# Build a BaseOS card folder for Socket.
#
#   ./build.sh <socket.apk>
#
# Output: dist/ (copy its contents to the root of your frontend card).
set -eu

APK="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="$HERE/dist"

sh "$HERE/engine/build-engine.sh"
sh "$HERE/tools/build-retroarch.sh"

rm -rf "$DIST"
mkdir -p "$DIST"
cp -R "$HERE/card/." "$DIST/"
cp "$HERE/work/godot/bin/godot.linuxbsd.template_release.arm64" "$DIST/System/socket/godot"
cp "$HERE/work/socket-hardware" "$DIST/System/socket/socket-hardware"
cp "$HERE/work/RetroArch/retroarch" "$DIST/System/socket/retroarch/retroarch"
sh "$HERE/tools/build-pack.sh" "$APK" "$DIST/System/socket/socket.pck"
echo "build: card files are in $DIST"
