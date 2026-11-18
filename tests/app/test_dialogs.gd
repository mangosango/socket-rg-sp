extends RefCounted

var tree: SceneTree
var checks: int = 0

func require(ok: bool, message: String) -> bool:
	if not ok:
		printerr("FAIL: dialogs: ", message)
		tree.quit(1)
		return false
	checks += 1
	return true

func action(name: String) -> void:
	var event := InputEventAction.new()
	event.action = name
	event.pressed = true
	tree.root.push_input(event)
	await tree.create_timer(0.05).timeout
	event = event.duplicate()
	event.pressed = false
	tree.root.push_input(event)
	await tree.create_timer(0.05).timeout

func shoulder(index: int) -> void:
	var event := InputEventJoypadButton.new()
	event.button_index = index
	event.pressed = true
	tree.root.push_input(event)
	await tree.create_timer(0.05).timeout
	event = event.duplicate()
	event.pressed = false
	tree.root.push_input(event)
	await tree.create_timer(0.05).timeout

func collect(node: Node, dialogs: Array[FileDialog]) -> void:
	if node is FileDialog:
		dialogs.append(node)
	for child in node.get_children():
		collect(child, dialogs)

func choose(list: ItemList, text: String) -> bool:
	if list.select_mode == ItemList.SELECT_MULTI:
		# Seed a known cursor without changing the already marked files.
		var selected := list.get_selected_items()
		list.select(0)
		list.deselect(0)
		for index in selected: list.select(index, false)
		for index in range(list.item_count):
			if list.get_item_text(index) == text: return true
			await action("ui_down")
	else:
		for i in range(list.item_count + 1):
			var selected := list.get_selected_items()
			if not selected.is_empty() and list.get_item_text(selected[0]) == text: return true
			await action("ui_down")
	return require(false, "cannot navigate to " + text)

func native_geometry(window: Window) -> bool:
	var stretch := tree.root.get_stretch_transform().get_scale()
	var physical := Vector2(window.size) * stretch
	if not require(window.content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS and window.content_scale_size == Vector2i.ZERO, "no low-resolution viewport intermediate"): return false
	if not require(not window.is_using_font_oversampling(), "embedded root downscale must not shrink font rasterization"): return false
	if not require(is_equal_approx(window.content_scale_factor * stretch.x, 1.0), "default fonts have native physical pixel sizing"): return false
	if not require(absf(window.get_theme_font_size("title_font_size") * stretch.x - 14.0) < 1.0, "window titles remain readable in physical pixels"): return false
	if not require(absf(window.get_theme_icon("close").get_width() * stretch.x - 14.0) < 1.0, "window close icons remain readable in physical pixels"): return false
	if not require(physical.distance_to(Vector2(tree.root.size) * 0.9) < 2.0, "window occupies 90% of physical panel, including nested windows"): return false
	return require(window.get_visible_rect().size.distance_to(physical) < 2.0, "one dialog layout pixel equals one physical pixel")

func native_resolutions(dialogs: Array[FileDialog], fixture: String) -> bool:
	var original_size := tree.root.size
	var original_factor := tree.root.content_scale_factor
	for resolution in [Vector2i(640, 480), Vector2i(720, 480)]:
		for ui_scale in [0.75, 1.0, 1.5]:
			tree.root.size = resolution
			tree.root.content_scale_factor = ui_scale
			await tree.process_frame
			for dialog in dialogs:
				dialog.current_dir = fixture
				dialog.popup_centered()
				await tree.create_timer(0.1).timeout
				if not native_geometry(dialog): return false
				for nested in [AcceptDialog.new(), ConfirmationDialog.new()]:
					dialog.add_child(nested)
					await tree.process_frame
					nested.popup_centered()
					await tree.create_timer(0.1).timeout
					if not native_geometry(nested): return false
					nested.hide()
					nested.queue_free()
				dialog.hide()
			var picker = preload("res://addons/FrontendPlugin/folder_picker.gd").new()
			tree.root.add_child(picker)
			picker.open(fixture)
			await tree.process_frame
			if not native_geometry(picker): return false
			picker.hide()
			picker.queue_free()
		tree.root.content_scale_factor = original_factor
	tree.root.size = original_size
	await tree.process_frame
	return true

func run(harness) -> bool:
	tree = harness
	var screen = load("res://scripts/screens/screen.gd")
	var settings = screen.get_screen("settings")
	settings.open()
	await tree.create_timer(0.6).timeout
	var before: Control = tree.root.gui_get_focus_owner()
	var fixture := OS.get_environment("SOCKET_TEST_ROOT").path_join("dialog fixtures")
	DirAccess.make_dir_recursive_absolute(fixture.path_join("nested"))
	var audio := AudioStreamWAV.new()
	audio.format = AudioStreamWAV.FORMAT_8_BITS
	audio.mix_rate = 8000
	audio.data = PackedByteArray([128, 128, 128, 128])
	audio.save_to_wav(fixture.path_join("Track One.wav"))
	audio.save_to_wav(fixture.path_join("Track Two.wav"))
	var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	image.save_png(fixture.path_join("Cover.png"))
	var ignored := FileAccess.open(fixture.path_join("ignored.txt"), FileAccess.WRITE)
	ignored.close()
	var dialogs: Array[FileDialog] = []
	collect(tree.root, dialogs)
	if not require(dialogs.size() == 3, "audit includes platform folders, custom artwork and music"): return false
	if not await native_resolutions(dialogs, fixture): return false
	for dialog in dialogs:
		if not require(dialog.has_node("ControllerDialog"), "every native file dialog has controller support"): return false
		var canceled: Array = []
		var selected: Array = []
		dialog.canceled.connect(func(): canceled.append(true))
		dialog.file_selected.connect(func(path): selected.append(path))
		dialog.dir_selected.connect(func(path): selected.append(path))
		dialog.files_selected.connect(func(paths): selected.append(paths))
		dialog.current_dir = fixture
		dialog.popup_centered()
		await tree.create_timer(0.2).timeout
		var list: ItemList = dialog.gui_get_focus_owner()
		if not require(list != null and list.size.y >= 180, "file list has focus and usable height"): return false
		for index in range(list.item_count):
			if list.get_item_text(index) == "ignored.txt":
				if not require(dialog.file_mode == FileDialog.FILE_MODE_OPEN_DIR and list.is_item_disabled(index), "native file filters remain active (mode %s)" % dialog.file_mode): return false
		var available := dialog.get_parent().get_viewport().get_visible_rect().size
		if not require(Vector2(dialog.size).x <= available.x and Vector2(dialog.size).y <= available.y, "dialog fits panel viewport"): return false
		if not require(Rect2(Vector2.ZERO, dialog.get_visible_rect().size).encloses(dialog.get_cancel_button().get_global_rect()), "cancel button is on-screen"): return false
		await shoulder(JOY_BUTTON_RIGHT_SHOULDER)
		if not require(dialog.gui_get_focus_owner() != list and dialog.gui_get_focus_owner() != null, "R1 escapes the list focus region"): return false
		await shoulder(JOY_BUTTON_LEFT_SHOULDER)
		if not require(dialog.gui_get_focus_owner() == list, "L1 returns through the focus chain"): return false
		await action("ui_left")
		if not require(dialog.gui_get_focus_owner() == dialog.get_cancel_button(), "left reaches Cancel directly"): return false
		await action("ui_up")
		if not require(dialog.gui_get_focus_owner() == list, "up returns to file list"): return false
		await action("ui_cancel")
		if not require(not dialog.visible and canceled.size() == 1 and selected.is_empty(), "Cancel always closes without selecting"): return false
		if not require(tree.root.gui_get_focus_owner() == before, "cancel restores parent focus"): return false
		if dialog.file_mode == FileDialog.FILE_MODE_OPEN_FILES:
			var settings_manager = tree.root.get_node("SettingsManager")
			var expected_cancels := 1
			for confirm in [JOY_BUTTON_A, JOY_BUTTON_B]:
				settings_manager.set_setting("confirm_joy_button", confirm)
				dialog.popup_centered()
				await tree.create_timer(0.2).timeout
				await harness.joy(JOY_BUTTON_B if confirm == JOY_BUTTON_A else JOY_BUTTON_A)
				expected_cancels += 1
				if not require(not dialog.visible and settings.is_open and canceled.size() == expected_cancels, "physical remapped Cancel closes only the file dialog"): return false
			settings_manager.set_setting("confirm_joy_button", JOY_BUTTON_A)
		var cancel_count := canceled.size()
		# Reopening must not duplicate handlers, and empty directories must stay escapable.
		dialog.current_dir = fixture.path_join("nested")
		dialog.popup_centered()
		await tree.create_timer(0.2).timeout
		await action("open_settings")
		if not require(dialog.current_dir == fixture, "parent-folder shortcut works"): return false
		list = dialog.gui_get_focus_owner()
		if dialog.file_mode == FileDialog.FILE_MODE_OPEN_FILES:
			# Native FileDialog initially selects the first entry (our folder).
			await action("option")
			if not require(list.get_selected_items().is_empty(), "controller can unmark the initial selection"): return false
			if not await choose(list, "Track One.wav"): return false
			await action("option")
			if not await choose(list, "Track Two.wav"): return false
			await action("option")
			if not require(list.get_selected_items().size() == 2, "controller can mark multiple music tracks"): return false
		elif dialog.file_mode == FileDialog.FILE_MODE_OPEN_FILE:
			if not await choose(list, "Cover.png"): return false
		else:
			if not await choose(list, "nested"): return false
			await action("ui_accept")
			if not require(dialog.current_dir == fixture.path_join("nested"), "accept opens a folder"): return false
		await action("ui_right")
		if not require(dialog.gui_get_focus_owner() == dialog.get_ok_button(), "right reaches Open/Select: mode=%s focus=%s disabled=%s dir=%s" % [dialog.file_mode, dialog.gui_get_focus_owner(), dialog.get_ok_button().disabled, dialog.current_dir]): return false
		await action("ui_accept")
		if not require(not dialog.visible and selected.size() == 1 and canceled.size() == cancel_count, "confirm emits exactly one selection"): return false
		if dialog.file_mode == FileDialog.FILE_MODE_OPEN_FILES:
			if not require(selected[0] == PackedStringArray([fixture.path_join("Track One.wav"), fixture.path_join("Track Two.wav")]), "music receives both selected paths"): return false
		elif dialog.file_mode == FileDialog.FILE_MODE_OPEN_FILE:
			if not require(selected[0] == fixture.path_join("Cover.png"), "artwork receives the chosen image path"): return false
		else:
			if not require(selected[0] == fixture.path_join("nested"), "folder picker receives the chosen directory"): return false
		# Native error/overwrite dialogs are separate windows, not Socket Screens.
		dialog.popup_centered()
		await tree.create_timer(0.2).timeout
		for nested in [ConfirmationDialog.new(), AcceptDialog.new()]:
			dialog.add_child(nested)
			await tree.process_frame
			await tree.process_frame
			nested.popup_centered()
			await tree.create_timer(0.2).timeout
			await action("ui_cancel")
			if not require(not nested.visible and dialog.visible, "cancel closes only the topmost native dialog"): return false
			if not require(dialog.gui_get_focus_owner() == list, "nested cancel restores file-list focus"): return false
			nested.queue_free()
		await action("ui_cancel")
		if not require(not dialog.visible, "parent dialog is still cancelable after nested close"): return false
	# Linux ROM and save-folder buttons use the bridge's dedicated picker.
	var editor = screen.get_screen("edit_platform")
	var bridge = tree.root.get_node("FrontendBridge")
	editor.rom_folder_path = fixture
	editor.save_folder_path = fixture.path_join("nested")
	for method in ["_on_roms_folder_button_pressed", "_on_saves_folder_button_pressed"]:
		editor.call(method)
		await tree.create_timer(0.2).timeout
		var picker = bridge.get_node("FolderPicker")
		var expected: String = editor.save_folder_path if method.contains("saves") else editor.rom_folder_path
		if not require(picker.current_dir == expected, "ROM/save picker starts in its own folder"): return false
		await action("ui_accept")
		if not require(not bridge.has_node("FolderPicker"), "folder confirmation closes the picker"): return false
		editor.call(method)
		await tree.create_timer(0.2).timeout
		await action("ui_cancel")
		if not require(not bridge.has_node("FolderPicker"), "ROM/save picker cancels without trapping input"): return false
	# Socket's own modal Screens use ActionButton shortcuts, not native Windows.
	var dialog_screen = screen.get_screen("dialog")
	var callbacks: Array = []
	dialog_screen.display("Controller test", "Confirm or cancel", func(): callbacks.append("ok"), func(): callbacks.append("cancel"))
	await tree.create_timer(0.6).timeout
	await action("ui_cancel")
	await tree.create_timer(0.4).timeout
	if not require(not dialog_screen.is_open and callbacks == ["cancel"] and settings.is_open, "Socket confirmation cancels once without closing settings"): return false
	var options: Array[Dictionary] = []
	for i in range(60): options.append({"id": str(i), "label": "Option %02d" % i})
	var option_screen = screen.get_screen("option_dialog")
	option_screen.display("Options", options, "0", func(id): callbacks.append(id))
	await tree.create_timer(0.6).timeout
	await action("ui_down")
	await action("ui_cancel")
	await tree.create_timer(0.4).timeout
	if not require(not option_screen.is_open and callbacks == ["cancel"], "long option dialog navigates and cancels without a selection"): return false
	var keyboard = screen.get_screen("keyboard")
	var field := LineEdit.new()
	settings.add_child(field)
	keyboard.open_for(field)
	await tree.create_timer(0.6).timeout
	await action("add_platform")
	await tree.create_timer(0.4).timeout
	if not require(not keyboard.is_open and settings.is_open, "on-screen keyboard Done returns to its owner"): return false
	field.queue_free()
	settings.close()
	await tree.create_timer(0.5).timeout
	print("PASS: all three native file dialogs, controller confirmation/cancel, multi-file selection, folder traversal, fitting, focus restoration and nested modal isolation (", checks, " checks)")
	return true
