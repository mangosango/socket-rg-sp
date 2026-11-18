extends Node

# Device Settings during a game. RetroArch keeps the display. This node shows
# the same device_settings.gd panel as the launcher, draws it offscreen and
# gives the pixels to RetroArch. frontend_bridge.gd adds this node for the time
# of one game, and only when the engine has an offscreen GL context.
#
# Files in SOCKET_RUN:
# - menu.input (RetroArch writes, append only): the lines "session <token> 2",
#   "open <id>", "close <id>" and "pad <name> <0|1>". RetroArch is the only
#   reader of the pad. MENU is not sent: RetroArch sends "close".
#   While RetroArch has the pad on one of its pages, it sends one line for
#   each change: "view <id> <selected> <first> <total> <title> <status> <row>
#   ...". Each string is UTF-8 as hex, 120 bytes at most. "-" is an empty
#   string. There are six rows at most, selected is an index of them, and
#   first is the index of the first row in the full list. "root <id>" shows
#   the main list again. After a sleep, "view" can follow "open" directly.
#   The panel shows these lines. A line that is not correct is ignored.
# - menu.frame (this node writes, with a rename): a 28-byte header and the
#   RGBA pixels of the full screen, top row first. Header, little-endian:
#   "SKMF", version 1, open id, frame number, width, height, flags. Flag bit 0
#   is set: the alpha is premultiplied. Transparent pixels show the game.
#   Flag bits 8 to 31 are the number of "view" and "root" lines of this open
#   that the frame shows. Each such line gives one new frame or more, so
#   RetroArch can ignore a frame that is older than its last line.
# - menu.event (this node writes, with a rename): "<id> <n> <word>". The word
#   is close (B on the main list), game or cheats (A on that row). RetroArch
#   shows its Game and Cheats pages itself.
#
# - menu.theme (this node writes, before the first frame of each open):
#   "2 <surface rrggbb> <ink rrggbb> <x> <y> <width> <height> <radius>". The
#   native pages of RetroArch use these colors. Version 2 tells RetroArch that
#   this node shows "view" lines. An older RetroArch has no "2" in its session
#   line and reads version 1 only, so it gets "1" as the first field.
#
# A frame is written only after a redraw that changed the pixels. While the
# menu is closed, this node only reads the size of menu.input.

const PAD := {
	"up": JOY_BUTTON_DPAD_UP, "down": JOY_BUTTON_DPAD_DOWN, "left": JOY_BUTTON_DPAD_LEFT, "right": JOY_BUTTON_DPAD_RIGHT,
	"a": JOY_BUTTON_A, "b": JOY_BUTTON_B, "x": JOY_BUTTON_X, "y": JOY_BUTTON_Y,
	"l": JOY_BUTTON_LEFT_SHOULDER, "r": JOY_BUTTON_RIGHT_SHOULDER,
}
# Main loop sleep while the window cannot draw. The first value sets the
# longest wait for a MENU tap and for the game exit. Tune both on the device.
const IDLE_USEC := 33000
const MENU_USEC := 8000
# Minimum time between two frames, for a page that changes continuously.
const FRAME_MSEC := 33
# Main loop sleep while socket-hardware has stopped the game for a sleep.
const SLEEP_USEC := 500000

var hud: Node

var _run_dir: String = OS.get_environment("SOCKET_RUN") if OS.has_environment("SOCKET_RUN") else "/tmp/socket"
var _sleep_usec: int
var _offset: int = 0
var _id: int = 0
var _frame: int = 0
var _version: int = 1
var _views: int = 0
var _views_sent: int = 0
var _event: int = 0
var _panel: Node
var _pixels: PackedByteArray
var _drawn: int = -1
var _published_at: int = 0
var _paced_at: int = 0
var _down: Dictionary = {}
var _hex := RegEx.create_from_string("^([0-9a-fA-F]{2}){0,120}$")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_sleep_usec = OS.low_processor_usage_mode_sleep_usec
	OS.low_processor_usage_mode_sleep_usec = IDLE_USEC
	# RetroArch makes a new menu.input for each game. Do not read an old one.
	for file_name in ["menu.input", "menu.frame", "menu.event", "menu.theme"]:
		DirAccess.remove_absolute(_run_dir.path_join(file_name))


func _exit_tree() -> void:
	OS.low_processor_usage_mode_sleep_usec = _sleep_usec


func _process(_delta: float) -> void:
	# Publish before the read: a new panel gets its layout after its first frame.
	# RetroArch waits for the frame of its last "view" or "root" line, so that
	# frame has no minimum time. The line came in the _process before this
	# one, and the panel made its layout after that _process.
	if is_instance_valid(_panel) and (_views != _views_sent or Time.get_ticks_msec() - _published_at >= FRAME_MSEC and (RenderingServer.has_changed() or Engine.get_frames_drawn() != _drawn)):
		_publish()
	_read()
	# One time each second: a stopped game needs only a slow loop.
	var now := Time.get_ticks_msec()
	if now - _paced_at >= 1000:
		_paced_at = now
		if not is_instance_valid(_panel):
			OS.low_processor_usage_mode_sleep_usec = SLEEP_USEC if _game_stopped() else IDLE_USEC


# True while the game process has the stopped state, as during a sleep.
func _game_stopped() -> bool:
	var path := _run_dir.path_join("app.pid")
	if not FileAccess.file_exists(path):
		return false
	var file := FileAccess.open("/proc/%s/stat" % FileAccess.get_file_as_string(path).strip_edges(), FileAccess.READ)
	if file == null:
		return false
	# "<pid> (<name>) <state> ...": the name can contain spaces.
	var stat := file.get_line()
	return stat.substr(stat.rfind(")") + 2, 1) == "T"


func _read() -> void:
	var path := _run_dir.path_join("menu.input")
	var size := FileAccess.get_size(path) if FileAccess.file_exists(path) else 0
	if size < _offset:
		_offset = 0
	if size <= _offset:
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	file.seek(_offset)
	var data := file.get_buffer(size - _offset)
	# Use complete lines only.
	var end := data.rfind(10)
	if end < 0:
		return
	_offset += end + 1
	for line in data.slice(0, end).get_string_from_ascii().split("\n"):
		var parts := line.split(" ")
		if parts[0] == "session":
			_version = 2 if parts.size() == 3 and parts[2] == "2" else 1
			_close()
		elif parts[0] == "close":
			_close()
		elif parts[0] == "open" and parts.size() == 2 and parts[1].is_valid_int() and parts[1].to_int() > 0:
			_close()
			_open(parts[1].to_int())
		elif parts[0] == "pad" and parts.size() == 3 and is_instance_valid(_panel) and PAD.has(parts[1]):
			_pad(parts[1], parts[2] == "1")
		elif parts[0] == "view" and is_instance_valid(_panel):
			_view(parts)
		elif parts[0] == "root" and parts.size() == 2 and parts[1] == str(_id) and is_instance_valid(_panel):
			_panel.show_root()
			_views += 1


# Show one "view" line. Ignore a line that is not correct.
func _view(parts: PackedStringArray) -> void:
	if parts.size() < 7 or parts.size() > 13 or parts[1] != str(_id):
		return
	for index in range(2, 5):
		if parts[index].length() > 9 or not parts[index].is_valid_int() or parts[index].to_int() < 0:
			return
	var texts := PackedStringArray()
	for index in range(5, parts.size()):
		var hex := "" if parts[index] == "-" else parts[index]
		if _hex.search(hex) == null:
			return
		texts.append(hex.hex_decode().get_string_from_utf8())
	_panel.show_view(parts[2].to_int(), parts[3].to_int(), parts[4].to_int(), texts[0], texts[1], texts.slice(2))
	_views += 1


func _open(id: int) -> void:
	_id = id
	_frame = 0
	_views = 0
	_views_sent = 0
	_published_at = 0
	_pixels = PackedByteArray()
	_panel = load("res://addons/FrontendPlugin/device_settings.gd").new()
	_panel.name = "DeviceSettings"
	_panel.hud = hud
	_panel.game = true
	_panel.game_event.connect(_send)
	get_tree().root.add_child(_panel)
	OS.low_processor_usage_mode_sleep_usec = MENU_USEC


# frontend_bridge.gd calls this function before it removes the node.
func stop() -> void:
	_close()


func _close() -> void:
	for pad_name in _down.keys():
		_pad(pad_name, false)
	# Free it now: its pages stop their radio work and erase the typed text.
	if is_instance_valid(_panel):
		_panel.free()
	_panel = null
	_id = 0
	for file_name in ["menu.frame", "menu.theme"]:
		DirAccess.remove_absolute(_run_dir.path_join(file_name))
	OS.low_processor_usage_mode_sleep_usec = IDLE_USEC


func _pad(pad_name: String, pressed: bool) -> void:
	if pressed:
		_down[pad_name] = true
	else:
		_down.erase(pad_name)
	var event := InputEventJoypadButton.new()
	event.device = 0
	event.button_index = PAD[pad_name]
	event.pressed = pressed
	event.pressure = 1.0 if pressed else 0.0
	Input.parse_input_event(event)


func _send(word: String) -> void:
	_event += 1
	_write("menu.event", ("%d %d %s\n" % [_id, _event, word]).to_ascii_buffer())


func _publish() -> void:
	# The window cannot draw during a game, so the main loop does not draw.
	RenderingServer.force_draw(false)
	_drawn = Engine.get_frames_drawn()
	var image: Image = _panel.frame()
	if image == null or image.is_empty():
		return
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	var pixels := image.get_data()
	if pixels == _pixels and _views == _views_sent:
		return
	_pixels = pixels
	_views_sent = _views
	if _frame == 0:
		_write("menu.theme", ("%d %s\n" % [_version, _panel.look()]).to_ascii_buffer())
	_published_at = Time.get_ticks_msec()
	_frame += 1
	var data := PackedByteArray()
	data.resize(28)
	data.encode_u32(0, 0x464d4b53)
	var fields := [1, _id, _frame, image.get_width(), image.get_height(), 1 | (_views & 0xffffff) << 8]
	for index in fields.size():
		data.encode_u32(4 + index * 4, fields[index])
	data.append_array(pixels)
	_write("menu.frame", data)


func _write(file_name: String, data: PackedByteArray) -> void:
	var path := _run_dir.path_join(file_name)
	var file := FileAccess.open(path + ".new", FileAccess.WRITE)
	if file == null:
		return
	file.store_buffer(data)
	file.close()
	DirAccess.rename_absolute(path + ".new", path)
