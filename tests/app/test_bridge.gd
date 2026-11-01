extends SceneTree

var selected: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(640, 480)
	root.gui_embed_subwindows = true
	var bridge = load("res://addons/FrontendPlugin/frontend_bridge.gd").new()
	root.add_child(bridge)
	await load("res://test_controls.gd").new().run(self, bridge)
	var folder: = OS.get_environment("SOCKET_TEST_ROOT")
	var scalar: = folder.path_join("scalar")
	var scalar_file: = FileAccess.open(scalar, FileAccess.WRITE)
	scalar_file.store_string(" 42 \nunused\n")
	scalar_file.close()
	assert(bridge._read_sys(scalar) == "42")
	DirAccess.remove_absolute(scalar)
	assert(bridge._read_sys(scalar).is_empty())
	if FileAccess.file_exists("/sys/devices/system/cpu/online"):
		var online: String = bridge._read_sys("/sys/devices/system/cpu/online")
		assert(RegEx.create_from_string("^[0-9,-]+$").search(online) != null)
		print("PASS: sysfs scalar read excludes the unread page tail")
	var files: Array = bridge.get_files_in_dir(folder)
	assert(files == [{"name": "Game One.gba", "uri": folder.path_join("Game One.gba")}])
	files = bridge.get_files_in_dir(folder, true)
	assert(files.size() == 2)
	assert(files[1] == {"name": "Game Two.gba", "uri": folder.path_join("nested/Game Two.gba")})
	assert(bridge.get_files_in_dir(folder.path_join("missing"), true).is_empty())
	var nested: = folder.path_join("nested/Game Two.gba")
	var expected_meta: = {"size": 10, "md5": FileAccess.get_md5(nested)}
	assert(bridge.get_rom_metadata(folder, nested) == expected_meta)
	assert(bridge.get_rom_metadata(folder, "nested/Game Two.gba") == expected_meta)
	assert(bridge.get_rom_metadata(folder, "Game Two.gba") == {"size": 0, "md5": ""})
	if ResourceLoader.exists("res://scan_prefix.gd"):
		var scanner = load("res://scan_prefix.gd").new()
		scanner.FrontendBridge = bridge
		var platform: = {"rom_folder_path": folder.path_join("missing"), "games": [{"rom_name": "Keep Me"}], "model": {"id": "gba"}, "app_id": "", "scan_subfolders": true, "hide_duplicates": false}
		scanner.scan_platform_in_user(null, platform)
		assert(platform.games == [{"rom_name": "Keep Me"}])
		platform.rom_folder_path = nested
		scanner.scan_platform_in_user(null, platform)
		assert(platform.games == [{"rom_name": "Keep Me"}])
		platform.rom_folder_path = folder
		scanner.scan_platform_in_user(null, platform)
		assert(platform.games.size() == 2)
		assert(platform.games[0].rom_path == folder.path_join("Game One.gba"))
		assert(platform.games[1].rom_path == nested)
		assert(scanner.saved == 2)
	bridge.folder_selected.connect(func(path: String): selected.append(path))
	bridge.open_folder_picker(folder)
	var picker = bridge.get_node("FolderPicker")
	assert(picker.current_dir == folder)
	# A second request must not open a second modal window.
	bridge.open_folder_picker(folder)
	assert(bridge.get_child_count() == 2)
	picker._activate(3)
	assert(picker.current_dir == folder.path_join("nested"))
	var left: = InputEventAction.new()
	left.action = "ui_left"
	left.pressed = true
	picker._input(left)
	assert(picker.current_dir == folder)
	var down: = InputEventAction.new()
	down.action = "ui_down"
	down.pressed = true
	picker._input(down)
	assert(picker._folders.get_selected_items()[0] == 1)
	var accept: = InputEventAction.new()
	accept.action = "ui_accept"
	accept.pressed = true
	picker._input(accept)
	await process_frame
	assert(selected.is_empty())
	bridge.open_folder_picker(folder.path_join("nested"))
	picker = bridge.get_node("FolderPicker")
	picker._input(accept)
	await process_frame
	assert(selected == [folder.path_join("nested")])
	bridge.open_folder_picker("/does/not/exist")
	picker = bridge.get_node("FolderPicker")
	assert(DirAccess.dir_exists_absolute(picker.current_dir))
	var cancel: = InputEventAction.new()
	cancel.action = "ui_cancel"
	cancel.pressed = true
	picker._input(cancel)
	await process_frame
	assert(selected.size() == 1)
	var probe = load("res://input_probe.gd").new()
	probe.text = "Parent control"
	root.add_child(probe)
	probe.grab_focus()
	bridge.open_folder_picker(folder)
	await process_frame
	var joy: = InputEventJoypadButton.new()
	joy.button_index = JOY_BUTTON_A
	joy.pressed = true
	InputMap.action_add_event("ui_accept", joy)
	var cancel_joy: = InputEventJoypadButton.new()
	cancel_joy.button_index = JOY_BUTTON_B
	InputMap.action_add_event("ui_cancel", cancel_joy)
	Input.parse_input_event(joy)
	await process_frame
	await process_frame
	assert(selected == [folder.path_join("nested"), folder])
	assert(probe.presses == 0 and probe.accept_events == 0)
	joy.pressed = false
	Input.parse_input_event(joy)
	await process_frame
	bridge.open_folder_picker(folder)
	await process_frame
	joy = InputEventJoypadButton.new()
	joy.button_index = JOY_BUTTON_B
	joy.pressed = true
	Input.parse_input_event(joy)
	await process_frame
	await process_frame
	assert(selected.size() == 2)
	assert(not bridge.has_node("FolderPicker"))
	assert(probe.presses == 0 and probe.accept_events == 0)
	joy.pressed = false
	Input.parse_input_event(joy)
	probe.queue_free()
	bridge.queue_free()
	if ResourceLoader.exists("res://sound.gd"):
		await load("res://test_settings.gd").new().run(self)
	print("PASS: scan, nested metadata, folder navigation, Save/Cancel, Joypad routing and modal isolation")
	quit()
