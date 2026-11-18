# Check the 3D benchmark candidates of the packed app with a real Compatibility
# renderer. Run with tests/app/run_render.py. The SOCKET_3D_* and SOCKET_UI_SNAP
# variables select the candidate; with none set, this checks the defaults.
# This test checks the effective settings and the log fields. It does not measure speed.
extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func require(ok: bool, message: String) -> bool:
	if not ok:
		printerr("FAIL: ", message)
		quit(1)
	return ok

func _run() -> void:
	OS.low_processor_usage_mode = false
	root.size = Vector2i(720, 480)
	var output := OS.get_environment("SOCKET_EVIDENCE")
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	var view: SubViewport
	for i in range(20000):
		await process_frame
		if not root.get_meta("socket_shader_startup_complete", false):
			continue
		var views := root.find_children("*", "SubViewport", true, false).filter(func(node): return node.get_script() != null and node.get_script().resource_path == "res://scenes/render_scale_3d.gd")
		if not views.is_empty():
			view = views[0]
			break
	if not require(view != null, "startup completes and the 3D view exists"): return
	for i in range(10): await process_frame

	var cap_text := OS.get_environment("SOCKET_3D_CAP")
	var cap := clampf(cap_text.to_float(), 0.05, 1.0) if cap_text.is_valid_float() else 1.0
	var settings = root.get_node("SettingsManager")
	if not require(is_equal_approx(float(settings.get_setting("render_scale_3d")), 0.75), "fresh Display settings select 0.75"): return
	var initial := Vector2(view.size) * view.scaling_3d_scale
	if not require(initial.distance_to(Vector2(720, 480) * minf(cap, 0.75)) <= 1.5, "fresh viewport uses the default scale"): return
	# On the 720x480 panel the cap sets the 3D pixels at each render-scale setting.
	for render_scale in [0.5, 0.75, 1.0]:
		settings.set_setting("render_scale_3d", render_scale)
		for i in range(3): await process_frame
		var effective: Vector2 = Vector2(view.size) * view.scaling_3d_scale
		var target := minf(cap, render_scale)
		if not require(absf(effective.x - 720.0 * target) <= 1.0 and absf(effective.y - 480.0 * target) <= 1.0, "3D pixels follow the cap at render scale %s: %s" % [render_scale, effective]): return
		print("render_scale=", render_scale, " viewport=", view.size, " scaling_3d=", view.scaling_3d_scale, " effective=", effective)

	var display: CanvasItem = view.get("_display")
	var shader: Shader = display.material.shader if display.material is ShaderMaterial else null
	if not require(shader != null, "3D display has the display shader"): return
	var linear := OS.get_environment("SOCKET_3D_FILTER") == "linear"
	if not require(shader.code.begins_with("#define DISPLAY_LINEAR\n") == linear and (linear or shader.resource_path == "res://shaders/display_aa.gdshader"), "display filter follows SOCKET_3D_FILTER"): return
	var msaa: int = {"2": Viewport.MSAA_2X, "4": Viewport.MSAA_4X}.get(OS.get_environment("SOCKET_3D_MSAA"), Viewport.MSAA_DISABLED)
	if OS.get_environment("SOCKET_3D_MSAA") == "auto" and OS.get_environment("SOCKET_TILE_MSAA") == "1":
		msaa = Viewport.MSAA_2X
	if not require(view.msaa_3d == msaa, "MSAA follows SOCKET_3D_MSAA"): return
	if not require(settings.get_setting("cartridge_msaa") == true, "older profiles allow cartridge MSAA by default"): return
	settings.set_setting("cartridge_msaa", false)
	var saved := ConfigFile.new()
	if not require(saved.load("user://settings.cfg") == OK and saved.get_value("General", "cartridge_msaa") == false and view.msaa_3d == Viewport.MSAA_DISABLED, "Off disables edge MSAA live and survives a restart"): return
	settings.set_setting("cartridge_msaa", true)
	if not require(view.msaa_3d == msaa, "On restores the driver sample count"): return
	var lights := view.find_children("*", "Light3D", true, false)
	var shadows := OS.get_environment("SOCKET_3D_SHADOWS") != "0"
	# One shadow pass is the default. "4" selects the four splits of Socket.
	var one_pass := shadows and OS.get_environment("SOCKET_3D_SHADOWS") != "4"
	var sun := lights.filter(func(light): return light is DirectionalLight3D)
	if not require(sun.size() == 1 and sun[0].shadow_enabled == shadows, "shadows follow SOCKET_3D_SHADOWS"): return
	if not require(not shadows or (sun[0].directional_shadow_mode == DirectionalLight3D.SHADOW_ORTHOGONAL) == one_pass and (one_pass or sun[0].directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS), "shadow mode follows SOCKET_3D_SHADOWS"): return
	# The separate tonemap pass is necessary only with the shadow map. 0.3.2 has no such pass.
	var worlds := view.find_children("*", "WorldEnvironment", true, false).filter(func(world): return world.environment != null and world.environment.tonemap_mode == Environment.TONE_MAPPER_REINHARDT)
	if not require(worlds.all(func(world): return world.environment.adjustment_enabled == shadows), "tonemap pass follows the shadow map"): return
	# The light UI of 0.10.1 has no glass panel on the main menu that reads the screen.
	if root.get_node("Main").has_method("_baseos_light_ui"):
		var light_ui := OS.get_environment("SOCKET_UI_LIGHT") != "0"
		# The home screen is the "main" screen. An empty library can have no glass panel.
		var home = load("res://scripts/screens/screen.gd").get_screen("main")
		var glass: Array = home.find_children("*", "Control", true, false).filter(func(node): return node.material is ShaderMaterial and node.material.shader.code.contains("GLASS_FLAT"))
		if not require(glass.all(func(node): return node.material.shader.code.begins_with("#define GLASS_FLAT\n") == light_ui), "main menu glass follows SOCKET_UI_LIGHT"): return
		var copies := root.find_children("*", "BackBufferCopy", true, false).filter(func(node): return node.is_visible_in_tree() and node.copy_mode != BackBufferCopy.COPY_MODE_DISABLED)
		if not require(not light_ui or copies.is_empty(), "the light UI makes no screen copy: %d" % copies.size()): return
		var corners := root.find_children("*", "ColorRect", true, false).filter(func(node): return node.material is ShaderMaterial and node.material.shader.resource_path == "res://scenes/outline.gdshader")
		if not require(corners.size() == 1 and (corners[0].size == Vector2.ZERO) == light_ui and (corners[0].get_child_count() == 1) == light_ui, "corner overlay follows SOCKET_UI_LIGHT"): return
	var snap := OS.get_environment("SOCKET_UI_SNAP") != "0"
	var ui: Viewport = root.find_child("MainScreen", true, false).get_node("SubViewport") if root.find_child("MainScreen", true, false) != null and root.find_child("MainScreen", true, false).has_node("SubViewport") else root
	if not require(root.snap_2d_vertices_to_pixel == snap and ui.snap_2d_vertices_to_pixel == snap, "UI pixel snap follows SOCKET_UI_SNAP"): return

	await RenderingServer.frame_post_draw
	if not require(root.get_texture().get_image().save_png(output.path_join("frame.png")) == OK, "save frame evidence"): return

	if OS.get_environment("SOCKET_FPS_DIAGNOSTICS") == "1":
		# Hold a key so that the sample has navigation frames.
		var key := InputEventKey.new()
		key.keycode = KEY_F24
		key.pressed = true
		Input.parse_input_event(key)
		var sample
		for i in range(20000):
			await process_frame
			for line in FileAccess.get_file_as_string("user://render-performance.jsonl").strip_edges().split("\n", false):
				var record = JSON.parse_string(line)
				if record is Dictionary and record.has("p95_frame_ms"):
					sample = record
			if sample != null:
				break
		if not require(sample != null, "frame-rate log has a sample"): return
		print("sample ", JSON.stringify(sample))
		if not require(sample.p95_frame_ms > 0.0 and sample.p95_frame_ms <= sample.worst_frame_ms, "sample has the 95th percentile frame time"): return
		if not require(sample.nav_frames > 0 and sample.nav_p95_ms > 0.0 and sample.nav_worst_ms >= sample.nav_p95_ms, "sample has navigation frame times"): return
		if not require(sample.new_shaders_3d is Array and sample.shaders_3d is Array, "sample lists new 3D shaders"): return
		if not require(sample.shader_cache_files_at_start >= 0 and sample.shader_startup is Dictionary and sample.shader_startup.get("draws", 0) > 0 and sample.shader_startup.longest_frame_ms > 0.0 and sample.shader_startup.first_input_ms >= sample.shader_startup.warmup_ms, "first sample has the startup record"): return
		if not require(sample.worst_frame_ms < sample.shader_startup.warmup_ms, "the paused warmup is not counted as a frame"): return
		if not require(sample.SOCKET_3D_CAP == cap_text and sample.SOCKET_3D_FILTER == OS.get_environment("SOCKET_3D_FILTER") and sample.has("SOCKET_UI_SNAP") and int(sample.msaa_3d) == view.msaa_3d, "sample identifies the candidate"): return
		if not require(absf(sample.viewport_3d[0] * view.scaling_3d_scale - 720.0 * cap) <= 1.0, "sample has the 3D size"): return
	if OS.get_environment("SOCKET_TEST_AA_BUDGET") == "1":
		# Force slow frames on Mesa to exercise the policy used by the tile renderer.
		Engine.max_fps = 10
		if not require(not view._baseos_aa_carousel(), "respect a lower requested frame rate"): return
		Engine.max_fps = 30
		if not require(view._baseos_aa_carousel(), "measure only the visible live carousel"): return
		view.msaa_3d = Viewport.MSAA_2X
		view._baseos_watch_aa(view._baseos_aa_generation)
		paused = true
		if not require(not view._baseos_aa_carousel(), "time in Device Settings is outside the frame budget"): return
		await create_timer(1.0).timeout
		paused = false
		# Finish the interrupted interval slowly. It must not count against MSAA.
		var interrupted := Time.get_ticks_msec()
		while Time.get_ticks_msec() - interrupted < 3150:
			OS.delay_msec(115)
			await process_frame
		var started := Time.get_ticks_msec()
		while Time.get_ticks_msec() - started < 8000 and view.msaa_3d != Viewport.MSAA_DISABLED:
			OS.delay_msec(115)
			await process_frame
		if not require(Time.get_ticks_msec() - started >= 5450 and view.msaa_3d == Viewport.MSAA_DISABLED and view.size == Vector2i(720, 480), "two slow intervals release MSAA and keep the native image"): return
		if not require(root.get_meta("socket_cartridge_msaa_paused", false) and settings.get_setting("cartridge_msaa") == true, "the watchdog pauses MSAA for this session only"): return
		settings.set_setting("cartridge_msaa", false)
		settings.set_setting("cartridge_msaa", true)
		if not require(not root.get_meta("socket_cartridge_msaa_paused") and view.msaa_3d == msaa, "turning MSAA back on retries after the watchdog stops it"): return
	print("PASS: render candidate cap=", cap, " viewport=", view.size, " linear=", linear, " msaa=", msaa, " shadows=", shadows, " one_shadow_pass=", one_pass, " ui_snap=", snap)
	quit()
