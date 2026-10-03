//! The `openreliant.camera` package ([#498](https://github.com/OpenReliant/openreliant/issues/498)),
//! for player scripts: the camera's view, and switching between the game's views (`package`).

const openreliant = @import("openreliant");
const engine_camera = openreliant.engine.game.camera;
const Object = openreliant.engine.hooks.Object;
const api = @import("api.zig");
const Call = api.Call;
const Presentation = @import("presentation.zig").Presentation;

/// What `openreliant.camera` holds.
pub const package = struct {
    pub const view = api.Field(?engine_camera.View, "The view the camera shows; nil while no mission is shown.", struct {
        pub fn get(call: Call) ?engine_camera.View {
            const held = Presentation.hostOf(call, "camera.view").camera orelse return null;
            return held.camera.view;
        }
    });

    pub const set_view = api.Function("Switches the camera to `view`, of `object`, or of the player's ship where it's nil, as the player's camera keys do. Returns whether it switched: a mission's own camera and the cutaways hold it.", &.{ "view", "object" }, setView);
};

/// `camera.set_view(view, object)`.
fn setView(call: Call, wanted: engine_camera.View, object: ?Object) bool {
    const held = Presentation.hostOf(call, "camera.set_view").camera orelse return false;
    const of = if (object) |named| named.slot() else held.player;
    return held.camera.setView(wanted, of, false, false, held.now);
}
