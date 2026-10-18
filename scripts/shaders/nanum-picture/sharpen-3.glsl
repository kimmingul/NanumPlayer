// NanumPlayer picture correction: bounded sharpening, strong (3/3).
// Original shader (no third-party code). Luma-only unsharp mask: the difference between the pixel and its
// 3x3 gaussian blur is soft-thresholded (tiny differences, i.e. noise, are not amplified), limited to
// +-0.12, scaled by 1.50 and added to all channels. The result is then confined to the minimum and
// maximum of the 3x3 neighbourhood of every channel, so no overshoot (halo / ringing) can be produced and
// no clamp to a fixed 0..1 range is needed (HDR signals pass unchanged). MAIN hook, source size.

//!DESC nanum-picture sharpen 3 (strong)
//!HOOK MAIN
//!BIND HOOKED

#define AMOUNT 1.50
#define LIMIT 0.12
#define NOISE_FLOOR 0.004

float luma(vec3 c) {
    return dot(c, vec3(0.2627, 0.6780, 0.0593));
}

vec4 hook() {
    vec4 center = HOOKED_texOff(vec2(0.0));
    vec3 lo = center.rgb;
    vec3 hi = center.rgb;
    float blur = luma(center.rgb) * 4.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            if (x == 0 && y == 0) continue;
            vec3 c = HOOKED_texOff(vec2(float(x), float(y))).rgb;
            lo = min(lo, c);
            hi = max(hi, c);
            float w = (x == 0 || y == 0) ? 2.0 : 1.0;
            blur += luma(c) * w;
        }
    }
    blur *= 0.0625;
    float detail = luma(center.rgb) - blur;
    float mag = max(abs(detail) - NOISE_FLOOR, 0.0);
    float delta = clamp(sign(detail) * mag * AMOUNT, -LIMIT, LIMIT);
    vec3 outc = clamp(center.rgb + vec3(delta), lo, hi);
    return vec4(outc, center.a);
}
