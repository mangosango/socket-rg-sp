extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func require(ok: bool, message: String) -> bool:
	if not ok:
		printerr("FAIL: resident ", message)
		quit(1)
	return ok

func _run() -> void:
	if not require(DisplayServer.get_name() == "fbdev", "uses the real fbdev display server"): return
	OS.low_processor_usage_mode = false
	var result: = OS.get_environment("SOCKET_RESIDENT_RESULT")
	if not result.is_empty():
		await _run_result(result)
		return
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = DisplayServer.window_get_size()
	var image: = Image.create(32, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.8, 0.2, 0.4))
	var texture: = ImageTexture.create_from_image(image)
	var rect: = TextureRect.new()
	rect.texture = texture
	rect.size = Vector2(DisplayServer.window_get_size())
	root.add_child(rect)
	for i in range(3): await RenderingServer.frame_post_draw
	var rid: = texture.get_rid()
	var pid: = OS.get_process_id()
	var hud = root.get_node("FrontendBridge/ControlsHUD")
	var sfx: = AudioServer.get_bus_index("sfx")
	if not require(sfx > 0 and AudioServer.is_bus_mute(sfx), "UI sounds start muted"): return
	if not require(is_equal_approx(AudioServer.get_bus_volume_db(sfx), 0.0), "UI bus uses shared Master gain"): return
	for cycle in range(3):
		# Launch from processing, outside the renderer's post-draw signal.
		await process_frame
		root.get_node("FrontendBridge").launch_emulator({"core": "test", "rom": "fixture", "platform": "gb"})
		if not require(FileAccess.get_file_as_string(OS.get_environment("SOCKET_RUN").path_join("child-ok")).count("ok\n") == cycle + 1, "RetroArch child succeeds"): return
		if not require(hud._sequence == cycle and not hud._view.visible and hud._shown_at == -1500, "game controls synchronize without a HUD"): return
		if not require(is_equal_approx(AudioServer.get_bus_volume_linear(0), 0.64) and AudioServer.is_bus_mute(sfx), "game gain synchronizes and UI mute survives"): return
		if not require(DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN, "display resumes"): return
		if not require(OS.get_process_id() == pid and texture.get_rid() == rid, "process and texture survive"): return
		# The EGL shim checks framebuffer zero before the first resumed swap.
		for i in range(3): await RenderingServer.frame_post_draw
		if not require(FileAccess.get_file_as_string(OS.get_environment("SOCKET_RUN").path_join("app.pid")).strip_edges() == str(pid), "resident PID is restored"): return
	var controls: = OS.get_environment("SOCKET_RUN").path_join("controls")
	var file: = FileAccess.open(controls, FileAccess.WRITE)
	file.store_string("2 3 85 4 0 1\n")
	file.close()
	hud._poll()
	hud._process(0.0)
	if not require(hud._sequence == 3 and hud._view.visible and is_equal_approx(AudioServer.get_bus_volume_linear(0), 0.7225), "next real volume adjustment shows HUD and updates gain"): return
	if not require(AudioServer.is_bus_mute(sfx), "next adjustment preserves UI mute"): return
	print("PASS: resident fbdev bridge, child process, three EGL surface releases, retained texture and first resumed frame")
	quit()

func _run_result(result: String) -> void:
	var bridge: = root.get_node("FrontendBridge")
	if result == "resume":
		var marker: = OS.get_environment("SOCKET_RUN").path_join("resume-ran")
		for i in range(120):
			if FileAccess.file_exists(marker) and not bridge._playing:
				break
			await process_frame
		if not require(FileAccess.get_file_as_string(marker) == "resumed\n", "boot resume runs the record once"): return
		if not require(DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN, "boot resume returns to the resident frontend"): return
		if not require(not AudioServer.is_bus_mute(0), "boot resume restores frontend audio"): return
		if not require(not FileAccess.file_exists(OS.get_environment("SOCKET_RUN").path_join("session_seconds")), "boot resume does not count launcher playtime"): return
		for i in range(3): await RenderingServer.frame_post_draw
		print("PASS: resident boot resume starts after the frontend and returns without a cold load")
		quit()
		return
	if result == "success" or result == "crashacked": bridge.set_process(false)
	bridge.launch_emulator({"core": "test", "rom": "fixture", "platform": "gb"})
	var request: = OS.get_environment("SOCKET_RUN").path_join("poweroff.request")
	# A crash after the acknowledged save also powers off; the save is durable.
	if result == "success" or result == "crashacked":
		# Like Slot, an acknowledged shutdown save quits without the launcher frame or audio.
		if not require(DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED, "acknowledged poweroff keeps the display released"): return
		if not require(AudioServer.is_bus_mute(0), "acknowledged poweroff mutes the frontend"): return
		if not require(FileAccess.file_exists(request), "successful child keeps the poweroff request"): return
		print("PASS: resident acknowledged poweroff quits without restoring display or audio")
		await create_timer(0.7).timeout
		printerr("FAIL: resident successful poweroff request did not quit")
		quit(1)
		return
	if not require(DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN and not bridge._playing, "result restores the display and clears playing"): return
	if result == "unacked":
		await create_timer(0.4).timeout
		if not require(FileAccess.file_exists(request) and not bridge._poweroff_ready(), "unacknowledged request keeps frontend running"): return
		print("PASS: resident unacknowledged request does not quit frontend")
		quit()
	elif result == "failure":
		if not require(not FileAccess.file_exists(request), "failed child removes the poweroff request"): return
		await create_timer(0.4).timeout
		print("PASS: resident failed child removes poweroff request and keeps frontend running")
		quit()
