//! What a few types set off first as one of their components is destroyed, in
//! `C:\lancer\game\explode.cpp`: the first part of `explode_component_lost` (`0x0046D090`). The
//! Boridin throws its gun dome off, the Kronstadt an arm, the Krasnaya an arm with its engine
//! block (`krasnaya_left_arm_off`, `0x00472140`, and `krasnaya_right_arm_off`, `0x00472420`, which
//! its split runs too), the Stalag a door, and the prototype gate a panel of its core; the Stalag's
//! cargo pods burst in a red flame; and the Dark Reign's hat goes out with its coil (`putOutHat`),
//! as it does when the ship splits.
//!
//! Not ported: what lights the prototype gate's power core and the Boridin breakaway's core as
//! their components go ([#238](https://github.com/OpenReliant/openreliant/issues/238)).

const std = @import("std");

const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const create = @import("../create.zig");
const explode = @import("../explode.zig");
const gameobj = @import("../gameobj.zig");
const objects = @import("../objects.zig");
const particles = @import("../particles.zig");
const sound3d = @import("../sound3d.zig");
const events = @import("../mission/events.zig");

/// What `explode_component_lost` sets off first for the object in slot `index` as its component of
/// assembly `link` in `model`, the object's own model or one it carries, is destroyed: whether the
/// assembly's parts go up after, as they do but for a prototype gate's panel.
pub fn componentLost(world: gameobj.World, index: u16, model: *objects.Model, link: u32) bool {
    const slot = &world.objects.slots[index];
    const own = if (slot.model) |*live| live == model else false;
    switch (slot.object.type.base()) {
        .boridin => if (own) switch (link) {
            gun_dome_link => if (model.partNamed(gun_dome)) |ref| throwOff(world, slot, ref, .of(.boridin_gun_dome), @splat(0)),
            power_link => slot.object.flags.unpowered = false,
            else => {},
        },
        .kronstadt => if (own and link == kronstadt_arm_link) {
            if (model.partNamed(kronstadt_arm)) |ref| throwOff(world, slot, ref, .of(.kronstadt_arm), @splat(0));
        },
        .krasnaya => if (own) engineBlockLost(world, index, model, link),
        .stalag => if (own) doorLost(world, index, model, link) else podLost(world, slot, model),
        .proto_gate => if (link >= first_panel_link and link <= last_panel_link) {
            return !panelLost(world, index, model, link);
        },
        .darkreign => if (link == hat_link and model.partNamed(create.extra.dark_hat) != null) putOutHat(world, index),
        else => {},
    }
    return true;
}

/// The assembly of the Dark Reign's `Dark Coil`, whose loss puts its hat out (`0x0046DFC9`).
const hat_link = 17;

/// Puts out the Dark Reign's hat (`create.extra.Hat`), as the loss of its coil does
/// (`0x0046DFD4`) and its split (`explode_capship_component`, `0x0046F8A7`): its four rays go
/// (`eray_remove`), its sparks stop (`particle_emitter_free`), and its band, its star and the
/// record go with them. The object in slot `index` has its hat no more.
///
/// **Fix:** losing a component of the coil's assembly, the game looks for the hat under the model
/// that held the component, and a turret mounted on the ship has none: the game reads through
/// nothing and fails. OpenReliant puts nothing out.
pub fn putOutHat(world: gameobj.World, index: u16) void {
    const slot = &world.objects.slots[index];
    const extra = slot.extra orelse return;
    const hat = switch (extra.*) {
        .hat => |*worn| worn,
    };
    if (world.rays) |rays| for (hat.rays) |kept| {
        if (rays.kept(kept orelse continue)) |ray| rays.remove(ray);
    };
    if (world.explosions) |explosions| explosions.dropStream(index, &explode.hat_sparks);
    extra.destroy(world.objects.gpa);
    slot.extra = null;
}

/// The Boridin's gun dome, its assembly and its wreck's part (`0x00500400`); and the assembly whose
/// loss gives the Boridin its power back.
const gun_dome_link = 15;
const gun_dome = "Bor Ion can bot DEST";
const power_link = 6;

/// The Kronstadt's arm, its assembly and its part (`0x005003CC`).
const kronstadt_arm_link = 9;
const kronstadt_arm = "Kron arm3";

/// A piece of the object in `slot` thrown off from `ref`, one of its parts, as an object of
/// `piece_type`: `offset` from the part in its frame and turned as it is, tumbling and drifting
/// back along it (`throwPiece`, `arm_speed`), with fireballs about the part (`fireballsAbout`).
fn throwOff(world: gameobj.World, slot: *create.Slot, ref: objects.PartRef, piece_type: gameobj.Type, offset: Vector) void {
    const place = slot.partPlace(ref.part()) orelse return;
    const at: math.Place = .{ .position = place.point(offset), .orientation = place.orientation };
    if (throwPiece(world, piece_type, at, arm_tumble)) |made| world.objects.slots[made].object.velocity = gameobj.vec3(back(world, place, arm_speed));
    fireballsAbout(world, place.position, ref.part().object.radius);
}

/// How an arm or a gun dome thrown off tumbles, up to half this either way about each axis, a step
/// (`0x004DC4D0`); and how fast it drifts back, this and up to as much again, a step
/// (`0x004DC72C`).
const arm_tumble: f32 = 0.005;
const arm_speed: f32 = 20;

/// A velocity back along `place`'s forward axis, `speed` and up to as much again.
fn back(world: gameobj.World, place: math.Place, speed: f32) Vector {
    const drift: Vector = .{ 0, 0, -(world.random.fraction() * speed + speed) };
    return math.transform(place.orientation, drift);
}

/// An object of `piece_type` made where `at` stands, turned as it is, unpowered and tumbling
/// (`tumbling`): its slot, or null where it can't be made.
fn throwPiece(world: gameobj.World, piece_type: gameobj.Type, at: math.Place, tumble: f32) ?u16 {
    const made = create.make(world, null, piece_type) catch null orelse return null;
    const piece = &world.objects.slots[made];
    objects.setPlace(&piece.object, &piece.drawn, at);
    piece.object.flags.unpowered = true;
    piece.object.rotation = tumbling(world, tumble);
    return made;
}

/// A turn of up to half `tumble` either way about each axis, a step, at random.
fn tumbling(world: gameobj.World, tumble: f32) math.Matrix {
    const random = world.random;
    const roll = random.centred() * tumble;
    const yaw = random.centred() * tumble;
    return math.fromAngles(random.centred() * tumble, yaw, roll);
}

/// Three lit fireballs `radius` across about `at`, within a quarter of it either way along each
/// axis (`0x004DC408`), each `about_gap` ticks after the last.
fn fireballsAbout(world: gameobj.World, at: Vector, radius: f32) void {
    for (0..about_fireballs) |n| {
        var spot = at;
        inline for (0..3) |axis| spot[axis] += world.random.centred() * radius * about_spread;
        explode.fireballAt(world, spot, .{ .size = radius, .light = true, .delay = @intCast(n * about_gap) });
    }
}

const about_fireballs = 3;
const about_spread: f32 = 0.5;
const about_gap = 10;

/// The Krasnaya's arms: each hangs on its engine block, whose loss throws it off.
pub const Side = enum {
    left,
    right,

    /// The engine block's part (`0x005003EC`, `0x005003D8`), and its assembly in the shipped model,
    /// which the split goes by.
    pub fn block(side: Side) []const u8 {
        return switch (side) {
            .left => "Kras l eng block",
            .right => "Kras r eng block",
        };
    }

    pub fn link(side: Side) u32 {
        return switch (side) {
            .left => 10,
            .right => 11,
        };
    }

    /// The parts of the Krasnaya that go with the arm, and its wreck's that show in their place
    /// (`0x00500650` on).
    fn hidden(side: Side) [6][]const u8 {
        return switch (side) {
            .left => .{ "Kras l bot eng", "Kras l bot eng DEST", "Kras l eng block", "Kras l top eng", "Kras l top eng DEST", "Kras l eng suprt" },
            .right => .{ "Kras r bot eng", "Kras r bot eng DEST", "Kras r eng block", "Kras r top eng", "Kras r top eng DEST", "Kras r eng suprt" },
        };
    }

    fn shown(side: Side) [2][]const u8 {
        return switch (side) {
            .left => .{ "Kras l eng block DEST", "Kras l eng DEST" },
            .right => .{ "Kras r eng block DEST", "Kras r eng DEST" },
        };
    }

    /// The arm thrown off.
    ///
    /// **Fix:** the game throws the left arm off on either side; OpenReliant throws the right
    /// arm's model off on the right.
    fn piece(side: Side) gameobj.Type {
        return switch (side) {
            .left => .of(.krasnaya_left_arm),
            .right => .of(.krasnaya_right_arm),
        };
    }
};

/// The Krasnaya in slot `index` loses its component of assembly `link`: where the assembly's first
/// part is an engine block, its Destroyed is posted and its arm is thrown off (`throwArm`).
fn engineBlockLost(world: gameobj.World, index: u16, model: *objects.Model, link: u32) void {
    const block = model.partOfAssembly(link) orelse return;
    const name = (block.data() orelse return).part.name();
    const side: Side = for (std.enums.values(Side)) |side| {
        if (std.mem.eql(u8, name, side.block())) break side;
    } else return;
    const slot = &world.objects.slots[index];
    if (slot.componentIndex(block.part())) |n| events.destroyed(world, index, n);
    throwArm(world, index, side, link);
}

/// `krasnaya_left_arm_off` (`0x00472140`) and `krasnaya_right_arm_off` (`0x00472420`): the
/// Krasnaya in slot `index` throws its arm on `side` off, from the first part of assembly `link`,
/// its engine block. The arm's parts go and its wreck's show (`Side.hidden`, `Side.shown`); the
/// arm (`Side.piece`) is thrown off `arm_offset` from the block (`throwOff`); the screen flashes,
/// and the block is gone.
///
/// **Fix:** as the split throws an arm off, the game looks for the arm's parts under the engine
/// block alone, so only the block goes and the rest of the arm stays on the ship beside the arm
/// thrown off; OpenReliant looks through the whole ship, as when the block is destroyed.
pub fn throwArm(world: gameobj.World, index: u16, side: Side, link: u32) void {
    const slot = &world.objects.slots[index];
    const model = if (slot.model) |*live| live else return;
    const block = model.partOfAssembly(link) orelse return;
    for (side.hidden()) |name| model.hideNamed(name);
    for (side.shown()) |name| model.showNamed(name);
    throwOff(world, slot, block, side.piece(), arm_offset);
    if (world.flash) |flash| flash.start();
    objects.destroyPart(slot, block);
}

/// Where a Krasnaya's arm thrown off stands, from its engine block in the block's frame.
const arm_offset: Vector = .{ 0, 3300, -14000 };

/// The Stalag in slot `index` loses its door of assembly `link`, one of its three, the first part
/// of the assembly: it is heard (`plateoff`) as it goes, thrown off as the Stalag's doors with the
/// other two hidden, tumbling and flying out ahead of where it stood at `door_speed` and up to half
/// as much again, passing through the Stalag and the Stalag through it; fireballs go off about it,
/// and it is gone.
fn doorLost(world: gameobj.World, index: u16, model: *objects.Model, link: u32) void {
    if (link < 1 or link > doors.len) return;
    const door_part = model.partOfAssembly(link) orelse return;
    const slot = &world.objects.slots[index];
    const part = door_part.part();
    const place = slot.partPlace(part) orelse return;
    sound3d.playIn(world, place.position, math.forward(place.orientation), null, .plateoff, 1, .not_reserved);
    if (throwPiece(world, .of(.stalag_doors), place, door_tumble)) |made| {
        const door = &world.objects.slots[made];
        if (door.model) |*doors_model| {
            for (doors, 1..) |name, n| if (n != link) doors_model.hideNamed(name);
        }
        const out: Vector = .{ 0, 0, world.random.fraction() * door_speed_range + door_speed };
        door.object.velocity = gameobj.vec3(math.transform(place.orientation, out));
        passThrough(world, index, made);
    }
    fireballsAbout(world, place.position, part.object.radius);
    objects.destroyPart(slot, door_part);
}

/// The Stalag's doors by their assemblies' numbers, as the parts of the doors' model
/// (`0x005003BC` to `0x0050039C`); how a door tumbles (`0x004DC518`), and how fast it flies out
/// (`0x004DC440`, `0x004DC48C`).
const doors = [_][]const u8{ "Stalag Door 1", "Stalag Door 2", "Stalag Door 3" };
const door_tumble: f32 = 0.01;
const door_speed: f32 = 100;
const door_speed_range: f32 = 50;

/// The objects in slots `a` and `b` pass through each other: the collision sweep leaves the pair
/// out (`GameObject.passes_through`).
fn passThrough(world: gameobj.World, a: u16, b: u16) void {
    world.objects.slots[a].object.passes_through[0] = .of(b);
    world.objects.slots[b].object.passes_through[0] = .of(a);
}

/// A cargo pod the Stalag carries, `model`, is destroyed: where its first part is a `Cargo pod`, a
/// red flame bursts out of it every way (`pod_flame`), turned as the part is in its model, and
/// fireballs go off about it.
fn podLost(world: gameobj.World, slot: *create.Slot, model: *objects.Model) void {
    const part = model.rootChild(0) orelse return;
    const name = if (model.partData(0)) |data| data.part.name() else return;
    if (!std.mem.eql(u8, name, pod) and !std.mem.eql(u8, name, pod_spaced)) return;
    const at = part.drawn().position;
    var emitter: particles.Emitter = .{
        .born = world.clock.frame_start,
        .template = &pod_flame,
        .place = .{ .position = at, .orientation = part.turn },
        .spread = @splat(std.math.pi),
        .speed = pod_flame_speed,
        .speed_range = pod_flame_speed_range,
        .inherited = gameobj.vector(slot.object.velocity) * @as(Vector, @splat(pod_flame_carried)),
    };
    explode.burstFrom(world, &emitter, pod_flame_count);
    fireballsAbout(world, at, part.object.radius);
}

/// A cargo pod's first part, as the game spells it twice (`0x004E20F8`, `0x00500390`).
const pod = "Cargo pod";
const pod_spaced = "Cargo pod ";

/// The red flame a cargo pod bursts into (`0x0055AD20`): two seconds of it, shrinking from 200
/// across to 150 as it goes from red to nothing.
const pod_flame: particles.Template = .{
    .life = 200,
    .life_spread = 20,
    .rate = .through(90, 90, 90),
    .size = .through(200, 175, 150),
    .colour = .{ .through(1, 0.5, 0), .through(0, 0, 0), .through(0, 0, 0) },
};

/// How the pod's flame leaves it: how fast, a tick, how much of the Stalag's velocity it carries,
/// and how many.
const pod_flame_speed: f32 = 10;
const pod_flame_speed_range: f32 = 4;
const pod_flame_carried: f32 = 0.25;
const pod_flame_count = 200;

/// The prototype gate in slot `index` loses its core panel of assembly `link`, the assembly's
/// first part: a panel of the gate (`proto_gate_panel`) showing one of its three plates at random
/// is thrown off where it stood, tumbling and flying away from the gate's power core at
/// `panel_speed` and up to half as much again, heard (`plateoff`) from it, and passing through the
/// gate and the gate through it; a burst of flame and a lit fireball go off where it was
/// (`explode.burstFlames`), and it is gone. Whether it was a panel.
fn panelLost(world: gameobj.World, index: u16, model: *objects.Model, link: u32) bool {
    const panel_part = model.partOfAssembly(link) orelse return false;
    const slot = &world.objects.slots[index];
    const part = panel_part.part();
    const place = slot.partPlace(part) orelse return false;
    const random = world.random;
    if (throwPiece(world, .of(.proto_gate_panel), place, panel_tumble)) |made| {
        const panel = &world.objects.slots[made];
        const shown = random.rand() % plates.len;
        if (panel.model) |*panel_model| {
            for (plates, 0..) |name, n| if (n != shown) panel_model.hideNamed(name);
        }
        const speed = random.fraction() * panel_speed_range + panel_speed;
        if (model.partNamed(power_core)) |ref| if (slot.partPlace(ref.part())) |core| {
            panel.object.velocity = gameobj.vec3(math.normalize(place.position - core.position) * @as(Vector, @splat(speed)));
        };
        sound3d.playIn(world, place.position, math.forward(place.orientation), made, .plateoff, 1, .player_fx);
        passThrough(world, index, made);
    }
    const flame = explode.burstFlames(world, place.position, gameobj.vector(slot.object.velocity));
    const drift: Vector = if (flame) |emitter| emitter.inherited else @splat(0);
    explode.fireballAt(world, place.position, .{ .size = part.object.radius, .light = true, .velocity = drift });
    objects.destroyPart(slot, panel_part);
    return true;
}

/// The prototype gate's core panels' assemblies; the plates a panel thrown off shows one of
/// (`0x00500380` to `0x00500360`); the gate's power core (`0x004F9D78`); and how a panel tumbles
/// (`0x004DC474`) and how fast it flies (`0x004DC468`, `0x004DC440`).
const first_panel_link = 2;
const last_panel_link = 11;
const plates = [_][]const u8{ "Core plate 1", "Core plate 2", "Core plate 3" };
const power_core = "Protogate Power core";
const panel_tumble: f32 = 0.05;
const panel_speed: f32 = 200;
const panel_speed_range: f32 = 100;

/// A ship of `ship_type` in `stage`'s mission whose model is `named`'s, 5000 ahead of the player,
/// the pieces it throws off made of the same model.
fn testingShip(stage: *explode.testing.Stage, named: anytype, kind: *create.Type, ship_type: gameobj.Type) !struct { u16, gameobj.World } {
    kind.* = .{ .model = &named.parts.source, .loaded = &named.parts.loaded };
    const types = create.testing.oneType(kind);
    const mission = &stage.mission;
    _ = try mission.add(.of(.kamov), @splat(0));
    const ship = try mission.addWith(types, ship_type, .{ 0, 0, 5000 });
    var world = stage.world();
    world.spawn = mission.spawn(types);
    return .{ ship, world };
}

test "the Krasnaya throws an arm off with its engine block" {
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    var named: objects.testing.NamedParts(4) = undefined;
    named.init(.{ "Kras l eng block", "Kras l eng block DEST", "Kras l eng suprt", "Kras body" }, @splat(.cut), @splat(&.{}));
    named.parts.member(0, Side.left.link(), -1);
    named.parts.member(1, Side.left.link(), -1);
    var kind: create.Type = undefined;
    const ship, var world = try testingShip(&stage, &named, &kind, .of(.krasnaya));
    var lit: @import("../main/flash.zig").Flash = .{};
    world.flash = &lit;
    const model = &stage.mission.slot(ship).model.?;
    model.parts[1].hidden = true;
    const count = world.objects.count;

    // Its block goes, with the arm's support; its wreck shows; the arm drifts off back along it,
    // and the screen flashes.
    try std.testing.expect(componentLost(world, ship, model, Side.left.link()));
    try std.testing.expect(model.parts[0].removed and model.parts[2].hidden and !model.parts[1].hidden and !model.parts[3].hidden);
    try std.testing.expectEqual(count + 1, world.objects.count);
    const arm = &world.objects.slots[count].object;
    try std.testing.expectEqual(gameobj.GameType.krasnaya_left_arm, arm.type.base());
    try std.testing.expect(arm.flags.unpowered and gameobj.vector(arm.velocity)[2] < -arm_speed + 1);
    try std.testing.expect(lit.left > 0);
    // Its split finds no block left to throw off.
    try std.testing.expectEqual(null, model.partNamed(Side.left.block()));
}

test "the Stalag throws a door off" {
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    var named: objects.testing.NamedParts(4) = undefined;
    named.init(.{ "Stalag hull", doors[0], doors[1], doors[2] }, @splat(.cut), @splat(&.{}));
    for (1..4) |n| named.parts.member(n, @intCast(n), -1);
    var kind: create.Type = undefined;
    const ship, const world = try testingShip(&stage, &named, &kind, .of(.stalag));
    const model = &stage.mission.slot(ship).model.?;
    const count = world.objects.count;

    // The second door goes, and flies out ahead as the doors' model showing it alone; it and the
    // Stalag pass through each other.
    try std.testing.expect(componentLost(world, ship, model, 2));
    try std.testing.expect(model.parts[2].removed and !model.parts[1].removed);
    const door = &world.objects.slots[count];
    try std.testing.expectEqual(gameobj.GameType.stalag_doors, door.object.type.base());
    try std.testing.expect(door.model.?.parts[1].hidden and !door.model.?.parts[2].hidden and door.model.?.parts[3].hidden);
    try std.testing.expect(gameobj.vector(door.object.velocity)[2] >= door_speed);
    try std.testing.expectEqual(ship, door.object.passes_through[0].index().?);
    try std.testing.expectEqual(count, world.objects.slots[ship].object.passes_through[0].index().?);
    // An assembly past its three doors throws nothing off.
    try std.testing.expect(componentLost(world, ship, model, 4));
    try std.testing.expectEqual(count + 1, world.objects.count);
}

test "the prototype gate throws a core panel off away from its power core" {
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    var named: objects.testing.NamedParts(2) = undefined;
    named.init(.{ power_core, "Core panel" }, @splat(.cut), @splat(&.{}));
    named.parts.member(1, first_panel_link, -1);
    var kind: create.Type = undefined;
    const gate, const world = try testingShip(&stage, &named, &kind, .of(.proto_gate));
    const slot = stage.mission.slot(gate);
    const model = &slot.model.?;
    model.parts[1].animation.now.place.position = .{ 1000, 0, 0 };
    const count = world.objects.count;

    // The panel goes, and the assembly goes up no further; the panel flies out away from the core.
    try std.testing.expect(!componentLost(world, gate, model, first_panel_link));
    try std.testing.expect(model.parts[1].removed);
    const panel = &world.objects.slots[count];
    try std.testing.expectEqual(gameobj.GameType.proto_gate_panel, panel.object.type.base());
    const away = gameobj.vector(panel.object.velocity);
    try std.testing.expect(away[0] >= panel_speed and away[1] == 0 and away[2] == 0);
    try std.testing.expectEqual(gate, panel.object.passes_through[0].index().?);
    // An assembly outside the panels' goes up as usual.
    try std.testing.expect(componentLost(world, gate, model, last_panel_link + 1));
}

test "the Boridin throws its gun dome off, and gets its power back" {
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    var named: objects.testing.NamedParts(1) = undefined;
    named.init(.{gun_dome}, @splat(.cut), @splat(&.{}));
    var kind: create.Type = undefined;
    const ship, const world = try testingShip(&stage, &named, &kind, .of(.boridin));
    const object = &stage.mission.slot(ship).object;
    const model = &stage.mission.slot(ship).model.?;
    const count = world.objects.count;
    try std.testing.expect(componentLost(world, ship, model, gun_dome_link));
    try std.testing.expectEqual(gameobj.GameType.boridin_gun_dome, world.objects.slots[count].object.type.base());
    object.flags.unpowered = true;
    try std.testing.expect(componentLost(world, ship, model, power_link));
    try std.testing.expect(!object.flags.unpowered);
}

test putOutHat {
    const gpa = std.testing.allocator;
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    var ship: create.extra.testing.DarkReign = undefined;
    const world = try ship.init(gpa, &stage, @splat(0));
    defer ship.deinit(gpa);
    const model = &stage.mission.slot(ship.index).model.?;
    // Another assembly's loss leaves the hat on.
    try std.testing.expect(componentLost(world, ship.index, model, hat_link + 1));
    try std.testing.expect(ship.hat(&stage) != null);
    // The coil's puts it out, its rays and its sparks with it, and the coil's assembly goes up.
    try std.testing.expect(componentLost(world, ship.index, model, hat_link));
    try std.testing.expectEqual(null, ship.hat(&stage));
    for (ship.rays.rays.slots) |slot| try std.testing.expectEqual(null, slot);
    try std.testing.expectEqual(null, stage.explosions.streams[0]);
}
