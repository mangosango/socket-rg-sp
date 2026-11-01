# Controls, sleep and power

In Socket, the RG SP buttons work as labeled. For the game menu and
RetroArch buttons, see [RetroArch](retroarch.md).

## Volume

- Socket and RetroArch share one volume level, controlled by the volume
  buttons. It runs from 0 to 100 in steps of 5 and starts at 40.
- The level carries over when you switch between Socket and a game.
- The gain follows Slot's squared volume curve. At 0, sound is muted.
- Hold a button to repeat the change. The first repeat is after 400 ms, then
  each 120 ms.
- UI sounds use the same gain. The UI sound switch in Socket still mutes
  them.
- When you go back from a game, Socket uses the new level. It won't show a
  stale volume or brightness bar.
- Speakers and headphones use the same level. Slot's mute chord and separate
  headphone level aren't available.

## Brightness and screen temperature

- SELECT + Up or Down changes the brightness by one of 10 levels for each
  press.
- SELECT + Left or Right changes the screen temperature by one of 10 steps
  for each press. Step 0 is neutral. Right makes the screen warmer.
- Screen temperature works like Slot's blue light filter. It multiplies each
  color channel by a gain, to a maximum of 1.0, 0.82 and 0.62.
- Socket and RetroArch apply the temperature to the full frame, the overlay
  included.
- Volume, brightness and temperature show Slot's icon and bar at the top of
  the screen for 1.5 seconds. The bar fades in the last 250 ms.

## Saved values

The helper saves volume, brightness and temperature to
`Saves/socket/controls.cfg`. It saves one second after the last change, and
before sleep and shutdown. These values carry over between starts. The
helper ignores an invalid file.

## Sleep

- Press POWER to sleep. Close the lid to sleep immediately, as in Slot.
  There's no 30-second lid delay.
- In a game, the device first saves a resume state named `.state.sleep`.
  This leaves the numbered slots and Save & Exit's `.auto` state alone.
- Then the device pauses the app and turns off the screen. The game stays
  silent from the sleep request until wake.
- Open the lid or press POWER to wake. Wake picks up the game in RAM without
  loading a file.
- A short release of POWER does not start sleep again. If you hold POWER for
  one second, the device requests a shutdown.
- The lid must open before it can start sleep again.
- If the sleep save fails, the app still pauses with the screen off. Wake
  continues the game in RAM, but a dead battery can lose your progress.
- The RG SP uses screen-off sleep, so the lid can wake it. This uses more
  battery than kernel suspend. Devices without a hall sensor use kernel
  suspend. They cannot use the shutdown timer without kernel RTC wake
  support.

## Shutdown

- Hold POWER for one second to request a shutdown. In a game, the device
  first saves the `.state.sleep` resume state.
- After three minutes of sleep, the device requests a shutdown. This matches
  Slot's default timer. POWER sleep uses the same timer.
- If no game is running, the helper turns off the device with Socket still
  paused, as Slot does.
- If a game is running, the helper continues the game to save its resume
  state. If the save fails, the device stays asleep and tries again after
  five seconds. Unlike Slot, the port requires a successful save before it
  turns off a game. If writes to the card always fail, the battery can drain
  during sleep.
- After a successful save, you cannot cancel the shutdown. The screen stays
  off, the sound stays muted and the device ignores wake input. Socket stops
  without a frame.
- If the device is still on after 60 seconds, the helper turns it off. It
  tries again every 10 seconds.
- The power-off sequence syncs the card, unloads the 8821cs WiFi driver (5
  seconds maximum), syncs again and runs `poweroff`, as Slot does. This
  driver can block `poweroff`.
- Lid sleep waits while a shutdown request is pending, so it cannot pause a
  save.

## Resume after a shutdown

- On the next boot, Socket loads first, then opens the game and loads its
  resume state. The usual `.auto` load is disabled for that start.
- Socket stays muted until the game starts. The resumed session does not add
  play time.
- When you leave the resumed game, Socket returns as quickly as after a
  normal game.
- If the restore fails, the game stays paused with an Exit option. Your
  usual save slots stay untouched. Select Exit before you close the device,
  because that session cannot save for an automatic shutdown and tries again
  during sleep.
- The device tries each resume record only once, so a bad state cannot cause
  a boot loop.
- The record is in `Saves/socket/resume-game`. The last record that the
  device tried is in `resume-game.attempt`. A successful wake and a normal
  game exit remove the pending record.
- After a successful shutdown save, the record stays until power-off. It
  also stays if the emulator exits with an error.
- Do not replace a ROM or core that has a pending resume record. The record
  checks paths, not ROM or core hashes.
- A sudden battery loss during a game can't create a new state. The resume
  state protects sleep and requested shutdowns only.

## Controls helper

`socket-hardware` runs during Socket and during games. It needs
`/dev/uinput` and exclusive access to the physical controls. It logs startup
errors to `Logs/socket-hardware.log`.

The helper requests a 10 ms poll interval for its controls, as Slot does. It
does not change a faster interval. If the kernel refuses the request, the
helper continues.

## Return time

`Logs/socket-game.log` records the uptime at game start, game exit and
cleanup. `Logs/socket.log` records the time from game exit to the first
Socket frame. Use these values to measure how quickly Socket returns on the
device.
