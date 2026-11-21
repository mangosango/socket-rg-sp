# Socket for the RG SP

Flip through a shelf of Game Boy, Game Boy Color and Game Boy Advance cartridges on your Anbernic RG SP. Pick a game and play. Close the lid mid-dungeon and pick up where you left off.

<p align="center">
  <img src="docs/media/demo.webp" width="640" alt="Browsing the cartridge library in Socket and launching a game on the RG SP">
</p>

> [!IMPORTANT]
> **Bring your own [Socket APK](https://www.patreon.com/cw/SocketLauncher).** This repository includes no Socket code, assets or games. The installer converts your APK on your computer. Don’t share the resulting ZIP: it contains Socket assets and may also contain your credentials.

**[Open the browser installer](https://mangosango.github.io/socket-rg-sp/)** · [Install guide](docs/web-converter.md) · [Controls](docs/controls.md)

Play offline, or connect to Wi-Fi to download cover art and earn RetroAchievements in supported games. Hold **L2** to rewind when enabled, **R2** to fast-forward, or **MENU** for a second to save your place and return to the shelf.

## Get playing

1. **Prepare your card.** Back it up first: flashing [BaseOS](https://github.com/pvaibhav/BaseOS/wiki/BaseOS-Install-Guide) erases it. Use BaseOS in slot TF1 and one frontend per card.
2. **Make your install ZIP.** Open the installer in a desktop browser and drop in your APK ([supported versions](docs/socket-versions.md): 0.10.1, 0.8.0 and 0.3.2). The ZIP includes the mGBA emulator.
3. **Copy, don’t flash.** Extract `socket-baseos.zip` and merge its contents into the root of the `BASEOS` volume. Add your own unpacked games to `Games/GB/`, `Games/GBC/` or `Games/GBA/`.
4. **Find your cartridges.** Eject the card, boot the RG SP and choose **Scan** in each platform’s editor. No account or Wi-Fi needed.

[Setup & troubleshooting](docs/setup.md) · [Port documentation](docs/README.md) · [License](LICENSE) · [Credits](docs/licenses.md)

An unofficial port inspired by [Slot](https://github.com/BrandonKowalski/slot), not affiliated with the Socket developers. The project’s GPL license does not cover Socket.
