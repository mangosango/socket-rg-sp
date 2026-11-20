# Opt-in render benchmark of the packed app. It is not a pass/fail test of the pack.
# One camera and one fixture library (five GBA games, three cartridges in view).
# The default suite changes settings within one process. The opt-in label
# comparison measures the startup settings of four separate processes.
#
# Run on Mesa GLES (software renderer, Docker):
#   sh tests/app/run_bench_render.sh <pack.pck> <new-directory> [NAME=value ...]
# Summarize: python3 tests/app/bench_report.py <directory>/results.jsonl
#
# Mesa llvmpipe rasterizes on the host CPU. Its times show the relative pixel
# and shader work only. They are NOT Mali times. Draw calls, primitives and the
# edge-quality numbers do not depend on the GPU speed.
#
# Run on the RG SP (Mali): see tests/app/bench_device.sh. The two runs use the same
# launcher, the engine options of the card and the settings file of the card.
# The fixture library and its ROM files go to /tmp, not to the card. This script
# stops if the app data folder is not below /tmp, so it cannot change the saves.
#
# The variant `as_started` measures the startup settings.
# The other variants set each value, so they do not depend on the launcher.
#
# Variables:
#   SOCKET_BENCH_FRAMES   timed frames for each variant and round (default 60)
#   SOCKET_BENCH_ROUNDS   rounds; the variants are interleaved (default 5)
#   SOCKET_BENCH_ONLY     comma list of variant names; empty runs all
#   SOCKET_BENCH_QUALITY  0 skips the edge-quality captures
#   SOCKET_BENCH_SYNC     1 reads the frame back each frame (forces the GPU to finish)
#   SOCKET_BENCH_IMAGES   0 does not save a frame image for each variant
#   SOCKET_BENCH_VSYNC    1 keeps vertical sync on (times then step by 16.7 ms)
#   SOCKET_BENCH_LABEL_COMPARE  1: opaque scale comparison; 66: animated translucent GBA at 0.66
#   SOCKET_TEST_ROOT      folder below /tmp for the fixture ROM files (necessary)
extends SceneTree

const DEFAULTS := {"cap": 2.0 / 3.0, "filter": "edge", "shadows": "4", "msaa": 0, "carts": true, "view3d": true, "display": true, "post": true, "casing": "", "label": "", "hide": []}
# Timed variants. Each entry: name, changes to DEFAULTS.
var VARIANTS := [
	# The app as the launcher started it: no value is set.
	["as_started", null],
	# Comparison configuration: 480x320, current edge filter, four shadow splits.
	["base", {}],
	# Parts of the frame.
	["3d_frozen", {"view3d": false}],
	["3d_frozen_no_display", {"view3d": false, "display": false}],
	["no_carts", {"carts": false}],
	["no_post", {"post": false}],
	["ui_no_dots", {"hide": ["dots"]}],
	["ui_no_outline", {"hide": ["outline"]}],
	["ui_no_glass", {"hide": ["glass"]}],
	["ui_no_controls", {"hide": ["controls"]}],
	["ui_none", {"hide": ["dots", "outline", "glass", "controls"]}],
	["ui_none_3d_frozen", {"hide": ["dots", "outline", "glass", "controls"], "view3d": false}],
	["nothing", {"hide": ["dots", "outline", "glass", "controls"], "view3d": false, "display": false}],
	# Shadows.
	["shadows_1", {"shadows": "1"}],
	["shadows_off", {"shadows": "0"}],
	# Labels. The casing finishes are added at run time.
	["label_holo_foil", {"label": "holo_foil_sticker"}],
	["label_chrome", {"label": "chrome_outline_sticker"}],
	# Antialiasing and 3D size.
	["linear", {"filter": "linear"}],
	["msaa2", {"msaa": 2}],
	["msaa4", {"msaa": 4}],
	["msaa2_linear", {"msaa": 2, "filter": "linear"}],
	["msaa4_linear", {"msaa": 4, "filter": "linear"}],
	["cap0.5", {"cap": 0.5}],
	["cap0.8334", {"cap": 0.8334}],
	["cap0.8334_linear", {"cap": 0.8334, "filter": "linear"}],
	["cap0.8334_msaa2_linear", {"cap": 0.8334, "filter": "linear", "msaa": 2}],
	["cap1", {"cap": 1.0}],
	["cap1_linear", {"cap": 1.0, "filter": "linear"}],
	["cap1_msaa2_linear", {"cap": 1.0, "filter": "linear", "msaa": 2}],
	["cap1_msaa4_linear", {"cap": 1.0, "filter": "linear", "msaa": 4}],
	# The card before the change: 600x400, linear display, one shadow pass.
	["previous_card", {"cap": 0.8334, "filter": "linear", "shadows": "1"}],
	# Compare the two display filters at the default 540x360 with all other settings equal.
	["linear_075", {"cap": 0.75, "filter": "linear", "shadows": "1"}],
	["new_card", {"cap": 0.75, "filter": "edge", "shadows": "1"}],
]
# Variants that change the 3D image edges. Only these get a quality capture.
const QUALITY_KEYS := ["cap", "filter", "msaa"]

var home
var carousel
var view: SubViewport
var display: CanvasItem
var edge_shader: Shader
var linear_shader: Shader
var lights := []
var environment: Environment
var environment_default := {}
var casings := []  # [mesh, original override]
var labels := []  # [mesh, surface, original material, original override]
var finishes := {}
var hidden := []
var log_file: FileAccess

func _initialize() -> void:
	_run.call_deferred()

func fail(message: String) -> void:
	printerr("FAIL: ", message)
	quit(1)

func write(record: Dictionary) -> void:
	log_file.store_line(JSON.stringify(record))
	log_file.flush()

func global_class(name: String) -> Script:
	for entry in ProjectSettings.get_global_class_list():
		if entry["class"] == name:
			return load(entry["path"])
	return null

func _run() -> void:
	OS.low_processor_usage_mode = false
	root.size = Vector2i(720, 480)
	var output := OS.get_environment("SOCKET_EVIDENCE")
	if not OS.get_user_data_dir().begins_with("/tmp/"): return fail("set XDG_DATA_HOME to a folder below /tmp; the fixture library must not change the saves: " + OS.get_user_data_dir())
	var roms := OS.get_environment("SOCKET_TEST_ROOT")
	if not roms.begins_with("/tmp/") or not DirAccess.dir_exists_absolute(roms): return fail("set SOCKET_TEST_ROOT to a folder below /tmp")
	log_file = FileAccess.open(output.path_join("results.jsonl"), FileAccess.WRITE)
	if log_file == null: return fail("cannot write results.jsonl")
	var manager = root.get_node("Manager")
	load("res://scripts/models/emulator_database.gd").store("gba", [{"uniqueId": "gba.ra64.mgba", "name": "mGBA", "acceptedFilenameRegex": "[.]gba$", "amStartArguments": "-n com.retroarch/.Main -e LIBRETRO mgba"}])
	# A settings change here would reload the scene. The launcher supplies the settings file.
	var settings = root.get_node("SettingsManager")
	var label_trial := OS.get_environment("SOCKET_BENCH_LABEL_TRIAL")
	var requested_scale := OS.get_environment("SOCKET_BENCH_BODY_SCALE").to_float()
	var requested_split := OS.get_environment("SOCKET_3D_SPLIT_LABEL") == "1"
	if not label_trial.is_empty() and not is_equal_approx(float(settings.get_setting("render_scale_3d")), requested_scale):
		return fail("temporary profile has the requested body scale")
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	var screen = load("res://scripts/screens/screen.gd")
	for i in range(40000):
		home = screen.get_screen("main")
		if home != null and home.is_node_ready() and root.get_meta("socket_shader_startup_complete", false): break
		await process_frame
	if home == null or not root.get_meta("socket_shader_startup_complete", false): return fail("startup completes")

	# Five games exercise artwork prefetch for games outside the three visible slots.
	var art := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	for y in range(256):
		for x in range(256):
			art.set_pixel(x, y, Color(0.9, 0.2, 0.15) if (x / 16 + y / 16) % 2 == 0 else Color.WHITE)
	DirAccess.make_dir_recursive_absolute("user://scraped_data/gba")
	var platform = load("res://scripts/platform.gd").new()
	platform.model = manager.db.get_platform("gba").new()
	platform.app_id = "gba.ra64.mgba"
	platform.rom_folder_path = roms
	manager.add_platform_to_user(manager.current_user, platform)
	var fixture_games := ["One", "Two", "Three", "Four", "Five"]
	var finish_id := "translucent" if OS.get_environment("SOCKET_BENCH_FINISH") == "translucent" else "opaque"
	var animate := not label_trial.is_empty() and finish_id == "translucent"
	var fixture_meta := {} if label_trial.is_empty() else {"cart_material": finish_id}
	for game_name in fixture_games:
		FileAccess.open(platform.rom_folder_path.path_join(game_name + ".gba"), FileAccess.WRITE).close()
		art.save_png("user://scraped_data/gba/%s_support.png" % game_name)
		var info := FileAccess.open("user://scraped_data/gba/%s.json" % game_name, FileAccess.WRITE)
		info.store_string(JSON.stringify({"matched": true, "method": "md5", "game_id": 1, "name": game_name, "platform": "nintendo-game-boy-advance", "region": "World", "texture_url": "", "labels": [], "meta": fixture_meta}))
		info.close()
	await manager.scan_platform_in_user(manager.current_user, platform)
	home.selected_platform_index = home._get_visible_platforms().find(platform)
	home.render_carousel()
	carousel = home.carousel_3d
	if not label_trial.is_empty():
		if carousel.games.size() != fixture_games.size(): return fail("all five fixture games are in the carousel")
		if not animate:
			carousel.float_amplitude = 0.0
			carousel.rotation_amplitude = 0.0
	for i in range(200): await process_frame
	# A cartridge on each side of the selected one.
	carousel.next()
	for i in range(120): await process_frame
	# Wait until the carousel's own shader warm-up meshes are gone.
	var quiet := 0
	for i in range(3000):
		quiet = 0 if carousel.get_children().any(func(node): return node is MeshInstance3D and node.material_override) else quiet + 1
		if quiet >= 30: break
		await process_frame
	if not label_trial.is_empty() and quiet < 30: return fail("carousel shader warm-up finishes")
	if carousel.active_cartridges.size() != 3: return fail("three cartridges are in view: %d" % carousel.active_cartridges.size())
	# Same pose for each variant.
	carousel.set_process(false)

	view = home.viewport_3d
	display = view.get("_display")
	if display == null or not display.material is ShaderMaterial: return fail("the 3D view has the display pass")
	lights = view.find_children("*", "Light3D", true, false).filter(func(light): return light.get_viewport() == view)
	if label_trial.is_empty():
		edge_shader = load("res://shaders/display_aa.gdshader")
		linear_shader = Shader.new()
		linear_shader.code = "#define DISPLAY_LINEAR\n" + edge_shader.code
		environment = view.find_children("*", "WorldEnvironment", true, false)[0].environment
		environment_default = {"tonemap": environment.tonemap_mode, "adjust": environment.adjustment_enabled}
	for cart in carousel.active_cartridges.values():
		if not label_trial.is_empty():
			if cart.game.platform_id != "gba" or cart.resolve_finish_id(cart.game.custom_material_index) != finish_id:
				return fail("label comparison requires " + finish_id + " GBA cartridges")
			# Read the authored label, not any additional surfaces created by the split renderer.
			var cover = cart.get_cover_material()
			if not cover is ShaderMaterial or not cover.get_shader_parameter("artwork_texture") is Texture2D:
				return fail("each visible paper label samples the fixture artwork")
			continue
		for mesh in cart.casing_meshs:
			if mesh.get_surface_override_material_count() > 0:
				casings.append([mesh, mesh.get_surface_override_material(0), cart])
		for mesh in cart.find_children("*", "MeshInstance3D", true, false):
			for surface in (mesh.mesh.get_surface_count() if mesh.mesh else 0):
				var material = mesh.get_active_material(surface)
				if material is ShaderMaterial and material.shader and material.shader.resource_path.ends_with("paper_sticker.gdshader"):
					labels.append([mesh, surface, material, mesh.get_surface_override_material(surface)])
	var bank := global_class("CartFinishBank") if label_trial.is_empty() else null
	if bank != null:
		var at := VARIANTS.find_custom(func(variant): return variant[0] == "label_holo_foil")
		for finish in bank.all():
			finishes[String(finish.id)] = finish
			VARIANTS.insert(at, ["casing_" + String(finish.id), {"casing": String(finish.id)}])
			at += 1

	# Measure work, not the display rate.
	Engine.max_fps = 0
	if OS.get_environment("SOCKET_BENCH_VSYNC") != "1":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	RenderingServer.viewport_set_measure_render_time(view.get_viewport_rid(), true)
	var only := Array(OS.get_environment("SOCKET_BENCH_ONLY").split(",", false))
	var variants := VARIANTS.filter(func(variant): return only.is_empty() or variant[0] in only)
	var frames := maxi(OS.get_environment("SOCKET_BENCH_FRAMES").to_int(), 0) if OS.has_environment("SOCKET_BENCH_FRAMES") else 60
	var rounds := OS.get_environment("SOCKET_BENCH_ROUNDS").to_int() if OS.has_environment("SOCKET_BENCH_ROUNDS") else 5
	var sync := OS.get_environment("SOCKET_BENCH_SYNC") == "1"
	if not label_trial.is_empty():
		if frames < 1 or rounds < 1: return fail("label comparison needs positive frames and rounds")
		variants = [[label_trial, null]]
	var run := {"type": "run", "renderer": RenderingServer.get_video_adapter_name(), "vendor": RenderingServer.get_video_adapter_vendor(), "api": RenderingServer.get_video_adapter_api_version(),
		"window": [root.size.x, root.size.y], "vsync": DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED, "frames": frames, "rounds": rounds, "sync": sync, "cartridges": carousel.active_cartridges.size(), "finishes": finishes.keys(), "label_surfaces": labels.size() if label_trial.is_empty() else carousel.active_cartridges.size(),
		# The startup profile of this run.
		"shader_startup": root.get_meta("socket_shader_startup_stats", {}),
		"settings": ["dark_mode", "theme_id", "font_id", "background_pattern", "background_gradient", "render_scale_3d", "max_fps", "ui_scale"].map(func(key): return [key, settings.get_setting(key)]),
		"environment": ["SOCKET_3D_CAP", "SOCKET_3D_FILTER", "SOCKET_3D_SHADOWS", "SOCKET_3D_MSAA", "SOCKET_UI_SNAP", "SOCKET_UI_FONT", "SOCKET_FPS_DIAGNOSTICS"].map(func(key): return [key, OS.get_environment(key)]),
		"started": {"viewport_3d": [view.size.x, view.size.y], "msaa_3d": view.msaa_3d, "linear": display.material.shader.code.begins_with("#define DISPLAY_LINEAR"),
			"shadows": lights.filter(func(light): return light.shadow_enabled).map(func(light): return light.directional_shadow_mode if light is DirectionalLight3D else -1)}}
	if not label_trial.is_empty():
		run.merge({"requested_mode": label_trial, "requested_body_scale": requested_scale, "requested_split_label": requested_split, "fixture": finish_id + "_gba", "animated": animate, "games": fixture_games})
	write(run)

	# Measure the untouched startup profile before any trial changes the viewport.
	var trials := []
	for untouched in [true, false]:
		for round in range(rounds):
			for variant in variants:
				if (variant[1] == null) == untouched:
					trials.append([round, variant])
	for trial in trials:
		var round: int = trial[0]
		var variant: Array = trial[1]
		if variant[1] != null:
			await apply(DEFAULTS.merged(variant[1], true))
		if not label_trial.is_empty():
			var label := split_label_viewport()
			if label != null:
				RenderingServer.viewport_set_measure_render_time(label.get_viewport_rid(), true)
		# The first frames after a change can compile shaders or allocate targets.
		for i in range(8): await process_frame
		var times := PackedFloat64Array()
		var steady_split_frames := 0
		if animate:
			carousel.set("_time", 0.0)
		var last := Time.get_ticks_usec()
		for i in range(frames):
			if animate:
				# Same 60 Hz tilt poses in every trial, independent of actual frame rate.
				carousel._process(1.0 / 60.0)
			await process_frame
			if sync:
				root.get_texture().get_image()
			var now := Time.get_ticks_usec()
			times.append((now - last) / 1000.0)
			last = now
			if not label_trial.is_empty() and view.get_meta("socket_split_label_active", false): steady_split_frames += 1
		times.sort()
		var record := {"type": "time", "variant": variant[0], "round": round, "viewport_3d": [view.size.x, view.size.y], "msaa_3d": view.msaa_3d}
		if frames > 0:
			var middle := frames / 2
			var median := times[middle]
			if not label_trial.is_empty() and frames % 2 == 0: median = (times[middle - 1] + median) / 2.0
			record.merge({"median_ms": median, "p95_ms": times[ceili(frames * 0.95) - 1], "min_ms": times[0], "max_ms": times[-1]})
		record["draw_calls"] = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		record["primitives"] = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		add_render_info(record, "3d", view, Viewport.RENDER_INFO_TYPE_VISIBLE)
		add_render_info(record, "shadow", view, Viewport.RENDER_INFO_TYPE_SHADOW)
		add_render_info(record, "canvas", root, Viewport.RENDER_INFO_TYPE_CANVAS)
		add_view_timing(record, "view3d", view)
		add_view_timing(record, "root", root)
		record["process_ms"] = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		if not label_trial.is_empty():
			var active := bool(view.get_meta("socket_split_label_active", false))
			var label := split_label_viewport()
			if active and label == null: return fail("active split has a label viewport")
			record.merge({"split_label_active": active, "split_label_fallback": requested_split and not active, "viewport_label": null,
				"steady_split_active_frames": steady_split_frames})
			if label != null:
				record["viewport_label"] = [label.size.x, label.size.y]
				var rect = display.material.get_shader_parameter("label_rect")
				var span := Vector2(rect.z, rect.w) if rect is Vector4 else Vector2.ONE
				record["label_region_px"] = [roundi(root.size.x * span.x), roundi(root.size.y * span.y)]
				record["label_msaa_3d"] = label.msaa_3d
				add_render_info(record, "label_3d", label, Viewport.RENDER_INFO_TYPE_VISIBLE)
				add_render_info(record, "label_shadow", label, Viewport.RENDER_INFO_TYPE_SHADOW)
				add_view_timing(record, "label", label)
		else:
			write(record)
		if round == 0 and OS.get_environment("SOCKET_BENCH_IMAGES") != "0":
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(output.path_join("frame-%s.png" % variant[0]))
		if not label_trial.is_empty():
			var navigation := await measure_navigation(sync)
			if navigation.is_empty(): return fail("navigation returns to the fixture pose")
			record.merge(navigation)
			write(record)

	if label_trial.is_empty():
		if OS.get_environment("SOCKET_BENCH_QUALITY") != "0":
			await quality(variants.filter(func(variant): return variant[1] != null), output)
		await apply(DEFAULTS)
	log_file.close()
	# This object lives longer than the scene. Release the materials, the
	# textures and the nodes that it holds before the exit.
	casings.clear()
	labels.clear()
	finishes.clear()
	lights.clear()
	hidden.clear()
	home = null
	carousel = null
	view = null
	display = null
	environment = null
	edge_shader = null
	linear_shader = null
	print("PASS: benchmark wrote results.jsonl")
	quit()

func split_label_viewport() -> SubViewport:
	if view.get_meta("socket_split_label_active", false) and view.has_meta("socket_split_label_viewport"):
		return view.get_meta("socket_split_label_viewport") as SubViewport
	return null

func add_render_info(record: Dictionary, key: String, viewport: Viewport, kind: Viewport.RenderInfoType) -> void:
	record[key + "_draw_calls"] = viewport.get_render_info(kind, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	record[key + "_primitives"] = viewport.get_render_info(kind, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)

func add_view_timing(record: Dictionary, key: String, viewport: Viewport) -> void:
	# Timer queries. A driver without them gives zero.
	record[key + "_gpu_ms"] = RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid())
	record[key + "_cpu_ms"] = RenderingServer.viewport_get_measured_render_time_cpu(viewport.get_viewport_rid())

func measure_navigation(sync: bool) -> Dictionary:
	var times := PackedFloat64Array()
	var split_frames := 0
	var initial: int = carousel.scroll_position
	carousel.set_process(true)
	# Follow real carousel transitions, including the first frame after each step.
	# The app's navigation diagnostics use the same half-second window per input.
	for direction in [1, 1, 1, -1, -1, -1]:
		var last := Time.get_ticks_usec()
		var until := last + 500000
		carousel.jump(direction)
		while last < until:
			await process_frame
			if sync:
				root.get_texture().get_image()
			var now := Time.get_ticks_usec()
			times.append((now - last) / 1000.0)
			last = now
			if view.get_meta("socket_split_label_active", false): split_frames += 1
	carousel.set_process(false)
	if carousel.scroll_position != initial or carousel.active_cartridges.size() != 3: return {}
	times.sort()
	return {"nav_frames": times.size(), "nav_p95_ms": times[ceili(times.size() * 0.95) - 1], "nav_worst_ms": times[-1], "nav_split_active_frames": split_frames}

func apply(knobs: Dictionary) -> void:
	# Each named trial selects its own resolution independently of the saved slider.
	view.set("_scale", 1.0)
	view.set("_baseos_cap", knobs.cap)
	view.call("_apply")
	display.material.shader = linear_shader if knobs.filter == "linear" else edge_shader
	view.msaa_3d = {0: Viewport.MSAA_DISABLED, 2: Viewport.MSAA_2X, 4: Viewport.MSAA_4X}[knobs.msaa]
	for light in lights:
		if light is DirectionalLight3D:
			light.shadow_enabled = knobs.shadows != "0"
			light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL if knobs.shadows == "1" else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	carousel.visible = knobs.carts
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if knobs.view3d else SubViewport.UPDATE_DISABLED
	display.visible = knobs.display
	environment.adjustment_enabled = environment_default.adjust and knobs.post
	environment.tonemap_mode = environment_default.tonemap if knobs.post else Environment.TONE_MAPPER_LINEAR
	for entry in casings:
		var material = entry[1]
		if knobs.casing != "":
			var finish = finishes[knobs.casing]
			material = global_class("CartFinishBank").build(finish.id, finish.fallback_color, entry[2].casing_maps())
		entry[0].set_surface_override_material(0, material)
	for entry in labels:
		var material = entry[3]
		if knobs.label != "":
			material = load("res://res/label_styles/materials/" + knobs.label + ".tres").duplicate()
			material.set_shader_parameter("artwork_texture", entry[2].get_shader_parameter("artwork_texture"))
		entry[0].set_surface_override_material(entry[1], material)
	for node in hidden:
		if is_instance_valid(node): node.visible = true
	hidden.clear()
	for node in root.find_children("*", "CanvasItem", true, false):
		if not node.visible or node == display or node.is_ancestor_of(display):
			continue
		var shader: Shader = node.material.shader if node.material is ShaderMaterial else null
		var path := shader.resource_path if shader else ""
		var kind := ""
		if path.ends_with("scrolling_dots.gdshader"): kind = "dots"
		elif path.ends_with("outline.gdshader"): kind = "outline"
		elif shader != null and shader.code.contains("hint_screen_texture"): kind = "glass"
		# The controls of the main menu: all that is not the 3D view.
		elif node.get_parent() == home: kind = "controls"
		if kind in knobs.hide:
			node.visible = false
			hidden.append(node)
	await process_frame

# Edge quality: the 3D layer as the panel shows it, against a reference with 16
# samples for each panel pixel (2880x1920, box filter). Premultiplied RGB on black.
func quality(variants: Array, output: String) -> void:
	var stage := SubViewport.new()
	stage.size = Vector2i(720, 480)
	stage.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(stage)
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.size = Vector2(720, 480)
	stage.add_child(black)
	var copy := TextureRect.new()
	copy.texture = view.get_texture()
	copy.material = display.material
	copy.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	copy.stretch_mode = TextureRect.STRETCH_SCALE
	copy.size = Vector2(720, 480)
	# The filter that the display node gets from its parents.
	var filter := CanvasItem.TEXTURE_FILTER_PARENT_NODE
	var node: Node = display
	while node is CanvasItem and filter == CanvasItem.TEXTURE_FILTER_PARENT_NODE:
		filter = node.texture_filter
		node = node.get_parent()
	if filter == CanvasItem.TEXTURE_FILTER_PARENT_NODE:
		filter = int(ProjectSettings.get_setting("rendering/textures/canvas_textures/default_texture_filter")) + 1
	copy.texture_filter = filter
	stage.add_child(copy)
	var seen := {}
	for pose in [0.0, 12.0]:
		carousel.rotation_degrees.y = pose
		await apply(DEFAULTS.merged({"filter": "linear"}, true))
		# The app sets the 3D size again when its container changes. Stop that for the reference.
		var fit := Callable(view, "_apply")
		view.get_parent().resized.disconnect(fit)
		view.size = Vector2i(2880, 1920)
		for i in range(4): await process_frame
		await RenderingServer.frame_post_draw
		var reference := view.get_texture().get_image()
		view.get_parent().resized.connect(fit)
		if reference.get_size() != Vector2i(2880, 1920): return fail("reference has 16 samples for each panel pixel: %s" % reference.get_size())
		reference.convert(Image.FORMAT_RGBA8)
		reference.shrink_x2()
		reference.shrink_x2()
		reference.save_png(output.path_join("quality-pose%d-reference.png" % pose))
		var ref := reference.get_data()
		# Edge pixels: the reference changes by more than 0.08 in a 3x3 area.
		var lum := luminance(ref)
		var mask := PackedByteArray()
		mask.resize(720 * 480)
		var edges := 0
		for y in range(1, 479):
			for x in range(1, 719):
				var low := 1.0
				var high := 0.0
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						var value := lum[(y + dy) * 720 + x + dx]
						low = minf(low, value)
						high = maxf(high, value)
				if high - low > 0.08:
					mask[y * 720 + x] = 1
					edges += 1
		var ref_gradient := gradient(lum, mask)
		for variant in variants:
			var knobs: Dictionary = DEFAULTS.merged(variant[1], true)
			var key := str(QUALITY_KEYS.map(func(name): return knobs[name]))
			if variant[0] != "base" and (seen.has(key + str(pose)) or not QUALITY_KEYS.any(func(name): return variant[1].has(name)) or variant[1].keys().any(func(name): return name not in QUALITY_KEYS + ["shadows"])):
				continue
			seen[key + str(pose)] = true
			await apply(DEFAULTS.merged({"cap": knobs.cap, "filter": knobs.filter, "msaa": knobs.msaa}, true))
			for i in range(4): await process_frame
			await RenderingServer.frame_post_draw
			var image := stage.get_texture().get_image()
			image.convert(Image.FORMAT_RGBA8)
			image.save_png(output.path_join("quality-pose%d-%s.png" % [pose, variant[0]]))
			var data := image.get_data()
			var error := 0.0
			var edge_error := 0.0
			var squares := 0.0
			for i in range(720 * 480):
				var d := (absi(data[i * 4] - ref[i * 4]) + absi(data[i * 4 + 1] - ref[i * 4 + 1]) + absi(data[i * 4 + 2] - ref[i * 4 + 2])) / 3.0
				error += d
				squares += d * d
				if mask[i] == 1:
					edge_error += d
			write({"type": "quality", "variant": variant[0], "pose": pose, "viewport_3d": [view.size.x, view.size.y], "edge_pixels": edges,
				"mean_error": error / (720 * 480), "edge_error": edge_error / maxi(edges, 1), "psnr_db": 10.0 * log(255.0 * 255.0 / maxf(squares / (720 * 480), 0.000001)) / log(10.0),
				# Below 1: softer than the reference. Above 1: harder steps than the reference.
				"edge_contrast": gradient(luminance(data), mask) / maxf(ref_gradient, 0.000001)})
		print("quality pose ", pose, " done")
	carousel.rotation_degrees.y = 0.0
	stage.free()

func luminance(data: PackedByteArray) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(720 * 480)
	for i in range(720 * 480):
		result[i] = (data[i * 4] * 0.299 + data[i * 4 + 1] * 0.587 + data[i * 4 + 2] * 0.114) / 255.0
	return result

func gradient(lum: PackedFloat32Array, mask: PackedByteArray) -> float:
	var total := 0.0
	for y in range(1, 479):
		for x in range(1, 719):
			var i := y * 720 + x
			if mask[i] == 1:
				total += absf(lum[i + 1] - lum[i]) + absf(lum[i + 720] - lum[i])
	return total
