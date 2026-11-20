# Run with tests/app/run_render.py and the packed 0.10.1 launcher.
# The first title wraps around to a frosted GBC neighbor, the next has two opaque neighbors.
extends SceneTree

const PANEL := Vector2i(720, 480)
const BODY := Vector2i(360, 240)
const NATIVE := &"socket_split_label_viewport"
const FIXTURE := {
	"A Circuit": ["gba", 0, 0],
	"B Orchard": ["gba", 0, 0],
	"C Creek": ["gb", 0, 0],
	"Z Forest": ["gbc", 2, 6],
}
var body: SubViewport
var settings: Node
var ink: ImageTexture

func _initialize() -> void:
	_run.call_deferred()

func require(ok: bool, message: String) -> bool:
	if not ok:
		printerr("FAIL: ", message)
		quit(1)
	return ok

func populate_favorites(manager) -> bool:
	var art := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	var platforms := {}
	var idx := 0
	for title in FIXTURE:
		var sample: Array = FIXTURE[title]
		var id: String = sample[0]
		var game = load("res://scripts/game.gd").new()
		game.rom_name = title
		game.rom_path = OS.get_environment("SOCKET_TEST_ROOT").path_join(title + "." + id)
		game.platform_id = id
		game.is_favorite = true
		game.custom_material_index = sample[1]
		game.custom_color_index = sample[2]
		game.support_texture_path = "user://favorites-%s.png" % idx
		art.fill(Color.from_hsv(idx / 4.0, 0.7, 0.5))
		if not require(art.save_png(game.support_texture_path) == OK, "write synthetic art for " + title): return false
		if not platforms.has(id):
			var platform = load("res://scripts/platform.gd").new()
			platform.model = manager.db.get_platform(id).new()
			platform.app_id = id + ".ra64.mgba"
			platform.rom_folder_path = OS.get_environment("SOCKET_TEST_ROOT")
			manager.add_platform_to_user(manager.current_user, platform)
			platforms[id] = platform
		platforms[id].games.append(game)
		idx += 1
	manager.save_user()
	var solid := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	solid.fill(Color("00ff9d"))
	ink = ImageTexture.create_from_image(solid)
	return true

func pixels(view: Viewport) -> PackedByteArray:
	var image := view.get_texture().get_image()
	image.convert(Image.FORMAT_RGBA8)
	return image.get_data()

func check_route(cart, label: SubViewport, focused: bool, glass: bool) -> bool:
	var cover: ShaderMaterial = cart.get_cover_material()
	var art: Texture2D = cart.game.support_texture
	if not require(cover != null and art != null and cover.get_shader_parameter("artwork_texture") == art, "loaded each title's art"): return false
	var body_before := pixels(body)
	var native_before := pixels(label)
	var panel_before := pixels(root)
	cover.set_shader_parameter("artwork_texture", ink)
	await RenderingServer.frame_post_draw
	var in_body := pixels(body) != body_before
	var in_native := pixels(label) != native_before
	var displayed := pixels(root) != panel_before
	cover.set_shader_parameter("artwork_texture", art)
	await RenderingServer.frame_post_draw
	print(cart.game.title, ": body=", in_body, " native=", in_native, " displayed=", displayed)
	return require(in_body == (not focused or glass) and in_native == focused and displayed,
		"%s: only the focus is native; glass still sees the whole scaled scene" % cart.game.title)

func _run() -> void:
	if not require(ProjectSettings.get_setting("application/config/version") == "0.10.1", "requires a packed 0.10.1 launcher"): return
	OS.low_processor_usage_mode = false
	root.size = PANEL
	settings = root.get_node("SettingsManager")
	settings.set_setting("render_scale_3d", 0.5)
	settings.set_setting("high_res_labels", true)
	settings.set_setting("cartridge_msaa", false)
	if not populate_favorites(root.get_node("Manager")): return
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	var screen = load("res://scripts/screens/screen.gd")
	var home
	for i in 3000:
		home = screen.get_screen("main")
		if home != null and home.is_node_ready() and root.get_meta("socket_shader_startup_complete", false): break
		await process_frame
	if not require(home != null and home.is_node_ready() and root.get_meta("socket_shader_startup_complete", false), "startup completes"): return
	for i in home._get_visible_platforms().size():
		if home.is_showing_favorites(): break
		home._on_prev_platform_button_pressed()
	var carousel = home.carousel_3d
	if not require(home.is_showing_favorites() and carousel.games.size() == FIXTURE.size(), "open the packed Favorites tab"): return
	body = home.viewport_3d
	for title in ["A Circuit", "B Orchard"]:
		await create_timer(0.9).timeout
		var selected = carousel.selected_game
		if not require(selected != null and selected.game.title == title, "select " + title + " by normal Favorites order"): return
		var carts: Array = carousel.active_cartridges.values()
		var frosted: Array = carts.filter(func(cart): return cart.game.title == "Z Forest")
		if not require(carts.size() == 3 and frosted.size() == int(title == "A Circuit"), "only the wraparound selection has the frosted neighbor"): return
		if not frosted.is_empty() and not require(frosted[0].resolve_finish_id(2) == "translucent", "wraparound neighbor uses real frosted finish"): return
		for cart in carts:
			carousel.set_cartridge_active(cart, false)
			cart.position.y = cart.get_meta("base_y")
			cart.rotation_degrees = cart.get_meta("base_rot")
		await RenderingServer.frame_post_draw
		var physical := Vector2(body.size) * body.scaling_3d_scale
		if not require(physical == Vector2(BODY), "casing remains at 360x240"): return
		var label := body.get_meta(NATIVE) as SubViewport if body.has_meta(NATIVE) else null
		var display: TextureRect = body.get("_display")
		if not require(label != null and label.size.x * label.size.y <= PANEL.x * PANEL.y / 2 and display.material.get_shader_parameter("native_label") == label.get_texture(), title + ": draws the selected sticker in a cropped target"): return
		for cart in carts:
			if not await check_route(cart, label, cart == selected, not frosted.is_empty()): return
		if title == "A Circuit": carousel.next()
	print("PASS: native Favorites labels survive a frosted wraparound neighbor")
	quit()
