//! `DREAMCACHEHW.DAT`, the Dreamcast version's texture cache: the PC's `tcachehw.dat` (`tcache.zig`)
//! made for the Dreamcast's PowerVR. It has the PC's header and room for 1000 entries, but its
//! entries are 92 bytes, and its textures are in the PowerVR's layouts (`pvr.zig`), each starting
//! on a 32-byte boundary.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const layout = @import("../layout.zig");
const tcache = @import("../tcache.zig");
const pvr = @import("pvr.zig");

pub const file_name = "DREAMCACHEHW.DAT";

/// The header: the PC's, version 102.
pub const Header = tcache.Header;

/// The entries the directory has room for.
pub const capacity = 1000;

/// The boundary each texture starts on.
pub const alignment = 32;

/// How a texture is stored. One of the last three bits gives the texels' format.
pub const Kind = packed struct(u16) {
    mipmaps: bool = false,
    /// Compressed with vector quantization (VQ).
    compressed: bool = false,
    _unknown_2: bool = false,
    rgb565: bool = false,
    argb4444: bool = false,
    argb1555: bool = false,
    _unknown_6: u10 = 0,

    pub fn layoutOf(kind: Kind) pvr.Layout {
        return .{ .compressed = kind.compressed, .mipmaps = kind.mipmaps };
    }

    /// Writes the kind as a listing shows it, such as `VQ, mipmaps, RGB 565`.
    pub fn format(kind: Kind, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(if (kind.compressed) "VQ" else "plain");
        if (kind.mipmaps) try writer.writeAll(", mipmaps");
        if (kind.rgb565) try writer.writeAll(", RGB 565");
        if (kind.argb4444) try writer.writeAll(", ARGB 4444");
        if (kind.argb1555) try writer.writeAll(", ARGB 1555");
    }
};

/// A component of a texel: the PC's `tcache.Channel` in 8 bytes.
pub const Channel = extern struct {
    mask: u32,
    shift: u16,
    /// Bits of 8 the component lacks.
    loss: u16,

    pub fn value(channel: Channel, texel: u16) ?u8 {
        const pc: tcache.Channel = .{ .mask = channel.mask, .shift = channel.shift, .loss = channel.loss };
        return pc.value(texel);
    }
};

pub const Entry = extern struct {
    name_bytes: [32]u8,
    /// The entry's own index.
    index: u32,
    kind: Kind,
    /// **Unknown:** with mipmaps, the levels of the full chain or one fewer; 1 without.
    levels: u16,
    width: u16,
    height: u16,
    red: Channel,
    green: Channel,
    blue: Channel,
    alpha: Channel,
    /// **Unknown:** zero in every entry but the last.
    _unknown_4c: u32,
    /// Where the texture is in the file.
    offset: u32,
    _unused_54: [8]u8,

    pub fn name(entry: *align(1) const Entry) []const u8 {
        return std.mem.sliceTo(&entry.name_bytes, 0);
    }

    comptime {
        assert(@offsetOf(Entry, "kind") == 0x24);
        assert(@offsetOf(Entry, "red") == 0x2C);
        assert(@offsetOf(Entry, "offset") == 0x50);
        assert(@sizeOf(Entry) == 92);
    }
};

pub const Error = error{ NotACache, Truncated } || pvr.Error;

pub const Cache = struct {
    bytes: []const u8,
    entries: []align(1) const Entry,

    pub fn parse(bytes: []const u8) Error!Cache {
        const header = layout.view(Header, bytes) catch return error.NotACache;
        if (header.version != tcache.version or header.count > capacity) return error.NotACache;
        const entries = layout.array(Entry, bytes[@sizeOf(Header)..], header.count) catch return error.Truncated;
        return .{ .bytes = bytes, .entries = entries };
    }

    /// The texture of `entry`, an entry of this cache.
    pub fn texture(cache: Cache, entry: *align(1) const Entry) Error!Texture {
        const size = entry.kind.layoutOf().size(entry.width);
        if (entry.width != entry.height) return error.BadSize;
        if (entry.offset > cache.bytes.len or cache.bytes.len - entry.offset < size) return error.Truncated;
        return .{ .entry = entry, .data = cache.bytes[entry.offset..][0..size] };
    }
};

pub const Texture = struct {
    entry: *align(1) const Entry,
    data: []const u8,

    /// Its largest level as 8-bit RGBA, row by row from the top. A texture without alpha is
    /// opaque.
    pub fn rgba(texture: Texture, gpa: Allocator) (Allocator.Error || pvr.Error)![]u8 {
        const entry = texture.entry;
        const texels = try gpa.alloc(u16, @as(usize, entry.width) * entry.width);
        defer gpa.free(texels);
        try pvr.decode(entry.kind.layoutOf(), entry.width, texture.data, texels);
        const out = try gpa.alloc(u8, texels.len * 4);
        for (texels, 0..) |texel, at| out[at * 4 ..][0..4].* = .{
            entry.red.value(texel) orelse 0,
            entry.green.value(texel) orelse 0,
            entry.blue.value(texel) orelse 0,
            entry.alpha.value(texel) orelse 0xFF,
        };
        return out;
    }
};

test Cache {
    const gpa = std.testing.allocator;
    // A cache of one plain 2 by 2 texture in ARGB 1555, after the directory.
    const offset = std.mem.alignForward(usize, @sizeOf(Header) + capacity * @sizeOf(Entry), alignment);
    const bytes = try gpa.alloc(u8, offset + 8);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    const header: *align(1) Header = @ptrCast(bytes[0..@sizeOf(Header)]);
    header.* = .{ .version = tcache.version, .count = 1, .end = @intCast(bytes.len) };
    const entry: *align(1) Entry = @ptrCast(bytes[@sizeOf(Header)..][0..@sizeOf(Entry)]);
    @memcpy(entry.name_bytes[0..4], "test");
    entry.kind = .{ .argb1555 = true };
    entry.width = 2;
    entry.height = 2;
    entry.red = .{ .mask = 0x7C00, .shift = 10, .loss = 3 };
    entry.green = .{ .mask = 0x03E0, .shift = 5, .loss = 3 };
    entry.blue = .{ .mask = 0x001F, .shift = 0, .loss = 3 };
    entry.alpha = .{ .mask = 0x8000, .shift = 15, .loss = 7 };
    entry.offset = @intCast(offset);
    // Row by row: opaque red and clear black, then opaque blue and opaque green.
    @memcpy(bytes[offset..], std.mem.sliceAsBytes(&[_]u16{ 0xFC00, 0x0000, 0x801F, 0x83E0 }));

    const cache: Cache = try .parse(bytes);
    try std.testing.expectEqualStrings("test", cache.entries[0].name());
    const pixels = try (try cache.texture(&cache.entries[0])).rgba(gpa);
    defer gpa.free(pixels);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 255, 255, 0, 255, 0, 255 }, pixels);
    try std.testing.expectError(error.NotACache, Cache.parse(bytes[0..4]));
}
