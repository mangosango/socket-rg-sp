extends Node

# BaseOS replacement for Socket's Android FrontendPlugin bridge.
# It keeps the same API. Android-only features return their "no plugin" values.
# Keep the frontend loaded while the emulator owns the display and audio.

signal folder_selected(uri: String)
signal apps_changed
signal second_screen_freed

var installed_app_list: Dictionary = {}

var _run_dir: String = OS.get_environment("SOCKET_RUN") if OS.has_environment("SOCKET_RUN") else "/tmp/socket"
var _cores_dir: String = OS.get_environment("SOCKET_CORES") if OS.has_environment("SOCKET_CORES") else "/mnt/sdcard/System/socket/cores"
var _libretro_regex: = RegEx.create_from_string("-e LIBRETRO\\s+(\\S+)")
var _poweroff_poll: float = 0.0
var _playing: bool = false
var _clock_error_shown: bool = false
var _settings_poll: float = 0.0
var _settings_armed: bool = false
var _settings_epoch: int = -1
var _settings_count: int = 0
var _settings_format := RegEx.create_from_string("^([0-9]{1,18}) ([0-9]{1,9})\\n\\z")


func _enter_tree() -> void:
	get_tree().node_added.connect(_on_dialog_added)
	# Keep cartridge shadows without a 4096-pixel atlas on the handheld GPU.
	RenderingServer.directional_shadow_atlas_set_size(1024, true)
	AudioServer.set_bus_volume_db(0, -20.0)
	# A boot resume goes into the game at once. Keep the launcher silent until then.
	if OS.get_environment("SOCKET_RESUME_BOOT") == "1":
		AudioServer.set_bus_mute(0, true)


func _on_dialog_added(node: Node) -> void:
	if node is AcceptDialog:
		var controller := preload("res://addons/FrontendPlugin/controller_dialog.gd").new()
		controller.name = "ControllerDialog"
		node.add_child.call_deferred(controller)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var hud: = preload("res://addons/FrontendPlugin/controls_hud.gd").new()
	hud.name = "ControlsHUD"
	add_child(hud)
	if OS.get_name() == "Linux":
		var audio_route := preload("res://addons/FrontendPlugin/bluetooth_audio.gd").new()
		audio_route.name = "BluetoothAudio"
		add_child(audio_route)
	if OS.get_environment("SOCKET_RESUME_BOOT") == "1":
		_resume_boot_game.call_deferred()


# Start the resume record after the frontend loads. Leaving the game then uses
# the same fast resident return as a game started from the launcher.
func _resume_boot_game() -> void:
	OS.unset_environment("SOCKET_RESUME_BOOT")
	await get_tree().process_frame
	await get_tree().process_frame
	# A resumed game can hide fbdev; finish startup draws before launching it.
	while OS.get_name() == "Linux" and ResourceLoader.exists("res://addons/FrontendPlugin/shader_startup.gd"):
		var scene := get_tree().current_scene
		if scene == null or scene.scene_file_path not in ["res://scenes/boot.tscn", "res://scenes/main.tscn"]:
			break
		if get_tree().root.get_meta("socket_shader_startup_complete", false):
			break
		await get_tree().process_frame
	await _run_game("resume_game.sh", PackedStringArray(), "Resume")
	# The launcher did not start this session, so it must not count its playtime.
	DirAccess.remove_absolute(_run_dir.path_join("session_seconds"))
	if not _poweroff_ready():
		AudioServer.set_bus_mute(0, false)


# socket-hardware writes "<epoch> <count>" to settings.open: the number of
# MENU presses in the launcher since its last discard. A discard starts a new epoch.
# Return the number of presses that were not counted before, and count them.
# The file is only read and stays in place. Thus a press between two polls, or
# during a poll, is not lost and is not used two times.
func _new_menu_presses() -> int:
	var path := _run_dir.path_join("settings.open")
	if not FileAccess.file_exists(path):
		return 0
	var found := _settings_format.search(FileAccess.get_file_as_string(path))
	if found == null:
		return 0
	var epoch := found.get_string(1).to_int()
	var count := found.get_string(2).to_int()
	var counted := _settings_count if epoch == _settings_epoch and count >= _settings_count else 0
	_settings_epoch = epoch
	_settings_count = count
	return count - counted


# Each MENU press opens Device Settings, or closes it from each of its pages.
# Two presses between two polls open and close it: the state does not change.
# Discard the presses from before the end of startup.
func _poll_device_settings(delta: float) -> void:
	# During a game, RetroArch gets MENU and game_overlay.gd owns the panel.
	if _playing:
		return
	_settings_poll += delta
	if _settings_poll < 0.05:
		return
	_settings_poll = 0.0
	var ready: bool = get_tree().root.get_meta("socket_shader_startup_complete", false)
	var armed := _settings_armed
	# The first poll after startup only counts the presses. The next polls use them.
	_settings_armed = ready
	if _new_menu_presses() % 2 == 1 and armed and ready:
		var panel := get_tree().root.get_node_or_null("DeviceSettings")
		if panel != null:
			panel.menu_close()
		else:
			open_device_settings()


func open_device_settings() -> void:
	if _playing or get_tree().root.has_node("DeviceSettings"):
		return
	# A file dialog window gets the input and covers the panel. Do not open then.
	for window in get_tree().root.get_embedded_subwindows():
		if window.visible:
			return
	var panel = load("res://addons/FrontendPlugin/device_settings.gd").new()
	panel.name = "DeviceSettings"
	panel.hud = get_node("ControlsHUD")
	get_tree().root.add_child(panel)


func _process(delta: float) -> void:
	_poll_device_settings(delta)
	_poweroff_poll += delta
	if _poweroff_poll < 0.2 or _playing:
		return
	_poweroff_poll = 0.0
	if not _clock_error_shown and FileAccess.file_exists(_run_dir.path_join("wifi.clock-error")):
		_clock_error_shown = true
		var label := Label.new()
		label.text = "Clock sync failed. Check the device date and time."
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_constant_override("outline_size", 5)
		get_node("ControlsHUD").add_child(label)
		label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
		get_tree().create_timer(6.0).timeout.connect(label.queue_free)
	if _poweroff_ready():
		_quit_for_poweroff()


# Like Slot, a shutdown does not play launcher audio or show the launcher.
func _quit_for_poweroff() -> void:
	AudioServer.set_bus_mute(0, true)
	get_tree().quit()


func _poweroff_ready() -> bool:
	if not FileAccess.file_exists(_run_dir.path_join("poweroff.request")):
		return false
	var system: = OS.get_environment("SOCKET_SYSTEM")
	return not system.is_empty() and OS.execute("/bin/sh", PackedStringArray([system.path_join("poweroff_ready.sh"), "frontend"])) == 0


func open_folder_picker(start_path: String = "/mnt/sdcard") -> void:
	if has_node("FolderPicker"):
		return
	var picker = preload("res://addons/FrontendPlugin/folder_picker.gd").new()
	picker.name = "FolderPicker"
	add_child(picker)
	picker.folder_selected.connect(func(path: String): folder_selected.emit(path))
	picker.open(start_path)


func get_installed_app_list(_refresh: bool = false) -> Dictionary:
	return installed_app_list


func has_usage_access() -> bool:
	return false


func open_usage_access_settings() -> void:
	pass


# Seconds of the last game session, as measured by launch_frontend.sh.
func get_foreground_seconds(_package_name: String, since_seconds_ago: int) -> int:
	var path: = _run_dir.path_join("session_seconds")
	if not FileAccess.file_exists(path):
		return -1
	var seconds: = FileAccess.get_file_as_string(path).strip_edges().to_int()
	DirAccess.remove_absolute(path)
	return mini(seconds, since_seconds_ago)


func launch_app_with_params(_app_id: String, _params: Dictionary, _screen: String = "") -> void:
	pass


func get_app_activities(_package_name: String) -> Array:
	return []


func open_app_info(_package_name: String) -> void:
	pass


func uninstall_app(_package_name: String) -> void:
	pass


# Return the libretro core name in Daijishou "am start" arguments when that
# core is on the card. Return "" for other emulators.
func libretro_core(am_start_arguments: String) -> String:
	var found: = _libretro_regex.search(am_start_arguments)
	if found == null:
		return ""
	var core: = found.get_string(1).get_file().trim_suffix("_libretro_android.so")
	return core if FileAccess.file_exists(_cores_dir.path_join(core + "_libretro.so")) else ""


# params: {"core": String, "rom": String, "platform": String}
func launch_emulator(params: Dictionary) -> void:
	await _run_game("play_game.sh", PackedStringArray([str(params.get("core", "")),
		str(params.get("rom", "")), str(params.get("platform", ""))]), "RetroArch")


func _run_game(script: String, arguments: PackedStringArray, label: String) -> void:
	if _playing:
		return
	DirAccess.make_dir_recursive_absolute(_run_dir)
	var system: String = OS.get_environment("SOCKET_SYSTEM")
	if system.is_empty() or DisplayServer.get_name() != "fbdev":
		push_error("FrontendBridge: resident launch needs the fbdev display and SOCKET_SYSTEM")
		return
	_playing = true
	var audio_route := get_node_or_null("BluetoothAudio")
	if audio_route:
		audio_route.release()
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_MINIMIZED:
		_playing = false
		push_error("FrontendBridge: could not release the display")
		return
	var manager = get_node_or_null("/root/Manager")
	if manager:
		manager.notification(NOTIFICATION_APPLICATION_PAUSED)
	OS.set_environment("SOCKET_FRONTEND_PID", str(OS.get_process_id()))
	var command: = PackedStringArray([system.path_join(script)])
	command.append_array(arguments)
	# The engine sets this mark when it has a GL context without the display.
	# Without it, no GL call is safe during the game: wait in one blocking call.
	var status: int
	if OS.get_environment("SOCKET_GAME_OVERLAY_EGL") == "1":
		status = await _play_with_menu(command)
	else:
		status = OS.execute("/bin/sh", command)
	var returned: = Time.get_ticks_msec()
	# A MENU press from the game session must not open Device Settings now.
	_new_menu_presses()
	# A saved game shutdown quits before the display and audio return.
	if _poweroff_ready():
		_quit_for_poweroff()
		return
	var pid_file: = FileAccess.open(_run_dir.path_join("app.pid.new"), FileAccess.WRITE)
	if pid_file:
		pid_file.store_line(str(OS.get_process_id()))
		pid_file.close()
		DirAccess.rename_absolute(_run_dir.path_join("app.pid.new"), _run_dir.path_join("app.pid"))
	get_node("ControlsHUD").sync_after_game()
	# The frame-rate record ignores the time of the game.
	get_tree().root.set_meta("socket_game_return_usec", Time.get_ticks_usec())
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
	_playing = false
	if manager:
		manager.notification(NOTIFICATION_APPLICATION_RESUMED)
	_log_return.call_deferred(returned)
	if status != 0:
		DirAccess.remove_absolute(_run_dir.path_join("poweroff.request"))
		DirAccess.remove_absolute(_run_dir.path_join("poweroff.ack"))
		push_error("%s exited with status %d; see Logs/socket-game.log" % [label, status])
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED:
		get_tree().quit(1)
	elif _poweroff_ready():
		_quit_for_poweroff()


# Run the game while the main loop continues at a low rate. game_overlay.gd
# shows Device Settings when RetroArch asks for it. Launcher nodes do not run,
# and only the menu SubViewport draws.
func _play_with_menu(command: PackedStringArray) -> int:
	var tree := get_tree()
	var was_paused := tree.paused
	tree.paused = true
	# An inactive root viewport also stops the menu SubViewport. Keep it active
	# with no content.
	var root_3d := tree.root.disable_3d
	tree.root.disable_3d = true
	RenderingServer.viewport_set_disable_2d(tree.root.get_viewport_rid(), true)
	var views: Dictionary = {}
	for view in tree.root.find_children("*", "SubViewport", true, false):
		views[view] = view.render_target_update_mode
		view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var overlay := preload("res://addons/FrontendPlugin/game_overlay.gd").new()
	overlay.name = "GameOverlay"
	overlay.hud = get_node("ControlsHUD")
	add_child(overlay)
	var status := 1
	var pid := OS.create_process("/bin/sh", command)
	if pid > 0:
		while OS.is_process_running(pid):
			await tree.process_frame
		status = OS.get_process_exit_code(pid)
		# No exit code: do not report a success.
		if status < 0:
			status = 1
	overlay.stop()
	overlay.free()
	for view in views:
		if is_instance_valid(view):
			view.render_target_update_mode = views[view]
	RenderingServer.viewport_set_disable_2d(tree.root.get_viewport_rid(), false)
	tree.root.disable_3d = root_3d
	tree.paused = was_paused
	return status


func is_second_screen_usable() -> bool:
	return false


func kill_package_processes(_package_name: String) -> void:
	pass


func get_sdk_version() -> int:
	return 0


func show_second_screen_hold(_image_path: String, _dim: float, _show_timer: bool, _title: String = "") -> bool:
	return false


func hide_second_screen_hold() -> void:
	pass


func get_rom_metadata(folder_path: String, file_path_or_uri: String) -> Dictionary:
	var path: = file_path_or_uri if file_path_or_uri.is_absolute_path() else folder_path.path_join(file_path_or_uri)
	if not FileAccess.file_exists(path):
		return {"size": 0, "md5": ""}
	return {"size": FileAccess.get_size(path), "md5": FileAccess.get_md5(path)}


func is_default_launcher() -> bool:
	return true


func open_home_settings() -> void:
	pass


func get_battery_status() -> Dictionary:
	for supply in DirAccess.get_directories_at("/sys/class/power_supply"):
		var dir: = "/sys/class/power_supply".path_join(supply)
		if _read_sys(dir.path_join("type")) != "Battery":
			continue
		var status: = _read_sys(dir.path_join("status"))
		return {
			"percentage": _read_sys(dir.path_join("capacity")).to_float(),
			"is_charging": status == "Charging" or status == "Full",
		}
	return {"percentage": 100.0}


func get_network_status() -> Dictionary:
	var ready := FileAccess.file_exists(_run_dir.path_join("wifi.ready"))
	# Each service checks reachability with its own request.
	return {"type": "wifi" if ready else "none", "internet": false}


func get_files_in_dir(uri_string: String, recursive: bool = false) -> Array:
	var files: Array = []
	var dir: = DirAccess.open(uri_string)
	if dir == null:
		return files
	for file_name in dir.get_files():
		files.append({"name": file_name, "uri": uri_string.path_join(file_name)})
	if recursive:
		for folder in dir.get_directories():
			# Do not follow links back into a folder that was already scanned.
			if not dir.is_link(folder):
				files.append_array(get_files_in_dir(uri_string.path_join(folder), true))
	return files


func _read_sys(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file: = FileAccess.open(path, FileAccess.READ)
	# Sysfs reports a page size, not the length of its text.
	return file.get_line().strip_edges() if file != null else ""


# Record the time from game exit to the first launcher frame, for device checks.
func _log_return(returned: int) -> void:
	await RenderingServer.frame_post_draw
	print("FrontendBridge: first launcher frame %d ms after the game script returned" % (Time.get_ticks_msec() - returned))
