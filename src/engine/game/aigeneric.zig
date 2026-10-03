//! `C:\lancer\game\aigeneric.cpp`: each object's stack of orders, the current one on top, which the
//! AI, the mission scripts and the player's controls push and pop, and what runs the current one.
//! [`ai/orders.zig`](ai/orders.zig) has the order table, and [`ai.zig`](ai.zig) its records.
//!
//! **Unverified:** the code from `order_retaliate` (`0x0040C520`) to `order_refused` lies before
//! this file's known code, and `order_pop` onward after it; it does the stack's work.

const std = @import("std");
const assert = std.debug.assert;

const log = std.log.scoped(.orders);

const dte = @import("../../formats/dte.zig");
const ai = @import("ai.zig");
const aieject = @import("aieject.zig");
const aiexplode = @import("aiexplode.zig");
const aifight = @import("aifight.zig");
const aifuncs = @import("aifuncs.zig");
const aidock = @import("aidock.zig");
const ailand = @import("ailand.zig");
const airipper = @import("airipper.zig");
const follow = @import("ai/follow.zig");
const friendly_fire = @import("friendly_fire.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const guns = @import("guns.zig");
const hooks = @import("../hooks.zig");
const input = @import("../input.zig");
const jump = @import("jump.zig");
const launch = @import("launch.zig");
const missiles = @import("missiles.zig");
const motion = @import("motion.zig");
const orders = @import("ai/orders.zig");
const Order = orders.Order;
const tractor = @import("tractor.zig");
const wgate = @import("wgate.zig");

/// Orders an object's stack holds; `order_push` refuses another.
pub const max_stack = 20;

/// Orders from other players an object's queue holds; `order_queue` stops with a fatal error past
/// the last.
pub const max_queued = 20;

/// What an order is aimed at, as the `SetAI` command gives it.
pub const Target = extern struct {
    kind: Kind,
    /// The ship's slot, or the flight group's or squad's index; -1 for none.
    index: i16,
    /// A component of the ship, or -1 for the whole ship.
    component: i16,

    /// An order aimed at nothing, which is how the mission's records leave a target it does not
    /// name.
    pub const none: Target = .{ .kind = .ship, .index = -1, .component = whole };

    /// A target of `kind` whose slot or record is `record`, -1 for none, at `component` as the game
    /// holds it, -1 for the whole.
    pub fn of(kind: Kind, record: ?u16, component: i16) Target {
        return .{ .kind = kind, .index = indexOf(record), .component = component };
    }

    /// The ship in `ship_slot`, whole or, where `part_index` names one, one of its components.
    pub fn at(ship_slot: u16, part_index: ?u16) Target {
        return .of(.ship, ship_slot, indexOf(part_index));
    }

    /// The flight group or the squad of `kind` whose index is `index`, whole; -1 for none.
    pub fn group(kind: Kind, index: ?u16) Target {
        return .of(kind, index, whole);
    }

    /// A slot's or a record's index as a target holds it: the halfword the game stores, -1 for
    /// none.
    pub fn indexOf(found: ?u16) i16 {
        return if (found) |value| @bitCast(value) else -1;
    }

    /// The same index and component, as a ship's: what `order_push_ship` (`0x0040CBF0`) makes of a
    /// target's halves.
    pub fn asShip(target: Target) Target {
        return .{ .kind = .ship, .index = target.index, .component = target.component };
    }

    /// Whether it aims where `other` does: the same kind, index and component.
    pub fn eql(target: Target, other: Target) bool {
        return target.kind == other.kind and target.index == other.index and target.component == other.component;
    }

    /// The slot of the ship it names, where it names one.
    pub fn ship(target: Target) ?u16 {
        return if (target.kind == .ship and target.index >= 0) @intCast(target.index) else null;
    }

    /// The slot its index names, whatever its kind, as the game reads a target's index where it
    /// takes it for a ship's; null for none.
    pub fn slot(target: Target) ?u16 {
        return std.math.cast(u16, target.index);
    }

    /// `slot`, where it is one of `all`'s slots, which the game takes on trust.
    pub fn slotIn(target: Target, all: *const create.Objects) ?u16 {
        const index = target.slot() orelse return null;
        return if (index < all.slots.len) index else null;
    }

    /// The component it names, or null for the whole ship.
    pub fn part(target: Target) ?u16 {
        return if (target.component >= 0) @intCast(target.component) else null;
    }

    /// The `component` of a target that names the whole ship.
    pub const whole: i16 = -1;

    /// Whether it names a whole ship rather than one of its components (`component == -1`).
    pub fn isWhole(target: Target) bool {
        return target.component == whole;
    }

    /// The kinds of the mission's object table, as a word.
    pub const Kind = enum(i16) {
        ship = 0,
        flight_group = 1,
        squad = 2,
        _,
    };

    comptime {
        for (std.enums.values(dte.Object.Kind)) |kind| {
            assert(@intFromEnum(@field(Kind, @tagName(kind))) == @intFromEnum(kind));
        }
        assert(@offsetOf(Target, "index") == 0x2);
        assert(@offsetOf(Target, "component") == 0x4);
        assert(@sizeOf(Target) == 0x6);
    }
};

test Target {
    try std.testing.expectEqual(null, Target.none.ship());
    try std.testing.expectEqual(null, Target.none.part());
    const whole: Target = .at(7, null);
    try std.testing.expectEqual(7, whole.ship());
    try std.testing.expectEqual(null, whole.part());
    try std.testing.expectEqual(2, Target.at(7, 2).part());
    try std.testing.expect(whole.isWhole() and !Target.at(7, 2).isWhole());
    // A flight group names no ship, though its index reads as a slot.
    const group: Target = .{ .kind = .flight_group, .index = 1, .component = Target.whole };
    try std.testing.expectEqual(null, group.ship());
    try std.testing.expectEqual(1, group.slot());
    try std.testing.expectEqual(null, Target.none.slot());
    try std.testing.expectEqual(group, Target.group(.flight_group, 1));
    try std.testing.expectEqual(Target{ .kind = .squad, .index = -1, .component = Target.whole }, Target.group(.squad, null));
    // An index takes its halfword, as the game stores it, and none is -1.
    try std.testing.expectEqual(-1, Target.indexOf(null));
    try std.testing.expectEqual(@as(i16, @bitCast(@as(u16, 40000))), Target.at(40000, null).index);
    // As a ship's, a target keeps its halves.
    try std.testing.expectEqual(Target{ .kind = .ship, .index = 1, .component = Target.whole }, group.asShip());
    try std.testing.expectEqual(Target.none, Target.none.asShip());
    // A command's raw component stays as it gives it.
    try std.testing.expectEqual(Target{ .kind = .ship, .index = 3, .component = 5 }, Target.of(.ship, 3, 5));
    try std.testing.expectEqual(Target.none, Target.of(.ship, null, Target.whole));
    // Targets are equal only in every half.
    try std.testing.expect(Target.at(7, 2).eql(.at(7, 2)));
    try std.testing.expect(!Target.at(7, 2).eql(.at(7, null)));
    try std.testing.expect(!Target.at(1, null).eql(group));
}

/// How far apart ships fly abreast, in the places `Entry.abreast` counts: Formation's and Jump In's
/// (`0x004DC508`).
pub const abreast_spacing: f32 = 3000;

/// An order on an object's stack.
pub const Entry = extern struct {
    order: Order,
    target: Target,
    /// Its place among the orders `SetAI` gives a flight group or a squad, counted from 0 while it
    /// numbers them (`startNumbering`), and 0 otherwise. The escort, the formations, the jumps,
    /// Launch and Warp Out read it.
    sequence: i16,
    /// The order's own data, zero when the order is pushed.
    data: Data,

    pub const Data = extern union {
        /// `player_controls` keeps the mouse's stick position in the first two.
        words: [8]i16,
        /// Fight's: the maneuver to start next.
        fight: aifight.FightData,
        /// Fly's: the speed to fly at, or zero for its full throttle, which it reads as a whole
        /// word from the first two. The entries sit two bytes apart, so the word is not aligned.
        fly: i32 align(2),
        /// Explode's and Eject Spin's: what `object_destroyed` was told.
        destroyed: aiexplode.Data,
        disrupted: aifuncs.DisruptedData,
        launch: launch.Data,
        /// Ship Follow Curve's and Ship Follow Curve Backwards'.
        follow: follow.Data,
        dock: aidock.Data,
    };

    /// How many places out its order's place among its group's (`sequence`) puts its ship
    /// abreast, counting from `first`: half the count, as Jump In's settling pitches by it
    /// (`order_jump_in`).
    pub fn placesOut(entry: Entry, first: i32) i32 {
        return @divTrunc(@as(i32, entry.sequence) + first, 2);
    }

    /// Its place abreast (`placesOut`), signed: to the right for an odd count, to the left for an
    /// even one (`order_formation_init`, `jump_in_place`, and Jump In's settling's roll).
    pub fn abreast(entry: Entry, first: i32) i32 {
        const counted = @as(i32, entry.sequence) + first;
        const side: i32 = if (counted & 1 != 0) 1 else -1;
        return side * @divTrunc(counted, 2);
    }

    comptime {
        assert(@offsetOf(Entry, "target") == 0x2);
        assert(@offsetOf(Entry, "data") == 0xA);
        assert(@sizeOf(Entry) == 0x1A);
    }
};

test Entry {
    var entry: Entry = std.mem.zeroes(Entry);
    // Counted from 1, the first stands at the target, then one place to the left, one to the
    // right, and two to the left.
    for ([_]i32{ 0, -1, 1, -2 }, [_]i32{ 0, 1, 1, 2 }, 0..) |abreast, out, sequence| {
        entry.sequence = @intCast(sequence);
        try std.testing.expectEqual(abreast, entry.abreast(1));
        try std.testing.expectEqual(out, entry.placesOut(1));
    }
    // Counted from 2, the first stands one place to the left, then one to the right, two to the
    // left and two to the right.
    for ([_]i32{ -1, 1, -2, 2 }, [_]i32{ 1, 1, 2, 2 }, 0..) |abreast, out, sequence| {
        entry.sequence = @intCast(sequence);
        try std.testing.expectEqual(abreast, entry.abreast(2));
        try std.testing.expectEqual(out, entry.placesOut(2));
    }
}

/// An order from another player in a multiplayer game, waiting for its frame: an entry of an
/// object's queue.
pub const Queued = extern struct {
    entry: Entry,
    _unknown_1a: u16,
    /// **Unknown.** A byte the sender passes to `order_queue`.
    _unknown_1c: u32,
    /// The tick, counted by `mission_ticks`, from which `object_orders` may start it.
    due: i32,

    comptime {
        assert(@offsetOf(Queued, "due") == 0x20);
        assert(@sizeOf(Queued) == 0x24);
    }
};

/// What the current order keeps between updates, zeroed when an order starts; each order uses it
/// its own way.
pub const State = extern union {
    bytes: [0x90]u8,
    fight: aifight.FightState,
    fly: aifuncs.FlyState,
    mill: aifuncs.MillState,
    aimless: aifuncs.AimlessState,
    find_scoop_up: aifuncs.FindScoopState,
    formation: aifuncs.FormationState,
    list: aifuncs.ListState,
    escort: aifuncs.EscortState,
    find_target: aifuncs.FindTargetState,
    attach: aifuncs.AttachState,
    explode: aiexplode.State,
    eject_player: aieject.PlayerState,
    eject: aieject.State,
    scoop_up: tractor.State,
    disrupted: aifuncs.DisruptedState,
    launch: launch.State,
    jump: jump.State,
    follow: follow.State,
    dock: aidock.State,
    nanny_dock: aidock.NannyState,
    warp: wgate.warp_orders.State,
    land: ailand.State,
    ripper_grab: airipper.GrabState,
    ripper_drop: airipper.DropState,
    ripper_end_drop: airipper.EndDropState,
    ripper_attach: airipper.AttachState,
    friendly_fire: friendly_fire.State,
    gate: wgate.State,
    /// What every order that flies a ship by `motion_follow` holds first.
    follower: motion.Follower,

    comptime {
        assert(@sizeOf(State) == 0x90);
    }
};

/// What the order routines reach besides the object they run for, which `object_orders` reaches
/// through globals: the world the mission runs in, its clock with it, and the devices the player's
/// controls read.
pub const Context = struct {
    world: gameobj.World,
    /// The keyboard and the joystick, which the Player Control order steers by; null where nothing
    /// reads them, as in a test.
    devices: ?*input.Devices = null,

    /// What the orders run against in `world`, with no devices.
    pub fn of(world: gameobj.World) Context {
        return .{ .world = world };
    }
};

/// The fatal error the game stops with as "Cannot set ai %s on ship %s: Still %s".
///
/// **Fix:** the game stops with a fatal error; OpenReliant hands back `error.OrderConflict` to its
/// caller, and `give` logs it.
pub const Error = error{OrderConflict};

/// The original catalogue or a mod's registered order. All runtime metadata uses this lookup.
/// **Improvement:** custom order metadata is supplied by the script registry (#615).
pub fn infoOf(all: *const create.Objects, order: Order) ?orders.Info {
    if (orders.info(order)) |info| return info;
    const scripts = all.scripts orelse return null;
    return (scripts.vtable.order_info orelse return null)(scripts.context, order);
}

fn custom(ctx: Context, index: u16, order: Order, role: ai.routines.Role) bool {
    const scripts = ctx.world.objects.scripts orelse return false;
    return (scripts.vtable.order_run orelse return false)(scripts.context, ctx, index, order, role);
}

/// The sphere the action keeps to (`action_sphere_center`, `0x00515D78`, and
/// `action_sphere_radius`, `0x00515D74`): a fighter that strays out of it with no player near flies
/// back to the object at its centre.
pub const ActionSphere = struct {
    /// The object's slot.
    centre: u16,
    radius: f32,

    /// Where the AI's setup (`ai_first_setup`, `0x0040C9B0`) puts it, around the first slot;
    /// `SetActionCentre` moves it, and gives it this radius when given none.
    pub const default: ActionSphere = .{ .centre = 0, .radius = 220000 };
};

/// How often `ordersUpdate` clears what each object has lately taken (`recent_damage`), in ticks
/// (`0x0040C938`).
pub const damage_window: u32 = 500;

/// The first of the orders numbered 100 and up, the table's second group, every one of which a
/// player's ship takes (`order_refused`).
const players_orders: i16 = orders.groups[1].first;

comptime {
    assert(players_orders == 100);
}

/// `order_refused` (`0x0040CA00`): whether the ship refuses the order outright. A player's ship,
/// which is one of the slots from the first that belong to players, takes only the orders numbered
/// 100 and up and those the table marks as a player's. An order the table does not hold is refused
/// with them.
///
/// **Improvement:** registered orders use their explicit player eligibility flag (#615).
pub fn refused(all: *const create.Objects, index: u16, order: Order) bool {
    if (orders.info(order) == null) {
        if (infoOf(all, order)) |info| return index < all.players and !info.flags.players;
    }
    if (index >= all.players or @intFromEnum(order) >= players_orders) return false;
    const info = infoOf(all, order) orelse return true;
    return !info.flags.players;
}

/// `order_give_way` (`0x0040CA50`): whether the current order makes way for `order`, or for
/// clearing them all where that is null, running its `exit` as it goes.
///
/// An object that is exploding, whose pilot has ejected, or that is being taken apart takes no
/// order at all. Otherwise the way is clear while it has no order or its order has yet to start,
/// and for a one-shot order, which runs over the top of whatever is there. A started order gives
/// way to Explode, and to any order while its own priority is zero or the new order's is higher.
/// Pushing anything else on it is the game's fatal error.
///
/// **Fix:** the game stops with a fatal error; OpenReliant hands back `error.OrderConflict`, which
/// its callers log (`give`).
pub fn giveWay(ctx: Context, index: u16, order: ?Order) Error!bool {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    if (object.flags.outOfAction()) return false;
    const current = slot.current() orelse return true;
    if (object.order_starting) return true;
    // Clearing reads the record before the table in the game, which is zero, so it is neither
    // one-shot nor of any priority.
    const pushed = if (order) |wanted| infoOf(all, wanted) else null;
    if (pushed) |info| if (info.flags.one_shot) return true;
    const running = infoOf(all, current.order) orelse return true;
    if (order == .explode or running.priority == 0) {
        exitOrder(ctx, index, running);
        return true;
    }
    const wanted = pushed orelse return error.OrderConflict;
    if (running.priority >= wanted.priority) return error.OrderConflict;
    exitOrder(ctx, index, running);
    return true;
}

/// Whether `order` has a priority (`ai.Record.priority`): once started, it gives way only to
/// Explode, a one-shot order or an order of higher priority (`giveWay`).
pub fn prioritised(all: *const create.Objects, order: Order) bool {
    const info = infoOf(all, order) orelse return false;
    return info.priority > 0;
}

/// `order_push` (`0x0040CC10`): pushes an order aimed at `target` on the object's stack, and
/// whether it took. It takes at once where the current order is the same order aimed the same way.
/// Otherwise the current order must give way, any equal order deeper in the stack is dropped, and
/// the stack must have room. A pushed order starts with its data zeroed, and unless it is one-shot
/// it is marked as starting and the order state is zeroed with it.
///
/// The game allocates the stack and the state with the object's first order; OpenReliant keeps both
/// in the slot, so an object always has them.
pub fn push(ctx: Context, index: u16, order: Order, target: Target) Error!bool {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    if (refused(all, index, order)) return false;
    if (slot.current()) |running| if (running.order == order and running.target.eql(target)) return true;
    if (!try giveWay(ctx, index, order)) return false;

    // The same order aimed the same way, deeper in the stack, is dropped rather than left to come
    // back once this one is done.
    for (slot.stack(), 0..) |entry, deeper| {
        if (deeper == 0 or entry.order != order or !entry.target.eql(target)) continue;
        remove(slot, deeper);
        break;
    }

    if (object.order_count >= max_stack) return false;
    const count = slot.stack().len;
    std.mem.copyBackwards(Entry, slot.orders[1 .. count + 1], slot.orders[0..count]);
    const sequence: i16 = if (all.order_number) |*next| numbered: {
        defer next.* +%= 1;
        break :numbered @truncate(next.*);
    } else 0;
    slot.orders[0] = .{ .order = order, .target = target, .sequence = sequence, .data = .{ .words = @splat(0) } };
    if (infoOf(all, order)) |info| if (!info.flags.one_shot) start(slot);
    object.order_count += 1;
    return true;
}

/// `orders_numbering_start` (`0x0040CBC0`): the orders pushed from now on are numbered from 0
/// (`Entry.sequence`), as `SetAI` numbers the orders it gives a flight group's or a squad's ships.
pub fn startNumbering(all: *create.Objects) void {
    all.order_number = 0;
}

/// `orders_numbering_stop` (`0x0040CBE0`): the orders pushed from now on take 0 again.
pub fn stopNumbering(all: *create.Objects) void {
    all.order_number = null;
}

/// `order_push_ship` (`0x0040CBF0`): `push`, aimed at the ship in slot `ship`: at its component
/// `part`, or the whole ship where that is null (`Target.at`).
pub fn pushShip(ctx: Context, index: u16, order: Order, ship: u16, part: ?u16) Error!bool {
    return push(ctx, index, order, .at(ship, part));
}

/// `push`, where a conflict (`Error`) is logged in the game's words, "Cannot set ai %s on ship %s:
/// Still %s", and the order is not taken: whether it took.
///
/// **Fix:** the game stops there, as a fatal error.
pub fn give(ctx: Context, index: u16, order: Order, target: Target) bool {
    return push(ctx, index, order, target) catch conflict(ctx.world.objects, index, order);
}

/// `give`, aimed at the ship in a slot, whole where `part` is null (`pushShip`).
pub fn giveShip(ctx: Context, index: u16, order: Order, ship: u16, part: ?u16) bool {
    return pushShip(ctx, index, order, ship, part) catch conflict(ctx.world.objects, index, order);
}

/// Logs the conflict `give` meets, the ship in slot `index` still running the order on top of its
/// stack where `order` was pushed; false, the order not taken.
fn conflict(all: *const create.Objects, index: u16, order: Order) bool {
    const running: Named = .{ .order = all.slots[index].orders[0].order };
    log.warn("Cannot set ai {f} on ship {d}: Still {f}", .{ Named{ .order = order }, index, running });
    return false;
}

/// An order as `give` logs it: its developers' name where the table gives one, else as
/// `Order.format` names it.
const Named = struct {
    order: Order,

    pub fn format(named: Named, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (orders.info(named.order)) |info| if (info.name.len > 0) return writer.writeAll(info.name);
        return writer.print("{f}", .{named.order});
    }
};

/// `order_pop` (`0x0040CE70`): pops the current order, running its `exit` where it has started, and
/// whether there was one. Unless the popped order was one-shot, the order below starts again.
pub fn pop(ctx: Context, index: u16) bool {
    const slot = &ctx.world.objects.slots[index];
    const object = &slot.object;
    const running = slot.current() orelse return false;
    const popped = infoOf(ctx.world.objects, running.order);
    if (popped) |info| if (!object.order_starting) exitOrder(ctx, index, info);
    remove(slot, 0);
    if (popped) |info| if (!info.flags.one_shot) start(slot);
    return true;
}

/// `order_pop` as an order's own routine ends itself: pops the order that runs (`pop`).
pub fn end(ctx: Context, index: u16) void {
    _ = pop(ctx, index);
}

/// `orders_clear` (`0x0040CF50`): drops every order where the current one gives way, running only
/// its `exit`, as the `ClearAI` command does.
pub fn clear(ctx: Context, index: u16) Error!void {
    if (try giveWay(ctx, index, null)) ctx.world.objects.slots[index].object.order_count = 0;
}

/// `orders_pop_all` (`0x0040CF80`): pops every order, running each `exit` in turn.
pub fn popAll(ctx: Context, index: u16) void {
    while (ctx.world.objects.slots[index].object.order_count > 0) {
        if (!pop(ctx, index)) return;
    }
}

/// Removes a registration's orders before its script context closes, including suspended ones.
pub fn forget(ctx: Context, order: Order) void {
    for (0..ctx.world.objects.slots.len) |index| forgetIn(ctx, @intCast(index), order);
}

/// Stops custom orders before an object is retired, while its handle and callbacks are valid.
pub fn forgetCustom(ctx: Context, index: u16) void {
    forgetIn(ctx, index, null);
}

/// Removes one registered order, or all registered orders where `order` is null. Unknown
/// original-file order numbers are left alone, as they are without scripts.
fn forgetIn(ctx: Context, index: u16, order: ?Order) void {
    const slot = &ctx.world.objects.slots[index];
    var at: usize = 0;
    while (at < slot.stack().len) {
        const candidate = slot.orders[at].order;
        const matches = if (order) |wanted| candidate == wanted else orders.info(candidate) == null and infoOf(ctx.world.objects, candidate) != null;
        if (!matches) {
            at += 1;
            continue;
        }
        if (at == 0) {
            _ = pop(ctx, index);
        } else remove(slot, at);
    }
}

/// Ends an order the object has started: its `exit` runs (`runExit`), and the scripts hear of it
/// (`order_ended`).
fn exitOrder(ctx: Context, index: u16, info: orders.Info) void {
    runExit(ctx, index, info);
    hooks.tell(ctx, .order_ended, .{ .object = .of(index), .order = info.order });
}

/// Marks the current order as one that has yet to start and clears what an order keeps between its
/// updates, which both `order_push` and `order_pop` do.
fn start(slot: *create.Slot) void {
    slot.object.order_starting = true;
    slot.object.fighting = .none;
    slot.state = .{ .bytes = @splat(0) };
}

/// Removes entry `at` of the slot's stack, the entries below it moving up a place; nothing where
/// the stack holds no such entry.
fn remove(slot: *create.Slot, at: usize) void {
    const live = slot.stack();
    if (at >= live.len) return;
    std.mem.copyForwards(Entry, live[at .. live.len - 1], live[at + 1 ..]);
    slot.object.order_count -= 1;
}

/// `object_orders` (`0x0040C5F0`): runs an object's current order. A `retaliate` order lets the
/// ship turn on whoever is shooting it first. Both burns are cleared, so an order that burns sets
/// them again each time it runs. A one-shot order runs its update, pops itself and lets the order
/// below run in the same pass; any other runs its `init` where it is starting, which the scripts
/// hear of (`order_started`), then its update. Afterwards the object's own state has the last word:
/// engines that are disabled hold the throttle at nothing, an empty tank stops both burns, and only
/// a ship that can reverse keeps reverse thrust.
///
/// **Improvement** (`input.force.Unread.played`): the player's afterburner lighting and going out
/// starts and stops `Afterburn` on the controller (`input.force.Forces.afterburner`).
///
/// Not ported: the orders other players' machines queue, which are multiplayer's
/// ([#55](https://github.com/OpenReliant/openreliant/issues/55)).
///
/// **Improvement:** registered orders run protected script callbacks through the engine's script
/// bridge. Completion or failure pops the order using the existing stack rules (#615).
pub fn objectOrders(ctx: Context, index: u16) void {
    if (hooks.enter(.object_orders, objectOrders, .{ ctx, index })) |done| return done;
    const slot = &ctx.world.objects.slots[index];
    const object = &slot.object;
    if (slot.current()) |entry| {
        if (infoOf(ctx.world.objects, entry.order)) |info| if (info.flags.retaliate) retaliate(ctx, index);
    }
    object.afterburner = false;
    object.reverse_thrust = false;
    if (slot.current()) |entry| run: {
        const running = infoOf(ctx.world.objects, entry.order) orelse break :run;
        if (!running.flags.one_shot) {
            if (object.order_starting) {
                if (orders.info(running.order) == null) {
                    object.order_starting = false;
                    if (!custom(ctx, index, running.order, .init)) {
                        _ = pop(ctx, index);
                        break :run;
                    }
                } else runInit(ctx, index, running);
                object.order_starting = false;
                hooks.tell(ctx, .order_started, .{ .object = .of(index), .order = running.order });
            }
            if (orders.info(running.order) == null) {
                if (!custom(ctx, index, running.order, .update)) _ = pop(ctx, index);
            } else runUpdate(ctx, index, running);
        } else {
            if (orders.info(running.order) == null) {
                _ = custom(ctx, index, running.order, .update);
            } else runUpdate(ctx, index, running);
            const starting = object.order_starting;
            _ = pop(ctx, index);
            object.order_starting = starting;
            objectOrders(ctx, index);
        }
    }
    if (object.flags.engines_disabled) {
        object.throttle = 0;
        object.afterburner = false;
        object.reverse_thrust = false;
    }
    if (object.afterburner_fuel < 1) {
        object.afterburner = false;
        object.reverse_thrust = false;
    }
    if (!object.flags.can_reverse) object.reverse_thrust = false;
    if (index == ctx.world.objects.player) if (ctx.world.forces) |forces| forces.afterburner(object.afterburner, ctx.world.clock.frame_start);
}

/// `orders_update` (`0x0040C8F0`): the orders of every object that is not disabled, once a frame,
/// in the loops' order, and after them its turrets' steps, where its guns are not disabled
/// (`guns.turrets.step`). Every `damage_window` ticks it first clears what each object has lately
/// taken, which is what the ships retaliate by.
pub fn ordersUpdate(ctx: Context) void {
    const all = ctx.world.objects;
    const clock = ctx.world.clock;
    if (clock.game_ticks > all.damage_cleared_at) {
        for (all.slots[0..all.count]) |*slot| slot.object.recent_damage = 0;
        all.damage_cleared_at = clock.game_ticks + damage_window;
    }
    var walk = all.walk();
    while (walk.next()) |index| {
        if (all.slots[index].object.flags.disabled) continue;
        objectOrders(ctx, index);
        if (!all.slots[index].object.flags.guns_disabled) guns.turrets.step(ctx.world, index);
    }
}

/// The share of its full armour (`create.ShipCombat.fullArmor`) a ship must take before it turns on
/// its attacker (`0x004DC484`).
const retaliation_share: f32 = 0.7;

/// `order_retaliate` (`0x0040C520`): while the current order lets the ship retaliate, enough damage
/// sends it after whoever last hit it. Both ships must be of the fighter class, the attacker must
/// be on the other side and not already the order's target, and a ship told not to be disturbed
/// stays on its order.
pub fn retaliate(ctx: Context, index: u16) void {
    if (hooks.enter(.order_retaliate, retaliate, .{ ctx, index })) |done| return done;
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const combat = slot.combat orelse return;
    if (combat.class != .fighter) return;
    if (combat.fullArmor() * retaliation_share > object.recent_damage) return;
    if (object.flags.do_not_disturb) return;

    const attacking = object.last_attacker.index() orelse return;
    const attacker: Target = .at(attacking, null);
    if (!ai.targetValid(all, attacker, .{})) return;
    if (attacker.index == slot.orders[0].target.index) return;
    const other = &all.slots[attacking];
    if (other.object.side == object.side) return;
    const other_combat = other.combat orelse return;
    if (other_combat.class != .fighter) return;
    _ = giveShip(ctx, index, .fight, attacking, null);
}

/// The `init` of the order, where OpenReliant runs it, which scripts can hook under the routine's
/// name (`hooks.routine_hooks`). The orders whose `init` isn't ported yet do nothing
/// ([#30](https://github.com/OpenReliant/openreliant/issues/30)), the warps' among them
/// ([#481](https://github.com/OpenReliant/openreliant/issues/481)) and multiplayer's
/// ([#55](https://github.com/OpenReliant/openreliant/issues/55)).
fn runInit(ctx: Context, index: u16, info: orders.Info) void {
    if (hooks.enterRoutine(.init, runInit, ctx, index, info)) |done| return done;
    switch (info.order) {
        .fly => aifuncs.flyInit(ctx, index),
        .mill => aifuncs.millInit(ctx, index),
        .fly_aimlessly => aifuncs.flyAimlesslyInit(ctx, index),
        .formation => aifuncs.formationInit(ctx, index),
        .escort => aifuncs.escortInit(ctx, index),
        .object_attach => aifuncs.attachInit(ctx, index),
        .random_spin_slow => aifuncs.randomSpinInit(ctx, index, .slow),
        .random_spin_medium => aifuncs.randomSpinInit(ctx, index, .medium),
        .random_spin_fast => aifuncs.randomSpinInit(ctx, index, .fast),
        .explode => aiexplode.init(ctx, index),
        .eject_player => aieject.playerInit(ctx, index),
        .eject => aieject.init(ctx, index),
        .eject_spin => aieject.spinInit(ctx, index),
        .eject_106 => aieject.abandonedInit(ctx, index),
        .scoop_up => tractor.scoopUpInit(ctx, index),
        .fight => aifight.init(ctx, index),
        .torpedo => missiles.torpedoInit(ctx, index),
        .find_scoop_up, .make_capship_list_left, .make_capship_list_right => aifuncs.firstStepInit(ctx, index),
        .disrupted => aifuncs.disruptedInit(ctx, index),
        .launch => launch.init(ctx, index),
        .jump_in, .jump_in_40 => jump.inInit(ctx, index),
        .jump_out, .jump_out_41 => jump.outInit(ctx, index),
        .ship_follow_curve => follow.init(ctx, index),
        .ship_follow_curve_backwards => follow.backwardsInit(ctx, index),
        .dock => aidock.init(ctx, index),
        .land => ailand.init(ctx, index),
        .ripper_grabs_target_object => airipper.grabInit(ctx, index),
        .make_ripper_drop_what_its_carrying => airipper.dropInit(ctx, index),
        .ripper_end_drop_object => airipper.endDropInit(ctx, index),
        .ripper_attach_cargo_pod_to_mammoth => airipper.attachInit(ctx, index),
        .friendly_fire => friendly_fire.init(ctx, index),
        .fixed_gate_jump_in => wgate.jumpInInit(ctx, index),
        .fixed_gate_jump_out => wgate.jumpOutInit(ctx, index),
        .fixed_gate_open => wgate.openInit(ctx, index),
        .fixed_gate_close => wgate.closeInit(ctx, index),
        .fixed_gate_collapse => wgate.collapseInit(ctx, index),
        // Warp steps share their independent tunnel record.
        .warp_in => wgate.warp_orders.inInit(ctx, index),
        .warp_out => wgate.warp_orders.outInit(ctx, index),
        // Not ported: multiplayer's ([#55](https://github.com/OpenReliant/openreliant/issues/55)).
        .deathmatch_respawn_effect => {},
        // Not ported ([#30](https://github.com/OpenReliant/openreliant/issues/30)).
        .formation_regroup,
        .patrol_route,
        .turns_object_lights_on,
        .make_boridin_section_break_away,
        .rotate_boridin_breakaway_warp_projector,
        .start_warp_projection_from_boridin,
        .avoid_target,
        .dark_reign_shoot_110,
        => {},
        // The table gives these no `init`, or only `noop` (`0x004983A0`).
        .do_nothing,
        .launch_missile,
        .unnamed_3,
        .run_away,
        .find_new_target,
        .toggle_cloak,
        .slow_rotate,
        .match_speed,
        .dark_reign_shoot,
        .move_to_spawn_pos,
        .turns_object_lights_off,
        .huuuuuuuge_explosion,
        .immediately_set_ship_to_zero_velocity_and_rotation,
        .fly_ship_backwards,
        .player_control,
        .multiplayer_control,
        .eject_fighter_attack,
        .deathmatch_dark_reign_target,
        .unnamed_200,
        => {},
        // A number the table does not hold.
        _ => {},
    }
}

/// The `update` of the order, where OpenReliant runs it, which scripts can hook under the routine's
/// name (`hooks.routine_hooks`). The orders whose update isn't ported yet do nothing
/// ([#30](https://github.com/OpenReliant/openreliant/issues/30)), the warps' among them
/// ([#481](https://github.com/OpenReliant/openreliant/issues/481)) and multiplayer's
/// ([#55](https://github.com/OpenReliant/openreliant/issues/55)).
fn runUpdate(ctx: Context, index: u16, info: orders.Info) void {
    if (hooks.enterRoutine(.update, runUpdate, ctx, index, info)) |done| return done;
    switch (info.order) {
        .do_nothing => aifuncs.doNothing(ctx, index),
        .fly => aifuncs.fly(ctx, index),
        .mill => aifuncs.mill(ctx, index),
        .fly_aimlessly => aifuncs.flyAimlessly(ctx, index),
        .find_scoop_up => aifuncs.findScoopUp(ctx, index),
        .formation => aifuncs.formation(ctx, index),
        .escort => aifuncs.escort(ctx, index),
        .find_new_target => aifuncs.findNewTarget(ctx, index),
        .object_attach => aifuncs.attach(ctx, index),
        .toggle_cloak => aifuncs.toggleCloak(ctx, index),
        .run_away => aifuncs.runAway(ctx, index),
        .slow_rotate => aifuncs.slowRotate(ctx, index),
        .match_speed => aifuncs.matchSpeed(ctx, index),
        .immediately_set_ship_to_zero_velocity_and_rotation => aifuncs.zeroVelocity(ctx, index),
        .fly_ship_backwards => aifuncs.flyBackwards(ctx, index),
        .player_control => input.playerControlOrder(ctx, index),
        .explode => aiexplode.update(ctx, index),
        .huuuuuuuge_explosion => aiexplode.huge(ctx, index),
        .eject_player => aieject.player(ctx, index),
        .eject => aieject.update(ctx, index),
        .eject_spin => aieject.spin(ctx, index),
        .eject_106 => aieject.abandoned(ctx, index),
        .scoop_up => tractor.scoopUp(ctx, index),
        .eject_fighter_attack => aieject.fighterAttack(ctx, index),
        .fight => aifight.update(ctx, index),
        .torpedo => missiles.torpedo(ctx, index),
        .make_capship_list_left => aifuncs.capshipList(ctx, index, .left),
        .make_capship_list_right => aifuncs.capshipList(ctx, index, .right),
        .disrupted => aifuncs.disrupted(ctx, index),
        .launch_missile => aifuncs.launchMissile(ctx, index),
        .unnamed_3 => aifuncs.launchJackHammer(ctx, index),
        .launch => launch.update(ctx, index),
        .jump_in, .jump_in_40 => jump.inUpdate(ctx, index),
        .jump_out, .jump_out_41 => jump.outUpdate(ctx, index),
        .ship_follow_curve => follow.update(ctx, index),
        .ship_follow_curve_backwards => follow.backwardsUpdate(ctx, index),
        .dock => aidock.update(ctx, index),
        .land => ailand.update(ctx, index),
        .ripper_grabs_target_object => airipper.grab(ctx, index),
        .make_ripper_drop_what_its_carrying => airipper.drop(ctx, index),
        .ripper_end_drop_object => airipper.endDrop(ctx, index),
        .ripper_attach_cargo_pod_to_mammoth => airipper.attach(ctx, index),
        .friendly_fire => friendly_fire.update(ctx, index),
        .fixed_gate_jump_in => wgate.jumpIn(ctx, index),
        .fixed_gate_jump_out => wgate.jumpOut(ctx, index),
        .fixed_gate_open => wgate.open(ctx, index),
        .fixed_gate_close => wgate.close(ctx, index),
        .fixed_gate_collapse => wgate.collapse(ctx, index),
        // Warp steps share their independent tunnel record.
        .warp_in => wgate.warp_orders.inUpdate(ctx, index),
        .warp_out => wgate.warp_orders.outUpdate(ctx, index),
        // Not ported: multiplayer's ([#55](https://github.com/OpenReliant/openreliant/issues/55)).
        .multiplayer_control, .deathmatch_respawn_effect => {},
        // Not ported ([#30](https://github.com/OpenReliant/openreliant/issues/30)).
        .formation_regroup,
        .patrol_route,
        .dark_reign_shoot,
        .move_to_spawn_pos,
        .turns_object_lights_on,
        .turns_object_lights_off,
        .start_warp_projection_from_boridin,
        .avoid_target,
        .dark_reign_shoot_110,
        => {},
        // The table gives these no update, or only `noop` (`0x004983A0`).
        .random_spin_slow,
        .random_spin_medium,
        .random_spin_fast,
        .make_boridin_section_break_away,
        .rotate_boridin_breakaway_warp_projector,
        .deathmatch_dark_reign_target,
        .unnamed_200,
        => {},
        // A number the table does not hold.
        _ => {},
    }
}

/// The `exit` of the order, where OpenReliant runs it, which scripts can hook under the routine's
/// name (`hooks.routine_hooks`). Dark reign shoot's isn't ported yet
/// ([#30](https://github.com/OpenReliant/openreliant/issues/30)), nor multiplayer's
/// ([#55](https://github.com/OpenReliant/openreliant/issues/55)).
fn runExit(ctx: Context, index: u16, info: orders.Info) void {
    if (orders.info(info.order) == null) {
        if (!info.flags.one_shot) _ = custom(ctx, index, info.order, .exit);
        return;
    }
    if (hooks.enterRoutine(.exit, runExit, ctx, index, info)) |done| return done;
    switch (info.order) {
        .scoop_up => tractor.scoopUpExit(ctx, index),
        .disrupted => aifuncs.disruptedExit(ctx, index),
        .ship_follow_curve => follow.exit(ctx, index),
        .ship_follow_curve_backwards => follow.backwardsExit(ctx, index),
        .dock => aidock.exit(ctx, index),
        .ripper_grabs_target_object => airipper.grabExit(ctx, index),
        // Not ported ([#30](https://github.com/OpenReliant/openreliant/issues/30)).
        .dark_reign_shoot_110 => {},
        // Not ported: multiplayer's ([#55](https://github.com/OpenReliant/openreliant/issues/55)).
        .deathmatch_respawn_effect => {},
        // The table gives the others no `exit`, which the build checks, so that one it gives
        // needs its own arm.
        inline else => |order| comptime {
            @setEvalBranchQuota(orders.table.len * orders.table.len);
            assert(orders.info(order).?.exit == null);
        },
        // A number the table does not hold.
        _ => {},
    }
}

test {
    std.testing.refAllDecls(@This());
}

test prioritised {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    try std.testing.expect(prioritised(mission.objects, .land));
    try std.testing.expect(prioritised(mission.objects, .explode));
    try std.testing.expect(!prioritised(mission.objects, .player_control));
}

test push {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();
    const index = try mission.addOther(@splat(0));
    const slot = &all.slots[index];

    try std.testing.expect(try push(ctx, index, .slow_rotate, .none));
    try std.testing.expectEqual(1, slot.object.order_count);
    try std.testing.expectEqual(Order.slow_rotate, slot.orders[0].order);
    try std.testing.expect(slot.object.order_starting);

    // The same order aimed the same way is already what it is doing.
    try std.testing.expect(try push(ctx, index, .slow_rotate, .none));
    try std.testing.expectEqual(1, slot.object.order_count);

    // Another order goes on top, and the one below waits.
    try std.testing.expect(try push(ctx, index, .do_nothing, .none));
    try std.testing.expectEqual(2, slot.object.order_count);
    try std.testing.expectEqual(Order.do_nothing, slot.orders[0].order);
    try std.testing.expectEqual(Order.slow_rotate, slot.orders[1].order);

    // Pushing the deeper order again moves it up rather than leaving it twice on the stack.
    try std.testing.expect(try push(ctx, index, .slow_rotate, .none));
    try std.testing.expectEqual(2, slot.object.order_count);
    try std.testing.expectEqual(Order.slow_rotate, slot.orders[0].order);
    try std.testing.expectEqual(Order.do_nothing, slot.orders[1].order);

    // Deeper in the middle of the stack, it is taken out from between the others, which keep
    // their order.
    try std.testing.expect(try push(ctx, index, .mill, .none));
    try std.testing.expectEqual(3, slot.object.order_count);
    try std.testing.expect(try push(ctx, index, .slow_rotate, .none));
    try std.testing.expectEqual(3, slot.object.order_count);
    for ([_]Order{ .slow_rotate, .mill, .do_nothing }, slot.stack()) |order, entry| {
        try std.testing.expectEqual(order, entry.order);
    }

    // A full stack takes no more.
    slot.object.order_count = max_stack;
    try std.testing.expect(!try push(ctx, index, .fly, .none));
}

test remove {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const index = try mission.addOther(@splat(0));
    const slot = mission.slot(index);
    for ([_]Order{ .fly, .mill, .slow_rotate }) |order| try std.testing.expect(try push(ctx, index, order, .none));

    // The middle entry goes, and the other two keep their order.
    remove(slot, 1);
    try std.testing.expectEqual(2, slot.object.order_count);
    try std.testing.expectEqual(Order.slow_rotate, slot.orders[0].order);
    try std.testing.expectEqual(Order.fly, slot.orders[1].order);
    // An entry past the stack is none to remove.
    remove(slot, 2);
    try std.testing.expectEqual(2, slot.object.order_count);
}

test startNumbering {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();
    const first = try mission.addOther(@splat(0));
    const second = try mission.addOther(.{ 1000, 0, 0 });

    // While the orders are numbered, each pushed takes the next number, whatever its ship.
    startNumbering(all);
    _ = try push(ctx, first, .fly, .none);
    _ = try push(ctx, second, .fly, .none);
    _ = try push(ctx, first, .slow_rotate, .none);
    try std.testing.expectEqual(2, all.slots[first].orders[0].sequence);
    try std.testing.expectEqual(1, all.slots[second].orders[0].sequence);
    // Otherwise each takes 0.
    stopNumbering(all);
    _ = try push(ctx, second, .slow_rotate, .none);
    try std.testing.expectEqual(0, all.slots[second].orders[0].sequence);
    try std.testing.expectEqual(1, all.slots[second].orders[1].sequence);
}

test "a player's ship refuses the orders that are not its own" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const index = try mission.add(.predator, @splat(0));
    const none: Target = .none;
    try std.testing.expectEqual(0, index);

    // Slow Rotate is numbered below 100 and is not marked as a player's.
    try std.testing.expect(!try push(ctx, index, .slow_rotate, none));
    // Eject is marked as one, and Player Control is numbered above 100.
    try std.testing.expect(try push(ctx, index, .eject, none));
    try std.testing.expect(try push(ctx, index, .player_control, none));
    // Another ship takes the orders the player's refuses.
    const other = try mission.addOther(@splat(0));
    try std.testing.expect(try push(ctx, other, .slow_rotate, none));
}

test pop {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();
    const index = try mission.addOther(@splat(0));
    const slot = &all.slots[index];
    const none: Target = .none;

    try std.testing.expect(!pop(ctx, index));
    try std.testing.expect(try push(ctx, index, .fly, none));
    try std.testing.expect(try push(ctx, index, .player_control, none));
    slot.object.order_starting = false;

    try std.testing.expect(pop(ctx, index));
    try std.testing.expectEqual(1, slot.object.order_count);
    // The order below starts again, with the state it kept cleared.
    try std.testing.expect(slot.object.order_starting);
    try std.testing.expectEqual(Order.fly, slot.orders[0].order);

    popAll(ctx, index);
    try std.testing.expectEqual(0, slot.object.order_count);
    // A count below 0 is no orders: nothing pops.
    slot.object.order_count = -1;
    try std.testing.expect(!pop(ctx, index));
    try std.testing.expectEqual(-1, slot.object.order_count);
}

test giveWay {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();
    const index = try mission.addOther(@splat(0));
    const slot = &all.slots[index];
    const none: Target = .none;

    // Eject has priority 98: once it has started, an ordinary order cannot push it aside.
    try std.testing.expect(try push(ctx, index, .eject, none));
    slot.object.order_starting = false;
    try std.testing.expectError(error.OrderConflict, push(ctx, index, .fly, none));
    try std.testing.expectError(error.OrderConflict, clear(ctx, index));
    // Explode, at 99, does.
    try std.testing.expect(try push(ctx, index, .explode, none));

    // A count below 0 is no orders: the way is clear.
    const count = slot.object.order_count;
    slot.object.order_count = -1;
    try std.testing.expect(try giveWay(ctx, index, .fly));
    slot.object.order_count = count;

    // An object that is being taken apart takes no order at all.
    slot.object.flags.exploding = true;
    try std.testing.expect(!try push(ctx, index, .fly, none));
}

test give {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const index = try mission.addOther(@splat(0));
    const slot = mission.slot(index);
    try std.testing.expect(give(ctx, index, .do_nothing, .none));
    // Eject has priority 98: once it has started, an ordinary order is not taken, and the stack
    // stays as it was.
    try std.testing.expect(give(ctx, index, .eject, .none));
    slot.object.order_starting = false;
    const before = slot.orders;
    try std.testing.expect(!give(ctx, index, .fly, .none));
    try std.testing.expect(!giveShip(ctx, index, .fight, index, null));
    try std.testing.expectEqual(2, slot.object.order_count);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&slot.orders));
    try std.testing.expect(!slot.object.order_starting);
}

test "Named.format" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Eject", try std.fmt.bufPrint(&buffer, "{f}", .{Named{ .order = .eject }}));
    // A nameless order goes by OpenReliant's name for it, and one the table lacks by its number.
    try std.testing.expectEqualStrings("unnamed_3", try std.fmt.bufPrint(&buffer, "{f}", .{Named{ .order = .unnamed_3 }}));
    try std.testing.expectEqualStrings("order 99", try std.fmt.bufPrint(&buffer, "{f}", .{Named{ .order = @enumFromInt(99) }}));
}

test objectOrders {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();
    const index = try mission.addOther(@splat(0));
    const slot = &all.slots[index];
    const none: Target = .none;

    // Order 44 stops the ship and pops itself, leaving the order below to run the next time round.
    try std.testing.expect(try push(ctx, index, .slow_rotate, none));
    try std.testing.expect(try push(ctx, index, .immediately_set_ship_to_zero_velocity_and_rotation, none));
    slot.object.velocity = .{ .x = 0, .y = 0, .z = 100 };
    objectOrders(ctx, index);
    try std.testing.expectEqual(0, slot.object.velocity.z);
    try std.testing.expectEqual(1, slot.object.order_count);
    try std.testing.expectEqual(0, slot.object.yaw_input);
    objectOrders(ctx, index);
    try std.testing.expectEqual(aifuncs.spin_input, slot.object.yaw_input);

    // A one-shot order runs, pops, and the order below runs in the same pass. The ship's model
    // cannot cloak, so Toggle Cloak changes nothing else.
    slot.object.yaw_input = 0;
    try std.testing.expect(try push(ctx, index, .toggle_cloak, none));
    objectOrders(ctx, index);
    try std.testing.expectEqual(1, slot.object.order_count);
    try std.testing.expectEqual(aifuncs.spin_input, slot.object.yaw_input);

    // Both burns are cleared before the order runs, and neither lasts without fuel.
    slot.object.afterburner = true;
    slot.object.afterburner_fuel = 0;
    objectOrders(ctx, index);
    try std.testing.expect(!slot.object.afterburner);

    // Disabled engines hold the throttle at nothing.
    try std.testing.expect(try push(ctx, index, .fly, none));
    slot.object.flags.engines_disabled = true;
    objectOrders(ctx, index);
    try std.testing.expectEqual(0, slot.object.throttle);
}

test retaliate {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    _ = try mission.add(.predator, @splat(0));
    const ship = try mission.add(.sabre, .{ 0, 0, 1000 });
    const attacker = try mission.add(.sabre, .{ 0, 0, 2000 });
    const slot = mission.slot(ship);
    slot.object.side = .hostile;
    mission.slot(attacker).object.side = .friendly;
    mission.slot(attacker).object.flags.targetable = true;
    try std.testing.expect(try push(ctx, ship, .do_nothing, .none));
    slot.object.last_attacker = .of(attacker);
    const enough = slot.combat.?.fullArmor() * retaliation_share;

    // Short of enough damage, or told not to be disturbed, it stays on its order.
    slot.object.recent_damage = enough - 1;
    retaliate(ctx, ship);
    try std.testing.expectEqual(Order.do_nothing, slot.orders[0].order);
    slot.object.recent_damage = enough;
    slot.object.flags.do_not_disturb = true;
    retaliate(ctx, ship);
    try std.testing.expectEqual(Order.do_nothing, slot.orders[0].order);
    // Hurt enough, it turns on whoever hit it last.
    slot.object.flags.do_not_disturb = false;
    retaliate(ctx, ship);
    try std.testing.expectEqual(Order.fight, slot.orders[0].order);
    try std.testing.expectEqual(attacker, slot.orders[0].target.ship());
    // Not on its own side.
    try std.testing.expect(try push(ctx, ship, .do_nothing, .none));
    mission.slot(attacker).object.side = .hostile;
    retaliate(ctx, ship);
    try std.testing.expectEqual(Order.do_nothing, slot.orders[0].order);
}

test ordersUpdate {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();
    const none: Target = .none;
    // The player's slot comes first, then three ships that all turn on the spot.
    for (0..4) |_| _ = try mission.add(.predator, @splat(0));
    for (1..4) |index| _ = try push(ctx, @intCast(index), .slow_rotate, none);

    all.slots[2].object.flags.disabled = true;
    for (all.slots[0..4]) |*slot| slot.object.recent_damage = 10;
    mission.clock.game_ticks = 1;
    ordersUpdate(ctx);

    // Every object that is not disabled has run its order, and what they had taken is cleared.
    try std.testing.expectEqual(aifuncs.spin_input, all.slots[1].object.yaw_input);
    try std.testing.expectEqual(0, all.slots[2].object.yaw_input);
    try std.testing.expectEqual(aifuncs.spin_input, all.slots[3].object.yaw_input);
    try std.testing.expectEqual(0, all.slots[1].object.recent_damage);
    try std.testing.expectEqual(damage_window + 1, all.damage_cleared_at);

    // It clears them once a window, not every frame.
    all.slots[1].object.recent_damage = 10;
    mission.clock.game_ticks = damage_window;
    ordersUpdate(ctx);
    try std.testing.expectEqual(10, all.slots[1].object.recent_damage);
}
