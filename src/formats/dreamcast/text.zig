//! The Dreamcast version's text tables, `GTEXT.DAT` for the game and `ITEXT.DAT` for the ITAC,
//! where the PC version uses the string tables in `LANGUAGE.DLL` and `ITACLANG.DLL`. A table is a
//! word, then the offset of each string in the file, then the strings, each ending in a zero byte.
//! The offsets run up to the first string. **Unknown:** the first word, 6551 in both tables.
//! **Unverified:** how the strings' numbers relate to the PC's string IDs.

const std = @import("std");

const layout = @import("../layout.zig");

pub const game_file = "GTEXT.DAT";
pub const itac_file = "ITEXT.DAT";

pub const Error = error{NotATable};

pub const Table = struct {
    bytes: []const u8,
    offsets: []align(1) const u32,

    pub fn parse(bytes: []const u8) Error!Table {
        const first = (layout.view(u32, bytes[@min(bytes.len, 4)..]) catch return error.NotATable).*;
        if (first < 8 or first % 4 != 0 or first > bytes.len) return error.NotATable;
        const offsets = layout.array(u32, bytes[4..], (first - 4) / 4) catch return error.NotATable;
        for (offsets) |offset| {
            if (offset < first or offset >= bytes.len) return error.NotATable;
        }
        return .{ .bytes = bytes, .offsets = offsets };
    }

    /// String `number`, without its zero byte; null past the last, or for one the file doesn't end.
    pub fn string(table: Table, number: usize) ?[]const u8 {
        if (number >= table.offsets.len) return null;
        const rest = table.bytes[table.offsets[number]..];
        return rest[0 .. std.mem.findScalar(u8, rest, 0) orelse return null];
    }
};

test Table {
    // The word, two offsets, then the strings.
    const bytes = "\x97\x19\x00\x00\x0C\x00\x00\x00\x14\x00\x00\x00PHOENIX\x00SHROUD\x00";
    const table: Table = try .parse(bytes);
    try std.testing.expectEqual(2, table.offsets.len);
    try std.testing.expectEqualStrings("PHOENIX", table.string(0).?);
    try std.testing.expectEqualStrings("SHROUD", table.string(1).?);
    try std.testing.expectEqual(null, table.string(2));
    try std.testing.expectError(error.NotATable, Table.parse("\x97\x19\x00\x00\xFF\x00\x00\x00"));
}
