extends SceneTree

# Drive the Wi-Fi settings page with ui actions. This script is the worker.
var run := OS.get_environment("SOCKET_RUN")
var page
var backs := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> bool:
	if not ok:
		printerr("FAIL: ", message, " view=", page._view if page else "", " rows=", rows())
		quit(1)
		return false
	checks += 1
	return true

func rows() -> Array:
	if page == null: return []
	return page.find_children("*", "Control", true, false).map(func(c): return c.text if "text" in c else "")

func focused() -> String:
	var owner := root.gui_get_focus_owner()
	return "" if owner == null else owner.placeholder_text if owner is LineEdit else owner.text

func press(action: String, count := 1) -> void:
	for i in count:
		for pressed in [true, false]:
			var event := InputEventAction.new()
			event.action = action
			event.pressed = pressed
			Input.parse_input_event(event)
			await process_frame
		await process_frame

func worker(state: String, result := "ok", saved := "") -> void:
	var file := FileAccess.open(run.path_join("wifi.status"), FileAccess.WRITE)
	file.store_string("id=%d\nresult=%s\nstate=%s\nsaved=%s\n" % [page._sent, result, state, saved])
	file.close()
	await create_timer(0.4).timeout

func request() -> String:
	var text := FileAccess.get_file_as_string(run.path_join("wifi.request"))
	DirAccess.remove_absolute(run.path_join("wifi.request"))
	return text.strip_edges().get_slice(" ", 1)

func type(text: String) -> void:
	# Move to each key of the fallback keyboard by focus, then confirm.
	for c in text:
		for key in page._focusable():
			if key.text == c:
				key.grab_focus()
		await press("ui_accept")

func _run() -> void:
	var script = load("res://addons/FrontendPlugin/wifi_settings.gd")
	# Card format rules. The Python worker test gives the same values to the parser.
	for valid in [["a", "12345678"], ['a "# = $HOME \\', 'quote"# = $(false) \\ " ;'], ["Café", "x".repeat(63)], ["x", "aB".repeat(32)]]:
		if not check(script.check(valid[0], valid[1]) == "", "valid " + valid[0]): return
	for invalid in [["", "12345678"], ["x".repeat(33), "12345678"], ["é".repeat(17), "12345678"], ["x", "1234567"], ["x", "g".repeat(64)], ["x", "a".repeat(65)], ["x", "123\t45678"], [" x", "12345678"], ["x", "12345678 "]]:
		if not check(script.check(invalid[0], invalid[1]) != "", "invalid " + invalid[0]): return
	var table := "bssid / frequency / signal level / flags / ssid\n" + \
		"02:00:00:00:00:01\t2437\t-70\t[WPA2-PSK-CCMP][ESS]\tCaf\\xc3\\xa9 \\\"net\\\" \\\\\n" + \
		"02:00:00:00:00:02\t2437\t-40\t[WPA2-PSK-CCMP][ESS]\tCaf\\xc3\\xa9 \\\"net\\\" \\\\\n" + \
		"02:00:00:00:00:03\t2437\t-50\t[WPA2-SAE-CCMP][ESS]\tThree\n" + \
		"02:00:00:00:00:04\t2437\t-51\t[WPA2-PSK+SAE-CCMP][ESS]\tMixed\n" + \
		"02:00:00:00:00:05\t2437\t-52\t[WPA2-EAP-CCMP][ESS]\tWork\n" + \
		"02:00:00:00:00:06\t2437\t-53\t[WPA-PSK-TKIP][ESS]\tOld\n" + \
		"02:00:00:00:00:07\t2437\t-54\t[WEP][ESS]\tOlder\n" + \
		"02:00:00:00:00:08\t2437\t-55\t[ESS]\tCafe guest\n" + \
		"02:00:00:00:00:09\t2437\t-30\t[WPA2-PSK-CCMP][ESS]\t\n" + \
		"02:00:00:00:00:0a\t2437\t-30\t[WPA2-PSK-CCMP][ESS]\t\\x00\\x00\n"
	var found: Array = script.parse_scan(table).map(func(n): return [n["ssid"], n["security"], n["supported"], n["signal"]])
	if not check(found == [['Café "net" \\', "WPA2", true, -40], ["Three", "WPA3", false, -50], ["Mixed", "WPA2", true, -51], ["Work", "Enterprise", false, -52], ["Old", "WPA", false, -53], ["Older", "WEP", false, -54], ["Cafe guest", "Open", false, -55]], "escaped names, security types, hidden rows and duplicates: %s" % [found]): return

	page = script.new()
	page.back_requested.connect(func(): backs += 1)
	root.add_child(page)
	await process_frame
	await process_frame
	if not check(focused() == "Back" and rows()[0] == "Wi-Fi is not available.", "no worker"): return
	await worker("idle")
	if not check(focused() == "Wi-Fi: On", "page takes focus"): return
	# Scan, cancel, and ignore the late result.
	await press("ui_down")
	await press("ui_accept")
	if not check(request() == "scan" and focused() == "Cancel", "scan request"): return
	page.go_back()
	if not check(request() == "cancel" and page._view == "main", "B cancels the scan"): return
	FileAccess.open(run.path_join("wifi.scan"), FileAccess.WRITE).store_string(table)
	page._sent -= 1
	await worker("idle")
	page._sent += 1
	if not check(page._view == "main", "late scan result ignored"): return
	# Scan again and select the unsupported network, then the supported network.
	await press("ui_down")
	await press("ui_accept")
	request()
	await worker("idle", "pending")
	if not check(page._view == "networks" and focused() == "Cancel", "pending scan"): return
	await worker("idle")
	if not check(rows().slice(1, 4) == ['Café "net" \\  (WPA2)', "Three  (WPA3, not supported)", "Mixed  (WPA2)"] and rows().size() == found.size() + 3 and rows().has("Cafe guest  (Open, not supported)"), "network list includes the weakest visible network"): return
	await press("ui_down")
	await press("ui_accept")
	if not check(page._view == "networks" and rows()[0].contains("WPA2-Personal"), "unsupported security stays in the list"): return
	await press("ui_up")
	await press("ui_accept")
	if not check(page._view == "form" and focused() == "Password", "password form"): return
	await press("ui_accept")
	if not check(page._view == "keys" and focused() == "q", "fallback keyboard opens"): return
	await type("pass")
	page.go_back()
	if not check(page._psk.text == "pas" and rows()[0] == "***|", "B deletes, preview is masked"): return
	await press("ui_accept")
	for key in page._focusable():
		if key.text == "Done": key.grab_focus()
	await press("ui_accept")
	if not check(page._view == "form" and focused() == "Password", "Done returns to the field"): return
	await press("ui_down")
	await press("ui_accept")
	if not check(page._view == "form" and rows()[1].begins_with("The password must") and not FileAccess.file_exists(run.path_join("wifi.request")), "short password reported before the join"): return
	page._psk.text = "pass word #="
	await press("ui_accept")
	if not check(request() == "join" and page._view == "busy", "join request"): return
	if not check(FileAccess.get_file_as_string(run.path_join("wifi.candidate")) == 'ssid=Café "net" \\\npsk=pass word #=\n', "candidate file"): return
	if not check(FileAccess.get_unix_permissions(run.path_join("wifi.candidate")) == 0x180, "candidate is private"): return
	# A wrong password keeps the form and offers the saved network.
	await worker("connecting", "auth", "Home")
	if not check(page._view == "form" and rows()[1] == page.ERRORS["auth"] and rows()[-1] == "Reconnect to Home" and page._psk.text != "", "authentication error"): return
	for result in ["dhcp", "save", "notfound"]:
		page._join()
		request()
		await worker("connecting", result, "Home")
		if not check(rows()[1] == page.ERRORS[result], result + " error is separate"): return
	# Cancel a pending join. A late success is ignored.
	page._join()
	request()
	await press("ui_accept")
	if not check(request() == "cancel" and page._view == "busy", "cancel waits for the worker"): return
	await worker("connecting", "ok", "Home")
	if not check(page._view == "form" and rows()[1] == "Canceled." and page._psk.text != "", "cancel join"): return
	# The worker saved the network before it read the cancel request.
	page._join()
	request()
	page.go_back()
	page.go_back()
	if not check(request() == "cancel", "one cancel request"): return
	await worker("connected", "ok", 'Café "net" \\')
	if not check(page._view == "main" and rows()[0] == 'Connected to Café "net" \\.' and rows().size() == 4 and page._psk.text == "", "cancel after the commit shows the saved network"): return
	await press("ui_down")
	await press("ui_accept")
	request()
	await worker("connected", "ok", 'Café "net" \\')
	await press("ui_accept")
	page._psk.text = "12345678"
	page._join()
	request()
	page.go_back()
	request()
	await worker("connecting", "ok", "Home")
	page._sent -= 1
	await worker("connected", "ok", "Other")
	page._sent += 1
	if not check(page._view == "form", "late join result ignored"): return
	# Back discards the edit.
	page.go_back()
	if not check(page._view == "networks" and page._psk.text == "" and page._ssid.text == "", "Back discards the edit"): return
	# Hidden network. The name field uses the same keyboard, not masked.
	await process_frame
	for row in page._focusable():
		if row.text == "Enter network name": row.grab_focus()
	await press("ui_accept")
	if not check(focused() == "Network name", "hidden network form"): return
	await press("ui_accept")
	await type("ab")
	if not check(page._view == "keys" and rows()[0] == "ab|", "name preview is readable"): return
	page._close_keys()
	await process_frame
	page._ssid.text = "Hidden one"
	page._psk.text = "a".repeat(64)
	page._join()
	if not check(request() == "join" and FileAccess.get_file_as_string(run.path_join("wifi.candidate")) == "ssid=Hidden one\npsk=%s\n" % "a".repeat(64), "hidden join with a raw key"): return
	await worker("connected", "ok", "Hidden one")
	if not check(page._view == "main" and rows()[0] == "Connected to Hidden one." and page._psk.text == "", "joined, password dropped"): return
	if not check(rows().slice(1) == ["Wi-Fi: On", "Choose a network", "Forget Hidden one"], "connected rows"): return
	# Forget needs a confirmation. Cancel has the focus.
	await press("ui_down", 2)
	await press("ui_accept")
	if not check(page._view == "confirm" and focused() == "Cancel", "forget asks first"): return
	await press("ui_down")
	await press("ui_accept")
	if not check(request() == "forget", "forget request"): return
	await worker("idle")
	if not check(rows() == ["Wi-Fi is on. No network is saved.", "Wi-Fi: On", "Choose a network"], "forgotten"): return
	# Off keeps the saved network. Retry appears while the link is down.
	await worker("connecting", "ok", "Home")
	if not check(rows().has("Retry"), "retry row"): return
	await press("ui_accept")
	if not check(request() == "off", "off request"): return
	await worker("off", "ok", "Home")
	if not check(rows() == ["Wi-Fi is off. Saved network: Home.", "Wi-Fi: Off"], "off keeps the network"): return
	# Hiding the page stops a join.
	await worker("idle")
	page._open_form("Example", false)
	page._psk.text = "12345678"
	page._join()
	request()
	page.hide()
	if not check(request() == "cancel" and page._psk.text == "", "hide cancels and drops the password"): return
	page.show()
	await process_frame
	await process_frame
	if not check(page._view == "main" and focused() == "Wi-Fi: On", "shown again with focus"): return
	page.go_back()
	if not check(backs == 1, "B leaves the page"): return
	await worker("external")
	if not check(rows() == ["BaseOS manages Wi-Fi. Not connected.", "Back"], "borrowed connection"): return
	page.free()
	print("PASS: Wi-Fi settings page (", checks, " checks)")
	quit()
