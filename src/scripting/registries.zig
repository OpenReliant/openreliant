//! Presentation registries (#558). Qualified names and script contexts define identity/lifetime;
//! the original engine's camera and the existing drawing packages supply the behavior.
const std = @import("std");
const runtime = @import("runtime.zig");
const luau = @import("luau.zig");
const api = @import("api.zig");
const values = @import("values.zig");
const util = @import("util.zig");
const engine = @import("openreliant").engine;
const camera = engine.game.camera;
const math = engine.surrender.math;
const presentation = @import("presentation.zig");
const log = std.log.scoped(.scripts);
const objects = @import("objects.zig");

pub const Kind = enum { camera, display, screen };
const first_view = camera.views.records.len;
/// Keep session-local IDs inside the engine's view representation, including retired entries.
pub const max_registered = @as(usize, std.math.maxInt(@typeInfo(camera.View).@"enum".tag_type)) + 1 - first_view;
const axes_tolerance: f32 = 0.01;
const Callback = enum { frame, key };

comptime {
    std.debug.assert(first_view + max_registered - 1 <= std.math.maxInt(@typeInfo(camera.View).@"enum".tag_type));
}

const Entry = struct {
    context: *runtime.Context,
    name: runtime.Name,
    kind: Kind,
    callbacks: ?luau.Ref,
    enabled: bool = true,
    shown: bool = true,
    letterbox: bool = false,
};

pub const Pose = struct {
    position: @Vector(3, f32),
    orientation: util.Orientation,
};

pub const Registry = struct {
    entries: std.ArrayList(Entry) = .empty,
    selected_camera: ?usize = null,
    selected_screen: ?usize = null,
    camera_subject: ?objects.Handle = null,
    updating: bool = false,

    pub fn deinit(registry: *Registry, scripts: *runtime.Runtime) void {
        for (registry.entries.items) |entry| if (entry.callbacks) |ref| scripts.release(ref);
        registry.entries.deinit(scripts.gpa);
    }

    pub fn find(registry: *const Registry, kind: Kind, name: []const u8) ?usize {
        for (registry.entries.items, 0..) |entry, index| {
            if (entry.kind == kind and entry.enabled and !entry.context.closed and std.mem.eql(u8, entry.name.slice(), name)) return index;
        }
        return null;
    }

    pub fn removeSince(registry: *Registry, scripts: *runtime.Runtime, context: *runtime.Context, first: usize) void {
        for (first..registry.entries.items.len) |index| {
            if (registry.entries.items[index].context != context) continue;
            registry.disable(scripts, index);
            if (registry.entries.items[index].callbacks) |ref| scripts.release(ref);
            registry.entries.items[index].callbacks = null;
        }
    }

    fn disable(registry: *Registry, scripts: *runtime.Runtime, index: usize) void {
        registry.entries.items[index].enabled = false;
        if (registry.selected_camera == index) {
            registry.resetCamera(scripts);
        }
        if (registry.selected_screen == index) registry.selected_screen = null;
    }

    pub fn resetCamera(registry: *Registry, scripts: *runtime.Runtime) void {
        if (scripts.presentation) |shown| if (shown.host) |host| if (host.camera) |held| {
            if (registry.selected_camera) |index| if (held.camera.view == viewId(index) and !held.camera.locked) {
                _ = held.camera.setView(.cockpit, held.player, false, false, held.now);
            };
        };
        registry.selected_camera = null;
        registry.camera_subject = null;
    }

    pub fn viewId(index: usize) camera.View {
        return @enumFromInt(first_view + index);
    }

    pub fn cameraName(registry: *const Registry, view: camera.View) ?[]const u8 {
        const number = @intFromEnum(view);
        if (number < first_view) return null;
        const index = number - first_view;
        if (index >= registry.entries.items.len) return null;
        const entry = &registry.entries.items[index];
        return if (entry.kind == .camera and entry.enabled and !entry.context.closed) entry.name.slice() else null;
    }

    pub fn selectCamera(registry: *Registry, scripts: *runtime.Runtime, index: usize, object: ?engine.hooks.Object) bool {
        const host = scripts.presentation.?.host orelse return false;
        const held = host.camera orelse return false;
        if (!held.camera.setView(viewId(index), if (object) |ship| ship.slot() else held.player, false, false, held.now)) return false;
        registry.selected_camera = index;
        if (scripts.objects) |all| registry.camera_subject = .of(all, held.camera.object.?);
        return true;
    }

    pub fn frame(registry: *Registry, scripts: *runtime.Runtime, seconds: f32) void {
        registry.updating = true;
        defer registry.updating = false;
        if (scripts.presentation) |shown| if (shown.host) |host| if (host.camera) |held| {
            if (registry.selected_camera) |index| {
                if (held.camera.view != viewId(index)) {
                    registry.selected_camera = null;
                    registry.camera_subject = null;
                } else if (!held.camera.locked) registry.cameraFrame(scripts, index, seconds);
            }
        };
        const count = registry.entries.items.len;
        for (0..count) |index| {
            const entry = registry.entries.items[index];
            if (!entry.enabled or entry.context.closed or !entry.shown) continue;
            if (entry.kind == .display and scripts.presentation.?.views.get(.hud) != null) registry.invoke(scripts, index, "frame", .{seconds});
        }
        if (registry.selected_screen) |index| {
            if (scripts.presentation.?.views.get(.ui) != null) registry.invoke(scripts, index, "frame", .{seconds});
        }
    }

    pub fn input(registry: *Registry, scripts: *runtime.Runtime, key: engine.input.Key, down: bool) void {
        if (registry.updating) return;
        registry.updating = true;
        defer registry.updating = false;
        if (registry.selected_screen) |index| {
            const ref = scripts.make(struct {
                fn push(state: *luau.State, given: engine.input.Key) void {
                    values.push(state, engine.input.Key, given);
                }
            }.push, .{key}) orelse return;
            defer scripts.release(ref);
            registry.invoke(scripts, index, "key", .{ ref, down });
        }
    }

    fn invoke(registry: *Registry, scripts: *runtime.Runtime, index: usize, key: [:0]const u8, args: anytype) void {
        const entry = registry.entries.items[index];
        if (!entry.enabled or entry.context.closed) return;
        const callbacks = entry.callbacks orelse return;
        // A failed display/screen must not leave half of its frame on either drawing layer.
        const shown = scripts.presentation.?;
        var commands: [shown.layers.values.len]usize = undefined;
        var text: [shown.layers.values.len]usize = undefined;
        for (shown.layers.values, &commands, &text) |layer, *command_count, *text_count| {
            command_count.* = layer.commands.items.len;
            text_count.* = layer.text.items.len;
        }
        if (scripts.callIn(entry.context, callbacks, key, args)) |called| {
            if (called == .failed) {
                for (&shown.layers.values, commands, text) |*layer, command_count, text_count| {
                    layer.commands.shrinkRetainingCapacity(command_count);
                    layer.text.shrinkRetainingCapacity(text_count);
                }
                log.warn("{s}: registered {t} {s} failed and is disabled", .{ entry.context.modOf().name, entry.kind, entry.name.slice() });
                registry.disable(scripts, index);
            }
        }
    }

    fn cameraFrame(registry: *Registry, scripts: *runtime.Runtime, index: usize, seconds: f32) void {
        const entry = registry.entries.items[index];
        const callbacks = entry.callbacks orelse return;
        const held = scripts.presentation.?.host.?.camera.?;
        const ship = held.camera.object orelse held.player;
        const subject = registry.camera_subject;
        if (scripts.objects == null or subject == null or !subject.?.valid(scripts.objects.?) or @import("world.zig").objectIn(scripts.objects.?, ship) == null) {
            registry.disable(scripts, index);
            return;
        }
        const object = scripts.make(struct {
            fn push(state: *luau.State, slot: u16) void {
                @import("objects.zig").push(state, slot);
            }
        }.push, .{ship}) orelse return;
        defer scripts.release(object);
        const pose = scripts.callResult(entry.context, callbacks, "frame", Pose, .{ object, seconds }) orelse {
            registry.disable(scripts, index);
            return;
        };
        // Callback code can switch views. Do not overwrite that selection or a mission lock.
        if (registry.selected_camera != index or held.camera.view != viewId(index) or held.camera.locked or !registry.entries.items[index].enabled) return;
        const axes = pose.orientation;
        if (!validOrientation(axes)) {
            log.warn("{s}: camera {s} returned non-orthonormal axes", .{ entry.context.modOf().name, entry.name.slice() });
            registry.disable(scripts, index);
            return;
        }
        held.camera.place = .{ .position = pose.position, .orientation = pose.orientation.matrix() };
        held.camera.cockpit_place = null;
        held.camera.bars = if (entry.letterbox) camera.letterbox else 0;
        held.camera.bar_speed = 0;
    }
};

fn validOrientation(axes: util.Orientation) bool {
    for ([_]@Vector(3, f32){ axes.right, axes.down, axes.forward }) |axis| {
        if (!@reduce(.And, @abs(axis) <= @as(@Vector(3, f32), @splat(std.math.floatMax(f32))))) return false;
        if (@abs(math.length(axis) - 1) > axes_tolerance) return false;
    }
    return @abs(math.dot(axes.right, axes.down)) <= axes_tolerance and
        @abs(math.dot(axes.right, axes.forward)) <= axes_tolerance and
        @abs(math.dot(axes.down, axes.forward)) <= axes_tolerance and
        math.dot(math.cross(axes.right, axes.down), axes.forward) >= 1 - axes_tolerance;
}

test "camera orientation validation requires finite right-handed orthonormal axes" {
    try std.testing.expect(validOrientation(.of(math.identity)));
    try std.testing.expect(validOrientation(.of(math.fromAngles(0.3, -0.7, 1.2))));
    var axes: util.Orientation = .of(math.identity);
    axes.forward = -axes.forward;
    try std.testing.expect(!validOrientation(axes));
    axes = .of(math.identity);
    axes.right = axes.down;
    try std.testing.expect(!validOrientation(axes));
    axes = .of(math.identity);
    axes.right[0] = std.math.nan(f32);
    try std.testing.expect(!validOrientation(axes));
}

pub fn register(comptime kind: Kind, state: *luau.State) i32 {
    const call = api.Call.of(state, "register");
    const scripts = call.runtime();
    if (scripts.presentation == null) call.raise("presentation registrations require player or menu scripts", .{});
    if (kind != .screen and call.context.family != .player) call.raise("camera views and HUD displays require player scripts", .{});
    if (scripts.registries.updating) call.raise("cannot register from a registry callback", .{});
    const local = values.read(state, []const u8, 1, "name");
    if (!@import("openreliant").dte.source.validId(local)) call.raise("registry name must be an identifier", .{});
    var buffer: [runtime.max_name]u8 = undefined;
    const name = runtime.Name.of(std.fmt.bufPrint(&buffer, "{s}:{s}", .{ call.context.modOf().name, local }) catch call.raise("qualified name is too long", .{})).?;
    if (scripts.registries.find(kind, name.slice()) != null) call.raise("this name is already registered", .{});
    if (scripts.registries.entries.items.len == max_registered) call.raise("the presentation registry is full", .{});
    if (state.typeOf(2) != .table) call.raise("registration expects a definition table", .{});
    var letterbox = false;
    state.pushNil();
    while (state.next(2)) {
        const key = (if (state.typeOf(-2) == .string) state.toString(-2) else null) orelse call.raise("definition keys must be names", .{});
        if (kind == .camera and std.mem.eql(u8, key, "letterbox")) letterbox = values.read(state, bool, -1, "letterbox") else if (std.mem.eql(u8, key, "frame") or (kind == .screen and std.mem.eql(u8, key, "key"))) {
            if (state.typeOf(-1) != .function) call.raise("registry callbacks must be functions", .{});
        } else call.raise("unknown registry field '{s}'", .{key});
        state.pop(1);
    }
    if (state.rawGetField(2, "frame") != .function) call.raise("frame callback is required", .{});
    state.pop(1);
    scripts.registries.entries.ensureUnusedCapacity(scripts.gpa, 1) catch call.raise("out of memory registering", .{});
    state.newTable(0, std.meta.fields(Callback).len);
    inline for (std.meta.fields(Callback)) |callback| {
        _ = state.rawGetField(2, callback.name);
        state.rawSetField(-2, callback.name);
    }
    const callbacks = state.ref(-1);
    state.pop(1);
    scripts.registries.entries.appendAssumeCapacity(.{ .context = call.context, .name = name, .kind = kind, .callbacks = callbacks, .letterbox = letterbox });
    state.pushString(name.slice());
    return 1;
}

pub fn registration(comptime kind: Kind) fn (*luau.State) i32 {
    return struct {
        fn run(state: *luau.State) i32 {
            return register(kind, state);
        }
    }.run;
}

pub fn show(call: api.Call, kind: Kind, name: ?[]const u8, enabled: bool) bool {
    _ = presentation.Presentation.of(call, "registered drawing");
    const registry = &call.runtime().registries;
    if (kind == .screen and name == null) {
        registry.selected_screen = null;
        return true;
    }
    const index = registry.find(kind, name orelse return false) orelse return false;
    if (kind == .display) registry.entries.items[index].shown = enabled else registry.selected_screen = index;
    return true;
}
