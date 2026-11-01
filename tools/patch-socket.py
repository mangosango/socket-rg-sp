"""Apply the BaseOS changes to Socket sources decoded from your APK.

Usage: python3 -I patch-socket.py <src-dir> <project.binary>

Each edit is a short regular expression that finds a place in a Socket file,
and the BaseOS text that goes there. Anchors are function names, Godot API
calls and platform checks. This file does not contain Socket source; text that
moves is captured from your copy. If an anchor does not match the expected
number of times, the script stops and changes no files.

Supported Socket versions: 0.8.0 and 0.3.2. The version comes from
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
    """Apply an edit only to one Socket version."""
    return edit + (version,)


LINUX = 'OS.get_name() == "Linux"'
V080, V032 = "0.8.0", "0.3.2"
VERSIONS = (V080, V032)

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
"""
FPS_START = """\
    set_process(OS.get_environment("SOCKET_FPS_DIAGNOSTICS") == "1")
    if is_processing():
        _fps_started_usec = Time.get_ticks_usec()
        _fps_last_usec = _fps_started_usec
        _fps_drawn_frames = Engine.get_frames_drawn()
        _fps_log = FileAccess.open("user://render-performance.jsonl", FileAccess.WRITE)
        if _fps_log == null:
            push_error("Socket: cannot open render-performance.jsonl: " + str(FileAccess.get_open_error()))
"""
FPS_PROCESS = """\
func _process(_delta: float) -> void:
    var now: = Time.get_ticks_usec()
    _fps_worst_usec = maxi(_fps_worst_usec, now - _fps_last_usec)
    _fps_last_usec = now
    _fps_frames += 1
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
    var line: = JSON.stringify(sample)
    if _fps_log != null:
        _fps_log.store_line(line)
        _fps_log.flush()
    print("Socket render: ", line)
    _fps_started_usec = now
    _fps_drawn_frames = drawn
    _fps_frames = 0
    _fps_worst_usec = 0
"""


# (file, pattern, replacement, expected matches, flags[, version])
EDITS = [
    # Scrape results: reload the texture and game info after the paths change.
    # Runs before the Linux scrape is added below, which sets both itself.
    (MANAGER, r"^(\t+)(game\.support_texture_path = .*\n)", r"\1\2\1game.force_reload_texture()\n", 2, M),
    (MANAGER, r"^(\t+)(game\.game_info_path = .*\n)", r"\1\2\1game._game_info_loaded = false\n", 2, M),
    only(V080, prepend(MANAGER, "needs_emulator_database", """\
    if OS.get_name() == "Linux":
        return false
""")),
    only(V080, (MANAGER, r"^(\tconst TITLE\b.*\n)", lambda m: m[1] + gd("""\
    if OS.get_name() == "Linux":
        ScreenDialog.display(TITLE, "Use the Mac setup tool to update emulator lists on the SD card.", func(): pass, Callable())
        return
"""), 1, M)),
    # Start RetroArch on Linux. 0.3.2 has no play sessions.
    *[only(version, (MANAGER, r"^(\t\tFrontendBridge\.launch_emulator\(intent_params\)\n)", lambda m, session=session: m[1] + gd("""\
    elif OS.get_name() == "Linux":
        var core: String = FrontendBridge.libretro_core(raw_args)
        if core.is_empty():
            ScreenDialog.display("Cannot Launch", "BaseOS runs RetroArch emulators only. Choose a RetroArch core for this platform and add its _libretro.so file to System/socket/cores.", func(): pass, Callable())
            return
""" + session + """\
        FrontendBridge.launch_emulator({"core": core, "rom": game.rom_path, "platform": game.platform_id})
"""), 1, M)) for version, session in ((V080, '        _begin_play_session(game, "retroarch")\n'), (V032, ""))],
    # Use the bridge on Linux for play time and folder listing.
    (MANAGER, r'OS\.get_name\(\) == "Android"(:\n\t+[^\n]*FrontendBridge\.get_files_in_dir\()',
     rf'OS.get_name() == "Android" or {LINUX}\1', 2, M),
    only(V080, (MANAGER, r'OS\.get_name\(\) == "Android"(:\n\t+[^\n]*FrontendBridge\.get_foreground_seconds\()',
     rf'OS.get_name() == "Android" or {LINUX}\1', 1, M)),
    prepend(MANAGER, "scan_platform_in_user", """\
    if OS.get_name() == "Linux" and not platform.rom_folder_path.is_empty() and DirAccess.open(platform.rom_folder_path) == null:
        print("BaseOS: cannot open ROM folder: ", platform.rom_folder_path)
        return
"""),
    # Save the scan before the scrape so the library shows the games at once.
    (MANAGER, r"^(\tawait scrape_platform_in_user\()", r"\tsave_user()\n\tuser_updated.emit()\n\n\1", 1, M),
    # BaseOS has no network scrape. Use artwork that the Mac setup tool cached.
    prepend(MANAGER, "scrape_platform_in_user", """\
    if OS.get_name() == "Linux":
        var cache_dir = "user://scraped_data/" + platform.model.abbreviation.to_lower() + "/"
        for game in platform.games:
            var cache_path = cache_dir + game.rom_name.validate_filename()
            if game.game_info_path.is_empty() and FileAccess.file_exists(cache_path + ".json"):
                game.game_info_path = cache_path + ".json"
                game._game_info_loaded = false
            if game.support_texture_path.is_empty() and FileAccess.file_exists(cache_path + "_support.png"):
                game.support_texture_path = cache_path + "_support.png"
                game.force_reload_texture()
        save_user()
        user_updated.emit()
        return

"""),
    # Offer only emulator entries that have a RetroArch core on the card.
    (MANAGER, r'^(\t+)if (OS\.get_name\(\) != "Android" or installed_apps\.has\()',
     lambda m: f'{m[1]}if OS.get_name() == "Linux":\n'
               f'{m[1]}\tif not FrontendBridge.libretro_core(am_args).is_empty():\n'
               f'{m[1]}\t\tapp_options.append({{"id": full_unique_id, "label": app.name}})\n'
               f'{m[1]}elif {m[2]}', 1, M),
    (MANAGER, r'^(func _get_app_by_id\(.*\n\tif OS\.get_name\(\) != "Android")', r'\1 and OS.get_name() != "Linux"', 1, M),

    # 0.3.2 reads the app list on every platform.
    only(V080, ("scenes/screen_apps.gd", r'(get_installed_app_list\([^)]*\) if OS\.get_name\(\) == "Android")', rf"\1 or {LINUX}", 1, M)),

    only(V080, (EDIT_PLATFORM, r"^(\tsuper\._ready\(\)\n)", lambda m: m[1] + gd("""
    var scan_button: Button = add_button.get_node("../Button_Scan")
    delete_button.focus_neighbor_right = delete_button.get_path_to(scan_button)
    add_button.focus_neighbor_left = add_button.get_path_to(scan_button)
"""), 1, M)),
    (EDIT_PLATFORM, r'OS\.get_name\(\) == "Android"(:\n\t+FrontendBridge\.open_folder_picker\()\)',
     rf'OS.get_name() == "Android" or {LINUX}\1rom_folder_path)', 1, M),
    # Stop when no folder is set, and scan with the values on the screen.
    # 0.3.2 has no subfolder option.
    *[only(version, (EDIT_PLATFORM, r"^(\tManager\.scan_platform_in_user\()", lambda m, subfolders=subfolders: gd("""\
    if rom_folder_path == "":
        return

    platform.rom_folder_path = rom_folder_path
    platform.app_id = _get_selected_app_id()
""" + subfolders + """\
    platform.hide_duplicates = hide_duplicates_toggle.is_on
""") + m[1], 1, M)) for version, subfolders in ((V080, "    platform.scan_subfolders = scan_subfolders_toggle.is_on\n"), (V032, ""))],

    # UI sounds use the "sfx" bus. Make it before the first sound plays.
    ("scripts/screens/screen.gd", r'(_audio\.bus = )"fx"', r'\1"sfx"', 1, M),
    only(V080, prepend("scripts/screens/screen.gd", "_collect_and_disable_focus", """\
    if node == self or (node is Screen and not node.visible):
        return
""")),
    only(V080, ("scripts/autoload/theme_manager.gd", r"^(func _ready\(\).*\n)", lambda m: gd("""\
func _enter_tree() -> void:
    _apply_ui_sounds_enabled(bool(SettingsManager.get_setting("ui_sounds_enabled")))

""") + m[1] + gd("""\
    _apply_ui_sounds_enabled(bool(SettingsManager.get_setting("ui_sounds_enabled")))
"""), 1, M)),
    only(V080, ("scripts/autoload/theme_manager.gd", r"^(func _apply_ui_sounds_enabled\(.*\n\t.*\bbus_index\b.*\n)(?:\t.*\n)+", lambda m: m[1] + gd("""\
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
    ("scripts/cartridge.gd", r"^\telse:\n(?=\t\tpush_error\()",
     "\telif not game.support_texture_path.is_empty() or not game.custom_support_image_path.is_empty():\n", 1, M),
    prepend("scenes/cartridge_carousel.gd", "_ready", """\
    visible_games = mini(visible_games, 3)
"""),

    # 3D view: optional frame-rate log, no MSAA, a 2/3 resolution limit,
    # one tonemap pass and the display edge filter. 0.3.2 has a simpler view.
    *[only(V080, edit) for edit in [
    (RENDER_SCALE, r"(?<=\n)(?=\nfunc _ready\(\))", gd(FPS_VARS), 1, M),
    (RENDER_SCALE, r"^(\t_display\.texture = .*\n)", lambda m: m[1] + gd("""\
    var display_material := ShaderMaterial.new()
    display_material.shader = load("res://shaders/display_aa.gdshader")
    _display.material = display_material
"""), 1, M),
    (RENDER_SCALE, r"^\tmsaa_3d = .*\n", gd("""\
    msaa_3d = Viewport.MSAA_DISABLED
    # Compatibility tonemaps each shadowed light pass alone, so lit labels clip.
    # Neutral adjustments make Godot tonemap once after all passes. A mild
    # Reinhard curve then keeps highlight detail. The 2D UI does not change.
    for node in find_children("*", "WorldEnvironment", true, false):
        var world: = node as WorldEnvironment
        if world.environment == null:
            continue
        world.environment = world.environment.duplicate()
        world.environment.tonemap_mode = Environment.TONE_MAPPER_REINHARDT
        world.environment.tonemap_white = 1.3
        world.environment.adjustment_enabled = true
        world.environment.adjustment_brightness = 1.0
        world.environment.adjustment_contrast = 1.0
        world.environment.adjustment_saturation = 1.05
""" + FPS_START), 1, M),
    (RENDER_SCALE, r"^\tvar pixels: = .*\n", "\tvar pixels: = requested.min(native * (2.0 / 3.0))\n", 1, M),
    (RENDER_SCALE, r"\n+\Z", gd("\n\n" + FPS_PROCESS), 1, 0),
    ]],

    # 0.3.2 draws the UI and 3D view at the 1920x1280 logical size and the
    # AYN Thor bottom screen every frame. Use panel pixels as 0.8.0 does.
    *[only(V032, edit) for edit in [
    prepend(KEYBOARD_AVOIDER, "_ready", """\
    if OS.get_name() == "Linux":
        # A hidden container stops updating its viewport.
        if has_node("BottomScreen"):
            $BottomScreen.hide()
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
        viewport.size_2d_override = Vector2i.ZERO
        container.stretch = true
        return
    container.stretch = false
    viewport.size = pixels
    viewport.size_2d_override = Vector2i(container.size)
    viewport.size_2d_override_stretch = true
    container.scale = container.size / Vector2(pixels)
"""), 1, 0),
    (RENDER_SCALE, r"(?<=\n)(?=\nfunc _ready\(\))", gd(FPS_VARS + "var _baseos_scale: = 1.0\n"), 1, M),
    prepend(RENDER_SCALE, "_ready", FPS_START + """\
    # Filter edges after the upscale, and size the view again on screen changes.
    var display_material := ShaderMaterial.new()
    display_material.shader = load("res://shaders/display_aa.gdshader")
    get_parent().material = display_material
    get_parent().resized.connect(func(): _apply(_baseos_scale))
    get_tree().root.size_changed.connect(func(): _apply(_baseos_scale))
"""),
    (RENDER_SCALE, r"^func _apply\((\w+)(.*\n)(?:\t.*\n)+", lambda m: f"func _apply({m[1]}{m[2]}" + gd(f"""\
    # Render 3D at most at 2/3 of the panel pixels. An integer shrink of the
    # container lowers the pixels and the 3D scale sets the rest.
    _baseos_scale = {m[1]}
    var container: = get_parent() as SubViewportContainer
    var root: = get_tree().root
    var logical: = root.get_visible_rect().size.x
    if container == null or container.size.x < 1.0 or logical < 1.0:
        scaling_3d_scale = clampf({m[1]}, 0.5, 1.0)
        return
    var native: = container.size.x * root.size.x / logical
    var target: = minf(container.size.x * clampf({m[1]}, 0.5, 1.0), native * 2.0 / 3.0)
    container.stretch_shrink = maxi(1, floori(container.size.x / target))
    scaling_3d_scale = clampf(target * container.stretch_shrink / container.size.x, 0.25, 1.0)
"""), 1, M),
    (RENDER_SCALE, r"\n+\Z", gd("\n\n" + FPS_PROCESS), 1, 0),
    ]],

    # Shaders: fewer blur taps, and less work per fragment.
    only(V080, ("scenes/liquid_glass.gdshader", r"(const int BLUR_TAPS = )\d+;", r"\g<1>4;", 1, M)),
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
    (STICKER, r"^(\theight = h;\n)", lambda m: m[1] + gd("""\
    // A zero fade removes the gradient from the result.
    if (fade == 0.0) {
        return normalize(n);
    }
"""), 1, M),
    (STICKER, r"^(\tvec3 grating_axis = [^\n]*\n)(.*?)"
              r"^((?:\t//[^\n]*\n)*\tfloat tilt_gain = [^\n]*\n\tvec3 view_tilted = [^\n]*\n\tvec3 light_tilted = [^\n]*\n)"
              r"(.*?^\tif \(enable_diffraction\) \{\n)", move_diffraction_setup, 1, S),
    (STICKER, r"\(noise_tex\.rgb \* 2\.0\)", "noise_tex.rgb", 1, M),
]


def socket_version(project_binary):
    """Read application/config/version from a binary project.godot (ECFG)."""
    data = open(project_binary, "rb").read()
    key = b"application/config/version"
    at = data.find(struct.pack("<I", len(key)) + key)
    if data[:4] != b"ECFG" or at < 0:
        return None
    # Key, then the encoded value size and a String variant: type 4, length, bytes.
    kind, size = struct.unpack_from("<II", data, at + 4 + len(key) + 4)
    start = at + 4 + len(key) + 12
    return data[start:start + size].decode() if kind == 4 else None


def main(root, project_binary):
    version = socket_version(project_binary)
    if version not in VERSIONS:
        sys.exit(f"patch-socket: Socket {version} is not supported; use {' or '.join(VERSIONS)}")
    files = {}
    for path, pattern, repl, count, flags, *versions in EDITS:
        if versions and version not in versions:
            continue
        if path not in files:
            files[path] = open(f"{root}/{path}", encoding="utf-8").read()
        files[path], n = re.subn(pattern, repl, files[path], flags=flags)
        if n != count:
            sys.exit(f"patch-socket: {path}: /{pattern[:60]}/ matched {n} times, expected {count}")
    for path, text in files.items():
        with open(f"{root}/{path}", "w", encoding="utf-8") as f:
            f.write(text)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
