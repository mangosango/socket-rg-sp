# The launcher side of the shared menu test. The packed resident frontend
# starts one game with the real RetroArch and shows Device Settings for it.
# Run with tests/app/run_shared_menu.py. The probe of that file does the checks
# of the game side.
extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func require(ok: bool, message: String) -> bool:
	if not ok:
		printerr("FAIL: shared menu ", message)
		quit(1)
	return ok

func _run() -> void:
	if not require(DisplayServer.get_name() == "fbdev", "uses the real fbdev display server"): return
	var run_dir := OS.get_environment("SOCKET_RUN")
	# The card setting dark_mode=true comes from settings.cfg, not from this script.
	var palette = load("res://scripts/theme_palette.gd").active()
	if not require(palette.dark == (OS.get_environment("SOCKET_TEST_DARK") == "true"), "palette follows the requested theme"): return
	var surface: Color = palette.recolor_surface(Color.WHITE)
	var file := FileAccess.open(run_dir.path_join("expected.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"surface": [surface.r8, surface.g8, surface.b8]}))
	file.close()
	# The pack keeps its low processor mode: no change gives no draw. Do not
	# wait for a draw. Launch from processing.
	for i in range(3): await process_frame
	var bridge := root.get_node("FrontendBridge")
	await bridge.launch_emulator({"core": "test", "rom": "fixture", "platform": "gba"})
	if not require(OS.get_environment("SOCKET_GAME_OVERLAY_EGL") == "1", "the engine kept a GL context during the game"): return
	if not require(FileAccess.get_file_as_string(run_dir.path_join("child-ok")) == "ok\n", "the RetroArch probe succeeds"): return
	if not require(not root.has_node("DeviceSettings") and not bridge.has_node("GameOverlay"), "the menu scene is gone after the game"): return
	if not require(not paused and not bridge._playing, "the launcher runs again"): return
	if not require(DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN, "display resumes"): return
	for i in range(3): await process_frame
	print("PASS: shared menu launcher showed Device Settings for one real RetroArch game and resumed")
	quit()
