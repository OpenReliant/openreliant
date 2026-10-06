//! The `openreliant.camera` package ([#498](https://github.com/OpenReliant/openreliant/issues/498)),
//! for player scripts: the camera's view, and switching between the game's views (`package`).

const openreliant = @import("openreliant");
const engine_camera = openreliant.engine.game.camera;
const Object = openreliant.engine.hooks.Object;
const api = @import("api.zig");
const Call = api.Call;
const Presentation = @import("presentation.zig").Presentation;
const registries = @import("registries.zig");
const values = @import("values.zig");

pub const Identifier = union(enum) { name: []const u8, number: u32 };

/// What `openreliant.camera` holds.
pub const package = struct {
    pub const register_view = api.Native("Registers a camera view, which `name` qualified with the mod's name names. `frame` gives the camera's position and orientation each frame; its axes must be unit length, at right angles and right-handed. A failed `frame` goes back to the cockpit view. Returns the qualified name.", "name: string, definition: {frame: (object: Object, seconds: number) -> {position: vector, orientation: Orientation}, letterbox: boolean?}", "string", registries.registration(.camera));
    pub const view = api.Field(?Identifier, "The view the camera shows: one of the game's (`View`), or a mod's by its qualified name; nil while no mission is shown.", struct {
        pub fn get(call: Call) ?Identifier {
            const held = Presentation.hostOf(call, "camera.view").camera orelse return null;
            if (call.runtime().registries.cameraName(held.camera.view)) |name| return .{ .name = name };
            if (values.name(engine_camera.View, held.camera.view)) |name| return .{ .name = name };
            return .{ .number = @backingInt(held.camera.view) };
        }
    });

    pub const set_view = api.Function("Switches to `view`, one of the game's or a mod's by its qualified name, looking at `object`, or at the player's ship where it's nil. Returns whether it switched: a mission that holds the camera, or shows a cutaway, keeps it.", &.{ "view", "object" }, setView);
};

/// `camera.set_view(view, object)`.
fn setView(call: Call, wanted: Identifier, object: ?Object) bool {
    const held = Presentation.hostOf(call, "camera.set_view").camera orelse return false;
    const of = if (object) |named| named.slot() else held.player;
    const view: engine_camera.View = switch (wanted) {
        .name => |name| values.byName(engine_camera.View, name) orelse {
            const index = call.runtime().registries.find(.camera, name) orelse return false;
            return call.runtime().registries.selectCamera(call.runtime(), index, object);
        },
        .number => |number| if (number < engine_camera.views.records.len) @fromBackingInt(@intCast(number)) else return false,
    };
    if (!held.camera.setView(view, of, false, false, held.now)) return false;
    call.runtime().registries.selected_camera = null;
    call.runtime().registries.camera_subject = null;
    return true;
}
