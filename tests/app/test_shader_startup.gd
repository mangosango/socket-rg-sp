extends SceneTree

# Functional coverage only: --headless cannot compile GPU shaders or prove coverage.
var _failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)

func _run() -> void:
	check(DisplayServer.get_name() == "headless", "this test is headless functional coverage only")
	var helper = load("res://addons/FrontendPlugin/shader_startup.gd")
	check(helper != null and helper.can_instantiate(), "startup helper parses")
	if helper == null or not helper.can_instantiate():
		quit(1)
		return
	var main := Node.new()
	root.add_child(main)
	main.process_mode = Node.PROCESS_MODE_PAUSABLE
	var children := root.get_child_count()
	var old_oversampling := root.is_using_font_oversampling()
	for was_paused in [false, true]:
		root.set_use_font_oversampling(was_paused)
		paused = was_paused
		root.remove_meta("socket_shader_startup_complete")
		await helper.run(main)
		check(root.get_meta("socket_shader_startup_complete", false), "headless startup completes without waiting for draw")
		check(not root.get_meta("socket_shader_startup_active", false), "headless startup does not activate gate")
		check(not root.get_meta("socket_shader_startup_warmed", false), "headless never claims GPU warmup")
		check(paused == was_paused, "headless preserves pause state")
		check(root.is_using_font_oversampling() == was_paused, "headless preserves font oversampling")
		check(main.process_mode == Node.PROCESS_MODE_PAUSABLE, "headless preserves process mode")
		await helper.run(main)
		check(root.get_child_count() == children, "headless/repeated startup leaves no overlay or scene")
	paused = false

	# Palette APIs differ by release; exercise real resources, including inverted ink.
	var palette_script = load("res://scripts/theme_palette.gd") if ResourceLoader.exists("res://scripts/theme_palette.gd") else null
	var original_palette = palette_script.active() if palette_script else null
	var old_scale := root.content_scale_factor
	var old_size := root.size
	root.size = Vector2i(640, 480)
	for inverted in [false, true]:
		var expected_surface := Color.WHITE
		var expected_ink := Color(0.13, 0.13, 0.13)
		if palette_script:
			var palette = original_palette.duplicate()
			palette.low = Color(0.92, 0.92, 0.92) if inverted else Color(0.05, 0.05, 0.05)
			palette.high = Color(0.1, 0.1, 0.1) if inverted else Color(0.95, 0.95, 0.95)
			for property in palette.get_property_list():
				if property.name == "dark":
					palette.dark = inverted
			palette_script.set_active(palette)
			expected_surface = palette.call("recolor_surface" if palette.has_method("recolor_surface") else "recolor", expected_surface)
			expected_ink = palette.call("recolor_ink" if palette.has_method("recolor_ink") else "recolor", expected_ink)
		for ui_scale in [0.5, 1.0, 2.0]:
			root.content_scale_factor = ui_scale
			var status = helper.new()
			status.process_mode = Node.PROCESS_MODE_ALWAYS
			paused = true
			root.add_child(status)
			var label: Label = status.find_children("*", "Label", true, false)[0]
			var theme_manager = root.get_node("ThemeManager")
			if theme_manager.has_method("_on_node_added"):
				theme_manager.call("_on_node_added", label)
				theme_manager.call("_on_node_added", status._backdrop)
			await process_frame
			await process_frame
			check(status._backdrop.color.is_equal_approx(expected_surface), "palette surface survives deferred theme processing")
			check(label.get_theme_color("font_color").is_equal_approx(expected_ink), "palette ink survives deferred theme processing")
			check(label.get_theme_font_size("font_size") == 24, "legible native font size")
			check((root.get_stretch_transform() * status.transform).is_equal_approx(Transform2D.IDENTITY), "status cancels root UI scaling while paused")
			check(status._backdrop.size == Vector2(root.size), "native backdrop covers window")
			check(label.size == status._backdrop.size, "label centered across native backdrop: %s vs %s" % [label.size, status._backdrop.size])
			status.free()
	root.content_scale_factor = old_scale
	root.size = old_size
	if palette_script:
		palette_script.set_active(original_palette)
	paused = false

	# Exercise teardown independently, including early cancellation before warmup.
	for was_paused in [false, true]:
		root.set_use_font_oversampling(was_paused)
		var startup = helper.new()
		startup._main = main
		startup._tree = self
		startup._paused = was_paused
		startup._main_mode = Node.PROCESS_MODE_PAUSABLE
		var viewport := SubViewport.new()
		main.add_child(viewport)
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		startup._viewport = viewport
		startup._update_mode = SubViewport.UPDATE_WHEN_VISIBLE
		var carousel := Node3D.new()
		main.add_child(carousel)
		carousel.hide()
		startup._carousel = carousel
		startup._carousel_visible = true
		var holder := Node3D.new()
		main.add_child(holder)
		startup._holder = holder
		startup.process_mode = Node.PROCESS_MODE_ALWAYS
		main.process_mode = Node.PROCESS_MODE_DISABLED
		paused = true
		root.set_meta("socket_shader_startup_active", true)
		root.add_child(startup)
		check(not root.is_using_font_oversampling(), "native label rasterization ignores logical UI scale")
		var labels: Array = startup.find_children("*", "Label", true, false)
		check(labels.size() == 1 and labels[0].text == "Compiling shaders", "exact startup status label")
		startup._input(InputEventAction.new())
		check(root.is_input_handled(), "overlay consumes input")
		startup.free()
		check(root.is_using_font_oversampling() == was_paused, "cancellation restores original font oversampling")
		check(not is_instance_valid(holder), "temporary render geometry freed")
		check(viewport.render_target_update_mode == SubViewport.UPDATE_WHEN_VISIBLE, "viewport update policy restored")
		check(carousel.visible, "carousel visibility restored")
		check(paused == was_paused, "teardown restores prior pause")
		check(main.process_mode == Node.PROCESS_MODE_PAUSABLE, "teardown restores main processing")
		check(not root.get_meta("socket_shader_startup_active", true), "teardown releases input gate")
		viewport.free()
		carousel.free()
	paused = false

	root.set_use_font_oversampling(old_oversampling)

	# No library games are used: validate every built-in/regional model API and
	# every finish/label setter the GPU pass will call, without claiming draws.
	var material_helper = helper.new()
	var cartridge_script = load("res://scripts/cartridge.gd")
	var game_script = load("res://scripts/game.gd")
	var finish_bank = load("res://scripts/models/cart_finish_bank.gd")
	var manager = root.get_node("Manager")
	var seen := {}
	var models := 0
	var variants := 0
	for platform_id in manager.db.platforms:
		var script = manager.db.get_platform(platform_id)
		var model = script.new()
		var scenes: Array = [model.selectable_scene]
		for value in script.get_script_constant_map().values():
			if value is PackedScene:
				scenes.append(value)
		for scene in scenes:
			if scene == null:
				continue
			var key: String = scene.resource_path + ":" + str(model.is_disc_shaped)
			if seen.has(key):
				continue
			seen[key] = true
			var cart = scene.instantiate()
			if not is_instance_of(cart, cartridge_script):
				cart.free()
				continue
			var game = game_script.new()
			game.platform_id = platform_id
			if cart.default_label_material:
				cart.default_label_material = cart.default_label_material.duplicate()
			cart.set_game(game)
			# Setter/API checks do not attach render geometry to the dummy renderer.
			models += 1
			for finish in finish_bank.all():
				var material = finish_bank.build(finish.id, finish.fallback_color, cart.casing_maps())
				material_helper._set_casing(cart, material)
				for mesh in cart.casing_meshs:
					if mesh.get_surface_override_material_count() > 0:
						check(mesh.get_surface_override_material(0) == material, "all finishes bypass user gilding overrides")
				variants += 1
			material_helper._set_casing(cart, cart.default_casing_material)
			for index in cart.enabled_label_styles.size():
				cart.update_label_style(index + 1)
				variants += 1
			# Dummy rendering never flushes draws; keep final materials alive while
			# MeshInstance teardown scans dirty instances before freeing their RIDs.
			var retained_materials: Array = []
			for mesh in cart.find_children("*", "MeshInstance3D", true, false):
				retained_materials.append(mesh.material_override)
				retained_materials.append(mesh.material_overlay)
				if mesh.mesh:
					for surface in mesh.mesh.get_surface_count():
						retained_materials.append(mesh.get_active_material(surface))
			cart.free()
			retained_materials.clear()
	check(models > 0 and variants > models, "empty-library built-ins include material variants")
	var disc_scene = manager.db.get_platform("psx").new().selectable_scene
	check(seen.has(disc_scene.resource_path + ":true") and seen.has(disc_scene.resource_path + ":false"), "shared disc model covers both disc and Wii cartridge labels")
	material_helper.free()
	main.free()
	root.remove_meta("socket_shader_startup_complete")
	check(change_scene_to_file("res://scenes/main.tscn") == OK, "real main scene loads")
	for frame in range(10):
		await process_frame
	check(root.get_meta("socket_shader_startup_complete", false), "real main ready invokes startup hook")
	check(not paused and not root.get_meta("socket_shader_startup_active", false), "real main remains interactive after headless skip")
	check(not root.get_meta("socket_shader_startup_warmed", false), "real headless main never claims rendered warmup")
	if _failures == 0:
		print("PASS: shader startup headless lifecycle and empty-library model APIs: ", models, " models, ", variants, " variants; GPU efficacy NOT tested")
	quit(1 if _failures else 0)
