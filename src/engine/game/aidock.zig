//! `C:\lancer\game\aidock.cpp`: Dock, order 109, by which a ship docks at a port of another: a
//! freighter at a station's port, a fighter in a Nanny to take on missiles, a limpet car on a
//! ship. Its init picks one of five styles by what docks where; each style has its own init,
//! update and exit (`dock_styles`, `0x004E1618`). OpenReliant has the station's, which mission 1's
//! convoy docks at Fort Sherman by. `docs/engine/orders.md` describes it.
//!
//! Not ported: the Nanny's, the limpet car's, the limpet car's at the Czar and the limpet pod's
//! styles ([#320](https://github.com/vdmkenny/openreliant/issues/320)), which leave the ship
//! doing nothing.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.orders);

const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const Context = aigeneric.Context;
const create = @import("create.zig");
const events = @import("mission/events.zig");
const gameobj = @import("gameobj.zig");
const motion = @import("motion.zig");
const objects = @import("objects.zig");
const sound3d = @import("sound3d.zig");

/// How a ship docks, by what it is and what it docks at (`order_dock_init`).
pub const Style = enum(u8) {
    /// Any other ship at any other port: a freighter at a station.
    station = 0,
    /// A ship at a Nanny, which takes it aboard to rearm.
    nanny = 1,
    /// A limpet car at a ship.
    limpet_car = 2,
    /// A limpet car at the Czar, docked.
    limpet_car_czar = 3,
    /// A limpet pod.
    limpet_pod = 4,
    _,

    /// The style a ship of type `own` docks in at one of type `at` (`order_dock_init`): a limpet
    /// car's, or at the Czar docked its own; a limpet pod's; at a Nanny, the Nanny's; and
    /// otherwise the station's.
    pub fn of(own: gameobj.Type, at: gameobj.Type) Style {
        return switch (own) {
            .limpet_car => if (at == .czar_docked) .limpet_car_czar else .limpet_car,
            .limpet_pod => .limpet_pod,
            else => if (at == .nanny) .nanny else .station,
        };
    }
};

/// The order's data (`aigeneric.Entry.data`).
pub const Data = extern struct {
    style: Style,
    _unknown_01: u8,
    /// The ship and the port the search for a free port found (`PortSearch`), before the order
    /// takes them for its target.
    found_ship: i16 align(1),
    found_port: u8,

    comptime {
        assert(@offsetOf(Data, "found_ship") == 0x2);
        assert(@offsetOf(Data, "found_port") == 0x4);
    }
};

/// The station style's state (`GameObject.order_state`).
pub const State = extern struct {
    /// The docking path `motion_follow` follows as the ship slides in, at half its top speed.
    follower: motion.Follower,
    step: Step,
    /// The mission's tick the slide in ends at (`mission_ticks`).
    until: i32,
    /// The part of the ship its docking point is on, by its place among the model's parts, and
    /// where the point stands on it; the game holds the part's node.
    own_part: u32,
    own_point: [3]f32,
    /// The part of the station its port is on, and where the port stands on it and how it is
    /// turned.
    port_part: u32,
    port_point: [3]f32,
    port_turn: [9]f32,
    /// The side of the port's line the ship came at it from, which mirrors the way round.
    from: Side,
    /// Where the ship stood as the slide in began.
    slide_from: [3]f32,

    comptime {
        assert(@offsetOf(State, "step") == 0x08);
        assert(@offsetOf(State, "until") == 0x0C);
        assert(@offsetOf(State, "own_part") == 0x10);
        assert(@offsetOf(State, "own_point") == 0x14);
        assert(@offsetOf(State, "port_part") == 0x20);
        assert(@offsetOf(State, "port_point") == 0x24);
        assert(@offsetOf(State, "port_turn") == 0x30);
        assert(@offsetOf(State, "from") == 0x54);
        assert(@offsetOf(State, "slide_from") == 0x58);
    }
};

/// The station style's steps.
pub const Step = enum(u32) {
    /// Beside the port, `aside` out on the side the ship came from.
    beside = 0,
    /// Beside the port and `aside` behind it too.
    beside_behind = 1,
    /// Twice its turn's width out, and `aside` behind the port.
    turning_in = 2,
    /// On the port's line, `far_behind` behind it.
    far_behind = 3,
    /// On the port's line, `near_behind` behind it.
    near_behind = 4,
    /// It latches on, and starts to slide in.
    latching = 5,
    /// It slides in along the port's line (`way`).
    sliding = 6,
    /// It is in: set in place, and docked.
    docked = 7,
    /// OpenReliant's own: the ship or the port has no docking point, and the order ends.
    no_port = 8,
    _,

    /// The step after it.
    fn next(step: Step) Step {
        return @enumFromInt(@intFromEnum(step) +% 1);
    }
};

/// The side of the port's line a ship comes at it from, as the station style's init notes it.
pub const Side = enum(u32) {
    left = 0,
    right = 1,
    _,

    /// What the steps' points are scaled by: across the port's line for a ship from its right.
    /// The game tests the word against zero, so any other value mirrors as the right does.
    fn mirror(side: Side) Vector {
        return if (side == .left) .{ 1, 1, 1 } else .{ -1, 1, 1 };
    }
};

/// Where the station style steers, in the port's frame: out to its side and behind it
/// (`0x004DC4A0`, `0x004DC494`, and the immediates of `0x004070F0`).
const aside: f32 = 100000;
const far_behind: f32 = 50000;
const near_behind: f32 = 10000;

/// How near its point a step takes the ship before the next: the square of 2000 (`0x004DC490`).
const reach_squared: f32 = 4000000;

/// How far aside the turn in starts, in the ship's cruise speeds over its yaw rate (`0x004DC4A4`).
const turn_widths: f32 = -2;

/// Where a step aims, from where the ship is along the port's line, as the station style's init
/// picks its first: far behind it, and further aside than this share of the way behind
/// (`0x004DC3F8`).
const behind_share: f32 = 0.2;

/// How long the slide in lasts, in ticks (`0x00407313`).
const slide_ticks = 1000;
/// Each tick's share of the slide (`0x004DC49C`).
const slide_share: f32 = 0.001;

comptime {
    assert(slide_share * slide_ticks == 1);
}

/// The share of its top speed a ship slides in at (`0x00407303`).
const slide_limit: f32 = 0.5;

/// How the station style rolls the ship to stand as the port stands: its roll input is the roll
/// between them less this many times its roll rate, turned into the input by the orders' shared
/// gain (`ai.roll_input_per_radian`), within 1 either way.
const roll_damping: f32 = 2;

/// The animation a port plays as a ship docks at it (`0x004E1690`).
const port_track = "deploy";

/// How fast the port's animation plays (`0x00406E15`).
const port_speed: f32 = 4;

/// `order_dock_init` (`0x00406B80`): where the order names no port, or a flight group or a squad
/// rather than a ship, the first free port of the ships it names (`PortSearch`) becomes its
/// target. Then the style, by what the ship is and what it docks at (`Style.of`), and the style's
/// init. **Unverified:** it lies before this file's known code.
pub fn init(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const entry = &all.slots[index].orders[0];
    if (entry.target.kind != .ship or entry.target.isWhole()) {
        entry.data.dock.found_ship = 0;
        entry.data.dock.found_port = 0;
        var search: PortSearch = .{ .all = all, .searcher = index };
        _ = ai.eachShip(ctx.world, entry.target, &search);
        entry.target.index = entry.data.dock.found_ship;
        entry.target.component = entry.data.dock.found_port;
    }
    const target = entry.target.slotIn(all) orelse return;
    entry.data.dock.style = .of(all.slots[index].object.type, all.slots[target].object.type);
    switch (entry.data.dock.style) {
        .station => stationInit(ctx, index),
        // Not ported ([#320](https://github.com/vdmkenny/openreliant/issues/320)).
        .nanny, .limpet_car, .limpet_car_czar, .limpet_pod, _ => {},
    }
}

/// `dock_port_search` (`0x00406A90`), the search `init` runs over each ship its target names
/// (`ai.eachShip`): the first of the ship's ports, counting its docking points part by part, at
/// which no other object's current order is Dock. **Unverified:** it lies before this file's known
/// code.
const PortSearch = struct {
    all: *create.Objects,
    searcher: u16,

    pub fn visit(search: *PortSearch, ship: aigeneric.Target) bool {
        const at = ship.slotIn(search.all) orelse return false;
        const model = if (search.all.slots[at].model) |*held| held else return false;
        var ports: DockPoints = .of(model);
        var port: u8 = 0;
        while (ports.next()) |_| : (port +%= 1) {
            if (taken(search.all, search.searcher, at, port)) continue;
            const entry = &search.all.slots[search.searcher].orders[0];
            entry.data.dock.found_ship = @intCast(at);
            entry.data.dock.found_port = port;
            return true;
        }
        return false;
    }

    /// Whether an object other than `searcher` has Dock on at port `port` of the ship in slot `at`.
    fn taken(all: *const create.Objects, searcher: u16, at: u16, port: u8) bool {
        for (all.slots[0..all.count], 0..) |*slot, index| {
            if (index == searcher) continue;
            const entry = (slot.current() orelse continue).*;
            if (entry.order == .dock and entry.target.index == at and entry.target.component == port) return true;
        }
        return false;
    }
};

/// A model's docking points (`shp.Attachment.Kind.dock_point`), part by part as the root's child
/// list holds them, each part's attachments in order.
pub const DockPoints = objects.Model.RootAttachments(isDockPoint);

fn isDockPoint(attachment: shp.Attachment, _: usize) bool {
    return attachment.kind == .dock_point;
}

/// `order_dock` (`0x00406C30`): the style's update.
pub fn update(ctx: Context, index: u16) void {
    switch (ctx.world.objects.slots[index].orders[0].data.dock.style) {
        .station => stationUpdate(ctx, index),
        // Not ported ([#320](https://github.com/vdmkenny/openreliant/issues/320)).
        .nanny, .limpet_car, .limpet_car_czar, .limpet_pod, _ => {},
    }
}

/// `order_dock_exit` (`0x00406C50`): the style's exit; the station's and the Nanny's
/// (`dock_station_exit`, `0x00407D10`) have the ship pass through nothing more at the first place.
pub fn exit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    switch (slot.orders[0].data.dock.style) {
        .station, .nanny => slot.object.passes_through[0] = .none,
        // Not ported ([#320](https://github.com/vdmkenny/openreliant/issues/320)).
        .limpet_car, .limpet_car_czar, .limpet_pod, _ => {},
    }
}

/// `dock_find_points` (`0x00406C80`): the ship's own docking point, its first, and the port of the
/// station its target names by the component, which starts the port's animation (`port_track`).
/// Whether both were found.
///
/// **Fix:** the game stops with "Docking information not defined on %s" where the ship has no
/// docking point. Its check of the station's port reads the ship's own node again (`0x00406E2A`,
/// `+0x10` where the port's is `+0x20`), so where the station has no such port the game goes on to
/// `dock_berth` with the port's node null, as `order_push` cleared the state, and faults on it. So
/// it does for a component that names none of the station's ports: one past its docking points,
/// or a negative one other than -1, which `init`'s search leaves alone and the game's count down
/// never reaches. OpenReliant logs either, and the order ends, as it does where the station has
/// gone.
fn findPoints(ctx: Context, index: u16) bool {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.dock;
    const entry = slot.orders[0];
    const own_model = if (slot.model) |*held| held else return missing(index);
    const own = DockPoints.nth(own_model, 0) orelse return missing(index);
    state.own_part = @intCast(own.part);
    state.own_point = gameobj.vector(own.attachment.position);
    const at = entry.target.slotIn(all) orelse return missing(index);
    const model = if (all.slots[at].model) |*held| held else return missing(at);
    const port = DockPoints.nth(model, entry.target.part() orelse return missing(at)) orelse return missing(at);
    state.port_part = @intCast(port.part);
    state.port_point = gameobj.vector(port.attachment.position);
    state.port_turn = port.attachment.orientation;
    model.playNamed(port.part, port_track, 0, null, port_speed);
    return true;
}

fn missing(index: u16) bool {
    log.warn("the object in slot {d} has no docking point", .{index});
    return false;
}

/// `dock_berth` (`0x00406E70`): the berth at the port, as the station is drawn, where the ship
/// stands docked: the port's frame in the world, less the ship's own docking point turned into it,
/// so that its docking point is on the port, and it is turned as the port is.
///
/// **Fix:** the game takes the ship's own docking point in its part's own frame alone (the node's
/// `+0x18` and `+0x3C`, `0x00406E97`), which berths a ship whose point is on a part hung from
/// another part off by that part's place; OpenReliant carries it up the parts it hangs from
/// (`objects.Model.frameAt`).
fn berth(world: gameobj.World, index: u16) ?math.Place {
    const all = world.objects;
    const slot = &all.slots[index];
    const state = slot.state.dock;
    const at = slot.orders[0].target.slotIn(all) orelse return null;
    const station = &all.slots[at];
    const model = if (station.model) |*held| held else return null;
    const own_model = if (slot.model) |*held| held else return null;
    if (state.port_part >= model.parts.len or state.own_part >= own_model.parts.len) return null;
    const own = own_model.frameAt(state.own_part, .{});
    const port = model.frameAt(state.port_part, station.drawn);
    const docked: math.Place = .{
        .position = @as(Vector, state.port_point) - math.transform(state.port_turn, own.point(state.own_point)),
        .orientation = state.port_turn,
    };
    return docked.within(port);
}

/// The station style's init (`0x00407010`): it finds the docking points (`findPoints`), and picks
/// its first step by where the ship stands from the berth, in the port's frame: far behind the
/// port, it turns in, or comes straight along the line where it stands near it; nearer, behind it
/// or ahead of it, it goes round beside the port first. It notes which side it came from.
fn stationInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.dock;
    if (!findPoints(ctx, index)) {
        state.step = .no_port;
        return;
    }
    const at = berth(ctx.world, index) orelse return;
    const off = at.inverse(slot.object.nextPosition());
    state.from = if (off[0] > 0) .right else .left;
    const step: Step = if (off[2] < -aside)
        if (@abs(off[0] / off[2]) > behind_share) .turning_in else .far_behind
    else if (off[2] < 0) .beside_behind else .beside;
    state.step = step;
}

/// The station style's update (`0x004070F0`), a step at a time (`Step`). Going round, the ship
/// steers at full throttle for the step's point (`ai.steer`), mirrored to the side it came from,
/// rolling to stand as the port stands, on to the next step within `reach_squared` of it. Latching
/// on, it flies `motion_follow` down the port's line (`way`), at `slide_limit` of its top speed,
/// the station stopped dead where it is. Once it is in, it is set in its berth, stopped, heard
/// docking, and has its Docked; the order ends.
///
/// **Fix:** the game goes on reading the frames of a station that has gone; OpenReliant ends the
/// order.
fn stationUpdate(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.dock;
    const at = berth(world, index) orelse return aigeneric.end(ctx, index);
    const offset: Vector = switch (state.step) {
        .beside => .{ -aside, 0, 0 },
        .beside_behind => .{ -aside, 0, -aside },
        .turning_in => turning: {
            const flight = slot.flight orelse return;
            break :turning .{ ai.cruiseSpeed(object, flight, world.view) * turn_widths / flight.yaw_rate, 0, -aside };
        },
        .far_behind => .{ 0, 0, -far_behind },
        .near_behind => .{ 0, 0, -near_behind },
        .latching => {
            object.flags.attached = true;
            slot.motion = .follow;
            state.follower = .{ .path = .dock, .limit = slide_limit };
            state.step = .sliding;
            state.until = ctx.world.clock.mission_ticks + slide_ticks;
            state.slide_from = object.nextPosition();
            if (slot.orders[0].target.slotIn(all)) |station| all.slots[station].object.velocity = .zero;
            return;
        },
        .sliding => return,
        .docked => {
            ai.stop(object);
            objects.setPlace(object, &slot.drawn, at);
            sound3d.playIn(world, null, null, index, .dock, 1, .not_reserved);
            events.docked(world, index);
            return aigeneric.end(ctx, index);
        },
        .no_port, _ => return aigeneric.end(ctx, index),
    };
    const point = at.point(offset * state.from.mirror());
    _ = ai.steer(world, index, point, ai.full_limit, ai.no_ease, .{});
    object.throttle = ai.full_throttle;
    const left = point - object.nextPosition();
    if (math.lengthSquared(left) < reach_squared) state.step = state.step.next();
    const up = math.transformTransposed(slot.drawn.orientation, math.yAxis(at.orientation));
    const roll = -std.math.atan2(up[0], up[1]);
    object.roll_input = std.math.clamp((roll - roll_damping * object.roll_rate) * ai.roll_input_per_radian, -1, 1);
}

/// `dock_way` (`0x00406F20`), which `motion_follow` calls as the ship slides in: a point on the
/// port's line behind the berth, as far back as the ship stood from it as it latched on, times the
/// square of the share of the slide left, and the port's way up. The share left is counted in
/// `mission_ticks`, as the simulation step runs it. Once the slide is over, the ship's motion is
/// `motion_backward`, and it is in.
///
/// **Fix:** where the station has gone, the game reads its frames on; the point is where the ship
/// stands, until the order ends (`stationUpdate`).
pub fn way(world: gameobj.World, index: u16) motion.Way {
    const slot = &world.objects.slots[index];
    const state = &slot.state.dock;
    const at = berth(world, index) orelse return .{ .point = gameobj.vector(slot.object.root.position) };
    const now = world.clock.mission_ticks;
    const left = @max(@as(f32, @floatFromInt(state.until -% now)) * slide_share, 0);
    const back = math.distance(at.position, state.slide_from) * left * left;
    const point = at.ahead(-back);
    if (state.until < now) {
        slot.motion = .backward;
        state.step = state.step.next();
    }
    return .{ .point = point, .up = math.yAxis(at.orientation) };
}

/// A part of a test model (`TestModel`): the part it hangs from, null for the root, its origin in
/// the model, and where the docking points it holds stand on it, unturned.
const TestPart = struct {
    parent: ?u8 = null,
    origin: Vector = @splat(0),
    points: []const Vector = &.{},
};

/// A model of `count` parts (`TestPart`), each holding up to two docking points, and a missile's
/// hardpoint in place of each it lacks, which the walk over the docking points passes by. Set it
/// up where it stays, as its records point into it.
fn TestModel(comptime count: usize) type {
    return struct {
        attachments: [count][2]shp.Attachment,
        parts: objects.testing.Parts(count),

        fn init(model: *@This(), parts: [count]TestPart) void {
            model.parts.init();
            for (&model.attachments, &model.parts.data, parts) |*attachments, *data, part| {
                for (attachments, 0..) |*attachment, n| {
                    const point = n < part.points.len;
                    attachment.* = std.mem.zeroes(shp.Attachment);
                    attachment.kind = if (point) .dock_point else .missile;
                    attachment.position = gameobj.vec3(if (point) part.points[n] else @splat(0));
                    attachment.orientation = math.identity;
                }
                data.part.parent = if (part.parent) |up| up else -1;
                data.part.position = gameobj.vec3(part.origin);
                data.attachments = attachments;
            }
        }
    };
}

/// A station at 10000 along Z, its two ports 1000 behind it and 1000 to its right, and two
/// freighters far behind it, each with its docking point at its nose, 500 ahead.
const TestDock = struct {
    game: gameobj.testing.Mission,
    station_model: TestModel(1),
    freighter_model: TestModel(1),
    station: u16,
    freighters: [2]u16,

    fn init(dock: *TestDock) !void {
        try dock.game.init(std.testing.allocator);
        errdefer dock.game.deinit();
        dock.station_model.init(.{.{ .points = &.{ .{ 0, 0, -1000 }, .{ 1000, 0, 0 } } }});
        dock.freighter_model.init(.{.{ .points = &.{.{ 0, 0, 500 }} }});
        _ = try dock.game.add(.predator, .{ 0, 50000, 0 });
        dock.station = try dock.game.add(.predator, .{ 0, 0, 10000 });
        try dock.station_model.parts.fit(std.testing.allocator, dock.game.slot(dock.station));
        for (&dock.freighters) |*freighter| {
            freighter.* = try dock.game.add(.predator, .{ 0, 0, -200000 });
            try dock.freighter_model.parts.fit(std.testing.allocator, dock.game.slot(freighter.*));
        }
    }

    fn deinit(dock: *TestDock) void {
        dock.game.deinit();
    }

    /// Moves the object in slot `index` to `at` (`objects.setPosition`).
    fn place(dock: *TestDock, index: u16, at: Vector) void {
        const slot = dock.game.slot(index);
        objects.setPosition(&slot.object, &slot.drawn, at);
    }

    fn orders(dock: *TestDock) Context {
        return dock.game.orders();
    }
};

test "Style.of" {
    // A limpet car docks in its own style, at the Czar docked in another, and a limpet pod in its
    // own, wherever they dock; any other ship in the Nanny's at a Nanny, and in the station's
    // anywhere else.
    try std.testing.expectEqual(Style.limpet_car, Style.of(.limpet_car, .predator));
    try std.testing.expectEqual(Style.limpet_car_czar, Style.of(.limpet_car, .czar_docked));
    try std.testing.expectEqual(Style.limpet_car, Style.of(.limpet_car, .nanny));
    try std.testing.expectEqual(Style.limpet_pod, Style.of(.limpet_pod, .nanny));
    try std.testing.expectEqual(Style.nanny, Style.of(.predator, .nanny));
    try std.testing.expectEqual(Style.station, Style.of(.predator, .czar_docked));
}

test Side {
    try std.testing.expectEqual(Vector{ 1, 1, 1 }, Side.left.mirror());
    try std.testing.expectEqual(Vector{ -1, 1, 1 }, Side.right.mirror());
    // Any other word mirrors, as the game's test against zero has it.
    try std.testing.expectEqual(Vector{ -1, 1, 1 }, @as(Side, @enumFromInt(2)).mirror());
}

test "a freighter docks at a station's port, from far behind it" {
    var dock: TestDock = undefined;
    try dock.init();
    defer dock.deinit();
    const index = dock.freighters[0];
    const slot = dock.game.slot(index);
    slot.motion = .forward;
    try std.testing.expect(try aigeneric.push(dock.orders(), index, .dock, .at(dock.station, 0)));

    // Far behind the port, on its line, it comes straight along it, full ahead.
    aigeneric.objectOrders(dock.orders(), index);
    const state = &slot.state.dock;
    try std.testing.expectEqual(Style.station, slot.orders[0].data.dock.style);
    try std.testing.expectEqual(Step.far_behind, state.step);
    try std.testing.expectEqual(1, slot.object.throttle);
    // Its berth brings its nose onto the port, and turns it as the port is.
    const at = berth(dock.orders().world, index).?;
    try std.testing.expectEqual(math.Place{ .position = .{ 0, 0, 8500 } }, at);
    // Near each point, on to the next, and then it latches on.
    dock.place(index, .{ 0, 0, 8500 - far_behind });
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(Step.near_behind, state.step);
    dock.place(index, .{ 0, 0, 8500 - near_behind });
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(Step.latching, state.step);
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(Step.sliding, state.step);
    try std.testing.expectEqual(motion.Motion.follow, slot.motion.?);
    try std.testing.expect(slot.object.flags.attached);
    // The slide goes by the mission's ticks: a frame that began past its end, with the ticks not
    // yet run, leaves the ship the whole way back.
    dock.game.clock.frame_start += 2 * slide_ticks;
    const held = way(dock.orders().world, index);
    try std.testing.expectEqual(Step.sliding, state.step);
    try std.testing.expectApproxEqAbs(8500 - near_behind, held.point[2], 1e-2);
    // Half way through the slide, a quarter of the way back along the port's line.
    dock.game.clock.mission_ticks += slide_ticks / 2;
    const half = way(dock.orders().world, index);
    try std.testing.expectApproxEqAbs(8500 - near_behind / 4, half.point[2], 1e-2);
    // Past its end, it is in: set in its berth, and its order over.
    dock.game.clock.mission_ticks += slide_ticks;
    _ = way(dock.orders().world, index);
    try std.testing.expectEqual(Step.docked, state.step);
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(0, slot.object.order_count);
    try std.testing.expectEqual(8500, slot.object.root.position.z);
    try std.testing.expectEqual(gameobj.Slot.none, slot.object.passes_through[0]);
}

test stationInit {
    // Where the ship stands, the berth being 8500 along, and the step it starts at and the side
    // it came from.
    const Case = struct { at: Vector, step: Step, from: Side };
    const cases = [_]Case{
        // Far behind, and further aside than a fifth of the way back: it turns in.
        .{ .at = .{ 100000, 0, -200000 }, .step = .turning_in, .from = .right },
        // Far behind, on the port's line: straight along it.
        .{ .at = .{ 0, 0, -200000 }, .step = .far_behind, .from = .left },
        // Nearer, behind the port: round beside it and behind it first.
        .{ .at = .{ -5000, 0, 3500 }, .step = .beside_behind, .from = .left },
        // Ahead of the port: round beside it first.
        .{ .at = .{ 0, 0, 9500 }, .step = .beside, .from = .left },
    };
    for (cases) |case| {
        var dock: TestDock = undefined;
        try dock.init();
        defer dock.deinit();
        const index = dock.freighters[0];
        dock.place(index, case.at);
        try std.testing.expect(try aigeneric.push(dock.orders(), index, .dock, .at(dock.station, 0)));
        aigeneric.objectOrders(dock.orders(), index);
        const state = dock.game.slot(index).state.dock;
        try std.testing.expectEqual(case.step, state.step);
        try std.testing.expectEqual(case.from, state.from);
    }
}

test "a ship goes round the port on the side it came from" {
    var dock: TestDock = undefined;
    try dock.init();
    defer dock.deinit();
    // Two ships that turn flat, ahead of the port on either side of its line: each yaws hard for
    // the point beside the port on its own side, which lies behind it.
    var flat = gameobj.testing.flight;
    flat.turns = .flat;
    for (dock.freighters, [_]f32{ 5000, -5000 }) |index, across| {
        dock.game.slot(index).flight = &flat;
        dock.place(index, .{ across, 0, 9500 });
        try std.testing.expect(try aigeneric.push(dock.orders(), index, .dock, .at(dock.station, 0)));
        aigeneric.objectOrders(dock.orders(), index);
        try std.testing.expectEqual(Step.beside, dock.game.slot(index).state.dock.step);
    }
    const right = dock.game.slot(dock.freighters[0]);
    const left = dock.game.slot(dock.freighters[1]);
    try std.testing.expectEqual(Side.right, right.state.dock.from);
    try std.testing.expectEqual(Side.left, left.state.dock.from);
    try std.testing.expectEqual(ai.full_limit, right.object.yaw_input);
    try std.testing.expectEqual(-ai.full_limit, left.object.yaw_input);
}

test "a ship's docking point on a part hung from another berths it as the parts stand" {
    var dock: TestDock = undefined;
    try dock.init();
    defer dock.deinit();
    // Its first part stands 1000 ahead of its origin, with no docking point; its second hangs
    // from the first, where it stands, with one 500 ahead of that.
    var model: TestModel(2) = undefined;
    model.init(.{
        .{ .origin = .{ 0, 0, 1000 } },
        .{ .parent = 0, .origin = .{ 0, 0, 1000 }, .points = &.{.{ 0, 0, 500 }} },
    });
    const index = try dock.game.add(.predator, .{ 0, 0, -200000 });
    try model.parts.fit(std.testing.allocator, dock.game.slot(index));
    try std.testing.expect(try aigeneric.push(dock.orders(), index, .dock, .at(dock.station, 0)));
    aigeneric.objectOrders(dock.orders(), index);
    // Its docking point stands 1500 ahead of its origin, so with the point on the port, 9000
    // along, its origin stands at 7500.
    try std.testing.expectEqual(1, dock.game.slot(index).state.dock.own_part);
    try std.testing.expectEqual(7500, berth(dock.orders().world, index).?.position[2]);
}

test "a ship without a port given takes the first free one" {
    var dock: TestDock = undefined;
    try dock.init();
    defer dock.deinit();
    for (dock.freighters) |index| {
        try std.testing.expect(try aigeneric.push(dock.orders(), index, .dock, .at(dock.station, null)));
        aigeneric.objectOrders(dock.orders(), index);
    }
    try std.testing.expectEqual(0, dock.game.slot(dock.freighters[0]).orders[0].target.component);
    try std.testing.expectEqual(1, dock.game.slot(dock.freighters[1]).orders[0].target.component);
}

test "a ship docks nowhere at a port that is not there" {
    var dock: TestDock = undefined;
    try dock.init();
    defer dock.deinit();
    const index = dock.freighters[0];
    const nowhere = [_]aigeneric.Target{
        // The player's ship, in the first slot, has no model, and so no port.
        .at(0, 0),
        // The station has two ports.
        .at(dock.station, 2),
        // A component below -1 names none: the search for a free port leaves it, and the game's
        // count down never reaches it.
        .of(.ship, dock.station, -2),
    };
    for (nowhere) |target| {
        try std.testing.expect(try aigeneric.push(dock.orders(), index, .dock, target));
        aigeneric.objectOrders(dock.orders(), index);
        try std.testing.expectEqual(0, dock.game.slot(index).object.order_count);
    }
}

test "a ship docked at a Nanny passes through nothing more" {
    var dock: TestDock = undefined;
    try dock.init();
    defer dock.deinit();
    const nanny = try dock.game.add(.nanny, .{ 0, 0, 20000 });
    const index = dock.freighters[0];
    const slot = dock.game.slot(index);
    slot.object.passes_through[0] = .of(nanny);
    try std.testing.expect(try aigeneric.push(dock.orders(), index, .dock, .at(nanny, 0)));
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(Style.nanny, slot.orders[0].data.dock.style);
    // Its exit is the station's.
    try std.testing.expect(aigeneric.pop(dock.orders(), index));
    try std.testing.expectEqual(gameobj.Slot.none, slot.object.passes_through[0]);
}
