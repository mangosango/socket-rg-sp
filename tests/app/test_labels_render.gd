# Run with the packed project and a real Compatibility renderer.
# Set SOCKET_LABEL_EVIDENCE to a writable output directory.
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
	Engine.print_to_stdout = true
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(720, 480)
	var output := OS.get_environment("SOCKET_LABEL_EVIDENCE")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(480, 320)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var display := TextureRect.new()
	display.texture = viewport.get_texture()
	root.add_child(display)
	var world := Node3D.new()
	viewport.add_child(world)
	var scene = load(ProjectSettings.get_setting("application/run/main_scene")).instantiate()
	world.add_child(scene.find_children("*", "WorldEnvironment", true, false)[0].duplicate())
	world.add_child(scene.find_children("*", "DirectionalLight3D", true, false)[0].duplicate())
	scene.free()
	var camera := Camera3D.new()
	camera.position.z = 4.0
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.5
	world.add_child(camera)
	var artwork := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	for y in range(256):
		for x in range(256):
			var color := Color(0.8, 0.8, 0.8)
			if y > 64 and y < 190:
				color = Color(0.35, 0.48, 0.65) if (x / 24 + y / 24) % 2 == 0 else Color(0.07, 0.09, 0.12)
			artwork.set_pixel(x, y, color)
	var mesh := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(2, 2)
	mesh.mesh = quad
	world.add_child(mesh)
	for style in ["chrome_outline_sticker", "holo_foil_sticker", "rainbow_prism_sticker", "golden_ticket_sticker", "chrome_outline_disc", "paper"]:
		var path: String = "res://materials/mat_label_default.tres" if style == "paper" else "res://res/label_styles/materials/" + style + ".tres"
		var material: ShaderMaterial = load(path).duplicate()
		material.set_shader_parameter("artwork_texture", ImageTexture.create_from_image(artwork))
		material.shader = material.shader.duplicate()
		var fixed := material.shader.code
		if not require("gradient_tex.rgb * noise_tex.rgb;" in fixed and not "noise_tex.rgb * 2.0" in fixed, "pack contains corrected foil color"): return
		mesh.material_override = material
		var baseline := {}
		var last: Image
		for variant in ["before", "fixed"]:
			# Restore only the defect to reproduce the old packed shader.
			material.shader.code = fixed.replace("gradient_tex.rgb * noise_tex.rgb;", "gradient_tex.rgb * (noise_tex.rgb * 2.0);") if variant == "before" else fixed
			for angle in [-30, 0, 30]:
				mesh.rotation_degrees = Vector3(angle, angle / 2.0, 0)
				for i in range(3): await process_frame
				await RenderingServer.frame_post_draw
				var image := viewport.get_texture().get_image()
				var saved := image.save_png(output.path_join("%s-%s-%s.png" % [style, variant, angle]))
				if not require(saved == OK, "save rendered evidence"): return
				var clipped := 0
				var white := 0
				for y in range(45, 275):
					for x in range(125, 355):
						var color := image.get_pixel(x, y)
						if maxf(color.r, maxf(color.g, color.b)) >= 0.99: clipped += 1
						if minf(color.r, minf(color.g, color.b)) >= 0.99: white += 1
				print(style, " ", variant, " ", angle, " clipped_channels=", clipped, " white=", white, "/52900")
				if variant == "before":
					if style == "chrome_outline_sticker" and angle == 30:
						if not require(white > 10000, "original shader reproduces white blowout"): return
					baseline[angle] = {"image": image, "clipped": clipped}
				else:
					if not require(clipped <= baseline[angle].clipped, "foil clipping does not increase"): return
					if style == "paper":
						if not require(image.get_data() == baseline[angle].image.get_data(), "paper pixels remain identical"): return
					else:
						if not require(white == 0, "foil keeps white highlight detail"): return
						if angle == 30:
							if not require(image.get_data() != baseline[angle].image.get_data(), "foil correction changes the rendered finish"): return
						if last != null:
							if not require(image.get_data() != last.get_data(), "foil responds to rotation"): return
						last = image
	print("PASS: packed foil highlights retain angle response and paper pixels remain unchanged")
	quit()
