//! The `openreliant.shaders` package ([#629](https://github.com/OpenReliant/openreliant/issues/629)),
//! for player scripts: GLSL functions from the calling mod that change how surfaces are lit.
//!
//! - A surface function changes a pixel's colour, normal, roughness, metalness, glow and alpha
//!   before it is lit. It draws on the textures it names, on every lit surface where it says so,
//!   and on the objects a script gives it (`object:set_surface`).
//! - A lighting function changes how much of each light reaches a pixel. One draws at a time: the
//!   enabled one registered last.
//! - `register_surface` and `register_lighting` read the shader from the mod's files and have the
//!   host compile it (`ShaderHost`). A shader that doesn't compile is an error in the script, with
//!   the file and the line. Names are qualified with the mod's, as `cel:ink`.
//! - A function is removed when the script that registered it stops. If a script fails to load,
//!   the functions it registered are removed (`Registry.removeSince`).
//! - The host draws them on the GPU only. Without a host, as with the software device, scripts can
//!   still register them, and they draw nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.scripts);

const openreliant = @import("openreliant");
const ModSurface = openreliant.engine.surrender.surrenderlib.srtexture.ModSurface;
const api = @import("api.zig");
const Call = api.Call;
const values = @import("values.zig");
const runtime_module = @import("runtime.zig");
const postprocessing = @import("postprocessing.zig");
const Context = runtime_module.Context;
const Object = openreliant.engine.hooks.Object;

/// The most functions the scripts can have registered at once.
pub const max_functions = 64;

/// The most textures a surface function names.
pub const max_textures = 32;

/// The numbers a function reads, as a post effect's (`postprocessing.Parameters`).
pub const parameter_count = postprocessing.parameter_count;
pub const Parameters = postprocessing.Parameters;

/// What a function changes.
pub const Kind = enum {
    /// A pixel's surface, before it is lit.
    surface,
    /// How much of each light reaches a pixel.
    lighting,
};

/// A surface function, as a script registers it.
pub const SurfaceDefinition = struct {
    pub const script_name = "SurfaceFunction";

    /// Its name, which the mod's name qualifies.
    name: []const u8,
    /// The mod's file that holds the function, such as `ink.glsl`.
    shader: []const u8,
    /// The textures it draws on, by file name, such as `pred_hull.tga`.
    textures: values.List([]const u8, max_textures) = .{},
    /// Whether it draws on every lit surface in the scene that has no surface function of its own.
    everywhere: bool = false,
    /// The numbers it reads as `parameters`; those left out are 0.
    parameters: Parameters = .{},
    enabled: bool = true,
};

/// A lighting function, as a script registers it.
pub const LightingDefinition = struct {
    pub const script_name = "LightingFunction";

    name: []const u8,
    /// The mod's file that holds the function, such as `bands.glsl`.
    shader: []const u8,
    parameters: Parameters = .{},
    enabled: bool = true,
};

/// What compiles the mods' functions and draws them. The driver provides it.
pub const ShaderHost = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Compiles the function of `kind` in `source`, called `name` in its messages, and keeps
        /// it as a function of the host's.
        add: *const fn (context: *anyopaque, kind: Kind, name: []const u8, source: []const u8) Compiled,
        /// Removes the function `function`.
        remove: *const fn (context: *anyopaque, function: u16) void,
        /// Draws `functions`, in the order they were registered, from now on.
        update: *const fn (context: *anyopaque, functions: []const Function) void,
    };

    /// What compiling a function gave.
    pub const Compiled = union(enum) {
        /// The function added.
        function: u16,
        /// Why it didn't compile. The text is valid until the host's next call.
        failed: []const u8,
    };
};

/// A function as the host draws it.
pub const Function = struct {
    function: u16,
    kind: Kind,
    parameters: [parameter_count]f32,
    enabled: bool,
    everywhere: bool,
    textures: []const []const u8,
};

/// A function registered.
const Entry = struct {
    context: *Context,
    name: runtime_module.Name,
    kind: Kind,
    parameters: [parameter_count]f32,
    enabled: bool,
    everywhere: bool,
    /// Owned copies of the texture names.
    textures: []const []const u8,
    /// The host's function, or null if there is no host.
    function: ?u16,
};

/// The functions the scripts have registered.
pub const Registry = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// What compiles and draws them, or null if nothing does, such as in a test.
    host: ?ShaderHost = null,

    pub fn deinit(registry: *Registry, gpa: Allocator) void {
        for (registry.entries.items) |entry| registry.release(gpa, entry);
        registry.entries.deinit(gpa);
    }

    fn release(registry: *const Registry, gpa: Allocator, entry: Entry) void {
        if (registry.host) |host| if (entry.function) |function| host.vtable.remove(host.context, function);
        freeTextures(gpa, entry.textures);
    }

    /// Sets what compiles and draws the functions from now on, or null for nothing. Functions
    /// already registered are removed from the old host and draw no more.
    pub fn setHost(registry: *Registry, host: ?ShaderHost) void {
        if (registry.host) |old| for (registry.entries.items) |*entry| {
            if (entry.function) |function| old.vtable.remove(old.context, function);
            entry.function = null;
        };
        registry.host = host;
        registry.sync();
    }

    /// Removes the functions `context` registered from entry `first` on: all of them when its
    /// script stops, or the ones it registered while failing to load.
    pub fn removeSince(registry: *Registry, gpa: Allocator, context: *const Context, first: usize) void {
        var kept: usize = @min(first, registry.entries.items.len);
        const before = registry.entries.items.len;
        for (registry.entries.items[kept..]) |entry| {
            if (entry.context == context) {
                registry.release(gpa, entry);
                continue;
            }
            registry.entries.items[kept] = entry;
            kept += 1;
        }
        registry.entries.shrinkRetainingCapacity(kept);
        if (kept != before) registry.sync();
    }

    /// Removes every function `context` registered.
    pub fn removeContext(registry: *Registry, gpa: Allocator, context: *const Context) void {
        registry.removeSince(gpa, context, 0);
    }

    fn find(registry: *Registry, name: []const u8) ?*Entry {
        for (registry.entries.items) |*entry| if (std.mem.eql(u8, entry.name.slice(), name)) return entry;
        return null;
    }

    /// Tells the host what to draw from now on.
    fn sync(registry: *const Registry) void {
        const host = registry.host orelse return;
        var buffer: [max_functions]Function = undefined;
        host.vtable.update(host.context, registry.functions(&buffer));
    }

    /// The functions the host has, in the order they were registered, in `buffer`.
    pub fn functions(registry: *const Registry, buffer: *[max_functions]Function) []const Function {
        var count: usize = 0;
        for (registry.entries.items) |entry| {
            const function = entry.function orelse continue;
            buffer[count] = .{
                .function = function,
                .kind = entry.kind,
                .parameters = entry.parameters,
                .enabled = entry.enabled,
                .everywhere = entry.everywhere,
                .textures = entry.textures,
            };
            count += 1;
        }
        return buffer[0..count];
    }
};

fn freeTextures(gpa: Allocator, textures: []const []const u8) void {
    for (textures) |name| gpa.free(name);
    gpa.free(textures);
}

/// What `openreliant.shaders` holds.
pub const package = struct {
    pub const register_surface = api.Function("Registers a surface function: a GLSL function `surface` from the calling mod's file `shader`, which changes a pixel before it is lit. It draws on the `textures` it names, on every lit surface without a function of its own where `everywhere` is true, and on the objects given it with `object:set_surface`. `parameters` holds up to four numbers it reads. Returns the function's name, qualified with the mod's. A shader that doesn't compile is an error, with its file and line. See the scripting guide for what the function reads and sets.", &.{"definition"}, registerSurface);
    pub const register_lighting = api.Function("Registers a lighting function: a GLSL function `lighting` from the calling mod's file `shader`, which changes how much of each light reaches a pixel. One draws at a time: the enabled one registered last. `parameters` holds up to four numbers it reads. Returns the function's name, qualified with the mod's. A shader that doesn't compile is an error, with its file and line.", &.{"definition"}, registerLighting);
    pub const set_enabled = api.Function("Turns the calling mod's function `name` on or off, by its own name or the qualified one. Returns whether the mod has it.", &.{ "name", "enabled" }, setEnabled);
    pub const set_parameters = api.Function("Sets the numbers the calling mod's function `name` reads on its textures and everywhere it draws, up to four; those left out are 0. Returns whether the mod has it.", &.{ "name", "parameters" }, setParameters);
};

fn registryOf(call: Call) *Registry {
    return &call.runtime().mod_shaders;
}

fn registerSurface(call: Call, given: SurfaceDefinition) []const u8 {
    return register(call, .surface, given.name, given.shader, given.parameters, given.enabled, given.everywhere, given.textures.slice());
}

fn registerLighting(call: Call, given: LightingDefinition) []const u8 {
    return register(call, .lighting, given.name, given.shader, given.parameters, given.enabled, false, &.{});
}

fn register(call: Call, kind: Kind, local: []const u8, shader: []const u8, parameters: Parameters, enabled: bool, everywhere: bool, textures: []const []const u8) []const u8 {
    if (call.context.family != .player) call.raise("shaders: only player scripts can register functions", .{});
    const scripts = call.runtime();
    const gpa = scripts.gpa;
    const registry = &scripts.mod_shaders;
    var buffer: [runtime_module.max_name]u8 = undefined;
    const name = runtime_module.Name.of(call.qualified("shaders", local, &buffer)).?;
    if (registry.find(name.slice()) != null) call.raise("shaders: the function '{s}' is registered already", .{name.slice()});
    if (registry.entries.items.len == max_functions) call.raise("shaders: at most {d} functions can be registered", .{max_functions});
    registry.entries.ensureUnusedCapacity(gpa, 1) catch call.raise("shaders: out of memory", .{});
    const mod = call.context.modOf();
    const source = mod.readFile(gpa, shader) catch |err| call.raise("shaders: {s} can't be read: {s}", .{ shader, @errorName(err) }) orelse
        call.raise("shaders: the mod {s} has no file {s}", .{ mod.name, shader });
    var file_buffer: [runtime_module.max_name * 2]u8 = undefined;
    const file = std.fmt.bufPrint(&file_buffer, "{s}/{s}", .{ mod.name, shader }) catch shader;
    const compiled: ?ShaderHost.Compiled = if (registry.host) |host| host.vtable.add(host.context, kind, file, source) else null;
    gpa.free(source);
    const function: ?u16 = if (compiled) |result| switch (result) {
        .function => |made| made,
        .failed => |message| call.raise("shaders: {s}", .{message}),
    } else null;
    // Copied last, as raising an error skips what would free them.
    const owned = copyTextures(gpa, textures) catch {
        if (registry.host) |host| if (function) |made| host.vtable.remove(host.context, made);
        call.raise("shaders: out of memory", .{});
    };
    registry.entries.appendAssumeCapacity(.{
        .context = call.context,
        .name = name,
        .kind = kind,
        .parameters = parameters.padded(0),
        .enabled = enabled,
        .everywhere = everywhere,
        .textures = owned,
        .function = function,
    });
    registry.sync();
    log.info("{s}: registered the {t} function {s}", .{ mod.name, kind, name.slice() });
    return registry.entries.items[registry.entries.items.len - 1].name.slice();
}

fn copyTextures(gpa: Allocator, textures: []const []const u8) Allocator.Error![]const []const u8 {
    const copies = try gpa.alloc([]const u8, textures.len);
    var made: usize = 0;
    errdefer {
        for (copies[0..made]) |name| gpa.free(name);
        gpa.free(copies);
    }
    for (textures, copies) |name, *copy| {
        copy.* = try gpa.dupe(u8, name);
        made += 1;
    }
    return copies;
}

fn setEnabled(call: Call, local: []const u8, enabled: bool) bool {
    var buffer: [runtime_module.max_name]u8 = undefined;
    const registry = registryOf(call);
    const entry = registry.find(call.qualified("shaders", local, &buffer)) orelse return false;
    entry.enabled = enabled;
    registry.sync();
    return true;
}

fn setParameters(call: Call, local: []const u8, given: Parameters) bool {
    var buffer: [runtime_module.max_name]u8 = undefined;
    const registry = registryOf(call);
    const entry = registry.find(call.qualified("shaders", local, &buffer)) orelse return false;
    entry.parameters = given.padded(0);
    registry.sync();
    return true;
}

/// `object:set_surface(name, parameters)`: draws the object with the surface function `name`, the
/// calling mod's by its own name or any mod's by the qualified one, reading `parameters`; nil
/// draws it with its textures' again. Returns false if no function of that name is registered.
pub fn setSurface(call: Call, object: Object, name: ?[]const u8, given: ?Parameters) bool {
    if (call.context.family != .player) call.raise("set_surface: only player scripts can set an object's surface function", .{});
    const all = call.runtime().objects orelse call.raise("set_surface: objects only exist while a game runs", .{});
    var surface: ?ModSurface = null;
    if (name) |wanted| {
        var buffer: [runtime_module.max_name]u8 = undefined;
        const qualified = if (std.mem.indexOfScalar(u8, wanted, ':') != null) wanted else call.qualified("set_surface", wanted, &buffer);
        const entry = registryOf(call).find(qualified) orelse return false;
        if (entry.kind != .surface) call.raise("set_surface: {s} is a lighting function", .{qualified});
        const parameters = (given orelse Parameters{}).padded(0);
        // Without a host the function draws nothing, and the object draws as it is.
        if (entry.function) |function| surface = .{ .function = function, .parameters = parameters };
    }
    if (all.slots[object.slot()].model) |*model| for (model.parts) |*part| {
        part.object.surface = surface;
    };
    return true;
}

/// A stand-in host for the tests, and the cel-shading example's functions, which the driver's
/// tests compile.
pub const testing = struct {
    pub const cel_bands = @embedFile("cel-shading/bands.glsl");
    pub const cel_ink = @embedFile("cel-shading/ink.glsl");

    /// It "compiles" any function that doesn't contain `broken`, numbering them from 1, and records
    /// what it is told.
    pub const Host = struct {
        added: u16 = 0,
        removed: std.ArrayList(u16) = .empty,
        /// What the last update drew: each function, by its number, its kind and whether it is on.
        drawn: std.ArrayList(Function) = .empty,

        pub fn deinit(host: *Host) void {
            host.removed.deinit(std.testing.allocator);
            host.drawn.deinit(std.testing.allocator);
        }

        pub fn shaderHost(held: *Host) ShaderHost {
            return .{ .context = held, .vtable = &.{ .add = add, .remove = remove, .update = update } };
        }

        fn from(context: *anyopaque) *Host {
            return @ptrCast(@alignCast(context));
        }

        fn add(context: *anyopaque, kind: Kind, name: []const u8, source: []const u8) ShaderHost.Compiled {
            _ = kind;
            _ = name;
            const held = from(context);
            if (std.mem.indexOf(u8, source, "broken") != null) return .{ .failed = "cel/broken.glsl:2: 'broken' : undeclared identifier" };
            held.added += 1;
            return .{ .function = held.added };
        }

        fn remove(context: *anyopaque, function: u16) void {
            from(context).removed.append(std.testing.allocator, function) catch {};
        }

        fn update(context: *anyopaque, functions: []const Function) void {
            const held = from(context);
            held.drawn.clearRetainingCapacity();
            held.drawn.appendSlice(std.testing.allocator, functions) catch {};
        }
    };
};
