extends SceneTree

# Smoke test for a pack built from Socket 0.3.2. Run it with run_packed.sh.

var checked: int = 0

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
	var manager = root.get_node("Manager")
	var bridge = root.get_node("FrontendBridge")
	# Record launch requests instead of starting RetroArch.
	var recorder: = GDScript.new()
	recorder.source_code = "extends \"res://addons/FrontendPlugin/frontend_bridge.gd\"\nvar launched: Dictionary = {}\nfunc launch_emulator(params: Dictionary) -> void:\n\tlaunched = params\n"
	recorder.reload()
	bridge.set_script(recorder)
	root.size = Vector2i(720, 480)
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	for i in range(30): await process_frame

	# The RG SP panel is 720x480 and the layout is 1920x1280.
	var layer = root.get_node("Main/CanvasLayer")
	if not require(not layer.get_node("BottomScreen").visible and layer.get_node("BottomScreen/SubViewport").render_target_update_mode == SubViewport.UPDATE_DISABLED, "AYN Thor bottom screen does not render"): return
	var ui: SubViewport = layer.get_node("MainScreen/SubViewport")
	var ui_container: SubViewportContainer = layer.get_node("MainScreen")
	if not require(ui.size == Vector2i(720, 480) and ui.size_2d_override == Vector2i(1920, 1280) and ui.size_2d_override_stretch, "UI renders at 720x480 with the 1920x1280 layout"): return
	if not require(not ui_container.stretch and ui_container.scale.is_equal_approx(Vector2(1920.0 / 720.0, 1280.0 / 480.0)), "UI texture covers the panel 1:1"): return
	# A click at the panel center reaches the center of the logical layout.
	var probe: = Control.new()
	probe.set_anchors_preset(Control.PRESET_FULL_RECT)
	var clicked: = [Vector2(-1, -1)]
	probe.gui_input.connect(func(event): if event is InputEventMouseButton: clicked[0] = event.position)
	ui.add_child(probe)
	await process_frame
	var click: = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(360, 240)
	click.global_position = click.position
	root.push_input(click)
	await process_frame
	probe.queue_free()
	if not require(clicked[0].is_equal_approx(Vector2(960, 640)), "panel input maps to the logical layout: " + str(clicked[0])): return
	var view: SubViewport = root.find_children("*", "SubViewport", true, false).filter(func(node): return node.get_script() != null and node.get_script().resource_path == "res://scenes/render_scale_3d.gd")[0]
	if not require(view.size == Vector2i(480, 320) and is_equal_approx(view.scaling_3d_scale, 1.0), "3D renders at 480x320, 2/3 of the panel"): return
	if not require(view.get_parent().material is ShaderMaterial and view.get_parent().material.shader.resource_path == "res://shaders/display_aa.gdshader", "3D view uses the display edge filter"): return
	root.size = Vector2i(1440, 960)
	for i in range(3): await process_frame
	if not require(view.size == Vector2i(960, 640) and ui.size == Vector2i(1440, 960), "UI and 3D sizes follow a window change"): return
	# A window larger than the layout keeps the stretched layout-size viewport.
	root.size = Vector2i(3840, 2560)
	for i in range(5): await process_frame
	if not require(ui_container.stretch and ui_container.scale == Vector2.ONE and ui.size == Vector2i(1920, 1280) and ui_container.size == Vector2(1920, 1280), "large window keeps a stable layout-size UI"): return
	root.size = Vector2i(720, 480)
	for i in range(3): await process_frame
	if not require(not ui_container.stretch and ui.size == Vector2i(720, 480) and ui_container.size == Vector2(1920, 1280), "UI returns to panel pixels"): return

	var platform = load("res://scripts/platform.gd").new()
	platform.model = manager.db.get_platform("gba").new()
	var apps: Array = manager.get_available_apps_for_platform(platform.model)
	if not require(not apps.is_empty(), "a RetroArch entry is offered when its core is on the card"): return
	for app in apps:
		var entry: Dictionary = manager._get_app_by_id(platform.model, app.id)
		if not require(bridge.libretro_core(entry.get("amStartArguments", "")) == "mgba", "only entries with an installed core are offered: " + app.id): return
	platform.app_id = apps[0].id
	platform.rom_folder_path = OS.get_environment("SOCKET_TEST_ROOT")
	manager.add_platform_to_user(manager.current_user, platform)

	# Artwork and metadata cached by the Mac setup tool.
	var artwork: = Image.create(2, 2, false, Image.FORMAT_RGBA8)
	artwork.fill(Color.RED)
	DirAccess.make_dir_recursive_absolute("user://scraped_data/gba")
	artwork.save_png("user://scraped_data/gba/One_support.png")
	var metadata: = FileAccess.open("user://scraped_data/gba/One.json", FileAccess.WRITE)
	metadata.store_string(JSON.stringify({"name": "Mac One"}))
	metadata.close()

	var scrape_started: = [false]
	manager.scrape_started.connect(func(_total): scrape_started[0] = true)
	await manager.scan_platform_in_user(manager.current_user, platform)
	if not require(platform.games.size() == 2, "offline scan finds both ROMs"): return
	if not require(not scrape_started[0] and manager._active_scraper == null, "scan starts no network scraper"): return
	var one = null
	for game in platform.games:
		if game.rom_name == "One":
			one = game
	if not require(one != null and one.title == "Mac One" and one.support_image != null, "cached metadata and artwork load offline"): return

	var editor = load("res://scripts/screens/screen.gd").get_screen("edit_platform")
	if not require(editor != null, "platform editor exists"): return
	editor.set_platform(platform)
	editor.rom_folder_path = ""
	editor._on_button_scan_pressed()
	if not require(platform.rom_folder_path == OS.get_environment("SOCKET_TEST_ROOT"), "Scan without a folder keeps the saved folder"): return

	manager.launch_game(one)
	if not require(bridge.launched == {"core": "mgba", "rom": one.rom_path, "platform": "gba"}, "launch requests RetroArch with the mGBA core"): return
	print("PASS: Socket 0.3.2 pack offline scan, emulator list and RetroArch launch (", checked, " checks)")
	quit(0)
