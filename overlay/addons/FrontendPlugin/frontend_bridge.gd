extends Node

# BaseOS replacement for Socket's Android FrontendPlugin bridge.
# It keeps the same API. Android-only features return their "no plugin" values.
# Keep the frontend loaded while the emulator owns the display and audio.

signal folder_selected(uri: String)
signal apps_changed

var installed_app_list: Dictionary = {}

var _run_dir: String = OS.get_environment("SOCKET_RUN") if OS.has_environment("SOCKET_RUN") else "/tmp/socket"
var _cores_dir: String = OS.get_environment("SOCKET_CORES") if OS.has_environment("SOCKET_CORES") else "/mnt/sdcard/System/socket/cores"
var _libretro_regex: = RegEx.create_from_string("-e LIBRETRO\\s+(\\S+)")
var _poweroff_poll: float = 0.0
var _playing: bool = false


func _enter_tree() -> void:
	# Keep cartridge shadows without a 4096-pixel atlas on the handheld GPU.
	RenderingServer.directional_shadow_atlas_set_size(1024, true)
	AudioServer.set_bus_volume_db(0, -20.0)
	# A boot resume goes into the game at once. Keep the launcher silent until then.
	if OS.get_environment("SOCKET_RESUME_BOOT") == "1":
		AudioServer.set_bus_mute(0, true)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var hud: = preload("res://addons/FrontendPlugin/controls_hud.gd").new()
	hud.name = "ControlsHUD"
	add_child(hud)
	if OS.get_environment("SOCKET_RESUME_BOOT") == "1":
		_resume_boot_game.call_deferred()


# Start the resume record after the frontend loads. Leaving the game then uses
# the same fast resident return as a game started from the launcher.
func _resume_boot_game() -> void:
	OS.unset_environment("SOCKET_RESUME_BOOT")
	await get_tree().process_frame
	await get_tree().process_frame
	_run_game("resume_game.sh", PackedStringArray(), "Resume")
	# The launcher did not start this session, so it must not count its playtime.
	DirAccess.remove_absolute(_run_dir.path_join("session_seconds"))
	if not _poweroff_ready():
		AudioServer.set_bus_mute(0, false)


func _process(delta: float) -> void:
	_poweroff_poll += delta
	if _poweroff_poll < 0.2 or _playing:
		return
	_poweroff_poll = 0.0
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


func launch_app_with_params(_app_id: String, _params: Dictionary) -> void:
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
	_run_game("play_game.sh", PackedStringArray([str(params.get("core", "")),
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
	var status: int = OS.execute("/bin/sh", command)
	var returned: = Time.get_ticks_msec()
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


func show_second_screen_hold(_image_path: String, _dim: float, _show_timer: bool) -> bool:
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
	var up: = _read_sys("/sys/class/net/wlan0/operstate") == "up"
	return {"type": "wifi" if up else "none", "internet": up}


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
