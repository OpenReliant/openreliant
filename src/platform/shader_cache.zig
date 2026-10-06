//! A cache of the shaders compiled as OpenReliant runs ([#628](https://github.com/OpenReliant/openreliant/issues/628)),
//! in the game folder's `cache/shaders`, so that a shader compiles again only when it changes: the
//! mods' shaders, and OpenReliant's own that their replacements are checked against.
//!
//! Each shader has one file (`cache_file.zig`), named after the shader's name, such as
//! `crt/crt.frag` for a post effect. Its payload is the SPIR-V's size in bytes, the SPIR-V, then
//! Metal's source. Its key is a hash of what was compiled (its kind, its stage, its definitions,
//! and each part's name and source) and of the compiler: the pinned versions of glslang and
//! SPIRV-Cross (`deps/shader-compiler/build.zig.zon`) and OpenReliant's wrapper
//! (`shader_compiler.cpp`). A changed shader or a new compiler doesn't match the key, so the
//! shader compiles again and its file is replaced. Shaders that don't compile aren't kept.
//!
//! **Improvement:** the original has no shaders from mods.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const cache_file = @import("cache_file.zig");
const shader_compiler = @import("shader_compiler.zig");
const Code = shader_compiler.Code;
const Part = shader_compiler.Part;

const log = std.log.scoped(.shaders);

/// Where the cache is, in the game folder.
pub const folder = "cache/shaders";

const Hash = [Sha256.digest_length]u8;

/// The cache's files. Change the version when the payload's layout changes.
const Files = cache_file.Files(.{ .folder = folder, .magic = "ORSH".*, .version = 3, .Key = Hash, .max_bytes = 16 * 1024 * 1024 });

comptime {
    // The header's size, which `docs/port/renderer.md` gives the offsets after.
    std.debug.assert(@sizeOf(Files.Header) == 56);
}

/// The compiler's files that the key covers, besides the shader.
const compiler_files = [_][]const u8{ @embedFile("shader-compiler.zon"), @embedFile("shader_compiler.cpp") };

pub const Cache = struct {
    io: Io,
    /// The game folder, or null to compile without the cache.
    root: ?Io.Dir,

    /// Compiles the post effect `source`, called `name` (`shader_compiler.compile`), or reads it
    /// from the cache if it was compiled already.
    pub fn compile(cache: Cache, gpa: Allocator, name: []const u8, source: []const u8) Allocator.Error!shader_compiler.Result {
        return cache.compileParts(gpa, name, .post_effect, .fragment, &.{.{ .name = name, .source = source }}, "");
    }

    /// Compiles the shader called `name` (`shader_compiler.compileParts`), or reads it from the
    /// cache if it was compiled already. A shader that compiles is kept in the cache, in place of
    /// what was kept under `name` before.
    pub fn compileParts(cache: Cache, gpa: Allocator, name: []const u8, kind: shader_compiler.Kind, stage: shader_compiler.Stage, parts: []const Part, preamble: []const u8) Allocator.Error!shader_compiler.Result {
        const key = keyOf(kind, stage, parts, preamble);
        if (try cache.load(gpa, name, key)) |code| return .{ .compiled = code };
        const result = try shader_compiler.compileParts(gpa, kind, stage, parts, preamble);
        switch (result) {
            .compiled => |code| cache.store(name, key, code) catch |err| {
                log.warn("can't keep the compiled shader {s} in {s}: {s}", .{ name, folder, @errorName(err) });
            },
            .diagnostic => {},
        }
        return result;
    }

    fn files(cache: Cache) Files {
        return .{ .io = cache.io, .root = cache.root };
    }

    /// The code kept for the shader `name` if its key is `key`, or null.
    fn load(cache: Cache, gpa: Allocator, name: []const u8, key: Hash) Allocator.Error!?Code {
        const read = try cache.files().read(gpa, name, key) orelse return null;
        defer read.deinit(gpa);
        return decode(gpa, read.payload);
    }

    /// Keeps `code` for the shader `name` with the key `key`, in place of what was kept.
    fn store(cache: Cache, name: []const u8, key: Hash, code: Code) !void {
        const spirv = std.mem.sliceAsBytes(code.spirv);
        const spirv_bytes: u32 = @intCast(spirv.len);
        try cache.files().write(name, key, &.{ std.mem.asBytes(&spirv_bytes), spirv, code.metal });
    }
};

/// The key of a shader of `kind` for `stage` made of `parts` after `preamble`, compiled by this
/// compiler. Each text goes in with its length, so that no two different shaders run together
/// alike.
fn keyOf(kind: shader_compiler.Kind, stage: shader_compiler.Stage, parts: []const Part, preamble: []const u8) Hash {
    var hash: Sha256 = .init(.{});
    for (compiler_files) |file| hash.update(file);
    hash.update(std.mem.asBytes(&@intFromEnum(kind)));
    hash.update(std.mem.asBytes(&@intFromEnum(stage)));
    update(&hash, preamble);
    for (parts) |part| {
        update(&hash, part.name);
        update(&hash, part.source);
    }
    return hash.finalResult();
}

fn update(hash: *Sha256, text: []const u8) void {
    hash.update(std.mem.asBytes(&@as(u64, text.len)));
    hash.update(text);
}

/// The key of the post effect `name` with the source `source`.
fn effectKey(name: []const u8, source: []const u8) Hash {
    return keyOf(.post_effect, .fragment, &.{.{ .name = name, .source = source }}, "");
}

/// The code in a cache file's payload, or null where its sizes don't fit.
fn decode(gpa: Allocator, payload: []const u8) Allocator.Error!?Code {
    if (payload.len < @sizeOf(u32)) return null;
    const spirv_bytes = std.mem.readInt(u32, payload[0..4], .little);
    const body = payload[@sizeOf(u32)..];
    if (spirv_bytes % @sizeOf(u32) != 0 or spirv_bytes > body.len) return null;
    const spirv = body[0..spirv_bytes];
    const metal = body[spirv_bytes..];
    const words = try gpa.alloc(u32, spirv.len / @sizeOf(u32));
    errdefer gpa.free(words);
    @memcpy(std.mem.sliceAsBytes(words), spirv);
    return .{ .spirv = words, .metal = try gpa.dupeZ(u8, metal) };
}

const fixture =
    \\#version 450
    \\layout(location=0) in vec2 uv;
    \\layout(location=0) out vec4 colour;
    \\layout(set=2, binding=0) uniform sampler2D source;
    \\void main() { colour = texture(source, uv); }
;

test Cache {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache: Cache = .{ .io = io, .root = tmp.dir };

    // The first compile keeps the shader, and the cache gives back the same code.
    const compiled = try cache.compile(gpa, "mod/a.frag", fixture);
    defer compiled.deinit(gpa);
    const kept = (try cache.load(gpa, "mod/a.frag", effectKey("mod/a.frag", fixture))).?;
    defer kept.deinit(gpa);
    try std.testing.expectEqualSlices(u32, compiled.compiled.spirv, kept.spirv);
    try std.testing.expectEqualStrings(compiled.compiled.metal, kept.metal);
    const again = try cache.compile(gpa, "mod/a.frag", fixture);
    defer again.deinit(gpa);
    try std.testing.expectEqualSlices(u32, compiled.compiled.spirv, again.compiled.spirv);

    // A changed source doesn't match the key, and replaces the file.
    const changed = fixture ++ "\n// changed\n";
    try std.testing.expectEqual(null, try cache.load(gpa, "mod/a.frag", effectKey("mod/a.frag", changed)));
    const recompiled = try cache.compile(gpa, "mod/a.frag", changed);
    defer recompiled.deinit(gpa);
    const replaced = (try cache.load(gpa, "mod/a.frag", effectKey("mod/a.frag", changed))).?;
    replaced.deinit(gpa);

    // A shader that doesn't compile isn't kept.
    const broken = try cache.compile(gpa, "mod/broken.frag", "#version 450\nvoid main() { broken; }\n");
    defer broken.deinit(gpa);
    try std.testing.expect(broken == .diagnostic);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, &Files.pathOf("mod/broken.frag"), .{}));

    // Without a game folder, shaders compile as they are.
    const uncached = try (Cache{ .io = io, .root = null }).compile(gpa, "mod/a.frag", fixture);
    defer uncached.deinit(gpa);
    try std.testing.expect(uncached == .compiled);
}

test decode {
    const gpa = std.testing.allocator;
    const spirv = [_]u32{ 0x07230203, 1, 2 };
    const metal = "fragment";
    var payload: [4 + spirv.len * 4 + metal.len]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], spirv.len * 4, .little);
    @memcpy(payload[4..][0 .. spirv.len * 4], std.mem.sliceAsBytes(&spirv));
    @memcpy(payload[4 + spirv.len * 4 ..], metal);

    const code = (try decode(gpa, &payload)).?;
    defer code.deinit(gpa);
    try std.testing.expectEqualSlices(u32, &spirv, code.spirv);
    try std.testing.expectEqualStrings(metal, code.metal);
    // A SPIR-V size past the payload, or not of whole words, is ignored.
    var long = payload;
    std.mem.writeInt(u32, long[0..4], 64, .little);
    try std.testing.expectEqual(null, try decode(gpa, &long));
    std.mem.writeInt(u32, long[0..4], 6, .little);
    try std.testing.expectEqual(null, try decode(gpa, &long));
    try std.testing.expectEqual(null, try decode(gpa, payload[0..2]));
    try std.testing.checkAllAllocationFailures(gpa, struct {
        fn run(allocator: Allocator, bytes: []const u8) !void {
            const decoded = (try decode(allocator, bytes)).?;
            decoded.deinit(allocator);
        }
    }.run, .{@as([]const u8, &payload)});
}
