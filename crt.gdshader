shader_type canvas_item;
// Retro-monitor pass over the visualizer viewport: phosphor bloom + scanlines.
// Runs on the SubViewportContainer, so the low-res buffer is already upscaled with
// NEAREST -- scanlines therefore land on real screen pixels, not on chunky viewport
// texels, which is what makes them read as a monitor instead of as part of the art.

uniform float glow_amount : hint_range(0.0, 3.0) = 1.15;
uniform float glow_radius : hint_range(0.0, 8.0) = 2.2;
uniform float scan_strength : hint_range(0.0, 1.0) = 0.30;
uniform float scan_period : hint_range(2.0, 12.0) = 4.0;
uniform float bleed : hint_range(0.0, 1.0) = 0.25;

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	vec2 px = TEXTURE_PIXEL_SIZE * glow_radius;

	// 8-tap ring. A separable gaussian would be cleaner but needs two passes and this
	// is a 1px wireframe on black -- the ring is indistinguishable at this line weight.
	vec4 sum = vec4(0.0);
	sum += texture(TEXTURE, UV + vec2( px.x, 0.0));
	sum += texture(TEXTURE, UV + vec2(-px.x, 0.0));
	sum += texture(TEXTURE, UV + vec2(0.0,  px.y));
	sum += texture(TEXTURE, UV + vec2(0.0, -px.y));
	sum += texture(TEXTURE, UV + px * 0.7);
	sum += texture(TEXTURE, UV - px * 0.7);
	sum += texture(TEXTURE, UV + vec2( px.x, -px.y) * 0.7);
	sum += texture(TEXTURE, UV + vec2(-px.x,  px.y) * 0.7);
	sum *= 0.125;

	vec3 col = base.rgb + sum.rgb * glow_amount;
	// glow has to carry alpha too or it is invisible over a transparent viewport
	float a = clamp(base.a + sum.a * glow_amount * bleed, 0.0, 1.0);

	// hard alternating rows in screen space -- distinct, not a soft sine wash
	float row = mod(FRAGCOORD.y, scan_period);
	float lit = step(scan_period * 0.5, row);
	col *= mix(1.0 - scan_strength, 1.0, lit);

	COLOR = vec4(col, a);
}
