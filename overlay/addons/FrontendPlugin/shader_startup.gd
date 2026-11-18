extends CanvasLayer

# Replay real draws each process start: a marker cannot validate a driver's cache.
# Godot persists GLES program binaries in user://shader_cache (source/GPU keyed).
var _main: Node
var _tree: SceneTree
var _paused: bool
var _main_mode: int
var _viewport: SubViewport
var _update_mode: int
var _carousel: Node3D
var _carousel_visible: bool
var _holder: Node3D
var _backdrop: ColorRect
var _window: Window
var _font_oversampling: bool
var _spinner: Control
var _angle := 0.0
# Benchmark data: the longest time between two presented frames is the longest
# visible freeze. The frame-rate log stores these values in its first sample.
var _started_usec := Time.get_ticks_usec()
var _presented_usec := 0
var _longest_frame_usec := 0
var _sets := 0
var _draws := 0
var _presents := 0
var _offscreen := false
# Each present waits for the panel refresh. Show a frame only when the status
# animation is due. The other warmup draws render fully, but without a present.
# 50 ms keeps the animation rate that the RG SP showed with one present per draw.
const PRESENT_USEC := 50000
# A smaller model fills fewer pixels. Shader variants do not depend on its size.
const FILL_SCALE := 0.5

static func run(main: Node) -> void:
	var tree := main.get_tree()
	if tree.root.get_meta("socket_shader_startup_complete", false):
		return
	if DisplayServer.get_name() == "headless":
		tree.root.set_meta("socket_shader_startup_complete", true)
		return
	var startup = load("res://addons/FrontendPlugin/shader_startup.gd").new()
	startup._main = main
	startup._tree = tree
	startup._paused = tree.paused
	startup._main_mode = main.process_mode
	main.process_mode = Node.PROCESS_MODE_DISABLED
	tree.paused = true
	tree.root.set_meta("socket_shader_startup_active", true)
	startup.process_mode = Node.PROCESS_MODE_ALWAYS
	startup.layer = 128
	main.tree_exiting.connect(startup.queue_free, CONNECT_ONE_SHOT)
	tree.root.add_child(startup)
	await startup._warm()
	startup.free()

func _ready() -> void:
	_window = get_viewport().get_window()
	_font_oversampling = _window.is_using_font_oversampling()
	# CanvasLayer inverse scaling does not cancel the viewport's font raster scale.
	_window.set_use_font_oversampling(false)
	_backdrop = ColorRect.new()
	_backdrop.color = Color.WHITE
	var ink := Color(0.13, 0.13, 0.13)
	# 0.3.2 has no palette; 0.8.0 has recolor but no separate surface/ink API.
	if ResourceLoader.exists("res://scripts/theme_palette.gd"):
		var palette = load("res://scripts/theme_palette.gd").active()
		_backdrop.color = palette.call("recolor_surface" if palette.has_method("recolor_surface") else "recolor", Color.WHITE)
		ink = palette.call("recolor_ink" if palette.has_method("recolor_ink") else "recolor", ink)
	var theme_manager := get_node_or_null("/root/ThemeManager")
	if theme_manager != null and theme_manager.has_method("get_active_theme"):
		_backdrop.theme = theme_manager.call("get_active_theme")
	_add_dots()
	# The surface plate keeps the ink legible on all dot colors and themes.
	var center := CenterContainer.new()
	_backdrop.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var plate := PanelContainer.new()
	var box := StyleBoxFlat.new()
	box.bg_color = _backdrop.color
	box.set_corner_radius_all(10)
	box.set_content_margin_all(12)
	plate.add_theme_stylebox_override("panel", box)
	center.add_child(plate)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	plate.add_child(row)
	# Socket 0.10.1 has a spinner. For the other versions, draw a small arc.
	if ResourceLoader.exists("res://scenes/ui/spinner.gd"):
		_spinner = load("res://scenes/ui/spinner.gd").new()
		_spinner.set("color", ink)
		_spinner.set("thickness", 3.0)
	else:
		_spinner = Control.new()
		_spinner.draw.connect(_draw_arc.bind(ink))
	_spinner.custom_minimum_size = Vector2(28, 28)
	row.add_child(_spinner)
	var label := Label.new()
	label.text = "Compiling shaders"
	label.add_theme_color_override("font_color", ink)
	# 22 is two times the 11-pixel grid of the default pixel font.
	label.add_theme_font_size_override("font_size", 22)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	# These colors are already palette-resolved, like boot's adaptive controls.
	# Mark each control before it enters the tree, so the theme does not recolor it.
	for node in [_backdrop] + _backdrop.find_children("*", "", true, false):
		node.set_meta("socket_adaptive_surface", true)
	add_child(_backdrop)
	RenderingServer.frame_post_draw.connect(_on_presented)
	_process(0.0)

# Show the moving dots of the Socket launch screen behind the status. This
# uses the dots material of a node that is in the tree (the boot screen on
# 0.10.1, the menu background on older versions). It does not load a scene.
func _add_dots() -> void:
	for node in get_tree().root.find_children("*", "Control", true, false):
		var material := node.material as ShaderMaterial
		if material == null or material.shader == null or material.shader.resource_path != "res://scenes/scrolling_dots.gdshader":
			continue
		# The shader sets the dot spacing from the height of its node. Keep the
		# spacing on the panel the same when the node height is not the panel height.
		var height: float = absf((node.get_viewport_transform() * node.get_global_transform()).y.y) * node.size.y
		if height < 1.0:
			continue
		var dots := ColorRect.new()
		dots.material = material.duplicate()
		var density = material.get_shader_parameter("density")
		if density == null:
			density = RenderingServer.shader_get_parameter_default(material.shader.get_rid(), "density")
		dots.material.set_shader_parameter("density", float(density) * get_viewport().get_window().size.y / height)
		# The dots of older menus do not move. Use the scroll of the launch screen.
		var scroll = material.get_shader_parameter("scroll_direction")
		if scroll is Vector2 and scroll.is_zero_approx():
			dots.material.set_shader_parameter("scroll_direction", Vector2(0.1, 0.1))
		_backdrop.add_child(dots)
		dots.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		return

func _draw_arc(ink: Color) -> void:
	_spinner.draw_arc(Vector2(14, 14), 11.0, 0.0, TAU, 32, Color(ink, 0.2), 3.0, true)
	_spinner.draw_arc(Vector2(14, 14), 11.0, _angle, _angle + TAU * 0.3, 16, ink, 3.0, true)

func _on_presented() -> void:
	if _offscreen:
		return
	_presents += 1
	var now := Time.get_ticks_usec()
	if _presented_usec > 0:
		_longest_frame_usec = maxi(_longest_frame_usec, now - _presented_usec)
	_presented_usec = now

func _process(delta: float) -> void:
	# Match the HUD: keep the status legible in native pixels at every UI scale.
	transform = get_viewport().get_stretch_transform().affine_inverse()
	_backdrop.size = get_viewport().get_window().size
	_angle = fposmod(_angle + 5.0 * delta, TAU)
	_spinner.queue_redraw()

func _input(_event: InputEvent) -> void:
	get_viewport().set_input_as_handled()

func _warm() -> void:
	# Present the status before resource loading/instantiation can stall GLES.
	await RenderingServer.frame_post_draw
	var menu: Node
	for node in _main.find_children("*", "", true, false):
		if node is ScreenMainMenu:
			menu = node
			break
	if menu == null:
		push_warning("Shader startup: main menu not found")
		return
	_viewport = menu.viewport_3d
	_carousel = menu.carousel_3d
	_update_mode = _viewport.render_target_update_mode
	_carousel_visible = _carousel.visible
	_carousel.hide()
	# Keep the exact live camera, lights, environment, transparency and AA path.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_holder = Node3D.new()
	_carousel.get_parent().add_child(_holder)
	_holder.transform = _carousel.transform
	await RenderingServer.frame_post_draw
	if _viewport.size.x < 2 or _viewport.size.y < 2 or _viewport.get_camera_3d() == null:
		push_warning("Shader startup: render target is not ready")
		return
	# Leave the draw callback: _draw must not start a draw from inside a draw.
	await _tree.process_frame
	var seen := {}
	for platform_id in Manager.db.platforms:
		var script = Manager.db.get_platform(platform_id)
		var model = script.new()
		var scenes: Array = [model.selectable_scene]
		# Regional/dual-mode models are constants, not necessarily in the library.
		for value in script.get_script_constant_map().values():
			if value is PackedScene:
				scenes.append(value)
		for scene in scenes:
			if scene == null:
				continue
			# Some platforms share the disc mesh but use cartridge label materials.
			var key: String = scene.resource_path + ":" + str(model.is_disc_shaped)
			if seen.has(key):
				continue
			seen[key] = true
			var cart = scene.instantiate()
			if not cart is Cartridge:
				cart.free()
				continue
			var game := Game.new()
			game.platform_id = platform_id
			# set_game writes label uniforms; never touch a library cart's shared default.
			if cart.default_label_material:
				cart.default_label_material = cart.default_label_material.duplicate()
			cart.set_game(game)
			_holder.add_child(cart)
			cart.position = Vector3(0, 0.45, 0)
			cart.rotation_degrees = Vector3(-70, 0, 20)
			cart.scale = (_carousel.call("_slot_scale", 0) if _carousel.has_method("_slot_scale") else Vector3.ONE * 1.4) * FILL_SCALE
			_set_casing(cart, cart.default_casing_material)
			await _draw_cart(cart)
			for finish in CartFinishBank.all():
				# Bypass user cheats (gilding), not the normal finish/texture builder.
				_set_casing(cart, CartFinishBank.build(finish.id, finish.fallback_color, cart.casing_maps()))
				await _draw_cart(cart)
			_set_casing(cart, cart.default_casing_material)
			for index in cart.enabled_label_styles.size():
				cart.update_label_style(index + 1)
				await _draw_cart(cart)
			cart.free()
	_sets = seen.size()
	_tree.root.set_meta("socket_shader_startup_warmed", not seen.is_empty())
	print("Shader startup: rendered ", seen.size(), " built-in model/label sets")

func _set_casing(cart: Cartridge, material: Material) -> void:
	for mesh in cart.casing_meshs:
		if mesh.get_surface_override_material_count() > 0:
			mesh.set_surface_override_material(0, material)

func _draw_cart(cart: Node3D) -> void:
	# Both front and back use real geometry, inside the frustum.
	await _draw()
	cart.rotation_degrees.y = 180
	await _draw()
	cart.rotation_degrees.y = 0
	_draws += 2

# Draw all viewports one time with the current warmup geometry.
func _draw() -> void:
	if Time.get_ticks_usec() - _presented_usec >= PRESENT_USEC:
		# The frame of this main loop iteration draws, presents and moves the status.
		await _tree.process_frame
		return
	# The scene tree sends Node3D transforms to the renderer only at its flush.
	_holder.propagate_call("force_update_transform")
	_offscreen = true
	# No buffer swap and no time step: GLES finishes the draw, the status does not move.
	RenderingServer.force_draw(false)
	_offscreen = false

func _exit_tree() -> void:
	if is_instance_valid(_window):
		_window.set_use_font_oversampling(_font_oversampling)
	if is_instance_valid(_holder):
		_holder.free()
	if is_instance_valid(_viewport):
		_viewport.render_target_update_mode = _update_mode
	if is_instance_valid(_carousel):
		_carousel.visible = _carousel_visible
	if is_instance_valid(_main):
		_main.process_mode = _main_mode
	if is_instance_valid(_tree):
		_tree.paused = _paused
		_tree.root.set_meta("socket_shader_startup_active", false)
		var now := Time.get_ticks_usec()
		var stats := {"sets": _sets, "draws": _draws, "presents": _presents, "warmup_ms": (now - _started_usec) / 1000.0, "longest_frame_ms": _longest_frame_usec / 1000.0, "first_input_ms": now / 1000.0}
		_tree.root.set_meta("socket_shader_startup_stats", stats)
		print("Shader startup: ", JSON.stringify(stats))
		# Completion releases the boot gate; _warmed records a completed draw replay.
		_tree.root.set_meta("socket_shader_startup_complete", true)
