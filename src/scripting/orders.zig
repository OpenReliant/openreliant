//! The `openreliant.orders` package ([#557](https://github.com/OpenReliant/openreliant/issues/557)),
//! for global and object scripts: what the order table says of each order, the stack of orders each
//! object has, and ending them (`package`). An object's `give_order` gives orders
//! (`objects.methods`); new orders come with the registries
//! ([#558](https://github.com/OpenReliant/openreliant/issues/558)).

const std = @import("std");

const openreliant = @import("openreliant");
const engine = openreliant.engine;
const aigeneric = engine.game.aigeneric;
const orders = engine.game.ai.orders;
const Object = engine.hooks.Object;
const api = @import("api.zig");
const Call = api.Call;
const values = @import("values.zig");
const objects = @import("objects.zig");
const world = @import("world.zig");

/// What the order table says of an order.
pub const OrderInfo = struct {
    /// The developers' name for it, such as `Run Away`; empty for a few.
    name: []const u8,
    /// How firmly it holds once it has started: 0 for an order that gives way to any other.
    /// Otherwise it gives way only to Explode, a one-shot order or an order of a higher priority.
    priority: i32,
    flags: orders.Flags,

    fn of(info: orders.Info) OrderInfo {
        return .{ .name = info.name, .priority = info.priority, .flags = info.flags };
    }
};

/// An order on an object's stack.
pub const OrderEntry = struct {
    order: orders.Order,
    /// The object it's aimed at, where that's an object in the mission; nil otherwise, such as for
    /// an order aimed at nothing, or at a flight group or a squad.
    target: ?Object,
    /// The component of the target it's aimed at; nil for the whole of it.
    component: ?u16,
};

/// An object's stack of orders, the one it follows first.
pub const Stack = values.List(OrderEntry, aigeneric.max_stack);

/// What `openreliant.orders` holds.
pub const package = struct {
    pub const info = api.Function("What the order table says of `order`: its developers' name, its priority and its flags. Nil for an order the table doesn't have.", &.{"order"}, infoOf);
    pub const stack = api.Function("The orders `object` has, the one it follows first, each with what it's aimed at. The ones below carry on as each ends.", &.{"object"}, stackOf);
    pub const cancel = api.Function("Ends the order `object` follows, as an order ends itself: its exit runs, and the order below it carries on. Returns whether it had one. Global scripts can end any object's orders, and an object's scripts their own object's.", &.{"object"}, cancelOrder);
    pub const clear = api.Function("Drops all of `object`'s orders, as a mission's ClearAI does, where the one it follows gives way. Returns whether they were dropped. Global scripts can drop any object's orders, and an object's scripts their own object's.", &.{"object"}, clearAll);
};

fn infoOf(_: Call, order: orders.Order) ?OrderInfo {
    return .of(orders.info(order) orelse return null);
}

fn stackOf(call: Call, object: Object) Stack {
    const all = call.runtime().objects orelse call.raise("orders.stack can only be used while a game runs", .{});
    var found: Stack = .{};
    for (all.slots[object.slot()].stack()) |entry| {
        const ship = entry.target.ship();
        found.append(.{
            .order = entry.order,
            .target = if (ship) |slot| world.objectIn(all, slot) else null,
            .component = entry.target.part(),
        });
    }
    return found;
}

fn cancelOrder(call: Call, object: Object) bool {
    return aigeneric.pop(objects.ordersOf(call, object, "orders.cancel"), object.slot());
}

fn clearAll(call: Call, object: Object) bool {
    const ctx = objects.ordersOf(call, object, "orders.clear");
    aigeneric.clear(ctx, object.slot()) catch return false;
    return ctx.world.objects.slots[object.slot()].object.order_count == 0;
}

test "scripts read the order table and an object's orders, and end them" {
    const gpa = std.testing.allocator;
    const runtime = @import("runtime.zig");
    const packages = @import("packages.zig");
    const bind = @import("bind.zig");
    var mission: engine.game.gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    _ = try mission.add(.predator, .{ 0, 0, 0 });
    const sabre = try mission.add(.sabre, .{ 0, 100, 0 });
    const scripts = try runtime.Runtime.create(gpa, std.testing.io, &.{}, .{ .side = .game, .limits = .{ .time = .fromSeconds(1), .memory = 1 << 20 }, .seed = 1, .version = "0.7.0" });
    defer scripts.destroy();
    objects.register(scripts);
    packages.push(scripts);
    scripts.objects = mission.objects;
    scripts.orders = mission.orders();
    const thread = scripts.state.newSandboxedThread();
    var context: runtime.Context = .{ .runtime = scripts, .mod = 0, .family = .global, .thread = thread, .thread_ref = undefined };
    thread.setThreadData(&context);
    objects.push(thread, sabre);
    thread.setGlobal("sabre");
    objects.push(thread, 0);
    thread.setGlobal("player");
    try bind.testing.runSource(thread,
        \\local orders = require("openreliant.orders")
        \\local info = orders.info("run_away")
        \\assert(info.name == "Run Away" and info.priority == 0 and info.flags.retaliate and not info.flags.one_shot)
        \\assert(sabre:give_order("fly_aimlessly") and sabre:give_order("run_away", player))
        \\local stack = orders.stack(sabre)
        \\assert(#stack == 2 and stack[1].order == "run_away" and stack[1].target == player and stack[1].component == nil)
        \\assert(stack[2].order == "fly_aimlessly" and stack[2].target == nil)
        \\-- Ending Run Away, Fly Aimlessly carries on; clearing drops it.
        \\assert(orders.cancel(sabre) and orders.stack(sabre)[1].order == "fly_aimlessly")
        \\assert(orders.clear(sabre) and #orders.stack(sabre) == 0)
        \\assert(not orders.cancel(sabre))
    );
    // An object's scripts change their own object's orders only.
    context.family = .object;
    context.object = .of(mission.objects, 0);
    try bind.testing.expectSourceError(thread, "require('openreliant.orders').cancel(sabre)", "can't change this object's orders");
}
