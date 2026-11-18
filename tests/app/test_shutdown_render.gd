# Quit the packed launcher with a library of five games and a real
# Compatibility renderer. Run with tests/app/run_shutdown.py: the leak and
# crash messages of the engine come after this script, so the runner reads the log.
# The carousel shows three games. It also prepares the labels of games that are
# not in view. With four games or more, these must not stay after the renderer.
extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func fail(message: String) -> void:
	printerr("FAIL: ", message)
	quit(1)

func _run() -> void:
	OS.low_processor_usage_mode = false
	root.size = Vector2i(720, 480)
	if not OS.get_user_data_dir().begins_with("/tmp/"): return fail("set XDG_DATA_HOME to a folder below /tmp")
	var roms := OS.get_environment("SOCKET_TEST_ROOT")
	if not roms.begins_with("/tmp/") or not DirAccess.dir_exists_absolute(roms): return fail("set SOCKET_TEST_ROOT to a folder below /tmp")
	var manager = root.get_node("Manager")
	load("res://scripts/models/emulator_database.gd").store("gba", [{"uniqueId": "gba.ra64.mgba", "name": "mGBA", "acceptedFilenameRegex": "[.]gba$", "amStartArguments": "-n com.retroarch/.Main -e LIBRETRO mgba"}])
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	var screen = load("res://scripts/screens/screen.gd")
	var home: Node
	for i in range(40000):
		home = screen.get_screen("main")
		if home != null and home.is_node_ready() and root.get_meta("socket_shader_startup_complete", false): break
		await process_frame
	if home == null or not root.get_meta("socket_shader_startup_complete", false): return fail("startup completes")
	var art := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	art.fill(Color(0.9, 0.2, 0.15))
	DirAccess.make_dir_recursive_absolute("user://scraped_data/gba")
	var platform = load("res://scripts/platform.gd").new()
	platform.model = manager.db.get_platform("gba").new()
	platform.app_id = "gba.ra64.mgba"
	platform.rom_folder_path = roms
	manager.add_platform_to_user(manager.current_user, platform)
	var names := ["One", "Two", "Three", "Four", "Five"]
	for game_name in names:
		FileAccess.open(roms.path_join(game_name + ".gba"), FileAccess.WRITE).close()
		art.save_png("user://scraped_data/gba/%s_support.png" % game_name)
		var info := FileAccess.open("user://scraped_data/gba/%s.json" % game_name, FileAccess.WRITE)
		info.store_string(JSON.stringify({"matched": true, "method": "md5", "game_id": 1, "name": game_name, "platform": "nintendo-game-boy-advance", "region": "World", "texture_url": "", "labels": [], "meta": {}}))
		info.close()
	await manager.scan_platform_in_user(manager.current_user, platform)
	home.selected_platform_index = home._get_visible_platforms().find(platform)
	home.render_carousel()
	var carousel = home.carousel_3d
	if carousel.games.size() < names.size(): return fail("the carousel has five games: %d" % carousel.games.size())
	# Draw the carousel, move one time, and let the label loads of the worker threads end.
	for i in range(60): await RenderingServer.frame_post_draw
	carousel.next()
	for i in range(120): await RenderingServer.frame_post_draw
	var loaded := 0
	for game in carousel.games:
		if game._support_image_loaded: loaded += 1
	if loaded < 4: return fail("the labels of games out of view are prepared: %d" % loaded)
	# Quit while new label loads can be in work.
	for game in carousel.games: game.force_reload_texture()
	carousel.next()
	for i in range(2): await process_frame
	print("PASS: launcher with five games prepared %d labels and quits" % loaded)
	quit()
