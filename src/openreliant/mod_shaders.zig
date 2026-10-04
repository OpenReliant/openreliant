//! The driver's side of the mods' shaders ([#559](https://github.com/OpenReliant/openreliant/issues/559)):
//! the host of the player scripts' post effects (`scripting.postprocessing`) and of their surface
//! and lighting functions (`scripting.shaders`). It compiles their shaders, or reads them from the
//! shader cache (`platform.shader_cache`), and adds them to the GPU: the post effects as passes
//! (`platform.gpu.effects`), and the functions as variants of the device's fragment shader
//! (`platform.gpu.variants`). Shaders draw on the GPU only: with the software device the scripts
//! have no host, and their shaders draw nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;

const platform = @import("platform");
const gpu_effects = platform.gpu.effects;
const variants = platform.gpu.variants;
const shader_compiler = platform.shader_compiler;
const scripting = @import("scripting");
const postprocessing = scripting.postprocessing;
const shaders = scripting.shaders;
const openreliant = @import("openreliant");
const srtexture = openreliant.engine.surrender.surrenderlib.srtexture;
const Screen = @import("presenter.zig").Screen;

const log = std.log.scoped(.shaders);

pub const ModShaders = struct {
    gpa: Allocator,
    screen: *Screen,
    /// The compiled shaders kept in the game folder.
    cache: platform.shader_cache.Cache,
    /// The scripts that register the shaders, if any run.
    presentation: ?*scripting.Presentation,
    /// The textures the surface functions name.
    textures: *srtexture.Table,
    /// The device shader the functions are compiled into: OpenReliant's own or a mod's
    /// replacement (`whole_shaders.zig`). Null where the replacement has no place for them, and
    /// they draw nothing.
    template: ?variants.Template,
    /// Why the last shader didn't compile, which is passed on to the script.
    message: [max_message]u8 = undefined,
    /// The surface and lighting functions, by the number the GPU knows their variants by.
    functions: std.AutoArrayHashMapUnmanaged(u16, Function) = .empty,
    /// The number the next function gets. 0 is the device shader the GPU started with.
    next_function: u16 = 1,
    /// The lighting function the variants are compiled with, or 0 for none.
    lighting: u16 = 0,
    /// The textures given a surface function, which the next update takes it from again.
    tagged: std.ArrayList(*srtexture.Image) = .empty,

    /// The longest message a script gets about a shader that didn't compile.
    const max_message = 1024;

    // A frame can draw every effect the scripts can register, and each function has its variant.
    comptime {
        std.debug.assert(postprocessing.max_effects <= gpu_effects.max_passes);
        std.debug.assert(shaders.max_functions < std.math.maxInt(u16));
    }

    /// A surface or lighting function as the host keeps it.
    const Function = struct {
        kind: shaders.Kind,
        /// The mod's file, such as `cel/ink.glsl`, and its source.
        name: []u8,
        source: []u8,
        /// The lighting function its variant is compiled with, 0 for none, while it has one.
        compiled_with: ?u16 = null,
        /// Whether the log said which of its textures aren't there.
        warned: bool = false,

        fn part(function: Function) shader_compiler.Part {
            return .{ .name = function.name, .source = function.source };
        }
    };

    /// Becomes the scripts' host for their post effects and functions, and the GPU's effect source,
    /// so that their shaders compile and draw. Does nothing without scripts or without the GPU.
    pub fn start(host: *ModShaders) void {
        const shown = host.presentation orelse return;
        const device = host.gpu() orelse return;
        shown.setEffectHost(.{ .context = host, .vtable = &.{ .compile = compileEffect, .remove = removeEffect } });
        shown.setShaderHost(.{ .context = host, .vtable = &.{ .add = addFunction, .remove = removeFunction, .update = update } });
        device.effect_source = .{ .context = host, .passes = passes };
    }

    /// Removes the shaders from the GPU. Call it before the GPU is destroyed.
    pub fn stop(host: *ModShaders) void {
        if (host.presentation) |shown| {
            shown.setEffectHost(null);
            shown.setShaderHost(null);
        }
        if (host.gpu()) |device| device.effect_source = null;
        host.untag();
        host.tagged.deinit(host.gpa);
        for (host.functions.values()) |function| host.free(function);
        host.functions.deinit(host.gpa);
    }

    fn gpu(host: *const ModShaders) ?*platform.gpu.Gpu {
        return switch (host.screen.*) {
            .gpu => |*device| device,
            .software => null,
        };
    }

    fn from(context: *anyopaque) *ModShaders {
        return @ptrCast(@alignCast(context));
    }

    /// Keeps `text`, cut to `max_message`, as the message the script gets.
    fn keep(host: *ModShaders, text: []const u8) []const u8 {
        const kept = std.mem.trimEnd(u8, text[0..@min(text.len, max_message)], "\n");
        @memcpy(host.message[0..kept.len], kept);
        return host.message[0..kept.len];
    }

    /// The message the script gets when the GPU can't make what it compiled.
    fn gpuFailed(host: *ModShaders, err: anyerror) []const u8 {
        var buffer: [max_message]u8 = undefined;
        return host.keep(std.fmt.bufPrint(&buffer, "the GPU can't make the shader: {s}", .{@errorName(err)}) catch "the GPU can't make the shader");
    }

    fn compileEffect(context: *anyopaque, name: []const u8, source: []const u8) postprocessing.EffectHost.Compiled {
        const host = from(context);
        const result = host.cache.compile(host.gpa, name, source) catch return .{ .failed = host.keep("out of memory compiling the shader") };
        defer result.deinit(host.gpa);
        const code = switch (result) {
            .diagnostic => |text| return .{ .failed = host.keep(text) },
            .compiled => |code| code,
        };
        const id = host.gpu().?.addEffect(code.spirv, code.metal) catch |err| return .{ .failed = host.gpuFailed(err) };
        return .{ .effect = @intFromEnum(id) };
    }

    fn removeEffect(context: *anyopaque, effect: u32) void {
        const device = from(context).gpu() orelse return;
        device.removeEffect(@enumFromInt(effect));
    }

    /// The passes of the effects the scripts have enabled.
    fn passes(context: *anyopaque, buffer: *[gpu_effects.max_passes]gpu_effects.Pass) []const gpu_effects.Pass {
        const host = from(context);
        const shown = host.presentation orelse return &.{};
        var scripted: [postprocessing.max_effects]postprocessing.Pass = undefined;
        const listed = shown.effectPasses(&scripted);
        for (listed, buffer[0..listed.len]) |pass, *into| into.* = .{
            .effect = @enumFromInt(pass.effect),
            .stage = switch (pass.stage) {
                .before_hud => .before_hud,
                .after_hud => .after_hud,
            },
            .parameters = pass.parameters,
        };
        return buffer[0..listed.len];
    }

    /// Compiles the variant of `template` with `lighting` and `surface`, each a function or none,
    /// through the cache.
    fn compileVariant(host: *ModShaders, template: *const variants.Template, lighting: ?Function, surface: ?Function) Allocator.Error!shader_compiler.Result {
        var buffer: [variants.max_parts]shader_compiler.Part = undefined;
        const lit = if (lighting) |function| function.part() else null;
        const surfaced = if (surface) |function| function.part() else null;
        var name_buffer: [512]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "variant {s} {s} {s}", .{
            template.after.name,
            if (lit) |part| part.name else "-",
            if (surfaced) |part| part.name else "-",
        }) catch "variant";
        return host.cache.compileParts(host.gpa, name, .openreliant, .fragment, template.parts(lit, surfaced, &buffer), variants.preamble(lit != null, surfaced != null));
    }

    /// Compiles the function of `kind` in `source` on its own, to find its mistakes, and keeps it.
    /// Without a template it is kept as it is, and draws nothing.
    fn addFunction(context: *anyopaque, kind: shaders.Kind, name: []const u8, source: []const u8) shaders.ShaderHost.Compiled {
        const host = from(context);
        const out_of_memory: shaders.ShaderHost.Compiled = .{ .failed = host.keep("out of memory compiling the shader") };
        if (host.next_function == std.math.maxInt(u16)) return .{ .failed = host.keep("too many functions registered since OpenReliant started") };
        host.functions.ensureUnusedCapacity(host.gpa, 1) catch return out_of_memory;
        const name_copy = host.gpa.dupe(u8, name) catch return out_of_memory;
        const source_copy = host.gpa.dupe(u8, source) catch {
            host.gpa.free(name_copy);
            return out_of_memory;
        };
        const function: Function = .{ .kind = kind, .name = name_copy, .source = source_copy };
        if (host.template) |*template| {
            const result = switch (kind) {
                .surface => host.compileVariant(template, null, function),
                .lighting => host.compileVariant(template, function, null),
            } catch {
                host.free(function);
                return out_of_memory;
            };
            defer result.deinit(host.gpa);
            if (result == .diagnostic) {
                host.free(function);
                return .{ .failed = host.keep(result.diagnostic) };
            }
        }
        const id = host.next_function;
        host.next_function += 1;
        host.functions.putAssumeCapacity(id, function);
        return .{ .function = id };
    }

    fn free(host: *ModShaders, function: Function) void {
        host.gpa.free(function.name);
        host.gpa.free(function.source);
    }

    fn removeFunction(context: *anyopaque, id: u16) void {
        const host = from(context);
        if (host.gpu()) |device| device.removeVariant(id);
        const removed = host.functions.fetchSwapRemove(id) orelse return;
        host.free(removed.value);
        if (host.lighting == id) host.lighting = 0;
    }

    /// Draws `functions` from now on: compiles the variants the lighting function that draws
    /// needs, gives the textures their surface functions, and sets what every lit surface takes.
    fn update(context: *anyopaque, functions: []const shaders.Function) void {
        const host = from(context);
        const device = host.gpu() orelse return;
        // The enabled lighting function registered last draws.
        var lighting: u16 = 0;
        device.mod_shaders.lighting = @splat(0);
        for (functions) |function| if (function.kind == .lighting and function.enabled) {
            lighting = function.function;
            device.mod_shaders.lighting = function.parameters;
        };
        if (lighting != host.lighting) {
            if (host.lighting != 0) host.drop(host.lighting);
            host.lighting = lighting;
        }
        if (lighting != 0) host.make(lighting, lighting);
        device.mod_shaders.base = lighting;
        // Each enabled surface function's variant, with the lighting function.
        for (host.functions.keys(), host.functions.values()) |id, function| {
            if (function.kind != .surface) continue;
            if (enabled(functions, id)) host.make(id, lighting) else host.drop(id);
        }
        // The textures and every lit surface, by the surface functions in the order they were
        // registered, so that a later one wins.
        host.untag();
        device.mod_shaders.every = null;
        for (functions) |function| {
            if (function.kind != .surface or !function.enabled) continue;
            const surface: srtexture.ModSurface = .{ .function = function.function, .parameters = function.parameters };
            if (function.everywhere) device.mod_shaders.every = surface;
            host.tag(function, surface);
        }
    }

    fn enabled(functions: []const shaders.Function, id: u16) bool {
        for (functions) |function| if (function.function == id) return function.enabled;
        return false;
    }

    /// Makes the variant of the function `id` with the lighting function `lighting`, unless it has
    /// it already. One that doesn't compile with it is left out, which the log says, and the
    /// function's draws look as if it had none.
    fn make(host: *ModShaders, id: u16, lighting: u16) void {
        const function = host.functions.getPtr(id) orelse return;
        if (function.compiled_with == lighting) return;
        const device = host.gpu() orelse return;
        const template = if (host.template) |*held| held else return;
        function.compiled_with = lighting;
        const lit = if (lighting != 0) host.functions.get(lighting) else null;
        const result = host.compileVariant(template, lit, if (function.kind == .surface) function.* else null) catch {
            log.warn("{s} is left out: out of memory compiling it", .{function.name});
            return device.removeVariant(id);
        };
        defer result.deinit(host.gpa);
        switch (result) {
            .diagnostic => |text| {
                log.warn("{s} is left out: it doesn't compile into {s} with {s}: {s}", .{
                    function.name,
                    template.after.name,
                    if (lit) |other| other.name else "no lighting function",
                    std.mem.trimEnd(u8, text, "\n"),
                });
                device.removeVariant(id);
            },
            .compiled => |code| device.setVariant(id, code.spirv, code.metal) catch |err| {
                log.warn("{s} is left out: the GPU can't make it: {s}", .{ function.name, @errorName(err) });
                device.removeVariant(id);
            },
        }
    }

    /// Removes the variant of the function `id`, if it has one.
    fn drop(host: *ModShaders, id: u16) void {
        const function = host.functions.getPtr(id) orelse return;
        function.compiled_with = null;
        if (host.gpu()) |device| device.removeVariant(id);
    }

    /// Gives the textures `function` names its surface function, `surface`.
    fn tag(host: *ModShaders, function: shaders.Function, surface: srtexture.ModSurface) void {
        const kept = host.functions.getPtr(function.function) orelse return;
        for (function.textures) |name| {
            const image = host.textures.find(name) catch null orelse {
                if (!kept.warned) log.warn("{s}: there is no texture {s}", .{ kept.name, name });
                continue;
            };
            host.tagged.append(host.gpa, image) catch continue;
            image.surface = surface;
        }
        kept.warned = true;
    }

    /// Takes the textures' surface functions away.
    fn untag(host: *ModShaders) void {
        for (host.tagged.items) |image| image.surface = null;
        host.tagged.clearRetainingCapacity();
    }
};

test "the cel-shading example's functions compile into a variant of the device shader" {
    const gpa = std.testing.allocator;
    var buffer: [variants.max_parts]shader_compiler.Part = undefined;
    const lighting: shader_compiler.Part = .{ .name = "cel-shading/bands.glsl", .source = shaders.testing.cel_bands };
    const surface: shader_compiler.Part = .{ .name = "cel-shading/ink.glsl", .source = shaders.testing.cel_ink };
    const result = try shader_compiler.compileParts(gpa, .openreliant, .fragment, variants.Template.builtin().parts(lighting, surface, &buffer), variants.preamble(true, true));
    defer result.deinit(gpa);
    switch (result) {
        .compiled => |code| try std.testing.expect(code.spirv.len > 0 and code.metal.len > 0),
        .diagnostic => |text| {
            std.debug.print("{s}\n", .{text});
            return error.TestUnexpectedResult;
        },
    }
}

test "the CRT example's shader compiles for both devices" {
    const gpa = std.testing.allocator;
    const result = try platform.shader_compiler.compile(gpa, "crt/crt.frag", postprocessing.testing.crt_shader);
    defer result.deinit(gpa);
    switch (result) {
        .compiled => |code| try std.testing.expect(code.spirv.len > 0 and code.metal.len > 0),
        .diagnostic => |text| {
            std.debug.print("{s}\n", .{text});
            return error.TestUnexpectedResult;
        },
    }
}
