extends SceneTree

# Drive the Bluetooth settings page with ui actions. This script is the worker.
const HEADSET := "AA:BB:CC:DD:EE:FF"
const PAD := "11:22:33:44:55:66"
const STRANGER := "99:99:99:99:99:99"

var run := OS.get_environment("SOCKET_RUN")
var page
var backs := 0
var checks := 0
var session := 0
var log_text := ""
var objects := {}

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> bool:
	if not ok:
		printerr("FAIL: ", message, " view=", page._view if page else "", " rows=", rows(), " focus=", focused())
		quit(1)
		return false
	checks += 1
	return true

func rows() -> Array:
	if page == null: return []
	return page.find_children("*", "Control", true, false).filter(func(c): return "text" in c).map(func(c): return c.text)

func focused() -> String:
	var owner := root.gui_get_focus_owner()
	return "" if owner == null else owner.text

func press(action: String, count := 1) -> void:
	for i in count:
		for pressed in [true, false]:
			var event := InputEventAction.new()
			event.action = action
			event.pressed = pressed
			Input.parse_input_event(event)
			await process_frame
		await process_frame

# Move the focus to the button with this text and press A.
func choose(text: String) -> void:
	for button in page.find_children("*", "Button", true, false):
		if button.text == text:
			button.grab_focus()
			await press("ui_accept")
			return
	check(false, "no button " + text)

# Take the requests in the order that the worker reads them.
func requests() -> Array:
	var found := []
	var names := Array(DirAccess.get_files_at(run)).filter(func(n): return n.begins_with("bluetooth.request."))
	names.sort()
	for name in names:
		found.append(FileAccess.get_file_as_string(run.path_join(name)).strip_edges())
		DirAccess.remove_absolute(run.path_join(name))
	return found

func write(name: String, text: String) -> void:
	var file := FileAccess.open(run.path_join(name), FileAccess.WRITE)
	file.store_string(text)
	file.close()

func poll() -> void:
	page._poll()
	await process_frame

func status(value: String) -> void:
	write("bluetooth.status", value + "\n")
	await poll()

# A new agent instance, as after open, reset or wake.
func agent(ready := true) -> void:
	session += 1
	log_text = "# 1 %d\n" % session
	await event("ready" if ready else "")

func event(line: String) -> void:
	if line != "":
		log_text += line + "\n"
	write("bluetooth.log", log_text)
	await poll()

# Write the objects in the format of dbus-send --print-reply.
func state() -> void:
	var text := "method return time=1.0 sender=:1.0 -> destination=:1.1 serial=3 reply_serial=2\n   array [\n"
	for path in objects:
		text += "      dict entry(\n         object path \"%s\"\n         array [\n" % path
		for interface in objects[path]:
			text += "            dict entry(\n               string \"%s\"\n               array [\n" % interface
			var properties: Dictionary = objects[path][interface]
			for key in properties:
				var value = properties[key]
				var printed := "string \"%s\"" % value
				if value is bool:
					printed = "boolean " + str(value)
				elif value is int:
					printed = "int16 %d" % value
				text += "                  dict entry(\n                     string \"%s\"\n                     variant                         %s\n                  )\n" % [key, printed]
			text += "               ]\n            )\n"
		text += "         ]\n      )\n"
	write("bluetooth.state", text + "   ]\n")
	await poll()

func device(address: String) -> Dictionary:
	return objects["/org/bluez/hci0/dev_" + address.replace(":", "_")]["org.bluez.Device1"]

func _run() -> void:
	page = load("res://addons/FrontendPlugin/bluetooth_settings.gd").new()
	page.back_requested.connect(func(): backs += 1)
	root.add_child(page)
	await process_frame
	await process_frame

	# No worker: the page reports it and Back has the focus.
	check(requests() == ["open"], "the page asks the worker for live data")
	check(rows() == ["Bluetooth is unavailable.", "Back"] and focused() == "Back", "unavailable state")
	await press("ui_accept")
	check(backs == 1, "Back returns to the settings list")
	await status("unavailable")
	check(rows() == ["Bluetooth is unavailable.", "Try again", "Back"], "missing adapter or services")
	# The worker gives the cause. Control characters do not reach the label.
	write("bluetooth.error", "The Bluetooth radio did not turn on\t(org.bluez.Error.Blocked).\n")
	await poll()
	check(rows() == ["The Bluetooth radio did not turn on (org.bluez.Error.Blocked).", "Try again", "Back"], "cause of the failure")
	await choose("Try again")
	check(requests() == ["on"], "the user starts a retry")
	DirAccess.remove_absolute(run.path_join("bluetooth.error"))
	await press("ui_down")

	await status("off")
	check(rows() == ["Bluetooth: Off", "Back"] and focused() == "Back", "radio off, the focus stays on its row")
	await press("ui_up")
	check(focused() == "Bluetooth: Off", "Up selects the power row")
	await press("ui_accept")
	check(requests() == ["on"], "A turns the radio on")
	await status("starting")
	check(rows()[0] == "Bluetooth: Turning on…" and focused() == rows()[0], "the focus stays on the power row")

	objects = {
		"/org/bluez": {"org.bluez.AgentManager1": {}},
		"/org/bluez/hci0": {"org.bluez.Adapter1": {"Address": "00:11:22:33:44:55", "Powered": true, "Discovering": false}},
		"/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF": {"org.bluez.Device1": {"Address": HEADSET, "Name": "Head \"set\" \\ one", "Alias": "Head \"set\" \\ one", "Paired": false, "Connected": false, "RSSI": -60, "Adapter": "/org/bluez/hci0"}},
		# Another interface of a device also has a Connected property.
		"/org/bluez/hci0/dev_11_22_33_44_55_66": {"org.bluez.Device1": {"Name": "Pad", "Alias": "Pad", "Paired": true, "Connected": false}, "org.bluez.MediaControl1": {"Connected": true}},
		"/org/bluez/hci0/dev_11_22_33_44_55_66/service0001": {"org.bluez.GattService1": {"Primary": true}},
		"/org/bluez/hci0/dev_22_22_22_22_22_22": {"org.bluez.Device1": {"Address": "22:22:22:22:22:22", "Paired": false, "RSSI": -80}},
		"/org/bluez/hci0/dev_33_33_33_33_33_33": {"org.bluez.Device1": {"Name": "Pad", "Alias": "Pad", "Paired": false}},
	}
	await state()
	await status("on")
	check(rows() == ["Bluetooth: On", "Pad (55:66): Paired", "Add accessory", "Back"], "paired list")
	await press("ui_up")
	check(focused() == "Back", "Up on the first row goes to the last row")
	await press("ui_down", 2)
	check(focused() == "Pad (55:66): Paired", "Down selects a row")
	await press("ui_left")
	check(focused() == "Pad (55:66): Paired", "Left keeps the focus on the page")

	# Discovery starts only when the agent is ready. The list shows named
	# accessories in range that are not paired.
	await agent(false)
	await choose("Add accessory")
	check(requests() == [] and rows()[0].begins_with("Searching…"), "scan waits for the agent")
	await event("ready")
	check(requests() == ["scan on"], "bounded discovery starts")
	objects["/org/bluez/hci0"]["org.bluez.Adapter1"]["Discovering"] = true
	await state()
	check(rows() == ["Searching… Put the accessory in pairing mode.", "Head \"set\" \\ one (EE:FF)", "Cancel"], "nearby list")
	objects["/org/bluez/hci0"]["org.bluez.Adapter1"]["Discovering"] = false
	device(HEADSET).erase("RSSI")
	await state()
	check(rows() == ["Search finished.", "Head \"set\" \\ one (EE:FF)", "Search again", "Cancel"], "found accessories stay after discovery stops")

	await choose("Head \"set\" \\ one (EE:FF)")
	check(rows()[0] == "Pair with Head \"set\" \\ one (EE:FF)?" and focused() == "Pair", "explicit Pair confirmation")
	check(requests() == [], "selection alone does not pair")
	await press("ui_accept")
	check(requests() == ["scan off", "pair " + HEADSET], "pairing starts for the selected accessory only")
	check(rows() == ["Pairing with Head \"set\" \\ one (EE:FF)…", "Cancel"] and focused() == "Cancel", "pairing view")

	# Events for other devices and other commands do not change this attempt.
	await event("rejected /org/bluez/hci0/dev_99_99_99_99_99_99 RequestConfirmation")
	await event("prompt confirm %s 999999" % STRANGER)
	await event("result pair %s ok" % STRANGER)
	await event("result connect %s ok" % HEADSET)
	check(rows()[0].begins_with("Pairing with") and requests() == [], "foreign events are ignored")
	await event("prompt confirm %s 123456" % HEADSET)
	check(rows() == ["Does Head \"set\" \\ one (EE:FF) show 123456?", "Accept", "Reject", "Cancel"], "numeric comparison")
	await choose("Accept")
	check(requests() == ["answer yes"] and rows()[0].begins_with("Pairing with"), "Accept answers the agent")
	device(HEADSET)["Paired"] = true
	await state()
	await event("result pair %s ok" % HEADSET)
	check(requests() == ["trust " + HEADSET, "connect " + HEADSET], "a confirmed bond is trusted and connected")
	check(rows()[0].begins_with("Connecting to"), "connecting view")

	# A failed connection keeps the bond. Connect does not pair again.
	await event("result connect %s error org.bluez.Error.Failed" % HEADSET)
	check(rows() == ["Could not connect.", "Head \"set\" \\ one (EE:FF)", "Connect", "Forget", "Back"], "connect failure after pairing")
	await choose("Connect")
	check(requests() == ["connect " + HEADSET], "Connect alone")
	device(HEADSET)["Connected"] = true
	await state()
	await event("result connect %s ok" % HEADSET)
	check(rows() == ["Connected.", "Head \"set\" \\ one (EE:FF)", "Disconnect", "Forget", "Back"], "connected")
	await choose("Disconnect")
	check(requests() == ["disconnect " + HEADSET], "Disconnect")
	page.go_back()
	await process_frame
	check(rows()[1] == "Head \"set\" \\ one (EE:FF): Connected" and rows()[2] == "Pad (55:66): Paired", "paired list shows the link state")

	# Forget asks first. Cancel has the focus.
	await choose("Pad (55:66): Paired")
	await choose("Forget")
	check(rows()[0] == "Forget Pad (55:66)? You must pair it again to use it." and focused() == "Cancel", "Forget confirmation")
	check(requests() == [], "no removal before the confirmation")
	await choose("Forget")
	check(requests() == ["remove " + PAD] and page._view == "main", "Forget removes the bond")

	# A code prompt, then Cancel. Cancel replaces the agent.
	device(HEADSET)["Paired"] = false
	device(HEADSET)["Connected"] = false
	device(HEADSET)["RSSI"] = -50
	await state()
	await choose("Add accessory")
	await poll()
	await choose("Head \"set\" \\ one (EE:FF)")
	await choose("Pair")
	requests()
	await event("prompt pin %s" % HEADSET)
	check(rows()[0] == "Enter the code for Head \"set\" \\ one (EE:FF): –" and not rows().has("Submit"), "code entry")
	await choose("1")
	await choose("2")
	await choose("3")
	await choose("Delete")
	check(rows()[0].ends_with(": 12") and focused() == "Delete", "digits and delete")
	await choose("Submit")
	check(requests() == ["answer 12"], "the code goes to the agent")
	await event("prompt display %s 654321" % HEADSET)
	check(rows()[0] == "Type 654321 on Head \"set\" \\ one (EE:FF). Then press Enter on it.", "code shown on the handheld")
	await event("canceled")
	check(rows()[0].begins_with("Pairing with"), "BlueZ withdraws a prompt")
	page.go_back()
	await process_frame
	check(requests() == ["reset"] and rows()[0] == "Canceled." and page._view == "scan", "Cancel stops the attempt")
	# The old agent is gone. A late line from it changes nothing.
	await event("result pair %s ok" % HEADSET)
	check(requests() == [] and page._view == "scan", "a late result of a canceled attempt is ignored")
	await agent()

	# A rejected code, a timeout and an agent restart end the attempt.
	await choose("Head \"set\" \\ one (EE:FF)")
	await choose("Pair")
	await event("result pair %s error org.bluez.Error.AuthenticationFailed" % HEADSET)
	check(rows()[0] == "The code was wrong or the accessory refused." and page._view == "scan", "rejected code")
	await choose("Head \"set\" \\ one (EE:FF)")
	await choose("Pair")
	requests()
	page._deadline = 0
	await poll()
	check(requests() == ["reset"] and rows()[0] == "The accessory did not respond.", "pairing timeout")
	await agent()
	await choose("Head \"set\" \\ one (EE:FF)")
	await choose("Pair")
	await event("prompt confirm %s 111111" % HEADSET)
	await agent()
	check(rows()[0] == "Interrupted." and not rows().has("Accept"), "sleep or a worker restart drops the prompt")
	requests()

	# Back leaves discovery. Hide and free tell the worker to stop the agent.
	await choose("Search again")
	await poll()
	check(requests() == ["scan on"], "search again")
	page.go_back()
	await process_frame
	check(requests() == ["scan off"] and page._view == "main" and backs == 1, "Back stops discovery")
	await status("off")
	check(rows() == ["Bluetooth: Off", "Back"], "radio switched off")
	page.hide()
	check(requests() == ["close"], "a hidden page stops the agent")
	page.show()
	await process_frame
	await process_frame
	check(requests() == ["open"] and focused() == "Bluetooth: Off", "a shown page takes the focus")
	page.go_back()
	check(backs == 2, "Back on the first view leaves the page")
	page.queue_free()
	await process_frame
	await process_frame
	check(requests() == ["close"], "a freed page stops the agent")

	# The route watcher selects the headset device only when it is listed.
	var watcher = load("res://addons/FrontendPlugin/bluetooth_audio.gd").new()
	root.add_child(watcher)
	write("bluetooth.audio", HEADSET + "\n")
	watcher._poll_at = 0
	await process_frame
	check(watcher._applied == "Default" and AudioServer.output_device == "Default", "no listed headset device")
	watcher._apply("plughw_socket_bluetooth;Bluetooth headset")
	watcher.release()
	check(watcher._applied == "Default", "release before a game")
	watcher.queue_free()
	print("PASS: Bluetooth settings page, %d checks" % checks)
	quit(0)
