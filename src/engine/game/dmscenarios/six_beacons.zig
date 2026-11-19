//! Six Beacons from dmscenarios.cpp. **Improvement:** the host determines pickups and gate
//! contact from the simulated ships. A beacon belongs to one admission and ship until dropped.

const std = @import("std");
const ai = @import("../ai.zig");
const hud = @import("../hud.zig");
const language = @import("../language.zig");
const input = @import("../../input.zig");
const math = @import("../../surrender/math.zig");
const gameobj = @import("../gameobj.zig");
const create = @import("../create.zig");
const players = @import("../players.zig");
const objects = @import("../objects.zig");
const sound3d = @import("../sound3d.zig");
const deathmatch = @import("../deathmatch.zig");

/// six_beacons_check_nuke (0x004B32C0) and the gate contact record (0x0050C500).
pub const required = 6;
const gate_distance: f32 = 2500;
/// six_beacons_trigger_nuke (0x004B3180, 0x004DCA64).
const blast_radius_share: f32 = 0.22;
pub const blast_ticks = 1000;
/// pickup_drop (0x004B26B0) cycles through these world axes at 0x0050C4AC.
const drop_directions = [required]math.Vector{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
const drop_radius_share: f32 = 0.8; // 0x004DC410
const repair_interval = 25; // six_beacons_frame, 0x004B339B
const wait_notice_gap = 30; // pickup_frame, 0x004B24A0
const boundary_interval = 50; // six_beacons_frame, 0x004B3316
const boundary_margin: f32 = 500; // 0x004DC4A8

pub const Notice = struct {
    pilot: players.ParticipantRef,
    tick: i32,
    kind: Kind,

    pub const Kind = enum(u16) { all_collected = 0x2EB, triggered = 0x300, waiting_for_players = 0x5B9 };

    pub const Sink = struct {
        context: *anyopaque,
        send: *const fn (*anyopaque, Notice) void,
    };

    pub fn present(notice: Notice, messages: *hud.Messages, strings: language.Language, viewer: players.ParticipantRef, pilot_name: []const u8) void {
        if (notice.kind == .waiting_for_players and !std.meta.eql(viewer, notice.pilot)) return;
        const format = strings.string(@backingInt(notice.kind)) orelse return;
        deathmatch.addMessage(messages, notice.tick, format, &.{pilot_name});
    }

    pub fn post(world: gameobj.World, pilot: players.ParticipantRef, kind: Kind) void {
        if (world.beacon_notices) |sink| sink.send(sink.context, .{ .pilot = pilot, .kind = kind, .tick = world.clock.frame_start });
    }
};

const Beacon = struct { object: gameobj.ObjectRef, carrier: ?players.ControlRef = null };

fn count(carriers: *const [required]?players.ControlRef, pilot: players.ParticipantRef, ship: ?gameobj.ObjectRef) u8 {
    var total: u8 = 0;
    for (carriers) |entry| {
        const carrier = entry orelse continue;
        if (!std.meta.eql(carrier.participant, pilot)) continue;
        if (ship) |object| if (!std.meta.eql(carrier.ship, object)) continue;
        total += 1;
    }
    return total;
}

/// The host captures the objective identities and carriers together.
pub const Snapshot = struct {
    beacons: [required]Beacon,

    pub fn countFor(view: *const Snapshot, binding: players.ControlRef) u8 {
        return view.hudSnapshot().countFor(binding);
    }

    pub fn hudSnapshot(view: *const Snapshot) HudSnapshot {
        var shown: HudSnapshot = .{};
        for (&shown.carriers, view.beacons) |*carrier, beacon| carrier.* = beacon.carrier;
        return shown;
    }
};

/// The display needs the carriers, including for a pilot joining mid-round.
pub const HudSnapshot = struct {
    carriers: [required]?players.ControlRef = @splat(null),

    pub fn countFor(view: *const HudSnapshot, binding: players.ControlRef) u8 {
        return count(&view.carriers, binding.participant, binding.ship);
    }

    /// **Fix:** six_beacons_target_text accepts slot eight, just past the original pilot slots.
    /// Only a ship bound to a pilot has a count.
    pub fn countAt(view: *const HudSnapshot, all: *const create.Objects, slot: u16) ?u8 {
        return view.countFor(all.playerBinding(slot) orelse return null);
    }
};

pub const Hud = struct {
    snapshot: *const HudSnapshot,
    icons: ?*hud.Art,

    const Counter = struct {
        shape: usize,
        icon: [2]i32,
        digits: [2]i32,
    };

    const local: Counter = .{ .shape = 0x0B, .icon = .{ 0, 0 }, .digits = .{ 21, 40 } }; // 0x004B3570
    const target: Counter = .{ .shape = 0x10, .icon = .{ -33, 2 }, .digits = .{ -24, 18 } }; // 0x004B3840

    /// six_beacons_draw_hud (0x004B3570) and six_beacons_hud_position (0x004B32E0).
    /// The local counter stays at the top of the screen when the camera changes.
    pub fn drawLocal(view: Hud, pen: hud.Pen, all: *const create.Objects) hud.Error!void {
        if (all.player_states[all.player].membership != .joined) return;
        const anchor = pen.placed(.{ -25, 0 }, 0.5, 0);
        try view.drawCounter(pen, pen.font, local, anchor, view.snapshot.countAt(all, all.player) orelse 0);
    }

    /// six_beacons_draw_pilot_count (0x004B3840). Both offsets start at the top left of the target box.
    pub fn drawTarget(view: Hud, pen: hud.Pen, font: *hud.Opened, pilot: players.ControlRef, corner: [2]i32) hud.Error!void {
        try view.drawCounter(pen, font, target, corner, view.snapshot.countFor(pilot));
    }

    fn drawCounter(view: Hud, pen: hud.Pen, font: *hud.Opened, counter: Counter, anchor: [2]i32, total: u8) hud.Error!void {
        if (view.icons) |art| try pen.drawing(.{ .art = art, .gpa = pen.gpa }).shape(counter.shape, pen.moved(anchor, counter.icon));
        var buffer: [3]u8 = undefined;
        const digits = std.fmt.bufPrint(&buffer, "{d}", .{total}) catch unreachable;
        _ = try pen.textIn(font, pen.moved(anchor, counter.digits), digits, .centre);
    }
};

/// six_beacons_target_text (0x004B37B0). The longest language string fits after a count and space.
pub const LabelBuffer = [language.max_length + 4]u8;
pub fn targetText(buffer: *LabelBuffer, strings: language.Language, total: u8) ?[]const u8 {
    const singular = 0x2D6;
    const plural = 0x2D7;
    const noun = strings.string(if (total == 1) singular else plural) orelse return null;
    return std.fmt.bufPrint(buffer, "{d} {s}", .{ total, noun }) catch null;
}

test "the target window uses the installed singular and plural beacon names" {
    var words: [0x2D7][]const u8 = @splat("");
    words[0x2D6 - 1] = "balise";
    words[0x2D7 - 1] = "balises";
    const strings: language.Language = .{ .strings = &words };
    var buffer: LabelBuffer = undefined;
    try std.testing.expectEqualStrings("0 balises", targetText(&buffer, strings, 0).?);
    try std.testing.expectEqualStrings("1 balise", targetText(&buffer, strings, 1).?);
    try std.testing.expectEqualStrings("6 balises", targetText(&buffer, strings, 6).?);
    try std.testing.expectEqual(null, targetText(&buffer, .{ .strings = &.{} }, 1));
}

pub const Round = struct {
    beacons: [required]Beacon,
    bounds: deathmatch.Bounds,
    drop_direction: usize = 0,
    last_wait: i32 = 0,

    /// six_beacons_init (0x004B2F10). The host selects the mode after the map has loaded.
    pub fn start(world: gameobj.World, scoring: std.meta.Tag(deathmatch.ArenaScores)) error{ NotArena, MissingExplosions, MissingGate, MissingBeacons }!void {
        if (world.damage_rules != .arena) return error.NotArena;
        if (world.explosions == null) return error.MissingExplosions;
        const all = world.objects;
        var has_gate = false;
        var beacons: [required]Beacon = undefined;
        var found: usize = 0;
        for (all.slots[0..all.count], 0..) |*slot, i| switch (slot.object.type.base()) {
            .dm_beacon_gate => has_gate = true,
            .dm_beacon => if (found < required) {
                beacons[found] = .{ .object = .of(all, @intCast(i)) };
                found += 1;
            },
            else => {},
        };
        if (!has_gate) return error.MissingGate;
        if (found != required) return error.MissingBeacons;
        deathmatch.startRound(all, scoring);
        all.arena_scenario = .{ .six_beacons = .{ .beacons = beacons, .bounds = .of(all) } };
        const round = &all.arena_scenario.six_beacons;
        round.reset(world);
        round.repair(world);
    }

    pub fn snapshot(round: *const Round) Snapshot {
        return .{ .beacons = round.beacons };
    }

    pub fn carried(round: *const Round, pilot: players.ParticipantRef) usize {
        return count(&round.snapshot().hudSnapshot().carriers, pilot, null);
    }

    /// pickup_place_at_marker (0x004B27F0) uses the first marker at least two beacon radii
    /// from each other beacon. It keeps the current position if all markers are occupied.
    fn place(round: *const Round, world: gameobj.World, index: u16) void {
        const all = world.objects;
        const slot = &all.slots[index];
        slot.object.flags.disabled = false;
        slot.object.flags.targetable = true;
        for (all.slots[0..all.count]) |*marker| {
            if (marker.object.type.base() != .beacon_marker) continue;
            for (round.beacons) |other| {
                const at = other.object.resolve(all) orelse continue;
                if (at != index and math.distance(marker.object.position(), all.slots[at].object.position()) < 2 * slot.object.radius) break;
            } else {
                objects.setPlace(&slot.object, &slot.drawn, marker.object.placeAt(.now));
                sound3d.playIn(world, null, null, index, .dmspawn2, 1, .not_reserved);
                return;
            }
        }
    }

    /// six_beacons_reset (0x004B2FF0) clears every carrier and places all six pickups.
    fn reset(round: *Round, world: gameobj.World) void {
        for (&round.beacons) |*beacon| {
            beacon.carrier = null;
            round.place(world, beacon.object.resolve(world.objects) orelse continue);
        }
    }

    /// six_beacons_drop (0x004B30D0) returns the pilot's beacons beside the dying or
    /// departing ship. Repeating the operation after its cargo is gone has no effect.
    pub fn drop(round: *Round, all: *create.Objects, index: u16) void {
        const binding = all.playerBinding(index) orelse return;
        const ship = &all.slots[index].object;
        for (&round.beacons) |*beacon| {
            if (!std.meta.eql(beacon.carrier orelse continue, binding)) continue;
            beacon.carrier = null;
            const item = &all.slots[beacon.object.resolve(all) orelse continue];
            const offset = drop_directions[round.drop_direction] * @as(math.Vector, @splat(drop_radius_share * ship.radius));
            round.drop_direction = (round.drop_direction + 1) % required;
            objects.setPosition(&item.object, &item.drawn, ship.position() + offset);
            item.object.flags.disabled = false;
            item.object.flags.targetable = true;
        }
    }

    /// six_beacons_frame (0x004B3300) maintains six objectives. Bind new map objects only
    /// when a tracked beacon is gone. A replacement in its slot starts without a carrier.
    fn repair(round: *Round, world: gameobj.World) void {
        const all = world.objects;
        for (all.slots[0..all.count], 0..) |*slot, i| {
            if (slot.object.type.base() != .dm_beacon) continue;
            const index: u16 = @intCast(i);
            const beacon = round.track(all, index) orelse {
                slot.object.flags.disabled = true;
                continue;
            };
            if (beacon.carrier != null) {
                slot.object.flags.disabled = true;
            } else if (slot.object.flags.disabled) round.place(world, index);
        }
    }

    fn track(round: *Round, all: *const create.Objects, index: u16) ?*Beacon {
        var missing: ?*Beacon = null;
        for (&round.beacons) |*beacon| {
            if (beacon.object.resolve(all)) |live| {
                if (live == index) return beacon;
            } else if (missing == null) {
                missing = beacon;
            }
        }
        const replacement = missing orelse return null;
        replacement.* = .{ .object = .of(all, index) };
        return replacement;
    }

    /// six_beacons_total (0x004B3510). The original waits for all six beacons to be
    /// accounted for before it accepts another pickup.
    fn ready(round: *const Round, all: *const create.Objects) bool {
        for (round.beacons) |beacon| {
            const index = beacon.object.resolve(all) orelse return false;
            if (all.slots[index].object.flags.disabled != (beacon.carrier != null)) return false;
        }
        return true;
    }

    /// pickup_frame (0x004B24A0) checks ships and pickup objects in slot order.
    fn collect(round: *Round, world: gameobj.World) void {
        const all = world.objects;
        if (!round.ready(all)) return;
        const states = all.player_states[0..all.playerSlotCount()];
        var joined: usize = 0;
        for (states) |*state| {
            if (state.membership == .joined) joined += 1;
        }
        for (states, 0..) |*state, i| {
            const index: u16 = @intCast(i);
            const binding = all.playerBinding(index) orelse continue;
            const ship = &all.slots[index];
            if (!all.hasBoundPlayerShip(index) or ship.running(.explode) != null or ship.running(.deathmatch_respawn_effect) != null) continue;
            if (world.clock.frame_start < state.membership.joined.pickups_after) continue;
            for (&round.beacons) |*beacon| {
                if (beacon.carrier != null) continue;
                const item = &all.slots[beacon.object.slot];
                if (math.distance(ship.drawn.position, item.drawn.position) >= ship.object.radius + item.object.radius) continue;
                if (joined < 2) {
                    if (world.clock.frame_start -| round.last_wait > wait_notice_gap) Notice.post(world, binding.participant, .waiting_for_players);
                    round.last_wait = world.clock.frame_start;
                    break;
                }
                round.take(world, beacon, binding);
            }
        }
    }

    /// six_beacons_collect (0x004B2300) hides the pickup. Pilots who had it targeted
    /// switch to the next hostile target (0x004B23AF).
    fn take(round: *Round, world: gameobj.World, beacon: *Beacon, pilot: players.ControlRef) void {
        const all = world.objects;
        beacon.carrier = pilot;
        all.slots[beacon.object.slot].object.flags.disabled = true;
        if (round.carried(pilot.participant) == required) Notice.post(world, pilot.participant, .all_collected);
        for (all.player_states[0..all.playerSlotCount()], 0..) |*state, i| {
            if (state.membership != .joined) continue;
            const owner: u16 = @intCast(i);
            const entry = ai.controlEntry(all, owner) orelse continue;
            if (entry.target.slotIn(all) == beacon.object.slot) {
                _ = input.cycleTargetFor(world.display, all, owner, .next, .hostile, true);
            }
        }
        const index = pilot.participant.slot;
        sound3d.playIn(world, null, null, index, .dmpickup, 1, sound3d.fxClass(all, index));
    }

    /// Gate contact (0x004B19D2) calls six_beacons_check_nuke (0x004B32C0).
    /// Contact with any gate fires the blast at the first gate in the map (0x004B3180).
    fn checkGate(round: *Round, world: gameobj.World) void {
        const all = world.objects;
        const carrier = round.beacons[0].carrier orelse return;
        if (round.carried(carrier.participant) != required or !round.ready(all)) return;
        const pilot = all.playerBindingFor(carrier.ship, carrier.participant.generation) orelse return;
        const index = pilot.participant.slot;
        var first: ?math.Place = null;
        for (all.slots[0..all.count]) |*slot| {
            if (slot.object.type.base() != .dm_beacon_gate) continue;
            if (first == null) first = slot.drawn;
            if (math.distance(all.slots[index].drawn.position, slot.drawn.position) > gate_distance) continue;
            @import("../explode.zig").uberExplode(world, index, first.?, round.bounds.radius * blast_radius_share, blast_ticks);
            Notice.post(world, pilot.participant, .triggered);
            if (world.flash) |flash| flash.start();
            world.shake.* = 1;
            sound3d.playIn(world, null, null, index, .dmdrop, 1, sound3d.fxClass(all, index));
            round.reset(world);
            return;
        }
    }

    /// six_beacons_frame (0x004B3300) maintains the objectives before
    /// mp_arena_pickups_frame (0x004B18E0) handles pickups and checks the gate.
    pub fn frame(round: *Round, world: gameobj.World) void {
        const all = world.objects;
        if (@mod(world.clock.frame_start, boundary_interval) == 0) {
            for (round.beacons) |beacon| {
                if (beacon.carrier != null) continue;
                const index = beacon.object.resolve(all) orelse continue;
                if (math.distance(all.slots[index].drawn.position, round.bounds.centre) > round.bounds.radius - boundary_margin) round.place(world, index);
            }
        }
        if (@mod(world.clock.frame_start, repair_interval) == 0) round.repair(world);
        round.collect(world);
        round.checkGate(world);
    }
};

const Arena = struct {
    stage: @import("../explode.zig").testing.Stage,
    host: gameobj.World,
    pilot: players.ParticipantRef,
    notices: std.ArrayList(Notice) = .empty,

    fn init(arena: *Arena) !void {
        arena.* = .{ .stage = undefined, .host = undefined, .pilot = undefined };
        try arena.stage.initShowing(null);
        errdefer arena.stage.deinit();
        arena.host = arena.stage.world();
        arena.host.damage_rules = .{ .arena = null };
        arena.host.beacon_notices = .{ .context = arena, .send = receive };
        const mission = &arena.stage.mission;
        const all = mission.objects;
        all.players = 2;
        for (0..all.players) |_| {
            const index = try mission.add(.of(.predator), .{ -500, 0, 0 });
            mission.slot(index).object.radius = 10;
        }
        arena.pilot = all.joinParticipant(0).?;
        _ = all.bindParticipant(arena.pilot, .of(all, 0)).?;
        const gate = try mission.add(.of(.dm_beacon_gate), @splat(0));
        mission.slot(gate).object.radius = 100;
        for (0..required) |i| {
            const x: f32 = @floatFromInt(5000 + i * 1000);
            const marker = try mission.add(.of(.beacon_marker), .{ x, 0, 0 });
            mission.slot(marker).object.radius = 0;
            const beacon = try mission.add(.of(.dm_beacon), .{ 20000, 0, 0 });
            mission.slot(beacon).object.radius = 20;
        }
        try Round.start(arena.host, .free_for_all);
        mission.clock.frame_start = 31;
    }

    fn deinit(arena: *Arena) void {
        arena.notices.deinit(std.testing.allocator);
        arena.stage.deinit();
    }

    fn receive(context: *anyopaque, notice: Notice) void {
        const arena: *Arena = @ptrCast(@alignCast(context));
        arena.notices.append(std.testing.allocator, notice) catch @panic("out of memory");
    }

    fn move(arena: *Arena, index: u16, position: math.Vector) void {
        const slot = arena.stage.mission.slot(index);
        objects.setPosition(&slot.object, &slot.drawn, position);
    }

    fn admitSecond(arena: *Arena) players.ParticipantRef {
        const all = arena.host.objects;
        const pilot = all.joinParticipant(1).?;
        _ = all.bindParticipant(pilot, .of(all, 1)).?;
        return pilot;
    }
};

test "the host announces the sixth pickup and fires once at the gate boundary" {
    var arena: Arena = undefined;
    try arena.init();
    defer arena.deinit();
    const all = arena.host.objects;
    const round = &all.arena_scenario.six_beacons;
    const first = all.slots[round.beacons[0].object.slot].drawn.position;
    try std.testing.expectEqual(math.Vector{ 5000, 0, 0 }, first);
    try std.testing.expectEqual(math.Vector{ 4950, 0, 0 }, round.bounds.centre);
    try std.testing.expectEqual(5050, round.bounds.radius);
    arena.move(0, first);
    round.frame(arena.host);
    round.frame(arena.host);
    try std.testing.expectEqual(0, round.carried(arena.pilot));
    try std.testing.expectEqual(1, arena.notices.items.len);
    try std.testing.expectEqual(Notice.Kind.waiting_for_players, arena.notices.items[0].kind);

    const rival = arena.admitSecond();
    arena.move(0, first + math.Vector{ 30, 0, 0 });
    round.frame(arena.host);
    try std.testing.expectEqual(0, round.carried(arena.pilot));
    arena.move(rival.slot, first);
    for (round.beacons, 0..) |beacon, i| {
        arena.move(0, all.slots[beacon.object.slot].drawn.position);
        _ = @import("../main.zig").missionFrame(.of(arena.host), .{}, null);
        try std.testing.expectEqual(i + 1, round.carried(arena.pilot));
    }
    try std.testing.expectEqual(0, round.carried(rival));
    try std.testing.expectEqual(Notice.Kind.all_collected, arena.notices.items[1].kind);
    try std.testing.expectEqual(null, arena.stage.explosions.uber.blast);
    arena.move(0, .{ 2501, 0, 0 });
    round.frame(arena.host);
    try std.testing.expectEqual(null, arena.stage.explosions.uber.blast);
    arena.move(0, .{ 2500, 0, 0 });
    round.frame(arena.host);
    const blast = arena.stage.explosions.uber.blast.?;
    try std.testing.expectEqual(arena.pilot.slot, blast.owner.object.slot);
    try std.testing.expectEqual(math.Vector{ 0, 0, 0 }, blast.place.position);
    try std.testing.expectEqual(round.bounds.radius * blast_radius_share, blast.size);
    try std.testing.expectEqual(blast_ticks, blast.duration);
    try std.testing.expectEqual(Notice.Kind.triggered, arena.notices.items[2].kind);
    try std.testing.expectEqual(arena.pilot, arena.notices.items[2].pilot);
    try std.testing.expectEqual(0, round.carried(arena.pilot));
    for (round.beacons) |beacon| {
        const flags = all.slots[beacon.object.slot].object.flags;
        try std.testing.expect(flags.targetable and !flags.disabled);
    }
    round.frame(arena.host);
    try std.testing.expectEqual(3, arena.notices.items.len);
}

test "leaving, destruction and replacement release cargo to the map" {
    var arena: Arena = undefined;
    try arena.init();
    defer arena.deinit();
    const all = arena.host.objects;
    const round = &all.arena_scenario.six_beacons;
    const rival = arena.admitSecond();
    const beacon = round.beacons[0].object.slot;
    const position = all.slots[beacon].drawn.position;
    arena.move(rival.slot, position);
    round.frame(arena.host);
    try std.testing.expectEqual(1, round.carried(rival));
    try std.testing.expect(create.Objects.leaveParticipant(arena.host, rival));
    try std.testing.expectEqual(position + math.Vector{ 8, 0, 0 }, all.slots[beacon].drawn.position);
    const successor = arena.admitSecond();
    try std.testing.expect(!create.Objects.leaveParticipant(arena.host, rival));
    try std.testing.expectEqual(0, round.carried(successor));

    arena.move(rival.slot, .{ -500, 0, 0 });
    arena.move(0, position);
    round.frame(arena.host);
    try std.testing.expectEqual(1, round.carried(arena.pilot));
    const ctx: @import("../aigeneric.zig").Context = .of(arena.host);
    try std.testing.expect(try @import("../aigeneric.zig").push(ctx, 0, .explode, .none));
    arena.stage.mission.ordersAfter(ctx, 0, 1);
    try std.testing.expectEqual(0, round.carried(arena.pilot));
    try std.testing.expectEqual(position - math.Vector{ 8, 0, 0 }, all.slots[beacon].drawn.position);
    round.frame(arena.host);
    try std.testing.expectEqual(0, round.carried(arena.pilot));
    const mission = &arena.stage.mission;
    if (all.playerBinding(0) != null) {
        mission.clock.frame_start = all.slots[0].state.explode.end + 1;
        @import("../aigeneric.zig").objectOrders(ctx, 0);
    }
    const main = @import("../main.zig");
    try std.testing.expectEqual(main.Ending.playing, arena.host.player.ending);
    arena.host.player.viewing.view = .pull_back;
    mission.clock.mission_ticks = 601;
    try std.testing.expect(!main.missionOver(arena.host));
    try std.testing.expect(main.missionOver(mission.world()));
    try std.testing.expectEqual(arena.stage.mission.clock.frame_start + 100, all.player_states[0].membership.joined.pickups_after);

    create.resetSlot(ctx, 0);
    _ = try create.createObject(all, &mission.tables, create.testing.no_models, 0, .of(.predator), 0, position, &mission.random);
    all.slots[0].object.radius = 10;
    _ = all.bindParticipant(arena.pilot, .of(all, 0)).?;
    mission.clock.frame_start += 99;
    round.frame(arena.host);
    try std.testing.expectEqual(0, round.carried(arena.pilot));
    mission.clock.frame_start += 1;
    round.frame(arena.host);
    try std.testing.expectEqual(1, round.carried(arena.pilot));
    create.resetSlot(ctx, 0);

    arena.move(successor.slot, position);
    round.frame(arena.host);
    try std.testing.expectEqual(1, round.carried(successor));
    create.resetSlot(ctx, successor.slot);
    try std.testing.expectEqual(0, round.carried(successor));
    try std.testing.expectEqual(position - math.Vector{ 0, 8, 0 }, all.slots[beacon].drawn.position);
}

test "beacon maintenance restores map pickups and ignores reused slots of another type" {
    var arena: Arena = undefined;
    try arena.init();
    defer arena.deinit();
    const all = arena.host.objects;
    const round = &all.arena_scenario.six_beacons;
    _ = arena.admitSecond();
    const beacon = round.beacons[0].object.slot;
    const marker = all.slots[beacon].drawn;
    arena.move(beacon, .{ -50000, 0, 0 });
    arena.stage.mission.clock.frame_start = 50;
    round.frame(arena.host);
    try std.testing.expectEqual(marker, all.slots[beacon].drawn);
    all.slots[beacon].object.flags.disabled = true;
    arena.stage.mission.clock.frame_start = 75;
    round.frame(arena.host);
    try std.testing.expect(!all.slots[beacon].object.flags.disabled);

    create.resetSlot(.of(arena.host), beacon);
    const replacement = try arena.stage.mission.add(.of(.dm_beacon), marker.position);
    round.frame(arena.host);
    try std.testing.expectEqual(replacement, round.beacons[0].object.resolve(all).?);
    try std.testing.expectEqual(gameobj.GameType.stand_in, all.slots[beacon].object.type.base());
    deathmatch.startRound(all, .teams);
    try std.testing.expect(all.arena_scenario == .deathmatch);
    try std.testing.expectError(error.NotArena, Round.start(arena.stage.world(), .free_for_all));
    try std.testing.expect(all.arena_scores == .teams);
}

test "a new viewer sees all carriers on its first frame and follows loss and delivery" {
    var arena: Arena = undefined;
    try arena.init();
    defer arena.deinit();
    const all = arena.host.objects;
    const round = &all.arena_scenario.six_beacons;
    _ = arena.admitSecond();
    const first = all.playerBinding(0).?;
    const second = all.playerBinding(1).?;
    arena.move(0, all.slots[round.beacons[0].object.slot].drawn.position);
    arena.move(1, all.slots[round.beacons[1].object.slot].drawn.position);
    round.frame(arena.host);

    var viewer = try @import("../main.zig").Drawn.init(std.testing.allocator);
    defer viewer.deinit();
    _ = try viewer.take(arena.host, .{});
    const initial = viewer.beacon_snapshot.?;
    try std.testing.expectEqual(1, initial.countFor(first));
    try std.testing.expectEqual(1, initial.countFor(second));
    try std.testing.expect(create.Objects.leaveParticipant(arena.host, second.participant));
    _ = arena.admitSecond();
    try std.testing.expectEqual(0, initial.countFor(all.playerBinding(1).?));
    var respawned = first;
    respawned.ship.reuse +%= 1;
    try std.testing.expectEqual(0, initial.countFor(respawned));

    arena.move(1, .{ -500, 0, 0 });
    for (round.beacons[1..]) |beacon| {
        arena.move(0, all.slots[beacon.object.slot].drawn.position);
        round.frame(arena.host);
    }
    _ = try viewer.take(arena.host, .{});
    try std.testing.expectEqual(6, viewer.beacon_snapshot.?.countFor(first));
    try std.testing.expectEqual(0, viewer.beacon_snapshot.?.countFor(second));
    try std.testing.expectEqual(1, initial.countFor(first));
    arena.move(0, @splat(0));
    round.frame(arena.host);
    _ = try viewer.take(arena.host, .{});
    try std.testing.expectEqual(0, viewer.beacon_snapshot.?.countFor(first));
    _ = try viewer.take(arena.stage.mission.world(), .{});
    try std.testing.expectEqual(null, viewer.beacon_snapshot);
}
