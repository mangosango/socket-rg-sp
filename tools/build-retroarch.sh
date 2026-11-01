#!/bin/sh
# Build RetroArch for BaseOS: Mali fbdev GLES, ALSA audio, udev gamepad.
# Output: work/RetroArch/retroarch
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/../work"
SRC="$WORK/RetroArch"
mkdir -p "$WORK"
[ -d "$SRC" ] || git clone --depth 1 -b v1.22.2 https://github.com/libretro/RetroArch.git "$SRC"

# Detect applied patches in reverse order on an isolated source copy.
PATCH_STATE="$(mktemp -d)"
trap 'rm -rf "$PATCH_STATE"' EXIT HUP INT TERM
PATCHES="retroarch-mali-rgb.patch retroarch-menu-hold.patch retroarch-menu-input.patch retroarch-controls.patch retroarch-quick-menu.patch retroarch-sleep.patch"
reverse_patches=""
for patch_file in $PATCHES; do
	sed -n 's|^--- a/||p' "$HERE/$patch_file"
done | sort -u | while IFS= read -r path; do
	mkdir -p "$PATCH_STATE/$(dirname "$path")"
	cp "$SRC/$path" "$PATCH_STATE/$path"
done
for patch_file in $PATCHES; do
	reverse_patches="$patch_file $reverse_patches"
done
for patch_file in $reverse_patches; do
	if patch -d "$PATCH_STATE" -p1 -R --force --dry-run --silent < "$HERE/$patch_file" > /dev/null 2>&1; then
		patch -d "$PATCH_STATE" -p1 -R --force --silent < "$HERE/$patch_file"
		touch "$PATCH_STATE/$patch_file"
	fi
done
for patch_file in $PATCHES; do
	if [ ! -f "$PATCH_STATE/$patch_file" ]; then
		patch -d "$SRC" -p1 --force < "$HERE/$patch_file"
	fi
done

cp "$HERE/retroarch-controls.h" "$SRC/socket_controls.h"
cp "$HERE/retroarch-control-icons.h" "$SRC/socket_control_icons.h"
cp "$HERE/retroarch-quick-menu.h" "$SRC/socket_quick_menu.h"

docker build --platform linux/arm64 -t socket-baseos-godot "$HERE/../engine"
docker run --rm --platform linux/arm64 -v "$SRC":/src -w /src socket-baseos-godot sh -euc '
	./configure --disable-x11 --disable-wayland --disable-kms --disable-sdl2 --disable-pulse \
		--disable-qt --disable-vulkan --disable-ffmpeg --disable-discord --disable-opengl \
		--enable-opengles --enable-opengles3 --enable-egl --enable-mali_fbdev \
		--enable-alsa --enable-udev
	make -j"$(nproc)"
	strip retroarch
'
