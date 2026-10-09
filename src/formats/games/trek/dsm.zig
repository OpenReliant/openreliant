//! Star Trek: Invasion's `.DSM` missions, which have the layout of StarLancer's `.DTE` missions: a
//! directory of sections, each a count and an offset, in front of the sections themselves. The
//! directory has 128 entries rather than 27, and the sections come in another order. The script
//! has StarLancer's bytecode, and its triggers and parts have StarLancer's records.
//!
//! Six sections hold StarLancer's records, and `Mission.asDte` points a `.DTE` directory at them,
//! so that StarLancer's mission reader (`dte.Mission`) reads them. The ships keep other records:
//! a ship names its model by a string, such as `VALKA`, and places it with whole numbers rather
//! than floats. The other sections are described in
//! [Star Trek: Invasion](../../../../docs/games/star-trek-invasion.md#missions).
//!
//! **Unknown:** what Invasion's Executor commands do. Commands `0x01` to `0x03` are StarLancer's
//! (`CreateTimer`, `DestroyTimer` and `CreateFlightGroup`), and the rest differ.

const std = @import("std");

const layout = @import("../../layout.zig");
const dte = @import("../../dte.zig");

/// The entries of the directory, which fills the first 1024 bytes.
pub const section_count = 128;

pub const Section = enum(u8) {
    /// NUL-terminated names, addressed by byte offset, as StarLancer's `strings`.
    strings = 1,
    /// The ships, stride `0x44`: a ship's model is a string offset at `+0`, its name one at `+4`.
    ships = 3,
    flight_groups = 4,
    triggers = 6,
    /// The script bytecode, counted in halfwords.
    script = 7,
    objects = 8,
    parts = 9,
    _,

    /// StarLancer's section with the same record layout, or null if the layout differs or isn't
    /// known.
    pub fn asDte(section: Section) ?dte.Section {
        return switch (section) {
            .strings => .strings,
            .flight_groups => .flight_groups,
            .triggers => .triggers,
            .script => .script,
            .objects => .objects,
            .parts => .parts,
            .ships, _ => null,
        };
    }

    pub fn format(section: Section, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return layout.formatTagAs(Section, section, "section", writer);
    }
};

pub const Error = error{NotAMission};

pub const Mission = struct {
    image: []const u8,
    directory: []align(1) const dte.DirectoryEntry,

    pub fn parse(image: []const u8) Error!Mission {
        const directory = layout.array(dte.DirectoryEntry, image, section_count) catch return error.NotAMission;
        return .{ .image = image, .directory = directory };
    }

    pub fn entry(mission: Mission, section: Section) dte.DirectoryEntry {
        return mission.directory[@backingInt(section)];
    }

    /// The bytes of the string pool, whose count is in bytes.
    pub fn strings(mission: Mission) []const u8 {
        const pool = mission.entry(.strings);
        if (!pool.isUsed() or pool.offset > mission.image.len) return &.{};
        const rest = mission.image[pool.offset..];
        return rest[0..@min(rest.len, pool.count)];
    }

    /// The mission as StarLancer's reader sees it: `directory` points at the sections that hold
    /// StarLancer's records (`Section.asDte`), and leaves every other section unused.
    pub fn asDte(mission: Mission, directory: *[dte.section_count]dte.DirectoryEntry) dte.Mission {
        return .remapped(mission.image, mission.directory, Section, directory);
    }
};

test Mission {
    // A directory of unused entries, then the strings and a script of one halfword.
    var image: [section_count * @sizeOf(dte.DirectoryEntry) + 8]u8 align(4) = undefined;
    const directory: *[section_count]dte.DirectoryEntry = @ptrCast(image[0 .. section_count * @sizeOf(dte.DirectoryEntry)]);
    directory.* = @splat(.unused);
    const end = section_count * @sizeOf(dte.DirectoryEntry);
    @memcpy(image[end..][0..6], "VALKA\x00");
    @memcpy(image[end + 6 ..][0..2], "\x34\x12");
    directory[@backingInt(Section.strings)] = .{ .count = 6, ._unused = 0, .formats = .all, .offset = end };
    directory[@backingInt(Section.script)] = .{ .count = 1, ._unused = 0, .formats = .all, .offset = end + 6 };
    directory[@backingInt(Section.ships)] = .{ .count = 1, ._unused = 0, .formats = .all, .offset = end };

    const mission: Mission = try .parse(&image);
    try std.testing.expectEqualStrings("VALKA\x00", mission.strings());
    var remapped: [dte.section_count]dte.DirectoryEntry = undefined;
    const starlancer = mission.asDte(&remapped);
    try std.testing.expectEqualStrings("VALKA", starlancer.name(0));
    try std.testing.expectEqualSlices(u8, "\x34\x12", try starlancer.script());
    // The ships keep other records, so StarLancer's reader sees none.
    try std.testing.expect(!starlancer.entry(.ships).isUsed());
    try std.testing.expectError(error.NotAMission, Mission.parse(image[0..100]));
}
