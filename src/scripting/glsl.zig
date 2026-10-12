//! A mod's shader as the driver compiles it: the GLSL file that a surface function, a lighting
//! function or a post effect is registered with, and the files of the mod it includes, as parts in
//! order ([#1115](https://github.com/OpenReliant/openreliant/issues/1115)). A line that holds only
//! `#include "name"` takes in the mod's file `name` in its place. An included file can include
//! others, and each file is taken in once, so that two files can include the same helpers. Each
//! part is named after its file, as `<mod>/<file>`, and starts at the line of the file it comes
//! from, so that the compiler's messages give the file and the line of a mistake.
//!
//! **Improvement:** the original has no shaders from mods.

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const Mod = openreliant.engine.game.bigfile.mods.Mod;

/// A piece of a shader: the file it comes from, its text, and the line of the file it starts on.
pub const Part = struct {
    name: []const u8,
    source: []const u8,
    line: u32 = 1,
};

/// The most `#include` lines a shader and the files it includes hold.
pub const max_includes = 7;

/// The most parts a shader is cut into: each file taken in is a part more, and each `#include` ends
/// a part of the file it is in.
pub const max_parts = 2 * max_includes + 1;

/// The directive that takes in another file.
const directive = "#include";

/// A shader read: its parts, which point into its arena.
pub const Shader = struct {
    arena: std.heap.ArenaAllocator,
    parts: []const Part,

    pub fn deinit(shader: *Shader) void {
        shader.arena.deinit();
        shader.* = undefined;
    }
};

/// Why a shader can't be read, as the script is told.
pub const Why = struct {
    buffer: [512]u8 = undefined,
    len: usize = 0,

    pub fn text(why: *const Why) []const u8 {
        return why.buffer[0..why.len];
    }
};

/// `error.Failed` leaves what is wrong in a `Why`.
pub const Error = error{ OutOfMemory, Failed };

/// Reads the mod's shader `name` with the files it includes. Fails with `error.Failed`, and what is
/// wrong in `why`, when a file can't be read or isn't in the mod, when an `#include` doesn't name a
/// file in quotes, or past `max_includes`.
pub fn read(gpa: Allocator, mod: *const Mod, name: []const u8, why: *Why) Error!Shader {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var reader: Reader = .{ .arena = arena.allocator(), .mod = mod, .why = why };
    try reader.take(name, null);
    return .{ .arena = arena, .parts = reader.parts.items };
}

/// Where an `#include` stands: the including file's part name, and its line.
const Place = struct { file: []const u8, line: u32 };

const Reader = struct {
    arena: Allocator,
    mod: *const Mod,
    why: *Why,
    parts: std.ArrayList(Part) = .empty,
    /// The files taken in so far, which a later `#include` of the same file leaves out.
    taken: std.ArrayList([]const u8) = .empty,
    /// The `#include` lines met so far.
    includes: usize = 0,

    /// Takes in the file `name`, which the `#include` at `from` names, or the shader's own file.
    fn take(reader: *Reader, name: []const u8, from: ?Place) Error!void {
        const mod = reader.mod;
        const text = mod.readFile(reader.arena, name) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return reader.fail(from, "{s} can't be read: {s}", .{ name, @errorName(err) }),
        } orelse return reader.fail(from, "the mod {s} has no file {s}", .{ mod.name, name });
        try reader.taken.append(reader.arena, name);
        const file = try reader.arena.print("{s}/{s}", .{ mod.name, name });
        // The text since the last `#include`, from its first line.
        var start: usize = 0;
        var start_line: u32 = 1;
        var at: usize = 0;
        var line: u32 = 1;
        while (at <= text.len) : (line += 1) {
            const end = std.mem.findScalarPos(u8, text, at, '\n') orelse text.len;
            if (Include.of(text[at..end])) |include| {
                const place: Place = .{ .file = file, .line = line };
                if (reader.includes == max_includes) return reader.fail(place, "a shader and the files it includes hold at most {d} #include lines", .{max_includes});
                reader.includes += 1;
                try reader.add(file, text[start..at], start_line);
                const target = switch (include) {
                    .file => |target| target,
                    .malformed => return reader.fail(place, "#include takes the name of one of the mod's files in quotes", .{}),
                };
                if (!reader.isTaken(target)) try reader.take(target, place);
                start = @min(end + 1, text.len);
                start_line = line + 1;
            }
            at = end + 1;
        }
        try reader.add(file, text[start..], start_line);
    }

    /// Adds the part `source` of `file`, from its line `line`, unless it is empty.
    fn add(reader: *Reader, file: []const u8, source: []const u8, line: u32) Error!void {
        if (source.len == 0) return;
        std.debug.assert(reader.parts.items.len < max_parts);
        try reader.parts.append(reader.arena, .{ .name = file, .source = source, .line = line });
    }

    /// Whether the file `name` was taken in already, ignoring case, as the mod's files are found.
    fn isTaken(reader: *const Reader, name: []const u8) bool {
        for (reader.taken.items) |taken| if (std.ascii.eqlIgnoreCase(taken, name)) return true;
        return false;
    }

    /// Fails with `what`, after the place of the `#include` where there is one.
    fn fail(reader: *Reader, from: ?Place, comptime what: []const u8, args: anytype) error{Failed} {
        var writer: std.Io.Writer = .fixed(&reader.why.buffer);
        if (from) |place| writer.print("{s}:{d}: ", .{ place.file, place.line }) catch {};
        writer.print(what, args) catch {};
        reader.why.len = writer.buffered().len;
        return error.Failed;
    }
};

/// What a line that starts with `#include` asks for: the file it names, in the form
/// `#include "name"` with nothing but spaces around it, or nothing it can take, in another form.
const Include = union(enum) {
    file: []const u8,
    malformed,

    /// What the line `line` includes; null if it isn't an `#include`.
    fn of(line: []const u8) ?Include {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const rest = std.mem.cutPrefix(u8, trimmed, directive) orelse return null;
        // `#includes` and the like are other words.
        if (rest.len > 0 and rest[0] != ' ' and rest[0] != '\t' and rest[0] != '"') return null;
        const quoted = std.mem.trimStart(u8, rest, " \t");
        if (quoted.len < 3 or quoted[0] != '"' or quoted[quoted.len - 1] != '"') return .malformed;
        const name = quoted[1 .. quoted.len - 1];
        if (std.mem.findScalar(u8, name, '"') != null) return .malformed;
        return .{ .file = name };
    }
};

test "Include.of" {
    try std.testing.expectEqualStrings("haze.glsl", Include.of("#include \"haze.glsl\"").?.file);
    try std.testing.expectEqualStrings("haze.glsl", Include.of("  #include  \"haze.glsl\"  \r").?.file);
    try std.testing.expectEqualStrings("haze.glsl", Include.of("#include\"haze.glsl\"").?.file);
    try std.testing.expectEqual(null, Include.of("vec3 haze = vec3(0.0);"));
    try std.testing.expectEqual(null, Include.of("#includes"));
    try std.testing.expectEqual(null, Include.of("// #include \"haze.glsl\""));
    for ([_][]const u8{ "#include <haze.glsl>", "#include haze.glsl", "#include \"\"", "#include \"a\" \"b\"", "#include" }) |line| {
        try std.testing.expectEqual(Include.malformed, Include.of(line).?);
    }
}

/// A mod in a folder of a temporary game folder, with `files`, for the tests.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    mods: openreliant.engine.game.bigfile.Mods,

    /// A file of the mod: its name and its text.
    const File = struct { []const u8, []const u8 };

    fn init(fixture: *Fixture, files: []const File) !void {
        const io = std.testing.io;
        fixture.tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer fixture.tmp.cleanup();
        try fixture.tmp.dir.createDirPath(io, "mods/haze");
        var path: [64]u8 = undefined;
        for (files) |file| try fixture.tmp.dir.writeFile(io, .{ .sub_path = try std.mem.print(&path, "mods/haze/{s}", .{file[0]}), .data = file[1] });
        fixture.mods = try .open(std.testing.allocator, io, fixture.tmp.dir, null);
    }

    fn deinit(fixture: *Fixture) void {
        fixture.mods.close(std.testing.allocator);
        fixture.tmp.cleanup();
    }

    fn mod(fixture: *const Fixture) *const Mod {
        return &fixture.mods.list[0];
    }
};

test "a shader takes in the files it includes, each once, as parts named after their files" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{ "titan.glsl", "// Titan.\n#include \"haze.glsl\"\n#include \"Haze.GLSL\"\nvoid surface() {}\n" },
        .{ "haze.glsl", "#include \"common.glsl\"\nfloat haze() { return 1.0; }\n" },
        .{ "common.glsl", "const float unit = 1.0;\n#include \"titan.glsl\"\n" },
    });
    defer fixture.deinit();
    var why: Why = .{};
    var shader = try read(std.testing.allocator, fixture.mod(), "titan.glsl", &why);
    defer shader.deinit();
    // titan.glsl's first line, then haze.glsl, which first takes in common.glsl; the second
    // include of haze.glsl, and common.glsl's include of titan.glsl, are left out; then the rest
    // of titan.glsl, from its fourth line.
    const Expected = struct { []const u8, []const u8, u32 };
    const expected = [_]Expected{
        .{ "haze/titan.glsl", "// Titan.\n", 1 },
        .{ "haze/common.glsl", "const float unit = 1.0;\n", 1 },
        .{ "haze/haze.glsl", "float haze() { return 1.0; }\n", 2 },
        .{ "haze/titan.glsl", "void surface() {}\n", 4 },
    };
    try std.testing.expectEqual(expected.len, shader.parts.len);
    for (expected, shader.parts) |want, part| {
        try std.testing.expectEqualStrings(want[0], part.name);
        try std.testing.expectEqualStrings(want[1], part.source);
        try std.testing.expectEqual(want[2], part.line);
    }
}

test "a shader without includes is one part, and a missing or malformed include fails at its line" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{ "plain.glsl", "void surface() {}" },
        .{ "missing.glsl", "void a() {}\n#include \"nowhere.glsl\"\n" },
        .{ "malformed.glsl", "\n\n#include <haze.glsl>\n" },
        .{ "self.glsl", "#include \"self.glsl\"\n" },
    });
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    var why: Why = .{};
    var plain = try read(gpa, fixture.mod(), "plain.glsl", &why);
    defer plain.deinit();
    try std.testing.expectEqual(1, plain.parts.len);
    try std.testing.expectEqualStrings("void surface() {}", plain.parts[0].source);
    try std.testing.expectError(error.Failed, read(gpa, fixture.mod(), "missing.glsl", &why));
    try std.testing.expectEqualStrings("haze/missing.glsl:2: the mod haze has no file nowhere.glsl", why.text());
    try std.testing.expectError(error.Failed, read(gpa, fixture.mod(), "malformed.glsl", &why));
    try std.testing.expectEqualStrings("haze/malformed.glsl:3: #include takes the name of one of the mod's files in quotes", why.text());
    try std.testing.expectError(error.Failed, read(gpa, fixture.mod(), "absent.glsl", &why));
    try std.testing.expectEqualStrings("the mod haze has no file absent.glsl", why.text());
    // A file that includes itself is taken in once: it is all includes, so it has no parts.
    var own = try read(gpa, fixture.mod(), "self.glsl", &why);
    defer own.deinit();
    try std.testing.expectEqual(0, own.parts.len);
}

test "a shader and the files it includes hold at most max_includes #include lines" {
    var fixture: Fixture = undefined;
    // `many.glsl` includes x0.glsl to x6.glsl, the most a shader can; x6.glsl includes x7.glsl,
    // one too many.
    var text: [max_includes * 32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text);
    for (0..max_includes) |n| try writer.print("int a{d};\n#include \"x{d}.glsl\"\n", .{ n, n });
    try writer.writeAll("int z;\n");
    var names: [max_includes + 1][16]u8 = undefined;
    var files: [max_includes + 2]Fixture.File = undefined;
    files[0] = .{ "many.glsl", writer.buffered() };
    for (0..max_includes + 1, &names) |n, *name| files[n + 1] = .{ try std.mem.print(name, "x{d}.glsl", .{n}), "int b;\n" };
    files[max_includes] = .{ files[max_includes][0], "#include \"x7.glsl\"\n" };
    var why: Why = .{};
    try fixture.init(&files);
    defer fixture.deinit();
    try std.testing.expectError(error.Failed, read(std.testing.allocator, fixture.mod(), "many.glsl", &why));
    try std.testing.expectEqualStrings("haze/x6.glsl:1: a shader and the files it includes hold at most 7 #include lines", why.text());
    // Without x6.glsl's include, the parts are within the limit: the main file's eight pieces and
    // the seven files.
    files[max_includes] = .{ files[max_includes][0], "int b;\n" };
    var again: Fixture = undefined;
    try again.init(&files);
    defer again.deinit();
    var shader = try read(std.testing.allocator, again.mod(), "many.glsl", &why);
    defer shader.deinit();
    try std.testing.expectEqual(2 * max_includes + 1, shader.parts.len);
}
