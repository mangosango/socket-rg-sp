extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var manager = root.get_node("Manager")
	var bridge = root.get_node("FrontendBridge")
	var recorder := GDScript.new()
	recorder.source_code = "extends \"res://addons/FrontendPlugin/frontend_bridge.gd\"\nvar launched: Dictionary = {}\nfunc launch_emulator(params: Dictionary) -> void:\n\tlaunched = params\n"
	recorder.reload()
	bridge.set_script(recorder)
	manager.load_user()
	var platforms: Array = manager.current_user.added_platforms
	if platforms.size() != 3:
		printerr("FAIL: fresh library should load three platforms")
		quit(1)
		return
	for platform in platforms:
		var id: String = platform.model.id
		var folder := "Games/" + id.to_upper()
		var entry: Dictionary = manager._get_app_by_id(platform.model, platform.app_id)
		if not platform.visible or platform.rom_folder_path != "/mnt/sdcard/" + folder or bridge.libretro_core(entry.get("amStartArguments", "")) != "mgba":
			printerr("FAIL: first boot emulator or folder for ", id)
			quit(1)
			return
		# The temporary test card isn't mounted at the device's /mnt/sdcard.
		platform.rom_folder_path = OS.get_environment("SOCKET_RUN").path_join(folder)
		await manager.scan_platform_in_user(manager.current_user, platform)
		if platform.games.size() != 1 or platform.games[0].rom_name != "One" or manager._active_scraper != null:
			printerr("FAIL: first boot offline scan for ", id)
			quit(1)
			return
		manager.launch_game(platform.games[0])
		if bridge.launched != {"core": "mgba", "platform": id, "rom": platform.games[0].rom_path}:
			printerr("FAIL: launch request for ", id)
			quit(1)
			return
	print("PASS: first boot library loads, scans and requests mGBA for GB, GBC and GBA offline")
	quit(0)
