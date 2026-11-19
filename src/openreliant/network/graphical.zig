//! A pilot on the connection screen, then in the dedicated host's arena.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const math = engine.surrender.math;
const Presentation = @import("scripting").Presentation;
const session = @import("session.zig");
const wire = @import("wire.zig");
const flight_input = @import("flight_input.zig");
const stock = @import("stock_arena.zig");
const FlightChat = @import("flight_chat.zig");
const FlightFrame = @import("flight_frame.zig");
const Graphical = @This();
const Connection = game.interface.Connection;
const combat_messages_per_frame = 8;
const messages_per_frame = combat_messages_per_frame + wire.ordnance.Page.pages;
const FlightNotice = union(enum) { beacon: wire.BeaconNotice, pilot: wire.PilotNotice, chat: wire.ChatLine };

// net_handle_system_message (0x004B6A80) posts 0x3B7 on session loss in flight.
const host_left: Connection.Label = .{ .english = "The host has left the game", .installed = 0x3B7 };
// pause_session_lost (0x0048E370) uses 0x5F1 for a failed connection.
const connection_lost: Connection.Label = .{ .english = "The connection to the host was lost", .installed = 0x5F1 };
const could_not_connect: Connection.Label = .{ .english = "Could not open the connection", .installed = 0x569 };
const round_finished: Connection.Label = .{ .english = "Round finished" };

client: ?session.Client = null,
hosted: ?*session.LocalGame = null,
roster: [wire.slots]?wire.CallSign = @splat(null),
flight: ?*FlightFrame = null,
notices: [game.hud.Messages.capacity]FlightNotice = undefined,
notice_count: usize = 0,
lobby_notices: Connection.Lobby.History = .{},
chat: FlightChat = .{},
wrecks: [2 * wire.slots]wire.Wreck = undefined,
wreck_count: usize = 0,
combat: [combat_messages_per_frame * wire.Combat.max]game.guns.FlightEffect = undefined,
combat_count: usize = 0,
stick: [2]i16 = @splat(0),
show_standings: bool = false,

pub fn start(pilot: *Graphical, io: std.Io, target: []const u8, screen: *Connection, name: *const wire.CallSign) void {
    if (pilot.client != null) return;
    pilot.client = .{ .expected_host = null };
    session.connect(&pilot.client.?, io, target) catch |err| {
        pilot.client = null;
        screen.message = switch (err) {
            error.ConnectFailed, error.InvalidTransportIdentity => could_not_connect,
            else => .{ .english = "Enter a valid IP address or invite" },
        };
        return;
    };
    pilot.client.?.call_sign = wire.lobbyName(name.slice());
    pilot.client.?.fighter = screen.fighter;
    screen.busy = true;
    screen.message = .{ .english = "Connecting..." };
}

pub fn hostLan(pilot: *Graphical, io: std.Io, gpa: std.mem.Allocator, directory: std.Io.Dir, screen: *Connection, name: *const wire.CallSign) void {
    if (pilot.client != null) return;
    pilot.client = .{ .expected_host = null };
    const call_sign = wire.lobbyName(name.slice());
    pilot.hosted = session.LocalGame.start(io, gpa, directory, &pilot.client.?, session.default_port, call_sign) catch |err| {
        std.log.warn("could not host a LAN game: {s}", .{@errorName(err)});
        pilot.client = null;
        screen.message = switch (err) {
            error.ListenFailed => .{ .english = "Could not open the LAN game port" },
            else => .{ .english = "Could not start the LAN game" },
        };
        return;
    };
    screen.busy = true;
    screen.source = .lan;
    pilot.client.?.fighter = screen.fighter;
    screen.selected = 0;
    screen.first = 0;
    pilot.roster[0] = pilot.hosted.?.host.localCallSign();
    screen.lobby = .{
        .role = .{ .host = .{ .port = session.default_port } },
        .roster = &pilot.roster,
        .notices = &pilot.lobby_notices,
        .local_slot = 0,
        .ship = screen.fighter,
    };
}

pub fn launch(pilot: *Graphical, screen: *Connection) void {
    const hosted = pilot.hosted orelse return;
    const lobby = screen.lobby orelse return;
    hosted.host.selectScenario(lobby.scenario);
    hosted.launch() catch |err| {
        std.log.warn("could not load the LAN arena: {s}", .{@errorName(err)});
        pilot.returnToBrowser(screen, null, .{ .english = "Could not load the multiplayer arena" });
    };
}

pub fn chooseShip(pilot: *Graphical, ship: wire.Fighter, screen: *Connection) void {
    const client = if (pilot.client) |*active| active else return;
    client.selectShip(ship) catch {
        if (screen.lobby) |*lobby| lobby.ship = client.fighter;
        return;
    };
    screen.fighter = ship;
}

pub fn returnToBrowser(pilot: *Graphical, screen: *Connection, presentation: ?*Presentation, message: Connection.Label) void {
    screen.lobby = null;
    screen.ship_picker = null;
    screen.busy = false;
    screen.message = message;
    pilot.stop(presentation);
}

pub fn leave(pilot: *Graphical, screen: *Connection, presentation: ?*Presentation) void {
    pilot.returnToBrowser(screen, presentation, .{ .english = if (pilot.hosted != null) "LAN game stopped" else "Left the server" });
}

pub fn stop(pilot: *Graphical, presentation: ?*Presentation) void {
    if (pilot.client) |*client| {
        if (pilot.hosted) |hosted| hosted.stop(client) else session.disconnect(client);
    }
    if (pilot.flight) |flight| {
        if (presentation) |shown| {
            shown.endGame();
            if (shown.host) |*host| {
                host.flight = null;
                host.flying = false;
            }
        }
        flight.destroy();
    }
    pilot.* = .{};
}

pub fn flying(pilot: *const Graphical) bool {
    return if (pilot.client) |*client| client.latest != null and !client.leaving else false;
}

pub fn sendLobbyChat(pilot: *Graphical, line: game.chat.Line) void {
    if (pilot.client) |*client| client.sendChat(.{ .to = .lobby, .text = line });
}

pub fn update(pilot: *Graphical, io: std.Io, front: *engine.genilib.interf.Interface, devices: *engine.input.Devices, typed: *game.winmain.Typed, presentation: ?*Presentation, strings: game.language.Language, chat_font: *const game.hud.Opened, reads_controls: bool) void {
    const client = if (pilot.client) |*active| active else return;
    if (front.screen != .connection) {
        pilot.returnToBrowser(&front.connection, presentation, .{});
        return;
    }
    if (pilot.hosted) |hosted| {
        if (front.connection.lobby) |lobby| hosted.host.selectScenario(lobby.scenario);
        const result = hosted.host.pump() catch |err| {
            std.log.warn("LAN game ended: {s}", .{@errorName(err)});
            pilot.returnToBrowser(&front.connection, presentation, .{ .english = "The LAN game stopped" });
            return;
        };
        if (result == .finished) {
            pilot.returnToBrowser(&front.connection, presentation, round_finished);
            return;
        }
        if (front.connection.lobby) |*lobby| lobby.role.host.can_launch = hosted.host.canLaunch();
    }
    if (pilot.flight) |flight| {
        const typing = pilot.chat.frame(client, &flight.drawn, devices, typed, chat_font, reads_controls);
        devices.keyboard.numbers_taken = flight.drawn.display.windows.up(.comms);
        defer devices.keyboard.numbers_taken = false;
        pilot.show_standings = reads_controls and !typing and devices.active(.display_kills, false);
        if (reads_controls and !typing) {
            const player = &flight.drawn.player;
            game.hud.targetKeys(&flight.drawn.display, .{
                .devices = devices,
                .player = player,
                .all = flight.drawn.objects,
                .last_view = player.viewing.last,
                .multiplayer = true,
            });
            player.balancing_shields = devices.active(.shield_balancing, false);
            player.power_held = devices.active(.powerball_window, false);
            client.setFlight(engine.input.sampleFlight(player, devices, &pilot.stick, player.viewing.view));
            client.fire_primary = engine.input.primaryHeld(devices);
            if (client.latest.?.scenario != null)
                client.setWeapons(.{ .aim = flight.weaponAim(), .presses = .from(engine.input.sampleOrdnance(player, devices)) });
        } else {
            client.setFlight(flight_input.release(client.flight_command));
            client.fire_primary = false;
            if (client.weapons) |*pending| pending.presses = .{};
        }
    }
    // Catch up after a slow render without letting a busy connection hold the frame.
    for (0..messages_per_frame) |_| {
        const event = client.poll(io) catch |err| {
            const message: Connection.Label = switch (err) {
                error.IncompatibleProtocol => .{ .english = "Incompatible multiplayer protocol" },
                error.UnverifiedServer => .{ .english = "Server identity does not match the invite" },
                error.Disconnected => if (client.joined != null) host_left else could_not_connect,
                error.TransportLost, error.SessionTimedOut => if (client.joined != null) connection_lost else could_not_connect,
                else => could_not_connect,
            };
            pilot.returnToBrowser(&front.connection, presentation, message);
            return;
        };
        switch (event) {
            .idle => return,
            .projectiles => {},
            .snapshot => {
                front.connection.lobby = null;
                front.connection.ship_picker = null;
            },
            .lobby => |scenario| {
                for (client.roster.pilots, &pilot.roster) |entry, *name| name.* = if (entry) |listed| listed.name else null;
                if (front.connection.lobby == null) front.connection.lobby = .{
                    .role = .guest,
                    .roster = &pilot.roster,
                    .notices = &pilot.lobby_notices,
                    .local_slot = client.joined.?.slot,
                    .scenario = scenario,
                    .ship = client.fighter,
                };
                if (front.connection.lobby.?.role == .guest) front.connection.lobby.?.scenario = scenario;
            },
            .beacon_notice => |notice| pilot.queueNotice(.{ .beacon = notice }),
            .pilot_notice => |notice| {
                if (notice.kind == .left_lobby) {
                    const listed = client.roster.pilots[notice.pilot.slot];
                    pilot.roster[notice.pilot.slot] = if (listed) |entry| entry.name else null;
                    presentPilotNotice(&pilot.lobby_notices, strings, notice);
                } else {
                    pilot.queueNotice(.{ .pilot = notice });
                }
            },
            .chat_line => |line| switch (line.scope) {
                .lobby => if (client.latest == null) presentChat(&pilot.lobby_notices, strings, line, 0),
                .flight, .private => pilot.queueNotice(.{ .chat = line }),
            },
            .wreck => |wreck| {
                if (pilot.wreck_count < pilot.wrecks.len) {
                    pilot.wrecks[pilot.wreck_count] = wreck;
                    pilot.wreck_count += 1;
                }
            },
            .combat => |effects| {
                const count = @min(pilot.combat.len - pilot.combat_count, effects.count);
                @memcpy(pilot.combat[pilot.combat_count..][0..count], effects.items()[0..count]);
                pilot.combat_count += count;
            },
            .admitted => if (pilot.hosted == null) {
                front.connection.message = .{ .english = "Waiting for another pilot" };
            },
            .finished => front.connection.message = round_finished,
            .closed => {
                // The local transport can acknowledge the final view before remote pilots get it.
                if (pilot.hosted) |hosted| if (hosted.host.final_tick != null) return;
                pilot.returnToBrowser(&front.connection, presentation, front.connection.message);
                return;
            },
        }
    }
}

pub fn frame(pilot: *Graphical, gpa: std.mem.Allocator, local: *game.create.Objects, tables: *const game.create.Stats, types: game.create.Types, files: stock.Files, strings: game.language.Language, presentation: ?*Presentation, combat_assets: FlightFrame.CombatAssets) !?*game.main.Drawn {
    if (!pilot.flying()) return null;
    const client = &pilot.client.?;
    if (pilot.flight) |flight| {
        try flight.apply(&client.latest.?, client.joined.?, local, types);
        try flight.presentProjectiles(&client.projectiles);
        flight.applyRoster(client.roster);
        try pilot.presentCombat(flight, types);
        pilot.presentNotices(flight, strings, client.joined.?);
        return &flight.drawn;
    }
    const flight = try FlightFrame.create(gpa, local, tables);
    errdefer flight.destroy();
    if (client.latest.?.scenario) |scenario| {
        try flight.loadArena(files, scenario, types);
        try flight.enableCombat(combat_assets, types);
    }
    try flight.apply(&client.latest.?, client.joined.?, local, types);
    try flight.presentProjectiles(&client.projectiles);
    flight.applyRoster(client.roster);
    try pilot.presentCombat(flight, types);
    pilot.presentNotices(flight, strings, client.joined.?);
    if (presentation) |shown| {
        errdefer shown.endGame();
        try shown.startGame(null, flight.drawn.objects, false);
        if (client.latest.?.scenario) |scenario| {
            var path: [game.winmain.mission_path_size]u8 = undefined;
            const number = scenario.mission();
            shown.missionStarted(game.main.scriptMission(&path, flight.drawn.objects, number, number));
        }
    }
    pilot.flight = flight;
    return &flight.drawn;
}

fn presentCombat(pilot: *Graphical, flight: *FlightFrame, types: game.create.Types) !void {
    flight.presentCombat(pilot.combat[0..pilot.combat_count]);
    pilot.combat_count = 0;
    var kept: usize = 0;
    for (pilot.wrecks[0..pilot.wreck_count]) |wreck| {
        if (wreck.tick > flight.drawn.clock.frame_start) {
            pilot.wrecks[kept] = wreck;
            kept += 1;
        } else {
            try flight.presentWreck(wreck, types);
        }
    }
    pilot.wreck_count = kept;
}

fn queueNotice(pilot: *Graphical, notice: FlightNotice) void {
    if (pilot.notice_count == pilot.notices.len) {
        @memmove(pilot.notices[0 .. pilot.notices.len - 1], pilot.notices[1..]);
        pilot.notice_count -= 1;
    }
    pilot.notices[pilot.notice_count] = notice;
    pilot.notice_count += 1;
}

fn pilotName(fallback: *[64]u8, strings: game.language.Language, name: *const wire.CallSign, slot: u16) []const u8 {
    if (name.len != 0) return name.slice();
    const label = strings.string(0xBF) orelse "Pilot";
    return std.fmt.bufPrint(fallback, "{s} {d}", .{ label, slot + 1 }) catch label;
}

/// The in-flight join text is literal in the original (0x0050DE30). Departures use the
/// installed lobby (0x562) or HUD (0x328) format from `mp_player_departed` (0x004B6890).
fn presentPilotNotice(messages: anytype, strings: game.language.Language, notice: wire.PilotNotice) void {
    const format = switch (notice.kind) {
        .joined_flight => "%s has joined the game",
        .left_flight => strings.string(0x328) orelse "%s has left the game",
        .left_lobby => strings.string(0x562) orelse "SYSTEM : %s HAS LEFT THE SESSION",
    };
    var fallback: [64]u8 = undefined;
    game.deathmatch.addMessage(messages, notice.tick, format, &.{pilotName(&fallback, strings, &notice.name, notice.pilot.slot)});
}

/// The original receives chat as "%s: %s" (0x00503184) in both the lobby
/// and the flight HUD.
fn presentChat(messages: anytype, strings: game.language.Language, line: wire.ChatLine, tick: i32) void {
    var fallback: [64]u8 = undefined;
    const name = pilotName(&fallback, strings, &line.name, line.sender);
    game.deathmatch.addMessage(messages, tick, "%s: %s", &.{ name, line.text.slice() });
}

fn presentNotices(pilot: *Graphical, flight: *FlightFrame, strings: game.language.Language, admission: wire.Admission) void {
    const viewer: game.players.ParticipantRef = .{ .slot = admission.slot, .generation = admission.generation };
    const messages = &flight.drawn.display.messages;
    for (pilot.notices[0..pilot.notice_count]) |*entry| switch (entry.*) {
        .beacon => |*notice| {
            var fallback: [64]u8 = undefined;
            notice.event.present(messages, strings, viewer, pilotName(&fallback, strings, &notice.name, notice.event.pilot.slot));
        },
        .pilot => |notice| presentPilotNotice(messages, strings, notice),
        .chat => |line| presentChat(messages, strings, line, flight.drawn.clock.frame_start),
    };
    pilot.notice_count = 0;
}

pub fn cameraPlace(pilot: *Graphical, drawn: *const game.main.Drawn) game.camera.Place {
    const slot = &drawn.objects.slots[drawn.objects.player];
    const flight = pilot.flight.?;
    const left = flight.respawns.left[drawn.objects.player];
    if (left != 0) return game.deathmatch.respawn.camera(slot.drawn, left);
    if (flight.death_view) |death| {
        if (death.watching_from) |at| return .{ .position = at, .orientation = math.lookAt(slot.drawn.position - at) };
        const since: f32 = @floatFromInt(drawn.clock.frame_start -| death.started);
        return game.camera.pullBack(slot.drawn.position, slot.drawn.orientation, since);
    }
    const offset = game.camera.Chase.offset(slot.object.type);
    const throttle = if (slot.object.afterburner) game.camera.Chase.afterburner_throttle else slot.object.throttle;
    const shake = drawn.shake * game.camera.Cockpit.shake_share * game.camera.Cockpit.camera_shake;
    const jitter = flight.random.centredVector(@splat(shake));
    return .{
        .position = slot.drawn.position + math.transform(slot.drawn.orientation, .{ 0, offset.height, -offset.distance - game.camera.Chase.throttle_distance * throttle }),
        .orientation = math.product(math.fromAngleVector(jitter), slot.drawn.orientation),
    };
}
