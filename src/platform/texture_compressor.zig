//! Compresses mods' pictures for the GPU ([#503](https://github.com/OpenReliant/openreliant/issues/503)),
//! with bc7enc and rgbcx (`texture_compressor.cpp`, `deps/texture-compressor`): colours and
//! material maps in BC7, normal maps in BC5. A 16-bit normal map goes to BC5 from its 16-bit
//! samples instead (`texels.bc5`). A level's rows of blocks are shared out between threads, as a
//! large picture has a million blocks.
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

/// The most threads a level is shared out between.
const max_threads = 16;

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
    const rows: u32 = @intCast(Level.blocks(level.height));
    const wanted: u32 = @intCast(@min(std.Thread.getCpuCount() catch 1, max_threads, rows));
    const share = (rows + wanted - 1) / wanted;
    var threads: [max_threads]?std.Thread = @splat(null);
    var first: u32 = 0;
    for (&threads) |*thread| {
        if (first >= rows) break;
        const count = @min(share, rows - first);
        // A thread that can't start leaves its rows to this one.
        thread.* = std.Thread.spawn(.{}, compressRows, .{ level, first, count, kind, out }) catch blk: {
            compressRows(level, first, count, kind, out);
            break :blk null;
        };
        first += count;
    }
    for (threads) |thread| if (thread) |started| started.join();
    return .{ .width = level.width, .height = level.height, .format = format, .texels = out };
}

fn compressRows(level: Level, first: u32, count: u32, kind: Kind, out: []u8) void {
    if (level.format == .rgba16) return bc5.encodeRows(level.texels, level.width, level.height, first, count, out);
    openreliant_compress_rows(level.texels.ptr, level.width, level.height, first, count, native(kind), out.ptr);
}

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
