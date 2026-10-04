//! The mods' post effects as the driver draws them ([#559](https://github.com/OpenReliant/openreliant/issues/559)):
//! it compiles the shaders the player scripts register (`platform.shader_compiler`), adds them to
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

const log = std.log.scoped(.scripts);

pub const PostEffects = struct {
    gpa: Allocator,
    screen: *Screen,
    /// The scripts that register the effects, where any run.
    presentation: ?*scripting.Presentation,
    /// Whether the effects are drawn: the MOD EFFECTS setting (`--no-mod-effects`).
    drawn: bool = true,
    /// Why the last shader didn't compile, which the scripts get.
    message: [max_message]u8 = undefined,

    /// The longest message a script gets of why a shader didn't compile.
    const max_message = 1024;

    /// Has the scripts' effects compiled and drawn, as the GPU draws its frames.
    pub fn start(effects: *PostEffects) void {
        const shown = effects.presentation orelse return;
        const device = effects.gpu() orelse return;
        shown.setEffectHost(.{ .context = effects, .vtable = &.{ .compile = compile, .remove = remove } });
        device.effect_source = .{ .context = effects, .passes = passes };
    }

    /// Takes the effects back from the GPU, before it goes.
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

    /// `text`, kept as the message the scripts get, cut to `max_message`.
    fn failed(effects: *PostEffects, text: []const u8) postprocessing.EffectHost.Compiled {
        const kept = std.mem.trimEnd(u8, text[0..@min(text.len, max_message)], "\n");
        @memcpy(effects.message[0..kept.len], kept);
        return .{ .failed = effects.message[0..kept.len] };
    }

    fn remove(context: *anyopaque, effect: u32) void {
        const device = from(context).gpu() orelse return;
        device.removeEffect(@enumFromInt(effect));
    }

    /// The passes the scripts have enabled, while MOD EFFECTS is on.
    fn passes(context: *anyopaque, buffer: *[gpu_effects.max_passes]gpu_effects.Pass) []const gpu_effects.Pass {
        const effects = from(context);
        const shown = effects.presentation orelse return &.{};
        if (!effects.drawn) return &.{};
        var scripted: [postprocessing.max_effects]postprocessing.Pass = undefined;
        const listed = shown.effectPasses(&scripted);
        const count = @min(listed.len, buffer.len);
        for (listed[0..count], buffer[0..count]) |pass, *drawn| drawn.* = .{
            .effect = @enumFromInt(pass.effect),
            .stage = switch (pass.stage) {
                .before_hud => .before_hud,
                .after_hud => .after_hud,
            },
            .parameters = pass.parameters,
        };
        return buffer[0..count];
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
