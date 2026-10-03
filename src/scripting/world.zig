//! The `openreliant.world` package ([#498](https://github.com/OpenReliant/openreliant/issues/498)),
//! for global and mission scripts: the objects of the mission, the player's ship and the mission
//! itself (`package`).

const openreliant = @import("openreliant");
const engine_hooks = openreliant.engine.hooks;
const Object = engine_hooks.Object;
const create = openreliant.engine.game.create;
const api = @import("api.zig");
const Call = api.Call;
const handles = @import("objects.zig");
const game = @import("game.zig");

/// What `openreliant.world` holds.
pub const package = struct {
    pub const objects = api.Function("Every object in the mission, in the order of their slots.", &.{}, allObjects);

    pub const player = api.Field(?Object, "The player's ship, while a mission runs; nil between missions.", struct {
        pub fn get(call: Call) ?Object {
            const held = game.Game.of(call, "world.player");
            if (held.mission == null) return null;
            return .of(held.objects.player);
        }
    });

    pub const mission = api.Field(?engine_hooks.Mission, "The mission that runs, with its `number` and its `file`'s name; nil between missions.", struct {
        pub fn get(call: Call) ?engine_hooks.Mission {
            const held = game.Game.of(call, "world.mission");
            return if (held.mission) |*running| running.view() else null;
        }
    });
};

/// `world.objects()`.
fn allObjects(call: Call) handles.List {
    const held = game.Game.of(call, "world.objects");
    var list: handles.List = .{};
    var walk = held.objects.walk();
    while (walk.next()) |index| {
        if (inMission(held.objects, index)) list.append(index);
    }
    return list;
}

/// Whether the object in slot `index` is in the mission: not a stand-in for an empty slot.
pub fn inMission(all: *const create.Objects, index: u16) bool {
    return all.slots[index].object.type != .stand_in;
}
