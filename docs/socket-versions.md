# Socket versions

`patch-socket.py` reads the version from the APK and applies the matching
changes. These versions are supported:

| Version | Status |
|---------|--------|
| 0.10.1 | Pack build and Linux AArch64 headless startup checked. RG SP hardware testing pending. |
| 0.8.0 | Full port. Tested on the RG SP. |
| 0.3.2 | The last free version. Library scan, cached artwork, emulator list and RetroArch launch work on the RG SP. |

The RetroArch menu, the controls, sleep and power-off come from this
repository. All supported versions use the same ones.

All three versions also use the Linux startup `Compiling shaders` screen to warm
built-in cartridge rendering variants before navigation, reusing the persistent
shader cache. Headless runs skip GPU preparation. This new startup path has not
yet been verified on RG SP hardware; previous hardware results in the table do
not validate it. See [Rendering](rendering.md#startup-shader-compilation).

Startup compatibility checks use a fresh 0.10.1 APK build and shader-only
repacks of existing 0.8.0/0.3.2 packs (their APKs were unavailable). Headless
checks cover gate cleanup, the exact status label, main-scene startup and
empty-library material APIs: 18 model/label-set combinations and 178 variants
for 0.10.1, 17/168 for 0.8.0, and 14/138 for 0.3.2. These are API checks, not
GPU draws or proof of persistent-cache reuse. The known 0.3.2 missing desktop
BPTC texture messages remain tolerated by the existing test runner.

The Wi-Fi build passed the packed offline and simulated online artwork and
achievement checks on all three versions. The 0.10.1 pack was built from the
APK. The 0.8.0 and 0.3.2 checks used local pack snapshots. Radio association,
live downloads and account unlocks still need an RG SP test.

## 0.10.1

The packed-app integration tests cover controller dialogs as well as the
library, audio and rendering patches. A copied 401-game
library also reaches the main screen, but that populated-library test reports
a null material in Godot's dummy renderer and segfaults on headless exit.
Hardware rendering and shutdown still need an RG SP check.

Uses the same BaseOS launch, library, audio and rendering patches as 0.8.0,
with these compatibility changes:

- Both ROM and save-folder pickers use the Linux folder picker.
- Native music, artwork and folder dialogs share controller navigation,
  readable sizing and cancellation, including their nested confirmations.
- Delayed carousel warmups are replaced by the shared startup shader warmup
  on Linux. Hardware shader coverage and cold/cached boot timing still need
  a follow-up check.
- The bridge accepts the newer Android API calls, with no-plugin defaults
  for Android-only features.
- The sticker bump optimization applies to the new shared shader include.
  The older diffraction and noise edits are not applied to the rewritten
  shader: its gloss pass also needs the groove axis.
- The image-error guard is already fixed upstream. Scrape resets already
  reload their data, so only the two result assignments need reload patches.

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
