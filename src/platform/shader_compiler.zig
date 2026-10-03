//! Improvement: GLSL post-effect compilation for Vulkan and Metal (#621). The C++ boundary
//! catches library exceptions and owns temporary allocations. Results here use the caller's
//! allocator; neither success nor diagnostics borrow compiler memory.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Native = opaque {};
extern fn openreliant_compile_post_effect(name: [*:0]const u8, source: [*]const u8, length: c_int) ?*Native;
extern fn openreliant_shader_spirv(result: *const Native, count: *usize) [*]const u32;
extern fn openreliant_shader_metal(result: *const Native) [*:0]const u8;
extern fn openreliant_shader_diagnostic(result: *const Native) [*:0]const u8;
extern fn openreliant_shader_free(result: *Native) void;

/// Bounds compiler input before copying it or entering the native libraries.
pub const max_source_bytes = 1024 * 1024;

pub const Result = union(enum) {
    compiled: struct { spirv: []u32, metal: [:0]u8 },
    diagnostic: []u8,

    pub fn deinit(result: Result, gpa: Allocator) void {
        switch (result) {
            .compiled => |code| {
                gpa.free(code.spirv);
                gpa.free(code.metal);
            },
            .diagnostic => |text| gpa.free(text),
        }
    }
};

/// Compiles one fragment source. Includes are unavailable; callers resolve mod files themselves.
/// Texture slots 0/1 use set 2, and optional two-vec4 uniforms use set 3, slot 0.
pub fn compile(gpa: Allocator, name: []const u8, source: []const u8) Allocator.Error!Result {
    if (source.len > max_source_bytes) return .{ .diagnostic = try gpa.dupe(u8, "shader source exceeds 1 MiB") };
    if (std.mem.indexOfScalar(u8, source, 0) != null or std.mem.indexOfScalar(u8, name, 0) != null)
        return .{ .diagnostic = try gpa.dupe(u8, "shader source and filename cannot contain NUL") };
    const filename = try gpa.dupeZ(u8, name);
    defer gpa.free(filename);
    const native = openreliant_compile_post_effect(filename, source.ptr, @intCast(source.len)) orelse return error.OutOfMemory;
    defer openreliant_shader_free(native);
    const diagnostic = std.mem.span(openreliant_shader_diagnostic(native));
    if (diagnostic.len != 0) return .{ .diagnostic = try gpa.dupe(u8, diagnostic) };
    var count: usize = undefined;
    const words = openreliant_shader_spirv(native, &count);
    const spirv = try gpa.dupe(u32, words[0..count]);
    errdefer gpa.free(spirv);
    const metal = try gpa.dupeZ(u8, std.mem.span(openreliant_shader_metal(native)));
    return .{ .compiled = .{ .spirv = spirv, .metal = metal } };
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
