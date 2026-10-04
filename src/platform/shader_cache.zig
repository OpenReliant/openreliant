//! A cache of the shaders compiled as OpenReliant runs ([#628](https://github.com/OpenReliant/openreliant/issues/628)),
//! in the game folder's `cache/shaders`, so that a shader compiles again only when it changes: the
//! mods' shaders, and OpenReliant's own that their replacements are checked against.
//!
//! Each shader has one file, named by a hash of the shader's name, such as `crt/crt.frag` for a
//! post effect. The file holds a `Header`, then the SPIR-V, then Metal's source. The header's key
//! is a hash of what was compiled (its kind, its stage, its definitions, and each part's name and
//! source) and of the compiler: the pinned versions of glslang and SPIRV-Cross
//! (`deps/shader-compiler/build.zig.zon`) and OpenReliant's wrapper (`shader_compiler.cpp`). A
//! changed shader or a new compiler doesn't match the key, so the shader compiles again and its
//! file is replaced. A file that is damaged or can't be read is ignored, and one that can't be
//! written is logged. Shaders that don't compile aren't kept. The folder can be deleted at any
//! time.
//!
//! **Improvement:** the original has no shaders from mods.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const shader_compiler = @import("shader_compiler.zig");
const Code = shader_compiler.Code;
const Part = shader_compiler.Part;

const log = std.log.scoped(.shaders);

/// Where the cache is, in the game folder.
pub const folder = "cache/shaders";

/// A cache file's extension.
const extension = ".bin";

/// What a cache file starts with.
const magic = "ORSH".*;

/// The version of the cache files' layout. Change it when `Header` or what follows it changes.
const format_version: u32 = 2;

/// The largest cache file read.
const max_file_bytes = 16 * 1024 * 1024;

const Hash = [Sha256.digest_length]u8;

/// The start of a cache file.
const Header = extern struct {
    magic: [4]u8 = magic,
    version: u32 = format_version,
    /// The hash of what was compiled (`keyOf`).
    key: Hash,
    /// The hash of the SPIR-V and Metal's source that follow.
    check: Hash,
    spirv_bytes: u32,
    metal_bytes: u32,

    comptime {
        std.debug.assert(@offsetOf(Header, "key") == 8);
        std.debug.assert(@sizeOf(Header) == 80);
    }
};

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
        const path = pathOf(name);
        if (try cache.load(gpa, &path, key)) |code| return .{ .compiled = code };
        const result = try shader_compiler.compileParts(gpa, kind, stage, parts, preamble);
        switch (result) {
            .compiled => |code| cache.store(&path, key, code) catch |err| {
                log.warn("can't keep the compiled shader {s} in {s}: {s}", .{ name, folder, @errorName(err) });
            },
            .diagnostic => {},
        }
        return result;
    }

    /// The code kept in the file `path` if its key is `key`, or null.
    fn load(cache: Cache, gpa: Allocator, path: []const u8, key: Hash) Allocator.Error!?Code {
        const root = cache.root orelse return null;
        const bytes = root.readFileAlloc(cache.io, path, gpa, .limited(max_file_bytes)) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return null,
        };
        defer gpa.free(bytes);
        return decode(gpa, bytes, key);
    }

    /// Writes `code` to the file `path` with the key `key`, replacing what was there.
    fn store(cache: Cache, path: []const u8, key: Hash, code: Code) !void {
        const root = cache.root orelse return;
        const spirv = std.mem.sliceAsBytes(code.spirv);
        const header: Header = .{
            .key = key,
            .check = checkOf(spirv, code.metal),
            .spirv_bytes = @intCast(spirv.len),
            .metal_bytes = @intCast(code.metal.len),
        };
        var file = try root.createFileAtomic(cache.io, path, .{ .make_path = true, .replace = true });
        defer file.deinit(cache.io);
        for ([_][]const u8{ std.mem.asBytes(&header), spirv, code.metal }) |part| try file.file.writeStreamingAll(cache.io, part);
        try file.replace(cache.io);
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

/// The hash of a cache file's code.
fn checkOf(spirv: []const u8, metal: []const u8) Hash {
    var hash: Sha256 = .init(.{});
    hash.update(spirv);
    hash.update(metal);
    return hash.finalResult();
}

/// The path of the shader `name`'s cache file in the game folder.
fn pathOf(name: []const u8) [folder.len + 1 + Sha256.digest_length * 2 + extension.len]u8 {
    var digest: Hash = undefined;
    Sha256.hash(name, &digest, .{});
    return (folder ++ "/").* ++ std.fmt.bytesToHex(digest, .lower) ++ extension.*;
}

/// The code in the cache file `bytes` if its key is `key` and it is whole, or null.
fn decode(gpa: Allocator, bytes: []const u8, key: Hash) Allocator.Error!?Code {
    if (bytes.len < @sizeOf(Header)) return null;
    const header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
    if (!std.mem.eql(u8, &header.magic, &magic) or header.version != format_version) return null;
    if (!std.mem.eql(u8, &header.key, &key)) return null;
    const body = bytes[@sizeOf(Header)..];
    if (header.spirv_bytes % @sizeOf(u32) != 0 or @as(u64, header.spirv_bytes) + header.metal_bytes != body.len) return null;
    const spirv = body[0..header.spirv_bytes];
    const metal = body[header.spirv_bytes..];
    if (!std.mem.eql(u8, &checkOf(spirv, metal), &header.check)) return null;
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
    const path = pathOf("mod/a.frag");

    // The first compile keeps the shader, and the cache gives back the same code.
    const compiled = try cache.compile(gpa, "mod/a.frag", fixture);
    defer compiled.deinit(gpa);
    const kept = (try cache.load(gpa, &path, effectKey("mod/a.frag", fixture))).?;
    defer kept.deinit(gpa);
    try std.testing.expectEqualSlices(u32, compiled.compiled.spirv, kept.spirv);
    try std.testing.expectEqualStrings(compiled.compiled.metal, kept.metal);
    const again = try cache.compile(gpa, "mod/a.frag", fixture);
    defer again.deinit(gpa);
    try std.testing.expectEqualSlices(u32, compiled.compiled.spirv, again.compiled.spirv);

    // A changed source doesn't match the key, and replaces the file.
    const changed = fixture ++ "\n// changed\n";
    try std.testing.expectEqual(null, try cache.load(gpa, &path, effectKey("mod/a.frag", changed)));
    const recompiled = try cache.compile(gpa, "mod/a.frag", changed);
    defer recompiled.deinit(gpa);
    const replaced = (try cache.load(gpa, &path, effectKey("mod/a.frag", changed))).?;
    replaced.deinit(gpa);

    // A shader that doesn't compile isn't kept.
    const broken = try cache.compile(gpa, "mod/broken.frag", "#version 450\nvoid main() { broken; }\n");
    defer broken.deinit(gpa);
    try std.testing.expect(broken == .diagnostic);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, &pathOf("mod/broken.frag"), .{}));

    // Without a game folder, shaders compile as they are.
    const uncached = try (Cache{ .io = io, .root = null }).compile(gpa, "mod/a.frag", fixture);
    defer uncached.deinit(gpa);
    try std.testing.expect(uncached == .compiled);
}

test decode {
    const gpa = std.testing.allocator;
    const key = effectKey("a.frag", "source");
    const spirv = [_]u32{ 0x07230203, 1, 2 };
    const metal = "fragment";
    const header: Header = .{ .key = key, .check = checkOf(std.mem.sliceAsBytes(&spirv), metal), .spirv_bytes = spirv.len * 4, .metal_bytes = metal.len };
    var file: [@sizeOf(Header) + spirv.len * 4 + metal.len]u8 = undefined;
    @memcpy(file[0..@sizeOf(Header)], std.mem.asBytes(&header));
    @memcpy(file[@sizeOf(Header)..][0 .. spirv.len * 4], std.mem.sliceAsBytes(&spirv));
    @memcpy(file[@sizeOf(Header) + spirv.len * 4 ..], metal);

    const code = (try decode(gpa, &file, key)).?;
    defer code.deinit(gpa);
    try std.testing.expectEqualSlices(u32, &spirv, code.spirv);
    try std.testing.expectEqualStrings(metal, code.metal);
    // Another key, a cut file and a changed byte are each ignored.
    try std.testing.expectEqual(null, try decode(gpa, &file, effectKey("a.frag", "other")));
    try std.testing.expectEqual(null, try decode(gpa, file[0 .. file.len - 1], key));
    try std.testing.expectEqual(null, try decode(gpa, file[0..10], key));
    var damaged = file;
    damaged[damaged.len - 1] ^= 1;
    try std.testing.expectEqual(null, try decode(gpa, &damaged, key));
    try std.testing.checkAllAllocationFailures(gpa, struct {
        fn run(allocator: Allocator, bytes: []const u8, wanted: Hash) !void {
            const decoded = (try decode(allocator, bytes, wanted)).?;
            decoded.deinit(allocator);
        }
    }.run, .{ @as([]const u8, &file), key });
}
