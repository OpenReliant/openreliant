//! The client's view of a host snapshot, in the records the flight renderer and HUD already read.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const wire = @import("wire.zig");
const stock = @import("stock_arena.zig");
const Projectiles = @import("projectiles.zig");
const FlightFrame = @This();

drawn: game.main.Drawn,
tables: game.create.Stats,
random: engine.random.Random = .{},
tick: ?u32 = null,
host_ship_reuse: [wire.slots]u32 = @splat(0),
deaths_at_spawn: [wire.slots]u32 = @splat(0),
loaded: ?*game.mission.Loaded = null,
environment: game.environfx.Environment = .{},
beacon_slots: [wire.beacon_count]?u16 = @splat(null),
rocks: stock.RockSlots = .{},
shot_ended_at: [game.guns.max_bullets]i32 = @splat(-1),
effect_tick: ?i32 = null,
sounds: ?*game.hog_snd.commands.Commands = null,
lock_tone: game.main.lock.Tone = .{},
projectiles: ?Projectiles = null,

pub fn create(gpa: std.mem.Allocator, local: *const game.create.Objects, tables: *const game.create.Stats) !*FlightFrame {
    const frame = try gpa.create(FlightFrame);
    errdefer gpa.destroy(frame);
    var random: engine.random.Random = .{};
    const objects = try game.create.Objects.create(gpa, &random);
    objects.count = wire.slots;
    objects.players = wire.slots;
    objects.reuses = local.reuses;
    objects.gun_stats = local.gun_stats;
    objects.missile_stats = local.missile_stats;
    objects.bullets.looks = local.bullets.looks;
    objects.bullets.shot_lights = local.bullets.shot_lights;
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

pub const CombatAssets = struct {
    textures: *engine.surrender.surrenderlib.srtexture.Table,
    images: ?game.explode.Explosions.Images,
    ordnance_models: game.objects.Effects,
    trails: game.missiles.trail.Trails.Images,
    sounds: ?*game.hog_snd.commands.Commands = null,
};

pub fn enableCombat(frame: *FlightFrame, assets: CombatAssets) !void {
    const gpa = frame.drawn.gpa;
    frame.drawn.effects.explosions = try .init(gpa, assets.images);
    frame.drawn.effects.sparks = try .create(gpa, assets.textures);
    frame.projectiles = .init(gpa, assets.ordnance_models, assets.trails);
    frame.sounds = assets.sounds;
}

pub fn destroy(frame: *FlightFrame) void {
    const gpa = frame.drawn.gpa;
    if (frame.loaded) |loaded| loaded.destroy();
    if (frame.projectiles) |*shown| shown.deinit();
    if (frame.sounds) |asked| frame.lock_tone.sound(false, asked, frame.drawn.player.viewing.last);
    if (frame.drawn.effects.explosions) |*effects| effects.deinit();
    if (frame.drawn.effects.sparks) |*sparks| sparks.deinit();
    frame.drawn.objects.destroy();
    frame.drawn.arena.deinit();
    gpa.destroy(frame);
}

pub fn presentProjectiles(frame: *FlightFrame, pages: *const [wire.ordnance.Page.pages]?wire.ordnance.Page) !void {
    if (frame.projectiles) |*shown| try shown.apply(frame.world(), pages, frame.tick orelse return);
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
    if (scenario == .asteroid_field) frame.rocks = try .collect(drawn.objects);
    if (scenario != .nuclear_threat) return;
    var count: usize = 0;
    for (drawn.objects.slots[0..drawn.objects.count], 0..) |*slot, index| {
        if (!slot.object.created or slot.object.type.base() != .dm_beacon) continue;
        if (count == frame.beacon_slots.len) return error.InvalidArenaBeacons;
        frame.beacon_slots[count] = @intCast(index);
        count += 1;
    }
    if (count != frame.beacon_slots.len) return error.InvalidArenaBeacons;
}

pub fn applyRoster(frame: *FlightFrame, roster: wire.Roster) void {
    for (roster.pilots, 0..) |entry, index| {
        const membership = &frame.drawn.objects.player_states[index].membership;
        if (membership.* != .joined) continue;
        const peer = entry orelse continue;
        if (peer.generation == membership.joined.generation) membership.joined.name.set(peer.name.slice());
    }
}

pub fn weaponAim(frame: *FlightFrame) wire.ordnance.Aim {
    const all = frame.drawn.objects;
    var aim: wire.ordnance.Aim = .{ .reuse = frame.host_ship_reuse[all.player] };
    const entry = game.ai.controlEntry(all, all.player) orelse return aim;
    const target = entry.target.slotIn(all) orelse return aim;
    if (target != all.player and target < wire.slots and all.playerBinding(target) != null)
        aim.target = .{ .slot = target, .reuse = frame.host_ship_reuse[target] };
    return aim;
}

fn presentWeapons(frame: *FlightFrame, status: ?wire.ordnance.Status) void {
    const all = frame.drawn.objects;
    const slot = &all.slots[all.player];
    const weapons = &all.player_states[all.player].weapons;
    const prior = weapons.ring;
    const decoys_before = slot.object.countermeasures;
    weapons.ring = if (status) |shown| shown.ring() else .{};
    weapons.lock = if (status) |shown| shown.held else .{};
    slot.object.countermeasures = if (status) |shown| shown.countermeasures else 0;
    if (slot.object.countermeasures < decoys_before) game.hud.beep(frame.world(), .done);
    slot.object.missile_homing = @intFromBool(if (status) |shown| shown.incoming else false);
    if (status != null and (weapons.ring.left < prior.left or weapons.ring.armed != prior.armed)) {
        if (frame.drawn.display.windows.open(.missiles, true))
            frame.drawn.display.windows.status.getPtr(.missiles).held = true;
    }
    if (frame.sounds) |asked| frame.lock_tone.sound(weapons.lock.locked(), asked, frame.drawn.player.viewing.last);
}

fn world(frame: *FlightFrame) game.gameobj.World {
    return .{
        .objects = frame.drawn.objects,
        .player = &frame.drawn.player,
        .random = &frame.random,
        .clock = &frame.drawn.clock,
        .shake = &frame.drawn.shake,
        .sounds = frame.sounds,
        .explosions = if (frame.drawn.effects.explosions) |*effects| effects else null,
        .sparks = if (frame.drawn.effects.sparks) |*sparks| sparks else null,
        .display = &frame.drawn.display,
    };
}

fn remoteShip(frame: *const FlightFrame, ref: game.gameobj.ObjectRef) ?u16 {
    if (ref.slot >= wire.slots or frame.host_ship_reuse[ref.slot] != ref.reuse) return null;
    return if (frame.drawn.objects.playerBinding(ref.slot) != null) ref.slot else null;
}

pub fn presentCombat(frame: *FlightFrame, effects: []const game.guns.FlightEffect) void {
    const scene = frame.world();
    if (effects.len == 0 and frame.effect_tick == scene.clock.frame_start) return;
    frame.effect_tick = scene.clock.frame_start;
    for (effects) |effect| switch (effect) {
        .shot => |shot| {
            if (shot.fired_at > frame.shot_ended_at[shot.index]) {
                game.guns.showShot(scene, shot);
                if (shot.owner == scene.objects.player) _ = frame.drawn.display.windows.open(.gunnery, false);
            }
        },
        .impact => |hit| {
            frame.shot_ended_at[hit.shot] = @max(frame.shot_ended_at[hit.shot], hit.fired_at);
            game.guns.showImpact(scene, hit, frame.remoteShip(hit.target));
        },
        .nova => |beam| if (frame.remoteShip(beam.owner)) |owner| game.guns.nova.show(scene, owner, beam),
    };
    game.guns.frameReplicas(scene);
}

pub fn apply(frame: *FlightFrame, snapshot: *const wire.Snapshot, admission: wire.Admission, local: *game.create.Objects, types: game.create.Types) !void {
    if (frame.tick == snapshot.tick) return;
    const all = frame.drawn.objects;
    all.player = admission.slot;
    const scene = frame.world();
    const ticks = snapshot.tick *| game.gameobj.ticks_per_step;
    frame.drawn.clock.drawn_duration = if (frame.tick == null) game.gameobj.ticks_per_step else @intCast(@min(ticks -| frame.drawn.clock.game_ticks, std.math.maxInt(i32)));
    frame.drawn.clock.game_ticks = ticks;
    frame.drawn.clock.mission_ticks = @intCast(@min(ticks, std.math.maxInt(i32)));
    frame.drawn.clock.frame_start = frame.drawn.clock.mission_ticks;
    if (scene.explosions) |effects| effects.frame(scene);
    if (scene.sparks) |sparks| sparks.frame(scene.clock);
    try frame.rocks.apply(all, &snapshot.rocks);
    for (snapshot.ships, 0..) |entry, offset| {
        const index: u16 = @intCast(offset);
        const prior = all.playerBinding(index);
        if (prior != null and entry != null and prior.?.participant.generation == entry.?.generation and
            frame.host_ship_reuse[index] != entry.?.reuse and entry.?.deaths > frame.deaths_at_spawn[index])
        {
            const slot = &all.slots[index];
            const velocity = engine.surrender.math.transform(slot.drawn.orientation, .{ 0, 0, slot.object.speed });
            game.explode.fighterFireball(scene, slot.drawn.position, velocity, slot.object.radius);
        }
        if (prior != null and (entry == null or prior.?.participant.generation != entry.?.generation or frame.host_ship_reuse[index] != entry.?.reuse or all.slots[index].object.type != entry.?.fighter.kind())) {
            game.create.resetSlot(.of(scene), index);
            all.player_states[index] = .{ .membership = .vacant };
        }
        const ship = entry orelse continue;
        if (!all.slots[index].object.created) {
            all.loadout_racks[index] = @splat(.of(.none));
            _ = try game.create.createObject(all, &frame.tables, types, index, ship.fighter.kind(), 0, ship.position, &frame.random);
            if (snapshot.scenario != null) all.slots[index].object.countermeasures = 0;
            all.player_states[index] = .{ .membership = .{ .joined = .{
                .generation = ship.generation,
                .ship = .of(all, index),
            } } };
            frame.host_ship_reuse[index] = ship.reuse;
            frame.deaths_at_spawn[index] = ship.deaths;
            if (index == admission.slot) {
                _ = try game.aigeneric.push(.of(scene), index, .player_control, .none);
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
        slot.object.shields = ship.shields;
        slot.object.armor = ship.armor;
        all.player_states[index].membership.joined.kills.count = ship.kills;
        all.player_states[index].membership.joined.deaths = ship.deaths;
        slot.object.afterburner = ship.throttle == game.motion.afterburner_throttle;
        slot.object.reverse_thrust = ship.throttle == game.motion.reverse_throttle;
        if (slot.model) |*model| model.place(slot.drawn.position, slot.drawn.orientation);
    }
    if (snapshot.scenario != null) frame.presentWeapons(snapshot.weapons);
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
    snapshot.ships[1].?.shields = .{ .left = 1, .right = 2, .fore = 3, .aft = 4 };
    snapshot.ships[1].?.armor = .all(40);
    snapshot.ships[1].?.kills = 2;
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
    try std.testing.expectEqual(snapshot.ships[1].?.shields, slot.object.shields);
    try std.testing.expectEqual(snapshot.ships[1].?.armor, slot.object.armor);
    try std.testing.expectEqual(2, game.hud.Readout.skull.value(all, &frame.drawn.player));
    var roster: wire.Roster = .{};
    roster.pilots[0] = .{ .generation = 1, .name = wire.lobbyName("Falcon") };
    frame.applyRoster(roster);
    try std.testing.expectEqualStrings("Falcon", all.player_states[0].membership.joined.name.slice());
    const earlier = all.playerBinding(0).?.ship;
    try std.testing.expect(!earlier.valid(local));

    snapshot.tick += 1;
    snapshot.ships[0].?.generation = 3;
    snapshot.ships[1].?.reuse = 8;
    snapshot.objectives.six_beacons[0] = .{ .loose = .{ 8, 0, 1 } };
    try frame.apply(&snapshot, admission, local, no_models);
    try std.testing.expect(!earlier.valid(all));
    try std.testing.expectEqual(3, all.playerBinding(0).?.participant.generation);
    frame.applyRoster(roster);
    try std.testing.expectEqualStrings("", all.player_states[0].membership.joined.name.slice());
    try std.testing.expectEqual(0, frame.drawn.beacon_snapshot.?.countAt(all, all.player));
    try std.testing.expectEqual(2, game.hud.Readout.skull.value(all, &frame.drawn.player));
}
