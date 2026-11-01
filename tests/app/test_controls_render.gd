extends SceneTree


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(720, 480)
	root.content_scale_size = Vector2i(1920, 1280)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	RenderingServer.set_default_clear_color(Color(0.2, 0.3, 0.4))
	var hud = load("res://addons/FrontendPlugin/controls_hud.gd").new()
	root.add_child(hud)
	hud._volume = 50
	hud._kind = 1
	hud._shown_at = Time.get_ticks_msec()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	assert(hud._view.get_viewport_transform().is_equal_approx(Transform2D.IDENTITY))
	var image: = root.get_texture().get_image()
	assert(image.get_size() == Vector2i(720, 480))
	var background: = image.get_pixel(10, 40)
	assert(absf(background.r - 0.2) < 0.02)
	assert(absf(image.get_pixel(10, 0).r - background.r * 0.28) < 0.02)
	var fill: = Color.html("f5f2ef")
	assert(image.get_pixel(200, 17).is_equal_approx(fill))
	assert(image.get_pixel(359, 22).is_equal_approx(fill))
	assert(image.get_pixel(360, 17).r < 0.4)
	assert(image.get_pixel(199, 17).r < 0.1)
	assert(image.get_pixel(519, 22).r > 0.2)
	assert(image.get_pixel(520, 22).r < 0.1)
	assert(image.get_pixel(200, 16).r < 0.1)
	assert(image.get_pixel(200, 23).r < 0.1)
	var icon_pixels: int = 0
	for y in range(6, 34):
		for x in range(164, 190):
			if image.get_pixel(x, y).r > 0.8:
				icon_pixels += 1
	assert(icon_pixels > 20)
	assert(image.get_pixel(163, 20).r < 0.1)
	assert(hud._icons[0].get_size() == Vector2(26, 27))
	image.save_png(OS.get_environment("SOCKET_HUD_SCREENSHOT"))
	var draws: = [0]
	hud._view.draw.connect(func(): draws[0] += 1)
	for i in range(3): await RenderingServer.frame_post_draw
	assert(draws[0] == 0)
	root.size = Vector2i(800, 480)
	await create_timer(0.1).timeout
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	image = root.get_texture().get_image()
	assert(draws[0] > 0)
	assert(image.get_pixel(240, 17).is_equal_approx(fill))
	assert(image.get_pixel(399, 22).is_equal_approx(fill))
	assert(image.get_pixel(400, 17).r < 0.4)
	root.size = Vector2i(720, 480)
	await create_timer(0.1).timeout
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	hud._shown_at = Time.get_ticks_msec() - 1375
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	image = root.get_texture().get_image()
	assert(image.get_pixel(10, 0).r > background.r * 0.6)
	assert(image.get_pixel(10, 0).r < background.r * 0.85)
	hud._shown_at = Time.get_ticks_msec() - 1500
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	image = root.get_texture().get_image()
	assert(image.get_pixel(10, 0).is_equal_approx(background))
	# Slot screen temperature multiplies the native frame, HUD included.
	hud._temperature = 9
	hud._tint.visible = true
	hud._tint.queue_redraw()
	hud._kind = 3
	hud._shown_at = Time.get_ticks_msec()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	image = root.get_texture().get_image()
	var warm: = image.get_pixel(10, 40)
	assert(absf(warm.r - 0.2) < 0.02 and absf(warm.g - 0.3 * 0.82) < 0.02 and absf(warm.b - 0.4 * 0.62) < 0.02)
	var warm_fill: = image.get_pixel(200, 17)
	assert(absf(warm_fill.r - fill.r) < 0.02 and absf(warm_fill.b - fill.b * 0.62) < 0.02)
	var warm_icon: int = 0
	for y in range(6, 34):
		for x in range(164, 190):
			if image.get_pixel(x, y).r > 0.8:
				warm_icon += 1
	assert(warm_icon > 20)
	image.save_png(OS.get_environment("SOCKET_HUD_SCREENSHOT").get_basename() + "-warm.png")
	hud._temperature = 0
	hud._tint.visible = false
	hud._shown_at = Time.get_ticks_msec() - 1500
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	image = root.get_texture().get_image()
	assert(image.get_pixel(10, 40).is_equal_approx(background))
	print("PASS: rendered native HUD geometry, fill, track, plate, fade, expiry and temperature at logical 1920x1280 / native 720x480")
	quit()
