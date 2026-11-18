# Socket for the RG SP

<p align="center">
  <img src="docs/media/demo.webp" width="640" alt="Socket running on an RG SP: browsing the game library and starting a game">
</p>

Bring the [Socket](https://www.patreon.com/cw/SocketLauncher) game launcher
to your **Anbernic RG SP** with
[BaseOS](https://github.com/pvaibhav/BaseOS). Heavily inspired by [Slot](https://github.com/BrandonKowalski/slot).

This port is built and tested for the RG SP. Other Anbernic H700 devices may
work, but are untested. Rotated panels, such as the RG28XX, are not supported.
Only GB, GBC and GBA are supported. Other systems may work, but are untested.

> [!IMPORTANT]
> This repository contains no Socket code or assets. You'll need your own
> Socket APK. The build reads it locally on your computer and creates the card
> files. Do not share the `dist/` folder, because `socket.pck` contains
> Socket.

This project is not affiliated with or endorsed by the Socket developers.

## Requirements

- An RG SP with BaseOS on the card in slot TF1.
- A Socket APK, version 0.10.1, 0.8.0 or 0.3.2. Version 0.3.2 is the last free
  version. See [Socket versions](docs/socket-versions.md).
- A macOS or Linux computer with Docker (AArch64 Linux containers), a C
  compiler, OpenSSL libcrypto, Python 3, zstd, unzip and patch.
- An AArch64 Linux libretro core for each platform, for example
  `mgba_libretro.so`.

## Build

1. Point the build at your APK:

   ```sh
   ./build.sh ~/Downloads/socket_release_0.10.1.apk
   ```

2. Your card files will be in `dist/`.

The first build compiles Godot and RetroArch. Expect it to take a while.

## Install

1. If BaseOS is not installed, follow the [BaseOS installation
   guide](https://github.com/pvaibhav/BaseOS/blob/main/INSTALL.md) to install
   it on the card for slot TF1. Back up the card first: flashing erases it.
2. Turn off your RG SP and put its BaseOS card in your computer.
3. If the card has another frontend, back up its
   `System/launch_frontend.sh`. The next step will overwrite it.
4. Copy the contents of `dist/` to the root of the card.
5. Copy your libretro cores to `System/socket/cores/`.
6. Put your games in `Games/GB`, `Games/GBC` and `Games/GBA`. Create each
   folder that you plan to use, even if it is empty.
7. Prepare the library on a Mac before the first boot. See [Prepare the
   library](#prepare-the-library-macos-only).
8. Eject the card. Put it in slot TF1 and turn on the RG SP.

Prepare the emulator lists on your computer before the first boot. Socket can
download artwork on a Wi-Fi-capable RG SP. You can also prepare the artwork on
your computer and use the device offline.

After this setup, you can scan new ROMs for the prepared platforms on the
RG SP with Socket's platform editor. Pick a ROM folder and a RetroArch
emulator, then select **Scan**.
Socket shows only emulators that have a core in `System/socket/cores/`.
An on-device scan loads cached media and downloads missing artwork when Wi-Fi is connected.

## Connect to Wi-Fi and enable RetroAchievements

1. In Socket, press **MENU**. Open **Wi-Fi**, choose your network
   or enter its name, type its password with the controller, then select **Join**.
   Socket saves one WPA2-Personal network. The network must supply an address
   through DHCP. You can also copy `Config/wifi.txt.example` to
   `Config/wifi.txt` on the card and enter the name and password there.
2. Wait for the Wi-Fi indicator. Open the platform editor,
   select a ROM folder, and choose **Scan**. Test with a game that has no cover.
   A downloaded cover stays on the card for offline use.
3. For in-game achievements, copy `Config/retroachievements.txt.example` to
   `Config/retroachievements.txt`. Fill in your RetroAchievements `username`
   and `password`. Launch a supported GB, GBC or GBA game with **mGBA** while
   connected. The first successful sign-in replaces the password with a login
   token. If the token expires, replace the file with a fresh copy of the
   example and enter your credentials again.
4. For progress and badges in Socket's achievement panel, enter your username
   and RetroAchievements **Web API key** in the panel. The gameplay login token
   and the Web API key have different purposes.

Achievements use softcore mode so rewind, save states and resume work. An
offline launch still starts the game. Relaunch it after Wi-Fi connects to
start an achievement session. Reconnect before quitting if the connection
drops during a session. Remove `Config/retroachievements.txt` to disable
gameplay achievements. To remove the saved Wi-Fi credentials, use **Forget**
in Device Settings. Treat the card and its backups as private because they
can contain Wi-Fi and account credentials.

## Prepare the library (macOS only)

`tools/setup-card.py` adds the GB, GBC and GBA platforms for the `Games/`
folders. It scans unpacked `.gb`, `.gbc` and `.gba` files. If the card has
Slot's mGBA or gpSP core in `System/`, the tool copies it to
`System/socket/cores/`.
Run this preparation before the first boot. When you add more games, scan
on the RG SP over Wi-Fi or run the tool again on your computer.

Missing metadata or artwork does not hide games from the homescreen.
Socket uses the ROM file name without its extension when metadata is missing and
shows a cartridge without downloaded artwork. The library and emulator
records must still be on the card.

1. Turn off the RG SP. Mount its card on the Mac.
2. Preview the changes without writing anything:

   ```sh
   python3 tools/setup-card.py --dry-run /Volumes/BASEOS
   ```

3. Prepare the library, metadata and artwork with your own Socket APK:

   ```sh
   python3 tools/setup-card-from-apk.py ~/Downloads/socket_release_0.10.1.apk /Volumes/BASEOS
   ```

   You can also explicitly set `SOCKET_API_KEY` to an authorized Socket GamesDB key
   (this is specific to Socket, not a standard GamesDB key), then run:

   ```sh
   python3 tools/setup-card.py /Volumes/BASEOS
   ```

   If you want to avoid scraping, prepare the library without downloads.
   This command needs no API key or network access. After you run it, games
   without cached metadata or artwork will still appear on the homescreen:

   ```sh
   python3 tools/setup-card.py --scan-only /Volumes/BASEOS
   ```

4. Check the report before you eject the card. Confirm that `scanned`
   includes your games and resolve entries in `failures`. Entries in
   `unmatched` have no service match. These games still appear without
   downloaded media.

Before replacing a file, the tool backs it up as `<file>.bak-<time>`. To
restore a file, copy its backup over it. To pick up interrupted downloads,
run the command again. Downloads need `curl` 8.4 or later.

## Controls

| Control | Action |
|---------|--------|
| Volume buttons | Change the volume in steps of 5. Socket and games use the same level. |
| SELECT + Up or Down | Change the brightness. |
| SELECT + Left or Right | Change the screen temperature. Right makes the screen warmer. |
| POWER, or close the lid | Sleep. In a game, the device first saves a resume state. |
| Hold POWER for 1 second | Shut down. In a game, the device first saves a resume state. |
| Tap MENU | Open or close Device Settings. In a game, choose **Game** for emulator controls or **Cheats** for cheat codes. |
| Hold MENU for 1 second (in a game) | Save a state and go back to Socket. |
| Hold L2 or R2 (in a game) | Rewind or fast-forward. |

### File dialogs

Music, artwork and native folder dialogs use native-resolution text and fit the
screen independently of Socket's UI scale, including nested confirmations.
They support the controller:

- Up/Down moves through files; confirm opens a folder or file.
- Left goes to **Cancel**; Right goes to **Open/Select** when a selection is valid.
- Up/Down from those buttons returns to the file list.
- L1/R1 moves between all controls, including filters and path fields.
- Y goes to the parent folder; X marks/unmarks files in the music picker.
- Cancel closes the topmost dialog and restores the previous focus.

The ROM/save-folder picker also has **Save this folder** and **Cancel** as
its first two entries; Left goes to the parent folder. Face-button actions
follow Socket's configured controller layout.

After three minutes of sleep, the device shuts down. After a shutdown in a
game, Socket opens that game again at the next start. For the details, see
[Controls, sleep and power](docs/controls.md).

## Troubleshooting

Look in the card's `Logs` folder:

- `socket.log`: Socket
- `socket-game.log`: RetroArch and game start
- `socket-hardware.log`: buttons, sleep and power

If the build stops at `patch-socket`, your APK uses an unsupported Socket
version.

## More information

See [docs](docs/README.md) for how the port works, RetroArch settings,
rendering changes and development.

## License

This project uses the GNU General Public License, version 3 or later. See
[LICENSE](LICENSE). It contains code from Godot, RetroArch, Slot and Nerd
Fonts. See [Licenses](docs/licenses.md).

Socket is not covered by this license.
