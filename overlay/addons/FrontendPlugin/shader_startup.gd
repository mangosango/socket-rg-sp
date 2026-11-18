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
	# These colors are already palette-resolved, like boot's adaptive controls.
	_backdrop.set_meta("socket_adaptive_surface", true)
	add_child(_backdrop)
	var label := Label.new()
	label.set_meta("socket_adaptive_surface", true)
	label.text = "Compiling shaders"
	label.add_theme_color_override("font_color", ink)
	label.add_theme_font_size_override("font_size", 24)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_backdrop.add_child(label)
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_process(0.0)

func _process(_delta: float) -> void:
	# Match the HUD: keep the status legible in native pixels at every UI scale.
	transform = get_viewport().get_stretch_transform().affine_inverse()
	_backdrop.size = get_viewport().get_window().size

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
			cart.scale = _carousel.call("_slot_scale", 0) if _carousel.has_method("_slot_scale") else Vector3.ONE * 1.4
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
	_tree.root.set_meta("socket_shader_startup_warmed", not seen.is_empty())
	print("Shader startup: rendered ", seen.size(), " built-in model/label sets")

func _set_casing(cart: Cartridge, material: Material) -> void:
	for mesh in cart.casing_meshs:
		if mesh.get_surface_override_material_count() > 0:
			mesh.set_surface_override_material(0, material)

func _draw_cart(cart: Node3D) -> void:
	# Both front and back use real geometry at navigation scale, inside the frustum.
	await RenderingServer.frame_post_draw
	cart.rotation_degrees.y = 180
	await RenderingServer.frame_post_draw
	cart.rotation_degrees.y = 0

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
		# Completion releases the boot gate; _warmed records a completed draw replay.
		_tree.root.set_meta("socket_shader_startup_complete", true)
