//! Variants of the device's fragment shader with mods' functions in them
//! ([#629](https://github.com/OpenReliant/openreliant/issues/629)): `shaders/device.glsl`, or a
//! mod's replacement for it (`programs.zig`), compiled with a mod's lighting function
//! (`MOD_LIGHTING`), its surface function (`MOD_SURFACE`) or both, which the scripts register
//! (`src/scripting/shaders.zig`).
//!
//! Each variant has an id, and the pipelines that draw with it carry it in their key. Variant 0 is
//! the device shader the GPU started with. A surface function's draws use the variant with its id,
//! and the other draws use `base`, which the driver sets to a variant with the lighting function
//! where one draws. Replacing or removing a variant releases its pipelines, and its draws then use
//! `base`. While MOD EFFECTS is off (`Gpu.mod_effects`), every draw uses variant 0.
//!
//! **Improvement:** the original has no shaders from mods.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("sdl");

const openreliant = @import("openreliant");
const ModSurface = openreliant.engine.surrender.surrenderlib.srtexture.ModSurface;
const shader_compiler = @import("../shader_compiler.zig");
const Part = shader_compiler.Part;
const programs = @import("programs.zig");

/// The line of the device shader that the mods' functions go in place of.
const functions_line = "// mod_functions";

/// The most parts a variant is compiled from: the device shader cut where it includes
/// `colour.glsl`, the two functions, and the rest of the shader after them.
pub const max_parts = programs.max_parts + 2 + 1;

comptime {
    std.debug.assert(max_parts <= shader_compiler.max_parts);
}

/// A device shader cut where the mods' functions go: OpenReliant's own, or a mod's replacement.
pub const Template = struct {
    /// The parts before the functions, and the part after them.
    before: [programs.max_parts]Part,
    before_count: usize,
    after: Part,

    /// `file` cut where the mods' functions go, with `included` in place of the line that includes
    /// `colour.glsl`; null if it has no line `// mod_functions` after that one.
    pub fn of(file: Part, included: Part) ?Template {
        var template: Template = .{ .before = undefined, .before_count = 0, .after = undefined };
        const cut = programs.parts(file, included, &template.before);
        const last = &template.before[cut.len - 1];
        const at = programs.lineAt(last.source, functions_line) orelse return null;
        template.after = last.from(at + functions_line.len);
        last.* = last.before(at);
        template.before_count = cut.len;
        return template;
    }

    /// OpenReliant's own device shader, cut.
    pub fn builtin() Template {
        return of(programs.Name.device.own(), programs.colour).?;
    }

    /// The parts of the variant with the lighting function `lighting` and the surface function
    /// `surface`, each a mod's file, in `buffer`.
    pub fn parts(template: *const Template, lighting: ?Part, surface: ?Part, buffer: *[max_parts]Part) []const Part {
        var count: usize = 0;
        for (template.before[0..template.before_count]) |part| {
            buffer[count] = part;
            count += 1;
        }
        for ([_]?Part{ lighting, surface }) |function| if (function) |part| {
            buffer[count] = part;
            count += 1;
        };
        buffer[count] = template.after;
        count += 1;
        return buffer[0..count];
    }
};

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
    /// The variants by id, all but variant 0.
    shaders: std.AutoHashMapUnmanaged(u16, *c.SDL_GPUShader) = .empty,
    /// The variant of the draws without a surface function.
    base: u16 = 0,
    /// The surface function of every lit draw in the scene that has none of its own, if any.
    every: ?ModSurface = null,
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
    const both = try shader_compiler.compileParts(gpa, .openreliant, .fragment, Template.builtin().parts(lighting, surface, &buffer), preamble(true, true));
    defer both.deinit(gpa);
    if (both == .diagnostic) std.debug.print("{s}\n", .{both.diagnostic});
    try std.testing.expect(both == .compiled);
    const plain = try shader_compiler.compileParts(gpa, .openreliant, .fragment, Template.builtin().parts(null, null, &buffer), preamble(false, false));
    defer plain.deinit(gpa);
    try std.testing.expect(plain == .compiled);
    // A mistake in a mod's function names its file and line.
    const broken: Part = .{ .name = "cel/broken.glsl", .source = "\nvoid surface(inout Surface s, vec4 parameters, float time) { broken; }\n" };
    const failed = try shader_compiler.compileParts(gpa, .openreliant, .fragment, Template.builtin().parts(null, broken, &buffer), preamble(false, true));
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
}
