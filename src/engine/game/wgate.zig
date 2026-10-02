//! `C:\lancer\game\wgate.cpp`: the gates' tunnels. A Coalition gate stands with a tunnel open in
//! it from the start, and Fixed Gate Open grows one at any object, a nav point among them; each is
//! a record of the gates (`Gates`), drawn each frame as a funnel of rings that sways and scrolls
//! (`Gates.draw`). A ship jumps out through the nearest tunnel (Fixed Gate Jump Out), the player's
//! riding the worm between gates, and jumps in through its order's (Fixed Gate Jump In), a portal
//! at the tunnel's throat cutting it as it passes. Fixed Gate Close shrinks a tunnel away, and
//! Fixed Gate Collapse brings a gate down. The tunnels' meshes and the flashes' are in
//! `wgate/tunnel.zig`, the worm's in `wgate/worm.zig`. [Gates](../../../docs/engine/gates.md)
//! describes them.
//!
//! Not ported: the warps' tunnels (kind 0, `order_warp_out`, `order_warp_in`), with their
//! particles and beams ([#481](https://github.com/vdmkenny/openreliant/issues/481)); the Boridin's
//! projection (kind 3, `order_start_warp_projection_from_boridin`)
//! ([#30](https://github.com/vdmkenny/openreliant/issues/30)); and the Krasny's split, as it jumps
//! in through the gate collapsing behind it in missions 16 and 66 (`0x00422CA0`)
//! ([#407](https://github.com/vdmkenny/openreliant/issues/407)).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const engine = @import("../../engine.zig");
const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const ease = @import("../genilib/interf/ease.zig");
const libcmt = @import("../libcmt.zig");
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const create = @import("create.zig");
const events = @import("mission/events.zig");
const explode = @import("explode.zig");
const Detail = explode.Detail;
const gameobj = @import("gameobj.zig");
const matmanager = @import("matmanager.zig");
const objects = @import("objects.zig");
const sound3d = @import("sound3d.zig");
const xtrabits = @import("xtrabits.zig");

pub const tunnel = @import("wgate/tunnel.zig");
pub const worm = @import("wgate/worm.zig");
pub const Kind = tunnel.Kind;
pub const Tunnels = tunnel.Tunnels;
const Grid = tunnel.Grid;
const Tunnel = tunnel.Tunnel;
const Square = tunnel.Square;
const Worm = worm.Worm;

const log = std.log.scoped(.wgate);

/// The records the gates keep (`0x0051D1A4`, 32 of them), each flagged in use in `0x0051D224`.
pub const max_records = 32;

/// How the gates are shown.
pub const Settings = struct {
    tunnels: Tunnels = .fine,
    rumbles: Rumbles = .steady,

    /// The original's: tunnels on its grid, and a ride through the worm that may rumble each frame.
    pub const original: Settings = .{ .tunnels = .original, .rumbles = .original };
};

/// How often the ride through the worm rumbles: the view shaking and flashing, and heard.
pub const Rumbles = enum {
    /// **Improvement:** a chance of `rumble_chance` for each of the simulation's steps, 25 a
    /// second, the ride rumbling on a frame where any comes up, so that it rumbles as often
    /// whatever the frame rate: as the game does at 25 frames a second.
    steady,
    /// A chance of `rumble_chance` each frame, as the game has it, so that the ride rumbles the
    /// more often the higher the frame rate.
    original,
};

/// The gates' state, `wgate.cpp`'s globals: the textures, the grid its tunnels are built on, its
/// records, and the worm the player's ship rides between gates.
pub const Gates = struct {
    gpa: Allocator,
    /// The tunnels' texture (`0x0051D1A0`): `warp128`, or `ddwarp128` without a hardware renderer.
    warp: *srtexture.Image,
    /// The jumps' flashes' texture (`warpin3`).
    flash: *srtexture.Image,
    /// Whether a hardware renderer draws them, which gives the tunnels their colours and their
    /// highlight (`tunnel.Tunnel.build`).
    hardware: bool,
    /// The grid the options' detail gives the tunnels (`0x0051D198`, `0x0051D128`).
    grid: Grid,
    settings: Settings,
    records: [max_records]?*Record = @splat(null),
    /// `0x0051D13C`: set while a ship jumps out through a tunnel, which the next waits for.
    exiting: bool = false,
    /// `0x0051D13E`: set while the player's ship rides the worm, which hides the gates' tunnels.
    riding: bool = false,
    /// `0x0051D19C`: the worm the player's ship rides between gates.
    worm: ?*Worm = null,
    /// Whether the worm is in this frame's scene, as Jump Out puts it for the player's ship.
    worm_shown: bool = false,
    /// `0x004E3F68`: where the next ship to jump in comes out, turned `spread_step` about the
    /// tunnel's axis for each step, from -2 to 2. It starts at -2 as the game does, and nothing
    /// sets it back between missions.
    spread: i32 = -2,
    /// The tick the ride's rumbles were last drawn for, in the steady style (`Rumbles`).
    rumbled_at: i32 = 0,

    /// The gates' start (`0x0041E280`), without the warps' textures and particles
    /// ([#481](https://github.com/vdmkenny/openreliant/issues/481)) and the Boridin's
    /// ([#30](https://github.com/vdmkenny/openreliant/issues/30)): the tunnels' texture, the
    /// flashes', and the grid by `detail`.
    pub fn init(gpa: Allocator, textures: *srtexture.Table, detail: Detail, hardware: bool, settings: Settings) matmanager.Error!Gates {
        return .{
            .gpa = gpa,
            .warp = try matmanager.textureRequire(textures, if (hardware) warp_texture else software_warp_texture),
            .flash = try matmanager.textureRequire(textures, flash_texture),
            .hardware = hardware,
            .grid = .of(detail),
            .settings = settings,
        };
    }

    /// The gates' end with a mission (`0x0041E4A0`) and their start with the next: every record
    /// and the worm let go, and nothing jumping.
    ///
    /// **Fix:** the game makes the worm anew for each of the player's jumps out and never lets the
    /// last one go; OpenReliant lets it go with the rest.
    pub fn reset(gates: *Gates) void {
        for (0..max_records) |index| gates.free(index);
        if (gates.worm) |tube| tube.destroy(gates.gpa);
        gates.worm = null;
        gates.worm_shown = false;
        gates.exiting = false;
        gates.riding = false;
    }

    pub fn deinit(gates: *Gates) void {
        gates.reset();
    }

    /// `0x00420920`: the first record whose tunnel stands at the object in slot `index`.
    pub fn of(gates: *const Gates, index: u16) ?*Record {
        for (gates.records) |held| {
            const record = held orelse continue;
            if (record.slot == index) return record;
        }
        return null;
    }

    /// `0x0041FE60`: a record for a tunnel of `kind` at the object in slot `index`, in the first
    /// free place, standing at `at` in the object's frame and turned a half turn about its Y axis,
    /// fully open, every vertex of it as much deeper as the object's type has it (`depthOf`); null
    /// where every place is taken, or for a kind not ported.
    pub fn make(gates: *Gates, world: gameobj.World, index: u16, kind: Kind, at: Vector) Allocator.Error!?*Record {
        switch (kind) {
            .proto, .advanced => {},
            .warp, .boridin => {
                log.warn("the tunnel of kind {s} at object {d} is left out: it is not ported", .{ @tagName(kind), index });
                return null;
            },
        }
        const place = for (&gates.records) |*held| {
            if (held.* == null) break held;
        } else return null;
        const record = try gates.gpa.create(Record);
        errdefer gates.gpa.destroy(record);
        const now = world.clock.frame_start;
        record.* = .{
            .kind = kind,
            .slot = index,
            .made_at = now,
            .drawn_at = now,
            .deeper = depthOf(world.objects.slots[index].object.type),
            .at = at,
            .tunnel = undefined,
            .squares = undefined,
        };
        try record.tunnel.build(gates.gpa, gates.grid, gates.settings.tunnels.split(), gates.hardware, gates.warp, kind, tunnelSize(kind, world.objects.mission_number));
        errdefer record.tunnel.deinit(gates.gpa);
        try record.squares[0].build(gates.gpa, gates.flash);
        errdefer record.squares[0].deinit(gates.gpa);
        try record.squares[1].build(gates.gpa, gates.flash);
        place.* = record;
        return record;
    }

    /// `0x00420830`: lets record `index` go, where it is in use.
    pub fn free(gates: *Gates, index: usize) void {
        const record = gates.records[index] orelse return;
        record.tunnel.deinit(gates.gpa);
        for (&record.squares) |*square| square.deinit(gates.gpa);
        gates.gpa.destroy(record);
        gates.records[index] = null;
    }

    /// `free` for the record `record` is.
    fn freeRecord(gates: *Gates, record: *const Record) void {
        for (gates.records, 0..) |held, index| {
            if (held == record) return gates.free(index);
        }
    }

    /// Whether the ride through the worm rumbles on the frame at tick `now`: where a number drawn
    /// from `random` comes up, `rumble_chance` of the time, once a frame as the game draws it; or
    /// in the steady style once for each simulation step since the last were drawn (`Rumbles`).
    fn rumbles(gates: *Gates, random: *libcmt.Rand, now: i32) bool {
        const draws: u32 = switch (gates.settings.rumbles) {
            .original => 1,
            .steady => gameobj.stepsDue(&gates.rumbled_at, now),
        };
        var rumbled = false;
        for (0..draws) |_| {
            if (random.fraction() < rumble_chance) rumbled = true;
        }
        return rumbled;
    }

    /// The gates' frame (`0x00420A00`), which `shield_bubbles_draw` runs before the bubbles, for
    /// each record of a fixed gate in turn: its tunnel's rings sway by its time since it was made
    /// (`recordTime`), a radian every 10 seconds, and the tunnel takes its shape, its lighting and
    /// its bounds from them (`tunnel.Tunnel.reshape`). Its portal goes into the world's layer, and
    /// its tunnel too unless the player's ship rides the worm. Before them go the flashes a ship
    /// jumping in shows (`jumpIn`), and after them the worm while the player's ship rides it
    /// (`jumpOut`).
    ///
    /// Where the game has the tunnel's frame hang from the object's and its portal's from the
    /// tunnel's, OpenReliant places them from where the object is drawn. The game scrolls the
    /// tunnel's texture as it draws it (`0x00420950`), which OpenReliant does here
    /// (`Record.scroll`). The game also has each ship in a list at `+0x80` dent the tunnel as it
    /// passes (`wgate_tunnel_dent`, `0x00422540`), and nothing fills the list.
    pub fn draw(gates: *Gates, gpa: Allocator, scene: *srcore.Scene, all: *const create.Objects, frame_start: i32) Allocator.Error!void {
        for (gates.records) |held| {
            const record = held orelse continue;
            record.drawn_at = frame_start;
            record.tunnel.reshape(record.kind, recordTime(record.made_at, frame_start), frame_start, record.deeper);
            const place = record.tunnelPlace(all);
            record.tunnel.object.position = place.position;
            record.tunnel.object.orientation = place.orientation;
            record.portal.position = place.point(record.portal_at);
            record.portal.orientation = place.orientation;
            record.scroll(frame_start);
            if (record.squares_shown) {
                record.squares_shown = false;
                for (&record.squares) |*square| {
                    square.object.position = place.point(.{ 0, 0, square.depth });
                    square.object.orientation = place.orientation;
                    try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &square.object }, .world);
                }
            }
            try xtrabits.sceneAdd(gpa, scene, .{ .portal = &record.portal }, .world);
            if (!gates.riding) try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &record.tunnel.object }, .world);
        }
        if (gates.worm_shown) if (gates.worm) |tube| {
            gates.worm_shown = false;
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &tube.object }, .world);
        };
    }
};

/// The textures (`0x004E3FA4`, `0x004E3FB8`, `0x004E1C2C`).
const warp_texture = "warp128";
const software_warp_texture = "ddwarp128";
const flash_texture = "warpin3";

/// The time from tick `from` to `now` as the gates count it (`gameobj.progress_per_tick`), the
/// ticks taken unsigned as the game takes a record's (`0x00420A00`, `0x00420950`, `0x00421940`,
/// `0x00421B80`).
fn recordTime(from: i32, now: i32) f32 {
    const ticks: u32 = @bitCast(now -% from);
    return @as(f32, @floatFromInt(ticks)) * gameobj.progress_per_tick;
}

/// A tunnel's size, which scales its radii: the prototype's 70, the advanced gate's 40, and 70
/// again in mission 8 (`0x0041FE60`). A warp's radius takes no size (`tunnel.ringRadius`), and
/// `Gates.make` leaves the warps and the Boridin out.
fn tunnelSize(kind: Kind, mission_number: u16) f32 {
    return switch (kind) {
        .advanced => if (mission_number == wide_advanced_mission) proto_size else advanced_size,
        .proto, .warp, .boridin => proto_size,
    };
}

const proto_size: f32 = 70;
const advanced_size: f32 = 40;
const wide_advanced_mission = 8;

/// `wgate_warp_size_table` (`0x004E3F38`): the types of object whose tunnels stand deeper, with
/// how much deeper every vertex stands (`+0x1C`) and a warp's size (`+0x18`), which
/// `wgate_create` (`0x0041FE60`) looks up for every kind (`wgate_warp_sizes`, `0x00423020`). Any
/// other type's stand no deeper, and its warp's size is 2000. The size and the flag the game sets
/// beside it (`+0x2C`) serve the warps alone
/// ([#481](https://github.com/vdmkenny/openreliant/issues/481)).
const warp_sizes = [_]WarpSize{
    .{ .type = .badanov, .depth = 15000, .size = 10000 },
    .{ .type = .yamato, .depth = 100000, .size = 50000 },
};

const WarpSize = struct { type: gameobj.Type, depth: f32, size: f32 };

/// `wgate_warp_sizes` (`0x00423020`) for the depth: how much deeper every vertex of a tunnel at an
/// object of `object_type` stands (`warp_sizes`), 0 for a type not listed.
fn depthOf(object_type: gameobj.Type) f32 {
    for (warp_sizes) |entry| {
        if (entry.type == object_type) return entry.depth;
    }
    return 0;
}

/// A record of the gates (`0x88` bytes): a tunnel at an object, its portal, and the two flashes a
/// ship jumping in through it shows.
pub const Record = struct {
    kind: Kind,
    /// The object it stands at (`+0x14`).
    slot: u16,
    /// The frame's tick it was made on (`+0x08`), and the tick of the last frame that drew it
    /// (`+0x0C`), which Open, Close and Collapse count their time from.
    made_at: i32,
    drawn_at: i32,
    /// The tick of the last frame that scrolled its texture (`+0x10`), 0 until one has.
    scrolled_at: i32 = 0,
    /// How much deeper than its ring every vertex of its tunnel stands, by its object's type
    /// (`+0x1C`, `depthOf`).
    deeper: f32 = 0,
    /// How far Open or Close has grown or shrunk it (`+0x20`).
    progress: f32 = 0,
    /// Where its tunnel stands in the object's frame.
    at: Vector,
    tunnel: Tunnel,
    /// `+0x70`: what cuts a ship jumping through it, where it stands in the tunnel's frame
    /// (`portalSetUp`), and whether its flashes are in this frame's scene (`+0x74`, `+0x78`).
    portal: srapiext.Portal = .{},
    portal_at: Vector = @splat(0),
    squares: [2]Square,
    squares_shown: bool = false,
    /// `+0x84`: set while a ship comes through it, until it is half way, which the next waits for.
    busy: bool = false,

    /// Where its tunnel stands in the world: at `at` in its object's frame, as the object is
    /// drawn, turned a half turn about its Y axis.
    pub fn tunnelPlace(record: *const Record, all: *const create.Objects) math.Place {
        const turned: math.Place = .{ .position = record.at, .orientation = tunnel_turn };
        return turned.within(all.slots[record.slot].drawn);
    }

    /// `0x0041FDF0`: its portal faces along the tunnel's axis, at the throat's ring
    /// (`tunnel.Tunnel.throat`) as the tunnel stands now.
    fn portalSetUp(record: *Record) void {
        record.portal.normal = .{ 0, 0, 1 };
        record.portal_at = record.tunnel.throat();
    }

    /// `0x00420950`: its tunnel's texture scrolls by the time since it last did (`recordTime`,
    /// `tunnel.Tunnel.scroll`), from `scrolled_at`, which moves on; the first time it only notes
    /// the tick.
    fn scroll(record: *Record, frame_start: i32) void {
        if (record.scrolled_at != 0) record.tunnel.scroll(recordTime(record.scrolled_at, frame_start));
        record.scrolled_at = frame_start;
    }
};

/// How a tunnel stands in its object's frame: a half turn about the Y axis (`0x0041FE60`).
const tunnel_turn = math.fromAngles(0, std.math.pi, 0);

// --- The orders ---------------------------------------------------------------------------

/// What the gates' orders keep in the object's order state.
pub const State = extern struct {
    _unknown_00: u32,
    /// Its step (`+0x04`), the order's own.
    step: Step,
    /// The frame's tick of its last update (`+0x08`), which `progress` counts from.
    updated: i32,
    /// How far through its step it is (`+0x0C`).
    progress: f32,
    /// Jump In: whether it has let the tunnel go for the next ship (`+0x10`).
    let_go: bool,
    _unknown_11: [3]u8,
    /// Collapse: how many of its fireballs have gone off (`+0x14`).
    fireballs: i32,
    /// Jump In: whether it moves in a straight line, rather than easing in and out (`+0x18`).
    linear: bool,
    _unknown_19: [3]u8,
    /// Jump In: where it comes from, deep in the tunnel (`+0x1C`); where it goes, out beyond the
    /// mouth for Jump In and down the tunnel for Jump Out (`+0x28`).
    from: shp.Vec3,
    to: shp.Vec3,
    /// The portal that cuts it (`+0x34`), its record's (`+0x70`). OpenReliant reaches the portal
    /// through the record, as `jump.effect.Record` does its scene objects.
    portal: engine.Pointer(anyopaque),

    comptime {
        assert(@offsetOf(State, "step") == 0x04);
        assert(@offsetOf(State, "updated") == 0x08);
        assert(@offsetOf(State, "progress") == 0x0C);
        assert(@offsetOf(State, "let_go") == 0x10);
        assert(@offsetOf(State, "fireballs") == 0x14);
        assert(@offsetOf(State, "linear") == 0x18);
        assert(@offsetOf(State, "from") == 0x1C);
        assert(@offsetOf(State, "to") == 0x28);
        assert(@offsetOf(State, "portal") == 0x34);
        assert(@sizeOf(State) == 0x38);
    }

    /// Moves on to `step`, `progress` from nothing.
    fn next(state: *State, step: Step) void {
        state.step = step;
        state.progress = 0;
    }
};

/// The step of a gate's order, in the word the game keeps it in: Jump In's, Jump Out's, the
/// swing's of Open and Close, or Collapse's.
pub const Step = extern union {
    in: InStep,
    out: OutStep,
    swing: SwingStep,
    collapse: CollapseStep,
};

/// The steps of Jump In.
pub const InStep = enum(u32) {
    /// Waiting for the tunnel to be free.
    waiting = 0,
    coming = 1,
    done = 2,
    _,
};

/// The steps of Jump Out.
pub const OutStep = enum(u32) {
    /// Waiting for the last ship to go through.
    waiting = 0,
    /// Drawn down the tunnel.
    entering = 1,
    /// Gone, the player's ship riding the worm.
    riding = 2,
    done = 3,
    /// OpenReliant's: no gate has a tunnel to go out through, and the order ends.
    stranded = 4,
    _,
};

/// Where `local`, in the tunnel's frame, stands in the world.
fn inTunnel(record: *const Record, all: *const create.Objects, local: Vector) Vector {
    return record.tunnelPlace(all).point(local);
}

/// The gate the current order of the ship in slot `index` names, and its record; null, logged,
/// for none.
fn aimed(gates: *const Gates, all: *const create.Objects, index: u16) ?Aimed {
    const gate = all.slots[index].orders[0].target.slotIn(all) orelse {
        log.warn("Bug in script - in a \"set_ai\" with ai function \"fixedgate_jump_in\", the target is NULL.  Sort it out!", .{});
        return null;
    };
    const record = gates.of(gate) orelse {
        log.warn("object {d} has no gate to jump through at object {d}", .{ index, gate });
        return null;
    };
    return .{ .gate = gate, .record = record };
}

/// The gate a ship's order names, in its slot, and the record of its tunnel.
const Aimed = struct { gate: u16, record: *Record };

/// `order_fixed_gate_jump_in_init` (`0x00420B80`): the ship in slot `index` comes in through the
/// tunnel at the object its order names. The portal cuts it (`xtrabits.clipTree`), from where it
/// comes, `start_player` or `start_other` in the tunnel's frame, to where it goes, `end_friendly`
/// or `end_other` beyond the mouth, turned about the tunnel's axis by `spread_step` for each step
/// of `Gates.spread`, which moves on: from -2 to 2, 0 passed over but by the player's ship, which
/// sets it to 0. It faces the way it goes, its lights' sprites hidden, untargetable, unpowered
/// and frozen, colliding with nothing where it lists no components; it goes in a straight line,
/// and the portal is set up (`Record.portalSetUp`). A Krasny in missions 16 and 66 comes out
/// straight ahead, and leaves the spread as it is.
///
/// **Fix:** the game asserts where the order names nothing, and reads the record before the first
/// where the object has no tunnel; OpenReliant logs either, and the order ends at its update.
pub fn jumpInInit(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const gates = world.gates orelse return;
    const slot = &all.slots[index];
    const state = &slot.state.gate;
    const record = (aimed(gates, all, index) orelse return).record;
    state.let_go = false;
    if (slot.model) |*model| xtrabits.clipTree(model, &record.portal);
    const player = index == all.player;
    state.from = gameobj.vec3(inTunnel(record, all, if (player) start_player else start_other));
    const friendly = if (slot.combat) |combat| combat.side == .friendly else false;
    const beyond: Vector = .{ 0, 0, if (friendly) end_friendly else end_other };
    const turn = if (krasnyRun(all, index)) math.identity else spread: {
        const step: f32 = @floatFromInt(gates.spread);
        gates.spread += 1;
        break :spread math.fromAngles(0, step * spread_step, 0);
    };
    state.to = gameobj.vec3(inTunnel(record, all, math.transform(turn, beyond)));
    if (slot.model) |*model| showLightSprites(model, false);
    if (gates.spread > spread_most) gates.spread = -spread_most;
    if (player) {
        gates.spread = 0;
    } else if (gates.spread == 0) {
        gates.spread = 1;
    }
    ai.setTargetable(&slot.object, slot.combat, false);
    slot.object.flags.unpowered = true;
    slot.object.flags.frozen = true;
    objects.setOrientation(&slot.object, &slot.drawn, math.lookAt(gameobj.vector(state.to) - gameobj.vector(state.from)));
    if (!slot.object.flags.components) slot.object.flags.no_collisions = true;
    state.linear = true;
    record.portalSetUp();
    state.progress = 0;
    state.updated = ctx.world.clock.frame_start;
}

/// Where a ship comes from in the tunnel's frame: the player's a little above the axis, the rest
/// on it (`0x00420BF1`); where it goes, a friend farther out than the rest (`0x00420C52`); how far
/// the spread turns a ship's way out for each step (`0x004DC4C0`), and its bounds.
const start_player: Vector = .{ 0, 2000, 18000 };
const start_other: Vector = .{ 0, 0, 26000 };
const end_friendly: f32 = -53000;
const end_other: f32 = -25000;
const spread_step: f32 = 0.3;
const spread_most = 2;

/// Whether the ship in slot `index` is a Krasny in mission 16 or 66, which comes through its gate
/// as it collapses.
fn krasnyRun(all: *const create.Objects, index: u16) bool {
    return all.slots[index].object.type == .krasny and (all.mission_number == krasny_missions[0] or all.mission_number == krasny_missions[1]);
}

const krasny_missions = [2]u16{ 0x10, 0x42 };

/// `order_fixed_gate_jump_in` (`0x00420FD0`): Jump In's update, a step at a time (`InStep`).
///
/// It waits while another ship comes through the tunnel (`Record.busy`), save the player's ship,
/// which does not. Then it holds the tunnel, the flashes stand at the throat, and it starts where
/// it comes from, heard (`warpin`); for the player's ship the mission's space takes on what its
/// script asked of it (`environfx.Environment.update`). It goes to where it goes in 5 seconds
/// (`in_rate`), in a straight line (or easing in and out), letting the tunnel go half way.
/// Over the first `flash_share` of the way, while the player's ship is not riding the worm, the
/// flashes show, `flash_pace` times as far through as the ship: the first shrinking from
/// `square_most` as it brightens, the second growing to it as it dims, each by the square of how
/// far through. Then it is powered, collides and can be targeted again, its lights' sprites show,
/// the portal lets it go (`release`), and the order ends; the ship's FixedGateJumpedIn is posted,
/// with the gate's (`events.fixedGateJumpedIn`).
///
/// A Krasny in missions 16 and 66 goes at `krasny_rate` instead and shows no flashes.
pub fn jumpIn(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.gate;
    const elapsed = gameobj.progressSince(&state.updated, world.clock.frame_start);
    const gates = world.gates orelse return aigeneric.end(ctx, index);
    const found = aimed(gates, all, index) orelse return aigeneric.end(ctx, index);
    const record = found.record;
    switch (state.step.in) {
        .waiting => {
            if (record.busy and index != all.player) return;
            record.busy = true;
            for (&record.squares) |*square| square.depth = record.tunnel.throat()[2];
            state.next(.{ .in = .coming });
            objects.setPosition(&slot.object, &slot.drawn, gameobj.vector(state.from));
            sound3d.playIn(world, null, null, index, .warpin, 1, .not_reserved);
            if (index == all.player) if (world.environment) |environment| environment.update();
        },
        .coming => {
            state.progress += elapsed * (if (krasnyRun(all, index)) krasny_rate else in_rate);
            const from = gameobj.vector(state.from);
            const to = gameobj.vector(state.to);
            const at = if (state.linear) ease.linear(from, to, state.progress) else ease.cosine(from, to, state.progress);
            objects.setPosition(&slot.object, &slot.drawn, at);
            slot.object.root.markMoved();
            if (state.progress <= 1) {
                if (state.progress > let_go_at and !state.let_go) {
                    record.busy = false;
                    state.let_go = true;
                }
            } else {
                state.next(.{ .in = .done });
            }
            if (gates.riding or !(state.progress < flash_share)) return;
            const through = state.progress * flash_pace;
            record.squares[0].set(ease.in(square_most, square_least, through), through);
            record.squares[1].set(ease.in(square_least, square_most, through), 1 - through);
            if (!krasnyRun(all, index)) record.squares_shown = true;
        },
        .done => {
            release(slot);
            if (slot.model) |*model| showLightSprites(model, true);
            ai.setTargetable(&slot.object, slot.combat, true);
            aigeneric.end(ctx, index);
            events.fixedGateJumpedIn(world, index, found.gate);
        },
        _ => {},
    }
}

/// How fast a ship comes through, twice the time passed (`0x004210C8`), and a Krasny in its
/// missions (`0x004DC618`); how far through it lets the tunnel go (`0x004DC408`); over how
/// much of the way the flashes show (`0x004DC3F8`), how fast they run through them
/// (`0x004DC56C`), and their sizes (`0x00421258`).
const in_rate: f32 = 2;
const krasny_rate: f32 = 0.13;
const let_go_at: f32 = 0.5;
const flash_share: f32 = 0.2;
const flash_pace: f32 = 5;
const square_most: f32 = 12500;
const square_least: f32 = 0.001;

/// Lets the ship in `slot` go at the end of a jump through a gate (`0x00420FD0`, `0x00421510`): it
/// collides and moves again, and the portal no longer cuts it.
fn release(slot: *create.Slot) void {
    slot.object.flags.no_collisions = false;
    slot.object.flags.thaw();
    if (slot.model) |*model| xtrabits.clipTree(model, null);
}

/// `0x00423050`: hides the sprites of every light of `model` and of the models it carries
/// (node kind 3), or shows them again.
fn showLightSprites(model: *objects.Model, shown: bool) void {
    for (model.lights) |*light| {
        if (light.sprites) |*sprites| sprites.set.flags.hidden = !shown;
    }
    var each = model.carried();
    while (each.next()) |mount| showLightSprites(&mount.model, shown);
}

/// `order_fixed_gate_jump_out_init` (`0x00420DD0`): the ship in slot `index` goes out through the
/// nearest gate's tunnel, whatever its order names: its inputs, its rates and its speed at nothing,
/// colliding with nothing, frozen and unpowered, the portal cutting it, and where it goes
/// `exit_player` or `exit_other` down the tunnel. The portal is set up (`Record.portalSetUp`), the
/// player's ship's worm made (`worm.Worm`), and it can no longer be targeted.
///
/// **Fix:** the game takes the record its order names for the portal that cuts the ship, and the
/// record before the first where no gate has a tunnel; OpenReliant takes the nearest gate's for
/// both, and ends the order where there is none.
pub fn jumpOutInit(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const gates = world.gates orelse return;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.gate;
    const record = nearest(gates, all, slot.drawn.position) orelse {
        log.warn("object {d} has no gate to jump out through", .{index});
        state.step = .{ .out = .stranded };
        return;
    };
    object.holdStill();
    object.speed = 0;
    object.flags.no_collisions = true;
    object.flags.frozen = true;
    object.flags.unpowered = true;
    if (slot.model) |*model| xtrabits.clipTree(model, &record.portal);
    state.to = gameobj.vec3(inTunnel(record, all, .{ 0, 0, if (index == all.player) exit_player else exit_other }));
    record.portalSetUp();
    if (index == all.player) {
        if (gates.worm) |tube| tube.destroy(gates.gpa);
        gates.worm = Worm.create(gates.gpa, gates.warp) catch |err| made: {
            log.warn("the worm is left out: {s}", .{@errorName(err)});
            break :made null;
        };
    }
    state.progress = 0;
    state.updated = ctx.world.clock.frame_start;
    ai.setTargetable(object, slot.combat, false);
}

/// How far down the tunnel a ship goes out: the player's and the rest (`0x00420E9B`).
const exit_player: f32 = 12000;
const exit_other: f32 = 26000;

/// The record of the fixed gate whose tunnel stands nearest `at`.
fn nearest(gates: *const Gates, all: *const create.Objects, at: Vector) ?*Record {
    var best: ?*Record = null;
    var best_distance = std.math.floatMax(f32);
    for (gates.records) |held| {
        const record = held orelse continue;
        const distance = math.distanceSquared(record.tunnelPlace(all).position, at);
        if (distance < best_distance) {
            best = record;
            best_distance = distance;
        }
    }
    return best;
}

/// `order_fixed_gate_jump_out` (`0x00421510`): Jump Out's update, a step at a time (`OutStep`).
///
/// It waits while another ship goes out through a tunnel (`Gates.exiting`), then holds it. It is
/// drawn toward where it goes, a share of the rest of the way each frame that grows by `out_rate`
/// as the gates count time, until it is within `arrived_within`: then it is gone to `slot` times
/// `away_spacing` along X and `away_depth` along Z, and the player's ship rides the worm, which
/// stands where the ship does, turned as it is, the screen flashing. While it rides, the worm sways
/// (`worm.Worm.wobble`) and its texture scrolls, and at random the view shakes and flashes and the
/// ride rumbles (`Gates.rumbles`, `ride_sound`); whatever the ship, the ride lasts 4 seconds
/// (`ride_rate`). Then the player's ship leaves the worm, flashing and shaking, the tunnels are
/// free, the ship is powered and collides again, the portal lets it go (`release`), and its order
/// gives way to Fixed Gate Jump In through the gate its order names.
///
/// **Fix:** the game turns the ship as it is drawn toward the angles of a matrix it never fills,
/// whatever the stack holds there; OpenReliant leaves it turned as it is.
pub fn jumpOut(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const gates = world.gates orelse return;
    const slot = &all.slots[index];
    const state = &slot.state.gate;
    const elapsed = gameobj.progressSince(&state.updated, ctx.world.clock.frame_start);
    const player = index == all.player;
    switch (state.step.out) {
        .waiting => {
            if (gates.exiting) return;
            gates.exiting = true;
            state.next(.{ .out = .entering });
        },
        .entering => {
            const at = math.lerp(gameobj.vector(slot.object.root.position), gameobj.vector(state.to), state.progress);
            objects.setPosition(&slot.object, &slot.drawn, at);
            slot.object.root.markMoved();
            state.progress += elapsed * out_rate;
            if (!(math.distance(slot.drawn.position, gameobj.vector(state.to)) < arrived_within)) return;
            state.next(.{ .out = .riding });
            objects.setPosition(&slot.object, &slot.drawn, .{ @as(f32, @floatFromInt(index)) * away_spacing, 0, away_depth });
            if (!player) return;
            gates.riding = true;
            gates.rumbled_at = ctx.world.clock.frame_start;
            if (gates.worm) |tube| {
                tube.object.position = gameobj.vector(slot.object.root.position);
                tube.object.orientation = slot.object.root.orientation;
            }
            if (world.flash) |flash| flash.start();
        },
        .riding => {
            if (player) {
                if (gates.worm) |tube| {
                    gates.worm_shown = true;
                    tube.wobble(ctx.world.clock.frame_start);
                    tube.scroll(elapsed);
                }
                if (gates.rumbles(world.random, ctx.world.clock.frame_start)) {
                    if (world.camera) |view| view.hit_shake = ride_shake;
                    if (world.flash) |flash| flash.start();
                    if (world.hearing) |hearing| hearing.sound.bufferAt(ride_sound, slot.drawn.position, hearing.camera.*, slot.object.radius * ride_loudness);
                }
            }
            state.progress += elapsed * ride_rate;
            if (!(state.progress > 1)) return;
            state.next(.{ .out = .done });
        },
        .done => {
            if (player) {
                if (world.flash) |flash| flash.start();
                if (world.camera) |view| view.hit_shake = ride_shake;
                gates.riding = false;
            }
            gates.exiting = false;
            release(slot);
            const gate = slot.orders[0].target;
            aigeneric.end(ctx, index);
            _ = aigeneric.giveShip(ctx, index, .fixed_gate_jump_in, gate.slot() orelse return, null);
        },
        .stranded => aigeneric.end(ctx, index),
        _ => {},
    }
}

/// How fast a ship is drawn down the tunnel (`0x004DC484`), how near it must come (`0x004DC5A8`),
/// where it waits while it is gone (`0x004DC4F8`, `0x0042166D`), how fast the ride goes
/// (`0x004DC59C`), and the chance it rumbles at each draw (`0x004DC53C`, `Gates.rumbles`), with its
/// shake, its sound in `bank_stdsmp` and its loudness by the ship's radius (`0x004DC438`).
const out_rate: f32 = 0.7;
const arrived_within: f32 = 400;
const away_spacing: f32 = 1e6;
const away_depth: f32 = -2.5e7;
const ride_rate: f32 = 2.5;
const rumble_chance: f32 = 0.025;
const ride_shake: f32 = 3;
const ride_sound = 10;
const ride_loudness: f32 = 2000;

/// `order_fixed_gate_open_init` (`0x004218A0`): a tunnel of a proto gate's colours, or an advanced
/// gate's where one is among the objects, is made at the object in slot `index` (`Gates.make`),
/// and the gate is heard opening (`gateopen`).
pub fn openInit(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const gates = world.gates orelse return;
    const advanced = for (all.slots[0..all.count]) |*slot| {
        if (slot.object.type == .advanced_gate) break true;
    } else false;
    _ = gates.make(world, index, if (advanced) .advanced else .proto, @splat(0)) catch |err| {
        log.warn("object {d} opens no tunnel: {s}", .{ index, @errorName(err) });
    };
    sound3d.playIn(world, null, null, index, .gateopen, 1, .guaranteed);
}

/// `order_fixed_gate_close_init` (`0x00421920`): the gate at the object in slot `index` is heard
/// closing (`gateclos`).
pub fn closeInit(ctx: aigeneric.Context, index: u16) void {
    sound3d.playIn(ctx.world, null, null, index, .gateclos, 1, .guaranteed);
}

/// `order_fixed_gate_open` (`0x00421940`): the tunnel at the object in slot `index` grows, easing
/// in and out from `closed_scale` to its full size over 1.1 seconds (`open_rate`) by the time since
/// it was last drawn (`Record.drawn_at`, `recordTime`); then the order ends.
///
/// **Fix:** the game reads the record before the first where the object has no tunnel;
/// OpenReliant ends the order.
pub fn open(ctx: aigeneric.Context, index: u16) void {
    swing(ctx, index, .opening);
}

/// `order_fixed_gate_close` (`0x00421A00`): the tunnel shrinks likewise from its full size to
/// `closed_scale`; then it is let go of (`Gates.free`), and the order ends.
///
/// **Fix:** as for Open.
pub fn close(ctx: aigeneric.Context, index: u16) void {
    swing(ctx, index, .closing);
}

const Swing = enum { opening, closing };

/// The steps of Open and Close.
pub const SwingStep = enum(u32) {
    swinging = 0,
    done = 1,
    _,
};

fn swing(ctx: aigeneric.Context, index: u16, way: Swing) void {
    const gates = ctx.world.gates orelse return;
    const state = &ctx.world.objects.slots[index].state.gate;
    const record = gates.of(index) orelse {
        log.warn("object {d} has no tunnel for {s}", .{ index, @tagName(way) });
        return aigeneric.end(ctx, index);
    };
    switch (state.step.swing) {
        .swinging => {
            record.progress += recordTime(record.drawn_at, ctx.world.clock.frame_start) * open_rate;
            record.tunnel.object.scale = switch (way) {
                .opening => ease.cosine(closed_scale, 1, record.progress),
                .closing => ease.cosine(1, closed_scale, record.progress),
            };
            if (record.progress > 1) {
                record.progress = 0;
                state.step = .{ .swing = .done };
            }
        },
        .done => {
            if (way == .closing) gates.freeRecord(record);
            aigeneric.end(ctx, index);
        },
        _ => {},
    }
}

/// How fast a tunnel opens and closes, as the gates count time, and its size closed (`0x004DC620`,
/// `0x38D1B717`).
const open_rate: f32 = 9;
const closed_scale: f32 = 0.0001;

/// What a collapse brings down, by the object's type: a prototype, an advanced gate, or any other
/// object, as `order_fixed_gate_collapse` tells them apart.
const Collapsing = enum {
    proto,
    advanced,
    other,

    fn of(object_type: gameobj.Type) Collapsing {
        return switch (object_type) {
            .proto_gate => .proto,
            .advanced_gate => .advanced,
            else => .other,
        };
    }

    /// The part whose cut list its fireballs go off at: a prototype's `Protogate`, any other's
    /// `OuterRing`.
    fn hull(collapsing: Collapsing) []const u8 {
        return switch (collapsing) {
            .proto => proto_hull,
            .advanced, .other => advanced_hull,
        };
    }
};

/// `order_fixed_gate_collapse_init` (`0x00421AC0`): the gate in slot `index` starts to collapse,
/// logged; a proto gate's hull burns (`explode.burnPart`) with flickering rays alone, for a while,
/// and the screen flashes.
///
/// Not ported: in missions 16 and 66, the Krasny's split where it is coming through the gate
/// ([#407](https://github.com/vdmkenny/openreliant/issues/407)).
pub fn collapseInit(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    log.info(">>>>>>Starting gate collapse at {d}", .{ctx.world.clock.frame_start});
    const state = &world.objects.slots[index].state.gate;
    state.progress = 0;
    state.fireballs = 0;
    switch (Collapsing.of(world.objects.slots[index].object.type)) {
        .proto => explode.burnPart(world, index, proto_hull, .{ .forever = false, .flickers = true, .lights = false }),
        .advanced, .other => {},
    }
    if (world.flash) |flash| flash.start();
}

/// The gates' parts the collapse works on (`0x004E4138`, `0x004E41B8`, `0x004E4198`, `0x004E41AC`,
/// `0x004E41A4`, `0x004E4168`): the hulls, a proto gate's ring, an advanced gate's inner ring and
/// tube, and the force field.
const proto_hull = "Protogate";
const advanced_hull = "OuterRing";
const proto_ring = "forcering";
const advanced_inner_ring = "InnerRing";
const advanced_tube = "Tube11";
const force_field = "forcefield";

/// How fast the gates' rings turn: an advanced gate's inner ring at four times its track's pace
/// (`0x004682E2`, `0x00421DD8`), the rest at their tracks' pace (`0x00467DCE`, `0x00421E13`), which
/// `create.gateMade` starts them at and the collapse slows them from.
pub const inner_ring_speed: f32 = 4;
pub const ring_speed: f32 = 1;

/// `order_fixed_gate_collapse` (`0x00421B80`): the collapse's update, a step at a time
/// (`CollapseStep`), its time counted from the tunnel's last frame (`Record.drawn_at`,
/// `recordTime`), which it moves on.
///
/// 1. Fireballs go off, `collapse_fireballs` over its 10 seconds, at each point of the hull's cut
///    list in turn (`Collapsing.hull`), `collapse_large` across, a seventh of them heard
///    (`explosion02`); each frame the hull's parts lose their second pass, at random,
///    `pass_off_chance` of the time (`secondPasses`). After 10 seconds they lose it for good, and
///    the screen flashes.
/// 2. Over the first `ring_stop_share`, `ring_stop_pace` times as far through, its rings slow to
///    a stop from their pace: a proto gate's `forcering` from `ring_speed`, an advanced gate's
///    `InnerRing` from `inner_ring_speed` and `Tube11` from `ring_speed`. At random,
///    `fireball_chance` of the frames, a fireball goes off at a random point of the cut list,
///    `collapse_small` across. The tunnel burns out (`tunnel.Tunnel.burnOut`), and the gate
///    shakes, unpowered, by `shake` along each axis at random; a proto gate's step lasts 20
///    seconds, any other's 40, its tunnel burning out twice as fast.
/// 3. The tunnel fades to black (`tunnel.Tunnel.fadeOut`) over 1.7 seconds.
/// 4. It is logged; any gate but a proto gate lets its tunnel go, an advanced gate losing its hull
///    (`ai.hullLost`); a gate's `forcefield` is hidden, and the order ends.
///
/// **Fix:** the game logs where the gate has no tunnel and reads the record before the first;
/// OpenReliant ends the order.
///
/// **Fix:** the game reads past the hull's cut list where a fireball's point lies beyond its end,
/// as the advanced gate's 41 points do for its 55 fireballs; OpenReliant counts on from the
/// list's start again (`cutIndex`).
///
/// Not ported: the Krasny's split in missions 16 and 66, which holds the second step
/// ([#407](https://github.com/vdmkenny/openreliant/issues/407)).
pub fn collapse(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const gates = world.gates orelse return;
    const slot = &all.slots[index];
    const state = &slot.state.gate;
    const record = gates.of(index) orelse {
        log.info(">>>>>>>>>Can't find gate (index = -1) at {d}", .{ctx.world.clock.frame_start});
        return aigeneric.end(ctx, index);
    };
    const frame_start = ctx.world.clock.frame_start;
    const elapsed = recordTime(record.drawn_at, frame_start);
    record.drawn_at = frame_start;
    const collapsing: Collapsing = .of(slot.object.type);
    switch (state.step.collapse) {
        .fireballs => {
            state.progress += elapsed;
            if (math.round(state.progress * collapse_fireballs) > state.fireballs) {
                if (cutPoint(slot, collapsing.hull(), std.math.cast(usize, state.fireballs) orelse 0)) |at| {
                    collapseFireball(world, at, collapse_large);
                    state.fireballs += 1;
                    if (@rem(state.fireballs, heard_every) == 0) sound3d.playIn(world, at, null, null, .explosion02, 1, .not_reserved);
                } else state.fireballs += 1;
            }
            secondPasses(slot, !(world.random.fraction() < pass_off_chance));
            if (!(state.progress >= 1)) return;
            if (world.flash) |flash| flash.start();
            secondPasses(slot, false);
            state.next(.{ .collapse = .burning });
        },
        .burning => {
            if (state.progress < ring_stop_share) if (slot.model) |*model| {
                const through = state.progress * ring_stop_pace;
                switch (collapsing) {
                    .proto => setSpeed(model, proto_ring, ease.linear(ring_speed, 0, through)),
                    .advanced => {
                        setSpeed(model, advanced_inner_ring, ease.linear(inner_ring_speed, 0, through));
                        setSpeed(model, advanced_tube, ease.linear(ring_speed, 0, through));
                    },
                    .other => {},
                }
            };
            if (world.random.fraction() < fireball_chance) {
                const point = std.math.cast(usize, math.round(world.random.fraction() * collapse_fireballs)) orelse 0;
                if (cutPoint(slot, collapsing.hull(), point)) |at| collapseFireball(world, at, collapse_small);
            }
            const burnt: f32, const burn_rate: f32 = switch (collapsing) {
                .proto => .{ state.progress, proto_burn_rate },
                .advanced, .other => .{ state.progress + state.progress, other_burn_rate },
            };
            record.tunnel.burnOut(burnt);
            state.progress += elapsed * burn_rate;
            slot.object.flags.unpowered = true;
            var shaken = slot.drawn.position;
            inline for (0..3) |axis| shaken[axis] += if (world.random.centred() < 0) -shake else shake;
            objects.setPosition(&slot.object, &slot.drawn, shaken);
            if (!(state.progress >= 1)) return;
            state.next(.{ .collapse = .fading });
        },
        .fading => {
            record.tunnel.fadeOut(state.progress);
            state.progress += elapsed * fade_rate;
            if (state.progress >= 1) state.step = .{ .collapse = .fallen };
        },
        .fallen => {
            log.info(">>>>>>Gate fully collapsed at {d}", .{frame_start});
            switch (collapsing) {
                .proto => {},
                .advanced => {
                    gates.freeRecord(record);
                    ai.hullLost(ctx, index);
                },
                .other => gates.freeRecord(record),
            }
            // The game finds the part itself (`node_find_named`) and sets its hidden flag, as
            // `node_hide_named` does.
            switch (collapsing) {
                .proto, .advanced => if (slot.model) |*model| model.hideNamed(force_field),
                .other => {},
            }
            aigeneric.end(ctx, index);
        },
        _ => {},
    }
}

/// The steps of Collapse.
pub const CollapseStep = enum(u32) {
    /// The fireballs go off along the hull.
    fireballs = 0,
    /// The rings stop, and the tunnel burns out.
    burning = 1,
    fading = 2,
    fallen = 3,
    _,
};

/// The collapse's fireballs: how many go off along the cut list over its first step (`0x004DC630`),
/// how large they are (`0x004DC62C`, `0x004DC508`; `0x004DC628`, `0x004DC44C`), how long they
/// last, how often one is heard, and how often one goes off at random in the second step
/// (`0x004DC474`).
const collapse_fireballs: f32 = 55;
const collapse_large: FireballSize = .{ .least = 5500, .spread = 3000 };
const collapse_small: FireballSize = .{ .least = 3500, .spread = 1000 };
const fireball_life = 150;
const heard_every = 7;
const fireball_chance: f32 = 0.05;
/// How often a frame of the first step drops the second passes (`0x004DC4C0`).
const pass_off_chance: f32 = 0.3;
/// How far through the second step the rings stop (`0x004DC3F8`), and how fast they slow through
/// it (`0x004DC56C`).
const ring_stop_share: f32 = 0.2;
const ring_stop_pace: f32 = 5;
/// How fast the second step goes, as the gates count time, for a proto gate and for the rest
/// (`0x004DC408`, `0x004DC3D4`); how far the gate shakes (`0x004DC624`); how fast the tunnel
/// fades (`0x004DC400`).
const proto_burn_rate: f32 = 0.5;
const other_burn_rate: f32 = 0.25;
const shake: f32 = 15;
const fade_rate: f32 = 6;

/// How large a collapse's fireball is: at least `least` across, and up to `spread` more at random.
const FireballSize = struct { least: f32, spread: f32 };

/// A collapse's fireball at `at`, lit, as large as `size` gives it at random.
fn collapseFireball(world: gameobj.World, at: Vector, size: FireballSize) void {
    explode.fireballAt(world, at, .{ .size = world.random.fraction() * size.spread + size.least, .life = fireball_life, .light = true });
}

/// Point `point` of the cut list of the part of the gate in `slot` named `hull`, in the world as
/// the part is drawn, counting on from the list's start again past its end (`cutIndex`); null
/// where the gate has no such part or its list no points.
fn cutPoint(slot: *create.Slot, hull: []const u8, point: usize) ?Vector {
    const model = if (slot.model) |*live| live else return null;
    const ref = model.partNamed(hull) orelse return null;
    const data = ref.data() orelse return null;
    const cut = data.pointList(.cut) orelse return null;
    const at = cutIndex(point, cut.points.len) orelse return null;
    return ref.part().drawn().point(gameobj.vector(cut.points[at].position));
}

/// Point `point` of a list of `count`, counted on from its start again past its end; null for an
/// empty list.
fn cutIndex(point: usize, count: usize) ?usize {
    if (count == 0) return null;
    return point % count;
}

/// Sets the animation speed of the part of `model` named `name`, where it has one.
fn setSpeed(model: *objects.Model, name: []const u8, speed: f32) void {
    const ref = model.partNamed(name) orelse return;
    ref.part().animation.speed = speed;
}

/// `0x00422680`: turns the second pass on or off of each surface with a second texture of every
/// part of the gate in `slot`, which its type's meshes hold, so that every gate of the type goes
/// with it.
///
/// Not ported: the parts of models the gate carries, which the game's walk of its nodes reaches
/// too; no shipped gate carries any ([#540](https://github.com/vdmkenny/openreliant/issues/540)).
fn secondPasses(slot: *create.Slot, on: bool) void {
    const loaded = (slot.type orelse return).loaded;
    for (loaded.parts) |*part| {
        for (part.meshes) |*mesh| {
            for (mesh.surfaces) |*surface| {
                if (surface.textures[1] != .none) surface.material.two_pass = on;
            }
        }
    }
}

pub const testing = struct {
    /// The gates over a table holding nothing but their textures.
    pub const Built = struct {
        textures: *srtexture.testing.Textures,
        gates: Gates,

        pub fn init(built: *Built, gpa: Allocator) !void {
            built.textures = try .init(gpa, &.{ warp_texture, software_warp_texture, flash_texture });
            errdefer built.textures.deinit(gpa);
            built.gates = try .init(gpa, &built.textures.table, .high, true, .{});
        }

        pub fn deinit(built: *Built, gpa: Allocator) void {
            built.gates.deinit();
            built.textures.deinit(gpa);
        }
    };

    /// The gates and a mission with nothing in it but what a test puts there, which the gates'
    /// orders run in. It stays where `init` fills it in, as the world points into it.
    pub const Run = struct {
        built: Built,
        mission: gameobj.testing.Mission,

        pub fn init(run: *Run, gpa: Allocator) !void {
            try run.built.init(gpa);
            errdefer run.built.deinit(gpa);
            try run.mission.init(gpa);
        }

        pub fn deinit(run: *Run, gpa: Allocator) void {
            run.mission.deinit();
            run.built.deinit(gpa);
        }

        /// What the orders run against, the gates among it.
        pub fn orders(run: *Run) aigeneric.Context {
            var ctx = run.mission.orders();
            ctx.world.gates = &run.built.gates;
            return ctx;
        }
    };
};

test {
    _ = tunnel;
    _ = worm;
}

test recordTime {
    // A thousandth for each tick.
    try std.testing.expectEqual(0.25, recordTime(100, 350));
    // The ticks taken unsigned, as the game takes a record's: a clock that ran back is a long time.
    try std.testing.expect(recordTime(350, 100) > 4e6);
}

test tunnelSize {
    try std.testing.expectEqual(proto_size, tunnelSize(.proto, 3));
    try std.testing.expectEqual(advanced_size, tunnelSize(.advanced, 3));
    // In mission 8 the advanced gate's is as wide as the prototype's.
    try std.testing.expectEqual(proto_size, tunnelSize(.advanced, wide_advanced_mission));
    try std.testing.expectEqual(proto_size, tunnelSize(.proto, wide_advanced_mission));
    try std.testing.expectEqual(proto_size, tunnelSize(.warp, 3));
    try std.testing.expectEqual(proto_size, tunnelSize(.boridin, 3));
}

test depthOf {
    try std.testing.expectEqual(15000, depthOf(.badanov));
    try std.testing.expectEqual(100000, depthOf(.yamato));
    try std.testing.expectEqual(0, depthOf(.proto_gate));
}

test cutIndex {
    try std.testing.expectEqual(3, cutIndex(3, 56));
    try std.testing.expectEqual(0, cutIndex(41, 41));
    try std.testing.expectEqual(14, cutIndex(55, 41));
    try std.testing.expectEqual(null, cutIndex(3, 0));
}

test krasnyRun {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const krasny = try mission.add(.krasny, @splat(0));
    const other = try mission.add(.predator, @splat(0));
    for ([_]u16{ 16, 66 }) |number| {
        mission.objects.mission_number = number;
        try std.testing.expect(krasnyRun(mission.objects, krasny));
        try std.testing.expect(!krasnyRun(mission.objects, other));
    }
    mission.objects.mission_number = 15;
    try std.testing.expect(!krasnyRun(mission.objects, krasny));
}

test "the gates keep 32 records, and make no more" {
    const gpa = std.testing.allocator;
    var run: testing.Run = undefined;
    try run.init(gpa);
    defer run.deinit(gpa);
    const point = try run.mission.addOther(@splat(0));
    const world = run.orders().world;
    for (0..max_records) |_| try std.testing.expect(try run.built.gates.make(world, point, .proto, @splat(0)) != null);
    try std.testing.expectEqual(null, try run.built.gates.make(world, point, .proto, @splat(0)));
    // Nor any of a kind not ported.
    run.built.gates.free(0);
    try std.testing.expectEqual(null, try run.built.gates.make(world, point, .warp, @splat(0)));
}

test "a tunnel at a Yamato stands deeper than one at a nav point" {
    const gpa = std.testing.allocator;
    var run: testing.Run = undefined;
    try run.init(gpa);
    defer run.deinit(gpa);
    const point = try run.mission.addOther(@splat(0));
    const yamato = try run.mission.add(.yamato, .{ 0, 0, 1e6 });
    const world = run.orders().world;
    const at_point = (try run.built.gates.make(world, point, .proto, @splat(0))).?;
    const at_yamato = (try run.built.gates.make(world, yamato, .proto, @splat(0))).?;
    try std.testing.expectEqual(depthOf(.yamato), at_yamato.deeper);

    // Drawn at the same tick, every vertex of the Yamato's stands 100000 deeper, its throat, its
    // portal and the flashes there with it.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    run.mission.clock.frame_start += 10;
    try run.built.gates.draw(gpa, &scene, run.mission.objects, run.mission.clock.frame_start);
    try std.testing.expectApproxEqAbs(100000, at_yamato.tunnel.throat()[2] - at_point.tunnel.throat()[2], 0.05);
    at_point.portalSetUp();
    at_yamato.portalSetUp();
    try std.testing.expectApproxEqAbs(100000, at_yamato.portal_at[2] - at_point.portal_at[2], 0.05);
}

test "the ride through the worm draws its rumbles at the pace of the simulation's steps" {
    const gpa = std.testing.allocator;
    var built: testing.Built = undefined;
    try built.init(gpa);
    defer built.deinit(gpa);
    const gates = &built.gates;
    var random: libcmt.Rand = .{};
    var expected = random;

    // A frame each tick draws a number on every fourth.
    for (1..4) |now| _ = gates.rumbles(&random, @intCast(now));
    try std.testing.expectEqual(expected, random);
    _ = gates.rumbles(&random, 4);
    _ = expected.fraction();
    try std.testing.expectEqual(expected, random);
    // A frame of twelve ticks draws three.
    _ = gates.rumbles(&random, 16);
    for (0..3) |_| _ = expected.fraction();
    try std.testing.expectEqual(expected, random);
    // The original's draws one each frame.
    gates.settings.rumbles = .original;
    _ = gates.rumbles(&random, 17);
    _ = expected.fraction();
    try std.testing.expectEqual(expected, random);
}

test "a tunnel opens at an object and closes again" {
    const gpa = std.testing.allocator;
    var run: testing.Run = undefined;
    try run.init(gpa);
    defer run.deinit(gpa);
    const mission = &run.mission;
    const point = try mission.addOther(@splat(0));
    const ctx = run.orders();

    _ = try aigeneric.push(ctx, point, .fixed_gate_open, .none);
    aigeneric.objectOrders(ctx, point);
    const record = run.built.gates.of(point).?;
    try std.testing.expectEqual(Kind.proto, record.kind);
    // Over a ninth of a thousand ticks it grows to its full size, drawn each frame, and the order
    // ends.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    for (0..120) |_| {
        mission.ordersAfter(ctx, point, 1);
        scene.clear();
        try run.built.gates.draw(gpa, &scene, mission.objects, mission.clock.frame_start);
    }
    try std.testing.expectApproxEqAbs(1, record.tunnel.object.scale, 1e-3);
    try std.testing.expectEqual(0, mission.slot(point).object.order_count);
    // Drawn, its portal and its tunnel are in the world's layer.
    try std.testing.expectEqual(1, scene.portals.items.len);
    try std.testing.expectEqual(&record.tunnel.object, scene.layers.get(.world).items[0].mesh);

    _ = try aigeneric.push(ctx, point, .fixed_gate_close, .none);
    for (0..120) |_| {
        mission.ordersAfter(ctx, point, 1);
        if (run.built.gates.of(point) != null) try run.built.gates.draw(gpa, &scene, mission.objects, mission.clock.frame_start);
    }
    try std.testing.expectEqual(null, run.built.gates.of(point));
    try std.testing.expectEqual(0, mission.slot(point).object.order_count);
}

test "a ship comes in through a gate" {
    const gpa = std.testing.allocator;
    var run: testing.Run = undefined;
    try run.init(gpa);
    defer run.deinit(gpa);
    const mission = &run.mission;
    _ = try mission.add(.predator, @splat(0));
    const ship = try mission.add(.predator, .{ 0, 0, -100000 });
    const gate = try mission.add(.proto_gate, @splat(0));
    const ctx = run.orders();
    const record = (try run.built.gates.make(ctx.world, gate, .proto, @splat(0))).?;

    _ = try aigeneric.pushShip(ctx, ship, .fixed_gate_jump_in, gate, null);
    aigeneric.objectOrders(ctx, ship);
    const slot = mission.slot(ship);
    const object = &slot.object;
    // Held for the jump, it starts deep in the tunnel, which faces the gate's back: the gate's -Z.
    try std.testing.expect(object.flags.frozen and object.flags.unpowered and !object.flags.targetable);
    try std.testing.expectApproxEqAbs(-26000, gameobj.vector(object.root.position)[2], 1e-2);
    try std.testing.expect(record.busy);
    // It comes out beyond the mouth, a friend 53000 off, turned by the spread.
    const to = gameobj.vector(slot.state.gate.to);
    try std.testing.expectApproxEqRel(53000, math.length(to), 1e-4);
    try std.testing.expect(to[2] > 0);
    try std.testing.expectEqual(-1, run.built.gates.spread);

    // Half way it lets the tunnel go; the flashes showed near the start, five times as far through
    // as the ship.
    mission.ordersAfter(ctx, ship, 50);
    try std.testing.expect(record.squares_shown);
    try std.testing.expectEqual(slot.state.gate.progress * flash_pace, record.squares[0].colours[0][0]);
    for (0..25) |_| mission.ordersAfter(ctx, ship, 10);
    try std.testing.expect(!record.busy);
    // Through, it is free, and the order ends.
    for (0..30) |_| mission.ordersAfter(ctx, ship, 10);
    try std.testing.expectEqual(0, object.order_count);
    try std.testing.expect(!object.flags.frozen and !object.flags.unpowered and object.flags.targetable);
    // It overshoots by the last update's step past the end, as the game's ships do.
    try std.testing.expectApproxEqRel(53000, math.length(gameobj.vector(object.root.position)), 0.05);
}

test "the player's ship goes out through the nearest gate and rides the worm" {
    const gpa = std.testing.allocator;
    var run: testing.Run = undefined;
    try run.init(gpa);
    defer run.deinit(gpa);
    const mission = &run.mission;
    const built = &run.built;
    const player = try mission.add(.predator, .{ 0, 0, 30000 });
    const near = try mission.add(.proto_gate, @splat(0));
    const far = try mission.add(.proto_gate, .{ 0, 0, 5e6 });
    const ctx = run.orders();
    _ = (try built.gates.make(ctx.world, near, .proto, @splat(0))).?;
    _ = (try built.gates.make(ctx.world, far, .proto, @splat(0))).?;

    _ = try aigeneric.pushShip(ctx, player, .fixed_gate_jump_out, far, null);
    aigeneric.objectOrders(ctx, player);
    const slot = mission.slot(player);
    // It goes down the nearest tunnel, whatever its order names.
    try std.testing.expectApproxEqAbs(-12000, gameobj.vector(slot.state.gate.to)[2], 1e-2);
    try std.testing.expect(built.gates.exiting and built.gates.worm != null);
    var ticks: usize = 0;
    while (!built.gates.riding and ticks < 1000) : (ticks += 1) mission.ordersAfter(ctx, player, 1);
    try std.testing.expect(built.gates.riding);
    try std.testing.expectEqual(math.Vector{ 0, 0, away_depth }, gameobj.vector(slot.object.root.position));
    // While it rides, the tunnels are left out of the scene and the worm is in it.
    mission.ordersAfter(ctx, player, 1);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try built.gates.draw(gpa, &scene, mission.objects, mission.clock.frame_start);
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(2, scene.portals.items.len);
    // After the ride, it comes in through the gate its order names.
    for (0..420) |_| mission.ordersAfter(ctx, player, 1);
    try std.testing.expect(!built.gates.riding and !built.gates.exiting);
    try std.testing.expectEqual(@import("ai/orders.zig").Order.fixed_gate_jump_in, slot.orders[0].order);
    try std.testing.expectEqual(@as(i16, @intCast(far)), slot.orders[0].target.index);
}

/// Runs the collapse of the gate in slot `gate` a tick at a time to its end, and how many ticks
/// each step took, the tunnel's colours checked on the way: burning, then fading.
fn collapseSteps(run: *testing.Run, gate: u16) ![4]usize {
    const ctx = run.orders();
    const state = &run.mission.slot(gate).state.gate;
    const tube = &run.built.gates.of(gate).?.tunnel;
    const ring = tube.grid.vertex(2, 0);
    const before = tube.colours[ring];
    _ = try aigeneric.push(ctx, gate, .fixed_gate_collapse, .none);
    var ticks: [4]usize = @splat(0);
    var burnt = false;
    var faded = false;
    while (run.mission.slot(gate).object.order_count > 0) {
        const step = state.step.collapse;
        run.mission.ordersAfter(ctx, gate, 1);
        switch (step) {
            .fireballs => try std.testing.expectEqual(before, tube.colours[ring]),
            // The burning colours are red, the fading ones grey.
            .burning => burnt = burnt or tube.colours[ring][1] < tube.colours[ring][0] * 0.5,
            .fading => faded = faded or tube.colours[ring][1] > tube.colours[ring][0],
            .fallen => {},
            _ => return error.TestUnexpectedResult,
        }
        ticks[@intFromEnum(step)] += 1;
        if (ticks[@intFromEnum(step)] > 10000) return error.TestUnexpectedResult;
    }
    try std.testing.expect(burnt and faded);
    return ticks;
}

test "an advanced gate collapses: its tunnel burns out and fades, and it loses its hull" {
    const gpa = std.testing.allocator;
    var run: testing.Run = undefined;
    try run.init(gpa);
    defer run.deinit(gpa);
    _ = try run.mission.add(.predator, @splat(0));
    const gate = try run.mission.add(.advanced_gate, @splat(0));
    _ = (try run.built.gates.make(run.orders().world, gate, .advanced, @splat(0))).?;

    const ticks = try collapseSteps(&run, gate);
    // Its fireballs go off over 10 seconds, its tunnel burns out over 40, and fades in 1.7.
    try std.testing.expectApproxEqAbs(1000, @as(f32, @floatFromInt(ticks[0])), 2);
    try std.testing.expectApproxEqAbs(4000, @as(f32, @floatFromInt(ticks[1])), 2);
    try std.testing.expectApproxEqAbs(1000.0 / fade_rate, @as(f32, @floatFromInt(ticks[2])), 2);
    const object = &run.mission.slot(gate).object;
    try std.testing.expect(object.flags.unpowered and object.flags.exploding);
    // Its tunnel is let go.
    try std.testing.expectEqual(null, run.built.gates.of(gate));
}

test "a proto gate collapses, and keeps its tunnel" {
    const gpa = std.testing.allocator;
    var run: testing.Run = undefined;
    try run.init(gpa);
    defer run.deinit(gpa);
    _ = try run.mission.add(.predator, @splat(0));
    const gate = try run.mission.add(.proto_gate, @splat(0));
    _ = (try run.built.gates.make(run.orders().world, gate, .proto, @splat(0))).?;

    const ticks = try collapseSteps(&run, gate);
    // Its tunnel burns out over 20 seconds.
    try std.testing.expectApproxEqAbs(2000, @as(f32, @floatFromInt(ticks[1])), 2);
    const object = &run.mission.slot(gate).object;
    try std.testing.expect(!object.flags.exploding);
    try std.testing.expect(run.built.gates.of(gate) != null);
}

test showLightSprites {
    const lit = struct {
        fn light() objects.Model.Light {
            return .{
                .part = 0,
                .origin = @splat(0),
                .blink = .{},
                .sprites = .{
                    .colour = @splat(1),
                    .lamp_colour = @splat(1),
                    .size = 1,
                    .set = .{ .sprites = &.{} },
                    .sprite = @splat(.{}),
                    .lamp = srapiext.Surface.glow(null),
                },
                .cast = null,
            };
        }
    }.light;
    var inner_lights = [1]objects.Model.Light{lit()};
    var outer_lights = [1]objects.Model.Light{lit()};
    var mounts = [1]objects.Model.Mount{.{
        .part = 0,
        .attachment = 0,
        .origin = @splat(0),
        .orientation = math.identity,
        .model = .{ .parts = &.{}, .order = &.{}, .lights = &inner_lights, .glows = &.{}, .mounts = &.{} },
    }};
    var model: objects.Model = .{ .parts = &.{}, .order = &.{}, .lights = &outer_lights, .glows = &.{}, .mounts = &mounts };
    // Its own lights' sprites and those of the models it carries hide, and show again.
    showLightSprites(&model, false);
    try std.testing.expect(outer_lights[0].sprites.?.set.flags.hidden and inner_lights[0].sprites.?.set.flags.hidden);
    showLightSprites(&model, true);
    try std.testing.expect(!outer_lights[0].sprites.?.set.flags.hidden and !inner_lights[0].sprites.?.set.flags.hidden);
}

test secondPasses {
    const gpa = std.testing.allocator;
    var meshes = [1]srapiext.Mesh{try .create(gpa, .{ .polygons = 0, .vertices = 0, .indices = 0, .surfaces = 2 })};
    defer meshes[0].deinit(gpa);
    meshes[0].surfaces[0].material.two_pass = true;
    meshes[0].surfaces[0].textures[1] = .{ .highlight = 7 };
    var parts = [1]@import("srofiles.zig").LoadedPart{.{ .flags = .{}, .meshes = &meshes, .levels = &.{} }};
    const loaded: @import("srofiles.zig").Loaded = .{ .parts = &parts };
    const source: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &.{}, .trailing_bytes = 0 };
    const gate_type: create.Type = .{ .model = &source, .loaded = &loaded };
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const gate = mission.slot(try mission.add(.proto_gate, @splat(0)));
    gate.type = &gate_type;
    // Each surface with a second texture loses its second pass, and takes it again; the rest are
    // left as they are.
    secondPasses(gate, false);
    try std.testing.expect(!meshes[0].surfaces[0].material.two_pass);
    meshes[0].surfaces[1].material.two_pass = true;
    secondPasses(gate, true);
    try std.testing.expect(meshes[0].surfaces[0].material.two_pass and meshes[0].surfaces[1].material.two_pass);
    secondPasses(gate, false);
    try std.testing.expect(meshes[0].surfaces[1].material.two_pass);
    gate.type = null;
}
