# Check the label of a moving GBA cartridge behind each casing finish, with the
# packed carousel and the Compatibility renderer.
# Run with tests/app/run_glass_label.py (tile MSAA path of the RG SP, with depth
# loss) or tests/app/run_render.py (MSAA resolve path of Mesa).
#
# The translucent and clear finishes read the screen texture. The engine then
# leaves the 3D framebuffer in the middle of the frame. A tile MSAA driver can
# lose the depth at that time, and the casing then draws through the label.
# The opaque finish is the control: it must be correct in each run.
#
# For each pose of the idle tilt the test compares the label pixels of the MSAA
# view with the same pose without MSAA. Without MSAA the engine does not use
# the tile framebuffer.
#   GLASS_LABEL_EXPECT=bug  the pack has the defect: the test passes only when
#                           the glass finishes show it and the control is correct.
#   GLASS_LABEL_FRAMES      poses for each finish, default 8
extends SceneTree

const SIZE := Vector2i(540, 360)
# Casing material indexes of Customize. The first is the control.
const FINISHES := {1: "opaque", 2: "translucent", 3: "clear"}
# A label pixel is wrong when one channel differs by more than this (0 to 255).
const CHANNEL_LIMIT := 32
# The largest part of wrong label pixels in a correct pose.
const PASS_PART := 0.005
# The smallest part of wrong label pixels that shows the defect.
const BUG_PART := 0.05
# The largest part of wrong casing pixels. MSAA edges give 3 to 4 percent. The
# defect gave 6 to 7 percent, and a casing that is not drawn gives much more.
const CASING_PART := 0.05
var out := ""

func _initialize() -> void:
	_run.call_deferred()

func fail(message: String) -> void:
	printerr("FAIL: ", message)
	quit(1)

func grab(view: SubViewport) -> Image:
	for i in range(3): await process_frame
	await RenderingServer.frame_post_draw
	var image := view.get_texture().get_image()
	image.convert(Image.FORMAT_RGBA8)
	return image

# Draws that used lost depth, from the EGL helper. Zero without the helper.
func lost_draws() -> int:
	var path := OS.get_environment("SOCKET_FBO_COUNTS")
	var values := FileAccess.get_file_as_string(path).split_floats(" ") if path != "" else PackedFloat64Array()
	return int(values[5]) if values.size() > 5 else 0

# Wrong and total pixels of the label, then of the casing. Each area excludes
# 2 pixels at the label edge. The casing area is opaque without MSAA.
func compare(shot: Image, reference: Image, mask: Image) -> Array:
	var a := shot.get_data()
	var b := reference.get_data()
	var m := mask.get_data()
	var counts := [0, 0, 0, 0]
	for y in range(2, SIZE.y - 2):
		for x in range(2, SIZE.x - 2):
			var at := (y * SIZE.x + x) * 4
			var inside := 0
			for near in [at, at - 8, at + 8, at - SIZE.x * 8, at + SIZE.x * 8]:
				if m[near] >= 200 and m[near + 1] <= 55 and m[near + 2] >= 200 and m[near + 3] >= 200:
					inside += 1
			if (inside > 0 and inside < 5) or (inside == 0 and b[at + 3] < 255):
				continue
			var area := 0 if inside == 5 else 2
			counts[area + 1] += 1
			if absi(a[at] - b[at]) > CHANNEL_LIMIT or absi(a[at + 1] - b[at + 1]) > CHANNEL_LIMIT or absi(a[at + 2] - b[at + 2]) > CHANNEL_LIMIT:
				counts[area] += 1
	return counts

func _run() -> void:
	OS.low_processor_usage_mode = false
	root.size = Vector2i(720, 480)
	out = OS.get_environment("SOCKET_EVIDENCE")
	var roms := OS.get_environment("SOCKET_TEST_ROOT")
	var expect_bug := OS.get_environment("GLASS_LABEL_EXPECT") == "bug"
	var frames := (OS.get_environment("GLASS_LABEL_FRAMES") if OS.get_environment("GLASS_LABEL_FRAMES") != "" else "8").to_int()
	var manager = root.get_node("Manager")
	load("res://scripts/models/emulator_database.gd").store("gba", [{"uniqueId": "gba.ra64.mgba", "name": "mGBA", "acceptedFilenameRegex": "[.]gba$", "amStartArguments": "-n com.retroarch/.Main -e LIBRETRO mgba"}])
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	var screen = load("res://scripts/screens/screen.gd")
	var home
	for i in range(40000):
		home = screen.get_screen("main")
		if home != null and home.is_node_ready() and root.get_meta("socket_shader_startup_complete", false): break
		await process_frame
	if home == null or not root.get_meta("socket_shader_startup_complete", false): return fail("startup completes")
	var art := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	for y in range(256):
		for x in range(256):
			art.set_pixel(x, y, Color(0.9, 0.2, 0.15) if (x / 16 + y / 16) % 2 == 0 else Color.WHITE)
	DirAccess.make_dir_recursive_absolute("user://scraped_data/gba")
	var platform = load("res://scripts/platform.gd").new()
	platform.model = manager.db.get_platform("gba").new()
	platform.app_id = "gba.ra64.mgba"
	platform.rom_folder_path = roms
	manager.add_platform_to_user(manager.current_user, platform)
	for game_name in ["One", "Two", "Three", "Four", "Five"]:
		FileAccess.open(roms.path_join(game_name + ".gba"), FileAccess.WRITE).close()
		art.save_png("user://scraped_data/gba/%s_support.png" % game_name)
		var info := FileAccess.open("user://scraped_data/gba/%s.json" % game_name, FileAccess.WRITE)
		info.store_string(JSON.stringify({"matched": true, "method": "md5", "game_id": 1, "name": game_name, "platform": "nintendo-game-boy-advance", "region": "World", "texture_url": "", "labels": [], "meta": {}}))
		info.close()
	await manager.scan_platform_in_user(manager.current_user, platform)
	home.selected_platform_index = home._get_visible_platforms().find(platform)
	home.render_carousel()
	var carousel = home.carousel_3d
	for i in range(200): await process_frame
	carousel.next()
	for i in range(120): await process_frame
	# Wait until the carousel has no shader warm-up mesh for 30 frames.
	var quiet := 0
	for i in range(3000):
		quiet = 0 if carousel.get_children().any(func(node): return node is MeshInstance3D and node.material_override) else quiet + 1
		if quiet >= 30: break
		await process_frame
	if carousel.active_cartridges.size() != 3: return fail("carousel shows three cartridges")
	carousel.set_process(false)
	var view: SubViewport = home.viewport_3d
	var fit := Callable(view, "_apply")
	view.get_parent().resized.disconnect(fit)
	root.size_changed.disconnect(fit)
	var shipped_msaa := view.msaa_3d
	var tile := OS.get_environment("SOCKET_TILE_MSAA") == "1"
	var discard := OS.get_environment("SOCKET_TILE_DISCARD")
	print("path=", "tile MSAA" if tile else "MSAA resolve", " depth_loss=", discard if discard != "" else "off", " view=", view.size, " msaa=", shipped_msaa)
	if view.size != SIZE: return fail("the pack starts at 540x360")
	if shipped_msaa != Viewport.MSAA_2X: return fail("the pack selects 2x MSAA")
	if expect_bug and not (tile and discard != ""): return fail("the defect needs the tile MSAA helper with SOCKET_TILE_DISCARD")
	var magenta := StandardMaterial3D.new()
	magenta.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	magenta.albedo_color = Color(1, 0, 1)
	magenta.disable_fog = true
	var carts: Array = carousel.active_cartridges.values()
	var ok := true
	for index in FINISHES:
		# The real path of Customize: the app selects and builds the casing material.
		for cart in carts:
			cart.game.custom_material_index = index
			cart.game.custom_color_index = 0
			cart.refresh_casing()
		var id: String = carts[0].resolve_finish_id(index)
		var casing: Material = carts[0].casing_meshs[0].get_surface_override_material(0)
		if id != FINISHES[index]: return fail("finish %d is %s, not %s" % [index, id, FINISHES[index]])
		var labels := []
		for cart in carts:
			for mesh in cart.find_children("*", "MeshInstance3D", true, false):
				for surface in (mesh.mesh.get_surface_count() if mesh.mesh else 0):
					var material = mesh.get_active_material(surface)
					if material is ShaderMaterial and material.shader and material.shader.resource_path.ends_with("paper_sticker.gdshader"):
						labels.append([mesh, surface, mesh.get_surface_override_material(surface)])
		if labels.size() < 3: return fail("each cartridge has a label")
		for i in range(30): await process_frame
		carousel.set("_time", 0.0)
		var worst := 0.0
		var least := 1.0
		var lost := 0
		var parts := []
		var casing_worst := 0.0
		for k in range(frames):
			# One step of the idle tilt: the cartridge moves between poses.
			carousel._process(1.0 / 6.0)
			view.msaa_3d = Viewport.MSAA_DISABLED
			var reference: Image = await grab(view)
			for label in labels: label[0].set_surface_override_material(label[1], magenta)
			var mask: Image = await grab(view)
			for label in labels: label[0].set_surface_override_material(label[1], label[2])
			view.msaa_3d = shipped_msaa
			var before := lost_draws()
			var shot: Image = await grab(view)
			lost += lost_draws() - before
			var result: Array = compare(shot, reference, mask)
			if result[1] < 5000 or result[3] < 5000: return fail("%s pose %d has a label area and a casing area" % [id, k])
			var part: float = float(result[0]) / result[1]
			casing_worst = maxf(casing_worst, float(result[2]) / result[3])
			parts.append(snappedf(part * 100.0, 0.01))
			worst = maxf(worst, part)
			least = minf(least, part)
			if k == 0 or k == frames - 1 or part == worst:
				shot.save_png(out.path_join("%s-%02d-shot.png" % [id, k]))
				reference.save_png(out.path_join("%s-%02d-reference.png" % [id, k]))
		var shader: String = casing.shader.resource_path if casing is ShaderMaterial else casing.get_class()
		print("finish ", id, " shader=", shader, " wrong_label_percent=", parts, " worst_wrong_casing_percent=", snappedf(casing_worst * 100.0, 0.01), " draws_with_lost_depth=", lost)
		var bug_here: bool = expect_bug and index != 1
		if bug_here and least < BUG_PART:
			ok = false
			printerr("FAIL: ", id, ": the defect shows in each pose (least %.2f %%)" % (least * 100.0))
		if not bug_here and casing_worst > CASING_PART:
			ok = false
			printerr("FAIL: ", id, ": the casing is correct in each pose (worst %.2f %%)" % (casing_worst * 100.0))
		if not bug_here and worst > PASS_PART:
			ok = false
			printerr("FAIL: ", id, ": the label is correct in each pose (worst %.2f %%)" % (worst * 100.0))
	if not ok:
		quit(1)
		return
	print("PASS: " + ("glass finishes show the label defect and the opaque control is correct" if expect_bug else "moving labels are correct behind opaque, translucent and clear casings"))
	quit()
