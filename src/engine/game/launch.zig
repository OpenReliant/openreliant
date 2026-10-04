//! `C:\lancer\game\launch.cpp`: order 104, Launch. `order_launch_init` (`0x00418EB0`)
//! prepares a ship to leave its carrier, and `order_launch` (`0x004191C0`) updates it.
//! The ship and carrier types select a style, with an init and update routine in the table
//! at `0x004E3C98`. OpenReliant runs all ten styles: the Yamato
//! ([`launch/yamato.zig`](launch/yamato.zig)), the Reliant
//! ([`launch/reliant.zig`](launch/reliant.zig)), the torpedoes
//! ([`launch/torpedo.zig`](launch/torpedo.zig)), the hangar bays
//! ([`launch/bay.zig`](launch/bay.zig)), the Badanov and the Krasny
//! ([`launch/badanov.zig`](launch/badanov.zig)), the escape pods
//! ([`launch/escape_pod.zig`](launch/escape_pod.zig)), the rogue base
//! ([`launch/rogue_base.zig`](launch/rogue_base.zig)), the Stork
//! ([`launch/stork.zig`](launch/stork.zig)) and the Zakov ([`launch/zakov.zig`](launch/zakov.zig)).
//! **Unverified:** the source-file assignment of the adjacent gate search, StartLaunch handler,
//! style routines and launch-point placement. Their behaviour matches this file's known code;
//! the next known source file is `tractor.cpp`.
//! [Launches](../../../docs/engine/launch.md) describes them.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.launch);

const engine = @import("../../engine.zig");
const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const create = @import("create.zig");
const models = @import("create/models.zig");
const events = @import("mission/events.zig");
const gameobj = @import("gameobj.zig");
const objects = @import("objects.zig");
const videoreports = @import("videoreports.zig");
const xtrabits = @import("xtrabits.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srmesh = @import("../surrender/surrenderlib/srmesh.zig");

pub const badanov = @import("launch/badanov.zig");
pub const bay = @import("launch/bay.zig");
pub const escape_pod = @import("launch/escape_pod.zig");
pub const reliant = @import("launch/reliant.zig");
pub const rogue_base = @import("launch/rogue_base.zig");
pub const stork = @import("launch/stork.zig");
pub const torpedo = @import("launch/torpedo.zig");
pub const zakov = @import("launch/zakov.zig");
pub const yamato = @import("launch/yamato.zig");

/// Launch styles (`launch_styles`, `0x004E3C98`). Each has an init routine that places the
/// ship and selects its riding node, and an update routine that runs the style's steps.
pub const Style = enum(i32) {
    /// From a hangar bay (`0x0041A610`, `0x0041A9C0`): the Victorious's, the Endeavour's, the
    /// Mitchells', the Bremen's, the Ramases's, the Pukov's, the Kronstadt's, the Krasnaya's, the
    /// Varyag's and the Kiev's, and the rogue base's from its seventh gate on.
    bay = 0,
    /// From the Yamato (`launch_yamato_init`, `0x004192C0`, and `launch_yamato_run`, `0x00419840`).
    yamato = 1,
    /// From the Badanov and the Krasny (`launch_badanov_init`, `0x00419F60`, and
    /// `launch_badanov_run`, `0x0041A100`).
    badanov = 2,
    /// A torpedo from its tube (`0x0041A360`, `0x0041A390`), whatever it launches from.
    torpedo = 3,
    /// An escape pod (`launch_point_init`, `0x0041A4B0`, and `launch_pod_run`, `0x0041A4D0`).
    escape_pod = 4,
    /// From the Stork (`launch_point_init`, `0x0041A4B0`, and `launch_stork_run`, `0x0041AD10`).
    stork = 5,
    /// From the Reliant (`0x0041AE20`, `0x0041B240`).
    reliant = 6,
    /// The other escape pod (`launch_point_init`, `0x0041A4B0`, and `launch_pod_other_run`,
    /// `0x0041B690`).
    other_escape_pod = 7,
    /// From the rogue base's first six gates (`launch_rogue_init`, `0x0041B770`, and
    /// `launch_rogue_run`, `0x0041B7F0`).
    rogue_base = 8,
    /// From the Zakov (`0x0041B8B0`, `0x0041B940`).
    zakov = 9,
    _,

    /// Selects the style as `order_launch_init` does: torpedoes and escape pods use their own
    /// types; other ships use the carrier's type and gate. Returns null for an unsupported
    /// carrier, which the original rejects with "Error: Trying to launch from %s".
    pub fn of(ship: gameobj.Type, carrier: gameobj.Type, gate: i16) ?Style {
        return switch (ship) {
            .torpedo, .russian_torpedo => .torpedo,
            .escape_pod => .escape_pod,
            .other_escape_pod => .other_escape_pod,
            else => switch (carrier) {
                .reliant => .reliant,
                .yamato => .yamato,
                .victorious, .endeavour, .mitchell, .bremen, .ramases, .pukov, .kronstadt, .krasnaya, .varyag, .other_ramases, .other_mitchell, .kiev => .bay,
                .stork => .stork,
                .badanov, .krasny => .badanov,
                .rogue_base => if (gate < rogue_base_gates) .rogue_base else .bay,
                .zakov => .zakov,
                else => null,
            },
        };
    }

    /// The init and update pair from `launch_styles` (`0x004E3C98`), or null for an unknown style.
    pub fn routines(style: Style) ?Routines {
        return switch (style) {
            .bay => .{ .init = &bay.init, .run = &bay.run },
            .reliant => .{ .init = &reliant.init, .run = &reliant.run },
            .torpedo => .{ .init = &torpedo.init, .run = &torpedo.run },
            .stork => .{ .init = &attachAtGate, .run = &stork.run },
            .zakov => .{ .init = &zakov.init, .run = &zakov.run },
            .badanov => .{ .init = &badanov.init, .run = &badanov.run },
            .escape_pod => .{ .init = &attachAtGate, .run = &escape_pod.run },
            .other_escape_pod => .{ .init = &attachAtGate, .run = &escape_pod.runOther },
            .rogue_base => .{ .init = &rogue_base.init, .run = &rogue_base.run },
            .yamato => .{ .init = &yamato.init, .run = &yamato.run },
            _ => null,
        };
    }

    pub fn format(style: Style, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return switch (style) {
            _ => writer.print("style {d}", .{@intFromEnum(style)}),
            inline else => |named| writer.writeAll(@tagName(named)),
        };
    }
};

/// A style's two routines (`launch_styles`, `0x004E3C98`, 24 bytes a style): the first places the
/// ship in slot `index` for its launch from the carrier in slot `carrier` and names the node it
/// rides, the second runs its launch an update at a time from step 2 on (`Step.styled`).
pub const Routines = struct {
    init: *const fn (ctx: aigeneric.Context, index: u16, carrier: u16) void,
    run: *const fn (ctx: aigeneric.Context, index: u16) void,
};

/// The rogue base's gates that launch in its own style; those after launch from a bay
/// (`0x00418F8A`).
const rogue_base_gates = 6;

/// A launch's steps as `order_launch` runs them: waiting for StartLaunch, then a moment more
/// (`most_delay`), then its style's own, numbered from `styled` on.
pub const Step = enum(i32) {
    waiting = 0,
    delaying = 1,
    _,

    /// The first of the style's own steps, which `order_launch` sets once the wait is over
    /// (`0x0041928A`): each style's own step enum starts its steps there.
    pub const styled: Step = @enumFromInt(2);

    /// Whether the style's own steps have begun.
    pub fn isStyled(step: Step) bool {
        return @intFromEnum(step) >= @intFromEnum(styled);
    }

    /// The step as a style's own steps, `Styled`, number it.
    pub fn as(step: Step, comptime Styled: type) Styled {
        comptime assert(@typeInfo(Styled).@"enum".tag_type == i32);
        return @enumFromInt(@intFromEnum(step));
    }

    /// A style's own step as a launch's.
    pub fn of(own: anytype) Step {
        comptime assert(@typeInfo(@TypeOf(own)).@"enum".tag_type == i32);
        return @enumFromInt(@intFromEnum(own));
    }

    /// The step after it.
    pub fn next(step: Step) Step {
        return @enumFromInt(@intFromEnum(step) + 1);
    }
};

/// The quarter turn the Yamato's and the Badanov's styles turn a ship by about its Y axis
/// (`0x004193AF`, `0x0041A00C`): the float nearest to half of pi, `0x3FC90FDB`.
pub const quarter_turn: f32 = std.math.pi / 2.0;

comptime {
    // Each style's own steps begin where the launch's leave off.
    assert(Step.of(reliant.Step.start) == Step.styled);
    assert(Step.of(torpedo.Step.fire) == Step.styled);
    assert(Step.of(zakov.Step.leave) == Step.styled);
    assert(Step.of(bay.Step.open) == Step.styled);
    assert(Step.of(stork.Step.leave) == Step.styled);
    assert(Step.of(badanov.Step.open) == Step.styled);
    assert(Step.of(escape_pod.Step.leave) == Step.styled);
    assert(Step.of(escape_pod.OtherStep.sound) == Step.styled);
    assert(Step.of(rogue_base.Step.leave) == Step.styled);
    assert(Step.of(yamato.Step.release) == Step.styled);
}

/// What Launch keeps in the object's order state.
pub const State = extern struct {
    style: Style,
    /// The frame's tick after which its next step runs.
    due: i32,
    step: Step,
    /// Where the ship stands in the frame of the node it rides, and how it is turned there.
    position: shp.Vec3,
    orientation: math.Matrix,
    /// Whether it rides its node, which each frame's pass places it on (`hold`).
    attached: bool,
    _unknown_3d: [3]u8,
    /// The node it rides, which its style names: the address OpenReliant keeps as
    /// `create.Slot.riding`.
    node: engine.Pointer(objects.Node),
    /// How many launch points the search for a gate passes over (`GateSearch`): its order's place
    /// among those its command gave (`aigeneric.Entry.sequence`).
    sequence: i32,
    /// The carrier, and the gate on it, the search found.
    carrier: i32,
    gate: i32,
    /// The nodes of a bay's doors, which `launch_bay_init` keeps. OpenReliant looks them up from
    /// the carrier and the gate instead (`bay.Doors`).
    doors: [2]engine.Pointer(objects.Node),
    _unknown_58: [0x90 - 0x58]u8,

    comptime {
        assert(@offsetOf(State, "due") == 0x04);
        assert(@offsetOf(State, "step") == 0x08);
        assert(@offsetOf(State, "position") == 0x0C);
        assert(@offsetOf(State, "orientation") == 0x18);
        assert(@offsetOf(State, "attached") == 0x3C);
        assert(@offsetOf(State, "node") == 0x40);
        assert(@offsetOf(State, "sequence") == 0x44);
        assert(@offsetOf(State, "carrier") == 0x48);
        assert(@offsetOf(State, "gate") == 0x4C);
        assert(@offsetOf(State, "doors") == 0x50);
        assert(@sizeOf(State) == 0x90);
    }

    /// Moves on to step `next`, which runs once `wait` more ticks have passed from `now`.
    pub fn advance(state: *State, next: Step, now: i32, wait: i32) void {
        state.step = next;
        state.due = now + wait;
    }

    /// Moves on from the style's own step `from` to the one after it, which runs once `wait` more
    /// ticks have passed from `now`.
    pub fn moveOn(state: *State, from: anytype, now: i32, wait: i32) void {
        state.advance(Step.of(from).next(), now, wait);
    }
};

/// What Launch keeps in its entry's data (`aigeneric.Entry.Data`).
pub const Data = extern struct {
    /// Set by StartLaunch (`start`): the launch goes.
    go: bool,
};

/// How long a launch waits after its start before its style's first step, at most, in ticks: a
/// random share of it (`order_launch`, `0x00419254`).
const most_delay = 200;

/// How long the init has a launch wait before its next step (`order_launch_init`, `0x00419023`),
/// which no step reads before the start sets its own.
const init_wait = 200;

/// OpenReliant's sentinel for an unsupported carrier. It has no entry in the original's table.
const unsupported_style: Style = @enumFromInt(-1);

/// `order_launch_init` (`0x00418EB0`): prepares the ship in slot `index` to launch. For a flight
/// group, squad or target without a gate, `GateSearch` walks the target's ships (`ai.eachShip`).
/// It writes the carrier's slot and gate into the target, preserving its kind. The ship and
/// carrier types select the style (`Style.of`), whose init places the ship and selects the node
/// it rides. The order stores its position and orientation relative to that node. The ship
/// passes through its carrier and cannot be targeted until the launch ends.
///
/// **Fix:** the original asserts for an unsupported carrier and dereferences a missing launch
/// node. OpenReliant logs an unsupported carrier and lets the ship go when the launch starts.
/// A ship without a launch node stays where it was placed.
pub fn init(ctx: aigeneric.Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const entry = &slot.orders[0];
    const state = &slot.state.launch;
    if (entry.target.kind != .ship or entry.target.isWhole()) {
        state.carrier = 0;
        state.gate = 0;
        state.sequence = entry.sequence;
        var search: GateSearch = .{ .all = all, .state = state };
        _ = ai.eachShip(ctx.world, entry.target, &search);
        entry.target.index = @truncate(state.carrier);
        entry.target.component = @truncate(state.gate);
    }
    const carrier = entry.target.slotIn(all) orelse return;
    const carrier_type = all.slots[carrier].object.type;
    // No named style handles an unsupported carrier.
    state.style = Style.of(slot.object.type, carrier_type, entry.target.component) orelse unsupported_style;
    state.step = .waiting;
    slot.riding = null;
    if (state.style.routines()) |found| found.init(ctx, index, carrier) else {
        log.warn("slot {d} can't launch from {f}: it goes where it stands", .{ index, carrier_type });
        slot.riding = .{ .object = carrier };
    }
    if (if (slot.riding) |riding| riding.place(all) else null) |node| {
        const relative = slot.drawn.relativeTo(node);
        state.position = gameobj.vec3(relative.position);
        state.orientation = relative.orientation;
        state.attached = true;
    }
    state.due = ctx.world.clock.frame_start + init_wait;
    slot.object.passes_through[0] = .of(carrier);
    ai.setTargetable(&slot.object, slot.combat, false);
}

/// `order_launch` (`0x004191C0`): runs the launch of the ship in slot `index`, once an update.
/// Until the style's own steps begin, a ship whose carrier is gone (a stand-in or exploding) is
/// destroyed with it (`ai.objectDestroyed`). The exception is an escape pod leaving the Ulysses.
/// Once StartLaunch sets `Data.go`, the launch waits a random delay of up to `most_delay` ticks,
/// drawn from the ship's own numbers (`xtrabits.objectRandom15`), and then the style runs it from
/// step 2. When the player's launch starts, the radio plays its line (`videoreports.launchLine`).
///
/// **Fix:** for a Launch aimed at nothing, the game reads the carrier from the word before its
/// object table (`0x00587CDC`, `mission25_second_part`). Its assertion "Launch Crash Imminent"
/// (`0x004191E6`) compares the sign-extended index with 0xFFFF, so it never fires. OpenReliant lets
/// the ship go (`letGo`).
pub fn update(ctx: aigeneric.Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const entry = &slot.orders[0];
    const state = &slot.state.launch;
    const now = ctx.world.clock.frame_start;
    if (!state.step.isStyled()) {
        const carrier = entry.target.slotIn(all) orelse return letGo(ctx, index);
        const from = &all.slots[carrier].object;
        if (from.gone() and !(from.type == .ulysses and slot.object.type == .escape_pod)) {
            ai.objectDestroyed(ctx, index, false, false);
            return;
        }
        if (entry.data.launch.go and state.step == .waiting) {
            state.advance(.delaying, now, @intCast(xtrabits.objectRandom15(&slot.object) % most_delay));
            if (index == all.player) videoreports.launchLine(ctx.world, carrier);
        }
        if (state.step == .delaying and state.due < now) state.step = Step.styled;
    }
    if (state.style.routines()) |found| found.run(ctx, index) else if (state.step.isStyled()) letGo(ctx, index);
}

/// Ends the launch and clears the carrier pass-through entry, as the last step of
/// `launch_reliant_run` does (`0x0041B639`). Unknown styles use this when the launch starts.
pub fn letGo(ctx: aigeneric.Context, index: u16) void {
    ctx.world.objects.slots[index].object.passes_through[0] = .none;
    finish(ctx, index);
}

/// Pops the Launch order, restores targeting and posts the Launched event (`events.launched`).
/// Styles that preserve the carrier pass-through entry call this directly.
pub fn finish(ctx: aigeneric.Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    slot.riding = null;
    aigeneric.end(ctx, index);
    ai.setTargetable(&slot.object, slot.combat, true);
    events.launched(ctx.world, index);
}

/// `launch_start` (`0x00418DB0`): starts the first Launch among the orders of the ship in slot
/// `index` (`Data.go`), as StartLaunch and the Kamov's LAUNCH MISSILE do. A ship without one is
/// left alone.
pub fn start(all: *create.Objects, index: u16) void {
    if (all.slots[index].firstOrder(.launch)) |entry| entry.data.launch.go = true;
}

/// Whether the ship in slot `index` is dropping out of the Reliant, or about to: its current order
/// is Launch in the Reliant's style, at `reliant.Step.drop` or later. `camera_frame` reads this for
/// the bay's view.
pub fn dropping(all: *const create.Objects, index: u16) bool {
    const slot = &all.slots[index];
    if (slot.running(.launch) == null) return false;
    const state = slot.state.launch;
    return state.style == .reliant and @intFromEnum(state.step) >= @intFromEnum(Step.of(reliant.Step.drop));
}

/// `mission_frame`'s placing of a ship that rides a node (`0x00492C14`), once a frame before the
/// ship is drawn (`main.frameObjects`). If the current order of the ship in slot `index` is Launch,
/// its carrier isn't exploding and the ship rides its node, the ship is put back where the launch
/// placed it on the node, turned as it was. Returns whether it placed the ship.
pub fn hold(all: *create.Objects, index: u16) bool {
    const slot = &all.slots[index];
    const entry = slot.running(.launch) orelse return false;
    const carrier = entry.target.slotIn(all) orelse return false;
    if (all.slots[carrier].object.flags.exploding) return false;
    const state = &slot.state.launch;
    if (!state.attached) return false;
    const node = (slot.riding orelse return false).place(all) orelse return false;
    const riding: math.Place = .{ .position = gameobj.vector(state.position), .orientation = state.orientation };
    objects.setPlace(&slot.object, &slot.drawn, riding.within(node));
    return true;
}

// --- Launch points ------------------------------------------------------------------------------

/// The launch points of a model (`launch_find_gate`, `launch_attach`), part by part in the order of
/// the root's child list, and each part's attachments in order. A launch point is an attachment of
/// kind `launch_point`, or of kind `pod` where the pod table has no model at the part's index.
///
/// **Quirk:** the game looks pods up by the index of the part that holds the attachment, not by
/// the attachment's id, which names the pod it mounts.
pub const Points = objects.Model.RootAttachments(isPoint);

/// A launch point, and the part that holds it.
pub const Point = Points.Point;

fn isPoint(attachment: shp.Attachment, part: usize) bool {
    return switch (attachment.kind) {
        .launch_point => true,
        .pod => podless(part),
        else => false,
    };
}

/// Whether the pod table has no model at `place` (`attachment_models`, kind 5). Past the pods' ids
/// the game reads on into the next kinds' entries, none of which has a model.
fn podless(place: usize) bool {
    const id = std.math.cast(u32, place) orelse return true;
    const entry = models.attachment(.pod, id) orelse return true;
    return entry.model == null;
}

/// `launch_find_gate` (`0x00418DF0`): the search for a gate that `init` runs over each ship the
/// order's target names (`ai.eachShip`). Each ship it visits becomes the carrier, with the gate
/// counted from 0 again, and each of its launch points (`Points`) takes one off the sequence, which
/// carries on from ship to ship. The point that takes the sequence below 0 ends the search, and its
/// index among that ship's points is the gate.
const GateSearch = struct {
    all: *const create.Objects,
    state: *State,

    pub fn visit(search: *GateSearch, carrier: aigeneric.Target) bool {
        const state = search.state;
        const index = carrier.slotIn(search.all) orelse return false;
        state.carrier = index;
        state.gate = 0;
        const model = if (search.all.slots[index].model) |*held| held else return false;
        var points: Points = .of(model);
        while (points.next()) |_| {
            state.sequence -= 1;
            if (state.sequence < 0) return true;
            state.gate += 1;
        }
        return false;
    }
};

/// `launch_attach` (`0x0041B9F0`): places the ship in slot `index` at launch point `gate` of the
/// object in slot `on`, counting from 0 over its points (`Points`). The ship's centre of mass stands
/// at the point and it is turned as the point is, and it rides the part that holds the point
/// (`State.node`, `create.Slot.riding`). If the object has no such point, the ship stays where it
/// is. The game reads the gate from the component of the ship's order's target, which
/// `launch_reliant_init` overwrites with the hangar's point and then restores (`0x0041B15E`,
/// `0x0041B174`, `0x0041B206`). OpenReliant passes the gate instead.
pub fn attach(all: *create.Objects, index: u16, on: u16, gate: i16) void {
    const slot = &all.slots[index];
    const holder = &all.slots[on];
    const model = if (holder.model) |*held| held else return;
    const point = Points.nth(model, std.math.cast(usize, gate) orelse return) orelse return;
    slot.riding = .{ .object = on, .part = point.part };
    const frame = model.frameAt(point.part, holder.drawn);
    const standing: math.Place = .{ .position = gameobj.vector(point.attachment.position), .orientation = point.attachment.orientation };
    const at = standing.within(frame);
    objects.setPlace(&slot.object, &slot.drawn, .{ .position = at.point(gameobj.vector(slot.object.centre)), .orientation = at.orientation });
}

/// `launch_point_init` (`0x0041A4B0`), the first routine of the escape pods' styles and the
/// Stork's: places the ship in slot `index` at the launch point of the carrier in slot `carrier`
/// that its gate names (`attach`), riding the part that holds it. The first routines of the bays,
/// the torpedoes and the Zakov start the same way.
pub fn attachAtGate(ctx: aigeneric.Context, index: u16, carrier: u16) void {
    const all = ctx.world.objects;
    attach(all, index, carrier, all.slots[index].orders[0].target.component);
}

test {
    std.testing.refAllDecls(@This());
}

test "Step.as" {
    // A style's own step, as a launch's and back.
    try std.testing.expectEqual(reliant.Step.drop, Step.of(reliant.Step.drop).as(reliant.Step));
    try std.testing.expectEqual(torpedo.Step.boost, Step.of(torpedo.Step.boost).as(torpedo.Step));
    try std.testing.expect(Step.of(torpedo.Step.fire).isStyled());
    try std.testing.expect(!Step.delaying.isStyled());
}

test "Style.of" {
    // Torpedoes and escape pods go by their own type, whatever launches them.
    try std.testing.expectEqual(Style.torpedo, Style.of(.russian_torpedo, .reliant, 0));
    try std.testing.expectEqual(Style.other_escape_pod, Style.of(.other_escape_pod, .kamov, 0));
    // Any other ship by its carrier's.
    try std.testing.expectEqual(Style.reliant, Style.of(.predator, .reliant, 3));
    try std.testing.expectEqual(Style.badanov, Style.of(.sabre, .krasny, 0));
    try std.testing.expectEqual(Style.bay, Style.of(.sabre, .kiev, 0));
    // The rogue base's first six gates have a style of their own.
    try std.testing.expectEqual(Style.rogue_base, Style.of(.sabre, .rogue_base, 5));
    try std.testing.expectEqual(Style.bay, Style.of(.sabre, .rogue_base, 6));
    // Nothing launches from a fighter.
    try std.testing.expectEqual(null, Style.of(.sabre, .predator, 0));
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("reliant", try std.fmt.bufPrint(&buffer, "{f}", .{Style.reliant}));
    try std.testing.expectEqualStrings("style 12", try std.fmt.bufPrint(&buffer, "{f}", .{@as(Style, @enumFromInt(12))}));
    // Every named style has its original pair of routines.
    for (std.enums.values(Style)) |style| {
        const runs = switch (style) {
            .bay, .reliant, .torpedo, .stork, .zakov, .badanov, .escape_pod, .other_escape_pod, .rogue_base, .yamato => true,
            _ => false,
        };
        try std.testing.expectEqual(runs, style.routines() != null);
    }
}

/// Fixtures for the launches' tests.
pub const testing = struct {
    /// A carrier's model of three parts hanging from the root, 100 apart along X. The first holds
    /// no launch point, only a missile's hardpoint; the second two, 10 and 20 along Z, turned half
    /// a turn about Y, with a pod's between them, which the pod table has a model for at the second
    /// part's place; the third a pod's, which the table has none for at the third's. Set it up
    /// where it stays, as its records point into it.
    pub const Carrier = struct {
        attachments: [5]shp.Attachment,
        parts: objects.testing.Parts(3),

        pub fn init(carrier: *Carrier) void {
            const kinds = [_]shp.Attachment.Kind{ .missile, .launch_point, .pod, .launch_point, .pod };
            const along = [_]f32{ 0, 10, 15, 20, 0 };
            for (&carrier.attachments, kinds, along) |*attachment, kind, z| {
                attachment.* = std.mem.zeroes(shp.Attachment);
                attachment.kind = kind;
                attachment.position = .{ .x = 0, .y = 0, .z = z };
                attachment.orientation = math.rotation(.y, std.math.pi);
            }
            carrier.parts.init();
            for (&carrier.parts.data, 0..) |*part, n| part.part.position = .{ .x = @floatFromInt(100 * n), .y = 0, .z = 0 };
            carrier.parts.data[0].attachments = carrier.attachments[0..1];
            carrier.parts.data[1].attachments = carrier.attachments[1..4];
            carrier.parts.data[2].attachments = carrier.attachments[4..5];
        }
    };

    /// A carrier's model of `count` parts, each drawing a level with the bounds `init` gives and
    /// holding the doors' track (`objects.door_track`), for the styles that place a ship by a
    /// part's bounds. Set it up where it stays, as its records point into it.
    pub fn Bounded(comptime count: usize) type {
        return struct {
            mesh: srapiext.Mesh,
            levels: [1]srapiext.Level,
            tracks: [1]shp.Track,
            parts: objects.testing.Parts(count),

            const Model = @This();

            pub fn init(model: *Model, gpa: std.mem.Allocator, bounds: [2]math.Vector) !void {
                model.mesh = try srmesh.testing.square(gpa);
                model.mesh.bounds = bounds;
                model.levels = .{.{ .mesh = &model.mesh, .until = std.math.inf(f32) }};
                model.tracks = .{.{ .clip = objects.testing.clip(100, .once, objects.door_track), .keyframes = &.{}, .events = &.{} }};
                model.parts.init();
                for (&model.parts.loaded_parts, &model.parts.data) |*part, *data| {
                    part.levels = &model.levels;
                    data.tracks = &model.tracks;
                }
            }

            pub fn deinit(model: *Model, gpa: std.mem.Allocator) void {
                model.mesh.deinit(gpa);
            }
        };
    }

    /// Whether the launch of the ship in `slot` is over: its current order is no longer Launch.
    pub fn ended(slot: *const create.Slot) bool {
        const entry = slot.current() orelse return true;
        return entry.order != .launch;
    }

    /// Moves the clock past the wait of the launch of the ship in slot `index`, and runs its
    /// orders once.
    pub fn pastDue(mission: *gameobj.testing.Mission, ctx: aigeneric.Context, index: u16) void {
        mission.clock.frame_start = mission.slot(index).state.launch.due + 1;
        aigeneric.objectOrders(ctx, index);
    }
};

test Points {
    var carrier: testing.Carrier = undefined;
    carrier.init();
    var model = try carrier.parts.create(std.testing.allocator);
    defer model.deinit(std.testing.allocator);
    // The second part's two points, not the pod between them, which has a model at its place, and
    // the third's pod, which has none: a quirk of the game's.
    var points: Points = .of(&model);
    const expected = [_]struct { usize, f32 }{ .{ 1, 10 }, .{ 1, 20 }, .{ 2, 0 } };
    for (expected) |point| {
        const found = points.next().?;
        try std.testing.expectEqual(point[0], found.part);
        try std.testing.expectEqual(point[1], found.attachment.position.z);
    }
    try std.testing.expectEqual(null, points.next());
    // A part taken out of its model holds none.
    model.parts[1].removed = true;
    points = .of(&model);
    try std.testing.expectEqual(2, points.next().?.part);
}

test "a launch stands its ship at its gate's point, riding it, until it starts" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var carrier_model: testing.Carrier = undefined;
    carrier_model.init();
    _ = try mission.add(.predator, @splat(0));
    const carrier = try mission.add(.kamov, .{ 1000, 0, 0 });
    try carrier_model.parts.fit(gpa, mission.slot(carrier));
    mission.slot(carrier).object.velocity = .{ .x = 0, .y = 0, .z = 5 };
    const torpedo_slot = try mission.add(.torpedo, @splat(0));
    const ctx = mission.orders();

    // Through its second gate, the second part's second point: its centre there, turned as the
    // point is, riding the part, passing through the carrier and not to be targeted.
    _ = try aigeneric.pushShip(ctx, torpedo_slot, .launch, carrier, 1);
    mission.slot(torpedo_slot).object.flags.targetable = true;
    aigeneric.objectOrders(ctx, torpedo_slot);
    const slot = mission.slot(torpedo_slot);
    const state = &slot.state.launch;
    try std.testing.expectEqual(Style.torpedo, state.style);
    try std.testing.expectEqual(objects.NodeOf{ .object = carrier, .part = 1 }, slot.riding.?);
    try std.testing.expectEqual(math.Vector{ 1100, 0, 20 }, slot.drawn.position);
    try std.testing.expectApproxEqAbs(-1, math.forward(slot.drawn.orientation)[2], 1e-6);
    try std.testing.expect(state.attached and slot.object.flags.no_collisions);
    try std.testing.expectEqual(carrier, slot.object.passes_through[0].index());
    try std.testing.expect(!slot.object.flags.targetable);

    // It rides its node as the carrier moves.
    objects.setPosition(&mission.slot(carrier).object, &mission.slot(carrier).drawn, .{ 1000, 50, 0 });
    try std.testing.expect(hold(mission.objects, torpedo_slot));
    try std.testing.expectEqual(math.Vector{ 1100, 50, 20 }, slot.drawn.position);

    // It waits until the launch starts, then a moment of up to two seconds.
    mission.clock.frame_start = 10;
    aigeneric.objectOrders(ctx, torpedo_slot);
    try std.testing.expectEqual(Step.waiting, state.step);
    start(mission.objects, torpedo_slot);
    aigeneric.objectOrders(ctx, torpedo_slot);
    try std.testing.expectEqual(Step.delaying, state.step);
    try std.testing.expect(state.due >= 10 and state.due < 10 + most_delay);
}

test "a launch's search for a gate counts the launch points on" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var carrier_model: testing.Carrier = undefined;
    carrier_model.init();
    const first = try mission.add(.kamov, @splat(0));
    const second = try mission.add(.kamov, .{ 5000, 0, 0 });
    for ([_]u16{ first, second }) |index| try carrier_model.parts.fit(gpa, mission.slot(index));
    var state = std.mem.zeroes(State);
    var search: GateSearch = .{ .all = mission.objects, .state = &state };
    // The third order a command gave takes the first carrier's third point.
    state.sequence = 2;
    try std.testing.expect(search.visit(.at(first, null)));
    try std.testing.expectEqual(first, state.carrier);
    try std.testing.expectEqual(2, state.gate);
    // The fifth goes on to the second carrier's second, its count starting again there.
    state.sequence = 4;
    try std.testing.expect(!search.visit(.at(first, null)));
    try std.testing.expect(search.visit(.at(second, null)));
    try std.testing.expectEqual(second, state.carrier);
    try std.testing.expectEqual(1, state.gate);
}

test "a launch ends with its carrier, and an unknown style lets the ship go" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    _ = try mission.add(.predator, @splat(0));
    const carrier = try mission.add(.yamato, .{ 0, 0, 5000 });
    const ship = try mission.add(.sabre, .{ 0, 0, 5000 });
    const lost = try mission.add(.sabre, .{ 0, 0, 5000 });
    const ctx = mission.orders();
    for ([_]u16{ ship, lost }) |index| {
        _ = try aigeneric.pushShip(ctx, index, .launch, carrier, 0);
        aigeneric.objectOrders(ctx, index);
    }
    // A missing bay leaves the ship riding the root. An unknown style still lets it go.
    try std.testing.expectEqual(Style.yamato, mission.slot(ship).state.launch.style);
    try std.testing.expectEqual(objects.NodeOf{ .object = carrier }, mission.slot(ship).riding.?);
    mission.slot(ship).state.launch.style = @enumFromInt(12);
    start(mission.objects, ship);
    aigeneric.objectOrders(ctx, ship);
    testing.pastDue(&mission, ctx, ship);
    try std.testing.expectEqual(0, mission.slot(ship).object.order_count);
    try std.testing.expectEqual(null, mission.slot(ship).object.passes_through[0].index());

    // A ship still waiting when its carrier explodes goes with it.
    mission.slot(carrier).object.flags.exploding = true;
    aigeneric.objectOrders(ctx, lost);
    try std.testing.expectEqual(ai.orders.Order.explode, mission.slot(lost).orders[0].order);
}

test dropping {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const player = try mission.add(.predator, @splat(0));
    try std.testing.expect(!dropping(mission.objects, player));
    _ = try aigeneric.pushShip(mission.orders(), player, .launch, player, 0);
    const state = &mission.slot(player).state.launch;
    state.style = .reliant;
    state.step = .of(reliant.Step.open);
    try std.testing.expect(!dropping(mission.objects, player));
    state.step = .of(reliant.Step.drop);
    try std.testing.expect(dropping(mission.objects, player));
}

test "an unsupported carrier waits for StartLaunch and releases without running a bay style" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    _ = try mission.add(.predator, @splat(0));
    const carrier = try mission.add(.kamov, .{ 0, 0, 10000 });
    const ship = try mission.add(.sabre, .{ 0, 0, 10500 });
    const ctx = mission.orders();
    _ = try aigeneric.pushShip(ctx, ship, .launch, carrier, 0);
    aigeneric.objectOrders(ctx, ship);
    const slot = mission.slot(ship);
    try std.testing.expectEqual(null, slot.state.launch.style.routines());
    try std.testing.expectEqual(Step.waiting, slot.state.launch.step);
    try std.testing.expectEqual(objects.NodeOf{ .object = carrier }, slot.riding.?);
    start(mission.objects, ship);
    aigeneric.objectOrders(ctx, ship);
    testing.pastDue(&mission, ctx, ship);
    try std.testing.expectEqual(0, slot.object.order_count);
    try std.testing.expectEqual(null, slot.object.passes_through[0].index());
}
