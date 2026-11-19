# Licenses

This project uses the GNU General Public License, version 3 or later. See
[LICENSE](../LICENSE).

This port includes or patches code from these projects:

| Project | License | Files |
|---------|---------|-------|
| [Godot Engine](https://godotengine.org) | MIT | `engine/godot-fbdev.patch` and the fbdev display server, which builds against Godot 4.7.1. See `engine/GODOT-LICENSE.txt`. |
| [RetroArch](https://github.com/libretro/RetroArch) | GPL-3.0-or-later | `tools/retroarch-*.patch` and the headers that they add. |
| [mGBA](https://mgba.io/) | MPL-2.0 with separately licensed components | The AArch64 `mgba_libretro.so` built for GB/GBC/GBA. The downloadable card runtime carries license notices; its corresponding source is available alongside it on Pages. |
| [Slot](https://github.com/BrandonKowalski/slot) | GPL-3.0-or-later | The LCD3x and grid shader in `card/System/socket/retroarch/shaders`. See its `NOTICE.txt`. |
| [Nerd Fonts](https://www.nerdfonts.com) symbols | MIT | The control icons in `overlay/addons/FrontendPlugin/controls` and `tools/retroarch-control-icons.h`. See `controls/LICENSE.txt`. |

Socket is not covered by this license. Its code and assets remain under the
terms set by its developers. This repository contains no Socket code or
assets.
