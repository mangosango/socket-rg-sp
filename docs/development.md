# Development

## Build individual parts

```sh
sh engine/build-engine.sh                  # Godot template: work/godot/bin/
sh tools/build-retroarch.sh                # RetroArch: work/RetroArch/retroarch
sh tools/build-pack.sh socket.apk out.pck  # Socket data
```

The engine and RetroArch build in an AArch64 Debian Bullseye container
(`engine/Dockerfile`), using glibc 2.31, just like Slot.

## Change the Socket patch

`tools/patch-socket.py` keeps the edits in one list. Each entry has a file,
a regular expression, a replacement, a match count and optional Socket
versions. When changing it:

- Do not add Socket source to this repository. Use function names, Godot API
  calls and short checks as anchors.
- To move Socket lines, capture them with the pattern. Do not write them in
  the replacement.
- Set the version for an edit that applies to one Socket version only.
- Make sure that the patched output of the other versions does not change.

## Tests

Run the Python tests:

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
```

Some RetroArch tests need a RetroArch build and an environment variable, for
example `RETROARCH_MENU_SMOKE=1`. Those tests skip when the requirements are
missing.

Run the Godot tests with a pack:

```sh
GODOT=/path/to/godot sh tests/app/run.sh                                    # bridge and controls
GODOT=/path/to/godot sh tests/app/run.sh out.pck                            # also checks a 0.8.0 pack
GODOT=/path/to/godot sh tests/app/run_packed.sh out.pck                     # 0.8.0
GODOT=/path/to/godot sh tests/app/run_packed.sh out.pck test_packed_032.gd  # 0.3.2
```

`run.sh` needs a desktop Godot build. With a pack, it also runs
`tests/app/test_pack.py`, which checks the patched sources of a 0.8.0 pack.
`run_packed.sh` needs a Godot 4.7.1 template. To use the AArch64 template
from `engine/build-engine.sh`, run it in the `socket-baseos-godot` Docker
image with the work folders mounted.

## Tools

| Tool | Use |
|------|-----|
| `tools/setup-card.py` | Adds platforms and media to the card library. See the main README. |
| `tools/seed-library.py` | Older setup tool. It stores the Daijishou emulator lists and adds GB, GBC and GBA platforms. |
| `tools/migrate-gba-settings.py` | Plans and applies the one-time GBA move from gpSP to mGBA on a card. |
| `tools/build-pacing-probe.sh`, `tools/pacing-probe.c` | Build a library that records RetroArch frame and audio timing on the device. |
| `tools/pacing-report.py` | Summarizes a pacing log. |

## Device checks

These still need more testing on the RG SP:

- Display and audio recovery after many game starts and sleep cycles.
- Lid countdown, wake cancellation and the save before shutdown.
- The udev button numbers in `retroarch.cfg`.
- The GPU cost of the tonemap pass and the edge filter.
- GBA frame pacing.
- The frame rate of 0.3.2 with the 720x480 UI.

Rotated panels, such as the RG28XX, do not work.
