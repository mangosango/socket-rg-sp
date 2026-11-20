# python3 tests/app/run_render.py <0.10.1.pck> tests/app/test_split_label_transitions.gd <evidence-dir>
extends SceneTree

const PANEL := Vector2i(720, 480)
const REDUCED := Vector2i(432, 288)
const ACTIVE := "socket_split_label_active"
const LABEL_VIEW := "socket_split_label_viewport"
var body: SubViewport
var label: SubViewport
var display: TextureRect

func _initialize() -> void:
	_run.call_deferred()

func require(ok: bool, message: String) -> bool:
	if not ok:
		printerr("FAIL: ", message)
		quit(1)
	return ok

# Inspect the first drawn frame after each mutation, not the eventual steady state.
func check_frame(stage: String, expected_size: Vector2i, split: bool) -> bool:
	await RenderingServer.frame_post_draw
	var active: Variant = body.get_meta(ACTIVE, "missing")
	var native_texture: Variant = display.material.get_shader_parameter("native_label")
	print(stage, ": body=", body.size, " split=", active, " native bound=", native_texture != null)
	if not require(active is bool and active == split, stage + ": expected split state"): return false
	if not require(Vector2(expected_size).distance_to(Vector2(body.size) * body.scaling_3d_scale) <= 1.0, stage + ": body uses expected physical pixels"): return false
	if split:
		var native: Variant = body.get_meta(LABEL_VIEW, false)
		if not require(native is SubViewport, stage + ": native label viewport exists"): return false
		label = native
		var rect: Vector4 = display.material.get_shader_parameter("label_rect")
		return require(label.size == Vector2i((Vector2(rect.z, rect.w) * Vector2(PANEL)).round()) and is_equal_approx(label.scaling_3d_scale, 1.0)
			and native_texture == label.get_texture(), stage + ": display samples the native label viewport")
	if not require(native_texture == null and (not is_instance_valid(label) or not label.is_inside_tree()
		or label.render_target_update_mode == SubViewport.UPDATE_DISABLED), stage + ": native texture is detached and no longer rendered"): return false
	var first := pixels(body)
	await RenderingServer.frame_post_draw
	return require(pixels(body) == first, stage + ": single-pass image is complete on the first frame")

func pixels(view: SubViewport) -> PackedByteArray:
	return view.get_texture().get_image().get_data()

# With only opaque casings in the body pass, fractional alpha measures silhouette coverage.
func partial_edge_pixels(view: SubViewport) -> int:
	var image := view.get_texture().get_image()
	image.convert(Image.FORMAT_RGBA8)
	var rgba := image.get_data()
	var count := 0
	for i in range(3, rgba.size(), 4):
		if rgba[i] > 0 and rgba[i] < 255: count += 1
	return count

# A color-only edit to a real cover distinguishes the drawing passes without
# relying on the controller's choice of mesh copies or camera layers.
func check_artwork_route(cart, native: bool, body_copy := false) -> bool:
	var body_before := pixels(body)
	var label_before := pixels(label) if body.get_meta(ACTIVE, false) else PackedByteArray()
	var cover: ShaderMaterial = cart.get_cover_material()
	var saved: Texture2D = cover.get_shader_parameter("artwork_texture")
	var ink := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	ink.fill(Color(0.2, 1.0, 0.1))
	cover.set_shader_parameter("artwork_texture", ImageTexture.create_from_image(ink))
	await RenderingServer.frame_post_draw
	var body_changed := pixels(body) != body_before
	var label_changed := not label_before.is_empty() and pixels(label) != label_before
	cover.set_shader_parameter("artwork_texture", saved)
	await RenderingServer.frame_post_draw
	return require(body_changed == (not native or body_copy) and label_changed == native, "%s artwork routing: body=%s native=%s" % [cart.game.rom_path.get_file(), body_changed, label_changed])

# Compare visible label pixels in the final display, not just viewport metadata.
func check_panel_detail(settings: Node, name: String) -> bool:
	var rect: Vector4 = display.material.get_shader_parameter("label_rect")
	var mask_image := Image.create_empty(PANEL.x, PANEL.y, false, Image.FORMAT_RGBA8)
	var crop := label.get_texture().get_image()
	crop.convert(Image.FORMAT_RGBA8)
	mask_image.blit_rect(crop, Rect2i(Vector2i.ZERO, crop.get_size()), Vector2i((Vector2(rect.x, rect.y) * Vector2(PANEL)).round()))
	var mask := mask_image.get_data()
	var split := root.get_texture().get_image().get_data()
	settings.set_setting("high_res_labels", false)
	await RenderingServer.frame_post_draw
	var low := root.get_texture().get_image().get_data()
	settings.set_setting("render_scale_3d", 1.0)
	await RenderingServer.frame_post_draw
	var native := root.get_texture().get_image().get_data()
	settings.set_setting("render_scale_3d", 0.5)
	settings.set_setting("high_res_labels", true)
	await RenderingServer.frame_post_draw
	if not require(mask.size() == PANEL.x * PANEL.y * 4 and native.size() == mask.size(), "RGBA8 panel comparison"): return false
	var count := 0
	var split_error := 0
	var low_error := 0
	for i in range(0, mask.size(), 4):
		if mask[i + 3] != 255: continue
		count += 1
		for c in 3:
			split_error += absi(split[i+c] - native[i+c])
			low_error += absi(low[i+c] - native[i+c])
	print(name, ": ", count, " label pixels; mean RGB error vs native: split=", split_error / maxf(1, count*3), " half=", low_error / maxf(1, count*3))
	return require(count > 1000 and split_error < low_error, name + ": displayed label is closer to native with the toggle On")

func _run() -> void:
	if not require(ProjectSettings.get_setting("application/config/version") == "0.10.1", "requires a 0.10.1 pack"): return
	OS.low_processor_usage_mode = false
	root.size = PANEL
	# Exercise the real smoothing preference independently of the desktop driver's auto mode.
	OS.set_environment("SOCKET_3D_MSAA", "2")
	OS.set_environment("SOCKET_3D_FILTER", "linear")
	var manager = root.get_node("Manager")
	var settings = root.get_node("SettingsManager")
	settings.set_setting("cartridge_msaa", false)
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
	var art := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	for game_name in ["One", "Two"]:
		art.fill(Color("ede1a5"))
		var ink := Color("ab267d") if game_name == "One" else Color("2656ab")
		for x in range(0, 128, 8):
			art.fill_rect(Rect2i(x, 0, 4, 128), ink)
		if not require(art.save_png(fixture.path_join(game_name + "_support.png")) == OK, "write fixture art for " + game_name): return
		var info := FileAccess.open(fixture.path_join(game_name + ".json"), FileAccess.WRITE)
		if not require(info != null, "write fixture metadata for " + game_name): return
		info.store_string(JSON.stringify({"matched": true, "method": "md5", "game_id": 1, "name": game_name, "platform": "nintendo-game-boy-advance", "region": "World", "texture_url": "", "labels": [], "meta": {}}))
		info.close()
	var platform = load("res://scripts/platform.gd").new()
	platform.model = manager.db.get_platform("gba").new()
	platform.app_id = "gba.ra64.mgba"
	platform.rom_folder_path = OS.get_environment("SOCKET_TEST_ROOT")
	manager.add_platform_to_user(manager.current_user, platform)
	await manager.scan_platform_in_user(manager.current_user, platform)
	home.selected_platform_index = home._get_visible_platforms().find(platform)
	if not require(home.selected_platform_index >= 0, "fixture platform is visible"): return
	home.render_carousel()
	var carousel = home.carousel_3d
	await create_timer(1.0).timeout
	var carts: Array = carousel.active_cartridges.values()
	var selected = carousel.selected_game
	if not require(carts.size() == 2 and selected in carts and carts[0].game != carts[1].game, "carousel displays two different fixture carts"): return
	var other = carts[1] if carts[0] == selected else carts[0]
	for cart in carts:
		# Freeze idle motion without disabling the carousel's modal pause handling.
		carousel.set_cartridge_active(cart, false)
		cart.position.y = cart.get_meta("base_y")
		cart.rotation_degrees = cart.get_meta("base_rot")
		cart.update_material(1)
		cart.update_color(0)
		var cover: ShaderMaterial = cart.get_cover_material()
		var artwork: Texture2D = cart.game.support_texture
		if not require(cart.is_visible_in_tree() and cart.resolve_finish_id(1) == "opaque" and cover != null
			and artwork != null and cover.get_shader_parameter("artwork_texture") == artwork, "each visible cart is opaque with its own artwork"): return
	body = home.viewport_3d
	display = body.get("_display")
	if not require(display != null and display.material is ShaderMaterial, "carousel uses the packed display shader"): return

	settings.set_setting("render_scale_3d", 0.5)
	settings.set_setting("high_res_labels", true)
	if not await check_frame("half-scale casing, native labels", Vector2i(360, 240), true): return
	if not await check_artwork_route(selected, true): return
	if not await check_artwork_route(other, false): return
	# Exercise the same automatic choice as tile-capable Mali on the Mesa runner.
	OS.set_environment("SOCKET_TILE_MSAA", "1")
	OS.set_environment("SOCKET_3D_MSAA", "auto")
	settings.set_setting("cartridge_msaa", true)
	if not await check_frame("auto smoothing, split", Vector2i(360, 240), true): return
	if not require(body.msaa_3d == Viewport.MSAA_DISABLED and display.material.shader.code.begins_with("#define DISPLAY_SPLIT_LABEL\n#define DISPLAY_SPLIT_EDGE\n"), "auto uses coverage filtering instead of multisampling the split body"): return
	settings.set_setting("high_res_labels", false)
	await RenderingServer.frame_post_draw
	if not require(body.msaa_3d == Viewport.MSAA_2X and display.material.shader.code.begins_with("#define DISPLAY_LINEAR"), "single-pass restores normal AA without changing the setting"): return
	OS.set_environment("SOCKET_3D_MSAA", "2")
	settings.set_setting("cartridge_msaa", false)
	if not await check_frame("half-scale, preference off", Vector2i(360, 240), false): return
	if not await check_artwork_route(selected, false): return
	var saved := ConfigFile.new()
	if not require(saved.load("user://settings.cfg") == OK and saved.get_value("General", "high_res_labels", true) == false, "Off is persisted"): return
	settings.set_setting("render_scale_3d", 0.66)
	if not await check_frame("rounded casing, preference off", Vector2i(474, 316), false): return
	settings.set_setting("high_res_labels", true)
	if not await check_frame("rounded casing, native labels", Vector2i(474, 316), true): return
	settings.set_setting("render_scale_3d", 0.6)
	if not await check_frame("initial opaque", REDUCED, true): return
	var split_body := pixels(body)
	var split_label := pixels(label)
	settings.set_setting("render_scale_3d", 1.0)
	if not await check_frame("native-size bypass", PANEL, false): return
	if not await check_artwork_route(selected, false): return
	settings.set_setting("render_scale_3d", 0.6)
	if not await check_frame("reduced reactivation", REDUCED, true): return
	if not require(pixels(body) == split_body and pixels(label) == split_label, "reactivation redraws the original split frame"): return

	other.update_material(3)
	if not require(other.resolve_finish_id(3) == "clear", "change only the non-selected cart to clear"): return
	if not await check_frame("one clear neighbour: native labels over complete scaled scene", REDUCED, true): return
	if not await check_artwork_route(selected, true, true): return
	if not await check_artwork_route(other, false): return
	var glass_body := pixels(body)
	settings.set_setting("high_res_labels", false)
	if not await check_frame("clear neighbour, preference off", REDUCED, false): return
	if not require(pixels(body) == glass_body, "glass samples the same complete scaled image with the toggle on or off"): return
	settings.set_setting("high_res_labels", true)
	other.update_material(1)
	if not await check_frame("opaque restored", REDUCED, true): return
	if not require(pixels(body) == split_body and pixels(label) == split_label, "restoration redraws the original split frame"): return
	if not await check_artwork_route(selected, true): return
	if not await check_artwork_route(other, false): return

	# A stock disc remains scaled, but must not demote the neighbouring cover in Favorites.
	var disc = load("res://scenes/selectables/cart_disc.tscn").instantiate()
	var disc_game = load("res://scripts/game.gd").new()
	disc_game.platform_id = "psx"
	disc_game.support_texture_path = other.game.support_texture_path
	disc.set_game(disc_game)
	carousel.add_child(disc)
	disc.transform = other.transform
	other.hide()
	if not await check_frame("mixed cart and disc", REDUCED, true): return
	if not await check_artwork_route(selected, true, true): return
	if not await check_artwork_route(disc, false): return
	disc.free()
	other.show()
	if not await check_frame("mixed neighbours removed", REDUCED, true): return
	if not require(pixels(body) == split_body and pixels(label) == split_label, "no scaled label copy remains after the mixed tab"): return

	var modal = screen.get_screen("settings")
	modal.open()
	if not await check_frame("settings opens", REDUCED, true): return
	if not require(body.render_target_update_mode == SubViewport.UPDATE_ONCE, "Socket pauses the carousel with UPDATE_ONCE"): return
	var paused_body := pixels(body)
	var paused_label := pixels(label)
	var edges_before := partial_edge_pixels(body)
	settings.set_setting("cartridge_msaa", true)
	if not await check_frame("smoothing on while paused", REDUCED, true): return
	var edges_after := partial_edge_pixels(body)
	print("Partially covered casing pixels: off=", edges_before, " on=", edges_after)
	if not require(body.msaa_3d == Viewport.MSAA_2X and label.msaa_3d == Viewport.MSAA_DISABLED
		and edges_after > edges_before and pixels(label) == paused_label, "MSAA smooths the casing silhouette but preserves the native label pixels"): return
	settings.set_setting("cartridge_msaa", false)
	if not await check_frame("smoothing off while paused", REDUCED, true): return
	if not require(body.msaa_3d == Viewport.MSAA_DISABLED and pixels(body) == paused_body and pixels(label) == paused_label, "turning smoothing off restores both images"): return
	selected.position.x += 0.25
	await RenderingServer.frame_post_draw
	if not require(pixels(body) == paused_body and pixels(label) == paused_label, "both targets freeze behind Settings"): return
	carousel.set_model_zoom(0.85)
	await RenderingServer.frame_post_draw
	if not require(pixels(body) != paused_body and pixels(label) != paused_label, "paused zoom redraws both targets in the same frame"): return
	paused_body = pixels(body)
	paused_label = pixels(label)
	selected.position.x -= 0.25
	await RenderingServer.frame_post_draw
	if not require(pixels(body) == paused_body and pixels(label) == paused_label, "paused zoom redraw happens only once"): return

	var resized := Vector2i(540, 360)
	settings.set_setting("render_scale_3d", 0.75)
	if not await check_frame("paused body resize", resized, true): return
	var resized_body := body.get_texture().get_image()
	if not require(resized_body != null and resized_body.get_size() == resized and resized_body.get_used_rect().has_area()
		and pixels(label) != paused_label, "body resize redraws the nonempty body and native label in the same frame"): return
	paused_body = resized_body.get_data()
	paused_label = pixels(label)
	selected.position.x += 0.25
	await RenderingServer.frame_post_draw
	if not require(pixels(body) == paused_body and pixels(label) == paused_label, "body and label freeze again after the paused resize"): return
	modal.close()
	if not await check_frame("settings closes", resized, true): return
	if not require(body.render_target_update_mode == SubViewport.UPDATE_ALWAYS and pixels(body) != paused_body and pixels(label) != paused_label, "both targets resume together"): return
	for cart in carts: cart.hide()
	settings.set_setting("render_scale_3d", 0.5)
	for id in manager.db.platforms:
		var script = manager.db.get_platform(id)
		var scenes: Array = [script.new().selectable_scene]
		for variant in script.get_script_constant_map().values():
			if variant is PackedScene and not variant in scenes: scenes.append(variant)
		for scene in scenes:
			var sample = scene.instantiate()
			var game = load("res://scripts/game.gd").new()
			game.platform_id = id
			game.support_texture_path = selected.game.support_texture_path
			game.force_reload_texture()
			sample.default_label_material = sample.default_label_material.duplicate()
			sample.set_game(game)
			carousel.add_child(sample)
			sample.transform = selected.transform
			carousel.selected_game = sample
			var name := "%s/%s" % [id, scene.resource_path.get_file()]
			await RenderingServer.frame_post_draw
			var active: bool = body.get_meta(ACTIVE, false)
			if id in ["gb", "gbc", "gba"] and not require(active, name + ": opaque handheld cart splits"): return
			if not await check_frame(name, Vector2i(360, 240), active): return
			if id in ["gb", "gbc", "gba"]:
				if not await check_artwork_route(sample, true): return
				if not await check_panel_detail(settings, name): return
			sample.free()
	print("PASS: split lifecycle preserves the whole packed carousel frame across bypass, fallback, restore and pause")
	quit()
