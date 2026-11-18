# Draw the in-game Device Settings with the packed project, the fbdev display
# server and the window released, as during a game. Use tests/app/run_render.py
# with SOCKET_3D_MSAA=2 to exercise the switch on Mesa.
# The script saves each frame above a game picture in SOCKET_EVIDENCE.
extends SceneTree

var run_dir: String = OS.get_environment("SOCKET_RUN")
var evidence: String = OS.get_environment("SOCKET_EVIDENCE")
var log_text := ""
var layout := ""

func _initialize() -> void:
	_run.call_deferred()

func require(ok: bool, message: String) -> bool:
	if not ok:
		printerr("FAIL: ", message)
		quit(1)
	return ok

func wait(seconds: float) -> void:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame

# RetroArch appends lines to menu.input.
func send(text: String, settle: float = 0.4) -> void:
	log_text += text
	var file := FileAccess.open(run_dir.path_join("menu.input"), FileAccess.WRITE)
	file.store_string(log_text)
	file.close()
	await wait(settle)

func press(pad_name: String) -> void:
	await send("pad %s 1\n" % pad_name, 0.1)
	await send("pad %s 0\n" % pad_name)

func number() -> int:
	var file := FileAccess.open(run_dir.path_join("menu.frame"), FileAccess.READ)
	return file.get_buffer(16).decode_u32(12) if file != null else 0

func save(file_name: String) -> void:
	var data := FileAccess.get_file_as_bytes(run_dir.path_join("menu.frame"))
	var image := Image.create_from_data(data.decode_u32(16), data.decode_u32(20), false, Image.FORMAT_RGBA8, data.slice(28))
	var shown := Image.create(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8)
	for y in image.get_height():
		for x in image.get_width():
			var game := Color(0.2, 0.7, 0.3) if (x / 40 + y / 40) % 2 == 0 else Color(0.9, 0.8, 0.2)
			var pixel := image.get_pixel(x, y)
			shown.set_pixel(x, y, Color(pixel.r + game.r * (1.0 - pixel.a), pixel.g + game.g * (1.0 - pixel.a), pixel.b + game.b * (1.0 - pixel.a)))
	shown.save_png(evidence.path_join(file_name))
	# The rectangle, the text and the line count of each control. Compare the
	# file of two packs to see a layout change.
	layout += "== %s\n" % file_name
	for node in root.get_node("DeviceSettings")._gui.find_children("*", "Control", true, false):
		if node.is_visible_in_tree():
			layout += "%s %s %s lines=%s focus=%s %s\n" % [node.get_class(), node.get_global_rect().position.snappedf(0.01), node.size.snappedf(0.01),
				node.get_line_count() if node is Label else 1, node.has_focus(), (node.text if "text" in node else "").c_escape()]
	var file := FileAccess.open(evidence.path_join("layout.txt"), FileAccess.WRITE)
	file.store_string(layout)
	file.close()

func _run() -> void:
	OS.low_processor_usage_mode = false
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	for i in range(5000):
		if root.get_meta("socket_shader_startup_complete", false):
			break
		await process_frame
	if not require(root.get_meta("socket_shader_startup_complete", false), "startup completes"): return
	await wait(1.0)
	# SOCKET_TEST_DARK=1 selects Socket's dark mode, as on the test card.
	if OS.get_environment("SOCKET_TEST_DARK") == "1":
		root.get_node("SettingsManager").set_setting("dark_mode", true)
		await wait(0.5)
	var manager = root.get_node("Manager")
	var platform = load("res://scripts/platform.gd").new()
	platform.model = manager.db.get_platform("gba").new()
	var rom := OS.get_environment("SOCKET_TEST_ROOT").path_join("One.gba")
	platform.games.append(load("res://scripts/game.gd").from_dict({"rom_name": "One", "rom_path": rom, "platform_id": "gba"}))
	manager.add_platform_to_user(manager.current_user, platform)
	var home = load("res://scripts/screens/screen.gd").get_screen("main")
	home.selected_platform_index = home._get_visible_platforms().find(platform)
	home.render_carousel()
	var view: SubViewport = home.viewport_3d
	await wait(1.0)
	if not require(view.get_texture().get_image().get_used_rect().has_area(), "fixture cartridges are visible before launch"): return
	var bridge := root.get_node("FrontendBridge")
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
	if not require(OS.get_environment("SOCKET_GAME_OVERLAY_EGL") == "1", "the engine has a GL context without the display"): return
	var game := run_dir.path_join("game.sh")
	var script := FileAccess.open(game, FileAccess.WRITE)
	script.store_string("echo $$ > '%s'\nwhile [ ! -e '%s' ] && kill -0 $PPID 2>/dev/null; do sleep 0.05; done\nexit 0\n" % [run_dir.path_join("app.pid"), run_dir.path_join("game.stop")])
	script.close()
	var result: Array[int] = []
	var play := func() -> void: result.append(await bridge._play_with_menu(PackedStringArray([game])))
	play.call()
	await wait(0.5)
	var drawn := Engine.get_frames_drawn()
	var opened := Time.get_ticks_msec()
	await send("session 1-1 2\nopen 1\n", 0.0)
	while number() == 0 and Time.get_ticks_msec() - opened < 5000:
		await process_frame
	if not require(number() > 0, "the first frame arrives"): return
	print("Game menu: first frame %d ms after the open line" % (Time.get_ticks_msec() - opened))
	await wait(0.5)
	save("root.png")
	print("Game menu: theme ", FileAccess.get_file_as_string(run_dir.path_join("menu.theme")).strip_edges())
	if not require(FileAccess.get_file_as_string(run_dir.path_join("menu.theme")).begins_with("2 "), "a version 2 session gets theme version 2"): return
	# The focus outline and the filled part of a level bar must be clear on the
	# surface, in the light mode and in the dark mode.
	var panel := root.get_node("DeviceSettings")
	if not require(Rect2(Vector2.ZERO, panel._logical).encloses(panel._card.get_global_rect()), "all seven game menu rows fit on the panel"): return
	var data := FileAccess.get_file_as_bytes(run_dir.path_join("menu.frame"))
	var shot := Image.create_from_data(720, 480, false, Image.FORMAT_RGBA8, data.slice(28))
	var scale: float = 480.0 / panel._logical.y
	var surface: float = panel._surface.get_luminance()
	var row: Control = panel._gui.gui_get_focus_owner()
	var edge := shot.get_pixelv(Vector2i((row.global_position + Vector2(2.5 * panel._unit, row.size.y / 2.0)) * scale))
	var bar: Control = panel._rows["Volume"].get_node("Side/Bar")
	var fill := shot.get_pixelv(Vector2i((bar.global_position + Vector2(bar.size.x * 0.1, bar.size.y / 2.0)) * scale))
	print("Game menu: surface %.2f, focus outline %.2f, bar fill %.2f" % [surface, edge.get_luminance(), fill.get_luminance()])
	if not require(absf(edge.get_luminance() - surface) > 0.4, "the focus outline is clear on the surface"): return
	if not require(absf(fill.get_luminance() - surface) > 0.4, "the level bar fill is clear on the surface"): return
	var idle := number()
	await wait(1.5)
	print("Game menu: %d frames while idle for 1.5 s" % (number() - idle))
	await press("down")
	save("cheats-focus.png")
	# A page of RetroArch: six rows with values, a long selected row and a status of three lines.
	var card: Vector2 = panel._card.size
	var rows := PackedStringArray()
	for text in ["State slot                 3", "Shader                    On", "Fast-forward speed        2x", "Save state", "Load state", "A selected core option name of 120 bytes, the longest that RetroArch sends, shows all of its text on more lines  Enabled"]:
		if not require(text.to_utf8_buffer().size() <= 120, "row length"): return
		rows.append(text.to_utf8_buffer().hex_encode())
	await send("view 1 5 4 24 %s %s %s\n" % ["Cheats".to_utf8_buffer().hex_encode(),
		"Saved to slot 3. This status text has 120 bytes, the longest that RetroArch sends, and it is on some lines of the panel.".to_utf8_buffer().hex_encode(), " ".join(rows)])
	save("view.png")
	data = FileAccess.get_file_as_bytes(run_dir.path_join("menu.frame"))
	if not require(data.decode_u32(24) == 1 | 1 << 8, "the frame has the number of view lines"): return
	if not require(panel._card.size == card, "a page keeps the size of the panel"): return
	row = panel._gui.gui_get_focus_owner()
	if not require(row.get_parent() == panel._view_rows and panel._view_rows.get_parent().get_global_rect().grow(1.0).encloses(row.get_global_rect()), "the selected row is visible"): return
	await send("view 1 0 0 3 %s - %s\n" % ["Core options".to_utf8_buffer().hex_encode(), " ".join(rows.slice(0, 3))])
	save("view-short.png")
	await send("root 1\n")
	if not require(panel._gui.gui_get_focus_owner().name == "Cheats" and panel._card.size == card, "root returns to the row"): return
	await press("up") # Game
	await press("up") # Cartridge MSAA when available, otherwise Bluetooth
	var msaa_row: Button = panel._rows["Cartridge MSAA"]
	if not msaa_row.disabled:
		if not require(msaa_row.has_focus(), "the cartridge MSAA row has focus"): return
		await press("a")
		if not require(root.get_node("SettingsManager").get_setting("cartridge_msaa") == false, "the game menu saved MSAA Off"): return
		await press("up")
	await press("a")
	if not require(panel._sub != null and panel._title.text == "Bluetooth", "Bluetooth opens from the shared menu"): return
	await wait(1.0)
	save("bluetooth.png")
	await press("b")
	await wait(0.3)
	await press("up")
	await press("a")
	await wait(1.0)
	save("wifi.png")
	var animated := number()
	await wait(1.5)
	print("Game menu: %d frames in 1.5 s on the Wi-Fi page" % (number() - animated))
	await send("close 1\n")
	if not require(not FileAccess.file_exists(run_dir.path_join("menu.frame")), "close removes the frame"): return
	if not require(Engine.get_frames_drawn() == drawn, "the main loop does not draw during the game"): return
	# A stopped game, as during a sleep, slows the loop. A continued game restores it.
	var overlay := bridge.get_node("GameOverlay")
	var game_pid := FileAccess.get_file_as_string(run_dir.path_join("app.pid")).strip_edges()
	OS.execute("kill", PackedStringArray(["-STOP", game_pid]))
	await wait(1.6)
	if not require(OS.low_processor_usage_mode_sleep_usec == overlay.SLEEP_USEC, "a stopped game slows the loop"): return
	OS.execute("kill", PackedStringArray(["-CONT", game_pid]))
	await wait(1.6)
	if not require(OS.low_processor_usage_mode_sleep_usec == overlay.IDLE_USEC, "a continued game restores the loop"): return
	FileAccess.open(run_dir.path_join("game.stop"), FileAccess.WRITE).close()
	await wait(0.5)
	if not require(result == [0] and not paused, "the game exit restores the launcher"): return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
	for i in range(3): await RenderingServer.frame_post_draw
	if not require(view.msaa_3d == Viewport.MSAA_DISABLED, "the resumed carousel uses the selected MSAA state"): return
	if not require(view.get_texture().get_image().get_used_rect().has_area(), "the resumed cartridge viewport draws cartridges"): return
	root.get_texture().get_image().save_png(evidence.path_join("launcher-after.png"))
	print("PASS: game menu frames with the packed project")
	quit()
