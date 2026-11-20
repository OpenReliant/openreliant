//! Readiness for the shared co-op debrief (multiplayer_debriefing, 0x004296A0).
const std = @import("std");
const Crew = @This();

pub const size = 4;
pub const Pilots = std.bit_set.IntegerBitSet(size);
pub const Choice = enum(u8) { ready, advance, replay };

present: Pilots = .empty,
eligible: Pilots = .empty,
ready: Pilots = .empty,
lead: u8 = 0,

/// The session owner leads if eligible. Otherwise the first eligible pilot
/// leads. When everyone lost, the lowest remaining seat can offer a replay.
pub fn chooseLead(crew: *Crew, owner: ?u8) void {
    if (crew.eligible.findFirstSet()) |first| {
        crew.lead = if (owner != null and crew.eligible.isSet(owner.?)) owner.? else @intCast(first);
    } else {
        crew.lead = @intCast(crew.present.findFirstSet() orelse 0);
    }
}

pub fn permits(crew: Crew, pilot: u8, choice: Choice) bool {
    if (pilot >= size or !crew.present.isSet(pilot)) return false;
    if (choice == .ready) return pilot != crew.lead and !crew.ready.isSet(pilot);
    if (pilot != crew.lead) return false;
    var waiting = if (choice == .advance) crew.eligible else crew.present;
    if (choice == .advance and waiting.count() == 0) return false;
    waiting.unset(pilot);
    return waiting.subsetOf(crew.ready);
}

test "advance and replay have different readiness requirements" {
    var crew: Crew = .{ .present = .{ .mask = 0b1111 }, .eligible = .{ .mask = 0b1010 }, .ready = .{ .mask = 0b1000 } };
    crew.chooseLead(0);
    try std.testing.expectEqual(1, crew.lead);
    try std.testing.expect(crew.permits(1, .advance));
    try std.testing.expect(!crew.permits(1, .replay));
    try std.testing.expect(!crew.permits(3, .advance));
    crew.ready = .{ .mask = 0b1101 };
    try std.testing.expect(crew.permits(1, .replay));
    crew.eligible = .empty;
    crew.chooseLead(0);
    try std.testing.expectEqual(0, crew.lead);
    try std.testing.expect(!crew.permits(0, .advance));
    try std.testing.expect(!crew.permits(0, .replay));
    crew.ready.set(1);
    try std.testing.expect(crew.permits(0, .replay));
}
