//! The `openreliant.world` package ([#498](https://github.com/OpenReliant/openreliant/issues/498)),
//! for global and mission scripts: the objects of the mission, its missiles in flight, the player's
//! ship and the mission itself (`package`).

const openreliant = @import("openreliant");
const engine_hooks = openreliant.engine.hooks;
const Object = engine_hooks.Object;
const create = openreliant.engine.game.create;
const hud = openreliant.engine.game.hud;
const api = @import("api.zig");
const Call = api.Call;
const handles = @import("objects.zig");
const missile_handles = @import("missiles.zig");
const game = @import("game.zig");

/// What `openreliant.world` holds.
pub const package = struct {
    pub const objects = api.Function("Every object in the mission, in the order of their slots.", &.{}, allObjects);
    pub const missiles = api.Function("Every missile in flight, newest first.", &.{}, allMissiles);
    pub const set_objective = api.Function("Objective `objective` of the mission that runs, numbered from 0 to 9 as a mission's SetObjective numbers them, takes `state`, as SetObjective does: `hidden`, `listed`, or `current`, which the objectives window then shows. Returns whether it changed: false between missions, and in a mission whose objectives nothing names.", &.{ "objective", "state" }, setObjective);

    pub const player = api.Field(?Object, "The player's ship, while a mission runs; nil between missions.", struct {
        pub fn get(call: Call) ?Object {
            const held = game.Game.of(call);
            if (held.mission == null) return null;
            return .of(held.objects.player);
        }
    });

    pub const mission = api.Field(?engine_hooks.Mission, "The mission that runs, with its `number` and its `file`'s name; nil between missions.", struct {
        pub fn get(call: Call) ?engine_hooks.Mission {
            const held = game.Game.of(call);
            return if (held.mission) |*running| running.view() else null;
        }
    });
};

/// `world.set_objective(objective, state)`: `hud.Objectives.set`, as a mission's `SetObjective`
/// calls it.
fn setObjective(call: Call, objective: u8, state: hud.Objectives.Status) bool {
    if (objective >= hud.Objectives.per_mission) call.raise("world.set_objective: objectives are numbered from 0 to {d}", .{hud.Objectives.per_mission - 1});
    const orders = call.runtime().orders orelse return false;
    const display = orders.world.display orelse return false;
    return display.objectives.set(objective, state);
}

/// `world.objects()`.
fn allObjects(call: Call) handles.List {
    const held = game.Game.of(call);
    var list: handles.List = .{};
    var walk = held.objects.walk();
    while (walk.next()) |index| {
        if (inMission(held.objects, index)) list.append(.of(index));
    }
    return list;
}

/// `world.missiles()`.
fn allMissiles(call: Call) missile_handles.List {
    const held = game.Game.of(call);
    var list: missile_handles.List = .{};
    var walk = held.objects.missiles.walk();
    while (walk.next()) |record| list.append(.of(record));
    return list;
}

/// Whether the object in slot `index` is in the mission: not a stand-in for an empty slot.
pub fn inMission(all: *const create.Objects, index: u16) bool {
    return all.slots[index].object.type.base() != .stand_in;
}

/// The object in slot `index`, as the game names one by its slot, where that's one of the slots
/// and its object is in the mission; null otherwise.
pub fn objectIn(all: *const create.Objects, index: u16) ?Object {
    if (index >= all.slots.len or !inMission(all, index)) return null;
    return .of(index);
}
