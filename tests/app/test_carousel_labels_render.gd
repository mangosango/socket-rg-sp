# Render real carousel labels with the packed project and the Compatibility renderer.
# Set SOCKET_LABEL_EVIDENCE to a writable output directory and SOCKET_TEST_ROOT to
# a folder with One.gba and Two.gba.
extends SceneTree

const STYLES := ["paper", "holo_foil_sticker", "chrome_outline_sticker"]

func _initialize() -> void:
	_run.call_deferred()

func require(ok: bool, message: String) -> bool:
	if not ok:
		printerr("FAIL: ", message)
		quit(1)
	return ok

func measure(image: Image, base: Image) -> Dictionary:
	var clipped := 0
	var mid := 0.0
	var mid_count := 0
	var saturation := 0.0
	var saturation_count := 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var color := image.get_pixel(x, y)
			if color.a < 0.5:
				continue
			if maxf(color.r, maxf(color.g, color.b)) >= 0.99:
				clipped += 1
			var before := base.get_pixel(x, y)
			var level := (before.r + before.g + before.b) / 3.0
			if level > 0.2 and level < 0.6:
				mid += ((color.r + color.g + color.b) / 3.0) / level
				mid_count += 1
			if before.s > 0.5 and before.v > 0.3 and before.v < 0.95:
				saturation += color.s / before.s
				saturation_count += 1
	return {"clipped": clipped, "mid": mid / maxi(mid_count, 1), "saturation": saturation / maxi(saturation_count, 1) if saturation_count > 0 else 1.0}

func _run() -> void:
	OS.low_processor_usage_mode = false
	root.size = Vector2i(720, 480)
	var output := OS.get_environment("SOCKET_LABEL_EVIDENCE")
	DirAccess.make_dir_recursive_absolute(output)
	var manager = root.get_node("Manager")
	load("res://scripts/models/emulator_database.gd").store("gba", [{"uniqueId": "gba.ra64.mgba", "name": "mGBA", "acceptedFilenameRegex": "[.]gba$", "amStartArguments": "-n com.retroarch/.Main -e LIBRETRO mgba"}])
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	for i in range(30): await process_frame
	var home = load("res://scripts/screens/screen.gd").get_screen("main")
	# White paper with saturated blocks. Bright label art is common.
	var art := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	for y in range(256):
		for x in range(256):
			var color := Color.WHITE
			if y > 80 and y < 176:
				color = Color(0.9, 0.2, 0.15) if x < 128 else Color(0.95, 0.85, 0.2)
			if y > 200:
				color = Color(0.2, 0.45, 0.9)
			art.set_pixel(x, y, color)
	DirAccess.make_dir_recursive_absolute("user://scraped_data/gba")
	var platform = load("res://scripts/platform.gd").new()
	platform.model = manager.db.get_platform("gba").new()
	platform.app_id = "gba.ra64.mgba"
	platform.rom_folder_path = OS.get_environment("SOCKET_TEST_ROOT")
	manager.add_platform_to_user(manager.current_user, platform)
	for game_name in ["One", "Two"]:
		art.save_png("user://scraped_data/gba/%s_support.png" % game_name)
		var info := FileAccess.open("user://scraped_data/gba/%s.json" % game_name, FileAccess.WRITE)
		info.store_string(JSON.stringify({"matched": true, "method": "md5", "game_id": 1, "name": game_name, "platform": "nintendo-game-boy-advance", "region": "World", "texture_url": "", "labels": [], "meta": {}}))
		info.close()
	await manager.scan_platform_in_user(manager.current_user, platform)
	var carousel = home.carousel_3d
	# The carousel adds hidden shader warm-up meshes with label materials and frees each
	# after 2 frames. A cached warm-up mesh is a freed object later (release builds crash).
	if OS.get_environment("SOCKET_LABEL_WARMUP_PROBE") == "1":
		for i in range(3000):
			# The original collection filter over the whole 3D view.
			for mesh in home.viewport_3d.find_children("*", "MeshInstance3D", true, false):
				if not mesh.material_override or not _is_label(mesh.get_active_material(0)):
					continue
				if not require(mesh.get_parent() == carousel and not _in_active_cartridge(carousel, mesh), "captured mesh is a carousel warm-up mesh, not an active cartridge"): return
				var cached: MeshInstance3D = mesh
				for frame in range(3): await process_frame
				if not require(not is_instance_valid(cached), "warm-up label mesh is freed within 3 frames"): return
				print("PASS: the original label filter captured a live warm-up mesh (carousel child, material_override, not in an active cartridge); it was freed within 3 frames")
				quit()
				return
			await process_frame
		require(false, "no warm-up label mesh appeared")
		return
	for i in range(200): await process_frame
	# Wait until no warm-up mesh exists for 30 frames, so none can be collected.
	var quiet := 0
	for i in range(3000):
		quiet = 0 if carousel.get_children().any(func(node): return node is MeshInstance3D and node.material_override) else quiet + 1
		if quiet >= 30:
			break
		await process_frame
	if not require(quiet >= 30, "shader warm-up finishes"): return
	if not require(home.carousel_3d.games.size() == 2, "carousel shows the fixture games"): return
	home.carousel_3d.set_process(false)
	var view: SubViewport = home.viewport_3d
	var worlds := view.find_children("*", "WorldEnvironment", true, false)
	if not require(worlds.size() == 1, "cartridge view has one environment"): return
	var environment: Environment = worlds[0].environment
	var fixed := {"tonemap": environment.tonemap_mode, "white": environment.tonemap_white, "adjust": environment.adjustment_enabled,
		"brightness": environment.adjustment_brightness, "contrast": environment.adjustment_contrast, "saturation": environment.adjustment_saturation}
	print("environment ", fixed)
	# Crash investigation only: render every style without the look assertions,
	# so a pack without the label fix also reaches each material swap.
	var crash_only := OS.get_environment("SOCKET_LABEL_CRASH_ONLY") == "1"
	# Crash investigation only: keep adjustments on for "before", so the test does not toggle them.
	var keep_adjust := OS.get_environment("SOCKET_LABEL_KEEP_ADJUST") == "1"
	if not crash_only and not require(fixed.tonemap == Environment.TONE_MAPPER_REINHARDT and is_equal_approx(fixed.white, 1.3) and fixed.adjust
			and is_equal_approx(fixed.brightness, 1.0) and is_equal_approx(fixed.contrast, 1.0), "pack applies one Reinhard pass after all lights"): return
	# Collect labels only from the carousel's active cartridges, never from warm-up meshes.
	var labels := []
	for cart in carousel.active_cartridges.values():
		for mesh in cart.find_children("*", "MeshInstance3D", true, false):
			if mesh.material_override or mesh.is_queued_for_deletion():
				continue
			for surface in (mesh.mesh.get_surface_count() if mesh.mesh else 0):
				var material = mesh.get_active_material(surface)
				if _is_label(material):
					labels.append([mesh, surface, material, mesh.get_surface_override_material(surface)])
	if not require(labels.size() >= 2, "carousel has label surfaces"): return
	for style in STYLES:
		for label in labels:
			if not require(is_instance_valid(label[0]), "label mesh is valid before " + style): return
			if not require(not label[0].is_queued_for_deletion(), "label mesh is not queued for deletion before " + style): return
			if not require(label[0].material_override == null, "label mesh is not a warm-up mesh before " + style): return
			if not require(_in_active_cartridge(carousel, label[0]), "label mesh belongs to an active cartridge before " + style): return
		for label in labels:
			var material = label[3]
			if style != "paper":
				material = load("res://res/label_styles/materials/" + style + ".tres").duplicate()
				material.set_shader_parameter("artwork_texture", label[2].get_shader_parameter("artwork_texture"))
			label[0].set_surface_override_material(label[1], material)
		var images := {}
		for variant in ["before", "fixed", "turned"]:
			# Restore only the original environment to reproduce the defect.
			environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR if variant == "before" else fixed.tonemap
			environment.tonemap_white = 1.0 if variant == "before" else fixed.white
			environment.adjustment_enabled = fixed.adjust if keep_adjust else (variant != "before" and fixed.adjust)
			home.carousel_3d.rotation_degrees.y = 12.0 if variant == "turned" else 0.0
			for i in range(6): await process_frame
			await RenderingServer.frame_post_draw
			images[variant] = view.get_texture().get_image()
			images[variant + "_ui"] = root.get_texture().get_image()
			if not require(images[variant].save_png(output.path_join("%s-%s.png" % [style, variant])) == OK, "save rendered evidence"): return
		home.carousel_3d.rotation_degrees.y = 0.0
		var before := measure(images.before, images.before)
		var after := measure(images.fixed, images.before)
		print(style, " before clipped=", before.clipped, " fixed clipped=", after.clipped, " mid=", snappedf(after.mid, 0.001), " saturation=", snappedf(after.saturation, 0.001))
		if crash_only:
			continue
		if not require(before.clipped > 500, style + ": original environment reproduces clipped labels"): return
		if not require(after.clipped == 0, style + ": fixed labels keep highlight detail"): return
		if not require(after.mid > 0.95 and after.mid < 1.03, style + ": midtones stay within 5 percent"): return
		if not require(after.saturation > 0.95, style + ": colors keep their saturation"): return
		if not require(images.turned.get_data() != images.fixed.get_data(), style + ": finish responds to rotation"): return
		# The 2D UI around the cartridge view must not change.
		for y in range(0, 40):
			for x in range(0, 720, 3):
				if not require(images.fixed_ui.get_pixel(x, y) == images.before_ui.get_pixel(x, y), "native UI pixels stay the same"): return
	if crash_only:
		print("CRASH-ONLY: rendered every style without a crash")
		quit()
		return
	print("PASS: carousel labels keep highlight detail, midtones, colors, finish response and native UI")
	quit()


func _is_label(material) -> bool:
	return material is ShaderMaterial and material.shader and material.shader.resource_path.ends_with("paper_sticker.gdshader")


func _in_active_cartridge(carousel, node: Node) -> bool:
	for cart in carousel.active_cartridges.values():
		if is_instance_valid(cart) and cart.is_ancestor_of(node):
			return true
	return false
