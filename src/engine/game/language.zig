//! `C:\lancer\game\language.cpp`: the game's strings. `language_init` (`0x00490DC0`) loads
//! `language.dll` at start-up and reads its string table with `LoadStringA`, from id 1 on, into an
//! array; `language_string` (`0x00491030`) hands one out by its id.

const std = @import("std");
const Allocator = std.mem.Allocator;

const pe = @import("../../formats/pe.zig");

/// The module the strings come from. The game asks for `language.dll`; the disc's file is
/// named in capitals, and Windows finds either.
pub const file_name = "LANGUAGE.DLL";

/// The names a module of strings goes by, the first found being read: the one the Russian
/// release keeps its own strings under, and the game's. That release leaves the English modules
/// under the game's names and adds its own beside them, their first letter an R, which its
/// executable asks for instead: `RANGUAGE.DLL` for `LANGUAGE.DLL`, and `RTACLANG.DLL` for the
/// ITAC's `ITACLANG.DLL`
/// ([Russian release](../../../docs/formats/russian-release.md)).
pub fn names(comptime name: []const u8) [2][]const u8 {
    return .{ "R" ++ name[1..], name };
}

test names {
    try std.testing.expectEqualStrings("RANGUAGE.DLL", names(file_name)[0]);
    try std.testing.expectEqualStrings("LANGUAGE.DLL", names(file_name)[1]);
    try std.testing.expectEqualStrings("RTACLANG.DLL", names("ITACLANG.DLL")[0]);
}

/// The most of a string `LoadStringA` copies: `language_init`'s buffer is 999 bytes, the last
/// for the terminator.
pub const max_length = 998;

/// A line of up to `room` bytes in the game's code page, stored by value.
pub fn Text(comptime room: usize) type {
    return struct {
        bytes: [room]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        /// The line, without its terminator.
        pub fn slice(text: *const Self) []const u8 {
            return text.bytes[0..text.len];
        }

        /// Copies as much of the line as fits.
        pub fn set(text: *Self, from: []const u8) void {
            text.len = @min(from.len, room);
            @memmove(text.bytes[0..text.len], from[0..text.len]);
        }
    };
}

/// The code page the game's text is in. The game reads its strings with `LoadStringA`, which
/// writes them in the system's own page, and its fonts hold that page's characters: the Western
/// page for the releases Microsoft made, and the Cyrillic one for the Russian release, whose
/// strings are Cyrillic and whose fonts were redrawn with those letters
/// ([Russian release](../../../docs/formats/russian-release.md)).
pub const Page = enum {
    /// Code page 1252.
    western,
    /// Code page 1251.
    cyrillic,

    /// The page a string table's text needs: the Cyrillic one where any of its strings holds a
    /// Cyrillic letter, the Western one otherwise.
    pub fn of(module: pe.Image) Page {
        var id: u32 = 1;
        while (id <= std.math.maxInt(u16)) : (id += 1) {
            const units = module.string(@intCast(id)) orelse break;
            if (units.len == 0) break;
            for (units) |unit| if (unit >= cyrillic_first and unit <= cyrillic_last) return .cyrillic;
        }
        return .western;
    }

    /// Whether the page holds a letter at `byte` beyond the Latin ones every page shares: the
    /// Russian alphabet, with Ё and ё, in the Cyrillic page. The Western page's accented letters
    /// don't count, as the game's fonts were measured by their plain ones.
    pub fn ownLetter(in: Page, byte: u8) bool {
        return switch (in) {
            .western => false,
            .cyrillic => byte >= 0xC0 or byte == 0xA8 or byte == 0xB8,
        };
    }

    /// The Unicode block of the Cyrillic letters.
    const cyrillic_first = 0x0400;
    const cyrillic_last = 0x04FF;

    /// What the page holds from `0x80` on, as far as it differs from Unicode's own characters of
    /// those numbers.
    fn high(in: Page) []const u16 {
        return switch (in) {
            .western => &cp1252_high,
            .cyrillic => &cp1251_high,
        };
    }

    /// The character the page holds at `byte`: `byte` itself below `0x80`, and past what `high`
    /// lists.
    pub fn toUnicode(in: Page, byte: u8) u21 {
        const listed = in.high();
        return if (byte >= 0x80 and byte - 0x80 < listed.len) listed[byte - 0x80] else byte;
    }

    /// A UTF-16 unit as `LoadStringA` writes it under the page: its byte there, and a question
    /// mark for a character the page doesn't hold.
    pub fn fromUnit(in: Page, unit: u16) u8 {
        if (unit < 0x80) return @intCast(unit);
        const listed = in.high();
        for (listed, 0x80..) |mapped, byte| {
            if (mapped == unit) return @intCast(byte);
        }
        return if (unit >= 0x80 + listed.len and unit <= 0xFF) @intCast(unit) else '?';
    }
};

/// The page the game's text is in (`Page`), which the driver sets from the strings it loaded, as
/// Windows gives a program the system's. Every conversion below goes by it.
pub var page: Page = .western;

/// The units the head-up display writes after a target's speed and its range, which the game
/// keeps in its executable rather than among its strings (`0x00502523`, `0x0050252C`): `kps` and
/// `k`. The Russian release's executable has them in Russian, in the Cyrillic page.
pub const Units = struct {
    speed: []const u8,
    range: []const u8,

    /// The units in the game's page (`page`).
    pub fn shown() Units {
        return switch (page) {
            .western => .{ .speed = "kps", .range = "k" },
            // "км/с" and "к".
            .cyrillic => .{ .speed = "\xEA\xEC/\xF1", .range = "\xEA" },
        };
    }
};

pub const Language = struct {
    /// Each string, in the game's code page, by its id less one.
    strings: []const []const u8,
    /// The page the strings are in (`Page.of`).
    page: Page = .western,

    /// `language_init`: the strings of `module` from id 1 up to the first one `LoadStringA` finds
    /// nothing of, which is a missing string or an empty one. A blank string the game wants is
    /// therefore a space.
    pub fn load(gpa: Allocator, module: pe.Image) Allocator.Error!Language {
        var strings: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (strings.items) |text| gpa.free(text);
            strings.deinit(gpa);
        }
        const in: Page = .of(module);
        var id: u32 = 1;
        while (id <= std.math.maxInt(u16)) : (id += 1) {
            const units = module.string(@intCast(id)) orelse break;
            if (units.len == 0) break;
            const text = try gpa.alloc(u8, @min(units.len, max_length));
            for (text, units[0..text.len]) |*out, unit| out.* = in.fromUnit(unit);
            try strings.append(gpa, text);
        }
        return .{ .strings = try strings.toOwnedSlice(gpa), .page = in };
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

    /// Some installed tables have blank entries. Use the supplied text for those and missing IDs.
    pub fn stringOr(language: Language, id: u32, fallback: []const u8) []const u8 {
        const found = language.string(id) orelse return fallback;
        return if (std.mem.trim(u8, found, " \t\r\n").len == 0) fallback else found;
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

/// A character typed, as `WM_CHAR` gives it in the game's code page (`page`): a question mark for
/// one the page doesn't hold.
pub fn fromUnicode(character: u21) u8 {
    return page.fromUnit(std.math.cast(u16, character) orelse return '?');
}

/// `text`, UTF-8, in the game's code page (`fromUnicode`), as much of it as `buffer` holds;
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

/// `text`, in the game's code page, as UTF-8 (`toUnicode`), as many whole characters of it as
/// `buffer` holds.
pub fn decode(buffer: []u8, text: []const u8) []u8 {
    var length: usize = 0;
    for (text) |byte| {
        const character = utf8_of.get(page)[byte];
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

/// Each byte of each code page in UTF-8 (`Page.toUnicode`), worked out as the build runs.
const utf8_of: std.EnumArray(Page, [256]Utf8) = tables: {
    @setEvalBranchQuota(20000);
    var tables: std.EnumArray(Page, [256]Utf8) = undefined;
    for (std.enums.values(Page)) |in| {
        var table: [256]Utf8 = undefined;
        for (&table, 0..) |*entry, byte| {
            entry.bytes = @splat(0);
            entry.len = std.unicode.utf8Encode(in.toUnicode(byte), &entry.bytes) catch unreachable;
        }
        tables.set(in, table);
    }
    break :tables tables;
};

/// The character the game's code page holds at `byte` (`Page.toUnicode`).
pub fn toUnicode(byte: u8) u21 {
    return page.toUnicode(byte);
}

/// What code page 1252 holds from `0x80` to `0x9F`. The five places it leaves undefined map to
/// the control characters of the same number, as Windows round-trips them.
const cp1252_high = [32]u16{
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
};

/// What code page 1251 holds from `0x80` on: its own characters to `0xBF`, then the Russian
/// alphabet, capitals and small letters, in order. The one place it leaves undefined, `0x98`, maps
/// to the control character of the same number.
const cp1251_high = [64]u16{
    0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021,
    0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
    0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x0098, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
    0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7,
    0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
    0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7,
    0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
} ++ russian: {
    var letters: [64]u16 = undefined;
    for (&letters, 0..) |*letter, at| letter.* = 0x0410 + at;
    break :russian letters;
};

/// `CharUpperBuffA` over `text`, in place, under the game's code page (`page`): the small letters
/// of the page become its capitals, and the rest stay, `ß` and `µ` among them, which have no
/// capital in the Western page. The loadout's panels write their labels so.
/// **Unverified:** the function. The payload calls it through SafeDisc, whose stubs pick the
/// function by the call's own address, so the import tables don't name it; it takes a buffer and
/// its length, and the panels' other text is in capitals.
pub fn upperCase(text: []u8) void {
    for (text) |*character| character.* = switch (page) {
        .western => switch (character.*) {
            'a'...'z', 0xE0...0xF6, 0xF8...0xFE => character.* - 0x20,
            0x9A, 0x9C, 0x9E => character.* - 0x10,
            0xFF => 0x9F,
            else => character.*,
        },
        // The Russian alphabet's small letters, and the page's other pairs.
        .cyrillic => switch (character.*) {
            'a'...'z', 0xE0...0xFF => character.* - 0x20,
            0x90, 0x9A, 0x9C...0x9F, 0xB8, 0xBA, 0xBF => character.* - 0x10,
            0x83 => 0x81,
            0xA2 => 0xA1,
            0xB3 => 0xB2,
            0xB4 => 0xA5,
            0xBC => 0xA3,
            0xBE => 0xBD,
            else => character.*,
        },
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
    try std.testing.expectEqualStrings("English", language.stringOr(2, "English"));
    try std.testing.expectEqualStrings("External Camera", language.stringOr(3, "English"));
    try std.testing.expectEqualStrings("English", language.stringOr(5, "English"));
}

test Page {
    // The Western page: Latin-1 as it is, and its own characters from 0x80 to 0x9F.
    try std.testing.expectEqual(0xE9, Page.western.fromUnit(0xE9));
    try std.testing.expectEqual(0x80, Page.western.fromUnit(0x20AC));
    try std.testing.expectEqual('?', Page.western.fromUnit(0x0416));
    try std.testing.expectEqual(0x20AC, Page.western.toUnicode(0x80));
    // The Cyrillic page: the Russian alphabet from 0xC0, and no Latin-1 letters.
    try std.testing.expectEqual(0xC0, Page.cyrillic.fromUnit(0x0410));
    try std.testing.expectEqual(0xFF, Page.cyrillic.fromUnit(0x044F));
    try std.testing.expectEqual(0xA8, Page.cyrillic.fromUnit(0x0401));
    try std.testing.expectEqual('?', Page.cyrillic.fromUnit(0xE9));
    try std.testing.expectEqual('A', Page.cyrillic.fromUnit('A'));
    try std.testing.expectEqual(0x0416, Page.cyrillic.toUnicode(0xC6));
    // Every byte of each page comes back from its character.
    for (std.enums.values(Page)) |in| for (0..256) |byte| {
        try std.testing.expectEqual(byte, in.fromUnit(@intCast(in.toUnicode(@intCast(byte)))));
    };
    // The game's text follows the page set.
    defer page = .western;
    page = .cyrillic;
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\xCF\xF3\xF1\xEA", encode(&buffer, "\u{41F}\u{443}\u{441}\u{43A}"));
    try std.testing.expectEqualStrings("\u{41F}\u{443}\u{441}\u{43A}", decode(&buffer, "\xCF\xF3\xF1\xEA"));
    var word = "\xEF\xF3\xF1\xEA abc\xB8".*;
    upperCase(&word);
    try std.testing.expectEqualStrings("\xCF\xD3\xD1\xCA ABC\xA8", &word);
}

test "a string table with Cyrillic letters is read in the Cyrillic page" {
    const gpa = std.testing.allocator;
    var table: [20]?[]const u8 = @splat(null);
    table[1] = "Mission";
    table[2] = "\u{41F}\u{443}\u{441}\u{43A}";
    const rsrc = try pe.testing.stringResources(gpa, 0x3000, &table);
    defer gpa.free(rsrc);
    const bytes = try pe.testing.buildWith(gpa, 0x10000000, &.{
        .{ .name = ".rsrc", .rva = 0x3000, .data = rsrc },
    }, &.{.{ .index = .resource, .rva = 0x3000, .size = @intCast(rsrc.len) }});
    defer gpa.free(bytes);
    var language: Language = try .load(gpa, try .parse(bytes));
    defer language.deinit(gpa);
    try std.testing.expectEqual(Page.cyrillic, language.page);
    try std.testing.expectEqualStrings("Mission", language.string(1).?);
    try std.testing.expectEqualStrings("\xCF\xF3\xF1\xEA", language.string(2).?);
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
    for (std.enums.values(Page)) |in| for (utf8_of.get(in)) |character| {
        try std.testing.expect(character.len >= 1 and character.len <= max_utf8_bytes);
    };
}

test toUnicode {
    try std.testing.expectEqual('A', toUnicode('A'));
    try std.testing.expectEqual(0xE9, toUnicode(0xE9));
    try std.testing.expectEqual(0x20AC, toUnicode(0x80));
    try std.testing.expectEqual(0x2122, toUnicode(0x99));
    // Every byte back where it came from, the page's five undefined places among them.
    for (0..0x100) |byte| try std.testing.expectEqual(byte, fromUnicode(toUnicode(@intCast(byte))));
}

test upperCase {
    var text = "Max Speed \xE9\xF7\xFF\x9A\xDF\xB5".*;
    upperCase(&text);
    try std.testing.expectEqualStrings("MAX SPEED \xC9\xF7\x9F\x8A\xDF\xB5", &text);
}

test "Page.ownLetter" {
    // The Russian alphabet, with Ё and ё, in the Cyrillic page alone.
    try std.testing.expect(Page.cyrillic.ownLetter(0xC0));
    try std.testing.expect(Page.cyrillic.ownLetter(0xFF));
    try std.testing.expect(Page.cyrillic.ownLetter(0xA8));
    try std.testing.expect(Page.cyrillic.ownLetter(0xB8));
    try std.testing.expect(!Page.cyrillic.ownLetter('A'));
    try std.testing.expect(!Page.cyrillic.ownLetter(0xA9));
    try std.testing.expect(!Page.western.ownLetter(0xC0));
}
