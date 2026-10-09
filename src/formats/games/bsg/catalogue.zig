//! Battlestar Galactica's command catalogue, which its executable keeps in StarLancer's layout
//! (`vm.Function`): the names, parameter labels and descriptions of the Executor's commands, which
//! extend StarLancer's. It starts with the command StarLancer's starts with, `PrintShipName`, and
//! ends at an entry without an implementation, as StarLancer counts its own
//! (`catalogue_count`, `0x00452A80`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const layout = @import("../../layout.zig");
const xbe = @import("../../xbox/xbe.zig");
const Pointer = @import("../../../engine.zig").Pointer;
const Function = @import("../../../engine/vm.zig").Function;
const Kinds = @import("../../../engine/game/executor.zig").Kinds;

/// The name of the catalogue's first command, in both games.
pub const first = "PrintShipName";

/// The longest name, label or description this reads.
const longest_text = 256;

pub const Param = struct {
    kinds: Kinds,
    label: []const u8,
};

pub const Command = struct {
    name: []const u8,
    params: []const Param,
    description: []const u8,
};

pub const Error = error{ NoCatalogue, BadEntry } || Allocator.Error;

/// The catalogue's address in `executable`: the entry whose name is `first`.
pub fn find(executable: xbe.Executable) ?u32 {
    const name = executable.find(first ++ "\x00") orelse return null;
    for (executable.sections) |section| {
        const data = executable.at(section.address) orelse continue;
        var at: usize = 0;
        while (at + @sizeOf(Function) <= data.len) : (at += @alignOf(Function)) {
            const entry = layout.view(Function, data[at..]) catch break;
            if (@backingInt(entry.name) == name and isEntry(entry)) return section.address + @as(u32, @intCast(at));
        }
    }
    return null;
}

/// Whether `entry` can be a command: it has an implementation and takes no more arguments than
/// an entry holds.
fn isEntry(entry: *align(1) const Function) bool {
    return entry.entry.implementation != .null and entry.argument_count <= Function.max_params;
}

/// The commands of `executable`'s catalogue, by their numbers.
pub fn read(arena: Allocator, executable: xbe.Executable) Error![]const Command {
    var address = find(executable) orelse return error.NoCatalogue;
    var commands: std.ArrayList(Command) = .empty;
    while (true) : (address += @sizeOf(Function)) {
        const entry = layout.view(Function, executable.at(address) orelse return error.BadEntry) catch return error.BadEntry;
        if (entry.entry.implementation == .null) break;
        if (!isEntry(entry)) return error.BadEntry;
        const params = try arena.alloc(Param, entry.argument_count);
        for (params, entry.params[0..params.len]) |*param, held| {
            param.* = .{ .kinds = held.kinds, .label = try text(executable, held.label) };
        }
        try commands.append(arena, .{
            .name = try text(executable, entry.name),
            .params = params,
            .description = try text(executable, entry.description),
        });
    }
    return commands.items;
}

/// The text a catalogue's pointer points at; empty for none.
fn text(executable: xbe.Executable, pointer: Pointer(u8)) Error![]const u8 {
    if (pointer == .null) return "";
    return executable.string(@backingInt(pointer), longest_text) orelse error.BadEntry;
}

/// The commands' names, by their numbers.
pub fn names(arena: Allocator, commands: []const Command) Allocator.Error![]const []const u8 {
    const all = try arena.alloc([]const u8, commands.len);
    for (all, commands) |*name, command| name.* = command.name;
    return all;
}

test read {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The section at `base`: the strings, then two entries and the entry that ends them.
    const base = 0x20000;
    var data: [0x40 + 3 * @sizeOf(Function)]u8 = @splat(0);
    @memcpy(data[0x00..][0..14], first ++ "\x00");
    @memcpy(data[0x10..][0..8], "Testing\x00");
    @memcpy(data[0x18..][0..5], "Ship\x00");
    @memcpy(data[0x20..][0..4], "Fly\x00");
    var entries: [3]Function = @splat(std.mem.zeroes(Function));
    entries[0].entry = .{ .implementation = @fromBackingInt(0x11000) };
    entries[0].name = @fromBackingInt(base);
    entries[0].description = @fromBackingInt(base + 0x10);
    entries[0].argument_count = 1;
    entries[0].params[0] = .{ .kinds = .{ .ship = true }, .extra = 0, .label = @fromBackingInt(base + 0x18) };
    entries[1].entry = .{ .implementation = @fromBackingInt(0x11010) };
    entries[1].name = @fromBackingInt(base + 0x20);
    @memcpy(data[0x40..], std.mem.sliceAsBytes(&entries));

    const executable: xbe.Executable = try .parse(try xbe.testing.build(arena, 0x10000, base, &data));
    try std.testing.expectEqual(base + 0x40, find(executable));
    const commands = try read(arena, executable);
    try std.testing.expectEqual(2, commands.len);
    try std.testing.expectEqualStrings(first, commands[0].name);
    try std.testing.expectEqualStrings("Ship", commands[0].params[0].label);
    try std.testing.expect(commands[0].params[0].kinds.ship);
    try std.testing.expectEqualStrings("Testing", commands[0].description);
    try std.testing.expectEqualStrings("Fly", commands[1].name);
    try std.testing.expectEqualStrings("", commands[1].description);
    try std.testing.expectEqualSlices(u8, "Fly", (try names(arena, commands))[1]);
}
