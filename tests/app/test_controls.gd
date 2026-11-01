extends RefCounted


func run(tree: SceneTree, bridge: Node) -> void:
	var hud = bridge.get_node("ControlsHUD")
	assert(is_equal_approx(AudioServer.get_bus_volume_linear(0), 0.1))
	assert(hud._icons.size() == 4)
	assert(hud.layer == 128 and hud._view.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	AudioServer.add_bus()
	var sfx: = AudioServer.bus_count - 1
	AudioServer.set_bus_mute(sfx, true)
	var path: String = OS.get_environment("SOCKET_RUN").path_join("controls")
	write(path, "2 0 50 4 0 0\n")
	await tree.create_timer(0.08).timeout
	assert(hud._sequence == 0 and hud._shown_at == -1500 and not hud._view.visible)
	assert(is_equal_approx(AudioServer.get_bus_volume_linear(0), 0.25))
	write(path, "2 1 55 4 0 1\n")
	await tree.create_timer(0.08).timeout
	assert(hud._sequence == 1 and hud._kind == 1 and hud._view.visible)
	assert(is_equal_approx(AudioServer.get_bus_volume_linear(0), 0.3025))
	var pulse: = InputEventJoypadButton.new()
	pulse.button_index = JOY_BUTTON_PADDLE1
	pulse.pressed = true
	Input.parse_input_event(pulse)
	await tree.process_frame
	assert(is_equal_approx(AudioServer.get_bus_volume_linear(0), 0.3025))
	var shown: int = hud._shown_at
	for invalid in ["2 2 101 4 0 1\n", "2 2 50 4 0 4\n", "2 2 50 4 10 1\n", "1 2 50 4 1\n", "2 4294967296 50 4 0 1\n", "2 2 50 4 0 1\nextra", "2 2 50 4 0 1", "2 2 -1 4 0 1\n", "2 2 50 4 0 1\n\n"]:
		write(path, invalid)
		await tree.create_timer(0.06).timeout
		assert(hud._sequence == 1 and hud._shown_at == shown)
	write(path, "2 6 55 4 7 3\n")
	await tree.create_timer(0.08).timeout
	assert(hud._sequence == 6 and hud._kind == 3 and hud._temperature == 7 and hud._tint.visible and hud._view.visible)
	write(path, "2 7 55 4 0 3\n")
	await tree.create_timer(0.08).timeout
	assert(hud._temperature == 0 and not hud._tint.visible)
	write(path, "2 1 55 4 0 1\n")
	await tree.create_timer(0.08).timeout
	hud._sequence = 1
	shown = hud._shown_at
	tree.paused = true
	write(path, "2 2 0 9 0 2\n")
	await tree.create_timer(0.08).timeout
	assert(hud._kind == 2 and hud._brightness == 9)
	tree.paused = false
	assert(AudioServer.get_bus_volume_linear(0) == 0.0)
	assert(AudioServer.is_bus_mute(sfx) and not AudioServer.is_bus_mute(0))
	# The game changes volume while the frontend cannot poll controls.
	hud.set_process(false)
	write(path, "2 3 80 9 0 1\n")
	hud.sync_after_game()
	assert(hud._sequence == 3 and not hud._view.visible and hud._shown_at == -1500)
	assert(is_equal_approx(AudioServer.get_bus_volume_linear(0), 0.64))
	assert(AudioServer.is_bus_mute(sfx))
	hud.set_process(true)
	await tree.create_timer(0.08).timeout
	assert(not hud._view.visible)
	write(path, "2 4 85 9 0 1\n")
	await tree.create_timer(0.08).timeout
	assert(hud._sequence == 4 and hud._view.visible)
	assert(is_equal_approx(AudioServer.get_bus_volume_linear(0), 0.7225))
	write(path, "2 5 0 9 0 1\n")
	hud.sync_after_game()
	assert(AudioServer.get_bus_volume_linear(0) == 0.0 and not hud._view.visible)
	assert(AudioServer.is_bus_mute(sfx))
	AudioServer.remove_bus(sfx)
	hud._shown_at = Time.get_ticks_msec() - 1600
	await tree.process_frame
	assert(not hud._view.visible)
	write(path, "2 99 70 4 0 1\n")
	var fresh = load("res://addons/FrontendPlugin/controls_hud.gd").new()
	bridge.add_child(fresh)
	assert(fresh._sequence == 99 and fresh._shown_at == -1500 and not fresh._view.visible)
	assert(is_equal_approx(AudioServer.get_bus_volume_linear(0), 0.49))
	fresh.queue_free()
	await tree.process_frame
	DirAccess.remove_absolute(path)
	print("PASS: controls file polling, squared gain, initial and resume HUD suppression, next adjustment, validation, brightness, temperature, mute isolation")


func write(path: String, record: String) -> void:
	var file: = FileAccess.open(path + ".tmp", FileAccess.WRITE)
	file.store_string(record)
	file.close()
	assert(DirAccess.rename_absolute(path + ".tmp", path) == OK)
