# How the port works

Socket is a Godot 4.7.1 project. The Android APK contains an encrypted copy
of the project. The port keeps Socket's scenes, scripts and assets, swapping
out the platform layer.

| Part | Android | BaseOS |
|------|---------|--------|
| Engine | Godot 4.7.1 for Android | Godot 4.7.1 Linux AArch64 template with a Mali fbdev display server (`engine/`) |
| Renderer | Mobile (Vulkan) | Compatibility (OpenGL ES 3.0) |
| Gamepad | Android input | evdev, with the H700 button codes that Slot uses |
| Platform bridge | `FrontendPlugin` Java plugin | `overlay/addons/FrontendPlugin/frontend_bridge.gd` |
| Game start | Android intent | Socket releases the display and audio, runs the emulator, then continues |
| Emulators | Android apps from the Socket emulator list | RetroArch entries from the same list, with cores from `System/socket/cores` |

## Pack build

`tools/build-pack.sh` turns the APK into `socket.pck`:

1. `godot-unpack extract` finds the AES-256 key of the project in
   `libgodot_android.so`. It tests each candidate against the `ECFG` header
   of `project.binary`.
2. The same process decrypts each pack file and checks its MD5. The pack
   key stays in that process.
3. `gdc2gd.py` converts the compiled scripts that the port changes back to
   GDScript.
4. `patch-socket.py` reads the Socket version from `project.binary` and
   applies the BaseOS changes for that version. Each change finds its
   location with a short pattern, so this repository contains no Socket
   source. If the version isn't supported or a pattern doesn't match, the
   script stops without changing any files.
5. The build replaces only the scripts that changed. It adds the bridge and
   removes the AYN Thor GDExtension.
6. `pack.py` writes the PCK.

## Game start

Socket stays loaded during a game. The fbdev display server releases the EGL
window, the audio device and the input descriptors. `play_game.sh` runs
RetroArch. When you exit the game, the display server restores the window,
audio and input. Socket then shows its loaded scene, so there's no need to
reload the pack or rebuild the scenes.

The save flush runs at the same time as the first Socket frame. A shutdown
waits for the flush to complete.

## Android features

These Android features aren't active on BaseOS: the Android apps platform,
usage access play time, the home app prompt and the AYN Thor second screen.
Play time is the time between game start and game exit.

## Card layout

```
System/
  launch_frontend.sh          BaseOS starts this file
  socket/
    godot                     engine
    socket-hardware           input, sleep and power helper
    socket.pck                Socket, made from your APK
    launch_game.sh            starts a game; edit it to use another emulator
    play_game.sh              game log, process ID and session time
    resume_game.sh            starts the resume record after a shutdown
    poweroff.sh               power-off sequence
    poweroff_ready.sh         checks that a requested shutdown can start
    cores/                    libretro cores
    retroarch/                RetroArch, its settings and shaders
Saves/socket/                 Socket settings, library and RetroArch settings
Logs/                         socket.log, socket-game.log, socket-hardware.log
```

BaseOS starts `System/frontend` if it exists. If not, it starts
`System/launch_frontend.sh`.
