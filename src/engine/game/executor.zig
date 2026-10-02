//! `C:\lancer\game\Executor.cpp`: the mission script's commands.
//! [`executor/commands.zig`](executor/commands.zig) transcribes the command catalogue.
//! **Unverified:** the catalogue lies in the data before this file's path, and some commands lie
//! outside this file's code.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.mission);

const dte = @import("../../formats/dte.zig");
const vm = @import("../vm.zig");
const input = @import("../input.zig");
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const camera = @import("camera.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const follow = @import("ai/follow.zig");
const friendly_fire = @import("friendly_fire.zig");
const guns = @import("guns.zig");
const hud = @import("hud.zig");
const hudmovie = @import("hudmovie.zig");
const launch = @import("launch.zig");
const videoreports = @import("videoreports.zig");
const mission = @import("mission.zig");
const objects = @import("objects.zig");
const math = @import("../surrender/math.zig");
const pilots = @import("pilots.zig");
const Order = @import("ai/orders.zig").Order;

pub const commands = @import("executor/commands.zig");
pub const curves = @import("executor/curves.zig");
pub const director = @import("executor/director.zig");

const Call = vm.machine.Call;
const Ship = vm.Machine.Ship;
const run_on = vm.run_on;
const yield = vm.yield;

/// The catalogue's number of the command `name`: the operand of `command` that runs it.
pub fn commandIndex(comptime name: []const u8) u8 {
    return comptime for (commands.table, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, name)) break index;
    } else @compileError("the Executor has no command " ++ name);
}

/// The implementation of command `number`, or null for one not ported yet
/// ([#281](https://github.com/vdmkenny/openreliant/issues/281)).
pub fn implementation(number: u8) ?vm.Implementation {
    return if (number < implementations.len) implementations[number] else null;
}

/// How the implementations table gives a command: by its implementation, by the work it does in a
/// game (`inGame`), or by the work it does for each ship its first argument names (`perShip`), with
/// the orders it gives meanwhile numbered (`numbered`) or not.
const Entry = union(enum) {
    command: vm.Implementation,
    in_game: vm.GameImplementation,
    per_ship: vm.Machine.ShipImplementation,
    numbered: vm.Machine.ShipImplementation,
};

const implementations = table: {
    @setEvalBranchQuota(10_000);
    var table: [commands.table.len]?vm.Implementation = @splat(null);
    for ([_]struct { []const u8, Entry }{
        .{ "CreateTimer", .{ .command = vm.Machine.createTimer } },
        .{ "DestroyTimer", .{ .command = vm.Machine.destroyTimer } },
        .{ "CreateFlightGroup", .{ .in_game = createFlightGroup } },
        .{ "Wait", .{ .command = vm.Machine.wait } },
        .{ "SetAI", .{ .numbered = setAIShip } },
        .{ "InterruptTriggerCode", .{ .command = vm.Machine.interruptTriggerCode } },
        .{ "Fly", .{ .per_ship = flyShip } },
        .{ "SetRescueProbabilities", .{ .in_game = setRescueProbabilities } },
        .{ "KillAllScriptExecutionExecptMe", .{ .command = vm.Machine.killAllScriptExecutionExceptMe } },
        .{ "PlaySpeech", .{ .in_game = playSpeech } },
        .{ "WaitForSpeech", .{ .command = waitForSpeech } },
        .{ "PlayCommsMovie", .{ .in_game = playCommsMovie } },
        .{ "WaitForMovie", .{ .command = waitForMovie } },
        .{ "SetupLaunch", .{ .numbered = setupLaunchShip } },
        .{ "StartLaunch", .{ .per_ship = startLaunchShip } },
        .{ "SetInvulnerability", .{ .per_ship = setInvulnerabilityShip } },
        .{ "PlayMusic", .{ .in_game = playMusic } },
        .{ "DisableTaunts", .{ .in_game = remarkFlag("taunts_disabled") } },
        .{ "DisableGenericComms", .{ .in_game = remarkFlag("generic_comms_disabled") } },
        .{ "UpdateEnvironmentFXState", .{ .in_game = updateEnvironmentFXState } },
        .{ "CommsFromShip", .{ .command = comms(.ship, .looping) } },
        .{ "CommsFromPilot", .{ .command = comms(.pilot, .looping) } },
        .{ "CommsFromShipOnce", .{ .command = comms(.ship, .once) } },
        .{ "CommsFromPilotOnce", .{ .command = comms(.pilot, .once) } },
        .{ "WaitForJumpOrLaunch", .{ .command = waitForJumpOrLaunch } },
        .{ "SetEnvironmentFXNebula", .{ .in_game = setEnvironmentFXNebula } },
        .{ "SetEnvironmentFX", .{ .in_game = setEnvironmentFX } },
        .{ "OpenInstrument", .{ .in_game = vm.Machine.openInstrument } },
        .{ "CloseInstrument", .{ .in_game = vm.Machine.closeInstrument } },
        .{ "SetObjective", .{ .in_game = setObjective } },
        .{ "SetShipAvoidance", .{ .per_ship = setShipAvoidanceShip } },
        .{ "MultiplayerScriptSync", .{ .command = multiplayerScriptSync } },
        .{ "SetTriggerState", .{ .command = vm.triggers.setTriggerState } },
        .{ "SetAnyTriggerState", .{ .command = vm.triggers.setAnyTriggerState } },
        .{ "WhenPlayerLastJumped", .{ .command = whenPlayerLastJumped } },
        .{ "DestroyFlightGroup", .{ .in_game = destroyFlightGroup } },
        .{ "ClearAI", .{ .per_ship = clearAIShip } },
        .{ "StartShipAnimation", .{ .in_game = startShipAnimation } },
        .{ "StartShipAnimationReverse", .{ .in_game = startShipAnimationReverse } },
        .{ "DisableObject", .{ .per_ship = disableObjectShip } },
        .{ "PositionRelative", .{ .per_ship = positionRelativeShip } },
        .{ "SetPlayerTarget", .{ .in_game = setPlayerTarget } },
        .{ "SetTargetable", .{ .per_ship = setTargetableShip } },
        .{ "SetActionCentre", .{ .in_game = setActionCentre } },
        .{ "DisableGuns", .{ .per_ship = flagShip("guns_disabled") } },
        .{ "DisableEject", .{ .per_ship = flagShip("eject_disabled") } },
        .{ "SetHostile", .{ .per_ship = setHostileShip } },
        .{ "DoNotDisturb", .{ .per_ship = flagShip("do_not_disturb") } },
        .{ "SetEscortPoint", .{ .per_ship = setEscortPointShip } },
        .{ "SetPrimaryTarget", .{ .in_game = setPrimaryTarget } },
        .{ "SnapToPoint", .{ .in_game = snapToPoint } },
        .{ "IsShipThisPlayer", .{ .command = isShipThisPlayer } },
        .{ "SetFlybackMarker", .{ .in_game = setFlybackMarker } },
        .{ "ResetFlybackMarker", .{ .in_game = resetFlybackMarker } },
        .{ "MatchSpeed", .{ .in_game = matchSpeed } },
        .{ "Dock", .{ .in_game = dock } },
        .{ "ShipFollowCurve", .{ .per_ship = followCurveShip(.ship_follow_curve, false) } },
        .{ "MovingShipFollowCurve", .{ .per_ship = followCurveShip(.ship_follow_curve, true) } },
        .{ "MovingShipBackupCurve", .{ .per_ship = followCurveShip(.ship_follow_curve_backwards, true) } },
        .{ "StartDirectorCam", .{ .in_game = startDirectorCam } },
        .{ "StackDirectorCam", .{ .in_game = stackDirectorCam } },
        .{ "StopDirectorCam", .{ .in_game = stopDirectorCam } },
        .{ "WaitForDirectorCam", .{ .command = waitForDirectorCam } },
        .{ "FriendlyFire", .{ .in_game = friendlyFire } },
        .{ "DestroySubObject", .{ .in_game = destroySubObject } },
        .{ "ReplaceSubObject", .{ .in_game = replaceSubObject } },
        .{ "DisableLights", .{ .per_ship = disableLightsShip } },
        .{ "TerminateMission", .{ .in_game = terminateMission } },
        .{ "TurretSetTarget", .{ .per_ship = turretSetTargetShip } },
        .{ "ReplenishWeapons", .{ .in_game = replenishWeapons } },
        .{ "DisableListing", .{ .in_game = disableListing } },
        .{ "Scanner", .{ .in_game = scanner } },
        .{ "Fire", .{ .in_game = fire } },
    }) |pair| {
        const number = commandIndex(pair[0]);
        table[number] = switch (pair[1]) {
            .command => |run| run,
            .in_game => |work| inGame(work),
            // A command the table walks the ships for is one the game hands `for_each_ship` a
            // routine.
            .per_ship => |each| perShip(each),
            .numbered => |each| numbered(each),
        };
        switch (pair[1]) {
            .per_ship, .numbered => assert(commands.table[number].per_ship != null),
            .command, .in_game => {},
        }
    }
    break :table table;
};

/// A command that does `work` in a game, and nothing outside one, and lets its thread run on: each
/// of the game's commands that always ends so.
fn inGame(comptime work: vm.GameImplementation) vm.Implementation {
    return &struct {
        fn run(call: Call) u32 {
            if (call.machine.game) |game| work(call, game);
            return run_on;
        }
    }.run;
}

/// A command that runs `each` for each ship its first argument names (`for_each_ship`,
/// `vm.Machine.forEachShip`), and lets its thread run on: each of the game's commands that hands
/// `for_each_ship` a routine of its own, its `cmd_<name>_ship`, and does nothing else.
fn perShip(comptime each: vm.Machine.ShipImplementation) vm.Implementation {
    return &struct {
        fn run(call: Call) u32 {
            vm.Machine.forEachShip(call, each);
            return run_on;
        }
    }.run;
}

/// `perShip`, the orders pushed meanwhile numbered from 0 as they are given
/// (`aigeneric.startNumbering`), as `cmd_SetAI` (`0x004581F0`) and `cmd_SetupLaunch`
/// (`0x00458970`) give theirs.
fn numbered(comptime each: vm.Machine.ShipImplementation) vm.Implementation {
    return &struct {
        fn run(call: Call) u32 {
            const game = call.machine.game orelse return run_on;
            aigeneric.startNumbering(game.world.objects);
            vm.Machine.forEachShip(call, each);
            aigeneric.stopNumbering(game.world.objects);
            return run_on;
        }
    }.run;
}

/// `cmd_CreateFlightGroup` (`0x00457C40`, command `0x03`): creates each ship of the flight group
/// its argument names, in the mission's order (`createShip`), then lists the flight groups in
/// their wings (`mission.buildWings`).
///
/// **Fix:** the game stops with a fatal error where the argument names no flight group; OpenReliant
/// creates nothing.
fn createFlightGroup(call: Call, game: aigeneric.Context) void {
    const machine = call.machine;
    const group = machine.mission.flightGroup(machine.mission.flightGroupIndex(call.args[0]) orelse return) orelse return;
    for (machine.mission.groupShips(group.*)) |ship| createShip(game, machine.mission, ship);
    mission.buildWings(game.world.objects, machine.mission);
}

/// `mission_ship_create` (`0x00457CD0`): creates the object of mission ship `index` in the slot of
/// its index, as its record has it, turned by its record (`mission.recordOrientation`).
///
/// A nav point or a marker (`dte.Ship.isMarker`) is a `gameobj.Type.marker` at its place.
///
/// Any other ship is an object of its kind (`shipType`), fitted by its loadout tier, at its place,
/// with its atmosphere where it is a planet that has one (`atmosphere.Atmospheres.made`), set up as
/// a planet where it is one (`create.planetMade`), and as a gate where it is one
/// (`create.gateMade`). It gets its first order: Player Control for the player's ship, whose view
/// the camera takes (view 0), Multiplayer Control for another player's, and Do Nothing for the
/// rest. A ship that launches gets a Launch order through the gate it names of the first of the
/// mission's ships of the kind it launches from, which starts at once (`aigeneric.objectOrders`),
/// and a ship flown by a pilot of `pilotstats.bin` gets the pilot.
///
/// The game also counts the nav points it makes (`nav_point_count`, `0x00565698`), which nothing
/// reads, and logs lines; OpenReliant leaves both out.
pub fn createShip(game: aigeneric.Context, bound: *const mission.Mission, index: u16) void {
    const all = game.world.objects;
    const spawn = game.world.spawn orelse return;
    const ships = bound.ships() catch return;
    if (index >= ships.len) return;
    const ship = ships[index];
    const marker = ship.isMarker();
    const kind: gameobj.Type, const tier: u8 = if (marker) .{ .marker, 0 } else .{ shipType(all, bound, ship), ship.tier };
    const made = create.createObject(all, spawn.tables, spawn.types, index, kind, tier, ship.position, game.world.random) catch |err| {
        log.warn("mission ship {d} is not made: {s}", .{ index, @errorName(err) });
        return;
    };
    const slot = &all.slots[made];
    const turn = mission.recordOrientation(ship);
    if (marker) return objects.setOrientation(&slot.object, &slot.drawn, turn);
    if (game.world.atmospheres) |atmospheres| atmospheres.made(all, made);
    create.planetMade(all, made);
    create.gateMade(game.world, made);
    const first: Order = if (made >= all.players) .do_nothing else if (made == all.player) .player_control else .multiplayer_control;
    _ = aigeneric.give(game, made, first, .none);
    if (made == all.player) if (game.world.camera) |view| {
        _ = view.setView(.cockpit, made, false, false, game.world.clock.viewTime());
    };
    objects.setOrientation(&slot.object, &slot.drawn, turn);
    if (ship.launchGate()) |gate| for (ships, 0..) |carrier, from| {
        if (carrier.kind != ship.launch_from) continue;
        _ = aigeneric.giveShip(game, made, .launch, @intCast(from), gate);
        aigeneric.objectOrders(game, made);
        break;
    };
    if (ship.pilotRecord()) |pilot| pilots.setPilot(&slot.object, pilot);
}

/// The type `mission_ship_create` asks for a mission ship of: its kind, save that from
/// `create.twins_from_mission` on a ship of the player's wing flies the `t_` twin of its kind, or
/// a Kamov in mission 25's first part.
///
/// **Fix:** from `create.twins_from_mission` on, the game takes a ship of the player's wing whose
/// kind is none of the player's ships for the object in the slot its record's address gives, and
/// reads the wing of a ship in no flight group from past the groups; OpenReliant makes the first of
/// its own kind, and takes the second for a ship of no wing.
fn shipType(all: *const create.Objects, bound: *const mission.Mission, ship: dte.Ship) gameobj.Type {
    const kind: gameobj.Type = @enumFromInt(ship.kind);
    if (all.mission_number < create.twins_from_mission) return kind;
    const group = bound.flightGroup(ship.flightGroup() orelse return kind) orelse return kind;
    if (group.wing != .player) return kind;
    if (all.kamovPart()) return .kamov;
    return kind.twin() orelse kind;
}

/// `cmd_SetAI` (`0x004581F0`, command `0x0B`) and `cmd_SetAI_ship` (`0x00458220`), for each ship
/// the first argument names, the orders numbered from 0 as they are given (`numbered`): pushes the
/// order the command's second argument gives on the ship's stack, aimed at what its fourth names: a
/// flight group or a squad by its index, or a ship by its slot and the component `push_component`
/// named for it, or nothing. The third, whether the order starts at once, is not read.
fn setAIShip(call: Call, ship: Ship) void {
    const machine = call.machine;
    const aim = call.args[2];
    const target = recordTarget(machine, aim, shipTarget(machine, call.thread, aim, 3));
    const order: Order = @enumFromInt(halfword(call.args[0]));
    _ = aigeneric.give(ship.game, ship.index, order, target);
}

/// The dispatch on `record_kind` that `SetAI`, `SetupLaunch` and `Dock` share for what `place`
/// names (`cmd_SetAI_ship`, `cmd_SetupLaunch_ship`, `cmd_Dock`): a flight group or a squad by its
/// index, whole, and `ship` for a ship's record or for a place that is none of the three, which
/// `record_kind` gives as `0xFFFF` and the commands take as a ship's.
fn recordTarget(machine: *const vm.Machine, place: u32, ship: aigeneric.Target) aigeneric.Target {
    return switch (machine.mission.recordKind(place) orelse .ship) {
        .flight_group => .group(.flight_group, machine.mission.flightGroupIndex(place)),
        .squad => .group(.squad, machine.mission.squadIndex(place)),
        .ship => ship,
    };
}

/// The target a command aims at the ship `aim` names: its slot, and the component
/// `push_component` named for the command's argument `argument`, or none where `aim` names no
/// ship.
fn shipTarget(machine: *const vm.Machine, thread: u8, aim: u32, argument: u8) aigeneric.Target {
    const ship = machine.mission.shipIndex(aim) orelse return .none;
    return .of(.ship, ship, machine.argumentComponent(thread, argument) orelse aigeneric.Target.whole);
}

/// Gives the ship `order` aimed at `target` (`aigeneric.give`), and the entry on top of its stack
/// that took it, which the command then fills in; null where the ship does not take it.
fn given(ship: Ship, order: Order, target: aigeneric.Target) ?*aigeneric.Entry {
    if (!aigeneric.give(ship.game, ship.index, order, target)) return null;
    return ship.slot.current();
}

/// `cmd_Fly` (`0x00458F50`, command `0x28`) and `cmd_Fly_ship` (`0x00458F70`), for each ship the
/// first argument names (`perShip`): pushes a Fly order on the ship's stack, aimed at the ship the
/// command's second argument names, its slot the halfword the game stores whatever the argument
/// is, or at none, which holds the heading it starts on, at the speed the third gives, or 0 for its
/// full throttle.
///
/// **Fix:** the game writes the speed into whatever order the ship has on top where it refuses
/// Fly: Player Control's mouse stick on the player's ship, which then turns it, or Explode's
/// `may_spin` on an exploding one; OpenReliant writes none.
fn flyShip(call: Call, ship: Ship) void {
    const target: aigeneric.Target = .of(.ship, call.machine.mission.shipIndex(call.args[0]), aigeneric.Target.whole);
    const entry = given(ship, .fly, target) orelse return;
    entry.data.fly = @bitCast(call.args[1]);
}

/// `cmd_SetRescueProbabilities` (`0x004598D0`, command `0x44`): the odds of how the player fares
/// after ejecting: picked up by a nanny ship, by the enemy, and killed, each the whole signed
/// number the mission gives.
fn setRescueProbabilities(call: Call, game: aigeneric.Context) void {
    game.world.player.rescue_odds = .{
        .rescued = @bitCast(call.args[0]),
        .captured = @bitCast(call.args[1]),
        .killed = @bitCast(call.args[2]),
    };
}

/// `cmd_PlaySpeech` (`0x00458090`, command `0x06`): the speech file the argument names plays at
/// once, without the radio's window or a film, ending the line playing
/// (`videoreports.Radio.playSpeech`).
fn playSpeech(call: Call, game: aigeneric.Context) void {
    const radio, const ctx = videoreports.onAir(game.world) orelse return;
    const name = call.machine.mission.text(call.args[0]) catch return;
    radio.playSpeech(ctx.sound, name);
}

/// `cmd_WaitForSpeech` (`0x00458100`, command `0x07`): the thread waits while a line plays
/// (`videoreports.Radio.speaking`), running the command again each time
/// (`vm.machine.Call.againItself`).
fn waitForSpeech(call: Call) u32 {
    const game = call.machine.game orelse return run_on;
    const radio, const ctx = videoreports.onAir(game.world) orelse return run_on;
    return if (radio.speaking(ctx.sound)) call.againItself() else run_on;
}

/// The room the game gives the speech file's name and the film's path (`cmd_PlayCommsMovie`'s
/// buffers, `0x00458120`).
const comms_movie_path_size = 52;

/// `cmd_PlayCommsMovie` (`0x00458120`, command `0x08`): the film the first argument names,
/// `pilots\<film>`, plays in the radio's window with the speech file the second names, at once,
/// looping, under the string the third numbers, the line nobody's. The game also sets a halfword
/// nothing reads (`0x005373EA`).
///
/// **Fix:** the game writes a name longer than its buffer past it; OpenReliant says nothing.
fn playCommsMovie(call: Call, game: aigeneric.Context) void {
    const machine = call.machine;
    const radio, const ctx = videoreports.onAir(game.world) orelse return;
    const film = machine.mission.text(call.args[0]) catch return;
    const speech = machine.mission.text(call.args[1]) catch return;
    var buffer: [comms_movie_path_size]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "pilots\\{s}", .{film}) catch return;
    if (speech.len >= comms_movie_path_size or path.len >= comms_movie_path_size) return;
    radio.say(ctx, .{ .film = path, .speech = speech, .name = @truncate(call.args[2]), .flags = .looping, .object = videoreports.nobody }, .now);
}

/// `cmd_WaitForMovie` (`0x00458180`, command `0x09`): the thread waits while a film of the radio's
/// plays (`hudmovie.Movie.playing`), running the command again each time
/// (`vm.machine.Call.againItself`).
fn waitForMovie(call: Call) u32 {
    const game = call.machine.game orelse return run_on;
    const radio = game.world.radio orelse return run_on;
    return if (radio.movie.playing) call.againItself() else run_on;
}

/// `cmd_SetupLaunch` (`0x00458970`, command `0x13`) and `cmd_SetupLaunch_ship` (`0x004589A0`), for
/// each ship the first argument names, the orders numbered from 0 as they are given (`numbered`),
/// which a launch from a flight group or a squad counts its launch points by (`launch.init`):
/// pushes a Launch order on the ship's stack, aimed at what the command's second argument names it
/// to launch from: a flight group or a squad by its index, whose ships' launch points the launch
/// searches for a gate, or a ship by its slot, through the gate the third argument gives, counted
/// on by one for each ship the walk reached before this one (`launchGate`).
fn setupLaunchShip(call: Call, ship: Ship) void {
    const machine = call.machine;
    const from = call.args[0];
    const target = recordTarget(machine, from, launchGate(machine, from, call.args[1]));
    _ = aigeneric.give(ship.game, ship.index, .launch, target);
}

/// The target `SetupLaunch` aims a ship at to launch from the ship `from` names: through `gate`,
/// the low half of the command's argument, and on by one for each ship its walk reached before
/// this one (`vm.Machine.walk_count`), wrapping round as a halfword does.
fn launchGate(machine: *const vm.Machine, from: u32, gate: u32) aigeneric.Target {
    const counted = @as(u16, @truncate(gate)) +% machine.walk_count -% 1;
    return .of(.ship, machine.mission.shipIndex(from), @bitCast(counted));
}

/// `cmd_StartLaunch` (`0x00458A40`, command `0x14`) and `cmd_StartLaunch_ship` (`0x00458A60`), for
/// each ship the argument names (`perShip`): the ship starts its launch (`launch.start`).
fn startLaunchShip(call: Call, ship: Ship) void {
    _ = call;
    launch.start(ship.game.world.objects, ship.index);
}

/// `cmd_SetInvulnerability` (`0x00458BC0`, command `0x1A`) and `cmd_SetInvulnerability_ship`
/// (`0x00458BE0`), for each ship the first argument names (`perShip`): the ship takes the
/// invulnerability the command's second argument gives, or where the first names one of its
/// components (`push_component`), that component does, which its damage does not read yet
/// (`gameobj.Component.invulnerable`, [#538](https://github.com/vdmkenny/openreliant/issues/538)).
/// A ship in the players' slots is reached only in the training missions
/// (`create.Objects.training`) and in the Reliant's simulator's training (`simulator_mode` 1,
/// `create.Simulator.Mode.training`).
fn setInvulnerabilityShip(call: Call, ship: Ship) void {
    const machine = call.machine;
    const all = ship.game.world.objects;
    if (ship.index < all.players and !all.training() and all.simulator.mode != .training) return;
    const object = &ship.slot.object;
    const value = call.args[0];
    if (machine.argumentComponent(call.thread, 0)) |component| {
        if (component < object.components.len) object.components[component].invulnerable = @truncate(value);
        return;
    }
    object.invulnerable = @enumFromInt(@as(u8, @truncate(value)));
}

/// How loud a mission's music plays (`cmd_PlayMusic`, `0x00458E16`).
const music_level = 80;

/// How many times a mission's music plays: for ever (`cmd_PlayMusic`, `0x00458E18`).
const music_forever = 0;

/// The room the game gives a piece's path (`cmd_PlayMusic`'s buffer, `0x00458DF0`).
const music_path_size = 128;

/// The folder the pieces are in (`cmd_PlayMusic`'s format, `0x004F5C14`).
const music_folder = "music\\";

/// `cmd_PlayMusic` (`0x00458DF0`, command `0x23`): plays the piece the first argument names from
/// the game's music folder, for ever, at once where the second argument is 1, or else once the
/// music playing has faded out (`hog_snd.Sound.When.of`, `hog_snd.Sound.playMusic`).
///
/// **Fix:** the game writes a path longer than its buffer past it; OpenReliant plays nothing.
fn playMusic(call: Call, game: aigeneric.Context) void {
    const hearing = game.world.hearing orelse return;
    const name = call.machine.mission.text(call.args[0]) catch return;
    var buffer: [music_path_size]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, music_folder ++ "{s}", .{name}) catch {
        log.warn("the music {s} is left out: its path is too long", .{name});
        return;
    };
    hearing.sound.playMusic(path, music_forever, music_level, .of(call.args[1], game.world.clock.game_ticks));
}

/// Who a comms command's first argument names to speak: a mission's ship, or a pilot of the
/// pilots' table.
const Speaker = enum { ship, pilot };

/// The radio's comms commands, each ending the frame's handlers (`vm.yield`):
///
/// | Command | Speaker | Film |
/// |---|---|---|
/// | `cmd_CommsFromShip` (`0x00458AC0`, command `0x18`) | `ship` | `looping` |
/// | `cmd_CommsFromPilot` (`0x00458B10`, command `0x19`) | `pilot` | `looping` |
/// | `cmd_CommsFromShipOnce` (`0x00458FD0`, command `0x29`) | `ship` | `once` |
/// | `cmd_CommsFromPilotOnce` (`0x00459020`, command `0x2A`) | `pilot` | `once` |
///
/// The ship the first argument names (`videoreports.Radio.sayShip`), or the pilot it numbers
/// (`videoreports.Radio.sayPilot`), says the speech file the third names at once, its face moving
/// as the second says, the film looping while the line plays, or playing once
/// (`hudmovie.Flags.once`).
fn comms(comptime speaker: Speaker, comptime flags: hudmovie.Flags) vm.Implementation {
    return &struct {
        fn run(call: Call) u32 {
            const machine = call.machine;
            const game = machine.game orelse return yield;
            const radio, const ctx = videoreports.onAir(game.world) orelse return yield;
            const head: pilots.Head = @enumFromInt(call.args[1]);
            const name = machine.mission.text(call.args[2]) catch return yield;
            switch (speaker) {
                .ship => {
                    const ship = mission.shipSlot(machine.mission, ctx.all, call.args[0]) orelse return yield;
                    radio.sayShip(ctx, ship, head, name, .now, flags, videoreports.no_expiry);
                },
                .pilot => radio.sayPilot(ctx, @truncate(call.args[0]), head, name, .now, flags, videoreports.no_expiry),
            }
            return yield;
        }
    }.run;
}

/// A command's argument read as the signed halfword the game stores it as (`(short)`).
fn halfword(argument: u32) i16 {
    return @bitCast(@as(u16, @truncate(argument)));
}

/// A command's argument read as the halfword the game stores it as, set or not.
fn halfwordSet(argument: u32) bool {
    return halfword(argument) != 0;
}

/// `cmd_FriendlyFire` (`0x00459F30`, command `0x57`): the player's ship is to be sent home as for
/// destroying a friend (`friendly_fire.friendDestroyed`).
fn friendlyFire(_: Call, game: aigeneric.Context) void {
    friendly_fire.friendDestroyed(game.world);
}

/// The commands that set a flag of the radio's remarks (`videoreports.Remarks`) while the argument,
/// read as a halfword, is set, and clear it while it is not (`halfwordSet`):
///
/// | Command | Flag |
/// |---|---|
/// | `cmd_DisableTaunts` (`0x00458F40`, command `0x27`) | `taunts_disabled`: the enemy's taunts on the radio stop |
/// | `cmd_DisableGenericComms` (`0x004591F0`, command `0x2E`) | `generic_comms_disabled`: the remarks the radio makes by itself stop |
fn remarkFlag(comptime flag: []const u8) vm.GameImplementation {
    return &struct {
        fn set(call: Call, game: aigeneric.Context) void {
            @field(game.world.player.remarks, flag) = halfwordSet(call.args[0]);
        }
    }.set;
}

/// `cmd_UpdateEnvironmentFXState` (`0x004591A0`, command `0x38`): what the script asks of its
/// space takes effect at once, rather than at the next jump (`environfx.Environment.update`), and
/// the mission's markers aim the sun, the lights and the nebula again
/// (`backdrop.Backdrop.place`).
fn updateEnvironmentFXState(_: Call, game: aigeneric.Context) void {
    const world = game.world;
    const environment = world.environment orelse return;
    environment.update();
    const ships = if (world.mission) |bound| bound.shipCount() else 0;
    environment.space.place(environment.sky, world.objects, ships);
}

/// `cmd_SetEnvironmentFXNebula` (`0x00459190`, command `0x3C`): asks for the nebula the argument
/// numbers (`environfx.Environment.requested`), which shows once the space is updated.
fn setEnvironmentFXNebula(call: Call, game: aigeneric.Context) void {
    if (game.world.environment) |environment| environment.requested = call.args[0];
}

/// `cmd_SetEnvironmentFX` (`0x00459170`, command `0x2C`): turns the environment effect the first
/// argument numbers on while the second is set, and off while it is not
/// (`environfx.Environment.setEffect`).
fn setEnvironmentFX(call: Call, game: aigeneric.Context) void {
    if (game.world.environment) |environment| environment.setEffect(call.args[0], call.args[1] != 0);
}

/// How far back `WaitForJumpOrLaunch` runs again (`0x004595C6`): over itself
/// (`vm.machine.command_size`) and its push of the ships before it, which then pushes them afresh.
const wait_back = 4;

/// `cmd_WaitForJumpOrLaunch` (`0x004595A0`, command `0x3A`): the thread waits while any ship the
/// argument names is still jumping or launching (`jumpingOrLaunching`), pushing the argument again
/// and running the command again each time.
fn waitForJumpOrLaunch(call: Call) u32 {
    const machine = call.machine;
    machine.still_moving = false;
    vm.Machine.forEachShip(call, jumpingOrLaunching);
    if (machine.still_moving) return call.again(wait_back);
    return run_on;
}

/// `cmd_WaitForJumpOrLaunch_ship` (`0x004595E0`): the ship is still jumping or launching where it
/// is one the AI's searches reach (`gameobj.GameObject.Flags.outOfSearch`) and its current order
/// is one by which a ship jumps, warps or launches.
fn jumpingOrLaunching(call: Call, ship: Ship) void {
    if (ship.slot.object.flags.outOfSearch()) return;
    const entry = ship.slot.current() orelse return;
    switch (entry.order) {
        .jump_in, .jump_out, .warp_in, .warp_out, .fixed_gate_jump_in, .fixed_gate_jump_out, .jump_in_40, .jump_out_41, .launch => call.machine.still_moving = true,
        else => {},
    }
}

/// `cmd_SetObjective` (`0x00459870`, command `0x43`): the mission's objective the first argument
/// numbers takes the state the second gives (`hud.Objectives.set`).
fn setObjective(call: Call, game: aigeneric.Context) void {
    const display = game.world.display orelse return;
    display.objectives.set(call.args[0], @enumFromInt(halfword(call.args[1])));
}

/// `cmd_SetShipAvoidance` (`0x00459A30`, command `0x49`) and `cmd_SetShipAvoidance_ship`
/// (`0x00459A50`), for each ship the first argument names (`perShip`): the ship, unless a
/// stand-in, keeps clear of others no more where the command's second argument is set, and does
/// again where it is not (`gameobj.GameObject.Flags.no_avoidance`).
fn setShipAvoidanceShip(call: Call, ship: Ship) void {
    const object = &ship.slot.object;
    if (object.type == .stand_in) return;
    object.flags.no_avoidance = call.args[0] != 0;
}

/// `cmd_MultiplayerScriptSync` (`0x00459DF0`, command `0x56`): in a single-player game, the thread
/// runs on at once.
///
/// Not ported: a multiplayer game's players' scripts kept in step
/// ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
fn multiplayerScriptSync(call: Call) u32 {
    _ = call;
    return run_on;
}

/// `vm_clock_tick` (`0x00458910`): a second of the mission has passed, the script's clock on by
/// one (`vm.Machine.clock`), and the timers to run for it (`vm.Machine.ticked`). The game's timer
/// calls it once a second, and it returns at once while the script debugger holds the clock
/// (`0x005373F8`) or the game is paused (`paused`, `0x0057E04C`); OpenReliant's caller holds it
/// there (`mission.Loaded.tickClock`).
pub fn clockTick(machine: *vm.Machine) void {
    machine.ticked = true;
    machine.clock +%= 1;
}

/// `cmd_WhenPlayerLastJumped` (`0x00458580`, command `0x1E`): how many seconds of the script's
/// clock ago JUMP DRIVE last took a jump or a warp (`vm.Machine.last_jumped`), at least 1; and
/// `never_jumped` while the clock stands before it, as it does before the first.
fn whenPlayerLastJumped(call: Call) u32 {
    const machine = call.machine;
    const ago: i32 = @bitCast(machine.clock -% machine.last_jumped);
    if (ago < 0) return vm.Machine.never_jumped;
    return @max(@as(u32, @intCast(ago)), 1);
}

/// `cmd_DestroyFlightGroup` (`0x00457FD0`, command `0x04`): each ship of the flight group the
/// argument names leaves the mission at once, a stand-in in its place (`create.retire`), a
/// planet's atmosphere let go of with it (`create.atmosphere.Atmospheres.release`).
fn destroyFlightGroup(call: Call, game: aigeneric.Context) void {
    const machine = call.machine;
    const group = machine.mission.flightGroup(machine.mission.flightGroupIndex(call.args[0]) orelse return) orelse return;
    const all = game.world.objects;
    for (machine.mission.groupShips(group.*)) |ship| {
        if (ship >= all.slots.len) continue;
        if (game.world.atmospheres) |atmospheres| atmospheres.release(ship);
        create.retire(game, ship);
    }
}

/// `cmd_ClearAI` (`0x004588C0`, command `0x0C`) and `cmd_ClearAI_ship` (`0x004588E0`), for each
/// ship the argument names (`perShip`): a ship past the players' slots drops every order, where its
/// current one gives way (`aigeneric.clear`).
fn clearAIShip(call: Call, ship: Ship) void {
    _ = call;
    if (ship.index < ship.game.world.objects.players) return;
    aigeneric.clear(ship.game, ship.index) catch |err| log.warn("mission ship {d} keeps its orders: {s}", .{ ship.index, @errorName(err) });
}

/// How fast `StartShipAnimation` plays its track, a step, forwards and backwards (`0x0045874B`).
const animation_speed: f32 = 4;

/// `cmd_StartShipAnimation` (`0x00458720`, command `0x11`): each part of the ship the first
/// argument names, but those taken out of its model, plays its track the second names, from the
/// start, in the track's own mode, at `animation_speed` (`playShipAnimation`).
fn startShipAnimation(call: Call, game: aigeneric.Context) void {
    playShipAnimation(call, game, false);
}

/// `cmd_StartShipAnimationReverse` (`0x004587D0`, command `0x3D`): the same backwards, each part's
/// track from where it stands (`playShipAnimation`).
fn startShipAnimationReverse(call: Call, game: aigeneric.Context) void {
    playShipAnimation(call, game, true);
}

/// The work of `StartShipAnimation` and `StartShipAnimationReverse`: each part in the root's child
/// list of the model of the ship the command's first argument names plays its track the second
/// names (`objects.Model.playNamedTree`), forwards from 0 at `animation_speed`, or `backwards`
/// from where the part's own track stands at `-animation_speed`.
fn playShipAnimation(call: Call, game: aigeneric.Context, backwards: bool) void {
    const machine = call.machine;
    const all = game.world.objects;
    const ship = mission.shipSlot(machine.mission, all, call.args[0]) orelse return;
    const model = if (all.slots[ship].model) |*live| live else return;
    const name = machine.mission.text(call.args[1]) catch return;
    const time: f32 = if (backwards) objects.Model.keep_time else 0;
    model.playNamedTree(name, time, null, if (backwards) -animation_speed else animation_speed);
}

/// `cmd_DisableObject` (`0x004583C0`, command `0x1C`) and `cmd_DisableObject_ship` (`0x004583E0`),
/// for each ship the first argument names (`perShip`): where the first argument names one of the
/// ship's components (`push_component`, or a squad's member), the component's assembly shows its
/// damaged model while the second argument is set, and its own again while it is not; otherwise
/// the ship is disabled, which leaves it out of the mission's work (`GameObject.Flags.disabled`),
/// or enabled again. A mission hides the slots a Ripper fills this way (Ripper attach cargo pod to
/// Mammoth).
fn disableObjectShip(call: Call, ship: Ship) void {
    const machine = call.machine;
    const slot = ship.slot;
    const disabled = call.args[0] != 0;
    const component = machine.argumentComponent(call.thread, 0) orelse {
        slot.object.flags.disabled = disabled;
        return;
    };
    const part = slot.component(component) orelse return;
    const model = if (slot.model) |*live| live.holding(part) orelse return else return;
    var each = model.assembly(part.link_id);
    while (each.next()) |at| {
        const piece = &model.parts[at];
        piece.hidden = if (piece.flags.damaged) !disabled else disabled;
    }
}

/// `cmd_PositionRelative` (`0x004584D0`, command `0x1D`) and `cmd_PositionRelative_ship`
/// (`0x004584F0`), for each ship the first argument names (`perShip`): the ship moves as far as the
/// ship the second names has moved from where the mission places it. The missions keep a camera's
/// marker or a flight group with a ship this way.
///
/// The ship's run-time place (`dte.Ship.runtime_position`) moves by how far the object of the ship
/// the command's second argument names stands from where the mission places that ship
/// (`dte.Ship.position`), and the ship's object is put there (`object_place`, `0x004521E0`, which
/// places it as `objects.setPosition` does). The run-time place follows the object again each
/// frame (`mission.syncShips`).
///
/// **Fix:** where the second argument names no ship, the game reads it from address zero;
/// OpenReliant moves nothing.
fn positionRelativeShip(call: Call, ship: Ship) void {
    const machine = call.machine;
    const all = ship.game.world.objects;
    const marker = mission.shipSlot(machine.mission, all, call.args[0]) orelse return;
    const placed = machine.mission.ship(marker) orelse return;
    const moved = gameobj.vector(all.slots[marker].object.root.position) - placed.position;
    const record = machine.mission.ship(ship.index) orelse return;
    record.runtime_position = moved + record.runtime_position;
    objects.setPosition(&ship.slot.object, &ship.slot.drawn, record.runtime_position);
}

/// `cmd_SetPlayerTarget` (`0x00458C80`, command `0x21`): where the first argument names the
/// player's ship, the ship the second names, or its component (`push_component`), becomes the
/// player's target, where it can be aimed at (`ai.targetValid`): the player's Player Control order
/// is aimed at it, the display follows (`hud.State.targetChanged`), and the player stops matching
/// speeds (`input.Player.matching_speed`).
///
/// Not ported: a ship past the players' slots aimed through its Multiplayer Control order, which no
/// ship has outside a multiplayer game ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
fn setPlayerTarget(call: Call, game: aigeneric.Context) void {
    const machine = call.machine;
    const world = game.world;
    const all = world.objects;
    if (mission.shipSlot(machine.mission, all, call.args[0]) != all.player) return;
    const aimed = shipTarget(machine, call.thread, call.args[1], 1);
    if (!ai.targetValid(all, aimed, .{})) return;
    const entry = ai.playerControlEntry(all) orelse return;
    entry.target.index = aimed.index;
    entry.target.component = aimed.component;
    if (world.display) |display| display.targetChanged(all, false);
    world.player.matching_speed = false;
}

/// `cmd_SetTargetable` (`0x00458D50`, command `0x22`) and `cmd_SetTargetable_ship` (`0x00458D70`),
/// for each ship the first argument names (`perShip`): where the first argument names one of the
/// ship's components (`push_component`), the component can be picked as a subtarget, or not
/// (`objects.Model.Part.targetable`); otherwise the ship can be targeted, where its type allows, or
/// not (`ai.setTargetable`).
fn setTargetableShip(call: Call, ship: Ship) void {
    const machine = call.machine;
    const slot = ship.slot;
    const targetable = call.args[0] != 0;
    const component = machine.argumentComponent(call.thread, 0) orelse return ai.setTargetable(&slot.object, slot.combat, targetable);
    if (slot.component(component)) |part| part.targetable = targetable;
}

/// `cmd_SetActionCentre` (`0x00458E60`, command `0x25`): the sphere the fighters keep to
/// (`aigeneric.ActionSphere`) centres on the object the first argument names, its radius the
/// second, or the default one for none.
///
/// **Fix:** where the first argument names no object, the game centres the sphere on the slot
/// before the objects; OpenReliant keeps its centre.
fn setActionCentre(call: Call, game: aigeneric.Context) void {
    const machine = call.machine;
    const all = game.world.objects;
    const sphere = &all.action_sphere;
    if (mission.shipSlot(machine.mission, all, call.args[0])) |centre| sphere.centre = centre;
    const radius: f32 = @floatFromInt(call.args[1]);
    sphere.radius = if (radius == 0) aigeneric.ActionSphere.default.radius else radius;
}

/// The commands that set a flag of each ship the first argument names while the second is set, and
/// clear it while it is not (`perShip`), each through its `_ship` routine:
///
/// | Command | Flag |
/// |---|---|
/// | `cmd_DisableGuns` (`0x00459200`, command `0x2F`; `0x00459220`) | `guns_disabled`: its guns do not fire, and its turrets rest |
/// | `cmd_DisableEject` (`0x00459450`, command `0x35`; `0x00459470`) | `eject_disabled`: the player cannot eject |
/// | `cmd_DoNotDisturb` (`0x00459640`, command `0x3B`; `0x00459660`) | `do_not_disturb`: it does not retaliate, come to another's help, rise to a taunt or take the wingmen's commands |
fn flagShip(comptime flag: []const u8) vm.Machine.ShipImplementation {
    return &struct {
        fn set(call: Call, ship: Ship) void {
            @field(ship.slot.object.flags, flag) = call.args[0] != 0;
        }
    }.set;
}

/// `cmd_SetHostile` (`0x004594F0`, command `0x36`) and `cmd_SetHostile_ship` (`0x00459510`), for
/// each ship the first argument names (`perShip`): the ship's side (`gameobj.GameObject.side`)
/// becomes hostile where the command's second argument is set, and friendly where it is not, a
/// neutral ship's too.
fn setHostileShip(call: Call, ship: Ship) void {
    ship.slot.object.side = if (call.args[0] != 0) .hostile else .friendly;
}

/// `cmd_DestroySubObject` (`0x00459750`, command `0x42`): the component the first argument names
/// (`push_component`) goes at once, with its assembly and nothing to show for it: each part of the
/// assembly that is shown is taken out (`objects.destroyPart`), an engine taking its share off the
/// ship's `engines_intact` (`objects.loseEngine`) and a shield generator leaving it without one; a
/// hidden part, its damaged model, is taken out too, unless the second argument is set, when it
/// is shown in the component's place.
fn destroySubObject(call: Call, game: aigeneric.Context) void {
    const machine = call.machine;
    const all = game.world.objects;
    const ship = mission.shipSlot(machine.mission, all, call.args[0]) orelse return;
    const slot = &all.slots[ship];
    const component = slot.component(machine.argumentComponent(call.thread, 0) orelse return) orelse return;
    const model = if (slot.model) |*live| live.holding(component) orelse return else return;
    const keeps_damaged = call.args[1] != 0;
    var each = model.assembly(component.link_id);
    while (each.next()) |at| {
        const part = &model.parts[at];
        if (!part.hidden) {
            if (part.class == .engine) objects.loseEngine(&slot.object);
            if (part.class == .shield_generator) slot.object.flags.shield_generator = false;
        } else if (keeps_damaged) {
            part.hidden = false;
            continue;
        }
        objects.destroyPart(slot, .{ .model = model, .index = at });
    }
}

/// `cmd_ReplaceSubObject` (`0x00459CF0`, command `0x54`): the ship the second argument names takes
/// the place of the component the first names (`push_component`): it stands where the component's
/// frame stands in the world (`create.Slot.partPlace`), turned as it is, and the component is
/// hidden. A cargo pod stands turned as the Mammoth's and the Stalag's pods hang from them
/// (`pod_half_turn`, `pod_quarter_back`).
///
/// **Fix:** where the first argument names no component, or either argument no ship, the game
/// reads past the object's components or past the objects; OpenReliant does nothing.
fn replaceSubObject(call: Call, game: aigeneric.Context) void {
    const machine = call.machine;
    const all = game.world.objects;
    const ship = mission.shipSlot(machine.mission, all, call.args[0]) orelse return;
    const slot = &all.slots[ship];
    const component = slot.component(machine.argumentComponent(call.thread, 0) orelse return) orelse return;
    const taking = mission.shipSlot(machine.mission, all, call.args[1]) orelse return;
    const replacement = &all.slots[taking];
    var place = slot.partPlace(component) orelse return;
    if (replacement.object.type == .cargo_pod) {
        place.orientation = math.turned(math.turned(place.orientation, .y, pod_half_turn), .x, pod_quarter_back);
    }
    objects.setPlace(&replacement.object, &replacement.drawn, place);
    component.hidden = true;
}

/// How `ReplaceSubObject` turns a cargo pod from the frame of the component it replaces: half a turn
/// about the pod's own `Y` (`0x00459D8F`), then a quarter turn back about its own `X`
/// (`0x00459D9D`), the game's floats being these exactly.
const pod_half_turn: f32 = std.math.pi;
const pod_quarter_back: f32 = -std.math.pi / 2.0;

/// `cmd_DisableLights_ship` (`0x00459100`), which `cmd_DisableLights` (`0x00459070`, command
/// `0x2B`) runs for each ship its first argument names: while the second argument is set, the
/// ship's lights go out (`gameobj.GameObject.Flags.lights_disabled`), with the static lights baked
/// into its parts' meshes (`showStaticLights`); where it is not, they come on again.
fn disableLightsShip(call: Call, ship: Ship) void {
    const out = call.args[0] != 0;
    ship.slot.object.flags.lights_disabled = out;
    if (ship.slot.model) |*model| showStaticLights(model, !out);
}

/// `0x00459090`: the static lights baked into the meshes of each part of `model` that has them
/// (`shp.Part.Flags.has_static_light`), and of the models it carries, shown or not
/// (`srapiext.ObjectFlags.baked_mesh`). It walks the root's child list and each node's, which pass
/// over a part taken out of the model and what it carries (`objects.Model.rootChild`).
fn showStaticLights(model: *objects.Model, shown: bool) void {
    for (model.parts, 0..) |*part, index| {
        if (part.removed) continue;
        if (part.flags.has_static_light) part.object.flags.baked_mesh = shown;
        var each = model.carriedBy(index);
        while (each.next()) |mount| showStaticLights(&mount.model, shown);
    }
}

/// `cmd_TerminateMission` (`0x00459BB0`, command `0x4D`): the mission ends once the frame is over
/// (`input.Player.terminated`), as one the player's ship is destroyed in where it is numbered below
/// 28 (`main.missionRunEnd`).
fn terminateMission(_: Call, game: aigeneric.Context) void {
    game.world.player.terminated +%= 1;
}

/// `cmd_TurretSetTarget` (`0x00459BD0`, command `0x4E`) and `cmd_TurretSetTarget_ship`
/// (`0x00459BF0`), for each ship the first argument names (`perShip`): where the first argument
/// names one of the ship's components (`push_component`, or a squad's member), each aimed turret
/// whose base it is aims at the whole of the ship the second names, which it keeps to until the
/// ship is gone.
fn turretSetTargetShip(call: Call, ship: Ship) void {
    const machine = call.machine;
    const slot = ship.slot;
    const component = slot.component(machine.argumentComponent(call.thread, 0) orelse return) orelse return;
    const aimed_at = aigeneric.Target.indexOf(machine.mission.shipIndex(call.args[0]));
    for (slot.guns) |*gun| switch (gun.turret) {
        .aimed => |*aimed| if (&aimed.model.parts[aimed.base] == component) {
            aimed.target.index = aimed_at;
            aimed.target.component = aigeneric.Target.whole;
        },
        .fixed, .spin, .missile, .gone => {},
    };
}

/// `cmd_ReplenishWeapons` (`0x00459FA0`, command `0x59`): the ship the argument names is armed
/// again (`create.arm`), a player's ship as its loadout fitted it where the loadout ran, outside
/// the simulator (`create.Objects.loadoutRacks`), and by loadout tier 0 otherwise, and any other
/// ship by its `loadout_tier`; and made whole (`create.makeWhole`); the display's missiles follow
/// the player's (`hud.missile_display.Ring.build`).
fn replenishWeapons(call: Call, game: aigeneric.Context) void {
    const machine = call.machine;
    const world = game.world;
    const all = world.objects;
    const ship = mission.shipSlot(machine.mission, all, call.args[0]) orelse return;
    const slot = &all.slots[ship];
    const fit: create.Fit = if (all.loadoutRacks(ship)) |racks| .{ .loadout = racks } else .{
        .tier = if (ship < all.players) 0 else std.math.lossyCast(u2, slot.object.loadout_tier),
    };
    create.arm(all.gpa, slot, fit) catch |err| log.warn("mission ship {d} is not armed again: {s}", .{ ship, @errorName(err) });
    if (ship == all.player) if (world.display) |display| display.missiles.build(&slot.object);
    if (slot.combat) |combat| create.makeWhole(&slot.object, combat);
}

/// `cmd_DisableListing` (`0x0045A210`, command `0x5C`): unlike the flags' other commands, which set
/// each ship of what their first argument names, it sets the one ship its first argument names. The
/// ship no longer lurches as a torpedo strikes it while the second argument is set, and lurches
/// again while it is not (`gameobj.GameObject.Flags.listing_disabled`).
///
/// **Fix:** where the first argument names no ship, the game writes past the objects; OpenReliant
/// sets nothing.
fn disableListing(call: Call, game: aigeneric.Context) void {
    const machine = call.machine;
    const all = game.world.objects;
    const ship = mission.shipSlot(machine.mission, all, call.args[0]) orelse return;
    all.slots[ship].object.flags.listing_disabled = call.args[1] != 0;
}

/// `cmd_Scanner` (`0x00459CB0`, command `0x53`): the scanner looks for the ship the argument names,
/// or is off where it names none (`main.scanner.Scanner.set`), and the display's scanner starts
/// from its first frame (`hud.State.restartScanner`).
fn scanner(call: Call, game: aigeneric.Context) void {
    const machine = call.machine;
    const world = game.world;
    world.player.scanner.set(mission.shipSlot(machine.mission, world.objects, call.args[0]));
    if (world.display) |display| display.restartScanner();
}

/// `cmd_Fire` (`0x00459DD0`, command `0x55`): the ship the first argument names holds its guns'
/// trigger for the ticks the second gives (`guns.fire`), the player's view shaking with the Nova
/// Cannon's charge where it is the player's ship.
///
/// **Fix:** where the first argument names no ship, the game reads past the objects; OpenReliant
/// fires nothing.
fn fire(call: Call, game: aigeneric.Context) void {
    const machine = call.machine;
    const world = game.world;
    const all = world.objects;
    const ship = mission.shipSlot(machine.mission, all, call.args[0]) orelse return;
    const slot = &all.slots[ship];
    var trigger = slot.trigger(world.clock.frame_start);
    if (ship == all.player) trigger.shake = world.shake;
    guns.fire(&slot.object, trigger, @bitCast(call.args[1]));
}

/// `cmd_SetEscortPoint` (`0x004592F0`, command `0x31`) and `cmd_SetEscortPoint_ship`
/// (`0x00459310`), for each ship the first argument names (`perShip`): the ship's escort point
/// becomes the object the command's second argument names, or none (`GameObject.escort_point`).
fn setEscortPointShip(call: Call, ship: Ship) void {
    ship.slot.object.escort_point = .from(mission.shipSlot(call.machine.mission, ship.game.world.objects, call.args[0]));
}

/// `cmd_SetPrimaryTarget` (`0x00459550`, command `0x39`): the ship the argument names, or its
/// component (`push_component`), becomes the mission's primary target, which PRIMARY TARGET makes
/// the player's (`input.Player.primary_target`); none where it names no object.
fn setPrimaryTarget(call: Call, game: aigeneric.Context) void {
    const machine = call.machine;
    const all = game.world.objects;
    const index = mission.shipSlot(machine.mission, all, call.args[0]) orelse {
        game.world.player.primary_target = null;
        return;
    };
    game.world.player.primary_target = .{ .index = index, .component = machine.argumentComponent(call.thread, 0) };
}

/// `cmd_SnapToPoint` (`0x004596A0`, command `0x3E`): the ship the first argument names, unless it
/// is exploding, ejected or sent off (`GameObject.Flags.sent_off`), is put where the object the
/// second names will stand next, turned as it will be, and stopped (`ai.stop`).
///
/// Not ported: in a multiplayer game, the move told to the other players
/// ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
fn snapToPoint(call: Call, game: aigeneric.Context) void {
    const machine = call.machine;
    const all = game.world.objects;
    const ship = mission.shipSlot(machine.mission, all, call.args[0]) orelse return;
    const slot = &all.slots[ship];
    const flags = slot.object.flags;
    if (flags.exploding or flags.ejected or flags.sent_off) return;
    const point = mission.shipSlot(machine.mission, all, call.args[1]) orelse return;
    objects.setPlace(&slot.object, &slot.drawn, all.slots[point].object.placeAt(.next));
    ai.stop(&slot.object);
}

/// What `IsShipThisPlayer` answers: 1 for yes, which the scripts test for, and 2 for no; a
/// command's result of 0 would suspend its thread.
const answer_yes: u32 = 1;
const answer_no: u32 = 2;

/// `cmd_IsShipThisPlayer` (`0x004598F0`, command `0x45`): whether the argument names the player's
/// ship.
fn isShipThisPlayer(call: Call) u32 {
    const machine = call.machine;
    const game = machine.game orelse return answer_no;
    return if (machine.mission.shipIndex(call.args[0]) == game.world.objects.player) answer_yes else answer_no;
}

/// `cmd_SetFlybackMarker` (`0x00459910`, command `0x46`): the flyback markers start afresh with
/// each ship the first argument names (`setFlybackMarkerShip`).
fn setFlybackMarker(call: Call, game: aigeneric.Context) void {
    game.world.player.flyback = .{};
    vm.Machine.forEachShip(call, setFlybackMarkerShip);
}

/// `cmd_SetFlybackMarker_ship` (`0x00459960`): the ship, unless it is a stand-in, is marked, the
/// command's second argument its reach (`input.Flyback.mark`).
fn setFlybackMarkerShip(call: Call, ship: Ship) void {
    if (ship.slot.object.type == .stand_in) return;
    ship.game.world.player.flyback.mark(ship.index, @floatFromInt(call.args[0]));
}

/// `cmd_ResetFlybackMarker` (`0x004599E0`, command `0x47`): the flyback markers are dropped, and
/// the player's ship points to no nav point.
fn resetFlybackMarker(_: Call, game: aigeneric.Context) void {
    const all = game.world.objects;
    game.world.player.flyback = .{};
    all.slots[all.player].object.nav_point = .none;
}

/// `cmd_MatchSpeed` (`0x00459A90`, command `0x4A`): where the first argument names the player's
/// ship, the player matches the target's speed from now on, where the second is set, having
/// matched it at once where it already did (`input.matchTargetSpeed`), or stops matching it.
fn matchSpeed(call: Call, game: aigeneric.Context) void {
    const machine = call.machine;
    const world = game.world;
    const all = world.objects;
    if (machine.mission.shipIndex(call.args[0]) != all.player) return;
    if (call.args[1] != 0) {
        input.matchTargetSpeed(world.player, all, world.view);
        world.player.matching_speed = true;
    } else {
        world.player.matching_speed = false;
    }
}

/// `cmd_Dock` (`0x00458EB0`, command `0x26`): the ship the first argument names docks (Dock): at
/// the port the third gives of the ship the second names, or at the first free port of the ships
/// of a flight group or a squad the second names.
fn dock(call: Call, game: aigeneric.Context) void {
    const machine = call.machine;
    const ship = mission.shipSlot(machine.mission, game.world.objects, call.args[0]) orelse return;
    const port: aigeneric.Target = .of(.ship, machine.mission.shipIndex(call.args[1]), halfword(call.args[2]));
    const target = recordTarget(machine, call.args[1], port);
    _ = aigeneric.give(game, ship, .dock, target);
}

/// The commands that give each ship the first argument names an order that follows a path
/// (`perShip`), each through its `_ship` routine (`followCurve`): the curve the second argument
/// names, over the seconds the third gives, the path carried or not by where the ship the fourth
/// names stands, as the order starts, from where the mission placed it (`follow.Data.offset`).
///
/// | Command | Order | Carried |
/// |---|---|---|
/// | `cmd_ShipFollowCurve` (`0x004585D0`, command `0x12`; `0x004585F0`) | Ship Follow Curve | no |
/// | `cmd_MovingShipFollowCurve` (`0x004585A0`, command `0x1B`; `0x004585C0`) | Ship Follow Curve | yes |
/// | `cmd_MovingShipBackupCurve` (`0x00458670`, command `0x4B`; `0x00458690`) | Ship Follow Curve Backwards | yes, where the fourth argument may be null |
///
/// **Fix:** `cmd_MovingShipFollowCurve_ship` takes a null fourth argument for a ship's record at
/// address -1; OpenReliant carries the path by nothing.
fn followCurveShip(comptime order: Order, comptime carried: bool) vm.Machine.ShipImplementation {
    return &struct {
        fn give(call: Call, ship: Ship) void {
            followCurve(call, ship, order, if (carried) call.args[2] else null);
        }
    }.give;
}

/// `follow_curve_give` (`0x00458600`), and the like work of `cmd_MovingShipBackupCurve_ship`
/// (`0x00458690`): the mission's ship takes `order`, aimed at nothing, with its data from the
/// command's arguments after the first: the curve its path starts along, the path's seconds, and
/// the ship the path is carried by, `offset`, where there is one.
///
/// **Fix:** the game writes the data into whatever order the ship has on top where it refuses the
/// order; OpenReliant writes none.
fn followCurve(call: Call, ship: Ship, order: Order, offset: ?u32) void {
    const machine = call.machine;
    const entry = given(ship, order, .none) orelse return;
    const offset_ship = if (offset) |place| machine.mission.shipIndex(place) else null;
    entry.data = .{ .follow = .of(machine.mission.curveIndex(call.args[0]), call.args[1], offset_ship) };
}

/// `cmd_StartDirectorCam` (`0x004582E0`, command `0x10`): the director's shots waiting are
/// dropped, and the camera takes this one at once (`stackDirectorCam`).
fn startDirectorCam(call: Call, game: aigeneric.Context) void {
    const view = game.world.camera orelse return;
    view.shots.count = 0;
    stackDirectorCam(call, game);
}

/// `cmd_StackDirectorCam` (`0x00458300`, command `0x52`): the director's camera takes the shot the
/// arguments give after those waiting (`camera.shots.stack`): the curve its path starts along, or
/// the ship it stands at; the ship it looks at; its seconds; the ship its path rides along with;
/// and the ship, flight group or squad it holds still while it is on screen.
fn stackDirectorCam(call: Call, game: aigeneric.Context) void {
    const view = game.world.camera orelse return;
    camera.shots.stack(game.world, view, directorShot(call.machine, call.args));
}

/// The shot `StackDirectorCam`'s arguments `args` give. The first names a curve unless it names one
/// of the mission's records, which it takes for a ship's (`record_kind`, `ship_index`), and the
/// seconds are a whole number.
fn directorShot(machine: *vm.Machine, args: []const u32) camera.shots.Shot {
    const path: ?camera.shots.Shot.Path = if (machine.mission.recordKind(args[0]) != null)
        if (machine.mission.shipIndex(args[0])) |ship| .{ .ship = ship } else null
    else if (machine.mission.curveIndex(args[0])) |curve| .{ .curve = curve } else null;
    const held: ?aigeneric.Target = if (machine.mission.recordKind(args[4])) |kind| switch (kind) {
        .ship => if (machine.mission.shipIndex(args[4])) |ship| .at(ship, null) else null,
        .flight_group => if (machine.mission.flightGroupIndex(args[4])) |group| .group(.flight_group, group) else null,
        .squad => if (machine.mission.squadIndex(args[4])) |squad| .group(.squad, squad) else null,
    } else null;
    return .{
        .path = path,
        .tracked = machine.mission.shipIndex(args[1]),
        .seconds = @floatFromInt(args[2]),
        .pace = machine.mission.shipIndex(args[3]),
        .held = held,
    };
}

/// `cmd_StopDirectorCam` (`0x00458E30`, command `0x24`): the camera goes back to the player's
/// cockpit, forced, unless the player's slot holds a stand-in. The shots waiting stay.
fn stopDirectorCam(_: Call, game: aigeneric.Context) void {
    const view = game.world.camera orelse return;
    const all = game.world.objects;
    if (all.slots[all.player].object.type != .stand_in) _ = view.setView(.cockpit, all.player, false, true, game.world.clock.viewTime());
}

/// `cmd_WaitForDirectorCam` (`0x00459C90`, command `0x50`): the thread waits while the camera is in
/// the director's view, running the command again each time (`vm.machine.Call.againItself`).
fn waitForDirectorCam(call: Call) u32 {
    const game = call.machine.game orelse return run_on;
    const view = game.world.camera orelse return run_on;
    return if (view.view == .director) call.againItself() else run_on;
}

test commandIndex {
    try std.testing.expectEqual(0x05, commandIndex("Wait"));
    try std.testing.expectEqualStrings("Wait", commands.table[commandIndex("Wait")].name);
}

test implementation {
    try std.testing.expect(implementation(commandIndex("Wait")) != null);
    try std.testing.expectEqual(null, implementation(commandIndex("PrintShipName")));
    try std.testing.expectEqual(null, implementation(0xFF));
}

test whenPlayerLastJumped {
    var machine: vm.Machine = .{ .gpa = std.testing.allocator, .mission = undefined, .random = undefined };
    const call: Call = .{ .machine = &machine, .thread = 0, .args = &.{} };
    // Before the first jump, never.
    machine.clock = 5;
    try std.testing.expectEqual(vm.Machine.never_jumped, whenPlayerLastJumped(call));
    // In the second of the jump, 1; then the seconds since.
    machine.last_jumped = 5;
    try std.testing.expectEqual(1, whenPlayerLastJumped(call));
    machine.clock = 12;
    try std.testing.expectEqual(7, whenPlayerLastJumped(call));
}

/// The tests' mission records (`dte.testing`).
const shipRecord = dte.testing.ship;
const groupRecord = dte.testing.flightGroup;
const objectRecord = dte.testing.object;
const memberRecord = dte.testing.squadMember;

const Routine = vm.machine.testing.Routine;
const finishPart = vm.machine.testing.finishPart;

/// Has `routine` create the flight groups `groups` in turn (`CreateFlightGroup`).
fn createFlightGroups(routine: *Routine, groups: []const u8) !void {
    for (groups) |group| {
        try routine.op(.push_flight_group, &.{group});
        try routine.command("CreateFlightGroup");
    }
}

test recordTarget {
    const ships = dte.testing.ships(2, @intFromEnum(gameobj.Type.sabre));
    var fixture: vm.machine.testing.Fixture = undefined;
    try fixture.init(std.testing.allocator, &.{}, .{
        .ships = &ships,
        .flight_groups = &.{ groupRecord(2, .none), groupRecord(3, .none) },
        .squads = &.{dte.testing.squad(0, 0)},
    });
    defer fixture.deinit();
    const machine = &fixture.machine;
    const own: aigeneric.Target = .at(1, 4);
    // A flight group or a squad by its index, whole.
    try std.testing.expectEqual(aigeneric.Target.group(.flight_group, 1), recordTarget(machine, machine.mission.recordPlace(.flight_groups, 1), own));
    try std.testing.expectEqual(aigeneric.Target.group(.squad, 0), recordTarget(machine, machine.mission.recordPlace(.squads, 0), own));
    // A ship's record, or a place that is none of the three, the command's own ship target.
    try std.testing.expectEqual(own, recordTarget(machine, machine.mission.recordPlace(.ships, 1), own));
    try std.testing.expectEqual(own, recordTarget(machine, vm.machine.none, own));
}

test "a mission's start part makes its ships and gives them their orders" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    try createFlightGroups(&routine, &.{ 0, 1, 2, 3 });
    // The Sabres fight the player's ship.
    try routine.op(.push_flight_group, &.{1});
    try routine.op(.push_byte, &.{@intCast(@intFromEnum(Order.fight))});
    try routine.op(.push_byte, &.{1});
    try routine.op(.push_ship, &.{0});
    try routine.command("SetAI");
    // The Reliant flies at 10, holding its heading.
    try routine.op(.push_ship, &.{5});
    try routine.op(.push_null, &.{});
    try routine.op(.push_byte, &.{10});
    try routine.command("Fly");
    try routine.op(.push_byte, &.{33});
    try routine.op(.push_byte, &.{33});
    try routine.op(.push_byte, &.{34});
    try routine.command("SetRescueProbabilities");
    const code = try finishPart(&routine);
    defer gpa.free(code);

    var ships = [_]dte.Ship{
        shipRecord(0, 0, @intFromEnum(gameobj.Type.predator)),
        shipRecord(1, 0, @intFromEnum(gameobj.Type.grendel)),
        shipRecord(2, 1, @intFromEnum(gameobj.Type.sabre)),
        shipRecord(3, 1, @intFromEnum(gameobj.Type.sabre)),
        shipRecord(4, 2, dte.Ship.nav_point_kind),
        shipRecord(5, 3, @intFromEnum(gameobj.Type.reliant)),
    };
    for (ships[2..4]) |*sabre| sabre.pilot = 42;
    ships[2].yaw = 180;
    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .ships = &ships,
        .flight_groups = &.{ groupRecord(6, .player), groupRecord(7, .none), groupRecord(8, .none), groupRecord(9, .none) },
    });
    defer game.deinit();
    const world = &game.mission;
    try game.start(game.spawning());

    const all = world.objects;
    // Each ship in the slot of its index, of its kind; the nav point a marker.
    const types = [_]gameobj.Type{ .predator, .grendel, .sabre, .sabre, .marker, .reliant };
    for (types, all.slots[0..types.len]) |made, slot| {
        try std.testing.expect(slot.object.created);
        try std.testing.expectEqual(made, slot.object.type);
    }
    // The player's ship on its controls, the others at rest until the script says otherwise.
    try std.testing.expectEqual(Order.player_control, all.slots[0].orders[0].order);
    try std.testing.expectEqual(Order.do_nothing, all.slots[1].orders[0].order);
    // The Sabres fight the player, numbered in turn, each naming the first of them but the first.
    for ([_]u16{ 2, 3 }, 0..) |at, n| {
        const entry = all.slots[at].orders[0];
        try std.testing.expectEqual(Order.fight, entry.order);
        try std.testing.expectEqual(0, entry.target.ship());
        try std.testing.expectEqual(@as(i16, @intCast(n)), entry.sequence);
        try std.testing.expectEqual(42, all.slots[at].object.pilot);
    }
    // Each names the first ship of the walk, none for the first (`vm.Machine.walkShip`).
    for ([_]u16{ 2, 3 }, [_]?u16{ null, 2 }) |at, first| {
        try std.testing.expectEqual(mission.bind.recordReference(.ship, first), all.slots[at].object._unknown_698);
    }
    // Turned by its record: the first Sabre faces back along Z.
    try std.testing.expectApproxEqAbs(-1, @import("../surrender/math.zig").forward(all.slots[2].object.root.orientation)[2], 1e-6);
    // The Reliant flies at 10, at nothing.
    try std.testing.expectEqual(Order.fly, all.slots[5].orders[0].order);
    try std.testing.expectEqual(null, all.slots[5].orders[0].target.ship());
    try std.testing.expectEqual(10, all.slots[5].orders[0].data.fly);
    // The player's flight group is the player's wing.
    try std.testing.expectEqual(mission.WingSlots{ 0, 1, null, null, null, null }, all.wing);
    try std.testing.expectEqual(.player, all.slots[1].object.wing);
    try std.testing.expectEqual(.none, all.slots[2].object.wing);
    try std.testing.expectEqual(@import("aieject.zig").RescueOdds{ .rescued = 33, .captured = 33, .killed = 34 }, world.player.rescue_odds);
}

test "the launch commands set ships up, start them, and wait for them" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    // The Reliant's flight group first, then the two Sabres', which launch from it through its
    // tubes from the fourth on, and wait until they are out.
    try createFlightGroups(&routine, &.{ 2, 0, 1 });
    try routine.op(.push_flight_group, &.{1});
    try routine.op(.push_ship, &.{4});
    try routine.op(.push_byte, &.{3});
    try routine.command("SetupLaunch");
    try routine.op(.push_flight_group, &.{1});
    try routine.command("StartLaunch");
    try routine.op(.push_flight_group, &.{1});
    try routine.command("WaitForJumpOrLaunch");
    try routine.op(.select_global, &.{0});
    try routine.op(.push_byte, &.{1});
    try routine.op(.assign, &.{});
    const code = try finishPart(&routine);
    defer gpa.free(code);

    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .globals = &.{0},
        .ships = &.{
            shipRecord(0, 0, @intFromEnum(gameobj.Type.predator)),
            shipRecord(1, 0, @intFromEnum(gameobj.Type.grendel)),
            shipRecord(2, 1, @intFromEnum(gameobj.Type.sabre)),
            shipRecord(3, 1, @intFromEnum(gameobj.Type.sabre)),
            shipRecord(4, 2, @intFromEnum(gameobj.Type.reliant)),
        },
        .flight_groups = &.{ groupRecord(5, .player), groupRecord(6, .none), groupRecord(7, .none) },
    });
    defer game.deinit();
    const fixture = &game.fixture;
    try game.start(game.spawning());

    // Each Sabre launches from the Reliant through a tube of its own, started.
    const all = game.mission.objects;
    for ([_]u16{ 2, 3 }, 3..) |ship, gate| {
        const entry = all.slots[ship].orders[0];
        try std.testing.expectEqual(Order.launch, entry.order);
        try std.testing.expectEqual(4, entry.target.ship());
        try std.testing.expectEqual(@as(i16, @intCast(gate)), entry.target.component);
        try std.testing.expect(entry.data.launch.go);
    }
    // The script waits while they launch, and runs on once they are out.
    try std.testing.expectEqual(0, fixture.global(0));
    fixture.second();
    try std.testing.expectEqual(0, fixture.global(0));
    for ([_]u16{ 2, 3 }) |ship| _ = aigeneric.pop(game.orders(), ship);
    fixture.second();
    try std.testing.expectEqual(1, fixture.global(0));
}

test "the commands that set ships, the radio, the display and the space" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    try createFlightGroups(&routine, &.{ 0, 1 });
    // The Sabres keep clear of nothing; the player's ship, and the second Sabre, invulnerable.
    try routine.op(.push_flight_group, &.{1});
    try routine.op(.push_byte, &.{1});
    try routine.command("SetShipAvoidance");
    for ([_]u8{ 0, 2 }) |ship| {
        try routine.op(.push_ship, &.{ship});
        try routine.op(.push_byte, &.{@intFromEnum(gameobj.Invulnerability.full)});
        try routine.command("SetInvulnerability");
    }
    try routine.op(.push_byte, &.{1});
    try routine.command("DisableTaunts");
    try routine.op(.push_byte, &.{1});
    try routine.command("DisableGenericComms");
    // The objectives window opens, the second objective current, and nebula 6 asked for.
    try routine.op(.push_byte, &.{@intFromEnum(hud.windows.Window.objectives)});
    try routine.command("OpenInstrument");
    try routine.op(.push_byte, &.{1});
    try routine.op(.push_byte, &.{@intFromEnum(hud.Objectives.Status.current)});
    try routine.command("SetObjective");
    try routine.op(.push_byte, &.{6});
    try routine.command("SetEnvironmentFXNebula");
    try routine.op(.push_byte, &.{0});
    try routine.command("MultiplayerScriptSync");
    try routine.command("WaitForMovie");
    const code = try finishPart(&routine);
    defer gpa.free(code);

    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .ships = &.{
            shipRecord(0, 0, @intFromEnum(gameobj.Type.predator)),
            shipRecord(1, 1, @intFromEnum(gameobj.Type.sabre)),
            shipRecord(2, 1, @intFromEnum(gameobj.Type.sabre)),
        },
        .flight_groups = &.{ groupRecord(3, .player), groupRecord(4, .none) },
    });
    defer game.deinit();
    const world = &game.mission;
    const fixture = &game.fixture;
    world.objects.mission_number = 1;
    var display: hud.State = .{};
    display.objectives.reset(1, false);
    var environment: @import("environfx.zig").Environment = .{ .sky = undefined, .textures = undefined, .space = undefined };
    var ctx = game.spawning();
    ctx.world.display = &display;
    ctx.world.environment = &environment;
    try game.start(ctx);

    const all = world.objects;
    try std.testing.expect(!all.slots[0].object.flags.no_avoidance and all.slots[1].object.flags.no_avoidance and all.slots[2].object.flags.no_avoidance);
    // Outside missions 30 to 35 the player's ship is not reached.
    try std.testing.expectEqual(.none, all.slots[0].object.invulnerable);
    try std.testing.expectEqual(.full, all.slots[2].object.invulnerable);
    try std.testing.expect(world.player.remarks.taunts_disabled and world.player.remarks.generic_comms_disabled);
    try std.testing.expect(display.windows.up(.objectives));
    try std.testing.expect(display.windows.status.get(.objectives).held);
    try std.testing.expectEqual(.current, display.objectives.states[1]);
    try std.testing.expectEqual(1, display.objectives.shown);
    try std.testing.expectEqual(6, environment.requested);
    // Neither the sync nor the films hold the thread in a game of one player with no films.
    try std.testing.expect(fixture.machine.finished);
}

test "the commands mission 1 runs at the convoy" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    try createFlightGroups(&routine, &.{ 0, 1, 2, 3 });
    // The second Sabre becomes the player's target and the primary one; the action centres on the
    // first Sabre, 50000 across; the Sabres' guns are disabled.
    try routine.op(.push_ship, &.{2});
    try routine.op(.push_byte, &.{1});
    try routine.command("SetTargetable");
    try routine.op(.push_ship, &.{0});
    try routine.op(.push_ship, &.{2});
    try routine.command("SetPlayerTarget");
    try routine.op(.push_ship, &.{2});
    try routine.command("SetPrimaryTarget");
    try routine.op(.push_ship, &.{1});
    try routine.pushConstant(50000);
    try routine.command("SetActionCentre");
    try routine.op(.push_flight_group, &.{1});
    try routine.op(.push_byte, &.{1});
    try routine.command("DisableGuns");
    try routine.op(.push_ship, &.{0});
    try routine.op(.push_byte, &.{1});
    try routine.command("DisableEject");
    // The player escorts the nav point, which also marks where to fly back to, 20000 about it; a
    // Grendel is put on the nav point, and the other disabled.
    try routine.op(.push_ship, &.{0});
    try routine.op(.push_ship, &.{3});
    try routine.command("SetEscortPoint");
    try routine.op(.push_ship, &.{3});
    try routine.pushConstant(20000);
    try routine.command("SetFlybackMarker");
    try routine.op(.push_ship, &.{4});
    try routine.op(.push_ship, &.{3});
    try routine.command("SnapToPoint");
    try routine.op(.push_ship, &.{5});
    try routine.op(.push_byte, &.{1});
    try routine.command("DisableObject");
    // Which of two ships is the player's.
    for ([_]u8{ 0, 1 }, [_]u8{ 0, 2 }) |global, ship| {
        try routine.op(.select_global, &.{global});
        try routine.op(.push_ship, &.{ship});
        try routine.command("IsShipThisPlayer");
        try routine.op(.push_result, &.{});
        try routine.op(.assign, &.{});
    }
    // The player matches its target's speed; the Sabres drop their orders.
    try routine.op(.push_ship, &.{0});
    try routine.op(.push_byte, &.{1});
    try routine.command("MatchSpeed");
    try routine.op(.push_flight_group, &.{1});
    try routine.command("ClearAI");
    const code = try finishPart(&routine);
    defer gpa.free(code);

    var marker = shipRecord(3, 2, dte.Ship.nav_point_kind);
    marker.position = .{ 0, 0, 30000 };
    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .globals = &.{ 0, 0 },
        .ships = &.{
            shipRecord(0, 0, @intFromEnum(gameobj.Type.predator)),
            shipRecord(1, 1, @intFromEnum(gameobj.Type.sabre)),
            shipRecord(2, 1, @intFromEnum(gameobj.Type.sabre)),
            marker,
            shipRecord(4, 3, @intFromEnum(gameobj.Type.grendel)),
            shipRecord(5, 3, @intFromEnum(gameobj.Type.grendel)),
        },
        .flight_groups = &.{ groupRecord(6, .player), groupRecord(7, .none), groupRecord(8, .none), groupRecord(9, .none) },
    });
    defer game.deinit();
    const world = &game.mission;
    const fixture = &game.fixture;
    world.tables.combat[@intFromEnum(gameobj.Type.sabre)].targeting.targetable = true;
    try game.start(game.spawning());

    const all = world.objects;
    try std.testing.expectEqual(2, ai.playerControlEntry(all).?.target.slot());
    try std.testing.expectEqual(2, world.player.primary_target.?.index);
    try std.testing.expectEqual(null, world.player.primary_target.?.component);
    try std.testing.expectEqual(1, all.action_sphere.centre);
    try std.testing.expectEqual(50000, all.action_sphere.radius);
    try std.testing.expect(all.slots[1].object.flags.guns_disabled and all.slots[2].object.flags.guns_disabled);
    try std.testing.expect(!all.slots[0].object.flags.guns_disabled);
    try std.testing.expect(all.slots[0].object.flags.eject_disabled and !all.slots[1].object.flags.eject_disabled);
    try std.testing.expectEqual(gameobj.Slot.of(3), all.slots[0].object.escort_point);
    try std.testing.expectEqual(1, world.player.flyback.count);
    try std.testing.expectEqual(3, world.player.flyback.markers[0].slot);
    try std.testing.expectEqual(20000, world.player.flyback.markers[0].reach);
    try std.testing.expectEqual(30000, all.slots[4].object.root.position.z);
    try std.testing.expect(all.slots[5].object.flags.disabled);
    try std.testing.expectEqual(answer_yes, fixture.global(0));
    try std.testing.expectEqual(answer_no, fixture.global(1));
    try std.testing.expect(world.player.matching_speed);
    try std.testing.expectEqual(0, all.slots[1].object.order_count);
    // The player's ship, 30000 from the nav point, points back to it.
    input.nextNavPoint(game.world());
    try std.testing.expectEqual(gameobj.Slot.of(3), all.slots[0].object.nav_point);
}

test "SetPlayerTarget keeps the player's target where its second argument names no ship" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    try routine.op(.push_ship, &.{0});
    try routine.op(.push_null, &.{});
    try routine.command("SetPlayerTarget");
    const code = try finishPart(&routine);
    defer gpa.free(code);

    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .ships = &.{
            shipRecord(0, dte.Ship.no_flight_group, @intFromEnum(gameobj.Type.predator)),
            shipRecord(1, dte.Ship.no_flight_group, @intFromEnum(gameobj.Type.sabre)),
        },
    });
    defer game.deinit();
    const world = &game.mission;
    const player = try world.add(.predator, @splat(0));
    const sabre = try world.add(.sabre, .{ 0, 0, 5000 });
    world.slot(sabre).object.flags.targetable = true;
    try std.testing.expect(try aigeneric.push(game.orders(), player, .player_control, .at(sabre, null)));
    try game.start(game.orders());

    try std.testing.expectEqual(aigeneric.Target.at(sabre, null), ai.playerControlEntry(world.objects).?.target);
}

test "the commands that move ships, change their sides and leave them be" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    try createFlightGroups(&routine, &.{ 0, 1, 2 });
    // The Grendel is put on the nav point, and the Sabres move as far as it has; a marker that is
    // no ship moves nothing.
    try routine.op(.push_ship, &.{1});
    try routine.op(.push_ship, &.{4});
    try routine.command("SnapToPoint");
    try routine.op(.push_flight_group, &.{1});
    try routine.op(.push_ship, &.{1});
    try routine.command("PositionRelative");
    try routine.op(.push_ship, &.{0});
    try routine.op(.push_null, &.{});
    try routine.command("PositionRelative");
    // The Sabres turn hostile and are not to be disturbed, then the second friendly again and
    // free to be; the Grendel lurches no more.
    for ([_]dte.Opcode{ .push_flight_group, .push_ship }, [_]u8{ 1, 3 }, [_]u8{ 1, 0 }) |push, entity, set| {
        try routine.op(push, &.{entity});
        try routine.op(.push_byte, &.{set});
        try routine.command("SetHostile");
        try routine.op(push, &.{entity});
        try routine.op(.push_byte, &.{set});
        try routine.command("DoNotDisturb");
    }
    try routine.op(.push_ship, &.{1});
    try routine.op(.push_byte, &.{1});
    try routine.command("DisableListing");
    const code = try finishPart(&routine);
    defer gpa.free(code);

    var grendel = shipRecord(1, 0, @intFromEnum(gameobj.Type.grendel));
    grendel.position = .{ 100, 0, 0 };
    var sabres = [2]dte.Ship{ shipRecord(2, 1, @intFromEnum(gameobj.Type.sabre)), shipRecord(3, 1, @intFromEnum(gameobj.Type.sabre)) };
    sabres[0].position = .{ 0, 0, 1000 };
    sabres[1].position = .{ 0, 0, 2000 };
    var marker = shipRecord(4, 2, dte.Ship.nav_point_kind);
    marker.position = .{ 0, 0, 30000 };
    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .ships = &.{ shipRecord(0, 0, @intFromEnum(gameobj.Type.predator)), grendel, sabres[0], sabres[1], marker },
        .flight_groups = &.{ groupRecord(5, .player), groupRecord(6, .none), groupRecord(7, .none) },
    });
    defer game.deinit();
    try game.start(game.spawning());

    const all = game.mission.objects;
    const ships = try game.fixture.mission.ships();
    // The Grendel stands 30000 ahead and 100 to the left of where the mission places it.
    for ([_]u16{ 2, 3 }, [_]f32{ 31000, 32000 }) |sabre, z| {
        const at: [3]f32 = .{ -100, 0, z };
        try std.testing.expectEqual(at, ships[sabre].runtime_position);
        try std.testing.expectEqual(at, gameobj.vector(all.slots[sabre].object.root.position));
        try std.testing.expectEqual(at, gameobj.vector(all.slots[sabre].object.root.next_position));
        try std.testing.expectEqual(at, all.slots[sabre].drawn.position);
    }
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, gameobj.vector(all.slots[0].object.root.position));
    try std.testing.expectEqual(.hostile, all.slots[2].object.side);
    try std.testing.expectEqual(.friendly, all.slots[3].object.side);
    try std.testing.expect(all.slots[2].object.flags.do_not_disturb and !all.slots[3].object.flags.do_not_disturb);
    try std.testing.expect(all.slots[1].object.flags.listing_disabled and !all.slots[2].object.flags.listing_disabled);
}

test "the flyback markers and the Grendels go, and the action sphere takes its default" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    try createFlightGroups(&routine, &.{ 0, 1 });
    try routine.op(.push_ship, &.{1});
    try routine.pushConstant(0);
    try routine.command("SetActionCentre");
    try routine.command("ResetFlybackMarker");
    try routine.op(.push_flight_group, &.{1});
    try routine.command("DestroyFlightGroup");
    const code = try finishPart(&routine);
    defer gpa.free(code);

    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .ships = &.{
            shipRecord(0, 0, @intFromEnum(gameobj.Type.predator)),
            shipRecord(1, 1, @intFromEnum(gameobj.Type.grendel)),
            shipRecord(2, 1, @intFromEnum(gameobj.Type.grendel)),
        },
        .flight_groups = &.{ groupRecord(3, .player), groupRecord(4, .none) },
    });
    defer game.deinit();
    const world = &game.mission;
    world.player.flyback.mark(0, 10);
    world.objects.action_sphere.radius = 5;
    try game.start(game.spawning());

    const all = world.objects;
    try std.testing.expectEqual(aigeneric.ActionSphere.default.radius, all.action_sphere.radius);
    try std.testing.expectEqual(0, world.player.flyback.count);
    try std.testing.expectEqual(.none, all.slots[0].object.nav_point);
    for ([_]u16{ 1, 2 }) |ship| try std.testing.expectEqual(.stand_in, all.slots[ship].object.type);
}

test "DisableObject acts on each component a squad names" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    try routine.op(.push_squad, &.{0});
    try routine.op(.push_byte, &.{1});
    try routine.command("DisableObject");
    const code = try finishPart(&routine);
    defer gpa.free(code);

    // Ship 0 and a squad of two of its components, 0 and 2, as a mission hides a ship's cargo pods.
    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .ships = &.{shipRecord(0, dte.Ship.no_flight_group, @intFromEnum(gameobj.Type.mammoth))},
        .objects = &.{ objectRecord(.ship, 0, 0), objectRecord(.squad, 0, 0) },
        .squads = &.{dte.testing.squad(1, 0)},
        .squad_members = &.{ memberRecord(0, 0, 0), memberRecord(0, 0, 2) },
    });
    defer game.deinit();

    // Components 0 to 2 are parts 0, 2 and 3; part 1 is part 0's damaged model, which shares its
    // link.
    var mammoth: objects.testing.Parts(4) = undefined;
    mammoth.init();
    mammoth.components(.{ true, false, true, true }, .{ 1, 1, 2, 3 });
    const slot = &game.mission.objects.slots[0];
    slot.model = try mammoth.model(gpa, .{});
    create.collectComponents(slot);

    try game.start(game.orders());
    // Each named component's assembly shows its damaged model; the rest, and the ship, are as they
    // were.
    const parts = slot.model.?.parts;
    try std.testing.expect(parts[0].hidden and !parts[1].hidden);
    try std.testing.expect(!parts[2].hidden and parts[3].hidden);
    try std.testing.expect(!slot.object.flags.disabled);
}

test "the commands of Instant Action's bosses and its end" {
    const gpa = std.testing.allocator;
    const shp = @import("../../formats/shp.zig");
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    // The turret base, component 0, goes with its damaged model; the engine, component 1, goes and
    // leaves its damaged model shown.
    try routine.op(.push_component, &.{ 1, 0 });
    try routine.op(.push_byte, &.{0});
    try routine.command("DestroySubObject");
    try routine.op(.push_component, &.{ 1, 1 });
    try routine.op(.push_byte, &.{1});
    try routine.command("DestroySubObject");
    // The turret on component 2 aims at the player's ship.
    try routine.op(.push_component, &.{ 1, 2 });
    try routine.op(.push_ship, &.{0});
    try routine.command("TurretSetTarget");
    try routine.op(.push_ship, &.{0});
    try routine.command("ReplenishWeapons");
    try routine.op(.push_byte, &.{0});
    try routine.op(.push_byte, &.{1});
    try routine.command("SetEnvironmentFX");
    try routine.command("TerminateMission");
    const code = try finishPart(&routine);
    defer gpa.free(code);

    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .ships = &.{
            shipRecord(0, dte.Ship.no_flight_group, @intFromEnum(gameobj.Type.predator)),
            shipRecord(1, dte.Ship.no_flight_group, @intFromEnum(gameobj.Type.kurgan)),
        },
    });
    defer game.deinit();
    const world = &game.mission;
    const player = try world.add(.predator, @splat(0));
    const boss = try world.add(.kurgan, @splat(0));
    var environment: @import("environfx.zig").Environment = .{ .sky = undefined, .textures = undefined, .space = undefined };
    var ctx = game.orders();
    ctx.world.environment = &environment;

    // The boss's components are parts 0, 2 and 4; parts 1 and 3 are the damaged models of the
    // first two, which share their links. Part 2 is an engine.
    var kurgan: objects.testing.Parts(5) = undefined;
    kurgan.init();
    kurgan.components(.{ true, false, true, false, true }, .{ 1, 1, 2, 2, 3 });
    kurgan.data[2].part.class = .engine;
    const slot = world.slot(boss);
    slot.model = try kurgan.model(gpa, .{});
    create.collectComponents(slot);
    slot.object.engines = 1;
    // Its turret stands on component 2, aimed at nothing.
    var muzzle = std.mem.zeroes(shp.Attachment);
    const model = &slot.model.?;
    try guns.testing.fitTo(slot, gpa, &.{.{ .turret = .{ .aimed = .{
        .barrel = .{ .muzzle = .{ .model = model, .part = 4, .attachment = &muzzle }, .type = .turret_lasers },
        .model = model,
        .base = 4,
        .pitch = 4,
        .slots = @splat(null),
    } } }});
    // The player's ship spent.
    const ship = &world.slot(player).object;
    ship.countermeasures = 0;
    ship.gun_charge = 0;
    ship.afterburner_fuel = 0;
    ship.armor = .all(1);

    try game.start(ctx);
    const parts = model.parts;
    try std.testing.expect(parts[0].removed and parts[1].removed);
    try std.testing.expect(parts[2].removed and !parts[3].removed and !parts[3].hidden);
    try std.testing.expectEqual(0, slot.object.engines_intact);
    try std.testing.expectEqual(null, slot.component(0));
    try std.testing.expectEqual(@as(i16, @intCast(player)), slot.guns[0].turret.aimed.target.index);
    try std.testing.expectEqual(gameobj.countermeasures_when_created, ship.countermeasures);
    try std.testing.expectEqual(100, ship.gun_charge);
    try std.testing.expectEqual(6000, ship.afterburner_fuel);
    try std.testing.expectEqual(gameobj.Quadrants.all(29), ship.armor);
    try std.testing.expect(environment.asked.ice_field and !environment.effects.ice_field);
    try std.testing.expectEqual(1, world.player.terminated);
}

test "Scanner looks for a ship, and Fire holds its trigger" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    // The scanner looks for the Sabre, which fires for 500 ticks.
    try routine.op(.push_ship, &.{1});
    try routine.command("Scanner");
    try routine.op(.push_ship, &.{1});
    try routine.pushConstant(500);
    try routine.command("Fire");
    const code = try finishPart(&routine);
    defer gpa.free(code);

    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .ships = &.{
            shipRecord(0, dte.Ship.no_flight_group, @intFromEnum(gameobj.Type.predator)),
            shipRecord(1, dte.Ship.no_flight_group, @intFromEnum(gameobj.Type.sabre)),
        },
    });
    defer game.deinit();
    const world = &game.mission;
    _ = try world.add(.predator, @splat(0));
    const sabre = try world.add(.sabre, .{ 0, 0, 5000 });
    // The Sabre fires its one gun with every group.
    const slot = world.slot(sabre);
    try guns.testing.fitTo(slot, gpa, &.{guns.testing.barrel(.laser_cannon)});
    slot.object.gun_mode.all = true;
    world.clock.frame_start = 700;
    // The display's scanner stands at a later frame, which the command starts again.
    var display: hud.State = .{ .scanner_frame = 3, .scanner_next = 900 };
    var ctx = game.orders();
    ctx.world.display = &display;
    try game.start(ctx);

    try std.testing.expectEqual(sabre, world.player.scanner.object.?);
    try std.testing.expectEqual(0, display.scanner_frame);
    try std.testing.expectEqual(0, display.scanner_next);
    try std.testing.expectEqual(1200, slot.guns[0].firing_until);
}

test "DisableLights puts a ship's lights out, the static lights baked into its parts with them" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    try routine.op(.push_ship, &.{1});
    try routine.op(.push_byte, &.{1});
    try routine.command("DisableLights");
    const code = try finishPart(&routine);
    defer gpa.free(code);

    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .ships = &.{
            shipRecord(0, dte.Ship.no_flight_group, @intFromEnum(gameobj.Type.predator)),
            shipRecord(1, dte.Ship.no_flight_group, @intFromEnum(gameobj.Type.kurgan)),
        },
    });
    defer game.deinit();
    const world = &game.mission;
    _ = try world.add(.predator, @splat(0));
    const kurgan = try world.add(.kurgan, @splat(0));
    // Parts 0 and 2 hold static lights, as the loader baked them; part 2 has been taken out.
    var parts: objects.testing.Parts(3) = undefined;
    parts.init();
    for ([_]usize{ 0, 2 }) |index| {
        parts.data[index].part.flags.has_static_light = true;
        parts.loaded_parts[index].flags.baked_mesh = true;
    }
    const slot = world.slot(kurgan);
    try parts.fit(gpa, slot);
    const model = &slot.model.?;
    model.parts[2].removed = true;
    try game.start(game.orders());

    try std.testing.expect(slot.object.flags.lights_disabled);
    try std.testing.expect(!model.parts[0].object.flags.baked_mesh);
    // A part without static lights is left alone, and so is a part taken out.
    try std.testing.expect(!model.parts[1].object.flags.baked_mesh);
    try std.testing.expect(model.parts[2].object.flags.baked_mesh);
}

test showStaticLights {
    // A carrier of two parts, the first with static lights and carrying a model whose one part
    // has them too.
    var carried_parts = [_]objects.Model.Part{objects.testing.node()};
    carried_parts[0].flags.has_static_light = true;
    var mounts = [_]objects.Model.Mount{.{
        .part = 0,
        .attachment = 0,
        .origin = @splat(0),
        .orientation = math.identity,
        .model = .{ .parts = &carried_parts, .order = &.{0}, .lights = &.{}, .glows = &.{}, .mounts = &.{} },
    }};
    var parts = [_]objects.Model.Part{ objects.testing.node(), objects.testing.node() };
    parts[0].flags.has_static_light = true;
    var model: objects.Model = .{ .parts = &parts, .order = &.{ 0, 1 }, .lights = &.{}, .glows = &.{}, .mounts = &mounts };
    showStaticLights(&model, true);
    try std.testing.expect(parts[0].object.flags.baked_mesh and !parts[1].object.flags.baked_mesh);
    try std.testing.expect(carried_parts[0].object.flags.baked_mesh);
    // Out again, the carried model's with them.
    showStaticLights(&model, false);
    try std.testing.expect(!parts[0].object.flags.baked_mesh and !carried_parts[0].object.flags.baked_mesh);
    // A part taken out keeps what it had, and so does what it carries.
    parts[0].removed = true;
    showStaticLights(&model, true);
    try std.testing.expect(!parts[0].object.flags.baked_mesh and !carried_parts[0].object.flags.baked_mesh);
}

test "ReplaceSubObject puts a ship in a component's place, a cargo pod turned as the pods hang" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    for ([_]u8{ 2, 3 }) |replacement| {
        try routine.op(.push_component, &.{ 1, 0 });
        try routine.op(.push_ship, &.{replacement});
        try routine.command("ReplaceSubObject");
    }
    const code = try finishPart(&routine);
    defer gpa.free(code);

    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .ships = &.{
            shipRecord(0, dte.Ship.no_flight_group, @intFromEnum(gameobj.Type.predator)),
            shipRecord(1, dte.Ship.no_flight_group, @intFromEnum(gameobj.Type.kurgan)),
            shipRecord(2, dte.Ship.no_flight_group, @intFromEnum(gameobj.Type.sabre)),
            shipRecord(3, dte.Ship.no_flight_group, @intFromEnum(gameobj.Type.cargo_pod)),
        },
    });
    defer game.deinit();
    const world = &game.mission;
    _ = try world.add(.predator, @splat(0));
    const kurgan = try world.add(.kurgan, .{ 1000, 0, 0 });
    const sabre = try world.add(.sabre, @splat(0));
    const pod = try world.add(.cargo_pod, @splat(0));
    // The Kurgan's one component stands 100 along its Z, the Kurgan itself turned a quarter turn
    // about Y.
    var parts: objects.testing.Parts(1) = undefined;
    parts.init();
    parts.components(.{true}, .{1});
    parts.data[0].part.position = .{ .x = 0, .y = 0, .z = 100 };
    const slot = world.slot(kurgan);
    try parts.fit(gpa, slot);
    create.collectComponents(slot);
    const turn = math.rotation(.y, std.math.pi / 2.0);
    objects.setPlace(&slot.object, &slot.drawn, .{ .position = .{ 1000, 0, 0 }, .orientation = turn });
    const frame = slot.partPlace(&slot.model.?.parts[0]).?;
    try math.testing.expectVectorWithin(.{ 1100, 0, 0 }, frame.position, 1e-3);
    try game.start(game.orders());

    // The Sabre stands where the component's frame does, turned as it is; the component is hidden.
    try std.testing.expect(slot.model.?.parts[0].hidden);
    const placed = world.slot(sabre).object.placeAt(.now);
    try math.testing.expectVectorWithin(frame.position, placed.position, 1e-3);
    try math.testing.expectMatrixWithin(frame.orientation, placed.orientation, 1e-5);
    // The pod is turned on from there, half a turn about its own Y, a quarter back about its X.
    const turned = world.slot(pod).object.placeAt(.now);
    try math.testing.expectVectorWithin(frame.position, turned.position, 1e-3);
    try math.testing.expectMatrixWithin(math.turned(math.turned(frame.orientation, .y, std.math.pi), .x, -std.math.pi / 2.0), turned.orientation, 1e-5);
}

test shipType {
    var world: gameobj.testing.Mission = undefined;
    try world.init(std.testing.allocator);
    defer world.deinit();
    const all = world.objects;
    const image = try mission.bind.testing.image(std.testing.allocator, .{
        .ships = &.{ shipRecord(0, 0, 2), shipRecord(1, 1, 2) },
        .flight_groups = &.{ groupRecord(2, .player), groupRecord(3, .none) },
    });
    var bound: mission.Mission = try .bind(std.testing.allocator, image);
    defer bound.deinit();
    const ships = try bound.ships();
    // Before the 14th mission every ship is of its kind.
    try std.testing.expectEqual(gameobj.Type.grendel, shipType(all, &bound, ships[0]));
    // From it on, the player's wing flies the twins, and mission 25's first part a Kamov.
    all.mission_number = create.twins_from_mission;
    try std.testing.expectEqual(gameobj.Type.grendel.twin().?, shipType(all, &bound, ships[0]));
    try std.testing.expectEqual(gameobj.Type.grendel, shipType(all, &bound, ships[1]));
    all.mission_number = create.kamov_mission;
    try std.testing.expectEqual(gameobj.Type.kamov, shipType(all, &bound, ships[0]));
}

test "Dock gives its order at a port, or at a flight group's ports" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    try createFlightGroups(&routine, &.{0});
    // The first Sabre at the Reliant's third port; the second at the Reliant's flight group.
    try routine.op(.push_ship, &.{1});
    try routine.op(.push_ship, &.{3});
    try routine.op(.push_byte, &.{3});
    try routine.command("Dock");
    try routine.op(.push_ship, &.{2});
    try routine.op(.push_flight_group, &.{1});
    try routine.op(.push_byte, &.{0});
    try routine.command("Dock");
    const code = try finishPart(&routine);
    defer gpa.free(code);

    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .ships = &.{
            shipRecord(0, 0, @intFromEnum(gameobj.Type.predator)),
            shipRecord(1, 0, @intFromEnum(gameobj.Type.sabre)),
            shipRecord(2, 0, @intFromEnum(gameobj.Type.sabre)),
            shipRecord(3, 1, @intFromEnum(gameobj.Type.reliant)),
        },
        .flight_groups = &.{ groupRecord(4, .none), groupRecord(5, .none) },
    });
    defer game.deinit();
    try game.start(game.spawning());

    const all = game.mission.objects;
    try std.testing.expectEqual(Order.dock, all.slots[1].orders[0].order);
    try std.testing.expectEqual(aigeneric.Target.at(3, 3), all.slots[1].orders[0].target);
    try std.testing.expectEqual(aigeneric.Target.group(.flight_group, 1), all.slots[2].orders[0].target);
}

test "the follow commands give their orders along the curves" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    try createFlightGroups(&routine, &.{0});
    // The first Sabre along curve 0 for 150 seconds; the second backwards along it, carried by
    // where the first stands.
    try routine.op(.push_ship, &.{1});
    try routine.op(.push_curve, &.{0});
    try routine.pushConstant(150);
    try routine.command("ShipFollowCurve");
    try routine.op(.push_ship, &.{2});
    try routine.op(.push_curve, &.{0});
    try routine.op(.push_byte, &.{20});
    try routine.op(.push_ship, &.{1});
    try routine.command("MovingShipBackupCurve");
    const code = try finishPart(&routine);
    defer gpa.free(code);

    const point = dte.Ship.curve_point_kind;
    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .ships = &.{
            shipRecord(0, 0, @intFromEnum(gameobj.Type.predator)),
            shipRecord(1, 0, @intFromEnum(gameobj.Type.sabre)),
            shipRecord(2, 0, @intFromEnum(gameobj.Type.sabre)),
            shipRecord(3, dte.Ship.no_flight_group, point),
            shipRecord(4, dte.Ship.no_flight_group, point),
        },
        .flight_groups = &.{groupRecord(5, .none)},
        .curves = &.{dte.testing.curve(3, 4, .{ 0, 0, 0 }, .{ 0, 0, 1000 })},
    });
    defer game.deinit();
    try game.start(game.spawning());

    const all = game.mission.objects;
    try std.testing.expectEqual(Order.ship_follow_curve, all.slots[1].orders[0].order);
    try std.testing.expectEqual(follow.Data.of(0, 150, null), all.slots[1].orders[0].data.follow);
    try std.testing.expectEqual(Order.ship_follow_curve_backwards, all.slots[2].orders[0].order);
    try std.testing.expectEqual(follow.Data.of(0, 20, 1), all.slots[2].orders[0].data.follow);
}

test "the director's commands stack shots, wait for them and stop them" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    try createFlightGroups(&routine, &.{0});
    // Along the curve for a second, looking at the Sabre, the player's flight group held still.
    try routine.op(.push_curve, &.{0});
    try routine.op(.push_ship, &.{3});
    try routine.op(.push_byte, &.{1});
    try routine.op(.push_null, &.{});
    try routine.op(.push_flight_group, &.{0});
    try routine.command("StartDirectorCam");
    try routine.command("WaitForDirectorCam");
    try routine.op(.select_global, &.{0});
    try routine.op(.push_byte, &.{1});
    try routine.op(.assign, &.{});
    // Then at the Sabre for five seconds, stopped at once.
    try routine.op(.push_ship, &.{3});
    try routine.op(.push_null, &.{});
    try routine.op(.push_byte, &.{5});
    try routine.op(.push_null, &.{});
    try routine.op(.push_null, &.{});
    try routine.command("StackDirectorCam");
    try routine.command("StopDirectorCam");
    const code = try finishPart(&routine);
    defer gpa.free(code);

    const point = dte.Ship.curve_point_kind;
    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .globals = &.{0},
        .ships = &.{
            shipRecord(0, 0, @intFromEnum(gameobj.Type.predator)),
            shipRecord(1, dte.Ship.no_flight_group, point),
            shipRecord(2, dte.Ship.no_flight_group, point),
            shipRecord(3, 0, @intFromEnum(gameobj.Type.sabre)),
        },
        .flight_groups = &.{groupRecord(4, .player)},
        .curves = &.{dte.testing.curve(1, 2, .{ 0, 0, 0 }, .{ 0, 0, 1000 })},
    });
    defer game.deinit();
    const world = &game.mission;
    const fixture = &game.fixture;
    var view: camera.Camera = .{};
    var ctx = game.spawning();
    ctx.world.camera = &view;
    try game.start(ctx);

    // The curve's points are made as markers, the start part having left them.
    const all = world.objects;
    for (all.slots[1..3]) |slot| try std.testing.expectEqual(gameobj.Type.marker, slot.object.type);
    // The shot on screen, the flight group held, and the script waiting for it.
    try std.testing.expectEqual(camera.View.director, view.view);
    try std.testing.expectEqual(3, view.director.tracked);
    try std.testing.expectEqual(100, view.director.total);
    for ([_]u16{ 0, 3 }) |ship| try std.testing.expect(all.slots[ship].object.flags.jumping);
    fixture.second();
    try std.testing.expectEqual(0, fixture.global(0));
    const seen: camera.Subject = .{ .position = @splat(0), .orientation = @import("../surrender/math.zig").identity };
    world.clock.frame_duration = 100;
    _ = view.frame(.{ .object = seen, .player = seen, .ticks = 100, .game = ctx.world });
    try std.testing.expectEqual(camera.View.cockpit, view.view);
    for ([_]u16{ 0, 3 }) |ship| try std.testing.expect(!all.slots[ship].object.flags.jumping);
    // Over, the script runs on: the next shot begins and is stopped, and stays stacked.
    fixture.second();
    try std.testing.expectEqual(1, fixture.global(0));
    try std.testing.expectEqual(camera.View.cockpit, view.view);
    try std.testing.expectEqual(1, view.shots.count);
    try std.testing.expectEqual(camera.shots.Shot.Path{ .ship = 3 }, view.shots.first().?.path.?);
}

/// The radio for the tests of its commands: a line, `MS1_BAN_001`, and the static's film in
/// archives of their own, a speaker, and the radio on them. It stays where `init` fills it in, as
/// the world's hearing holds the speaker.
const TestRadio = struct {
    archives: videoreports.testing.Archives,
    speaker: @import("hog_snd.zig").testing.Speaker,
    radio: videoreports.Radio,

    fn init(t: *TestRadio) !void {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        try t.archives.init(gpa, io, &.{"MS1_BAN_001"}, &.{.{ .name = "static.fm8", .frames = 2, .colour = 0x80 }});
        errdefer t.archives.deinit();
        try t.speaker.init(2, null);
        t.radio = t.archives.radio(gpa, io);
    }

    fn deinit(t: *TestRadio) void {
        t.radio.deinit(&t.speaker.sound);
        t.speaker.sound.shutdown();
        t.archives.deinit();
    }

    /// Puts the radio on the air in `ctx`'s world, heard on `game`'s clock.
    fn wire(t: *TestRadio, ctx: *aigeneric.Context, game: *vm.machine.testing.Game) void {
        ctx.world.radio = &t.radio;
        ctx.world.hearing = t.speaker.hearing(&game.mission.clock);
    }
};

test "the radio's commands say lines and wait for their films" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    try createFlightGroups(&routine, &.{0});
    // The ship says a line once, and the thread waits for its film, then for a line of its own.
    try routine.op(.push_ship, &.{0});
    try routine.op(.push_byte, &.{0});
    try routine.pushString("ms1_ban_001.ut");
    try routine.command("CommsFromShipOnce");
    try routine.command("WaitForMovie");
    try routine.op(.select_global, &.{0});
    try routine.op(.push_byte, &.{1});
    try routine.op(.assign, &.{});
    try routine.pushString("ms1_ban_001.ut");
    try routine.command("PlaySpeech");
    try routine.command("WaitForSpeech");
    try routine.op(.select_global, &.{0});
    try routine.op(.push_byte, &.{2});
    try routine.op(.assign, &.{});
    const code = try finishPart(&routine);
    defer gpa.free(code);

    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .globals = &.{0},
        .ships = &.{shipRecord(0, 0, @intFromEnum(gameobj.Type.predator))},
        .flight_groups = &.{groupRecord(1, .player)},
    });
    defer game.deinit();
    const fixture = &game.fixture;
    var on_air: TestRadio = undefined;
    try on_air.init();
    defer on_air.deinit();
    const radio = &on_air.radio;
    const sound = &on_air.speaker.sound;
    var display: hud.State = .{};
    var ctx = game.spawning();
    ctx.world.display = &display;
    on_air.wire(&ctx, &game);
    try game.start(ctx);

    // The line waits for the window, held open, with its film playing once.
    try std.testing.expect(radio.movie.playing and radio.movie.waiting);
    try std.testing.expectEqual(hudmovie.Flags.once, radio.movie.flags);
    try std.testing.expect(display.windows.status.get(.radio).held);
    fixture.second();
    try std.testing.expectEqual(0, fixture.global(0));
    // Once the film is over, the script plays its own line, and waits for that.
    radio.movie.stop();
    fixture.second();
    try std.testing.expectEqual(1, fixture.global(0));
    try std.testing.expect(radio.speaking(sound));
    fixture.second();
    try std.testing.expectEqual(1, fixture.global(0));
    radio.player.stop(gpa, sound);
    fixture.second();
    try std.testing.expectEqual(2, fixture.global(0));
}

test halfword {
    try std.testing.expectEqual(-1, halfword(0xFFFF));
    try std.testing.expectEqual(-1, halfword(0xFFFF_FFFF));
    try std.testing.expectEqual(0x2345, halfword(0x12345));
    try std.testing.expectEqual(std.math.minInt(i16), halfword(0x8000));
    try std.testing.expect(halfwordSet(0x10001) and !halfwordSet(0x10000));
}

test "Fly aims at the halfword its target gives, and gives no speed where it is refused" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    // The player's ship refuses Fly at 100, and the exploding Sabre at 0.
    for ([_]u8{ 0, 2 }, [_]u8{ 100, 0 }) |ship, speed| {
        try routine.op(.push_ship, &.{ship});
        try routine.op(.push_null, &.{});
        try routine.op(.push_byte, &.{speed});
        try routine.command("Fly");
    }
    // The other Sabre flies at 20 to what a byte names: a place before the ships' records, which
    // the game takes for a ship's all the same.
    try routine.op(.push_ship, &.{1});
    try routine.op(.push_byte, &.{1});
    try routine.op(.push_byte, &.{20});
    try routine.command("Fly");
    const code = try finishPart(&routine);
    defer gpa.free(code);

    const ships = dte.testing.ships(3, @intFromEnum(gameobj.Type.sabre));
    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{ .ships = &ships });
    defer game.deinit();
    const world = &game.mission;
    const player = try world.add(.predator, @splat(0));
    const flying = try world.add(.sabre, .{ 0, 0, 5000 });
    const exploding = try world.add(.sabre, .{ 0, 0, 9000 });
    try std.testing.expect(try aigeneric.push(game.orders(), player, .player_control, .none));
    try std.testing.expect(try aigeneric.push(game.orders(), exploding, .explode, .none));
    world.slot(exploding).orders[0].data.destroyed.may_spin = true;
    world.slot(exploding).object.flags.exploding = true;
    try game.start(game.orders());

    // The player's ship keeps its controls, the mouse's stick where it was; the exploding Sabre
    // may still spin out.
    const controls = world.slot(player).orders[0];
    try std.testing.expectEqual(Order.player_control, controls.order);
    try std.testing.expectEqual([2]i16{ 0, 0 }, controls.data.words[0..2].*);
    try std.testing.expect(world.slot(exploding).orders[0].data.destroyed.may_spin);
    const fly = world.slot(flying).orders[0];
    try std.testing.expectEqual(Order.fly, fly.order);
    try std.testing.expectEqual(@as(i16, @bitCast(game.fixture.machine.mission.shipIndex(1).?)), fly.target.index);
    try std.testing.expectEqual(20, fly.data.fly);
}

test "SetInvulnerability reaches the player's ship in the simulator's training, and components" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    // The player's ship and the Sabre's component 1 invulnerable, and its component 0 targetable.
    try routine.op(.push_ship, &.{0});
    try routine.op(.push_byte, &.{@intFromEnum(gameobj.Invulnerability.full)});
    try routine.command("SetInvulnerability");
    try routine.op(.push_component, &.{ 1, 1 });
    try routine.op(.push_byte, &.{@intFromEnum(gameobj.Invulnerability.player_can_hit)});
    try routine.command("SetInvulnerability");
    try routine.op(.push_component, &.{ 1, 0 });
    try routine.op(.push_byte, &.{1});
    try routine.command("SetTargetable");
    const code = try finishPart(&routine);
    defer gpa.free(code);

    const ships = dte.testing.ships(2, @intFromEnum(gameobj.Type.sabre));
    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{ .ships = &ships });
    defer game.deinit();
    const world = &game.mission;
    const player = try world.add(.predator, @splat(0));
    const sabre = try world.add(.sabre, .{ 0, 0, 5000 });
    // Outside the training missions, in the simulator's training.
    world.objects.mission_number = 1;
    world.objects.simulator.mode = .training;
    // The Sabre's two components, of an assembly each.
    var parts: objects.testing.Parts(2) = undefined;
    parts.init();
    parts.components(.{ true, true }, .{ 1, 2 });
    const slot = world.slot(sabre);
    slot.model = try parts.model(gpa, .{});
    create.collectComponents(slot);
    try game.start(game.orders());

    try std.testing.expectEqual(.full, world.slot(player).object.invulnerable);
    // The components take what the commands give; the Sabre itself is as it was.
    try std.testing.expectEqual(@intFromEnum(gameobj.Invulnerability.player_can_hit), slot.object.components[1].invulnerable);
    try std.testing.expectEqual(0, slot.object.components[0].invulnerable);
    try std.testing.expectEqual(.none, slot.object.invulnerable);
    try std.testing.expect(slot.component(0).?.targetable and !slot.component(1).?.targetable);
}

test "StartShipAnimation plays a ship's track from the start, and the reverse from where it stands" {
    const gpa = std.testing.allocator;
    const shp = @import("../../formats/shp.zig");
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    // The first ship's doors open, and the second's close.
    try routine.op(.push_ship, &.{0});
    try routine.pushString("doors");
    try routine.command("StartShipAnimation");
    try routine.op(.push_ship, &.{1});
    try routine.pushString("doors");
    try routine.command("StartShipAnimationReverse");
    const code = try finishPart(&routine);
    defer gpa.free(code);

    const ships = dte.testing.ships(2, @intFromEnum(gameobj.Type.reliant));
    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{ .ships = &ships });
    defer game.deinit();
    const world = &game.mission;
    // Two ships of two parts, each with the track; each part of the second stands partway through
    // it.
    var tracks = [_]shp.Track{.{ .clip = objects.testing.clip(400, .once, "Doors"), .keyframes = &.{}, .events = &.{} }};
    var models: [2]objects.testing.Parts(2) = undefined;
    const times = [2]f32{ 100, 250 };
    for (&models, 0..) |*parts, at| {
        parts.init();
        for (&parts.data) |*data| data.tracks = &tracks;
        const slot = world.slot(try world.add(.reliant, @splat(0)));
        try parts.fit(gpa, slot);
        if (at == 1) for (slot.model.?.parts, times) |*part, time| {
            part.animation.time = time;
        };
    }
    try game.start(game.orders());

    for ([_]u16{ 0, 1 }) |ship| {
        for (world.slot(ship).model.?.parts, times) |part, time| {
            const a = part.animation;
            try std.testing.expectEqual(objects.Model.Mode.once, a.mode);
            try std.testing.expectEqual(if (ship == 0) 0 else time, a.time);
            try std.testing.expectEqual(if (ship == 0) animation_speed else -animation_speed, a.speed);
        }
    }
}

test "PlayMusic plays its piece from the music folder, at once only for 1" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    // A piece that waits for the music playing to fade, as for 0, then one whose path is too long,
    // which plays nothing.
    try routine.pushString("theme.wav");
    try routine.op(.push_byte, &.{2});
    try routine.command("PlayMusic");
    try routine.pushString("m" ** music_path_size);
    try routine.op(.push_byte, &.{1});
    try routine.command("PlayMusic");
    // A second on, one at once, which drops the piece waiting.
    try routine.op(.push_byte, &.{1});
    try routine.command("Wait");
    try routine.pushString("battle.wav");
    try routine.op(.push_byte, &.{1});
    try routine.command("PlayMusic");
    const code = try finishPart(&routine);
    defer gpa.free(code);

    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{});
    defer game.deinit();
    var speaker: @import("hog_snd.zig").testing.Speaker = undefined;
    try speaker.init(2, null);
    const sound = &speaker.sound;
    defer sound.shutdown();
    var ctx = game.orders();
    ctx.world.hearing = speaker.hearing(&game.mission.clock);
    try game.start(ctx);

    const queued = sound.music.queued.?;
    try std.testing.expectEqualStrings("music\\theme.wav", queued.path[0..queued.path_len]);
    try std.testing.expectEqual(music_forever, queued.loops);
    try std.testing.expectEqual(music_level, queued.level);
    for (0..2) |_| game.fixture.second();
    try std.testing.expectEqual(null, sound.music.queued);
}

test "PlayCommsMovie and CommsFromPilot say their lines on the radio" {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    // The first pilot says a line, which ends the frame's handlers.
    try routine.op(.push_byte, &.{0});
    try routine.op(.push_byte, &.{@intFromEnum(pilots.Head.talking)});
    try routine.pushString("ms1_ban_001.ut");
    try routine.command("CommsFromPilot");
    // A film whose path fits the game's buffer, under string 9; then one whose path does not,
    // which says nothing.
    for ([_][]const u8{ "bandit", "b" ** (comms_movie_path_size - "pilots\\".len) }, [_]u8{ 9, 7 }) |film, name| {
        try routine.pushString(film);
        try routine.pushString("ms1_ban_001.ut");
        try routine.op(.push_byte, &.{name});
        try routine.command("PlayCommsMovie");
    }
    const code = try finishPart(&routine);
    defer gpa.free(code);

    var game: vm.machine.testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{});
    defer game.deinit();
    var on_air: TestRadio = undefined;
    try on_air.init();
    defer on_air.deinit();
    const radio = &on_air.radio;
    var ctx = game.orders();
    on_air.wire(&ctx, &game);
    try game.start(ctx);

    try std.testing.expectEqual(videoreports.pilot_base, radio.object);
    try std.testing.expect(radio.movie.playing);
    game.fixture.second();
    try std.testing.expectEqual(9, radio.name);
    try std.testing.expectEqual(videoreports.nobody, radio.object);
    try std.testing.expectEqual(hudmovie.Flags.looping, radio.movie.flags);
    try std.testing.expect(game.fixture.machine.finished);
}

test {
    std.testing.refAllDecls(@This());
}
