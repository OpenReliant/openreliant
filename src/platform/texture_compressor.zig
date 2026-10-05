//! Compresses mods' pictures for the GPU ([#503](https://github.com/OpenReliant/openreliant/issues/503)),
//! with bc7enc and rgbcx (`texture_compressor.cpp`, `deps/texture-compressor`): colours and
//! material maps in BC7, normal maps in BC5. A 16-bit normal map goes to BC5 from its 16-bit
//! samples instead (`texels.bc5`). A level's rows of blocks are shared out between threads
//! (`srtexture.shareRows`), as a large picture has a million blocks.
//!
//! **Improvement:** the original's textures are small, and kept as they are.

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const srtexture = openreliant.engine.surrender.surrenderlib.srtexture;
const Level = srtexture.Level;
const bc5 = openreliant.texels.bc5;

extern fn openreliant_texture_compressor_init() void;
extern fn openreliant_compress_rows(rgba: [*]const u8, width: u32, height: u32, first: u32, count: u32, kind: c_int, out: [*]u8) void;

const Kind = srtexture.Compressor.Kind;

/// The number `texture_compressor.cpp` knows `kind` by.
fn native(kind: Kind) c_int {
    return switch (kind) {
        .colour => 0,
        .data => 1,
        .normals => 2,
    };
}

/// The least rows of blocks worth a thread of their own: fewer would cost more to start than they
/// save.
const least_rows = 16;

/// How far the encoders are from ready.
const Readiness = enum(u8) { not_ready, making_ready, ready };
var readiness: std.atomic.Value(Readiness) = .init(.not_ready);

/// Makes the encoders ready, the first time; a thread that comes while another makes them ready
/// waits for it.
fn prepare() void {
    if (readiness.load(.acquire) == .ready) return;
    if (readiness.cmpxchgStrong(.not_ready, .making_ready, .acquire, .acquire) == null) {
        openreliant_texture_compressor_init();
        readiness.store(.ready, .release);
        return;
    }
    while (readiness.load(.acquire) != .ready) std.atomic.spinLoopHint();
}

/// `level`, 8-bit RGBA, or a normal map in 16-bit RGBA, compressed as `kind`, its texels allocated
/// in `gpa`.
pub fn compress(gpa: Allocator, level: Level, kind: Kind) Allocator.Error!Level {
    std.debug.assert(level.format == .rgba8 or (level.format == .rgba16 and kind == .normals));
    prepare();
    const format = kind.format();
    const out = try gpa.alloc(u8, format.size(level.width, level.height));
    const compressing: Compressing = .{ .level = level, .kind = kind, .out = out };
    srtexture.shareRows(Level.blocks(level.height), least_rows, compressing, Compressing.rows);
    return .{ .width = level.width, .height = level.height, .format = format, .texels = out };
}

/// A level being compressed, whose rows of blocks each thread compresses some of.
const Compressing = struct {
    level: Level,
    kind: Kind,
    out: []u8,

    fn rows(compressing: Compressing, first: usize, count: usize) void {
        const level = compressing.level;
        if (level.format == .rgba16) return bc5.encodeRows(level.texels, level.width, level.height, @intCast(first), @intCast(count), compressing.out);
        openreliant_compress_rows(level.texels.ptr, level.width, level.height, @intCast(first), @intCast(count), native(compressing.kind), compressing.out.ptr);
    }
};

test compress {
    const gpa = std.testing.allocator;
    // A 6 by 5 level, which takes 2 by 2 blocks, its rows shared out.
    var rgba: [6 * 5 * 4]u8 = undefined;
    for (0..6 * 5) |at| rgba[at * 4 ..][0..4].* = .{ @intCast(at * 8), 128, 255 - @as(u8, @intCast(at * 8)), 255 };
    const level: Level = .{ .width = 6, .height = 5, .texels = &rgba };
    for (std.enums.values(Kind)) |kind| {
        const made = try compress(gpa, level, kind);
        defer gpa.free(made.texels);
        try std.testing.expectEqual(kind.format(), made.format);
        try std.testing.expectEqual(2 * 2 * 16, made.texels.len);
        try std.testing.expectEqual(6, made.width);
    }
    // A 16-bit normal map, of the same size, to BC5.
    var rgba16: [6 * 5 * 4 * 2]u8 = @splat(0x80);
    const wide: Level = .{ .width = 6, .height = 5, .format = .rgba16, .texels = &rgba16 };
    const normals = try compress(gpa, wide, .normals);
    defer gpa.free(normals.texels);
    try std.testing.expectEqual(Level.Format.bc5, normals.format);
    try std.testing.expectEqual(2 * 2 * 16, normals.texels.len);
}
