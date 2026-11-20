# Run with run_split_label_render.py against the 0.10.1 pack. Score the label
# interior from the final window, not from either 3D render target.
extends SceneTree

const PANEL := Vector2i(720, 480)
const POSES := {"front": Vector3(-70, 0, 20), "tilt": Vector3(-62, 15, 12)}
const SCALES := {"native": 1.0, "single-075": 0.75, "single-060": 0.6}
const ACTIVE := "socket_split_label_active"
# 5x7 bitmap type, so no host fonts or rasterizer choices enter the fixture.
const GLYPHS := [[31, 16, 16, 31, 1, 1, 31], [14, 17, 17, 17, 17, 17, 14],
	[15, 16, 16, 16, 16, 16, 15], [17, 18, 20, 24, 20, 18, 17],
	[31, 16, 16, 30, 16, 16, 31], [31, 4, 4, 4, 4, 4, 4]] # SOCKET
var out: String
var view: SubViewport
var settings: Node

func _initialize() -> void:
	_run.call_deferred()

func require(ok: bool, message: String) -> bool:
	if not ok:
		printerr("FAIL: ", message)
		quit(1)
	return ok

func make_art() -> Image:
	var art := Image.create(512, 512, false, Image.FORMAT_RGBA8)
	var ink := Color("173154")
	art.fill(Color("f0ddac"))
	for y in range(512):
		for x in range(512):
			var period := 8 if x < 256 else 16
			if (x + y * 2) % period < period / 2:
				art.set_pixel(x, y, ink)
	for y in range(32, 480, 80):
		art.fill_rect(Rect2i(0, y, 512, 42), Color("f0ddac"))
		for x in range(16, 448, 144):
			for letter in range(GLYPHS.size()):
				for row in range(7):
					for bit in range(5):
						if GLYPHS[letter][row] & (1 << (4 - bit)):
							art.fill_rect(Rect2i(x + letter * 18 + bit * 3, y + 10 + row * 3, 3, 3), ink)
	return art

func capture(filename: String, scale: float, active: Variant, save_body := false) -> Image:
	settings.set_setting("render_scale_3d", scale)
	for i in range(6): await process_frame
	await RenderingServer.frame_post_draw
	var effective := Vector2(view.size) * view.scaling_3d_scale
	var actual: bool = view.get_meta(ACTIVE, false) == true
	print(filename, " body_pixels=", effective, " body_msaa=", view.msaa_3d, " ", ACTIVE, "=", actual)
	match OS.get_environment("SOCKET_3D_MSAA"):
		"0":
			if not require(view.msaa_3d == Viewport.MSAA_DISABLED, filename + ": casing smoothing disabled"): return null
		"2":
			if not require(view.msaa_3d == Viewport.MSAA_2X, filename + ": casing smoothing enabled"): return null
	if active != null and not require(actual == active, "%s: expected %s=%s" % [filename, ACTIVE, active]): return null
	if not require(effective.distance_to(Vector2(PANEL) * scale) <= 1.5, filename + ": expected physical scale"): return null
	if save_body:
		var body := view.get_texture().get_image()
		if not require(body != null and body.get_size() == Vector2i(Vector2(PANEL) * scale), filename + ": body texture really is low-res"): return null
		body.convert(Image.FORMAT_RGBA8)
		if not require(body.save_png(out.path_join(filename + "-body.png")) == OK, filename + ": save body PNG"): return null
	var image := root.get_texture().get_image()
	if not require(image != null and image.get_size() == PANEL, filename + ": final display is 720x480"): return null
	image.convert(Image.FORMAT_RGBA8)
	if not require(image.save_png(out.path_join(filename + ".png")) == OK, filename + ": save display PNG"): return null
	return image

func load_frame(filename: String, size := PANEL) -> Image:
	var image := Image.load_from_file(out.path_join(filename + ".png"))
	if not require(image != null and image.get_size() == size, filename + ": corresponding PNG exists at the expected size"): return null
	image.convert(Image.FORMAT_RGBA8)
	return image

func is_marker(data: PackedByteArray, i: int) -> bool:
	return data[i] >= 220 and data[i + 1] <= 40 and data[i + 2] >= 220

func label_pixels(mask: Image) -> PackedInt32Array:
	var data := mask.get_data()
	var stride := PANEL.x * 4
	var pixels := PackedInt32Array()
	# Keep marker pixels at least two pixels inside the visible label edge.
	for y in range(2, PANEL.y - 2):
		for x in range(2, PANEL.x - 2):
			var i := y * stride + x * 4
			if is_marker(data, i) and is_marker(data, i - 8) and is_marker(data, i + 8) and is_marker(data, i - 2 * stride) and is_marker(data, i + 2 * stride):
				pixels.append(i)
	return pixels

func rgb_mae(frame: Image, reference: Image, pixels: PackedInt32Array) -> float:
	var a := frame.get_data()
	var b := reference.get_data()
	var error := 0
	for i in pixels:
		error += absi(a[i] - b[i]) + absi(a[i + 1] - b[i + 1]) + absi(a[i + 2] - b[i + 2])
	return float(error) / (3 * pixels.size())

func split_uses_material(cart, material: ShaderMaterial) -> bool:
	# Check the first draw after the swap, before any settling or scale changes.
	await RenderingServer.frame_post_draw
	if not require(view.get_meta(ACTIVE, false) == true, "split stays active on the style swap"): return false
	var native := view.get_meta("socket_split_label_viewport") as SubViewport
	if not require(native != null and native.size.x < PANEL.x and native.get_camera_3d() != null, "style swap keeps a native label pass"): return false
	for child in cart.cover_mesh.get_children(true):
		if child is MeshInstance3D and child.is_visible_in_tree() and child.layers & native.get_camera_3d().cull_mask and child.get_active_material(0) == material:
			return true
	return require(false, "native label draws the live cover material instance")

func compare_style_swap(cart, paper: ShaderMaterial, regions: Dictionary, split: bool) -> bool:
	var holo_index := 0
	for i in range(cart.enabled_label_styles.size()):
		if cart.enabled_label_styles[i].material.shader.resource_path == "res://scenes/paper_sticker_foil_holo.gdshader":
			holo_index = i + 1
			break
	if not require(holo_index > 0, "the shipped holo foil is a GBA customization style"): return false
	var texture: Texture2D = paper.get_shader_parameter("artwork_texture")
	var crop := Vector2(0.13, -0.09)
	var zoom := 1.35
	cart.rotation_degrees = POSES.front
	cart.set_cover_offsets(crop, zoom)
	cart.update_label_style(holo_index)
	var foil: ShaderMaterial = cart.get_cover_material()
	if not require(foil != paper and foil.shader.resource_path.ends_with("paper_sticker_foil_holo.gdshader") and foil.get_shader_parameter("enable_foil"), "the live swap installs real holo foil"): return false
	if not require(foil.get_shader_parameter("artwork_texture") == texture and foil.get_shader_parameter("artwork_offset") == crop and is_equal_approx(foil.get_shader_parameter("artwork_zoom"), zoom), "holo keeps the same artwork, crop and zoom"): return false
	# Remove only wall-clock sway, keeping the shipped view-angle response.
	foil.set_shader_parameter("foil_sway", 0.0)
	if split and not await split_uses_material(cart, foil): return false
	for pose in POSES:
		cart.rotation_degrees = POSES[pose]
		var name: String = pose + "-holo"
		var frame := await capture(name + ("-split-060" if split else "-native"), 0.6 if split else 1.0, split)
		if frame == null: return false
		var reference := load_frame(name + "-native") if split else frame
		if reference == null: return false
		var error := rgb_mae(frame, reference, regions[pose])
		if split:
			print(name, " RGB MAE vs native (8-bit): ", error)
			if not require(error <= 2.0, name + ": cropped holo stays near native"): return false
		if pose == "tilt":
			# Same pose and lighting, but with no view-angle input to the foil.
			var neutral: Image
			if split:
				neutral = load_frame(name + "-no-tilt-response")
			else:
				var response = foil.get_shader_parameter("foil_tilt_response")
				foil.set_shader_parameter("foil_tilt_response", 0.0)
				neutral = await capture(name + "-no-tilt-response", 1.0, false)
				foil.set_shader_parameter("foil_tilt_response", response)
			if neutral == null: return false
			var signal_error := rgb_mae(reference, neutral, regions[pose])
			print(name, " RGB MAE from removing angle response (8-bit): ", signal_error)
			if not require(signal_error > 2.0 and error < signal_error / 2.0, "tilted foil preserves the native angle response"): return false
	cart.rotation_degrees = POSES.front
	cart.update_label_style(0)
	cart.set_cover_offsets(Vector2.ZERO, 1.0)
	var restored: ShaderMaterial = cart.get_cover_material()
	if not require(restored.shader == paper.shader and restored.get_shader_parameter("artwork_texture") == texture, "the live swap back restores paper and artwork"): return false
	if split and not await split_uses_material(cart, restored): return false
	var returned := await capture("front-paper-return-" + ("split-060" if split else "native"), 0.6 if split else 1.0, split)
	var original := load_frame("front-native")
	if returned == null or original == null: return false
	var error := rgb_mae(returned, original, regions.front)
	print("paper return RGB MAE vs native (8-bit): ", error)
	return require(error <= 2.0, "restored paper stays near the native reference")

func stock_pixels(mask: Image) -> PackedInt32Array:
	var pixels := PackedInt32Array()
	var allowed := PackedByteArray()
	allowed.resize(PANEL.x * PANEL.y)
	if mask != null:
		var data := mask.get_data()
		# Allow a 3px edge band for single-sample labels over an upscaled body.
		for y in range(3, PANEL.y - 3):
			for x in range(3, PANEL.x - 3):
				if not is_marker(data, (y * PANEL.x + x) * 4): continue
				for dy in range(-3, 4):
					for dx in range(-3, 4):
						allowed[(y + dy) * PANEL.x + x + dx] = 1
	# The launcher clock changes between processes; the 3D fixture is below the header.
	for i in range(48 * PANEL.x, allowed.size()):
		if allowed[i] == 0: pixels.append(i * 4)
	return pixels

func changed_rgb(frame: Image, reference: Image, pixels: PackedInt32Array) -> int:
	var a := frame.get_data()
	var b := reference.get_data()
	var changed := 0
	for i in pixels:
		if a[i] != b[i] or a[i + 1] != b[i + 1] or a[i + 2] != b[i + 2]:
			changed += 1
	return changed

func glass_mask(name: String, cart, marker: ShaderMaterial, split: bool, foreground = null) -> Image:
	if split: return load_frame(name + "-mask")
	var original: ShaderMaterial = cart.get_cover_material()
	cart.set_cover_material(marker)
	# Use opaque green shells only in the geometry oracle: real glass can
	# refract the marker into areas that must not receive the native overlay.
	var green := StandardMaterial3D.new()
	green.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	green.albedo_color = Color.GREEN
	var meshes: Array = cart.casing_meshs.duplicate()
	if foreground != null: meshes.append_array(foreground.casing_meshs)
	var shell_materials := []
	for mesh in meshes:
		shell_materials.append(mesh.get_surface_override_material(0))
		mesh.set_surface_override_material(0, green)
	var mask := await capture(name + "-mask", 1.0, false)
	cart.set_cover_material(original)
	for i in meshes.size():
		meshes[i].set_surface_override_material(0, shell_materials[i])
	return mask

func check_glass_pose(name: String, cart, split: bool, mask: Image, refracted := PackedInt32Array()) -> bool:
	var exposed := label_pixels(mask) if mask != null else PackedInt32Array()
	var protected := stock_pixels(mask) if split else PackedInt32Array()
	var native: Image
	if mask != null:
		if not require(exposed.size() > 1000, name + ": usable exposed label interior"): return false
		native = load_frame(name + "-native") if split else await capture(name + "-native", 1.0, false)
		if native == null: return false
	for scale: float in [0.5, 0.6]:
		var suffix := "-%03d" % roundi(scale * 100)
		var stock_name := name + "-single" + suffix
		if not split:
			var stock := await capture(stock_name, scale, false, true)
			if stock == null: return false
			if native != null:
				var error := rgb_mae(stock, native, exposed)
				print(stock_name, " exposed_pixels=", exposed.size(), " RGB MAE vs native: ", error)
				if not require(error > 2.0, stock_name + ": low-res control loses label detail"): return false
			if not refracted.is_empty():
				var cover: ShaderMaterial = cart.get_cover_material()
				var original: Texture2D = cover.get_shader_parameter("artwork_texture")
				var art := Image.create(32, 32, false, Image.FORMAT_RGBA8)
				art.fill(Color.BLACK)
				cover.set_shader_parameter("artwork_texture", ImageTexture.create_from_image(art))
				var dark := await capture(stock_name + "-black", scale, false)
				art.fill(Color.WHITE)
				cover.set_shader_parameter("artwork_texture", ImageTexture.create_from_image(art))
				var recolored := await capture(stock_name + "-white", scale, false)
				cover.set_shader_parameter("artwork_texture", original)
				if dark == null or recolored == null: return false
				var signal_error := rgb_mae(recolored, dark, refracted)
				print(stock_name, " refracted_pixels=", refracted.size(), " RGB MAE after rear art recolor: ", signal_error)
				# The tinted finish attenuates this signal even across a large overlap.
				if not require(signal_error > 1.0, stock_name + ": foreground glass actually samples the rear label"): return false
			continue
		var split_name := name + "-split" + suffix
		# A rear-only pose need not have an active pass if it has no exposed pixels.
		var frame := await capture(split_name, scale, true if mask != null else null, true)
		var stock := load_frame(stock_name)
		if frame == null or stock == null: return false
		if native != null:
			var label := view.get_meta("socket_split_label_viewport", null) as SubViewport
			var rect: Vector4 = view.get("_display").material.get_shader_parameter("label_rect")
			if not require(label != null and label.size == Vector2i((Vector2(rect.z, rect.w) * Vector2(PANEL)).round()), split_name + ": one label texel per panel pixel"): return false
		var body_size := Vector2i(Vector2(PANEL) * scale)
		var body := load_frame(split_name + "-body", body_size)
		var stock_body := load_frame(stock_name + "-body", body_size)
		if body == null or stock_body == null: return false
		var same_body := body.get_data() == stock_body.get_data()
		var exterior_delta := changed_rgb(frame, stock, protected)
		var refraction_delta := changed_rgb(frame, stock, refracted)
		print(split_name, " body_identical=", same_body, " changed_protected=", exterior_delta, "/", protected.size(),
			" changed_refracted=", refraction_delta, "/", refracted.size())
		if not require(same_body, split_name + ": complete low-res body RGBA is byte-identical to stock"): return false
		if not require(exterior_delta == 0 and refraction_delta == 0, split_name + ": protected display RGB is byte-identical to stock"): return false
		if native != null:
			var error := rgb_mae(frame, native, exposed)
			var low_error := rgb_mae(stock, native, exposed)
			print(split_name, " exposed_pixels=", exposed.size(), " RGB MAE vs native: split=", error, " low=", low_error)
			if not require(error <= 2.0 and error < low_error, split_name + ": exposed label stays near native"): return false
	return true

func compare_glass(cart, carousel, marker: ShaderMaterial, split: bool) -> bool:
	var foreground = load(cart.scene_file_path).instantiate()
	foreground.set_game(cart.game)
	# Recoloring the rear label must not edit the foreground cartridge's art.
	foreground.set_cover_material(foreground.get_cover_material().duplicate())
	carousel.add_child(foreground)
	var finishes := {2: "translucent", 3: "clear"}
	for index in finishes:
		var finish: String = finishes[index]
		if not require(cart.resolve_finish_id(index) == finish, "select the real " + finish + " finish"): return false
		cart.update_material(index)
		foreground.refresh_casing()
		foreground.hide()
		cart.rotation_degrees = POSES.front
		var front := "glass-" + finish + "-front"
		var front_mask := await glass_mask(front, cart, marker, split)
		if front_mask == null or not await check_glass_pose(front, cart, split, front_mask): return false
		cart.rotate_object_local(Vector3.RIGHT, PI)
		foreground.transform = cart.transform
		if not await check_glass_pose("glass-" + finish + "-rear", cart, split, null): return false
		cart.rotation_degrees = POSES.front
		var camera := view.get_camera_3d().global_transform.basis
		foreground.global_position += camera.x * 0.9 + camera.z * 0.8
		foreground.show()
		var overlap := "glass-" + finish + "-overlap"
		var overlap_mask := await glass_mask(overlap, cart, marker, split, foreground)
		if overlap_mask == null: return false
		var geometry := overlap_mask.get_data()
		var refracted := PackedInt32Array()
		for i in label_pixels(front_mask):
			# Only use overlap well inside the foreground shell and rear label.
			var green := true
			for at in [i, i - 16, i + 16, i - PANEL.x * 16, i + PANEL.x * 16]:
				if geometry[at] > 40 or geometry[at + 1] < 220 or geometry[at + 2] > 40:
					green = false
					break
			if green: refracted.append(i)
		if not require(refracted.size() > 1000, overlap + ": casing occludes a usable label interior"): return false
		if not await check_glass_pose(overlap, cart, split, overlap_mask, refracted): return false
	foreground.queue_free()
	return true

func _run() -> void:
	OS.low_processor_usage_mode = false
	root.size = PANEL
	out = OS.get_environment("SOCKET_EVIDENCE")
	var split := OS.get_environment("SOCKET_3D_SPLIT_LABEL") == "1"
	if not require(ProjectSettings.get_setting("application/config/version") == "0.10.1", "requires a 0.10.1 pack"): return
	if not require(DirAccess.dir_exists_absolute(out), "requires an evidence directory"): return
	var manager = root.get_node("Manager")
	settings = root.get_node("SettingsManager")
	settings.set_setting("new_game_reveal_enabled", false)
	settings.set_setting("carousel_duplicate_fill_enabled", false)
	load("res://scripts/models/emulator_database.gd").store("gba", [{"uniqueId": "gba.ra64.mgba", "name": "mGBA", "acceptedFilenameRegex": "[.]gba$", "amStartArguments": "-n com.retroarch/.Main -e LIBRETRO mgba"}])
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	var screen = load("res://scripts/screens/screen.gd")
	var home
	for i in range(3000):
		home = screen.get_screen("main")
		if home != null and home.is_node_ready() and root.get_meta("socket_shader_startup_complete", false): break
		await process_frame
	if not require(home != null and home.is_node_ready() and root.get_meta("socket_shader_startup_complete", false), "startup completes"): return
	var fixture := "user://scraped_data/gba"
	DirAccess.make_dir_recursive_absolute(fixture)
	if not require(make_art().save_png(fixture.path_join("One_support.png")) == OK, "write fixture art"): return
	var info := FileAccess.open(fixture.path_join("One.json"), FileAccess.WRITE)
	if not require(info != null, "write fixture metadata"): return
	info.store_string(JSON.stringify({"matched": true, "method": "md5", "game_id": 1, "name": "One", "platform": "nintendo-game-boy-advance", "region": "World", "texture_url": "", "labels": [], "meta": {}}))
	info.close()
	var platform = load("res://scripts/platform.gd").new()
	platform.model = manager.db.get_platform("gba").new()
	platform.app_id = "gba.ra64.mgba"
	platform.rom_folder_path = OS.get_environment("SOCKET_TEST_ROOT")
	manager.add_platform_to_user(manager.current_user, platform)
	await manager.scan_platform_in_user(manager.current_user, platform)
	home.selected_platform_index = home._get_visible_platforms().find(platform)
	if not require(home.selected_platform_index >= 0, "display the fixture platform"): return
	home.render_carousel()
	var carousel = home.carousel_3d
	for i in range(60): await process_frame
	if not require(carousel.active_cartridges.size() == 1 and carousel.selected_game != null, "display one selected GBA cartridge"): return
	carousel.set_process(false)
	var cart = carousel.selected_game
	# Snap out of the idle float; the startup tween is settled before either pose.
	cart.position.y = cart.get_meta("base_y")
	cart.update_material(1)
	cart.update_color(0)
	if not require(cart.resolve_finish_id(1) == "opaque", "start with the supported opaque finish"): return
	var cover: ShaderMaterial = cart.get_cover_material()
	if not require(cover != null and cover.get_shader_parameter("artwork_texture") is Texture2D, "fixture art reaches the real cover material"): return
	view = home.viewport_3d
	var marker := ShaderMaterial.new()
	marker.shader = Shader.new()
	marker.shader.code = "shader_type spatial; render_mode unshaded; void fragment() { ALBEDO = vec3(1.0, 0.0, 1.0); }"
	var regions := {}
	var origin: Vector3 = cart.global_position
	var poses := POSES.merged({"slide": POSES.tilt})
	for pose in poses:
		cart.global_position = origin + view.get_camera_3d().global_basis.x * (1.5 if pose == "slide" else 0.0)
		cart.rotation_degrees = poses[pose]
		var mask: Image
		var reference: Image
		var reduced := {}
		if split:
			mask = load_frame(pose + "-mask")
			reference = load_frame(pose + "-native")
			for variant in ["single-075", "single-060"]:
				reduced[variant] = load_frame(pose + "-" + variant)
		else:
			for variant in SCALES:
				var frame := await capture(pose + "-" + variant, SCALES[variant], false)
				if frame == null: return
				if variant == "native": reference = frame
				else: reduced[variant] = frame
			cart.set_cover_material(marker)
			mask = await capture(pose + "-mask", 1.0, false)
			cart.set_cover_material(cover)
		if mask == null or reference == null or reduced["single-060"] == null or reduced["single-075"] == null: return
		var pixels := label_pixels(mask)
		if not require(pixels.size() >= 1000, pose + ": marker covers a usable label interior"): return
		regions[pose] = pixels
		var e075 := rgb_mae(reduced["single-075"], reference, pixels)
		var e060 := rgb_mae(reduced["single-060"], reference, pixels)
		print(pose, " interior_pixels=", pixels.size(), " RGB MAE vs native (8-bit): single-075=", e075, " single-060=", e060)
		if not require(minf(e075, e060) > 1.0, pose + ": reduced controls lose measurable label detail"): return
		if split:
			for body_scale: float in [0.5, 0.6, 0.66]:
				var name := "%s-split-%03d" % [pose, roundi(body_scale * 100)]
				var frame := await capture(name, body_scale, true)
				if frame == null: return
				var error := rgb_mae(frame, reference, pixels)
				print(name, " RGB MAE vs native (8-bit): ", error)
				if not require(error < minf(e075, e060) and error <= 2.0, name + ": split label stays near the native reference"): return
	cart.global_position = origin
	if not await compare_style_swap(cart, cover, regions, split): return
	if not await compare_glass(cart, carousel, marker, split): return
	print("PASS: split label " + ("candidate" if split else "controls"))
	quit()
