extends SceneTree

var manager
var home
var scan_started: bool = false
var checked: int = 0
var joy_device: int
var artwork: Image

func _initialize() -> void:
	_run.call_deferred()

func require(ok: bool, message: String) -> bool:
	if not ok:
		printerr("FAIL: ", message)
		quit(1)
		return false
	checked += 1
	return true

func _run() -> void:
	root.size = Vector2i(640, 480)
	manager = root.get_node("Manager")
	# GUIDE ignores events from devices that have not connected.
	joy_device = root.get_node("GUIDE")._input_state.connect_virtual_stick(0)
	await load(get_script().resource_path.get_base_dir().path_join("test_controls.gd")).new().run(self, root.get_node("FrontendBridge"))
	var settings = root.get_node("SettingsManager")
	if not require(settings.get_setting("ui_sounds_enabled") == false, "saved mute setting loaded at startup"): return
	var bus: int = AudioServer.get_bus_index("sfx")
	if not require(bus > 0 and AudioServer.is_bus_mute(bus), "startup sfx bus is muted"): return
	var database = load("res://scripts/models/emulator_database.gd")
	database.store("gba", [{"uniqueId": "gba.ra64.mgba", "name": "mGBA", "acceptedFilenameRegex": "[.]gba$", "amStartArguments": "-n com.retroarch/.Main -e LIBRETRO mgba"}])
	if not require(not manager.needs_emulator_database(), "partial Mac emulator cache skips startup download"): return
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	for i in range(30): await process_frame
	var screen = load("res://scripts/screens/screen.gd")
	home = screen.get_screen("main")
	var viewport: SubViewport = home.viewport_3d
	var lights: = viewport.find_children("*", "DirectionalLight3D", true, false)
	if not require(lights.size() == 1 and lights[0].shadow_enabled and lights[0].directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS, "smaller shadow atlas preserves the cartridge light and four shadow splits"): return
	if FileAccess.file_exists("/sys/devices/system/cpu/online"):
		var online: String = root.get_node("FrontendBridge")._read_sys("/sys/devices/system/cpu/online")
		if not require(RegEx.create_from_string("^[0-9,-]+$").search(online) != null, "packed sysfs read excludes the unread page tail"): return
	var display: TextureRect = viewport.get("_display")
	if not require(display.material is ShaderMaterial and display.material.shader.resource_path == "res://shaders/display_aa.gdshader", "AA uses the existing 3D display"): return
	if not require(viewport.msaa_3d == Viewport.MSAA_DISABLED, "cartridge viewport disables MSAA"): return
	if not require(viewport.is_processing() == (OS.get_environment("SOCKET_FPS_DIAGNOSTICS") == "1"), "FPS diagnostics are opt-in"): return
	if viewport.is_processing():
		viewport._fps_started_usec = Time.get_ticks_usec() - 5000000
		Engine.print_to_stdout = false
		viewport._process(0.0)
		Engine.print_to_stdout = true
		if not require(viewport._fps_frames == 0 and viewport._fps_worst_usec == 0, "FPS diagnostics emit and reset each wall-time interval"): return
		var records: = FileAccess.get_file_as_string("user://render-performance.jsonl").strip_edges().split("\n")
		var sample = JSON.parse_string(records[-1])
		if not require(sample is Dictionary and sample.elapsed_seconds >= 5.0 and sample.process_frames >= 1 and sample.process_fps > 0.0 and sample.drawn_frames == 0 and sample.rendered_fps == 0.0, "FPS diagnostics persist with stdout disabled and distinguish headless frames"): return
		if not require(sample.screens is Array and sample.shaders_3d is Array and sample.viewport_update_mode == viewport.render_target_update_mode and sample.process_ms >= 0.0 and sample.physics_ms >= 0.0 and sample.primitives >= 0.0, "FPS diagnostics identify screen, material and render state"): return
	else:
		if not require(not FileAccess.file_exists("user://render-performance.jsonl"), "disabled diagnostics write no file"): return
	for window_size in [Vector2i(640, 480), Vector2i(720, 480), Vector2i(2560, 1440)]:
		root.size = window_size
		for i in range(3): await process_frame
		var container: SubViewportContainer = viewport.get_parent()
		var native: Vector2 = container.size * container.get_global_transform().get_scale() * Vector2(root.size) / root.get_visible_rect().size
		var requested: Vector2 = container.size * 0.5
		settings.set_setting("render_scale_3d", 0.5)
		viewport._apply()
		var expected: Vector2 = requested.min(native * (2.0 / 3.0))
		if not require(viewport.size == Vector2i(roundi(expected.x), roundi(expected.y)).maxi(2), "3D size preserves lower setting and caps native pixels: " + str(window_size)): return
		if window_size == Vector2i(720, 480):
			if not require(root.content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS, "720x480 UI draws at native resolution"): return
			if not require(root.get_visible_rect().size == Vector2(1920, 1280), "720x480 keeps the expanded 3:2 logical layout"): return
			if not require(viewport.size == Vector2i(480, 320), "720x480 limits 3D to 480x320 with saved 50% render scale"): return
			var camera: Camera3D = viewport.get_camera_3d()
			if not require(camera.fov == 20.0 and camera.keep_aspect == Camera3D.KEEP_HEIGHT, "720x480 preserves the cartridge camera framing"): return
	root.size = Vector2i(720, 480)
	for i in range(3): await process_frame
	var hud = root.get_node("FrontendBridge/ControlsHUD")
	if not require(hud._view.get_viewport_transform().is_equal_approx(Transform2D.IDENTITY), "HUD cancels the 1920x1280 logical scale at 720x480"): return
	var platform = load("res://scripts/platform.gd").new()
	platform.model = manager.db.get_platform("gba").new()
	platform.app_id = "gba.ra64.mgba"
	manager.add_platform_to_user(manager.current_user, platform)
	var editor = screen.get_screen("edit_platform")
	screen.get_screen("settings").open()
	editor.set_platform(platform)
	editor.open()
	editor.rom_folder_path = OS.get_environment("SOCKET_TEST_ROOT")
	editor._update_compatible_games_preview()
	if not require(editor.total_games_label.text == "2 compatible games found", "real editor previews fixture ROMs"): return
	await create_timer(0.5).timeout
	var scan = editor.add_button.get_node("../Button_Scan")
	editor.delete_button.grab_focus()
	await joy(JOY_BUTTON_DPAD_RIGHT)
	if not require(root.gui_get_focus_owner() == scan, "joypad Delete to Scan"): return
	await joy(JOY_BUTTON_DPAD_RIGHT)
	if not require(root.gui_get_focus_owner() == editor.add_button, "joypad Scan to Save"): return
	await joy(JOY_BUTTON_DPAD_LEFT)
	if not require(root.gui_get_focus_owner() == scan, "joypad Save to Scan"): return
	await joy(JOY_BUTTON_DPAD_LEFT)
	if not require(root.gui_get_focus_owner() == editor.delete_button, "joypad Scan to Delete"): return
	await joy(JOY_BUTTON_DPAD_RIGHT)
	check_audio(root)
	settings.set_setting("ui_sounds_enabled", true)
	if not require(not AudioServer.is_bus_mute(bus), "setting enables UI sound"): return
	settings.set_setting("ui_sounds_enabled", false)
	if not require(AudioServer.is_bus_mute(bus), "setting disables UI sound"): return
	artwork = Image.create(2, 2, false, Image.FORMAT_RGBA8)
	artwork.fill(Color.RED)
	DirAccess.make_dir_recursive_absolute("user://scraped_data/gba")
	artwork.save_png("user://scraped_data/gba/curated-one.png")
	artwork.save_png("user://scraped_data/gba/Two_support.png")
	var info: = {"matched": true, "method": "md5", "game_id": 42, "name": "Mac One", "platform": "nintendo-game-boy-advance", "region": "World", "texture_url": "https://example.invalid/label.png", "labels": [], "meta": {"md5": "host-hash"}}
	var metadata: = FileAccess.open("user://scraped_data/gba/curated-one.json", FileAccess.WRITE)
	metadata.store_string(JSON.stringify(info))
	metadata.close()
	info.name = "Mac Two"
	metadata = FileAccess.open("user://scraped_data/gba/Two.json", FileAccess.WRITE)
	metadata.store_string(JSON.stringify(info))
	metadata.close()
	# Use the saved Mac library schema and the actual Game deserializer.
	var game_type = load("res://scripts/game.gd")
	var existing = game_type.from_dict({"rom_name": "One", "rom_path": OS.get_environment("SOCKET_TEST_ROOT").path_join("One.gba"), "platform_id": "gba", "game_info_path": "user://scraped_data/gba/curated-one.json", "support_texture_path": "user://scraped_data/gba/curated-one.png", "playtime": 123, "is_favorite": true, "custom_label_zoom": 1.5, "added_at": 12345})
	platform.games.append(existing)
	manager.save_user()
	manager.scrape_started.connect(func(_total): scan_started = true)
	await joy(JOY_BUTTON_A)
	await create_timer(0.5).timeout
	if not require(not scan_started and manager._active_scraper == null, "real Scan never starts Linux network scraper"): return
	if not require(platform.games.size() == 2, "offline scan keeps both discovered games"): return
	if not require(platform.games.has(existing), "rescan preserves the existing Game object"): return
	if not require(existing.playtime == 123 and existing.is_favorite and existing.custom_label_zoom == 1.5 and existing.added_at == 12345, "Mac game preferences and history survive rescan"): return
	for game in platform.games:
		if not require(game.support_image != null and game.support_texture != null, "Mac artwork loads offline: " + game.rom_name): return
		if not require(game.title == "Mac " + game.rom_name, "Mac metadata loads offline: " + game.rom_name): return
	var third: = FileAccess.open(OS.get_environment("SOCKET_TEST_ROOT").path_join("Three.gba"), FileAccess.WRITE)
	third.close()
	await manager.scan_platform_in_user(manager.current_user, platform)
	if not require(platform.games.size() == 3 and platform.games.has(existing), "rescan retains populated games and discovers an uncached game offline"): return
	if not require(manager._active_scraper == null and not scan_started, "uncached game starts no scraper"): return
	var original_user = manager.current_user
	manager.load_user()
	var restored = manager.current_user.added_platforms[0]
	if not require(restored.games.size() == 3, "offline library survives reload"): return
	for game in restored.games:
		if game.rom_name == "Three":
			if not require(game.game_info_path.is_empty() and game.support_texture_path.is_empty(), "uncached ROM remains playable without media"): return
		else:
			if not require(game.title == "Mac " + game.rom_name and game.support_image != null, "saved cache paths survive reload"): return
	manager.current_user = original_user
	check_audio(root)
	if not require(home.carousel_3d.games.size() == 3, "home refreshes after offline rescan"): return
	var carousel = home.carousel_3d
	var selected: int = carousel.selected_index
	carousel.next()
	if not require(carousel.selected_index != selected and carousel.selected_game.game == carousel.get_selected_game(), "optimized carousel advances selection"): return
	carousel.prev()
	if not require(carousel.selected_index == selected and carousel.active_cartridges.size() == 3, "optimized carousel returns with three visible cartridges"): return
	if not await check_focus(screen): return
	root.get_node("GUIDE")._input_state.disconnect_virtual_stick(joy_device)
	await create_timer(0.5).timeout
	await manager.update_emulator_database(true)
	var dialog = screen.get_screen("dialog")
	if not require(dialog.message_label.text.contains("Mac setup tool"), "manual emulator update gives offline setup instruction"): return
	print("PASS: packed app viewport limits, carousel navigation, settings/customization focus outlines, startup mute, UI audio, joypad footer, real offline Scan, Mac metadata/artwork preservation, uncached ROM discovery and reload (", checked, " checks)")
	quit()

func check_focus(screen) -> bool:
	var opened: Array = screen.screens_open.duplicate()
	opened.reverse()
	for current in opened:
		if current != home:
			current.close()
			await create_timer(0.7).timeout
	var overlay = home.get_parent().get_node("FocusOverlay")
	for name in ["settings", "customize"]:
		var current = screen.get_screen(name)
		current.open()
		await create_timer(0.7).timeout
		# GUIDE virtual input changes selection without a window input event.
		var controller: = InputEventJoypadButton.new()
		controller.button_index = JOY_BUTTON_DPAD_DOWN
		controller.pressed = true
		overlay._input(controller)
		var first: Control = root.gui_get_focus_owner()
		await joy(JOY_BUTTON_DPAD_DOWN)
		await create_timer(0.3).timeout
		var selected: Control = root.gui_get_focus_owner()
		if not require(selected != first and current.is_ancestor_of(selected), name + " joypad changes the selected item"): return false
		if not require(overlay.is_visible_in_tree() and overlay._target_control == selected, name + " outline follows the selected item"): return false
		if not require(overlay.global_position.distance_to(selected.global_position - Vector2.ONE * overlay.offset / 2.0) < 2.0, name + " outline reaches the selected item"): return false
		if not require(overlay.size.is_equal_approx(selected.size + Vector2.ONE * overlay.offset), name + " outline fits the selected item"): return false
		if not require(effective_z(overlay) > effective_z(selected) and effective_z(overlay) < effective_z(home.get_parent().get_node("Transition")), name + " outline draws above the selected item and below transitions"): return false
		var panel: Panel = overlay.get_node("Panel")
		var border: StyleBoxFlat = panel.get_theme_stylebox("panel")
		if not require(panel.is_visible_in_tree() and border.border_width_left > 0 and border.border_color.a > 0 and not border.draw_center, name + " outline has a visible border and a transparent center"): return false
		overlay._input(InputEventMouseMotion.new())
		await process_frame
		if not require(not overlay.visible, name + " mouse input hides the outline"): return false
		overlay._input(controller)
		await joy(JOY_BUTTON_DPAD_UP)
		if not require(overlay.visible and overlay._target_control == root.gui_get_focus_owner(), name + " controller input restores the outline"): return false
		if name == "settings":
			var dialog = screen.get_screen("dialog")
			dialog.display("Focus", "Modal focus", func(): pass, func(): pass)
			await create_timer(0.7).timeout
			var modal_focus: Control = root.gui_get_focus_owner()
			if not require(modal_focus != null and dialog.is_ancestor_of(modal_focus) and (not overlay.visible or (overlay._target_control != null and dialog.is_ancestor_of(overlay._target_control))), "modal dialog keeps the outline off background settings"): return false
			dialog.close()
			await create_timer(0.7).timeout
		current.close()
		await create_timer(0.7).timeout
	return true

func effective_z(control: CanvasItem) -> int:
	var depth: int = 0
	var node: Node = control
	while node is CanvasItem:
		depth += node.z_index
		if not node.z_as_relative: break
		node = node.get_parent()
	return depth

func joy(button: int) -> void:
	var event: = InputEventJoypadButton.new()
	event.device = joy_device
	event.button_index = button
	event.pressed = true
	Input.parse_input_event(event)
	# Virtual controllers send input through GUIDE's public input entry point.
	root.get_node("GUIDE").inject_input(event)
	for i in range(4): await process_frame
	event = InputEventJoypadButton.new()
	event.device = joy_device
	event.button_index = button
	Input.parse_input_event(event)
	# Virtual controllers send input through GUIDE's public input entry point.
	root.get_node("GUIDE").inject_input(event)
	for i in range(4): await process_frame

func check_audio(node: Node) -> void:
	if node is AudioStreamPlayer:
		if not require(node.bus == &"sfx", "UI audio routes through sfx: " + str(node.get_path())): return
	for child in node.get_children(): check_audio(child)
