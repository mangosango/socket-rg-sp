# Standalone GLES pixel proof. Run via tests/app/run_split_label_depth.py.
extends SceneTree

const SIZE := Vector2i(200, 120)
const OCCLUDER := preload("res://shaders/split_label_occluder.gdshader")
const EPS := 2.0 / 255.0

var view := SubViewport.new()
var environment := Environment.new()
var casing: Array[MeshInstance3D] = []
var label: MeshInstance3D

func _initialize() -> void:
	_run.call_deferred()

func require(ok: bool, message: String) -> bool:
	if not ok:
		printerr("FAIL: ", message)
		quit(1)
	return ok

func material(code: String) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = "shader_type spatial;\nrender_mode unshaded, depth_draw_opaque;\n" + code
	var result := ShaderMaterial.new()
	result.shader = shader
	return result

func shape(mesh: Mesh, at: Vector3, surface: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = at
	instance.material_override = surface
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	view.add_child(instance)
	return instance

func box(at: Vector3, size: Vector3, tilt: float = 0.0) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := shape(mesh, at, null)
	instance.rotation.z = tilt
	casing.append(instance)

func fixture() -> void:
	view.size = SIZE
	view.transparent_bg = true
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 4.0
	camera.position.z = 5.0
	camera.environment = environment
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.tonemap_white = 1.3
	environment.adjustment_saturation = 1.05
	view.add_child(camera)
	var quad := QuadMesh.new()
	quad.size = Vector2(4, 2.6)
	label = shape(quad, Vector3.ZERO, null)
	var near_quad := QuadMesh.new()
	near_quad.size = Vector2(0.36, 0.52)
	shape(near_quad, Vector3(0.38, 0.25, 1.2), material("void fragment() { ALBEDO = vec3(0, 1, 0); }"))
	box(Vector3(-1.1, 0, -0.4), Vector3(1.6, 3.1, 0.35)) # Own casing.
	box(Vector3(0.4, 0, 0.6), Vector3(0.8, 3, 0.4), 0.38) # Nearer, diagonal silhouette.
	box(Vector3(1.65, 0, 0.35), Vector3(0.6, 3.1, 0.4)) # Another nearer casing.

func frame(casing_material: Material) -> Image:
	for proxy in casing:
		proxy.visible = casing_material != null
		proxy.material_override = casing_material
	await process_frame
	await RenderingServer.frame_post_draw
	return view.get_texture().get_image()

func blank(pixel: Color) -> bool:
	return maxf(maxf(pixel.r, pixel.g), maxf(pixel.b, pixel.a)) <= EPS

# One pass with blue casing and red/green labels encodes expected coverage
# in R+G. Use unobstructed colors from the same tonemapping stage for RGB.
func compare(reference: Image, split: Image, label_only: Image, adjusted: bool) -> Vector4i:
	var red := label_only.get_pixel(52, 55)
	var green := label_only.get_pixel(111, 52)
	var errors := Vector4i.ZERO # coverage errors, color errors, edge pixels, peak post-adjusted RGB delta (8-bit)
	for y in range(SIZE.y):
		for x in range(SIZE.x):
			var oracle := reference.get_pixel(x, y)
			var pixel := split.get_pixel(x, y)
			var coverage := oracle.r + oracle.g
			if absf(pixel.a - coverage) > EPS:
				errors.x += 1
			var expected := red * oracle.r + green * oracle.g
			var delta := maxf(maxf(absf(pixel.r - expected.r), absf(pixel.g - expected.g)), absf(pixel.b - expected.b))
			var partial := (oracle.r > EPS and oracle.r < 1.0 - EPS) or (oracle.g > EPS and oracle.g < 1.0 - EPS)
			# Godot's nonlinear post process runs after MSAA resolve, so report,
			# rather than require exact premultiplication on adjusted edge pixels.
			if adjusted and partial:
				errors.w = maxi(errors.w, roundi(delta * 255.0))
			elif delta > EPS:
				errors.y += 1
			if x >= 96 and x <= 134 and y >= 63 and y <= 89 and coverage > EPS and coverage < 1.0 - EPS:
				errors.z += 1
	return errors

func _run() -> void:
	var output := OS.get_environment("SOCKET_EVIDENCE")
	var counts_path := OS.get_environment("SOCKET_FBO_COUNTS")
	var tile := not counts_path.is_empty()
	print("display=", DisplayServer.get_name(), " method=", RenderingServer.get_current_rendering_method(),
		" driver=", RenderingServer.get_current_rendering_driver_name(), " vendor=", RenderingServer.get_video_adapter_vendor(),
		" adapter=", RenderingServer.get_video_adapter_name(), " api=", RenderingServer.get_video_adapter_api_version(),
		" tile=", OS.get_environment("SOCKET_TILE_MSAA"), " prepass=", ProjectSettings.get_setting("rendering/driver/depth_prepass/enable"))
	if not require(DisplayServer.get_name() != "headless" and RenderingServer.get_current_rendering_method() == "gl_compatibility" and not output.is_empty(), "graphical Compatibility and evidence path required"): return
	fixture()
	await frame(null)
	var opaque := material("void fragment() { ALBEDO = vec3(1, 0, 0); }")
	var cutout := material("""
uniform sampler2D artwork : filter_nearest, repeat_disable;
void fragment() {
	ALBEDO = vec3(1, 0, 0);
	ALPHA = texture(artwork, UV).a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
""")
	var mask := Image.create_empty(8, 1, false, Image.FORMAT_RGBA8)
	mask.fill(Color.WHITE)
	mask.set_pixel(2, 0, Color.TRANSPARENT)
	cutout.set_shader_parameter("artwork", ImageTexture.create_from_image(mask))
	var blue := material("void fragment() { ALBEDO = vec3(0, 0, 1); }")
	var erase := ShaderMaterial.new()
	erase.shader = OCCLUDER
	erase.render_priority = Material.RENDER_PRIORITY_MAX

	for msaa: Viewport.MSAA in [Viewport.MSAA_DISABLED, Viewport.MSAA_2X]:
		view.msaa_3d = msaa
		for cut in [false, true]:
			label.material_override = cutout if cut else opaque
			for behind in [false, true]:
				var name := "%s-%s-%s" % ["2x" if msaa else "off", "cutout" if cut else "opaque", "behind" if behind else "front"]
				label.position.z = -0.8 if behind else 0.0
				environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
				environment.adjustment_enabled = false
				var unoccluded := await frame(null)
				if not require(unoccluded.get_pixel(114, 70).r > 0.98 and unoccluded.get_pixel(150, 78).r > 0.98, name + ": disabling the occluders must expose both overlaps"): return
				var reference := await frame(blue)
				var reference_edges := msaa != Viewport.MSAA_DISABLED and not tile
				for stage: String in ["linear", "reinhard", "adjusted"]:
					environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR if stage == "linear" else Environment.TONE_MAPPER_REINHARDT
					environment.adjustment_enabled = stage == "adjusted"
					var label_only := unoccluded if stage == "linear" else await frame(null)
					var split := await frame(erase)
					var check := compare(reference, split, label_only, environment.adjustment_enabled)
					var context := name + "-" + stage
					if not require(check.x == 0 and check.y == 0, "%s: oracle mismatch in %d coverage / %d color pixels" % [context, check.x, check.y]): return
					if not require((check.z > 10) if reference_edges else (check.z == 0), "%s: unexpected %d fractional occluder edge pixels" % [context, check.z]): return
					if not require(blank(split.get_pixel(68, 16)) and blank(split.get_pixel(114, 70)) and blank(split.get_pixel(150, 78)), context + ": casing-only and both occlusions must be transparent black"): return
					if not require(split.get_pixel(52, 55).a > 0.98 if not behind else blank(split.get_pixel(52, 55)), context + ": own casing must distinguish front and behind"): return
					if not require(blank(split.get_pixel(77, 62)) if cut or behind else split.get_pixel(77, 62).a > 0.98, context + ": alpha-scissor hole must not fill"): return
					if not require(split.get_pixel(111, 52).g > 0.5 and split.get_pixel(111, 52).a > 0.98, context + ": nearer label must survive the eraser"): return
					if not require(split.save_png(output.path_join(context + ".png")) == OK, context + ": save PNG"): return
					print(context, ": coverage/color mismatch=", Vector2i(check.x, check.y), ", fractional edge pixels=", check.z,
						", post-adjusted edge RGB delta=", check.w, "/255")
				if not require(reference.save_png(output.path_join(name + "-reference.png")) == OK, name + ": save oracle"): return

	if tile:
		var counts := FileAccess.get_file_as_string(counts_path).split_floats(" ")
		if not require(OS.get_environment("SOCKET_TILE_MSAA") == "1" and counts.size() >= 6 and counts[2] > 0 and counts[4] == 1 and counts[5] == 0,
				"tile path must be exercised with emulated extension and no draws after depth discard: %s" % [counts]): return
		print("tile framebuffer counts=", counts)
	print("PASS: split label occlusion and transparent background on GLES")
	quit()
