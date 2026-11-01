shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;

varying vec4 display_modulate;

void vertex() {
	display_modulate = COLOR;
}

float edge_value(vec4 sample_color) {
	// Include coverage so black silhouettes on transparent pixels have edges.
	return dot(sample_color.rgb, vec3(0.299, 0.587, 0.114)) + sample_color.a;
}

void fragment() {
	vec4 center = texture(TEXTURE, UV);
	vec4 nw = texture(TEXTURE, UV + vec2(-1.0, -1.0) * TEXTURE_PIXEL_SIZE);
	vec4 ne = texture(TEXTURE, UV + vec2(1.0, -1.0) * TEXTURE_PIXEL_SIZE);
	vec4 sw = texture(TEXTURE, UV + vec2(-1.0, 1.0) * TEXTURE_PIXEL_SIZE);
	vec4 se = texture(TEXTURE, UV + vec2(1.0, 1.0) * TEXTURE_PIXEL_SIZE);
	float m = edge_value(center);
	float a = edge_value(nw);
	float b = edge_value(ne);
	float c = edge_value(sw);
	float d = edge_value(se);
	float low = min(m, min(min(a, b), min(c, d)));
	float high = max(m, max(max(a, b), max(c, d)));
	vec4 filtered = center;
	if (high - low >= max(0.03125, high * 0.125)) {
		vec2 direction = vec2(-((a + b) - (c + d)), (a + c) - (b + d));
		float reduction = max((a + b + c + d) * (0.25 * 0.125), 0.0078125);
		direction = clamp(direction / (min(abs(direction.x), abs(direction.y)) + reduction), vec2(-4.0), vec2(4.0)) * TEXTURE_PIXEL_SIZE;
		vec4 inner = 0.5 * (texture(TEXTURE, UV - direction / 6.0) + texture(TEXTURE, UV + direction / 6.0));
		vec4 outer = inner * 0.5 + 0.25 * (texture(TEXTURE, UV - direction * 0.5) + texture(TEXTURE, UV + direction * 0.5));
		float value = edge_value(outer);
		filtered = value < low || value > high ? inner : outer;
	}
	// The transparent GLES viewport stores premultiplied color.
	COLOR = filtered * vec4(display_modulate.rgb * display_modulate.a, display_modulate.a);
}
