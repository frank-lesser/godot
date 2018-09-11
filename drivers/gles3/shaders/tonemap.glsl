/* clang-format off */
[vertex]

layout(location = 0) in highp vec4 vertex_attrib;
/* clang-format on */
layout(location = 4) in vec2 uv_in;

out vec2 uv_interp;

void main() {
	gl_Position = vertex_attrib;

	uv_interp = uv_in;

#ifdef V_FLIP
	uv_interp.y = 1.0f - uv_interp.y;
#endif
}

/* clang-format off */
[fragment]

#if !defined(GLES_OVER_GL)
precision mediump float;
#endif
/* clang-format on */

in vec2 uv_interp;

uniform highp sampler2D source; //texunit:0

uniform float exposure;
uniform float white;

#ifdef USE_AUTO_EXPOSURE
uniform highp sampler2D source_auto_exposure; //texunit:1
uniform highp float auto_exposure_grey;
#endif

#if defined(USE_GLOW_LEVEL1) || defined(USE_GLOW_LEVEL2) || defined(USE_GLOW_LEVEL3) || defined(USE_GLOW_LEVEL4) || defined(USE_GLOW_LEVEL5) || defined(USE_GLOW_LEVEL6) || defined(USE_GLOW_LEVEL7)
#define USING_GLOW // only use glow when at least one glow level is selected

uniform highp sampler2D source_glow; //texunit:2
uniform highp float glow_intensity;
#endif

#ifdef USE_BCS
uniform vec3 bcs;
#endif

#ifdef USE_COLOR_CORRECTION
uniform sampler2D color_correction; //texunit:3
#endif

layout(location = 0) out vec4 frag_color;

#ifdef USE_GLOW_FILTER_BICUBIC
// w0, w1, w2, and w3 are the four cubic B-spline basis functions
float w0(float a) {
	return (1.0f / 6.0f) * (a * (a * (-a + 3.0f) - 3.0f) + 1.0f);
}

float w1(float a) {
	return (1.0f / 6.0f) * (a * a * (3.0f * a - 6.0f) + 4.0f);
}

float w2(float a) {
	return (1.0f / 6.0f) * (a * (a * (-3.0f * a + 3.0f) + 3.0f) + 1.0f);
}

float w3(float a) {
	return (1.0f / 6.0f) * (a * a * a);
}

// g0 and g1 are the two amplitude functions
float g0(float a) {
	return w0(a) + w1(a);
}

float g1(float a) {
	return w2(a) + w3(a);
}

// h0 and h1 are the two offset functions
float h0(float a) {
	return -1.0f + w1(a) / (w0(a) + w1(a));
}

float h1(float a) {
	return 1.0f + w3(a) / (w2(a) + w3(a));
}

uniform ivec2 glow_texture_size;

vec4 texture2D_bicubic(sampler2D tex, vec2 uv, int p_lod) {
	float lod = float(p_lod);
	vec2 tex_size = vec2(glow_texture_size >> p_lod);
	vec2 pixel_size = vec2(1.0f) / tex_size;

	uv = uv * tex_size + vec2(0.5f);

	vec2 iuv = floor(uv);
	vec2 fuv = fract(uv);

	float g0x = g0(fuv.x);
	float g1x = g1(fuv.x);
	float h0x = h0(fuv.x);
	float h1x = h1(fuv.x);
	float h0y = h0(fuv.y);
	float h1y = h1(fuv.y);

	vec2 p0 = (vec2(iuv.x + h0x, iuv.y + h0y) - vec2(0.5f)) * pixel_size;
	vec2 p1 = (vec2(iuv.x + h1x, iuv.y + h0y) - vec2(0.5f)) * pixel_size;
	vec2 p2 = (vec2(iuv.x + h0x, iuv.y + h1y) - vec2(0.5f)) * pixel_size;
	vec2 p3 = (vec2(iuv.x + h1x, iuv.y + h1y) - vec2(0.5f)) * pixel_size;

	return (g0(fuv.y) * (g0x * textureLod(tex, p0, lod) + g1x * textureLod(tex, p1, lod))) +
		   (g1(fuv.y) * (g0x * textureLod(tex, p2, lod) + g1x * textureLod(tex, p3, lod)));
}

#define GLOW_TEXTURE_SAMPLE(m_tex, m_uv, m_lod) texture2D_bicubic(m_tex, m_uv, m_lod)
#else
#define GLOW_TEXTURE_SAMPLE(m_tex, m_uv, m_lod) textureLod(m_tex, m_uv, float(m_lod))
#endif

vec3 tonemap_filmic(vec3 color, float white) {
	const float A = 0.15f;
	const float B = 0.50f;
	const float C = 0.10f;
	const float D = 0.20f;
	const float E = 0.02f;
	const float F = 0.30f;
	const float W = 11.2f;

	vec3 color_tonemapped = ((color * (A * color + C * B) + D * E) / (color * (A * color + B) + D * F)) - E / F;
	float white_tonemapped = ((white * (A * white + C * B) + D * E) / (white * (A * white + B) + D * F)) - E / F;

	return clamp(color_tonemapped / white_tonemapped, vec3(0.0f), vec3(1.0f));
}

vec3 tonemap_aces(vec3 color, float white) {
	const float A = 2.51f;
	const float B = 0.03f;
	const float C = 2.43f;
	const float D = 0.59f;
	const float E = 0.14f;

	vec3 color_tonemapped = (color * (A * color + B)) / (color * (C * color + D) + E);
	float white_tonemapped = (white * (A * white + B)) / (white * (C * white + D) + E);

	return clamp(color_tonemapped / white_tonemapped, vec3(0.0f), vec3(1.0f));
}

vec3 tonemap_reindhart(vec3 color, float white) {
	return clamp((color) / (1.0f + color) * (1.0f + (color / (white))), vec3(0.0f), vec3(1.0f)); // whitepoint is probably not in linear space here!
}

vec3 linear_to_srgb(vec3 color) { // convert linear rgb to srgb, assumes clamped input in range [0;1]
	const vec3 a = vec3(0.055f);
	return mix((vec3(1.0f) + a) * pow(color.rgb, vec3(1.0f / 2.4f)) - a, 12.92f * color.rgb, lessThan(color.rgb, vec3(0.0031308f)));
}

vec3 apply_tonemapping(vec3 color, float white) { // inputs are LINEAR, always outputs clamped [0;1] color
#ifdef USE_REINDHART_TONEMAPPER
	return tonemap_reindhart(color, white);
#endif

#ifdef USE_FILMIC_TONEMAPPER
	return tonemap_filmic(color, white);
#endif

#ifdef USE_ACES_TONEMAPPER
	return tonemap_aces(color, white);
#endif

	return clamp(color, vec3(0.0f), vec3(1.0f)); // no other seleced -> linear
}

vec3 gather_glow(sampler2D tex, vec2 uv) { // sample all selected glow levels
	vec3 glow = vec3(0.0f);

#ifdef USE_GLOW_LEVEL1
	glow += GLOW_TEXTURE_SAMPLE(tex, uv, 1).rgb;
#endif

#ifdef USE_GLOW_LEVEL2
	glow += GLOW_TEXTURE_SAMPLE(tex, uv, 2).rgb;
#endif

#ifdef USE_GLOW_LEVEL3
	glow += GLOW_TEXTURE_SAMPLE(tex, uv, 3).rgb;
#endif

#ifdef USE_GLOW_LEVEL4
	glow += GLOW_TEXTURE_SAMPLE(tex, uv, 4).rgb;
#endif

#ifdef USE_GLOW_LEVEL5
	glow += GLOW_TEXTURE_SAMPLE(tex, uv, 5).rgb;
#endif

#ifdef USE_GLOW_LEVEL6
	glow += GLOW_TEXTURE_SAMPLE(tex, uv, 6).rgb;
#endif

#ifdef USE_GLOW_LEVEL7
	glow += GLOW_TEXTURE_SAMPLE(tex, uv, 7).rgb;
#endif

	return glow;
}

vec3 apply_glow(vec3 color, vec3 glow) { // apply glow using the selected blending mode
#ifdef USE_GLOW_REPLACE
	color = glow;
#endif

#ifdef USE_GLOW_SCREEN
	color = max((color + glow) - (color * glow), vec3(0.0));
#endif

#ifdef USE_GLOW_SOFTLIGHT
	glow = glow * vec3(0.5f) + vec3(0.5f);

	color.r = (glow.r <= 0.5f) ? (color.r - (1.0f - 2.0f * glow.r) * color.r * (1.0f - color.r)) : (((glow.r > 0.5f) && (color.r <= 0.25f)) ? (color.r + (2.0f * glow.r - 1.0f) * (4.0f * color.r * (4.0f * color.r + 1.0f) * (color.r - 1.0f) + 7.0f * color.r)) : (color.r + (2.0f * glow.r - 1.0f) * (sqrt(color.r) - color.r)));
	color.g = (glow.g <= 0.5f) ? (color.g - (1.0f - 2.0f * glow.g) * color.g * (1.0f - color.g)) : (((glow.g > 0.5f) && (color.g <= 0.25f)) ? (color.g + (2.0f * glow.g - 1.0f) * (4.0f * color.g * (4.0f * color.g + 1.0f) * (color.g - 1.0f) + 7.0f * color.g)) : (color.g + (2.0f * glow.g - 1.0f) * (sqrt(color.g) - color.g)));
	color.b = (glow.b <= 0.5f) ? (color.b - (1.0f - 2.0f * glow.b) * color.b * (1.0f - color.b)) : (((glow.b > 0.5f) && (color.b <= 0.25f)) ? (color.b + (2.0f * glow.b - 1.0f) * (4.0f * color.b * (4.0f * color.b + 1.0f) * (color.b - 1.0f) + 7.0f * color.b)) : (color.b + (2.0f * glow.b - 1.0f) * (sqrt(color.b) - color.b)));
#endif

#if !defined(USE_GLOW_SCREEN) && !defined(USE_GLOW_SOFTLIGHT) && !defined(USE_GLOW_REPLACE) // no other selected -> additive
	color += glow;
#endif

	return color;
}

vec3 apply_bcs(vec3 color, vec3 bcs) {
	color = mix(vec3(0.0f), color, bcs.x);
	color = mix(vec3(0.5f), color, bcs.y);
	color = mix(vec3(dot(vec3(1.0f), color) * 0.33333f), color, bcs.z);

	return color;
}

vec3 apply_color_correction(vec3 color, sampler2D correction_tex) {
	color.r = texture(correction_tex, vec2(color.r, 0.0f)).r;
	color.g = texture(correction_tex, vec2(color.g, 0.0f)).g;
	color.b = texture(correction_tex, vec2(color.b, 0.0f)).b;

	return color;
}

void main() {
	vec3 color = textureLod(source, uv_interp, 0.0f).rgb;

	// Exposure

#ifdef USE_AUTO_EXPOSURE
	color /= texelFetch(source_auto_exposure, ivec2(0, 0), 0).r / auto_exposure_grey;
#endif

	color *= exposure;

	// Early Tonemap & SRGB Conversion

	color = apply_tonemapping(color, white);

#ifdef KEEP_3D_LINEAR
	// leave color as is (-> don't convert to SRGB)
#else
	color = linear_to_srgb(color); // regular linear -> SRGB conversion
#endif

	// Glow

#ifdef USING_GLOW
	vec3 glow = gather_glow(source_glow, uv_interp) * glow_intensity;

	// high dynamic range -> SRGB
	glow = apply_tonemapping(glow, white);
	glow = linear_to_srgb(glow);

	color = apply_glow(color, glow);
#endif

	// Additional effects

#ifdef USE_BCS
	color = apply_bcs(color, bcs);
#endif

#ifdef USE_COLOR_CORRECTION
	color = apply_color_correction(color, color_correction);
#endif

	frag_color = vec4(color, 1.0f);
}
