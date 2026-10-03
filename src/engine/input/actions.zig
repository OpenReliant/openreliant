//! Mod actions kept separately from the original control catalogue (#617). Names, not indices,
//! identify bindings across reloads. The controls list's byte-sized row count bounds this registry.
const std = @import("std");
const input = @import("../input.zig");
const controls = input.controls;

pub const max_actions = std.math.maxInt(u8) - controls.list.len - 1;
/// Storage includes the terminator. Labels are UTF-8 before conversion for the original font.
pub const name_size = 128;
pub const label_size = 128;

pub const Entry = struct {
    name: [name_size]u8 = @splat(0),
    label: [label_size]u8 = @splat(0),
    owner: ?*anyopaque = null,
    /// Changes whenever the slot is registered again, even by the same context.
    generation: u64 = 0,
    default: controls.Binding,
    gamepad_button: ?u8 = null,
    binding: controls.Binding,
    held: bool = false,
    /// A new registration must see release before it emits a press.
    ready: bool = false,

    pub fn nameOf(entry: *const Entry) []const u8 {
        return std.mem.sliceTo(&entry.name, 0);
    }
    pub fn labelOf(entry: *const Entry) []const u8 {
        return std.mem.sliceTo(&entry.label, 0);
    }
};

pub const Registry = struct {
    entries: [max_actions]Entry = undefined,
    count: usize = 0,
    generation: u64 = 0,

    pub const Error = error{ DuplicateName, TooMany, NameTooLong, InvalidText };

    pub fn find(registry: *const Registry, name: []const u8) ?usize {
        for (registry.entries[0..registry.count], 0..) |*entry, index| {
            // Profile keys are case-insensitive, so identity uses the same comparison.
            if (entry.owner != null and std.ascii.eqlIgnoreCase(entry.nameOf(), name)) return index;
        }
        return null;
    }

    pub fn add(registry: *Registry, owner: *anyopaque, name: []const u8, label: []const u8, default: controls.Binding) Error!usize {
        if (name.len >= name_size or label.len >= label_size) return error.NameTooLong;
        if (name.len == 0 or label.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null or std.mem.indexOfScalar(u8, label, 0) != null) return error.InvalidText;
        if (registry.find(name) != null) return error.DuplicateName;
        const index = for (registry.entries[0..registry.count], 0..) |*entry, at| {
            if (entry.owner == null and std.ascii.eqlIgnoreCase(entry.nameOf(), name)) break at;
        } else for (registry.entries[0..registry.count], 0..) |entry, at| {
            if (entry.owner == null) break at;
        } else blk: {
            if (registry.count == max_actions) return error.TooMany;
            defer registry.count += 1;
            break :blk registry.count;
        };
        const entry = &registry.entries[index];
        registry.generation += 1;
        entry.* = .{ .owner = owner, .generation = registry.generation, .default = default, .binding = default };
        @memcpy(entry.name[0..name.len], name);
        @memcpy(entry.label[0..label.len], label);
        return index;
    }

    pub fn removeOwner(registry: *Registry, owner: *anyopaque) void {
        registry.removeSince(owner, 0);
    }

    pub fn removeSince(registry: *Registry, owner: *anyopaque, generation: u64) void {
        for (registry.entries[0..registry.count]) |*entry| if (entry.owner == owner and entry.generation > generation) {
            entry.owner = null;
            entry.held = false;
            entry.ready = false;
        };
    }

    pub fn liveCount(registry: *const Registry) usize {
        var count: usize = 0;
        for (registry.entries[0..registry.count]) |entry| count += @intFromBool(entry.owner != null);
        return count;
    }

    pub fn rowCount(registry: *const Registry) u8 {
        const live = registry.liveCount();
        return @intCast(controls.list.len + live + @intFromBool(live != 0));
    }

    pub fn liveIndex(registry: *const Registry, row: usize) ?usize {
        var seen: usize = 0;
        for (registry.entries[0..registry.count], 0..) |entry, index| {
            if (entry.owner == null) continue;
            if (seen == row) return index;
            seen += 1;
        }
        return null;
    }

    /// Only registrations owned by a live script can activate. Edge state resets out of flight.
    pub fn pressed(registry: *Registry, index: usize, devices: *input.Devices, flying: bool) bool {
        const entry = &registry.entries[index];
        const down = entry.owner != null and flying and devices.bindingActive(entry.binding, false);
        const pressed_ = down and entry.ready and !entry.held;
        if (!flying) entry.ready = false else if (!down) entry.ready = true;
        entry.held = down;
        return pressed_;
    }
};

test "named actions isolate mods, reuse closed slots and suppress held registration presses" {
    var registry: Registry = .{};
    var a: u8 = 0;
    var b: u8 = 0;
    const default: controls.Binding = .{ .name = "", .string = 0, .key = @intFromEnum(input.Key.k), .modifier = .shift, .button = null };
    const first = try registry.add(&a, "a:pulse", "Pulse A", default);
    _ = try registry.add(&b, "b:pulse", "Pulse B", default);
    try std.testing.expectError(error.DuplicateName, registry.add(&b, "a:pulse", "Duplicate", default));
    try std.testing.expectError(error.DuplicateName, registry.add(&b, "A:Pulse", "Case collision", default));
    var devices: input.Devices = .{};
    devices.keyboard.down[@intFromEnum(input.Key.k)] = true;
    devices.keyboard.down[input.scan.left_shift] = true;
    try std.testing.expect(!registry.pressed(first, &devices, true));
    devices.keyboard.down[@intFromEnum(input.Key.k)] = false;
    try std.testing.expect(!registry.pressed(first, &devices, true));
    devices.keyboard.down[@intFromEnum(input.Key.k)] = true;
    try std.testing.expect(registry.pressed(first, &devices, true));
    try std.testing.expect(!registry.pressed(first, &devices, true));
    try std.testing.expect(!registry.pressed(first, &devices, false));
    try std.testing.expect(!registry.pressed(first, &devices, true));
    registry.removeOwner(&a);
    try std.testing.expectEqual(null, registry.find("a:pulse"));
    try std.testing.expectEqual(1, registry.liveCount());
    const old_generation = registry.entries[first].generation;
    try std.testing.expectEqual(first, try registry.add(&a, "a:pulse", "Reloaded", default));
    try std.testing.expect(registry.entries[first].generation != old_generation);
    try std.testing.expect(!registry.pressed(first, &devices, true));
    devices.keyboard.down = @splat(false);
    registry.entries[first].binding.button = 3;
    devices.joystick.buttons = 4;
    devices.joystick.state.buttons[3] = 0;
    try std.testing.expect(!registry.pressed(first, &devices, true));
    devices.joystick.state.buttons[3] = 0x80;
    try std.testing.expect(registry.pressed(first, &devices, true));
    const checkpoint = registry.generation;
    const added = try registry.add(&a, "a:later", "Later", default);
    registry.removeSince(&a, checkpoint);
    try std.testing.expectEqual(null, registry.entries[added].owner);
    try std.testing.expectEqual(first, registry.find("a:pulse").?);
}
