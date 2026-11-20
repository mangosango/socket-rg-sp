# Run with a 0.10.1 pack and its compatible Godot template. This also works
# against a pack without the overlay installed when invoked by absolute path.
extends SceneTree

const HELPER := "res://addons/FrontendPlugin/split_label_surfaces.gd"
const GBA := "res://scenes/selectables/cart_gba.tscn"
const GB := "res://scenes/selectables/cart_gb.tscn"

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var path := HELPER
	if not ResourceLoader.exists(path):
		path = get_script().resource_path.get_base_dir().path_join("../../overlay/addons/FrontendPlugin/split_label_surfaces.gd").simplify_path()
	var surfaces = load(path)
	if not require(surfaces != null, "load split-label helper"): return
	var carousel := Node3D.new()
	root.add_child(carousel)
	if not require(surfaces.discover(carousel).is_empty(), "empty carousel falls back"): return

	var image := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	var art_path := "user://split-label-surfaces-fixture.png"
	if not require(image.save_png(art_path) == OK, "write local artwork fixture"): return
	var left = spawn_gba(carousel, art_path)
	var right = spawn_gba(carousel, art_path)
	var mesh: MeshInstance3D = right.cover_mesh
	var found: Dictionary = surfaces.discover(carousel)
	if not require(not found.is_empty() and found.carts.size() == 2, "admit two packed opaque carts"): return
	if not require(found.carts[0].label_mesh == left.cover_mesh
			and found.carts[0].occluder_surfaces == PackedInt32Array([0, 2]), "include occluders from both carts"): return
	var label: Dictionary = found.carts[1]
	if not require(label.cart == right and label.label_mesh == mesh and label.label_surface == 1
			and label.label_material == right.get_cover_material() and mesh.get_active_material(1) == label.label_material
			and label.occluder_surfaces == PackedInt32Array([0, 2]), "return the setter's actual surface/material, and both occluding surfaces"): return

	# The controller can suppress the original color draw and own internal
	# child proxies; neither breaks source discovery.
	mesh.layers = 0
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	var proxy := MeshInstance3D.new()
	mesh.add_child(proxy, false, Node.INTERNAL_MODE_BACK)
	if not require(right.enabled_label_styles.size() == 5, "packed GBA has five foil styles"): return
	for index in range(1, right.enabled_label_styles.size() + 1):
		right.update_label_style(index)
		found = surfaces.discover(carousel)
		if not require(not found.is_empty() and found.carts[1].label_material == right.get_cover_material()
				and found.carts[1].label_material != label.label_material and mesh.layers == 0
				and mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
				and proxy.get_parent() == mesh, "foil replacement re-discovered without mutating the source or proxies"): return

	right.update_material(1)
	if not require(not surfaces.discover(carousel).is_empty(), "accept explicit packed opaque finish"): return
	for index in [2, 3, 4, 5]:
		right.update_material(index)
		found = surfaces.discover(carousel)
		if not require(not found.is_empty() and found.carts[1].label_mesh == mesh
			and found.keep_body_labels == (right.resolve_finish_id(index) in ["translucent", "clear"]), "only refractive finishes need the complete body pass: %d" % index): return
	right.update_material(0)

	var unknown := StandardMaterial3D.new()
	mesh.set_surface_override_material(2, unknown)
	found = surfaces.discover(carousel)
	if not require(not found.is_empty() and found.carts[1].label_mesh == null and found.keep_body_labels, "static unverified surface keeps only its own cart scaled"): return
	unknown.no_depth_test = true
	if not require(surfaces.discover(carousel).is_empty(), "an unbounded depth override cannot be used as a blocker"): return
	mesh.set_surface_override_material(2, null)
	var foil: ShaderMaterial = right.get_cover_material()
	var art: Texture2D = foil.get_shader_parameter("artwork_texture")
	var blended := ShaderMaterial.new()
	blended.shader = Shader.new()
	blended.shader.code = "shader_type spatial; uniform sampler2D artwork_texture; void fragment() { ALPHA = texture(artwork_texture, UV).a; }"
	blended.set_shader_parameter("artwork_texture", art)
	right.set_cover_material(blended)
	if not require(surfaces.discover(carousel).is_empty(), "reject unverified label shader even with artwork at the setter's surface"): return
	right.set_cover_material(foil)
	foil.set_shader_parameter("artwork_texture", null)
	found = surfaces.discover(carousel)
	if not require(not found.is_empty() and found.carts[1].label_mesh == null and found.carts[0].label_mesh != null, "missing artwork does not demote a neighbouring cover"): return
	foil.set_shader_parameter("artwork_texture", art)
	var extra := MeshInstance3D.new()
	extra.mesh = BoxMesh.new()
	right.add_child(extra)
	extra.owner = right
	if not require(surfaces.discover(carousel).is_empty(), "unknown geometry falls back"): return
	extra.free()
	right.hide()
	if not require(surfaces.discover(carousel).carts.size() == 1, "hidden carts excluded"): return

	var gb := (load(GB) as PackedScene).instantiate() as Node3D
	carousel.add_child(gb)
	found = surfaces.discover(carousel)
	if not require(found.carts.size() == 2 and found.carts[1].label_mesh == null, "uninitialized GB cart is a scaled blocker"): return
	gb.queue_free()
	if not require(surfaces.discover(carousel).carts.size() == 2, "queued visible departures still block this frame"): return
	await process_frame
	if not require(not surfaces.discover(carousel).keep_body_labels, "pure split resumes after the blocker leaves"): return
	carousel.free()
	DirAccess.remove_absolute(art_path)
	print("PASS: packed 0.10.1 per-cartridge label discovery and safe fallbacks")
	quit()


func spawn_gba(carousel: Node3D, art_path: String) -> Node3D:
	var cart = (load(GBA) as PackedScene).instantiate()
	var game = load("res://scripts/game.gd").new()
	game.platform_id = "gba"
	game.rom_name = "Surface fixture"
	game.support_texture_path = art_path
	game.force_reload_texture()
	cart.set_game(game)
	carousel.add_child(cart)
	return cart


func require(condition: bool, message: String) -> bool:
	if not condition:
		printerr("FAIL: ", message)
		quit(1)
	return condition
