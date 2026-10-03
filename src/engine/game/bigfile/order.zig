//! The order the mods load in, and which ones are on (`Order`), as the mods screen keeps them in
//! `starlancer.ini`. Without a list, every mod is on and they load in the order of their names
//! (`bigfile.mods.Mods.open`).
//!
//! **Improvement:** the original can't load mods.

const std = @import("std");
const Allocator = std.mem.Allocator;

const profile = @import("../../profile.zig");

/// The section of `starlancer.ini` that lists the mods, one key for each: the name of the mod in
/// the `mods` folder, and 1 if it is on or 0 if it is off. The keys stand in the order the mods
/// load in, a later mod's files replacing an earlier mod's.
pub const section = "OpenReliantMods";

/// The values of a mod's line in the list: 1 for a mod that is on, and 0 for one that is off.
const on_value = "1";
const off_value = "0";

/// A mod in the list.
pub const Listed = struct {
    /// The mod's name in the `mods` folder.
    name: []const u8,
    on: bool,
};

/// The order and the state of the mods, read from the settings file.
pub const Order = struct {
    profile: profile.Profile = .empty,

    /// No list: every mod on, in the order of their names.
    pub const none: Order = .{};

    /// Where `name` stands in the list, ignoring case; null if it isn't in it.
    pub fn position(order: Order, name: []const u8) ?usize {
        var keys = order.profile.keys(section);
        var at: usize = 0;
        while (keys.next()) |key| : (at += 1) {
            if (std.ascii.eqlIgnoreCase(key, name)) return at;
        }
        return null;
    }

    /// Whether the mod `name` is on: its line in the list isn't 0. A mod the list doesn't have is.
    pub fn isOn(order: Order, name: []const u8) bool {
        const value = order.profile.value(section, name) orelse return true;
        return !std.mem.eql(u8, value, off_value);
    }

    /// Whether the mod `first` loads before `second`: the mods in the list in its order, then the
    /// others in the order of their names, ignoring case.
    pub fn before(order: Order, first: []const u8, second: []const u8) bool {
        const at = order.position(first);
        const other = order.position(second);
        if (at != null and other != null) return at.? < other.?;
        if (at != null or other != null) return at != null;
        return std.ascii.lessThanIgnoreCase(first, second);
    }

    /// Whether a mod of the name `name` can be in the list. A name is a key of the settings file,
    /// so it can't have an equals sign, start with a bracket or have spaces at either end. A mod
    /// that can't be in the list is always on and loads with the mods the list doesn't have.
    pub fn listable(name: []const u8) bool {
        if (name.len == 0 or name[0] == '[' or std.mem.indexOfScalar(u8, name, '=') != null) return false;
        return std.mem.trim(u8, name, " \t").len == name.len;
    }

    /// Replaces the list in `file` with `mods`, in their order. A mod that can't be in the list
    /// (`listable`) is left out.
    pub fn write(file: *profile.File, mods: []const Listed) Allocator.Error!void {
        var old: std.ArrayList([]const u8) = .empty;
        defer old.deinit(file.arena);
        var keys = file.profile.keys(section);
        while (keys.next()) |key| try old.append(file.arena, key);
        for (old.items) |key| try file.remove(section, key);
        for (mods) |mod| {
            if (listable(mod.name)) try file.write(section, mod.name, if (mod.on) on_value else off_value);
        }
    }
};

test "mods not in the list are on and load by name after the listed ones" {
    const order: Order = .{ .profile = .{ .text = "[Device]\r\nView=1\r\n[OpenReliantMods]\r\nzeta=1\r\nAlpha=0\r\n" } };
    try std.testing.expectEqual(0, order.position("ZETA"));
    try std.testing.expectEqual(1, order.position("alpha"));
    try std.testing.expectEqual(null, order.position("beta"));
    try std.testing.expect(order.isOn("zeta"));
    try std.testing.expect(!order.isOn("Alpha"));
    try std.testing.expect(order.isOn("beta"));
    // Only 0 turns a mod off.
    const written: Order = .{ .profile = .{ .text = "[OpenReliantMods]\na=on\nb=0\nc=\n" } };
    try std.testing.expect(written.isOn("a") and !written.isOn("b") and written.isOn("c"));
    // The listed ones go first, in the list's order; the others by name.
    try std.testing.expect(order.before("zeta", "alpha"));
    try std.testing.expect(!order.before("alpha", "zeta"));
    try std.testing.expect(order.before("alpha", "beta"));
    try std.testing.expect(!order.before("beta", "zeta"));
    try std.testing.expect(order.before("Beta", "gamma"));
    try std.testing.expect(Order.none.before("a", "B"));
    try std.testing.expect(Order.none.isOn("anything"));
}

test "listable names" {
    try std.testing.expect(Order.listable("10-ships"));
    try std.testing.expect(Order.listable("beta.hog"));
    try std.testing.expect(Order.listable("my mod"));
    try std.testing.expect(!Order.listable(""));
    try std.testing.expect(!Order.listable("[mod]"));
    try std.testing.expect(!Order.listable("a=b"));
    try std.testing.expect(!Order.listable(" mod"));
    try std.testing.expect(!Order.listable("mod "));
}

test "write replaces the list and leaves the rest of the file" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var file: profile.File = .{ .arena = arena.allocator(), .profile = .{ .text = "[OpenReliantMods]\r\nold=1\r\n[Device]\r\nView=1\r\n" } };
    try Order.write(&file, &.{
        .{ .name = "b", .on = true },
        .{ .name = "a=1", .on = true },
        .{ .name = "a", .on = false },
    });
    try std.testing.expectEqualStrings("[OpenReliantMods]\r\nb=1\r\na=0\r\n[Device]\r\nView=1\r\n", file.profile.text);
    try std.testing.expect(file.changed);
    // With no list in the file, the section goes at the end.
    file.profile = .{ .text = "[Device]\r\nView=1\r\n" };
    try Order.write(&file, &.{.{ .name = "mod", .on = false }});
    try std.testing.expectEqualStrings("[Device]\r\nView=1\r\n[OpenReliantMods]\r\nmod=0\r\n", file.profile.text);
    const order: Order = .{ .profile = file.profile };
    try std.testing.expect(!order.isOn("mod"));
}
