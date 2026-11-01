# Socket versions

`patch-socket.py` reads the version from the APK and applies the matching
changes. These versions are supported:

| Version | Status |
|---------|--------|
| 0.8.0 | Full port. Tested on the RG SP. |
| 0.3.2 | The last free version. Library scan, cached artwork, emulator list and RetroArch launch work on the RG SP. |

The RetroArch menu, the controls, sleep and power-off come from this
repository. Both versions use the same ones.

## 0.3.2

Socket 0.3.2 draws its UI and 3D view at the layout size of 1920x1280. It
also draws the AYN Thor bottom screen in each frame. On BaseOS, the port
makes these changes:

- It disables the bottom screen.
- It draws the UI at the panel resolution (720x480 on the RG SP) with the
  same layout. On a screen larger than the layout, the UI uses the layout
  size.
- It draws the 3D view at 2/3 of the panel pixels (480x320 on the RG SP)
  with the display edge filter.
- It writes the same frame-rate log as 0.8.0. See [Rendering](rendering.md).

These 0.8.0 changes don't apply to 0.3.2 because it doesn't have the related
code:

- The single tonemap pass.
- Fewer liquid glass blur taps. The 0.3.2 shader uses only three reads.
- The UI sound bus setup.
- The joypad focus for the Scan button.
- The modal focus fix.

Socket 0.3.2 doesn't track play time.

On the RG SP, 0.3.2 is slower than 0.8.0. The main menu ran at 21.5 frames
per second on 0.3.2 and at 28.9 on 0.8.0, before the 720x480 UI change.

Socket 0.3.2 refers to a desktop copy of an environment texture that isn't
in the APK. `socket.log` shows `Unable to open file ... .bptc.ctex`. Socket
keeps running despite this message.
