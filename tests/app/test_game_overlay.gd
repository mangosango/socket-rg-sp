extends SceneTree

# Device Settings during a game. This script does the work of RetroArch: it
# writes menu.input and reads menu.frame and menu.event.

# Like Socket's GUIDE node: it makes ui_accept and ui_cancel from A and B.
class Guide extends Node:
	func inject_input(event: InputEvent) -> void:
		if event is InputEventJoypadButton and event.button_index in [JOY_BUTTON_A, JOY_BUTTON_B]:
			var made := InputEventAction.new()
			made.action = "ui_accept" if event.button_index == JOY_BUTTON_A else "ui_cancel"
			made.pressed = event.pressed
			Input.parse_input_event(made)

var run_dir: String = OS.get_environment("SOCKET_RUN")
var evidence: String = OS.get_environment("SOCKET_EVIDENCE")
var log_text := ""


func _initialize() -> void:
	_run.call_deferred()


func wait(seconds: float) -> void:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame


# RetroArch appends lines to menu.input.
func send(text: String, settle: float = 0.3) -> void:
	log_text += text
	var file := FileAccess.open(run_dir.path_join("menu.input"), FileAccess.WRITE)
	file.store_string(log_text)
	file.close()
	await wait(settle)


func press(pad_name: String) -> void:
	await send("pad %s 1\n" % pad_name, 0.1)
	await send("pad %s 0\n" % pad_name)


func hex(text: String) -> String:
	return text.to_utf8_buffer().hex_encode()


# Return the header fields and the image of menu.frame.
func frame() -> Dictionary:
	var data := FileAccess.get_file_as_bytes(run_dir.path_join("menu.frame"))
	assert(data.size() >= 28 and data.slice(0, 4).get_string_from_ascii() == "SKMF" and data.decode_u32(4) == 1)
	var width := data.decode_u32(16)
	var height := data.decode_u32(20)
	assert(data.size() == 28 + width * height * 4 and data.decode_u32(24) & 0xff == 1)
	return {"id": data.decode_u32(8), "number": data.decode_u32(12), "views": data.decode_u32(24) >> 8,
		"image": Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data.slice(28))}


# Save the frame as RetroArch shows it: above a game picture.
func save(file_name: String) -> void:
	if evidence.is_empty():
		return
	var image: Image = frame().image
	var shown := Image.create(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8)
	for y in image.get_height():
		for x in image.get_width():
			var game := Color(0.2, 0.7, 0.3) if (x / 40 + y / 40) % 2 == 0 else Color(0.9, 0.8, 0.2)
			var pixel := image.get_pixel(x, y)
			shown.set_pixel(x, y, Color(pixel.r + game.r * (1.0 - pixel.a), pixel.g + game.g * (1.0 - pixel.a), pixel.b + game.b * (1.0 - pixel.a)))
	shown.save_png(evidence.path_join(file_name))


func _run() -> void:
	root.size = Vector2i(720, 480)
	var guide := Guide.new()
	guide.name = "GUIDE"
	root.add_child(guide)
	var launcher := Button.new()
	launcher.text = "Launcher"
	root.add_child(launcher)
	launcher.grab_focus()
	var view := SubViewport.new()
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var bridge: Node = load("res://addons/FrontendPlugin/frontend_bridge.gd").new()
	bridge.name = "FrontendBridge"
	root.add_child(bridge)
	await wait(0.2)
	var sleep_usec := OS.low_processor_usage_mode_sleep_usec

	# A menu.input from the game before must not open a panel.
	var stale := FileAccess.open(run_dir.path_join("menu.input"), FileAccess.WRITE)
	stale.store_string("session 1-1\nopen 9\n")
	stale.close()
	var game := run_dir.path_join("game.sh")
	var script := FileAccess.open(game, FileAccess.WRITE)
	script.store_string("while [ ! -e '%s' ] && kill -0 $PPID 2>/dev/null; do sleep 0.05; done\nexit 7\n" % run_dir.path_join("game.stop"))
	script.close()
	var result: Array[int] = []
	var play := func() -> void: result.append(await bridge._play_with_menu(PackedStringArray([game])))
	play.call()
	await wait(0.3)
	var overlay: Node = bridge.get_node("GameOverlay")
	assert(result.is_empty() and paused and not root.has_node("DeviceSettings"))
	assert(view.render_target_update_mode == SubViewport.UPDATE_DISABLED)
	assert(OS.low_processor_usage_mode_sleep_usec == overlay.IDLE_USEC)
	assert(not FileAccess.file_exists(run_dir.path_join("menu.input")))
	print("PASS: game start")

	# MENU: the panel of the launcher, with the game rows. Game has the focus.
	await send("session 77-1 2\nopen 1\n", 0.6)
	var panel: Node = root.get_node("DeviceSettings")
	assert(panel.game and panel._rows.keys() == ["Brightness", "Volume", "Wi-Fi", "Bluetooth", "Game", "Cheats"])
	assert(panel._gui.gui_get_focus_owner().name == "Game")
	assert(OS.low_processor_usage_mode_sleep_usec == overlay.MENU_USEC)
	var first := frame()
	assert(first.id == 1 and first.number >= 1 and first.image.get_size() == Vector2i(720, 480))
	# The corner is the dimmer. The center is the opaque panel surface.
	var corner: Color = first.image.get_pixel(4, 4)
	assert(corner.r == 0.0 and absf(corner.a - 0.6) < 0.02)
	assert(first.image.get_pixel(360, 80).a == 1.0)
	save("game-menu-root.png")
	# The pages of RetroArch get the colors and the rectangle of the panel.
	var card: Rect2 = panel._card.get_global_rect()
	var look := FileAccess.get_file_as_string(run_dir.path_join("menu.theme")).strip_edges().split(" ")
	assert(look.size() == 8 and look[0] == "2" and look[1] == "ffffff" and look[2] == "212121" and look[7] == "18")
	assert(look[3].to_int() == int(card.position.x) and look[5].to_int() == int(card.size.x) and look[6].to_int() == int(card.size.y))
	# No new frame while the pixels stay the same.
	await wait(0.5)
	assert(frame().number == first.number)
	print("PASS: first frame %d, no frame while idle" % first.number)

	# The pad lines move the focus. A on a game row sends its event.
	await press("down")
	assert(panel._gui.gui_get_focus_owner().name == "Cheats" and frame().number > first.number)
	await press("a")
	assert(FileAccess.get_file_as_string(run_dir.path_join("menu.event")) == "1 1 cheats\n")
	await press("up")
	# RetroArch reads the event a short time later. A press in that time is not used.
	await send("pad a 1\n", 0.1)
	await send("pad a 0\npad down 1\npad down 0\npad a 1\npad a 0\n")
	assert(FileAccess.get_file_as_string(run_dir.path_join("menu.event")) == "1 2 game\n")
	assert(panel._gui.gui_get_focus_owner().name == "Game" and panel._sub == null)
	# RetroArch has the pad on its Game page. The panel shows each snapshot.
	var before := frame()
	var card_size: Vector2 = panel._card.size
	var long_name := "A row name that is much longer than the panel is wide, as a cheat name can be"
	assert(before.views == 0)
	await send("view 1 1 0 3 %s - %s %s %s\n" % [hex("Game"), hex("Resume"), hex(long_name), hex("Exit")], 0.0)
	# The first frame of a snapshot is its final picture.
	while frame().views == 0:
		await process_frame
	var early := frame()
	await wait(0.4)
	assert(frame().number == early.number)
	var focus: Control = panel._gui.gui_get_focus_owner()
	assert(panel._title.text == "Game" and not panel._list.visible and not panel._view_status.visible)
	assert(focus.get_parent() == panel._view_rows and focus.text == long_name and focus.get_index() == 1)
	assert(panel._card.size == card_size and focus.size.x < panel._card.size.x)
	# The selected row shows all of its long name. Each other row has one line.
	assert(focus.size.y > panel._view_rows.get_child(0).size.y * 1.5)
	var shown := frame()
	assert(shown.views == 1 and shown.number > before.number and shown.image.get_data() != before.image.get_data())
	save("game-menu-view.png")
	# The same snapshot again gives a new frame, so RetroArch sees its line count.
	await send("view 1 1 0 3 %s - %s %s %s\n" % [hex("Game"), hex("Resume"), hex(long_name), hex("Exit")])
	assert(frame().views == 2 and frame().number > shown.number and frame().image.get_data() == shown.image.get_data())
	# A long list, a long status and a title that is not ASCII.
	var six := PackedStringArray()
	for index in 6:
		six.append(hex("Cheat %d            On" % (index + 8)))
	var acknowledged: int = frame().number
	var sent := Time.get_ticks_msec()
	await send("view 1 5 7 24 %s %s %s\n" % [hex("Chéats"), hex("Saved. " + long_name + ". Press A again to confirm it."), " ".join(six)], 0.0)
	# The frame of a snapshot does not wait for the minimum frame time, and it is the final picture.
	while frame().views < 3:
		await process_frame
	print("View frame after %d ms" % (Time.get_ticks_msec() - sent))
	acknowledged = frame().number
	await wait(0.4)
	assert(frame().number == acknowledged)
	focus = panel._gui.gui_get_focus_owner()
	assert(panel._title.text == "Chéats  13/24" and focus.text == "Cheat 13" and focus.get_node("Value").text == "On" and panel._view_status.visible)
	# The value is on the right side of the row.
	var value: Label = focus.get_node("Value")
	assert(value.visible and value.get_global_rect().end.x > focus.get_global_rect().end.x - 40.0)
	assert(panel._card.size == card_size and panel._view_status.get_line_count() > 1)
	# The focused row and the status are in the panel.
	var list: Rect2 = panel._view_rows.get_parent().get_global_rect()
	assert(list.grow(1.0).encloses(focus.get_global_rect()) and not list.intersects(panel._view_status.get_global_rect()))
	assert(panel._card.get_global_rect().encloses(panel._view_status.get_global_rect()))
	assert(frame().views == 3)
	save("game-menu-view-scroll.png")
	# Fewer rows, and lines that are not correct: no change.
	await send("view 1 0 0 1 %s - %s\n" % [hex("Core"), hex("Only")])
	assert(panel._view_rows.get_children().filter(func(row): return row.visible).size() == 1)
	await send("view 1 0 0 1 zz - %s\nview 2 0 0 1 %s - %s\nview 1 0 0 7 %s - %s\nview 1 -1 0 1 %s -\nroot 2\n" % [
		hex("x"), hex("x"), hex("x"), hex("x"), " ".join(six) + " " + six[0], hex("x")])
	assert(panel._title.text == "Core" and frame().views == 4)
	# A long label has an ellipsis left of its value. A long value stays in the text.
	await send("view 1 2 0 3 %s - %s %s %s\n" % [hex("Core"), hex(long_name + "   On"), hex("Mode   " + long_name), hex("Mode   " + long_name)])
	var rows: Array = panel._view_rows.get_children()
	assert(rows[0].text == long_name and rows[0].get_node("Value").visible and rows[0].size.y < rows[2].size.y)
	assert(rows[1].text == "Mode  " + long_name and not rows[1].get_node("Value").visible)
	assert(rows[2].autowrap_mode != TextServer.AUTOWRAP_OFF and panel._card.size == card_size)
	assert(panel._view_rows.get_parent().get_global_rect().grow(1.0).encloses(rows[2].get_global_rect()))
	save("game-menu-view-long.png")
	await send("view 1 0 0 1 %s - %s\n" % [hex("Core"), hex("Only")])
	# "-" is an empty string. A page can have no rows.
	await send("view 1 0 0 0 - %s\n" % hex("No cheats"))
	assert(panel._title.text == "" and panel._view_status.text == "No cheats" and frame().views == 7)
	assert(panel._view_rows.get_children().all(func(row): return not row.visible))
	# The text is literal: no translation and no markup.
	await send("view 1 0 0 1 %s - %s\n" % [hex("[b]Game[/b]"), hex("[b]Row[/b]")])
	assert(panel._title.text == "[b]Game[/b]" and panel._gui.gui_get_focus_owner().text == "[b]Row[/b]")
	# Root: the main list, with the focus on the row that opened the page.
	await send("root 1\n")
	assert(panel._view == null and panel._list.visible and panel._title.text == "Device Settings")
	assert(panel._gui.gui_get_focus_owner().name == "Game")
	assert(frame().views == 9 and frame().image.get_data() == before.image.get_data())
	print("PASS: views")
	# B on the main list asks RetroArch to close. RetroArch closes the panel.
	await press("b")
	assert(FileAccess.get_file_as_string(run_dir.path_join("menu.event")) == "1 3 close\n")
	assert(root.get_node("DeviceSettings") == panel)
	await send("close 1\n")
	assert(not root.has_node("DeviceSettings") and not FileAccess.file_exists(run_dir.path_join("menu.frame")))
	assert(not FileAccess.file_exists(run_dir.path_join("menu.theme")))
	assert(OS.low_processor_usage_mode_sleep_usec == overlay.IDLE_USEC and paused)
	# A launcher MENU record during the game does not open or close a panel.
	bridge._playing = true
	bridge._settings_armed = true
	root.set_meta("socket_shader_startup_complete", true)
	var record := FileAccess.open(run_dir.path_join("settings.open"), FileAccess.WRITE)
	record.store_string("1 1\n")
	record.close()
	await wait(0.2)
	assert(not root.has_node("DeviceSettings"))
	bridge._playing = false
	bridge._new_menu_presses()
	print("PASS: pad, events and close")

	# Only a complete line opens the menu. The Wi-Fi page opens in the game.
	await send("open 2")
	assert(not root.has_node("DeviceSettings"))
	await send("\n", 0.6)
	panel = root.get_node("DeviceSettings")
	assert(frame().id == 2)
	# Bluetooth is not available in this test, so Up goes to Wi-Fi.
	await press("up")
	assert(panel._gui.gui_get_focus_owner().name == "Wi-Fi")
	await press("a")
	assert(panel._sub != null and panel._title.text == "Wi-Fi")
	save("game-menu-wifi.png")
	# Left on a level row: the request goes to socket-hardware.
	await press("b")
	await press("up")
	await press("left")
	assert(FileAccess.get_file_as_string(run_dir.path_join("controls.set")).ends_with(" volume 35\n"))
	# A panel that another node removed does not stop the overlay.
	panel.free()
	await press("down")
	# Sleep: RetroArch closes the menu and opens it again in one write.
	await send("close 2\nopen 3\n", 0.6)
	assert(root.has_node("DeviceSettings"))
	var third := frame()
	assert(third.id == 3 and root.get_node("DeviceSettings")._gui.gui_get_focus_owner().name == "Game")
	# After a sleep, the page of RetroArch can follow the open line directly.
	await send("close 3\nopen 4\nview 4 0 0 1 %s - %s\n" % [hex("Game"), hex("Resume")], 0.6)
	panel = root.get_node("DeviceSettings")
	assert(frame().id == 4 and frame().views == 1 and panel._title.text == "Game")
	await send("root 4\n")
	assert(frame().views == 2 and panel._gui.gui_get_focus_owner().name == "Game")
	# The pages below Cheats return to the Cheats row.
	for title in ["Cheats", "Cheat files", "libretro cheat titles"]:
		await send("close 4\nopen 4\nview 4 0 0 1 %s - %s\nroot 4\n" % [hex(title), hex("Row")], 0.4)
		assert(root.get_node("DeviceSettings")._gui.gui_get_focus_owner().name == "Cheats" and frame().views == 2)
	# An older RetroArch has no "2" in its session line. It gets theme version 1.
	await send("session 78-1\nopen 1\n", 0.6)
	assert(FileAccess.get_file_as_string(run_dir.path_join("menu.theme")).begins_with("1 ffffff "))
	print("PASS: pages and reopen")

	# The game stops with the menu open and a button down.
	await send("pad left 1\n", 0.1)
	assert(Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_LEFT))
	FileAccess.open(run_dir.path_join("game.stop"), FileAccess.WRITE).close()
	await wait(0.5)
	assert(result == [7] and not root.has_node("DeviceSettings") and not bridge.has_node("GameOverlay"))
	assert(not Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_LEFT))
	assert(not paused and view.render_target_update_mode == SubViewport.UPDATE_ALWAYS)
	assert(OS.low_processor_usage_mode_sleep_usec == sleep_usec)
	assert(root.gui_get_focus_owner() == launcher)
	print("PASS: game overlay")
	quit()
