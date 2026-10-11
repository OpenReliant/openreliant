//! `.fat` sound banks: a table of RIFF/WAVE sounds ([`wave.zig`](wave.zig)) packed into one file.
//! The format's first version, `1.00`, which Privateer 2 ships, is `v1`.
//!
//! The engine loads a whole bank into memory and plays entry `n` by handing Miles the WAVE file at
//! `bank + offset`. An entry's priority decides whether it may take over a voice that is already
//! playing: the player finds the busy voice of lowest priority and stops it only for a sound whose
//! priority is higher (`sound_play`, `0x00481F80`).

const std = @import("std");
const assert = std.debug.assert;

const layout = @import("layout.zig");

pub const magic = "2.00";

pub const Error = error{
    NotABank,
    Truncated,
    /// An entry points outside the file.
    BadEntry,
};

pub const Entry = extern struct {
    /// From the start of the bank.
    offset: u32,
    size: u32,
    /// Higher takes over a voice from lower. The shipped banks use 1, 5, 50 and 10000.
    priority: u32,

    comptime {
        assert(@sizeOf(Entry) == 12);
    }
};

/// The bank's header, which its table of entries follows.
pub const Header = extern struct {
    magic: [4]u8,
    count: u32,

    comptime {
        assert(@sizeOf(Header) == 8);
    }
};

pub const header_size = @sizeOf(Header);

pub const Bank = struct {
    bytes: []const u8,
    entries: []align(1) const Entry,

    pub fn parse(bytes: []const u8) Error!Bank {
        const header = layout.view(Header, bytes) catch return error.NotABank;
        if (!std.mem.eql(u8, &header.magic, magic)) return error.NotABank;
        const entries = layout.array(Entry, bytes[header_size..], header.count) catch return error.Truncated;
        for (entries) |entry| {
            if (@as(usize, entry.offset) + entry.size > bytes.len) return error.BadEntry;
        }
        return .{ .bytes = bytes, .entries = entries };
    }

    /// Sound `index`, a complete RIFF/WAVE file.
    pub fn sound(bank: Bank, index: usize) ?[]const u8 {
        if (index >= bank.entries.len) return null;
        const entry = bank.entries[index];
        return bank.bytes[entry.offset..][0..entry.size];
    }
};

/// The format's first version, `1.00`, in which Privateer 2: The Darkening (Origin, 1996) keeps its
/// sounds ([Privateer 2](../../docs/games/privateer-2.md#sound-banks)). It has the same header. Its
/// entries are 16 bytes and give the sound's size decoded rather than stored, and its sounds are raw
/// 4-bit samples rather than WAVE files.
///
/// **Unknown:** the sounds' codec. It makes four bytes of 16-bit samples from each stored byte, but
/// isn't IMA, OKI or Yamaha ADPCM as these are usually decoded
/// ([#1074](https://github.com/OpenReliant/openreliant/issues/1074)).
pub const v1 = struct {
    pub const magic = "1.00";

    pub const Entry = extern struct {
        /// From the start of the bank.
        offset: u32,
        decoded: Decoded,
        /// 10 in every shipped bank.
        priority: u32,
        /// **Unknown:** `01 00 01 00` in the speech banks, and `01 00 01 03` in `DANI.BIG`'s.
        unknown: [4]u8,

        /// The sound's size decoded, in bytes: four times its size as stored in every shipped bank.
        pub const Decoded = packed struct(u32) {
            size: u24,
            /// **Unknown:** 1 in every shipped bank.
            flag: u8,
        };

        comptime {
            assert(@sizeOf(v1.Entry) == 16);
        }
    };

    pub const Bank = struct {
        bytes: []const u8,
        entries: []align(1) const v1.Entry,

        pub fn parse(bytes: []const u8) Error!v1.Bank {
            const header = layout.view(Header, bytes) catch return error.NotABank;
            if (!std.mem.eql(u8, &header.magic, v1.magic)) return error.NotABank;
            const entries = layout.array(v1.Entry, bytes[header_size..], header.count) catch return error.Truncated;
            for (entries) |entry| {
                if (entry.offset > bytes.len) return error.BadEntry;
            }
            return .{ .bytes = bytes, .entries = entries };
        }

        /// Sound `index` as stored. The entries give no stored size, so a sound runs to the next
        /// sound or to the end of the bank. Every shipped bank holds one sound.
        pub fn sound(bank: v1.Bank, index: usize) ?[]const u8 {
            if (index >= bank.entries.len) return null;
            const start = bank.entries[index].offset;
            var end = bank.bytes.len;
            for (bank.entries) |other| {
                if (other.offset > start) end = @min(end, other.offset);
            }
            return bank.bytes[start..end];
        }
    };
};

test "v1.Bank" {
    const entries = [2]v1.Entry{
        .{ .offset = 0x28, .decoded = .{ .size = 8, .flag = 1 }, .priority = 10, .unknown = .{ 1, 0, 1, 0 } },
        .{ .offset = 0x2A, .decoded = .{ .size = 12, .flag = 1 }, .priority = 10, .unknown = .{ 1, 0, 1, 3 } },
    };
    const file = std.mem.toBytes(Header{ .magic = v1.magic.*, .count = 2 }) ++ std.mem.toBytes(entries) ++ "\x01\x02\x03\x04\x05";

    const bank = try v1.Bank.parse(file);
    try std.testing.expectEqual(2, bank.entries.len);
    try std.testing.expectEqual(12, bank.entries[1].decoded.size);
    // A sound runs to the next one, and the last to the end of the bank.
    try std.testing.expectEqualSlices(u8, "\x01\x02", bank.sound(0).?);
    try std.testing.expectEqualSlices(u8, "\x03\x04\x05", bank.sound(1).?);
    try std.testing.expectEqual(null, bank.sound(2));

    // Each version reads only its own banks.
    try std.testing.expectError(error.NotABank, Bank.parse(file));
    try std.testing.expectError(error.NotABank, v1.Bank.parse(magic ++ "\x00\x00\x00\x00"));
    var past = file.*;
    past[header_size] = 0xFF;
    try std.testing.expectError(error.BadEntry, v1.Bank.parse(&past));
}

test Bank {
    const wave = comptime @import("wave.zig").testing.pcm("\x00\x00\x01\x00");
    const entry: Entry = .{ .offset = header_size + @sizeOf(Entry), .size = wave.len, .priority = 50 };
    const file = std.mem.toBytes(Header{ .magic = magic.*, .count = 1 }) ++ std.mem.toBytes(entry) ++ wave;

    const bank = try Bank.parse(file);
    try std.testing.expectEqual(@as(usize, 1), bank.entries.len);
    try std.testing.expectEqual(@as(u32, 50), bank.entries[0].priority);
    try std.testing.expectEqualSlices(u8, wave, bank.sound(0).?);
    try std.testing.expectEqual(@as(?[]const u8, null), bank.sound(1));

    try std.testing.expectError(error.NotABank, Bank.parse("1.40\x00\x00\x00\x00"));
    try std.testing.expectError(error.Truncated, Bank.parse(magic ++ "\x09\x00\x00\x00"));
}
