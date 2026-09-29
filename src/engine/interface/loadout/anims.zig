//! The loadout's animations (`loadout.cpp`, `0x004461E0` to `0x00448FF0`): each builder makes an
//! animation of two frames of GenILib's (`i3d.Anim`), from its first frame's key to its second's,
//! each key made where its object stands (`i3d.Key.at`) and then moved, and adds it to the
//! interface (`iinterface_add_anim`). What an animation calls as it steps, as it passes a share of
//! its way and as it ends is the loadout's, which it hands the builder.
//!
//! Not ported yet: the internal guns' (Move Clip Point,
//! [#448](https://github.com/vdmkenny/openreliant/issues/448)). Rotate Scroll Button and the second
//! Move Clip Point belong to a view nothing opens (`0x0044A470`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const camera = @import("../../game/camera.zig");
const i3d = @import("../../genilib/interf/i3d.zig");
const Vector = math.Vector;

/// An animation of two frames, as each of the loadout's builders makes one: from its first frame's
/// key to its second's, over the first frame's time and eases. The second frame's time and eases
/// are never read.
pub const Pair = struct {
    anim: i3d.Anim,
    frames: [2]i3d.Frame,

    /// Makes `pair` the animation `name` of `object` from `first` to `second`, to play forward, and
    /// adds it to `interface`. It must not move once made.
    fn make(pair: *Pair, interface: *i3d.Interface, name: []const u8, object: *i3d.Object, first: i3d.Frame, second: i3d.Key) Allocator.Error!void {
        pair.frames = .{ first, .{ .duration = 0, .key = second } };
        pair.anim = .create(name, object, &pair.frames, 0);
        try interface.addAnim(&pair.anim);
    }

    /// Played from its start `direction`'s way at `now` (`i3danim_reset`, `i3danim_start`), as the
    /// loadout starts each of its animations.
    pub fn play(pair: *Pair, direction: i3d.Direction, now: u32) void {
        pair.anim.reset(direction);
        pair.anim.start(now);
    }

    /// Whether it has stopped, at its end or not yet started (`I3DANIM + 0x24`).
    pub fn stopped(pair: Pair) bool {
        return !pair.anim.playing();
    }
};

/// The angles `object` is turned by (`mat3_angles`).
fn anglesOf(object: *const i3d.Object) Vector {
    return math.angles(object.orientation());
}

/// A turn round, added to or taken off one of a key's angles so that it spins once on its way
/// (`0x004DC3EC`).
const turn: f32 = std.math.tau;

/// How small an object zooms in from, and out to, the thousandth of its size (`0x3A83126F`).
pub const zoomed_out: f32 = 0.001;

/// `anim_spin_disc` (`0x004461E0`): Spin Disc (`0x004EAEC8`), `disc` spinning in from nothing over
/// 2000 ms: from the glow's place `spin_rise` nearer the camera, a turn behind about Z and a
/// thousandth of its size, to its own place, angles and size, its place and angles eased by the
/// cosine and its size easing in. Each step calls `step`, and its end `end`.
pub fn spinDisc(pair: *Pair, interface: *i3d.Interface, disc: *i3d.Object, glow: *const i3d.Object, step: i3d.AnimCallback, end: i3d.AnimCallback) Allocator.Error!void {
    var angles = anglesOf(disc);
    angles[2] -= turn;
    var from: i3d.Key = .at(disc, angles, zoomed_out);
    from.position = glow.position();
    from.position[2] -= spin_rise;
    try pair.make(interface, "Spin Disc", disc, .{
        .duration = spin_time,
        .position = .cosine,
        .angles = .cosine,
        .scale = .in,
        .key = from,
    }, .at(disc, anglesOf(disc), 1));
    pair.anim.on_step = step;
    pair.anim.on_end = end;
}

/// How long the disc spins in and the glow appears, and the panels and the ships zoom in with them
/// (`0x0044620E`).
pub const spin_time = 2000;

/// How much nearer the camera than the glow the disc spins in from (`0x004DC480`).
const spin_rise: f32 = 2;

/// `anim_ship_zoom` (`0x00446310`): Ship zooms with disc (`0x004EAEE0`), `ship` growing a thousand
/// times over 2000 ms, easing in, as the disc spins in: the loadout makes each ship a thousandth
/// of its size first. Only its size moves.
pub fn shipZoom(pair: *Pair, interface: *i3d.Interface, ship: *i3d.Object) Allocator.Error!void {
    try pair.make(interface, "Ship zooms with disc", ship, .{
        .duration = spin_time,
        .scale = .in,
        .key = .at(ship, @splat(0), 1),
    }, .at(ship, @splat(0), ship_growth));
}

/// How many times a ship grows as it zooms in with the disc (`0x447A0000`).
const ship_growth: f32 = 1000;

/// `anim_button_appears` (`0x004463E0`): Button Appears (`0x004EAF04`), `button` flying out of the
/// glow over 500 ms: from the glow's place, a turn ahead about Y and a thousandth of its size, to
/// its own place, angles and size, its place and angles eased by the cosine and its size easing
/// in. A fifth of its way it calls `share`, which starts the next button's.
pub fn buttonAppears(pair: *Pair, interface: *i3d.Interface, button: *i3d.Object, glow: *const i3d.Object, share: i3d.AnimCallback) Allocator.Error!void {
    var angles = anglesOf(button);
    angles[1] += turn;
    var from: i3d.Key = .at(button, angles, 1);
    from.position = glow.position();
    from.scale = zoomed_out;
    try pair.make(interface, "Button Appears", button, .{
        .duration = button_time,
        .position = .cosine,
        .angles = .cosine,
        .scale = .in,
        .key = from,
    }, .at(button, anglesOf(button), 1));
    pair.anim.on_share = share;
    pair.anim.share = button_share;
}

/// How long a button takes to appear (`0x00446472`), and the share of its way at which the next
/// starts (`0x3E4CCCCD`).
const button_time = 500;
const button_share: f32 = 0.2;

/// `anim_glow_appears` (`0x00446510`): Glow Appears (`0x004EAF20`), `glow` growing from a
/// thousandth of its size to its own over 2000 ms, eased by the cosine, where it stands.
pub fn glowAppears(pair: *Pair, interface: *i3d.Interface, glow: *i3d.Object) Allocator.Error!void {
    var from: i3d.Key = .at(glow, anglesOf(glow), 1);
    from.scale = zoomed_out;
    try pair.make(interface, "Glow Appears", glow, .{
        .duration = spin_time,
        .scale = .cosine,
        .key = from,
    }, .at(glow, anglesOf(glow), 1));
}

/// `anim_zoom_hardpoint` (`0x00448A40`): Zoom Hardpoint (`0x004EAFF0`), `object` growing from a
/// thousandth of its size to its own over 400 ms, evenly. Its first key's angles are whatever the
/// builder's stack held, here nought, and its second's `belly_up`; nothing eases them.
pub fn zoomHardpoint(pair: *Pair, interface: *i3d.Interface, object: *i3d.Object) Allocator.Error!void {
    try pair.make(interface, "Zoom Hardpoint", object, .{
        .duration = hardpoint_time,
        .scale = .linear,
        .key = .at(object, @splat(0), zoomed_out),
    }, .at(object, belly_up, 1));
}

/// The angles (pitch, yaw, roll) the chosen ship turns over to on the missile page, showing its
/// underside and its missile hardpoints to the camera (`0x004489B3`), which a missile flying to
/// a hardpoint turns to as well (`0x00448D45`).
const belly_up: Vector = .{ -std.math.pi / 2.0, std.math.pi, 0 };

/// `anim_sink_ship` (`0x004486A0`): Sink Ship (`0x004EAF9C`), a ship sinking into the disc from
/// its slot on the arc (`slot`), `sink_depth` down over 800 ms, easing in. A share of its way
/// (`chain_share`) it calls `share`, which starts the next, and its end calls `end`.
pub fn sinkShip(pair: *Pair, interface: *i3d.Interface, ship: *i3d.Object, slot: Placed, share: i3d.AnimCallback, end: i3d.AnimCallback) Allocator.Error!void {
    try sink(pair, interface, "Sink Ship", ship, slot, share, end);
}

/// `anim_sink_missile` (`0x004487F0`): Sink Missile (`0x004EAFB4`), a missile's icon sinking into
/// the disc from its slot on the arc as a ship does. Played back, it rises out of the disc.
pub fn sinkMissile(pair: *Pair, interface: *i3d.Interface, icon: *i3d.Object, slot: Placed, share: i3d.AnimCallback, end: i3d.AnimCallback) Allocator.Error!void {
    try sink(pair, interface, "Sink Missile", icon, slot, share, end);
}

/// A sinking from `slot` to `sink_depth` below it. Its keys take the slot's angles and the arc's
/// unit of scale (`0x004DC6E0`), which it never eases.
fn sink(pair: *Pair, interface: *i3d.Interface, name: []const u8, object: *i3d.Object, slot: Placed, share: i3d.AnimCallback, end: i3d.AnimCallback) Allocator.Error!void {
    var from: i3d.Key = .at(object, slot.angles, arc_unit);
    from.position = slot.position;
    var to = from;
    to.position[1] += sink_depth;
    try pair.make(interface, name, object, .{ .duration = sink_time, .position = .in, .key = from }, to);
    pair.anim.on_share = share;
    pair.anim.share = chain_share;
    pair.anim.on_end = end;
}

/// How long a ship or a missile takes to sink (`0x0044874C`), and how far down it sinks: the
/// float the disc spins in from (`0x004DC480`).
const sink_time = 800;
pub const sink_depth: f32 = 2;

/// The share of its way at which a ship's or a missile's sinking starts the next's
/// (`0x3D8F5C29`).
const chain_share: f32 = 0.07;

/// The arc's unit of scale (`0x004DC6E0`): a ship on the arc stands at a share of its scale made
/// of it (`loadout.arc_share`), and the sinkings' keys and Ship to Belly Up's last take it.
pub const arc_unit: f32 = 0.00175;

/// `anim_belly_up` (`0x00448950`): Ship to Belly Up (`0x004EAFD0`), the chosen `ship` turning
/// over 1000 ms, eased by the cosine, from the angles of its turn `spin` to `belly_up`. While it
/// plays, the ship's turn gives its first key the angles it has come to (`ship_spin`), so that it
/// turns back to where the spin is. Its end calls `end`. Its keys' scales, the ship's `scale` and
/// the arc's unit, are never eased.
pub fn bellyUp(pair: *Pair, interface: *i3d.Interface, ship: *i3d.Object, spin: math.Matrix, scale: f32, end: i3d.AnimCallback) Allocator.Error!void {
    try pair.make(interface, "Ship to Belly Up", ship, .{
        .duration = belly_up_time,
        .angles = .cosine,
        .key = .at(ship, math.angles(spin), scale),
    }, .at(ship, belly_up, arc_unit));
    pair.anim.on_end = end;
}

/// How long the chosen ship takes to turn belly up (`0x004489BD`).
const belly_up_time = 1000;

/// `anim_attach_missile` (`0x00448B10`): Attach Missile (`0x004EB00C`), `flight`, a copy of a
/// missile, flying over 1000 ms from the missile's icon `icon` to a hardpoint of the chosen ship
/// at `hardpoint`, its place and its angles eased by the cosine, from the icon's angles to
/// `belly_up`. Its end calls `end`. Its keys' scales, the icons' and 1, are never eased.
pub fn attachMissile(pair: *Pair, interface: *i3d.Interface, icon: *const i3d.Object, flight: *i3d.Object, hardpoint: Vector, end: i3d.AnimCallback) Allocator.Error!void {
    var to: i3d.Key = .at(icon, belly_up, 1);
    to.position = hardpoint;
    try pair.make(interface, "Attach Missile", flight, .{
        .duration = attach_time,
        .position = .cosine,
        .angles = .cosine,
        .key = .at(icon, anglesOf(icon), missile_scale),
    }, to);
    pair.anim.on_end = end;
}

/// How long a missile takes to fly to a hardpoint or back (`0x00448B77`).
const attach_time = 1000;

/// The scale of the missiles' icons and of a missile flying to the ship (`0x3BE56042`).
pub const missile_scale: f32 = 0.007;

/// How long a hardpoint's marker takes to zoom in (`0x00448A6B`).
const hardpoint_time = 400;

/// The panels' zoom (`loadout_load`, `0x00442514` to `0x0044259B`): a Zoom Hardpoint of `panel`
/// changed to fly it out of the glow as the disc spins in: over 2000 ms from the glow's place and
/// a turn about Y, to its own place and angles, both eased by the cosine, its size growing evenly
/// from a thousandth.
pub fn panelZoom(pair: *Pair, interface: *i3d.Interface, panel: *i3d.Object, glow: *const i3d.Object) Allocator.Error!void {
    try zoomHardpoint(pair, interface, panel);
    const first = &pair.frames[0];
    first.duration = spin_time;
    first.position = .cosine;
    first.angles = .cosine;
    first.key.angles = .{ 0, turn, 0 };
    first.key.position = glow.position();
    pair.frames[1].key.position = panel.position();
    pair.frames[1].key.angles = anglesOf(panel);
}

/// Where a ship stands on a slot of the disc, and how it is turned there (`slot_place`).
pub const Placed = struct {
    position: Vector,
    angles: Vector,
};

/// `anim_select_ship` (`0x00448160`): Select Ship (`0x004EAF4C`), `ship` flying off the disc to the
/// chosen spot over 1500 ms: from `slot`, at `arc_scale`, to `spot`, tilted back at `spot_angles`
/// and at `scale`, its place and angles eased by the cosine and its size growing evenly. Its end
/// calls `end`.
pub fn selectShip(pair: *Pair, interface: *i3d.Interface, ship: *i3d.Object, slot: Placed, arc_scale: f32, spot: Vector, scale: f32, end: i3d.AnimCallback) Allocator.Error!void {
    var from: i3d.Key = .at(ship, slot.angles, arc_scale);
    from.position = slot.position;
    var to: i3d.Key = .at(ship, spot_angles, scale);
    to.position = spot;
    try pair.make(interface, "Select Ship", ship, .{
        .duration = select_time,
        .position = .cosine,
        .angles = .cosine,
        .scale = .linear,
        .key = from,
    }, to);
    pair.anim.on_end = end;
}

/// How long a ship takes to fly to the chosen spot or back to the disc (`0x5DC`), and the angles it
/// stands at on the spot as it arrives, tilted back (`0x00448263`).
const select_time = 1500;
pub const spot_angles: Vector = .{ -0.75, 0, 0 };

/// `anim_deselect_ship` (`0x00448320`): Deselect Ship (`0x004EAF64`), `ship` flying back from the
/// chosen spot to `slot` over 1500 ms: from where it stands, at the angles of its spin `spin` and
/// at `scale`, to the slot at `arc_scale`, its place and angles eased by the cosine and its size
/// shrinking evenly. Its end calls `end`.
pub fn deselectShip(pair: *Pair, interface: *i3d.Interface, ship: *i3d.Object, spin: math.Matrix, scale: f32, slot: Placed, arc_scale: f32, end: i3d.AnimCallback) Allocator.Error!void {
    var to: i3d.Key = .at(ship, slot.angles, arc_scale);
    to.position = slot.position;
    try pair.make(interface, "Deselect Ship", ship, .{
        .duration = select_time,
        .position = .cosine,
        .angles = .cosine,
        .scale = .linear,
        .key = .at(ship, math.angles(spin), scale),
    }, to);
    pair.anim.on_end = end;
}

/// `anim_flip_ship_name` (`0x004484A0`): Flip Shipinfo (`0x004EAF80`), the ship's name `panel`
/// turning over about X over 1500 ms, eased by the cosine, from its angles as it is built to
/// (pi, 0, 0), which shows its back. Half way it calls `share`, the game's `noop`.
pub fn flipName(pair: *Pair, interface: *i3d.Interface, panel: *i3d.Object, share: i3d.AnimCallback) Allocator.Error!void {
    try flip(pair, interface, panel);
    pair.anim.on_share = share;
    pair.anim.share = flip_share;
}

/// `anim_flip_ship_info` (`0x004485A0`): Flip Shipinfo, the ship's stats `panel` turning over as
/// the name's does, calling nothing.
pub fn flipInfo(pair: *Pair, interface: *i3d.Interface, panel: *i3d.Object) Allocator.Error!void {
    try flip(pair, interface, panel);
}

fn flip(pair: *Pair, interface: *i3d.Interface, panel: *i3d.Object) Allocator.Error!void {
    try pair.make(interface, "Flip Shipinfo", panel, .{
        .duration = select_time,
        .angles = .cosine,
        .key = .at(panel, anglesOf(panel), 1),
    }, .at(panel, flipped, 1));
}

/// A panel turned over, its back to the camera (`0x004DC4AC`), and the share of its way at which
/// the name's flip calls its `noop` (`0x3F000000`).
pub const flipped: Vector = .{ std.math.pi, 0, 0 };
const flip_share: f32 = 0.5;

const expectVector = math.testing.expectVector;

/// The front end's projection, which the tests step the interface with.
const test_view: srapi.Context = .{ .projection = .init(640, 480, srapi.full_screen, camera.factors) };

/// What the tests' callbacks count.
const Counts = struct {
    steps: u32 = 0,
    shares: u32 = 0,
    ends: u32 = 0,

    fn of(context: *anyopaque) *Counts {
        return @ptrCast(@alignCast(context));
    }
    fn stepped(context: *anyopaque, _: *i3d.Anim) void {
        of(context).steps += 1;
    }
    fn shared(context: *anyopaque, _: *i3d.Anim) void {
        of(context).shares += 1;
    }
    fn ended(context: *anyopaque, _: *i3d.Anim) void {
        of(context).ends += 1;
    }
};

/// An object standing for a scene object of no mesh, at `position`, turned by `angles`.
fn testObject(scene_object: *srapiext.MeshObject, position: Vector, angles: Vector) i3d.Object {
    scene_object.* = .{ .flags = .{}, .position = position, .orientation = math.fromAngleVector(angles), .radius = 1, .levels = &.{} };
    var object: i3d.Object = .create(0, null, false);
    object.target = .{ .mesh = scene_object };
    return object;
}

test spinDisc {
    var counts: Counts = .{};
    var interface: i3d.Interface = .create(std.testing.allocator, &counts);
    defer interface.deinit();
    var disc_mesh: srapiext.MeshObject = undefined;
    var glow_mesh: srapiext.MeshObject = undefined;
    var disc = testObject(&disc_mesh, .{ 1.5, 3.75, 1.45 }, .{ -std.math.pi / 2.0, 0, 0 });
    const glow = testObject(&glow_mesh, .{ 1, 5.1, -3.8 }, @splat(0));
    var pair: Pair = undefined;
    try spinDisc(&pair, &interface, &disc, &glow, Counts.stepped, Counts.ended);
    try std.testing.expectEqual(1, interface.anims.items.len);
    // From the glow's place, 2 nearer the camera, and a thousandth of the disc's size.
    try std.testing.expectEqual(Vector{ 1, 5.1, -5.8 }, pair.frames[0].key.position);
    try std.testing.expectEqual(zoomed_out, pair.frames[0].key.scale);
    // Half way through its 2000 ms, it has come half the way along, eased by the cosine.
    pair.play(.forward, 0);
    try interface.frame(std.testing.allocator, &test_view, 1000, .{});
    try std.testing.expectApproxEqAbs(0.5 * (1.5 + 1), disc_mesh.position[0], 1e-5);
    try std.testing.expectEqual(1, counts.steps);
    // At its end, where the disc stood, at its size.
    interface.busy = true;
    try interface.frame(std.testing.allocator, &test_view, spin_time, .{});
    try std.testing.expectApproxEqAbs(1.5, disc_mesh.position[0], 1e-5);
    try std.testing.expectApproxEqAbs(1, disc_mesh.scale, 1e-6);
    try std.testing.expectEqual(1, counts.ends);
    try std.testing.expect(pair.stopped());
}

test panelZoom {
    var counts: Counts = .{};
    var interface: i3d.Interface = .create(std.testing.allocator, &counts);
    defer interface.deinit();
    var panel_mesh: srapiext.MeshObject = undefined;
    var glow_mesh: srapiext.MeshObject = undefined;
    var panel = testObject(&panel_mesh, .{ -8, -8.7, 0 }, @splat(0));
    const glow = testObject(&glow_mesh, .{ 1, 5.1, -3.8 }, @splat(0));
    var pair: Pair = undefined;
    try panelZoom(&pair, &interface, &panel, &glow);
    // Zoom Hardpoint's time and eases changed: from the glow, a turn about Y, to the panel's own.
    const first = pair.frames[0];
    try std.testing.expectEqual(spin_time, first.duration);
    try std.testing.expectEqual(i3d.Ease.cosine, first.position.?);
    try std.testing.expectEqual(i3d.Ease.linear, first.scale.?);
    try std.testing.expectEqual(Vector{ 0, turn, 0 }, first.key.angles);
    try std.testing.expectEqual(glow_mesh.position, first.key.position);
    try std.testing.expectEqual(panel_mesh.position, pair.frames[1].key.position);
    try std.testing.expectEqual(Vector{ 0, 0, 0 }, pair.frames[1].key.angles);
}

test selectShip {
    var counts: Counts = .{};
    var interface: i3d.Interface = .create(std.testing.allocator, &counts);
    defer interface.deinit();
    var ship_mesh: srapiext.MeshObject = undefined;
    var ship = testObject(&ship_mesh, .{ 0, 0, 0 }, @splat(0));
    var pair: Pair = undefined;
    const slot: Placed = .{ .position = .{ -6, 2.75, 3 }, .angles = .{ 0, 1, 0 } };
    try selectShip(&pair, &interface, &ship, slot, 0.002, .{ 3.3, -2.25, 3.25 }, 0.009, Counts.ended);
    // From the slot at the arc's size to the chosen spot, tilted back, at the ship's own.
    try std.testing.expectEqual(slot.position, pair.frames[0].key.position);
    try std.testing.expectEqual(slot.angles, pair.frames[0].key.angles);
    try std.testing.expectEqual(0.002, pair.frames[0].key.scale);
    try std.testing.expectEqual(Vector{ 3.3, -2.25, 3.25 }, pair.frames[1].key.position);
    try std.testing.expectEqual(spot_angles, pair.frames[1].key.angles);
    try std.testing.expectEqual(0.009, pair.frames[1].key.scale);
    try std.testing.expectEqual(select_time, pair.frames[0].duration);
}

test sinkShip {
    var counts: Counts = .{};
    var interface: i3d.Interface = .create(std.testing.allocator, &counts);
    defer interface.deinit();
    var ship_mesh: srapiext.MeshObject = undefined;
    var ship = testObject(&ship_mesh, @splat(0), @splat(0));
    var pair: Pair = undefined;
    const slot: Placed = .{ .position = .{ -6, 2.75, 3 }, .angles = .{ 0, 1, 0 } };
    try sinkShip(&pair, &interface, &ship, slot, Counts.shared, Counts.ended);
    // From its slot to two below it.
    try std.testing.expectEqual(slot.position, pair.frames[0].key.position);
    try std.testing.expectEqual(Vector{ -6, 4.75, 3 }, pair.frames[1].key.position);
    pair.play(.forward, 0);
    interface.busy = true;
    // Past its share of the way, the next is started; at its end it has sunk.
    try interface.frame(std.testing.allocator, &test_view, 60, .{});
    try std.testing.expectEqual(1, counts.shares);
    try interface.frame(std.testing.allocator, &test_view, sink_time, .{});
    try std.testing.expectEqual(Vector{ -6, 4.75, 3 }, ship_mesh.position);
    try std.testing.expectEqual(1, counts.ends);
    // Played back, it rises to its slot.
    pair.play(.back, 1000);
    try interface.frame(std.testing.allocator, &test_view, 1000 + sink_time, .{});
    try std.testing.expectEqual(slot.position, ship_mesh.position);
}

test bellyUp {
    var counts: Counts = .{};
    var interface: i3d.Interface = .create(std.testing.allocator, &counts);
    defer interface.deinit();
    var ship_mesh: srapiext.MeshObject = undefined;
    var ship = testObject(&ship_mesh, .{ 3.3, -2.25, 3.25 }, @splat(0));
    var pair: Pair = undefined;
    try bellyUp(&pair, &interface, &ship, math.fromAngles(-0.75, 0, 0), 0.009, Counts.ended);
    try std.testing.expectEqual(belly_up, pair.frames[1].key.angles);
    try std.testing.expectApproxEqAbs(-0.75, pair.frames[0].key.angles[0], 1e-6);
    // It turns where it stands, and ends belly up.
    pair.play(.forward, 0);
    interface.busy = true;
    try interface.frame(std.testing.allocator, &test_view, belly_up_time, .{});
    try std.testing.expectEqual(Vector{ 3.3, -2.25, 3.25 }, ship_mesh.position);
    try expectVector(math.forward(math.fromAngleVector(belly_up)), math.forward(ship_mesh.orientation));
    try std.testing.expectEqual(1, counts.ends);
}

test attachMissile {
    var counts: Counts = .{};
    var interface: i3d.Interface = .create(std.testing.allocator, &counts);
    defer interface.deinit();
    var icon_mesh: srapiext.MeshObject = undefined;
    const icon = testObject(&icon_mesh, .{ -6, 2.75, 3 }, .{ 0, 1, 0 });
    var flight_mesh: srapiext.MeshObject = undefined;
    var flight = testObject(&flight_mesh, @splat(0), @splat(0));
    var pair: Pair = undefined;
    try attachMissile(&pair, &interface, &icon, &flight, .{ 3, -1, 2 }, Counts.ended);
    // The copy flies from the icon, turned as it is, to the hardpoint, belly up.
    try std.testing.expectEqual(&flight, pair.anim.object);
    try std.testing.expectEqual(Vector{ -6, 2.75, 3 }, pair.frames[0].key.position);
    try std.testing.expectApproxEqAbs(1, pair.frames[0].key.angles[1], 1e-6);
    pair.play(.forward, 0);
    interface.busy = true;
    try interface.frame(std.testing.allocator, &test_view, attach_time / 2, .{});
    try expectVector(.{ -1.5, 0.875, 2.5 }, flight_mesh.position);
    try interface.frame(std.testing.allocator, &test_view, attach_time, .{});
    try std.testing.expectEqual(Vector{ 3, -1, 2 }, flight_mesh.position);
    try std.testing.expectEqual(1, counts.ends);
}

test flipName {
    var counts: Counts = .{};
    var interface: i3d.Interface = .create(std.testing.allocator, &counts);
    defer interface.deinit();
    var panel_mesh: srapiext.MeshObject = undefined;
    var panel = testObject(&panel_mesh, .{ -3.9, -7.9, 0 }, @splat(0));
    var pair: Pair = undefined;
    try flipName(&pair, &interface, &panel, Counts.shared);
    // Half way over, the name calls its share.
    pair.play(.forward, 0);
    interface.busy = true;
    try interface.frame(std.testing.allocator, &test_view, select_time / 2, .{});
    try std.testing.expectEqual(1, counts.shares);
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, math.angles(panel_mesh.orientation)[0], 1e-4);
}
