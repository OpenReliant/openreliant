//! The client's view of a host snapshot, in the records the flight renderer and HUD already read.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const wire = @import("wire.zig");
const stock = @import("stock_arena.zig");
const FlightFrame = @This();

drawn: game.main.Drawn,
tables: game.create.Stats,
random: engine.random.Random = .{},
tick: ?u32 = null,
host_ship_reuse: [wire.slots]u32 = @splat(0),
loaded: ?*game.mission.Loaded = null,
environment: game.environfx.Environment = .{},
beacon_slots: [wire.beacon_count]?u16 = @splat(null),

pub fn create(gpa: std.mem.Allocator, local: *const game.create.Objects, tables: *const game.create.Stats) !*FlightFrame {
    const frame = try gpa.create(FlightFrame);
    errdefer gpa.destroy(frame);
    var random: engine.random.Random = .{};
    const objects = try game.create.Objects.create(gpa, &random);
    objects.count = wire.slots;
    objects.players = wire.slots;
    objects.reuses = local.reuses;
    frame.* = .{
        .drawn = .{
            .gpa = gpa,
            .objects = objects,
            .arena = .init(gpa),
            .player = .{ .viewing = .{ .cockpit_mode = .chase } },
        },
        .tables = tables.*,
        .random = random,
    };
    return frame;
}

pub fn destroy(frame: *FlightFrame) void {
    const gpa = frame.drawn.gpa;
    if (frame.loaded) |loaded| loaded.destroy();
    frame.drawn.objects.destroy();
    frame.drawn.arena.deinit();
    gpa.destroy(frame);
}

pub fn loadArena(frame: *FlightFrame, files: stock.Files, scenario: wire.Scenario, types: game.create.Types) !void {
    if (!scenario.available()) return error.UnsupportedArena;
    const drawn = &frame.drawn;
    frame.loaded = try files.load(drawn.gpa, scenario, .{
        .objects = drawn.objects,
        .player = &drawn.player,
        .clock = &drawn.clock,
        .shake = &drawn.shake,
        .random = &frame.random,
        .spawn = .{ .tables = &frame.tables, .types = types },
        .environment = &frame.environment,
    });
    var count: usize = 0;
    for (drawn.objects.slots[0..drawn.objects.count], 0..) |*slot, index| {
        if (!slot.object.created or slot.object.type.base() != .dm_beacon) continue;
        if (count == frame.beacon_slots.len) return error.InvalidArenaBeacons;
        frame.beacon_slots[count] = @intCast(index);
        count += 1;
    }
    if (count != frame.beacon_slots.len) return error.InvalidArenaBeacons;
}

pub fn apply(frame: *FlightFrame, snapshot: *const wire.Snapshot, admission: wire.Admission, local: *game.create.Objects, types: game.create.Types) !void {
    if (frame.tick == snapshot.tick) return;
    const all = frame.drawn.objects;
    all.player = admission.slot;
    const world: game.gameobj.World = .{ .objects = all, .player = &frame.drawn.player, .random = &frame.random, .clock = &frame.drawn.clock, .shake = &frame.drawn.shake };
    for (snapshot.ships, 0..) |entry, offset| {
        const index: u16 = @intCast(offset);
        const prior = all.playerBinding(index);
        if (prior != null and (entry == null or prior.?.participant.generation != entry.?.generation or frame.host_ship_reuse[index] != entry.?.reuse or all.slots[index].object.type != entry.?.fighter.kind())) {
            game.create.resetSlot(.of(world), index);
            all.player_states[index] = .{ .membership = .vacant };
        }
        const ship = entry orelse continue;
        if (!all.slots[index].object.created) {
            all.loadout_racks[index] = @splat(.of(.none));
            _ = try game.create.createObject(all, &frame.tables, types, index, ship.fighter.kind(), 0, ship.position, &frame.random);
            all.player_states[index] = .{ .membership = .{ .joined = .{
                .generation = ship.generation,
                .ship = .of(all, index),
            } } };
            frame.host_ship_reuse[index] = ship.reuse;
            if (index == admission.slot) {
                _ = try game.aigeneric.push(.of(world), index, .player_control, .none);
                game.main.fitDevices(&all.player_states[index].charges, &frame.drawn.display, game.main.playerShip(ship.fighter.kind()), false);
            } else {
                all.slots[index].object.side = .hostile;
            }
        }
        const slot = &all.slots[index];
        game.objects.setPlace(&slot.object, &slot.drawn, .{ .position = ship.position, .orientation = ship.orientationMatrix() });
        slot.object.speed = ship.speed;
        slot.object.throttle = ship.throttle;
        slot.object.last_throttle = ship.throttle;
        slot.object.afterburner_fuel = ship.fuel;
        slot.object.afterburner = ship.throttle == game.motion.afterburner_throttle;
        slot.object.reverse_thrust = ship.throttle == game.motion.reverse_throttle;
        if (slot.model) |*model| model.place(slot.drawn.position, slot.drawn.orientation);
    }
    // Reserve the identities used during the session in the local mission's slot counters.
    for (local.reuses[0..wire.slots], all.reuses[0..wire.slots]) |*reuse, received| reuse.* = received +% 1;
    frame.drawn.beacon_snapshot = switch (snapshot.objectives) {
        .none => null,
        .six_beacons => |beacons| view: {
            var captured: game.deathmatch.six_beacons.HudSnapshot = .{};
            for (&captured.carriers, beacons, frame.beacon_slots) |*carrier, value, marker| {
                if (value == .carried) carrier.* = all.playerBinding(value.carried);
                if (marker) |index| {
                    const slot = &all.slots[index];
                    slot.object.flags.disabled = value != .loose;
                    if (value == .loose) {
                        const orientation = slot.object.root.orientation;
                        game.objects.setPlace(&slot.object, &slot.drawn, .{ .position = value.loose, .orientation = orientation });
                        if (slot.model) |*model| model.place(slot.drawn.position, orientation);
                    }
                }
            }
            break :view captured;
        },
    };
    const ticks = snapshot.tick *| game.gameobj.ticks_per_step;
    frame.drawn.clock.game_ticks = ticks;
    frame.drawn.clock.mission_ticks = @intCast(@min(ticks, std.math.maxInt(i32)));
    frame.drawn.clock.frame_start = frame.drawn.clock.mission_ticks;
    frame.drawn.display.messages.expire(frame.drawn.clock.frame_start);
    const seconds = ticks / game.main.ticks_per_second;
    frame.drawn.clock.play = .{
        .ticks = @intCast(ticks % game.main.ticks_per_second),
        .seconds = @intCast(seconds % std.time.s_per_min),
        .minutes = @intCast(seconds % std.time.s_per_hour / std.time.s_per_min),
        .hours = @intCast(seconds / std.time.s_per_hour),
    };
    frame.tick = snapshot.tick;
}

test "the flight view follows host admissions and objective carriers" {
    const gpa = std.testing.allocator;
    var random: engine.random.Random = .{};
    const local = try game.create.Objects.create(gpa, &random);
    defer local.destroy();
    const tables = game.create.testing.tables();
    const frame = try create(gpa, local, &tables);
    defer frame.destroy();
    const no_models = game.create.testing.no_models;
    const admission: wire.Admission = .{ .slot = 1, .generation = 2 };
    var snapshot: wire.Snapshot = .{
        .tick = 1,
        .ships = .{
            .{ .generation = 1, .position = .{ 3, 4, 5 } },
            .{ .generation = 2, .position = .{ 8, 0, 1 }, .speed = 12, .throttle = 0.75, .fuel = 240 },
            null,
        },
        .objectives = .{ .six_beacons = @splat(.{ .loose = @splat(0) }) },
    };
    snapshot.objectives.six_beacons[0] = .{ .carried = 1 };
    try frame.apply(&snapshot, admission, local, no_models);
    const all = frame.drawn.objects;
    try std.testing.expectEqual(admission.slot, all.player);
    try std.testing.expectEqual(@as(engine.surrender.math.Vector, .{ 3, 4, 5 }), all.slots[0].drawn.position);
    try std.testing.expectEqual(1, frame.drawn.beacon_snapshot.?.countAt(all, all.player));
    const slot = &all.slots[all.player];
    const gauges = game.hud.Cluster.Gauges.of(slot).?;
    try std.testing.expectEqual(12, gauges.speed);
    try std.testing.expectEqual(0.75, gauges.throttle);
    try std.testing.expectEqual(240, slot.object.afterburner_fuel);
    const earlier = all.playerBinding(0).?.ship;
    try std.testing.expect(!earlier.valid(local));

    snapshot.tick += 1;
    snapshot.ships[0].?.generation = 3;
    snapshot.objectives.six_beacons[0] = .{ .loose = .{ 8, 0, 1 } };
    try frame.apply(&snapshot, admission, local, no_models);
    try std.testing.expect(!earlier.valid(all));
    try std.testing.expectEqual(3, all.playerBinding(0).?.participant.generation);
    try std.testing.expectEqual(0, frame.drawn.beacon_snapshot.?.countAt(all, all.player));
}
