shader_type spatial;
#ifdef BLOCK_BOTH_FACES
render_mode unshaded, fog_disabled, blend_mul, depth_draw_never, cull_disabled;
#else
render_mode unshaded, fog_disabled, blend_mul, depth_draw_never;
#endif

// Compatibility draws this after the depth-writing labels. In a transparent
// viewport, multiply clears both RGB and alpha wherever the casing wins depth.
void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}
