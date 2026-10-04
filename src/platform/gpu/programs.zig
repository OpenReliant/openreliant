//! OpenReliant's own shaders, `shaders/device.glsl`, `shaders/bloom.glsl` and `shaders/shadow.glsl`,
//! and mods' replacements for them ([#630](https://github.com/OpenReliant/openreliant/issues/630)).
//! Each is one GLSL file with a vertex stage and a fragment stage, picked by `VERTEX` or `FRAGMENT`.
//! `make shaders` compiles OpenReliant's own into the SPIR-V and Metal code this embeds. A mod's
//! replacement is compiled as OpenReliant starts (`src/openreliant/whole_shaders.zig`), and the GPU
//! draws with it in place of OpenReliant's.
//!
//! **Improvement:** the original has no shaders, and nothing to replace them with.

const std = @import("std");

const shader_compiler = @import("../shader_compiler.zig");
const Code = shader_compiler.Code;
const Part = shader_compiler.Part;
const Stage = shader_compiler.Stage;

/// One of OpenReliant's shaders.
pub const Name = enum {
    /// What draws the scene, the display and the menus: Direct3D 7's fixed function, with
    /// OpenReliant's lighting.
    device,
    /// The screen's passes: the bloom, the frame's finish and the gamma ramp, whose vertex stage the
    /// mods' post effects draw with too.
    bloom,
    /// The shadow maps' depth pass.
    shadow,

    /// Its file, which a mod's file of the same name replaces.
    pub fn file(name: Name) []const u8 {
        return switch (name) {
            inline else => |tag| @tagName(tag) ++ ".glsl",
        };
    }

    /// Its file, as OpenReliant has it.
    pub fn own(name: Name) Part {
        return .{ .name = name.file(), .source = name.source() };
    }

    /// Its GLSL source.
    pub fn source(name: Name) []const u8 {
        return switch (name) {
            inline else => |tag| @embedFile("../shaders/" ++ @tagName(tag) ++ ".glsl"),
        };
    }

    /// Its stage `stage` as `make shaders` compiled it: SPIR-V where `spirv`, Metal's source
    /// otherwise.
    pub fn builtin(name: Name, stage: Stage, spirv: bool) []const u8 {
        return switch (name) {
            inline else => |tag| switch (stage) {
                inline else => |part| {
                    const base = "../shaders/" ++ @tagName(tag) ++ "." ++ comptime stageFile(part);
                    return if (spirv) @embedFile(base ++ ".spv") else @embedFile(base ++ ".msl");
                },
            },
        };
    }

    fn stageFile(stage: Stage) []const u8 {
        return switch (stage) {
            .vertex => "vert",
            .fragment => "frag",
        };
    }
};

/// The file OpenReliant's shaders include, which a mod's shader may include too, and its source.
pub const colour_file = "colour.glsl";
pub const colour_source = @embedFile("../shaders/colour.glsl");

/// The line that includes `colour_file`.
const include_line = "#include \"" ++ colour_file ++ "\"";

/// A mod's replacement for one of OpenReliant's shaders: its two stages, compiled.
pub const Replacement = struct { vertex: Code, fragment: Code };

/// The mods' replacements, where they have any.
pub const Replacements = std.EnumArray(Name, ?Replacement);

/// What the GPU draws a shader's stages with: the code for its kind of device.
pub const Stages = struct {
    vertex: []const u8,
    fragment: []const u8,
};

/// The code the GPU draws each of OpenReliant's shaders with: a mod's replacement where there is
/// one, and OpenReliant's own otherwise. It holds `replaced`'s code, which must outlast it.
pub fn chosen(replaced: *const Replacements, spirv: bool) std.EnumArray(Name, Stages) {
    var stages: std.EnumArray(Name, Stages) = undefined;
    for (std.enums.values(Name)) |name| {
        stages.set(name, if (replaced.get(name)) |replacement| .{
            .vertex = codeFor(replacement.vertex, spirv),
            .fragment = codeFor(replacement.fragment, spirv),
        } else .{
            .vertex = name.builtin(.vertex, spirv),
            .fragment = name.builtin(.fragment, spirv),
        });
    }
    return stages;
}

fn codeFor(code: Code, spirv: bool) []const u8 {
    return if (spirv) std.mem.sliceAsBytes(code.spirv) else code.metal;
}

/// The most parts `parts` cuts a shader into.
pub const max_parts = 3;

/// What OpenReliant's shaders include.
pub const colour: Part = .{ .name = colour_file, .source = colour_source };

/// `file` as the parts it is compiled from, in `buffer`: the line that includes `colour_file`
/// gives way to `included`, as glslc's includer would put it. A file without the line is one part.
pub fn parts(file: Part, included: Part, buffer: *[max_parts]Part) []const Part {
    const at = lineAt(file.source, include_line) orelse {
        buffer[0] = file;
        return buffer[0..1];
    };
    buffer[0] = file.before(at);
    buffer[1] = included;
    buffer[2] = file.from(at + include_line.len);
    return buffer[0..3];
}

/// Where `line` starts in `source`, alone on its line, if it is there.
pub fn lineAt(source: []const u8, line: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, source, from, line)) |at| : (from = at + line.len) {
        const starts_line = at == 0 or source[at - 1] == '\n';
        const after = source[at + line.len ..];
        const ends_line = after.len == 0 or after[0] == '\n' or after[0] == '\r';
        if (starts_line and ends_line) return at;
    }
    return null;
}

test parts {
    var buffer: [max_parts]Part = undefined;
    const cut = parts(.{ .name = "device.glsl", .source = "#version 450\n#include \"colour.glsl\"\nvoid main() {}\n" }, .{ .name = colour_file, .source = "vec3 c;\n" }, &buffer);
    try std.testing.expectEqual(3, cut.len);
    try std.testing.expectEqualStrings("#version 450\n", cut[0].source);
    try std.testing.expectEqualStrings("vec3 c;\n", cut[1].source);
    try std.testing.expectEqualStrings("\nvoid main() {}\n", cut[2].source);
    // The rest starts on the line of the include, which its first line ends.
    try std.testing.expectEqual(2, cut[2].line);
    // A shader that doesn't include it, or names it within a line, is one part.
    try std.testing.expectEqual(1, parts(.{ .name = "a.glsl", .source = "// see #include \"colour.glsl\"\n" }, colour, &buffer).len);
}

test "OpenReliant's own shaders compile as they are, each stage" {
    const gpa = std.testing.allocator;
    var buffer: [max_parts]Part = undefined;
    for (std.enums.values(Name)) |name| for (std.enums.values(Stage)) |stage| {
        const result = try shader_compiler.compileParts(gpa, .openreliant, stage, parts(name.own(), colour, &buffer), stage.definition());
        defer result.deinit(gpa);
        if (result == .diagnostic) std.debug.print("{s}\n", .{result.diagnostic});
        try std.testing.expect(result == .compiled);
    };
}
