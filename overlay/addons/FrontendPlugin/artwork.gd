extends RefCounted

const MAX_IMAGE_BYTES := 8 * 1024 * 1024
const MAX_EDGE := 4096

static func online() -> bool:
	return FrontendBridge.get_network_status().get("type", "none") == "wifi"


static func base_path(platform, game) -> String:
	return "user://scraped_data/%s/%s" % [platform.model.abbreviation.to_lower(), game.rom_name.validate_filename()]


static func exists(path: String) -> bool:
	return not path.is_empty() and FileAccess.file_exists(path)


static func has_image(game) -> bool:
	return exists(game.custom_support_image_path) or exists(game.support_texture_path)


static func prepare(platforms: Array) -> bool:
	var missing := false
	for platform in platforms:
		for game in platform.games:
			var base := base_path(platform, game)
			if not exists(game.game_info_path) and exists(base + ".json"):
				game.game_info_path = base + ".json"
				game._game_info_loaded = false
			if not exists(game.support_texture_path) and exists(base + "_support.png"):
				game.support_texture_path = base + "_support.png"
				game.force_reload_texture()
			if not exists(game.game_info_path) or not has_image(game):
				missing = true
	return missing and online()


# Stage all requested files before publishing a new cache entry.
static func store(game, base: String, info: Dictionary, image: Image, refresh: bool) -> bool:
	if info.is_empty():
		return false
	var need_image := refresh or not has_image(game)
	if need_image and (image == null or image.is_empty()):
		if refresh or not str(info.get("texture_url", "")).is_empty():
			return false
		need_image = false
	var json_path := base + ".json"
	var image_path := base + "_support.png"
	var need_info := refresh or not exists(game.game_info_path)
	if DirAccess.make_dir_recursive_absolute(base.get_base_dir()) != OK:
		return false
	var staged := not need_info or _stage(json_path, JSON.stringify(info, "\t").to_utf8_buffer())
	if staged and need_image:
		staged = _stage(image_path, image.save_png_to_buffer())
	# Keep a copy when a refresh replaces both files. If the metadata rename
	# fails, restore the previous image before returning to the library.
	var backup := staged and need_info and need_image and exists(image_path)
	if backup:
		staged = DirAccess.copy_absolute(image_path, image_path + ".previous") == OK
	var image_replaced := false
	if staged and need_image:
		image_replaced = DirAccess.rename_absolute(image_path + ".new", image_path) == OK
		staged = image_replaced
	if staged and need_info:
		staged = DirAccess.rename_absolute(json_path + ".new", json_path) == OK
	if not staged and image_replaced:
		if backup:
			if DirAccess.rename_absolute(image_path + ".previous", image_path) != OK:
				push_error("Could not restore the previous cached artwork")
				return false
		else:
			DirAccess.remove_absolute(image_path)
	for path in [json_path + ".new", image_path + ".new", image_path + ".previous"]:
		if exists(path):
			DirAccess.remove_absolute(path)
	if not staged:
		return false
	if need_info:
		game.game_info_path = json_path
		game._game_info_loaded = false
	if need_image:
		game.support_texture_path = image_path
		game.force_reload_texture()
	return true


static func _stage(path: String, bytes: PackedByteArray) -> bool:
	if bytes.is_empty():
		return false
	var temp := path + ".new"
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return false
	var written := file.store_buffer(bytes)
	file.close()
	return written and FileAccess.get_size(temp) == bytes.size()


static func limit_request(request: HTTPRequest, bytes: int) -> void:
	request.timeout = 12.0
	request.max_redirects = 0
	request.body_size_limit = bytes


# Read the dimensions before the decoder allocates the pixel buffer.
static func decode_image(data: PackedByteArray) -> Image:
	if data.size() < 30 or data.size() > MAX_IMAGE_BYTES:
		return null
	var size := Vector2i.ZERO
	var image := Image.new()
	if data.slice(0, 8).hex_encode() == "89504e470d0a1a0a":
		size = Vector2i(_be32(data, 16), _be32(data, 20))
		if _fits(size) and image.load_png_from_buffer(data) == OK:
			return image
	elif data.slice(0, 4).get_string_from_ascii() == "RIFF" and data.slice(8, 12).get_string_from_ascii() == "WEBP":
		# The decoder reads the bitstream dimensions. Check those even if a
		# VP8X canvas header is present. Animated files are outside this port.
		var at := 12
		while at + 18 <= data.size():
			var kind := data.slice(at, at + 4).get_string_from_ascii()
			var length := data.decode_u32(at + 4)
			var start := at + 8
			if start + length > data.size() or kind in ["ANIM", "ANMF"]:
				return null
			match kind:
				"VP8X":
					if length != 10 or not _fits(Vector2i(1 + _le24(data, start + 4), 1 + _le24(data, start + 7))):
						return null
				"VP8L":
					if length < 5 or data[start] != 47:
						return null
					var bits := data.decode_u32(start + 1)
					size = Vector2i(1 + (bits & 16383), 1 + ((bits >> 14) & 16383))
				"VP8 ":
					if length < 10:
						return null
					size = Vector2i(data.decode_u16(start + 6) & 16383, data.decode_u16(start + 8) & 16383)
			if size != Vector2i.ZERO:
				if _fits(size) and image.load_webp_from_buffer(data) == OK:
					return image
				return null
			at = start + length + (length & 1)
	elif data[0] == 255 and data[1] == 216:
		var at := 2
		while at + 9 <= data.size() and data[at] == 255:
			if data[at + 1] == 255:
				at += 1
				continue
			var marker := data[at + 1]
			var length := (data[at + 2] << 8) | data[at + 3]
			if length < 2 or at + 2 + length > data.size() or marker in [218, 217]:
				return null
			if marker in [192, 193, 194]:
				size = Vector2i((data[at + 7] << 8) | data[at + 8], (data[at + 5] << 8) | data[at + 6])
				if _fits(size) and image.load_jpg_from_buffer(data) == OK:
					return image
				return null
			at += 2 + length
	return null


static func _fits(size: Vector2i) -> bool:
	return size.x > 0 and size.y > 0 and size.x <= MAX_EDGE and size.y <= MAX_EDGE and size.x * size.y <= 4194304


static func _be32(data: PackedByteArray, at: int) -> int:
	return (data[at] << 24) | (data[at + 1] << 16) | (data[at + 2] << 8) | data[at + 3]


static func _le24(data: PackedByteArray, at: int) -> int:
	return data.decode_u16(at) | (data[at + 2] << 16)
