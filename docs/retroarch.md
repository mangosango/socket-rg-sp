# RetroArch

The port builds RetroArch for BaseOS with Mali fbdev GLES, ALSA audio and
udev gamepad input. The patches in `tools/retroarch-*.patch` add the game
menu, the controls overlay, sleep and the MENU hold actions.

## Game menu

- Tap MENU to pause the game and open **Device Settings**. Tap MENU again
  to resume. Socket renders the same panel used in the launcher, with its
  active theme, brightness and volume controls, Wi-Fi keyboard and Bluetooth
  pairing prompts. RetroArch shows it over the paused game and forwards pad
  input. If the launcher is unavailable, RetroArch opens its built-in panel.
- Open **Game** for core options, save and load states, screenshots, Screen
  settings, Gameplay settings, controls and Save & Exit. Select **Cheats**
  on the first page to manage codes for the current game. These pages use
  the Device Settings panel, including its font, selection outline and
  controller hints. Long lists scroll with the selection. B goes back one
  page. RetroArch applies the selected options and codes.
- During play, hold MENU for one second to save an automatic state and go back to Socket.
  The next launch with the same core loads that state. If the save fails,
  the game stays open and shows a warning.
- Hold L2 to rewind. Hold R2 to fast-forward. Rewind needs core support.
- RetroArch hides the usual startup messages, content load banner and sleep
  resume message. Save, load and resume failures still appear.
- RetroArch writes in-game save memory to the card every 10 seconds. States
  are separate.

Socket and RetroArch negotiate shared subpages at game start. With protocol
version 2, RetroArch sends the title, status, selection and up to six visible
rows when they change. Socket acknowledges the update in the frame it draws.
If either component supports only version 1, RetroArch draws its own subpages.

The menu leaves out Slot's advanced features, such as bezels, blue light
filter settings and button remapping.

## Cheats

1. During play, tap **MENU** and open **Cheats**. Connect to Wi-Fi from Device
   Settings if you need to download files.
2. For GB, GBC or GBA, select **Download cheats for this game**. If the ROM
   has a different name, select **Choose a title in the libretro list** and
   pick the matching game and region. The files come from the
   [libretro cheat database](https://github.com/libretro/libretro-database/tree/master/cht).
3. Open **Cheat files** and select a file. Its codes start disabled. Select a code
   to turn it on or off, then tap **MENU** to return to the game. RetroArch
   saves the selection for the next launch with the same core.

Downloaded files work offline. You can also copy a `.cht` file into the
matching folder under `Saves/socket/cheats`, such as
`Nintendo - Game Boy Advance`.

## GB, GBC and GBA profiles

The profiles copy Slot's settings: color correction, automatic GB palettes,
rewind, and 4x fast-forward with sound.

- GBA uses the LCD3x shader calculations of Slot. GB and GBC use its grid
  calculations. The effects render at the panel resolution.
- The profiles apply to mGBA, and to gpSP for GBA.
- The profiles use the native aspect ratio of the core. They do not copy the
  decorative bezel, the padded screen layout or the final display color of
  Slot.
- These are copied profiles, so later Slot changes won't update RetroArch.

## Saved settings

- Each launch copies the core options to RAM.
- The game menu saves core options and its settings in
  `Saves/socket/retroarch`. Settings are saved per platform. Core options
  also use the core name.
- Boot settings for one ROM take priority over the saved options.
- The installed profile files stay untouched.

## Frame skip, rewind and video

- The default frame skip for mGBA and gpSP is `auto`, as in Slot. RetroArch
  skips a frame only when the audio buffer is nearly empty. Slot skips
  frames only during fast-forward.
- Saved core options keep their frame skip value.
- The DMG Game Boy profile does not skip frames.
- Rewind records every second frame, as in Slot. With an achievement account and Wi-Fi ready, mGBA defaults to every twelfth frame: snapshots include achievement progress. Unlock checks still run every frame; only rewind is coarser.
- Video stays synchronized without a queued render thread.
- Fast-forward speed changes with the game and the core.

## Not included

- The separate X and Y turbo buttons of Slot.
- Link multiplayer.
- Slot save files. RetroArch keeps its own saves and states.
