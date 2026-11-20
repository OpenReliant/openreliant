//! Bounded views of mission objects. A page covers the same slots for the whole session.
const std = @import("std");
const game = @import("openreliant").engine.game;
const wire = @import("wire.zig");
const Page = @This();

const Mask = u16;
pub const width = @bitSizeOf(Mask);
pub const count = std.math.divCeil(usize, game.gameobj.max_objects, width) catch unreachable;
pub const capacity = @sizeOf(u8) + @sizeOf(u32) + @sizeOf(u8) + @sizeOf(Mask) + width * Pose.capacity;

tick: u32,
number: u8,
objects: [width]?Pose = @splat(null),

const Pose = struct {
    const capacity = @sizeOf(u32) + @sizeOf(u16) + 3 * @sizeOf(f32) + @sizeOf(wire.Facing) + @sizeOf(u8);
    reuse: u32,
    kind: game.gameobj.Type,
    position: [3]f32,
    angles: wire.Facing,
    flags: Flags,
};

const Flags = packed struct(u8) {
    targetable: bool,
    exploding: bool,
    reserved: u6 = 0,
};

pub fn first(page: *const Page) usize {
    return @as(usize, page.number) * width;
}

pub fn capture(all: *const game.create.Objects, tick: u32, number: u8) Page {
    var page: Page = .{ .tick = tick, .number = number };
    for (&page.objects, page.first()..) |*entry, slot| {
        // The pilot snapshot already carries the occupied pilot slots.
        if (slot < all.players or slot >= all.count) continue;
        const object = &all.slots[slot].object;
        if (!object.created or object.flags.outOfFrame() or object.flags.hidden) continue;
        entry.* = .{
            .reuse = all.reuses[slot],
            .kind = object.type,
            .position = object.nextPosition(),
            .angles = wire.packFacing(object.root.next_orientation),
            .flags = .{ .targetable = object.flags.targetable, .exploding = object.flags.exploding },
        };
    }
    return page;
}

pub fn mask(page: *const Page) Mask {
    var found: Mask = 0;
    for (page.objects, 0..) |entry, slot| {
        if (entry != null) found |= bit(slot);
    }
    return found;
}

fn bit(slot: usize) Mask {
    return @as(Mask, 1) << @as(std.math.Log2Int(Mask), @intCast(slot));
}

pub fn write(page: *const Page, writer: *std.Io.Writer) !void {
    try writer.writeInt(u32, page.tick, .little);
    try writer.writeByte(page.number);
    try writer.writeInt(Mask, page.mask(), .little);
    for (page.objects) |entry| {
        const object = entry orelse continue;
        try writer.writeInt(u32, object.reuse, .little);
        if (object.kind.number() >= game.create.ship_type_count) return error.InvalidScenePage;
        try writer.writeInt(u16, @intCast(object.kind.number()), .little);
        for (object.position) |axis| try writer.writeInt(u32, @bitCast(axis), .little);
        for (object.angles) |angle| try writer.writeInt(i16, angle, .little);
        try writer.writeByte(@bitCast(object.flags));
    }
}

pub fn read(reader: *std.Io.Reader) !Page {
    var page: Page = .{ .tick = try reader.takeInt(u32, .little), .number = try reader.takeByte() };
    if (page.tick == 0 or page.number >= count) return error.InvalidScenePage;
    const present = try reader.takeInt(Mask, .little);
    for (&page.objects, 0..) |*entry, slot| {
        if (present & bit(slot) == 0) continue;
        if (page.first() + slot >= game.gameobj.max_objects) return error.InvalidScenePage;
        const reuse = try reader.takeInt(u32, .little);
        const kind = try reader.takeInt(u16, .little);
        if (kind >= game.create.ship_type_count) return error.InvalidScenePage;
        var position: [3]f32 = undefined;
        for (&position) |*axis| {
            axis.* = @bitCast(try reader.takeInt(u32, .little));
            if (!std.math.isFinite(axis.*)) return error.InvalidScenePage;
        }
        var angles: wire.Facing = undefined;
        for (&angles) |*angle| angle.* = try reader.takeInt(i16, .little);
        const flags: Flags = @bitCast(try reader.takeByte());
        if (flags.reserved != 0) return error.InvalidScenePage;
        entry.* = .{ .reuse = reuse, .kind = @fromBackingInt(kind), .position = position, .angles = angles, .flags = flags };
    }
    return page;
}

/// Keeps host reuse counts separate from local object references used by the HUD and scripts.
pub const Replica = struct {
    ticks: [count]u32 = @splat(0),
    reuses: [game.gameobj.max_objects]?u32 = @splat(null),

    pub fn apply(replica: *Replica, world: game.gameobj.World, page: *const Page) !void {
        const applied = &replica.ticks[page.number];
        if (page.tick <= applied.*) return;
        const spawn = world.spawn orelse return error.MissingSceneModels;
        const all = world.objects;
        for (page.objects, page.first()..) |entry, index| {
            if (index < all.players or index >= all.slots.len) continue;
            const slot: u16 = @intCast(index);
            const current = &replica.reuses[slot];
            if (current.* != null and (entry == null or current.* != entry.?.reuse)) {
                game.create.resetSlot(.of(world), slot);
                current.* = null;
            }
            const seen = entry orelse continue;
            if (current.* == null) {
                _ = try game.create.createObject(all, spawn.tables, spawn.types, slot, seen.kind, 0, seen.position, world.random);
                all.count = @max(all.count, slot + 1);
                current.* = seen.reuse;
            }
            const shown = &all.slots[slot];
            game.objects.setPlace(&shown.object, &shown.drawn, .{ .position = seen.position, .orientation = wire.unpackFacing(seen.angles) });
            shown.object.flags.targetable = seen.flags.targetable;
            shown.object.flags.exploding = seen.flags.exploding;
            if (shown.model) |*model| model.place(shown.drawn.position, shown.drawn.orientation);
        }
        applied.* = page.tick;
    }
};

test "scene pages preserve a reused slot's new identity" {
    var mission: game.gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    mission.objects.players = 1;
    mission.objects.count = width;
    const slot = try mission.add(.of(.predator), .{ 100, 200, 300 });
    const previous = capture(mission.objects, 1, 1);
    game.create.resetSlot(mission.orders(), slot);
    _ = try game.create.createObject(mission.objects, &mission.tables, game.create.testing.no_models, slot, .of(.shroud), 0, .{ 500, 600, 700 }, &mission.random);
    const next = capture(mission.objects, 2, 1);
    try std.testing.expect(next.objects[0].?.reuse != previous.objects[0].?.reuse);
    var buffer: [capacity]u8 = undefined;
    const message: wire.Message = .{ .scene_page = next };
    const received = try wire.Message.decode(try message.encode(&buffer));
    try std.testing.expectEqualDeep(next, received.scene_page);

    var display: game.gameobj.testing.Mission = undefined;
    try display.init(std.testing.allocator);
    defer display.deinit();
    var world = display.world();
    world.spawn = display.spawn(game.create.testing.no_models);
    var replica: Replica = .{};
    try replica.apply(world, &previous);
    const first_ship_ref: game.gameobj.ObjectRef = .of(display.objects, slot);
    try replica.apply(world, &received.scene_page);
    try replica.apply(world, &previous);
    try std.testing.expectEqual(null, first_ship_ref.resolve(display.objects));
    try std.testing.expectEqual(game.gameobj.Type.of(.shroud), display.slot(slot).object.type);
    try std.testing.expectEqual(next.objects[0].?.position, display.slot(slot).object.nextPosition());

    const empty: Page = .{ .tick = 3, .number = next.number };
    try replica.apply(world, &empty);
    try replica.apply(world, &next);
    try std.testing.expectEqual(null, replica.reuses[slot]);
    try std.testing.expect(!display.slot(slot).object.created);
}
