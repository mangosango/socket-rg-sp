extends Window

signal folder_selected(path: String)

var current_dir: String
var _path_label: Label
var _folders: ItemList
var _previous_focus: Control


func _ready() -> void:
	title = "ROMs folder"
	transient = true
	exclusive = true
	close_requested.connect(_cancel)
	var layout: = VBoxContainer.new()
	add_child(layout)
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_path_label = Label.new()
	_path_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	layout.add_child(_path_label)
	_folders = ItemList.new()
	_folders.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_folders.focus_mode = Control.FOCUS_NONE
	layout.add_child(_folders)
	_folders.item_activated.connect(_activate)
	var help: = Label.new()
	help.text = "Up/Down: choose   A: open/select   B: cancel   Left: parent"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(help)


func open(start_path: String) -> void:
	_previous_focus = get_parent().get_viewport().gui_get_focus_owner()
	current_dir = start_path if DirAccess.dir_exists_absolute(start_path) else "/mnt/sdcard"
	if not DirAccess.dir_exists_absolute(current_dir):
		current_dir = "/"
	_show_directory()
	popup_centered(Vector2i(600, 400))


func _show_directory() -> void:
	_path_label.text = current_dir
	_folders.clear()
	_folders.add_item("Save this folder")
	_folders.add_item("Cancel")
	_folders.add_item("../")
	for folder in DirAccess.get_directories_at(current_dir):
		_folders.add_item(folder + "/")
	_folders.select(0)
	_folders.ensure_current_is_visible()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_cancel()
	elif event.is_action_pressed("ui_left"):
		get_viewport().set_input_as_handled()
		_activate(2)
	elif event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		_activate(_folders.get_selected_items()[0])
	elif event.is_action_pressed("ui_up", true) or event.is_action_pressed("ui_down", true):
		get_viewport().set_input_as_handled()
		var step: = -1 if event.is_action_pressed("ui_up", true) else 1
		_folders.select(posmod(_folders.get_selected_items()[0] + step, _folders.item_count))
		_folders.ensure_current_is_visible()


func _activate(index: int) -> void:
	if index == 0:
		var selected: = current_dir
		_cancel()
		folder_selected.emit(selected)
	elif index == 1:
		_cancel()
	else:
		var path: = current_dir.get_base_dir() if index == 2 else current_dir.path_join(_folders.get_item_text(index).trim_suffix("/"))
		if DirAccess.open(path) == null:
			return
		current_dir = path
		_show_directory()


func _cancel() -> void:
	hide()
	if is_instance_valid(_previous_focus):
		_previous_focus.grab_focus()
	queue_free()
