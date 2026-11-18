extends CanvasLayer

# Device Settings: a controller panel above the current launcher screen.
# MENU opens it, and closes it from each page. socket-hardware does not send
# MENU to the launcher. frontend_bridge.gd adds the panel as the last child of the root.
#
# While the panel is open:
# - The scene tree is paused. The panel is the last child of the root, so it
#   gets each input event first. It marks each event as handled, so no action
#   reaches the launcher.
# - The panel has its own SubViewport, so panel navigation cannot move the
#   launcher focus. Focus in the SubViewport can clear the launcher focus
#   owner. The panel restores that owner when it closes. The selected
#   cartridge and the scroll position do not change.
# - Pad input goes to the SubViewport only.
# - Socket's input map has no pad buttons for ui_accept and ui_cancel. Socket's
#   GUIDE node makes these actions from the A and B buttons, with the layout
#   that the user selected. GUIDE reads unhandled input only, so the panel
#   gives each pad event to GUIDE. The actions come back as root input events.
#   Socket 0.10.1 sends them through Input. Older versions push them to the
#   root viewport. The panel gets both.
#
# A radio row loads a script that extends VBoxContainer. The script has the
# signal back_requested and the method go_back(). B calls go_back(). The
# subpanel emits back_requested to show the main list again. A subpanel gets
# its input and focus in the SubViewport. Launcher screens do not run.
#
# During a game, game_overlay.gd shows this panel with game = true. RetroArch
# draws the pixels of the SubViewport (see frame()). The list then has the rows
# Game and Cheats. These rows, and B on the main list, emit game_event.
# RetroArch shows its own page or closes the menu.
#
# RetroArch keeps the pad and the state of its pages (Game, Cheats and the
# pages below them). It sends a snapshot of the visible rows for each change.
# show_view() shows the snapshot with the widgets of this panel. show_root()
# shows the main list again, with the focus on the row that had it.
#
# Text: the SubViewport has the pixels of the display and the layout size of
# Socket, so a 46-unit label has 17.25 pixels on the 720x480 panel. Glyphs
# drawn at that size are soft: Departure Mono has a grid of 11 pixels, and a
# glyph position is not a whole pixel. The panel asks for larger glyphs (see
# _glyph_scale()) and the linear filter reduces them. The layout, the text
# sizes and the number of drawn pixels do not change.

signal closed
signal game_event(word: String)

const RADIOS := {
	"Wi-Fi": "res://addons/FrontendPlugin/wifi_settings.gd",
	"Bluetooth": "res://addons/FrontendPlugin/bluetooth_settings.gd",
}
# Request name, minimum, maximum and step of each level row.
const LEVELS := {"Brightness": ["brightness", 1, 10, 1], "Volume": ["volume", 0, 100, 5]}
const TITLE := "Device Settings"
const MSAA := "Cartridge edge smoothing"
const MSAA_KEY := "cartridge_msaa"
# The titles of the pages that RetroArch opens from the Cheats row.
const CHEATS_TITLES := ["Cheats", "Cheat files", "libretro cheat titles"]

var hud: Node
var game: bool = false

var _run_dir: String = OS.get_environment("SOCKET_RUN") if OS.has_environment("SOCKET_RUN") else "/tmp/socket"
var _root: Window
var _guide: Node
var _was_paused: bool
var _launcher_focus: Control
var _logical: Vector2
var _unit: float
var _ink: Color
var _surface: Color
var _container: SubViewportContainer
var _gui: SubViewport
var _card: PanelContainer
var _title: Label
var _list: VBoxContainer
var _body: VBoxContainer
var _rows: Dictionary = {}
var _sub: Control
var _scroll: ScrollContainer
var _sub_row: Control
var _view: VBoxContainer
var _view_rows: VBoxContainer
var _view_status: Label
var _root_row: Control
var _card_minimum: Vector2
# A press in this time after a game event is not used. See _game_row().
var _quiet_until: int = 0
# A row of RetroArch with a value: the label, two spaces or more, the value.
var _columns := RegEx.create_from_string("^(.*?\\S) {2,}(\\S.*)$")
var _cancel_down: bool = false
# Level rows: the shown value is the last value that socket-hardware applied.
var _shown: Dictionary = {"Brightness": 6, "Volume": 40}
var _wanted: Dictionary = {}
var _request: Dictionary = {}
var _token: int = int(Time.get_unix_time_from_system() * 1000.0)
var _sequence: int = -2
var _ack: = RegEx.create_from_string("^([0-9]{1,19}) (ok|error) ([0-9]{1,3})\\n\\z")
var _held: int = 0
var _repeat_at: int = 0
var _settings: Node


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Stay below the HUD layer, so the screen temperature tint covers the panel.
	layer = 127
	_root = get_tree().root
	_launcher_focus = _root.gui_get_focus_owner()
	_was_paused = get_tree().paused
	get_tree().paused = true
	_guide = get_node_or_null("/root/GUIDE")
	if _guide != null and not _guide.has_method("inject_input"):
		_guide = null
	if hud != null:
		hud.quiet = true
	_logical = _root.get_visible_rect().size
	_unit = _logical.y / 1280.0
	_build()
	_process(0.0)
	_rows["Game" if game else "Brightness"].grab_focus()


func _exit_tree() -> void:
	get_tree().paused = _was_paused
	if is_instance_valid(_launcher_focus) and _launcher_focus.is_visible_in_tree() and _root.gui_get_focus_owner() != _launcher_focus:
		_launcher_focus.grab_focus()
	if is_instance_valid(hud):
		hud.quiet = false


func close() -> void:
	if is_queued_for_deletion():
		return
	queue_free()
	closed.emit()


# MENU closes the panel from each page. If B is down, show the main list and
# close on the B release, so no part of the B press reaches the launcher.
func menu_close() -> void:
	if _cancel_down:
		_close_radio()
	else:
		close()


func _colors() -> void:
	_surface = Color.WHITE
	_ink = Color(0.13, 0.13, 0.13)
	# 0.3.2 has no palette. 0.8.0 has recolor only.
	if ResourceLoader.exists("res://scripts/theme_palette.gd"):
		var palette = load("res://scripts/theme_palette.gd").active()
		_surface = palette.call("recolor_surface" if palette.has_method("recolor_surface") else "recolor", _surface)
		_ink = palette.call("recolor_ink" if palette.has_method("recolor_ink") else "recolor", _ink)


func _socket_theme() -> Theme:
	var manager := get_node_or_null("/root/ThemeManager")
	if manager != null and manager.has_method("get_active_theme"):
		return manager.call("get_active_theme")
	# Older packs set the theme on each screen.
	var scene := get_tree().current_scene
	if scene != null:
		for node in [scene] + scene.find_children("*", "Control", true, false):
			if node is Control and node.theme != null:
				return node.theme
	# No Socket theme: keep the text legible in the logical layout.
	var plain := Theme.new()
	plain.default_font_size = roundi(44 * _unit)
	return plain


func _box(color: Color, radius: float, border: float = 0.0) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.draw_center = border == 0.0
	box.border_color = color
	box.set_border_width_all(roundi(border))
	box.set_corner_radius_all(roundi(radius))
	return box


func _build() -> void:
	_colors()
	_container = SubViewportContainer.new()
	_container.stretch = true
	_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_container)
	_gui = SubViewport.new()
	_gui.transparent_bg = true
	if game:
		# No visible window draws this viewport. game_overlay.gd starts each draw.
		_gui.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_container.add_child(_gui)
	var screen := ColorRect.new()
	screen.color = Color(0, 0, 0, 0.6)
	screen.theme = _socket_theme()
	_gui.add_child(screen)
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	screen.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	_card = panel
	var surface := _box(_surface, 48 * _unit)
	surface.set_content_margin_all(56 * _unit)
	panel.add_theme_stylebox_override("panel", surface)
	# The size is fixed. A radio page scrolls and cannot make the panel larger.
	panel.custom_minimum_size = _logical * Vector2(0.62, 0.72)
	# Socket does not change the colors of a control that has this mark.
	panel.set_meta("socket_adaptive_surface", true)
	center.add_child(panel)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", roundi(28 * _unit))
	panel.add_child(layout)
	_title = _label(TITLE)
	# A long page title of RetroArch must not make the panel wider.
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	layout.add_child(_title)
	_body = VBoxContainer.new()
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(_body)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", roundi(12 * _unit))
	_body.add_child(_list)
	var rows := ["Brightness", "Volume", "Wi-Fi", "Bluetooth"]
	if game:
		rows.append_array(["Game", "Cheats"])
	else:
		_settings = get_node_or_null("/root/SettingsManager")
		if _settings != null and _settings.has_method("cartridge_msaa_mode"):
			rows.append(MSAA)
	for row_name in rows:
		_list.add_child(_row(row_name))
	layout.add_child(_hint())


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", _ink)
	return label


func _button(text: String) -> Button:
	var row := Button.new()
	row.text = text
	_style(row)
	return row


# Give a row the look of the panel: the text and the focus outline.
func _style(row: Button, compact: bool = false) -> void:
	row.alignment = HORIZONTAL_ALIGNMENT_CENTER if compact else HORIZONTAL_ALIGNMENT_LEFT
	# The colors here are final. Socket must not change them a second time.
	row.set_meta("socket_adaptive_surface", true)
	var plain := StyleBoxEmpty.new()
	plain.set_content_margin_all((8 if compact else 28) * _unit)
	for style in ["normal", "hover", "pressed", "disabled"]:
		row.add_theme_stylebox_override(style, plain)
	# Like Socket's focus outline: a rounded border in the ink color.
	row.add_theme_stylebox_override("focus", _box(_ink, 24 * _unit, 5 * _unit))
	for color in ["font_color", "font_focus_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		row.add_theme_color_override(color, _ink)
	row.add_theme_color_override("font_disabled_color", Color(_ink, 0.45))


# The area at the right of a row. It holds the value of the row.
func _side(row: Button) -> HBoxContainer:
	var side := HBoxContainer.new()
	side.name = "Side"
	side.mouse_filter = Control.MOUSE_FILTER_IGNORE
	side.alignment = BoxContainer.ALIGNMENT_END
	side.add_theme_constant_override("separation", roundi(28 * _unit))
	row.add_child(side)
	side.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	side.offset_right = -28 * _unit
	return side


func _value(text: String) -> Label:
	var value := _label(text)
	value.name = "Value"
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return value


func _style_radio_row(row: Button, is_switch: bool, compact: bool) -> void:
	_style(row, compact)
	if is_switch:
		# Keep the full spoken name when the visible state moves to the right.
		row.accessibility_name = row.text
		_side(row).add_child(_value(row.text.get_slice(": ", 1)))
		row.text = row.text.get_slice(": ", 0)
	elif not compact:
		# Wrap long network and accessory names within the scroll area.
		row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


func _row(row_name: String) -> Button:
	var row := _button(row_name)
	row.name = row_name
	var side := _side(row)
	var value := _value("")
	if LEVELS.has(row_name):
		row.set_meta("level", row_name)
		var bar := ProgressBar.new()
		bar.name = "Bar"
		bar.show_percentage = false
		bar.set_meta("socket_adaptive_surface", true)
		bar.min_value = 0 if row_name == "Volume" else 1
		bar.max_value = LEVELS[row_name][2]
		bar.custom_minimum_size = Vector2(400, 14) * _unit
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.add_theme_stylebox_override("background", _box(Color(_ink, 0.18), 7 * _unit))
		bar.add_theme_stylebox_override("fill", _box(_ink, 7 * _unit))
		side.add_child(bar)
		value.custom_minimum_size.x = 150 * _unit
	elif row_name == MSAA:
		row.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
		row.pressed.connect(func(): _settings.call("set_setting", MSAA_KEY, not _settings.call("get_setting", MSAA_KEY)))
		if _settings.call("cartridge_msaa_mode") == Viewport.MSAA_DISABLED:
			row.disabled = true
			row.focus_mode = Control.FOCUS_NONE
	elif not RADIOS.has(row_name):
		row.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
		row.pressed.connect(_game_row.bind(row))
	elif ResourceLoader.exists(RADIOS[row_name]):
		# Open on the press. The action from GUIDE arrives one frame after the button.
		row.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
		row.pressed.connect(_open_radio.bind(row))
	else:
		value.text = "Unavailable"
		row.disabled = true
		row.focus_mode = Control.FOCUS_NONE
	side.add_child(value)
	_rows[row_name] = row
	return row


# A on Game or Cheats: RetroArch shows its page and takes the pad. RetroArch
# reads the event a short time later. Do not use a press that it sends in
# that time: the focus must stay on this row, and one press gives one event.
func _game_row(row: Button) -> void:
	_root_row = row
	_quiet_until = Time.get_ticks_msec() + 250
	game_event.emit(String(row.name).to_lower())


func _hint() -> Control:
	var hint := RichTextLabel.new()
	hint.bbcode_enabled = true
	hint.fit_content = true
	hint.autowrap_mode = TextServer.AUTOWRAP_OFF
	hint.scroll_active = false
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.add_theme_color_override("default_color", _ink)
	var parts: PackedStringArray = []
	for prompt in [["ui_accept", "A", "Select"], ["ui_cancel", "B", "Back"]]:
		var glyph: String = prompt[1]
		# The icon follows the controller layout that the user selected in Socket.
		var icons := get_node_or_null("/root/ControlIcons")
		if icons != null and icons.has_method("get_icon"):
			var path: String = icons.call("get_icon", prompt[0])
			if not path.is_empty() and ResourceLoader.exists(path):
				glyph = "[img=%d color=#%s]%s[/img]" % [roundi(50 * _unit), _ink.to_html(false), path]
		parts.append(glyph + " " + prompt[2])
	parts.append("Left/Right Adjust")
	hint.text = "     ".join(parts)
	return hint


func _process(_delta: float) -> void:
	# Like the HUD, draw in display pixels. The SubViewport keeps Socket's
	# logical layout size, so theme sizes fit and text is sharp.
	var native := _root.get_stretch_transform().affine_inverse()
	var window_size := Vector2(_root.size)
	if transform != native or _container.size != window_size:
		transform = native
		_container.size = window_size
		_gui.size_2d_override = Vector2i(_logical)
		_gui.size_2d_override_stretch = true
		if "oversampling_override" in _gui:
			_gui.set("oversampling_override", _glyph_scale(window_size.y / _logical.y))
	_poll_levels()
	var now := Time.get_ticks_msec()
	if _held != 0:
		var focus := _gui.gui_get_focus_owner()
		if focus == null or not focus.has_meta("level") or not Input.is_action_pressed("ui_left" if _held < 0 else "ui_right"):
			_held = 0
		elif now >= _repeat_at:
			_repeat_at = now + 120
			_step(focus.get_meta("level"), _held)
	for row_name in LEVELS:
		var level: int = _shown[row_name]
		_rows[row_name].get_node("Side/Bar").value = level
		_rows[row_name].get_node("Side/Value").text = "Muted" if row_name == "Volume" and level == 0 else str(level)
	if _rows.has(MSAA):
		# The watchdog can pause MSAA while the panel is open.
		var state := "On"
		if _rows[MSAA].disabled or not _settings.call("get_setting", MSAA_KEY):
			state = "Off"
		elif _root.get_meta("socket_cartridge_msaa_paused", false):
			state = "Paused"
		_rows[MSAA].get_node("Side/Value").text = state


# Glyph pixels for each layout unit. scale is the display pixels for each
# layout unit. A display with the size of the layout draws glyphs 1:1.
# A smaller display gets glyphs of about two times the display size, as in
# the launcher window. For Departure Mono, the glyph size of the theme text is
# a multiple of its 11 pixel grid: 33 pixels for the 46-unit text on the
# 720x480 panel. Godot uses steps of 1/64 and drops the remainder, so the
# result is the nearest step: 46/64, which gives 33.06 pixels.
func _glyph_scale(scale: float) -> float:
	if scale >= 1.0:
		return scale
	var size := _title.get_theme_font_size("font_size")
	if _title.get_theme_font("font").get_font_name() != "Departure Mono" or size <= 0:
		return 2.0 * scale
	return roundf(64.0 * maxf(roundf(2.0 * scale * size / 11.0), 1.0) * 11.0 / size) / 64.0


func _input(event: InputEvent) -> void:
	_root.set_input_as_handled()
	if is_queued_for_deletion():
		return
	if not (event is InputEventJoypadButton or event is InputEventJoypadMotion or event is InputEventKey or event is InputEventAction):
		return
	# RetroArch has the pad on its pages. A release still goes to its control.
	if event.is_pressed() and (_view != null or Time.get_ticks_msec() < _quiet_until):
		return
	if _guide != null and (event is InputEventJoypadButton or event is InputEventJoypadMotion):
		_guide.call("inject_input", event)
	if event.is_action("ui_cancel"):
		# Go back on release, so no part of the press reaches the launcher.
		if event.is_pressed():
			_cancel_down = true
		elif _cancel_down:
			_cancel_down = false
			_back()
		return
	var focus := _gui.gui_get_focus_owner()
	if _sub == null and focus != null and focus.has_meta("level") and (event.is_action("ui_left") or event.is_action("ui_right")):
		var direction := -1 if event.is_action("ui_left") else 1
		if event.is_pressed() and not event.is_echo():
			_held = direction
			_repeat_at = Time.get_ticks_msec() + 400
			_step(focus.get_meta("level"), direction)
		elif not event.is_pressed() and _held == direction:
			_held = 0
		return
	_gui.push_input(event)


# For the pages that RetroArch draws: the surface color, the ink color, and
# the rectangle and corner radius of the panel in pixels of the frame.
func look() -> String:
	var scale := float(_root.size.y) / _logical.y
	var rect := Rect2i(Rect2(_card.global_position * scale, _card.size * scale))
	return "%s %s %d %d %d %d %d" % [_surface.to_html(false), _ink.to_html(false),
		rect.position.x, rect.position.y, rect.size.x, rect.size.y, roundi(48 * _unit * scale)]


# The full screen of the panel, for RetroArch. The alpha is premultiplied.
func frame() -> Image:
	return _gui.get_texture().get_image()


# Show one page of RetroArch. rows has the visible rows, six at most. selected
# is an index of rows. first is the index of rows[0] in the full list of total
# rows. An empty status shows no status line.
func show_view(selected: int, first: int, total: int, title: String, status: String, rows: PackedStringArray) -> void:
	_close_radio()
	_quiet_until = 0
	if _view == null:
		# After a sleep, a page comes with no press on a row. The title tells
		# which row opened it.
		if not is_instance_valid(_root_row):
			_root_row = _rows.get("Cheats" if title in CHEATS_TITLES else "Game", _gui.gui_get_focus_owner())
		# Keep the size of the card: the main list can make it higher than its minimum.
		_card_minimum = _card.custom_minimum_size
		_card.custom_minimum_size = _card_minimum.max(_card.size)
		_list.hide()
		_view = VBoxContainer.new()
		_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_view.add_theme_constant_override("separation", roundi(12 * _unit))
		var scroll := _scroller()
		_view_rows = VBoxContainer.new()
		_view_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_view_rows.add_theme_constant_override("separation", roundi(12 * _unit))
		scroll.add_child(_view_rows)
		_view.add_child(scroll)
		# The status stays below the rows. A long status uses more lines.
		_view_status = _label("")
		_view_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		# The text of RetroArch is not a translation key.
		_view_status.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		_title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		_view.add_child(_view_status)
		_body.add_child(_view)
	# RetroArch scrolls the list. Show the position when some rows are not visible.
	_title.text = title if total <= rows.size() else "%s  %d/%d" % [title, first + selected + 1, total]
	_view_status.text = status
	_view_status.visible = not status.is_empty()
	while _view_rows.get_child_count() < rows.size():
		var row := _button("")
		row.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		var value := _label("")
		value.name = "Value"
		value.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(value)
		value.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		value.offset_right = -28 * _unit
		_view_rows.add_child(row)
	var width := _card.size.x - 2.0 * 56 * _unit
	for index in _view_rows.get_child_count():
		var row: Button = _view_rows.get_child(index)
		row.visible = index < rows.size()
		if not row.visible:
			continue
		# The value goes to the right side, as on the main list. A value that
		# is too long for the side stays in the text of the row.
		var value: Label = row.get_node("Value")
		var columns := _columns.search(rows[index])
		value.text = columns.get_string(2) if columns != null else ""
		var value_width := value.get_minimum_size().x
		value.visible = columns != null and value_width <= width * 0.45
		row.text = rows[index] if columns == null else columns.get_string(1) + ("" if value.visible else "  " + columns.get_string(2))
		row.get_theme_stylebox("normal").content_margin_right = (56 * _unit + value_width) if value.visible else 28 * _unit
		# A long name does not make the panel wider. The selected row shows all
		# of its text on more lines. Each other row has one line with an ellipsis.
		row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if index == selected else TextServer.AUTOWRAP_OFF
		row.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING if index == selected else TextServer.OVERRUN_TRIM_ELLIPSIS
		row.clip_text = index != selected
	if selected >= 0 and selected < rows.size():
		_view_rows.get_child(selected).grab_focus()


# Show the main list after a page of RetroArch.
func show_root() -> void:
	if _view == null:
		return
	_view.free()
	_view = null
	_quiet_until = 0
	_card.custom_minimum_size = _card_minimum
	_title.text = TITLE
	_title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_INHERIT
	_list.show()
	if is_instance_valid(_root_row):
		_root_row.grab_focus()


func _back() -> void:
	if _view != null:
		# RetroArch has the pad on its pages.
		return
	if _sub == null:
		if game:
			game_event.emit("close")
		else:
			close()
	elif _sub.has_method("go_back"):
		_sub.call("go_back")
	else:
		_close_radio()


func _open_radio(row: Button) -> void:
	if _sub != null:
		return
	_sub = load(RADIOS[row.name]).new()
	_sub_row = row
	if "row_style" in _sub:
		_sub.row_style = _style_radio_row
	_sub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if _sub.has_signal("back_requested"):
		_sub.connect("back_requested", _close_radio)
	_title.text = row.name
	_list.hide()
	_scroll = _scroller()
	_scroll.add_child(_sub)
	_body.add_child(_scroll)
	_focus_radio.call_deferred()


# A long list scrolls in the panel and keeps the focused row in view.
func _scroller() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# A rebuilt list can restore focus before its new buttons have positions.
	scroll.sort_children.connect(_reveal_focus.bind(scroll), CONNECT_DEFERRED)
	return scroll


func _reveal_focus(scroll: ScrollContainer) -> void:
	if not is_instance_valid(scroll) or not scroll.is_inside_tree():
		return
	var focus := _gui.gui_get_focus_owner()
	if focus != null and scroll.is_ancestor_of(focus):
		scroll.ensure_control_visible(focus)


func _focus_radio() -> void:
	# A subpanel usually takes the focus itself. If not, use its first control.
	if _sub == null:
		return
	var focus := _gui.gui_get_focus_owner()
	if focus == null or not _sub.is_ancestor_of(focus):
		var first := _sub.find_next_valid_focus()
		if first != null and _sub.is_ancestor_of(first):
			first.grab_focus()


func _close_radio() -> void:
	if _sub == null:
		return
	_scroll.queue_free()
	_sub = null
	_title.text = TITLE
	_list.show()
	_sub_row.grab_focus()


func _step(row_name: String, direction: int) -> void:
	var spec: Array = LEVELS[row_name]
	var base: int = _wanted.get(row_name, _shown[row_name])
	var next := clampi(base + direction * int(spec[3]), spec[1], spec[2])
	if next == base:
		return
	_wanted[row_name] = next
	_send()


# Send one level request to socket-hardware. Wait for its reply before the next.
func _send() -> void:
	if not _request.is_empty():
		return
	for row_name in _wanted.keys():
		var value: int = _wanted[row_name]
		if value == _shown[row_name]:
			_wanted.erase(row_name)
			continue
		_token += 1
		var path := _run_dir.path_join("controls.set")
		var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
		if file == null:
			_wanted.clear()
			return
		file.store_string("%d %s %d\n" % [_token, LEVELS[row_name][0], value])
		file.close()
		if DirAccess.rename_absolute(path + ".tmp", path) != OK:
			_wanted.clear()
			return
		_request = {"row": row_name, "value": value, "token": str(_token), "deadline": Time.get_ticks_msec() + 500}
		return


func _poll_levels() -> void:
	# The snapshot also shows changes from the volume buttons and shortcuts.
	if hud != null and hud.get("_sequence") != _sequence:
		_sequence = hud.get("_sequence")
		_shown["Volume"] = hud.get("_volume")
		# The snapshot has brightness 0 to 9. The panel shows 1 to 10.
		_shown["Brightness"] = hud.get("_brightness") + 1
	if _request.is_empty():
		return
	var path := _run_dir.path_join("controls.ack")
	var reply: RegExMatch = null
	if FileAccess.file_exists(path):
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null and file.get_length() <= 40:
			reply = _ack.search(file.get_as_text())
	if reply != null and reply.get_string(1) == _request.token:
		DirAccess.remove_absolute(path)
		var row_name: String = _request.row
		# The reply has the level in effect, also when the change failed.
		_shown[row_name] = clampi(reply.get_string(3).to_int(), LEVELS[row_name][1], LEVELS[row_name][2])
		if reply.get_string(2) == "error" or _wanted.get(row_name) == _request.value:
			_wanted.erase(row_name)
		_request = {}
		_send()
	elif Time.get_ticks_msec() >= _request.deadline:
		# No helper answered. Show the last applied values.
		_request = {}
		_wanted.clear()
