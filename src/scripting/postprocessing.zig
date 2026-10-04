//! The `openreliant.postprocessing` package ([#559](https://github.com/OpenReliant/openreliant/issues/559),
//! [#623](https://github.com/OpenReliant/openreliant/issues/623)), for player scripts: post effects
//! drawn over the whole frame, each a GLSL fragment shader from the calling mod (`package`).
//!
//! - `register` reads the shader from the mod's files and has the host compile it
//!   (`EffectHost`). A shader that doesn't compile is an error in the script, with the file and the
//!   line. The effect's name is qualified with the mod's: `crt` in the mod `retro` is `retro:crt`.
//! - Each frame the driver takes the passes of the enabled effects (`Registry.passes`): those drawn
//!   before the flight display first, then those after it, each group by `order`, then in the
//!   order they were registered.
//! - An effect is removed when the script that registered it stops. If a script fails to load, the
//!   effects it registered are removed (`Registry.removeSince`).
//! - Effects draw on the GPU only. Without a host, as with the software device, scripts can still
//!   register them, and they draw nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.scripts);

const api = @import("api.zig");
const Call = api.Call;
const values = @import("values.zig");
const runtime_module = @import("runtime.zig");
const Context = runtime_module.Context;

/// When an effect is drawn: over the scene, before the flight display and the menus, or over
/// everything.
pub const Stage = enum {
    pub const script_name = "EffectStage";

    before_hud,
    after_hud,
};

/// The most effects the scripts can have registered at once.
pub const max_effects = 64;

/// How many numbers an effect's parameters hold, which its shader reads as one `vec4`.
pub const parameter_count = 4;

pub const Parameters = values.List(f32, parameter_count);

/// An effect, as a script registers it.
pub const Definition = struct {
    pub const script_name = "Effect";

    /// Its name, which the mod's name qualifies.
    name: []const u8,
    /// The mod's file that holds its fragment shader, such as `crt.frag`.
    shader: []const u8,
    stage: Stage = .before_hud,
    /// Where it draws among the effects of its stage: lower first.
    order: i32 = 0,
    /// The numbers its shader reads as `frame.parameters`; those left out are 0.
    parameters: Parameters = .{},
    enabled: bool = true,
};

/// What compiles the mods' shaders and draws them. The driver provides it.
pub const EffectHost = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Compiles the fragment shader `source`, called `name` in its messages, and adds it as an
        /// effect.
        compile: *const fn (context: *anyopaque, name: []const u8, source: []const u8) Compiled,
        /// Removes the effect `effect`.
        remove: *const fn (context: *anyopaque, effect: u32) void,
    };

    /// What compiling a shader gave.
    pub const Compiled = union(enum) {
        /// The effect added.
        effect: u32,
        /// Why it didn't compile. The text is valid until the host's next call.
        failed: []const u8,
    };
};

/// A pass the frame draws: an effect, when, and its parameters.
pub const Pass = struct {
    effect: u32,
    stage: Stage,
    parameters: [parameter_count]f32,
};

/// An effect registered.
const Entry = struct {
    context: *Context,
    name: runtime_module.Name,
    stage: Stage,
    order: i32,
    parameters: [parameter_count]f32,
    enabled: bool,
    /// The host's effect, or null if there is no host.
    effect: ?u32,
};

/// The effects the scripts have registered.
pub const Registry = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// What compiles and draws them, or null if nothing does, such as in a test.
    host: ?EffectHost = null,

    pub fn deinit(registry: *Registry, gpa: Allocator) void {
        for (registry.entries.items) |entry| registry.release(entry);
        registry.entries.deinit(gpa);
    }

    fn release(registry: *const Registry, entry: Entry) void {
        const host = registry.host orelse return;
        if (entry.effect) |effect| host.vtable.remove(host.context, effect);
    }

    /// Sets what compiles and draws the effects from now on, or null for nothing. Effects already
    /// registered are removed from the old host and draw no more.
    pub fn setHost(registry: *Registry, host: ?EffectHost) void {
        for (registry.entries.items) |*entry| {
            registry.release(entry.*);
            entry.effect = null;
        }
        registry.host = host;
    }

    /// Removes the effects `context` registered from entry `first` on: all of them when its script
    /// stops, or the ones it registered while failing to load.
    pub fn removeSince(registry: *Registry, context: *const Context, first: usize) void {
        var kept: usize = @min(first, registry.entries.items.len);
        for (registry.entries.items[kept..]) |entry| {
            if (entry.context == context) {
                registry.release(entry);
                continue;
            }
            registry.entries.items[kept] = entry;
            kept += 1;
        }
        registry.entries.shrinkRetainingCapacity(kept);
    }

    /// Removes every effect `context` registered.
    pub fn removeContext(registry: *Registry, context: *const Context) void {
        registry.removeSince(context, 0);
    }

    fn find(registry: *Registry, name: []const u8) ?*Entry {
        for (registry.entries.items) |*entry| if (std.mem.eql(u8, entry.name.slice(), name)) return entry;
        return null;
    }

    /// The passes of the enabled effects in the order they draw, in `buffer`: the stage before the
    /// flight display first, each stage sorted by order, and effects of the same order in the order
    /// they were registered.
    pub fn passes(registry: *const Registry, buffer: *[max_effects]Pass) []const Pass {
        var drawn: [max_effects]Entry = undefined;
        var count: usize = 0;
        for (registry.entries.items) |entry| {
            if (!entry.enabled or entry.effect == null) continue;
            drawn[count] = entry;
            count += 1;
        }
        // A stable sort keeps the effects of the same stage and order as they were registered.
        std.sort.insertion(Entry, drawn[0..count], {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                if (a.stage != b.stage) return @intFromEnum(a.stage) < @intFromEnum(b.stage);
                return a.order < b.order;
            }
        }.lessThan);
        for (drawn[0..count], buffer[0..count]) |entry, *pass| pass.* = .{ .effect = entry.effect.?, .stage = entry.stage, .parameters = entry.parameters };
        return buffer[0..count];
    }
};

/// What `openreliant.postprocessing` holds.
pub const package = struct {
    pub const register = api.Function("Registers a post effect: a GLSL fragment shader from the calling mod's file `shader`, drawn over the whole frame. `stage` is `\"before_hud\"` (the default) or `\"after_hud\"`, `order` sorts the effects of a stage, lower first, and `parameters` holds up to four numbers its shader reads. Returns the effect's name, qualified with the mod's. A shader that doesn't compile is an error, with its file and line. See the scripting guide for what the shader reads.", &.{"definition"}, registerEffect);
    pub const set_enabled = api.Function("Turns the calling mod's effect `name` on or off, by its own name or the qualified one. Returns whether the mod has it.", &.{ "name", "enabled" }, setEnabled);
    pub const set_parameters = api.Function("Sets the numbers the calling mod's effect `name` reads, up to four; those left out are 0. Returns whether the mod has it.", &.{ "name", "parameters" }, setParameters);
};

fn registryOf(call: Call) *Registry {
    return &call.runtime().post_effects;
}

fn registerEffect(call: Call, given: Definition) []const u8 {
    if (call.context.family != .player) call.raise("postprocessing: only player scripts can register effects", .{});
    const scripts = call.runtime();
    const registry = &scripts.post_effects;
    var buffer: [runtime_module.max_name]u8 = undefined;
    const name = runtime_module.Name.of(call.qualified("postprocessing", given.name, &buffer)).?;
    if (registry.find(name.slice()) != null) call.raise("postprocessing: the effect '{s}' is registered already", .{name.slice()});
    if (registry.entries.items.len == max_effects) call.raise("postprocessing: at most {d} effects can be registered", .{max_effects});
    registry.entries.ensureUnusedCapacity(scripts.gpa, 1) catch call.raise("postprocessing: out of memory", .{});
    const mod = call.context.modOf();
    const source = mod.readFile(scripts.gpa, given.shader) catch |err| call.raise("postprocessing: {s} can't be read: {s}", .{ given.shader, @errorName(err) }) orelse
        call.raise("postprocessing: the mod {s} has no file {s}", .{ mod.name, given.shader });
    var file_buffer: [runtime_module.max_name * 2]u8 = undefined;
    const file = std.fmt.bufPrint(&file_buffer, "{s}/{s}", .{ mod.name, given.shader }) catch given.shader;
    const compiled: ?EffectHost.Compiled = if (registry.host) |host| host.vtable.compile(host.context, file, source) else null;
    scripts.gpa.free(source);
    const effect: ?u32 = if (compiled) |result| switch (result) {
        .effect => |made| made,
        .failed => |message| call.raise("postprocessing: {s}", .{message}),
    } else null;
    registry.entries.appendAssumeCapacity(.{
        .context = call.context,
        .name = name,
        .stage = given.stage,
        .order = given.order,
        .parameters = given.parameters.padded(0),
        .enabled = given.enabled,
        .effect = effect,
    });
    log.info("{s}: registered the post effect {s}", .{ mod.name, name.slice() });
    return registry.entries.items[registry.entries.items.len - 1].name.slice();
}

fn setEnabled(call: Call, local: []const u8, enabled: bool) bool {
    var buffer: [runtime_module.max_name]u8 = undefined;
    const entry = registryOf(call).find(call.qualified("postprocessing", local, &buffer)) orelse return false;
    entry.enabled = enabled;
    return true;
}

fn setParameters(call: Call, local: []const u8, given: Parameters) bool {
    var buffer: [runtime_module.max_name]u8 = undefined;
    const entry = registryOf(call).find(call.qualified("postprocessing", local, &buffer)) orelse return false;
    entry.parameters = given.padded(0);
    return true;
}

/// A stand-in host for the tests, and the CRT example's shader, which the driver's tests compile.
pub const testing = struct {
    pub const crt_shader = @embedFile("crt/crt.frag");

    /// A host that "compiles" any shader that doesn't contain `broken`. It counts the effects it
    /// adds and records the ones removed.
    pub const Host = struct {
        added: u32 = 0,
        removed: std.ArrayList(u32) = .empty,

        pub fn deinit(host: *Host) void {
            host.removed.deinit(std.testing.allocator);
        }

        pub fn effectHost(held: *Host) EffectHost {
            return .{ .context = held, .vtable = &.{ .compile = compile, .remove = remove } };
        }

        fn from(context: *anyopaque) *Host {
            return @ptrCast(@alignCast(context));
        }

        fn compile(context: *anyopaque, name: []const u8, source: []const u8) EffectHost.Compiled {
            _ = name;
            const held = from(context);
            if (std.mem.indexOf(u8, source, "broken") != null) return .{ .failed = "crt/broken.frag:2: 'broken' : undeclared identifier" };
            held.added += 1;
            return .{ .effect = held.added - 1 };
        }

        fn remove(context: *anyopaque, effect: u32) void {
            from(context).removed.append(std.testing.allocator, effect) catch {};
        }
    };
};
