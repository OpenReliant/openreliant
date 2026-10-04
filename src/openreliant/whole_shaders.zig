//! Mods' replacements for OpenReliant's shaders ([#630](https://github.com/OpenReliant/openreliant/issues/630)):
//! a mod's `device.glsl`, `bloom.glsl` or `shadow.glsl` in place of OpenReliant's own
//! (`platform.gpu.programs`), chosen as OpenReliant starts.
//!
//! - The last mod in the load order that has the file replaces OpenReliant's. A line that includes
//!   `colour.glsl` takes the same mod's `colour.glsl`, or OpenReliant's where it has none.
//! - Both stages compile, through the shader cache, and each is checked against OpenReliant's own,
//!   compiled the same way (`shader_compiler.checkReplacement`), and the two stages against each
//!   other (`shader_compiler.checkLink`). A replacement that doesn't compile or doesn't fit is
//!   left out, which the log says with the file and the reason, and OpenReliant's own draws.
//! - A replaced `device.glsl` is also what the mods' surface and lighting functions are compiled
//!   into (`platform.gpu.variants.Template`). Without the line `// mod_functions`, they draw
//!   nothing.
//!
//! **Improvement:** the original has no shaders, and nothing to replace them with.

const std = @import("std");
const Allocator = std.mem.Allocator;

const platform = @import("platform");
const programs = platform.gpu.programs;
const variants = platform.gpu.variants;
const shader_compiler = platform.shader_compiler;
const Code = shader_compiler.Code;
const Part = shader_compiler.Part;
const Stage = shader_compiler.Stage;
const Cache = platform.shader_cache.Cache;
const openreliant = @import("openreliant");
const Mod = openreliant.engine.game.bigfile.mods.Mod;

const log = std.log.scoped(.shaders);

/// The mods' replacements, and the device shader their functions are compiled into.
pub const Loaded = struct {
    replacements: programs.Replacements = .initFill(null),
    /// OpenReliant's own device shader or a mod's replacement, cut where the functions go; null
    /// where the replacement has no place for them.
    template: ?variants.Template,
};

/// Finds and checks the replacements `mods`, in load order, have for OpenReliant's shaders. What it
/// gives is allocated in `arena`, which must outlast the GPU that draws with it.
pub fn load(arena: Allocator, cache: Cache, mods: []const Mod) Allocator.Error!Loaded {
    var loaded: Loaded = .{ .template = .builtin() };
    for (std.enums.values(programs.Name)) |name| {
        const mod, const file = try last(arena, mods, name.file()) orelse continue;
        const colour = try read(arena, mod, programs.colour_file) orelse programs.colour;
        const replacement = replace(arena, cache, name, file, colour) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.LeftOut => continue,
        };
        loaded.replacements.set(name, replacement);
        log.info("{s} replaces OpenReliant's {s}", .{ file.name, name.file() });
        if (name == .device) {
            loaded.template = variants.Template.of(file, colour);
            if (loaded.template == null) log.warn("the mods' surface and lighting functions draw nothing: {s} has no line // mod_functions", .{file.name});
        }
    }
    return loaded;
}

/// The file `name` of the last of `mods` that has it, and that mod.
fn last(arena: Allocator, mods: []const Mod, name: []const u8) Allocator.Error!?struct { *const Mod, Part } {
    var at = mods.len;
    while (at > 0) {
        at -= 1;
        if (try read(arena, &mods[at], name)) |file| return .{ &mods[at], file };
    }
    return null;
}

/// The mod's file `name`, read and called as the messages call it, such as `retro/device.glsl`, or
/// null if it has none. One that can't be read is logged, as if it weren't there.
fn read(arena: Allocator, mod: *const Mod, name: []const u8) Allocator.Error!?Part {
    const source = mod.readFile(arena, name) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => {
            log.warn("{s}/{s} is left out: it can't be read: {s}", .{ mod.name, name, @errorName(err) });
            return null;
        },
    } orelse return null;
    return .{ .name = try std.fmt.allocPrint(arena, "{s}/{s}", .{ mod.name, name }), .source = source };
}

/// `file` compiled and checked as the replacement for OpenReliant's `name`, with `colour` for what
/// it includes. `error.LeftOut` where it doesn't compile or doesn't fit, which the log says.
fn replace(arena: Allocator, cache: Cache, name: programs.Name, file: Part, colour: Part) (Allocator.Error || error{LeftOut})!programs.Replacement {
    var stages: [2]Code = undefined;
    for (std.enums.values(Stage), &stages) |stage, *code| {
        code.* = try compiled(arena, cache, stage, file, colour) orelse return error.LeftOut;
        const own = try compiled(arena, cache, stage, name.own(), programs.colour) orelse {
            log.warn("{s} is left out: OpenReliant's own {s} doesn't compile at runtime", .{ file.name, name.file() });
            return error.LeftOut;
        };
        if (try shader_compiler.checkReplacement(arena, file.name, own.spirv, code.spirv)) |why| return leftOut(file, stage, why);
    }
    if (try shader_compiler.checkLink(arena, file.name, stages[0].spirv, stages[1].spirv)) |why| return leftOut(file, .fragment, why);
    return .{ .vertex = stages[0], .fragment = stages[1] };
}

/// The stage `stage` of `file`, through the cache, or null where it doesn't compile, which the log
/// says.
fn compiled(arena: Allocator, cache: Cache, stage: Stage, file: Part, colour: Part) Allocator.Error!?Code {
    var buffer: [programs.max_parts]Part = undefined;
    const parts = programs.parts(file, colour, &buffer);
    const cached_name = try std.fmt.allocPrint(arena, "{s} {t}", .{ file.name, stage });
    return switch (try cache.compileParts(arena, cached_name, .openreliant, stage, parts, stage.definition())) {
        .compiled => |code| code,
        .diagnostic => |text| {
            log.warn("{s} is left out, and OpenReliant's own draws: its {t} stage doesn't compile: {s}", .{ file.name, stage, std.mem.trimEnd(u8, text, "\n") });
            return null;
        },
    };
}

fn leftOut(file: Part, stage: Stage, why: []const u8) error{LeftOut} {
    log.warn("{s} is left out, and OpenReliant's own draws: its {t} stage doesn't fit: {s}", .{ file.name, stage, why });
    return error.LeftOut;
}

test load {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // OpenReliant's own bloom, shadow and device shaders, as three mods ship them: the bloom
    // changed in a way that fits, the shadow with a texture OpenReliant doesn't bind, and the
    // device without the place for the functions, in two mods, the later one winning.
    const bloom = try std.mem.replaceOwned(u8, arena, programs.Name.bloom.source(), "uv = vec2(corner.x, 1.0 - corner.y);", "uv = vec2(corner.x, 1.0 - corner.y) * 1.0;");
    const shadow = try std.mem.replaceOwned(u8, arena, programs.Name.shadow.source(), "#ifdef FRAGMENT\n", "#ifdef FRAGMENT\nlayout(set = 2, binding = 7) uniform sampler2D extra;\n");
    const device = try std.mem.replaceOwned(u8, arena, programs.Name.device.source(), "// mod_functions\n", "\n");
    try @import("scripting").load.testing.makeMods(io, tmp.dir, &.{
        .{ "a", &.{ .{ "mod.ini", "[Mod]\nName=A\n" }, .{ "device.glsl", "#version 450\nbroken\n" } } },
        .{ "b", &.{ .{ "mod.ini", "[Mod]\nName=B\n" }, .{ "bloom.glsl", bloom }, .{ "shadow.glsl", shadow }, .{ "device.glsl", device } } },
    });
    var mods: openreliant.engine.game.bigfile.Mods = try .open(gpa, io, tmp.dir, null);
    defer mods.close(gpa);
    const loaded = try load(arena, .{ .io = io, .root = null }, mods.list);
    // The bloom fits; the shadow is left out; the later device shader stands, but has no place
    // for the functions.
    try std.testing.expect(loaded.replacements.get(.bloom) != null);
    try std.testing.expectEqual(null, loaded.replacements.get(.shadow));
    try std.testing.expect(loaded.replacements.get(.device) != null);
    try std.testing.expectEqual(null, loaded.template);
}

test "a replacement that reads an input OpenReliant doesn't give is left out" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shadow = try std.mem.replaceOwned(u8, arena, programs.Name.shadow.source(), "layout(location = 1) in float strength;", "layout(location = 1) in float strength;\nlayout(location = 5) in vec4 extra;");
    const fixed = try std.mem.replaceOwned(u8, arena, shadow, "kept = strength;", "kept = strength + extra.x;");
    const file: Part = .{ .name = "b/shadow.glsl", .source = fixed };
    try std.testing.expectError(error.LeftOut, replace(arena, .{ .io = std.testing.io, .root = null }, .shadow, file, programs.colour));
}
