// The device's shader: what Direct3D 7's fixed function did with the vertices Surrender's driver
// hands over, for SDL's GPU interface, with OpenReliant's lighting of each pixel and its shadows. `make shaders` compiles the vertex stage, with VERTEX
// defined, and the fragment stage, with FRAGMENT, into SPIR-V, and from that into Metal's
// language. The platform layer embeds what it makes (src/platform/gpu.zig).
#version 450
#extension GL_GOOGLE_include_directive : require

#include "colour.glsl"

#ifdef VERTEX

// A vertex as the driver hands it over: on the screen, pixel centres on whole numbers, as
// Direct3D 7 has them; its depth, nearer greater; and one over its distance, scaled.
layout(location = 0) in vec4 position;
// Its colour's bytes as they lie in memory: blue, green, red and alpha.
layout(location = 1) in vec4 diffuse;
layout(location = 2) in vec2 coordinates;
// Its texture's layer in the bound array, or -1 for none.
layout(location = 3) in int layer;
// For lighting each pixel: where it stands in the camera's frame, its normal there, and the lights
// that don't reach it, all ones for none.
layout(location = 4) in vec3 view;
layout(location = 5) in vec3 normal;
layout(location = 6) in uint lightMask;
// What its pixels take besides their lights (gpu.zig's Shading): in the low byte the shadows, 0
// none, 1 the world's cascades, 2 the cockpit's map (device.zig's Receives); in the next two bits,
// how its texture is magnified, 0 by the settings' filter, 1 smoothly, 2 by FSR 1's edge-adaptive
// upscale, 3 as a glyph's coverage (srtexture.zig's Magnify); in the one after, 1 for the key
// lights to reach past its terminator, as a planet's atmosphere carries them; and in the two after
// that, 1 where its texture's normal map and its material map are shaded.
layout(location = 7) in uint shading;

layout(set = 1, binding = 0) uniform Target {
    // The frame's width and height in pixels.
    vec2 size;
} target;

layout(location = 0) out vec4 colour;
layout(location = 1) out vec2 uv;
layout(location = 2) flat out int image;
layout(location = 3) out vec3 place;
layout(location = 4) out vec3 facing;
layout(location = 5) flat out uint mask;
layout(location = 6) flat out uint shade;

void main() {
    // One over the reciprocal depth as the clip w makes colours and texture coordinates vary in
    // perspective, as Direct3D 7 made them by rhw. Stars carry none.
    float w = position.w > 0.0 ? 1.0 / position.w : 1.0;
    // Pixel centres lie half a pixel on from Direct3D 7's here.
    vec2 ndc = vec2((position.x + 0.5) / target.size.x * 2.0 - 1.0, 1.0 - (position.y + 0.5) / target.size.y * 2.0);
    gl_Position = vec4(ndc * w, position.z * w, w);
    gl_PointSize = 1.0;
    colour = diffuse.bgra;
    uv = coordinates;
    image = layer;
    place = view;
    facing = normal;
    mask = lightMask;
    shade = shading;
}

#endif

#ifdef FRAGMENT

layout(set = 2, binding = 0) uniform sampler2DArray images;
// The shadows' maps, a layer for each cascade and the cockpit's last, compared with a pixel's depth
// (gpu/shadows.zig).
layout(set = 2, binding = 1) uniform sampler2DArrayShadow shadowMaps;
// The array's normal maps and material maps, each at its texture's layer, in linear values
// (srtexture.zig's Maps): read only where the shading says the texture has them.
layout(set = 2, binding = 2) uniform sampler2DArray normalMaps;
layout(set = 2, binding = 3) uniform sampler2DArray materialMaps;

layout(set = 3, binding = 0) uniform Frame {
    // x: 1 to draw in 16-bit colour, dithered. y: 1 to magnify textures with a Catmull-Rom filter
    // rather than bilinearly. z: 1 to dither 32-bit colour as well, which costs nothing and keeps
    // a dark gradient, such as the nebula or a light's falloff, from banding. w: 1 to light in
    // linear light: the colours are decoded, lit, and encoded again as they are written.
    vec4 settings;
} frame;

// The frame's directional and point lights, for lighting each pixel. A light's colour is its red,
// green and blue; its vector, toward a directional light and as long as its intensity, or a point
// light's place and its reach; its mask; its kind, 0 directional or 1 point; and whether a caster
// shades what it lights.
struct Light {
    vec4 colour;
    vec4 vector;
    uint mask;
    uint kind;
    uint shadowed;
    uint unused;
};

layout(set = 3, binding = 1) uniform Lighting {
    uvec4 count;
    Light lights[64];
} lighting;

layout(location = 0) in vec4 colour;
layout(location = 1) in vec2 uv;
layout(location = 2) flat in int image;
layout(location = 3) in vec3 place;
layout(location = 4) in vec3 facing;
layout(location = 5) flat in uint mask;
layout(location = 6) flat in uint shade;
layout(location = 0) out vec4 result;

// A map's box along the sun (srshadow.zig): where a point of the camera's frame falls in the map,
// each row dotted with the point and 1, across and up from -1 to 1 and its depth from the sun's
// side from 0 to 1.
struct Box {
    vec4 rows[3];
    // For a cascade, the view depth it reaches to.
    float far;
    // A texel's width in the world, which a pixel's place is moved off its surface by.
    float texel;
    // How much of the sun a full shadow takes away.
    float depth;
    // How far apart the lookup's taps are, as a share of the map.
    float step;
};

const int cascadeCount = 4;
const int cockpitMap = cascadeCount;

layout(set = 3, binding = 2) uniform Shadows {
    Box boxes[cascadeCount + 1];
    // 1 where the frame has shadows.
    uint enabled;
    // The lookup's taps across and down.
    uint across;
    // 1 where the cockpit has a map.
    uint cockpit;
    uint unused;
} shadows;

// How many texels a pixel's place is moved off its surface, along its normal, before its shadow
// is looked up, so that a surface does not shade itself.
const float normalOffset = 1.5;

// How much of the sun reaches the pixel in map `map`, from its box's depth of shadow to 1: from a
// square of taps around it, each comparing the four texels around it. Outside the map it is lit.
float lookUp(int map, vec3 n) {
    Box box = shadows.boxes[map];
    vec4 p = vec4(place + n * (box.texel * normalOffset), 1.0);
    vec3 at = vec3(dot(box.rows[0], p), dot(box.rows[1], p), dot(box.rows[2], p));
    if (any(greaterThan(abs(at.xy), vec2(1.0)))) return 1.0;
    vec2 uv = vec2(at.x, -at.y) * 0.5 + 0.5;
    int across = int(shadows.across);
    float middle = float(across - 1) * 0.5;
    float sum = 0.0;
    for (int y = 0; y < across; y++) {
        for (int x = 0; x < across; x++) {
            vec2 offset = (vec2(x, y) - middle) * box.step;
            sum += texture(shadowMaps, vec4(uv + offset, float(map), at.z));
        }
    }
    return 1.0 - box.depth * (1.0 - sum / float(across * across));
}

// The shadows the pixel takes, the low byte of its shading.
uint receives() {
    return shade & 0xFFu;
}

// How much of the sun reaches the pixel: the cockpit's in its own map, where there is one; the
// world's in the first cascade that reaches as deep as it stands, fading to lit toward the last
// cascade's end.
float sunlit(vec3 n) {
    if (receives() == 2u) return shadows.cockpit != 0u ? lookUp(cockpitMap, n) : 1.0;
    for (int i = 0; i < cascadeCount; i++) {
        float far = shadows.boxes[i].far;
        if (place.z > far) continue;
        float lit = lookUp(i, n);
        if (i == cascadeCount - 1) lit = mix(lit, 1.0, smoothstep(far * 0.8, far, place.z));
        return lit;
    }
    return 1.0;
}

// The surface a pixel shows the lights: its normal, a unit long or none, toward the eye, and, for a
// material's, how much of the ambient light reaches it, how rough it is, how metallic, and the
// share of light it reflects straight back.
struct Surface {
    vec3 normal;
    vec3 toEye;
    bool material;
    float occlusion;
    float roughness;
    float metallic;
    vec3 reflectance;
};

// The share of light a surface that is no metal reflects straight back: about 4 percent.
const float dielectricReflectance = 0.04;
// The least roughness a material takes, short of which its highlights shrink to points too fine for
// the pixels.
const float leastRoughness = 0.045;
const float pi = 3.14159265358979323846;

// What a light of unit strength along `l` adds as a highlight to a material's pixel, in the diffuse
// light's units, which fold in pi as Lambert's does: GGX's microfacets, Smith's shadowing as
// Schlick fits it to GGX, and Schlick's Fresnel, times the cosine.
vec3 highlight(Surface s, vec3 l) {
    float nl = dot(s.normal, l);
    if (nl <= 0.0) return vec3(0.0);
    vec3 h = normalize(l + s.toEye);
    float nv = max(dot(s.normal, s.toEye), 1e-4);
    float nh = max(dot(s.normal, h), 0.0);
    float vh = max(dot(s.toEye, h), 0.0);
    float a = s.roughness * s.roughness;
    float a2 = a * a;
    float d = nh * nh * (a2 - 1.0) + 1.0;
    float microfacets = a2 / (pi * d * d);
    float k = (s.roughness + 1.0) * (s.roughness + 1.0) / 8.0;
    float shadowing = nl / (nl * (1.0 - k) + k) * (nv / (nv * (1.0 - k) + k));
    vec3 fresnel = s.reflectance + (1.0 - s.reflectance) * pow(1.0 - vh, 5.0);
    return pi * microfacets * shadowing * fresnel / (4.0 * nv);
}

// What the directional and point lights add to this pixel, as the pipeline adds them for each
// vertex (srmesh.zig): nothing for a vertex that comes lit already, as every one does in the
// original's look. A shadowed light is scaled by how much of the sun reaches the pixel, looked up
// once, and only where such a light faces it. On a material's pixel, the highlights each light
// gives go to `highlights`.
const float terminatorWrap = 0.25;

vec3 lights(Surface s, out vec3 highlights) {
    highlights = vec3(0.0);
    if (mask == 0xFFFFFFFFu || dot(s.normal, s.normal) < 0.5) return vec3(0.0);
    vec3 n = s.normal;
    vec3 sum = vec3(0.0);
    bool shaded = receives() != 0u && shadows.enabled != 0u;
    float sun = -1.0;
    for (uint i = 0u; i < lighting.count.x; i++) {
        Light light = lighting.lights[i];
        if ((light.mask & mask) != 0u) continue;
        if (light.kind == 0u) {
            float amount = dot(n, light.vector.xyz);
            float strength = sqrt(dot(light.vector.xyz, light.vector.xyz));
            // A planet's atmosphere carries the sun a little way past its terminator: the key
            // light's cosine is taken from -terminatorWrap rather than from 0.
            if ((shade & 0x400u) != 0u && light.shadowed != 0u) {
                amount = (amount / strength + terminatorWrap) / (1.0 + terminatorWrap) * strength;
            }
            if (amount <= 0.0) continue;
            // In linear light the key light falls off as light does. A fill light, the nebula's
            // glow, falls off as the original's did, which its colour and strength were chosen
            // for: otherwise the side of a ship away from the sun glows with it.
            if (frame.settings.w > 0.0 && light.shadowed == 0u) amount = decoded(vec3(amount)).x;
            float reaching = 1.0;
            if (shaded && light.shadowed != 0u) {
                if (sun < 0.0) sun = sunlit(n);
                reaching = sun;
            }
            sum += amount * reaching * light.colour.rgb;
            if (!s.material) continue;
            // A fill light is no point of light but a glow over much of the sky, which a rough
            // surface reflects much as it takes it in: it gives a material no highlight, but its
            // reflectance's share of the light, so that metal takes the nebula's tint as paint
            // does.
            vec3 reflected = light.shadowed == 0u ? s.reflectance * amount : highlight(s, light.vector.xyz / strength) * strength;
            highlights += reflected * reaching * light.colour.rgb;
            continue;
        }
        vec3 d = light.vector.xyz - place;
        float r2 = dot(d, d);
        float reach = light.vector.w;
        if (r2 >= reach * reach) continue;
        float along = dot(d, n);
        if (along <= 0.0) continue;
        float r = sqrt(r2);
        // (1 - r / reach)^2 times the cosine, as the pipeline works it out.
        sum += (1.0 / r + r / (reach * reach) - 2.0 / reach) * along * light.colour.rgb;
        if (s.material) {
            float falloff = (1.0 - r / reach) * (1.0 - r / reach);
            highlights += highlight(s, d / r) * falloff * light.colour.rgb;
        }
    }
    return sum;
}

// The frame of the pixel's texture on its surface, of unit normal `n`: the directions in which its
// coordinates' u and v grow, from how its place and its coordinates change across the screen, so
// that the meshes need no tangents. A column of zeros where the coordinates don't change.
mat3 textureFrame(vec3 n, vec3 p, vec2 at) {
    vec3 dp1 = dFdx(p);
    vec3 dp2 = dFdy(p);
    vec2 duv1 = dFdx(at);
    vec2 duv2 = dFdy(at);
    float determinant = duv1.x * duv2.y - duv2.x * duv1.y;
    if (abs(determinant) < 1e-12) return mat3(vec3(0.0), vec3(0.0), n);
    vec3 t = (dp1 * duv2.y - dp2 * duv1.y) / determinant;
    vec3 b = (dp2 * duv1.x - dp1 * duv2.x) / determinant;
    // Onto the surface, a unit long each.
    t -= n * dot(n, t);
    b -= n * dot(n, b);
    float tl = dot(t, t);
    float bl = dot(b, b);
    if (tl < 1e-20 || bl < 1e-20) return mat3(vec3(0.0), vec3(0.0), n);
    return mat3(t * inversesqrt(tl), b * inversesqrt(bl), n);
}

// The surface the pixel shows the lights, of texel `texel`: its normal, bent by its texture's
// normal map where it is shaded, through `onTexture` (`textureFrame`), and its material, where it
// has one.
Surface surfaceOf(vec4 texel, mat3 onTexture) {
    Surface s;
    float length = length(facing);
    s.normal = length < 1e-6 ? vec3(0.0) : facing / length;
    s.toEye = normalize(-place);
    s.material = false;
    s.occlusion = 1.0;
    s.roughness = 1.0;
    s.metallic = 0.0;
    s.reflectance = vec3(dielectricReflectance);
    if (image < 0 || length < 1e-6) return s;
    if ((shade & 0x800u) != 0u && dot(onTexture[0], onTexture[0]) > 0.0) {
        vec3 bent = texture(normalMaps, vec3(uv, image)).xyz * 2.0 - 1.0;
        // OpenGL's normal maps point their y toward the texture's top, where its v grows down.
        bent.y = -bent.y;
        s.normal = normalize(onTexture * bent);
    }
    if ((shade & 0x1000u) != 0u) {
        vec3 orm = texture(materialMaps, vec3(uv, image)).rgb;
        s.material = true;
        s.occlusion = orm.r;
        s.roughness = max(orm.g, leastRoughness);
        s.metallic = orm.b;
        // A metal tints what it reflects with its own colour, which reaches it in linear light.
        vec3 base = frame.settings.w > 0.0 ? texel.rgb : decoded(texel.rgb);
        s.reflectance = mix(vec3(dielectricReflectance), base, s.metallic);
    }
    return s;
}

// A texture magnified with a Catmull-Rom filter, from nine bilinear taps: sharper than bilinear,
// smoother than the nearest texel.
vec4 catmullRom(vec2 at, float layer) {
    vec2 size = vec2(textureSize(images, 0).xy);
    vec2 position = at * size;
    vec2 centre = floor(position - 0.5) + 0.5;
    vec2 f = position - centre;
    vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    vec2 w3 = f * f * (-0.5 + 0.5 * f);
    vec2 w12 = w1 + w2;
    vec2 t0 = (centre - 1.0) / size;
    vec2 t12 = (centre + w2 / w12) / size;
    vec2 t3 = (centre + 2.0) / size;
    vec4 sum = vec4(0.0);
    sum += textureLod(images, vec3(t0.x, t0.y, layer), 0.0) * w0.x * w0.y;
    sum += textureLod(images, vec3(t12.x, t0.y, layer), 0.0) * w12.x * w0.y;
    sum += textureLod(images, vec3(t3.x, t0.y, layer), 0.0) * w3.x * w0.y;
    sum += textureLod(images, vec3(t0.x, t12.y, layer), 0.0) * w0.x * w12.y;
    sum += textureLod(images, vec3(t12.x, t12.y, layer), 0.0) * w12.x * w12.y;
    sum += textureLod(images, vec3(t3.x, t12.y, layer), 0.0) * w3.x * w12.y;
    sum += textureLod(images, vec3(t0.x, t3.y, layer), 0.0) * w0.x * w3.y;
    sum += textureLod(images, vec3(t12.x, t3.y, layer), 0.0) * w12.x * w3.y;
    sum += textureLod(images, vec3(t3.x, t3.y, layer), 0.0) * w3.x * w3.y;
    return clamp(sum, 0.0, 1.0);
}

// A texture magnified with a cubic B-spline, from four bilinear taps: smooth, neither ringing nor
// sharpening, for a soft image stretched far. Each tap falls between two texels, so that the
// bilinear filter weighs them as the spline does.
vec4 bSpline(vec2 at, float layer) {
    vec2 size = vec2(textureSize(images, 0).xy);
    vec2 position = at * size - 0.5;
    vec2 base = floor(position);
    vec2 f = position - base;
    vec2 f2 = f * f;
    vec2 f3 = f2 * f;
    vec2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    vec2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    vec2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
    vec2 w3 = f3 / 6.0;
    vec2 g0 = w0 + w1;
    vec2 g1 = w2 + w3;
    vec2 t0 = (base - 0.5 + w1 / g0) / size;
    vec2 t1 = (base + 1.5 + w3 / g1) / size;
    vec4 sum = vec4(0.0);
    sum += textureLod(images, vec3(t0.x, t0.y, layer), 0.0) * g0.x * g0.y;
    sum += textureLod(images, vec3(t1.x, t0.y, layer), 0.0) * g1.x * g0.y;
    sum += textureLod(images, vec3(t0.x, t1.y, layer), 0.0) * g0.x * g1.y;
    sum += textureLod(images, vec3(t1.x, t1.y, layer), 0.0) * g1.x * g1.y;
    return sum;
}

// FSR 1's edge-adaptive upscale, EASU, from AMD's FidelityFX Super Resolution 1.0, whose notice
// follows. A picture magnified from twelve texels about the fragment, each weighed by a kernel
// shaped as Lanczos's and stretched along the edge the nearest four show, then held between those
// four so that it does not ring.
//
// Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
// associated documentation files (the "Software"), to deal in the Software without restriction,
// including without limitation the rights to use, copy, modify, merge, publish, distribute,
// sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or
// substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
// NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
// DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
// OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

// A texel's luma, twice over, from two multiplies.
float easuLuma(vec3 c) {
    return c.b * 0.5 + (c.r * 0.5 + c.g);
}

vec3 easuTexel(ivec2 at, ivec2 last, int layer) {
    return texelFetch(images, ivec3(clamp(at, ivec2(0), last), layer), 0).rgb;
}

// Adds one of the nearest four texels' part of the edge's direction and its strength, weighed as a
// bilinear filter weighs the texel: its gradient across a, b, c, d and e, c the texel.
//     a
//   b c d
//     e
void easuSet(inout vec2 dir, inout float len, float w, float lA, float lB, float lC, float lD, float lE) {
    float lenX = 1.0 / max(max(abs(lD - lC), abs(lC - lB)), 1.0 / 65536.0);
    float dirX = lD - lB;
    dir.x += dirX * w;
    lenX = clamp(abs(dirX) * lenX, 0.0, 1.0);
    len += lenX * lenX * w;
    float lenY = 1.0 / max(max(abs(lE - lC), abs(lC - lA)), 1.0 / 65536.0);
    float dirY = lE - lA;
    dir.y += dirY * w;
    lenY = clamp(abs(dirY) * lenY, 0.0, 1.0);
    len += lenY * lenY * w;
}

// Adds a texel `off` from the fragment, weighed by the kernel turned along `dir` and stretched by
// `len`: Lanczos 2 approximated without a sine, its window `lob`, clipped at `clp`.
void easuTap(inout vec3 aC, inout float aW, vec2 off, vec2 dir, vec2 len, float lob, float clp, vec3 c) {
    vec2 v = vec2(off.x * dir.x + off.y * dir.y, off.x * -dir.y + off.y * dir.x) * len;
    float d2 = min(v.x * v.x + v.y * v.y, clp);
    float wB = 2.0 / 5.0 * d2 - 1.0;
    float wA = lob * d2 - 1.0;
    wB = 25.0 / 16.0 * wB * wB - (25.0 / 16.0 - 1.0);
    float w = wB * wA * wA;
    aC += c * w;
    aW += w;
}

// The twelve texels about f, the texel at or before the fragment:
//     b c
//   e f g h
//   i j k l
//     n o
vec4 easu(vec2 at, float layer) {
    ivec2 size = textureSize(images, 0).xy;
    ivec2 last = size - 1;
    int l = int(layer);
    vec2 pp = at * vec2(size) - 0.5;
    vec2 fp = floor(pp);
    pp -= fp;
    ivec2 f0 = ivec2(fp);
    vec3 b = easuTexel(f0 + ivec2(0, -1), last, l);
    vec3 c = easuTexel(f0 + ivec2(1, -1), last, l);
    vec3 e = easuTexel(f0 + ivec2(-1, 0), last, l);
    vec3 f = easuTexel(f0, last, l);
    vec3 g = easuTexel(f0 + ivec2(1, 0), last, l);
    vec3 h = easuTexel(f0 + ivec2(2, 0), last, l);
    vec3 i = easuTexel(f0 + ivec2(-1, 1), last, l);
    vec3 j = easuTexel(f0 + ivec2(0, 1), last, l);
    vec3 k = easuTexel(f0 + ivec2(1, 1), last, l);
    vec3 m = easuTexel(f0 + ivec2(2, 1), last, l);
    vec3 n = easuTexel(f0 + ivec2(0, 2), last, l);
    vec3 o = easuTexel(f0 + ivec2(1, 2), last, l);
    float bL = easuLuma(b), cL = easuLuma(c), eL = easuLuma(e), fL = easuLuma(f);
    float gL = easuLuma(g), hL = easuLuma(h), iL = easuLuma(i), jL = easuLuma(j);
    float kL = easuLuma(k), mL = easuLuma(m), nL = easuLuma(n), oL = easuLuma(o);
    vec2 dir = vec2(0.0);
    float len = 0.0;
    easuSet(dir, len, (1.0 - pp.x) * (1.0 - pp.y), bL, eL, fL, gL, jL);
    easuSet(dir, len, pp.x * (1.0 - pp.y), cL, fL, gL, hL, kL);
    easuSet(dir, len, (1.0 - pp.x) * pp.y, fL, iL, jL, kL, nL);
    easuSet(dir, len, pp.x * pp.y, gL, jL, kL, mL, oL);
    // The edge's direction, level where there is none, and its strength, shaped.
    float dirR = dot(dir, dir);
    bool level = dirR < 1.0 / 32768.0;
    dir = level ? vec2(1.0, 0.0) : dir * inversesqrt(dirR);
    len = len * 0.5;
    len *= len;
    // The kernel stretched from 1 along the axes to the square root of 2 on the diagonals, and
    // across the edge up to twice; its window from about the square root of 2 to about 2.
    float stretch = dot(dir, dir) / max(abs(dir.x), abs(dir.y));
    vec2 len2 = vec2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
    float lob = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len;
    float clp = 1.0 / lob;
    vec3 aC = vec3(0.0);
    float aW = 0.0;
    easuTap(aC, aW, vec2(0.0, -1.0) - pp, dir, len2, lob, clp, b);
    easuTap(aC, aW, vec2(1.0, -1.0) - pp, dir, len2, lob, clp, c);
    easuTap(aC, aW, vec2(-1.0, 1.0) - pp, dir, len2, lob, clp, i);
    easuTap(aC, aW, vec2(0.0, 1.0) - pp, dir, len2, lob, clp, j);
    easuTap(aC, aW, vec2(0.0, 0.0) - pp, dir, len2, lob, clp, f);
    easuTap(aC, aW, vec2(-1.0, 0.0) - pp, dir, len2, lob, clp, e);
    easuTap(aC, aW, vec2(1.0, 1.0) - pp, dir, len2, lob, clp, k);
    easuTap(aC, aW, vec2(2.0, 1.0) - pp, dir, len2, lob, clp, m);
    easuTap(aC, aW, vec2(2.0, 0.0) - pp, dir, len2, lob, clp, h);
    easuTap(aC, aW, vec2(1.0, 0.0) - pp, dir, len2, lob, clp, g);
    easuTap(aC, aW, vec2(1.0, 2.0) - pp, dir, len2, lob, clp, o);
    easuTap(aC, aW, vec2(0.0, 2.0) - pp, dir, len2, lob, clp, n);
    vec3 rgb = clamp(aC / aW, min(min(f, g), min(j, k)), max(max(f, g), max(j, k)));
    return vec4(rgb, textureLod(images, vec3(at, layer), 0.0).a);
}

// The coverage of the texel at `at` of the glyph in `layer`, the grey its level is drawn in, none
// outside the glyph.
float coverageAt(ivec2 at, float layer, ivec2 size) {
    if (any(lessThan(at, ivec2(0))) || any(greaterThanEqual(at, size))) return 0.0;
    float level = texelFetch(images, ivec3(at, int(layer)), 0).r;
    // In linear light the texture comes decoded, as a colour; the coverage is taken as stored,
    // whatever the lighting.
    return frame.settings.w > 0.0 ? encoded(vec3(level)).x : level;
}

// A glyph of the menus' fonts as the font draws it, each of its pixels a square of its own
// coverage, the grey its level is drawn in: the step from one texel to the next eased over a pixel
// of the frame rather than a texel, so that the letters keep the fonts' shapes and greys at any
// size, without the nearest texel's uneven steps or a filter's blur. At a whole multiple of the
// font's size, its pixels come out as they are. Its colour is the vertex's alone. texels is how
// many of the texture's texels a pixel of the frame spans.
vec4 glyph(vec2 at, float layer, float texels) {
    ivec2 size = textureSize(images, 0).xy;
    vec2 position = at * vec2(size) - 0.5;
    ivec2 cell = ivec2(floor(position));
    vec2 f = clamp((position - vec2(cell) - 0.5) / texels + 0.5, 0.0, 1.0);
    float coverage = mix(
        mix(coverageAt(cell, layer, size), coverageAt(cell + ivec2(1, 0), layer, size), f.x),
        mix(coverageAt(cell + ivec2(0, 1), layer, size), coverageAt(cell + ivec2(1, 1), layer, size), f.x),
        f.y);
    return vec4(1.0, 1.0, 1.0, coverage);
}

// The texture at the fragment: magnified as the settings say, smoothly, by FSR 1 or as a glyph
// where its shading asks, minified by the sampler. texels is how many texels a pixel spans.
vec4 sampled(float texels) {
    float layer = float(image);
    if (frame.settings.y > 0.0 && textureQueryLod(images, uv).y < 0.0) {
        uint magnify = (shade >> 8) & 3u;
        if (magnify == 3u) return glyph(uv, layer, texels);
        if (magnify == 2u) return easu(uv, layer);
        return magnify == 1u ? bSpline(uv, layer) : catmullRom(uv, layer);
    }
    return texture(images, vec3(uv, layer));
}

void main() {
    // Worked out here, where every pixel of a quad reaches it, as a derivative needs.
    vec2 span = fwidth(uv) * vec2(textureSize(images, 0).xy);
    vec3 unbent = dot(facing, facing) < 1e-12 ? vec3(0.0, 0.0, 1.0) : normalize(facing);
    mat3 onTexture = textureFrame(unbent, place, uv);
    vec4 texel = image < 0 ? vec4(1.0) : sampled(max(span.x, span.y));
    Surface s = surfaceOf(texel, onTexture);
    vec3 highlights;
    vec3 added = lights(s, highlights);
    vec4 c = vec4(0.0, 0.0, 0.0, texel.a * colour.a);
    // What of the texture the lights reach: a metal's colour goes to its highlights alone.
    vec3 diffuse = texel.rgb * (1.0 - s.metallic);
    if (frame.settings.w > 0.0) {
        // In linear light, from decoded textures: the lights times the texture, encoded again for
        // the frame, which blends encoded as the game's effects were made to; and the vertex's own
        // colour, its ambient and baked light, added as the original added it, whose neutral floor
        // the lights' colours were chosen against. A material adds its highlights to its lights,
        // and its occlusion shades the ambient light.
        c.rgb = min(encoded(diffuse * min(added, vec3(1.0)) + highlights) + encoded(texel.rgb) * colour.rgb * s.occlusion, vec3(1.0));
    } else if (!s.material) {
        // Direct3D 7's stages: the texture times the colour, or the colour alone, the lights added
        // for the pixel and each channel held to 1.
        c.rgb = texel.rgb * min(colour.rgb + added, vec3(1.0));
    } else {
        c.rgb = min(texel.rgb * colour.rgb * s.occlusion + diffuse * added + highlights, vec3(1.0));
    }
    if (frame.settings.x > 0.0 || frame.settings.z > 0.0) {
        // To the levels the frame is kept in: five bits of red and blue and six of green in 16-bit
        // colour, eight bits a channel otherwise.
        vec3 levels = frame.settings.x > 0.0 ? vec3(31.0, 63.0, 31.0) : vec3(255.0);
        c.rgb = dithered(c.rgb, ivec2(gl_FragCoord.xy), levels);
    }
    result = c;
}

#endif
