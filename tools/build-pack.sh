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

# Replace compiled scripts with patched source. Godot loads res://x.gd once
# its .remap and .gdc are gone.
use_source() {
	rm -f "$RES/$1.remap" "$RES/${1%.gd}.gdc"
	cp "$2" "$RES/$1"
}
mkdir -p "$WORK/src"
SCRIPTS="scripts/autoload/manager.gd scenes/screen_apps.gd scenes/screen_edit_platform.gd scripts/autoload/theme_manager.gd scripts/screens/screen.gd scenes/focus_overlay.gd scripts/cartridge.gd scenes/render_scale_3d.gd scenes/cartridge_carousel.gd scenes/keyboard_avoider.gd"
for script in $SCRIPTS; do
	mkdir -p "$WORK/src/$(dirname "$script")"
	python3 -I "$HERE/gdc2gd.py" "$RES/${script%.gd}.gdc" "$WORK/src/$script"
done
SHADERS="scenes/liquid_glass.gdshader materials/frosted_glass.gdshader scenes/paper_sticker.gdshader"
for shader in $SHADERS; do
	mkdir -p "$WORK/src/$(dirname "$shader")"
	cp "$RES/$shader" "$WORK/src/$shader"
done
cp -R "$WORK/src" "$WORK/decoded"
python3 -I "$HERE/patch-socket.py" "$WORK/src" "$RES/project.binary"
# Replace only the files that this Socket version needs to change.
for shader in $SHADERS; do
	cp "$WORK/src/$shader" "$RES/$shader"
done
for script in $SCRIPTS; do
	cmp -s "$WORK/src/$script" "$WORK/decoded/$script" || use_source "$script" "$WORK/src/$script"
done
use_source addons/FrontendPlugin/frontend_bridge.gd "$OVERLAY/addons/FrontendPlugin/frontend_bridge.gd"
use_source addons/FrontendPlugin/folder_picker.gd "$OVERLAY/addons/FrontendPlugin/folder_picker.gd"
use_source addons/FrontendPlugin/controls_hud.gd "$OVERLAY/addons/FrontendPlugin/controls_hud.gd"
cp -R "$OVERLAY/addons/FrontendPlugin/controls" "$RES/addons/FrontendPlugin/controls"
mkdir -p "$RES/shaders"
cp "$OVERLAY/shaders/display_aa.gdshader" "$RES/shaders/display_aa.gdshader"

# The AYN Thor second-screen GDExtension has no Linux AArch64 build.
rm -rf "$RES/addons/AynThor/bin"
grep -v AynThor "$RES/.godot/extension_list.cfg" > "$WORK/extension_list.cfg" || true
mv "$WORK/extension_list.cfg" "$RES/.godot/extension_list.cfg"

python3 -I "$HERE/pack.py" "$RES" "$OUT"
echo "build-pack: wrote $OUT"
