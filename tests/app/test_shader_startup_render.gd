# Check the animated shader startup screen of the packed app with a real
# Compatibility renderer. Run with tests/app/run_render.py.
# Set SOCKET_TEST_DARK=1 to use an inverted palette (not available on 0.3.2).
# Mesa shows that the screen animates and stays legible. It does not show Mali
# compile stalls or cold and cached times. Measure those on the RG SP.
extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func require(ok: bool, message: String) -> bool:
	if not ok:
		printerr("FAIL: ", message)
		quit(1)
	return ok

func changed(a: Image, b: Image, rect: Rect2i) -> int:
	var count := 0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				count += 1
	return count

func _run() -> void:
	OS.low_processor_usage_mode = false
	root.size = Vector2i(720, 480)
	var output := OS.get_environment("SOCKET_EVIDENCE")
	if OS.get_environment("SOCKET_TEST_DARK") == "1" and ResourceLoader.exists("res://scripts/theme_palette.gd"):
		var palette_script = load("res://scripts/theme_palette.gd")
		var palette = palette_script.active().duplicate()
		palette.low = Color(0.92, 0.92, 0.92)
		palette.high = Color(0.1, 0.1, 0.1)
		for property in palette.get_property_list():
			if property.name == "dark":
				palette.dark = true
		palette_script.set_active(palette)
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	var frames: Array[Image] = []
	var status: CanvasLayer
	var plate: Rect2i
	var text: Rect2i
	var spinner: Rect2i
	var surface: Color
	var ink: Color
	var before: Image
	var sampled := 0
	# Capture the frame before the status, then frames during the warmup.
	for i in range(40000):
		await RenderingServer.frame_post_draw
		if root.get_meta("socket_shader_startup_complete", false):
			break
		if not root.get_meta("socket_shader_startup_active", false):
			before = root.get_texture().get_image()
			continue
		if status == null:
			for node in root.get_children():
				if node.get_script() != null and node.get_script().resource_path == "res://addons/FrontendPlugin/shader_startup.gd":
					status = node
			if not require(status != null, "status screen is in the tree while the gate is active"): return
			continue
		# Only a presented frame moves the status. Other warmup draws do not present.
		if frames.size() < 6 and status._presents >= sampled + 2:
			sampled = status._presents
			if frames.is_empty():
				var label: Label = status.find_children("*", "Label", true, false)[0]
				if not require(label.text == "Compiling shaders", "exact status label"): return
				# The status draws in panel pixels, so its rectangles are image rectangles.
				text = Rect2i(label.get_global_rect())
				plate = Rect2i(label.get_parent().get_parent().get_global_rect())
				spinner = Rect2i(status._spinner.get_global_rect())
				surface = status._backdrop.color
				ink = label.get_theme_color("font_color")
				var dots: Array = status._backdrop.get_children().filter(func(node): return node is ColorRect)
				print("dots reused=", not dots.is_empty(), " pack spinner=", status._spinner.get_script() != null, " plate=", plate, " text=", text, " spinner=", spinner)
				if not require(not dots.is_empty(), "status shows the scrolling dots of this pack"): return
				if not require(status._spinner.get_script() != null == ResourceLoader.exists("res://scenes/ui/spinner.gd"), "status uses the pack spinner where the pack has one"): return
			frames.append(root.get_texture().get_image())
	if not require(root.get_meta("socket_shader_startup_complete", false), "startup completes"): return
	if not require(frames.size() >= 3, "captured frames during the warmup: " + str(frames.size())): return
	if before != null:
		before.save_png(output.path_join("before-status.png"))
	for index in frames.size():
		frames[index].save_png(output.path_join("status-%d.png" % index))
	var outside := Rect2i(0, 0, 720, plate.position.y - 4)
	for index in range(1, frames.size()):
		var dot_pixels := changed(frames[index - 1], frames[index], outside)
		var spinner_pixels := changed(frames[index - 1], frames[index], spinner)
		var text_pixels := changed(frames[index - 1], frames[index], text)
		print("frame ", index, ": dots changed=", dot_pixels, " spinner changed=", spinner_pixels, " text changed=", text_pixels)
		if not require(dot_pixels > 200, "dots move between warmup frames"): return
		if not require(spinner_pixels > 4, "spinner turns between warmup frames"): return
		if not require(text_pixels == 0, "status text does not move"): return
	# Legible text: the label has pixels at the ink color on the surface plate.
	var ink_pixels := 0
	var surface_pixels := 0
	for y in range(text.position.y, text.end.y):
		for x in range(text.position.x, text.end.x):
			var color := frames[0].get_pixel(x, y)
			if Vector3(color.r, color.g, color.b).distance_to(Vector3(ink.r, ink.g, ink.b)) < 0.05: ink_pixels += 1
			if Vector3(color.r, color.g, color.b).distance_to(Vector3(surface.r, surface.g, surface.b)) < 0.05: surface_pixels += 1
	var contrast := absf(ink.get_luminance() - surface.get_luminance())
	print("text ink pixels=", ink_pixels, " surface pixels=", surface_pixels, " luminance contrast=", snappedf(contrast, 0.01))
	if not require(ink_pixels > 150 and surface_pixels > text.get_area() / 2 and contrast > 0.5, "status text is legible on its plate"): return
	# No blank flash: each frame after the status has more than one color.
	for index in 5:
		await RenderingServer.frame_post_draw
		var frame := root.get_texture().get_image()
		frame.save_png(output.path_join("after-%d.png" % index))
		var first := frame.get_pixel(0, 0)
		var other := 0
		for y in range(0, 480, 4):
			for x in range(0, 720, 4):
				if frame.get_pixel(x, y) != first:
					other += 1
		if not require(other > 200, "no blank frame after the status: frame " + str(index)): return
	if not require(not paused and not root.get_meta("socket_shader_startup_active", false) and root.get_meta("socket_shader_startup_warmed", false), "warmup drew and released the gate"): return
	if not require(root.is_using_font_oversampling(), "font oversampling is restored"): return
	var stats: Dictionary = root.get_meta("socket_shader_startup_stats", {})
	if not require(stats.get("draws", 0) > 0 and stats.longest_frame_ms > 0.0, "startup records its times"): return
	# Draws that are not due for the animation do not wait for a present.
	if not require(stats.presents > 0 and stats.presents < stats.draws, "warmup presents fewer frames than it draws: " + str(stats)): return
	print("PASS: shader startup screen animates dots and spinner, keeps legible text and shows no blank frame; ", JSON.stringify(stats), " (Mesa times, not Mali)")
	quit()
