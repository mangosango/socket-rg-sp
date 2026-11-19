extends VBoxContainer

signal back_requested

const LETTERS: Array[String] = ["1234567890", "qwertyuiop", "asdfghjkl'", "zxcvbnm,.-"]
const SYMBOLS: Array[String] = ["1234567890", "!@#$%&*()?", "_+=/\\:;\"~|", "[]{}<>^`,."]

var _view := "main"
var _ssid := LineEdit.new()
var _psk := LineEdit.new()
# State of the keyboard of this page. All Socket versions use it.
var _field: LineEdit
var _preview: Label
var _caps := false
var _symbols := false
# Device Settings supplies the style for list rows and keyboard keys.
var row_style := Callable()


func _setup_fields() -> void:
	_psk.secret = true
	for field: LineEdit in [_ssid, _psk]:
		field.virtual_keyboard_enabled = false
		field.context_menu_enabled = false
		field.gui_input.connect(_field_input.bind(field))


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for field in [_ssid, _psk]:
			if is_instance_valid(field) and not field.is_inside_tree():
				field.free()


func _show(view: String, focus := 0) -> void:
	_view = view
	_render(focus)


func _focusable() -> Array[Node]:
	return find_children("*", "Control", true, false).filter(func(c): return c.focus_mode != Control.FOCUS_NONE)


func _render(_focus := -1) -> void:
	pass


func _clear_rows(focus: int) -> int:
	if focus < 0:
		focus = maxi(_focusable().find(get_viewport().gui_get_focus_owner() if is_inside_tree() else null), 0)
	for child in get_children():
		remove_child(child)
		if child != _ssid and child != _psk:
			child.queue_free()
	return focus


func _focus_row(focus: int) -> void:
	var rows := _focusable()
	if not rows.is_empty():
		_grab.call_deferred(rows[mini(focus, rows.size() - 1)])


func _grab(row) -> void:
	if is_instance_valid(row) and row.is_visible_in_tree():
		row.grab_focus()


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


func _keyboard() -> void:
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
