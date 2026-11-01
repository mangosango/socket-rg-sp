# Rendering

Socket uses the Godot Compatibility renderer (OpenGL ES 3.0) on the RG SP's
Mali GPU. The panel is 720x480. The Socket layout is 1920x1280.

## Performance changes

- The 3D cartridge view renders at up to 2/3 of the panel pixels (480x320 on
  the RG SP). MSAA is off.
- The directional shadow atlas is 1024 pixels, not 4096. This is 16 times
  fewer shadow-map pixels. Shadows are still enabled.
- The cartridge carousel shows up to three games.
- The frosted glass blur uses five texture reads. The liquid glass blur uses
  four taps on 0.8.0.
- The label shader skips the gloss gradient when its fade is zero. It
  calculates the diffraction inputs only when the diffraction pass runs.
- Godot runs with `--render-thread safe`.

For the 0.3.2 changes, see [Socket versions](socket-versions.md).

## Image changes

- The Compatibility renderer tonemaps each shadowed light pass separately,
  which caused white labels to clip. On 0.8.0, the cartridge view tonemaps
  once after all passes, with Reinhard and a white point of 1.3. Menus and
  the 2D UI stay the same.
- Foil labels use the sampled gradient without the 2x color multiplier. This
  reduces clipped highlights. Gloss and diffraction stay enabled.
- The cartridge view uses an FXAA-style edge filter when it draws the 3D
  image. It uses five texture reads in flat areas and up to nine near edges.
  The filter doesn't affect menu text or focus outlines.

## Frame-rate log

`System/launch_frontend.sh` sets `SOCKET_FPS_DIAGNOSTICS=1`. Socket then
writes one JSON line every five seconds to
`Saves/socket/godot/app_userdata/Socket/render-performance.jsonl`. The file
is replaced on each start. Each line includes:

- Frames per second, the slowest frame and the process time.
- The window size, the layout size and the 3D viewport size.
- Draw calls and primitives.
- The open screens and the 3D shaders in use.

`socket.log` shows the same lines. To turn off logging, remove the
`SOCKET_FPS_DIAGNOSTICS` line from `launch_frontend.sh`.

## Other changes

The bridge reads sysfs values one line at a time. This prevents invalid
UTF-8 warnings from sysfs files that have the size of a page.
