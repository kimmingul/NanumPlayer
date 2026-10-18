// NanumPlayer picture correction: conservative line darkening, strong (3/3).
// Original shader (no third-party code); it does not reconstruct or invent detail. A pixel that is
// both darker than the ring of its 8 neighbours and at (or next to) the local minimum, i.e. the core of a
// thin dark line or the dark side of an outline, is darkened multiplicatively by at most 0.14 (so the hue
// is kept). Nothing is ever brightened, therefore no bright halo can appear, and flat or smoothly
// graded areas are left alone by the thresholds. MAIN hook, source size.

//!DESC nanum-picture lines 3 (strong)
//!HOOK MAIN
//!BIND HOOKED

#define MAX_DARKEN 0.14

float luma(vec3 c) {
    return dot(c, vec3(0.2627, 0.6780, 0.0593));
}

vec4 hook() {
    vec4 center = HOOKED_texOff(vec2(0.0));
    float y0 = luma(center.rgb);
    float ring = 0.0;
    float lo = 1e9;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            if (x == 0 && y == 0) continue;
            float l = luma(HOOKED_texOff(vec2(float(x), float(y))).rgb);
            ring += l;
            lo = min(lo, l);
        }
    }
    ring *= 0.125;
    float contrast = smoothstep(0.02, 0.12, ring - y0);
    float core = 1.0 - smoothstep(0.0, 0.05, y0 - lo);
    float amount = MAX_DARKEN * contrast * core;
    return vec4(center.rgb * (1.0 - amount), center.a);
}
