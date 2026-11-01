extends CanvasLayer

var _view: Control
var _icons: Array[Texture2D] = []
# Version 2: sequence, volume, brightness, Slot screen temperature (0-9), kind.
var _record: = RegEx.create_from_string("^2 ([0-9]{1,10}) ([0-9]{1,3}) ([0-9]) ([0-9]) ([0-3])\\n\\z")
var _sequence: int = -1
var _volume: int = 40
var _brightness: int = 0
var _temperature: int = 0
var _tint: Control
var _kind: int = 0
var _shown_at: int = -1500
var _poll_at: int = 0
var _path: String
var _window_size: Vector2i


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 128
	_path = (OS.get_environment("SOCKET_RUN") if OS.has_environment("SOCKET_RUN") else "/tmp/socket").path_join("controls")
	for name in ["volume", "volume-zero", "brightness", "temperature"]:
		var image: = Image.new()
		if image.load_png_from_buffer(FileAccess.get_file_as_bytes("res://addons/FrontendPlugin/controls/" + name + ".png")) == OK:
			_icons.append(ImageTexture.create_from_image(image))
	_view = Control.new()
	_view.hide()
	_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view.draw.connect(_draw_hud)
	add_child(_view)
	# Slot warms the whole frame, HUD included, by multiplying each channel.
	_tint = Control.new()
	_tint.hide()
	_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var multiply: = CanvasItemMaterial.new()
	multiply.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
	_tint.material = multiply
	_tint.draw.connect(_draw_tint)
	add_child(_tint)
	_poll()


func _process(_delta: float) -> void:
	var now: = Time.get_ticks_msec()
	if now >= _poll_at:
		_poll_at = now + 50
		_poll()
	# Cancel Socket's logical UI scale so HUD coordinates stay in display pixels.
	var native_transform: = get_viewport().get_stretch_transform().affine_inverse()
	var window_size: = get_viewport().get_window().size
	if transform != native_transform or _window_size != window_size:
		_window_size = window_size
		transform = native_transform
		_view.queue_redraw()
		_tint.queue_redraw()
	_view.visible = now - _shown_at < 1500
	if _view.visible and now - _shown_at >= 1250:
		_view.queue_redraw()


func sync_after_game() -> void:
	# Consume changes from the game before the frontend resumes.
	_poll(false)
	_shown_at = -1500
	_view.hide()


func _poll(show_change: bool = true) -> void:
	if not FileAccess.file_exists(_path):
		return
	var file: = FileAccess.open(_path, FileAccess.READ)
	if file == null or file.get_length() > 40:
		return
	var record: = _record.search(file.get_as_text())
	if record == null:
		return
	var sequence: = record.get_string(1).to_int()
	var volume: = record.get_string(2).to_int()
	var brightness: = record.get_string(3).to_int()
	var temperature: = record.get_string(4).to_int()
	var kind: = record.get_string(5).to_int()
	if sequence > 4294967295 or volume > 100 or brightness > 9:
		return
	if sequence == _sequence:
		return
	var initial: = _sequence < 0
	_sequence = sequence
	_volume = volume
	_brightness = brightness
	_temperature = temperature
	_tint.visible = temperature > 0
	_tint.queue_redraw()
	_kind = kind
	AudioServer.set_bus_volume_linear(0, pow(float(volume) / 100.0, 2.0))
	if show_change and not initial and kind != 0:
		_shown_at = Time.get_ticks_msec()
		_view.queue_redraw()


func _draw_hud() -> void:
	var alpha: = clampf(float(1500 - (Time.get_ticks_msec() - _shown_at)) / 250.0, 0.0, 1.0)
	if alpha <= 0.0:
		return
	var x: = (get_viewport().get_window().size.x - 320.0) / 2.0
	_view.draw_rect(Rect2(0, 0, get_viewport().get_window().size.x, 40), Color(0, 0, 0, 0.72 * alpha))
	var icon: = _kind if _kind >= 2 else (1 if _volume == 0 else 0)
	if _icons.size() == 4:
		_view.draw_texture(_icons[icon], Vector2(x - 36.0, 6.5), Color(1, 1, 1, alpha))
	_view.draw_rect(Rect2(x, 17, 320, 6), Color(1, 1, 1, 0.18 * alpha))
	var fraction: = float(_volume) / 100.0
	if _kind == 2:
		fraction = float(_brightness) / 9.0
	elif _kind == 3:
		fraction = float(_temperature) / 9.0
	_view.draw_rect(Rect2(x, 17, 320 * fraction, 6), Color(245.0 / 255.0, 242.0 / 255.0, 239.0 / 255.0, alpha))


# Slot grade.rs: gain moves from white to [1.0, 0.82, 0.62] over steps 1 to 9.
static func temperature_gain(step: int) -> Color:
	var t: = clampf(float(step) / 9.0, 0.0, 1.0)
	return Color(1.0, 1.0 - 0.18 * t, 1.0 - 0.38 * t)


func _draw_tint() -> void:
	if _temperature > 0:
		_tint.draw_rect(Rect2(Vector2.ZERO, Vector2(get_viewport().get_window().size)), temperature_gain(_temperature))
