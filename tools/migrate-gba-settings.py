#!/usr/bin/env python3
"""Plan the one-time GBA move from gpSP to mGBA on a Socket card.

Usage:
  tools/migrate-gba-settings.py CARD --plan DIR      write DIR/plan.json and DIR/staged/
  tools/migrate-gba-settings.py CARD --apply DIR     apply a plan; backup goes to work/

The plan does these operations. Each one has the sha256 before and after.
- edit: user_data.json, the GBA app_id "gba.ra64.gpsp" becomes "gba.ra64.mgba".
  No other byte changes.
- edit: gpsp-gba-options.cfg, gpsp_frameskip becomes "auto". This applies if
  gpSP is selected again.
- copy: each gpSP in-game save (.srm) that has data goes to Saves/retroarch/mGBA
  at the size that mGBA uses for that cartridge (from the ROM save-type ID).
  Bytes past that size must all be 0xFF. The gpSP .srm files stay.
- move: the gpSP test save states (.state*) and Saves/socket/resume-game.attempt
  go to the backup. They are not deleted. Sang authorized this.

The script refuses when:
- a live Saves/socket/resume-game exists;
- an mGBA save already exists for a game it would copy;
- the GBA app_id does not occur exactly once;
- a save type cannot be found;
- data would be cut off.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import time

USER_DATA = Path("Saves/socket/godot/app_userdata/Socket/user_data.json")
GPSP_OPTIONS = Path("Saves/socket/retroarch/gpsp-gba-options.cfg")
GPSP = Path("Saves/retroarch/gpSP")
MGBA = Path("Saves/retroarch/mGBA")
GAMES = Path("Games/GBA")
RESUME = Path("Saves/socket/resume-game")
RESUME_ATTEMPT = Path("Saves/socket/resume-game.attempt")
SAVE_IDS = ((b"FLASH1M_V", 131072), (b"FLASH512_V", 65536), (b"FLASH_V", 65536),
            (b"SRAM_F_V", 32768), (b"SRAM_V", 32768), (b"EEPROM_V", None))


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def mgba_size(rom, save):
    """Return the save size that mGBA uses for this cartridge, or None."""
    for marker, size in SAVE_IDS:
        if re.search(re.escape(marker) + rb"\d{3}", rom):
            if size is None:
                # 4 Kbit or 64 Kbit EEPROM. Data past 512 bytes needs the large chip.
                size = 8192 if save[512:8192].strip(b"\xff") else 512
            return size
    return None


def plan(card):
    """Return a list of operations. Each one has path, action, before, after, and data."""
    if (card / RESUME).exists():
        raise SystemExit(f"Refused: {RESUME} exists. Resume or finish that game first.")
    operations = []
    old = (card / USER_DATA).read_bytes()
    if old.count(b'"gba.ra64.gpsp"') != 1:
        raise SystemExit(f"Refused: expected one \"gba.ra64.gpsp\" in {USER_DATA}")
    new = old.replace(b'"gba.ra64.gpsp"', b'"gba.ra64.mgba"')
    json.loads(new.decode("utf-8"))
    operations.append(dict(path=str(USER_DATA), action="edit", data=new))
    if (card / GPSP_OPTIONS).is_file():
        old = (card / GPSP_OPTIONS).read_bytes()
        new = re.sub(rb'(?m)^[ \t]*gpsp_frameskip[ \t]*=.*$', b'gpsp_frameskip = "auto"', old)
        if new != old:
            operations.append(dict(path=str(GPSP_OPTIONS), action="edit", data=new))
    for path in sorted((card / GPSP).glob("*")):
        if path.name.startswith("._") or not path.is_file():
            continue
        if ".state" in path.name:
            operations.append(dict(path=str(GPSP / path.name), action="move"))
            continue
        if not path.name.endswith(".srm"):
            continue
        save = path.read_bytes()
        if not save.strip(b"\xff"):
            continue  # No in-game save.
        game = path.name[:-len(".srm")]
        rom = card / GAMES / (game + ".gba")
        size = mgba_size(rom.read_bytes(), save) if rom.is_file() else None
        if size is None:
            raise SystemExit(f"Refused: no save type for {game}")
        if save[size:].strip(b"\xff"):
            raise SystemExit(f"Refused: {game} has data past {size} bytes")
        target = MGBA / path.name
        if (card / target).exists():
            raise SystemExit(f"Refused: {target} exists")
        operations.append(dict(path=str(target), action="copy", source=str(GPSP / path.name), data=save[:size]))
    if (card / RESUME_ATTEMPT).exists():
        operations.append(dict(path=str(RESUME_ATTEMPT), action="move"))
    for operation in operations:
        current = card / operation["path"]
        operation["before"] = sha256(current.read_bytes()) if current.exists() else None
        operation["after"] = sha256(operation["data"]) if "data" in operation else None
    return operations


def write_plan(card, directory):
    operations = plan(card)
    directory.mkdir(parents=True, exist_ok=False)
    for operation in operations:
        if "data" in operation:
            staged = directory / "staged" / operation["path"]
            staged.parent.mkdir(parents=True, exist_ok=True)
            staged.write_bytes(operation.pop("data"))
            operation["staged"] = str(staged.relative_to(directory))
    (directory / "plan.json").write_text(json.dumps(operations, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    return operations


def fsync_dir(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    except OSError:
        pass
    finally:
        os.close(descriptor)


def apply_plan(card, directory, backup):
    """Check every before hash, back up every touched file, then apply."""
    operations = json.loads((directory / "plan.json").read_text(encoding="utf-8"))
    if (card / RESUME).exists():
        raise SystemExit(f"Refused: {RESUME} exists")
    for operation in operations:
        current = card / operation["path"]
        if (sha256(current.read_bytes()) if current.exists() else None) != operation["before"]:
            raise SystemExit("Changed since the plan: " + operation["path"])
        if "staged" in operation and sha256((directory / operation["staged"]).read_bytes()) != operation["after"]:
            raise SystemExit("Changed staged file: " + operation["staged"])
    backup.mkdir(parents=True, exist_ok=False)
    for operation in operations:
        current = card / operation["path"]
        if current.exists():
            saved = backup / operation["path"]
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(current, saved)
            if sha256(saved.read_bytes()) != operation["before"]:
                raise SystemExit("Backup check failed: " + str(saved))
    (backup / "plan.json").write_text(json.dumps(operations, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    for operation in operations:
        current = card / operation["path"]
        if operation["action"] == "move":
            current.unlink()  # The checked copy is in the backup.
        else:
            current.parent.mkdir(parents=True, exist_ok=True)
            temporary = current.with_name(current.name + ".tmp")
            with open(temporary, "xb") as file:
                file.write((directory / operation["staged"]).read_bytes())
                file.flush()
                os.fsync(file.fileno())
            if operation["action"] == "copy" and current.exists():
                temporary.unlink()
                raise SystemExit("Refused to overwrite " + operation["path"])
            os.replace(temporary, current)
        fsync_dir(current.parent)
    print(f"Applied {len(operations)} operations. Backup: {backup}. Eject the card before you remove it.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("card", type=Path)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--plan", type=Path)
    action.add_argument("--apply", type=Path)
    parser.add_argument("--backup", type=Path,
        default=Path(__file__).resolve().parents[1] / "work" / f"card-backup-gba-{time.time_ns()}")
    args = parser.parse_args()
    card = args.card.resolve()
    if args.plan:
        for operation in write_plan(card, args.plan):
            print(f'{operation["action"]:5} {operation["path"]}  {operation["before"] or "-"} -> {operation["after"] or "-"}')
    else:
        apply_plan(card, args.apply, args.backup)


if __name__ == "__main__":
    main()
