// NanumPlayer picture correction: edge-preserving bilateral denoise, medium (2/3).
// Original shader (no third-party code). Works at the size of the source picture on the MAIN hook,
// before scaling: neighbours are weighted by distance and by colour similarity, so flat noisy areas are
// smoothed while strong edges (large colour difference) keep their weight. This is a classic spatial
// filter, not a learned model.
//
// Parameters of this level: radius 2 px, spatial sigma 1.5, range sigma 0.060 (signal units 0..1).

//!DESC nanum-picture denoise 2 (medium)
//!HOOK MAIN
//!BIND HOOKED

#define RADIUS 2
#define SIGMA_S 1.5
#define SIGMA_R 0.060

vec4 hook() {
    vec4 center = HOOKED_texOff(vec2(0.0));
    vec3 sum = center.rgb;
    float wsum = 1.0;
    float inv_s = -0.5 / (SIGMA_S * SIGMA_S);
    float inv_r = -0.5 / (SIGMA_R * SIGMA_R);
    for (int y = -RADIUS; y <= RADIUS; y++) {
        for (int x = -RADIUS; x <= RADIUS; x++) {
            if (x == 0 && y == 0) continue;
            vec3 c = HOOKED_texOff(vec2(float(x), float(y))).rgb;
            vec3 dc = c - center.rgb;
            float w = exp(float(x * x + y * y) * inv_s + dot(dc, dc) * inv_r);
            sum += c * w;
            wsum += w;
        }
    }
    return vec4(sum / wsum, center.a);
}
