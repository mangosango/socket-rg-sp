#!/bin/sh
# Build the BaseOS Godot 4.7.1 export template (AArch64, glibc 2.31) with the
# Mali fbdev display server. launch_frontend.sh runs the engine through the
# glibc loader, so the engine cannot find a pack next to itself; it needs
# --main-pack, which disable_path_overrides=no keeps. Output: work/godot/bin/godot.linuxbsd.template_release.arm64
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/../work"
SRC="$WORK/godot"
mkdir -p "$WORK"

if [ ! -d "$SRC" ]; then
	git clone --depth 1 -b 4.7.1-stable https://github.com/godotengine/godot.git "$SRC"
	git -C "$SRC" apply "$HERE/godot-fbdev.patch"
fi
rm -rf "$SRC/platform/linuxbsd/fbdev"
cp -R "$HERE/fbdev" "$SRC/platform/linuxbsd/fbdev"

docker build --platform linux/arm64 -t socket-baseos-godot "$HERE"
docker run --rm --platform linux/arm64 -v "$SRC":/godot socket-baseos-godot \
	scons -j"$(getconf _NPROCESSORS_ONLN)" platform=linuxbsd target=template_release arch=arm64 \
	production=yes lto=none disable_path_overrides=no fbdev=yes x11=no wayland=no vulkan=no opengl3=yes sdl=no \
	pulseaudio=no dbus=no speechd=no fontconfig=no udev=no accesskit=no

# Build the session controls helper with the same BaseOS ABI.
docker run --rm --platform linux/arm64 -v "$HERE/fbdev":/src:ro -v "$WORK":/out socket-baseos-godot \
	cc -std=c11 -O2 -Wall -Wextra -Werror /src/hardware.c -lm -o /out/socket-hardware
