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

client: ?session.Client = null,
flight: ?*FlightFrame = null,
stick: [2]i16 = @splat(0),

pub fn start(pilot: *Graphical, io: std.Io, target: []const u8, screen: *game.interface.Connection) void {
    if (pilot.client != null) return;
    pilot.client = .{ .expected_host = null };
    session.connect(&pilot.client.?, io, target) catch |err| {
        pilot.client = null;
        screen.message = switch (err) {
            error.ConnectFailed, error.InvalidTransportIdentity => "Could not open the connection",
            else => "Enter a valid IP address or invite",
        };
        return;
    };
    screen.busy = true;
    screen.message = "Connecting...";
}

pub fn stop(pilot: *Graphical, presentation: ?*Presentation) void {
    if (pilot.client) |*client| session.disconnect(client);
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
        pilot.stop(presentation);
        front.connection.busy = false;
        return;
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
            front.connection.message = switch (err) {
                error.IncompatibleProtocol => "Incompatible multiplayer protocol",
                error.UnverifiedServer => "Server identity does not match the invite",
                error.SessionTimedOut => "Connection timed out",
                else => "Lost connection to server",
            };
            pilot.stop(presentation);
            front.connection.busy = false;
            return;
        };
        switch (event) {
            .idle => return,
            .snapshot => {},
            .admitted => front.connection.message = "Waiting for another pilot",
            .finished => front.connection.message = "Round finished",
            .closed => {
                pilot.stop(presentation);
                front.connection.busy = false;
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
