//! The `openreliant.core` package ([#498](https://github.com/OpenReliant/openreliant/issues/498)),
//! available to every script (`package`).

const api = @import("api.zig");
const Call = api.Call;
const data = @import("data.zig");
const game = @import("game.zig");

/// What `openreliant.core` holds.
pub const package = struct {
    pub const version = api.Field([]const u8, "The version of OpenReliant, such as `0.7.0`.", struct {
        pub fn get(call: Call) []const u8 {
            return call.runtime().options.version;
        }
    });

    pub const send_global_event = api.Function("Sends the event `name` to the global and mission scripts, with `data`, which must be plain data. It arrives at the next update.", &.{ "name", "data" }, game.sendGlobalEvent);
};
