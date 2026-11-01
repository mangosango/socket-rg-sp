// Adapted from Slot crates/slot-gfx/src/shaders.rs, GAME_FRAG (GPL-3.0-or-later).
// LCD3x math: Gigaherz, public domain. Grid math: Slot.
#pragma parameter SLOT_GRID "Slot grid (0 = LCD3x)" 0.0 0.0 1.0 1.0

#if defined(VERTEX)
attribute vec4 VertexCoord;
attribute vec4 TexCoord;
uniform mat4 MVPMatrix;
varying vec2 v_uv;
void main() {
    gl_Position = MVPMatrix * VertexCoord;
    v_uv = TexCoord.xy;
}
#elif defined(FRAGMENT)
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
uniform sampler2D Texture;
uniform vec2 InputSize;
uniform vec2 TextureSize;
uniform vec2 OutputSize;
#ifdef PARAMETER_UNIFORM
uniform float SLOT_GRID;
#else
#define SLOT_GRID 0.0
#endif
varying vec2 v_uv;
vec2 grid_band(vec2 x) {
    return floor(x) / 3.0 + min(fract(x), vec2(1.0 / 3.0));
}
void main() {
    vec2 f = fract(v_uv * TextureSize);
    vec3 c = texture2D(Texture, v_uv).rgb;
    if (SLOT_GRID > 0.5) {
        vec2 hp = 0.5 * InputSize / OutputSize;
        vec2 edge = (grid_band(f + hp) - grid_band(f - hp)) / (2.0 * hp);
        c *= 1.0 - 0.75 * max(edge.x, edge.y);
    } else {
        const vec3 offsets = vec3(3.141592654) * vec3(0.5, 0.5 - 2.0 / 3.0, 0.5 - 4.0 / 3.0);
        vec2 angle = f * 6.283185307;
        float yfactor = (16.0 + sin(angle.y)) / 17.0;
        vec3 xfactors = (4.0 + sin(angle.x + offsets)) / 5.0;
        c *= yfactor * xfactors;
    }
    gl_FragColor = vec4(c, 1.0);
}
#endif
