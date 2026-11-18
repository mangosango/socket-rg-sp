shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;

// Display pass of the cartridge view.
//
// The 3D target has one sample for each texel: a texel is in a cartridge or it
// is empty. The outline thus has stair steps. This pass finds the two ends of
// a step, and draws the straight line through them with a ramp of one panel
// pixel. It uses alpha only to find the outline.
//
// It changes only pixels on the outline between an opaque texel and an empty
// texel. All other pixels keep the one linear read, so artwork and
// semi-transparent casings do not change. A target with MSAA, or a target that
// is already filtered, has part coverage on its outline. Such an outline keeps
// the linear read.
//
// Texture reads: one color read for each panel pixel. A pixel where the alpha
// of that read changes gets two texel reads. A pixel on the outline gets six
// reads more. There is no loop: eight more reads is the maximum.
// With a 3D target of the panel size, each pixel gets two reads more, and a
// pixel near the outline gets four: twelve more reads is the maximum.

// Alpha at or below EMPTY is an empty texel. Alpha at or above OPAQUE is a full texel.
const float EMPTY = 0.004;
const float OPAQUE = 0.996;

varying vec4 display_modulate;

void vertex() {
	display_modulate = COLOR;
}

void fragment() {
	vec4 center = texture(TEXTURE, UV);
	vec4 filtered = center;
	// DISPLAY_LINEAR is the variant with the linear read only.
#ifndef DISPLAY_LINEAR
	// Derivatives are not defined in a branch that only some pixels take.
	// The alpha change of the linear read, with the sign in texture directions.
	vec2 slope = vec2(dFdx(center.a) * sign(dFdx(UV.x)), dFdy(center.a) * sign(dFdy(UV.y)));
	vec2 pixel = TEXTURE_PIXEL_SIZE;
	// Texels for each panel pixel: 0.75 at 540x360 on the 720x480 panel.
	float texels = clamp(abs(dFdx(UV.x)) / pixel.x, 0.25, 1.0);
	vec2 position = UV / pixel;
	vec2 texel = floor(position) + 0.5;
	if (texels > 0.99) {
		// Panel size: the linear read is one texel, and a derivative shows
		// the change in one of two pixel columns and rows only. Read the four
		// texel corners. Each read gives the mean of four texels.
		float north_west = textureLod(TEXTURE, (texel + vec2(-0.5, -0.5)) * pixel, 0.0).a;
		float south_east = textureLod(TEXTURE, (texel + vec2(0.5, 0.5)) * pixel, 0.0).a;
		slope = vec2(0.0);
		// No outline is near if the two corners are opaque or the two are empty.
		if (min(north_west, south_east) < OPAQUE && max(north_west, south_east) > EMPTY) {
			float north_east = textureLod(TEXTURE, (texel + vec2(0.5, -0.5)) * pixel, 0.0).a;
			float south_west = textureLod(TEXTURE, (texel + vec2(-0.5, 0.5)) * pixel, 0.0).a;
			slope = vec2(north_east + south_east - north_west - south_west, south_west + south_east - north_west - north_east);
		}
	}
	if (max(abs(slope.x), abs(slope.y)) > 0.003) {
		vec2 inside = position - texel;
		// The direction into the cartridge, along the axis with the larger change.
		vec2 inward = abs(slope.y) >= abs(slope.x) ? vec2(0.0, sign(slope.y)) : vec2(sign(slope.x), 0.0);
		vec4 middle = textureLod(TEXTURE, texel * pixel, 0.0);
		bool solid = middle.a > EMPTY;
		// The neighbor on the other side of the outline.
		vec2 normal = solid ? -inward : inward;
		vec4 other = textureLod(TEXTURE, (texel + normal) * pixel, 0.0);
		vec4 material = solid ? middle : other;
		float outside = solid ? other.a : middle.a;
		// Only an outline between an opaque texel and an empty texel.
		if (material.a >= OPAQUE && outside <= EMPTY) {
			vec2 tangent = abs(normal.yx);
			// A read on the border between the two rows gives their mean: 0.5 on
			// the outline. At the end of the step the two rows are equal, and the
			// mean is 0 or 1. Each read is between two columns, so it shows the
			// columns at 1 and 2, at 3 and 4, and at 7 and 8 texels on each side.
			vec2 border = (texel + normal * 0.5) * pixel;
			vec2 step_size = tangent * pixel;
			vec2 at_1 = vec2(textureLod(TEXTURE, border - 1.5 * step_size, 0.0).a, textureLod(TEXTURE, border + 1.5 * step_size, 0.0).a) - 0.5;
			vec2 at_3 = vec2(textureLod(TEXTURE, border - 3.5 * step_size, 0.0).a, textureLod(TEXTURE, border + 3.5 * step_size, 0.0).a) - 0.5;
			vec2 at_7 = vec2(textureLod(TEXTURE, border - 7.5 * step_size, 0.0).a, textureLod(TEXTURE, border + 7.5 * step_size, 0.0).a) - 0.5;
			vec2 end_1 = step(vec2(0.125), abs(at_1));
			vec2 end_3 = step(vec2(0.125), abs(at_3));
			vec2 end_7 = step(vec2(0.125), abs(at_7));
			// The distance to each end of the step, in texels. The nearest read
			// that shows an end gives the distance. Nine is the limit.
			vec2 reach = mix(vec2(9.0), vec2(6.0), end_7);
			reach = mix(reach, vec2(2.75), end_3);
			reach = mix(reach, 2.5 - abs(at_1) * 4.0, end_1);
			// The sign shows which of the two rows continues after the end.
			vec2 ends = mix(mix(at_7, at_3, end_3), at_1, end_1);
			float along = dot(inside, tangent);
			vec2 to_end = reach + vec2(along, -along);
			float nearest = to_end.x < to_end.y ? ends.x : ends.y;
			// The line is half a texel from the border at an end of the step,
			// and on the border in the middle of the step.
			float offset = 0.5 * sign(nearest) * (1.0 - 2.0 * min(to_end.x, to_end.y) / (to_end.x + to_end.y));
			// The distance from the line into the cartridge, in panel pixels.
			float cover = clamp(0.5 + ((solid ? 1.0 : -1.0) * (0.5 - dot(inside, normal)) + offset) / texels, 0.0, 1.0);
			// Premultiplied color: the color of the cartridge times the new alpha.
			filtered = vec4(center.a > 0.45 ? center.rgb / center.a : material.rgb, 1.0) * cover;
		}
	}
#endif
	// The transparent GLES viewport stores premultiplied color.
	COLOR = filtered * vec4(display_modulate.rgb * display_modulate.a, display_modulate.a);
}
