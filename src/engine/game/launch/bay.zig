//! A ship's launch from a hangar bay (`launch_bay_init`, `0x0041A610`, and `launch_bay_run`,
//! `0x0041A9C0`): from the Victorious, the Endeavour, the Mitchells, the Bremen, the Ramases, the
//! Pukov, the Kronstadt, the Krasnaya, the Varyag, the Kiev, and the rogue base from its seventh
//! gate on. The ship waits at one of its carrier's launch points. Then the bay's doors open and the
//! ship flies out. The doors close behind it unless another ship is still on its way out through
//! them, and the ship flies on by itself.

const std = @import("std");

const math = @import("../../surrender/math.zig");
const aigeneric = @import("../aigeneric.zig");
const create = @import("../create.zig");
const gameobj = @import("../gameobj.zig");
const objects = @import("../objects.zig");
const shp = @import("../../../formats/shp.zig");
const sound3d = @import("../sound3d.zig");
const launch = @import("../launch.zig");

/// A launch's steps from a bay, after `launch.Step`'s two.
pub const Step = enum(i32) {
    /// The doors open.
    open = 2,
    /// The ship lets go of its carrier and flies out.
    out = 3,
    /// The doors close, unless another ship is still on its way out through them.
    close = 4,
    /// The ship flies itself, and the launch ends.
    end = 5,
    _,
};

/// How long the doors take to open before the ship flies out, in ticks (`0x0041A9FE`).
const open_ticks = 200;

/// How long the ship flies out before the doors close, in ticks (`0x0041AACB`), and from the
/// Pukov and the Varyag (`0x0041AADB`).
const out_ticks = 200;
const long_out_ticks = 400;

/// How long after the doors close the ship flies itself, in ticks (`0x0041AC4A`).
const close_ticks = 300;

/// The throttle the ship flies out at (`0x0041AAF2`).
const out_throttle: f32 = 2;

/// The pitch input a ship flying out of the Pukov or the Varyag takes for the last
/// `climb_ticks` of its way out (`0x0041AB42`, `0x0041AB3B`).
const climb_input: f32 = 0.1;
const climb_ticks = 100;

/// The track the doors play (`0x004E1728`), forward from where it stands to open them and back to
/// close them, at `door_speed` (`0x0041AA0A`, `0x0041ABD8`).
pub const door_track = objects.door_track;
pub const door_speed: f32 = 4;

/// The doors a bay's gate opens: up to two parts of the carrier's root's child list, which the game
/// keeps as nodes in the launch's state (`launch.State.doors`). Their sound plays at the first.
pub const Doors = struct {
    first: ?u8 = null,
    second: ?u8 = null,

    fn pair(first: u8, second: u8) Doors {
        return .{ .first = first, .second = second };
    }

    /// The doors of gate `gate` on a carrier of type `carrier` (`launch_bay_init`, its switch at
    /// `0x0041A667`). A carrier or a gate that the table doesn't list has none: the Mitchell
    /// (`0x13`), the Ramases, the Kronstadt, the other Ramases and the rogue base among them.
    pub fn of(carrier: gameobj.Type, gate: i16) Doors {
        return switch (carrier) {
            .victorious, .other_mitchell => switch (gate) {
                0 => .pair(3, 4),
                1 => .pair(5, 6),
                2 => .pair(7, 8),
                3 => .pair(9, 10),
                else => .{},
            },
            .endeavour => switch (gate) {
                0 => .pair(13, 14),
                1 => .pair(15, 16),
                2 => .pair(19, 20),
                3 => .pair(17, 18),
                else => .{},
            },
            .bremen => switch (gate) {
                0 => .pair(6, 7),
                1 => .pair(4, 5),
                else => .{},
            },
            .pukov, .varyag => switch (gate) {
                0, 1 => .{ .first = 15 },
                2, 3 => .{ .first = 16 },
                else => .{},
            },
            .krasnaya => switch (gate) {
                0 => .{ .first = 3 },
                1 => .{ .first = 4 },
                2 => .{ .first = 5 },
                else => .{},
            },
            .kiev => switch (gate) {
                0 => .{ .first = 8 },
                1 => .{ .second = 7 },
                else => .{},
            },
            else => .{},
        };
    }

    /// The doors of the launch of the ship in `slot`, whose order's target names its carrier and
    /// its gate.
    fn ofLaunch(all: *const create.Objects, slot: *const create.Slot) Doors {
        const target = slot.orders[0].target;
        const carrier = target.slotIn(all) orelse return .{};
        return .of(all.slots[carrier].object.type, target.component);
    }
};

/// Whether the carrier the ship flies out of is the Pukov or the Varyag, whose ships fly out for
/// longer, climbing at the end (`0x0041AAB9`, `0x0041AB25`).
fn longBay(carrier: gameobj.Type) bool {
    return carrier == .pukov or carrier == .varyag;
}

/// `launch_bay_init` (`0x0041A610`): places the ship in slot `index` at the launch point of the
/// carrier in slot `carrier` for its gate (`launch.attachAtGate`), riding the part that holds it.
/// The game then keeps the gate's doors in the launch's state (`Doors.of`).
pub fn init(ctx: aigeneric.Context, index: u16, carrier: u16) void {
    launch.attachAtGate(ctx, index, carrier);
}

/// `launch_bay_run` (`0x0041A9C0`): the launch of the ship in slot `index` from step 2 on.
///
/// 1. The gate's doors open, with the `dooropen` sound at the first door. `open_ticks` later, the
///    ship lets go of its carrier and flies out along its nose at `out_throttle`
///    (`motion.Motion.plain`), starting with its carrier's velocity.
/// 2. After `out_ticks`, the doors close, with the `doorclos` sound. From the Pukov or the Varyag
///    this takes `long_out_ticks`, and the ship climbs with a pitch input of `climb_input` for the
///    last `climb_ticks`. The doors stay open while another ship launches from the same carrier
///    through the same doors, from its delay until it closes them itself.
/// 3. After `close_ticks`, the ship flies itself (`motion.Motion.forward`) with its throttle and
///    inputs set to 0, and the launch lets it go (`launch.letGo`).
///
/// **Fix:** when the carrier's model lacks a door part, the game reads past the end of its root's
/// child list. OpenReliant skips that door.
pub fn run(ctx: aigeneric.Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.launch;
    const now = ctx.world.clock.frame_start;
    const carrier = slot.orders[0].target.slotIn(all) orelse return launch.letGo(ctx, index);
    const carrier_slot = &all.slots[carrier];
    switch (state.step.as(Step)) {
        .open => {
            state.advance(.of(Step.out), now, open_ticks);
            playDoors(ctx.world, carrier_slot, Doors.ofLaunch(all, slot), .open);
        },
        .out => if (state.due < now) {
            slot.object.velocity = carrier_slot.object.velocity;
            state.advance(.of(Step.close), now, if (longBay(carrier_slot.object.type)) long_out_ticks else out_ticks);
            slot.object.throttle = out_throttle;
            state.attached = false;
            slot.motion = .plain;
        },
        .close => {
            if (longBay(carrier_slot.object.type) and state.due < now + climb_ticks) slot.object.pitch_input = climb_input;
            if (state.due >= now) return;
            const doors = Doors.ofLaunch(all, slot);
            if (!doorsInUse(all, index, doors)) playDoors(ctx.world, carrier_slot, doors, .close);
            state.advance(.of(Step.end), now, close_ticks);
            slot.object.pitch_input = 0;
        },
        .end => if (state.due < now) {
            slot.object.letGo();
            slot.motion = .forward;
            launch.letGo(ctx, index);
        },
        _ => {},
    }
}

/// Which way the doors go.
const Way = enum { open, close };

/// Plays the track of the doors `doors` of the carrier in `carrier`: forward from where it stands
/// to open them, backwards to close them. The sound plays at the first door.
fn playDoors(world: gameobj.World, carrier: *create.Slot, doors: Doors, way: Way) void {
    const model = if (carrier.model) |*live| live else return;
    const speed: f32 = switch (way) {
        .open => door_speed,
        .close => -door_speed,
    };
    for ([_]?u8{ doors.first, doors.second }, 0..) |door, which| {
        const part = door orelse continue;
        const shown = model.rootChild(part) orelse continue;
        model.playNamed(part, door_track, objects.Model.keep_time, .once, speed);
        if (which == 0) sound3d.playFrom(world, shown.drawn(), switch (way) {
            .open => .dooropen,
            .close => .doorclos,
        }, .not_reserved);
    }
}

/// Whether another ship launches from the same carrier as the ship in slot `index` through the
/// same `doors`, from its delay until it closes them itself (`0x0041AB5D` on): its current order
/// is Launch, aimed at the same carrier, in a bay's style, at step 1 to 4.
fn doorsInUse(all: *const create.Objects, index: u16, doors: Doors) bool {
    const carrier = all.slots[index].orders[0].target.index;
    for (all.slots[0..all.count], 0..) |*other, other_index| {
        if (other_index == index) continue;
        const entry = other.current() orelse continue;
        if (entry.order != .launch or entry.target.index != carrier) continue;
        const state = other.state.launch;
        if (state.style != .bay or !std.meta.eql(Doors.ofLaunch(all, other), doors)) continue;
        const step = @intFromEnum(state.step);
        if (step > @intFromEnum(launch.Step.waiting) and step <= @intFromEnum(Step.close)) return true;
    }
    return false;
}

/// A Bremen's model for the tests: its gates' doors, parts 4 to 7 of its root's child list, each
/// with the doors' track, and its two launch points on part 1, which are gates 0 and 1.
const testing = struct {
    const Bremen = struct {
        attachments: [2]shp.Attachment,
        tracks: [1]shp.Track,
        parts: objects.testing.Parts(8),

        fn init(bremen: *Bremen) void {
            for (&bremen.attachments, 0..) |*attachment, n| {
                attachment.* = std.mem.zeroes(shp.Attachment);
                attachment.kind = .launch_point;
                attachment.position = .{ .x = 0, .y = 0, .z = @floatFromInt(100 * (n + 1)) };
                attachment.orientation = math.identity;
            }
            bremen.tracks = .{.{ .clip = objects.testing.clip(100, .once, door_track), .keyframes = &.{}, .events = &.{} }};
            bremen.parts.init();
            bremen.parts.data[1].attachments = &bremen.attachments;
            for (bremen.parts.data[4..8]) |*door| door.tracks = &bremen.tracks;
        }
    };

    /// A mission with the player's ship, a Bremen and two Wolverines that launch from its gates 0
    /// and `second_gate`.
    const Bay = struct {
        mission: gameobj.testing.Mission,
        bremen_model: Bremen,
        bremen: u16,
        first: u16,
        second: u16,

        fn init(bay: *Bay, gpa: std.mem.Allocator, second_gate: u16) !void {
            try bay.mission.init(gpa);
            errdefer bay.mission.deinit();
            bay.bremen_model.init();
            _ = try bay.mission.add(.predator, @splat(0));
            bay.bremen = try bay.mission.add(.bremen, .{ 0, 0, 10000 });
            try bay.bremen_model.parts.fit(gpa, bay.mission.slot(bay.bremen));
            bay.first = try bay.mission.add(.wolverine, @splat(0));
            bay.second = try bay.mission.add(.wolverine, @splat(0));
            const ctx = bay.mission.orders();
            for ([_]u16{ bay.first, bay.second }, [_]u16{ 0, second_gate }) |ship, gate| {
                _ = try aigeneric.pushShip(ctx, ship, .launch, bay.bremen, gate);
                aigeneric.objectOrders(ctx, ship);
            }
        }

        fn deinit(bay: *Bay) void {
            bay.mission.deinit();
        }

        /// The track speed of the Bremen's part `part`.
        fn doorSpeed(bay: *Bay, part: usize) f32 {
            return bay.mission.slot(bay.bremen).model.?.parts[part].animation.speed;
        }
    };
};

test "Doors.of" {
    try std.testing.expectEqual(Doors{ .first = 6, .second = 7 }, Doors.of(.bremen, 0));
    try std.testing.expectEqual(Doors{ .first = 4, .second = 5 }, Doors.of(.bremen, 1));
    try std.testing.expectEqual(Doors{}, Doors.of(.bremen, 2));
    try std.testing.expectEqual(Doors{ .first = 19, .second = 20 }, Doors.of(.endeavour, 2));
    // The Pukov's first two gates share a door, and the Kiev's second gate opens only its second.
    try std.testing.expectEqual(Doors.of(.pukov, 0), Doors.of(.pukov, 1));
    try std.testing.expectEqual(Doors{ .second = 7 }, Doors.of(.kiev, 1));
    // The Mitchell has none, unlike the other Mitchell.
    try std.testing.expectEqual(Doors{}, Doors.of(.mitchell, 0));
    try std.testing.expectEqual(Doors{ .first = 3, .second = 4 }, Doors.of(.other_mitchell, 0));
}

test "a ship launches out of a bay, its doors opening and closing behind it" {
    var bay: testing.Bay = undefined;
    try bay.init(std.testing.allocator, 1);
    defer bay.deinit();
    const ctx = bay.mission.orders();
    const slot = bay.mission.slot(bay.first);
    const state = &slot.state.launch;
    try std.testing.expectEqual(launch.Style.bay, state.style);
    // It waits at gate 0, the point 100 along the launch points' part, riding it.
    try std.testing.expect(state.attached);
    try std.testing.expectEqual(bay.bremen, slot.riding.?.object);

    // Started, past its delay, the gate's doors open.
    launch.start(bay.mission.objects, bay.first);
    aigeneric.objectOrders(ctx, bay.first);
    launch.testing.pastDue(&bay.mission, ctx, bay.first);
    try std.testing.expectEqual(Step.out, state.step.as(Step));
    try std.testing.expectEqual(door_speed, bay.doorSpeed(6));
    try std.testing.expectEqual(door_speed, bay.doorSpeed(7));
    try std.testing.expectEqual(0, bay.doorSpeed(4));

    // Once they're open, it lets go and flies out with the Bremen's velocity.
    bay.mission.slot(bay.bremen).object.velocity = .{ .x = 0, .y = 0, .z = 5 };
    launch.testing.pastDue(&bay.mission, ctx, bay.first);
    try std.testing.expectEqual(Step.close, state.step.as(Step));
    try std.testing.expect(!state.attached);
    try std.testing.expectEqual(.plain, slot.motion.?);
    try std.testing.expectEqual(out_throttle, slot.object.throttle);
    try std.testing.expectEqual(5, slot.object.velocity.z);

    // The doors close behind it, and later it flies itself, its launch over.
    launch.testing.pastDue(&bay.mission, ctx, bay.first);
    try std.testing.expectEqual(-door_speed, bay.doorSpeed(6));
    try std.testing.expectEqual(Step.end, state.step.as(Step));
    launch.testing.pastDue(&bay.mission, ctx, bay.first);
    try std.testing.expectEqual(.forward, slot.motion.?);
    try std.testing.expectEqual(0, slot.object.throttle);
    try std.testing.expect(launch.testing.ended(slot));
    try std.testing.expectEqual(null, slot.riding);
}

test "a bay's doors stay open while another ship launches through them" {
    var bay: testing.Bay = undefined;
    try bay.init(std.testing.allocator, 0);
    defer bay.deinit();
    const ctx = bay.mission.orders();
    const doors = Doors.of(.bremen, 0);
    // The second ship, through the same doors, has yet to start: it doesn't hold them open.
    try std.testing.expect(!doorsInUse(bay.mission.objects, bay.first, doors));
    // Once it has started, it does.
    launch.start(bay.mission.objects, bay.second);
    aigeneric.objectOrders(ctx, bay.second);
    try std.testing.expect(doorsInUse(bay.mission.objects, bay.first, doors));
    // Doors elsewhere on the Bremen are free.
    try std.testing.expect(!doorsInUse(bay.mission.objects, bay.first, Doors.of(.bremen, 1)));
}
