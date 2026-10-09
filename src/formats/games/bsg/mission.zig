//! Battlestar Galactica's `.dte` missions, which keep StarLancer's records behind a new
//! directory: `0xDEADDEAD`, then 15 entries of an offset, a count, a zero byte and the record
//! size, where StarLancer's has 27 fixed entries of a count, flags and an offset. The script has
//! StarLancer's bytecode.
//!
//! Eight sections hold StarLancer's records, and `Mission.asDte` points a `.DTE` directory at them,
//! so that StarLancer's mission reader (`dte.Mission`) reads them. The ships and the squads have
//! 4 bytes more than StarLancer's, and the missions carry no string pool. The other sections are
//! described in [Battlestar Galactica](../../../../docs/games/battlestar-galactica.md#missions).

const std = @import("std");
const assert = std.debug.assert;

const layout = @import("../../layout.zig");
const dte = @import("../../dte.zig");

pub const magic: u32 = 0xDEADDEAD;

/// The entries of the directory.
pub const section_count = 15;

/// An entry of the directory.
pub const Entry = extern struct {
    offset: u32,
    count: u16,
    _zero: u8,
    /// The size of a record.
    record_size: u8,

    /// The entry as StarLancer's directory has it.
    pub fn asDte(entry: Entry) dte.DirectoryEntry {
        return .{ .count = entry.count, ._unused = 0, .formats = .all, .offset = entry.offset };
    }

    comptime {
        assert(@sizeOf(Entry) == 8);
    }
};

pub const Section = enum(u8) {
    /// The ships, `0x50` bytes each: StarLancer's records and 4 bytes more.
    ships = 0,
    flight_groups = 1,
    /// The squads, `0x10` bytes each: StarLancer's records and 4 bytes more.
    squads = 2,
    squad_members = 3,
    objects = 4,
    curves = 6,
    /// **Unverified:** the globals. No script uses a global past their count.
    globals = 7,
    parts = 8,
    triggers = 9,
    /// The script bytecode, counted in halfwords.
    script = 10,
    /// One halfword for each of the game's commands.
    command_flags = 11,
    _,

    /// StarLancer's section with the same record layout, or null if the layout differs or isn't
    /// known.
    pub fn asDte(section: Section) ?dte.Section {
        return switch (section) {
            .flight_groups => .flight_groups,
            .squad_members => .squad_members,
            .objects => .objects,
            .curves => .curves,
            .parts => .parts,
            .triggers => .triggers,
            .script => .script,
            .command_flags => .command_flags,
            .ships, .squads, .globals, _ => null,
        };
    }

    pub fn format(section: Section, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return layout.formatTagAs(Section, section, "section", writer);
    }
};

pub const Error = error{NotAMission};

pub const Mission = struct {
    image: []const u8,
    directory: []align(1) const Entry,

    pub fn parse(image: []const u8) Error!Mission {
        const found = layout.view(u32, image) catch return error.NotAMission;
        if (found.* != magic) return error.NotAMission;
        const directory = layout.array(Entry, image[@sizeOf(u32)..], section_count) catch return error.NotAMission;
        return .{ .image = image, .directory = directory };
    }

    /// The mission as StarLancer's reader sees it: `directory` points at the sections that hold
    /// StarLancer's records (`Section.asDte`), and leaves every other section unused.
    pub fn asDte(mission: Mission, directory: *[dte.section_count]dte.DirectoryEntry) dte.Mission {
        var entries: [section_count]dte.DirectoryEntry = undefined;
        for (&entries, mission.directory) |*converted, entry| converted.* = entry.asDte();
        return .remapped(mission.image, &entries, Section, directory);
    }
};

test Mission {
    // The directory, then a script of one halfword and an object.
    var image: [4 + section_count * @sizeOf(Entry) + 4 + 8]u8 = @splat(0);
    std.mem.writeInt(u32, image[0..4], magic, .little);
    const directory: *align(1) [section_count]Entry = @ptrCast(image[4..][0 .. section_count * @sizeOf(Entry)]);
    const end = 4 + section_count * @sizeOf(Entry);
    directory[@backingInt(Section.script)] = .{ .offset = end, .count = 1, ._zero = 0, .record_size = 2 };
    directory[@backingInt(Section.objects)] = .{ .offset = end + 4, .count = 1, ._zero = 0, .record_size = 8 };
    directory[@backingInt(Section.ships)] = .{ .offset = end, .count = 1, ._zero = 0, .record_size = 0x50 };
    @memcpy(image[end..][0..2], "\x43\x00");

    const mission: Mission = try .parse(&image);
    var remapped: [dte.section_count]dte.DirectoryEntry = undefined;
    const starlancer = mission.asDte(&remapped);
    try std.testing.expectEqualSlices(u8, "\x43\x00", try starlancer.script());
    try std.testing.expectEqual(1, (try starlancer.objects()).len);
    // The ships keep other records, so StarLancer's reader sees none.
    try std.testing.expect(!starlancer.entry(.ships).isUsed());
    try std.testing.expectError(error.NotAMission, Mission.parse("\xAD\xDE\xAD\xDE"));
    try std.testing.expectError(error.NotAMission, Mission.parse(image[4..]));
}
