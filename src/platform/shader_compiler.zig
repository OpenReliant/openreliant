//! Compiles GLSL shaders as OpenReliant runs, into SPIR-V for Vulkan and Metal's source for Metal,
//! with glslang and SPIRV-Cross (`shader_compiler.cpp`): mods' post effects (#621), the variants of
//! the device shader with mods' functions in them (#629), and mods' replacements for OpenReliant's
//! shaders, which `checkReplacement` and `checkLink` check (#630). The C++ wrapper catches the
//! libraries' exceptions; what it gives is copied into the caller's allocator.
//!
//! **Improvement:** the original has no shaders from mods.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Native = opaque {};
extern fn openreliant_compile_shader(kind: Kind, stage: Stage, count: c_int, names: [*]const [*:0]const u8, sources: [*]const [*]const u8, lengths: [*]const c_int, preamble: [*:0]const u8) ?*Native;
extern fn openreliant_check_replacement(name: [*:0]const u8, reference: [*]const u32, reference_count: usize, replacement: [*]const u32, replacement_count: usize) ?*Native;
extern fn openreliant_check_link(name: [*:0]const u8, vertex: [*]const u32, vertex_count: usize, fragment: [*]const u32, fragment_count: usize) ?*Native;
/// What `openreliant_check_replacement` and `openreliant_check_link` take: a name for the message,
/// and two shaders' SPIR-V.
const NativeCheck = @TypeOf(openreliant_check_link);
extern fn openreliant_shader_spirv(result: *const Native, count: *usize) [*]const u32;
extern fn openreliant_shader_metal(result: *const Native) [*:0]const u8;
extern fn openreliant_shader_diagnostic(result: *const Native) [*:0]const u8;
extern fn openreliant_shader_free(result: *Native) void;

/// The largest part of a shader's source the compiler takes.
pub const max_source_bytes = 1024 * 1024;

/// The message for a source or a name that holds a NUL byte, which the libraries can't take.
const nul_message = "shader source and filename cannot contain NUL";

/// The most parts a shader is compiled from.
pub const max_parts = 8;

/// What a shader is compiled as: a mod's post effect, checked against the resources post effects
/// get, or one of OpenReliant's shaders, a mod's replacement for one (checked by
/// `checkReplacement`) or a variant of the device shader (`gpu/variants.zig`).
pub const Kind = enum(c_int) { post_effect = 0, openreliant = 1 };

/// The stage a shader is compiled for. Post effects are fragment shaders.
pub const Stage = enum(c_int) {
    vertex = 0,
    fragment = 1,

    /// The definition OpenReliant's shaders pick the stage by, as `make shaders` gives it.
    pub fn definition(stage: Stage) []const u8 {
        return switch (stage) {
            .vertex => "#define VERTEX\n",
            .fragment => "#define FRAGMENT\n",
        };
    }
};

/// A part of a shader's source, the name its messages give it, such as `crt/crt.frag`, and the line
/// of that file it starts on, which a part cut from the middle of a file keeps.
pub const Part = struct {
    name: []const u8,
    source: []const u8,
    line: u32 = 1,

    /// The part of this one from `offset` on, starting on its line.
    pub fn from(part: Part, offset: usize) Part {
        const lines: u32 = @intCast(std.mem.count(u8, part.source[0..offset], "\n"));
        return .{ .name = part.name, .source = part.source[offset..], .line = part.line + lines };
    }

    /// The part of this one before `offset`.
    pub fn before(part: Part, offset: usize) Part {
        return .{ .name = part.name, .source = part.source[0..offset], .line = part.line };
    }
};

/// A compiled shader: SPIR-V for Vulkan, and Metal's source.
pub const Code = struct {
    spirv: []u32,
    metal: [:0]u8,

    pub fn deinit(code: Code, gpa: Allocator) void {
        gpa.free(code.spirv);
        gpa.free(code.metal);
    }
};

pub const Result = union(enum) {
    compiled: Code,
    diagnostic: []u8,

    pub fn deinit(result: Result, gpa: Allocator) void {
        switch (result) {
            .compiled => |code| code.deinit(gpa),
            .diagnostic => |text| gpa.free(text),
        }
    }
};

/// Compiles the mod's post effect `source`, called `name`, and checks that it reads only what post
/// effects get: up to two textures at set 2, bindings 0 and 1, and a uniform block of two `vec4`s
/// at set 3, binding 0.
pub fn compile(gpa: Allocator, name: []const u8, source: []const u8) Allocator.Error!Result {
    return compileParts(gpa, .post_effect, .fragment, &.{.{ .name = name, .source = source }}, "");
}

/// Compiles the shader of `stage` made of `parts`, in order, as `kind`, after the definitions in
/// `preamble`, such as `#define FRAGMENT`. Messages name the part they are about.
pub fn compileParts(gpa: Allocator, kind: Kind, stage: Stage, parts: []const Part, preamble: []const u8) Allocator.Error!Result {
    std.debug.assert(parts.len > 0 and parts.len <= max_parts);
    for (parts) |part| {
        if (part.source.len > max_source_bytes) return .{ .diagnostic = try std.fmt.allocPrint(gpa, "{s}: shader source exceeds 1 MiB", .{part.name}) };
        if (std.mem.indexOfScalar(u8, part.source, 0) != null or std.mem.indexOfScalar(u8, part.name, 0) != null)
            return .{ .diagnostic = try gpa.dupe(u8, nul_message) };
    }
    if (std.mem.indexOfScalar(u8, preamble, 0) != null) return .{ .diagnostic = try gpa.dupe(u8, nul_message) };
    // Each part after the first starts with a `#line` directive, so that the messages give its
    // file's own line numbers, and on a line of its own, so that it doesn't run on from the part
    // before. glslang counts each part's lines apart, so the directive goes in the part itself.
    var names: [max_parts][*:0]const u8 = undefined;
    var sources: [max_parts][]const u8 = undefined;
    var lengths: [max_parts]c_int = undefined;
    var made: usize = 0;
    defer for (names[0..made], sources[0..made], 0..) |name, source, at| {
        gpa.free(std.mem.span(name));
        if (at > 0) gpa.free(source);
    };
    for (parts, 0..) |part, at| {
        const name = try gpa.dupeZ(u8, part.name);
        const source = if (at == 0) part.source else std.fmt.allocPrint(gpa, "\n#line {d}\n{s}", .{ part.line, part.source }) catch |err| {
            gpa.free(name);
            return err;
        };
        names[made] = name;
        sources[made] = source;
        lengths[made] = @intCast(source.len);
        made += 1;
    }
    var pointers: [max_parts][*]const u8 = undefined;
    for (sources[0..made], pointers[0..made]) |source, *pointer| pointer.* = source.ptr;
    const definitions = try gpa.dupeZ(u8, preamble);
    defer gpa.free(definitions);
    const native = openreliant_compile_shader(kind, stage, @intCast(made), &names, &pointers, &lengths, definitions) orelse return error.OutOfMemory;
    defer openreliant_shader_free(native);
    if (try complaint(gpa, native)) |text| return .{ .diagnostic = text };
    var count: usize = undefined;
    const words = openreliant_shader_spirv(native, &count);
    const spirv = try gpa.dupe(u32, words[0..count]);
    errdefer gpa.free(spirv);
    const metal = try gpa.dupeZ(u8, std.mem.span(openreliant_shader_metal(native)));
    return .{ .compiled = .{ .spirv = spirv, .metal = metal } };
}

/// The result's diagnostic, owned, or null where it has none.
fn complaint(gpa: Allocator, native: *const Native) Allocator.Error!?[]u8 {
    const diagnostic = std.mem.span(openreliant_shader_diagnostic(native));
    return if (diagnostic.len == 0) null else try gpa.dupe(u8, diagnostic);
}

/// Why `replacement`, a mod's shader called `name`, can't stand in for OpenReliant's `reference`
/// of the same stage, owned, or null where it can: it may use only the textures and uniform blocks
/// the reference has, alike and no larger, read only the inputs the reference reads, write every
/// output the reference writes, and, as a fragment shader, no others.
pub fn checkReplacement(gpa: Allocator, name: []const u8, reference: []const u32, replacement: []const u32) Allocator.Error!?[]u8 {
    return check(gpa, openreliant_check_replacement, name, reference, replacement);
}

/// Why the fragment stage `fragment` reads what the vertex stage `vertex` doesn't write alike,
/// owned, or null where it doesn't.
pub fn checkLink(gpa: Allocator, name: []const u8, vertex: []const u32, fragment: []const u32) Allocator.Error!?[]u8 {
    return check(gpa, openreliant_check_link, name, vertex, fragment);
}

/// What the C++ check `native` complains of in the shaders `first` and `second`, named `name`.
fn check(gpa: Allocator, native: NativeCheck, name: []const u8, first: []const u32, second: []const u32) Allocator.Error!?[]u8 {
    const named = try gpa.dupeZ(u8, name);
    defer gpa.free(named);
    const result = native(named, first.ptr, first.len, second.ptr, second.len) orelse return error.OutOfMemory;
    defer openreliant_shader_free(result);
    return complaint(gpa, result);
}

const fixture =
    \\#version 450
    \\layout(location=0) in vec2 uv;
    \\layout(location=0) out vec4 colour;
    \\layout(set=2, binding=0) uniform sampler2D source;
    \\layout(set=3, binding=0, std140) uniform Frame { vec4 size_time; vec4 parameters; } frame;
    \\void main() { colour = texture(source, uv) * frame.parameters.x; }
;

test "post-effect compilation produces deterministic owned Vulkan and Metal code" {
    const gpa = std.testing.allocator;
    const a = try compile(gpa, "effect.frag", fixture);
    defer a.deinit(gpa);
    const b = try compile(gpa, "effect.frag", fixture);
    defer b.deinit(gpa);
    try std.testing.expect(a == .compiled and b == .compiled);
    try std.testing.expectEqualSlices(u32, a.compiled.spirv, b.compiled.spirv);
    try std.testing.expectEqualStrings(a.compiled.metal, b.compiled.metal);
    try std.testing.expect(std.mem.indexOf(u8, a.compiled.metal, "fragment") != null);
    try std.testing.expect(std.mem.indexOf(u8, a.compiled.metal, "[[texture(0)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a.compiled.metal, "[[buffer(0)]]") != null);
}

test "shader errors retain filenames and lines and reject incompatible resources" {
    const gpa = std.testing.allocator;
    const bad = try compile(gpa, "broken.frag", "#version 450\nvoid main() { broken; }\n");
    defer bad.deinit(gpa);
    try std.testing.expect(bad == .diagnostic);
    try std.testing.expect(std.mem.indexOf(u8, bad.diagnostic, "broken.frag:2") != null);
    const wrong = try std.mem.replaceOwned(u8, gpa, fixture, "set=2", "set=0");
    defer gpa.free(wrong);
    const rejected = try compile(gpa, "wrong.frag", wrong);
    defer rejected.deinit(gpa);
    try std.testing.expect(rejected == .diagnostic);
    try std.testing.expect(std.mem.indexOf(u8, rejected.diagnostic, "set 2") != null);
}

test "shader result allocation failures release native and Zig allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            const result = try compile(gpa, "effect.frag", fixture);
            defer result.deinit(gpa);
        }
    }.run, .{});
}

test "post-effect reflection rejects resource and interface variants" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "in vec2 uv", "in vec3 uv" },
        .{ "location=0) out", "location=1) out" },
        .{ "sampler2D source", "sampler2D source[2]" },
        .{ "binding=0) uniform sampler", "binding=2) uniform sampler" },
        .{ "vec4 size_time; vec4 parameters", "vec3 size_time; vec4 parameters" },
        .{ "set=3, binding=0", "set=3, binding=1" },
        .{ "colour = texture(source, uv)", "gl_FragDepth = 0.5; colour = texture(source, uv)" },
    };
    for (cases) |case| {
        const source = try std.mem.replaceOwned(u8, gpa, fixture, case[0], case[1]);
        defer gpa.free(source);
        const result = try compile(gpa, "variant.frag", source);
        defer result.deinit(gpa);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expect(std.mem.indexOf(u8, result.diagnostic, "variant.frag") != null);
    }
    const duplicate = try compile(gpa, "duplicate.frag", fixture ++
        "\nlayout(set=2, binding=0) uniform sampler2D duplicate_source;\n");
    defer duplicate.deinit(gpa);
    try std.testing.expect(duplicate == .diagnostic);
    const include = try compile(gpa, "include.frag", "#version 450\n#extension GL_GOOGLE_include_directive : require\n#include \"missing.glsl\"\nvoid main() {}\n");
    defer include.deinit(gpa);
    try std.testing.expect(include == .diagnostic);
}

test "post effects can omit resources and read the second texture slot" {
    const gpa = std.testing.allocator;
    const plain = try compile(gpa, "plain.frag",
        \\#version 450
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 colour;
        \\void main() { colour = vec4(uv, gl_FragCoord.x, 1); }
    );
    defer plain.deinit(gpa);
    try std.testing.expect(plain == .compiled);
    const source = try std.mem.replaceOwned(u8, gpa, fixture, "set=2, binding=0", "set=2, binding=1");
    defer gpa.free(source);
    const second = try compile(gpa, "second.frag", source);
    defer second.deinit(gpa);
    try std.testing.expect(second == .compiled);
    try std.testing.expect(std.mem.indexOf(u8, second.compiled.metal, "[[texture(1)]]") != null);
}

test "shader input bounds and failed diagnostic allocations clean up" {
    const gpa = std.testing.allocator;
    const nul = try compile(gpa, "nul.frag", "#version 450\x00");
    defer nul.deinit(gpa);
    try std.testing.expect(nul == .diagnostic);
    const large = try gpa.alloc(u8, max_source_bytes + 1);
    defer gpa.free(large);
    const bounded = try compile(gpa, "large.frag", large);
    defer bounded.deinit(gpa);
    try std.testing.expect(bounded == .diagnostic);
    try std.testing.checkAllAllocationFailures(gpa, struct {
        fn run(allocator: Allocator) !void {
            const result = try compile(allocator, "broken.frag", "#version 450\nvoid main() { broken; }");
            defer result.deinit(allocator);
            try std.testing.expect(result == .diagnostic);
        }
    }.run, .{});
}

test "a part cut from the middle of a file keeps the file's line numbers" {
    const gpa = std.testing.allocator;
    const parts = [_]Part{
        .{ .name = "mod/device.glsl", .source = "#version 450\n" },
        .{ .name = "colour.glsl", .source = "vec3 grey() { return vec3(0.5); }" },
        .{ .name = "mod/device.glsl", .source = "\nvoid main() {\n    broken;\n}\n", .line = 10 },
    };
    const result = try compileParts(gpa, .openreliant, .fragment, &parts, Stage.fragment.definition());
    defer result.deinit(gpa);
    try std.testing.expect(result == .diagnostic);
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostic, "mod/device.glsl:12") != null);
}
