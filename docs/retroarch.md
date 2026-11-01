# RetroArch

The port builds RetroArch for BaseOS with Mali fbdev GLES, ALSA audio and
udev gamepad input. The patches in `tools/retroarch-*.patch` add the game
menu, the controls overlay, sleep and the MENU hold actions.

## Game menu

- Tap MENU to open the game menu. You'll find Resume, core options, save and
  load states, screenshots, Screen settings, Gameplay settings, control
  hints and Save & Exit.
- Hold MENU for one second to save an automatic state and go back to Socket.
  The next launch with the same core loads that state. If the save fails,
  the game stays open and shows a warning.
- Hold L2 to rewind. Hold R2 to fast-forward. Rewind needs core support.
- RetroArch hides the usual startup messages, content load banner and sleep
  resume message. Save, load and resume failures still appear.
- RetroArch writes in-game save memory to the card every 10 seconds. States
  are separate.

The menu leaves out Slot's advanced features, such as bezels, blue light
filter settings and button remapping.

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
- Rewind records every second frame, as in Slot.
- Video stays synchronized without a queued render thread.
- Fast-forward speed changes with the game and the core.

## Not included

- The separate X and Y turbo buttons of Slot.
- Link multiplayer.
- Slot save files. RetroArch keeps its own saves and states.
