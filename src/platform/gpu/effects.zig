//! Mods' post effects ([#559](https://github.com/OpenReliant/openreliant/issues/559)): fragment
//! shaders a mod's player scripts register (`src/scripting/postprocessing.zig`), each drawn as a
//! pass over the whole frame, before the flight display and the menus are drawn over it or after.
//!
//! A pass reads the frame as the passes before it left it (`source`, set 2, binding 0) and the frame
//! as it was before any effect (`frame_image`, binding 1), and gets the frame's size, the time and
//! four parameters the script sets (`Uniforms`, set 3, binding 0), as the shader compiler checks
//! (`shader_compiler.zig`). The passes take turns writing into two targets of the finished frame's
//! format, so each reads what the last wrote. A frame with no passes is drawn exactly as before.
//!
//! **Improvement:** the original has no post effects.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("sdl");

const gpu = @import("../gpu.zig");
const sdl = @import("../sdl.zig");
const fail = sdl.fail;

const log = std.log.scoped(.gpu);

/// When a pass is drawn: over the scene, before the flight display and the menus are drawn over
/// it, or over everything.
pub const Stage = enum { before_hud, after_hud };

/// An effect's handle, which `add` gives.
pub const Id = enum(u32) { _ };

/// A pass the frame draws: an effect, when, and its parameters.
pub const Pass = struct {
    effect: Id,
    stage: Stage,
    parameters: [4]f32 = @splat(0),
};

/// The most passes a frame draws.
pub const max_passes = 64;

/// What a pass's shader reads, in std140's layout: the frame's size in pixels and the time in
/// seconds, then the script's four parameters.
pub const Uniforms = extern struct {
    size_time: [4]f32,
    parameters: [4]f32,

    comptime {
        std.debug.assert(@offsetOf(Uniforms, "parameters") == 16);
        std.debug.assert(@sizeOf(Uniforms) == 32);
    }
};

/// The two textures a pass reads: what the passes before it left, and the frame before any effect.
const samplers = 2;
const uniform_buffers = 1;

/// An effect: its fragment shader, or null once it is removed, and the pipeline it draws with.
const Effect = struct {
    shader: ?*c.SDL_GPUShader,
    pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    /// Whether making its pipeline failed.
    failed: bool = false,

    /// Its pipeline, made the first time it draws. Returns null if the pipeline can't be made, and
    /// the effect is left out from then on.
    fn pipelineFor(effect: *Effect, screen: Screen) ?*c.SDL_GPUGraphicsPipeline {
        if (effect.pipeline) |made| return made;
        if (effect.failed) return null;
        const fragment = effect.shader orelse return null;
        effect.pipeline = gpu.screenPassPipeline(screen.handle, screen.vertex_shader, fragment, screen.format) catch |err| {
            log.err("a mod's post effect is left out: {s}", .{@errorName(err)});
            effect.failed = true;
            return null;
        };
        return effect.pipeline;
    }
};

/// What drawing a pass needs from the GPU device.
pub const Screen = struct {
    handle: *c.SDL_GPUDevice,
    /// The screen-wide triangle's vertex shader (`shaders/bloom.glsl`).
    vertex_shader: *c.SDL_GPUShader,
    sampler: *c.SDL_GPUSampler,
    /// The finished frame's format, which the passes draw in.
    format: c.SDL_GPUTextureFormat,
    width: u32,
    height: u32,
};

/// The effects the mods have added, and the passes the next frame draws.
pub const Effects = struct {
    gpa: Allocator,
    /// Indexed by `Id`. A removed effect leaves its place empty, so the other ids don't change.
    effects: std.ArrayList(Effect) = .empty,
    passes: std.ArrayList(Pass) = .empty,
    /// The time in seconds, which the passes get.
    time: f32 = 0,
    /// The two targets the passes take turns writing into, and their size.
    targets: ?[2]*c.SDL_GPUTexture = null,
    size: [2]u32 = .{ 0, 0 },

    pub fn deinit(effects: *Effects, handle: *c.SDL_GPUDevice) void {
        for (effects.effects.items) |effect| release(handle, effect);
        effects.effects.deinit(effects.gpa);
        effects.passes.deinit(effects.gpa);
        effects.releaseTargets(handle);
    }

    /// Adds an effect of the compiled fragment shader `code`: SPIR-V words where the device takes
    /// SPIR-V, Metal's source otherwise.
    pub fn add(effects: *Effects, handle: *c.SDL_GPUDevice, spirv: bool, code: []const u8) (sdl.Error || Allocator.Error)!Id {
        try effects.effects.ensureUnusedCapacity(effects.gpa, 1);
        const made = try gpu.shader(handle, spirv, c.SDL_GPU_SHADERSTAGE_FRAGMENT, code, samplers, uniform_buffers);
        effects.effects.appendAssumeCapacity(.{ .shader = made });
        return @enumFromInt(effects.effects.items.len - 1);
    }

    /// Removes the effect `id` and the passes that draw it. SDL frees its shader and pipeline once
    /// the frames that use them are done.
    pub fn remove(effects: *Effects, handle: *c.SDL_GPUDevice, id: Id) void {
        const index = @intFromEnum(id);
        if (index >= effects.effects.items.len) return;
        release(handle, effects.effects.items[index]);
        effects.effects.items[index] = .{ .shader = null };
        var kept: usize = 0;
        for (effects.passes.items) |pass| {
            if (pass.effect == id) continue;
            effects.passes.items[kept] = pass;
            kept += 1;
        }
        effects.passes.shrinkRetainingCapacity(kept);
    }

    fn release(handle: *c.SDL_GPUDevice, effect: Effect) void {
        if (effect.pipeline) |made| c.SDL_ReleaseGPUGraphicsPipeline(handle, made);
        if (effect.shader) |made| c.SDL_ReleaseGPUShader(handle, made);
    }

    /// Sets the passes the next frame draws, in order, and the time in seconds. Passes past
    /// `max_passes` and passes of removed effects are left out.
    pub fn set(effects: *Effects, passes: []const Pass, time: f32) void {
        effects.time = time;
        effects.passes.clearRetainingCapacity();
        effects.passes.ensureTotalCapacity(effects.gpa, max_passes) catch return;
        for (passes) |pass| {
            if (effects.passes.items.len == max_passes) break;
            const index = @intFromEnum(pass.effect);
            if (index >= effects.effects.items.len or effects.effects.items[index].shader == null) continue;
            effects.passes.appendAssumeCapacity(pass);
        }
    }

    /// Whether the next frame draws a pass at `stage`.
    pub fn drawsAt(effects: *const Effects, stage: Stage) bool {
        for (effects.passes.items) |pass| if (pass.stage == stage) return true;
        return false;
    }

    /// Draws the passes at `stage` over `shown`, and returns the texture to show after them. That
    /// is `shown` itself if there are no passes at `stage` or they can't be drawn (the log says
    /// why).
    pub fn draw(effects: *Effects, commands: *c.SDL_GPUCommandBuffer, screen: Screen, stage: Stage, shown: *c.SDL_GPUTexture, frame_image: *c.SDL_GPUTexture) *c.SDL_GPUTexture {
        if (!effects.drawsAt(stage)) return shown;
        const targets = effects.ensureTargets(screen) catch |err| {
            log.err("the mods' post effects are left out: {s}", .{@errorName(err)});
            return shown;
        };
        var source = shown;
        for (effects.passes.items) |pass| {
            if (pass.stage != stage) continue;
            const effect = &effects.effects.items[@intFromEnum(pass.effect)];
            const pipeline = effect.pipelineFor(screen) orelse continue;
            // Each pass writes into the target it doesn't read.
            const into = if (source == targets[0]) targets[1] else targets[0];
            const uniforms: Uniforms = .{
                .size_time = .{ @floatFromInt(screen.width), @floatFromInt(screen.height), effects.time, 0 },
                .parameters = pass.parameters,
            };
            gpu.drawScreenPass(commands, into, pipeline, screen.sampler, source, frame_image, std.mem.asBytes(&uniforms)) catch |err| {
                log.err("a mod's post effect is left out: {s}", .{@errorName(err)});
                continue;
            };
            source = into;
        }
        return source;
    }

    /// The two targets, made again if the frame's size has changed.
    fn ensureTargets(effects: *Effects, screen: Screen) sdl.Error![2]*c.SDL_GPUTexture {
        if (effects.targets) |made| {
            if (effects.size[0] == screen.width and effects.size[1] == screen.height) return made;
            effects.releaseTargets(screen.handle);
        }
        const first = try target(screen);
        errdefer c.SDL_ReleaseGPUTexture(screen.handle, first);
        const made: [2]*c.SDL_GPUTexture = .{ first, try target(screen) };
        effects.targets = made;
        effects.size = .{ screen.width, screen.height };
        return made;
    }

    fn releaseTargets(effects: *Effects, handle: *c.SDL_GPUDevice) void {
        const made = effects.targets orelse return;
        for (made) |texture| c.SDL_ReleaseGPUTexture(handle, texture);
        effects.targets = null;
    }
};

fn target(screen: Screen) sdl.Error!*c.SDL_GPUTexture {
    var info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
    info.type = c.SDL_GPU_TEXTURETYPE_2D;
    info.format = screen.format;
    info.usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER;
    info.width = screen.width;
    info.height = screen.height;
    info.layer_count_or_depth = 1;
    info.num_levels = 1;
    info.sample_count = c.SDL_GPU_SAMPLECOUNT_1;
    return c.SDL_CreateGPUTexture(screen.handle, &info) orelse fail("SDL_CreateGPUTexture");
}

test "a frame's passes leave out effects that aren't there, and those past the most" {
    var effects: Effects = .{ .gpa = std.testing.allocator };
    defer {
        effects.effects.deinit(effects.gpa);
        effects.passes.deinit(effects.gpa);
    }
    // Two effects without shaders a test can make: the first stands, the second was removed.
    try effects.effects.append(effects.gpa, .{ .shader = @ptrFromInt(0x1000) });
    try effects.effects.append(effects.gpa, .{ .shader = null });
    const kept: Id = @enumFromInt(0);
    const removed: Id = @enumFromInt(1);
    var passes: [max_passes + 3]Pass = undefined;
    for (&passes, 0..) |*pass, at| pass.* = .{ .effect = if (at == 1) removed else kept, .stage = if (at % 2 == 0) .before_hud else .after_hud };
    passes[2].effect = @enumFromInt(7);
    effects.set(&passes, 1.5);
    try std.testing.expectEqual(max_passes, effects.passes.items.len);
    for (effects.passes.items) |pass| try std.testing.expectEqual(kept, pass.effect);
    try std.testing.expectEqual(1.5, effects.time);
    try std.testing.expect(effects.drawsAt(.before_hud) and effects.drawsAt(.after_hud));
    // None set, none drawn.
    effects.set(&.{}, 2);
    try std.testing.expect(!effects.drawsAt(.before_hud));
}
