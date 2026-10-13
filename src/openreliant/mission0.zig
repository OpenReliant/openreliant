//! Mission 0, OpenReliant's own: the sandbox, which `openreliant` plays where no other mission is
//! chosen. Its mission source, [`mission0.mission.luau`](mission0.mission.luau), describes it, and
//! the build compiles that into a standard mission file, `mission0.dte`, which `openreliant`
//! carries and the original plays too ([Mission source](../../docs/formats/mission-source.md)).
//! The tests here check the mission the build made.

const std = @import("std");

const openreliant = @import("openreliant");
const dte = openreliant.dte;
const game = openreliant.engine.game;
const Type = game.gameobj.Type;
const Order = game.ai.orders.Order;

/// The mission's number, which `openreliant` plays by default.
pub const number = 0;

/// The mission file the build compiled from the source.
const file = @embedFile("mission0.dte");

/// The place among the mission's ships of the one the source names `name`.
fn shipNamed(name: []const u8) !u16 {
    const mission: dte.Mission = try .parse(file);
    for (try mission.ships(), 0..) |ship, index| {
        if (std.mem.eql(u8, mission.name(ship.name), name)) return @intCast(index);
    }
    return error.TestUnexpectedResult;
}

/// The flight group the source names `name`.
fn groupNamed(mission: *const game.mission.Mission, name: []const u8) !dte.FlightGroup {
    for (try mission.flightGroups()) |group| {
        if (std.mem.eql(u8, mission.file.name(group.name), name)) return group;
    }
    return error.TestUnexpectedResult;
}

test "mission 0 is a standard mission, which binds" {
    const gpa = std.testing.allocator;
    var mission: game.mission.Mission = try .bind(gpa, try gpa.dupe(u8, file));
    defer mission.deinit();

    // A standard mission, the template's, which OpenReliant names.
    const name = "Sandbox";
    try std.testing.expectEqual(dte.write.template.size + @sizeOf(dte.OpenReliantName) + name.len + 1, file.len);
    try std.testing.expectEqualStrings(name, mission.file.openReliantName().?);
    // The player's own record first, and the wing in the player's flight group, listed in the
    // player's wing.
    const records = try mission.ships();
    try std.testing.expectEqualStrings("Player", mission.file.name((try mission.file.player()).?.name));
    const alpha = try groupNamed(&mission, "(FG)Alpha");
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2, 3 }, mission.groupShips(alpha));
    try std.testing.expectEqual(.player, alpha.wing);
    // The wing launches through the Reliant's first four tubes; the rest launch from nothing.
    for (records[0..4], 0..) |record, gate| {
        try std.testing.expectEqual(gate, record.launchGate().?);
        try std.testing.expectEqual(Type.of(.reliant).number(), record.launch_from);
    }
    try std.testing.expectEqual(null, records[try shipNamed("The Reliant")].launchGate());
    // One part, run at the start, which disassembles whole.
    const parts = try mission.file.parts();
    try std.testing.expectEqual(1, parts.len);
    try std.testing.expect(parts[0].flags.start);
    const disassembly = (try dte.disassemble(gpa, try mission.file.script(), parts[0].start())).?;
    defer gpa.free(disassembly.instructions);
    try std.testing.expect(!disassembly.incomplete);
    // The command flags as the template's missions have them, and a clear flag for each byte of the
    // script.
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&dte.write.template.command_flags), std.mem.sliceAsBytes(try mission.file.records(u16, .command_flags)));
    const script_flags = try mission.file.records(u8, .script_flags);
    try std.testing.expectEqual((try mission.file.script()).len, script_flags.len);
    for (script_flags) |flag| try std.testing.expectEqual(0, flag);
    // The object table marks the player's ship as the original's tools do.
    const objects = try mission.file.objects();
    try std.testing.expect(objects[0].tool_flags.player);
    try std.testing.expect(!objects[1].tool_flags.player);
}

test "the wing waits in the Reliant's tubes as the mission starts, its launch started" {
    const gpa = std.testing.allocator;
    var world: game.gameobj.testing.Mission = undefined;
    try world.init(gpa);
    defer world.deinit();
    var orders = world.orders();
    orders.world.spawn = world.spawn(game.create.testing.no_models);
    const loaded = try game.mission.Loaded.create(gpa, try gpa.dupe(u8, file), &world.random);
    defer loaded.destroy();
    orders.world.mission = &loaded.bound;
    try loaded.start(orders);
    const reliant = try shipNamed("The Reliant");
    for (world.objects.slots[0..4]) |*slot| {
        const entry = slot.current().?;
        try std.testing.expectEqual(Order.launch, entry.order);
        try std.testing.expectEqual(reliant, entry.target.slot().?);
        try std.testing.expect(entry.data.launch.go);
    }
    // The capital ships wait with the script for the wing to be out, their guns held.
    const badanov = try shipNamed("The Badanov");
    try std.testing.expectEqual(Order.do_nothing, world.objects.slots[reliant].current().?.order);
    for ([_]u16{ reliant, badanov }) |ship| try std.testing.expect(world.objects.slots[ship].object.flags.guns_disabled);
    // Once the wing is out, they fly on at a crawl, free to fire.
    for (0..4) |ship| _ = game.aigeneric.pop(orders, @intCast(ship));
    loaded.process(orders);
    for ([_]u16{ reliant, badanov }) |ship| {
        try std.testing.expectEqual(Order.fly, world.objects.slots[ship].current().?.order);
        try std.testing.expect(!world.objects.slots[ship].object.flags.guns_disabled);
    }
}

test "the Reliant flies at a crawl" {
    // The source flies the capital ships at 10, and the Reliant's type cruises at 100
    // (`shipstats.bin`, type 0x0C). Fly holds the throttle at the speed in its data over that, and
    // the flight model settles the nose speed there, so the Reliant makes its 10 a step.
    const crawl = 10;
    const cruise = 100;
    var flight = game.gameobj.testing.flight;
    flight.max_speed = cruise;
    var object = game.gameobj.testing.object();
    object.throttle = @as(f32, crawl) / cruise;
    for (0..200) |_| game.motion.Motion.forward.run(&object, .{ .own = &flight }, .chase, .{});
    const velocity = object.velocity.vector();
    try std.testing.expectApproxEqAbs(crawl, @sqrt(@reduce(.Add, velocity * velocity)), 0.01);
}

test "the rocks lie beyond the action's sphere, apart" {
    const gpa = std.testing.allocator;
    var mission: game.mission.Mission = try .bind(gpa, try gpa.dupe(u8, file));
    defer mission.deinit();
    const records = try mission.ships();
    const rocks = mission.groupShips(try groupNamed(&mission, "(FG)Rocks"));
    try std.testing.expectEqual(12, rocks.len);
    // The rows are 26000 apart, and a rock is moved up to 7000 along and across from its place, so
    // no two stand closer than 12000, across and along.
    const least_apart = 12000;
    const sphere = game.aigeneric.ActionSphere.default.radius;
    var seen = std.bit_set.Static(7).empty;
    for (rocks, 0..) |rock, n| {
        const at: @Vector(3, f32) = records[rock].position;
        try std.testing.expect(@sqrt(@reduce(.Add, at * at)) > sphere);
        for (rocks[n + 1 ..]) |other| {
            const off = at - @as(@Vector(3, f32), records[other].position);
            try std.testing.expect(@max(@abs(off[0]), @abs(off[2])) >= least_apart);
        }
        seen.set(records[rock].kind - Type.asteroid(0).number());
    }
    // Every one of the seven asteroids is among them.
    try std.testing.expectEqual(7, seen.count());
}
