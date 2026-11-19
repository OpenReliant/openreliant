//! A pilot on the connection screen, then in the dedicated host's arena.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const math = engine.surrender.math;
const Presentation = @import("scripting").Presentation;
const session = @import("session.zig");
const wire = @import("wire.zig");
const flight_input = @import("flight_input.zig");
const FlightFrame = @import("flight_frame.zig");
const Graphical = @This();
const Connection = game.interface.Connection;

// net_handle_system_message (0x004B6A80) posts 0x3B7 on session loss in flight.
const host_left: Connection.Label = .{ .english = "The host has left the game", .installed = 0x3B7 };
// pause_session_lost (0x0048E370) uses 0x5F1 for a failed connection.
const connection_lost: Connection.Label = .{ .english = "The connection to the host was lost", .installed = 0x5F1 };
const could_not_connect: Connection.Label = .{ .english = "Could not open the connection", .installed = 0x569 };
const lobby_scenario: Connection.Label = .{ .english = "Nuclear Threat", .installed = 0x2B0 };
const lobby_ship: Connection.Label = .{ .english = "Predator", .installed = 0x1F7 };

client: ?session.Client = null,
hosted: ?*session.LocalGame = null,
roster: wire.Lobby = @splat(null),
flight: ?*FlightFrame = null,
stick: [2]i16 = @splat(0),

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
    screen.selected = 0;
    screen.first = 0;
    pilot.roster[0] = call_sign;
    screen.lobby = .{
        .role = .{ .host = .{ .port = session.default_port } },
        .roster = &pilot.roster,
        .local_slot = 0,
        .scenario = lobby_scenario,
        .ship = lobby_ship,
    };
}

pub fn launch(pilot: *Graphical) void {
    if (pilot.hosted) |hosted| hosted.host.launch();
}

pub fn returnToBrowser(pilot: *Graphical, screen: *Connection, presentation: ?*Presentation, message: Connection.Label) void {
    screen.lobby = null;
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

pub fn update(pilot: *Graphical, io: std.Io, front: *engine.genilib.interf.Interface, devices: *engine.input.Devices, presentation: ?*Presentation, reads_controls: bool) void {
    const client = if (pilot.client) |*active| active else return;
    if (front.screen != .connection) {
        pilot.returnToBrowser(&front.connection, presentation, .{});
        return;
    }
    if (pilot.hosted) |hosted| {
        _ = hosted.host.pump() catch |err| {
            std.log.warn("LAN game ended: {s}", .{@errorName(err)});
            pilot.returnToBrowser(&front.connection, presentation, .{ .english = "The LAN game stopped" });
            return;
        };
        if (front.connection.lobby) |*lobby| lobby.role.host.can_launch = hosted.host.canLaunch();
    }
    if (pilot.flight) |flight| {
        if (reads_controls) {
            const player = &flight.drawn.player;
            player.balancing_shields = devices.active(.shield_balancing, false);
            player.power_held = devices.active(.powerball_window, false);
            client.setFlight(engine.input.sampleFlight(player, devices, &pilot.stick, player.viewing.view));
        } else {
            client.setFlight(flight_input.release(client.flight_command));
        }
    }
    // Catch up after a slow render without letting a busy connection hold the frame.
    for (0..8) |_| {
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
            .snapshot => front.connection.lobby = null,
            .lobby => |roster| {
                pilot.roster = roster;
                if (front.connection.lobby == null) front.connection.lobby = .{
                    .role = .guest,
                    .roster = &pilot.roster,
                    .local_slot = client.joined.?.slot,
                    .scenario = lobby_scenario,
                    .ship = lobby_ship,
                };
            },
            .admitted => if (pilot.hosted == null) {
                front.connection.message = .{ .english = "Waiting for another pilot" };
            },
            .finished => front.connection.message = .{ .english = "Round finished" },
            .closed => {
                pilot.returnToBrowser(&front.connection, presentation, front.connection.message);
                return;
            },
        }
    }
}

pub fn frame(pilot: *Graphical, gpa: std.mem.Allocator, local: *game.create.Objects, tables: *const game.create.Stats, types: game.create.Types, presentation: ?*Presentation) !?*game.main.Drawn {
    if (!pilot.flying()) return null;
    const client = &pilot.client.?;
    if (pilot.flight) |flight| {
        try flight.apply(&client.latest.?, client.joined.?, local, types);
        return &flight.drawn;
    }
    const flight = try FlightFrame.create(gpa, local, tables);
    errdefer flight.destroy();
    try flight.apply(&client.latest.?, client.joined.?, local, types);
    if (presentation) |shown| {
        errdefer shown.endGame();
        try shown.startGame(null, flight.drawn.objects, false);
    }
    pilot.flight = flight;
    return &flight.drawn;
}

pub fn chase(drawn: *const game.main.Drawn) game.camera.Place {
    const slot = &drawn.objects.slots[drawn.objects.player];
    const offset = game.camera.Chase.offset(slot.object.type);
    const throttle = if (slot.object.afterburner) game.camera.Chase.afterburner_throttle else slot.object.throttle;
    return .{
        .position = slot.drawn.position + math.transform(slot.drawn.orientation, .{ 0, offset.height, -offset.distance - game.camera.Chase.throttle_distance * throttle }),
        .orientation = slot.drawn.orientation,
    };
}
