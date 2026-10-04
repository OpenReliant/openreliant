//! The menu flow from mods ([#560](https://github.com/OpenReliant/openreliant/issues/560)): a
//! menu script's registered screen standing in for one of the front end's own
//! (`ui.replace_screen`), and going on from it (`ui.go_to`, `ui.start_game_mode`, `ui.quit`).
//!
//! - While a mod's screen stands in for the screen the front end shows, the front end runs it in
//!   place of its own (`interf.Scripted`): it is selected, so that it draws and takes the keys,
//!   over the screen's background, with the pointer over it. `ui.pointer` says where the pointer
//!   is.
//! - The screen goes on by asking the front end: to another of its screens, or the mod's screen
//!   that stands in for that one; into a game mode (`game_modes.zig`); or out of the game. The
//!   front end takes one request a pass.
//! - A screen whose script stops, or whose callback fails, stands in for nothing more, and the
//!   front end shows its own again.
//!
//! **Improvement:** the original's menus are its own alone.

const std = @import("std");

const openreliant = @import("openreliant");
const interf = openreliant.engine.genilib.interf;
const api = @import("api.zig");
const Call = api.Call;
const runtime_module = @import("runtime.zig");
const presentation = @import("presentation.zig");
const Presentation = presentation.Presentation;

/// Where the pointer is, in pixels from the window's top left corner, and whether its left button
/// is down.
pub const Pointer = struct {
    pub const script_name = "Pointer";

    at: @Vector(3, f32),
    down: bool,
};

/// The screens that stand in for the front end's own, by the registered screen's place.
pub const Standing = struct {
    screens: std.AutoArrayHashMapUnmanaged(interf.Screen, usize) = .empty,
    /// What the screen shown has asked for, until the front end takes it.
    request: ?interf.Request = null,

    pub fn deinit(standing: *Standing, gpa: std.mem.Allocator) void {
        standing.screens.deinit(gpa);
    }
};

/// The functions of `openreliant.ui` for the menu flow.
pub const functions = struct {
    pub const replace_screen = api.Function("Makes the calling mod's registered screen `name` stand in for the front end's own `screen`, such as `\"main_menu\"`: while the front end shows `screen`, it runs and draws the mod's screen in its place, over its background. nil gives `screen` back to the front end. Only menu scripts can use it. Returns whether the screen is registered.", &.{ "screen", "name" }, replaceScreen);
    pub const go_to = api.Function("Asks the front end to go to its screen `screen`, or to the mod's screen that stands in for it. Only menu scripts can use it.", &.{"screen"}, goTo);
    pub const start_game_mode = api.Function("Asks the front end to start the game mode `name`: the calling mod's by its own name, or any mod's by the qualified one. Only menu scripts can use it. Returns whether the mode is registered.", &.{"name"}, startGameMode);
    pub const quit = api.Function("Asks the front end to quit the game. Only menu scripts can use it.", &.{}, quitGame);
    pub const pointer = api.Field(?Pointer, "Where the pointer is, in pixels from the window's top left corner, and whether its left button is down; nil before it has been over the window.", struct {
        pub fn get(call: Call) ?Pointer {
            const host = Presentation.of(call, "pointer").host orelse return null;
            const at = host.devices.mouse.at orelse return null;
            return .{ .at = .{ at[0], at[1], 0 }, .down = host.devices.mouse.buttons.left };
        }
    });
};

/// The Presentation of a menu script's call, `label` naming the function in the error raised
/// otherwise.
fn menuOf(call: Call, comptime label: []const u8) *Presentation {
    if (call.context.family != .menu) call.raise("ui." ++ label ++ ": only menu scripts can use it", .{});
    return Presentation.of(call, label);
}

fn replaceScreen(call: Call, screen: interf.Screen, name: ?[]const u8) bool {
    const shown = menuOf(call, "replace_screen");
    const standing = &shown.standing;
    const wanted = name orelse {
        _ = standing.screens.swapRemove(screen);
        return true;
    };
    var buffer: [runtime_module.max_name]u8 = undefined;
    const index = shown.runtime.registries.find(.screen, call.qualified("ui.replace_screen", wanted, &buffer)) orelse return false;
    standing.screens.put(shown.gpa, screen, index) catch call.raise("ui.replace_screen: out of memory", .{});
    return true;
}

fn goTo(call: Call, screen: interf.Screen) void {
    menuOf(call, "go_to").standing.request = .{ .go = screen };
}

fn startGameMode(call: Call, name: []const u8) bool {
    const shown = menuOf(call, "start_game_mode");
    const modes = call.runtime().options.shared.modes orelse return false;
    var buffer: [runtime_module.max_name]u8 = undefined;
    const qualified = if (std.mem.indexOfScalar(u8, name, ':') != null) name else call.qualified("ui.start_game_mode", name, &buffer);
    const index = modes.find(qualified) orelse return false;
    shown.standing.request = .{ .game_mode = @intCast(index) };
    return true;
}

fn quitGame(call: Call) void {
    menuOf(call, "quit").standing.request = .quit;
}

/// The registered screen that stands in for `screen`, where its script still runs.
fn standingIn(shown: *Presentation, screen: interf.Screen) ?usize {
    const index = shown.standing.screens.get(screen) orelse return null;
    const entry = shown.runtime.registries.entries.items[index];
    return if (entry.enabled and !entry.context.closed) index else null;
}

/// The mods' screens as the front end reaches them.
pub fn scripted(shown: *Presentation) interf.Scripted {
    return .{ .context = shown, .vtable = &.{ .replaces = replaces, .show = show, .take = take } };
}

fn from(context: *anyopaque) *Presentation {
    return @ptrCast(@alignCast(context));
}

fn replaces(context: *anyopaque, screen: interf.Screen) bool {
    return standingIn(from(context), screen) != null;
}

fn show(context: *anyopaque, screen: ?interf.Screen) void {
    const shown = from(context);
    const registry = &shown.runtime.registries;
    registry.selected_screen = if (screen) |standing| standingIn(shown, standing) else null;
    shown.standing.request = null;
}

fn take(context: *anyopaque) ?interf.Request {
    const shown = from(context);
    defer shown.standing.request = null;
    return shown.standing.request;
}
