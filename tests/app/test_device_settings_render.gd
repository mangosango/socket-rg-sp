# Draw the launcher Device Settings with the packed project and the fbdev
# display server at 720x480. Use tests/app/run_render.py. The script is the
# Wi-Fi and Bluetooth worker. It moves the focus with pad buttons only, types a
# password on the Wi-Fi keyboard and opens a Bluetooth accessory.
#
# SOCKET_EVIDENCE gets the display pixels of each step and layout.txt: the
# rectangle, the text and the line count of each control, and the focus. Run
# the script on two packs and compare the two layout.txt files to see a layout
# change.
extends SceneTree

const HEADSET := "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"

var evidence: String = OS.get_environment("SOCKET_EVIDENCE")
var run_dir: String = OS.get_environment("SOCKET_RUN")
var panel: Node
var layout := ""

func _initialize() -> void:
	_run.call_deferred()

func require(ok: bool, message: String) -> bool:
	if not ok:
		printerr("FAIL: ", message)
		quit(1)
	return ok

func wait(seconds: float) -> void:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		worker()
		await process_frame

func write(file_name: String, text: String) -> void:
	var file := FileAccess.open(run_dir.path_join(file_name), FileAccess.WRITE)
	file.store_string(text)
	file.close()

# Do the work of the Wi-Fi worker: a scan gives two networks, a join stays pending.
func worker() -> void:
	var path := run_dir.path_join("wifi.request")
	if not FileAccess.file_exists(path):
		return
	var request := FileAccess.get_file_as_string(path).strip_edges().split(" ")
	DirAccess.remove_absolute(path)
	if request[1] == "scan":
		write("wifi.scan", "bssid / frequency / signal level / flags / ssid\n" +
			"02:00:00:00:00:01\t2437\t-40\t[WPA2-PSK-CCMP][ESS]\tA long network name of 32 bytes!\n" +
			"02:00:00:00:00:02\t2437\t-50\t[WPA2-PSK-CCMP][ESS]\tHome\n")
	write("wifi.status", "id=%s\nresult=%s\nstate=disconnected\nsaved=\n" % [request[0], "pending" if request[1] == "join" else "ok"])

# A physical pad button, as the fbdev display server sends it.
func press(button: JoyButton) -> void:
	for pressed in [true, false]:
		var event := InputEventJoypadButton.new()
		event.device = 0
		event.button_index = button
		event.pressed = pressed
		event.pressure = 1.0 if pressed else 0.0
		Input.parse_input_event(event)
		await wait(0.05)

func control(text: String) -> Control:
	for node in panel._gui.find_children("*", "Control", true, false):
		if node.is_visible_in_tree() and node.focus_mode != Control.FOCUS_NONE and (node.text if "text" in node and node.text != "" else node.get("placeholder_text")) == text:
			return node
	return null

# Move the focus to the control with this text. Use the direction buttons only.
func steer(text: String) -> bool:
	for step in 60:
		var target := control(text)
		if not require(target != null, "the page has the control " + text): return false
		var focus: Control = panel._gui.gui_get_focus_owner()
		if focus == target:
			return true
		if not require(focus != null, "a control has the focus"): return false
		var delta := target.get_global_rect().get_center() - focus.get_global_rect().get_center()
		if absf(delta.y) > focus.size.y / 2.0:
			await press(JOY_BUTTON_DPAD_DOWN if delta.y > 0 else JOY_BUTTON_DPAD_UP)
		else:
			await press(JOY_BUTTON_DPAD_RIGHT if delta.x > 0 else JOY_BUTTON_DPAD_LEFT)
	return require(false, "the direction buttons get to " + text)

func choose(text: String) -> bool:
	if not await steer(text): return false
	await press(JOY_BUTTON_A)
	await wait(0.6)
	return true

# The part of the text pixels of a control that are between the surface color
# and the ink color, for each pixel with the ink color. Lower is sharper.
func soft(image: Image, node: Control) -> float:
	var scale: float = float(root.size.y) / panel._logical.y
	var rect := Rect2i(Rect2(node.global_position * scale, node.size * scale)).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	var surface: float = panel._surface.get_luminance()
	var ink: float = panel._ink.get_luminance()
	var between := 0
	var full := 0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var part := (image.get_pixel(x, y).get_luminance() - surface) / (ink - surface)
			if part > 0.75:
				full += 1
			elif part > 0.25:
				between += 1
	return float(between) / maxi(full, 1)

func shot(step: String) -> Image:
	await wait(0.5)
	var image := root.get_texture().get_image()
	image.save_png(evidence.path_join("launcher-%s.png" % step))
	layout += "== %s\n" % step
	for node in panel._gui.find_children("*", "Control", true, false):
		if node.is_visible_in_tree():
			layout += "%s %s %s lines=%s focus=%s %s\n" % [node.get_class(), node.get_global_rect().position.snappedf(0.01), node.size.snappedf(0.01),
				node.get_line_count() if node is Label else 1, node.has_focus(), (node.text if "text" in node else "").c_escape()]
	var file := FileAccess.open(evidence.path_join("layout.txt"), FileAccess.WRITE)
	file.store_string(layout)
	file.close()
	return image

func _run() -> void:
	OS.low_processor_usage_mode = false
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	for i in range(5000):
		if root.get_meta("socket_shader_startup_complete", false):
			break
		await process_frame
	if not require(root.get_meta("socket_shader_startup_complete", false), "startup completes"): return
	await wait(1.0)
	if OS.get_environment("SOCKET_TEST_DARK") == "1":
		root.get_node("SettingsManager").set_setting("dark_mode", true)
	# The panel pauses the launcher. Let the launcher complete its transition first.
	await wait(2.0)
	if not require(root.size == Vector2i(720, 480), "the display has 720x480 pixels"): return
	write("wifi.status", "id=0\nresult=ok\nstate=disconnected\nsaved=\n")
	write("bluetooth.status", "on\n")
	var state := "method return time=1.0 sender=:1.0 -> destination=:1.1 serial=3 reply_serial=2\n   array [\n"
	for device in [[HEADSET, "Headphones with a long name (32)", true], [HEADSET.replace("FF", "00"), "Pad", false]]:
		state += "      dict entry(\n         object path \"%s\"\n         array [\n            dict entry(\n               string \"org.bluez.Device1\"\n               array [\n" % device[0]
		for property in [["Alias", "string \"%s\"" % device[1]], ["Paired", "boolean true"], ["Connected", "boolean " + str(device[2])]]:
			state += "                  dict entry(\n                     string \"%s\"\n                     variant                         %s\n                  )\n" % property
		state += "               ]\n            )\n         ]\n      )\n"
	write("bluetooth.state", state + "   ]\n")

	root.get_node("FrontendBridge").open_device_settings()
	panel = root.get_node("DeviceSettings")
	if not require(panel._rows.keys() == ["Brightness", "Volume", "Wi-Fi", "Bluetooth"], "launcher menu has four device settings"): return
	var image := await shot("root")
	var gui: SubViewport = panel._gui
	var scale: float = 480.0 / panel._logical.y
	var title: Label = panel._title
	var size := title.get_theme_font_size("font_size")
	var font := title.get_theme_font("font")
	var glyph: float = size * gui.oversampling_override
	var values := [soft(image, title), soft(image, panel._rows["Bluetooth"])]
	print("Device Settings render: viewport %s, font %s at %d units (%.2f display pixels, %.2f glyph pixels), card %s, soft pixels for each full pixel: title %.3f, row %.3f" % [
		gui.size, font.get_font_name(), size, size * scale, glyph, Rect2(panel._card.global_position * scale, panel._card.size * scale), values[0], values[1]])
	if not require(gui.size == Vector2i(720, 480), "the panel draws one sample for each display pixel"): return
	if not require(size == panel._socket_theme().default_font_size, "the text has the size of the Socket theme"): return

	# Wi-Fi: scan, choose the long name, type a password on the keyboard, join.
	if not await choose("Wi-Fi"): return
	if not require(panel._sub != null and control("Choose a network") != null, "A opens the Wi-Fi page"): return
	await shot("wifi")
	if not await choose("Choose a network"): return
	await shot("wifi-networks")
	if not await choose("A long network name of 32 bytes!  (WPA2)"): return
	if not await choose("Password"): return
	if not require(control("Caps") != null, "A on the password field opens the keyboard"): return
	for key in ["s", "o", "c", "k", "Caps", "E", "CAPS", "t", "-", "9", "9", "0", "Delete"]:
		if not await choose(key): return
	await shot("wifi-keyboard")
	if not require(panel._sub._psk.text == "sockEt-99", "the keyboard types the password"): return
	if not await choose("Done"): return
	await shot("wifi-form")
	if not await choose("Join"): return
	if not require(FileAccess.get_file_as_string(run_dir.path_join("wifi.candidate")).contains("sockEt-99"), "Join sends the network and the password: view %s, note %s, file %s" % [panel._sub._view, panel._sub._note, FileAccess.get_file_as_string(run_dir.path_join("wifi.candidate")).c_escape()]): return
	await shot("wifi-joining")
	# B goes back to the main list of the panel, one page for each press.
	for i in 6:
		if panel._sub == null:
			break
		await press(JOY_BUTTON_B)
		await wait(0.6)
	if not require(panel._sub == null and panel._gui.gui_get_focus_owner() == panel._rows["Wi-Fi"], "B returns to the Wi-Fi row"): return

	# Bluetooth: the paired accessories, then the page of one accessory.
	if not await choose("Bluetooth"): return
	await wait(0.5)
	if not require(panel._sub != null and control("Add accessory") != null, "A opens the Bluetooth page"): return
	await shot("bluetooth")
	if not await choose("Headphones with a long name (32) (EE:FF): Connected"): return
	if not require(control("Disconnect") != null, "A opens the accessory"): return
	await shot("bluetooth-device")
	if not await choose("Disconnect"): return
	var requests := Array(DirAccess.get_files_at(run_dir)).filter(func(n): return n.begins_with("bluetooth.request.")).map(func(n): return FileAccess.get_file_as_string(run_dir.path_join(n)).strip_edges())
	if not require("open" in requests and "disconnect AA:BB:CC:DD:EE:FF" in requests, "the page sends the requests: %s" % [requests]): return
	for i in 4:
		if panel._sub == null:
			break
		await press(JOY_BUTTON_B)
		await wait(0.6)
	if not require(panel._sub == null and panel._gui.gui_get_focus_owner() == panel._rows["Bluetooth"], "B returns to the Bluetooth row"): return
	await press(JOY_BUTTON_B)
	await wait(0.3)
	if not require(not root.has_node("DeviceSettings") and not paused, "B closes the panel"): return
	# After the captures, so a pack without the larger glyphs gives them too.
	if font.get_font_name() == "Departure Mono":
		if not require(glyph > 1.5 * size * scale and absf(glyph / 11.0 - roundf(glyph / 11.0)) < 0.02, "the glyphs are on the 11 pixel grid of Departure Mono"): return
		# This pack gives 0.4 to 0.7. Glyphs at the size of the display give 2.2 to 3.6.
		if not require(values.max() < 1.0, "the text has sharp edges"): return
	print("PASS: launcher Device Settings at 720x480 with Wi-Fi and Bluetooth pad input")
	quit()
