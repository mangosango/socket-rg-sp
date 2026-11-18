extends Node

# Adapt native dialogs, including FileDialog's nested confirmations, to a pad.
var _dialog: AcceptDialog
var _previous_focus: Control
var _files: ItemList


func _ready() -> void:
	_dialog = get_parent() as AcceptDialog
	_dialog.about_to_popup.connect(_opening)
	_dialog.visibility_changed.connect(_visibility_changed)
	# Socket's large control theme can squeeze the file list to zero height.
	_dialog.theme = ThemeDB.get_default_theme()
	if _dialog is FileDialog:
		var files := _dialog as FileDialog
		files.use_native_dialog = false
		files.display_mode = FileDialog.DISPLAY_LIST
		var help := Label.new()
		help.text = "Left/Right: buttons   L1/R1: next control\nY: parent folder   X: mark files   Cancel: close"
		files.get_vbox().add_child(help)


func _opening() -> void:
	_previous_focus = _dialog.get_parent().get_viewport().gui_get_focus_owner()
	_fit_and_focus.call_deferred()


static func fit_window(window: Window) -> void:
	var embedder := window.get_parent().get_viewport()
	while not embedder.is_embedding_subwindows() and embedder.get_parent() != null:
		embedder = embedder.get_parent().get_viewport()
	var available := embedder.get_visible_rect().size
	var stretch := embedder.get_stretch_transform().get_scale()
	# Render at native pixels, with default-theme text sized in physical pixels.
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	window.content_scale_size = Vector2i.ZERO
	window.content_scale_factor = 1.0 / minf(stretch.x, stretch.y)
	# Embedded Windows otherwise rasterize fonts at the root's downscale alone.
	window.set_use_font_oversampling(false)
	# Decorations are drawn by the embedder, outside the content transform.
	var scale := window.content_scale_factor
	var defaults := ThemeDB.get_default_theme()
	window.add_theme_font_size_override("title_font_size", roundi(14 * scale))
	window.add_theme_constant_override("title_height", roundi(20 * scale))
	window.add_theme_constant_override("close_h_offset", roundi(18 * scale))
	window.add_theme_constant_override("close_v_offset", roundi(17 * scale))
	for name in ["embedded_border", "embedded_unfocused_border"]:
		var border := defaults.get_stylebox(name, "Window").duplicate() as StyleBoxFlat
		border.expand_margin_top = 20 * scale
		window.add_theme_stylebox_override(name, border)
	for name in ["close", "close_pressed"]:
		var image := defaults.get_icon(name, "Window").get_image()
		image.resize(roundi(14 * scale), roundi(14 * scale), Image.INTERPOLATE_LANCZOS)
		window.add_theme_icon_override(name, ImageTexture.create_from_image(image))
	window.size = Vector2i(available * 0.9)
	window.position = Vector2i((available - Vector2(window.size)) / 2.0)


func _fit_and_focus() -> void:
	if not _dialog.visible:
		return
	# FileDialog focuses its file list on popup; its getter is not script-bound.
	if _dialog is FileDialog and _dialog.gui_get_focus_owner() is ItemList:
		_files = _dialog.gui_get_focus_owner() as ItemList
		_files.custom_minimum_size.y = 180
		_files.add_theme_font_size_override("font_size", 18)
	fit_window(_dialog)
	if _files != null:
		_files.grab_focus()
	elif not _dialog is FileDialog:
		_dialog.get_ok_button().grab_focus()


func _visibility_changed() -> void:
	if not _dialog.visible:
		_restore_focus.call_deferred()


func _restore_focus() -> void:
	if is_instance_valid(_previous_focus) and _previous_focus.is_visible_in_tree() and _previous_focus.focus_mode != Control.FOCUS_NONE:
		_previous_focus.grab_focus()


func _input(event: InputEvent) -> void:
	if not _dialog.visible:
		return
	if event.is_action_pressed("ui_cancel"):
		# AcceptDialog listens for ui_close_dialog, not Socket's ui_cancel.
		_dialog.set_input_as_handled()
		if _dialog is ConfirmationDialog:
			(_dialog as ConfirmationDialog).get_cancel_button().pressed.emit()
		else:
			_dialog.hide()
			_dialog.canceled.emit()
		return
	var focus := _dialog.gui_get_focus_owner()
	if event is InputEventJoypadButton and event.pressed and event.button_index in [JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER]:
		if focus != null:
			var next := focus.find_prev_valid_focus() if event.button_index == JOY_BUTTON_LEFT_SHOULDER else focus.find_next_valid_focus()
			if next != null:
				next.grab_focus()
		_dialog.set_input_as_handled()
		return
	if not _dialog is FileDialog or _files == null:
		return
	var files := _dialog as FileDialog
	var list := _files
	if event.is_action_pressed("open_settings"):
		files.current_dir = files.current_dir.get_base_dir()
		list.grab_focus()
	elif focus == list and event.is_action_pressed("option"):
		var select := InputEventAction.new()
		select.action = "ui_select"
		select.pressed = true
		files.push_input.call_deferred(select)
	elif focus == list and event.is_action_pressed("ui_right"):
		if not files.get_ok_button().disabled:
			files.get_ok_button().grab_focus()
		else:
			files.get_cancel_button().grab_focus()
	elif focus == list and event.is_action_pressed("ui_left"):
		files.get_cancel_button().grab_focus()
	elif focus in [files.get_ok_button(), files.get_cancel_button()] and (event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down")):
		list.grab_focus()
	else:
		return
	files.set_input_as_handled()
