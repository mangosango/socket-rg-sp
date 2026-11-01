# Run with the packed project and a real Compatibility renderer.
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
	var output := OS.get_environment("SOCKET_AA_EVIDENCE")
	DirAccess.make_dir_recursive_absolute(output)
	var view := SubViewport.new()
	view.size = Vector2i(720, 480)
	view.transparent_bg = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var source := Image.create(480, 320, false, Image.FORMAT_RGBA8)
	var display := TextureRect.new()
	display.size = Vector2(720, 480)
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	display.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	view.add_child(display)
	var label := Label.new()
	label.text = "Native text 0123456789"
	label.position = Vector2(420, 430)
	view.add_child(label)
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/display_aa.gdshader")
	var premul := ShaderMaterial.new()
	premul.shader = Shader.new()
	premul.shader.code = "shader_type canvas_item; render_mode unshaded, blend_premul_alpha;"
	for fixture in ["opaque", "coverage", "black", "flat", "modulate"]:
		for y in range(320):
			for x in range(480):
				var inside := float(x) + 0.5 < 90.0 + (float(y) + 0.5) * 0.55
				var color := Color.WHITE if inside else Color.BLACK
				if fixture in ["coverage", "modulate"]: color = Color(1, 0.25, 0.125, 1) if inside else Color(0, 0, 0, 0)
				if fixture == "black": color = Color(0, 0, 0, 1) if inside else Color(0, 0, 0, 0)
				if fixture == "flat": color = Color(0.25, 0.5, 0.75, 1)
				source.set_pixel(x, y, color)
		display.texture = ImageTexture.create_from_image(source)
		display.modulate = Color(0.5, 0.75, 1, 0.6) if fixture == "modulate" else Color.WHITE
		var baseline: Image
		for enabled in [false, true]:
			# Use the old plain display for opaque pixels; isolate AA from alpha correction.
			display.material = material if enabled else (null if fixture in ["opaque", "flat"] else premul)
			for i in range(3): await process_frame
			await RenderingServer.frame_post_draw
			var image := view.get_texture().get_image()
			if not require(image.save_png(output.path_join(fixture + ("-aa.png" if enabled else "-linear.png"))) == OK, "save display evidence"): return
			if not enabled:
				baseline = image
				continue
			var error_linear := 0.0
			var error_aa := 0.0
			var changed := 0
			for y in range(30, 420):
				for x in range(60, 420):
					var actual := image.get_pixel(x, y)
					var old := baseline.get_pixel(x, y)
					if actual != old: changed += 1
					var coverage := clampf((90.0 + (y + 0.5) / 1.5 * 0.55) * 1.5 - x, 0.0, 1.0)
					var observed := actual.r if fixture == "opaque" else actual.a
					var before := old.r if fixture == "opaque" else old.a
					error_linear += pow(before - coverage, 2)
					error_aa += pow(observed - coverage, 2)
					if fixture in ["coverage", "modulate"] and actual.a > 0.03:
						var expected := Vector3(0.5, 0.1875, 0.125) if fixture == "modulate" else Vector3(1, 0.25, 0.125)
						var ratio := Vector3(actual.r, actual.g, actual.b) / actual.a
						if not require(ratio.distance_to(expected) < 0.07, "premultiplied RGB has no dark halo"): return
			if fixture == "modulate":
				var interior := image.get_pixel(100, 100)
				if not require(absf(interior.a - 0.6) < 0.01 and Vector3(interior.r, interior.g, interior.b).distance_to(Vector3(0.3, 0.1125, 0.075)) < 0.015, "modulation preserves absolute RGB and alpha"): return
			if fixture == "flat":
				if not require(changed == 0, "flat pixels remain identical"): return
			elif fixture != "modulate":
				print(fixture, " linear_squared_error=", error_linear, " aa_squared_error=", error_aa, " changed=", changed)
				if not require(error_aa < error_linear * 0.95, "diagonal improves over linear upscale"): return
			for y in range(430, 470):
				for x in range(420, 710):
					if not require(image.get_pixel(x, y) == baseline.get_pixel(x, y), "native label pixels remain identical"): return
	# Check the actual GLES 3D target before testing its display blend.
	var source_view := SubViewport.new()
	source_view.size = Vector2i(480, 320)
	source_view.transparent_bg = true
	source_view.own_world_3d = true
	source_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(source_view)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color.BLACK
	source_view.add_child(environment)
	var camera := Camera3D.new()
	camera.position.z = 3
	source_view.add_child(camera)
	var mesh := MeshInstance3D.new()
	mesh.mesh = QuadMesh.new()
	mesh.rotation.z = 0.3
	var casing := ShaderMaterial.new()
	casing.shader = Shader.new()
	casing.shader.code = "shader_type spatial; render_mode unshaded; void fragment() { ALBEDO = vec3(0.8, 0.4, 0.2); ALPHA = 0.5; }"
	mesh.material_override = casing
	source_view.add_child(mesh)
	for i in range(3): await process_frame
	await RenderingServer.frame_post_draw
	var rendered := source_view.get_texture().get_image()
	print("3D source format=", rendered.get_format(), " center=", rendered.get_pixel(240, 160), " clear=", rendered.get_pixel(0, 0))
	if not require(rendered.get_pixel(0, 0) == Color(0, 0, 0, 0), "3D transparent clear has zero RGB"): return
	var center := rendered.get_pixel(240, 160)
	if not require(absf(center.a - 0.5) < 0.01 and absf(center.r - 0.4) < 0.02, "3D target contains premultiplied color"): return
	display.texture = source_view.get_texture()
	display.modulate = Color.WHITE
	display.material = material
	var background := ColorRect.new()
	background.size = Vector2(720, 480)
	background.color = Color(0.9, 0.85, 0.8, 1)
	view.add_child(background)
	view.move_child(background, 0)
	for i in range(3): await process_frame
	await RenderingServer.frame_post_draw
	var composite := view.get_texture().get_image()
	if not require(composite.save_png(output.path_join("3d-bright-background.png")) == OK, "save 3D alpha evidence"): return
	for y in range(60, 420):
		for x in range(120, 600):
			var color := composite.get_pixel(x, y)
			if not require(color.r > 0.82 and color.r < 0.92, "3D transparent casing has no dark fringe on bright background"): return
	print("PASS: display AA improves linear diagonals, keeps premultiplied color, modulation, flat pixels and native text")
	quit()
