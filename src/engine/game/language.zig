//! `C:\lancer\game\language.cpp`: the game's strings. `language_init` (`0x00490DC0`) loads
//! `language.dll` at start-up and reads its string table with `LoadStringA`, from id 1 on, into an
//! array; `language_string` (`0x00491030`) hands one out by its id.

const std = @import("std");
const Allocator = std.mem.Allocator;

const pe = @import("../../formats/pe.zig");

/// The module the strings come from. The game asks for `language.dll`; the disc's file is
/// named in capitals, and Windows finds either.
pub const file_name = "LANGUAGE.DLL";

/// The most of a string `LoadStringA` copies: `language_init`'s buffer is 999 bytes, the last
/// for the terminator.
pub const max_length = 998;

pub const Language = struct {
    /// Each string, in the game's code page, by its id less one.
    strings: []const []const u8,

    /// `language_init`: the strings of `module` from id 1 up to the first one `LoadStringA` finds
    /// nothing of, which is a missing string or an empty one. A blank string the game wants is
    /// therefore a space.
    pub fn load(gpa: Allocator, module: pe.Image) Allocator.Error!Language {
        var strings: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (strings.items) |text| gpa.free(text);
            strings.deinit(gpa);
        }
        var id: u32 = 1;
        while (id <= std.math.maxInt(u16)) : (id += 1) {
            const units = module.string(@intCast(id)) orelse break;
            if (units.len == 0) break;
            const text = try gpa.alloc(u8, @min(units.len, max_length));
            for (text, units[0..text.len]) |*out, unit| out.* = codePage1252(unit);
            try strings.append(gpa, text);
        }
        return .{ .strings = try strings.toOwnedSlice(gpa) };
    }

    pub fn deinit(language: *Language, gpa: Allocator) void {
        for (language.strings) |text| gpa.free(text);
        gpa.free(language.strings);
        language.* = undefined;
    }

    /// `language_string`: the string of `id`, or null for an id past the table, for which the
    /// game stops with the fatal error "id out of range".
    pub fn string(language: Language, id: u32) ?[]const u8 {
        if (id == 0 or id > language.strings.len) return null;
        return language.strings[id - 1];
    }
};

/// Words to show: a string of a language table, by its id, or a mod's own text in the game's code
/// page.
pub const Words = union(enum) {
    string: u16,
    text: []const u8,

    /// The text of `words`, reading a string from `table`; empty for an id past the table.
    pub fn in(words: Words, table: Language) []const u8 {
        return switch (words) {
            .string => |id| table.string(id) orelse "",
            .text => |text| text,
        };
    }

    /// The strings `ids` as words, at compile time.
    pub fn strings(comptime ids: []const u16) []const Words {
        return comptime all: {
            @setEvalBranchQuota(10_000);
            var all: [ids.len]Words = undefined;
            for (&all, ids) |*words, id| words.* = .{ .string = id };
            const kept = all;
            break :all &kept;
        };
    }
};

test Words {
    const table: Language = .{ .strings = &.{ "Mission", "Kills" } };
    try std.testing.expectEqualStrings("Kills", (Words{ .string = 2 }).in(table));
    try std.testing.expectEqualStrings("", (Words{ .string = 3 }).in(table));
    try std.testing.expectEqualStrings("Bananas", (Words{ .text = "Bananas" }).in(table));
    try std.testing.expectEqual(5, Words.strings(&.{ 4, 5 })[1].string);
}

/// A character typed, as `WM_CHAR` gives it in the game's code page, 1252 (`codePage1252`): a
/// question mark for one the page doesn't hold.
pub fn fromUnicode(character: u21) u8 {
    return codePage1252(std.math.cast(u16, character) orelse return '?');
}

/// `text`, UTF-8, in the game's code page, 1252 (`fromUnicode`), as much of it as `buffer` holds;
/// empty where it isn't UTF-8.
pub fn encode(buffer: []u8, text: []const u8) []u8 {
    const view = std.unicode.Utf8View.init(text) catch return buffer[0..0];
    var points = view.iterator();
    var length: usize = 0;
    while (points.nextCodepoint()) |point| {
        if (length == buffer.len) break;
        buffer[length] = fromUnicode(point);
        length += 1;
    }
    return buffer[0..length];
}

/// `text`, in the game's code page, 1252, as UTF-8 (`toUnicode`), as many whole characters of it
/// as `buffer` holds.
pub fn decode(buffer: []u8, text: []const u8) []u8 {
    var length: usize = 0;
    for (text) |byte| {
        const character = utf8_of[byte];
        if (length + character.len > buffer.len) break;
        @memcpy(buffer[length..][0..character.len], character.bytes[0..character.len]);
        length += character.len;
    }
    return buffer[0..length];
}

/// The most bytes a character of the game's code page takes in UTF-8.
pub const max_utf8_bytes = 3;

/// A character of the code page in UTF-8: its first `len` bytes.
const Utf8 = struct { bytes: [max_utf8_bytes]u8, len: u8 };

/// Each byte of the code page in UTF-8 (`toUnicode`), worked out as the build runs.
const utf8_of: [256]Utf8 = table: {
    @setEvalBranchQuota(10000);
    var table: [256]Utf8 = undefined;
    for (&table, 0..) |*entry, byte| {
        entry.bytes = @splat(0);
        entry.len = std.unicode.utf8Encode(toUnicode(byte), &entry.bytes) catch unreachable;
    }
    break :table table;
};

/// The character the game's code page, 1252, holds at `byte` (`codePage1252`): `byte` itself below
/// `0x80` and from `0xA0`, and the page's own between.
pub fn toUnicode(byte: u8) u21 {
    return switch (byte) {
        0x80...0x9F => cp1252_high[byte - 0x80],
        else => byte,
    };
}

/// A UTF-16 unit as `LoadStringA` writes it under Windows' Western code page, 1252: itself below
/// `0x80` and from `0xA0` to `0xFF`, the page's own byte for the characters it holds between, and
/// a question mark for the rest. **Unverified:** that the game's strings meet the Western page;
/// `LoadStringA` takes the system's own.
fn codePage1252(unit: u16) u8 {
    if (unit < 0x80 or (unit >= 0xA0 and unit <= 0xFF)) return @intCast(unit);
    for (cp1252_high, 0x80..) |mapped, byte| {
        if (mapped == unit) return @intCast(byte);
    }
    return '?';
}

/// What code page 1252 holds from `0x80` to `0x9F`. The five places it leaves undefined map to
/// the control characters of the same number, as Windows round-trips them.
const cp1252_high = [32]u16{
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
};

/// `CharUpperBuffA` over `text`, in place, under code page 1252, which the game's strings are in
/// (`codePage1252`): the small letters of the page become its capitals, and the rest stay, `ß` and
/// `µ` among them, which have no capital in the page. The loadout's panels write their labels so.
/// **Unverified:** the function. The payload calls it through SafeDisc, whose stubs pick the
/// function by the call's own address, so the import tables don't name it; it takes a buffer and
/// its length, and the panels' other text is in capitals.
pub fn upperCase(text: []u8) void {
    for (text) |*character| character.* = switch (character.*) {
        'a'...'z', 0xE0...0xF6, 0xF8...0xFE => character.* - 0x20,
        0x9A, 0x9C, 0x9E => character.* - 0x10,
        0xFF => 0x9F,
        else => character.*,
    };
}

test Language {
    const gpa = std.testing.allocator;
    var table: [20]?[]const u8 = @splat(null);
    table[1] = "Cockpit View";
    table[2] = " ";
    table[3] = "External Camera";
    table[5] = "past the gap";
    const rsrc = try pe.testing.stringResources(gpa, 0x3000, &table);
    defer gpa.free(rsrc);
    const bytes = try pe.testing.buildWith(gpa, 0x10000000, &.{
        .{ .name = ".rsrc", .rva = 0x3000, .data = rsrc },
    }, &.{.{ .index = .resource, .rva = 0x3000, .size = @intCast(rsrc.len) }});
    defer gpa.free(bytes);

    var language: Language = try .load(gpa, try .parse(bytes));
    defer language.deinit(gpa);
    // Ids count from 1, and the first empty string ends the table.
    try std.testing.expectEqual(3, language.strings.len);
    try std.testing.expectEqualStrings("Cockpit View", language.string(1).?);
    try std.testing.expectEqualStrings(" ", language.string(2).?);
    try std.testing.expectEqualStrings("External Camera", language.string(3).?);
    try std.testing.expectEqual(null, language.string(0));
    try std.testing.expectEqual(null, language.string(5));
}

test fromUnicode {
    try std.testing.expectEqual('A', fromUnicode('A'));
    try std.testing.expectEqual(0xE9, fromUnicode(0xE9));
    try std.testing.expectEqual(0x80, fromUnicode(0x20AC));
    try std.testing.expectEqual('?', fromUnicode(0x1F600));
}

test encode {
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqualStrings("A\xE9?", encode(&buffer, "A\u{E9}\u{416}"));
    // Cut to the buffer, and nothing where it isn't UTF-8.
    try std.testing.expectEqualStrings("Page", encode(&buffer, "Page Up"));
    try std.testing.expectEqualStrings("", encode(&buffer, "\xFF"));
}

test decode {
    var buffer: [16]u8 = undefined;
    // Plain letters stay, and the page's own characters become theirs: 0x80 is the euro sign.
    try std.testing.expectEqualStrings("A\u{20AC}b\u{E9}", decode(&buffer, "A\x80b\xE9"));
    // Only whole characters fit: the euro sign takes three bytes.
    try std.testing.expectEqualStrings("ab", decode(buffer[0..4], "ab\x80"));
    // Every byte has a character of at most `max_utf8_bytes`.
    for (0..256) |byte| try std.testing.expect(utf8_of[byte].len >= 1 and utf8_of[byte].len <= max_utf8_bytes);
}

test toUnicode {
    try std.testing.expectEqual('A', toUnicode('A'));
    try std.testing.expectEqual(0xE9, toUnicode(0xE9));
    try std.testing.expectEqual(0x20AC, toUnicode(0x80));
    try std.testing.expectEqual(0x2122, toUnicode(0x99));
    // Every byte back where it came from, the page's five undefined places among them.
    for (0..0x100) |byte| try std.testing.expectEqual(byte, fromUnicode(toUnicode(@intCast(byte))));
}

test codePage1252 {
    try std.testing.expectEqual('A', codePage1252('A'));
    try std.testing.expectEqual(0xE9, codePage1252(0xE9));
    try std.testing.expectEqual(0x80, codePage1252(0x20AC));
    try std.testing.expectEqual(0x99, codePage1252(0x2122));
    try std.testing.expectEqual('?', codePage1252(0x4E2D));
}

test upperCase {
    var text = "Max Speed \xE9\xF7\xFF\x9A\xDF\xB5".*;
    upperCase(&text);
    try std.testing.expectEqualStrings("MAX SPEED \xC9\xF7\x9F\x8A\xDF\xB5", &text);
}
