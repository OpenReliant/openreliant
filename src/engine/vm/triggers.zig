//! The triggers at run time. An event raised on an object fires each of the object's triggers that
//! answers it (`trigger_raise_event`, `trigger_match`), and an event on a ship goes on to its
//! flight group and to the squads that hold it, once the condition's handlers have given their
//! verdict on the group (`condition_raise`). The mission's queue raises the events
//! ([`game/mission/events.zig`](../game/mission/events.zig));
//! [docs/engine/script-vm.md](../../../docs/engine/script-vm.md#events) describes them.
//!
//! **Unknown:** the source file. The matcher lies with the interpreter, past `mission.cpp`'s code,
//! and `condition_raise` and the handlers with the mission's binding, past `loadout.cpp`'s.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.vm);

const dte = @import("../../formats/dte.zig");
const math = @import("../surrender/math.zig");
const vm = @import("../vm.zig");
const gameobj = @import("../game/gameobj.zig");
const Kinds = @import("../game/executor/commands.zig").Kinds;

const conditions = vm.conditions;
const Machine = vm.Machine;
const Call = vm.machine.Call;

/// An event as it is raised on an object.
pub const Event = struct {
    condition: dte.Condition,
    /// The component of the ship the event concerns, by its index among the components of the
    /// ship's live object, or `dte.Trigger.whole_object` for the ship itself. An event on a flight
    /// group or a squad concerns the group itself.
    qualifier: u8 = dte.Trigger.whole_object,
    /// Its values, in the order the condition lists them: a ship, a flight group or a squad by
    /// where its record lies in the mission image (`bind.Mission.recordPlace`), 0 for none, and a
    /// number as it is. ShotAt's handlers put a group's damage values in place of the ship's.
    values: []u32 = &.{},

    /// The event as the ship's groups have it (`groupsOf`): the same condition and values, on the
    /// group itself.
    pub fn onGroup(event: Event) Event {
        return .{ .condition = event.condition, .values = event.values };
    }
};

/// `trigger_raise_event` (`0x0045CE70`): raises `event` on the object `object` (`match`), where
/// there is one; the game raises nothing on an object ID of `0xFFFF`. Then the handlers' verdict
/// lets every trigger answer again.
pub fn raise(machine: *Machine, object: ?u16, event: Event) void {
    if (object) |id| match(machine, id, event);
    machine.verdict = true;
}

/// `trigger_match` (`0x0045CEA0`): each trigger that fires on `event` (`firings`) starts a thread
/// on its block, the one whose locals have the event's values, at once or for the scheduler as the
/// trigger says, unless a thread it started still runs (`threadRunning`). It is disarmed as its
/// repeat mode says (`disarm`), whether or not a thread started.
fn match(machine: *Machine, object: u16, event: Event) void {
    var each = firings(machine, object, event);
    while (each.next()) |firing| {
        const trigger = firing.trigger;
        log.debug("trigger {d} of object {d} fires on {f}", .{ firing.index, object, event.condition });
        if (!threadRunning(machine, firing.index)) {
            _ = machine.startThread(machine.mission.blockAt(.script, trigger.block()), firing.thread, trigger.deferred != 0, null, firing.index);
        }
        disarm(trigger);
    }
}

/// `event_would_fire` (`0x0045B4E0`): whether `event` on the object `object` would fire any of the
/// object's triggers (`firings`), whatever their threads; the queue asks it before it takes an
/// event (`game.mission.events`). Like the matcher, it has the object keep the event, and gives
/// the event's values to the first free thread for each trigger that answers, up to the first that
/// fires. **Unverified:** it lies past `mission.cpp`'s known code, before the queue's routines.
pub fn wouldFire(machine: *Machine, object: u16, event: Event) bool {
    var each = firings(machine, object, event);
    return each.next() != null;
}

/// The steps `trigger_match` (`0x0045CEA0`) and `event_would_fire` (`0x0045B4E0`) share: the object
/// `object` first keeps `event` where the condition keeps its last one (`keep`). Then each trigger
/// in its slice of the trigger list that answers the event (`answers`) gives the event's values to
/// the first free thread's locals, and fires where its operands then pass (`passes`).
fn firings(machine: *Machine, object: u16, event: Event) Firings {
    keep(machine, object, event);
    return .{ .machine = machine, .event = event, .slice = triggersOf(machine, object) };
}

/// A trigger that fires: its index in the trigger list, and the thread whose locals have the
/// event's values, where one was free.
const Firing = struct {
    trigger: *align(1) dte.Trigger,
    index: usize,
    thread: ?u8,
};

/// The triggers `firings` finds, each looked at only as the next is asked for.
const Firings = struct {
    machine: *Machine,
    event: Event,
    slice: Slice,
    /// The next trigger of the slice to look at.
    at: usize = 0,

    fn next(each: *Firings) ?Firing {
        const machine = each.machine;
        while (each.at < each.slice.triggers.len) {
            const at = each.at;
            each.at += 1;
            const trigger = &each.slice.triggers[at];
            if (!answers(machine.verdict, trigger.*, each.event)) continue;
            const thread = machine.allocThread();
            if (thread) |free| giveLocals(machine, free, each.event);
            if (!passes(machine, trigger.*, each.event)) continue;
            return .{ .trigger = trigger, .index = each.slice.first + at, .thread = thread };
        }
        return null;
    }
};

/// The triggers of an object's slice of the trigger list, and where the slice starts in it.
pub const Slice = struct {
    triggers: []align(1) dte.Trigger,
    first: usize,

    const empty: Slice = .{ .triggers = &.{}, .first = 0 };
};

/// The slice of the trigger list that the object `object` holds (`sliceOf`).
///
/// **Fix:** the game reads an object past the object table from past it; OpenReliant takes none.
fn triggersOf(machine: *Machine, object: u16) Slice {
    const objects = machine.mission.file.objects() catch return .empty;
    if (object >= objects.len) return .empty;
    return sliceOf(machine.mission.triggers() catch return .empty, objects[object]);
}

/// The slice of the trigger list `all` that `object` holds (`MissionObject.first`, `count`).
///
/// **Fix:** the game reads a slice past the trigger list from past it; OpenReliant takes what lies
/// within (`dte.Object.triggerBounds`).
pub fn sliceOf(all: []align(1) dte.Trigger, object: dte.Object) Slice {
    const first, const end = object.triggerBounds(all.len);
    return .{ .triggers = all[first..end], .first = first };
}

/// Whether the object `object` holds any triggers, which an event on a group is raised for only
/// where it does.
pub fn holdsTriggers(machine: *Machine, object: u16) bool {
    const objects = machine.mission.file.objects() catch return false;
    return object < objects.len and objects[object].count != 0;
}

/// Whether `trigger` answers `event`: armed, of the event's condition and qualifier, with a block
/// to run, and, where the handlers have vetoed the event (`verdict` false), of the repeat mode the
/// condition exempts from a veto.
fn answers(verdict: bool, trigger: dte.Trigger, event: Event) bool {
    if (trigger.armed == 0 or trigger.condition != event.condition or trigger.qualifier != event.qualifier) return false;
    if (!verdict and trigger.repeat != exempt(event.condition)) return false;
    return trigger.block() != null;
}

/// The repeat mode that the condition exempts from a veto (`ConditionDescriptor.veto_exempt`), or
/// `no_exempt` for none, which a trigger's byte may yet hold: the game compares the two bytes.
fn exempt(condition: dte.Condition) dte.Trigger.Repeat {
    return (condition.descriptor() orelse return no_exempt).veto_exempt orelse no_exempt;
}

/// The repeat mode a condition that exempts none from a veto holds
/// (`vm.ConditionDescriptor.none`).
const no_exempt: dte.Trigger.Repeat = @enumFromInt(vm.ConditionDescriptor.none);

/// Whether `trigger`'s operands pass `event`'s values: each operand for a value the condition marks
/// as checked (`checkOperand`), an operand the trigger leaves unset passing any.
fn passes(machine: *Machine, trigger: dte.Trigger, event: Event) bool {
    const descriptor = event.condition.descriptor() orelse return true;
    const count = @min(event.values.len, trigger.operands.len, descriptor.values.len);
    for (event.values[0..count], trigger.operands[0..count], descriptor.values[0..count]) |value, operand, described| {
        if (!described.checked) continue;
        if (!checkOperand(machine, described.kinds, operand, value, trigger.condition)) return false;
    }
    return true;
}

/// `trigger_check_operand` (`0x0045D810`): whether a trigger's `operand`, for a value of `kinds`,
/// passes the event's `value`, as the operand reads (`trigger_operand_value`, `0x004530A0`). An
/// operand for any ship passes the players' ships (`dte.Reference.any_ship`); a number of the
/// proximity conditions is the most the value may be; and anything else is the value itself, a
/// reference being where its record lies.
///
/// **Fix:** an operand that names no ship, flight group or squad, which the game stops for ("NULL
/// entity referenced in script"), passes nothing.
fn checkOperand(machine: *Machine, kinds: Kinds, operand: u32, value: u32, condition: dte.Condition) bool {
    return switch (dte.Operand.read(operand, kinds)) {
        .unset => true,
        .number => |number| switch (condition) {
            .proximity_close, .proximity_general => value <= number,
            else => value == number,
        },
        .any_ship => playersShip(machine, value),
        .ship => |index| value == machine.mission.recordPlace(.ships, index),
        .flight_group => |index| value == machine.mission.recordPlace(.flight_groups, index),
        .squad => |index| value == machine.mission.recordPlace(.squads, index),
        .other => |raw| other: {
            if (!machine.named_nothing) log.warn("a trigger's operand names no ship, flight group or squad: 0x{X:0>8}", .{raw});
            machine.named_nothing = true;
            break :other false;
        },
    };
}

/// Whether `value` is where the record of one of the players' ships lies: the ships of the first
/// slots, one in a game of one.
fn playersShip(machine: *const Machine, value: u32) bool {
    const players: u32 = if (machine.game) |game| game.world.objects.players else 1;
    const first = machine.mission.recordPlace(.ships, 0);
    return value >= first and value < machine.mission.recordPlace(.ships, players);
}

/// `trigger_thread_running` (`0x0045D0D0`): whether a thread that trigger `index` started still
/// runs (`vm.machine.Running.trigger`). Each such thread that waits for its trigger
/// (`InterruptTriggerCode`) runs on again.
///
/// **Fix:** the game keeps the index in a byte of the thread's record (`vm.Thread.trigger`,
/// `0x0045B929`), and compares the whole index against it (`0x0045D106`): trigger 255 takes every
/// thread no trigger started for its own, and a trigger past 255 never finds its own threads.
/// OpenReliant keeps the whole index beside the record.
fn threadRunning(machine: *Machine, index: usize) bool {
    var running = false;
    var threads = machine.liveThreads();
    while (threads.next()) |found| {
        const thread = found[0];
        if (thread.trigger != index) continue;
        thread.record.interrupted = false;
        running = true;
    }
    return running;
}

/// A trigger that has fired: `once` is disarmed, and `counted` once it has used up its count;
/// `always`, or a mode the game has no name for, stays armed.
fn disarm(trigger: *align(1) dte.Trigger) void {
    switch (trigger.repeat) {
        .once => trigger.armed = 0,
        .counted => {
            if (trigger.repeat_counter != 0) trigger.repeat_counter -= 1;
            if (trigger.repeat_counter == 0) trigger.armed = 0;
        },
        .always, _ => {},
    }
}

/// `cmd_SetTriggerState` (`0x0045D300`, command `0x0F`): arms, or disarms, each trigger of the
/// condition the second argument names in the slice of the object the first names, where it
/// watches a component `push_component` named for the command, or the object itself
/// (`Machine.tagged`); arming it gives it its count again (`setArmed`). Its proximity watches
/// follow it (`mission.events.Events.arm`).
pub fn setTriggerState(call: Call) u32 {
    setState(call, null);
    return vm.run_on;
}

/// `cmd_SetAnyTriggerState` (`0x0045D3A0`, command `0x4F`): the same for the one trigger of that
/// condition the fourth argument numbers among the slice's, counting from 0, where it watches a
/// component named or the object itself, its count left as it stands.
pub fn setAnyTriggerState(call: Call) u32 {
    setState(call, call.args[3]);
    return vm.run_on;
}

fn setState(call: Call, number: ?u32) void {
    const machine = call.machine;
    const object = machine.mission.objectId(call.args[0]) orelse return;
    const condition: dte.Condition = @enumFromInt(@as(u8, @truncate(call.args[1])));
    const armed: u8 = @truncate(call.args[2]);
    const slice = triggersOf(machine, object);
    var counted: u8 = 0;
    for (slice.triggers, slice.first..) |*trigger, index| {
        if (trigger.condition != condition) continue;
        defer counted +%= 1;
        if (!machine.tagged(trigger.qualifier)) continue;
        if (number) |wanted| {
            if (wanted != counted) continue;
            trigger.armed = armed;
        } else {
            setArmed(trigger, armed);
        }
        if (machine.game) |game| if (game.world.events) |events| events.arm(@intCast(index), armed != 0);
    }
}

/// `trigger_set_armed` (`0x0045D390`): `trigger` is armed or disarmed as `armed` says; armed, it
/// has its count again (`dte.Trigger.repeat_count`).
fn setArmed(trigger: *align(1) dte.Trigger, armed: u8) void {
    trigger.armed = armed;
    if (armed != 0) trigger.repeat_counter = trigger.repeat_count;
}

/// The locals of thread `thread` take `event`'s values, as far as they go.
fn giveLocals(machine: *Machine, thread: u8, event: Event) void {
    const locals = &machine.threads[thread].record.locals;
    const count = @min(event.values.len, locals.len);
    @memcpy(locals[0..count], event.values[0..count]);
}

/// Where the condition keeps each object's last event (`ConditionDescriptor.slot`), the object
/// `object` keeps `event`'s values, which `push_event_value` reads.
fn keep(machine: *Machine, object: u16, event: Event) void {
    const descriptor = event.condition.descriptor() orelse return;
    const slot = descriptor.slot orelse return;
    if (object >= machine.event_values.len) return;
    const kept = machine.event_values[object].flat();
    // Every slot lies within the kept events (`vm.ObjectEvents.slots`).
    const from = @as(usize, slot) * vm.max_event_values;
    const count = @min(event.values.len, vm.max_event_values);
    @memcpy(kept[from..][0..count], event.values[0..count]);
}

/// `condition_raise` (`0x00453210`): `event`, raised on the mission's ship `ship`, goes on to the
/// groups that hold the ship (`groupsOf`), as one on the group itself (`Event.onGroup`). For each
/// group the condition's handlers first count its members (`Tally`), and their verdict decides
/// which of the group's triggers answer (`Machine.verdict`).
pub fn raiseOnGroups(machine: *Machine, ship: u16, event: Event) void {
    const handlers = Handlers.of(event.condition);
    var groups = groupsOf(machine, ship, event.qualifier);
    while (groups.next()) |group| {
        var tally: Tally = .{ .handlers = handlers };
        switch (group.of) {
            .flight_group => |flight_group| tally.addFlightGroup(machine, flight_group),
            .squad => |squad| if (handlers != null) tally.addSquad(machine, squad, 0),
        }
        machine.verdict = tally.verdict(event.values);
        raise(machine, group.object, event.onGroup());
    }
}

/// The groups an event on mission ship `ship` goes on to, in turn, as `condition_raise`
/// (`0x00453210`) raises it on them and `event_post_group` (`0x0045B690`) asks whether one would
/// answer it: its flight group, then each squad that holds it as the component `qualifier` names
/// (`Machine.inSquad`), in the order of the mission's squads, each only where its slice holds
/// triggers. None where the mission has no such ship.
pub fn groupsOf(machine: *Machine, ship: u16, qualifier: u8) Groups {
    const record = machine.mission.ship(ship);
    return .{
        .machine = machine,
        .ship = ship,
        .qualifier = qualifier,
        .flight_group = if (record) |found| found.flightGroup() else null,
        .squad = if (record != null) 0 else null,
    };
}

/// The groups `groupsOf` finds, each squad looked at only as the next is asked for.
pub const Groups = struct {
    machine: *Machine,
    ship: u16,
    qualifier: u8,
    /// The ship's flight group, while it is still to come.
    flight_group: ?u8,
    /// The next squad to look at, null once there are no more.
    squad: ?usize,

    pub const Group = struct {
        /// The group's object ID, whose slice holds its triggers.
        object: u16,
        of: union(enum) {
            flight_group: dte.FlightGroup,
            /// A squad by its index among the mission's squads.
            squad: u16,
        },
    };

    pub fn next(groups: *Groups) ?Group {
        const machine = groups.machine;
        if (groups.flight_group) |index| {
            groups.flight_group = null;
            if (machine.mission.flightGroup(index)) |group| if (holdsTriggers(machine, group.object_id)) {
                return .{ .object = group.object_id, .of = .{ .flight_group = group.* } };
            };
        }
        const first = groups.squad orelse return null;
        groups.squad = null;
        const squads = machine.mission.file.squads() catch return null;
        const place = machine.mission.recordPlace(.ships, groups.ship);
        for (squads[@min(first, squads.len)..], first..) |squad, index| {
            if (!holdsTriggers(machine, squad.object_id)) continue;
            const holds = machine.inSquad(machine.mission.recordPlace(.squads, index), place, groups.qualifier, 0) catch false;
            if (!holds) continue;
            groups.squad = index + 1;
            return .{ .object = squad.object_id, .of = .{ .squad = @intCast(index) } };
        }
        return null;
    }
};

/// What a condition's handlers do with its events on a flight group or a squad
/// (`ConditionDescriptor.begin`, `add_member`, `verdict`), by the routines the catalogue names.
const Handlers = enum {
    /// ShotAt's: the group's event carries its members' average damage values (`damageValue`) in
    /// place of the ship's, and goes ahead.
    average_damage,
    /// Destroyed's: the group's event goes ahead only once every member, or the component a squad
    /// names of it, is destroyed.
    all_destroyed,
    /// Cloaked's and Decloaked's: Destroyed's first and last, with a routine for each member that
    /// does nothing (`cloak_group_add`), so every event goes ahead.
    pass,

    /// `shot_at_group_begin`, `shot_at_group_add` and `shot_at_group_verdict`.
    const average_damage_routines: conditions.Handlers = .{ .begin = 0x00452BB0, .add_member = 0x00452BD0, .verdict = 0x00452C00 };
    /// `destroyed_group_begin`, `destroyed_group_add` and `destroyed_group_verdict`.
    const all_destroyed_routines: conditions.Handlers = .{ .begin = 0x00452C40, .add_member = 0x00452C50, .verdict = 0x00452CA0 };
    /// `destroyed_group_begin`, `cloak_group_add` and `destroyed_group_verdict`.
    const pass_routines: conditions.Handlers = .{ .begin = 0x00452C40, .add_member = 0x0045D800, .verdict = 0x00452CA0 };

    /// The condition's handlers, where it has any.
    fn of(condition: dte.Condition) ?Handlers {
        const descriptor = condition.descriptor() orelse return null;
        return known(descriptor.handlers orelse return null);
    }

    fn known(routines: conditions.Handlers) ?Handlers {
        if (std.meta.eql(routines, average_damage_routines)) return .average_damage;
        if (std.meta.eql(routines, all_destroyed_routines)) return .all_destroyed;
        if (std.meta.eql(routines, pass_routines)) return .pass;
        return null;
    }

    comptime {
        for (conditions.table) |condition| {
            if (condition.handlers) |routines| assert(known(routines) != null);
        }
    }
};

/// What a group's members come to as its condition's handlers count them. It starts as the
/// handlers' `begin` routines start them: `shot_at_group_begin` (`0x00452BB0`) zeroes the totals,
/// and `destroyed_group_begin` (`0x00452C40`) sets the verdict.
const Tally = struct {
    handlers: ?Handlers,
    /// The members counted, which ShotAt's averages over.
    count: u16 = 0,
    /// ShotAt's total of the members' damage values, which the game keeps twice, once for each of
    /// the event's damage values (`shot_at_shield_total`, `0x005294E6`; `shot_at_hull_total`,
    /// `0x0052950A`).
    damage: u16 = 0,
    /// Destroyed's (`destroyed_group_all`, `0x00525F7C`): whether every member counted so far is
    /// destroyed.
    all_destroyed: bool = true,

    /// The member ship `ship`, whole or as its component `component` (`add_member`:
    /// `shot_at_group_add`, `0x00452BD0`; `destroyed_group_add`, `0x00452C50`). A component is
    /// destroyed once the ship's record has its bit clear (`dte.Ship.componentIntact`).
    fn add(tally: *Tally, machine: *Machine, ship: u16, component: u8) void {
        const handlers = tally.handlers orelse return;
        switch (handlers) {
            .average_damage => {
                const game = machine.game orelse return;
                tally.damage +%= damageValue(game.world, ship, component);
            },
            .all_destroyed => {
                if (!tally.all_destroyed) return;
                const record = machine.mission.ship(ship) orelse return;
                tally.all_destroyed = if (component == dte.Trigger.whole_object)
                    record.flags.destroyed
                else
                    !record.componentIntact(component);
            },
            .pass => {},
        }
    }

    /// `condition_squad_add` (`0x004533D0`): the members of squad `squad`, `depth` squads down, in
    /// turn (`bind.Mission.squadMembers`): a ship as the component its membership names, each ship
    /// of a flight group whole, and a squad's own members in turn.
    fn addSquad(tally: *Tally, machine: *Machine, squad: u16, depth: usize) void {
        var members = machine.mission.squadMembers(squad, depth);
        while (members.next()) |member| switch (member) {
            .ship => |ship| {
                tally.add(machine, ship.index, ship.component orelse dte.Trigger.whole_object);
                tally.count +%= 1;
            },
            .flight_group => |group| tally.addFlightGroup(machine, group),
            .squad => |inner| tally.addSquad(machine, inner, depth + 1),
        };
    }

    /// The members of flight group `group`: each of its ships whole, then its `ship_count` added
    /// to the count, as `condition_raise` (`0x0045327E`) and `condition_squad_add` (`0x00453477`)
    /// count them.
    fn addFlightGroup(tally: *Tally, machine: *Machine, group: dte.FlightGroup) void {
        for (machine.mission.groupShips(group)) |ship| tally.add(machine, ship, dte.Trigger.whole_object);
        tally.count +%= group.ship_count;
    }

    /// The handlers' verdict on the group's event (`verdict`: `shot_at_group_verdict`,
    /// `0x00452C00`; `destroyed_group_verdict`, `0x00452CA0`), which ShotAt's gives the members'
    /// average damage value for both of the event's damage values first; true for a condition
    /// without handlers.
    fn verdict(tally: Tally, values: []u32) bool {
        const handlers = tally.handlers orelse return true;
        return switch (handlers) {
            .average_damage => {
                // The game divides by the count, which never comes to zero: the ship the event
                // is on is among the members.
                if (tally.count == 0) return true;
                const average = tally.damage / tally.count;
                for ([_]usize{ shield_damage, hull_damage }) |value| {
                    if (value < values.len) values[value] = average;
                }
                return true;
            },
            .all_destroyed, .pass => tally.all_destroyed,
        };
    }
};

/// ShotAt's damage values, among its event's values.
const shield_damage = 1;
const hull_damage = 2;

comptime {
    const values = conditions.table[@intFromEnum(dte.Condition.shot_at)].values;
    assert(std.mem.eql(u8, values[shield_damage].label, "Shield Damage"));
    assert(std.mem.eql(u8, values[hull_damage].label, "Hull Damage"));
}

/// `ship_damage_value` (`0x00452CB0`): how much of its armour the mission's ship `ship` has lost,
/// in whole hundredths, a hundred once any of it has run out. The ship's own is its weakest
/// quadrant's against the full armour of its type (`create.ShipCombat.fullArmor`); its component
/// `component`'s is the component's against what it starts with, and a hundred for a component the
/// ship lists no more.
///
/// The game looks the full armour up by the object's current type (`ship_combat_stats`,
/// `0x004FC670`). For a stand-in, type 1001, such as a ship not made yet or one retired, it reads
/// past the table at `0x00508224`, in a 3D sound's name. That value makes the full armour a large
/// negative number, so a stand-in's value is a hundred, as is a component's it no longer lists.
pub fn damageValue(world: gameobj.World, ship: u16, component: u8) u16 {
    const all = world.objects;
    if (ship >= all.slots.len) return 0;
    const slot = &all.slots[ship];
    if (component == dte.Trigger.whole_object and slot.object.type == .stand_in) return all_lost;
    const left: f32, const full: f32 = if (component == dte.Trigger.whole_object)
        .{ slot.object.armor.weakest(), if (slot.combat) |combat| combat.fullArmor() else 0 }
    else if (slot.component(component)) |part|
        .{ part.armor, @floatFromInt(part.component_armor) }
    else
        .{ 0, all_lost };
    if (left < 0) return all_lost;
    return @truncate(@as(u32, @bitCast(math.ftol((full - left) / full * all_lost))));
}

/// The damage value of a ship or a component with no armour left (`0x004DC440`).
const all_lost = 100;

const machine_testing = vm.machine.testing;

/// The tests' mission records (`dte.testing`).
const shipRecord = dte.testing.ship;
const groupRecord = dte.testing.flightGroup;
const objectRecord = dte.testing.object;
const memberRecord = dte.testing.squadMember;

/// Fixtures for the tests of the triggers, and of what posts the events.
pub const testing = struct {
    /// A trigger, armed as the script's start arms it, watching its object itself, with no operand
    /// set, whose block is part `part` of `parts`.
    pub fn trigger(parts: []const machine_testing.Part, part: usize, condition: dte.Condition, repeat: dte.Trigger.Repeat) dte.Trigger {
        var made = std.mem.zeroes(dte.Trigger);
        made.condition = condition;
        made.repeat = repeat;
        made.link = machine_testing.Fixture.link(parts, part);
        made.qualifier = dte.Trigger.whole_object;
        made.operands = @splat(0xFFFF_FFFF);
        return made;
    }
};

test "an event fires the triggers that answer it, as their repeat modes allow" {
    const gpa = std.testing.allocator;
    // The block stores its first local, the event's first value, in global 0, and counts in
    // global 1.
    const stores = try machine_testing.assemble(gpa, struct {
        fn build(r: *machine_testing.Routine) !void {
            try r.op(.select_global, &.{0});
            try r.op(.push_local, &.{0});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{1});
            try r.op(.push_byte, &.{1});
            try r.op(.add_assign, &.{});
            try r.op(.push_byte, &.{1});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(stores);
    const again = try machine_testing.counting(gpa, 2);
    defer gpa.free(again);
    const parts = [_]machine_testing.Part{ .{ .code = stores }, .{ .code = again } };

    var once = testing.trigger(&parts, 0, .launched, .once);
    once.operands[0] = 1; // Ship 1.
    var counted = testing.trigger(&parts, 1, .launched, .counted);
    counted.repeat_counter = 2;
    const ships = dte.testing.ships(2, 0);
    var fixture: machine_testing.Fixture = undefined;
    try fixture.init(gpa, &parts, .{
        .globals = &.{ 0, 0, 0 },
        .ships = &ships,
        .objects = &.{ objectRecord(.ship, 0, 2), objectRecord(.ship, 2, 0) },
        .triggers = &.{ once, counted },
    });
    defer fixture.deinit();
    const machine = &fixture.machine;
    try machine.start();

    // Ship 0 launched: the counted trigger answers, the other's operand wants ship 1.
    var zero = [_]u32{machine.mission.recordPlace(.ships, 0)};
    raise(machine, 0, .{ .condition = .launched, .values = &zero });
    try std.testing.expectEqual(0, fixture.global(1));
    try std.testing.expectEqual(1, fixture.global(2));
    // Ship 1: both fire, the first with the ship in its local.
    var one = [_]u32{machine.mission.recordPlace(.ships, 1)};
    try std.testing.expect(wouldFire(machine, 0, .{ .condition = .launched, .values = &one }));
    raise(machine, 0, .{ .condition = .launched, .values = &one });
    try std.testing.expectEqual(one[0], fixture.global(0));
    try std.testing.expectEqual(1, fixture.global(1));
    try std.testing.expectEqual(2, fixture.global(2));
    // Both are spent: the one fired once, the other twice.
    try std.testing.expect(!wouldFire(machine, 0, .{ .condition = .launched, .values = &one }));
    raise(machine, 0, .{ .condition = .launched, .values = &one });
    try std.testing.expectEqual(1, fixture.global(1));
    try std.testing.expectEqual(2, fixture.global(2));
    // Another condition, or a component, answers nothing.
    try std.testing.expect(!wouldFire(machine, 0, .{ .condition = .destroyed, .values = &one }));
}

test "a trigger whose thread still runs lets it go on instead" {
    const gpa = std.testing.allocator;
    // The block counts, waits for its trigger to fire again, and counts again.
    const code = try machine_testing.assemble(gpa, struct {
        fn build(r: *machine_testing.Routine) !void {
            for (0..2) |_| {
                try r.op(.select_global, &.{0});
                try r.op(.push_byte, &.{1});
                try r.op(.add_assign, &.{});
                try r.command("InterruptTriggerCode");
            }
            try r.op(.push_byte, &.{1});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    const parts = [_]machine_testing.Part{.{ .code = code }};
    var fixture: machine_testing.Fixture = undefined;
    try fixture.init(gpa, &parts, .{
        .globals = &.{0},
        .ships = &dte.testing.ships(1, 0),
        .objects = &.{objectRecord(.ship, 0, 1)},
        .triggers = &.{testing.trigger(&parts, 0, .player_ready_to_jump, .always)},
    });
    defer fixture.deinit();
    const machine = &fixture.machine;
    try machine.start();

    raise(machine, 0, .{ .condition = .player_ready_to_jump });
    try std.testing.expectEqual(1, fixture.global(0));
    try std.testing.expectEqual(1, machine.thread_count);
    // Held, the thread waits; the trigger firing again lets it go on, starting no other.
    machine.runThreads();
    try std.testing.expectEqual(1, fixture.global(0));
    raise(machine, 0, .{ .condition = .player_ready_to_jump });
    try std.testing.expectEqual(1, machine.thread_count);
    machine.runThreads();
    try std.testing.expectEqual(2, fixture.global(0));
}

test "a trigger past the 255th finds its own threads alone" {
    const gpa = std.testing.allocator;
    // Trigger 256's block counts in global 0, waits for its trigger to fire again, and counts
    // again; trigger 0's counts in global 1.
    const waits = try machine_testing.assemble(gpa, struct {
        fn build(r: *machine_testing.Routine) !void {
            for (0..2) |round| {
                try r.op(.select_global, &.{0});
                try r.op(.push_byte, &.{1});
                try r.op(.add_assign, &.{});
                if (round == 0) try r.command("InterruptTriggerCode");
            }
            try r.op(.push_byte, &.{1});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(waits);
    const counts = try machine_testing.counting(gpa, 1);
    defer gpa.free(counts);
    const parts = [_]machine_testing.Part{ .{ .code = waits }, .{ .code = counts } };
    var all: [257]dte.Trigger = @splat(std.mem.zeroes(dte.Trigger));
    all[0] = testing.trigger(&parts, 1, .player_ready_to_jump, .always);
    all[256] = testing.trigger(&parts, 0, .player_ready_to_jump, .always);
    var fixture: machine_testing.Fixture = undefined;
    try fixture.init(gpa, &parts, .{
        .globals = &.{ 0, 0 },
        .ships = &dte.testing.ships(2, 0),
        .objects = &.{ objectRecord(.ship, 256, 1), objectRecord(.ship, 0, 1) },
        .triggers = &all,
    });
    defer fixture.deinit();
    const machine = &fixture.machine;
    try machine.start();

    // Trigger 256 fires again while its thread waits: the thread runs on, and no other starts.
    raise(machine, 0, .{ .condition = .player_ready_to_jump });
    raise(machine, 0, .{ .condition = .player_ready_to_jump });
    try std.testing.expectEqual(1, fixture.global(0));
    try std.testing.expectEqual(1, machine.thread_count);
    // Trigger 0, whose index the waiting thread's record holds the low byte of, starts its own.
    raise(machine, 1, .{ .condition = .player_ready_to_jump });
    try std.testing.expectEqual(1, fixture.global(1));
    machine.runThreads();
    try std.testing.expectEqual(2, fixture.global(0));
}

test "SetAnyTriggerState arms the one trigger it numbers, and SetTriggerState each" {
    const gpa = std.testing.allocator;
    const code = try machine_testing.counting(gpa, 0);
    defer gpa.free(code);
    const parts = [_]machine_testing.Part{.{ .code = code }};
    // Three triggers of Destroyed: on the ship, on its component 3, and on the ship again.
    var counted = testing.trigger(&parts, 0, .destroyed, .counted);
    counted.repeat_count = 3;
    var on_component = testing.trigger(&parts, 0, .destroyed, .always);
    on_component.qualifier = 3;
    var last = testing.trigger(&parts, 0, .destroyed, .counted);
    last.repeat_count = 5;
    last.repeat_counter = 1;
    var fixture: machine_testing.Fixture = undefined;
    try fixture.init(gpa, &parts, .{
        .globals = &.{0},
        .ships = &dte.testing.ships(1, 0),
        .objects = &.{objectRecord(.ship, 0, 3)},
        .triggers = &.{ counted, on_component, last },
    });
    defer fixture.deinit();
    const machine = &fixture.machine;
    try machine.start();
    const records = try fixture.mission.triggers();
    for (records) |*trigger| trigger.armed = 0;
    const armed = struct {
        fn of(triggers: []align(1) const dte.Trigger) [3]u8 {
            return .{ triggers[0].armed, triggers[1].armed, triggers[2].armed };
        }
    }.of;
    const condition: u32 = @intFromEnum(dte.Condition.destroyed);
    var args = [_]u32{ machine.mission.recordPlace(.ships, 0), condition, 1, 1 };
    const call: Call = .{ .machine = machine, .thread = 0, .args = &args };

    // The component's trigger is counted, though no component is named for the command, so the
    // second numbers it and arms nothing.
    _ = setAnyTriggerState(call);
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, armed(records));
    // The third arms the last alone, its count left as it stands.
    args[3] = 2;
    _ = setAnyTriggerState(call);
    try std.testing.expectEqual([3]u8{ 0, 0, 1 }, armed(records));
    try std.testing.expectEqual(1, records[2].repeat_counter);
    // SetTriggerState arms both on the ship, each with its count again.
    _ = setTriggerState(.{ .machine = machine, .thread = 0, .args = args[0..3] });
    try std.testing.expectEqual([3]u8{ 1, 0, 1 }, armed(records));
    try std.testing.expectEqual(3, records[0].repeat_counter);
    try std.testing.expectEqual(5, records[2].repeat_counter);
}

test "an object keeps the last event of the conditions that keep theirs" {
    const gpa = std.testing.allocator;
    const code = try machine_testing.counting(gpa, 0);
    defer gpa.free(code);
    const parts = [_]machine_testing.Part{.{ .code = code }};
    var fixture: machine_testing.Fixture = undefined;
    try fixture.init(gpa, &parts, .{
        .globals = &.{0},
        .ships = &dte.testing.ships(2, 0),
        .objects = &.{ objectRecord(.ship, 0, 0), objectRecord(.ship, 0, 0) },
    });
    defer fixture.deinit();
    const machine = &fixture.machine;
    try machine.start();

    var shot = [_]u32{ 1, 2, 3, 4, 5 };
    raise(machine, 1, .{ .condition = .shot_at, .values = &shot });
    try std.testing.expectEqual(shot, machine.event_values[1].shot_at);
    var killed = [_]u32{ 6, 7 };
    raise(machine, 1, .{ .condition = .destroyed, .values = &killed });
    try std.testing.expectEqual([_]u32{ 6, 7, 0, 0, 0 }, machine.event_values[1].destroyed);
    // Launched keeps none, and the other object keeps nothing of the first's.
    var launched = [_]u32{8};
    raise(machine, 1, .{ .condition = .launched, .values = &launched });
    try std.testing.expectEqual(shot, machine.event_values[1].shot_at);
    try std.testing.expectEqual([_]u32{ 6, 7, 0, 0, 0 }, machine.event_values[1].destroyed);
    try std.testing.expectEqual(std.mem.zeroes(vm.ObjectEvents), machine.event_values[0]);
}

test "a group's Destroyed goes ahead once every member is destroyed" {
    const gpa = std.testing.allocator;
    const always = try machine_testing.counting(gpa, 0);
    defer gpa.free(always);
    const once = try machine_testing.counting(gpa, 1);
    defer gpa.free(once);
    const in_squad = try machine_testing.counting(gpa, 2);
    defer gpa.free(in_squad);
    const parts = [_]machine_testing.Part{ .{ .code = always }, .{ .code = once }, .{ .code = in_squad } };

    // Ships 0 and 1 make flight group 0, which squad 0 holds as its only member.
    const ships = [_]dte.Ship{ shipRecord(0, 0, 0), shipRecord(1, 0, 0) };
    var fixture: machine_testing.Fixture = undefined;
    try fixture.init(gpa, &parts, .{
        .globals = &.{ 0, 0, 0 },
        .ships = &ships,
        .flight_groups = &.{groupRecord(2, .player)},
        .squads = &.{dte.testing.squad(3, 0)},
        .squad_members = &.{memberRecord(2, 0, dte.Trigger.whole_object)},
        .objects = &.{ objectRecord(.ship, 0, 0), objectRecord(.ship, 0, 0), objectRecord(.flight_group, 0, 2), objectRecord(.squad, 2, 1) },
        .triggers = &.{
            testing.trigger(&parts, 0, .destroyed, .always),
            testing.trigger(&parts, 1, .destroyed, .once),
            testing.trigger(&parts, 2, .destroyed, .once),
        },
    });
    defer fixture.deinit();
    const machine = &fixture.machine;
    try machine.start();
    const records = try fixture.mission.ships();

    // One of two gone: only the group's trigger of the mode the veto spares answers.
    records[0].flags.destroyed = true;
    var values = [_]u32{ 0, machine.mission.recordPlace(.ships, 0) };
    raiseOnGroups(machine, 0, .{ .condition = .destroyed, .values = &values });
    try std.testing.expectEqual([3]u32{ 1, 0, 0 }, [3]u32{ fixture.global(0), fixture.global(1), fixture.global(2) });
    try std.testing.expect(machine.verdict);
    // Both gone: the group's and the squad's go ahead.
    records[1].flags.destroyed = true;
    values[1] = machine.mission.recordPlace(.ships, 1);
    raiseOnGroups(machine, 1, .{ .condition = .destroyed, .values = &values });
    try std.testing.expectEqual([3]u32{ 2, 1, 1 }, [3]u32{ fixture.global(0), fixture.global(1), fixture.global(2) });
}

test groupsOf {
    const gpa = std.testing.allocator;
    const code = try machine_testing.counting(gpa, 0);
    defer gpa.free(code);
    const parts = [_]machine_testing.Part{.{ .code = code }};

    // Ship 0 is in flight group 0, and squads 0 and 1 hold it whole; ship 1 is in neither. The
    // flight group and squad 1 hold triggers, squad 0 none.
    const ships = [_]dte.Ship{ shipRecord(0, 0, 0), shipRecord(1, dte.Ship.no_flight_group, 0) };
    const squads = [_]dte.Squad{ dte.testing.squad(3, 0), dte.testing.squad(4, 1) };
    const whole = dte.Trigger.whole_object;
    var fixture: machine_testing.Fixture = undefined;
    try fixture.init(gpa, &parts, .{
        .globals = &.{0},
        .ships = &ships,
        .flight_groups = &.{groupRecord(2, .player)},
        .squads = &squads,
        .squad_members = &.{ memberRecord(0, 0, whole), memberRecord(0, 1, whole) },
        .objects = &.{ objectRecord(.ship, 0, 0), objectRecord(.ship, 0, 0), objectRecord(.flight_group, 0, 1), objectRecord(.squad, 1, 0), objectRecord(.squad, 1, 1) },
        .triggers = &.{ testing.trigger(&parts, 0, .destroyed, .always), testing.trigger(&parts, 0, .destroyed, .always) },
    });
    defer fixture.deinit();
    const machine = &fixture.machine;

    // The flight group, then squad 1; squad 0 holds no triggers.
    var groups = groupsOf(machine, 0, dte.Trigger.whole_object);
    const flight_group = groups.next().?;
    try std.testing.expectEqual(2, flight_group.object);
    try std.testing.expectEqual(2, flight_group.of.flight_group.object_id);
    const squad = groups.next().?;
    try std.testing.expectEqual(4, squad.object);
    try std.testing.expectEqual(1, squad.of.squad);
    try std.testing.expectEqual(null, groups.next());
    try std.testing.expectEqual(null, groups.next());
    // The squads hold the whole ship, not one of its components.
    var component = groupsOf(machine, 0, 3);
    try std.testing.expectEqual(2, component.next().?.object);
    try std.testing.expectEqual(null, component.next());
    // A ship in no group, and a ship the mission lacks, go on to none.
    for ([_]u16{ 1, 2 }) |ship| {
        var none = groupsOf(machine, ship, dte.Trigger.whole_object);
        try std.testing.expectEqual(null, none.next());
    }
}

test "an operand for any ship passes the players' ships alone" {
    const gpa = std.testing.allocator;
    const code = try machine_testing.counting(gpa, 0);
    defer gpa.free(code);
    const parts = [_]machine_testing.Part{.{ .code = code }};
    var trigger = testing.trigger(&parts, 0, .proximity_general, .always);
    trigger.operands[0] = 0xFF00_0000 | @as(u32, dte.Reference.any_ship);
    // The distance is not checked, however far the event's.
    trigger.operands[1] = 1;
    const ships = dte.testing.ships(2, 0);
    var fixture: machine_testing.Fixture = undefined;
    try fixture.init(gpa, &parts, .{ .globals = &.{0}, .ships = &ships, .objects = &.{objectRecord(.ship, 0, 1)}, .triggers = &.{trigger} });
    defer fixture.deinit();
    const machine = &fixture.machine;
    try machine.start();

    var other = [_]u32{ machine.mission.recordPlace(.ships, 1), 30 };
    raise(machine, 0, .{ .condition = .proximity_general, .values = &other });
    try std.testing.expectEqual(0, fixture.global(0));
    var player = [_]u32{ machine.mission.recordPlace(.ships, 0), 30 };
    raise(machine, 0, .{ .condition = .proximity_general, .values = &player });
    try std.testing.expectEqual(1, fixture.global(0));
}

test "ShotAt's handlers average the members' damage values" {
    var values = [_]u32{ 0, 90, 90, 0, 0xFFFF_FFFF };
    const tally: Tally = .{ .handlers = .average_damage, .count = 3, .damage = 100 };
    try std.testing.expect(tally.verdict(&values));
    try std.testing.expectEqualSlices(u32, &.{ 0, 33, 33, 0, 0xFFFF_FFFF }, &values);
    // Destroyed's vetoes while a member stands; the cloak's never do.
    try std.testing.expect(!(Tally{ .handlers = .all_destroyed, .all_destroyed = false }).verdict(&values));
    try std.testing.expect((Tally{ .handlers = .pass }).verdict(&values));
    try std.testing.expectEqual(.average_damage, Handlers.of(.shot_at).?);
    try std.testing.expectEqual(.pass, Handlers.of(.decloaked).?);
    try std.testing.expectEqual(null, Handlers.of(.launched));
}

test damageValue {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ship = try mission.add(.predator, @splat(0));
    const slot = mission.slot(ship);
    const full = slot.combat.?.fullArmor();
    // Untouched, a ship has lost nothing; its weakest quadrant at a quarter off, 25.
    slot.object.armor = .all(full);
    try std.testing.expectEqual(0, damageValue(mission.world(), ship, dte.Trigger.whole_object));
    slot.object.armor.aft = full * 0.75;
    try std.testing.expectEqual(25, damageValue(mission.world(), ship, dte.Trigger.whole_object));
    // Any quadrant run out, 100; a component it lists no more, 100.
    slot.object.armor.left = -1;
    try std.testing.expectEqual(100, damageValue(mission.world(), ship, dte.Trigger.whole_object));
    try std.testing.expectEqual(100, damageValue(mission.world(), ship, 3));
    // A stand-in has lost it all: one retired keeps its armour and its type's figures, and one not
    // made yet has neither.
    slot.object.armor = .all(full);
    slot.object.type = .stand_in;
    try std.testing.expectEqual(100, damageValue(mission.world(), ship, dte.Trigger.whole_object));
    slot.combat = null;
    slot.object.armor = .all(0);
    try std.testing.expectEqual(100, damageValue(mission.world(), ship, dte.Trigger.whole_object));
}
