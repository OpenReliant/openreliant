//! `C:\lancer\game\airipper.cpp`: the Ripper, which carries cargo pods in the tractor beams of its
//! four back pincers. Ripper grabs target object (order 12) lifts an object up to the Ripper and
//! stows it aboard; Make ripper drop what it's carrying (39) lets it go, or, where the order names
//! a component of a ship, hands over to Ripper attach cargo pod to Mammoth (112), which fits the
//! pod there; and Ripper end drop object (111) backs the Ripper away from what it let go. What
//! each Ripper carries (`rippercargo`) and their beams are the file's tables (`Rippers`).
//! docs/engine/orders.md describes the orders.
//!
//! **Unverified:** that `airipper_init` and `airipper_free` (`0x0040FC90`, `0x0040FCF0`), between
//! `ailand.cpp`'s known code and the file's, and the attach order's update and the beams' routines,
//! `0x00411420` to `0x004124D0`, after it, are the file's.
//!
//! Not ported: a multiplayer game's wait for the other players between the steps
//! (`ai_sequence_sync`, `0x00401000`, [#55](https://github.com/vdmkenny/openreliant/issues/55)).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const ease = @import("../genilib/interf/ease.zig");
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const Context = aigeneric.Context;
const create = @import("create.zig");
const events = @import("mission/events.zig");
const gameobj = @import("gameobj.zig");
const matmanager = @import("matmanager.zig");
const motion = @import("motion.zig");
const objects = @import("objects.zig");
const particles = @import("particles.zig");
const sound3d = @import("sound3d.zig");
const tractor = @import("tractor.zig");
const xtrabits = @import("xtrabits.zig");
const shp = @import("../../formats/shp.zig");
const Invulnerability = gameobj.Invulnerability;
const Order = @import("ai/orders.zig").Order;

const log = std.log.scoped(.orders);

// --- The tables ---------------------------------------------------------------------------------

/// How many Rippers can carry at once, and how many sets of beams there can be
/// (`AIRIPPER_MAX_FX`; the tables wrap at it, `0x00410AA0`, `0x00412198`).
pub const capacity = 150;

/// A place among the Rippers' sets of beams.
const Place = std.math.IntFittingRange(0, capacity - 1);

/// What the Rippers carry (`rippercargo`, `0x00518648`, and `next_rippercargo`, `0x00518AFC`) and
/// their beams (`airipper_fx`, `0x00518B00`, and `next_airipper_fx`, `0x00518640`), with the
/// texture the beams are drawn over (`airipper_texture`, `0x00518AF8`).
pub const Rippers = struct {
    gpa: Allocator,
    /// How the beams look (`tractor.Look`).
    look: tractor.Look,
    cargo: [capacity]?Carried = @splat(null),
    next_cargo: usize = 0,
    grips: [capacity]?*Grip = @splat(null),
    next_grip: Place = 0,

    /// `airipper_init` (`0x0040FC90`), as a mission loads: nothing carried, no beams, and `laser2`
    /// (`tractor.Look.init`).
    pub fn init(gpa: Allocator, textures: *srtexture.Table) matmanager.Error!Rippers {
        return .{ .gpa = gpa, .look = try .init(textures) };
    }

    /// `airipper_free` (`0x0040FCF0`), as a mission ends, then the tables as a mission loads:
    /// every set of beams let go, and nothing carried.
    pub fn reset(rippers: *Rippers) void {
        for (0..capacity) |index| rippers.free(index);
        rippers.cargo = @splat(null);
        rippers.next_cargo = 0;
        rippers.next_grip = 0;
    }

    pub fn deinit(rippers: *Rippers) void {
        rippers.reset();
    }

    /// `airipper_fx_take` (`0x00412140`), with `airipper_fx_pincers` (`0x00412390`): the next set
    /// of beams, let go first where one holds it, for the Ripper in slot `ripper`, one from the
    /// first point of each of its back pincers' first point lists (`pincers`), and its place;
    /// null where it can't be made.
    fn take(rippers: *Rippers, world: gameobj.World, ripper: u16) ?Taken {
        const index = rippers.next_grip;
        rippers.next_grip = if (index == capacity - 1) 0 else index + 1;
        rippers.free(index);
        const made = rippers.gpa.create(Grip) catch return null;
        made.* = .{};
        rippers.grips[index] = made;
        const taken: Taken = .{ .grip = made, .place = index };
        const model = if (world.objects.slots[ripper].model) |*live| live else return taken;
        for (&made.beams, pincers) |*beam, name| {
            const part = model.partNamed(name) orelse continue;
            if (part.model != model) continue;
            const point = firstPoint(part) orelse continue;
            beam.* = tractor.Beam.create(rippers.gpa, rippers.look, ripper, part.index, point) catch null;
        }
        return taken;
    }

    /// A set of beams `take` made, and its place.
    const Taken = struct { grip: *Grip, place: Place };

    /// A set of beams for the Ripper in slot `ripper` (`take`), aimed at the pod in slot `pod`
    /// where one is named (`Grip.aimAt`), as both inits take and aim them: where it is, or none
    /// where it can't be made.
    fn takeFor(rippers: *Rippers, world: gameobj.World, ripper: u16, pod: ?u16) GripRef {
        const taken = rippers.take(world, ripper) orelse return .none;
        if (pod) |aimed| taken.grip.aimAt(world, aimed);
        return .of(taken.place);
    }

    /// `airipper_fx_free` (`0x004121C0`): set of beams `index` let go.
    fn free(rippers: *Rippers, index: usize) void {
        const held = rippers.grips[index] orelse return;
        tractor.destroyAll(&held.beams, rippers.gpa);
        rippers.gpa.destroy(held);
        rippers.grips[index] = null;
    }

    /// The set of beams `grip` names, where it names one that is held.
    fn gripAt(rippers: *Rippers, grip: GripRef) ?*Grip {
        const place = grip.place() orelse return null;
        return if (place < capacity) rippers.grips[place] else null;
    }

    /// OpenReliant's: each set of beams an order showed this frame goes into `scene`, where its
    /// Ripper and its pod are drawn: each beam aimed from its pincer, in the pincer's frame, at the
    /// middle of its pair of the pod's points, which the game takes in the frame the pod's part
    /// hangs from (`hungFrom`). The game aims and adds them as the order runs (`airipper_fx_show`).
    pub fn draw(rippers: *Rippers, gpa: Allocator, scene: *srcore.Scene, all: *create.Objects) Allocator.Error!void {
        for (rippers.grips) |held| {
            const shown = held orelse continue;
            if (!shown.shown) continue;
            shown.shown = false;
            for (shown.beams, 0..) |made, n| {
                const beam = made orelse continue;
                const target = shown.targets[n / beams_per_pair] orelse continue;
                const from = drawnPart(all, beam.ship, beam.part) orelse continue;
                const to = hungFrom(all, target.ship, target.part) orelse continue;
                beam.aim(from, to.point(target.point));
                try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &beam.object }, .world);
            }
        }
    }

    /// The Ripper in slot `ripper` carries the object in slot `object`, in the next entry
    /// (`order_ripper_grabs_target_object`'s last step, `0x0040FF80`).
    ///
    /// **Fix:** where the next entry is still taken, the game stops with "Ripper Grab AI error:
    /// Too many rippers doing their stuff at once."; OpenReliant logs it and takes the entry.
    fn hold(rippers: *Rippers, ripper: u16, object: u16) void {
        const index = rippers.next_cargo;
        if (rippers.cargo[index] != null) log.warn("too many Rippers carry at once: the one in slot {d} takes another's entry", .{ripper});
        rippers.cargo[index] = .{ .ripper = ripper, .object = object };
        rippers.next_cargo = (index + 1) % capacity;
    }

    /// `ripper_carried` (`0x00412340`): what the Ripper in slot `ripper` carries, the first entry
    /// naming it; null where it carries nothing.
    ///
    /// **Fix:** where it carries nothing, the game stops with "AI ripper enddrop error: Can't find
    /// the object the ripper grabbed!"; OpenReliant's orders give up.
    pub fn carried(rippers: *const Rippers, ripper: u16) ?u16 {
        const entry = rippers.entryOf(ripper) orelse return null;
        return rippers.cargo[entry].?.object;
    }

    /// The Ripper in slot `ripper` carries nothing from now on: the first entry naming it is
    /// cleared (`order_ripper_end_drop_object`'s last step, `0x00410E90`).
    fn release(rippers: *Rippers, ripper: u16) void {
        const entry = rippers.entryOf(ripper) orelse return;
        rippers.cargo[entry] = null;
    }

    fn entryOf(rippers: *const Rippers, ripper: u16) ?usize {
        for (rippers.cargo, 0..) |held, index| {
            const entry = held orelse continue;
            if (entry.ripper == ripper) return index;
        }
        return null;
    }
};

/// A Ripper and what it carries (`rippercargo`, 8 bytes: `ripper_idx` and the object's).
pub const Carried = struct { ripper: u16, object: u16 };

/// Where an order's set of beams is among the Rippers' (`Rippers.grips`), as its state keeps it;
/// the game holds the record itself, and a null pointer for none.
pub const GripRef = enum(i32) {
    none = -1,
    _,

    fn of(at: Place) GripRef {
        return @enumFromInt(@as(i32, at));
    }

    /// Its place among the Rippers' beams, where it names one.
    pub fn place(grip: GripRef) ?usize {
        return std.math.cast(usize, @intFromEnum(grip));
    }
};

/// `airipper_fx_free` (`0x004121C0`) on an order's beams: the set `grip` names let go, where it
/// names one of `rippers`', and `grip` left naming none, as the game clears its pointer.
fn freeGrip(rippers: ?*Rippers, grip: *GripRef) void {
    if (rippers) |tables| if (grip.place()) |at| if (at < capacity) tables.free(at);
    grip.* = .none;
}

/// A Ripper's beams (`0x74` bytes of `airipper_fx`): one from each of its back pincers, the first
/// two reaching for the middle of the pod's first pair of points and the last two for that of its
/// second.
pub const Grip = struct {
    beams: [pincers.len]?*tractor.Beam = @splat(null),
    targets: [pod_pairs.len]?Target = @splat(null),
    /// Whether an order showed it this frame.
    shown: bool = false,

    /// `airipper_fx_show` (`0x00412200`): shown this frame, as solid as `alpha`.
    fn show(grip: *Grip, alpha: f32) void {
        tractor.fadeAll(&grip.beams, alpha);
        grip.shown = true;
    }

    /// Its beams reach for the pod in slot `pod` from now on: the middles of its part
    /// `cargo_part`'s first two pairs of points, for a type whose pods the Ripper can lift
    /// (`carries`), as both inits aim them (`order_ripper_grabs_target_object_init`, `0x0040FD10`,
    /// and `order_ripper_attach_cargo_pod_to_mammoth_init`, `0x00411200`).
    fn aimAt(grip: *Grip, world: gameobj.World, pod: u16) void {
        const slot = &world.objects.slots[pod];
        if (!carries(slot.object.type)) return;
        const model = if (slot.model) |*live| live else return;
        const part = model.partNamed(cargo_part) orelse return;
        if (part.model != model) return;
        const data = part.data() orelse return;
        if (data.point_lists.len == 0) return;
        const points = data.point_lists[0].points;
        for (&grip.targets, pod_pairs) |*target, pair| {
            if (pair[1] >= points.len) continue;
            const a = gameobj.vector(points[pair[0]].position);
            const b = gameobj.vector(points[pair[1]].position);
            target.* = .{ .ship = pod, .part = part.index, .point = (a + b) * @as(Vector, @splat(0.5)) };
        }
    }
};

/// Where a beam reaches: a point on a part of an object.
pub const Target = struct { ship: u16, part: usize, point: Vector };

/// The pairs of a pod's points whose middles the beams reach for.
const pod_pairs = [_][2]usize{ .{ 0, 1 }, .{ 2, 3 } };

/// How many beams reach for each pair of the pod's points (`airipper_fx_show`: beam `n` for pair
/// `n / 2`).
const beams_per_pair = pincers.len / pod_pairs.len;

comptime {
    assert(pincers.len == beams_per_pair * pod_pairs.len);
}

/// Where part `index` of the object in slot `ship` was last drawn, where it is there to draw.
fn drawnPart(all: *const create.Objects, ship: u16, index: usize) ?math.Place {
    const model = if (all.slots[ship].model) |*live| live else return null;
    if (index >= model.parts.len) return null;
    return model.parts[index].drawn();
}

/// Where the frame that part `index` of the object in slot `ship` hangs from stands, where the
/// object has the part: the object's own place (`create.Slot.drawn`) for a part that hangs from
/// the root, as a pod's part does, else its parent's frame worked out from the root (`frameAt`).
/// `airipper_fx_show` (`0x00412200`) takes the pod's points in it, reading the pod frame's parent
/// (`+0x10`, `0x00412235`), so the beams stay on a pod that is disabled and not framed.
fn hungFrom(all: *const create.Objects, ship: u16, index: usize) ?math.Place {
    const slot = &all.slots[ship];
    const model = if (slot.model) |*live| live else return null;
    if (index >= model.parts.len) return null;
    const parent = model.parts[index].parent orelse return slot.drawn;
    return model.frameAt(parent, slot.drawn);
}

/// The first point of `part`'s first list, where it has one (part `+0x228`).
fn firstPoint(part: objects.PartRef) ?Vector {
    const data = part.data() orelse return null;
    if (data.point_lists.len == 0 or data.point_lists[0].points.len == 0) return null;
    return gameobj.vector(data.point_lists[0].points[0].position);
}

/// The Ripper's back pincers, each with a point its beam comes from (`airipper_fx_pincers`).
const pincers = [_][]const u8{ "Ripper Back pincer 2", "Ripper Back pincer 03", "Ripper Back pincer 04", "Ripper Back pincer 05" };

/// The part a pod shows as, which the Ripper has one of too, shown while it carries (`0x004E20F8`).
pub const cargo_part = "Cargo pod";

/// The Ripper's cabin, whose turn back the end of a drop and the fitting of a pod wait for
/// (`0x004E226C`).
const cabin_part = "Ripper Cabin";

/// The Ripper's tracks, which every part of it that has them plays together: its forearms reaching
/// out, its pincers closing on a pod, and its cabin turning (`0x004E2208`, `0x004E21FC`,
/// `0x004E21F0`).
const ready_track = "ready to grab";
const grab_track = "grab pod";
const cabin_track = "cabin turn";

/// Whether the Ripper can lift an object of `object`: the cargo pod and the fuel pod. The game
/// asserts "Ripper cannot pick up this type of object." for another, in code that never runs.
fn carries(object: gameobj.Type) bool {
    return object == .cargo_pod or object == .fuel_pod;
}

// --- Order states --------------------------------------------------------------------------------

/// What Ripper grabs target object keeps in its ship's order state.
pub const GrabState = extern struct {
    /// When the step began.
    since: i32,
    step: GrabStep,
    /// Its beams.
    grip: GripRef,
    /// Whether it lifts the object from below, as in mission 26.
    below: bool,
    _unknown_0d: [3]u8,
    /// How invulnerable the object was, to be given back; the game stores the byte widened to a
    /// word, so the three after it are zero.
    invulnerable: Invulnerability,
    _unknown_11: [3]u8,
    /// The Ripper's motion, to be given back should the object go: kept by number, or
    /// `no_motion` for none (`keepMotion`, `keptMotion`).
    motion: u32,
    /// Where the Ripper stops to grab it.
    at: [3]f32,
    /// How the object is turned, and how the Ripper is, as the object is turned to match.
    angles: [3]f32,
    own_angles: [3]f32,
    /// Where the object is lifted from, and where to: 300 from the Ripper toward it.
    from: [3]f32,
    to: [3]f32,
    _unknown_54: [0x90 - 0x54]u8,

    comptime {
        assert(@offsetOf(GrabState, "step") == 0x04);
        assert(@offsetOf(GrabState, "grip") == 0x08);
        assert(@offsetOf(GrabState, "below") == 0x0C);
        assert(@offsetOf(GrabState, "invulnerable") == 0x10);
        assert(@offsetOf(GrabState, "motion") == 0x14);
        assert(@offsetOf(GrabState, "at") == 0x18);
        assert(@offsetOf(GrabState, "angles") == 0x24);
        assert(@offsetOf(GrabState, "own_angles") == 0x30);
        assert(@offsetOf(GrabState, "from") == 0x3C);
        assert(@offsetOf(GrabState, "to") == 0x48);
        assert(@sizeOf(GrabState) == 0x90);
    }

    /// Keeps the Ripper's motion `kept`, or none.
    fn keepMotion(state: *GrabState, kept: ?motion.Motion) void {
        state.motion = if (kept) |moving| @intFromEnum(moving) else no_motion;
    }

    /// The motion it keeps, where it keeps one it knows.
    fn keptMotion(state: GrabState) ?motion.Motion {
        if (state.motion == no_motion) return null;
        return std.enums.fromInt(motion.Motion, state.motion);
    }
};

/// The Ripper's motion as `GrabState` keeps none.
const no_motion = std.math.maxInt(u32);

/// Ripper grabs target object's steps.
pub const GrabStep = enum(u32) {
    /// Waiting for the other players.
    starting = 0,
    /// Flying to where it grabs the object, until it comes to rest there.
    approaching = 1,
    /// Lifting from below, turning to face the object.
    facing = 2,
    /// The beams coming on.
    reaching = 3,
    /// The object drawn halfway.
    lifting = 4,
    /// The object turned to match the Ripper.
    turning = 5,
    /// The object drawn the rest of the way; then the pincers close.
    drawing = 6,
    /// The cabin about to turn.
    gripping = 7,
    /// The cabin turning.
    stowing = 8,
    /// Done: the object is aboard.
    stowed = 9,
    _,

    /// How long it lasts, in ticks, for a step that lasts a while (`ripper_grab_ticks`,
    /// `0x004E2060`).
    fn ticks(comptime step: GrabStep) i32 {
        return switch (step) {
            .reaching => 150,
            .lifting => 300,
            .turning => 500,
            .drawing => 300,
            .gripping => 150,
            .stowing => 500,
            .starting, .approaching, .facing, .stowed, _ => @compileError("a step that lasts no set time"),
        };
    }
};

/// What Make ripper drop what it's carrying keeps.
pub const DropState = extern struct {
    since: i32,
    step: DropStep,
    _unknown_08: [0x90 - 0x08]u8,

    comptime {
        assert(@offsetOf(DropState, "step") == 0x04);
        assert(@sizeOf(DropState) == 0x90);
    }
};

pub const DropStep = enum(u32) {
    /// Coming to rest; then the pincers open.
    stopping = 0,
    /// The pincers opening.
    opening = 1,
    /// Letting go.
    letting_go = 2,
    _,
};

/// What Ripper end drop object keeps.
pub const EndDropState = extern struct {
    since: i32,
    step: EndDropStep,
    _unknown_08: [4]u8,
    /// Where the Ripper turns to face as it leaves.
    ahead: [3]f32,
    _unknown_18: [0x90 - 0x18]u8,

    comptime {
        assert(@offsetOf(EndDropState, "step") == 0x04);
        assert(@offsetOf(EndDropState, "ahead") == 0x0C);
        assert(@sizeOf(EndDropState) == 0x90);
    }
};

pub const EndDropStep = enum(u32) {
    /// The forearms drawing back.
    starting = 0,
    /// Until they are in; then the Ripper backs away.
    opening = 1,
    /// Backing away, for half a second; then the cabin turns back.
    backing = 2,
    /// Until the cabin is round.
    turning = 3,
    /// Turning to face ahead.
    facing = 4,
    /// Done.
    done = 5,
    _,

    /// How long it lasts, in ticks, for a step that lasts a while (`ripper_end_drop_ticks`,
    /// `0x004E2094`).
    fn ticks(comptime step: EndDropStep) i32 {
        return switch (step) {
            .backing => 50,
            .starting, .opening, .turning, .facing, .done, _ => @compileError("a step that lasts no set time"),
        };
    }
};

/// What Ripper attach cargo pod to Mammoth keeps.
pub const AttachState = extern struct {
    since: i32,
    step: AttachStep,
    /// Its beams.
    grip: GripRef,
    /// Where the Ripper turns to face as it leaves: behind it.
    away: [3]f32,
    /// Where it stops beside the ship's component, and where the component stands.
    beside: [3]f32,
    port: [3]f32,
    /// How the pod is turned fitted.
    fitted_angles: [3]f32,
    /// Where the pod is let go from, and how it is turned there.
    from: [3]f32,
    from_angles: [3]f32,
    _unknown_54: [0x90 - 0x54]u8,

    comptime {
        assert(@offsetOf(AttachState, "step") == 0x04);
        assert(@offsetOf(AttachState, "grip") == 0x08);
        assert(@offsetOf(AttachState, "away") == 0x0C);
        assert(@offsetOf(AttachState, "beside") == 0x18);
        assert(@offsetOf(AttachState, "port") == 0x24);
        assert(@offsetOf(AttachState, "fitted_angles") == 0x30);
        assert(@offsetOf(AttachState, "from") == 0x3C);
        assert(@offsetOf(AttachState, "from_angles") == 0x48);
        assert(@sizeOf(AttachState) == 0x90);
    }
};

pub const AttachStep = enum(u32) {
    /// Waiting for the other players.
    starting = 0,
    /// Flying to beside the component, until it comes to rest there.
    approaching = 1,
    /// Turning to face the component; then the pincers open.
    facing = 2,
    /// The pincers opening.
    opening = 3,
    /// The beams coming on.
    reaching = 4,
    /// The pod carried onto the component, and turned to fit; then the forearms draw back.
    fitting = 5,
    /// Until they are in; then the cabin turns back.
    releasing = 6,
    /// Until the cabin is round.
    turning = 7,
    /// Turning to face away.
    facing_away = 8,
    /// Done: the pod is fitted.
    fitted = 9,
    _,

    /// How long it lasts, in ticks, for a step that lasts a while (`ripper_attach_ticks`,
    /// `0x004E20AC`).
    fn ticks(comptime step: AttachStep) i32 {
        return switch (step) {
            .reaching => 150,
            .fitting => 1000,
            .starting, .approaching, .facing, .opening, .releasing, .turning, .facing_away, .fitted, _ => @compileError("a step that lasts no set time"),
        };
    }
};

// --- Shared measures -----------------------------------------------------------------------------

/// The limit its steering takes while it approaches, and while it turns to face (`0x00410043`,
/// `0x0041103F`).
const approach_limit: f32 = 0.3;
const face_limit: f32 = 2;

/// How far short of where it stops the Ripper slows to `slow_throttle` (`0x004DC438`, `0x00410130`);
/// and within how far of the point it stops: to grab, to grab from below, and to fit a pod
/// (`0x004DC438`, `0x004DC440`, `0x004DC544`).
const slow_within: f32 = 2000;
const grab_stop_within: f32 = 2000;
const grab_stop_within_below: f32 = 100;
const attach_stop_within: f32 = 300;
const slow_throttle: f32 = 0.2;

/// How still it must be to let go: its speed and its rates, which the game compares with their
/// signs (`0x004DC474`).
const drop_still: f32 = 0.05;

/// How far above a component the Ripper stands to grab it (`ripper_grab_offset`, `0x00412480`),
/// from a table of the Mammoth's and the Stalag's, both this (`ripper_grab_offsets`).
///
/// **Fix:** for another type the game reads past the table's end, into the bytes of "Cargo pod";
/// OpenReliant takes this for it too.
const grab_above: Vector = .{ 0, 2500, 0 };

/// Where the Ripper lifts an object from below, in mission 26: 1000 under it (`0x0040FF32`).
const grab_below: Vector = .{ 0, -1000, 0 };
const below_mission = 26;

/// How far the object is drawn toward the Ripper: to this far from it (`0x004104F3`).
const lifted_to: f32 = 300;

/// The share of the way each of the lift's two steps draws the object (`0x004DC408`).
const lift_share: f32 = 0.5;

/// How far off a component the Ripper stops to fit a pod to it: above, or below for a Sharov and a
/// Boridin; and how far above it it stands as the pod goes on (`0x0041129C`, `0x004112B5`,
/// `0x00411B50`).
const beside_by: f32 = 2500;
const standing_by: f32 = 4000;

/// How far ahead the Ripper turns to face as it leaves a pod it dropped, and how far behind as it
/// leaves one it fitted (`0x00410FDE`, `0x00411DE9`).
const leave_by: f32 = 10000;

/// The throttle at which it backs away from a pod it dropped (`0x00410F45`).
const backing_throttle: f32 = 0.2;

/// How still the Ripper must be to finish turning as it leaves a pod it dropped: at rest, each
/// input and rate below its limit rather than within it (`order_ripper_end_drop_object`'s step 4,
/// `0x00410E90`).
const leaving_still = ai.Stillness.at_rest.strictly();

/// The share of the fitting through which the pod keeps its turn, and the share after which it is
/// turned as it fits (`0x004DC450`, `0x004DC408`).
///
/// **Improvement:** OpenReliant divides by the span between them where the game multiplies by its
/// rounded reciprocal (`0x004DC540`).
const turn_from: f32 = 0.15;
const turn_until: f32 = 0.5;

/// How far the pod is turned to fit, back about the component's axis (`fitTurn`, `0x00411A7B`).
const fit_turn: f32 = -std.math.pi / 2.0;

/// The Ripper's tracks: where each starts and how fast it plays, a speed below zero playing it
/// back to its start. Each plays once (`0x00410294`, `0x00410923`, `0x00410965`, `0x00410E36`,
/// and in the end drop's and the attach's updates, `0x00410E90` and `0x00411420`).
const Play = struct { track: []const u8, from: f32, speed: f32 };
const open_forearms: Play = .{ .track = ready_track, .from = 0, .speed = 15 };
const close_pincers: Play = .{ .track = grab_track, .from = 0, .speed = 10 };
const turn_cabin: Play = .{ .track = cabin_track, .from = 0, .speed = 4.5 };
const open_pincers: Play = .{ .track = grab_track, .from = 350, .speed = -10 };
const draw_forearms: Play = .{ .track = ready_track, .from = 350, .speed = -6 };
const turn_cabin_back: Play = .{ .track = cabin_track, .from = 400, .speed = -4.5 };

/// Every part of the Ripper in `slot` plays `play`'s track, where it has it
/// (`objects.Model.playNamedTree`).
fn playAll(slot: *create.Slot, play: Play) void {
    if (slot.model) |*model| model.playNamedTree(play.track, play.from, .once, play.speed);
}

/// Whether the track the root's first child last played is back at its start (`(root.children[0])
/// + 0xBC`), which the Ripper's forearms and pincers are once a track played backwards is over.
fn trackDone(slot: *const create.Slot) bool {
    const model = if (slot.model) |*live| live else return true;
    const first = model.rootChild(0) orelse return true;
    return first.animation.time == 0;
}

/// Whether the Ripper's cabin's track is back at its start.
fn cabinDone(slot: *create.Slot) bool {
    const model = if (slot.model) |*live| live else return true;
    const cabin = model.partNamed(cabin_part) orelse return true;
    return cabin.part().animation.time == 0;
}

/// Where `part` of the object in `slot`, one of its model's or of a model it carries, stands in the
/// world (`SR_object_concate_parents`).
fn placeOf(slot: *create.Slot, part: *const objects.Model.Part) ?math.Place {
    const model = if (slot.model) |*live| live else return null;
    return model.placeOf(slot.drawn, part, .now);
}

/// Where the first part named `name` of the object in `slot` stands in the world
/// (`node_find_named`).
fn namedPlace(slot: *create.Slot, name: []const u8) ?math.Place {
    const model = if (slot.model) |*live| live else return null;
    const ref = model.partNamed(name) orelse return null;
    return placeOf(slot, ref.part());
}

/// The object in `slot` shows its part named `name`, or hides it (`objects.Model.showNamed`,
/// `objects.Model.hideNamed`).
fn showPart(slot: *create.Slot, name: []const u8, shown: bool) void {
    const model = if (slot.model) |*live| live else return;
    if (shown) model.showNamed(name) else model.hideNamed(name);
}

/// How far through its step an order is at tick `now`, for a step `ticks` long.
fn through(since: i32, now: i32, ticks: i32) f32 {
    return particles.through(now, since, ticks);
}

/// Whether a step `ticks` long that began at `since` is over by tick `now`.
fn over(since: i32, now: i32, ticks: i32) bool {
    return since + ticks < now;
}

/// Where the Ripper's beams have drawn the object it grabs by tick `now`, in `step`: `lift_share`
/// of the way from where it stood to `lifted_to` off the Ripper as they lift it, and the rest of
/// the way as they draw it in (`GrabStep.lifting`, `GrabStep.drawing`), no farther.
fn liftedAt(state: *const GrabState, comptime step: GrabStep, now: i32) Vector {
    const t = through(state.since, now, step.ticks());
    const drawn = switch (step) {
        .lifting => t * lift_share,
        .drawing => (t + 1) * lift_share,
        .starting, .approaching, .facing, .reaching, .turning, .gripping, .stowing, .stowed, _ => @compileError("a step that draws nothing"),
    };
    return math.lerp(@as(Vector, state.from), @as(Vector, state.to), @min(drawn, 1));
}

/// Where the Ripper's beams have carried the pod by tick `now` as they fit it onto the component,
/// easing each way from where it stood (`AttachStep.fitting`).
fn fittedAt(state: *const AttachState, now: i32) Vector {
    const share = through(state.since, now, AttachStep.fitting.ticks());
    return ease.cosine(@as(Vector, state.from), @as(Vector, state.port), share);
}

// --- Ripper grabs target object -------------------------------------------------------------------

/// `order_ripper_grabs_target_object_init` (`0x0040FD10`): the Ripper takes its beams, aims them
/// at the object, its target, and neither collides with the other from now on; the object can't be
/// harmed while it is carried, and the Ripper flies by `motion_plain`, held (`Flags.attached`).
/// Where the target names a component, the Ripper stops `grab_above` it, in its frame; in mission
/// 26, `grab_below` the object, which it lifts from below; else at the object.
///
/// **Fix:** for an object the Ripper can't lift (`carries`), the game aims the beams at whatever
/// its set of beams last held; OpenReliant shows none.
pub fn grabInit(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.ripper_grab;
    const target = slot.orders[0].target;
    const at = target.slotIn(all) orelse return;
    const object = &all.slots[at];
    state.invulnerable = object.object.invulnerable;
    object.object.invulnerable = .full;
    state.since = ctx.world.clock.frame_start;
    state.step = .starting;
    state.grip = if (world.rippers) |rippers| rippers.takeFor(world, index, at) else .none;
    state.keepMotion(slot.motion);
    slot.motion = .plain;
    slot.object.passes_through[0] = .of(at);
    object.object.passes_through[0] = .of(index);
    slot.object.flags.attached = true;
    state.below = false;
    const component = if (target.part()) |part| object.component(part) else null;
    if (component) |part| {
        const place = placeOf(object, part) orelse object.drawn;
        state.at = place.point(grab_above);
    } else if (all.mission_number == below_mission) {
        state.at = object.drawn.point(grab_below);
        state.below = true;
    } else {
        state.at = object.drawn.position;
    }
}

/// `order_ripper_grabs_target_object_exit` (`0x00410B50`): the Ripper is held no longer, and lets
/// its beams go.
pub fn grabExit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    slot.object.flags.attached = false;
    freeGrip(ctx.world.rippers, &slot.state.ripper_grab.grip);
}

/// `order_ripper_grabs_target_object` (`0x0040FF80`): the Ripper flies to where it grabs the
/// object and comes to rest, its forearms reaching out (`ready_track`); from below, it turns to
/// face the object. Its beams come on over the step's time, heard on the object (`tractor`), and
/// draw it halfway to the Ripper, `lifted_to` off; turn it to match the Ripper; and draw it the
/// rest of the way, as the pincers close on it (`grab_track`), heard (`ripgrab`). The cabin turns
/// (`cabin_track`), and the object is aboard: the Ripper's own pod shows in its place, the object
/// is disabled and can be harmed again, and the Ripper, which flies astern from now on
/// (`motion_backward`), carries it (`Rippers.hold`), and has its RipperGrabbedObject
/// (`events.ripperGrabbed`). Should the object go first, the Ripper gives up.
///
/// **Improvement:** the object is drawn on between the ticks as it is drawn in
/// (`create.Slot.glide`); the game draws it where each tick places it.
pub fn grab(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.ripper_grab;
    const now = ctx.world.clock.frame_start;
    const held_at = slot.orders[0].target.slotIn(all) orelse return;
    const held = &all.slots[held_at];
    const grip: ?*Grip = if (world.rippers) |rippers| rippers.gripAt(state.grip) else null;
    if (held.object.gone()) {
        freeGrip(world.rippers, &state.grip);
        object.flags.attached = false;
        slot.motion = state.keptMotion();
        return aigeneric.end(ctx, index);
    }
    switch (state.step) {
        .starting => next(state, now),
        .approaching => {
            if (!approach(world, index, state.at, if (state.below) grab_stop_within_below else grab_stop_within)) return;
            object.letGo();
            playAll(slot, open_forearms);
            next(state, now);
        },
        .facing => {
            if (!state.below) return next(state, now);
            _ = ai.steer(world, index, held.drawn.position, approach_limit, ai.no_ease, .{});
            if (!ai.Stillness.at_rest.holds(object, false)) return;
            object.letGo();
            next(state, now);
        },
        .reaching => {
            const t = through(state.since, now, GrabStep.reaching.ticks());
            if (grip) |beams| beams.show(ease.in(0, 1, t));
            if (!over(state.since, now, GrabStep.reaching.ticks())) return;
            next(state, now);
            const from = held.drawn.position;
            const own = slot.drawn.position;
            state.from = from;
            state.to = own + math.normalize(from - own) * @as(Vector, @splat(lifted_to));
            held.object.flags.thaw();
            sound3d.playIn(world, null, null, held_at, .tractor, 1, .not_reserved);
        },
        .lifting => {
            const at = liftedAt(state, .lifting, now);
            objects.setPosition(&held.object, &held.drawn, at);
            held.glide = liftedAt(state, .lifting, now + 1) - at;
            if (grip) |beams| beams.show(1);
            if (!over(state.since, now, GrabStep.lifting.ticks())) return;
            next(state, now);
            state.angles = math.angles(held.drawn.orientation);
            state.own_angles = math.angles(slot.drawn.orientation);
        },
        .turning => {
            const share = @min(through(state.since, now, GrabStep.turning.ticks()), 1);
            objects.setOrientation(&held.object, &held.drawn, math.fromAngleVector(ease.cosine(@as(Vector, state.angles), @as(Vector, state.own_angles), share)));
            if (grip) |beams| beams.show(1);
            if (over(state.since, now, GrabStep.turning.ticks())) next(state, now);
        },
        .drawing => {
            const at = liftedAt(state, .drawing, now);
            objects.setPlace(&held.object, &held.drawn, .{ .position = at, .orientation = math.fromAngleVector(state.own_angles) });
            held.glide = liftedAt(state, .drawing, now + 1) - at;
            if (grip) |beams| beams.show(1);
            if (!over(state.since, now, GrabStep.drawing.ticks())) return;
            next(state, now);
            sound3d.playIn(world, null, null, held_at, .ripgrab, 1, .not_reserved);
            playAll(slot, close_pincers);
        },
        .gripping => {
            if (over(state.since, now, GrabStep.gripping.ticks())) {
                next(state, now);
                playAll(slot, turn_cabin);
            }
            objects.setOrientation(&held.object, &held.drawn, math.fromAngleVector(state.own_angles));
        },
        .stowing => {
            if (over(state.since, now, GrabStep.stowing.ticks())) next(state, now);
            objects.setOrientation(&held.object, &held.drawn, math.fromAngleVector(state.own_angles));
        },
        .stowed => {
            showPart(held, cargo_part, false);
            showPart(slot, cargo_part, true);
            slot.motion = .backward;
            held.object.invulnerable = state.invulnerable;
            held.object.flags.disabled = true;
            if (world.rippers) |rippers| rippers.hold(index, held_at);
            aigeneric.end(ctx, index);
            object.flags.attached = false;
            events.ripperGrabbed(world, index, held_at);
        },
        _ => {},
    }
}

/// The order on to its next step, from tick `now`.
fn next(state: anytype, now: i32) void {
    state.step = @enumFromInt(@intFromEnum(state.step) + 1);
    state.since = now;
}

/// The Ripper in slot `index` flies to `at` and comes to rest there, which it tells: it steers at
/// it, and flies at full throttle beyond `slow_within` of `stop`, at `slow_throttle` nearer and not
/// at all within `stop`, holding still where it isn't facing the point near it
/// (`ai.approachToRest`), as `order_ripper_grabs_target_object`'s step 1 flies it
/// (`0x0040FF80`).
fn approach(world: gameobj.World, index: u16, at: Vector, stop: f32) bool {
    const slot = &world.objects.slots[index];
    const reach = math.distance(at, slot.drawn.position);
    _ = ai.steer(world, index, at, approach_limit, ai.no_ease, .{});
    return ai.approachToRest(slot, at - slot.drawn.position, reach, .{ .full_beyond = stop + slow_within, .slow_beyond = stop, .slow_throttle = slow_throttle });
}

// --- Make ripper drop what it's carrying ------------------------------------------------------------

/// `order_make_ripper_drop_what_its_carrying_init` (`0x00410B90`): the Ripper stops turning and
/// thrusting, flies by `motion_plain` and is held.
pub fn dropInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.ripper_drop;
    state.step = .stopping;
    state.since = ctx.world.clock.frame_start;
    slot.object.letGo();
    slot.motion = .plain;
    slot.object.flags.attached = true;
}

/// `order_make_ripper_drop_what_its_carrying` (`0x00410C00`): where the order names a ship, the
/// Ripper fits what it carries to it instead (`attach`), its order aimed at the target's index and
/// component taken as a ship's (`order_push_ship`). Else, at rest, it opens its pincers
/// (`grab_track`, played back), heard (`ripgrab`); then what it carries stands where its own pod
/// is, shown in its place, and the Ripper leaves it (Ripper end drop object). What it drops stays
/// disabled.
///
/// **Fix:** for a negative index other than -1, the game takes it for a ship's slot and reads
/// before its table; OpenReliant takes it for none.
///
/// **Fix:** the game plays `ripgrab`, which follows an object, on none (-1), reading before the
/// objects' table; OpenReliant plays nothing (`sound3d.play`).
pub fn drop(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const target = slot.orders[0].target;
    if (target.slot() != null) {
        aigeneric.end(ctx, index);
        _ = aigeneric.give(ctx, index, .ripper_attach_cargo_pod_to_mammoth, target.asShip());
        return;
    }
    const rippers = world.rippers orelse return;
    const pod = rippers.carried(index) orelse return giveUp(ctx, index);
    const state = &slot.state.ripper_drop;
    const now = ctx.world.clock.frame_start;
    const object = &slot.object;
    switch (state.step) {
        .stopping => {
            if (object.speed < drop_still and object.pitch_rate < drop_still and object.yaw_rate < drop_still and object.roll_rate < drop_still) {
                next(state, now);
                playAll(slot, open_pincers);
            }
        },
        .opening => if (trackDone(slot)) {
            next(state, now);
            sound3d.playIn(world, null, null, null, .ripgrab, 1, .not_reserved);
        },
        .letting_go => {
            const place = namedPlace(slot, cargo_part) orelse return giveUp(ctx, index);
            const dropped = &all.slots[pod];
            objects.setPlace(&dropped.object, &dropped.drawn, place);
            showPart(dropped, cargo_part, true);
            showPart(slot, cargo_part, false);
            object.flags.attached = false;
            aigeneric.end(ctx, index);
            _ = aigeneric.give(ctx, index, .ripper_end_drop_object, .none);
        },
        _ => {},
    }
}

/// The order ends, where what it needs is gone. **Fix:** the game stops, or goes on reading what
/// is gone; OpenReliant lets the Ripper go.
fn giveUp(ctx: Context, index: u16) void {
    ctx.world.objects.slots[index].object.flags.attached = false;
    aigeneric.end(ctx, index);
}

// --- Ripper end drop object ------------------------------------------------------------------------

/// `order_ripper_end_drop_object_init` (`0x00410E60`): the Ripper is held no longer.
pub fn endDropInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    slot.object.flags.attached = false;
    const state = &slot.state.ripper_end_drop;
    state.step = .starting;
    state.since = ctx.world.clock.frame_start;
}

/// `order_ripper_end_drop_object` (`0x00410E90`): the Ripper draws its forearms back
/// (`ready_track`, played back), then backs away astern at `backing_throttle` for the step's time,
/// and turns its cabin back (`cabin_track`); once it is round, it turns to face `leave_by` ahead
/// until it is still (`leaving_still`), and flies on (`motion_forward`): neither it nor what it
/// dropped passes through the other any more, it carries nothing, and it has its
/// RipperDroppedObject (`events.ripperDropped`).
pub fn endDrop(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.ripper_end_drop;
    const now = ctx.world.clock.frame_start;
    const rippers = world.rippers orelse return;
    const pod = rippers.carried(index) orelse return giveUp(ctx, index);
    switch (state.step) {
        .starting => {
            playAll(slot, draw_forearms);
            next(state, now);
        },
        .opening => if (trackDone(slot)) {
            next(state, now);
            slot.motion = .backward;
            object.throttle = backing_throttle;
        },
        .backing => if (over(state.since, now, EndDropStep.backing.ticks())) {
            next(state, now);
            object.throttle = 0;
            playAll(slot, turn_cabin_back);
        },
        .turning => if (cabinDone(slot)) {
            next(state, now);
            state.ahead = slot.drawn.point(.{ 0, 0, leave_by });
        },
        .facing => {
            _ = ai.steer(world, index, state.ahead, face_limit, ai.no_ease, .{});
            if (leaving_still.holds(object, false)) next(state, now);
        },
        .done => {
            slot.motion = .forward;
            object.passes_through[0] = .none;
            all.slots[pod].object.passes_through[0] = .none;
            rippers.release(index);
            events.ripperDropped(world, index, pod);
            object.flags.attached = false;
            aigeneric.end(ctx, index);
        },
        _ => {},
    }
}

// --- Ripper attach cargo pod to Mammoth ------------------------------------------------------------

/// `order_ripper_attach_cargo_pod_to_mammoth_init` (`0x00411200`): the Ripper takes its beams,
/// aims them at the pod it carries, and notes where to stop beside the component its target names,
/// `beside_by` off it in its frame, and where the component stands. It flies astern
/// (`motion_backward`), held.
pub fn attachInit(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.ripper_attach;
    state.step = .starting;
    state.since = ctx.world.clock.frame_start;
    state.grip = if (world.rippers) |rippers| rippers.takeFor(world, index, rippers.carried(index)) else .none;
    if (portOf(all, slot.orders[0].target)) |port| {
        const ship = &all.slots[port.ship];
        const by: f32 = if (ship.object.type == .sharov or ship.object.type == .boridin) -beside_by else beside_by;
        state.beside = port.place.point(.{ 0, by, 0 });
        state.port = port.place.position;
    }
    slot.motion = .backward;
    slot.object.flags.attached = true;
}

/// A component a pod is fitted to, and where it stands.
const Port = struct { ship: u16, part: *objects.Model.Part, place: math.Place };

/// The component `target` names, where it is there.
fn portOf(all: *create.Objects, target: aigeneric.Target) ?Port {
    const ship = target.slotIn(all) orelse return null;
    const slot = &all.slots[ship];
    const part = slot.component(target.part() orelse return null) orelse return null;
    return .{ .ship = ship, .part = part, .place = placeOf(slot, part) orelse return null };
}

/// How the pod is turned to fit a ship of `ship`: a quarter turn back about the component's X, on
/// the Mammoth under any of its numbers, the Sharov and the Boridin, and about its Z on any other
/// (`0x00411A7B`).
fn fitTurn(ship: gameobj.Type) math.Axis {
    return switch (ship) {
        .mammoth, .sharov, .boridin => .x,
        else => {
            const number = std.math.cast(u8, @intFromEnum(ship)) orelse return .z;
            const under = create.donor(number) orelse return .z;
            return if (under == @intFromEnum(gameobj.Type.mammoth)) .x else .z;
        },
    };
}

/// `order_ripper_attach_cargo_pod_to_mammoth` (`0x00411420`): the Ripper flies astern to beside
/// the component and comes to rest, at full throttle beyond `slow_within`, then by `motion_plain`
/// at `slow_throttle` until within `attach_stop_within`; turns to face the component, and opens its
/// pincers (`grab_track`, played back). The pod stands where the Ripper's own was, its beams come
/// on over the step's time, heard (`tractor`), and the pod shows in place of the Ripper's own and
/// is enabled; then over a second the beams carry it onto the component, easing, and turn it to fit
/// (`fitTurn`) through the middle of the time, heard (`ripgrab`) as it arrives. The forearms draw
/// back (`ready_track`, played back), the cabin turns back (`cabin_track`), and once it is round
/// the Ripper turns to face `leave_by` behind it; then the pod is gone into the ship: the pod is
/// disabled and can't be aimed at, the component shows in its place, the Ripper carries nothing
/// and flies on (`motion_forward`), and it has its RipperDroppedObject. Should the pod or the
/// component go first, the Ripper gives up.
///
/// **Fix:** the game goes on as the Ripper carries nothing, and stops as it looks for what it
/// carries; OpenReliant gives up.
///
/// **Fix:** the game never clears the Ripper's `rippercargo` entry once the pod is fitted, so
/// `ripper_carried` keeps returning that pod: each later drop or fit by the same Ripper takes the
/// pod it fitted first out of the ship again, while the pod last grabbed stays hidden where it was
/// lifted, and RipperDroppedObject names the wrong pod. OpenReliant clears the entry
/// (`Rippers.release`), as Ripper end drop object does.
///
/// **Fix:** as the cabin turns back, the game waits for the root's first child, a forearm with no
/// `cabin_track` that the step before has already seen at rest, so the Ripper turns away while
/// its cabin is still turning. OpenReliant waits for the cabin (`cabinDone`), as Ripper end drop
/// object does.
///
/// **Improvement:** the pod is drawn on between the ticks as it is carried onto the component
/// (`create.Slot.glide`); the game draws it where each tick places it.
///
/// The slots stay hidden until then as the mission's script hides them, disabling the components
/// as it makes the ship (`DisableObject`, on a squad of them in mission 1).
pub fn attach(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.ripper_attach;
    const now = ctx.world.clock.frame_start;
    const rippers = world.rippers orelse return;
    const pod_at = rippers.carried(index) orelse return attachGiveUp(ctx, index);
    const pod = &all.slots[pod_at];
    const port = portOf(all, slot.orders[0].target) orelse return attachGiveUp(ctx, index);
    if (pod.model == null) return attachGiveUp(ctx, index);
    const grip = rippers.gripAt(state.grip);
    switch (state.step) {
        .starting => next(state, now),
        .approaching => {
            const flight = slot.flight orelse return;
            const at: Vector = state.beside;
            const reach = math.distance(at, slot.drawn.position);
            _ = ai.steer(world, index, at, approach_limit, ai.no_ease, .{});
            const toward = if (slot.motion == .backward) slot.drawn.position - at else at - slot.drawn.position;
            if (ai.turnFirst(flight, slot.drawn.orientation, reach, toward)) {
                object.throttle = 0;
                return;
            }
            if (reach > slow_within) {
                object.throttle = ai.full_throttle;
            } else if (reach > attach_stop_within) {
                slot.motion = .plain;
                object.throttle = slow_throttle;
            } else {
                object.throttle = 0;
            }
            if (!ai.Stillness.at_rest.inputsHeld(object, true)) return;
            slot.motion = .plain;
            if (!ai.Stillness.at_rest.ratesHeld(object)) return;
            object.letGo();
            next(state, now);
        },
        .facing => {
            _ = ai.steer(world, index, state.port, face_limit, ai.no_ease, .{});
            if (!ai.Stillness.at_rest.holds(object, false)) return;
            next(state, now);
            playAll(slot, open_pincers);
        },
        .opening => if (trackDone(slot)) {
            next(state, now);
            all.slots[port.ship].object.flags.thaw();
            const place = namedPlace(slot, cargo_part) orelse return attachGiveUp(ctx, index);
            state.from = place.position;
            state.from_angles = math.angles(place.orientation);
            objects.setPlace(&pod.object, &pod.drawn, place);
        },
        .reaching => {
            const t = @min(through(state.since, now, AttachStep.reaching.ticks()), 1);
            if (grip) |beams| beams.show(ease.in(0, 1, t));
            if (!over(state.since, now, AttachStep.reaching.ticks())) return;
            next(state, now);
            sound3d.playIn(world, null, null, pod_at, .tractor, 1, .not_reserved);
            showPart(pod, cargo_part, true);
            showPart(slot, cargo_part, false);
            pod.object.flags.disabled = false;
        },
        .fitting => {
            const share = through(state.since, now, AttachStep.fitting.ticks());
            if (grip) |beams| beams.show(1);
            const at = fittedAt(state, now);
            objects.setPosition(&pod.object, &pod.drawn, at);
            pod.glide = fittedAt(state, now + 1) - at;
            state.beside = port.place.point(.{ 0, standing_by, 0 });
            state.port = port.place.position;
            state.fitted_angles = math.angles(math.turned(port.place.orientation, fitTurn(all.slots[port.ship].object.type), fit_turn));
            const angles: [3]f32 = if (share < turn_from)
                state.from_angles
            else if (share < turn_until)
                ease.cosine(@as(Vector, state.from_angles), @as(Vector, state.fitted_angles), (share - turn_from) / (turn_until - turn_from))
            else
                state.fitted_angles;
            objects.setOrientation(&pod.object, &pod.drawn, math.fromAngleVector(angles));
            if (!over(state.since, now, AttachStep.fitting.ticks())) return;
            next(state, now);
            sound3d.playIn(world, null, null, pod_at, .ripgrab, 1, .not_reserved);
            playAll(slot, draw_forearms);
        },
        .releasing => if (trackDone(slot)) {
            next(state, now);
            playAll(slot, turn_cabin_back);
        },
        .turning => if (cabinDone(slot)) {
            next(state, now);
            state.away = slot.drawn.point(.{ 0, 0, -leave_by });
        },
        .facing_away => {
            _ = ai.steer(world, index, state.away, face_limit, ai.no_ease, .{});
            if (ai.Stillness.at_rest.holds(object, false)) next(state, now);
        },
        .fitted => {
            freeGrip(rippers, &state.grip);
            rippers.release(index);
            aigeneric.end(ctx, index);
            pod.object.flags.disabled = true;
            pod.object.flags.targetable = false;
            port.part.hidden = false;
            slot.motion = .forward;
            showPart(pod, cargo_part, false);
            object.flags.attached = false;
            events.ripperDropped(world, index, pod_at);
        },
        _ => {},
    }
}

/// Attaching ends, where the pod or the component is gone: the beams let go. The Ripper still
/// carries what it carried.
fn attachGiveUp(ctx: Context, index: u16) void {
    freeGrip(ctx.world.rippers, &ctx.world.objects.slots[index].state.ripper_attach.grip);
    aigeneric.end(ctx, index);
}

/// A mission of a Ripper at the origin, facing along Z, with its four pincers, its own pod and its
/// cabin; a cargo pod 1000 ahead of it; a ship with one component; and the Rippers' tables.
const TestRipper = struct {
    game: gameobj.testing.Mission,
    textures: *srtexture.testing.Textures,
    rippers: Rippers,
    ripper_model: objects.testing.NamedParts(6),
    pod_model: objects.testing.NamedParts(1),
    ship_model: objects.testing.NamedParts(1),
    ripper: u16,
    pod: u16,
    ship: u16,

    const pod_points = [_]Vector{ .{ -100, 0, 0 }, .{ -100, 0, 200 }, .{ 100, 0, 0 }, .{ 100, 0, 200 } };

    fn init(t: *TestRipper) !void {
        const gpa = std.testing.allocator;
        try t.game.init(gpa);
        errdefer t.game.deinit();
        t.textures = try srtexture.testing.Textures.init(gpa, &.{"laser2"});
        errdefer t.textures.deinit(gpa);
        t.rippers = try .init(gpa, &t.textures.table);
        t.ripper_model.init(pincers ++ [_][]const u8{ cargo_part, cabin_part }, @splat(.tractor), .{
            &.{.{ -50, 0, 0 }}, &.{.{ 50, 0, 0 }}, &.{.{ -50, 0, 100 }}, &.{.{ 50, 0, 100 }}, &pod_points, &.{},
        });
        t.pod_model.init(.{cargo_part}, .{.tractor}, .{&pod_points});
        t.ship_model.init(.{"Cargo slot"}, .{.tractor}, .{&.{}});
        // The player holds the first slot, and refuses these orders.
        _ = try t.game.add(.predator, .{ 0, 50000, 0 });
        t.ripper = try t.game.add(.ripper, @splat(0));
        try t.ripper_model.parts.fit(gpa, t.game.slot(t.ripper));
        t.game.slot(t.ripper).model.?.parts[4].hidden = true;
        t.pod = try t.game.add(.cargo_pod, .{ 0, 0, 1000 });
        try t.pod_model.parts.fit(gpa, t.game.slot(t.pod));
        t.ship = try t.game.add(.predator, .{ 0, 0, 50000 });
        try t.ship_model.parts.fit(gpa, t.game.slot(t.ship));
        const ship = t.game.slot(t.ship);
        ship.components[0] = &ship.model.?.parts[0];
        ship.object.component_count = 1;
        ship.model.?.parts[0].hidden = true;
        for ([_]u16{ t.ripper, t.pod, t.ship }) |index| {
            const slot = t.game.slot(index);
            slot.drawn = .{ .position = gameobj.vector(slot.object.root.position) };
        }
    }

    fn deinit(t: *TestRipper) void {
        t.rippers.deinit();
        t.textures.deinit(std.testing.allocator);
        t.game.deinit();
    }

    fn orders(t: *TestRipper) Context {
        var ctx = t.game.orders();
        ctx.world.rippers = &t.rippers;
        return ctx;
    }

    /// The object in slot `index` stands at `at`, turned as `orientation`.
    fn place(t: *TestRipper, index: u16, at: Vector, orientation: math.Matrix) void {
        const slot = t.game.slot(index);
        objects.setPlace(&slot.object, &slot.drawn, .{ .position = at, .orientation = orientation });
    }

    /// The Ripper's orders run once a tick for `ticks` ticks.
    fn run(t: *TestRipper, ticks: usize) void {
        for (0..ticks) |_| t.game.ordersAfter(t.orders(), t.ripper, 1);
    }

    /// The Ripper's current order, where it has one.
    fn doing(t: *TestRipper) ?Order {
        return if (t.game.slot(t.ripper).current()) |entry| entry.order else null;
    }
};

test "a Ripper grabs a pod ahead of it, and stows it aboard" {
    var t: TestRipper = undefined;
    try t.init();
    defer t.deinit();
    try std.testing.expect(try aigeneric.push(t.orders(), t.ripper, .ripper_grabs_target_object, .at(t.pod, null)));
    t.run(1);
    const ripper = t.game.slot(t.ripper);
    const pod = t.game.slot(t.pod);
    // Nothing harms the pod while it is carried; the Ripper flies by the plain model, held.
    try std.testing.expectEqual(.full, pod.object.invulnerable);
    try std.testing.expect(ripper.object.flags.attached);
    try std.testing.expectEqual(motion.Motion.plain, ripper.motion.?);
    // Its beams come from its four pincers, and reach for the middles of the pod's point pairs.
    const grip = t.rippers.gripAt(ripper.state.ripper_grab.grip).?;
    for (grip.beams) |beam| try std.testing.expect(beam != null);
    try std.testing.expectEqual(@as(Vector, .{ -100, 0, 100 }), grip.targets[0].?.point);
    try std.testing.expectEqual(@as(Vector, .{ 100, 0, 100 }), grip.targets[1].?.point);
    // At rest within reach, the beams come on, as the square of the time.
    t.run(76);
    try std.testing.expectEqual(GrabStep.reaching, ripper.state.ripper_grab.step);
    try std.testing.expect(grip.shown);
    try std.testing.expectApproxEqAbs(0.25, grip.beams[0].?.colours[1][3], 0.02);
    // Halfway through the lift, the pod is a quarter of the way to 300 off the Ripper.
    t.run(75 + 150);
    try std.testing.expectEqual(GrabStep.lifting, ripper.state.ripper_grab.step);
    try std.testing.expectApproxEqAbs(1000 - 700 * 0.25, pod.drawn.position[2], 5);
    // It is drawn on between the ticks, a tick's worth of the lift.
    try std.testing.expectApproxEqAbs(-700 * 0.5 / @as(f32, @floatFromInt(GrabStep.lifting.ticks())), pod.glide[2], 1e-3);
    t.run(2000);
    // Aboard: the Ripper carries it, its own pod shows in its place, and it flies astern.
    try std.testing.expectEqual(null, t.doing());
    try std.testing.expectEqual(t.pod, t.rippers.carried(t.ripper).?);
    try std.testing.expectApproxEqAbs(300, pod.drawn.position[2], 1);
    try std.testing.expect(pod.object.flags.disabled);
    try std.testing.expect(pod.model.?.parts[0].hidden);
    try std.testing.expect(!ripper.model.?.parts[4].hidden);
    try std.testing.expectEqual(Invulnerability.none, pod.object.invulnerable);
    try std.testing.expectEqual(motion.Motion.backward, ripper.motion.?);
    try std.testing.expect(!ripper.object.flags.attached);
    // Its beams are let go.
    for (t.rippers.grips) |held| try std.testing.expectEqual(null, held);
}

test "a Ripper lets its pod go where it stands, and backs away from it" {
    var t: TestRipper = undefined;
    try t.init();
    defer t.deinit();
    t.rippers.hold(t.ripper, t.pod);
    const ripper = t.game.slot(t.ripper);
    const pod = t.game.slot(t.pod);
    pod.object.flags.disabled = true;
    pod.model.?.parts[0].hidden = true;
    ripper.model.?.parts[4].hidden = false;
    t.place(t.ripper, .{ 0, 0, 5000 }, math.identity);
    try std.testing.expect(try aigeneric.push(t.orders(), t.ripper, .make_ripper_drop_what_its_carrying, .none));
    // At rest, it opens its pincers and lets go: the pod stands where its own was.
    t.run(3);
    try std.testing.expectEqual(Order.ripper_end_drop_object, t.doing().?);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 5000 }), pod.drawn.position);
    try std.testing.expect(!pod.model.?.parts[0].hidden);
    try std.testing.expect(ripper.model.?.parts[4].hidden);
    // It backs away astern, and turns its cabin back.
    t.run(3);
    try std.testing.expectEqual(motion.Motion.backward, ripper.motion.?);
    try std.testing.expectEqual(backing_throttle, ripper.object.throttle);
    t.run(60);
    try std.testing.expectEqual(EndDropStep.facing, ripper.state.ripper_end_drop.step);
    try std.testing.expectEqual(0, ripper.object.throttle);
    // Still flying astern, it turns its tail to the point it noted ahead of it; then it carries
    // nothing, and flies on.
    try std.testing.expectEqual(1, @abs(ripper.object.yaw_input));
    t.place(t.ripper, ripper.drawn.position, math.rotation(.y, std.math.pi));
    t.run(2);
    try std.testing.expectEqual(null, t.doing());
    try std.testing.expectEqual(null, t.rippers.carried(t.ripper));
    try std.testing.expectEqual(motion.Motion.forward, ripper.motion.?);
    try std.testing.expectEqual(gameobj.Slot.none, ripper.object.passes_through[0]);
}

test "a Ripper told to drop its pod onto a ship's component fits it there" {
    var t: TestRipper = undefined;
    try t.init();
    defer t.deinit();
    t.rippers.hold(t.ripper, t.pod);
    const ripper = t.game.slot(t.ripper);
    const pod = t.game.slot(t.pod);
    const ship = t.game.slot(t.ship);
    pod.object.flags.disabled = true;
    // The ship's up points back along Z, so the Ripper stops 2500 short of the component on its
    // line, which it faces from there; it comes astern, so it stands 200 beyond, facing away.
    const port: Vector = .{ 0, 0, 50000 };
    t.place(t.ship, port, math.rotation(.x, -std.math.pi / 2.0));
    t.place(t.ripper, port - @as(Vector, .{ 0, 0, 2300 }), math.identity);
    try std.testing.expect(try aigeneric.push(t.orders(), t.ripper, .make_ripper_drop_what_its_carrying, .at(t.ship, 0)));
    t.run(1);
    try std.testing.expectEqual(Order.ripper_attach_cargo_pod_to_mammoth, t.doing().?);
    t.run(1);
    const state = &ripper.state.ripper_attach;
    try std.testing.expectApproxEqAbs(port[2] - 2500, state.beside[2], 1e-2);
    try std.testing.expectEqual(port, @as(Vector, state.port));
    try std.testing.expect(t.rippers.gripAt(state.grip).?.targets[0] != null);
    // It comes to rest, faces the component and opens its pincers; the pod stands where its own
    // was, shows as the beams come on, and is carried onto the component.
    t.run(10);
    try std.testing.expectEqual(AttachStep.reaching, state.step);
    t.run(160);
    try std.testing.expectEqual(AttachStep.fitting, state.step);
    try std.testing.expect(!pod.object.flags.disabled);
    try std.testing.expect(!pod.model.?.parts[0].hidden);
    // Carried onto the component, it is drawn on toward it between the ticks.
    t.run(500);
    try std.testing.expect(math.dot(pod.glide, port - pod.drawn.position) > 0);
    // The forearms in, it waits for its cabin to turn round before it turns away.
    ripper.model.?.parts[5].animation.time = 100;
    t.run(510);
    try std.testing.expectEqual(AttachStep.turning, state.step);
    ripper.model.?.parts[5].animation.time = 0;
    t.run(1);
    try std.testing.expectEqual(AttachStep.facing_away, state.step);
    try std.testing.expectApproxEqAbs(0, math.distance(pod.drawn.position, port), 1);
    // A quarter turn back about the component's Z, a ship not being a Mammoth.
    const fitted = math.turned(ship.drawn.orientation, .z, fit_turn);
    try math.testing.expectMatrixWithin(fitted, pod.drawn.orientation, 1e-4);
    // Turned away, it leaves the pod in the ship: the component shows in its place.
    t.place(t.ripper, ripper.drawn.position, math.rotation(.y, std.math.pi));
    t.run(2);
    try std.testing.expectEqual(null, t.doing());
    try std.testing.expect(pod.object.flags.disabled);
    try std.testing.expect(!pod.object.flags.targetable);
    try std.testing.expect(!ship.model.?.parts[0].hidden);
    try std.testing.expect(pod.model.?.parts[0].hidden);
    try std.testing.expectEqual(motion.Motion.forward, ripper.motion.?);
    for (t.rippers.grips) |held| try std.testing.expectEqual(null, held);
    // It carries nothing from then on, so the next pod it grabs is the one it drops next.
    try std.testing.expectEqual(null, t.rippers.carried(t.ripper));
    t.rippers.hold(t.ripper, t.ship);
    try std.testing.expectEqual(t.ship, t.rippers.carried(t.ripper).?);
}

test "a Ripper told to drop its pod onto a ship passes its target on as a ship's" {
    var t: TestRipper = undefined;
    try t.init();
    defer t.deinit();
    // Whatever kind its target is and whatever component it names, the halves go on as they are.
    const named: aigeneric.Target = .{ .kind = .flight_group, .index = @intCast(t.ship), .component = -2 };
    try std.testing.expect(try aigeneric.push(t.orders(), t.ripper, .make_ripper_drop_what_its_carrying, named));
    drop(t.orders(), t.ripper);
    const entry = t.game.slot(t.ripper).current().?;
    try std.testing.expectEqual(Order.ripper_attach_cargo_pod_to_mammoth, entry.order);
    try std.testing.expectEqual(named.asShip(), entry.target);
    try std.testing.expectEqual(-2, entry.target.component);
}

test "a Ripper gives up its grab where the object goes" {
    var t: TestRipper = undefined;
    try t.init();
    defer t.deinit();
    const ripper = t.game.slot(t.ripper);
    ripper.motion = .backward;
    try std.testing.expect(try aigeneric.push(t.orders(), t.ripper, .ripper_grabs_target_object, .at(t.pod, null)));
    t.run(77);
    try std.testing.expectEqual(GrabStep.reaching, ripper.state.ripper_grab.step);
    // The pod explodes: the beams let go, the Ripper is held no more, and flies as it did.
    t.game.slot(t.pod).object.flags.exploding = true;
    t.run(1);
    try std.testing.expectEqual(null, t.doing());
    for (t.rippers.grips) |held| try std.testing.expectEqual(null, held);
    try std.testing.expect(!ripper.object.flags.attached);
    try std.testing.expectEqual(motion.Motion.backward, ripper.motion.?);
}

test "a Ripper gives up fitting a pod where the component goes or it carries nothing" {
    var t: TestRipper = undefined;
    try t.init();
    defer t.deinit();
    t.rippers.hold(t.ripper, t.pod);
    const ship = t.game.slot(t.ship);
    try std.testing.expect(try aigeneric.push(t.orders(), t.ripper, .make_ripper_drop_what_its_carrying, .at(t.ship, 0)));
    t.run(2);
    try std.testing.expectEqual(Order.ripper_attach_cargo_pod_to_mammoth, t.doing().?);
    // The component gone, the beams let go and the order ends; the Ripper still carries the pod.
    ship.components[0] = null;
    t.run(1);
    try std.testing.expectEqual(null, t.doing());
    for (t.rippers.grips) |held| try std.testing.expectEqual(null, held);
    try std.testing.expectEqual(t.pod, t.rippers.carried(t.ripper).?);
    // Carrying nothing, it gives up as well.
    ship.components[0] = &ship.model.?.parts[0];
    t.rippers.release(t.ripper);
    try std.testing.expect(try aigeneric.push(t.orders(), t.ripper, .make_ripper_drop_what_its_carrying, .at(t.ship, 0)));
    t.run(2);
    try std.testing.expectEqual(null, t.doing());
    for (t.rippers.grips) |held| try std.testing.expectEqual(null, held);
}

test "a Ripper's beams are taken, let go, and let go again harmlessly" {
    var t: TestRipper = undefined;
    try t.init();
    defer t.deinit();
    const world = t.orders().world;
    var grip = t.rippers.takeFor(world, t.ripper, t.pod);
    const place = grip.place().?;
    try std.testing.expect(t.rippers.gripAt(grip).?.targets[0] != null);
    freeGrip(&t.rippers, &grip);
    try std.testing.expectEqual(GripRef.none, grip);
    try std.testing.expectEqual(null, t.rippers.grips[place]);
    freeGrip(&t.rippers, &grip);
    try std.testing.expectEqual(null, t.rippers.gripAt(grip));
    // Aimed at nothing, the beams reach for nothing.
    var unaimed = t.rippers.takeFor(world, t.ripper, null);
    try std.testing.expectEqual(null, t.rippers.gripAt(unaimed).?.targets[0]);
    // A grip past the tables names none, and letting it go leaves them be.
    var past: GripRef = @enumFromInt(capacity);
    try std.testing.expectEqual(null, t.rippers.gripAt(past));
    freeGrip(&t.rippers, &past);
    try std.testing.expectEqual(GripRef.none, past);
    try std.testing.expect(t.rippers.gripAt(unaimed) != null);
    // Without the tables, a grip is only forgotten.
    freeGrip(null, &unaimed);
    try std.testing.expectEqual(GripRef.none, unaimed);
    // The last set's place is followed by the first's.
    t.rippers.next_grip = capacity - 1;
    var last = t.rippers.takeFor(world, t.ripper, null);
    try std.testing.expectEqual(capacity - 1, last.place().?);
    try std.testing.expectEqual(0, t.rippers.next_grip);
    freeGrip(&t.rippers, &last);
}

test "Rippers.draw" {
    const gpa = std.testing.allocator;
    var t: TestRipper = undefined;
    try t.init();
    defer t.deinit();
    const ripper = t.game.slot(t.ripper);
    ripper.model.?.place(ripper.drawn.position, ripper.drawn.orientation);
    try std.testing.expect(try aigeneric.push(t.orders(), t.ripper, .ripper_grabs_target_object, .at(t.pod, null)));
    t.run(77);
    const grip = t.rippers.gripAt(ripper.state.ripper_grab.grip).?;
    try std.testing.expect(grip.shown);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    // Each of the four beams goes into the world, once for the frame it is shown.
    try t.rippers.draw(gpa, &scene, t.game.objects);
    try std.testing.expectEqual(pincers.len, scene.layers.get(.world).items.len);
    try std.testing.expect(!grip.shown);
    // Each stands at its pincer's point and faces the middle of its pair of the pod's points, in
    // the pod's place: the first two the first pair's, the last two the second's.
    const pod = t.game.slot(t.pod).drawn;
    const points = [_]Vector{ .{ -50, 0, 0 }, .{ 50, 0, 0 }, .{ -50, 0, 100 }, .{ 50, 0, 100 } };
    for (grip.beams, points, 0..) |made, point, n| {
        const beam = made.?;
        try std.testing.expectEqual(point, beam.object.position);
        const middle = pod.point(grip.targets[n / beams_per_pair].?.point);
        try std.testing.expectApproxEqAbs(1, math.dot(math.forward(beam.object.orientation), math.normalize(middle - point)), 1e-5);
    }
    scene.clear();
    try t.rippers.draw(gpa, &scene, t.game.objects);
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
}

test hungFrom {
    var t: TestRipper = undefined;
    try t.init();
    defer t.deinit();
    const all = t.game.objects;
    // A pod's part hangs from the root: the pod's own place, framed or not.
    t.place(t.pod, .{ 0, 0, 7000 }, math.identity);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 7000 }), hungFrom(all, t.pod, 0).?.position);
    // A part that hangs from another: that one's frame, from the root.
    const model = &t.game.slot(t.ripper).model.?;
    model.parts[1].parent = 0;
    model.parts[0].origin = .{ 0, 10, 0 };
    t.place(t.ripper, .{ 0, 0, 500 }, math.identity);
    try std.testing.expectEqual(@as(Vector, .{ 0, 10, 500 }), hungFrom(all, t.ripper, 1).?.position);
    // No such part.
    try std.testing.expectEqual(null, hungFrom(all, t.ripper, model.parts.len));
}

test "what a Ripper carries is the first it holds, until it lets that go" {
    var t: TestRipper = undefined;
    try t.init();
    defer t.deinit();
    try std.testing.expectEqual(null, t.rippers.carried(t.ripper));
    t.rippers.hold(t.ripper, t.pod);
    t.rippers.hold(t.ripper, t.ship);
    try std.testing.expectEqual(t.pod, t.rippers.carried(t.ripper).?);
    t.rippers.release(t.ripper);
    try std.testing.expectEqual(t.ship, t.rippers.carried(t.ripper).?);
}

test fitTurn {
    try std.testing.expectEqual(math.Axis.x, fitTurn(.mammoth));
    try std.testing.expectEqual(math.Axis.x, fitTurn(.sharov));
    try std.testing.expectEqual(math.Axis.x, fitTurn(.boridin));
    // The Mammoth under another number.
    try std.testing.expectEqual(math.Axis.x, fitTurn(@enumFromInt(0xE3)));
    try std.testing.expectEqual(math.Axis.z, fitTurn(.stalag));
    try std.testing.expectEqual(math.Axis.z, fitTurn(.stand_in));
}

test {
    std.testing.refAllDecls(@This());
}
