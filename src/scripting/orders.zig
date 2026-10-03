//! Order inspection and custom order callbacks (#615). Registrations belong to a global script's
//! context and use the existing engine stack. Closing that context removes its orders first.

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
const runtime = @import("runtime.zig");
const luau = @import("luau.zig");
const State = luau.State;
const log = std.log.scoped(.scripts);
const Role = engine.game.ai.routines.Role;

/// First session-local order number, derived from the original catalogue rather than fixed.
pub const first_custom: i32 = first: {
    var highest: i32 = 0;
    for (orders.table) |info| highest = @max(highest, @intFromEnum(info.order));
    break :first highest + 1;
};

fn orderAt(index: usize) orders.Order {
    return @enumFromInt(first_custom + @as(i32, @intCast(index)));
}

fn pushObject(state: *State, object: ?Object) void {
    values.push(state, ?Object, object);
}

const Registered = struct {
    context: *runtime.Context,
    name: runtime.Name,
    qualified: runtime.Name,
    flags: orders.Flags,
    priority: i32,
    callbacks: ?luau.Ref,
    enabled: bool = true,
};

/// Registrations are never renumbered or reused while this runtime lives.
pub const Registry = struct {
    entries: std.ArrayList(Registered) = .empty,
    running: bool = false,

    pub fn deinit(registry: *Registry, scripts: *runtime.Runtime) void {
        for (registry.entries.items) |*entry| registry.release(scripts, entry);
        registry.entries.deinit(scripts.gpa);
    }

    fn release(_: *Registry, scripts: *runtime.Runtime, entry: *Registered) void {
        if (entry.callbacks) |ref| scripts.release(ref);
        entry.callbacks = null;
    }

    fn position(registry: *Registry, order: orders.Order) ?usize {
        const index = @as(i32, @intFromEnum(order)) - first_custom;
        if (index < 0 or index >= registry.entries.items.len) return null;
        return @intCast(index);
    }

    pub fn info(registry: *Registry, order: orders.Order) ?orders.Info {
        const entry = &registry.entries.items[registry.position(order) orelse return null];
        return .{ .order = order, .name = entry.qualified.slice(), .flags = entry.flags, .priority = if (entry.enabled) entry.priority else 0, .init = null, .update = null, .exit = null };
    }

    /// Names are qualified by mod folder/archive identity, not the manifest's display name.
    pub fn find(registry: *Registry, name: []const u8) ?orders.Order {
        for (registry.entries.items, 0..) |entry, index| {
            if (!entry.enabled or entry.context.closed) continue;
            if (std.mem.eql(u8, name, entry.qualified.slice())) return orderAt(index);
        }
        return null;
    }

    pub fn removeContext(registry: *Registry, scripts: *runtime.Runtime, context: *runtime.Context) void {
        registry.removeSince(scripts, context, 0);
    }

    pub fn removeSince(registry: *Registry, scripts: *runtime.Runtime, context: *runtime.Context, first: usize) void {
        for (first..registry.entries.items.len) |index| {
            if (registry.entries.items[index].context != context) continue;
            if (scripts.orders) |ctx| aigeneric.forget(ctx, orderAt(index));
            registry.entries.items[index].enabled = false;
            registry.release(scripts, &registry.entries.items[index]);
        }
    }

    pub fn endMission(registry: *Registry, scripts: *runtime.Runtime) void {
        if (scripts.orders) |ctx| for (0..registry.entries.items.len) |index| {
            aigeneric.forget(ctx, orderAt(index));
        };
    }

    pub fn run(registry: *Registry, scripts: *runtime.Runtime, ctx: aigeneric.Context, index: u16, order: orders.Order, role: Role) bool {
        const at = registry.position(order) orelse return false;
        const held = registry.entries.items[at];
        if ((!held.enabled and role != .exit) or held.context.closed or registry.running) return false;
        const callbacks = held.callbacks orelse return false;
        registry.running = true;
        defer registry.running = false;
        const aim = ctx.world.objects.slots[index].orders[0].target.ship();
        const target: ?Object = if (aim) |slot| world.objectIn(ctx.world.objects, slot) else null;
        const ship_ref = scripts.make(pushObject, .{@as(?Object, .of(index))}) orelse return false;
        defer scripts.release(ship_ref);
        const target_ref = scripts.make(pushObject, .{target}) orelse return false;
        defer scripts.release(target_ref);
        const seconds = @as(f32, @floatFromInt(ctx.world.clock.frameTicks())) / engine.game.main.ticks_per_second;
        const called = scripts.callIn(held.context, callbacks, @tagName(role), .{ ship_ref, target_ref, seconds }) orelse return true;
        if (called == .failed) {
            registry.entries.items[at].enabled = false;
            log.warn("{s}: custom order {s} failed and is disabled", .{ held.context.modOf().name, held.name.slice() });
            return false;
        }
        return role != .update or called != .returned_false;
    }
};

fn registerOrder(state: *State) i32 {
    const call = Call.of(state, "orders.register");
    if (call.context.family != .global) call.raise("orders.register requires a global script", .{});
    const scripts = call.runtime();
    if (scripts.custom_orders.running) call.raise("orders cannot be registered from an order callback", .{});
    const name = values.read(state, []const u8, 1, "name");
    const key = runtime.Name.of(name) orelse call.raise("order name is too long", .{});
    if (!openreliant.dte.source.validId(name)) call.raise("order name must be an identifier", .{});
    var qualified_buffer: [runtime.max_name]u8 = undefined;
    const qualified = runtime.Name.of(std.fmt.bufPrint(&qualified_buffer, "{s}:{s}", .{ call.context.modOf().name, name }) catch call.raise("qualified order name is too long", .{})).?;
    if (state.typeOf(2) != .table) call.raise("orders.register expects a definition table", .{});
    var flags: orders.Flags = .{};
    var priority: i32 = 0;
    state.pushNil();
    while (state.next(2)) {
        const field = (if (state.typeOf(-2) == .string) state.toString(-2) else null) orelse call.raise("order definition keys must be names", .{});
        if (std.mem.eql(u8, field, "flags")) {
            flags = values.read(state, orders.Flags, -1, "flags");
        } else if (std.mem.eql(u8, field, "priority")) {
            priority = values.read(state, i32, -1, "priority");
            if (priority < 0) call.raise("order priority must be nonnegative", .{});
        } else if (std.meta.stringToEnum(Role, field) != null) {
            if (state.typeOf(-1) != .function) call.raise("order callbacks must be functions", .{});
        } else call.raise("unknown order definition field '{s}'", .{field});
        state.pop(1);
    }
    if (state.rawGetField(2, "update") != .function) call.raise("order update callback is required", .{});
    state.pop(1);
    for (scripts.custom_orders.entries.items) |entry| {
        if (entry.enabled and !entry.context.closed and entry.context.mod == call.context.mod and std.mem.eql(u8, entry.name.slice(), name)) call.raise("this mod already registered order '{s}'", .{name});
    }
    const number = first_custom + scripts.custom_orders.entries.items.len;
    if (number > std.math.maxInt(i16)) call.raise("the custom order registry is full", .{});
    scripts.custom_orders.entries.ensureUnusedCapacity(scripts.gpa, 1) catch call.raise("orders.register: out of memory", .{});
    // Copy callbacks so later changes to the definition cannot replace a registered handler.
    state.newTable(0, std.meta.fields(Role).len);
    inline for (std.meta.fields(Role)) |role| {
        _ = state.rawGetField(2, role.name);
        state.rawSetField(-2, role.name);
    }
    const callbacks = state.ref(-1);
    state.pop(1);
    scripts.custom_orders.entries.appendAssumeCapacity(.{ .context = call.context, .name = key, .qualified = qualified, .flags = flags, .priority = priority, .callbacks = callbacks });
    // The only remaining allocations are in Luau; context cleanup owns the registration now.
    state.pushString(qualified.slice());
    return 1;
}

/// Original names/numbers stay supported. Custom orders require a qualified name.
pub const Identifier = union(enum) { name: []const u8, number: i16 };

pub fn identifierOf(all: *const engine.game.create.Objects, order: orders.Order) Identifier {
    if (values.name(orders.Order, order)) |name| return .{ .name = name };
    if (aigeneric.infoOf(all, order)) |info| return .{ .name = info.name };
    return .{ .number = @intFromEnum(order) };
}

fn find(scripts: *runtime.Runtime, identifier: Identifier) ?orders.Order {
    return switch (identifier) {
        .name => |name| values.byName(orders.Order, name) orelse scripts.custom_orders.find(name),
        .number => |number| if (orders.info(@enumFromInt(number)) != null) @enumFromInt(number) else null,
    };
}

pub fn resolve(call: Call, identifier: Identifier) orders.Order {
    return find(call.runtime(), identifier) orelse switch (identifier) {
        .name => |name| {
            call.raise("no registered order named '{s}'", .{name});
        },
        .number => call.raise("custom orders must be named, not numbered", .{}),
    };
}

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
    order: Identifier,
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
    pub const register = api.Native("Registers a custom order for this global script's mod. Returns its qualified name, which give_order and orders.info accept. The update callback returns false to finish; callbacks cannot change order stacks. Registrations stop with their script context.", "name: string, definition: {priority: number?, flags: OrderFlags?, init: ((ship: Object, target: Object?, seconds: number) -> ())?, update: (ship: Object, target: Object?, seconds: number) -> boolean?, exit: ((ship: Object, target: Object?, seconds: number) -> ())?}", "string", registerOrder);
    pub const info = api.Function("The metadata of an original order or mod-qualified custom order: name, priority and flags. Nil for an unknown or disabled registration.", &.{"order"}, infoOf);
    pub const stack = api.Function("The orders `object` has, the one it follows first, each with what it's aimed at. The ones below carry on as each ends.", &.{"object"}, stackOf);
    pub const cancel = api.Function("Ends the order `object` follows, as an order ends itself: its exit runs, and the order below it carries on. Returns whether it had one. Global scripts can end any object's orders, and an object's scripts their own object's.", &.{"object"}, cancelOrder);
    pub const clear = api.Function("Drops all of `object`'s orders, as a mission's ClearAI does, where the one it follows gives way. Returns whether they were dropped. Global scripts can drop any object's orders, and an object's scripts their own object's.", &.{"object"}, clearAll);
};

fn infoOf(call: Call, identifier: Identifier) ?OrderInfo {
    const order = find(call.runtime(), identifier) orelse return null;
    const all = call.runtime().objects;
    return .of((if (all) |objects_held| aigeneric.infoOf(objects_held, order) else orders.info(order)) orelse return null);
}

fn stackOf(call: Call, object: Object) Stack {
    const all = call.runtime().objects orelse call.raise("orders.stack can only be used while a game runs", .{});
    var found: Stack = .{};
    for (all.slots[object.slot()].stack()) |entry| {
        const ship = entry.target.ship();
        found.append(.{
            .order = identifierOf(all, entry.order),
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
