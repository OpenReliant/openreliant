//! The cockpit a mission's start (`0x004934F0`) makes for the player's ship: its frame model,
//! read from the game's archive and made into an object of its own (`Cockpit`, `create`), which
//! hangs from the camera's frame (`place`) and moves with the ship's turns (`Cockpit.Shown.inputFor`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const shp = @import("../../../formats/shp.zig");
const math = @import("../../surrender/math.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const ai = @import("../ai.zig");
const bigfile = @import("../bigfile.zig");
const camera = @import("../camera.zig");
const Slot = @import("../create.zig").Slot;
const gameobj = @import("../gameobj.zig");
const main = @import("../main.zig");
const objects = @import("../objects.zig");
const srofiles = @import("../srofiles.zig");

const log = std.log.scoped(.cockpit);

/// The cockpit loaded for the player's ship, in an arena of its own, so that another ship's can
/// take its place.
pub const Cockpit = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    /// Null for a ship the player can't fly, or one whose cockpit the game lacks.
    shown: ?Shown = null,

    pub const Shown = struct {
        /// The frame model as read, whose eye and hands the camera moves the cockpit by.
        source: *const shp.Model,
        model: objects.Model,

        /// What `camera_frame` reads to move the cockpit (`input`) for the player's ship in
        /// `slot`, seen in `view`: the ship's rates of turn, each over its flight model's full
        /// rate, and its speed over its cruise speed (`ai.cruiseSpeed`). A ship without flight
        /// stats leaves the cockpit still, as none the player flies is.
        pub fn inputFor(shown: *const Shown, slot: *const Slot, view: camera.View) ?camera.Cockpit.Input {
            const flight = slot.flight orelse return null;
            const live = &slot.object;
            const rates: [3]f32 = .{
                live.pitch_rate / flight.pitch_rate,
                live.yaw_rate / flight.yaw_rate,
                live.roll_rate / flight.roll_rate,
            };
            return input(&shown.model, shown.source, rates, live.speed / ai.cruiseSpeed(live, flight, view));
        }
    };

    /// Loads the cockpit of `ship_type`, a ship the player can fly (`main.playerShip`), in place
    /// of the one before, as each mission's start makes it afresh, built as `models` says. A
    /// cockpit the game lacks or can't read is left out.
    pub fn load(cockpit: *Cockpit, resources: *const bigfile.Hog, textures: *srtexture.Table, ship_type: gameobj.Type, models: srofiles.Settings) Allocator.Error!void {
        cockpit.shown = null;
        _ = cockpit.arena.reset(.free_all);
        const player_ship = main.playerShip(ship_type) orelse return;
        const gpa = cockpit.arena.allocator();
        const file = srofiles.readModel(gpa, resources, textures, player_ship.cockpit, models) catch |err| switch (err) {
            error.OutOfMemory => |out| return out,
            else => {
                log.warn("the cockpit {s} is left out: {s}", .{ player_ship.cockpit, @errorName(err) });
                return;
            },
        };
        cockpit.shown = .{ .source = file.model, .model = try create(gpa, file.model, file.loaded) };
    }

    pub fn deinit(cockpit: *Cockpit) void {
        cockpit.arena.deinit();
    }
};

/// The cockpit model's two parts `mission_frame` draws: the cockpit's frame and the pilot's hands.
/// A model with more has the rest left out; the Phoenix's has a third, its base.
pub const frame = 0;
pub const hands = 1;

/// How far the cockpit's every level of detail reaches: the mission's start pushes them all out
/// to this (`0x00493BFA`), so the finest is always the one drawn.
pub const detail: f32 = 1048576;

/// The lights' masks that reach the cockpit's parts, as a mask of those that do not (`+0xDC`).
pub const light_mask: u32 = 0x12;

/// The cockpit as the mission's start (`0x004934F0`) makes it: an object of its own
/// (`0x005883F4`) with a part for each of the cockpit frame model's, each drawn always
/// (`always_drawn`), reached only by the lights `light_mask` lets through, and with every
/// level pushed out to `detail`; its root then hangs from the camera's frame. Its parts
/// hang as an object's do, its origin at their centre of mass (`object_link_parts`). The levels
/// are made in `gpa`.
pub fn create(gpa: Allocator, model: *const shp.Model, loaded: *const srofiles.Loaded) Allocator.Error!objects.Model {
    var cockpit: objects.Model = try .create(gpa, model, loaded, .{});
    for (cockpit.parts) |*part| try fitPart(gpa, part);
    gameobj.linkParts(&cockpit, model);
    return cockpit;
}

/// What the start does to each of the cockpit's parts.
fn fitPart(gpa: Allocator, part: *objects.Model.Part) Allocator.Error!void {
    part.object.flags.always_drawn = true;
    part.object.light_mask = light_mask;
    const levels = try gpa.dupe(srapiext.Level, part.object.levels);
    for (levels) |*level| level.until = detail;
    part.object.levels = levels;
}

/// What `camera_frame` reads of the cockpit's model to move it, for a ship turning at `rates`,
/// each over its full rate, and flying at `speed`, over its cruise speed.
pub fn input(cockpit: *const objects.Model, model: *const shp.Model, rates: [3]f32, speed: f32) ?camera.Cockpit.Input {
    if (cockpit.parts.len <= hands) return null;
    return .{
        .rates = rates,
        .speed = speed,
        .eye = gameobj.vector(model.header.eye),
        .hands_origin = cockpit.parts[hands].origin,
        .hands_pivot = gameobj.vector(model.parts[hands].part.mount_point),
    };
}

/// The cockpit lit for a pilot about to eject (`order_eject_player_init`): each of its parts coloured
/// pure red (`0x00416383`) and reached by the lights `emergency_light_mask` lets through
/// (`0x004163E1`), the fill lights as well as the ambient ones but the first key light no more, a
/// red glow that lasts until the mission ends.
pub fn lightEmergency(cockpit: *objects.Model) void {
    for (cockpit.parts) |*part| {
        part.object.colour[0..3].* = emergency_red;
        part.object.light_mask = emergency_light_mask;
    }
}

const emergency_red = [3]f32{ 1, 0, 0 };
const emergency_light_mask: u32 = 1;

/// Places the cockpit's parts in the world for the camera at `at`: its root hangs from the
/// camera's frame where `placed` puts it, each part stands from the root as it does in the model,
/// and the hands where the camera turned them.
pub fn place(cockpit: *objects.Model, at: camera.Place, placed: camera.Cockpit.Placed) void {
    const root = placed.root.within(at);
    cockpit.place(root.position, root.orientation);
    if (cockpit.parts.len <= hands) return;
    const held = placed.hands.within(root);
    const object = &cockpit.parts[hands].object;
    object.position = held.position;
    object.orientation = held.orientation;
}

test "each part is drawn always, from its finest level" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    const levels = [_]srapiext.Level{ .{ .mesh = &mesh, .until = 1000 }, .{ .mesh = &mesh, .until = 5000 } };
    var part: objects.Model.Part = .{
        .hidden = false,
        .parent = null,
        .origin = @splat(0),
        .object = .{ .flags = .{}, .position = @splat(0), .radius = 1, .levels = &levels },
    };
    try fitPart(gpa, &part);
    defer gpa.free(part.object.levels);
    try std.testing.expect(part.object.flags.always_drawn);
    try std.testing.expectEqual(light_mask, part.object.light_mask);
    for (part.object.levels) |level| try std.testing.expectEqual(detail, level.until);
    // The model's own levels are left as they were.
    try std.testing.expectEqual(1000, levels[0].until);
}

test input {
    var data: [2]shp.PartData = @splat(objects.testing.part());
    data[hands].part.mount_point = .{ .x = 0, .y = 5, .z = 20 };
    var header = std.mem.zeroes(shp.Header);
    header.eye = .{ .x = 0, .y = -10, .z = 30 };
    const source: shp.Model = .{ .header = header, .parts = &data, .trailing_bytes = 0 };
    var parts = [_]objects.Model.Part{
        .{ .hidden = false, .parent = null, .origin = .{ 0, 0, 100 }, .object = .{ .flags = .{}, .position = @splat(0), .radius = 1, .levels = &.{} } },
        .{ .hidden = false, .parent = null, .origin = .{ 1, 2, 3 }, .object = .{ .flags = .{}, .position = @splat(0), .radius = 1, .levels = &.{} } },
    };
    var model: objects.Model = .{ .parts = &parts, .order = &.{ 0, 1 }, .lights = &.{}, .glows = &.{}, .mounts = &.{} };
    // The frame model's eye, and the hands where their part stands and turning about its mount
    // point, with the ship's rates and speed as they are.
    const moved = input(&model, &source, .{ 0.5, -0.25, 1 }, 0.75).?;
    try std.testing.expectEqual(math.Vector{ 0, -10, 30 }, moved.eye);
    try std.testing.expectEqual(math.Vector{ 1, 2, 3 }, moved.hands_origin);
    try std.testing.expectEqual(math.Vector{ 0, 5, 20 }, moved.hands_pivot);
    try std.testing.expectEqual([3]f32{ 0.5, -0.25, 1 }, moved.rates);
    try std.testing.expectEqual(0.75, moved.speed);
    // A model without hands has nothing to move.
    model.parts = parts[0..1];
    try std.testing.expectEqual(null, input(&model, &source, @splat(0), 0));
}

test "Shown.inputFor" {
    var data: [2]shp.PartData = @splat(objects.testing.part());
    const source: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &data, .trailing_bytes = 0 };
    var parts = [_]objects.Model.Part{
        .{ .hidden = false, .parent = null, .origin = @splat(0), .object = .{ .flags = .{}, .position = @splat(0), .radius = 1, .levels = &.{} } },
        .{ .hidden = false, .parent = null, .origin = @splat(0), .object = .{ .flags = .{}, .position = @splat(0), .radius = 1, .levels = &.{} } },
    };
    const shown: Cockpit.Shown = .{ .source = &source, .model = .{ .parts = &parts, .order = &.{ 0, 1 }, .lights = &.{}, .glows = &.{}, .mounts = &.{} } };
    var slot: Slot = .{ .object = gameobj.testing.object(), .flight = &gameobj.testing.flight };
    slot.object.pitch_rate = 1;
    slot.object.yaw_rate = -1.5;
    slot.object.roll_rate = 0.75;
    slot.object.speed = 240;
    // Each rate over the flight model's, and the speed over the cruise speed, 320.
    const moved = shown.inputFor(&slot, .chase).?;
    try std.testing.expectEqual([3]f32{ 0.5, -1, 0.25 }, moved.rates);
    try std.testing.expectEqual(0.75, moved.speed);
    // Without flight stats, nothing moves it.
    slot.flight = null;
    try std.testing.expectEqual(null, shown.inputFor(&slot, .chase));
}

test place {
    var parts = [_]objects.Model.Part{
        .{ .hidden = false, .parent = null, .origin = .{ 0, 0, 100 }, .object = .{ .flags = .{}, .position = @splat(0), .radius = 1, .levels = &.{} } },
        .{ .hidden = false, .parent = null, .origin = .{ 0, 0, 50 }, .object = .{ .flags = .{}, .position = @splat(0), .radius = 1, .levels = &.{} } },
    };
    var model: objects.Model = .{ .parts = &parts, .order = &.{ 0, 1 }, .lights = &.{}, .glows = &.{}, .mounts = &.{} };
    // The camera turned a quarter about Y: the root, set back from the eye, turns with it.
    const at: camera.Place = .{ .position = .{ 1000, 0, 0 }, .orientation = math.rotation(.y, std.math.pi / 2.0) };
    const placed: camera.Cockpit.Placed = .{
        .root = .{ .position = .{ 0, 0, -300 }, .orientation = math.identity },
        .hands = .{ .position = .{ 0, 10, 0 }, .orientation = math.identity },
    };
    place(&model, at, placed);
    const root = at.position + math.transform(at.orientation, .{ 0, 0, -300 });
    try math.testing.expectVectorWithin(root + math.transform(at.orientation, .{ 0, 0, 100 }), parts[frame].object.position, 1e-3);
    // The hands stand where the camera put them, not at their origin.
    try math.testing.expectVectorWithin(root + math.transform(at.orientation, .{ 0, 10, 0 }), parts[hands].object.position, 1e-3);
}

test lightEmergency {
    var parts = [_]objects.Model.Part{
        .{ .hidden = false, .parent = null, .origin = @splat(0), .object = .{ .flags = .{}, .position = @splat(0), .radius = 1, .levels = &.{}, .light_mask = light_mask } },
        .{ .hidden = false, .parent = null, .origin = @splat(0), .object = .{ .flags = .{}, .position = @splat(0), .radius = 1, .levels = &.{}, .light_mask = light_mask } },
    };
    var model: objects.Model = .{ .parts = &parts, .order = &.{ 0, 1 }, .lights = &.{}, .glows = &.{}, .mounts = &.{} };
    // Every part glows red, and takes the lights but the first key light.
    lightEmergency(&model);
    for (parts) |part| {
        try std.testing.expectEqual(emergency_red, part.object.colour[0..3].*);
        try std.testing.expectEqual(emergency_light_mask, part.object.light_mask);
    }
}
