extends RefCounted
## Read-only discovery for the packed 0.10.1 carousel. Unknown geometry fails closed.

const SOLID_CASINGS := [
	preload("res://scenes/selectables/cartridge_casing.gdshader"),
	preload("res://materials/casing_metallic.gdshader"),
	preload("res://materials/casing_glitter.gdshader"),
]
const GLASS := preload("res://materials/frosted_glass.gdshader")
const DISC := preload("res://scenes/selectables/disc.gdshader")
const LABEL_SHADERS := [
	preload("res://scenes/paper_sticker.gdshader"),
	preload("res://scenes/paper_sticker_foil_radiant.gdshader"),
	preload("res://scenes/paper_sticker_foil_cosmos.gdshader"),
	preload("res://scenes/paper_sticker_foil_gold.gdshader"),
	preload("res://scenes/paper_sticker_foil_holo.gdshader"),
	preload("res://scenes/paper_sticker_foil_rainbow.gdshader"),
]

static func discover(carousel: Node3D) -> Dictionary:
	if ProjectSettings.get_setting("application/config/version", "") != "0.10.1" or not is_instance_valid(carousel) or not carousel.is_visible_in_tree():
		return {}
	var carts: Array[Dictionary] = []
	var any_label := false
	var keep_body_labels := false
	for child in carousel.get_children():
		if not child is Node3D:
			if child.get_child_count() != 0:
				return {}
			continue
		if not child.is_visible_in_tree():
			continue
		if not child is Cartridge:
			return {}
		var entry := _discover_cart(child)
		if entry.is_empty():
			return {}
		carts.append(entry)
		any_label = any_label or entry.label_mesh != null
		keep_body_labels = keep_body_labels or entry.keep_body_labels
	return {"carts": carts, "keep_body_labels": keep_body_labels} if any_label else {}


static func _discover_cart(cart: Cartridge) -> Dictionary:
	var label := cart.get_cover_material()
	var scaled_only := label == null or label.shader not in LABEL_SHADERS or not label.get_shader_parameter("artwork_texture") is Texture2D
	var entry := {}
	var meshes: Array[MeshInstance3D] = []
	var glass := false
	# Only scene-owned visuals: never rediscover the controller's runtime proxies.
	for visual in cart.find_children("*", "VisualInstance3D", true, true):
		if not visual.is_visible_in_tree():
			continue
		var source := visual as MeshInstance3D
		if not source or source.material_override or source.material_overlay or source.transparency != 0.0 or source.skin:
			return {}
		if source.visibility_range_begin != 0.0 or source.visibility_range_end != 0.0:
			return {}
		var mesh := source.mesh as ArrayMesh
		if not mesh or mesh.get_blend_shape_count() != 0:
			return {}
		meshes.append(source)
		var cover := -1
		var casing := PackedInt32Array()
		for i in mesh.get_surface_count():
			if mesh.surface_get_primitive_type(i) != Mesh.PRIMITIVE_TRIANGLES:
				return {}
			var material := source.get_active_material(i)
			if not material or material.next_pass:
				return {}
			var shader := (material as ShaderMaterial).shader if material is ShaderMaterial else null
			if material == label and shader in LABEL_SHADERS and cover < 0:
				cover = i
			elif shader in SOLID_CASINGS or shader == GLASS:
				casing.append(i)
				glass = glass or shader == GLASS
			elif shader in LABEL_SHADERS or shader == DISC or _static_standard(material):
				# Secondary stickers, disc surfaces, etc. stay stock, but don't veto their neighbours.
				scaled_only = true
			else:
				return {}
		if cover >= 0:
			scaled_only = scaled_only or not entry.is_empty()
			entry = {"label_mesh": source, "label_surface": cover, "label_material": label, "occluder_surfaces": casing}
	if scaled_only or entry.is_empty():
		return {"cart": cart, "label_mesh": null, "body_meshes": meshes, "keep_body_labels": true}
	meshes.erase(entry.label_mesh)
	entry.merge({"cart": cart, "body_meshes": meshes, "keep_body_labels": glass})
	return entry


# A two-sided triangle mask can conservatively cover these stock materials.
# Deformed vertices or an overridden depth test could show a label through them.
static func _static_standard(material: Material) -> bool:
	var standard := material as StandardMaterial3D
	return (standard != null and standard.billboard_mode == BaseMaterial3D.BILLBOARD_DISABLED
		and not standard.grow and not standard.fixed_size and not standard.use_particle_trails
		and not standard.use_z_clip_scale and not standard.no_depth_test and standard.depth_test == BaseMaterial3D.DEPTH_TEST_DEFAULT)
