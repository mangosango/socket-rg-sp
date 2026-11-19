extends "res://addons/FrontendPlugin/settings_form.gd"

var game := false
var card := "/mnt/sdcard"
var _note := ""
const ACCOUNT := "Config/retroachievements.txt"
const PLATFORMS := ["gb", "gbc", "gba"]

func _ready() -> void:
	_setup_fields()
	_ssid.placeholder_text = "RetroAchievements username"
	_psk.placeholder_text = "New password"
	_show("main")

func _replace(path: String, value: String) -> bool:
	var tmp := path + ".menu-new"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return false
	FileAccess.set_unix_permissions(tmp, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	var ok := file.store_string(value)
	file.flush()
	ok = ok and file.get_error() == OK
	file.close()
	if ok and DirAccess.rename_absolute(tmp, path) == OK:
		return true
	DirAccess.remove_absolute(tmp)
	return false

func _render(focus := -1) -> void:
	focus = _clear_rows(focus)
	if _view == "keys":
		_keyboard()
	elif _view == "form":
		_label("Replace the local login. Use your existing RetroAchievements username and password.")
		add_child(_ssid)
		add_child(_psk)
		_row("Save account", _save_account)
	else:
		var path := card.path_join(ACCOUNT)
		var enabled := FileAccess.file_exists(path) and not FileAccess.file_exists(path + ".off")
		_label("Achievement changes apply on the next game launch (mGBA).")
		_row("RetroAchievements: " + ("On" if enabled else "Off"), _toggle_account, self, true)
		_row("Set username and password", _edit_account)
		if game:
			_label("For live rewind: Game → Gameplay → Rewind.")
		else:
			for platform: String in PLATFORMS:
				_rewind_row(platform)
	if _note != "" and _view != "keys":
		_label(_note)
	_focus_row(focus)

func _toggle_account() -> void:
	var path := card.path_join(ACCOUNT)
	if not FileAccess.file_exists(path):
		_edit_account()
		return
	var off := path + ".off"
	var ok := DirAccess.remove_absolute(off) == OK if FileAccess.file_exists(off) else _replace(off, "off\n")
	_note = "" if ok else "Could not save the change."
	_render()

func _edit_account() -> void:
	_ssid.clear()
	_psk.clear()
	_note = ""
	_show("form")

func _save_account() -> void:
	for field in [_ssid, _psk]:
		var value: String = field.text
		var bytes := value.to_utf8_buffer()
		if bytes.is_empty() or bytes.size() > (31 if field == _ssid else 255) or value != value.strip_edges() or RegEx.create_from_string("[[:cntrl:]]").search(value) != null:
			_note = "Enter 1–31 username bytes and 1–255 password bytes, without control characters or surrounding spaces."
			_render()
			return
	if not _replace(card.path_join(ACCOUNT), "username = %s\npassword = %s\n" % [_ssid.text, _psk.text]):
		_note = "Could not save the account."
		_render()
		return
	_ssid.clear()
	_psk.clear()
	_note = "Account saved."
	_show("main")

func _rewind_row(platform: String) -> void:
	var path := card.path_join("Saves/socket/retroarch/" + platform + ".cfg")
	var contents := ""
	if FileAccess.file_exists(path):
		contents = FileAccess.get_file_as_string(path)
		if FileAccess.get_open_error() != OK:
			_label("Cannot read " + platform.to_upper() + " settings.")
			return
	var key := RegEx.create_from_string('(?m)^\\h*rewind_enable\\h*=([^\\n]*)$')
	var matches := key.search_all(contents)
	var on := matches.is_empty() or matches[-1].get_string(1).strip_edges().trim_prefix('"').trim_suffix('"') != "false"
	_row(platform.to_upper() + " rewind: " + ("On" if on else "Off"), func():
		var updated := key.sub(contents, "", true).strip_edges(false, true) + '\nrewind_enable = "%s"\n' % ("false" if on else "true")
		var ok := DirAccess.make_dir_recursive_absolute(path.get_base_dir()) == OK and _replace(path, updated)
		_note = "" if ok else "Could not save rewind settings."
		_render(), self, true)

func go_back() -> void:
	if _view == "keys":
		_close_keys()
	elif _view == "form":
		_psk.clear()
		_ssid.clear()
		_note = ""
		_show("main")
	else:
		back_requested.emit()
