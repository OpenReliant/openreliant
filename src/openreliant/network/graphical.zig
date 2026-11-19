//! A pilot on the connection screen, then in the dedicated host's arena.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const math = engine.surrender.math;
const Presentation = @import("scripting").Presentation;
const session = @import("session.zig");
const wire = @import("wire.zig");
const MultiplayerMenu = game.hudoptions.multiplayer;
const stock = @import("stock_arena.zig");
const FlightChat = @import("flight_chat.zig");
const FlightFrame = @import("flight_frame.zig");
const Graphical = @This();
const Connection = game.interface.Connection;
const combat_messages_per_frame = 8;
const messages_per_frame = combat_messages_per_frame + wire.ordnance.Page.pages;
const FlightNotice = union(enum) { beacon: wire.BeaconNotice, tag_bomb: wire.TagBombNotice, shadow: wire.ShadowNotice, pilot: wire.PilotNotice, chat: wire.ChatLine };

// net_handle_system_message (0x004B6A80) posts 0x3B7 on session loss in flight.
const host_left: Connection.Label = .{ .english = "The host has left the game", .installed = 0x3B7 };
// pause_session_lost (0x0048E370) uses 0x5F1 for a failed connection.
const connection_lost: Connection.Label = .{ .english = "The connection to the host was lost", .installed = 0x5F1 };
const dropped: Connection.Label = .{ .english = "The host dropped your connection" };
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
flight_history: MultiplayerMenu.History = .{},
pause_menu: MultiplayerMenu.State = .{},
menu_open: bool = false,
session_lost: ?Connection.Label = null,
pause_players: [wire.slots]?MultiplayerMenu.Player = @splat(null),
pause_name: [64]u8 = undefined,
last_camera: ?game.camera.Place = null,
wrecks: [2 * wire.slots]wire.Wreck = undefined,
wreck_count: usize = 0,
combat: [combat_messages_per_frame * wire.Combat.max]game.guns.FlightEffect = undefined,
combat_count: usize = 0,
stick: [2]i16 = @splat(0),
standings_first: ?usize = null,

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

fn stopConnection(pilot: *Graphical) void {
    if (pilot.client) |*client| {
        if (pilot.hosted) |hosted| hosted.stop(client) else session.disconnect(client);
    }
    pilot.client = null;
    pilot.hosted = null;
}

pub fn stop(pilot: *Graphical, presentation: ?*Presentation) void {
    pilot.stopConnection();
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
    if (pilot.session_lost != null) return pilot.flight != null;
    return if (pilot.client) |*client| client.latest != null and !client.leaving else false;
}

pub fn sendLobbyChat(pilot: *Graphical, line: game.chat.Line) void {
    if (pilot.client) |*client| client.sendChat(.{ .to = .lobby, .text = line });
}

pub fn sharedPaused(pilot: *const Graphical) bool {
    if (pilot.hosted) |hosted| return hosted.host.paused;
    return if (pilot.client) |*client| client.roster.paused else false;
}

pub fn menuVisible(pilot: *const Graphical) bool {
    return pilot.flight != null and (pilot.menu_open or pilot.sharedPaused() or pilot.session_lost != null);
}

pub fn takesText(pilot: *const Graphical) bool {
    return if (pilot.menuVisible()) pilot.session_lost == null and pilot.pause_menu.editor.focused else pilot.chat.target != null;
}

pub fn menuView(pilot: *Graphical, strings: game.language.Language) ?MultiplayerMenu.View {
    if (!pilot.menuVisible()) return null;
    if (pilot.session_lost) |reason| return .{ .lost = reason };
    const client = &pilot.client.?;
    const shared = pilot.sharedPaused();
    for (client.roster.pilots, &pilot.pause_players, 0..) |entry, *row, slot| {
        row.* = if (entry) |peer| .{
            .generation = peer.generation,
            .name = peer.name,
            .can_drop = if (pilot.hosted) |hosted| hosted.host.canDropPausedPilot(.{ .slot = @intCast(slot), .generation = peer.generation }) else false,
        } else null;
    }
    const host = &client.roster.pilots[0];
    return .{ .match = .{
        .all = pilot.flight.?.drawn.objects,
        .history = &pilot.flight_history,
        .players = &pilot.pause_players,
        .paused_by = if (shared) pilotName(&pilot.pause_name, strings, if (host.*) |*peer| &peer.name else &.{}, 0) else null,
        .can_continue = !shared or pilot.hosted != null,
    } };
}

fn menuAction(pilot: *Graphical, action: MultiplayerMenu.Action, screen: *Connection, presentation: ?*Presentation) void {
    switch (action) {
        .resume_match => {
            pilot.menu_open = false;
            pilot.pause_menu = .{};
            if (pilot.hosted) |hosted| hosted.host.setPaused(false);
        },
        .leave_match => {
            if (pilot.session_lost) |reason| pilot.returnToBrowser(screen, presentation, reason) else pilot.leave(screen, presentation);
        },
        .send_chat => |line| pilot.client.?.sendChat(.{ .to = .flight, .text = line }),
        .drop => |admission| if (pilot.hosted) |hosted| hosted.host.dropPausedPilot(.{ .slot = @intCast(admission.slot), .generation = admission.generation }),
    }
}

fn showSessionLoss(pilot: *Graphical, screen: *Connection, presentation: ?*Presentation, reason: Connection.Label) void {
    if (pilot.flight == null) {
        pilot.returnToBrowser(screen, presentation, reason);
        return;
    }
    pilot.stopConnection();
    pilot.session_lost = reason;
    pilot.pause_menu = .{};
    pilot.chat = .{};
}

pub fn update(pilot: *Graphical, io: std.Io, front: *engine.genilib.interf.Interface, controls: MultiplayerMenu.ControlFrame, presentation: ?*Presentation, strings: game.language.Language, chat_font: *const game.hud.Opened, reads_controls: bool) void {
    if (pilot.client == null and pilot.session_lost == null) return;
    if (front.screen != .connection) {
        pilot.returnToBrowser(&front.connection, presentation, .{});
        return;
    }
    if (pilot.session_lost != null) {
        if (reads_controls) if (pilot.pause_menu.frame(pilot.menuView(strings).?, controls)) |action|
            pilot.menuAction(action, &front.connection, presentation);
        return;
    }
    const client = if (pilot.client) |*active| active else return;
    if (pilot.hosted) |hosted| {
        if (front.connection.lobby) |lobby| hosted.host.selectScenario(lobby.scenario);
        const result = hosted.host.pump() catch |err| {
            std.log.warn("LAN game ended: {s}", .{@errorName(err)});
            pilot.showSessionLoss(&front.connection, presentation, .{ .english = "The LAN game stopped" });
            return;
        };
        if (result == .finished) {
            pilot.returnToBrowser(&front.connection, presentation, round_finished);
            return;
        }
        if (front.connection.lobby) |*lobby| lobby.role.host.can_launch = hosted.host.canLaunch();
    }
    if (pilot.flight) |flight| {
        const devices = controls.devices;
        const typed = controls.typed;
        var consumed = pilot.menuVisible();
        if (consumed) {
            if (reads_controls) if (pilot.pause_menu.frame(pilot.menuView(strings).?, controls)) |action| {
                pilot.menuAction(action, &front.connection, presentation);
                if (pilot.client == null) return;
            };
        } else {
            // COMMS and its active draft get Escape before the match menu.
            consumed = pilot.chat.frame(client, &flight.drawn, devices, typed, chat_font, reads_controls);
            if (reads_controls and !consumed and devices.keyboard.pressed(engine.input.scan.escape, .none, true)) {
                pilot.menu_open = true;
                pilot.pause_menu = .{};
                typed.clear();
                if (pilot.hosted) |hosted| hosted.host.setPaused(true);
                consumed = true;
            }
        }
        devices.keyboard.numbers_taken = flight.drawn.display.windows.up(.comms);
        defer devices.keyboard.numbers_taken = false;
        if (reads_controls and !consumed and devices.active(.display_kills, false)) {
            const standings = game.hud.standings;
            var count: usize = 0;
            for (client.roster.pilots) |entry| if (entry != null) {
                count += 1;
            };
            const shown = standings.visibleRows(controls.window, controls.scale.of(controls.window) * controls.standings_scale);
            var scroll = standings.scrollWindow(pilot.standings_first orelse 0, count, shown);
            if (count > shown) {
                standings.scrollWheel(&scroll, devices.mouse.notches());
                if (devices.keyboard.pressed(@backingInt(engine.input.Key.page_up), .none, true)) standings.scrollPage(&scroll, .up);
                if (devices.keyboard.pressed(@backingInt(engine.input.Key.page_down), .none, true)) standings.scrollPage(&scroll, .down);
            }
            pilot.standings_first = scroll.first;
        } else {
            pilot.standings_first = null;
        }
        if (reads_controls and !consumed) {
            const scene = flight.world();
            const all = scene.objects;
            const display = &flight.drawn.display;
            const multiplayer_ordnance = client.latest.?.scenario != null;
            var cockpit: game.players.CockpitCommand = .{};
            game.hud.targetKeys(display, .{
                .devices = devices,
                .player = scene.player,
                .all = all,
                .last_view = scene.player.viewing.last,
                .multiplayer = true,
                .multiplayer_ordnance = multiplayer_ordnance,
                .world = scene,
            });
            engine.input.frameKeys(.{
                .display = display,
                .charges = &all.player_states[all.player].charges,
                .player = scene.player,
                .devices = devices,
                .slot = &all.slots[all.player],
                .view = scene.view(),
                .game_ticks = scene.clock.game_ticks,
                .multiplayer = true,
                .submitted = &cockpit,
                .world = scene,
                .all = all,
            });
            client.setFlight(engine.input.sampleFlight(scene.player, devices, &pilot.stick, scene.player.viewing.view));
            client.fire_primary = engine.input.primaryHeld(devices);
            if (multiplayer_ordnance) {
                const weapons = engine.input.sampleOrdnance(scene.player, devices);
                if (weapons.rotate_missiles != null and display.windows.open(.missiles, false))
                    display.windows.status.getPtr(.missiles).held = true;
                client.setWeapons(.{ .aim = flight.weaponAim(), .presses = .from(weapons), .cockpit = cockpit });
            }
        } else {
            client.releaseFlight();
        }
    }
    const shared_before = pilot.sharedPaused();
    // Catch up after a slow render without letting a busy connection hold the frame.
    for (0..messages_per_frame) |_| {
        const event = client.poll(io) catch |err| {
            const message: Connection.Label = switch (err) {
                error.IncompatibleProtocol => .{ .english = "Incompatible multiplayer protocol" },
                error.UnverifiedServer => .{ .english = "Server identity does not match the invite" },
                error.DroppedForLag => dropped,
                error.Disconnected => if (client.joined != null) host_left else could_not_connect,
                error.TransportLost, error.SessionTimedOut => if (client.joined != null) connection_lost else could_not_connect,
                else => if (pilot.flight != null) connection_lost else could_not_connect,
            };
            pilot.showSessionLoss(&front.connection, presentation, message);
            return;
        };
        switch (event) {
            .idle => break,
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
            .tag_bomb_notice => |notice| pilot.queueNotice(.{ .tag_bomb = notice }),
            .shadow_notice => |notice| pilot.queueNotice(.{ .shadow = notice }),
            .pilot_notice => |notice| {
                if (notice.kind == .left_lobby) {
                    const listed = client.roster.pilots[notice.pilot.slot];
                    pilot.roster[notice.pilot.slot] = if (listed) |entry| entry.name else null;
                    presentPilotNotice(&pilot.lobby_notices, strings, notice);
                } else {
                    presentPilotNotice(&pilot.flight_history, strings, notice);
                    pilot.queueNotice(.{ .pilot = notice });
                }
            },
            .chat_line => |line| switch (line.scope) {
                .lobby => if (client.latest == null) presentChat(&pilot.lobby_notices, strings, line, 0),
                .flight, .private => {
                    presentChat(&pilot.flight_history, strings, line, 0);
                    pilot.queueNotice(.{ .chat = line });
                },
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
    if (!shared_before and pilot.sharedPaused()) {
        if (pilot.flight) |flight| flight.drawn.display.windows.close(.comms);
        pilot.chat = .{};
        controls.typed.clear();
        client.releaseFlight();
    } else if (shared_before and !pilot.sharedPaused() and !pilot.menu_open) {
        pilot.pause_menu = .{};
        controls.typed.clear();
    }
}

pub fn frame(pilot: *Graphical, gpa: std.mem.Allocator, local: *game.create.Objects, tables: *const game.create.Stats, types: game.create.Types, files: stock.Files, strings: game.language.Language, presentation: ?*Presentation, combat_assets: FlightFrame.CombatAssets) !?*game.main.Drawn {
    if (!pilot.flying()) return null;
    if (pilot.session_lost != null) return &pilot.flight.?.drawn;
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
    var shadow_announced = false;
    for (pilot.notices[0..pilot.notice_count]) |*entry| switch (entry.*) {
        .beacon => |*notice| {
            var fallback: [64]u8 = undefined;
            notice.event.present(messages, strings, viewer, pilotName(&fallback, strings, &notice.name, notice.event.pilot.slot));
        },
        .tag_bomb => |*notice| {
            var fallback: [2][64]u8 = undefined;
            notice.event.present(messages, strings, viewer, pilotName(&fallback[0], strings, &notice.name, notice.event.pilot.slot), pilotName(&fallback[1], strings, &notice.other_name, notice.event.other.slot));
        },
        .shadow => |*notice| {
            var fallback: [2][64]u8 = undefined;
            const name = pilotName(&fallback[0], strings, &notice.name, notice.event.pilot.slot);
            const other = if (notice.event.other) |participant| pilotName(&fallback[1], strings, &notice.other_name, participant.slot) else "";
            notice.event.present(messages, strings, viewer, name, other);
            shadow_announced = shadow_announced or notice.event.kind != .killed;
        },
        .pilot => |notice| presentPilotNotice(messages, strings, notice),
        .chat => |line| presentChat(messages, strings, line, flight.drawn.clock.frame_start),
    };
    if (flight.drawn.tag_bomb) |bomb| {
        const active = bomb.carrier != null;
        // The original init announces a loose bomb only on the playing host (0x004B4398).
        if (!active and (flight.bomb_was_active orelse (pilot.hosted != null)))
            messages.add(strings.string(0x2E3) orelse "No-one has the bomb", flight.drawn.clock.frame_start);
        flight.bomb_was_active = active;
    }
    if (pilot.client.?.latest.?.scenario == .hunt_the_shadow) {
        const role = flight.drawn.shadow;
        const tick = flight.drawn.clock.frame_start;
        const shadow = game.deathmatch.hunt_the_shadow;
        if (flight.shadow_was_active == null and !shadow_announced) {
            if (role) |owner| {
                const roster = pilot.client.?.roster.pilots[owner.slot];
                const name = if (roster != null and roster.?.generation == owner.generation) roster.?.name else wire.CallSign{};
                var fallback: [64]u8 = undefined;
                shadow.announce(messages, strings, tick, pilotName(&fallback, strings, &name, owner.slot));
            } else shadow.announce(messages, strings, tick, null);
        } else if (flight.shadow_was_active == true and role == null) {
            shadow.announce(messages, strings, tick, null);
        }
        flight.shadow_was_active = role != null;
    }
    pilot.notice_count = 0;
}

pub fn cameraPlace(pilot: *Graphical, drawn: *const game.main.Drawn) game.camera.Place {
    if (pilot.sharedPaused() or pilot.session_lost != null) {
        if (pilot.last_camera) |place| return place;
    }
    const place = pilot.flightCamera(drawn);
    pilot.last_camera = place;
    return place;
}

fn flightCamera(pilot: *Graphical, drawn: *const game.main.Drawn) game.camera.Place {
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
