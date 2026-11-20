extends Node

const ACTIVE := &"socket_split_label_active"
const VIEWPORT := &"socket_split_label_viewport"
# Outside the packed cameras' 20 editor layers. The body camera never sees it.
const NATIVE_LAYER := 1 << 20
const CAMERA_PROPERTIES := [&"attributes", &"environment", &"h_offset", &"v_offset"]
const LENS := [&"keep_aspect", &"projection", &"fov",
	&"size", &"near", &"far", &"frustum_offset"]
const VIEW_PROPERTIES := [&"positional_shadow_atlas_size", &"positional_shadow_atlas_16_bits",
	&"positional_shadow_atlas_quad_0", &"positional_shadow_atlas_quad_1", &"positional_shadow_atlas_quad_2",
	&"positional_shadow_atlas_quad_3", &"mesh_lod_threshold"]

var _body: SubViewport
var _display: TextureRect
var _surfaces: Script
var _eraser: ShaderMaterial
var _two_sided_eraser: ShaderMaterial
var _warm_cart: Node3D
var _view: SubViewport
var _camera: Camera3D
var _light: DirectionalLight3D
var _plain: ShaderMaterial
var _plain_shader: Shader
var _split: ShaderMaterial
var _records: Dictionary[int, Dictionary] = {}
var _geometry: Dictionary[ArrayMesh, Array] = {}
var _crop := Rect2i()
var _panel := Vector2i.ZERO
var _edge_aa := false
var _drawn_body_size := Vector2i.ZERO
var _drawn_body_msaa := Viewport.MSAA_DISABLED
var _needs_body_refresh := false
var _restore_mode := -1


func start(body: SubViewport, display: TextureRect) -> void:
	if _body != null or get_parent() != body or display == null or not _supported_renderer():
		return
	var surfaces_path := "res://addons/FrontendPlugin/split_label_surfaces.gd"
	var eraser_path := "res://shaders/split_label_occluder.gdshader"
	if not ResourceLoader.exists(surfaces_path) or not ResourceLoader.exists(eraser_path):
		return
	_surfaces = load(surfaces_path) as Script
	var shader := load(eraser_path) as Shader
	if _surfaces == null or shader == null:
		return
	_eraser = ShaderMaterial.new()
	_eraser.shader = shader
	_eraser.render_priority = Material.RENDER_PRIORITY_MAX
	var two_sided := Shader.new()
	two_sided.code = "#define BLOCK_BOTH_FACES\n" + shader.code
	_two_sided_eraser = _eraser.duplicate()
	_two_sided_eraser.shader = two_sided
	_body = body
	_display = display
	_body.set_meta(ACTIVE, false)
	RenderingServer.frame_pre_draw.connect(_before_draw)


func warmup(cart: Node3D) -> void:
	_warm_cart = cart
	if cart == null:
		_deactivate()


func _supported_renderer() -> bool:
	return (OS.get_name() == "Linux" and DisplayServer.get_name() == "fbdev"
		and ProjectSettings.get_setting("application/config/version", "") == "0.10.1"
		and RenderingServer.get_current_rendering_method() == "gl_compatibility"
		and RenderingServer.get_current_rendering_driver_name() == "opengl3_es")


func _before_draw() -> void:
	var warming := is_instance_valid(_warm_cart)
	var visible := (is_instance_valid(_display) and _display.is_inside_tree()
		and (warming or _display.is_visible_in_tree()))
	if not visible or not _sync(warming):
		_deactivate()
	if visible and _needs_body_refresh:
		_refresh_body()


func _sync(warming: bool) -> bool:
	if (_display.texture != _body.get_texture() or _display.use_parent_material
			or _display.get_parent() != _body.get_parent() or not _body.transparent_bg
			or _body.render_target_clear_mode != SubViewport.CLEAR_MODE_ALWAYS
			or _body.render_target_update_mode == SubViewport.UPDATE_DISABLED
			or _body.scaling_3d_scale != 1.0 or get_tree().physics_interpolation):
		return false
	var scaled := _body.size
	var pixels := _native_size()
	# A different rounded aspect changes the projected position in display UVs.
	if pixels.x <= scaled.x or pixels.y <= scaled.y or pixels.x * scaled.y != pixels.y * scaled.x:
		return false
	var source_camera := _body.get_camera_3d()
	var sun := _body.get_node_or_null(^"DirectionalLight3D") as DirectionalLight3D
	var carousel := (_warm_cart.get_parent() if warming else _body.get_node_or_null(^"CartridgeCarousel")) as Node3D
	if (source_camera == null or source_camera.cull_mask & NATIVE_LAYER or sun == null
			or carousel == null or carousel.get_parent() != _body
			or bool(sun.layers & NATIVE_LAYER) != (_view != null)
			or (_view != null and (_light != sun or _view.world_3d != _body.find_world_3d()))):
		return false
	for child in _body.get_children():
		if child is Node3D and child.is_visible_in_tree() and child not in [carousel, source_camera, sun]:
			return false
	var frame: Dictionary = _surfaces.discover(carousel)
	if frame.is_empty() or (warming and (frame.carts.size() != 1 or frame.carts[0].cart != _warm_cart)):
		return false
	var selected: Cartridge = _warm_cart if warming else carousel.get("selected_game")
	var cover: MeshInstance3D
	for data: Dictionary in frame.carts:
		if data.cart == selected:
			cover = data.label_mesh
		if data.label_mesh != null and not _matches_layers(data.label_mesh, source_camera, sun):
			return false
		for source: MeshInstance3D in data.body_meshes:
			if not _matches_layers(source, source_camera, sun):
				return false
	if cover == null:
		return false
	var auto_aa := OS.get_environment("SOCKET_3D_MSAA") == "auto"
	var edge: bool = (auto_aa and SettingsManager.cartridge_msaa_mode() != Viewport.MSAA_DISABLED
		and SettingsManager.get_setting("cartridge_msaa") and not get_tree().root.get_meta("socket_cartridge_msaa_paused", false))
	if not _prepare_display(edge):
		return false
	if _view == null:
		_open_view(sun)
		_needs_body_refresh = true
	if auto_aa and _body.msaa_3d != Viewport.MSAA_DISABLED:
		# Glass otherwise forces a multisample color/depth resolve in the middle of the body pass.
		_body.msaa_3d = Viewport.MSAA_DISABLED
	if scaled != _drawn_body_size or _body.msaa_3d != _drawn_body_msaa:
		_drawn_body_size = scaled
		_drawn_body_msaa = _body.msaa_3d
		_needs_body_refresh = true
	_copy_properties(_body, _view, VIEW_PROPERTIES)
	_copy_properties(source_camera, _camera, CAMERA_PROPERTIES)
	if _camera.global_transform != source_camera.global_transform:
		_camera.global_transform = source_camera.global_transform
		_camera.force_update_transform()
	_sync_proxies(frame.carts, selected, frame.keep_body_labels)
	_fit_label(source_camera, _records[cover.get_instance_id()].label, selected, pixels)
	if _display.material != _split:
		_split.set_shader_parameter(&"native_label", _view.get_texture())
		_display.material = _split
		_needs_body_refresh = true
		_body.set_meta(ACTIVE, true)
	return true


func _native_size() -> Vector2i:
	var window := get_tree().root
	var logical := window.get_visible_rect().size
	if logical.x <= 0.0 or logical.y <= 0.0:
		return Vector2i.ZERO
	var pixels := _display.size * _display.get_global_transform().get_scale().abs() * Vector2(window.size) / logical
	return Vector2i(pixels.round())


# A cropped camera fits a different directional shadow map. Keep the original
# projection when another cartridge can cast a shadow onto the selected artwork.
func _shared_shadow(label: MeshInstance3D, selected: Cartridge) -> bool:
	if not _light.shadow_enabled:
		return false
	var light_space := _light.global_transform.affine_inverse()
	var area := _light_bounds(label, light_space)
	for record: Dictionary in _records.values():
		var source := record.source as MeshInstance3D
		if record.shadows != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and not selected.is_ancestor_of(source) and area.intersects(_light_bounds(source, light_space)):
			return true
	return false


func _light_bounds(mesh: MeshInstance3D, light_space: Transform3D) -> Rect2:
	var box := (light_space * mesh.global_transform) * mesh.get_aabb()
	return Rect2(box.position.x, box.position.y, box.size.x, box.size.y)


# Off-axis crop, not a zoom: one texel still lands on exactly one panel pixel.
# Use two target sizes per axis so idle tilt/scroll move the frustum, not the allocation.
func _fit_label(camera: Camera3D, mesh: MeshInstance3D, selected: Cartridge, panel: Vector2i) -> void:
	var rect := Rect2i(Vector2i.ZERO, panel)
	if (camera.projection == Camera3D.PROJECTION_PERSPECTIVE and camera.attributes == null
			and _body.render_target_update_mode == SubViewport.UPDATE_ALWAYS and not _shared_shadow(mesh, selected)):
		var box := mesh.get_aabb()
		var projected := Rect2()
		for i in 8:
			var world := mesh.to_global(box.get_endpoint(i))
			if camera.is_position_behind(world):
				projected = Rect2()
				break
			var pt := camera.unproject_position(world) * Vector2(panel) / Vector2(_body.size)
			projected = Rect2(pt, Vector2.ZERO) if i == 0 else projected.expand(pt)
		if projected.has_area():
			var bounds := projected.grow(2).intersection(Rect2(rect))
			var half := panel / 2
			rect.size = Vector2i(half.x if bounds.size.x <= half.x else panel.x, half.y if bounds.size.y <= half.y else panel.y)
			if _panel == panel and _crop.size == rect.size and Rect2(_crop).encloses(bounds):
				rect = _crop # Idle tilt usually fits without moving the frustum or its shadow map.
			else:
				rect.position = Vector2i((bounds.get_center() - Vector2(rect.size) * 0.5).round()).clamp(Vector2i.ZERO, panel - rect.size)
	if rect.size == panel:
		_copy_properties(camera, _camera, LENS)
	else:
		var projection := camera.get_camera_projection()
		var pixel := 2.0 * camera.near / (projection.y.y * panel.y)
		var offset := (Vector2(rect.position) + Vector2(rect.size - panel) * 0.5) * pixel * Vector2(1, -1)
		if _camera.keep_aspect != Camera3D.KEEP_HEIGHT:
			_camera.keep_aspect = Camera3D.KEEP_HEIGHT
		_camera.set_frustum(rect.size.y * pixel, offset, camera.near, camera.far)
	if _view.size != rect.size:
		_view.size = rect.size
		_needs_body_refresh = true
	if _crop != rect or panel != _panel or _display.material != _split:
		_panel = panel
		var uv := Vector2(rect.position) / Vector2(panel)
		var span := Vector2(rect.size) / Vector2(panel)
		_split.set_shader_parameter(&"label_rect", Vector4(uv.x, uv.y, span.x, span.y))
		_crop = rect


func _matches_layers(source: MeshInstance3D, camera: Camera3D, sun: DirectionalLight3D) -> bool:
	var owned := _records.get(source.get_instance_id(), {}) as Dictionary
	var layers := source.layers
	var shadows := source.cast_shadow
	if not owned.is_empty():
		if layers != owned.split_layers or shadows != owned.split_shadows:
			return false
		layers = owned.layers
		shadows = owned.shadows
	var sun_layers := sun.layers & ~NATIVE_LAYER
	return (layers & NATIVE_LAYER == 0 and layers & camera.cull_mask != 0
		and shadows in [GeometryInstance3D.SHADOW_CASTING_SETTING_ON, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF]
		and (sun_layers & camera.cull_mask != 0)
		and bool(sun.light_cull_mask & layers) == bool(sun.light_cull_mask & NATIVE_LAYER)
		and bool(sun.shadow_caster_mask & layers & camera.cull_mask) == bool(sun.shadow_caster_mask & NATIVE_LAYER))


func _prepare_display(edge: bool) -> bool:
	var plain := _plain if _display.material == _split else _display.material as ShaderMaterial
	if plain == null or plain.shader == null:
		return false
	if _split != null and plain == _plain and plain.shader == _plain_shader and edge == _edge_aa:
		return true
	var code := plain.shader.code
	if not "DISPLAY_SPLIT_LABEL" in code or not "native_label" in code:
		return false
	var shader := Shader.new()
	_edge_aa = edge
	shader.code = "#define DISPLAY_SPLIT_LABEL\n" + ("#define DISPLAY_SPLIT_EDGE\n" if edge else "") + code
	if _split != null:
		_split.set_shader_parameter(&"native_label", null)
	_plain = plain
	_plain_shader = plain.shader
	_split = plain.duplicate() as ShaderMaterial
	_split.shader = shader
	return true


func _open_view(sun: DirectionalLight3D) -> void:
	_light = sun
	_light.layers |= NATIVE_LAYER
	_view = SubViewport.new()
	_view.name = "NativeLabelViewport"
	_view.world_3d = _body.find_world_3d()
	_view.transparent_bg = true
	# Tonemapping after an MSAA resolve distorts partially transparent label edges.
	_view.msaa_3d = Viewport.MSAA_DISABLED
	_view.gui_disable_input = true
	# Follow the actual body pass, even when the public UPDATE_ONCE property
	# still says ONCE after the renderer has consumed it.
	_view.render_target_update_mode = SubViewport.UPDATE_WHEN_PARENT_VISIBLE
	add_child(_view, false, Node.INTERNAL_MODE_BACK)
	RenderingServer.viewport_set_disable_2d(_view.get_viewport_rid(), true)
	if OS.get_environment("SOCKET_FPS_DIAGNOSTICS") == "1":
		RenderingServer.viewport_set_measure_render_time(_view.get_viewport_rid(), true)
	_camera = Camera3D.new()
	_camera.cull_mask = NATIVE_LAYER
	_view.add_child(_camera)
	_camera.make_current()
	_body.set_meta(VIEWPORT, _view)


func _copy_properties(source: Object, target: Object, properties: Array) -> void:
	for property: StringName in properties:
		var value: Variant = source.get(property)
		if target.get(property) != value:
			target.set(property, value)


func _sync_proxies(carts: Array[Dictionary], selected: Cartridge, keep_body_labels: bool) -> void:
	var used := {}
	for data in carts:
		if data.label_mesh != null:
			if data.cart == selected:
				_sync_mesh(data.label_mesh, data.label_surface, data.occluder_surfaces, used, _eraser, keep_body_labels)
			else:
				# Draw the whole neighbor in the body and mask even its sticker in the native pass.
				var mesh: MeshInstance3D = data.label_mesh
				_sync_mesh(mesh, -1, PackedInt32Array(range(mesh.mesh.get_surface_count())), used, _two_sided_eraser, false)
		var mask := _two_sided_eraser if data.label_mesh == null else _eraser
		for source: MeshInstance3D in data.body_meshes:
			_sync_mesh(source, -1, PackedInt32Array(range(source.mesh.get_surface_count())), used, mask, false)
	for id: int in _records.keys():
		if not used.has(id):
			_retire(id)
			_needs_body_refresh = true


func _sync_mesh(source: MeshInstance3D, cover: int, solids: PackedInt32Array, used: Dictionary, mask: ShaderMaterial, keep_body_label: bool) -> void:
	var id := source.get_instance_id()
	used[id] = true
	var record := _records.get(id, {}) as Dictionary
	if not record.is_empty() and (record.mesh != source.mesh or record.cover != cover):
		_retire(id)
		record = {}
	if record.is_empty():
		record = _make_proxies(source, cover, solids)
		_records[id] = record
		_needs_body_refresh = true
	for i in solids.size():
		_update_material(record.casing, i, source.get_active_material(solids[i]))
	if record.occluder and record.occluder.material_override != mask:
		record.occluder.material_override = mask
		_needs_body_refresh = true
	if cover >= 0:
		_update_material(record.label, 0, source.get_active_material(cover))
		# Glass must sample the complete scaled scene. Replace only exposed sticker pixels afterward.
		var layers: int = NATIVE_LAYER | (record.layers if keep_body_label else 0)
		if record.label.layers != layers:
			record.label.layers = layers
			_needs_body_refresh = true


func _make_proxies(source: MeshInstance3D, label_surface: int, occluder_surfaces: PackedInt32Array) -> Dictionary:
	var mesh := source.mesh as ArrayMesh
	var parts: Array
	if label_surface < 0:
		parts = [mesh, null]
	elif occluder_surfaces.is_empty():
		parts = [null, mesh]
	elif _geometry.has(mesh) and _geometry[mesh][2] == label_surface:
		parts = _geometry[mesh]
	else:
		# Reuse the packed vertex/index data, including LODs and compressed UVs.
		var packed: Array = mesh.get("_surfaces")
		var solid: Array = []
		for i in occluder_surfaces:
			solid.append(packed[i])
		var casing := ArrayMesh.new()
		casing.set("_surfaces", solid)
		var label := ArrayMesh.new()
		label.set("_surfaces", [packed[label_surface]])
		parts = [casing, label, label_surface]
		_geometry[mesh] = parts
	var layers := source.layers
	var shadows := source.cast_shadow
	var record := {
		"source": source, "mesh": mesh, "cover": label_surface, "layers": layers, "shadows": shadows,
		"casing": _proxy(source, parts[0], layers),
		"label": _proxy(source, parts[1], NATIVE_LAYER),
		"occluder": _proxy(source, parts[0], NATIVE_LAYER, _eraser),
	}
	# Keep the original mesh/materials authoritative and casting on both passes.
	# The color proxies do not cast (especially the transparent eraser).
	if shadows == GeometryInstance3D.SHADOW_CASTING_SETTING_ON:
		source.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		source.layers = layers | NATIVE_LAYER
	else:
		source.layers = 0
	record.split_layers = source.layers
	record.split_shadows = source.cast_shadow
	return record


func _proxy(source: MeshInstance3D, mesh: ArrayMesh, layers: int, material: Material = null) -> MeshInstance3D:
	if mesh == null:
		return null
	var proxy := MeshInstance3D.new()
	proxy.mesh = mesh
	proxy.layers = layers
	proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	proxy.material_override = material
	proxy.lod_bias = source.lod_bias
	source.add_child(proxy, false, Node.INTERNAL_MODE_BACK)
	proxy.force_update_transform()
	return proxy


func _update_material(proxy: MeshInstance3D, surface: int, material: Material) -> void:
	if proxy.get_surface_override_material(surface) != material:
		proxy.set_surface_override_material(surface, material)
		_needs_body_refresh = true


func _retire(id: int) -> void:
	var record := _records[id]
	_records.erase(id)
	var source: Variant = record.source
	if is_instance_valid(source):
		if source.layers == record.split_layers:
			source.layers = record.layers
		elif record.split_layers & NATIVE_LAYER:
			source.layers &= ~NATIVE_LAYER
		if source.cast_shadow == record.split_shadows:
			source.cast_shadow = record.shadows
	for proxy: Variant in [record.casing, record.label, record.occluder]:
		if is_instance_valid(proxy):
			proxy.hide()
			proxy.queue_free()


func _deactivate() -> void:
	if _view == null:
		return
	if is_instance_valid(_display) and _display.material == _split:
		_display.material = _plain
	_split.set_shader_parameter(&"native_label", null)
	for id: int in _records.keys():
		_retire(id)
	if is_instance_valid(_light):
		_light.layers &= ~NATIVE_LAYER
	_light = null
	_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_view.queue_free()
	_view = null
	_camera = null
	_body.remove_meta(VIEWPORT)
	_body.set_meta(ACTIVE, false)
	if _body.is_inside_tree() and OS.get_environment("SOCKET_3D_MSAA") == "auto":
		_body.call("_baseos_apply_msaa", bool(SettingsManager.get_setting("cartridge_msaa")))
	_needs_body_refresh = true


func _refresh_body() -> void:
	_needs_body_refresh = false
	var mode := _body.render_target_update_mode
	if mode == SubViewport.UPDATE_ALWAYS:
		return
	# Refresh both textures before compositing a changed split state, including
	# when the app has already consumed its pause/resize UPDATE_ONCE.
	var rid := _body.get_viewport_rid()
	if mode in [SubViewport.UPDATE_DISABLED, SubViewport.UPDATE_ONCE]:
		RenderingServer.viewport_set_update_mode(rid, RenderingServer.VIEWPORT_UPDATE_ONCE)
	else:
		_restore_mode = mode
		RenderingServer.viewport_set_update_mode(rid, RenderingServer.VIEWPORT_UPDATE_ALWAYS)
		if not RenderingServer.frame_post_draw.is_connected(_restore_body_update):
			RenderingServer.frame_post_draw.connect(_restore_body_update, CONNECT_ONE_SHOT)


func _restore_body_update() -> void:
	if is_instance_valid(_body) and _body.render_target_update_mode == _restore_mode:
		_body.render_target_update_mode = _restore_mode
	_restore_mode = -1


func _exit_tree() -> void:
	if RenderingServer.frame_pre_draw.is_connected(_before_draw):
		RenderingServer.frame_pre_draw.disconnect(_before_draw)
	_deactivate()
	_geometry.clear()
	if is_instance_valid(_body) and _body.is_inside_tree() and _needs_body_refresh:
		_refresh_body()
