"""Scan a mounted Socket card and cache metadata and art for offline use.

Run with --scan-only to use existing media without network access.
Set SOCKET_API_KEY to an authorized Socket GamesDB key to download media.
Artwork validation and PNG conversion need the macOS sips command.
Downloads need curl 8.4 or newer to enforce the response size limit. The device
must not use the card while this tool runs. Existing files get a .bak-<time>
copy before atomic replacement. Copy a backup over its original to restore it.
Only unpacked .gb, .gbc, and .gba ROMs are scanned.
"""

import argparse
import functools
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import urllib.parse

SERVICE = "https://gamedb.depmots.com"
USER_DIR = Path("Saves/socket/godot/app_userdata/Socket")
PLATFORMS = {
    "gb": "nintendo-game-boy",
    "gbc": "nintendo-game-boy-color",
    "gba": "nintendo-game-boy-advance",
}
PNG = b"\x89PNG\r\n\x1a\n"


def safe_path(root, relative):
    path = root / relative
    if not path.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Path leaves card: {relative}")
    if path.is_symlink():
        raise ValueError(f"Symbolic link is not supported: {relative}")
    return path


def filename(name):
    return re.sub(r'[:/\\?*"|%<>]', "_", name.strip())


def read_json(path, default):
    if not path.exists():
        return default
    with path.open() as stream:
        return json.load(stream)


def write_file(path, data):
    if path.exists() and path.read_bytes() == data:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        backup = path.with_name(path.name + ".bak-" + str(time.time_ns()))
        shutil.copy2(path, backup)
    fd, temporary = tempfile.mkstemp(prefix=".socket-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_json(path, value):
    if path.exists() and read_json(path, None) == value:
        return
    write_file(path, (json.dumps(value, indent="\t", ensure_ascii=False) + "\n").encode())


class AuthenticationError(Exception):
    pass


@functools.cache
def check_curl():
    environment = os.environ.copy()
    environment.pop("SOCKET_API_KEY", None)
    try:
        result = subprocess.run(["curl", "-q", "--version"], capture_output=True, timeout=20, check=True,
                                env=environment)
        version = re.match(rb"curl (\d+)\.(\d+)\.(\d+)", result.stdout)
        if version and tuple(map(int, version.groups())) >= (8, 4, 0):
            return
    except (OSError, subprocess.SubprocessError):
        pass
    raise OSError("Downloads need curl 8.4 or newer to enforce the 32 MiB limit")


def request(url, key=""):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("Download URL must use HTTPS without user information")
    if any(ord(char) < 32 or ord(char) == 127 for char in url + key):
        raise ValueError("Download URL and API key must not contain control characters")
    config = ""
    if key and parsed.netloc == urllib.parse.urlsplit(SERVICE).netloc:
        escaped = key.replace("\\", "\\\\").replace('"', '\\"')
        config = f'header = "X-API-Key: {escaped}"\n'
    check_curl()
    command = ["curl", "-q", "--silent", "--globoff", "--proto", "=https", "--max-redirs", "0",
               "--max-time", "20", "--max-filesize", str(32 * 1024 * 1024),
               "--user-agent", "Socket-card-setup/1", "--config", "-", "--write-out", "\n%{http_code}",
               "--url", url]
    environment = os.environ.copy()
    environment.pop("SOCKET_API_KEY", None)
    for attempt in range(3):
        try:
            result = subprocess.run(command, input=config.encode(), stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, timeout=20, env=environment)
        except subprocess.TimeoutExpired:
            result = None
        except OSError:
            raise OSError("Cannot run curl") from None
        if result is not None:
            if result.returncode == 63:
                raise ValueError("Download exceeds 32 MiB")
            if result.returncode == 0:
                data, separator, status = result.stdout.rpartition(b"\n")
                if not separator or not re.fullmatch(rb"\d{3}", status):
                    raise OSError("Invalid HTTP status from curl")
                code = int(status)
                if len(data) > 32 * 1024 * 1024:
                    raise ValueError("Download exceeds 32 MiB")
                if 200 <= code < 300:
                    return data
                if code == 401:
                    raise AuthenticationError("HTTP 401: credential rejected. Use an authorized Socket GamesDB key, or run setup-card.py --scan-only")
                if code == 403:
                    raise AuthenticationError("HTTP 403: access denied by the service or its firewall. Run setup-card.py --scan-only")
                if code not in (429, 500, 502, 503, 504) or attempt == 2:
                    raise OSError(f"HTTP {code}")
        if attempt == 2:
            raise OSError("Download failed after three attempts") from None
        time.sleep(attempt + 1)


def png_bytes(data):
    with tempfile.TemporaryDirectory(prefix="socket-art-") as folder:
        source, output = Path(folder) / "image", Path(folder) / "image.png"
        source.write_bytes(data)
        try:
            subprocess.run(["sips", "-s", "format", "png", str(source), "--out", str(output)],
                           check=True, capture_output=True, timeout=30)
        except (OSError, subprocess.SubprocessError) as error:
            raise ValueError("Cannot convert artwork to PNG with macOS sips") from error
        result = output.read_bytes()
        if not result.startswith(PNG):
            raise ValueError("Artwork conversion did not produce PNG")
        return result


def cached_png(path):
    if not path.exists():
        return False
    data = path.read_bytes()
    if not data.startswith(PNG):
        return False
    try:
        png_bytes(data)
        return True
    except ValueError:
        return False


def match_info(result, name, region):
    if not isinstance(result, dict) or not result.get("matched"):
        return {}
    game = result["game"]
    if not isinstance(game, dict) or not isinstance(result.get("labels", []), list):
        raise ValueError("Invalid GamesDB game or labels")
    labels = result.get("labels", [])
    valid = [label for label in labels if isinstance(label, dict)]
    chosen = next((label for label in valid if str(label.get("region", "")).lower() == region.lower()), None)
    chosen = chosen or next((label for label in valid if str(label.get("region", "")).lower() in ("us", "en", "wor")), None)
    chosen = chosen or (valid[0] if valid else {})
    if not isinstance(chosen.get("image_url", ""), str):
        raise ValueError("Invalid GamesDB image URL")
    return {"matched": True, "method": result.get("method", ""), "game_id": game.get("id", 0),
            "name": game.get("canonical_name", name), "platform": game.get("platform_slug", ""),
            "region": chosen.get("region", ""), "texture_url": chosen.get("image_url", ""),
            "labels": labels, "meta": game.get("meta", {})}


def setup(card, *, scan_only=False, dry_run=False, api_key=None):
    card = Path(card).resolve(strict=True)
    if not safe_path(card, "System/socket").is_dir():
        raise ValueError("System/socket is missing; install Socket first")
    safe_path(card, USER_DIR)
    library_path = safe_path(card, USER_DIR / "user_data.json")
    library = read_json(library_path, {"added_platforms": []})
    if not isinstance(library, dict):
        raise ValueError("user_data.json must be a JSON object")
    platforms = library.setdefault("added_platforms", [])
    if not isinstance(platforms, list):
        raise ValueError("added_platforms must be an array")
    for platform in platforms:
        if not isinstance(platform, dict) or not isinstance(platform.get("rom_folder_path", ""), str):
            raise ValueError("Invalid platform record")
        games = platform.get("games", [])
        if not isinstance(games, list) or any(not isinstance(game, dict) for game in games):
            raise ValueError("Invalid game records")
    settings_path = safe_path(card, USER_DIR / "settings.cfg")
    settings = settings_path.read_text() if settings_path.exists() else ""
    region_match = re.search(r'^scrape_region\s*=\s*"([^"\n]*)"', settings, re.MULTILINE)
    region = region_match.group(1) if region_match else "us"
    report = {"scanned": 0, "added": 0, "cached": 0, "matched": 0, "unmatched": [], "failures": []}
    key = os.environ.get("SOCKET_API_KEY", "") if api_key is None else api_key
    network = not (scan_only or dry_run)
    if network and not key:
        raise AuthenticationError("Set an authorized SOCKET_API_KEY, or use --scan-only")
    for platform_id, slug in PLATFORMS.items():
        selected = [p for p in platforms if p.get("model_id") == platform_id]
        if not selected and safe_path(card, Path("Games") / platform_id.upper()).is_dir():
            platform = {"model_id": platform_id, "app_id": platform_id + ".ra64.mgba",
                        "rom_folder_path": "/mnt/sdcard/Games/" + platform_id.upper(), "games": [],
                        "visible": True, "background_style": "classic", "hide_duplicates": True,
                        "scan_subfolders": False, "camera_zoom": 1.0, "sort_mode": "title",
                        "launch_args_override": ""}
            platforms.append(platform)
            selected = [platform]
        for platform in selected:
            folder = platform["rom_folder_path"]
            if not folder.startswith("/mnt/sdcard/"):
                raise ValueError(f"Unsupported ROM folder: {folder}")
            rom_dir = safe_path(card, folder[len("/mnt/sdcard/"):])
            if not rom_dir.is_dir():
                report["failures"].append(f"Missing ROM folder: {folder}")
                continue
            games = platform.setdefault("games", [])
            by_path = {g.get("rom_path"): g for g in games}
            by_name = {g.get("rom_name"): g for g in games}
            paths = rom_dir.rglob("*") if platform.get("scan_subfolders") else rom_dir.iterdir()
            seen = set()
            for path in sorted(paths):
                if any(part.startswith(".") for part in path.relative_to(rom_dir).parts) or path.suffix.lower() != "." + platform_id or not path.is_file():
                    continue
                safe_path(card, path.relative_to(card))
                name = path.stem
                if name in seen:
                    report["failures"].append(f"Duplicate ROM name: {path.relative_to(card)}")
                    continue
                seen.add(name)
                report["scanned"] += 1
                device_path = "/mnt/sdcard/" + path.relative_to(card).as_posix()
                game = by_path.get(device_path) or by_name.get(name)
                if game is None:
                    game = {"rom_name": name, "rom_path": device_path, "platform_id": platform_id,
                            "added_at": int(time.time()), "is_new": True, "playtime": 0}
                    games.append(game)
                    report["added"] += 1
                else:
                    game["rom_path"] = device_path
                base = "scraped_data/" + platform_id + "/" + filename(name)
                info_path = safe_path(card, USER_DIR / (base + ".json"))
                image_path = safe_path(card, USER_DIR / (base + "_support.png"))
                try:
                    info = read_json(info_path, {})
                    if not isinstance(info, dict):
                        raise ValueError("Cached metadata must be a JSON object")
                    if network and not info:
                        digest = hashlib.md5()
                        with path.open("rb") as stream:
                            for block in iter(lambda: stream.read(1024 * 1024), b""):
                                digest.update(block)
                        query = urllib.parse.urlencode({"md5": digest.hexdigest(), "filename": name, "platform": slug})
                        info = match_info(json.loads(request(SERVICE + "/v1/match?" + query, key)), name, region)
                        if info:
                            write_json(info_path, info)
                            report["matched"] += 1
                        else:
                            report["unmatched"].append(str(path.relative_to(card)))
                    if info_path.is_file() and not game.get("game_info_path"):
                        game["game_info_path"] = "user://" + base + ".json"
                    image_valid = cached_png(image_path)
                    if network and not image_valid and info.get("texture_url"):
                        url = info["texture_url"]
                        if not isinstance(url, str):
                            raise ValueError("Cached texture_url must be a string")
                        if url.startswith("http://"):
                            url = "https://" + url[7:]
                        write_file(image_path, png_bytes(request(url, key)))
                        image_valid = True
                    if image_valid:
                        if not game.get("support_texture_path"):
                            game["support_texture_path"] = "user://" + base + "_support.png"
                        report["cached"] += 1
                    elif image_path.exists():
                        report["failures"].append(f"Invalid PNG cache: {image_path.relative_to(card)}")
                except AuthenticationError as error:
                    report["failures"].append(str(error))
                    network = False
                except (OSError, ValueError, KeyError, TypeError) as error:
                    report["failures"].append(f"{path.relative_to(card)}: {error}")
            if not dry_run:
                write_json(library_path, library)
        if not dry_run and selected:
            emulator = safe_path(card, USER_DIR / "emulators" / (platform_id + ".json"))
            if not emulator.exists():
                # This entry uses the core and launcher that are installed with BaseOS.
                write_json(emulator, [{"uniqueId": platform_id + ".ra64.mgba", "name": "RetroArch (mGBA)",
                                      "acceptedFilenameRegex": ".*\\." + platform_id + "$",
                                      "amStartArguments": "-n com.retroarch.aarch64/com.retroarch.browser.retroactivity.RetroActivityFuture -e LIBRETRO mgba -e ROM {file.path}"}])
    if not dry_run:
        for name in ("mgba_libretro.so", "gpsp_libretro.so"):
            source = safe_path(card, Path("System") / name)
            target = safe_path(card, Path("System/socket/cores") / name)
            if source.is_file() and not target.exists():
                write_file(target, source.read_bytes())
    if not safe_path(card, "System/socket/cores/mgba_libretro.so").is_file() and not safe_path(card, "System/mgba_libretro.so").is_file():
        report["failures"].append("Missing mGBA core: install System/socket/cores/mgba_libretro.so to start games")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("card", type=Path)
    parser.add_argument("--scan-only", action="store_true", help="scan and attach cached media without network access")
    parser.add_argument("--dry-run", action="store_true", help="report scan changes without writes or network access")
    args = parser.parse_args()
    try:
        report = setup(args.card, scan_only=args.scan_only, dry_run=args.dry_run)
    except (OSError, ValueError, AuthenticationError) as error:
        parser.exit(1, f"setup-card: {error}\n")
    print(json.dumps(report, indent=2))
    return bool(report["failures"])


if __name__ == "__main__":
    raise SystemExit(main())
