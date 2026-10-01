//! Replacements for Windows' `GetPrivateProfileIntA` and `GetPrivateProfileStringA`, which the game
//! uses to read its settings from `starlancer.ini`. An ini file consists of lines of text:
//! `[section]` starts a section, and `key=value` sets a value. Section and key names are not
//! case-sensitive, and values have surrounding spaces and one pair of quotes removed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const files = @import("files.zig");

/// The game's settings file, in its folder, which it names in lower case (`settings_path`,
/// `0x005D5644`, from `%sstarlancer.ini` at `0x005099B0`).
pub const settings_name = "starlancer.ini";

pub const Profile = struct {
    text: []const u8,

    /// An empty profile, used when the file is missing: every read returns its default.
    pub const empty: Profile = .{ .text = "" };

    /// The settings file in the game's folder `dir`, read into `arena`; empty where it is missing
    /// or can't be read, so that every setting keeps its default.
    pub fn read(io: Io, arena: Allocator, dir: Io.Dir) Profile {
        return .{ .text = dir.readFileAlloc(io, settings_name, arena, .limited(files.max_file_size)) catch "" };
    }

    /// The value of `key` in `section`, or null if there is none.
    pub fn value(profile: Profile, section: []const u8, key: []const u8) ?[]const u8 {
        const line = locate(profile.text, section, key).line orelse return null;
        const text = profile.text[line.start..line.end];
        const equals = std.mem.indexOfScalar(u8, text, '=').?;
        const found = std.mem.trim(u8, text[equals + 1 ..], " \t");
        if (found.len >= 2 and (found[0] == '"' or found[0] == '\'') and found[found.len - 1] == found[0]) {
            return found[1 .. found.len - 1];
        }
        return found;
    }

    /// `WritePrivateProfileStringA`: the text with `key` in `section` set to `written`. The key's
    /// line is replaced where the section has one; else the key goes after the section's last
    /// line, or the section and the key at the end. Lines end as the file's first one does, or
    /// with a carriage return and a line feed, as Windows writes them.
    pub fn write(profile: Profile, gpa: Allocator, section: []const u8, key: []const u8, written: []const u8) Allocator.Error![]u8 {
        const text = profile.text;
        const location = locate(text, section, key);
        const newline: []const u8 = if (std.mem.indexOfScalar(u8, text, '\n')) |at|
            (if (at > 0 and text[at - 1] == '\r') "\r\n" else "\n")
        else
            "\r\n";
        if (location.line) |line| {
            return std.mem.concat(gpa, u8, &.{ text[0..line.start], key, "=", written, text[line.end..] });
        }
        if (location.section_end) |end| {
            return std.mem.concat(gpa, u8, &.{ text[0..end], newline, key, "=", written, text[end..] });
        }
        const separate: []const u8 = if (text.len > 0 and text[text.len - 1] != '\n') newline else "";
        return std.mem.concat(gpa, u8, &.{ text, separate, "[", section, "]", newline, key, "=", written, newline });
    }

    /// Where `key` of `section` stands in `text`.
    const Location = struct {
        /// The key's line, without its line ending, where the section has it.
        line: ?Span = null,
        /// Where a line added to the section goes: the end of its last line that isn't blank.
        section_end: ?usize = null,

        const Span = struct { start: usize, end: usize };
    };

    /// Finds `key` in the first section named `section`, both without regard to case, as
    /// Windows does.
    fn locate(text: []const u8, section: []const u8, key: []const u8) Location {
        var location: Location = .{};
        var in_section = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const start = @intFromPtr(raw.ptr) - @intFromPtr(text.ptr);
            const end = start + std.mem.trimEnd(u8, raw, "\r").len;
            const line = std.mem.trim(u8, text[start..end], " \t");
            if (line.len == 0) continue;
            if (line[0] == '[') {
                const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
                // Only the first section of the name counts.
                if (in_section) return location;
                in_section = std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[1..close], " \t"), section);
                if (in_section) location.section_end = end;
                continue;
            }
            if (!in_section) continue;
            location.section_end = end;
            const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (location.line == null and std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, line[0..equals], " \t"), key)) {
                location.line = .{ .start = start, .end = end };
            }
        }
        return location;
    }

    /// `GetPrivateProfileStringA`: the value, or `default` if there is none, truncated to `size - 1`
    /// bytes to fit the game's buffer.
    pub fn string(profile: Profile, section: []const u8, key: []const u8, default: []const u8, size: usize) []const u8 {
        const found = profile.value(section, key) orelse default;
        return found[0..@min(found.len, size -| 1)];
    }

    /// `GetPrivateProfileIntA`: the number formed by the value's leading decimal digits (0 if it
    /// doesn't start with a digit), or `default` if there is no value.
    pub fn int(profile: Profile, section: []const u8, key: []const u8, default: u32) u32 {
        const found = profile.value(section, key) orelse return default;
        var number: u32 = 0;
        for (found) |c| {
            if (!std.ascii.isDigit(c)) break;
            number = number *% 10 +% (c - '0');
        }
        return number;
    }
};

/// The settings file while the game runs: its text, which the game's writes change, and whether it
/// has changed since it was last saved. Every version of the text stays in `arena`, as the game
/// writes its settings seldom.
pub const File = struct {
    arena: Allocator,
    profile: Profile,
    changed: bool = false,

    /// `WritePrivateProfileStringA`, of the file.
    pub fn write(file: *File, section: []const u8, key: []const u8, written: []const u8) Allocator.Error!void {
        file.profile.text = try file.profile.write(file.arena, section, key, written);
        file.changed = true;
    }

    /// Writes `number` in decimal, as the game's `%d` does.
    pub fn writeInt(file: *File, section: []const u8, key: []const u8, number: i64) Allocator.Error!void {
        var buffer: [24]u8 = undefined;
        const length = std.fmt.printInt(&buffer, number, 10, .lower, .{});
        try file.write(section, key, buffer[0..length]);
    }
};

/// The C runtime's `atol`: skips spaces, reads an optional sign and then as many decimal digits as
/// there are. Returns 0 if there are none.
pub fn atol(text: []const u8) i32 {
    var rest = std.mem.trimStart(u8, text, " \t");
    var negative = false;
    if (rest.len > 0 and (rest[0] == '-' or rest[0] == '+')) {
        negative = rest[0] == '-';
        rest = rest[1..];
    }
    var number: i32 = 0;
    for (rest) |c| {
        if (!std.ascii.isDigit(c)) break;
        number = number *% 10 +% (c - '0');
    }
    return if (negative) -%number else number;
}

test Profile {
    const profile: Profile = .{ .text =
        \\; the game writes this file itself
        \\[KeyConfig]
        \\JoystickInvert = 0
        \\FIRE LASERS=JOY BUTTON 3
        \\Controller=2 ; trailing words
        \\
        \\[joyconfig]
        \\fire lasers="JOY BUTTON 1"
        \\Empty=
        \\
    };
    try std.testing.expectEqualStrings("0", profile.value("KeyConfig", "JoystickInvert").?);
    try std.testing.expectEqualStrings("JOY BUTTON 3", profile.value("keyconfig", "fire lasers").?);
    try std.testing.expectEqualStrings("JOY BUTTON 1", profile.value("JoyConfig", "FIRE LASERS").?);
    try std.testing.expectEqual(null, profile.value("JoyConfig", "JoystickInvert"));
    try std.testing.expectEqual(0, profile.int("KeyConfig", "JoystickInvert", 1));
    try std.testing.expectEqual(1, profile.int("KeyConfig", "HatEnable", 1));
    try std.testing.expectEqual(2, profile.int("KeyConfig", "Controller", 0));
    try std.testing.expectEqual(0, profile.int("JoyConfig", "Empty", 7));
    try std.testing.expectEqualStrings("JOY", profile.string("JoyConfig", "Fire Lasers", "", 4));
    try std.testing.expectEqualStrings("57", profile.string("JoyConfig", "Missing", "57", 0x80));
    try std.testing.expectEqual(null, Profile.empty.value("KeyConfig", "Controller"));
}

test "Profile.read" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Without the file, every setting keeps its default.
    try std.testing.expectEqualStrings("", Profile.read(io, arena_state.allocator(), tmp.dir).text);
    try tmp.dir.writeFile(io, .{ .sub_path = settings_name, .data = "[Device]\r\nView=1\r\n" });
    try std.testing.expectEqual(1, Profile.read(io, arena_state.allocator(), tmp.dir).int("Device", "View", 0));
}

test "Profile.write" {
    const gpa = std.testing.allocator;
    const profile: Profile = .{ .text = "[Sound]\r\nFxvolume=80\r\n\r\n[Device]\r\nView=1\r\n" };

    // A key the section has keeps its place.
    const replaced = try profile.write(gpa, "sound", "FXVOLUME", "64");
    defer gpa.free(replaced);
    try std.testing.expectEqualStrings("[Sound]\r\nFXVOLUME=64\r\n\r\n[Device]\r\nView=1\r\n", replaced);
    // A new key goes after the section's last line, before the blank one.
    const added = try profile.write(gpa, "Sound", "Musicvolume", "70");
    defer gpa.free(added);
    try std.testing.expectEqualStrings("[Sound]\r\nFxvolume=80\r\nMusicvolume=70\r\n\r\n[Device]\r\nView=1\r\n", added);
    try std.testing.expectEqual(70, (Profile{ .text = added }).int("Sound", "Musicvolume", 0));
    // A new section goes at the end, and a file of plain line feeds keeps them.
    const sectioned = try (Profile{ .text = "[A]\nx=1" }).write(gpa, "Device", "gamma", "100");
    defer gpa.free(sectioned);
    try std.testing.expectEqualStrings("[A]\nx=1\n[Device]\ngamma=100\n", sectioned);
    const fresh = try Profile.empty.write(gpa, "Device", "View", "2");
    defer gpa.free(fresh);
    try std.testing.expectEqualStrings("[Device]\r\nView=2\r\n", fresh);
    // Only the first section of a name is read and written.
    const twice: Profile = .{ .text = "[S]\na=1\n[S]\nb=2\n" };
    try std.testing.expectEqual(null, twice.value("S", "b"));
    const written = try twice.write(gpa, "S", "b", "3");
    defer gpa.free(written);
    try std.testing.expectEqualStrings("[S]\na=1\nb=3\n[S]\nb=2\n", written);
}

test File {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var file: File = .{ .arena = arena.allocator(), .profile = .empty };
    try std.testing.expect(!file.changed);
    try file.writeInt("Device", "gamma", -5);
    try std.testing.expect(file.changed);
    try std.testing.expectEqualStrings("-5", file.profile.value("Device", "gamma").?);
}

test atol {
    try std.testing.expectEqual(57, atol("57"));
    try std.testing.expectEqual(-1, atol(" -1"));
    try std.testing.expectEqual(12, atol("12abc"));
    try std.testing.expectEqual(0, atol("abc"));
    try std.testing.expectEqual(0, atol(""));
}
