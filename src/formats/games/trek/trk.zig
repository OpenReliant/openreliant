//! Star Trek: Invasion's `.TRK` models: a header, then chunks, each a four-letter id, a length and
//! that many bytes, as in RIFF. The last chunk is `FINI`, and the archive pads the file after it.
//!
//! | Offset | Size | Field |
//! |---|---|---|
//! | 0 | 4 | `TREK` |
//! | 4 | 4 | The length of the file up to the end of `FINI` |
//! | 8 | 4 | The model's number, different in each model; absent in `WARP.TRK` |
//!
//! The chunks seen are `MODL`, the meshes, `ENGI`, `LODC`, `COLL`, `TEXS` and `TIMS`, a texture
//! as a TIM picture (`playstation.tim`), one for each texture. **Unknown:** the layout of every chunk but
//! `TIMS`. **Unverified:** how the game tells a model without a number; this reader takes four
//! capital letters after the length for the first chunk's id.

const std = @import("std");
const assert = std.debug.assert;

const layout = @import("../../layout.zig");
const riff = @import("../../riff.zig");

pub const Header = extern struct {
    magic: [4]u8,
    /// The length of the file up to the end of the last chunk.
    length: u32,

    pub const trek = "TREK";

    comptime {
        assert(@sizeOf(Header) == 8);
    }
};

/// The id of the chunk that ends the model.
pub const end_id = "FINI";
/// The id of a texture's chunk.
pub const texture_id = "TIMS";

pub const Error = error{ NotAModel, Truncated };

pub const Model = struct {
    header: *align(1) const Header,
    /// The model's number, if it has one.
    number: ?u32,
    /// The chunks, up to the end of `FINI`.
    body: []const u8,

    pub fn parse(bytes: []const u8) Error!Model {
        const header = layout.view(Header, bytes) catch return error.NotAModel;
        if (!std.mem.eql(u8, &header.magic, Header.trek)) return error.NotAModel;
        if (header.length < @sizeOf(Header) or header.length > bytes.len) return error.Truncated;
        const rest = bytes[@sizeOf(Header)..header.length];
        const number = layout.view(u32, rest) catch return error.Truncated;
        if (isId(std.mem.asBytes(number))) return .{ .header = header, .number = null, .body = rest };
        return .{ .header = header, .number = number.*, .body = rest[@sizeOf(u32)..] };
    }

    /// The model's chunks in turn. Every chunk's length is a multiple of four, so RIFF's padding
    /// never applies.
    pub fn chunks(model: Model) riff.Chunks {
        return .{ .rest = model.body };
    }

    /// Where `chunk`, one of the model's chunks, starts in the file.
    pub fn offsetOf(model: Model, chunk: riff.Chunk) usize {
        return @intFromPtr(chunk.body.ptr) - @intFromPtr(model.header) - @sizeOf(riff.ChunkHeader);
    }
};

/// Whether `bytes` could be a chunk's id: four capital letters.
fn isId(bytes: *const [4]u8) bool {
    for (bytes) |c| if (!std.ascii.isUpper(c)) return false;
    return true;
}

test Model {
    const chunk = riff.testing.chunk;
    const body = comptime chunk("MODL", "mesh") ++ chunk(texture_id, "tim!") ++ chunk(end_id, "");
    const header: Header = .{ .magic = Header.trek.*, .length = @sizeOf(Header) + 4 + body.len };
    // The model's number, 7, and the archive's padding after the last chunk.
    const bytes = std.mem.asBytes(&header) ++ "\x07\x00\x00\x00" ++ body ++ "pad";
    const model: Model = try .parse(bytes);
    try std.testing.expectEqual(7, model.number);
    var all = model.chunks();
    const first = (try all.next()).?;
    try std.testing.expectEqualStrings("mesh", first.body);
    try std.testing.expectEqual(@sizeOf(Header) + 4, model.offsetOf(first));
    try std.testing.expectEqualStrings(texture_id, &(try all.next()).?.id);
    try std.testing.expectEqualStrings(end_id, &(try all.next()).?.id);
    try std.testing.expectEqual(null, try all.next());

    // A model without a number.
    const plain: Header = .{ .magic = Header.trek.*, .length = @sizeOf(Header) + body.len };
    const unnumbered: Model = try .parse(std.mem.asBytes(&plain) ++ body);
    try std.testing.expectEqual(null, unnumbered.number);
    var unnumbered_chunks = unnumbered.chunks();
    try std.testing.expectEqualStrings("MODL", &(try unnumbered_chunks.next()).?.id);

    try std.testing.expectError(error.Truncated, Model.parse(bytes[0..20]));
    try std.testing.expectError(error.NotAModel, Model.parse("TRAK" ++ bytes[4..]));
}
