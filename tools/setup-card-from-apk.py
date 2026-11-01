"""Prepare a mounted card library and artwork with a local Socket APK.

Needs the build dependencies: cc, OpenSSL libcrypto, and zstd. Downloads
need curl 8.4 or later. Artwork conversion needs macOS sips.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import zipfile

TOOLS = Path(__file__).resolve().parent
SCRAPER = "scripts/models/scrapers/scraper_games_db.gdc"


SPEC = importlib.util.spec_from_file_location("setup_card", TOOLS / "setup-card.py")
setup_card = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(setup_card)


def run(command):
    # Subprocess output can contain credentials or decoded source.
    return subprocess.run(command, check=True, capture_output=True, timeout=120).stdout


def setup_from_apk(apk, card):
    card = Path(card).resolve(strict=True)
    if not (card / "System/socket").is_dir():
        raise ValueError("System/socket is missing; install Socket first")
    with tempfile.TemporaryDirectory(prefix="socket-apk-") as folder:
        root = Path(folder)
        with zipfile.ZipFile(apk) as archive:
            for name in ("lib/arm64-v8a/libgodot_android.so", "assets/project.binary", "assets/" + SCRAPER):
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(name) as source, target.open("wb") as output:
                    # Read to EOF so zipfile checks the CRC.
                    shutil.copyfileobj(source, output)
        try:
            flags = shlex.split(run(["pkg-config", "--cflags", "--libs", "libcrypto"]).decode())
        except (OSError, subprocess.SubprocessError):
            prefix = run(["brew", "--prefix", "openssl"]).decode().strip()
            flags = ["-I" + prefix + "/include", "-L" + prefix + "/lib", "-lcrypto"]
        unpack = str(root / "godot-unpack")
        run(["cc", "-O2", "-o", unpack, str(TOOLS / "godot-unpack.c"), *flags])
        run([unpack, "extract", str(root / "lib/arm64-v8a/libgodot_android.so"),
             str(root / "assets"), str(root / "res")])
        decoded = root / "scraper.gd"
        run([sys.executable, "-I", str(TOOLS / "gdc2gd.py"), str(root / "res" / SCRAPER), str(decoded)])
        matches = re.findall(r'^@export var api_key: String = ("(?:[^"\\\n]|\\.)*")\s*$',
                             decoded.read_text(), re.MULTILINE)
        if len(matches) != 1:
            raise ValueError("Cannot find one Socket GamesDB key in this APK")
        credential = json.loads(matches[0])
        if not credential or any(ord(char) < 32 or ord(char) == 127 for char in credential):
            raise ValueError("The APK has no valid Socket GamesDB key")
        return setup_card.setup(card, api_key=credential)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("card", type=Path)
    args = parser.parse_args()
    try:
        report = setup_from_apk(args.apk, args.card)
    except subprocess.SubprocessError:
        parser.exit(1, "setup-card-from-apk: APK extraction failed. Check the APK and required build tools.\n")
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, RuntimeError,
            setup_card.AuthenticationError) as error:
        parser.exit(1, f"setup-card-from-apk: {error}\n")
    print(json.dumps(report, indent=2))
    return bool(report["failures"])


if __name__ == "__main__":
    raise SystemExit(main())
