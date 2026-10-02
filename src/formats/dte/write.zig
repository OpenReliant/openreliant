//! Writing mission files: the sections laid out as the shipped missions lay them out, so that the
//! game, and any tool made for its missions, reads them as it reads its own.
//! [`docs/formats/dte.md`](../../../docs/formats/dte.md#writing) describes the layout.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const dte = @import("../dte.zig");
const commands = @import("../../engine/game/executor/commands.zig");
const Section = dte.Section;
const DirectoryEntry = dte.DirectoryEntry;

/// The layout 36 of the 44 shipped missions share, `mission1`'s among them: each section's offset,
/// the room it has up to the next, and the file's size. Section 21 has no room of its own: it
/// starts where section 22 does.
pub const template = struct {
    pub const offsets = [dte.section_count]u32{
        0x00400, 0x103FF, 0x303F7, 0x30FF7, 0x3A7F7, 0x3BBF7, 0x47BF7, 0x57BF7, 0x597F7,
        0x5B3F7, 0x5C3F7, 0x6C3F3, 0x6C3F7, 0x6C9F7, 0x6EDF7, 0x6EFF7, 0x70FF7, 0x753F7,
        0x76FF7, 0x86FF7, 0x87BF7, 0x8F3F7, 0x8F3F7, 0xAF3EF, 0xAF7EF, 0xAF9EF, 0xAFBEF,
    };
    pub const size: u32 = 0xCFBE7;
    /// The directory's slots before the first section, of which the game reads the first 27.
    pub const slots = offsets[0] / @sizeOf(DirectoryEntry);
    /// The flags every entry of the template's missions carries.
    pub const formats: DirectoryEntry.Formats = .all;

    /// Section 24 as the template's missions hold it (`Section.command_flags`): for each command
    /// of the catalogue a word with a bit for each of its parameters, save the commands that leave
    /// the players' ships out of a flight group or a squad (`unflagged_commands`), whose word is 0.
    pub const command_flags: [commands.table.len]u16 = flags: {
        @setEvalBranchQuota(10_000);
        var words: [commands.table.len]u16 = undefined;
        for (&words, commands.table) |*word, command| {
            word.* = (1 << command.params.len) - 1;
            for (unflagged_commands) |name| {
                if (std.mem.eql(u8, name, command.name)) word.* = 0;
            }
        }
        break :flags words;
    };

    /// The commands whose word of section 24 is 0 in the template's missions.
    pub const unflagged_commands = [_][]const u8{
        "ClearAI",               "SetPatrolRoute",        "SetTriggerState",
        "MovingShipFollowCurve", "MovingShipBackupCurve", "SetAnyTriggerState",
    };

    /// The bytes section `index` has before the next section, or the file's end: none for section
    /// 21, which starts where section 22 does.
    pub fn room(index: usize) u32 {
        const end = if (index + 1 < offsets.len) offsets[index + 1] else size;
        return end - offsets[index];
    }

    comptime {
        assert(offsets[0] == slots * @sizeOf(DirectoryEntry));
        for (offsets[1..], offsets[0 .. offsets.len - 1]) |next, before| assert(next >= before);
    }
};

/// What a section holds: its directory count and its bytes.
pub const Contents = struct {
    count: u16 = 0,
    bytes: []const u8 = &.{},
};

pub const Sections = [dte.section_count]Contents;

/// Has `sections` hold `bytes` in section `which`, counted as `count` records.
pub fn set(sections: *Sections, which: Section, count: usize, bytes: []const u8) void {
    sections[@intFromEnum(which)] = .{ .count = @intCast(count), .bytes = bytes };
}

pub const Options = struct {
    formats: DirectoryEntry.Formats = template.formats,
    /// OpenReliant's own name for the mission, which goes in section 21 (`dte.OpenReliantName`),
    /// written after the template's end, since the template gives the section no room.
    name: ?[]const u8 = null,
};

pub const Error = Allocator.Error || error{
    /// A section's bytes are more than the template has room for.
    SectionTooLarge,
    /// A name longer than its header can count.
    NameTooLong,
};

/// A mission file of `sections`, laid out as the template lays it out: a directory of
/// `template.slots` entries, the game's 27 first, each section at its offset and the rest of its
/// room zero. The directory's 28th entry holds the file's size, as the shipped missions' does, and
/// the rest are unused. Section 21, where it holds anything, and OpenReliant's name go after the
/// template's end.
pub fn write(gpa: Allocator, sections: *const Sections, options: Options) Error![]u8 {
    var name_section: []u8 = &.{};
    defer gpa.free(name_section);
    if (options.name) |name| name_section = try nameSection(gpa, name);
    const last: Contents = if (options.name != null)
        .{ .count = @intCast(name_section.len), .bytes = name_section }
    else
        sections[@intFromEnum(Section.openreliant_name)];
    const size = template.size + last.bytes.len;

    const bytes = try gpa.alloc(u8, size);
    errdefer gpa.free(bytes);
    @memset(bytes, 0);
    const directory: []align(1) DirectoryEntry = @alignCast(std.mem.bytesAsSlice(DirectoryEntry, bytes[0..template.offsets[0]]));
    for (directory) |*entry| entry.* = .{ .count = 0, ._unused = 0, .formats = options.formats, .offset = DirectoryEntry.unused_offset };
    directory[dte.section_count].offset = @intCast(size);
    for (sections, template.offsets, 0..) |section, offset, index| {
        const contents = if (index == @intFromEnum(Section.openreliant_name)) last else section;
        const at = if (index == @intFromEnum(Section.openreliant_name) and contents.bytes.len > 0) template.size else offset;
        if (at == offset and contents.bytes.len > template.room(index)) return error.SectionTooLarge;
        directory[index] = .{ .count = contents.count, ._unused = 0, .formats = options.formats, .offset = at };
        @memcpy(bytes[at..][0..contents.bytes.len], contents.bytes);
    }
    return bytes;
}

/// Section 21's bytes for `name`: the header, the name and a NUL.
fn nameSection(gpa: Allocator, name: []const u8) Error![]u8 {
    const length = std.math.cast(u16, name.len) orelse return error.NameTooLong;
    const header_size = @sizeOf(dte.OpenReliantName);
    if (header_size + name.len + 1 > std.math.maxInt(u16)) return error.NameTooLong;
    const bytes = try gpa.alloc(u8, header_size + name.len + 1);
    @as(*align(1) dte.OpenReliantName, @ptrCast(bytes[0..header_size])).* = .{ .length = length };
    @memcpy(bytes[header_size..][0..name.len], name);
    bytes[bytes.len - 1] = 0;
    return bytes;
}

/// Each section of `mission` as far as its records go: its count times its stride
/// (`Section.stride`). A section of an unknown stride must be empty.
pub fn records(mission: dte.Mission) (dte.Error || error{UnknownStride})!Sections {
    var sections: Sections = @splat(.{});
    for (&sections, 0..) |*section, index| {
        const entry = mission.entry(@enumFromInt(index));
        if (!entry.isUsed() or entry.count == 0) continue;
        const stride = (@as(Section, @enumFromInt(index))).stride() orelse return error.UnknownStride;
        const size = @as(usize, entry.count) * stride;
        if (entry.offset + size > mission.image.len) return error.Truncated;
        section.* = .{ .count = entry.count, .bytes = mission.image[entry.offset..][0..size] };
    }
    return sections;
}

/// Each section of `mission`, a mission laid out as the template lays it out, with all of its room:
/// what writing it again needs to give back the same bytes, whatever the room holds past the
/// records. Null for a mission laid out otherwise.
pub fn rooms(mission: dte.Mission) ?Sections {
    if (mission.image.len != template.size) return null;
    var sections: Sections = @splat(.{});
    for (&sections, template.offsets, 0..) |*section, offset, index| {
        const entry = mission.entry(@enumFromInt(index));
        if (entry.offset != offset) return null;
        section.* = .{ .count = entry.count, .bytes = mission.image[offset..][0..template.room(index)] };
    }
    return sections;
}

/// Whether two missions' sections hold the same records.
pub fn sameRecords(a: Sections, b: Sections) bool {
    for (a, b) |left, right| {
        if (left.count != right.count or !std.mem.eql(u8, left.bytes, right.bytes)) return false;
    }
    return true;
}

test write {
    const gpa = std.testing.allocator;
    var ship = std.mem.zeroes(dte.Ship);
    ship.name = 0;
    ship.pilot = dte.Ship.no_pilot;
    ship.kind = 43;
    var sections: Sections = @splat(.{});
    sections[@intFromEnum(Section.strings)] = .{ .count = 7, .bytes = "Player\x00" };
    sections[@intFromEnum(Section.ships)] = .{ .count = 1, .bytes = std.mem.asBytes(&ship) };
    const bytes = try write(gpa, &sections, .{ .name = "Test" });
    defer gpa.free(bytes);

    // The game's reader finds each section where the template has it, and the name after it.
    const mission: dte.Mission = try .parse(bytes);
    try std.testing.expectEqual(template.offsets[@intFromEnum(Section.ships)], mission.entry(.ships).offset);
    try std.testing.expectEqualStrings("Player", mission.name((try mission.player()).?.name));
    try std.testing.expectEqualStrings("Test", mission.openReliantName().?);
    try std.testing.expectEqual(bytes.len, mission.directory.ptr[dte.section_count].offset);
    // Its records read back as they were given, the name's section besides.
    var read = try records(mission);
    try std.testing.expectEqual(@sizeOf(dte.OpenReliantName) + "Test".len + 1, read[@intFromEnum(Section.openreliant_name)].count);
    read[@intFromEnum(Section.openreliant_name)] = .{};
    try std.testing.expect(sameRecords(sections, read));

    // A section larger than its room fails.
    const large = try gpa.alloc(u8, template.room(@intFromEnum(Section.globals)) + 1);
    defer gpa.free(large);
    @memset(large, 0);
    sections[@intFromEnum(Section.globals)] = .{ .count = 1, .bytes = large };
    try std.testing.expectError(error.SectionTooLarge, write(gpa, &sections, .{}));
}

test rooms {
    const gpa = std.testing.allocator;
    const empty: Sections = @splat(.{});
    const bytes = try write(gpa, &empty, .{});
    defer gpa.free(bytes);
    // Written again from its rooms, a mission of the template comes back byte for byte.
    const again = try write(gpa, &rooms(try .parse(bytes)).?, .{});
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, bytes, again);
}
