extends SceneTree

# A launcher node that does not pause. It must see no input while the panel is open.
class Probe extends Node:
	var events := 0
	func _input(event: InputEvent) -> void:
		if event is InputEventAction:
			events += 1

# Like Socket's GUIDE node: the input map has no pad buttons for ui_accept and
# ui_cancel. This node makes the actions from the A and B buttons.
class Guide extends Node:
	var injected := 0
	func inject_input(event: InputEvent) -> void:
		if event is InputEventJoypadButton and event.button_index in [JOY_BUTTON_A, JOY_BUTTON_B]:
			injected += 1
			var made := InputEventAction.new()
			made.action = "ui_accept" if event.button_index == JOY_BUTTON_A else "ui_cancel"
			made.pressed = event.pressed
			Input.parse_input_event(made)
	func _unhandled_input(event: InputEvent) -> void:
		inject_input(event)

# Like Socket's SettingsManager, with the cartridge MSAA setting only.
class Settings extends Node:
	var values := {"cartridge_msaa": true}
	var saves := 0
	var mode := Viewport.MSAA_2X
	func cartridge_msaa_mode() -> Viewport.MSAA:
		return mode
	func get_setting(key: String) -> Variant:
		return values.get(key)
	func set_setting(key: String, value: Variant) -> void:
		values[key] = value
		saves += 1

var run_dir: String = OS.get_environment("SOCKET_RUN")
var sequence := 0
var volume := 40
var brightness := 6
var fail_brightness := false
var helper_stopped := false
var requests: Array[String] = []
var menu_epoch := 5000
var menu_count := 0


func _initialize() -> void:
	_run.call_deferred()


func write(file_name: String, text: String) -> void:
	var file := FileAccess.open(run_dir.path_join(file_name + ".new"), FileAccess.WRITE)
	file.store_string(text)
	file.close()
	DirAccess.rename_absolute(run_dir.path_join(file_name + ".new"), run_dir.path_join(file_name))


func snapshot(kind: int) -> void:
	sequence += 1
	write("controls", "2 %d %d %d 0 %d\n" % [sequence, volume, brightness - 1, kind])


# Do the work of socket-hardware for one request.
func helper() -> void:
	var path := run_dir.path_join("controls.set")
	if helper_stopped or not FileAccess.file_exists(path):
		return
	var text := FileAccess.get_file_as_string(path)
	DirAccess.remove_absolute(path)
	requests.append(text)
	var parts := text.strip_edges().split(" ")
	var ok := true
	if parts[1] == "volume":
		volume = parts[2].to_int()
	elif fail_brightness:
		ok = false
	else:
		brightness = parts[2].to_int()
	if ok:
		snapshot(1 if parts[1] == "volume" else 2)
	write("controls.ack", "%s %s %d\n" % [parts[0], "ok" if ok else "error", volume if parts[1] == "volume" else brightness])


# MENU presses in the launcher, as socket-hardware publishes them.
func menu(presses: int = 1) -> void:
	menu_count += presses
	write("settings.open", "%d %d\n" % [menu_epoch, menu_count])
	await wait(0.2)


func wait(seconds: float) -> void:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		helper()
		await process_frame


func action(action_name: String, pressed: bool) -> void:
	var event := InputEventAction.new()
	event.action = action_name
	event.pressed = pressed
	Input.parse_input_event(event)
	await wait(0.05)


# A physical pad button, as the fbdev display server sends it.
func button(index: JoyButton, pressed: bool) -> void:
	var event := InputEventJoypadButton.new()
	event.button_index = index
	event.pressed = pressed
	Input.parse_input_event(event)
	await wait(0.05)


func tap(action_name: String) -> void:
	await action(action_name, true)
	await action(action_name, false)
	await wait(0.2)


func _run() -> void:
	root.size = Vector2i(720, 480)
	var guide := Guide.new()
	guide.name = "GUIDE"
	guide.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(guide)
	# Socket's input map has keys only for these actions.
	for unbound in ["ui_accept", "ui_cancel"]:
		for mapped in InputMap.action_get_events(unbound):
			if not mapped is InputEventKey:
				InputMap.action_erase_event(unbound, mapped)
	var probe := Probe.new()
	probe.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(probe)
	var launcher := Button.new()
	var presses: Array[int] = [0]
	launcher.pressed.connect(func(): presses[0] += 1)
	probe.add_child(launcher)
	launcher.grab_focus()
	snapshot(0)
	var bridge = load("res://addons/FrontendPlugin/frontend_bridge.gd").new()
	root.add_child(bridge)
	var hud = bridge.get_node("ControlsHUD")
	var request := run_dir.path_join("settings.open")

	# MENU presses during startup are counted and not used after startup.
	await menu()
	assert(FileAccess.file_exists(request) and not root.has_node("DeviceSettings"))
	menu()
	root.set_meta("socket_shader_startup_complete", true)
	await wait(0.3)
	assert(not root.has_node("DeviceSettings"))
	for invalid in ["x\n", "3\n", "7 3", "7 x\n", "1234567890123456789 1\n", "7 1234567890\n", " 7 3\n", ""]:
		write("settings.open", invalid)
		await wait(0.2)
		assert(not root.has_node("DeviceSettings"))
	print("PASS: startup and invalid open requests are discarded")

	# One press opens one panel. The request file stays and is not used again.
	await menu()
	var panel := root.get_node("DeviceSettings")
	await wait(0.3)
	assert(FileAccess.file_exists(request) and root.get_node("DeviceSettings") == panel)
	assert(root.find_children("*", "CanvasLayer", false, false).filter(func(node): return node.name.begins_with("DeviceSettings")).size() == 1)
	assert(paused and hud.quiet and panel.layer < hud.layer)
	var focus: Control = panel._gui.gui_get_focus_owner()
	assert(focus.name == "Brightness" and focus.get_node("Side/Value").text == "6")
	print("PASS: one panel opens above the paused launcher with its own focus")

	# Each step goes to the helper. The row shows the applied level.
	await tap("ui_right")
	assert(requests.size() == 1 and requests[0].ends_with(" brightness 7\n"))
	assert(brightness == 7 and focus.get_node("Side/Value").text == "7" and focus.get_node("Side/Bar").value == 7)
	fail_brightness = true
	await tap("ui_right")
	assert(requests.size() == 2 and focus.get_node("Side/Value").text == "7" and panel._wanted.is_empty())
	fail_brightness = false
	await tap("ui_down")
	focus = panel._gui.gui_get_focus_owner()
	assert(focus.name == "Volume" and focus.get_node("Side/Value").text == "40")
	await tap("ui_left")
	assert(requests[-1].ends_with(" volume 35\n") and focus.get_node("Side/Value").text == "35")
	assert(is_equal_approx(AudioServer.get_bus_volume_linear(0), 0.1225))
	# A hold repeats. The limit is 0 and the row shows the mute state.
	await action("ui_left", true)
	await wait(2.0)
	await action("ui_left", false)
	await wait(0.3)
	assert(volume == 0 and focus.get_node("Side/Value").text == "Muted" and AudioServer.get_bus_volume_linear(0) == 0.0)
	var sent := requests.size()
	await tap("ui_left")
	assert(requests.size() == sent)
	# The volume buttons change the row. The HUD bar stays hidden.
	volume = 80
	snapshot(1)
	await wait(0.2)
	assert(focus.get_node("Side/Value").text == "80" and not hud._view.visible)
	# No helper: the request ends after its time limit and the row keeps its value.
	helper_stopped = true
	await tap("ui_right")
	assert(not panel._request.is_empty() and FileAccess.get_file_as_string(run_dir.path_join("controls.set")).ends_with(" volume 85\n"))
	await wait(0.6)
	DirAccess.remove_absolute(run_dir.path_join("controls.set"))
	helper_stopped = false
	assert(panel._request.is_empty() and panel._wanted.is_empty() and focus.get_node("Side/Value").text == "80")
	print("PASS: level requests, replies, repeat and limits")

	# A radio row opens its page. B calls go_back and focus returns to the row.
	assert(panel._rows["Bluetooth"].disabled and panel._rows["Bluetooth"].get_node("Side/Value").text == "Unavailable")
	await tap("ui_down")
	focus = panel._gui.gui_get_focus_owner()
	assert(focus.name == "Wi-Fi")
	await tap("ui_down")
	assert(panel._gui.gui_get_focus_owner().name == "Emulation")
	await tap("ui_accept")
	var emu = panel._sub
	emu.card = run_dir
	DirAccess.make_dir_recursive_absolute(run_dir.path_join("Config"))
	emu._toggle_account()
	assert(emu._view == "form" and emu._psk.secret)
	emu._ssid.text = "tester"
	emu._psk.text = "a=b"
	emu._save_account()
	var account := run_dir.path_join("Config/retroachievements.txt")
	assert(FileAccess.get_file_as_string(account) == "username = tester\npassword = a=b\n" and emu._psk.text.is_empty())
	emu._toggle_account()
	assert(FileAccess.file_exists(account + ".off"))
	emu._edit_account()
	emu._ssid.text = "invalid\nname"
	emu._psk.text = "invalid"
	emu._save_account()
	assert(emu._view == "form" and FileAccess.get_file_as_string(account).contains("tester"))
	emu.go_back()
	emu._toggle_account()
	assert(not FileAccess.file_exists(account + ".off"))
	var gba := run_dir.path_join("Saves/socket/retroarch/gba.cfg")
	DirAccess.make_dir_recursive_absolute(gba.get_base_dir())
	var prefs := FileAccess.open(gba, FileAccess.WRITE)
	prefs.store_string('video_shader_enable = "false"\n')
	prefs.close()
	emu._render()
	for row in emu.get_children():
		if row is Button and row.text == "GBA rewind":
			row.pressed.emit()
	assert(FileAccess.get_file_as_string(gba) == 'video_shader_enable = "false"\nrewind_enable = "false"\n')
	emu.go_back()
	await wait(0.08)
	await tap("ui_up")
	assert(panel._gui.gui_get_focus_owner() == focus)
	# Physical A, B and D-pad events reach the panel and not the launcher.
	# The fbdev display server sends button 0 for A and button 1 for B.
	assert(guide.injected == 0)
	for check in ["ui_accept", "ui_cancel"]:
		assert(InputMap.action_get_events(check).all(func(mapped): return not mapped is InputEventJoypadButton))
	await button(JOY_BUTTON_A, true)
	await button(JOY_BUTTON_A, false)
	var page: Control = panel._sub
	assert(page != null and not panel._list.visible and panel._title.text == "Wi-Fi")
	assert(panel._gui.gui_get_focus_owner() == page.get_node("Network0"))
	# The power switch row of the page has the look of the panel rows.
	var switch: Button = page.get_node("Network0")
	var outline: StyleBoxFlat = switch.get_theme_stylebox("focus")
	var panel_outline: StyleBoxFlat = focus.get_theme_stylebox("focus")
	assert(switch.alignment == HORIZONTAL_ALIGNMENT_LEFT and switch.get_theme_stylebox("normal") is StyleBoxEmpty)
	assert(outline.corner_radius_top_left == panel_outline.corner_radius_top_left and outline.corner_radius_top_left > 0)
	assert(outline.border_width_left == panel_outline.border_width_left and outline.border_color == panel_outline.border_color and not outline.draw_center)
	assert(switch.get_theme_color("font_color") == focus.get_theme_color("font_color"))
	# The radio name is at the left and the state at the right, as on a panel switch.
	var state_label: Label = switch.get_node("Side/Value")
	var panel_value: Label = focus.get_node("Side/Value")
	assert(switch.text == "Wi-Fi" and state_label.text == "On" and switch.accessibility_name == "Wi-Fi: On")
	assert(state_label.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT and switch.get_node("Side").offset_right == focus.get_node("Side").offset_right)
	assert(state_label.get_theme_color("font_color") == panel_value.get_theme_color("font_color"))
	assert(state_label.get_global_rect().end.x <= switch.get_global_rect().end.x and state_label.get_global_rect().position.x > switch.get_global_rect().get_center().x)
	# A regular action row has the same look and the full width. It has no state area.
	var regular: Button = page.get_node("Network1")
	assert(regular.text == "Network1" and regular.alignment == HORIZONTAL_ALIGNMENT_LEFT and not regular.has_node("Side"))
	assert(regular.get_theme_stylebox("normal") is StyleBoxEmpty and regular.get_theme_color("font_color") == focus.get_theme_color("font_color"))
	assert(is_equal_approx(regular.size.x, switch.size.x) and is_equal_approx(regular.size.x, page.size.x))
	# A colon in a name stays in the text. Only the switch row has a state.
	var named: Button = page.get_node("Network3")
	assert(named.text == "Forget Office: Guest" and not named.has_node("Side") and named.accessibility_name == "")
	# A long label wraps. The row stays in the panel and becomes higher.
	var long: Button = page.get_node("Network2")
	var view: Rect2 = panel._scroll.get_global_rect()
	assert(long.text.begins_with("Forget A long network name") and not long.has_node("Side"))
	assert(long.get_global_rect().position.x >= view.position.x and long.get_global_rect().end.x <= view.end.x)
	assert(is_equal_approx(long.size.x, regular.size.x) and long.size.y > regular.size.y)
	assert(page.size.x <= view.size.x)
	# Keyboard keys are compact and centered. They fit in one line of the panel.
	var keys: Array = page.get_node("Keys").get_children()
	for key: Button in keys:
		assert(key.alignment == HORIZONTAL_ALIGNMENT_CENTER and not key.has_node("Side") and key.accessibility_name == "")
		assert(key.get_theme_stylebox("normal").get_margin(SIDE_LEFT) < regular.get_theme_stylebox("normal").get_margin(SIDE_LEFT))
		assert(key.get_global_rect().position.x >= view.position.x and key.get_global_rect().end.x <= view.end.x)
		assert(key.size.x < regular.size.x / 5 and key.size.y < regular.size.y)
	assert(keys.map(func(key): return key.text) == Array("qwertyuio:".split("")))
	assert(is_equal_approx(keys[0].position.y, keys[-1].position.y))
	# The focus outline is the same for the switch, a regular row, a long row and a key.
	for other: Button in [regular, named, long, keys[0], keys[-1]]:
		var same: StyleBoxFlat = other.get_theme_stylebox("focus")
		assert(same.corner_radius_top_left == outline.corner_radius_top_left and same.border_width_left == outline.border_width_left)
		assert(same.border_color == outline.border_color and not same.draw_center)
		assert(other.get_theme_color("font_focus_color") == switch.get_theme_color("font_focus_color"))
	# A long list scrolls in the panel. The last row stays visible and usable.
	var frame: PanelContainer = panel._gui.find_children("*", "PanelContainer", true, false)[0]
	var frame_size := frame.size
	for index in 29:
		await button(JOY_BUTTON_DPAD_DOWN, true)
		await button(JOY_BUTTON_DPAD_DOWN, false)
	var last: Button = page.get_node("Network29")
	var chosen: Array[int] = [0]
	last.pressed.connect(func(): chosen[0] += 1)
	assert(panel._gui.gui_get_focus_owner() == last)
	assert(frame.size == frame_size and frame.size.y <= panel._logical.y)
	assert(panel._scroll.get_global_rect().encloses(last.get_global_rect()))
	await button(JOY_BUTTON_A, true)
	await button(JOY_BUTTON_A, false)
	assert(chosen[0] == 1)
	await button(JOY_BUTTON_B, true)
	assert(page.backs == 0 and panel._sub == page)
	var backs: Array[int] = [0]
	page.back_requested.connect(func(): backs[0] += 1)
	await button(JOY_BUTTON_B, false)
	assert(backs[0] == 1 and not is_instance_valid(page) and panel._sub == null and panel._list.visible)
	assert(panel._gui.gui_get_focus_owner() == focus and panel._title.text == "Device Settings")
	print("PASS: radio page opens, goes back and restores the row focus")

	# B closes the panel on release. The launcher got no input and keeps its focus.
	await action("ui_cancel", true)
	assert(is_instance_valid(panel) and root.has_node("DeviceSettings"))
	await action("ui_cancel", false)
	await wait(0.1)
	assert(not is_instance_valid(panel) and not root.has_node("DeviceSettings"))
	assert(probe.events == 0 and presses[0] == 0)
	assert(not paused and not hud.quiet)
	assert(root.gui_get_focus_owner() == launcher)
	await tap("ui_accept")
	assert(probe.events == 2 and presses[0] == 1)
	# A file dialog window has the input. MENU does not open the panel over it.
	root.gui_embed_subwindows = true
	var dialog := AcceptDialog.new()
	root.add_child(dialog)
	dialog.popup_centered()
	await menu()
	assert(not root.has_node("DeviceSettings"))
	dialog.hide()
	# The next MENU press opens a new panel. MENU closes it from a radio page.
	# The launcher gets no input, is not paused and has its focus again.
	var seen := probe.events
	await menu()
	panel = root.get_node("DeviceSettings")
	assert(paused and root.gui_get_focus_owner() != launcher)
	await tap("ui_down")
	await tap("ui_down")
	await button(JOY_BUTTON_A, true)
	await button(JOY_BUTTON_A, false)
	page = panel._sub
	assert(page != null and panel._title.text == "Wi-Fi")
	await menu()
	assert(not root.has_node("DeviceSettings"))
	assert(not is_instance_valid(panel) and not is_instance_valid(page))
	assert(not paused and not hud.quiet and root.gui_get_focus_owner() == launcher)
	assert(probe.events == seen and presses[0] == 1)
	# MENU during a B hold closes the panel on the B release, not before.
	await menu()
	panel = root.get_node("DeviceSettings")
	await tap("ui_down")
	await tap("ui_down")
	await button(JOY_BUTTON_A, true)
	await button(JOY_BUTTON_A, false)
	assert(panel._sub != null)
	await button(JOY_BUTTON_B, true)
	await menu()
	assert(is_instance_valid(panel) and panel._sub == null and paused)
	await button(JOY_BUTTON_B, false)
	await wait(0.1)
	assert(not is_instance_valid(panel) and not root.has_node("DeviceSettings"))
	assert(not paused and root.gui_get_focus_owner() == launcher and probe.events == seen)
	# Each press toggles one time: open, close, open, close.
	for open in [true, false, true, false]:
		await menu()
		assert(root.has_node("DeviceSettings") == open and paused == open)
	# Two taps between two polls open and close: the state does not change.
	# This is true for one file with both taps and for two files in one poll.
	await menu(2)
	assert(not root.has_node("DeviceSettings") and not paused)
	menu()
	await menu()
	assert(not root.has_node("DeviceSettings") and not paused)
	await menu(3)
	panel = root.get_node("DeviceSettings")
	await menu(2)
	assert(root.get_node("DeviceSettings") == panel and paused)
	menu()
	await menu()
	assert(root.get_node("DeviceSettings") == panel and paused)
	await menu()
	assert(not root.has_node("DeviceSettings") and not paused)
	# After a wake, socket-hardware starts a new epoch. A press before the sleep
	# that was not used is gone. The first press after the wake toggles.
	menu()
	DirAccess.remove_absolute(request)
	menu_epoch += 1
	menu_count = 0
	await wait(0.2)
	assert(not root.has_node("DeviceSettings"))
	await menu()
	assert(root.has_node("DeviceSettings"))
	await menu()
	assert(not root.has_node("DeviceSettings"))
	# The return from a game counts a press from the game session and does not use it.
	menu()
	bridge._new_menu_presses()
	await wait(0.2)
	assert(not root.has_node("DeviceSettings"))
	await menu()
	assert(root.has_node("DeviceSettings"))
	# No SettingsManager with the setting: the panel has no Cartridge edge smoothing row.
	assert(not root.get_node("DeviceSettings")._rows.has("Cartridge edge smoothing"))
	root.get_node("DeviceSettings").close()
	await wait(0.1)
	assert(not paused and root.gui_get_focus_owner() == launcher)

	# Cartridge edge smoothing: the row shows the value of the manager. A changes and saves it.
	var settings := Settings.new()
	settings.name = "SettingsManager"
	root.add_child(settings)
	await menu()
	panel = root.get_node("DeviceSettings")
	assert(panel._rows.keys() == ["Brightness", "Volume", "Wi-Fi", "Bluetooth", "Cartridge edge smoothing", "Emulation"])
	for index in 3:
		await tap("ui_down")
	focus = panel._gui.gui_get_focus_owner()
	assert(focus.name == "Cartridge edge smoothing" and focus.get_node("Side/Value").text == "On" and settings.saves == 0)
	await button(JOY_BUTTON_A, true)
	await button(JOY_BUTTON_A, false)
	assert(settings.values["cartridge_msaa"] == false and settings.saves == 1 and focus.get_node("Side/Value").text == "Off")
	assert(panel._gui.gui_get_focus_owner() == focus and panel._sub == null and panel._title.text == "Device Settings")
	# The next panel shows the saved value. A sets it on again.
	await menu()
	await menu()
	panel = root.get_node("DeviceSettings")
	var state: Label = panel._rows["Cartridge edge smoothing"].get_node("Side/Value")
	assert(state.text == "Off")
	for index in 3:
		await tap("ui_down")
	await tap("ui_accept")
	assert(settings.values["cartridge_msaa"] == true and settings.saves == 2 and state.text == "On")
	# The watchdog pauses MSAA: the row shows Paused while the setting is true.
	# Off and then On change the setting. The renderer removes the mark.
	root.set_meta("socket_cartridge_msaa_paused", true)
	await wait(0.1)
	assert(state.text == "Paused" and settings.saves == 2)
	await tap("ui_accept")
	assert(settings.values["cartridge_msaa"] == false and state.text == "Off")
	root.remove_meta("socket_cartridge_msaa_paused")
	await tap("ui_accept")
	assert(settings.values["cartridge_msaa"] == true and settings.saves == 4 and state.text == "On")
	await menu()
	# The driver does not permit MSAA: the row shows Off and gets no focus.
	settings.mode = Viewport.MSAA_DISABLED
	root.set_meta("socket_cartridge_msaa_paused", true)
	await menu()
	panel = root.get_node("DeviceSettings")
	assert(panel._rows["Cartridge edge smoothing"].disabled and panel._rows["Cartridge edge smoothing"].get_node("Side/Value").text == "Off")
	for index in 4:
		await tap("ui_down")
	assert(panel._gui.gui_get_focus_owner().name == "Emulation")
	await tap("ui_accept")
	await button(JOY_BUTTON_B, true)
	await button(JOY_BUTTON_B, false)
	assert(panel._sub == null and settings.saves == 4)
	root.remove_meta("socket_cartridge_msaa_paused")
	settings.mode = Viewport.MSAA_4X
	await menu()
	assert(not root.has_node("DeviceSettings") and not paused and root.gui_get_focus_owner() == launcher and presses[0] == 1)
	# The in-game menu shows the radio and game rows.
	var game_panel = load("res://addons/FrontendPlugin/device_settings.gd").new()
	game_panel.game = true
	root.add_child(game_panel)
	await wait(0.2)
	assert(game_panel._rows.keys() == ["Brightness", "Volume", "Wi-Fi", "Bluetooth", "Game", "Cheats", "Emulation"])
	assert(game_panel._gui.gui_get_focus_owner().name == "Game")
	var card: Rect2 = game_panel._card.get_global_rect()
	print("Device Settings game card: %s of %s" % [card, game_panel._logical])
	assert(Rect2(Vector2.ZERO, game_panel._logical).encloses(card))
	for row in game_panel._rows.values():
		assert(card.encloses(row.get_global_rect()))
	game_panel.free()
	await wait(0.1)
	assert(not paused and root.gui_get_focus_owner() == launcher)
	print("PASS: Device Settings")
	quit()
