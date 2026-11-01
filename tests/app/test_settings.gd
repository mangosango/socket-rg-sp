extends RefCounted

var scans: Array = []
var warnings: int = 0

func get_setting(_key: String) -> bool:
	return false

func scan_platform_in_user(_user, platform) -> void:
	scans.append(platform.duplicate(true))

func display(_title, _text, _accept) -> void:
	warnings += 1

var current_user = null

func run(tree: SceneTree) -> void:
	AudioServer.set_bus_layout(load("res://bus_layout.res"))
	var sound = load("res://sound.gd").new()
	sound.SettingsManager = self
	tree.root.add_child(sound)
	var bus: = AudioServer.get_bus_index("sfx")
	assert(bus > 0 and AudioServer.is_bus_mute(bus))
	assert(is_equal_approx(AudioServer.get_bus_volume_db(bus), 0.0))
	assert(not AudioServer.is_bus_mute(0))
	sound._apply_ui_sounds_enabled(true)
	assert(not AudioServer.is_bus_mute(bus))
	sound._apply_ui_sounds_enabled(false)
	assert(AudioServer.is_bus_mute(bus))
	AudioServer.remove_bus(bus)
	sound._apply_ui_sounds_enabled(false)
	assert(AudioServer.bus_count == 2)
	assert(AudioServer.is_bus_mute(AudioServer.get_bus_index("sfx")))

	var screen = load("res://screen_focus.gd")
	var main = screen.new()
	var editor = screen.new()
	var dialog = screen.new()
	var background: = Button.new()
	var scan: = Button.new()
	var confirm: = Button.new()
	tree.root.add_child(main)
	main.add_child(background)
	main.add_child(editor)
	editor.add_child(scan)
	main.add_child(dialog)
	dialog.add_child(confirm)
	dialog.hide()
	assert(editor._audio.bus == &"sfx")
	editor._screens = [main, editor, dialog]
	dialog._screens = [main, editor, dialog]
	editor._disable_background_focus()
	assert(background.focus_mode == Control.FOCUS_NONE)
	assert(scan.focus_mode == Control.FOCUS_ALL)
	dialog.show()
	dialog._disable_background_focus()
	assert(scan.focus_mode == Control.FOCUS_NONE)
	assert(confirm.focus_mode == Control.FOCUS_ALL)
	dialog._restore_background_focus()
	dialog.hide()
	assert(scan.focus_mode == Control.FOCUS_ALL)
	assert(background.focus_mode == Control.FOCUS_NONE)

	var action = load("res://scan_editor.gd").new()
	action.Manager = self
	action.ScreenDialog = self
	action.platform = {"rom_folder_path": "old", "app_id": "old", "scan_subfolders": false, "hide_duplicates": false}
	action.rom_folder_path = "new"
	action.scan_subfolders_toggle = {"is_on": true}
	action.hide_duplicates_toggle = {"is_on": true}
	scan.pressed.connect(action._on_button_scan_pressed)
	scan.grab_focus()
	assert(tree.root.gui_get_focus_owner() == scan)
	var joy: = InputEventJoypadButton.new()
	joy.button_index = JOY_BUTTON_A
	joy.pressed = true
	Input.parse_input_event(joy)
	await tree.process_frame
	joy.pressed = false
	Input.parse_input_event(joy)
	await tree.process_frame
	assert(scans == [{"rom_folder_path": "new", "app_id": "selected.core", "scan_subfolders": true, "hide_duplicates": true}])
	action.rom_folder_path = ""
	action._on_button_scan_pressed()
	assert(warnings == 1 and scans.size() == 1)
	editor._restore_background_focus()
	assert(background.focus_mode == Control.FOCUS_ALL)
	main.queue_free()
	sound.queue_free()
	print("PASS: startup audio mute, unity UI gain, missing bus, nested modal focus and Joypad scan with current editor fields")
