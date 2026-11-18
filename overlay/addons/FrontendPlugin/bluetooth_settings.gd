extends VBoxContainer

# Bluetooth page of Device Settings. The card worker bluetooth.sh does the
# radio work. This page writes request files and reads the worker's files.
# The parent overlay sends B to go_back().

signal back_requested

const PAIR_TIMEOUT := 60000
const CONNECT_TIMEOUT := 20000

var _run: String = OS.get_environment("SOCKET_RUN") if OS.has_environment("SOCKET_RUN") else "/tmp/socket"
var _view := "main"  # main, device, forget, scan, confirm, busy
var _phase := ""  # pair or connect, while the view is busy
var _status := ""
var _error := ""  # the cause that the worker gives for "unavailable"
var _adapter := {}
var _devices := {}  # address -> Device1 properties
var _found := {}  # addresses seen in range while the scan view is open
var _target := ""
var _message := ""
var _prompt := {}  # kind and code of the pending agent prompt
var _entry := ""
var _deadline := 0
var _want_scan := false
var _session := ""
var _agent_ready := false
var _offset := 0
var _tail := ""
var _sequence := 0
var _poll_at := 0
var _signature := ""
# Device Settings supplies the style for list rows and pairing keys.
var row_style := Callable()
var _device_path := RegEx.create_from_string("^/org/bluez/hci[0-9]+/dev_((?:[0-9A-F]{2}_){5}[0-9A-F]{2})$")
var _control := RegEx.create_from_string("[\\x00-\\x1f\\x7f]")


func _ready() -> void:
	visibility_changed.connect(_visibility_changed)
	_visibility_changed()


func _exit_tree() -> void:
	_request("close")


func _visibility_changed() -> void:
	if not is_inside_tree():
		return
	_view = "main"
	_message = ""
	_prompt = {}
	_want_scan = false
	if is_visible_in_tree():
		_request("open")
		_poll()
		_focus_first.call_deferred()
	else:
		# The worker stops the agent. BlueZ then cancels discovery and pairing.
		_request("close")


func _process(_delta: float) -> void:
	if is_visible_in_tree() and Time.get_ticks_msec() >= _poll_at:
		_poll_at = Time.get_ticks_msec() + 250
		_poll()


func go_back() -> void:
	match _view:
		"main":
			back_requested.emit()
			return
		"busy":
			_cancel("Canceled.")
		"scan":
			_request("scan off")
			_want_scan = false
			_view = "main"
		"confirm":
			_view = "scan"
		"forget":
			_view = "device"
		_:
			_view = "main"
			_message = ""
	_render()


func _request(text: String) -> void:
	_sequence = maxi(_sequence + 1, Time.get_ticks_usec())
	var temp := _run.path_join("bluetooth.tmp-request")
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return
	file.store_line(text)
	file.close()
	DirAccess.rename_absolute(temp, _run.path_join("bluetooth.request.%014d" % _sequence))


func _poll() -> void:
	_status = FileAccess.get_file_as_string(_run.path_join("bluetooth.status")).strip_edges()
	_error = _control.sub(FileAccess.get_file_as_string(_run.path_join("bluetooth.error")).strip_edges(), " ", true).left(160)
	_read_state(FileAccess.get_file_as_string(_run.path_join("bluetooth.state")))
	_read_log()
	if _status != "on" and _view != "main":
		_view = "main"
		_message = ""
	if _view == "busy" and Time.get_ticks_msec() >= _deadline:
		_cancel("The accessory did not respond.")
	if _view == "scan":
		for address in _devices:
			if _devices[address].has("RSSI"):
				_found[address] = true
		if _want_scan and _agent_ready:
			_want_scan = false
			_request("scan on")
	_render()


# Parse the text that dbus-send prints for GetManagedObjects.
func _read_state(text: String) -> void:
	_adapter = {}
	_devices = {}
	var path := ""
	var interface := ""
	var key := ""
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("object path \""):
			path = line.substr(13, line.length() - 14)
			interface = ""
			key = ""
		elif line.begins_with("string \""):
			key = line.substr(8, line.length() - 9)
		elif line == "array [" and key != "":
			interface = key
			key = ""
		elif line.begins_with("variant") and key != "":
			var value: Variant = line.trim_prefix("variant").strip_edges()
			if value.begins_with("boolean "):
				value = value == "boolean true"
			elif value.begins_with("string \""):
				value = value.substr(8, value.length() - 9)
			var device := _device_path.search(path)
			if interface == "org.bluez.Adapter1":
				_adapter[key] = value
			elif interface == "org.bluez.Device1" and device != null:
				var address := device.get_string(1).replace("_", ":")
				if not _devices.has(address):
					_devices[address] = {}
				_devices[address][key] = value
			key = ""


# Read the new events of socket-bluetooth-agent. Line 1 names its instance.
func _read_log() -> void:
	var file := FileAccess.open(_run.path_join("bluetooth.log"), FileAccess.READ)
	var session := "" if file == null else file.get_line()
	if session != _session:
		# The worker started a new agent. BlueZ canceled the work of the old
		# one, so a result of a canceled attempt cannot arrive.
		_session = session
		_offset = 0 if file == null else file.get_position()
		_tail = ""
		_agent_ready = false
		_prompt = {}
		if _view == "busy":
			_leave_busy("Interrupted.")
	if file == null or file.get_length() <= _offset:
		return
	file.seek(_offset)
	var lines := (_tail + file.get_buffer(file.get_length() - _offset).get_string_from_utf8()).split("\n")
	_offset = file.get_length()
	_tail = lines[-1]
	for index in lines.size() - 1:
		_read_event(lines[index].split(" "))


func _read_event(words: PackedStringArray) -> void:
	if words[0] == "ready":
		_agent_ready = true
	elif words[0] == "canceled":
		_prompt = {}
	# The agent rejects each request that is not for its target. Check the
	# address again: only the attempt on this page can change it.
	if _view != "busy" or words.size() < 3 or words[2] != _target:
		return
	if words[0] == "prompt":
		_prompt = {"kind": words[1], "code": words[3] if words.size() > 3 else ""}
		_entry = ""
	elif words[0] == "result" and words[1] == _phase and words.size() > 3:
		var error := words[4] if words.size() > 4 else ""
		if _phase == "connect":
			_leave_busy("Connected." if words[3] == "ok" else "Could not connect.")
		elif words[3] == "ok" or error.ends_with(".AlreadyExists"):
			_request("trust " + _target)
			_connect()
		elif error.ends_with(".AuthenticationFailed") or error.ends_with(".AuthenticationRejected"):
			_leave_busy("The code was wrong or the accessory refused.")
		else:
			_leave_busy("Pairing failed.")


func _pair() -> void:
	_request("scan off")
	_want_scan = false
	_request("pair " + _target)
	_begin("pair", PAIR_TIMEOUT)


func _connect() -> void:
	_request("connect " + _target)
	_begin("connect", CONNECT_TIMEOUT)


func _begin(phase: String, timeout: int) -> void:
	_view = "busy"
	_phase = phase
	_prompt = {}
	_message = ""
	_deadline = Time.get_ticks_msec() + timeout
	_render()


# Replace the agent. BlueZ cancels its pairing, prompt and discovery, and
# a late reply to the canceled attempt cannot arrive.
func _cancel(message: String) -> void:
	_request("reset")
	_leave_busy(message)


func _leave_busy(message: String) -> void:
	_prompt = {}
	_message = message
	# A failed connection keeps the bond. The device page offers Connect again.
	_view = "device" if _phase == "connect" else "scan"
	_render()


func _answer(text: String) -> void:
	_request("answer " + text)
	_prompt = {}
	_render()


func _name(address: String) -> String:
	var device: Dictionary = _devices.get(address, {})
	var name := _control.sub(str(device.get("Alias", device.get("Name", ""))), "", true).left(32)
	# The address suffix separates accessories that have the same name.
	return "%s (%s)" % [name if name != "" else "Accessory", address.right(5)]


func _open(view: String, address: String = _target) -> void:
	_view = view
	_target = address
	_message = ""
	if view == "scan":
		_found = {}
		_want_scan = true
	_render()


# Each row is [id, text] for a label or [id, text, action] for a button.
func _rows() -> Array:
	var rows := []
	var device: Dictionary = _devices.get(_target, {})
	if _message != "":
		rows.append(["message", _message])
	match _view:
		"main":
			if _status == "off":
				rows.append(["power", "Bluetooth: Off", _request.bind("on")])
			elif _status == "starting":
				rows.append(["power", "Bluetooth: Turning on…", _request.bind("off")])
			elif _status == "on":
				rows.append(["power", "Bluetooth: On", _request.bind("off")])
				for address in _sorted(func(item: Dictionary) -> bool: return item.get("Paired", false)):
					var state := "Connected" if _devices[address].get("Connected", false) else "Paired"
					rows.append([address, "%s: %s" % [_name(address), state], _open.bind("device", address)])
				rows.append(["add", "Add accessory", _open.bind("scan")])
			else:
				rows.append(["state", _error if _status == "unavailable" and _error != "" else "Bluetooth is unavailable."])
				if _status == "unavailable":
					rows.append(["retry", "Try again", _request.bind("on")])
			rows.append(["back", "Back", go_back])
		"device":
			rows.append(["name", _name(_target)])
			if device.get("Connected", false):
				rows.append(["link", "Disconnect", _request.bind("disconnect " + _target)])
			else:
				rows.append(["link", "Connect", _connect])
			rows.append(["forget", "Forget", _open.bind("forget")])
			rows.append(["back", "Back", go_back])
		"forget":
			rows.append(["question", "Forget %s? You must pair it again to use it." % _name(_target)])
			rows.append(["back", "Cancel", go_back])
			rows.append(["forget", "Forget", func() -> void:
				_request("remove " + _target)
				_open("main")])
		"scan":
			var searching: bool = _want_scan or _adapter.get("Discovering", false)
			rows.append(["state", "Searching… Put the accessory in pairing mode." if searching else "Search finished."])
			for address in _sorted(func(item: Dictionary) -> bool: return not item.get("Paired", false) and item.has("Name")):
				if _found.has(address):
					rows.append([address, _name(address), _open.bind("confirm", address)])
			if not searching:
				rows.append(["again", "Search again", _open.bind("scan")])
			rows.append(["back", "Cancel", go_back])
		"confirm":
			rows.append(["question", "Pair with %s?" % _name(_target)])
			rows.append(["pair", "Pair", _pair])
			rows.append(["back", "Cancel", go_back])
		"busy":
			match _prompt.get("kind", ""):
				"confirm":
					rows.append(["state", "Does %s show %s?" % [_name(_target), _prompt.code]])
					rows.append(["yes", "Accept", _answer.bind("yes")])
					rows.append(["no", "Reject", _answer.bind("no")])
				"display":
					rows.append(["state", "Type %s on %s. Then press Enter on it." % [_prompt.code, _name(_target)]])
				"pin", "passkey":
					rows.append(["state", "Enter the code for %s: %s" % [_name(_target), _entry if _entry != "" else "–"]])
					rows.append(["digits", ""])
					rows.append(["delete", "Delete", func() -> void:
						_entry = _entry.left(-1)
						_render()])
					if _entry != "":
						rows.append(["submit", "Submit", func() -> void: _answer(_entry)])
				_:
					rows.append(["state", ("Pairing with %s…" if _phase == "pair" else "Connecting to %s…") % _name(_target)])
			rows.append(["back", "Cancel", go_back])
	return rows


func _sorted(keep: Callable) -> Array:
	var addresses := _devices.keys().filter(func(address: String) -> bool: return keep.call(_devices[address]))
	addresses.sort_custom(func(a: String, b: String) -> bool: return _name(a).naturalnocasecmp_to(_name(b)) < 0)
	return addresses


func _digit(digit: int) -> void:
	# A passkey has 6 digits. A legacy PIN has a maximum of 16.
	# shortcut: digits only. Add letters if an accessory needs a text PIN.
	if _entry.length() < (6 if _prompt.get("kind", "") == "passkey" else 16):
		_entry += str(digit)
		_render()


func _render() -> void:
	var rows := _rows()
	var signature := _view + str(rows.map(func(row: Array) -> Array: return row.slice(0, 2)))
	if signature == _signature:
		return
	_signature = signature
	var owner_now := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var had_focus := owner_now != null and is_ancestor_of(owner_now)
	var focused: String = owner_now.get_meta("row", "") if had_focus else ""
	for child in get_children():
		remove_child(child)
		child.queue_free()
	var buttons: Array[Button] = []
	for row in rows:
		var id: String = _view + ":" + row[0]
		if row[0] == "digits":
			var digits := HBoxContainer.new()
			add_child(digits)
			for digit in 10:
				var key := _button(id + str(digit), str(digit), _digit.bind(digit), true)
				key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				digits.add_child(key)
				buttons.append(key)
		elif row.size() == 3:
			var button := _button(id, row[1], row[2])
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			# Keep the D-pad inside this page.
			button.focus_neighbor_left = NodePath(".")
			button.focus_neighbor_right = NodePath(".")
			add_child(button)
			buttons.append(button)
		else:
			var label := Label.new()
			label.text = row[1]
			label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			add_child(label)
	buttons[0].focus_neighbor_top = buttons[0].get_path_to(buttons[-1])
	buttons[-1].focus_neighbor_bottom = buttons[-1].get_path_to(buttons[0])
	if had_focus:
		var target := buttons[0]
		for button in buttons:
			if button.get_meta("row") == focused:
				target = button
		target.grab_focus()


func _button(id: String, text: String, action: Callable, compact: bool = false) -> Button:
	var button := Button.new()
	button.text = text
	button.set_meta("row", id)
	button.pressed.connect(action)
	if row_style.is_valid():
		row_style.call(button, id == "main:power", compact)
	return button


func _focus_first() -> void:
	for child in get_children():
		if child is Button and is_visible_in_tree():
			child.grab_focus()
			return
