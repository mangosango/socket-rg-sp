extends SceneTree

var manager
var home
var mode := "match"
var fetched: Array[String] = []
var modern_api: bool
var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> bool:
	if not ok:
		printerr("FAIL: ", message)
		quit(1)
		return false
	checks += 1
	return true

func ready_file() -> String:
	return OS.get_environment("SOCKET_RUN").path_join("wifi.ready")

func write(path: String, value: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(value)
	file.close()

func dismiss() -> void:
	var dialog = load("res://scripts/screens/screen.gd").get_screen("dialog")
	if dialog.is_open:
		dialog.close()
		await dialog.closed

# Run the APK's response handlers. The image request uses loopback and is
# cancelled before the fixture supplies the response.
func respond(scraper) -> void:
	fetched.append(scraper.rom_name)
	if mode == "cancel":
		manager.cancel_scrape()
		return
	if mode == "rate":
		if modern_api:
			scraper._retries = scraper.MAX_RETRIES
		scraper._on_api_request_completed(0, 429, [], "{}".to_utf8_buffer())
		return
	if mode == "missing":
		scraper._on_api_request_completed(0, 200, [], "{}".to_utf8_buffer())
		return
	var label := {"region": "us", "url": "https://127.0.0.1:1/cover.png", "image_url": "https://127.0.0.1:1/cover.png"}
	var matched := {"matched": true, "game": {"name": "Downloaded", "canonical_name": "Downloaded"}, "labels": [label]}
	scraper._on_api_request_completed(0, 200, [], JSON.stringify(matched).to_utf8_buffer())
	scraper.image_request.cancel_request()
	if mode == "drop":
		scraper._on_image_request_completed(HTTPRequest.RESULT_CONNECTION_ERROR, 0, [], PackedByteArray())
	else:
		scraper._on_image_request_completed(0, 200, [], image.save_png_to_buffer())

func _run() -> void:
	manager = root.get_node("Manager")
	modern_api = manager.has_method("rescrape_game")
	image.fill(Color.GREEN)
	var user = manager.current_user
	var folder := OS.get_environment("SOCKET_TEST_ROOT")
	var platform = load("res://scripts/platform.gd").new()
	platform.model = manager.db.get_platform("gba").new()
	if ResourceLoader.exists("res://scripts/models/emulator_database.gd"):
		load("res://scripts/models/emulator_database.gd").store("gba", [{"uniqueId": "gba.ra64.mgba", "name": "mGBA", "acceptedFilenameRegex": "[.]gba$", "amStartArguments": "-n com.retroarch/.Main -e LIBRETRO mgba"}])
	platform.app_id = manager.get_available_apps_for_platform(platform.model)[0].id
	platform.rom_folder_path = folder
	manager.add_platform_to_user(user, platform)
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	var screen = load("res://scripts/screens/screen.gd")
	for i in 200:
		home = screen.get_screen("main")
		if home != null and home.is_node_ready():
			break
		await create_timer(0.05).timeout
	if not check(home != null and home.is_node_ready(), "main screen ready"): return
	var fake := GDScript.new()
	fake.source_code = "extends ScraperGamesDB\nfunc fetch() -> void:\n\tget_tree().respond(self)\n"
	if not check(fake.reload() == OK, "test scraper compiles"): return
	manager.child_entered_tree.connect(func(child):
		if child.get_script() == load("res://scripts/models/scrapers/scraper_games_db.gd"):
			child.set_script(fake)
	)
	var art = load("res://addons/FrontendPlugin/artwork.gd")
	if not check(not art.online(), "offline before the lease"): return
	var probe = load("res://scripts/models/scrapers/scraper_games_db.gd").new()
	# Use a synthetic key for every header assertion.
	probe.api_key = "fixture-only"
	root.add_child(probe)
	if not check(probe.api_request.timeout > 0 and probe.api_request.max_redirects == 0 and probe.image_request.body_size_limit == art.MAX_IMAGE_BYTES, "bounded requests and no credential redirects"): return
	if not check(probe._auth_headers(probe.base_url + "/label") == PackedStringArray(["X-API-Key: fixture-only"]), "same origin receives the key"): return
	for url in ["http://socket.depmots.com/label", probe.base_url + ".other.invalid/label", probe.base_url + "@other.invalid/label"]:
		if not check(probe._auth_headers(url).is_empty(), "foreign image origin gets no key"): return
	var rejected := []
	probe.game_scraping_finished.connect(func(info, _img): rejected.append(info))
	probe.rom_name = "Test"
	probe.base_url = "https://127.0.0.1:1"
	probe.fetch()
	if not check(rejected == [{}] and probe.last_failure_offline, "untrusted match endpoint rejected before request"): return
	probe.queue_free()
	for data in [image.save_png_to_buffer(), image.save_webp_to_buffer(), image.save_webp_to_buffer(true), image.save_jpg_to_buffer()]:
		if not check(art.decode_image(data) != null, "supported image format"): return
	var oversized := image.save_png_to_buffer()
	oversized[16] = 1
	if not check(art.decode_image(oversized) == null, "pixel limit checked before decode"): return

	var game_type = load("res://scripts/game.gd")
	var curated = game_type.from_dict({"rom_name": "One", "platform_id": "gba", "rom_path": folder.path_join("One.gba"), "is_favorite": true, "playtime": 42, "game_info_path": "user://curated.json", "support_texture_path": "user://curated.png"})
	write(curated.game_info_path, '{"name":"Hand edited"}')
	image.save_png(curated.support_texture_path)
	platform.games.append(curated)
	if modern_api:
		await manager.scan_and_scrape_all_platforms(user)
	else:
		await manager.scan_platform_in_user(user, platform)
	if not check(platform.games.size() == 2 and fetched.is_empty(), "offline scan keeps both games"): return
	write(ready_file(), "")
	if not check(art.online(), "frontend sees the worker lease"): return
	if modern_api:
		await manager.scan_and_scrape_all_platforms(user)
	else:
		await manager.scan_platform_in_user(user, platform)
	var downloaded = platform.games.filter(func(g): return g.rom_name == "Two")[0]
	if not check(fetched == ["Two"], "connected scan requests only the missing game"): return
	if not check(curated.title == "Hand edited" and curated.is_favorite and curated.playtime == 42, "curated paths and history survive"): return
	if not check(downloaded.title == "Downloaded" and downloaded.support_image != null, "new artwork loads immediately (%s, %s, %s)" % [downloaded.title, downloaded.game_info_path, downloaded.support_texture_path]): return
	if not check(downloaded.game_info_path == "user://scraped_data/gba/Two.json" and downloaded.support_texture_path == "user://scraped_data/gba/Two_support.png", "device writes the host cache layout"): return
	var cartridges: Array = home.carousel_3d.active_cartridges.values().filter(func(cart): return cart.game == downloaded)
	if not check(not cartridges.is_empty() and cartridges[0].game.support_texture != null, "visible cartridge has the downloaded texture"): return
	await dismiss()
	var partial = game_type.from_dict({"rom_name": "Partial", "game_info_path": "user://curated.json"})
	if not check(art.store(partial, "user://scraped_data/gba/Partial", {"name": "Other"}, image, false), "fill a missing image"): return
	if not check(partial.game_info_path == "user://curated.json" and partial.title == "Hand edited", "existing metadata survives a partial scrape"): return
	var previous_info := FileAccess.get_md5(downloaded.game_info_path)
	var previous_art := FileAccess.get_md5(downloaded.support_texture_path)
	for failure in ["drop", "cancel", "missing", "rate"]:
		mode = failure
		if modern_api:
			await manager.rescrape_game(downloaded)
		else:
			write(folder.path_join("Three.gba"), "missing")
			await manager.scan_platform_in_user(user, platform)
			var missing = platform.games.filter(func(g): return g.rom_name == "Three")[0]
			if not check(missing.game_info_path.is_empty() and missing.support_texture_path.is_empty(), failure + " publishes no partial files"): return
		if not check(FileAccess.get_md5(downloaded.game_info_path) == previous_info and FileAccess.get_md5(downloaded.support_texture_path) == previous_art, failure + " keeps both files"): return
		await dismiss()
	if modern_api:
		mode = "match"
		image.fill(Color.RED)
		if not check(await manager.rescrape_game(downloaded) == manager.ScrapeResult.MATCHED, "explicit refresh succeeds"): return
		if not check(FileAccess.get_md5(downloaded.support_texture_path) != previous_art, "valid replacement published"): return
		await dismiss()
	DirAccess.remove_absolute(ready_file())
	manager.load_user()
	var saved = manager.current_user.get_platform("gba").games.filter(func(g): return g.rom_name == "Two")[0]
	if not check(saved.title == "Downloaded" and saved.support_image != null, "artwork survives offline reload"): return
	if not await achievements(folder): return
	if modern_api:
		manager.current_user.romm_token = "fixture-only"
		manager.current_user.romm_server_url = "https://127.0.0.1:1"
		var romm = root.get_node("RomM")
		if not check(not romm.has_credentials(), "existing RomM account stays inactive"): return
		var nodes := romm.get_child_count()
		await romm.pull_save(saved)
		await romm.push_save(saved)
		if not check(romm.get_child_count() == nodes, "save transfers make no request"): return
	print("PASS: packed Wi-Fi artwork and achievement queries (", checks, " checks)")
	quit()

func achievements(folder: String) -> bool:
	var ra = root.get_node("RetroAchievements")
	var user = manager.current_user
	user.retro_achievements_username = "fixture user"
	user.retro_achievements_api_key = "fixture-private-web-key"
	# Exercise the actual response callbacks without sending credentials.
	var script := GDScript.new()
	script.source_code = ra.get_script().source_code.replace("request.request(url)", "_fixture_request(request, url)") + """
var response := []
var calls := 0
func _fixture_request(request: HTTPRequest, url: String) -> Error:
	calls += 1
	if url.begins_with(BADGE_BASE):
		request.request_completed.emit.call_deferred(0, 200, PackedStringArray(), get_tree().image.save_png_to_buffer())
	else:
		request.request_completed.emit.call_deferred(response[0], response[1], PackedStringArray(), JSON.stringify(response[2]).to_utf8_buffer())
	return OK
"""
	if not check(script.reload() == OK, "achievement transport fixture compiles"): return false
	ra.set_script(script)
	var results := []
	var received := func(id, digest): results.append([id, digest])
	for id in ["gb", "gbc", "gba"]:
		var platform = user.get_platform(id)
		if platform == null:
			platform = load("res://scripts/platform.gd").new()
			platform.model = manager.db.get_platform(id).new()
			platform.rom_folder_path = folder
			user.added_platforms.append(platform)
		var path := folder.path_join("nested/Lookup." + id)
		write(path, id)
		var game = load("res://scripts/game.gd").from_dict({"rom_name": "Lookup", "rom_path": path, "platform_id": id})
		var hash_value := FileAccess.get_md5(path)
		if not check(ra._compute_hash(game, platform) == hash_value, "hash nested " + id): return false
		if id == "gb":
			ra.identify_game(game, received)
			if not check(results[-1][0] < 0 and ra.calls == 0, "offline identification returns immediately"): return false
			write(ready_file(), "")
			ra.response = [HTTPRequest.RESULT_CANT_CONNECT, 0, {}]
			ra.identify_game(game, received)
			await process_frame
			if not check(ra._game_list_cache.is_empty() and results[-1][0] < 0, "failed list can retry"): return false
		ra.response = [0, 200, [{"ID": 77, "Hashes": [hash_value]}]]
		ra.identify_game(game, received)
		await process_frame
		if not check(results[-1] == [77, hash_value], "recognized " + id): return false
	var game = load("res://scripts/game.gd").from_dict({"rom_name": "Lookup", "rom_path": folder.path_join("nested/Lookup.gba"), "platform_id": "gba"})
	for date in ["", "2026-01-01"]:
		ra.response = [0, 200, {"Achievements": {"1": {"ID": 1, "BadgeName": "00123", "DateEarned": date}}}]
		home.screen_inspect._refresh_achievements(game)
		await process_frame
		await process_frame
		var expected := "0 / 1 unlocked" if date == "" else "1 / 1 unlocked"
		if not check(home.screen_inspect.achievements_status_label.text == expected, "panel shows " + expected): return false
		var badge_path: String = ra._badge_cache_path("00123", date == "")
		if not check(FileAccess.file_exists(badge_path), "panel caches badge"): return false
	return true
