# Rendering

Socket uses the Godot Compatibility renderer (OpenGL ES 3.0) on the RG SP's
Mali GPU. The panel is 720x480. The Socket layout is 1920x1280.

## Performance changes

- The RG SP uses the saved 3D render scale in **Settings > Display**.
  New profiles start at 0.75 (540x360). Existing profiles keep their saved
  scale. The slider reaches native 720x480 at 1.00. The 2D interface has
  its own resolution.
- The directional light draws one 512x512 shadow map. This uses a quarter of
  the texels of the previous 1024x1024 map. A fixed-pose comparison over six
  foil and casing combinations had a mean difference of 0.26 to 0.87 per
  RGB channel on opaque cartridge pixels, on a scale of 0 to 255. The alpha
  channel matched in every capture.
- The 0.10.1 main menu draws its rounded corners in a band around the screen.
  Its glass controls use the background colors and gradient when the dots
  are behind them. Lava backgrounds retain the screen-reading glass shader.
- The cartridge carousel shows up to three games.
- On Linux, supported Socket versions warm cartridge shaders before navigation
  behind a `Compiling shaders` screen. This replaces delayed carousel warmups;
  GLES compilation can otherwise block navigation for several seconds.
  See the startup behavior and validation limits below.
- The frosted glass blur uses five texture reads. The liquid glass blur uses
  four taps on 0.8.0.
- The label shader skips the gloss gradient when its fade is zero. It
  calculates the diffraction inputs only when the diffraction pass runs.
- Godot runs with `--render-thread safe`.

For the 0.3.2 changes, see [Socket versions](socket-versions.md).

## Startup shader compilation

On graphical Linux boots, the `Compiling shaders` screen shows a turning
indicator and the label on a plate in the active theme's surface and text
colors, with native-pixel text. Behind the plate it shows the moving dots of
the Socket launch screen. It uses the dots material of a node that is already
in the tree (the boot screen on 0.10.1, the menu background on 0.8.0 and
0.3.2) and keeps the dot spacing. It uses the Socket spinner on 0.10.1 and a
drawn arc on the older versions. It does not start the boot scene or load the
library again, and it adds no waits to the warmup. It does not change hardware
brightness. It blocks navigation while built-in cartridge scenes, casing finishes
and label styles are drawn using the
main carousel's camera, lights and rendering target. This also runs with an empty
library, without changing saved games or appearance settings.

The warmup replays on each app start, reusing Godot's persistent shader cache.
There is no permanent "first boot completed" flag: shader/engine/driver changes
or a cleared cache must not silently skip preparation. A cold cache takes longer;
compilation can freeze the status screen briefly between variants. The
animation cannot move during a synchronous GLES compile. Cached-boot duration
for the new renderer still needs measurement on the RG SP. Do not clear the existing
cache for normal upgrades.

The warmup renders the same material variants on a smaller cartridge. It
presents the spinner when 50 ms has passed. Between visible updates it draws
offscreen. The previous 600x400 build made 392 warmup draws per boot. The
RG SP logs recorded 20.9 s and 29.9 s for two runs.

The startup prints one `Shader startup:` line to `socket.log`, and the first
sample of the frame-rate log repeats it as `shader_startup`:

- `warmup_ms`: the time that the status screen was up.
- `longest_frame_ms`: the longest time between two presented frames. This is
  the longest visible freeze.
- `first_input_ms`: the time from engine start to the first usable input.
- `sets` and `draws`: the model and label sets, and the warmup draws.
- `presents` counts the warmup frames shown on the panel.

The same sample has `shader_cache_files_at_start`. Zero identifies a cold
start. To measure a cold start, move `shader_cache` out of
`Saves/socket/godot/app_userdata/Socket` and start Socket. Start it again for
the cached values.

Headless tests skip GPU preparation; non-Linux startup keeps upstream behavior.
This targets cartridge shader compilation, not every possible menu effect,
artwork-loading delay or other navigation stall. Real GPU coverage and cold/warm
boot timing remain unverified until tested on the device. Headless test success
is not evidence that all shader specializations were compiled.

## Image changes

- The Compatibility renderer tonemaps each shadowed light pass separately,
  which caused white labels to clip. On 0.8.0, the cartridge view tonemaps
  once after all passes, with Reinhard and a white point of 1.3. Menus and
  the 2D UI stay the same.
- Foil labels use the sampled gradient without the 2x color multiplier. This
  reduces clipped highlights. Gloss and diffraction stay enabled.
- The RG SP uses 2x MSAA for cartridge edges. The casing shaders use their
  original roughness.
- The optional `edge` display shader uses alpha to locate steps between opaque
  and empty texels. It samples three distances along each side of a step to
  estimate how much of the panel pixel the outline covers. At native size
  it checks the neighboring texel corners, so a one-pixel move gives the
  same edge treatment. Opaque label interiors and partially transparent
  edges keep their bilinear color. The shader uses the existing display
  pass with a single-sample 3D target.

## Small text

Socket lays out its UI at 1920x1280 and the panel shows it at 0.375 of that
size. The default pixel font files (Departure Mono `.otf` and `.woff`) ask for
glyphs at 10 and 8 times the layout size. A 46-unit menu label became a 460
pixel glyph that one linear texture read with no mipmaps reduced to 17 panel
pixels. This broke up the strokes. The native-pixel HUD, dialogs and startup
status had the same fault, because the font request also applies to them.

On Linux the port now:

- Removes the size request from those two font files. Native-pixel text gets
  glyphs at its exact size.
- Sets the font oversampling of the UI viewport to two times the panel scale.
  A 46-unit label gets a 34.5 pixel glyph, and one linear read gives smooth
  strokes. Typefaces, sizes and layout do not change.
- Draws UI vertices on whole panel pixels (`snap_2d_vertices_to_pixel`), so
  glyphs do not fall between pixels.
- Uses a 22 pixel startup label, two times the 11-pixel grid of Departure
  Mono.

Device Settings uses the same panel in Socket and in RetroArch. At 720x480
its 46-unit Departure Mono text occupies 17.25 panel pixels. The menu now
rasterizes those glyphs at 33 pixels, on the font's 11-pixel grid. The layout
and the frame sent to RetroArch keep their original dimensions.
At the same 720x480 size, the launcher title had 0.53 half-tone pixels per
full ink pixel, down from 3.56. The Wi-Fi keyboard went from 3.76 to 0.80.
The positions, line counts and focus order matched in the before and after
captures.

`SOCKET_UI_FONT=0` and `SOCKET_UI_SNAP=0` turn off the launcher font and vertex changes for a
comparison. Mesa captures at 720x480 show the change. The RG SP panel still
needs a visual check, and so do the HUD and dialog sizes: Departure Mono is
exact only at multiples of 11 pixels.

## RG SP profile and measurements

A test on the RG SP at 720x480 with automatic 2x MSAA recorded 12.2 fps
in the first sample after warmup and 0.74 fps in the next. The last sample
included a 62.9-second stall and reported MSAA off. The log does not locate
that stall inside the driver. That build used the engine with the framebuffer
leak described below. The current card uses the fixed engine.

The GLES renderer allocated a new framebuffer each time it looked up the
multisampled cartridge target for post-processing. It lost the reference
to the previous framebuffer. With the tile attachment calls emulated on
Mesa, the shipped ARM engine leaked 720 framebuffers in 120 frames.
The fixed engine reuses the framebuffer while its textures are active
and releases it when the target changes.

The last handheld run with silhouette reconstruction and MSAA off had 73
main-menu samples at 540x360. Median frame rate was 28.5 fps. The median of
the five-second p95 frame times was 50.5 ms. Ten samples included pad
navigation, with a median navigation p95 of 52.7 ms.

An earlier 24-frame trial on Mesa compared the same GBA idle tilt at 540x360 with
2x MSAA. The reference for each pose was a 2160x1440 render reduced to the
same size. The table counts bevel pixels whose change in brightness between
frames differed from the reference by more than 24 on a scale of 0 to 255.

| Finish | Highlight smoothing off | Highlight smoothing on |
| --- | ---: | ---: |
| Factory GBA | 81 | 22 |
| Opaque | 59 | 45 |
| Dark opaque | 83 | 23 |
| Glitter | 56 | 42 |

Mean bevel brightness changed by less than 1% in these captures. Highlights
spread over nearby pixels. Some dark-plastic pixels became brighter than the
reference, even as the large jumps during motion decreased. Label pixels
matched across all poses. A metallic trial increased the count from 47 to
99. The release uses the original material shading for all finishes.

In a separate five-round Mesa run, the median frame took 22.41 ms with the
experimental filter off and 23.52 ms with it on. Both modes used 18 scene draws and 37
canvas draws. The round times overlapped. Measuring the cost of this profile
on the RG SP requires a handheld run.

The 480x320 recovery build recorded 11 main-menu samples on the RG SP.
The median was 34.8 fps and the median of their p95 frame times was 37.6 ms.
With the fixed engine and MSAA off, three five-second main-menu samples at
720x480 recorded 19.2 to 24.2 fps. One at 540x360 recorded 36.9 fps. The
cartridge finishes differed between samples.

Across 12 cartridge poses and finishes on Mesa, the new filter reduced mean
absolute silhouette coverage error from 27.3 to 18.3 at 540x360, and from
19.3 to 12.3 at 720x480. Coverage ranges from 0 to 255. The reference used
2880x1920 renders reduced to panel size. These figures measure the outer
edge. Cartridge label detail still depends on the 3D resolution.

In seven interleaved trials of 120 frames at 540x360, the median frame on
Mesa llvmpipe took 10.00 ms with bilinear filtering and 11.93 ms with the
new outline filter. Both used 18 3D draws and 37 canvas draws. The cost on
the RG SP still needs measurement.

The earlier card used a 600x400 carousel with a linear display filter and
one shadow pass. Its last RG SP log contains 11 five-second main-menu samples,
excluding the interval that contained gameplay. Median frame rate was 23.3 fps.
The median of the sample p95 frame times was 55.0 ms, and 60.8 ms for navigation.
An earlier 480x320 build ran at 27 to 31 fps with different effects. Different
builds and scenes prevent a direct measurement of the cost of resolution alone.

A same-camera GLES capture shows why there is work on both sides of the 3D
viewport. Freezing the cartridge removes the 3D draw work. The window still
draws the animated background, cartridge texture, controls and final display
pass. On the previous card, the one Settings sample with the 3D view paused
ran at 38.8 fps. It also had more controls than the main menu. On a Mesa
software renderer, eliminating the screen-reading glass removes a full-screen
copy and reload. The single-shadow carousel goes from seven passes to five
before MSAA. The shadow map, material shading, fog and label highlights remain.
Disabling the shadow map also removes a tonemap pass, but the casings and
metallic or foil finishes visibly change.

The antialiasing comparison uses two fixed cartridge poses and a 2880x1920
reference reduced to panel size. The metric is mean absolute RGB error on
edge pixels, on a scale from 0 to 255. Lower is better.

| 3D size | Linear | Linear with 2x MSAA |
| --- | ---: | ---: |
| 480x320 | 15.0 | 14.7 |
| 600x400 | 11.0 | 10.6 |
| 720x480 | 6.7 | 4.8 |

These are Mesa captures. The actual MSAA sample count and cost depend on the
driver. The fbdev engine checks for `GL_EXT_multisampled_render_to_texture2`,
the attachment entry point and at least two samples. The extension allows
both color and depth textures to receive multisampled rendering. In automatic
mode, a driver without that capability uses one sample at the selected size.
Explicit 2x and 4x requests are available for comparison. [Khronos extension specification](https://registry.khronos.org/OpenGL/extensions/EXT/EXT_multisampled_render_to_texture2.txt)

Clear and translucent casings copy the opaque scene to draw refraction.
That copy can discard the depth texture on the tile MSAA path. The shell
can then draw over a label in front of it. For frames that need a screen
or depth copy, the renderer uses multisample renderbuffers that retain
depth through the transparent pass. It resolves the final image after that
pass. Frames without a copy continue to use tile MSAA. The cost of the
extra resolve on the RG SP still needs a handheld measurement.

On the RG SP, automatic mode starts at 2x. If the live carousel renders
below 12 fps for two consecutive three-second intervals, Socket releases
the extra samples for that session. The launcher keeps the selected 3D size.

| Variable | Card setting | Other settings |
| --- | --- | --- |
| `SOCKET_3D_CAP` | `1` (up to 720x480) | `0.6667` caps the slider at 480x320. |
| `SOCKET_3D_MSAA` | `auto` (2x on the RG SP) | `0` disables MSAA. `2` and `4` request a fixed count. |
| `SOCKET_3D_FILTER` | `linear` | `edge` selects silhouette reconstruction for a single-sample target. |
| `SOCKET_3D_SHADOWS` | `orthogonal` | `4` selects four splits. `0` disables the map. |
| `SOCKET_UI_LIGHT` | enabled | `0` restores the original glass and corner draws. |

For a controlled run on the handheld, copy `tests/app/bench_device.sh` and
`tests/app/bench_render.gd` into a `Benchmark` directory on the card. Create
an empty `Benchmark/run` file. Socket runs the benchmark once at the next
normal startup. A pending game resume takes priority. The fixture uses its
own temporary games and shader cache. The result is in
`Benchmark/results-1/results.jsonl`, or the next available number. Use
`python3 tests/app/bench_report.py <results.jsonl>` to read the table.
For a short run, put
`SOCKET_BENCH_ONLY=as_started,3d_frozen,no_post`
in `Benchmark/options`. Use `as_started` on each pack for a comparison of
all the changes together.

## Frame-rate log

`System/launch_frontend.sh` sets `SOCKET_FPS_DIAGNOSTICS=1`. Socket then
writes one JSON line every five seconds to
`Saves/socket/godot/app_userdata/Socket/render-performance.jsonl`. The file
is replaced on each start. Each line includes:

- Frames per second, the slowest frame and the process time.
- `frames_over_20ms_pct` gives the share of frames over 20 ms. A 60 Hz panel
  has 16.7 ms per refresh.
- `viewport_3d_draw_cpu_ms` and `window_draw_cpu_ms` measure CPU wall time
  inside each viewport draw. The latter includes the 2D scene. A driver wait
  can contribute to either value. The GLES backend on this device does not
  provide per-viewport GPU timer results.
- `p95_frame_ms`: the 95th percentile frame time of the sample.
- `nav_frames`, `nav_p95_ms` and `nav_worst_ms`: the same for navigation
  frames. A navigation frame has a button down, or had one in the last 0.5
  seconds, so it includes the carousel motion after a press.
- `new_shaders_3d`: the 3D shaders that this sample shows for the first time,
  such as a foil label or frosted glass.
- The render candidate variables and the MSAA mode.
- In the first sample: the startup record and the shader cache file count.

A frame of 250 ms or more also writes a `stall_ms` line at once, with the
open screens. A percentile or an average can hide a rare stall. The sampler
restarts after a game or shader warmup. Samples also include window and
viewport sizes, draw calls, primitives, active screens and shader names.

`socket.log` shows the same lines. To turn off logging, remove the
`SOCKET_FPS_DIAGNOSTICS` line from `launch_frontend.sh`.

## Other changes

The bridge reads sysfs values one line at a time. This prevents invalid
UTF-8 warnings from sysfs files that have the size of a page.
