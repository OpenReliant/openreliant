//! The transport-only workload uses two counters in place of the engine.
const Host = @This();

positions: [2][3]f32 = @splat(@splat(0)),

pub fn init(host: *Host) !void {
    host.* = .{};
}

pub fn deinit(_: *Host) void {}

pub fn step(host: *Host, controls: [2]i8) ![2][3]f32 {
    for (&host.positions, controls) |*position, control| position[0] += @floatFromInt(control);
    return host.positions;
}

pub fn check(tick: u16, positions: [2][3]f32) !void {
    const distance: f32 = @floatFromInt(tick);
    if (positions[0][0] != distance or positions[1][0] != -distance) return error.WrongPositions;
}
