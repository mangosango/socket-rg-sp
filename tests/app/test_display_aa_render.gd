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
	# The linear benchmark variant, made as the patched render_scale_3d.gd makes it.
	var premul := ShaderMaterial.new()
	premul.shader = Shader.new()
	premul.shader.code = "#define DISPLAY_LINEAR\n" + material.shader.code
	if not require(premul.shader.get_mode() == Shader.MODE_CANVAS_ITEM, "linear variant is a canvas shader"): return
	# opaque: artwork, a white and black diagonal with full alpha. coverage, black:
	# the outline of a cartridge on empty pixels. translucent: a casing with half
	# alpha, premultiplied. prefiltered: an outline with part coverage, as MSAA
	# or a scaled target gives. dot: a detail of one texel and a line of one texel.
	for fixture in ["opaque", "coverage", "black", "flat", "modulate", "translucent", "prefiltered", "dot"]:
		for y in range(320):
			for x in range(480):
				var inside := float(x) + 0.5 < 90.0 + (float(y) + 0.5) * 0.55
				var color := Color.WHITE if inside else Color.BLACK
				if fixture in ["coverage", "modulate"]: color = Color(1, 0.25, 0.125, 1) if inside else Color(0, 0, 0, 0)
				if fixture == "black": color = Color(0, 0, 0, 1) if inside else Color(0, 0, 0, 0)
				if fixture == "flat": color = Color(0.25, 0.5, 0.75, 1)
				if fixture == "translucent": color = Color(0.5, 0.125, 0.0625, 0.5) if inside else Color(0, 0, 0, 0)
				if fixture == "prefiltered":
					var part := clampf(90.0 + (float(y) + 0.5) * 0.55 - float(x), 0.0, 1.0)
					color = Color(part, 0.25 * part, 0.125 * part, part)
				if fixture == "dot": color = Color(1, 0.25, 0.125, 1) if (x == 100 and y == 100) or (y == 150 and x >= 80 and x < 140) else Color(0, 0, 0, 0)
				source.set_pixel(x, y, color)
		display.texture = ImageTexture.create_from_image(source)
		display.modulate = Color(0.5, 0.75, 1, 0.6) if fixture == "modulate" else Color.WHITE
		var baseline: Image
		for enabled in [false, true]:
			display.material = material if enabled else premul
			for i in range(3): await process_frame
			await RenderingServer.frame_post_draw
			var image := view.get_texture().get_image()
			if not require(image.save_png(output.path_join(fixture + ("-aa.png" if enabled else "-linear.png"))) == OK, "save display evidence"): return
			# Each variant must keep premultiplied color and the modulation.
			var variant := "edge filter" if enabled else "linear"
			if fixture in ["coverage", "modulate", "translucent", "prefiltered", "dot"]:
				var expected := Vector3(0.5, 0.1875, 0.125) if fixture == "modulate" else Vector3(1, 0.25, 0.125)
				for y in range(30, 420):
					for x in range(60, 420):
						var actual := image.get_pixel(x, y)
						# Compare premultiplied values. A ratio is not stable at low 8-bit alpha.
						# The edge filter divides the 8-bit linear read by its alpha (0.45 or more).
						# That makes a rounding error of the texture filter as large as 2.2 times.
						# The allowance for the color is thus four 8-bit codes. A dark halo is
						# ten times larger.
						if not require(Vector3(actual.r, actual.g, actual.b).distance_to(expected * actual.a) < (4.0 / 255.0 if enabled else 0.012), variant + ": premultiplied RGB has no dark halo"): return
			if fixture == "modulate":
				var interior := image.get_pixel(100, 100)
				if not require(absf(interior.a - 0.6) < 0.01 and Vector3(interior.r, interior.g, interior.b).distance_to(Vector3(0.3, 0.1125, 0.075)) < 0.015, variant + ": modulation preserves absolute RGB and alpha"): return
			if fixture == "flat":
				var flat := image.get_pixel(100, 100)
				if not require(Vector3(flat.r, flat.g, flat.b).distance_to(Vector3(0.25, 0.5, 0.75)) < 0.01 and flat.a > 0.99, variant + ": flat color is exact"): return
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
			if fixture in ["flat", "opaque", "translucent", "prefiltered"]:
				# The filter changes only an outline between opaque texels and empty texels.
				if not require(changed == 0, fixture + " pixels remain identical to the linear read"): return
			elif fixture == "dot":
				# Small details stay visible: full alpha in the middle, and most of the area.
				var area := 0.0
				var area_linear := 0.0
				for y in range(140, 240):
					for x in range(110, 220):
						area += image.get_pixel(x, y).a
						area_linear += baseline.get_pixel(x, y).a
				print("dot peak=", image.get_pixel(150, 150).a, " line=", image.get_pixel(165, 225).a, " area=", area, " linear_area=", area_linear)
				if not require(image.get_pixel(150, 150).a > 0.9 and image.get_pixel(165, 225).a > 0.9 and area > 0.6 * area_linear and area < 1.2 * area_linear, "one-texel details stay visible"): return
			elif fixture != "modulate":
				print(fixture, " linear_squared_error=", error_linear, " aa_squared_error=", error_aa, " changed=", changed)
				if not require(error_aa < error_linear * 0.6, "outline is nearer to the true coverage than the linear upscale"): return
			for y in range(430, 470):
				for x in range(420, 710):
					if not require(image.get_pixel(x, y) == baseline.get_pixel(x, y), "native label pixels remain identical"): return
	# Panel size: one texel for each panel pixel. The filter must find the outline
	# in each pixel column and row, so move the diagonal by one pixel.
	display.modulate = Color.WHITE
	var native := Image.create(720, 480, false, Image.FORMAT_RGBA8)
	var native_errors := []
	for shift in [0, 1]:
		for y in range(480):
			for x in range(720):
				native.set_pixel(x, y, Color(1, 0.25, 0.125, 1) if float(x) + 0.5 < 135.0 + shift + (float(y + shift) + 0.5) * 0.55 else Color(0, 0, 0, 0))
		display.texture = ImageTexture.create_from_image(native)
		var errors := []
		for enabled in [false, true]:
			display.material = material if enabled else premul
			for i in range(3): await process_frame
			await RenderingServer.frame_post_draw
			var image := view.get_texture().get_image()
			if not require(image.save_png(output.path_join("native-%d-%s.png" % [shift, "aa" if enabled else "linear"])) == OK, "save native evidence"): return
			var error := 0.0
			for y in range(30, 420):
				for x in range(60, 420):
					var actual := image.get_pixel(x, y)
					if not require(Vector3(actual.r, actual.g, actual.b).distance_to(Vector3(1, 0.25, 0.125) * actual.a) < 4.0 / 255.0, "native: premultiplied RGB has no dark halo"): return
					error += pow(actual.a - clampf(135.0 + shift + (y + shift + 0.5) * 0.55 - x, 0.0, 1.0), 2)
			errors.append(error)
		print("native shift=", shift, " linear_squared_error=", errors[0], " aa_squared_error=", errors[1])
		if not require(errors[1] < errors[0] * 0.6, "native outline improves at shift %d" % shift): return
		native_errors.append(errors[1])
	if not require(absf(native_errors[0] - native_errors[1]) < 0.1 * maxf(native_errors[0], native_errors[1]), "native outline is equal on even and odd pixels"): return
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
	# The linear variant must blend the real 3D target the same way.
	display.material = premul
	for i in range(3): await process_frame
	await RenderingServer.frame_post_draw
	var linear_composite := view.get_texture().get_image()
	if not require(linear_composite.save_png(output.path_join("3d-bright-background-linear.png")) == OK, "save linear 3D alpha evidence"): return
	for y in range(60, 420):
		for x in range(120, 600):
			var color := linear_composite.get_pixel(x, y)
			if not require(color.r > 0.82 and color.r < 0.92, "linear: 3D transparent casing has no dark fringe on bright background"): return
	print("PASS: display AA improves outlines at the scaled and the panel size, keeps premultiplied color, modulation, artwork, semi-transparent and prefiltered pixels, small details and native text; the linear variant keeps premultiplied color and modulation")
	quit()
