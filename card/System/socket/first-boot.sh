#!/bin/sh
# Run from the card root, with the launcher's hardware lock held.
set -eu
user=Saves/socket/godot/app_userdata/Socket
for dir in Saves Saves/socket Saves/socket/godot Saves/socket/godot/app_userdata "$user" "$user/emulators" Games Games/GB Games/GBC Games/GBA; do
	[ ! -L "$dir" ] || { echo "Refusing linked directory: $dir" >&2; exit 1; }
	[ -d "$dir" ] || mkdir "$dir"
done

# Publish only complete files. A failed boot can retry without repairing JSON.
tmp=
trap '[ -z "$tmp" ] || rm -f "$tmp"' EXIT
seed() {
	[ ! -e "$1" ] && [ ! -L "$1" ] || return 0
	tmp=$(mktemp "$1.XXXXXX")
	cat > "$tmp"
	mv -n "$tmp" "$1"
	rm -f "$tmp"
	tmp=
}
for id in gb gbc gba; do
	seed "$user/emulators/$id.json" <<EOF
[{"uniqueId":"$id.ra64.mgba","name":"RetroArch (mGBA)","acceptedFilenameRegex":"[.]$id$","amStartArguments":"-e LIBRETRO mgba -e ROM {file.path}"}]
EOF
done
seed "$user/user_data.json" <<'EOF'
{"added_platforms":[
 {"model_id":"gba","app_id":"gba.ra64.mgba","rom_folder_path":"/mnt/sdcard/Games/GBA","games":[]},
 {"model_id":"gbc","app_id":"gbc.ra64.mgba","rom_folder_path":"/mnt/sdcard/Games/GBC","games":[]},
 {"model_id":"gb","app_id":"gb.ra64.mgba","rom_folder_path":"/mnt/sdcard/Games/GB","games":[]}
]}
EOF
