// What the device's shader and the bloom's share of colour: sRGB's encoding, both ways, and the
// ordered dither to a colour's levels. `#include`d, and compiled with each.

// A colour as a texture or a vertex holds it, sRGB-encoded, in linear light.
vec3 decoded(vec3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), greaterThan(c, vec3(0.04045)));
}

// A colour in linear light, encoded in sRGB for the screen.
vec3 encoded(vec3 c) {
    c = clamp(c, 0.0, 1.0);
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, greaterThan(c, vec3(0.0031308)));
}

// A colour with each channel past `knee` eased toward 1 rather than clipped: what is far past it
// still goes white, as a fireball's heart does, but what lies between keeps its shading. What
// stays below the knee is left as it is.
vec3 shouldered(vec3 c) {
    const float knee = 0.8;
    vec3 over = max(c - knee, 0.0);
    return min(c, vec3(knee)) + (1.0 - knee) * over / (over + 1.0 - knee);
}

// `c` rounded to `levels` a channel over a 4 by 4 ordered dither at `pixel`.
vec3 dithered(vec3 c, ivec2 pixel, vec3 levels) {
    const float bayer[16] = float[](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
    ivec2 cell = pixel & 3;
    float threshold = (bayer[cell.y * 4 + cell.x] + 0.5) / 16.0;
    return floor(c * levels + threshold) / levels;
}
