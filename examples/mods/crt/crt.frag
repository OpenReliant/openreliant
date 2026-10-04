// The CRT effect (crt.luau): the frame as an old curved monitor shows it. The glass bulges a
// little, so the picture's edges bend in and what falls outside the glass is black; scanlines run
// across it, one for each two rows of the window; and the corners are darker.
#version 450

// The frame as the effects before this one left it, and the frame before any effect.
layout(set = 2, binding = 0) uniform sampler2D source;
layout(set = 2, binding = 1) uniform sampler2D frame_image;

layout(set = 3, binding = 0, std140) uniform Frame {
    // x and y: the frame's size in pixels; z: the seconds passed.
    vec4 size_time;
    // x: how dark the scanlines are; y: how far the glass bulges; z: how dark the corners are.
    vec4 parameters;
} frame;

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 colour;

void main() {
    // The bulge: points move out from the middle the more, the farther they stand from it.
    vec2 centred = uv * 2.0 - 1.0;
    centred *= 1.0 + frame.parameters.y * dot(centred, centred);
    vec2 read = centred * 0.5 + 0.5;
    if (any(lessThan(read, vec2(0.0))) || any(greaterThan(read, vec2(1.0)))) {
        colour = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    vec3 picture = texture(source, read).rgb;
    // A scanline every two rows of the window, dark at its middle.
    float row = read.y * frame.size_time.y * 0.5;
    float line = 0.5 + 0.5 * cos(row * 6.2831853);
    picture *= 1.0 - frame.parameters.x * line;
    // The corners, darker the farther they stand from the middle.
    float edge = dot(centred, centred) * 0.5;
    picture *= 1.0 - frame.parameters.z * edge * edge;
    colour = vec4(picture, 1.0);
}
