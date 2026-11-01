"""Set up Socket's library on a card that already has slot's games.

Usage: python3 -I seed-library.py <card-root>   (for example /Volumes/BASEOS)

1. Copies slot's mGBA and gpSP cores into System/socket/cores.
2. Stores Socket's emulator list (Daijishou), so Socket does not ask to
   download it on the device.
3. Adds GB, GBC and GBA platforms for slot's Games/ folders, using RetroArch
   with mGBA. It does not change an existing Socket library.
Then open each platform in Socket and press Scan.
"""
import json
import os
import shutil
import sys
import urllib.parse
import urllib.request

DAIJISHOU = "https://raw.githubusercontent.com/TapiocaFox/Daijishou/main/platforms/"
# (Socket platform ID, slot folder, Socket emulator entry)
PLATFORMS = [
    ("gba", "Games/GBA", "gba.ra64.mgba"),
    ("gbc", "Games/GBC", "gbc.ra64.mgba"),
    ("gb", "Games/GB", "gb.ra64.mgba"),
]


def get_json(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.load(response)


def main(card):
    if not os.path.isdir(os.path.join(card, "System", "socket")):
        sys.exit(f"seed-library: {card}/System/socket not found; copy dist/ to the card first")

    cores = os.path.join(card, "System", "socket", "cores")
    for core in ("mgba_libretro.so", "gpsp_libretro.so"):
        src = os.path.join(card, "System", core)
        if os.path.isfile(src):
            shutil.copyfile(src, os.path.join(cores, core))
            print(f"core: {core}")
    if not os.path.isfile(os.path.join(cores, "mgba_libretro.so")):
        print("warning: no mgba_libretro.so; Socket cannot start games until you add it to System/socket/cores")

    # Socket's user:// folder; launch_frontend.sh sets XDG_DATA_HOME=Saves/socket.
    user_dir = os.path.join(card, "Saves", "socket", "godot", "app_userdata", "Socket")
    emulators = os.path.join(user_dir, "emulators")
    os.makedirs(emulators, exist_ok=True)
    for entry in get_json(DAIJISHOU + "index.json")["platformList"]:
        pack = get_json(DAIJISHOU + urllib.parse.quote(entry["filename"]))
        with open(os.path.join(emulators, entry["platformUniqueId"] + ".json"), "w") as f:
            json.dump(pack["playerList"], f)
    print("emulator list: stored")

    user_data = os.path.join(user_dir, "user_data.json")
    if os.path.exists(user_data):
        print("library: Socket already has a library; add the platforms in Socket")
        return
    platforms = []
    for platform_id, folder, app_id in PLATFORMS:
        if not os.path.isdir(os.path.join(card, folder)):
            continue
        platforms.append({
            "model_id": platform_id,
            "app_id": app_id,
            "rom_folder_path": "/mnt/sdcard/" + folder,
            "games": [],
            "visible": True,
            "background_style": "classic",
            "hide_duplicates": True,
            "scan_subfolders": False,
            "camera_zoom": 1.0,
            "sort_mode": "title",
            "launch_args_override": "",
        })
        print(f"platform: {platform_id} -> /mnt/sdcard/{folder}")
    with open(user_data, "w") as f:
        json.dump({"added_platforms": platforms, "retro_achievements_username": "", "retro_achievements_api_key": ""}, f, indent="\t")


if __name__ == "__main__":
    main(sys.argv[1])
