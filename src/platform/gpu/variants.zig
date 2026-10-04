//! Variants of the device's fragment shader with mods' functions in them
//! ([#629](https://github.com/OpenReliant/openreliant/issues/629)): `shaders/device.glsl` compiled
//! with a mod's lighting function (`MOD_LIGHTING`), its surface function (`MOD_SURFACE`) or both,
//! which the scripts register (`src/scripting/shaders.zig`).
//!
//! Each variant has an id, and the pipelines that draw with it carry it in their key. Variant 0 is
//! OpenReliant's own shader. A surface function's draws use the variant with its id, and the other
//! draws use `base`, which the driver sets to a variant with the lighting function where one
//! draws. Replacing or removing a variant releases its pipelines, and its draws then use `base`.
//! While `on` is off (MOD EFFECTS), every draw uses OpenReliant's own shader.
//!
//! **Improvement:** the original has no shaders from mods.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("sdl");

const openreliant = @import("openreliant");
const ModSurface = openreliant.engine.surrender.surrenderlib.srtexture.ModSurface;
const shader_compiler = @import("../shader_compiler.zig");
const Part = shader_compiler.Part;

/// OpenReliant's device shader and what it includes, which the variants are compiled from.
const device_source = @embedFile("../shaders/device.glsl");
const colour_source = @embedFile("../shaders/colour.glsl");

/// The line of `device_source` that includes `colour_source`, which the variants put the file in
/// place of, and the line the mods' functions go in place of.
const include_line = "#include \"colour.glsl\"\n";
const functions_line = "// mod_functions\n";

/// Where those lines are, each once in the shader.
const include_at = lineAt(include_line);
const functions_at = lineAt(functions_line);

fn lineAt(comptime line: []const u8) usize {
    @setEvalBranchQuota(2_000_000);
    const at = std.mem.indexOf(u8, device_source, line) orelse @compileError("device.glsl has no line " ++ line);
    if (std.mem.lastIndexOf(u8, device_source, line) != at) @compileError("device.glsl has more than one line " ++ line);
    return at;
}

comptime {
    std.debug.assert(include_at < functions_at);
}

/// The most parts a variant is compiled from: the shader in three pieces, `colour.glsl`, and the
/// two functions.
pub const max_parts = 6;

/// The parts of the variant with the lighting function `lighting` and the surface function
/// `surface`, each a mod's file, in `buffer`.
pub fn parts(lighting: ?Part, surface: ?Part, buffer: *[max_parts]Part) []const Part {
    var count: usize = 0;
    buffer[count] = .{ .name = "device.glsl", .source = device_source[0..include_at] };
    count += 1;
    buffer[count] = .{ .name = "colour.glsl", .source = colour_source };
    count += 1;
    buffer[count] = .{ .name = "device.glsl", .source = device_source[include_at + include_line.len .. functions_at] };
    count += 1;
    for ([_]?Part{ lighting, surface }) |function| if (function) |part| {
        buffer[count] = part;
        count += 1;
    };
    buffer[count] = .{ .name = "device.glsl", .source = device_source[functions_at + functions_line.len ..] };
    count += 1;
    return buffer[0..count];
}

/// The definitions a variant is compiled with: the fragment stage, and the functions it has.
pub fn preamble(lighting: bool, surface: bool) []const u8 {
    const fragment = "#define FRAGMENT\n";
    const lit = "#define MOD_LIGHTING\n";
    const surfaced = "#define MOD_SURFACE\n";
    return switch (@as(u2, @intFromBool(lighting)) << 1 | @intFromBool(surface)) {
        0 => fragment,
        1 => fragment ++ surfaced,
        2 => fragment ++ lit,
        3 => fragment ++ lit ++ surfaced,
    };
}

/// What the variants read besides OpenReliant's own uniforms (`Custom`, set 3, binding 3), in
/// std140's layout: the surface function's parameters, the lighting function's, and the time.
pub const Uniforms = extern struct {
    surface: [4]f32,
    lighting: [4]f32,
    /// x: the seconds passed.
    time: [4]f32,

    comptime {
        std.debug.assert(@sizeOf(Uniforms) == 48);
    }
};

/// The uniform buffer the variants read `Uniforms` from.
pub const uniform_slot = 3;

/// The variant a draw is drawn with, and its surface function's parameters.
pub const Picked = struct {
    variant: u16 = 0,
    parameters: [4]f32 = @splat(0),
};

pub const Variants = struct {
    /// The variants by id, all but OpenReliant's own.
    shaders: std.AutoHashMapUnmanaged(u16, *c.SDL_GPUShader) = .empty,
    /// The variant of the draws without a surface function.
    base: u16 = 0,
    /// The surface function of every lit draw in the scene that has none of its own, if any.
    every: ?ModSurface = null,
    /// Whether the mods' variants draw (MOD EFFECTS).
    on: bool = true,
    /// The lighting function's parameters.
    lighting: [4]f32 = @splat(0),

    pub fn deinit(variants: *Variants, gpa: Allocator, handle: *c.SDL_GPUDevice) void {
        var it = variants.shaders.valueIterator();
        while (it.next()) |made| c.SDL_ReleaseGPUShader(handle, made.*);
        variants.shaders.deinit(gpa);
    }

    /// The variant and parameters of a draw: its object's surface function, `object`, else its
    /// texture's, `texture`, else, where it is `lit` in the scene, `every`'s. A function without a
    /// variant draws as `base`.
    pub fn pick(variants: Variants, object: ?ModSurface, texture: ?ModSurface, lit: bool) Picked {
        if (!variants.on) return .{};
        const surface = object orelse texture orelse (if (lit) variants.every else null);
        if (surface) |function| {
            if (variants.shaders.contains(function.function)) return .{ .variant = function.function, .parameters = function.parameters };
        }
        return .{ .variant = if (variants.shaders.contains(variants.base)) variants.base else 0 };
    }
};

test "a variant with both functions compiles, and with neither draws as OpenReliant's shader" {
    const gpa = std.testing.allocator;
    const lighting: Part = .{ .name = "cel/bands.glsl", .source = "float lighting(float cosine, vec4 parameters) { return cosine > parameters.x ? 1.0 : 0.3; }\n" };
    const surface: Part = .{ .name = "cel/ink.glsl", .source = "void surface(inout Surface s, vec4 parameters, float time) { s.glow = vec3(parameters.x * time); }\n" };
    var buffer: [max_parts]Part = undefined;
    const both = try shader_compiler.compileParts(gpa, .device_variant, parts(lighting, surface, &buffer), preamble(true, true));
    defer both.deinit(gpa);
    if (both == .diagnostic) std.debug.print("{s}\n", .{both.diagnostic});
    try std.testing.expect(both == .compiled);
    const plain = try shader_compiler.compileParts(gpa, .device_variant, parts(null, null, &buffer), preamble(false, false));
    defer plain.deinit(gpa);
    try std.testing.expect(plain == .compiled);
    // A mistake in a mod's function names its file and line.
    const broken: Part = .{ .name = "cel/broken.glsl", .source = "\nvoid surface(inout Surface s, vec4 parameters, float time) { broken; }\n" };
    const failed = try shader_compiler.compileParts(gpa, .device_variant, parts(null, broken, &buffer), preamble(false, true));
    defer failed.deinit(gpa);
    try std.testing.expect(failed == .diagnostic);
    try std.testing.expect(std.mem.indexOf(u8, failed.diagnostic, "cel/broken.glsl:2") != null);
}

test "a draw takes its object's function, its texture's, every lit draw's, or the base" {
    var variants: Variants = .{};
    defer variants.shaders.deinit(std.testing.allocator);
    // Two variants: 3, a surface function, and 5, the base with a lighting function.
    const shader: *c.SDL_GPUShader = @ptrFromInt(0x1000);
    try variants.shaders.put(std.testing.allocator, 3, shader);
    try variants.shaders.put(std.testing.allocator, 5, shader);
    const hologram: ModSurface = .{ .function = 3, .parameters = .{ 1, 2, 3, 4 } };
    const missing: ModSurface = .{ .function = 9 };
    try std.testing.expectEqual(Picked{}, variants.pick(null, null, true));
    variants.base = 5;
    try std.testing.expectEqual(Picked{ .variant = 5 }, variants.pick(null, null, true));
    try std.testing.expectEqual(Picked{ .variant = 3, .parameters = .{ 1, 2, 3, 4 } }, variants.pick(hologram, missing, false));
    try std.testing.expectEqual(Picked{ .variant = 3, .parameters = .{ 1, 2, 3, 4 } }, variants.pick(null, hologram, false));
    // A function without a variant draws as the base.
    try std.testing.expectEqual(Picked{ .variant = 5 }, variants.pick(missing, hologram, false));
    // Every lit draw, and only lit ones.
    variants.every = hologram;
    try std.testing.expectEqual(@as(u16, 3), variants.pick(null, null, true).variant);
    try std.testing.expectEqual(@as(u16, 5), variants.pick(null, null, false).variant);
    // Off, OpenReliant's own shader draws everything.
    variants.on = false;
    try std.testing.expectEqual(Picked{}, variants.pick(hologram, null, true));
}
