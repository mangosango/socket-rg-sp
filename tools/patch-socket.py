"""Apply the BaseOS changes to Socket sources decoded from your APK.

Usage: python3 -I patch-socket.py <src-dir> <project.binary>

Each edit is a short regular expression that finds a place in a Socket file,
and the BaseOS text that goes there. Anchors are function names, Godot API
calls and platform checks. This file does not contain Socket source; text that
moves is captured from your copy. If an anchor does not match the expected
number of times, the script stops and changes no files.

The script also adds the shader global of the casing filter to project.binary.

Supported Socket versions: 0.10.1, 0.8.0 and 0.3.2. The version comes from
application/config/version in project.binary.
"""
import re
import struct
import sys

M = re.M
S = re.M | re.S


def gd(text):
    """Convert 4-space indents in this file to the tabs that Socket uses."""
    return re.sub(r"(?m)^((?:    )+)", lambda m: "\t" * (len(m[1]) // 4), text)


def prepend(path, func, text):
    """Insert text as the first lines of a GDScript function."""
    return (path, rf"^(func {func}\(.*\n)", lambda m: m[1] + gd(text), 1, M)


def only(version, edit):
    """Apply an edit only to the listed Socket versions."""
    return edit + ((version,) if isinstance(version, str) else version)


LINUX = 'OS.get_name() == "Linux"'
V101, V080, V032 = "0.10.1", "0.8.0", "0.3.2"
MODERN = (V101, V080)
LEGACY = (V080, V032)
VERSIONS = (V101, V080, V032)

MANAGER = "scripts/autoload/manager.gd"
EDIT_PLATFORM = "scenes/screen_edit_platform.gd"
RENDER_SCALE = "scenes/render_scale_3d.gd"
KEYBOARD_AVOIDER = "scenes/keyboard_avoider.gd"
STICKER = "scenes/paper_sticker.gdshader"


def move_diffraction_setup(m):
    """Compute the diffraction inputs only when the diffraction pass runs."""
    moved = m[1] + m[3]
    return m[2] + m[4] + re.sub(r"(?m)^(?=.)", "\t", moved)


# Optional frame-rate log for the 3D view, enabled by SOCKET_FPS_DIAGNOSTICS=1.
FPS_VARS = """\
var _fps_started_usec: int = 0
var _fps_last_usec: int = 0
var _fps_worst_usec: int = 0
var _fps_frames: int = 0
var _fps_drawn_frames: int = 0
var _fps_log: FileAccess
var _fps_process_frame: int = 0
var _fps_frame_usec: PackedInt32Array = []
var _fps_nav_usec: PackedInt32Array = []
var _fps_nav_until_usec: int = 0
var _fps_seen_shaders: Array = []
var _fps_cache_files: int = -1
var _baseos_cap: = 1.0
var _baseos_aa_generation: = 0
var _baseos_last_unpause_usec: = 0
"""
# The pixel font files ask for glyphs at 8 or 10 times the layout size. The
# panel shows the layout at 0.375 of its size, so each glyph shrinks about 26
# times in one linear read with no mipmaps, and its strokes break up. Without
# that request, native-pixel text (HUD, dialogs, startup status) gets glyphs at
# its exact size. The scaled UI gets glyphs at two times the panel size, which
# one linear read makes smooth. The UI vertices go on whole panel pixels.
FONT_FILES = ["res://fonts/DepartureMono-1.500/DepartureMono-Regular." + kind for kind in ("otf", "woff")]
FONT_FIX = """\
        var window: = get_tree().root
        window.snap_2d_vertices_to_pixel = OS.get_environment("SOCKET_UI_SNAP") != "0"
        if OS.get_environment("SOCKET_UI_FONT") != "0":
            for path in %s:
                if ResourceLoader.exists(path):
                    load(path).oversampling = 0.0
            var fit: = func():
                var ui_scale: = window.get_stretch_transform().get_scale().y
                window.oversampling_override = 2.0 * ui_scale if ui_scale < 1.0 else 0.0
            window.size_changed.connect(fit)
            fit.call()
""" % FONT_FILES

# Device benchmark candidates. With no variable set, rendering does not change.
BENCH_NAMES = ["SOCKET_3D_CAP", "SOCKET_3D_FILTER", "SOCKET_3D_MSAA", "SOCKET_3D_SHADOWS", "SOCKET_UI_SNAP", "SOCKET_UI_FONT", "SOCKET_UI_LIGHT"]
BENCH_START = """\
    # Benchmark candidates: the 3D pixel limit as a part of the panel pixels,
    # 2x or 4x MSAA, and the shadow map. The defaults are the full slider range, no MSAA and
    # one shadow pass.
    var cap: = OS.get_environment("SOCKET_3D_CAP")
    if cap.is_valid_float():
        _baseos_cap = clampf(cap.to_float(), 0.05, 1.0)
    _baseos_apply_msaa(bool(SettingsManager.get_setting("cartridge_msaa")))
    # "4" keeps the four shadow splits of Socket. "0" removes the shadow map:
    # no shadow pass, no shadow reads in the cartridge shaders and no separate
    # tonemap pass. It changes the image, see TONEMAP.
    var shadows: = OS.get_environment("SOCKET_3D_SHADOWS")
    var shadow_map: = shadows != "0"
    for light in find_children("*", "DirectionalLight3D", true, false):
        if not shadow_map:
            light.shadow_enabled = false
            # A light with no shadow map gives less light in this renderer.
            # Two times the energy gives the mean brightness of the image with the shadow map.
            light.light_energy *= 2.0
        elif shadows != "4":
            # One shadow pass draws the casters one time, not one time for each of four splits.
            light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
"""
# Compatibility tonemaps the light with a shadow map alone, so lit labels
# clip. Neutral adjustments make Godot tonemap one time in a separate pass. A
# mild Reinhard curve then keeps highlight detail. The 2D UI does not change.
# With no shadow map the cartridge shader tonemaps one time itself, so the
# separate pass is off. That image is flatter: Mesa captures show a mean color
# difference of 12 to 20 of 255 on the cartridge pixels.
TONEMAP = """\
    for node in find_children("*", "WorldEnvironment", true, false):
        var world: = node as WorldEnvironment
        if world.environment == null:
            continue
        world.environment = world.environment.duplicate()
        world.environment.tonemap_mode = Environment.TONE_MAPPER_REINHARDT
        world.environment.tonemap_white = 1.3
        world.environment.adjustment_enabled = shadow_map
        world.environment.adjustment_brightness = 1.0
        world.environment.adjustment_contrast = 1.0
        world.environment.adjustment_saturation = 1.05
"""
DISPLAY_MATERIAL = """\
    var display_material := ShaderMaterial.new()
    display_material.shader = load("res://shaders/display_aa.gdshader")
    if OS.get_environment("SOCKET_3D_FILTER") == "linear":
        # Benchmark candidate: one linear read that keeps premultiplied alpha.
        var linear := Shader.new()
        linear.code = "#define DISPLAY_LINEAR\\n" + display_material.shader.code
        display_material.shader = linear
"""
# Fewer full-screen operations in the 2D frame. SOCKET_UI_LIGHT=0 turns this off.
#
# Corners: Socket draws the rounded screen corners with a shader on a rect of
# the full screen, but only a band at the screen edges can get color. Draw the
# band only, with the same shader and the same UV values.
#
# Glass: each glass panel reads the screen below it. For that read, the GPU
# stops the frame, copies it and continues, and a tile GPU must then load the
# full frame again. On the main menu the dotted background with its gradient is
# below the glass, and the blur removes the dots. So these panels get the
# background color, the mean dot cover and the gradient as inputs and do not
# read the screen. The lava background keeps the screen read.
LIGHT_UI = """\
var _baseos_glass: Array = []
var _baseos_glass_flat: Shader
var _baseos_background: BackgroundStyleController
var _baseos_glass_inputs: Array = []


func _baseos_light_ui() -> void:
    for overlay in find_children("*", "ColorRect", true, false):
        var corners: = overlay.material as ShaderMaterial
        if corners == null or corners.shader == null or corners.shader.resource_path != "res://scenes/outline.gdshader":
            continue
        var full: Vector2 = overlay.size
        var screen: Vector2 = corners.get_shader_parameter("size")
        var radius = corners.get_shader_parameter("corner_radius")
        var noise = corners.get_shader_parameter("noise_intensity")
        # The shader measures in units of the screen height. The noise moves the edge by half of its intensity.
        var reach: float = ((0.2 if radius == null else radius) + (0.01 if noise == null else noise)) * full.y + 4.0
        var band: = Vector2(reach * full.x * screen.y / (screen.x * full.y), reach).min(full / 2.0)
        var points: = PackedVector2Array()
        for rect in [Rect2(0, 0, full.x, band.y), Rect2(0, full.y - band.y, full.x, band.y), Rect2(0, band.y, band.x, full.y - 2.0 * band.y), Rect2(full.x - band.x, band.y, band.x, full.y - 2.0 * band.y)]:
            points.append_array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
        var edge: = Polygon2D.new()
        # With a texture of one pixel, the UV values are parts of the full rect.
        edge.texture = ImageTexture.create_from_image(Image.create(1, 1, false, Image.FORMAT_RGBA8))
        edge.polygon = points
        edge.uv = PackedVector2Array(Array(points).map(func(point): return point / full))
        edge.polygons = range(4).map(func(i): return PackedInt32Array([i * 4, i * 4 + 1, i * 4 + 2, i * 4 + 3]))
        edge.color = overlay.color
        edge.use_parent_material = true
        overlay.add_child(edge)
        # A rect of zero size draws nothing. The band keeps the place of the full rect.
        overlay.set_anchors_preset(Control.PRESET_TOP_LEFT)
        overlay.size = Vector2.ZERO
    _baseos_background = find_child("Background", true, false) as BackgroundStyleController
    if _baseos_background == null:
        return
    _baseos_glass_flat = Shader.new()
    _baseos_glass_flat.code = "#define GLASS_FLAT\\n" + load("res://scenes/liquid_glass.gdshader").code
    get_tree().node_added.connect(_baseos_glass_added)
    for node in find_children("*", "Control", true, false):
        _baseos_glass_added(node)
    get_tree().process_frame.connect(_baseos_glass_sync)


func _baseos_glass_added(node: Node) -> void:
    var panel: = node as Control
    if panel == null or not panel.material is ShaderMaterial or panel.material.shader == null or panel.material.shader.resource_path != "res://scenes/liquid_glass.gdshader":
        return
    # Other screens put more layers between the background and their glass.
    var home: = Screen.get_screen("main")
    if home == null or not home.is_ancestor_of(panel):
        return
    # Other panels can use the same material resource.
    panel.material = panel.material.duplicate()
    _baseos_glass.append(panel)
    panel.tree_exiting.connect(func(): _baseos_glass.erase(panel))
    _baseos_glass_inputs = []


# Runs one time for each frame. It reads the background state and stops when
# the state did not change, so a frame with no change has no material writes.
func _baseos_glass_sync() -> void:
    var background: = _baseos_background
    if get_tree().paused or _baseos_glass.is_empty() or not background.is_visible_in_tree():
        return
    var dots: = background.dots_rect.material as ShaderMaterial
    var inputs: = [background._bg_color, background._dot_color, dots.get_shader_parameter("dot_size"), background.dots_rect.visible, background.lava_rect.visible, background.gradient_rect.visible, background.gradient_rect.flip_v]
    if inputs == _baseos_glass_inputs:
        return
    _baseos_glass_inputs = inputs
    var flat: bool = not inputs[4]
    # The mean of the dotted background: a round dot covers pi / 4 of the square of its size.
    var dot_size: float = 0.3 if inputs[2] == null else inputs[2]
    var color: Color = inputs[0].lerp(inputs[1], clampf(0.785 * dot_size * dot_size, 0.0, 1.0)) if inputs[3] else inputs[0]
    for panel in _baseos_glass:
        var glass: = panel.material as ShaderMaterial
        if (glass.shader == _baseos_glass_flat) != flat:
            glass.shader = _baseos_glass_flat if flat else load("res://scenes/liquid_glass.gdshader")
            # Socket gives each glass panel a helper that copies the screen.
            for helper in panel.get_children(true):
                if helper is BackBufferCopy:
                    helper.queue_free()
            if not flat:
                panel.add_child(load("res://scripts/glass_backbuffer.gd").new(), false, Node.INTERNAL_MODE_FRONT)
        if flat:
            glass.set_shader_parameter("backdrop_color", color)
            glass.set_shader_parameter("backdrop_fog", background.gradient_rect.texture)
            glass.set_shader_parameter("backdrop_fog_strength", 1.0 if inputs[5] else 0.0)
            glass.set_shader_parameter("backdrop_fog_flip", 1.0 if inputs[6] else 0.0)
"""
FPS_START = """\
    set_process(OS.get_environment("SOCKET_FPS_DIAGNOSTICS") == "1")
    if is_processing():
        _fps_started_usec = Time.get_ticks_usec()
        _fps_last_usec = _fps_started_usec
        _fps_drawn_frames = Engine.get_frames_drawn()
        _fps_process_frame = Engine.get_process_frames()
        # Zero files identify a cold shader cache in the startup record.
        _fps_cache_files = 0
        for folder in DirAccess.get_directories_at("user://shader_cache"):
            var group: = "user://shader_cache/".path_join(folder)
            _fps_cache_files += DirAccess.get_files_at(group).size()
            for variant in DirAccess.get_directories_at(group):
                _fps_cache_files += DirAccess.get_files_at(group.path_join(variant)).size()
        RenderingServer.viewport_set_measure_render_time(get_viewport_rid(), true)
        RenderingServer.viewport_set_measure_render_time(get_tree().root.get_viewport_rid(), true)
        _fps_log = FileAccess.open("user://render-performance.jsonl", FileAccess.WRITE)
        if _fps_log == null:
            push_error("Socket: cannot open render-performance.jsonl: " + str(FileAccess.get_open_error()))
"""
FPS_PROCESS = """\
func _notification(what: int) -> void:
    if what == NOTIFICATION_UNPAUSED:
        _baseos_last_unpause_usec = Time.get_ticks_usec()


func _baseos_apply_msaa(enabled: bool) -> void:
    _baseos_aa_generation += 1
    var paused: bool = get_tree().root.get_meta("socket_cartridge_msaa_paused", false)
    msaa_3d = SettingsManager.cartridge_msaa_mode() if enabled and not paused else Viewport.MSAA_DISABLED
    if msaa_3d != Viewport.MSAA_DISABLED and OS.get_environment("SOCKET_3D_MSAA") == "auto":
        _baseos_watch_aa(_baseos_aa_generation)


# Release the extra samples after two intervals below 12 fps on the live carousel.
# Normal navigation on the RG SP runs at about 28 to 37 fps.
func _baseos_watch_aa(generation: int) -> void:
    var slow: = 0
    while msaa_3d != Viewport.MSAA_DISABLED:
        var tree: = get_tree()
        var start: = Time.get_ticks_usec()
        var drawn: = Engine.get_frames_drawn()
        var active: = _baseos_aa_carousel()
        await tree.create_timer(3.0, false, false, true).timeout
        if generation != _baseos_aa_generation:
            return
        var usec: = Time.get_ticks_usec() - start
        if active and start >= _baseos_last_unpause_usec and _baseos_aa_carousel() and (Engine.get_frames_drawn() - drawn) * 1000000.0 < 12.0 * usec:
            slow += 1
            if slow == 2:
                get_tree().root.set_meta("socket_cartridge_msaa_paused", true)
                msaa_3d = Viewport.MSAA_DISABLED
                print("Socket: disabled MSAA for this session after sustained rendering below 12 fps.")
        else:
            slow = 0


func _baseos_aa_carousel() -> bool:
    return not get_tree().paused and render_target_update_mode == SubViewport.UPDATE_ALWAYS and (Engine.max_fps == 0 or Engine.max_fps > 12) and get_tree().root.get_meta("socket_shader_startup_complete", false) and Screen.screens_open.size() == 1 and Screen.screens_open[0].name == &"Screen_MainMenu"


func _fps_write(record: Dictionary) -> void:
    var line: = JSON.stringify(record)
    if _fps_log != null:
        _fps_log.store_line(line)
        _fps_log.flush()
    print("Socket render: ", line)


func _fps_p95(values: PackedInt32Array) -> float:
    if values.is_empty():
        return 0.0
    values.sort()
    return values[ceili(values.size() * 0.95) - 1] / 1000.0


func _fps_restart(now: int) -> void:
    _fps_started_usec = now
    _fps_last_usec = now
    _fps_drawn_frames = Engine.get_frames_drawn()
    _fps_frames = 0
    _fps_worst_usec = 0
    _fps_frame_usec.clear()
    _fps_nav_usec.clear()


func _process(_delta: float) -> void:
    var now: = Time.get_ticks_usec()
    var process_frame: = Engine.get_process_frames()
    var resumed: = process_frame - _fps_process_frame > 1
    _fps_process_frame = process_frame
    if resumed or int(get_tree().root.get_meta("socket_game_return_usec", 0)) > _fps_last_usec:
        # The launcher had no frame to present while paused or in a game.
        _fps_restart(now)
        return
    var frame: = now - _fps_last_usec
    _fps_worst_usec = maxi(_fps_worst_usec, frame)
    _fps_last_usec = now
    _fps_frames += 1
    _fps_frame_usec.append(frame)
    # Navigation frames: a button is down, or was down in the last 0.5 seconds.
    # This includes the carousel motion that follows a press.
    if Input.is_anything_pressed():
        _fps_nav_until_usec = now + 500000
    var navigating: = now < _fps_nav_until_usec
    if navigating:
        _fps_nav_usec.append(frame)
    if frame >= 250000:
        # A percentile or an average can hide a rare stall. Record each one.
        _fps_write({"stall_ms": frame / 1000.0, "at_seconds": now / 1000000.0, "navigating": navigating, "screens": Screen.screens_open.map(func(screen): return String(screen.name))})
    var seconds: = (now - _fps_started_usec) / 1000000.0
    if seconds < 5.0:
        return
    # Frame delta can be clamped during stalls. Measure elapsed wall time.
    var drawn: = Engine.get_frames_drawn()
    var root: = get_tree().root
    var sample: = {"elapsed_seconds": seconds, "process_frames": _fps_frames, "drawn_frames": drawn - _fps_drawn_frames, "process_fps": _fps_frames / seconds, "rendered_fps": (drawn - _fps_drawn_frames) / seconds, "worst_frame_ms": _fps_worst_usec / 1000.0, "window": [root.size.x, root.size.y], "logical": [root.get_visible_rect().size.x, root.get_visible_rect().size.y], "viewport_3d": [size.x, size.y], "draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)}
    # Record the active render state so screen changes can be compared.
    sample["screens"] = Screen.screens_open.map(func(screen): return String(screen.name))
    sample["viewport_update_mode"] = render_target_update_mode
    sample["process_ms"] = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
    sample["physics_ms"] = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
    sample["primitives"] = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
    var shaders: Array[String] = []
    for node in find_children("*", "MeshInstance3D", true, false):
        var mesh: = node as MeshInstance3D
        if not mesh.is_visible_in_tree() or mesh.mesh == null:
            continue
        for surface in mesh.mesh.get_surface_count():
            var material: = mesh.get_active_material(surface) as ShaderMaterial
            if material != null and material.shader != null and not shaders.has(material.shader.resource_path):
                shaders.append(material.shader.resource_path)
    sample["shaders_3d"] = shaders
    # The first sample that shows a shader also shows its first-use cost.
    sample["new_shaders_3d"] = shaders.filter(func(path): return not _fps_seen_shaders.has(path))
    _fps_seen_shaders.append_array(sample["new_shaders_3d"])
    sample["p95_frame_ms"] = _fps_p95(_fps_frame_usec)
    # The p95 calculation sorted the frame times. Allow for panel clock jitter.
    sample["frames_over_20ms_pct"] = 100.0 * (_fps_frame_usec.size() - _fps_frame_usec.bsearch(20000, false)) / _fps_frame_usec.size()
    sample["viewport_3d_draw_cpu_ms"] = RenderingServer.viewport_get_measured_render_time_cpu(get_viewport_rid())
    sample["window_draw_cpu_ms"] = RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid())
    if has_meta("socket_split_label_viewport"):
        var label: SubViewport = get_meta("socket_split_label_viewport")
        sample["viewport_label"] = [label.size.x, label.size.y]
        sample["label_draw_cpu_ms"] = RenderingServer.viewport_get_measured_render_time_cpu(label.get_viewport_rid())
    sample["nav_frames"] = _fps_nav_usec.size()
    sample["nav_p95_ms"] = _fps_p95(_fps_nav_usec)
    # The sort for the percentile put the slowest navigation frame last.
    sample["nav_worst_ms"] = 0.0 if _fps_nav_usec.is_empty() else _fps_nav_usec[-1] / 1000.0
    sample["msaa_3d"] = msaa_3d
    sample["tile_msaa_supported"] = OS.get_environment("SOCKET_TILE_MSAA") == "1"
    for name in %s:
        sample[name] = OS.get_environment(name)
    if _fps_cache_files >= 0:
        # Startup record, one time: cold or cached start and the warmup times.
        sample["shader_cache_files_at_start"] = _fps_cache_files
        sample["shader_startup"] = root.get_meta("socket_shader_startup_stats", {})
        _fps_cache_files = -1
    _fps_write(sample)
    _fps_restart(now)
""" % BENCH_NAMES


# (file, pattern, replacement, expected matches, flags[, version])
EDITS = [
    ("scripts/autoload/settings_manager.gd", r'^(\s*"render_scale_3d": )0\.85(,)$', r'\g<1>0.75\2\n\t"cartridge_msaa": true,', 1, M),
    ("scripts/autoload/settings_manager.gd", r"\n+\Z", gd("""

func cartridge_msaa_mode() -> Viewport.MSAA:
    match OS.get_environment("SOCKET_3D_MSAA"):
        "auto":
            return Viewport.MSAA_2X if OS.get_environment("SOCKET_TILE_MSAA") == "1" else Viewport.MSAA_DISABLED
        "2":
            return Viewport.MSAA_2X
        "4":
            return Viewport.MSAA_4X
    return Viewport.MSAA_DISABLED
"""), 1, 0),
    prepend(RENDER_SCALE, "_on_setting_changed", """\
    if key == "cartridge_msaa":
        get_tree().root.set_meta("socket_cartridge_msaa_paused", false)
        _baseos_apply_msaa(bool(new_value))
"""),
    only(MODERN, ("scripts/game.gd", r"^(\t)WorkerThreadPool\.add_task\((func\(\): _on_support_image_prefetched)", r"\1FrontendBridge.prefetch_artwork(\2", 1, M)),
    # Scrape results: reload the texture and game info after the paths change.
    # Skip the reset in 0.10.1. It already reloads the game.
    (MANAGER, r'^(\t+)(game\.support_texture_path = (?!""\s*$).*\n)', r"\1\2\1game.force_reload_texture()\n", 2, M),
    (MANAGER, r'^(\t+)(game\.game_info_path = (?!""\s*$).*\n)', r"\1\2\1game._game_info_loaded = false\n", 2, M),
    only(MODERN, prepend(MANAGER, "needs_emulator_database", """\
    if OS.get_name() == "Linux":
        return false
""")),
    only(MODERN, (MANAGER, r"^(\tconst TITLE\b.*\n)", lambda m: m[1] + gd("""\
    if OS.get_name() == "Linux":
        ScreenDialog.display(TITLE, "Use the Mac setup tool to update emulator lists on the SD card.", func(): pass, Callable())
        return
"""), 1, M)),
    # Start RetroArch on Linux, and wait until the game stops. 0.3.2 has no play sessions.
    *[only(version, (MANAGER, r"^(\t\tFrontendBridge\.launch_emulator\(intent_params\)\n)", lambda m, session=session: m[1] + gd("""\
    elif OS.get_name() == "Linux":
        var core: String = FrontendBridge.libretro_core(raw_args)
        if core.is_empty():
            ScreenDialog.display("Cannot Launch", "BaseOS runs RetroArch emulators only. Choose a RetroArch core for this platform and add its _libretro.so file to System/socket/cores.", func(): pass, Callable())
            return
""" + session + """\
        await FrontendBridge.launch_emulator({"core": core, "rom": game.rom_path, "platform": game.platform_id})
"""), 1, M)) for version, session in ((MODERN, '        _begin_play_session(game, "retroarch")\n'), (V032, ""))],
    # Use the bridge on Linux for play time and folder listing.
    (MANAGER, r'OS\.get_name\(\) == "Android"(:\n\t+[^\n]*FrontendBridge\.get_files_in_dir\()',
     rf'OS.get_name() == "Android" or {LINUX}\1', 2, M),
    only(MODERN, (MANAGER, r'OS\.get_name\(\) == "Android"(:\n\t+[^\n]*FrontendBridge\.get_foreground_seconds\()',
     rf'OS.get_name() == "Android" or {LINUX}\1', 1, M)),
    prepend(MANAGER, "scan_platform_in_user", """\
    if OS.get_name() == "Linux" and not platform.rom_folder_path.is_empty() and DirAccess.open(platform.rom_folder_path) == null:
        print("BaseOS: cannot open ROM folder: ", platform.rom_folder_path)
        return
"""),
    # Save the scan before the scrape so the library shows the games at once.
    (MANAGER, r"^(\tawait scrape_platform_in_user\()", r"\tsave_user()\n\tuser_updated.emit()\n\n\1", 1, M),
    # Offer only emulator entries that have a RetroArch core on the card.
    (MANAGER, r'^(\t+)if (OS\.get_name\(\) != "Android" or installed_apps\.has\()',
     lambda m: f'{m[1]}if OS.get_name() == "Linux":\n'
               f'{m[1]}\tif not FrontendBridge.libretro_core(am_args).is_empty():\n'
               f'{m[1]}\t\tapp_options.append({{"id": full_unique_id, "label": app.name}})\n'
               f'{m[1]}elif {m[2]}', 1, M),
    (MANAGER, r'^(func _get_app_by_id\(.*\n\tif OS\.get_name\(\) != "Android")', r'\1 and OS.get_name() != "Linux"', 1, M),

    # 0.3.2 reads the app list on every platform.
    only(MODERN, ("scenes/screen_apps.gd", r'(get_installed_app_list\([^)]*\) if OS\.get_name\(\) == "Android")', rf"\1 or {LINUX}", 1, M)),

    only(MODERN, (EDIT_PLATFORM, r"^(\tsuper\._ready\(\)\n)", lambda m: m[1] + gd("""
    var scan_button: Button = add_button.get_node("../Button_Scan")
    delete_button.focus_neighbor_right = delete_button.get_path_to(scan_button)
    add_button.focus_neighbor_left = add_button.get_path_to(scan_button)
"""), 1, M)),
    only(LEGACY, (EDIT_PLATFORM, r'OS\.get_name\(\) == "Android"(:\n\t+FrontendBridge\.open_folder_picker\()\)',
     rf'OS.get_name() == "Android" or {LINUX}\1rom_folder_path)', 1, M)),
    only(V101, (EDIT_PLATFORM, r'OS\.get_name\(\) == "Android"(:\n\t+FrontendBridge\.open_folder_picker\()\)',
     rf'OS.get_name() == "Android" or {LINUX}\1save_folder_path if _picking_saves_folder else rom_folder_path)', 2, M)),
    # Stop when no folder is set, and scan with the values on the screen.
    # 0.3.2 has no subfolder option.
    *[only(version, (EDIT_PLATFORM, r"^(\tManager\.scan_platform_in_user\()", lambda m, subfolders=subfolders: gd("""\
    if rom_folder_path == "":
        return

    platform.rom_folder_path = rom_folder_path
    platform.app_id = _get_selected_app_id()
""" + subfolders + """\
    platform.hide_duplicates = hide_duplicates_toggle.is_on
""") + m[1], 1, M)) for version, subfolders in ((MODERN, "    platform.scan_subfolders = scan_subfolders_toggle.is_on\n"), (V032, ""))],

    # UI sounds use the "sfx" bus. Make it before the first sound plays.
    ("scripts/screens/screen.gd", r'(_audio\.bus = )"fx"', r'\1"sfx"', 1, M),
    only(MODERN, prepend("scripts/screens/screen.gd", "_collect_and_disable_focus", """\
    if node == self or (node is Screen and not node.visible):
        return
""")),
    only(MODERN, ("scripts/autoload/theme_manager.gd", r"^(func _ready\(\).*\n)", lambda m: gd("""\
func _enter_tree() -> void:
    _apply_ui_sounds_enabled(bool(SettingsManager.get_setting("ui_sounds_enabled")))

""") + m[1] + gd("""\
    _apply_ui_sounds_enabled(bool(SettingsManager.get_setting("ui_sounds_enabled")))
"""), 1, M)),
    only(MODERN, ("scripts/autoload/theme_manager.gd", r"^(func _apply_ui_sounds_enabled\(.*\n\t.*\bbus_index\b.*\n)(?:\t.*\n)+", lambda m: m[1] + gd("""\
    if bus_index == -1:
        AudioServer.add_bus()
        bus_index = AudioServer.bus_count - 1
        AudioServer.set_bus_name(bus_index, "sfx")
    AudioServer.set_bus_volume_db(bus_index, 0.0)
    AudioServer.set_bus_mute(bus_index, not enabled)
"""), 1, M)),
    prepend("scenes/focus_overlay.gd", "_ready", """\
    audio_stream.bus = "sfx"
    z_index = 1
"""),

    # Report a missing image only when the game has an image path.
    only(LEGACY, ("scripts/cartridge.gd", r"^\telse:\n(?=\t\tpush_error\()",
     "\telif not game.support_texture_path.is_empty() or not game.custom_support_image_path.is_empty():\n", 1, M)),
    prepend("scenes/cartridge_carousel.gd", "_ready", """\
    visible_games = mini(visible_games, 3)
"""),

    # Warm the actual renderer before navigation, including empty libraries.
    # Also make small text clean on the panel. See FONT_FIX.
    prepend("scenes/main.gd", "_ready", """\
    if OS.get_name() == "Linux":
""" + FONT_FIX + """\
        await preload("res://addons/FrontendPlugin/shader_startup.gd").run(self)
"""),
    # Draw less of the screen in each 2D frame. See LIGHT_UI.
    only(V101, ("scenes/main.gd", r"^(\t\tawait preload\(\"res://addons/FrontendPlugin/shader_startup\.gd\"\))", gd("""\
        if OS.get_environment("SOCKET_UI_LIGHT") != "0":
            _baseos_light_ui()
""") + r"\1", 1, M)),
    only(V101, ("scenes/main.gd", r"\n+\Z", gd("\n\n\n" + LIGHT_UI), 1, 0)),
    only(V101, ("scenes/liquid_glass.gdshader", r"^(uniform sampler2D screen_texture : hint_screen_texture[^\n]*\n)", lambda m: gd("""\
// GLASS_FLAT is the BaseOS variant for the main menu. It gets the background
// below the panel as inputs and does not read the screen.
#ifdef GLASS_FLAT
uniform sampler2D backdrop_fog : filter_linear, repeat_disable;
uniform vec4 backdrop_color = vec4(0.7, 0.7, 0.7, 1.0);
uniform float backdrop_fog_strength = 0.0;
uniform float backdrop_fog_flip = 0.0;
#else
""") + m[1] + "#endif\n", 1, M)),
    only(V101, ("scenes/liquid_glass.gdshader", r"^(vec3 blurred_screen\(.*?^\}\n)", r"#ifndef GLASS_FLAT\n\1#endif\n", 1, S)),
    only(V101, ("scenes/liquid_glass.gdshader", r"^(\s*)(vec3 bg = blurred_screen\([^\n]*\n)", lambda m: gd("""\
#ifdef GLASS_FLAT
    vec4 fog = texture(backdrop_fog, vec2(warped_uv.x, mix(warped_uv.y, 1.0 - warped_uv.y, backdrop_fog_flip))) * vec4(1.0, 1.0, 1.0, backdrop_fog_strength);
    vec3 bg = mix(backdrop_color.rgb, fog.rgb, fog.a);
#else
""") + m[1] + m[2] + "#endif\n", 1, M)),
    # Startup replaces the delayed/off-frustum upstream warmups on Linux.
    *[only(MODERN, prepend("scenes/cartridge_carousel.gd", func, """\
    if OS.get_name() == "Linux":
        return
""")) for func in ("_warm_up_shaders", "warm_up_platforms")],

    # 3D view: optional frame-rate log, no MSAA, a panel resolution limit,
    # one shadow pass, one tonemap pass and the display edge filter. 0.3.2 has
    # a simpler view.
    # Environment variables select the benchmark candidates for the device.
    *[only(MODERN, edit) for edit in [
    (RENDER_SCALE, r"(?<=\n)(?=\nfunc _ready\(\))", gd(FPS_VARS), 1, M),
    (RENDER_SCALE, r"^(\t_display\.texture = .*\n)", lambda m: m[1] + gd(DISPLAY_MATERIAL + """\
    _display.material = display_material
"""), 1, M),
    (RENDER_SCALE, r"^\tmsaa_3d = .*\n", gd(BENCH_START + TONEMAP + FPS_START), 1, M),
    (RENDER_SCALE, r"^\tvar pixels: = .*\n", "\tvar pixels: = requested.min(native * minf(_scale, _baseos_cap))\n", 1, M),
    (RENDER_SCALE, r"\n+\Z", gd("\n\n" + FPS_PROCESS), 1, 0),
    ]],

    # The old launch flag supplies the default only until the user saves a choice.
    only(V101, ("scripts/autoload/settings_manager.gd", r'^(\t"cartridge_msaa": true,)$',
                r'\1\n\t"high_res_labels": OS.get_environment("SOCKET_3D_SPLIT_LABEL") == "1",', 1, M)),
    only(V101, prepend(RENDER_SCALE, "_on_setting_changed", """\
    if key == "high_res_labels":
        _apply()
""")),
    only(V101, (RENDER_SCALE, r"^(\tvar pixels: = requested\.min\(native .*\n)", lambda m: m[1] + gd("""\
    if OS.get_name() == "Linux" and DisplayServer.get_name() != "headless":
        # Keep the same 3:2 casing projection whether the label pass is on or off.
        if roundi(native.x) * 2 == roundi(native.y) * 3:
            pixels = Vector2(3, 2) * maxf(1.0, roundf(minf(pixels.x / 3.0, pixels.y / 2.0)))
        var split = get_node_or_null("SocketSplitLabel")
        if SettingsManager.get_setting("high_res_labels"):
            if split == null:
                split = load("res://addons/FrontendPlugin/split_label_view.gd").new()
                split.name = "SocketSplitLabel"
                add_child(split)
                split.start(self, _display)
        elif split != null:
            split.free()
"""), 1, M)),

    # 0.3.2 draws the UI and 3D view at the 1920x1280 logical size and the
    # AYN Thor bottom screen every frame. Use panel pixels as 0.8.0 does.
    *[only(V032, edit) for edit in [
    prepend(KEYBOARD_AVOIDER, "_ready", """\
    if OS.get_name() == "Linux":
        # A hidden container stops updating its viewport.
        if has_node("BottomScreen"):
            $BottomScreen.hide()
        # The UI has its own viewport. Draw its vertices on whole panel pixels.
        get_node("MainScreen/SubViewport").snap_2d_vertices_to_pixel = OS.get_environment("SOCKET_UI_SNAP") != "0"
        get_tree().root.size_changed.connect(_baseos_fit_ui)
        $MainScreen.resized.connect(_baseos_fit_ui)
        _baseos_fit_ui()
"""),
    (KEYBOARD_AVOIDER, r"\n+\Z", gd("""


# Render the UI at the panel pixels that the container covers. The 2D
# override keeps the layout in logical units, and the container scale draws
# the texture 1:1 on the panel. Input maps back through the same transforms.
func _baseos_fit_ui() -> void:
    var container: SubViewportContainer = $MainScreen
    var viewport: SubViewport = get_node("MainScreen/SubViewport")
    var root: = get_tree().root
    var logical: = root.get_visible_rect().size
    if root.size.x < 1 or container.size.x < 1.0 or logical.x < 1.0:
        return
    var pixels: = Vector2i((container.size * Vector2(root.size) / logical).round()).maxi(1)
    # Without stretch, the viewport size is the container minimum size. A
    # viewport larger than the layout would grow the container on each resize,
    # so larger screens keep Socket's stretched layout-size viewport.
    if pixels.x > container.size.x or pixels.y > container.size.y:
        container.scale = Vector2.ONE
        viewport.oversampling_override = 0.0
        viewport.size_2d_override = Vector2i.ZERO
        container.stretch = true
        return
    container.stretch = false
    # Glyphs at two times the panel size. See FONT_FIX.
    viewport.oversampling_override = 2.0 * pixels.x / container.size.x if OS.get_environment("SOCKET_UI_FONT") != "0" else 0.0
    viewport.size = pixels
    viewport.size_2d_override = Vector2i(container.size)
    viewport.size_2d_override_stretch = true
    container.scale = container.size / Vector2(pixels)
"""), 1, 0),
    (RENDER_SCALE, r"(?<=\n)(?=\nfunc _ready\(\))", gd(FPS_VARS + "var _baseos_scale: = 1.0\nvar _display: TextureRect\n"), 1, M),
    prepend(RENDER_SCALE, "_ready", BENCH_START + FPS_START + """\
    # The scene sets a second 0.85 scale. Keep the chosen resolution through the display pass.
    scaling_3d_scale = 1.0
    var container := get_parent() as SubViewportContainer
    container.stretch = false
    container.self_modulate.a = 0.0
    _display = TextureRect.new()
    _display.texture = get_texture()
    _display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    _display.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _display.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    container.add_child.call_deferred(_display)
""" + DISPLAY_MATERIAL + """\
    _display.material = display_material
    get_parent().resized.connect(func(): _apply(_baseos_scale))
    get_tree().root.size_changed.connect(func(): _apply(_baseos_scale))
"""),
    (RENDER_SCALE, r"^func _apply\((\w+)(.*\n)(?:\t.*\n)+", lambda m: f"func _apply({m[1]}{m[2]}" + gd(f"""\
    _baseos_scale = {m[1]}
    var container := get_parent() as SubViewportContainer
    var root := get_tree().root
    var logical := root.get_visible_rect().size
    if container == null or container.size.x < 1.0 or logical.x < 1.0 or logical.y < 1.0:
        return
    var panel_scale := clampf({m[1]}, 0.5, 1.0)
    var native := container.size * Vector2(root.size) / logical
    var pixels := (container.size * panel_scale).min(native * minf(panel_scale, _baseos_cap))
    size = Vector2i(pixels.round()).maxi(2)
"""), 1, M),
    (RENDER_SCALE, r"\n+\Z", gd("\n\n" + FPS_PROCESS), 1, 0),
    ]],

    # Shaders: fewer blur taps, and less work per fragment.
    only(MODERN, ("scenes/liquid_glass.gdshader", r"(const int BLUR_TAPS = )\d+;", r"\g<1>4;", 1, M)),
    ("materials/frosted_glass.gdshader", r"(?:^//[^\n]*\n)*^vec3 gaussian_blur\((.*?)\)\{\n.*?^\}", lambda m: gd("""\
// Five taps retain the bright center and soft refraction at handheld resolution.
vec3 gaussian_blur(""") + m[1] + gd("""){
    vec2 radius = pixel_size * blur * 4.0 * 1.5 * 0.7071;
    vec3 color = textureLod(tex, pos, 2.0).rgb * 0.28;
    color += textureLod(tex, pos + vec2(-radius.x, -radius.y), 3.0).rgb * 0.18;
    color += textureLod(tex, pos + vec2( radius.x, -radius.y), 3.0).rgb * 0.18;
    color += textureLod(tex, pos + vec2(-radius.x,  radius.y), 3.0).rgb * 0.18;
    color += textureLod(tex, pos + vec2( radius.x,  radius.y), 3.0).rgb * 0.18;
    return color;
}"""), 1, S),
    *[only(versions, (path, r"^(\theight = h;\n)", lambda m: m[1] + gd("""\
    // A zero fade removes the gradient from the result.
    if (fade == 0.0) {
        return normalize(n);
    }
"""), 1, M)) for versions, path in ((LEGACY, STICKER), (V101, "scenes/paper_sticker_body.gdshaderinc"))],
    # 0.10.1 shares the groove axis with gloss; keep its new shader layout.
    only(LEGACY, (STICKER, r"^(\tvec3 grating_axis = [^\n]*\n)(.*?)"
              r"^((?:\t//[^\n]*\n)*\tfloat tilt_gain = [^\n]*\n\tvec3 view_tilted = [^\n]*\n\tvec3 light_tilted = [^\n]*\n)"
              r"(.*?^\tif \(enable_diffraction\) \{\n)", move_diffraction_setup, 1, S)),
    only(LEGACY, (STICKER, r"\(noise_tex\.rgb \* 2\.0\)", "noise_tex.rgb", 1, M)),
]


SCRAPER = "scripts/models/scrapers/scraper_games_db.gd"
CUSTOMIZE = "scripts/screens/screen_customize.gd"
ACHIEVEMENTS = "scripts/autoload/retro_achievements.gd"
ROMM = "scripts/autoload/romm.gd"


# Use the APK's parser, progress dialogs and cancellation for connected scans.
# Version 0.10.1 also enters _run_scrape directly from Scan All.
WIFI_EDITS = [
    *[(path, r"^(extends [^\n]+(?:\n+class_name [^\n]+)?)$", r'\1\n\nconst BaseOSArt = preload("res://addons/FrontendPlugin/artwork.gd")', 1, M)
      for path in (MANAGER, SCRAPER, CUSTOMIZE, ACHIEVEMENTS)],
    *[only(versions, prepend(MANAGER, func, f"""\
    if OS.get_name() == "Linux":
        if _active_scraper != null:
            return
        var download := BaseOSArt.prepare({platforms})
        save_user()
        user_updated.emit()
        if not download:
            return
""")) for versions, func, platforms in ((LEGACY, "scrape_platform_in_user", "[platform]"), (V101, "_run_scrape", "platforms"))],
    # Defer fetch so an immediate request error can complete the await.
    (MANAGER, r"^(\t+)scraper\.fetch\(\)$", r"\1scraper.fetch.call_deferred()", 1, M),
    only(LEGACY, (MANAGER, r"^(\t\t)(if FileAccess.file_exists\(expected_json_path\).*)$", lambda m: m[1] + gd("""\
if OS.get_name() == "Linux":
    if BaseOSArt.exists(game.game_info_path) and BaseOSArt.has_image(game):
        current_game += 1
        scrape_progress.emit(current_game, total_games)
        ScreenDialog.set_progress(current_game, total_games)
        continue
""").replace("\n", "\n" + m[1]) + "el" + m[2], 1, M)),
    only(LEGACY, (MANAGER, r"^(\t\t)if not scraped_info.is_empty\(\):", r'''\1if OS.get_name() == "Linux":
\1	if scraper.last_failure_offline:
\1		break
\1	BaseOSArt.store(game, base_save_dir + safe_filename, scraped_info, scraped_image, false)
\1elif not scraped_info.is_empty():''', 1, M)),
    only(LEGACY, (MANAGER, r"^(\t_active_scraper = null\n\tscraper.queue_free)", r"\tvar offline := scraper.last_failure_offline\n\1", 1, M)),
    only(LEGACY, (MANAGER, r'^(\t)if _scrape_cancelled:(\n\t\tScreenDialog.display)', r'''\1if offline:
\1	ScreenDialog.display("Scraping", "Artwork service unavailable. Try the scan again.", func(): pass, Callable())
\1elif _scrape_cancelled:\2''', 1, M)),
    only(V101, prepend(MANAGER, "_scan_platform_games", """\
    if OS.get_name() == "Linux" and DirAccess.open(platform.rom_folder_path) == null:
        return false
""")),
    only(V101, (MANAGER, r"^(func _scrape_game\(.*?)(\) -> ScrapeResult:)", r"\1, refresh: bool = false\2", 1, M)),
    only(V101, (MANAGER, r"^(\t)if (FileAccess.file_exists\(json_path\) and FileAccess.file_exists\(image_path\)):", r'''\1if OS.get_name() == "Linux":
\1	if not refresh and BaseOSArt.exists(game.game_info_path) and BaseOSArt.has_image(game):
\1		return ScrapeResult.CACHED
\1elif \2:''', 1, M)),
    only(V101, (MANAGER, r"^(\tvar json_file: = FileAccess.open\(json_path, FileAccess.WRITE\))", lambda m: gd("""\
    if OS.get_name() == "Linux":
        if BaseOSArt.store(game, base_save_dir + safe_filename, scraped_info, scraped_image, refresh):
            return ScrapeResult.MATCHED if BaseOSArt.has_image(game) else ScrapeResult.NO_ART
        return ScrapeResult.NO_ART

""") + m[1], 1, M)),
    # Keep the current files and label settings until a replacement is ready.
    only(V101, (MANAGER, r"^(\tvar base: = scraped_data_dir\(platform\).*?^\tgame.reload_scraped_data\(\)\n)", lambda m: gd("""\
    if OS.get_name() == "Linux":
        if _active_scraper != null:
            return ScrapeResult.CANCELLED
        if not BaseOSArt.online():
            ScreenDialog.display("Scraping", _OFFLINE_MESSAGE, func(): pass, Callable())
            return ScrapeResult.OFFLINE
    else:
""") + re.sub(r"(?m)^(?=.)", "\t", m[1]), 1, S)),
    only(V101, (MANAGER, r"^(\tvar status: ScrapeResult = await _scrape_game\(scraper, platform, game)\)$", r'\1, OS.get_name() == "Linux")', 1, M)),
    only(V101, prepend(MANAGER, "restore_original_art", """\
    var refreshed := OS.get_name() == "Linux"
    if refreshed:
        var status := await rescrape_game(game)
        if status != ScrapeResult.MATCHED:
            return status
""")),
    only(V101, (MANAGER, r"^(\treturn await rescrape_game\(game\))", lambda m: gd("""\
    if refreshed:
        save_user()
        return ScrapeResult.MATCHED
""") + m[1], 1, M)),
    only(V101, prepend(MANAGER, "update_emulator_database_silently", """\
    if OS.get_name() == "Linux":
        return
""")),
    only(V101, prepend(ROMM, "has_credentials", """\
    if OS.get_name() == "Linux":
        return false
""")),
    only(V101, prepend(ROMM, "_request", """\
    if OS.get_name() == "Linux":
        return {"ok": false, "code": 0, "body": PackedByteArray(), "data": null}
""")),
    only(V101, prepend(ROMM, "download_roms", """\
    if OS.get_name() == "Linux":
        return
""")),

    # Verify the upstream service and API revision before packaging its key.
    *[only(versions, (SCRAPER, rf'^(@export var base_url: String = )("{re.escape(origin)}")$', r"\1\2\nconst BASEOS_ORIGIN = \2", 1, M))
      for versions, origin in ((V101, "https://socket.depmots.com"), (LEGACY, "https://gamedb.depmots.com"))],
    *[only(versions, (SCRAPER, rf'^(\tvar url = base_url\.rstrip\("/"\) \+ "/{api}/match\?.*)$', lambda m: gd("""\
    if base_url != BASEOS_ORIGIN:
        last_failure_offline = true
        game_scraping_finished.emit({}, null)
        return
""") + m[1], 1, M)) for versions, api in ((V101, "v2"), (LEGACY, "v1"))],
    only(LEGACY, (SCRAPER, r"^(var api_request: HTTPRequest)", r"var last_failure_offline := false\n\1", 1, M)),
    only(LEGACY, prepend(SCRAPER, "fetch", "    last_failure_offline = false\n")),
    only(LEGACY, (SCRAPER, r'^(\tif err != OK:|\tif result != HTTPRequest.RESULT_SUCCESS or response_code != 200:)$', r"\1\n\t\tlast_failure_offline = true", 2, M)),
    only(V101, (SCRAPER, r"^(\tif response_code != 200:)$", r"\1\n\t\tlast_failure_offline = response_code == 429 or response_code >= 500", 1, M)),
    (SCRAPER, r"^(\tvar game: Dictionary = json_data.get)", lambda m: gd("""\
    if not json_data.get("game") is Dictionary or not json_data.get("labels", []) is Array:
        game_scraping_finished.emit({}, null)
        return
""") + m[1], 1, M),
    (SCRAPER, r"return labels\[0\]", "return labels[0] if labels[0] is Dictionary else {}", 1, M),
    (SCRAPER, r"^(\t)(add_child\(api_request\))", r"\1BaseOSArt.limit_request(api_request, 1048576)\n\1\2", 1, M),
    (SCRAPER, r"^(\t)(add_child\(image_request\))", r"\1BaseOSArt.limit_request(image_request, BaseOSArt.MAX_IMAGE_BYTES)\n\1\2", 1, M),
    (SCRAPER, r"^(func _auth_headers\()\)(.*\n)", r'\1url: String = BASEOS_ORIGIN + "/")\2\tif not url.begins_with(BASEOS_ORIGIN + "/"):\n\t\treturn PackedStringArray()\n', 1, M),
    (SCRAPER, r"image_request.request\(img_url, _auth_headers\(\)\)", 'image_request.request(img_url, _auth_headers(img_url)) if img_url.begins_with("https://") else ERR_INVALID_PARAMETER', 1, M),
    (SCRAPER, r"^\t\tdownloaded_image = Image.new\(\).*?^\telse:", "\t\tdownloaded_image = BaseOSArt.decode_image(body)\n\telse:\n\t\tlast_failure_offline = true", 1, S),
    (CUSTOMIZE, r"^(\t)(add_child\(label_image_request\))", r"\1BaseOSArt.limit_request(label_image_request, BaseOSArt.MAX_IMAGE_BYTES)\n\1\2", 1, M),
    (CUSTOMIZE, r'^(\tvar headers: = )PackedStringArray\(\["X-API-Key: " \+ temp_scraper.api_key\]\)$', r"\1temp_scraper._auth_headers(img_url)", 1, M),
    (CUSTOMIZE, r"^(\t_pending_label = label)$", lambda m: gd("""\
    if not img_url.begins_with("https://") or not _pending_label.is_empty():
        return
    if OS.get_name() == "Linux" and not BaseOSArt.online():
        return
""") + m[1], 1, M),
    (CUSTOMIZE, r"^\tvar img: = Image.new\(\)\n\tif img.load_webp_from_buffer\(body\).*?:\n", "\tvar img := BaseOSArt.decode_image(body)\n\tif img == null:\n", 1, M),
    (CUSTOMIZE, r"^\tvar save_err = img.save_png\(game_instance.support_texture_path\).*?^\tgame_instance.apply_base_label\(label\)\n", lambda m: gd("""\
    if OS.get_name() == "Linux":
        var platform = Manager.current_user.get_platform(game_instance.platform_id)
        if platform == null:
            return
        var details: Dictionary = game_instance._game_info.duplicate()
        details["region"] = label.get("region", "")
        details["texture_url"] = label.get("image_url", "")
        if not BaseOSArt.store(game_instance, BaseOSArt.base_path(platform, game_instance), details, img, true):
            return
    else:
""") + re.sub(r"(?m)^(?=.)", "\t", m[0]), 1, S),

    (CUSTOMIZE, r"^(\tif not main_menu.carousel_3d.refresh_cartridge_model\(game_instance\)):", r"\1 and is_instance_valid(current_node):", 1, M),

    # Use the bridge for full paths, including ROMs in subfolders.
    (ACHIEVEMENTS, r'^(\tif OS.get_name\(\) == "Android" or console_id == 5):', r'\1 or (OS.get_name() == "Linux" and console_id in [4, 6]):', 1, M),
    (ACHIEVEMENTS, r"^(\t+if data is Dictionary):(?=\n\s*_game_list_cache)", r"\1 and not data.is_empty():", 1, M),
    (ACHIEVEMENTS, r"^(\t+)(for entry in data:)$", r"\1\2\n\1\tif not entry is Dictionary:\n\1\t\tcontinue", 1, M),
    (ACHIEVEMENTS, r"^(\t+)(var a: Dictionary = raw_achievements\[key\])$", r"\1if not raw_achievements[key] is Dictionary:\n\1\tcontinue\n\1\2", 1, M),
    (ACHIEVEMENTS, r"^(\t\t\tif not DirAccess.dir_exists_absolute\(GAME_LIST_CACHE_DIR\))", lambda m: gd("""\
            if hash_map.is_empty():
                on_complete.call({})
                return
""") + m[1], 1, M),
    (ACHIEVEMENTS, r"^\t\t_game_list_cache\[console_id\] = hash_map$", "\t\tif not hash_map.is_empty():\n\t\t\t_game_list_cache[console_id] = hash_map", 1, M),
    (ACHIEVEMENTS, r"^(\t\tvar game_id: int = hash_map.get)", lambda m: gd("""\
        if hash_map.is_empty():
            on_complete.call(NO_CREDENTIALS_OR_IO_ERROR, rom_hash)
            return
""") + m[1], 1, M),
    *[(ACHIEVEMENTS, rf'^(\tvar url: = "%s{prefix})', lambda m, failure=failure: gd(f"""\
    if OS.get_name() == "Linux" and not BaseOSArt.online():
        {failure}
        return
""") + m[1], 1, M) for prefix, failure in (
        ("API_GetGameList", "on_complete.call({})"), ("API_GetGameInfoAndUserProgress", "on_complete.call([])"),
        ("%s%s\\.png", "on_loaded.call(null)"))],
    (ACHIEVEMENTS, r"^(\tvar request: = HTTPRequest.new\(\))$", r"\1\n\tBaseOSArt.limit_request(request, BaseOSArt.MAX_IMAGE_BYTES)", 3, M),
    (ACHIEVEMENTS, r"^(\tif badge_name.is_empty\(\)):", r"\1 or not badge_name.is_valid_filename():", 1, M),
    (ACHIEVEMENTS, r"^\t\tvar img: = Image.new\(\)\n\t\tif img.load_png_from_buffer\(body\) != OK:", "\t\tvar img := BaseOSArt.decode_image(body)\n\t\tif img == null:", 1, M),
]
EDITS.extend(WIFI_EDITS)


def socket_version(project_binary):
    """Read application/config/version from a binary project.godot (ECFG)."""
    limit = 1024 * 1024
    with open(project_binary, "rb") as project:
        data = project.read(limit + 1)
    if not 8 <= len(data) <= limit or data[:4] != b"ECFG":
        return None
    count, = struct.unpack_from("<I", data, 4)
    if count > (len(data) - 8) // 8:
        return None
    at, version = 8, None
    for _ in range(count):
        if at + 4 > len(data):
            return None
        key_size, = struct.unpack_from("<I", data, at)
        at += 4
        end = at + key_size
        if end + 4 > len(data):
            return None
        is_version = data[at:end] == b"application/config/version"
        length, = struct.unpack_from("<I", data, end)
        at = end + 4
        if at + length > len(data):
            return None
        if is_version:
            if version is not None or not 8 <= length <= 40:
                return None
            kind, size = struct.unpack_from("<II", data, at)
            if kind != 4 or length != 8 + size + (-size % 4):
                return None
            version = data[at + 8:at + 8 + size].decode("ascii", errors="replace")
        at += length
    return version if at == len(data) else None


def validate_version(project_binary):
    version = socket_version(project_binary)
    if version not in VERSIONS:
        raise ValueError(f"Socket version is not supported; use {' or '.join(VERSIONS)}")
    return version


def main(root, project_binary):
    try:
        version = validate_version(project_binary)
    except ValueError as exc:
        sys.exit(f"patch-socket: {exc}")
    files = {}
    for path, pattern, repl, count, flags, *versions in EDITS:
        if versions and version not in versions:
            continue
        if path not in files:
            with open(f"{root}/{path}", encoding="utf-8") as source:
                files[path] = source.read()
        files[path], n = re.subn(pattern, repl, files[path], flags=flags)
        if n != count:
            sys.exit(f"patch-socket: {path}: /{pattern[:60]}/ matched {n} times, expected {count}")
    for path, text in files.items():
        with open(f"{root}/{path}", "w", encoding="utf-8") as f:
            f.write(text)
    return version


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
