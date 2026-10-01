// The bloom the engine draws the finished frame through, so that the game's own bright things, its
// lights, its engine glows, its flares and the sun, bleed a little light into what stands around
// them, as a camera does. The original drew none: `--original` turns it off and the frame goes
// straight to the screen instead. And the display's gamma ramp, which the brightness sets, as the
// finished frame goes to the screen.
//
// One shader for all four passes, which `frame.settings.x` picks. `make shaders` compiles the
// vertex stage, with VERTEX defined, and the fragment stage, with FRAGMENT, as it does the device's.
#version 450
#extension GL_GOOGLE_include_directive : require

#include "colour.glsl"

#ifdef VERTEX

layout(location = 0) out vec2 uv;

void main() {
    // One triangle over the whole screen, from the vertex's number alone: no buffer to bind.
    vec2 corner = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
    gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
    // The frame's first row is its top, where the clip space's top is +1.
    uv = vec2(corner.x, 1.0 - corner.y);
}

#endif

#ifdef FRAGMENT

/// What the pass reads: the frame for the first, what the pass before left for the others.
layout(set = 2, binding = 0) uniform sampler2D source;
/// The frame itself, which only the last pass adds the bloom back onto.
layout(set = 2, binding = 1) uniform sampler2D frame_image;

layout(set = 3, binding = 0) uniform Frame {
    // x: which pass, 0 to take the bright parts, 1 to blur, 2 to add the bloom back and finish the
    // frame, 3 to put the finished frame on the screen through the gamma ramp. yz: one texel of the
    // image being read, along the axis a blur runs. w: the brightness a colour must pass to bloom;
    // in the third pass, how much of the bloom is added; in the fourth, the display's brightness.
    vec4 settings;
    // x: 1 for a frame kept in floats, whose highlights, past 1 where glows are stacked, are eased
    // rather than clipped, before they bloom and as the last pass finishes the frame. y: 1 for the
    // last pass to dither it to eight bits a channel.
    vec4 finish;
} frame;

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 result;

void main() {
    int pass = int(frame.settings.x);
    vec2 texel = frame.settings.yz;
    if (pass == 0) {
        // Only what stands above the threshold blooms, so that an ordinary lit hull does not.
        vec3 colour = texture(source, uv).rgb;
        // A fireball's heart, many times past white, blooms as white does.
        if (frame.finish.x > 0.0) colour = shouldered(colour);
        result = vec4(max(colour - vec3(frame.settings.w), vec3(0.0)), 1.0);
    } else if (pass == 1) {
        // Nine taps along one axis, weighted as a Gaussian; the two passes together blur both.
        const float weights[5] = float[](0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216);
        vec3 colour = texture(source, uv).rgb * weights[0];
        for (int tap = 1; tap < 5; tap++) {
            vec2 along = texel * float(tap);
            colour += texture(source, uv + along).rgb * weights[tap];
            colour += texture(source, uv - along).rgb * weights[tap];
        }
        result = vec4(colour, 1.0);
    } else if (pass == 2) {
        vec3 colour = texture(frame_image, uv).rgb + texture(source, uv).rgb * frame.settings.w;
        if (frame.finish.x > 0.0) colour = shouldered(colour);
        if (frame.finish.y > 0.0) colour = dithered(colour, ivec2(gl_FragCoord.xy), vec3(255.0));
        result = vec4(colour, 1.0);
    } else {
        // The gamma ramp `srd3d.dll` sets (`0x10005270`): each level at its power 1 / brightness,
        // and black for a brightness of 0.
        float brightness = frame.settings.w;
        vec3 colour = texture(source, uv).rgb;
        result = vec4(brightness > 0.0 ? pow(colour, vec3(1.0 / brightness)) : vec3(0.0), 1.0);
    }
}

#endif
