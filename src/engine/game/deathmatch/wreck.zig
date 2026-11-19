//! The host's record of a fighter breaking up at the end of its Explode order.
const Wreck = @This();
const std = @import("std");
const math = @import("../../surrender/math.zig");
const gameobj = @import("../gameobj.zig");
const players = @import("../players.zig");
const Fighter = @import("../dmscenarios.zig").Fighter;
const explode = @import("../explode.zig");
const objects = @import("../objects.zig");
const create = @import("../create.zig");

pilot: players.ControlRef,
fighter: Fighter,
tick: i32,
motion: explode.breakup.FlightSource,

pub const Sink = struct {
    context: *anyopaque,
    send: *const fn (*anyopaque, Wreck) void,
};

/// `explode_ship` (0x00408A60) still has the dying fighter when it calls `explode_blast`.
pub fn emit(world: gameobj.World, index: u16) void {
    const sink = world.arena_wrecks orelse return;
    const all = world.objects;
    const pilot = all.playerBinding(index) orelse return;
    const slot = &all.slots[index];
    const fighter = std.enums.fromInt(Fighter, slot.object.type.untwinned().number()) orelse return;
    sink.send(sink.context, .{
        .pilot = pilot,
        .fighter = fighter,
        .tick = world.clock.frame_start,
        .motion = .{ .place = slot.drawn, .velocity = slot.object.velocity.vector() },
    });
}

test "a fighter's twin type still emits the chosen fighter's breakup" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const index = try mission.add(.of(.shroud), .{ 100, 200, 300 });
    const all = mission.objects;
    all.players = index + 1;
    const pilot = all.joinParticipant(index).?;
    const bound = all.bindParticipant(pilot, .of(all, index)).?;
    all.slots[index].object.type = .of(.t_shroud);
    all.slots[index].object.flags.exploding = true;
    var captured: ?Wreck = null;
    const Capture = struct {
        fn send(context: *anyopaque, wreck: Wreck) void {
            const received: *?Wreck = @ptrCast(@alignCast(context));
            received.* = wreck;
        }
    };
    var world = mission.world();
    world.arena_wrecks = .{ .context = &captured, .send = Capture.send };
    emit(world, index);
    try std.testing.expectEqual(.shroud, captured.?.fighter);
    try std.testing.expectEqualDeep(bound, captured.?.pilot);
}

/// Builds fresh model frames at the host's final pose. The pieces own their cut meshes and
/// outlive both this model and any replacement ship in the pilot's slot.
pub fn present(wreck: Wreck, world: gameobj.World, types: create.Types) !void {
    const held = types.load(types.context, @intCast(wreck.fighter.kind().number())) orelse return;
    const gpa = world.objects.gpa;
    var model: objects.Model = try .create(gpa, held.model, held.loaded, held.effects);
    defer model.deinit(gpa);
    model.place(wreck.motion.place.position, wreck.motion.place.orientation);
    explode.shipBlast(world, .{
        .motion = wreck.motion,
        .radius = model.radius,
        .owner = .{
            .object = wreck.pilot.ship,
            .participant_generation = wreck.pilot.participant.generation,
            .side = .neutral,
            .type = wreck.fighter.kind(),
            .player = true,
        },
        .model = &model,
    });
}
