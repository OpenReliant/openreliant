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
const FlightNotice = union(enum) {
    beacon: wire.BeaconNotice,
    uber_kill: wire.UberKillNotice,
    tag_bomb: wire.TagBombNotice,
    shadow: wire.ShadowNotice,
    vampires: wire.VampiresNotice,
    pilot: wire.PilotNotice,
    chat: wire.ChatLine,
};

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
debrief_notices: Connection.Debrief.History = .{},
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
campaign_lines: [game.radio.queue_size + game.radio.report_count]wire.CampaignLine = undefined,
campaign_line_count: usize = 0,
campaign_result: ?wire.MissionView = null,
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

pub fn hostLan(pilot: *Graphical, io: std.Io, gpa: std.mem.Allocator, directory: std.Io.Dir, screen: *Connection, name: *const wire.CallSign, kind: Connection.HostChoice.Kind) void {
    if (pilot.client != null) return;
    pilot.client = .{ .expected_host = null };
    const call_sign = wire.lobbyName(name.slice());
    const mission: ?u16 = if (kind == .cooperative) game.gameflow.first_mission else null;
    pilot.hosted = session.LocalGame.start(io, gpa, directory, &pilot.client.?, session.default_port, call_sign, mission) catch |err| {
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
        .roster = pilot.roster[0..pilot.hosted.?.host.player_limit],
        .notices = &pilot.lobby_notices,
        .local_slot = 0,
        .ship = screen.fighter,
        .mission = mission,
    };
}

pub fn launch(pilot: *Graphical, screen: *Connection) void {
    const hosted = pilot.hosted orelse return;
    const lobby = screen.lobby orelse return;
    if (lobby.mission == null) hosted.host.selectScenario(lobby.scenario);
    hosted.launch() catch |err| {
        std.log.warn("could not load the multiplayer mission: {s}", .{@errorName(err)});
        pilot.returnToBrowser(screen, null, .{ .english = "Could not load the multiplayer mission" });
    };
}

pub fn upcomingBriefing(pilot: *const Graphical) ?u16 {
    const client = if (pilot.client) |*active| active else return null;
    if (client.briefed or !client.roster.briefing or client.latest != null) return null;
    return client.roster.mission;
}

pub const Briefing = struct {
    pilot: *Graphical,
    io: std.Io,
    failed: bool = false,

    pub fn service(context: *anyopaque) bool {
        const briefing: *Briefing = @ptrCast(@alignCast(context));
        briefing.update() catch {
            briefing.failed = true;
            return false;
        };
        return true;
    }

    fn update(briefing: *Briefing) !void {
        const pilot = briefing.pilot;
        if (pilot.hosted) |hosted| {
            if (try hosted.host.pump() == .finished) return error.SessionEnded;
        }
        const client = &pilot.client.?;
        for (0..messages_per_frame) |_| {
            if (try client.poll(briefing.io) == .idle) break;
        }
    }
};

pub fn finishBriefing(pilot: *Graphical, result: ?engine.interface.loadout.Result) !void {
    const fit: ?wire.CampaignLoadout = if (result) |chosen| .{
        .ship = std.enums.fromInt(wire.Fighter, chosen.ship) orelse return error.InvalidCampaignLoadout,
        .racks = chosen.racks,
    } else null;
    if (fit) |loadout| if (!loadout.valid()) return error.InvalidCampaignLoadout;
    try pilot.client.?.finishBriefing(fit);
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
    screen.debrief = null;
    screen.ship_picker = null;
    screen.busy = false;
    screen.message = message;
    const result = pilot.campaign_result;
    pilot.stop(presentation);
    pilot.campaign_result = result;
}

pub fn takeCampaignResult(pilot: *Graphical) ?wire.MissionView {
    if (pilot.client) |*client| if (client.result_tick == null) return null;
    const result = pilot.campaign_result;
    pilot.campaign_result = null;
    return result;
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

fn stopFlight(pilot: *Graphical, presentation: ?*Presentation) void {
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
    pilot.flight = null;
    pilot.menu_open = false;
    pilot.chat = .{};
    pilot.last_camera = null;
    pilot.campaign_line_count = 0;
    pilot.combat_count = 0;
    pilot.wreck_count = 0;
    pilot.notice_count = 0;
    pilot.flight_history = .{};
}

pub fn stop(pilot: *Graphical, presentation: ?*Presentation) void {
    pilot.stopConnection();
    pilot.stopFlight(presentation);
    pilot.* = .{};
}

pub fn flying(pilot: *const Graphical) bool {
    if (pilot.session_lost != null) return pilot.flight != null;
    return if (pilot.client) |*client| client.latest != null and client.result_tick == null and !client.leaving else false;
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
        if (front.connection.lobby) |lobby| if (lobby.mission == null) hosted.host.selectScenario(lobby.scenario);
        const result = hosted.host.pump() catch |err| {
            std.log.warn("LAN game ended: {s}", .{@errorName(err)});
            pilot.showSessionLoss(&front.connection, presentation, .{ .english = "The LAN game stopped" });
            return;
        };
        if (result == .finished) {
            const message = if (client.result_tick != null) campaign_complete else finalMessage(client.latest);
            pilot.returnToBrowser(&front.connection, presentation, message);
            return;
        }
        if (front.connection.lobby) |*lobby| {
            if (lobby.role == .host) lobby.role.host.can_launch = hosted.host.canLaunch();
        }
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
            const multiplayer_ordnance = client.latest.?.hasOrdnance();
            const cooperative = client.latest.?.mission != null;
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
            if (cooperative and devices.active(.permission_to_land, true)) client.requestCrewAction(.land);
            if (cooperative and devices.active(.eject, true)) client.requestCrewAction(.eject);
            engine.input.frameKeys(.{
                .display = display,
                .charges = &all.player_states[all.player].charges,
                .player = scene.player,
                .devices = devices,
                .slot = &all.slots[all.player],
                .view = scene.view(),
                .game_ticks = scene.clock.game_ticks,
                .multiplayer = true,
                .cooperative = cooperative,
                .submitted = &cockpit,
                .world = scene,
                .all = all,
            });
            if (cooperative and devices.active(.jump_drive, true)) client.requestCrewAction(.jump);
            client.setFlight(engine.input.sampleFlight(scene.player, devices, &pilot.stick, scene.player.viewing.view));
            client.fire_primary = engine.input.primaryHeld(devices);
            if (multiplayer_ordnance) {
                const weapons = engine.input.sampleOrdnance(scene.player, devices);
                if (weapons.rotate_missiles != null and display.windows.open(.missiles, false))
                    display.windows.status.getPtr(.missiles).held = true;
                var presses: wire.ordnance.Presses = .from(weapons);
                presses.match_speed = cooperative and devices.active(.match_speed, true);
                client.setWeapons(.{ .aim = flight.weaponAim(), .presses = presses, .cockpit = cockpit });
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
            .projectiles, .scene_page, .scenery => {},
            .campaign_result => {
                const mission = client.latest.?.mission.?;
                if (presentation) |shown| shown.missionEnded(.{ .ending = mission.ending, .rating = mission.rating });
                pilot.stopFlight(presentation);
                pilot.campaign_result = mission;
                pilot.debrief_notices = .{};
                const local = client.joined.?.slot;
                front.connection.debrief = .{
                    .local_slot = local,
                    .number = mission.number,
                    .ending = mission.ending,
                    .objectives_met = mission.objectives_met,
                    .record = .{ .rating = mission.rating, .kills = if (mission.ending == .destroyed or mission.ending == .captured) 0 else mission.kills },
                    .overall_kills = if (client.latest.?.ships[local]) |ship| ship.kills else @intCast(mission.kills),
                    .names = pilot.roster[0..wire.cooperative_slots],
                    .notices = &pilot.debrief_notices,
                };
                pilot.showDebriefCrew(&front.connection, client, strings);
            },
            .debrief => pilot.showDebriefCrew(&front.connection, client, strings),
            .campaign_next => {
                front.connection.debrief = null;
                front.connection.message = .{ .english = "Waiting for the briefing" };
            },
            .campaign_end => {
                if (pilot.hosted != null) return;
                pilot.returnToBrowser(&front.connection, presentation, campaign_complete);
                return;
            },
            .campaign_line => |line| {
                if (pilot.campaign_line_count < pilot.campaign_lines.len) {
                    pilot.campaign_lines[pilot.campaign_line_count] = line;
                    pilot.campaign_line_count += 1;
                }
            },
            .snapshot => {
                front.connection.lobby = null;
                front.connection.ship_picker = null;
            },
            .lobby => {
                for (client.roster.pilots, &pilot.roster) |entry, *name| name.* = if (entry) |listed| listed.name else null;
                if (client.result_tick != null) continue;
                if (front.connection.lobby == null) front.connection.lobby = .{
                    .role = .guest,
                    .roster = pilot.roster[0..client.roster.limit],
                    .notices = &pilot.lobby_notices,
                    .local_slot = client.joined.?.slot,
                    .mission = client.roster.mission,
                    .ship = client.fighter,
                };
                if (front.connection.lobby.?.role == .guest) {
                    front.connection.lobby.?.local_slot = client.joined.?.slot;
                    if (client.roster.lobby) |scenario| front.connection.lobby.?.scenario = scenario;
                }
            },
            .uber_kill => |notice| pilot.queueNotice(.{ .uber_kill = notice }),
            .beacon_notice => |notice| pilot.queueNotice(.{ .beacon = notice }),
            .tag_bomb_notice => |notice| pilot.queueNotice(.{ .tag_bomb = notice }),
            .shadow_notice => |notice| pilot.queueNotice(.{ .shadow = notice }),
            .vampires_notice => |notice| pilot.queueNotice(.{ .vampires = notice }),
            .pilot_notice => |notice| {
                if (notice.kind == .left_lobby) {
                    const listed = client.roster.pilots[notice.pilot.slot];
                    pilot.roster[notice.pilot.slot] = if (listed) |entry| entry.name else null;
                    if (client.result_tick != null) {
                        presentPilotNotice(&pilot.debrief_notices, strings, notice);
                    } else presentPilotNotice(&pilot.lobby_notices, strings, notice);
                } else {
                    presentPilotNotice(&pilot.flight_history, strings, notice);
                    pilot.queueNotice(.{ .pilot = notice });
                }
            },
            .chat_line => |line| switch (line.scope) {
                .lobby => if (client.result_tick != null) {
                    presentChat(&pilot.debrief_notices, strings, line, 0);
                } else if (client.latest == null) presentChat(&pilot.lobby_notices, strings, line, 0),
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
            .finished => {
                front.connection.message = finalMessage(client.latest);
                pilot.campaign_result = client.latest.?.mission;
                if (presentation) |shown| {
                    if (client.latest.?.mission) |mission|
                        shown.missionEnded(.{ .ending = mission.ending, .rating = mission.rating });
                }
            },
            .closed => {
                // The local transport can acknowledge the final view before remote pilots get it.
                if (pilot.hosted) |hosted| if (hosted.host.final_tick != null) return;
                pilot.returnToBrowser(&front.connection, presentation, front.connection.message);
                return;
            },
        }
    }
    // A landing film can pump the next briefing before the next menu frame.
    if (front.connection.debrief != null) {
        if (client.result_tick != null) pilot.showDebriefCrew(&front.connection, client, strings) else front.connection.debrief = null;
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

fn showDebriefCrew(pilot: *Graphical, screen: *Connection, client: *const session.Client, strings: game.language.Language) void {
    for (&pilot.roster, client.roster.pilots) |*name, seat| name.* = if (seat) |peer| peer.name else null;
    if (screen.debrief) |*debrief| if (client.debrief) |state| {
        var newly_ready = state.crew.ready.differenceWith(debrief.crew.ready).iterator(.{});
        while (newly_ready.next()) |slot| {
            const name = pilot.roster[slot] orelse continue;
            var fallback: [64]u8 = undefined;
            const shown = pilotName(&fallback, strings, &name, @intCast(slot));
            game.deathmatch.addMessage(&pilot.debrief_notices, 0, strings.stringOr(0x575, "System : %s READY"), &.{shown});
        }
        debrief.crew = state.crew;
    };
}

const campaign_complete: Connection.Label = .{ .english = "Campaign complete" };

fn finalMessage(view: ?wire.Snapshot) Connection.Label {
    const mission = (view orelse return round_finished).mission orelse return round_finished;
    return switch (mission.rating) {
        .partial_success, .success, .success_bonus => .{ .english = "Mission complete" },
        else => .{ .english = "Mission ended" },
    };
}

pub fn frame(pilot: *Graphical, gpa: std.mem.Allocator, local: *game.create.Objects, tables: *const game.create.Stats, types: game.create.Types, files: stock.Files, strings: game.language.Language, presentation: ?*Presentation, combat_assets: FlightFrame.CombatAssets) !?*game.main.Drawn {
    if (!pilot.flying()) return null;
    if (pilot.session_lost != null) return &pilot.flight.?.drawn;
    const client = &pilot.client.?;
    if (pilot.flight) |flight| {
        try pilot.applyFrame(flight, local, types, strings);
        return &flight.drawn;
    }
    const flight = try FlightFrame.create(gpa, local, tables);
    errdefer flight.destroy();
    flight.round_start = client.campaign_floor;
    if (client.latest.?.scenario) |scenario| {
        try flight.loadArena(files, scenario, types);
    }
    if (client.latest.?.mission != null)
        flight.drawn.radio = .openAt(gpa, files.io, files.directory, game.radio.speech_archive, game.hudmovie.archive_path);
    if (client.latest.?.hasOrdnance()) try flight.enableCombat(combat_assets, types);
    try pilot.applyFrame(flight, local, types, strings);
    if (presentation) |shown| {
        errdefer shown.endGame();
        try shown.startGame(null, flight.drawn.objects, false);
        const number = if (client.latest.?.scenario) |scenario| scenario.mission() else flight.drawn.objects.mission_number;
        if (client.latest.?.hasOrdnance()) {
            var path: [game.winmain.mission_path_size]u8 = undefined;
            shown.missionStarted(game.main.scriptMission(&path, flight.drawn.objects, number, number));
        }
    }
    pilot.flight = flight;
    return &flight.drawn;
}

fn applyFrame(pilot: *Graphical, flight: *FlightFrame, local: *game.create.Objects, types: game.create.Types, strings: game.language.Language) !void {
    const client = &pilot.client.?;
    try flight.apply(&client.latest.?, client.joined.?, local, types);
    if (client.scenery) |*scenery| {
        if (client.latest.?.scenario == scenery.scenario)
            try flight.presentScenery(scenery, types);
    }
    if (client.latest.?.mission) |mission| {
        try flight.presentScene(&client.scene, types);
        flight.presentGuide(mission.guide);
        flight.presentRadio(pilot.campaign_lines[0..pilot.campaign_line_count]);
        pilot.campaign_line_count = 0;
        const slot = client.joined.?.slot;
        // The original announces a takeover once, using string 0x558.
        if (slot != 0 and mission.lead == slot and !flight.lead_announced) {
            flight.lead_announced = true;
            game.deathmatch.addMessage(&flight.drawn.display.messages, flight.drawn.clock.frame_start, "%s", &.{
                strings.stringOr(0x558, "You are now flight leader"),
            });
        }
    }
    try flight.presentProjectiles(&client.projectiles);
    flight.applyRoster(client.roster);
    try pilot.presentCombat(flight, types);
    pilot.presentNotices(flight, strings, client.joined.?);
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
    const label = strings.stringOr(0xBF, "Pilot");
    return std.fmt.bufPrint(fallback, "{s} {d}", .{ label, slot + 1 }) catch label;
}

/// The in-flight join text is literal in the original (0x0050DE30). Departures use the
/// installed lobby (0x562) or HUD (0x328) format from `mp_player_departed` (0x004B6890).
fn presentPilotNotice(messages: anytype, strings: game.language.Language, notice: wire.PilotNotice) void {
    const format = switch (notice.kind) {
        .joined_flight => "%s has joined the game",
        .left_flight => strings.stringOr(0x328, "%s has left the game"),
        .left_lobby => strings.stringOr(0x562, "SYSTEM : %s HAS LEFT THE SESSION"),
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
        .uber_kill => |*notice| {
            var fallback: [2][64]u8 = undefined;
            notice.event.present(messages, strings, viewer, pilotName(&fallback[0], strings, &notice.owner_name, notice.event.owner.slot), pilotName(&fallback[1], strings, &notice.victim_name, notice.event.victim.slot));
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
        .vampires => |*notice| {
            var fallback: [64]u8 = undefined;
            const name = if (notice.event.change.pilot()) |who| pilotName(&fallback, strings, &notice.name, who.slot) else "";
            notice.event.present(messages, strings, viewer, name);
            flight.vampires_started = true;
        },
        .pilot => |notice| presentPilotNotice(messages, strings, notice),
        .chat => |line| presentChat(messages, strings, line, flight.drawn.clock.frame_start),
    };
    if (flight.drawn.tag_bomb) |bomb| {
        const active = bomb.carrier != null;
        // The original init announces a loose bomb only on the playing host (0x004B4398).
        if (!active and (flight.bomb_was_active orelse (pilot.hosted != null)))
            messages.add(strings.stringOr(0x2E3, "No-one has the bomb"), flight.drawn.clock.frame_start);
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
    if (flight.drawn.vampire_roles) |roles| {
        if (!flight.vampires_started and roles.count() == 0)
            game.deathmatch.vampires.announceEmpty(messages, strings, flight.drawn.clock.frame_start);
        flight.vampires_started = true;
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
    if (flight.landing_camera) |landing| return landing;
    if (flight.director) |director| return .{ .position = director.position, .orientation = wire.unpackFacing(director.angles) };
    const left = flight.respawns.left[drawn.objects.player];
    if (left != 0) return game.deathmatch.respawn.camera(slot.drawn, left);
    if (flight.death_view) |death| {
        if (death.watching_from) |at| return .{ .position = at, .orientation = math.lookAt(slot.drawn.position - at) };
        const since: f32 = @floatFromInt(drawn.clock.frame_start -| death.started);
        return game.camera.pullBack(slot.drawn.position, slot.drawn.orientation, since);
    }
    if (flight.eject_view) |eject| {
        const since: f32 = @floatFromInt(drawn.clock.frame_start -| eject.started);
        return game.camera.ejected(eject.offset, slot.drawn.position, since);
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
