# Setup and reference

## Requirements

- An RG SP with BaseOS on the card in slot TF1.
- A Socket APK, version 0.10.1, 0.8.0 or 0.3.2. Version 0.3.2 is the last free
  version. See [Socket versions](socket-versions.md).
- A desktop browser for the [web installer](web-converter.md). It supplies the RG SP engine, RetroArch and the mGBA core for GB, GBC and GBA. You supply your own games.
- **Manual build only:** macOS or Linux with Docker (AArch64 Linux containers), a C compiler, OpenSSL libcrypto, Python 3, zstd, unzip and patch. The manual `build.sh` path still requires an AArch64 libretro core.

## Build

For a first install, use the [browser installer](web-converter.md) and skip to **Install** below. You do not need a compiler, an existing Socket card, or a separate core download.

To build the port manually instead:

1. Point the build at your APK:

   ```sh
   ./build.sh ~/Downloads/socket_release_0.10.1.apk
   ```

2. Your card files will be in `dist/`.

The first build compiles Godot and RetroArch. Expect it to take a while.

## Install

1. If BaseOS is not installed, follow the [BaseOS installation
   guide](https://github.com/pvaibhav/BaseOS/wiki/BaseOS-Install-Guide) to install
   it on the card for slot TF1. Back up the card first: flashing erases it.
2. Turn off the RG SP and mount the visible `BASEOS` volume (or a dedicated frontend card). Use one frontend per card. Back up an existing card first: `System/launch_frontend.sh` will be replaced, and a different frontend's `System/frontend` binary takes priority over that script.
3. Unzip `socket-baseos.zip` on your computer. **Copy the extracted contents to the card root**, merging directories rather than replacing or deleting them. Check that `System/launch_frontend.sh` is directly under the root, not inside a `socket-baseos/` folder. Do not copy the unopened ZIP or reflash the card.
4. Add your own unpacked `.gb`, `.gbc` and `.gba` games in `Games/GB/`, `Games/GBC/` and `Games/GBA/`. The ZIP already includes mGBA; no core or BIOS download is needed for normal play. **Manual build only:** copy the contents of `dist/` instead of the ZIP and supply `System/socket/cores/mgba_libretro.so` yourself.
5. Eject the card, put it back in the RG SP and power on. On a fresh card the launcher prepares the platform and emulator entries. Select **Scan** in each platform's editor to find your games; Wi-Fi and a Mac are not required. Existing libraries are not reset.

To add more games later, copy the ROMs and scan again. Socket shows only emulators that have a core in `System/socket/cores/`.
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
3. In the launcher or during a game, open **MENU → Emulation → Set username and password**.
   Enter your RetroAchievements login and choose **Save account**. Check that
   **RetroAchievements** is **On**. Launch a supported GB, GBC or GBA game
   with **mGBA**, or close Device Settings to apply the change to the game
   already running. You don't need to restart the game. The first successful
   sign-in replaces the password on the card with a token.
   To switch accounts or replace an expired token, use the same form. Manual
   setup via `Config/retroachievements.txt.example` is still supported.
4. For progress and badges in Socket's achievement panel, enter your username
   and RetroAchievements **Web API key** in the panel. The gameplay login token
   and the Web API key have different purposes.

Achievements use softcore mode so rewind, save states and resume work. An
offline launch still starts the game. Once Wi-Fi connects, open and close
Device Settings to retry sign-in without losing your place. If the connection
drops, reconnect before quitting, switching accounts or turning achievements
off: unlocks not yet confirmed by the service can be lost. Switching
**RetroAchievements** off keeps the saved login. To remove the saved Wi-Fi
credentials, use **Forget** in Device Settings. Treat the card and its backups as private because they
can contain Wi-Fi and account credentials.

Set rewind separately for GB, GBC and GBA in **MENU → Emulation** in the
launcher. During a game, **MENU → Game → Gameplay → Rewind** applies immediately
and saves the preference for the current platform.

## Prepare the library (macOS only)

`tools/setup-card.py` adds the GB, GBC and GBA platforms for the `Games/`
folders. It scans unpacked `.gb`, `.gbc` and `.gba` files. If a core is missing from `System/socket/cores/`, the tool copies Slot's
mGBA or gpSP core from `System/` when available. It keeps an installed core.
This is optional desktop preparation for scanning or fetching artwork, not a first-boot prerequisite. When you add more games, scan on the RG SP or run the tool again on your computer.

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
[Controls, sleep and power](controls.md).

## Troubleshooting

Look in the card's `Logs` folder:

- `socket.log`: Socket
- `socket-game.log`: RetroArch and game start
- `socket-hardware.log`: buttons, sleep and power

If the build stops at `patch-socket`, your APK uses an unsupported Socket
version.

## Contributor setup

Install [Gitleaks](https://github.com/gitleaks/gitleaks) v8.30 or newer
(`brew install gitleaks` on macOS), then enable the tracked Git hooks once per clone:

```sh
git config --local core.hooksPath .githooks
```

The pre-commit hook scans staged changes, not unstaged files or commit history.
It blocks the commit on a finding or scanner error and redacts secrets in its output.
