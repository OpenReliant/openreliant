//! The driver's side of the mods' post effects ([#559](https://github.com/OpenReliant/openreliant/issues/559)).
//! It compiles the shaders the player scripts register (`platform.shader_compiler`), adds them to
//! the GPU (`platform.gpu.effects`), and gives the GPU each frame's passes from the scripts
//! (`scripting.postprocessing`). Effects draw on the GPU only: with the software device the scripts
//! have no host, and their effects draw nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;

const platform = @import("platform");
const gpu_effects = platform.gpu.effects;
const scripting = @import("scripting");
const postprocessing = scripting.postprocessing;
const Screen = @import("presenter.zig").Screen;

pub const PostEffects = struct {
    gpa: Allocator,
    screen: *Screen,
    /// The scripts that register the effects, if any run.
    presentation: ?*scripting.Presentation,
    /// Whether the effects are drawn: the MOD EFFECTS setting (`--no-mod-effects`).
    drawn: bool = true,
    /// Why the last shader didn't compile, which is passed on to the script.
    message: [max_message]u8 = undefined,

    /// The longest message a script gets about a shader that didn't compile.
    const max_message = 1024;

    // A frame can draw every effect the scripts can register.
    comptime {
        std.debug.assert(postprocessing.max_effects <= gpu_effects.max_passes);
    }

    /// Becomes the scripts' effect host and the GPU's effect source, so that the scripts' effects
    /// compile and draw. Does nothing without scripts or without the GPU.
    pub fn start(effects: *PostEffects) void {
        const shown = effects.presentation orelse return;
        const device = effects.gpu() orelse return;
        shown.setEffectHost(.{ .context = effects, .vtable = &.{ .compile = compile, .remove = remove } });
        device.effect_source = .{ .context = effects, .passes = passes };
    }

    /// Removes the effects from the GPU. Call it before the GPU is destroyed.
    pub fn stop(effects: *PostEffects) void {
        if (effects.presentation) |shown| shown.setEffectHost(null);
        if (effects.gpu()) |device| device.effect_source = null;
    }

    fn gpu(effects: *const PostEffects) ?*platform.gpu.Gpu {
        return switch (effects.screen.*) {
            .gpu => |*device| device,
            .software => null,
        };
    }

    fn from(context: *anyopaque) *PostEffects {
        return @ptrCast(@alignCast(context));
    }

    fn compile(context: *anyopaque, name: []const u8, source: []const u8) postprocessing.EffectHost.Compiled {
        const effects = from(context);
        const result = platform.shader_compiler.compile(effects.gpa, name, source) catch return effects.failed("out of memory compiling the shader");
        defer result.deinit(effects.gpa);
        const code = switch (result) {
            .diagnostic => |text| return effects.failed(text),
            .compiled => |code| code,
        };
        const device = effects.gpu().?;
        const id = device.addEffect(code.spirv, code.metal) catch |err| {
            var buffer: [max_message]u8 = undefined;
            return effects.failed(std.fmt.bufPrint(&buffer, "the GPU can't make the effect: {s}", .{@errorName(err)}) catch "the GPU can't make the effect");
        };
        return .{ .effect = @intFromEnum(id) };
    }

    /// Keeps `text`, cut to `max_message`, as the message the script gets.
    fn failed(effects: *PostEffects, text: []const u8) postprocessing.EffectHost.Compiled {
        const kept = std.mem.trimEnd(u8, text[0..@min(text.len, max_message)], "\n");
        @memcpy(effects.message[0..kept.len], kept);
        return .{ .failed = effects.message[0..kept.len] };
    }

    fn remove(context: *anyopaque, effect: u32) void {
        const device = from(context).gpu() orelse return;
        device.removeEffect(@enumFromInt(effect));
    }

    /// The passes of the effects the scripts have enabled, or none while MOD EFFECTS is off.
    fn passes(context: *anyopaque, buffer: *[gpu_effects.max_passes]gpu_effects.Pass) []const gpu_effects.Pass {
        const effects = from(context);
        const shown = effects.presentation orelse return &.{};
        if (!effects.drawn) return &.{};
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
};

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
