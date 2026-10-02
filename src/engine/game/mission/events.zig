//! The mission's events (`mission.cpp`). The game's code posts each as it happens, where a trigger
//! would answer it (`vm.triggers.wouldFire`), to the queue that the frame then raises on the
//! script's triggers (`event_post`, `event_post_group`, `events_flush`); the routines here post
//! each kind. Once a second the watches of the proximity conditions look for ships close by.
//! [docs/engine/script-vm.md](../../../../docs/engine/script-vm.md#events) describes them.
//!
//! **Unverified:** the queue's own routines (`0x0045B690` to `0x0045B840`) lie past this file's
//! known code, before the interpreter's; they do its queue's work.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.mission);

const dte = @import("../../../formats/dte.zig");
const math = @import("../../surrender/math.zig");
const vm = @import("../../vm.zig");
const gameobj = @import("../gameobj.zig");
const bind = @import("bind.zig");

const triggers = vm.triggers;
const Event = triggers.Event;

/// The events waiting for the frame, and the watches of the proximity conditions.
pub const Events = struct {
    gpa: Allocator,
    /// The script whose triggers the events are raised on.
    script: *vm.Machine,
    /// `event_queue` (`0x0052ABD8`), `count` of them waiting (`event_queue_count`, `0x005373E4`).
    waiting: [capacity]Queued = undefined,
    count: usize = 0,
    /// `0x00545860`: set while a collision's test against a hull runs again, which holds back the
    /// ShotAt of the knocks it deals (`objects_collide`).
    shots_held: bool = false,
    /// Whether an event past the queue's room has been logged.
    overflowed: bool = false,
    /// The watches of CloseProximity, Proximity and ShipReached.
    watches: std.EnumArray(Watched, []Watch) = .initFill(&.{}),

    /// The events the queue has room for, past which the game stops (`0x0045B330`).
    pub const capacity = 1000;

    /// The queue of a mission that starts, empty (`init_mission`, `0x0045A4E0`), for `script`.
    pub fn init(gpa: Allocator, script: *vm.Machine) Events {
        return .{ .gpa = gpa, .script = script };
    }

    pub fn deinit(events: *Events) void {
        for (&events.watches.values) |list| events.gpa.free(list);
        events.watches = .initFill(&.{});
    }

    /// `event_post` (`0x0045B7C0`): queues `event` on the mission's ship `ship`, where one of the
    /// ship's own triggers would answer it.
    pub fn post(events: *Events, ship: u16, event: Event) void {
        const object = events.objectOf(ship) orelse return;
        if (!triggers.wouldFire(events.script, object, event)) return;
        events.take(false, ship, event);
    }

    /// `event_post_group` (`0x0045B690`): queues `event` on the mission's ship `ship`, to be raised
    /// on its flight group and on the squads that hold it too, where a trigger would answer it:
    /// the ship's own, or one of the groups' it goes on to (`vm.triggers.groupsOf`), in that
    /// order. A group's triggers answer the event as one on the group itself (`Event.onGroup`).
    pub fn postGroup(events: *Events, ship: u16, event: Event) void {
        if (!events.anyWouldFire(ship, event)) return;
        events.take(true, ship, event);
    }

    fn anyWouldFire(events: *Events, ship: u16, event: Event) bool {
        const machine = events.script;
        if (events.objectOf(ship)) |object| if (triggers.wouldFire(machine, object, event)) return true;
        var groups = triggers.groupsOf(machine, ship, event.qualifier);
        while (groups.next()) |group| {
            if (triggers.wouldFire(machine, group.object, event.onGroup())) return true;
        }
        return false;
    }

    /// Takes `event` on the ship `ship` into the queue, once `0x0045B330` has looked at its room.
    ///
    /// **Fix:** the game stops with the assertion "Trigger List exceeded" once a thousand events
    /// wait, listing them first; OpenReliant passes over each event past them, and logs it once.
    fn take(events: *Events, groups: bool, ship: u16, event: Event) void {
        if (events.count >= capacity) {
            if (!events.overflowed) log.warn("more than {d} events in a frame; the rest are passed over", .{capacity});
            events.overflowed = true;
            return;
        }
        const count = @min(event.values.len, vm.QueuedEvent.max_values);
        var queued: Queued = .{ .groups = groups, .ship = ship, .condition = event.condition, .qualifier = event.qualifier, .count = @intCast(count) };
        @memcpy(queued.values[0..count], event.values[0..count]);
        events.waiting[events.count] = queued;
        events.count += 1;
    }

    /// `events_flush` (`0x0045B840`), once a frame from `mission_frame`, before the script runs:
    /// each event waiting, in turn, is raised on its ship's object (`vm.triggers.raise`) and, where
    /// it was posted for them, on the ship's flight group and squads
    /// (`vm.triggers.raiseOnGroups`). An event that a trigger's thread posts as it runs at once
    /// waits its turn in the same pass. Then the queue is empty.
    pub fn flush(events: *Events) void {
        const machine = events.script;
        var at: usize = 0;
        while (at < events.count) : (at += 1) {
            const queued = &events.waiting[at];
            if (machine.mission.ship(queued.ship) == null) continue;
            const event: Event = .{ .condition = queued.condition, .qualifier = queued.qualifier, .values = queued.values[0..queued.count] };
            triggers.raise(machine, events.objectOf(queued.ship), event);
            if (queued.groups) triggers.raiseOnGroups(machine, queued.ship, event);
        }
        events.count = 0;
    }

    /// The object ID of the mission's ship `ship`, which its triggers are held by: none past the
    /// mission's ships, or where the ID's low halfword is `no_object`.
    fn objectOf(events: *const Events, ship: u16) ?u16 {
        const record = events.script.mission.ship(ship) orelse return null;
        const id: u16 = @truncate(record.object_id);
        return if (id == no_object) null else id;
    }

    /// The object ID that names no object, on which `trigger_raise_event` raises no event
    /// (`0x0045CE70`).
    const no_object: u16 = 0xFFFF;

    /// The mission's ship the object in slot `index` stands for (`object_ship`, `0x0045A970`): a
    /// mission's ship takes the slot of its index, so the ship of the slot's index, and none past
    /// the mission's ships.
    fn shipOf(events: *const Events, index: u16) ?u16 {
        return if (events.script.mission.ship(index) != null) index else null;
    }

    /// What an event names the object in slot `index` by: where the record of the mission's ship
    /// it stands for lies, or `bind.Mission.no_place` for none.
    fn value(events: *const Events, index: ?u16) u32 {
        const ship = events.shipOf(index orelse return bind.Mission.no_place) orelse return bind.Mission.no_place;
        return events.script.mission.recordPlace(.ships, ship);
    }

    /// `0x0045AE10`, as the mission's tables are made (`mission_bind_tables`): a watch for each
    /// trigger of CloseProximity, Proximity and ShipReached, in the trigger list's order, on the
    /// object whose slice holds it, each armed. A trigger of the player's ship watches for the
    /// other players' ships too, with a watch on each of them.
    ///
    /// **Fix:** the game writes the lists into tables of a fixed size without looking at their
    /// room; OpenReliant makes them as long as the mission needs.
    pub fn watch(events: *Events, players: u16) !void {
        events.deinit();
        const file = events.script.mission.file;
        const all = try file.triggers();
        const ships = try file.ships();
        const owners = try file.triggerObjects(events.gpa);
        defer events.gpa.free(owners);
        for (std.enums.values(Watched)) |watched| {
            var list: std.ArrayList(Watch) = .empty;
            errdefer list.deinit(events.gpa);
            for (all, owners, 0..) |trigger, owner, index| {
                if (trigger.condition != watched.condition()) continue;
                try list.append(events.gpa, .{ .trigger = @intCast(index), .object = owner });
                if (!events.playersShip(owner)) continue;
                var other: usize = 1;
                while (other < players and other < ships.len) : (other += 1) {
                    try list.append(events.gpa, .{ .trigger = @intCast(index), .object = @truncate(ships[other].object_id) });
                }
            }
            events.watches.set(watched, try list.toOwnedSlice(events.gpa));
        }
    }

    /// Whether the object `object` is the player's ship, the mission's first.
    fn playersShip(events: *const Events, object: ?u16) bool {
        const id = object orelse return false;
        const record = events.script.mission.records[id] orelse return false;
        return switch (record) {
            .ship => |ship| ship == 0,
            else => false,
        };
    }

    /// `0x0045B2D0`: each watch of trigger `trigger` is armed, or not, as the script arms the
    /// trigger (`SetTriggerState`).
    pub fn arm(events: *Events, trigger: u16, armed: bool) void {
        for (&events.watches.values) |list| {
            for (list) |*each| {
                if (each.trigger == trigger) each.armed = armed;
            }
        }
    }

    /// `0x0045AF60`, once the script's clock has ticked, after the timers
    /// (`mission.Loaded.process`): the watches look for ships close by (`scan`), each on a mission's
    /// ship that is not destroyed and whose object is no stand-in, while the script has it armed.
    /// CloseProximity's look within `close_reach` of the ship's radii, once a ship; each of
    /// Proximity's within its trigger's distance, in the ship's radii; and ShipReached's, on a
    /// waypoint or a nav point, within `reached_reach`, once a ship.
    pub fn checkProximity(events: *Events, world: gameobj.World) void {
        const ships = events.script.mission.ships() catch return;
        const all = world.objects;
        const all_triggers = events.script.mission.file.triggers() catch return;
        for (std.enums.values(Watched)) |watched| {
            const list = events.watches.get(watched);
            if (list.len == 0) continue;
            for (ships, 0..) |ship, index| {
                if (ship.flags.destroyed or index >= all.slots.len) continue;
                const object = &all.slots[index].object;
                if (object.type == .stand_in) continue;
                const id: u16 = @truncate(ship.object_id);
                switch (watched) {
                    .close => {
                        if (firstArmed(list, id) == null) continue;
                        const reach = object.radius * close_reach;
                        const squared = reach * reach;
                        if (squared > 0) events.scan(world, @intCast(index), squared, .proximity_close);
                    },
                    .proximity => for (list) |each| {
                        if (each.object != id or !each.armed or each.trigger >= all_triggers.len) continue;
                        const distance = all_triggers[each.trigger].operands[proximity_operand];
                        if (@as(u16, @truncate(distance)) == dte.Reference.unset) continue;
                        const reach = @as(f32, @floatFromInt(distance)) * object.radius;
                        events.scan(world, @intCast(index), reach * reach, .proximity_general);
                    },
                    .reached => {
                        if (ship.kind != dte.Ship.waypoint_kind and ship.kind != dte.Ship.nav_point_kind) continue;
                        if (firstArmed(list, id) == null) continue;
                        events.scan(world, @intCast(index), reached_reach * reached_reach, .ship_reached);
                    },
                }
            }
        }
    }

    /// `0x0045B170`: each mission's ship but `subject`, not destroyed and whose object is no
    /// stand-in, whose object stands within the square root of `reach` of the subject's, has the
    /// subject's event posted for the subject's own triggers: for ShipReached, with the ship; for
    /// the proximity conditions, with the ship and how far it stands, in the subject's radii,
    /// truncated.
    fn scan(events: *Events, world: gameobj.World, subject: u16, reach: f32, condition: dte.Condition) void {
        const ships = events.script.mission.ships() catch return;
        const all = world.objects;
        const own = &all.slots[subject].object;
        for (ships, 0..) |ship, index| {
            if (ship.flags.destroyed or index == subject or index >= all.slots.len) continue;
            const other = &all.slots[index].object;
            if (other.type == .stand_in) continue;
            const apart = gameobj.vector(own.root.position) - gameobj.vector(other.root.position);
            const squared = apart * apart;
            const distance = squared[2] + squared[1] + squared[0];
            if (!(distance <= reach)) continue;
            var values = [_]u32{ events.script.mission.recordPlace(.ships, index), 0 };
            switch (condition) {
                .ship_reached => events.post(subject, .{ .condition = condition, .values = values[0..1] }),
                .proximity_close, .proximity_general => {
                    values[1] = @bitCast(math.ftol(@sqrt(distance) / own.radius));
                    events.post(subject, .{ .condition = condition, .values = &values });
                },
                else => {},
            }
        }
    }
};

/// An event waiting in the queue (`vm.QueuedEvent`).
const Queued = struct {
    /// Whether it goes on to its ship's flight group and the squads that hold it
    /// (`event_post_group`).
    groups: bool,
    /// The mission's ship it happened to.
    ship: u16,
    condition: dte.Condition,
    qualifier: u8,
    values: [vm.QueuedEvent.max_values]u32 = undefined,
    count: u8,
};

/// What the watches of each list watch for.
pub const Watched = enum {
    /// CloseProximity's (`0x00536DD8`): a ship within `close_reach` of the subject's radii.
    close,
    /// Proximity's (`0x00536758`): a ship within the trigger's distance, in the subject's radii.
    proximity,
    /// ShipReached's (`0x0052A5D0`): a ship within `reached_reach` of a waypoint or a nav point.
    reached,

    /// The condition of the triggers the list watches for.
    pub fn condition(watched: Watched) dte.Condition {
        return switch (watched) {
            .close => .proximity_close,
            .proximity => .proximity_general,
            .reached => .ship_reached,
        };
    }
};

/// A watch: a trigger of the watched condition, the object whose slice holds it, and whether the
/// script has it armed.
pub const Watch = struct {
    trigger: u16,
    /// The object's ID, or null where no slice holds the trigger, which watches for nothing.
    object: ?u16,
    armed: bool = true,
};

/// The first armed watch on the object `object`.
fn firstArmed(list: []const Watch, object: u16) ?Watch {
    for (list) |each| {
        if (each.object == object and each.armed) return each;
    }
    return null;
}

/// How far CloseProximity's watches look, in the subject's radii (`0x004DC72C`).
const close_reach: f32 = 20;

/// How far ShipReached's watches look (`0x4B742400`, its square).
const reached_reach: f32 = 4000;

/// The operand of a Proximity trigger that gives its distance, in the subject's radii.
const proximity_operand = 1;

/// What an event names no weapon by: ShotAt's weapon is always so.
const no_weapon: u32 = 0xFFFF_FFFF;

/// `event_launched` (`0x0045A9B0`): the object in slot `index` has launched. Its ship's Launched,
/// with the ship, goes on to its groups.
pub fn launched(world: gameobj.World, index: u16) void {
    postNaming(world, index, .launched, index);
}

/// `event_jumped_in` (`0x0045B300`): the object in slot `index` has jumped in (`jump.inUpdate`).
/// Its ship's JumpedIn, with the ship, goes on to its groups.
pub fn jumpedIn(world: gameobj.World, index: u16) void {
    postNaming(world, index, .jumped_in, index);
}

/// `event_fixed_gate_jumped_in` (`0x0045ABD0`): the object in slot `index` has come in through the
/// fixed gate in slot `gate` (`wgate.jumpIn`). Its ship's FixedGateJumpedIn, with the gate's ship,
/// goes on to its groups.
pub fn fixedGateJumpedIn(world: gameobj.World, index: u16, gate: u16) void {
    postNaming(world, index, .fixed_gate_jumped_in, gate);
}

/// The ship of the object in slot `index` posts `condition` with the ship of the object in slot
/// `named` as its value, which goes on to its groups; an object that stands for no mission's ship
/// posts nothing.
fn postNaming(world: gameobj.World, index: u16, condition: dte.Condition, named: u16) void {
    const events = world.events orelse return;
    const ship = events.shipOf(index) orelse return;
    var values = [_]u32{events.value(named)};
    events.postGroup(ship, .{ .condition = condition, .values = &values });
}

/// The ship of the object in slot `index` posts `condition`, with no values, for its own triggers;
/// an object that stands for no mission's ship posts nothing.
fn postOwn(world: gameobj.World, index: u16, condition: dte.Condition) void {
    const events = world.events orelse return;
    const ship = events.shipOf(index) orelse return;
    events.post(ship, .{ .condition = condition });
}

/// `event_shot_at` (`0x0045A9E0`): the object in slot `index` is hit by the one in slot
/// `attacker`, on its component `component`, or null for the object itself
/// (`dte.Trigger.whole_object`). Its ship's ShotAt goes on to its groups, with the attacker's
/// ship, its own damage value for the shields and for the hull alike (`vm.triggers.damageValue`),
/// the ship itself, and no weapon. A hit by what stands for no mission's ship posts nothing.
pub fn shotAt(world: gameobj.World, index: u16, attacker: u16, component: ?u8) void {
    const events = world.events orelse return;
    const ship = events.shipOf(index) orelse return;
    if (events.shipOf(attacker) == null) return;
    const qualifier = component orelse dte.Trigger.whole_object;
    const damage = triggers.damageValue(world, ship, qualifier);
    var values = [_]u32{ events.value(attacker), damage, damage, events.value(index), no_weapon };
    events.postGroup(ship, .{ .condition = .shot_at, .qualifier = qualifier, .values = &values });
}

/// `event_destroyed` (`0x0045AA60`): the object in slot `index` is destroyed, or its component
/// `component`, or null for the object itself, which its ship's record notes: the ship's own
/// Destroyed comes only once (`dte.Ship.Flags.destroyed`), and a component clears its bit
/// (`dte.Ship.loseComponent`). Its ship's Destroyed goes on to its groups, with the ship of
/// what last struck it (`GameObject.last_attacker`) and the ship itself.
pub fn destroyed(world: gameobj.World, index: u16, component: ?u8) void {
    const events = world.events orelse return;
    const ship = events.shipOf(index) orelse return;
    if (index >= world.objects.slots.len) return;
    const record = events.script.mission.ship(ship) orelse return;
    var values = [_]u32{ events.value(world.objects.slots[index].object.last_attacker.index()), events.value(index) };
    if (component) |part| {
        record.loseComponent(part);
    } else {
        if (record.flags.destroyed) return;
        record.flags.destroyed = true;
    }
    events.postGroup(ship, .{ .condition = .destroyed, .qualifier = component orelse dte.Trigger.whole_object, .values = &values });
}

/// `0x0045AAD0`: the object in slot `index` has taken the one in slot `object` aboard
/// (`order_scoop_up`). Its ship's ObjectScooped, with the ship of what it took, goes on to its
/// groups.
pub fn scooped(world: gameobj.World, index: u16, object: u16) void {
    postNaming(world, index, .object_scooped, object);
}

/// `event_ripper_grabbed` (`0x0045AB10`): the Ripper in slot `index` has the object in slot
/// `object` aboard (`airipper.grab`). Its ship's RipperGrabbedObject, with the ship of what it
/// took, goes on to its groups.
pub fn ripperGrabbed(world: gameobj.World, index: u16, object: u16) void {
    postNaming(world, index, .ripper_grabbed_object, object);
}

/// `event_ripper_dropped` (`0x0045AB90`): the Ripper in slot `index` has let go of the object in
/// slot `object`, or fitted it to a ship (`airipper.endDrop`, `airipper.attach`). Its ship's
/// RipperDroppedObject, with the ship of what it let go, goes on to its groups.
pub fn ripperDropped(world: gameobj.World, index: u16, object: u16) void {
    postNaming(world, index, .ripper_dropped_object, object);
}

/// `event_post_explosion` (`0x0045AB50`): the explosion that the object in slot `index` set off is
/// over. Its ship's ExplosionShip, with the ship, goes on to its groups.
pub fn exploded(world: gameobj.World, index: u16) void {
    postNaming(world, index, .explosion_ship, index);
}

/// The object in slot `index` cloaks, or uncloaks (`object_cloak`, `object_uncloak`): its ship's
/// Cloaked or Decloaked, with no values, for its own triggers.
///
/// **Fix:** the game faults on an object that stands for no mission's ship; OpenReliant posts
/// nothing.
pub fn cloaked(world: gameobj.World, index: u16, on: bool) void {
    postOwn(world, index, if (on) .cloaked else .decloaked);
}

/// `event_post_ship_reached` (`0x0045AC10`): the object in slot `index` has reached mission ship
/// `ship`, the end of a curve it followed or a point that marks a place on one. The ship's
/// ShipReached, with the ship of the object that reached it, for its own triggers.
pub fn shipReached(world: gameobj.World, ship: u16, index: u16) void {
    const events = world.events orelse return;
    var values = [_]u32{events.value(index)};
    events.post(ship, .{ .condition = .ship_reached, .values = &values });
}

/// The object in slot `index` has docked (`order_dock`): its ship's Docked, with no values, for its
/// own triggers.
pub fn docked(world: gameobj.World, index: u16) void {
    postOwn(world, index, .docked);
}

/// `event_camera_reached` (`0x00451180`): the director's camera has reached mission ship `ship`,
/// the end of the curve it flew or a point that marks a place on it. The ship's CameraReached, with
/// no values, for its own triggers.
pub fn cameraReached(world: gameobj.World, ship: u16) void {
    const events = world.events orelse return;
    events.post(ship, .{ .condition = .camera_reached });
}

/// JUMP DRIVE took the jump the mission had ready, or the warp (`player_jump`): the player's ship,
/// the mission's first, has its PlayerReadyToJump or its PlayerReadyToWarp, with no values, for its
/// own triggers.
pub fn readyToJump(world: gameobj.World, warp: bool) void {
    postOwn(world, 0, if (warp) .player_ready_to_warp else .player_ready_to_jump);
}

/// REQUEST BACKUP brought the mission's backup (`comms_request_backup`, `0x004559D6`): the
/// player's ship has its PlayerWantsBackup, with no values, for its own triggers.
pub fn wantsBackup(world: gameobj.World) void {
    postOwn(world, world.objects.player, .player_wants_backup);
}

/// A mission for the tests: a script with its events, and a world of objects that stand for its
/// ships, one a slot, whose events the world posts.
const TestMission = struct {
    game: vm.machine.testing.Game,
    events: Events,

    /// `parts` and `records` make the script; an object of the ship's slot stands at each of `at`,
    /// with a radius of `test_radius`.
    fn init(mission: *TestMission, parts: []const vm.machine.testing.Part, records: vm.machine.testing.Records, at: []const math.Vector) !void {
        const gpa = std.testing.allocator;
        try mission.game.init(gpa, parts, records);
        errdefer mission.game.deinit();
        for (at) |place| {
            const index = try mission.game.mission.add(.predator, place);
            mission.game.mission.slot(index).object.radius = test_radius;
        }
        mission.events = .init(gpa, &mission.game.fixture.machine);
        errdefer mission.events.deinit();
        try mission.events.watch(1);
        try mission.game.start(.of(mission.world()));
    }

    fn deinit(mission: *TestMission) void {
        mission.events.deinit();
        mission.game.deinit();
    }

    fn world(mission: *TestMission) gameobj.World {
        var seen = mission.game.world();
        seen.events = &mission.events;
        return seen;
    }

    const test_radius: f32 = 100;
};

test "an event waits where a trigger would answer it, and goes off with the frame" {
    const gpa = std.testing.allocator;
    const code = try vm.machine.testing.counting(gpa, 0);
    defer gpa.free(code);
    const parts = [_]vm.machine.testing.Part{.{ .code = code }};
    var mission: TestMission = undefined;
    try mission.init(&parts, .{
        .globals = &.{0},
        .ships = &dte.testing.ships(2, 0),
        .objects = &.{ dte.testing.object(.ship, 0, 1), dte.testing.object(.ship, 1, 0) },
        .triggers = &.{triggers.testing.trigger(&parts, 0, .launched, .always)},
    }, &.{ @splat(0), .{ 1000, 0, 0 } });
    defer mission.deinit();

    // No trigger of ship 1's answers its launch.
    launched(mission.world(), 1);
    try std.testing.expectEqual(0, mission.events.count);
    // Ship 0's waits for the frame.
    launched(mission.world(), 0);
    try std.testing.expectEqual(1, mission.events.count);
    try std.testing.expectEqual(0, mission.game.fixture.global(0));
    mission.events.flush();
    try std.testing.expectEqual(1, mission.game.fixture.global(0));
    try std.testing.expectEqual(0, mission.events.count);
}

test "an event waits where only its flight group's trigger would answer it" {
    const gpa = std.testing.allocator;
    const code = try vm.machine.testing.counting(gpa, 0);
    defer gpa.free(code);
    const parts = [_]vm.machine.testing.Part{.{ .code = code }};
    // Ships 0 and 1 make flight group 0, whose object holds the one trigger.
    const ships = [_]dte.Ship{ dte.testing.ship(0, 0, 0), dte.testing.ship(1, 0, 0) };
    var mission: TestMission = undefined;
    try mission.init(&parts, .{
        .globals = &.{0},
        .ships = &ships,
        .flight_groups = &.{dte.testing.flightGroup(2, .player)},
        .objects = &.{ dte.testing.object(.ship, 0, 0), dte.testing.object(.ship, 0, 0), dte.testing.object(.flight_group, 0, 1) },
        .triggers = &.{triggers.testing.trigger(&parts, 0, .launched, .always)},
    }, &.{ @splat(0), .{ 1000, 0, 0 } });
    defer mission.deinit();

    // Posted for the ship's own triggers alone, it waits for nothing.
    var values = [_]u32{mission.game.fixture.machine.mission.recordPlace(.ships, 1)};
    mission.events.post(1, .{ .condition = .launched, .values = &values });
    try std.testing.expectEqual(0, mission.events.count);
    // Posted for its groups too, it waits, and goes off on the flight group.
    launched(mission.world(), 1);
    try std.testing.expectEqual(1, mission.events.count);
    mission.events.flush();
    try std.testing.expectEqual(1, mission.game.fixture.global(0));
}

test "a ship's Destroyed comes once, and a component's clears its bit" {
    const gpa = std.testing.allocator;
    const whole = try vm.machine.testing.counting(gpa, 0);
    defer gpa.free(whole);
    const part = try vm.machine.testing.counting(gpa, 1);
    defer gpa.free(part);
    const parts = [_]vm.machine.testing.Part{ .{ .code = whole }, .{ .code = part } };
    var on_component = triggers.testing.trigger(&parts, 1, .destroyed, .always);
    on_component.qualifier = 3;
    var mission: TestMission = undefined;
    try mission.init(&parts, .{
        .globals = &.{ 0, 0 },
        .ships = &dte.testing.ships(2, 0),
        .objects = &.{ dte.testing.object(.ship, 0, 2), dte.testing.object(.ship, 2, 0) },
        .triggers = &.{ triggers.testing.trigger(&parts, 0, .destroyed, .always), on_component },
    }, &.{ @splat(0), .{ 1000, 0, 0 } });
    defer mission.deinit();
    const machine = &mission.game.fixture.machine;
    const records = try mission.game.fixture.mission.ships();

    // Ship 1 struck it last: the event names it the killer, and the ship keeps the event.
    mission.game.mission.slot(0).object.last_attacker = .of(1);
    destroyed(mission.world(), 0, null);
    destroyed(mission.world(), 0, null);
    mission.events.flush();
    try std.testing.expectEqual(1, mission.game.fixture.global(0));
    try std.testing.expect(records[0].flags.destroyed);
    try std.testing.expectEqual(machine.mission.recordPlace(.ships, 1), machine.event_values[0].destroyed[0]);
    // Component 3's answers its own trigger alone.
    destroyed(mission.world(), 0, 3);
    mission.events.flush();
    try std.testing.expectEqual(1, mission.game.fixture.global(0));
    try std.testing.expectEqual(1, mission.game.fixture.global(1));
    try std.testing.expectEqual(~@as(u32, 1 << 3), records[0].intact_components);
}

test "JUMP DRIVE takes the jump the mission has ready" {
    const gpa = std.testing.allocator;
    const code = try vm.machine.testing.counting(gpa, 0);
    defer gpa.free(code);
    const parts = [_]vm.machine.testing.Part{.{ .code = code }};
    var mission: TestMission = undefined;
    try mission.init(&parts, .{
        .globals = &.{0},
        .ships = &dte.testing.ships(1, 0),
        .objects = &.{dte.testing.object(.ship, 0, 1)},
        .triggers = &.{triggers.testing.trigger(&parts, 0, .player_ready_to_jump, .always)},
    }, &.{@splat(0)});
    defer mission.deinit();
    const machine = &mission.game.fixture.machine;
    const input = @import("../../input.zig");

    // Nothing ready, nothing happens.
    input.playerJump(mission.world());
    try std.testing.expectEqual(0, mission.events.count);
    // A jump ready is taken, the clock noting when.
    machine.variables.ready.jump = .shown;
    machine.clock = 7;
    input.playerJump(mission.world());
    mission.events.flush();
    try std.testing.expectEqual(1, mission.game.fixture.global(0));
    try std.testing.expectEqual(.no, machine.variables.ready.jump);
    try std.testing.expectEqual(7, machine.last_jumped);
}

test "the director's camera reaching a ship" {
    const gpa = std.testing.allocator;
    const code = try vm.machine.testing.counting(gpa, 0);
    defer gpa.free(code);
    const parts = [_]vm.machine.testing.Part{.{ .code = code }};
    var mission: TestMission = undefined;
    try mission.init(&parts, .{
        .globals = &.{0},
        .ships = &dte.testing.ships(2, 0),
        .objects = &.{ dte.testing.object(.ship, 0, 0), dte.testing.object(.ship, 0, 1) },
        .triggers = &.{triggers.testing.trigger(&parts, 0, .camera_reached, .always)},
    }, &.{ @splat(0), @splat(0) });
    defer mission.deinit();

    // Only the ship whose trigger answers it has its CameraReached.
    cameraReached(mission.world(), 0);
    try std.testing.expectEqual(0, mission.events.count);
    cameraReached(mission.world(), 1);
    mission.events.flush();
    try std.testing.expectEqual(1, mission.game.fixture.global(0));
}

test "the watches look for ships close by, while their triggers are armed" {
    const gpa = std.testing.allocator;
    const near = try vm.machine.testing.counting(gpa, 0);
    defer gpa.free(near);
    const close = try vm.machine.testing.counting(gpa, 1);
    defer gpa.free(close);
    const disarm = try vm.machine.testing.assemble(gpa, struct {
        fn build(r: *vm.machine.testing.Routine) !void {
            try r.op(.push_ship, &.{1});
            try r.op(.push_byte, &.{@intFromEnum(dte.Condition.proximity_general)});
            try r.op(.push_byte, &.{0});
            try r.command("SetTriggerState");
            try r.op(.push_byte, &.{1});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(disarm);
    const parts = [_]vm.machine.testing.Part{ .{ .code = near }, .{ .code = close }, .{ .code = disarm } };
    // Ship 1 watches for the player's ship within 15 of its radii, and for any ship within 20.
    var proximity = triggers.testing.trigger(&parts, 0, .proximity_general, .always);
    proximity.operands[0] = 0;
    proximity.operands[1] = 15;
    const close_by = triggers.testing.trigger(&parts, 1, .proximity_close, .always);
    var mission: TestMission = undefined;
    try mission.init(&parts, .{
        .globals = &.{ 0, 0 },
        .ships = &dte.testing.ships(3, 0),
        .objects = &.{ dte.testing.object(.ship, 0, 0), dte.testing.object(.ship, 0, 2), dte.testing.object(.ship, 2, 0) },
        .triggers = &.{ proximity, close_by },
    }, &.{ .{ 1000, 0, 0 }, @splat(0), .{ 0, 0, 1800 } });
    defer mission.deinit();
    const machine = &mission.game.fixture.machine;

    // The player's ship, 10 radii off, answers both; ship 2, 18 off, the close watch alone.
    mission.events.checkProximity(mission.world());
    mission.events.flush();
    try std.testing.expectEqual(1, mission.game.fixture.global(0));
    try std.testing.expectEqual(2, mission.game.fixture.global(1));
    // Disarmed, the Proximity trigger's watch looks no more.
    _ = machine.startThread(mission.game.fixture.mission.parts[2].block, null, false, null, null);
    try std.testing.expectEqual(0, (try mission.game.fixture.mission.file.triggers())[0].armed);
    try std.testing.expect(!mission.events.watches.get(.proximity)[0].armed);
    mission.events.checkProximity(mission.world());
    mission.events.flush();
    try std.testing.expectEqual(1, mission.game.fixture.global(0));
    try std.testing.expectEqual(4, mission.game.fixture.global(1));
}

test "REQUEST BACKUP brings the mission's backup once" {
    const gpa = std.testing.allocator;
    const code = try vm.machine.testing.counting(gpa, 0);
    defer gpa.free(code);
    const parts = [_]vm.machine.testing.Part{.{ .code = code }};
    var mission: TestMission = undefined;
    try mission.init(&parts, .{
        .globals = &.{0},
        .ships = &dte.testing.ships(1, 0),
        .objects = &.{dte.testing.object(.ship, 0, 1)},
        .triggers = &.{triggers.testing.trigger(&parts, 0, .player_wants_backup, .always)},
    }, &.{@splat(0)});
    defer mission.deinit();
    const videoreports = @import("../videoreports.zig");
    var world = mission.world();
    world.variables = &mission.game.fixture.machine.variables;

    // With no backup to send, the request brings none.
    videoreports.requestBackup(world);
    try std.testing.expectEqual(0, mission.events.count);
    // With backup to send, the first request brings it, and the next none.
    mission.game.fixture.machine.variables.backup_available = 1;
    videoreports.requestBackup(world);
    videoreports.requestBackup(world);
    mission.events.flush();
    try std.testing.expectEqual(1, mission.game.fixture.global(0));
    try std.testing.expect(mission.game.mission.player.remarks.backup_called);
}
