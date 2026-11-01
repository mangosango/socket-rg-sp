#!/bin/sh
# Start one game for Socket. Edit this file to use a different emulator.
#   $1  libretro core name, for example mgba
#   $2  ROM path
#   $3  Socket platform ID, for example gba
SYS="$(cd "$(dirname "$0")" && pwd)"
run="${SOCKET_RUN:-/tmp/socket}"
export SOCKET_GAME_DESCRIPTOR="$run/game.descriptor"
export SOCKET_RESUME_MANIFEST="${SOCKET_RESUME_MANIFEST:-/mnt/sdcard/Saves/socket/resume-game}"
# The resume record is data, never shell source.
case "${1:-}" in ''|*[!A-Za-z0-9_-]*) exit 1 ;; esac
case "${3:-}" in ''|*[!A-Za-z0-9_-]*) exit 1 ;; esac
case "${2:-}" in /*) ;; *) exit 1 ;; esac
case "$2" in *'
'*|*"$(printf '\r')"*) exit 1 ;; esac
[ -f "$2" ] && [ -f "$SYS/cores/${1}_libretro.so" ] || exit 1
mkdir -p "$run" "$(dirname "$SOCKET_RESUME_MANIFEST")" || exit 1
umask 077
printf 'socket-resume-v1\n%s\n%s\n%s\n' "$1" "$2" "$3" > "$SOCKET_GAME_DESCRIPTOR.new" &&
	mv -f "$SOCKET_GAME_DESCRIPTOR.new" "$SOCKET_GAME_DESCRIPTOR" || exit 1

# RetroArch uses the first duplicate key. Keep the last override explicitly.
merge_options() {
	awk -F= '{ text[NR]=$0; if ($1 ~ /^[a-zA-Z0-9_]+[[:space:]]*$/ && NF > 1) {
		key=$1; gsub(/[[:space:]]/, "", key); keys[NR]=key; last[key]=NR
	} } END { for (i=1; i<=NR; i++) if (!(i in keys) || last[keys[i]]==i) print text[i] }' \
		"$1" > "$1.new" && mv -f "$1.new" "$1"
}

# Create the save, state, and screenshot paths from retroarch.cfg before launch.
mkdir -p /mnt/sdcard/Saves/retroarch /mnt/sdcard/Screenshots || exit 1

# BaseOS has no udev daemon. Tag only the proxy so RetroArch cannot pick the
# grabbed physical pad. The proxy removes SELECT+Up/Down brightness chords.
mkdir -p /run/udev/data
for dev in /sys/class/input/event*; do
	name=$(cat "$dev/device/name" 2>/dev/null)
	data="/run/udev/data/c$(cat "$dev/dev" 2>/dev/null)"
	if [ "$name" = "Socket H700 Gamepad" ]; then
		printf 'E:ID_INPUT=1\nE:ID_INPUT_JOYSTICK=1\n' > "$data"
	elif awk '{ if (NF < 5) exit 1; w = sprintf("%16s", $(NF - 4)); exit index("13579bdf", substr(w, 4, 1)) ? 0 : 1 }' "$dev/device/capabilities/key" 2>/dev/null; then
		rm -f "$data"
	fi
done

# Apply the saved Slot screen settings only to the supported handheld cores.
case "$1:${3:-}" in
	mgba:gb|mgba:gbc|mgba:gba|gpsp:gba)
		run="${SOCKET_RUN:-/tmp/socket}"
		mkdir -p "$run" || exit 1
		preferences=/mnt/sdcard/Saves/socket/retroarch
		mkdir -p "$preferences" || exit 1
		export SOCKET_MENU_CONFIG="$preferences/$3.cfg"
		export SOCKET_CORE_OPTIONS="$preferences/$1-$3-options.cfg"
		options="$SYS/retroarch/core-options.cfg"
		if [ "$1" = mgba ] && [ "$3" != gba ]; then
			cgb=$(od -An -tu1 -j 323 -N 1 "$2" 2>/dev/null)
			if [ -n "$cgb" ] && [ "$cgb" -lt 128 ]; then
				options="$SYS/retroarch/gb-core-options.cfg"
			fi
		fi
		# Keep RGUI option changes in RAM. Preserve the installed settings snapshot.
		if [ "$3" = gb ]; then correction=GBC; else correction=Auto; fi
		sed "s/mgba_color_correction = .*/mgba_color_correction = \"$correction\"/" \
			"$options" > "$run/retroarch-core-options.cfg" || exit 1
		if [ -f "$SOCKET_CORE_OPTIONS" ]; then
			cat "$SOCKET_CORE_OPTIONS" >> "$run/retroarch-core-options.cfg" || exit 1
		fi
		if [ "$1:$3" = mgba:gba ]; then
			code=$(od -An -tu1 -j 172 -N 1 "$2" 2>/dev/null)
			gbp=OFF
			if [ -n "$code" ] && [ "$code" -ne 77 ]; then gbp=ON; fi
			printf 'mgba_force_gbp = "%s"\n' "$gbp" >> "$run/retroarch-core-options.cfg" || exit 1
		elif [ "$1" = gpsp ]; then
			bios=/mnt/sdcard/BIOS/gba_bios.bin
			if [ -f "$bios" ] && [ "$(wc -c < "$bios" | tr -d '[:space:]')" = 16384 ] && \
				[ "$(od -An -tu1 -N 1 "$bios" 2>/dev/null | tr -d ' ')" = 24 ]; then
				printf 'gpsp_boot_mode = "bios"\n' >> "$run/retroarch-core-options.cfg" || exit 1
			fi
		fi
		merge_options "$run/retroarch-core-options.cfg" || exit 1
		cat "$SYS/retroarch/$3.cfg" > "$run/retroarch.cfg" || exit 1
		if [ -f "$SOCKET_MENU_CONFIG" ]; then
			cat "$SOCKET_MENU_CONFIG" >> "$run/retroarch.cfg" || exit 1
		fi
		printf 'core_options_path = "%s"\n' "$run/retroarch-core-options.cfg" >> "$run/retroarch.cfg" || exit 1
		if [ "${SOCKET_RESUME_LOAD:-0}" = 1 ]; then
			printf 'savestate_auto_load = "false"\n' >> "$run/retroarch.cfg" || exit 1
		fi
		merge_options "$run/retroarch.cfg" || exit 1
		if [ "$3" = gba ]; then shader=lcd3x; else shader=grid; fi
		set -- "$1" "$2" --appendconfig "$run/retroarch.cfg" \
			--set-shader "$SYS/retroarch/shaders/$shader.glslp" ;;
	*) if [ "${SOCKET_RESUME_LOAD:-0}" = 1 ]; then
			printf 'savestate_auto_load = "false"\n' > "$run/retroarch-resume.cfg" || exit 1
			set -- "$1" "$2" --appendconfig "$run/retroarch-resume.cfg"
		else set -- "$1" "$2"; fi ;;
esac
core="$1"
rom="$2"
shift 2
printf '%s\n' "$$" > "$run/app.pid.new" && mv -f "$run/app.pid.new" "$run/app.pid" || exit 1
printf '%s\n' "$$" > "$run/game.active.new" && mv -f "$run/game.active.new" "$run/game.active" || exit 1
# Optional timing record. Install retroarch/pacing-probe.so only while measuring.
if [ -f "$SYS/retroarch/pacing-probe.so" ]; then
	export LD_PRELOAD="$SYS/retroarch/pacing-probe.so${LD_PRELOAD:+:$LD_PRELOAD}"
	export SOCKET_PACING_LOG=/mnt/sdcard/Logs/socket-pacing.csv
fi
exec /lib/ld-linux-aarch64.so.1 "$SYS/retroarch/retroarch" \
	--verbose --config "$SYS/retroarch/retroarch.cfg" "$@" -L "$SYS/cores/${core}_libretro.so" "$rom"
