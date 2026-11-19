//! A pilot on the connection screen, then in the dedicated host's arena.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const math = engine.surrender.math;
const lib = engine.surrender.surrenderlib;
const session = @import("session.zig");
const wire = @import("wire.zig");
const Graphical = @This();

client: ?session.Client = null,
models: [wire.slots]?game.objects.Model = @splat(null),

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

pub fn stop(pilot: *Graphical, gpa: std.mem.Allocator) void {
    if (pilot.client) |*client| session.disconnect(client);
    for (&pilot.models) |*model| if (model.*) |loaded| loaded.deinit(gpa);
    pilot.* = .{};
}

pub fn flying(pilot: *const Graphical) bool {
    return if (pilot.client) |*client| client.latest != null and !client.leaving else false;
}

pub fn update(pilot: *Graphical, gpa: std.mem.Allocator, io: std.Io, front: *engine.genilib.interf.Interface, devices: *engine.input.Devices) void {
    const client = if (pilot.client) |*active| active else return;
    if (front.screen != .connection) {
        pilot.stop(gpa);
        front.connection.busy = false;
        return;
    }
    const steering: wire.Steering = if (devices.active(.rotate_clockwise, false)) .left else if (devices.active(.rotate_anti_clockwise, false)) .right else .straight;
    // Catch up after a slow render without letting a busy connection hold the frame.
    for (0..8) |_| {
        const event = client.poll(io, steering) catch |err| {
            front.connection.message = switch (err) {
                error.IncompatibleProtocol => "Incompatible multiplayer protocol",
                error.UnverifiedServer => "Server identity does not match the invite",
                error.SessionTimedOut => "Connection timed out",
                else => "Lost connection to server",
            };
            pilot.stop(gpa);
            front.connection.busy = false;
            return;
        };
        switch (event) {
            .idle => return,
            .snapshot => {},
            .admitted => front.connection.message = "Waiting for another pilot",
            .finished => front.connection.message = "Round finished",
            .closed => {
                pilot.stop(gpa);
                front.connection.busy = false;
                return;
            },
        }
    }
}

pub fn draw(pilot: *Graphical, gpa: std.mem.Allocator, scene_allocator: std.mem.Allocator, types: game.create.Types, scene: *lib.srcore.Scene, context: *lib.srapi.Context, size: [2]u32, fov: f32) !void {
    const client = &pilot.client.?;
    const view = &client.latest.?;
    const local = view.ships[client.joined.?.slot].?;
    const facing = local.orientationMatrix();
    const offset = game.camera.Chase.offset(wire.arena_ship);
    context.camera = .{ .position = @as(math.Vector, local.position) + math.transform(facing, .{ 0, offset.height, -offset.distance - game.camera.Chase.throttle_distance }), .orientation = facing };
    context.projection = (game.camera.Camera{}).projection(.chase, size[0], size[1], fov);
    for (view.ships, &pilot.models) |entry, *saved| {
        const ship = entry orelse continue;
        if (saved.* == null) {
            const data = types.load(types.context, @intCast(wire.arena_ship.number())) orelse continue;
            saved.* = try game.objects.Model.create(gpa, data.model, data.loaded, data.effects);
        }
        const model = &saved.*.?;
        model.place(ship.position, ship.orientationMatrix());
        try model.draw(scene_allocator, scene, .world, .{ .camera = context.camera.position });
    }
}
