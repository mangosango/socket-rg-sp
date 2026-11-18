# Check that the 3D MSAA view does not make framebuffer objects on each frame.
# Run with tests/app/run_msaa_fbo.py. The EGL helper counts the framebuffer
# calls of the engine and gives the tile MSAA extension where Mesa has none.
# The failing card build used MSAA together with the adjustment pass. The engine
# then draws to its internal buffer and looks up the MSAA framebuffer many times
# a frame. This test exercises the path used by the RG SP at 2x MSAA.
extends SceneTree

const FRAMES := 120

func _initialize() -> void:
	_run.call_deferred()

func require(ok: bool, message: String) -> bool:
	if not ok:
		printerr("FAIL: ", message)
		quit(1)
	return ok

# Generated and deleted framebuffers, multisample attachments, presented frames.
func counts() -> Dictionary:
	var values := FileAccess.get_file_as_string(OS.get_environment("SOCKET_FBO_COUNTS")).split_floats(" ")
	if values.size() < 5:
		return {}
	return {"generated": int(values[0]), "live": int(values[0] - values[1]), "attaches": int(values[2]), "swaps": int(values[3]), "emulated": values[4] == 1.0}

# Draw FRAMES frames in a stable state. Return the counts before and after.
func measure() -> Array:
	for i in range(30): await process_frame
	var before := counts()
	for i in range(FRAMES): await process_frame
	return [before, counts()]

func _run() -> void:
	OS.low_processor_usage_mode = false
	root.size = Vector2i(720, 480)
	if not require(OS.get_environment("SOCKET_TILE_MSAA") == "1", "engine finds tile MSAA support"): return

	var view := SubViewport.new()
	view.size = Vector2i(720, 480)
	view.own_world_3d = true
	view.msaa_3d = Viewport.MSAA_2X
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color(0.1, 0.2, 0.3)
	world.environment.tonemap_mode = Environment.TONE_MAPPER_REINHARDT
	view.add_child(world)
	var camera := Camera3D.new()
	camera.position = Vector3(0, 0, 3)
	view.add_child(camera)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, 30, 0)
	light.shadow_enabled = true
	view.add_child(light)
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	box.rotation_degrees = Vector3(20, 30, 0)
	view.add_child(box)
	root.add_child(view)
	var display := TextureRect.new()
	display.texture = view.get_texture()
	root.add_child(display)

	# Without the adjustment pass the engine draws to the viewport texture.
	var direct: Array = await measure()
	if not require(not direct[0].is_empty() and direct[1].swaps - direct[0].swaps >= FRAMES, "the EGL helper counts the frames: %s" % [direct]): return
	if not require(direct[0].attaches > 0, "the 3D view uses the tile MSAA attachment"): return
	if not require(direct[1].generated == direct[0].generated and direct[1].live == direct[0].live, "direct MSAA makes no framebuffer in %d frames: %s" % [FRAMES, direct]): return

	# The failing card build: the adjustment pass moves the 3D view to the internal buffer.
	world.environment.adjustment_enabled = true
	world.environment.adjustment_saturation = 1.05
	var internal: Array = await measure()
	if not require(internal[0].attaches > direct[1].attaches, "the internal buffer gets a tile MSAA framebuffer"): return
	var made: int = internal[1].generated - internal[0].generated
	var kept: int = internal[1].live - internal[0].live
	if not require(made == 0 and kept == 0, "internal-buffer MSAA makes no framebuffer in %d frames: generated %d, not deleted %d" % [FRAMES, made, kept]): return

	# Each change between the two modes must release the framebuffers of the mode before.
	for cycle in range(3):
		world.environment.adjustment_enabled = false
		var away: Array = await measure()
		if not require(away[1].generated == away[0].generated and away[1].live == direct[1].live, "cycle %d: direct MSAA returns to %d framebuffers: %s" % [cycle, direct[1].live, away]): return
		world.environment.adjustment_enabled = true
		var back: Array = await measure()
		if not require(back[0].attaches > away[1].attaches, "cycle %d: the internal buffer gets a new tile MSAA framebuffer" % cycle): return
		if not require(back[1].generated == back[0].generated and back[1].live == internal[1].live, "cycle %d: internal-buffer MSAA returns to %d framebuffers: %s" % [cycle, internal[1].live, back]): return

	# A new viewport size makes new textures. The framebuffers of the old textures must go.
	# The view is in the internal-buffer mode here. Then do the same in the direct mode.
	for mode in [["internal-buffer", internal[1].live], ["direct", direct[1].live]]:
		world.environment.adjustment_enabled = mode[0] != "direct"
		for size in [Vector2i(600, 400), Vector2i(720, 480), Vector2i(480, 320), Vector2i(720, 480)]:
			view.size = size
			var resized: Array = await measure()
			if not require(resized[0].attaches > direct[1].attaches, "%s MSAA at %s uses the tile MSAA attachment" % [mode[0], size]): return
			print(mode[0], " ", size, ": live ", resized[1].live)
			if not require(resized[1].generated == resized[0].generated and resized[1].live == mode[1], "%s MSAA at %s returns to %d framebuffers: %s" % [mode[0], size, mode[1], resized]): return
	world.environment.adjustment_enabled = true
	var last: Array = await measure()
	if not require(last[1].generated == last[0].generated and last[1].live == internal[1].live, "internal-buffer MSAA after the resizes returns to %d framebuffers: %s" % [internal[1].live, last]): return

	# A material that reads the screen makes the engine copy the frame before the
	# transparent pass. Tile MSAA loses its depth in that copy. Thus these frames
	# use MSAA render buffers: no tile MSAA attachment and a correct depth test.
	var glass := MeshInstance3D.new()
	glass.mesh = QuadMesh.new()
	glass.position = Vector3(0, 0, 1.5)
	# Set the code before the material gets the shader. If not, the quad has the default material.
	var screen_reader := Shader.new()
	screen_reader.code = "shader_type spatial;\nrender_mode unshaded, depth_draw_always;\nuniform sampler2D screen : hint_screen_texture;\nvoid fragment() { ALBEDO = texture(screen, SCREEN_UV).rgb * 0.2 + vec3(0.8, 0.0, 0.0); }\n"
	glass.material_override = ShaderMaterial.new()
	glass.material_override.shader = screen_reader
	var label := MeshInstance3D.new()
	label.mesh = QuadMesh.new()
	label.scale = Vector3(0.3, 0.3, 1)
	label.position = Vector3(0, 0, 1.502)
	label.material_override = StandardMaterial3D.new()
	label.material_override.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	label.material_override.albedo_color = Color(0, 1, 0)
	view.add_child(label)
	glass.visible = false
	view.add_child(glass)
	# The MSAA setting stays at 2x. Only the visibility of the glass changes:
	# tile MSAA, then MSAA render buffers, then tile MSAA, in the two buffer modes.
	# The framebuffer of the screen copy stays after its first use.
	var tile_live := {}
	for cycle in range(3):
		for adjusted in [true, false]:
			var mode := "internal-buffer" if adjusted else "direct"
			world.environment.adjustment_enabled = adjusted
			var before: Array = await measure()
			if not require(before[1].generated == before[0].generated, "cycle %d: %s tile MSAA is stable before the glass: %s" % [cycle, mode, before]): return
			glass.visible = true
			var copy: Array = await measure()
			if not require(copy[1].attaches == copy[0].attaches and copy[1].generated == copy[0].generated and copy[1].live == copy[0].live, "cycle %d: a %s screen copy frame uses constant MSAA render buffers: %s" % [cycle, mode, copy]): return
			var image := view.get_texture().get_image()
			if cycle == 0: image.save_png(OS.get_environment("SOCKET_FBO_COUNTS").get_base_dir().path_join("glass-%s.png" % mode))
			var on_label := image.get_pixel(360, 240)
			var on_glass := image.get_pixel(430, 240)
			if not require(on_label.g > 0.5 and on_label.r < 0.3, "cycle %d: %s: the label is in front of the glass: %s" % [cycle, mode, on_label]): return
			if not require(on_glass.r > 0.5 and on_glass.g < 0.3, "cycle %d: %s: the glass is in front of the box: %s" % [cycle, mode, on_glass]): return
			glass.visible = false
			var tile: Array = await measure()
			if not require(tile[0].attaches > copy[1].attaches, "cycle %d: the %s view returns to tile MSAA: %s" % [cycle, mode, tile]): return
			var added: int = tile[1].live - before[1].live
			if not require(tile[1].generated == tile[0].generated and added >= 0 and added <= 1, "cycle %d: %s tile MSAA returns to its framebuffers, plus at most the screen copy: before %s, after %s" % [cycle, mode, before, tile]): return
			if not require(tile[1].live == tile_live.get(mode, tile[1].live), "cycle %d: %s tile MSAA returns to %s framebuffers: %s" % [cycle, mode, tile_live.get(mode), tile]): return
			tile_live[mode] = tile[1].live
	print("tile MSAA framebuffers after a screen copy: ", tile_live)
	label.queue_free()
	glass.queue_free()
	world.environment.adjustment_enabled = true
	internal = await measure()

	# A change of the MSAA mode releases the MSAA framebuffer of the view.
	view.msaa_3d = Viewport.MSAA_DISABLED
	var off: Array = await measure()
	if not require(off[1].live < internal[1].live and off[1].generated == off[0].generated, "the view without MSAA releases its MSAA framebuffer: %s" % [off]): return
	print("framebuffers: direct ", direct[1].live, ", internal ", internal[1].live, ", MSAA off ", off[1].live, ", generated in all ", off[1].generated)

	print("PASS: MSAA framebuffers stay constant (", "emulated" if direct[0].emulated else "driver", " tile MSAA, live ", internal[1].live, ")")
	quit()
