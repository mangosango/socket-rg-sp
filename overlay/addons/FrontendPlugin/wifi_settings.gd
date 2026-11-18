extends VBoxContainer

# Wi-Fi page of Device Settings. The Wi-Fi worker (wifi.sh) does all radio
# work. This page writes numbered requests into the session run folder and
# reads the worker status from it. A result with an older number is ignored.
signal back_requested

const POLL := 0.25
# Seconds. These limits are longer than the limits of the worker.
const SCAN_TIMEOUT := 30.0
const JOIN_TIMEOUT := 90.0
const REPLY_TIMEOUT := 8.0
const ERRORS := {
	"invalid": "The card format cannot store this name or password.",
	"auth": "The network rejected the password.",
	"notfound": "The network was not found.",
	"dhcp": "The network gave no address. DHCP failed.",
	"save": "The card could not save the change.",
	"timeout": "Wi-Fi did not answer. Try again.",
	"canceled": "Canceled.",
	"off": "Wi-Fi is off.",
	"external": "BaseOS manages Wi-Fi on this device.",
}
const LETTERS: Array[String] = ["1234567890", "qwertyuiop", "asdfghjkl'", "zxcvbnm,.-"]
const SYMBOLS: Array[String] = ["1234567890", "!@#$%&*()?", "_+=/\\:;\"~|", "[]{}<>^`,."]

var _run := OS.get_environment("SOCKET_RUN") if OS.has_environment("SOCKET_RUN") else "/tmp/socket"
var _view := "main"
var _status := {}
var _sent := 0
# The action that waits for the result of request _sent.
var _waiting := ""
var _deadline := 0
var _clock := 0.0
var _networks: Array[Dictionary] = []
var _target := ""
var _hidden := false
var _note := ""
var _ssid := LineEdit.new()
var _psk := LineEdit.new()
# State of the keyboard of this page. All Socket versions use it.
var _field: LineEdit
var _preview: Label
var _caps := false
var _symbols := false
# Device Settings supplies the style for list rows and keyboard keys.
var row_style := Callable()


func _ready() -> void:
	_ssid.placeholder_text = "Network name"
	_psk.placeholder_text = "Password"
	_psk.secret = true
	for field: LineEdit in [_ssid, _psk]:
		field.virtual_keyboard_enabled = false
		field.context_menu_enabled = false
		field.gui_input.connect(_field_input.bind(field))
	visibility_changed.connect(_visibility_changed)
	_visibility_changed()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for field in [_ssid, _psk]:
			if is_instance_valid(field) and not field.is_inside_tree():
				field.free()


func _exit_tree() -> void:
	_leave()


func _visibility_changed() -> void:
	if is_visible_in_tree():
		_read_status()
		_show("main")
	else:
		_leave()


# Stop a pending scan or join and discard the typed password.
func _leave() -> void:
	if _waiting in ["scan", "join"]:
		_send("cancel")
	_waiting = ""
	_note = ""
	_view = "main"
	for field in [_ssid, _psk]:
		if is_instance_valid(field):
			field.text = ""


func _process(delta: float) -> void:
	_clock += delta
	if _clock < POLL or not is_visible_in_tree():
		return
	_clock = 0.0
	var before := _status
	_read_status()
	if _waiting != "":
		if int(_status.get("id", "0")) == _sent and _status.get("result", "pending") != "pending":
			_finish(_status["result"])
		elif Time.get_ticks_msec() > _deadline:
			var pending := _waiting in ["scan", "join"]
			_waiting = ""
			if pending:
				_send("cancel")
			_waiting = "join" if _view == "busy" else "other"
			_read_status()
			_finish("timeout")
	elif _view == "main" and _status != before:
		_render()


func _read_status() -> void:
	_status = {}
	for line in FileAccess.get_file_as_string(_run.path_join("wifi.status")).split("\n", false):
		var pair := line.split("=", true, 1)
		if pair.size() == 2:
			_status[pair[0]] = pair[1]


# Replace the file in one step. Only this user can read it.
func _write(path: String, text: String) -> bool:
	var file := FileAccess.open(path + ".new", FileAccess.WRITE)
	if file == null:
		return false
	FileAccess.set_unix_permissions(path + ".new", FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	file.store_string(text)
	file.close()
	return DirAccess.rename_absolute(path + ".new", path) == OK


func _send(action: String, candidate := "") -> void:
	_read_status()
	_sent = maxi(_sent, int(_status.get("id", "0"))) + 1
	_waiting = action
	var limit := JOIN_TIMEOUT if action == "join" else SCAN_TIMEOUT if action == "scan" else REPLY_TIMEOUT
	_deadline = Time.get_ticks_msec() + int(limit * 1000)
	# The password goes into a private file, not into a command line.
	if (candidate != "" and not _write(_run.path_join("wifi.candidate"), candidate)) or not _write(_run.path_join("wifi.request"), "%d %s\n" % [_sent, action]):
		_deadline = 0


func _finish(result: String) -> void:
	var action := _waiting
	_waiting = ""
	var error: String = "" if result == "ok" else ERRORS.get(result, ERRORS["timeout"])
	_read_status()
	if action == "scan":
		_networks = parse_scan(FileAccess.get_file_as_string(_run.path_join("wifi.scan"))) if result == "ok" else []
		_note = error
		_show("networks")
	elif action == "cancel" and not (_status.get("state") == "connected" and _status.get("saved") == _target):
		_note = ERRORS["canceled"]
		_show("form")
	elif action == "join" and result != "ok":
		_note = error
		_show("form")
	else:
		if action in ["join", "cancel"]:
			_ssid.text = ""
			_psk.text = ""
		_note = error
		_show("main")


# Return the networks of a wpa_cli scan_results table. The strongest is first.
static func parse_scan(text: String) -> Array[Dictionary]:
	var best := {}
	for line in text.split("\n", false).slice(1):
		var cells := line.split("\t")
		if cells.size() < 5:
			continue
		var ssid := _unescape(cells[4])
		# A hidden network has an empty name or a name of zero bytes.
		if ssid.is_empty() or ssid.unicode_at(0) == 0 or (best.has(ssid) and best[ssid]["signal"] >= int(cells[2])):
			continue
		var flags := cells[3]
		var supported := false
		for group in flags.split("]", false):
			supported = supported or (group.begins_with("[WPA2-") and group.contains("PSK"))
		var security := "WPA2"
		if not supported:
			security = "WPA3" if flags.contains("SAE") else "Enterprise" if flags.contains("EAP") else "WPA" if flags.contains("[WPA") else "WEP" if flags.contains("WEP") else "Open"
		best[ssid] = {"ssid": ssid, "signal": int(cells[2]), "security": security, "supported": supported}
	var networks: Array[Dictionary] = []
	networks.assign(best.values())
	networks.sort_custom(func(a, b): return a["signal"] > b["signal"])
	return networks


# wpa_supplicant prints the bytes of a name with C escapes.
static func _unescape(text: String) -> String:
	var bytes := PackedByteArray()
	var codes := {"n": 10, "r": 13, "t": 9, "e": 27}
	var i := 0
	while i < text.length():
		var c := text[i]
		i += 1
		if c != "\\" or i >= text.length():
			bytes.append_array(c.to_utf8_buffer())
			continue
		c = text[i]
		i += 1
		if c == "x":
			bytes.append(text.substr(i, 2).hex_to_int())
			i += 2
		elif codes.has(c):
			bytes.append(codes[c])
		else:
			bytes.append_array(c.to_utf8_buffer())
	return bytes.get_string_from_utf8()


# Return the reason why Config/wifi.txt cannot store and give back these
# values. The rules are those of engine/wifi-config.c. Empty means valid.
static func check(ssid: String, psk: String) -> String:
	for item in [["network name", ssid], ["password", psk]]:
		var value: String = item[1]
		for byte in value.to_utf8_buffer():
			if byte < 32 or byte == 127:
				return "The %s has a character that the card cannot store." % item[0]
		if value != value.strip_edges():
			return "The %s cannot start or end with a space." % item[0]
	var name_size := ssid.to_utf8_buffer().size()
	if name_size < 1 or name_size > 32:
		return "The network name must be 1 to 32 bytes long."
	var key := psk.to_utf8_buffer()
	if key.size() < 8 or key.size() > 64:
		return "The password must be 8 to 63 characters long, or a key of 64 hexadecimal digits."
	if key.size() == 64:
		for c in psk:
			if not "0123456789abcdefABCDEF".contains(c):
				return "A password of 64 characters must be a key of hexadecimal digits."
	return ""


func _show(view: String, focus := 0) -> void:
	_view = view
	_render(focus)


func _focusable() -> Array[Node]:
	return find_children("*", "Control", true, false).filter(func(c): return c.focus_mode != Control.FOCUS_NONE)


# Build the rows of the current view. A negative focus keeps the focused row.
func _render(focus := -1) -> void:
	if focus < 0:
		focus = maxi(_focusable().find(get_viewport().gui_get_focus_owner() if is_inside_tree() else null), 0)
	for child in get_children():
		remove_child(child)
		if child != _ssid and child != _psk:
			child.queue_free()
	var state: String = _status.get("state", "")
	var saved: String = _status.get("saved", "")
	match _view:
		"main":
			_label(_summary(state, saved))
			if _note != "":
				_label(_note)
			if state in ["", "external"]:
				_row("Back", back_requested.emit)
			elif state == "off":
				_row("Wi-Fi: Off", _send.bind("on"), self, true)
			else:
				_row("Wi-Fi: On", _send.bind("off"), self, true)
				_row("Choose a network", _scan)
				if saved != "":
					if state != "connected":
						_row("Retry", _send.bind("reconnect"))
					_row("Forget %s" % saved, _show.bind("confirm"))
		"networks":
			if _waiting == "scan":
				_label("Searching for networks...")
				_row("Cancel", go_back)
			else:
				_label(_note if _note != "" else "No networks found." if _networks.is_empty() else "Choose a network.")
				for network in _networks:
					_row("%s  (%s%s)" % [network["ssid"], network["security"], "" if network["supported"] else ", not supported"], _choose.bind(network))
				_row("Enter network name", _open_form.bind("", true))
				_row("Search again", _scan)
		"form":
			_label("Join a hidden network" if _hidden else "Join %s" % _target)
			if _note != "":
				_label(_note)
			if _hidden:
				add_child(_ssid)
			add_child(_psk)
			_row("Join", _join)
			if _note != "" and saved != "":
				_row("Reconnect to %s" % saved, _reconnect)
		"busy":
			_label("Joining %s..." % _target)
			_row("Cancel", go_back)
		"confirm":
			_label("Forget %s? The device disconnects and removes the saved password." % saved)
			_row("Cancel", _show.bind("main"))
			_row("Forget", _forget)
		"keys":
			_preview = _label("")
			_refresh_preview()
			var grid := GridContainer.new()
			grid.columns = 10
			add_child(grid)
			for row in SYMBOLS if _symbols else LETTERS:
				for c in row:
					var key := c.to_upper() if _caps else c
					_row(key, _type.bind(key), grid)
			var bottom := HBoxContainer.new()
			add_child(bottom)
			_row("CAPS" if _caps else "Caps", func(): _caps = not _caps; _render(), bottom)
			_row("abc" if _symbols else "#+=", func(): _symbols = not _symbols; _render(), bottom)
			_row("Space", _type.bind(" "), bottom)
			_row("Delete", _delete, bottom)
			_row("Done", _close_keys, bottom)
	var rows := _focusable()
	if not rows.is_empty():
		_grab.call_deferred(rows[mini(focus, rows.size() - 1)])


# A later render can remove the row before this deferred call runs.
func _grab(row) -> void:
	if is_instance_valid(row) and row.is_visible_in_tree():
		row.grab_focus()


func _summary(state: String, saved: String) -> String:
	match state:
		"external":
			return "BaseOS manages Wi-Fi. " + ("Connected." if FileAccess.file_exists(_run.path_join("wifi.ready")) else "Not connected.")
		"off":
			return "Wi-Fi is off." + ("" if saved == "" else " Saved network: %s." % saved)
		"idle":
			return "Wi-Fi is on. No network is saved."
		"connecting":
			return "Connecting to %s..." % saved if saved != "" else "Connecting..."
		"connected":
			return "Connected to %s." % saved
	return "Wi-Fi is not available."


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(label)
	return label


func _row(text: String, action: Callable, parent: Node = self, is_switch: bool = false) -> void:
	var button := Button.new()
	button.text = text
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.pressed.connect(action)
	if row_style.is_valid():
		row_style.call(button, is_switch, parent != self)
	parent.add_child(button)


func _scan() -> void:
	_networks = []
	_note = ""
	_send("scan")
	_show("networks")


func _choose(network: Dictionary) -> void:
	if network["supported"]:
		_open_form(network["ssid"], false)
	else:
		_note = "This device joins WPA2-Personal networks only."
		_render()


func _open_form(ssid: String, hidden: bool) -> void:
	_target = ssid
	_hidden = hidden
	_ssid.text = ssid
	_psk.text = ""
	_note = ""
	_show("form")


func _join() -> void:
	_note = check(_ssid.text, _psk.text)
	if _note != "":
		_render()
		return
	_target = _ssid.text
	_send("join", "ssid=%s\npsk=%s\n" % [_ssid.text, _psk.text])
	_show("busy")


func _reconnect() -> void:
	_psk.text = ""
	_send("reconnect")
	_note = ""
	_show("main")


func _forget() -> void:
	_send("forget")
	_show("main")


func _field_input(event: InputEvent, field: LineEdit) -> void:
	if not event.is_action_pressed("ui_accept"):
		return
	field.accept_event()
	_field = field
	_caps = false
	_symbols = false
	_show("keys", 10)


func _refresh_preview() -> void:
	_preview.text = ("*".repeat(_field.text.length()) if _field.secret else _field.text) + "|"


func _type(key: String) -> void:
	_field.text += key
	_refresh_preview()


func _delete() -> void:
	_field.text = _field.text.left(-1)
	_refresh_preview()


func _close_keys() -> void:
	_show("form")
	_grab.call_deferred(_field)


# The parent calls this for the B button.
func go_back() -> void:
	match _view:
		"keys":
			if _field.text.is_empty():
				_close_keys()
			else:
				_delete()
		"busy":
			# The join can complete before the worker reads the cancel request.
			# _finish reads the status again when the worker answers.
			if _waiting == "join":
				_send("cancel")
		"form":
			_open_form("", false)
			_show("networks")
		"networks":
			if _waiting == "scan":
				_send("cancel")
				_waiting = ""
			_note = ""
			_show("main")
		"confirm":
			_show("main")
		_:
			back_requested.emit()
