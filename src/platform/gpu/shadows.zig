//! The shadow maps (`srshadow`): a depth texture with a layer for each cascade and one for the
//! cockpit, the frame's casters drawn into each before the frame itself, a faint caster into a
//! share of the texels as its strength, and what the device's shader looks them up with
//! (`shaders/device.glsl`).
//!
//! **Improvement:** the original drew no shadows. `Quality.off`, which `Settings.original` sets,
//! leaves them out.

const std = @import("std");
const c = @import("sdl");

const openreliant = @import("openreliant");
const srshadow = openreliant.engine.surrender.surrenderlib.srshadow;
const gpu = @import("../gpu.zig");
const sdl = @import("../sdl.zig");
const Geometry = @import("geometry.zig").Geometry;

/// How the shadows are drawn, or not at all.
pub const Quality = enum {
    off,
    /// Maps 1024 texels across, looked up in four filtered taps, reaching 60,000 from the camera:
    /// soft, and light on older GPUs.
    low,
    /// Maps 4096 texels across, looked up in sixteen, reaching 120,000: sharp near the camera, with
    /// smooth edges, and far out.
    high,

    /// What a quality draws: the maps and the cascades the engine fits them to, and how the
    /// lookup filters them.
    const Detail = struct {
        settings: srshadow.Settings,
        /// The lookup's taps across and down.
        across: u32,
        /// How far apart they are, in texels: the wider, the softer the shadows' edges.
        spacing: f32,
    };

    fn detail(quality: Quality) ?Detail {
        return switch (quality) {
            .off => null,
            .low => .{ .settings = .{ .texels = 1024, .reaches = .{ 1500, 6000, 20000, 60000 } }, .across = 2, .spacing = 1 },
            .high => .{ .settings = .{ .texels = 4096, .reaches = .{ 2500, 10000, 35000, 120000 } }, .across = 4, .spacing = 1.4 },
        };
    }

    /// The maps' size and the cascades' reaches, or null for none.
    pub fn settings(quality: Quality) ?srshadow.Settings {
        return if (quality.detail()) |found| found.settings else null;
    }
};

/// What the device's shader reads of the frame's shadows, in std140's layout.
pub const Uniforms = extern struct {
    /// Each map's box: the cascades', then the cockpit's.
    boxes: [srshadow.map_count]Box = @splat(.{}),
    /// 1 where the frame has shadows.
    enabled: u32 = 0,
    /// The lookup's taps across and down.
    across: u32 = 0,
    /// 1 where the cockpit has a map.
    cockpit: u32 = 0,
    unused: u32 = 0,

    const Box = extern struct {
        rows: [3][4]f32 = @splat(@splat(0)),
        /// For a cascade, the view depth it reaches to.
        far: f32 = 0,
        /// A texel's width in the world, which a pixel's place is moved off its surface by.
        texel: f32 = 0,
        /// How much of the sun a full shadow takes away.
        depth: f32 = 0,
        /// How far apart the lookup's taps are, as a share of the map.
        step: f32 = 0,
    };

    fn of(frame: *const srshadow.Frame, detail: Quality.Detail) Uniforms {
        const step = detail.spacing / @as(f32, @floatFromInt(detail.settings.texels));
        var uniforms: Uniforms = .{ .enabled = 1, .across = detail.across, .cockpit = @intFromBool(frame.cockpit != null) };
        for (&uniforms.boxes, 0..) |*taken, map| {
            const box = frame.box(map) orelse continue;
            const look: Look = if (map == srshadow.cockpit_map) .cockpit else .world;
            taken.* = .{ .rows = box.rows, .far = box.far, .texel = box.texel, .depth = look.depth, .step = step * look.spread };
        }
        return uniforms;
    }

    comptime {
        std.debug.assert(@sizeOf(Box) == 64);
        std.debug.assert(@offsetOf(Uniforms, "enabled") == srshadow.map_count * 64);
    }
};

/// How dark and how soft a map's shadows are: how much of the sun a full shadow takes away, and how
/// much wider than the quality's the lookup's taps spread.
///
/// **Improvement:** the cockpit's shadows are kept faint and soft, so that the struts' shadows
/// sweep across the dashboard without blacking it out. The cockpit takes both key lights, and its
/// map's texels are so fine that its shadows' edges would otherwise be razor sharp.
const Look = struct {
    depth: f32,
    spread: f32,

    const world: Look = .{ .depth = 1, .spread = 1 };
    const cockpit: Look = .{ .depth = 0.4, .spread = 3 };
};

/// How the depth pass keeps a surface from shadowing itself: a little farther from the sun, and
/// more where it slopes away from it.
const bias_constant: f32 = 1;
const bias_slope: f32 = 1.5;

pub const Shadows = struct {
    quality: Quality,
    /// A layer for each map: one texel across while there are no shadows, for the shader to bind
    /// all the same.
    maps: *c.SDL_GPUTexture,
    /// Compares a depth with the map's, filtered between the four texels around it.
    sampler: *c.SDL_GPUSampler,
    vertex_shader: ?*c.SDL_GPUShader = null,
    fragment_shader: ?*c.SDL_GPUShader = null,
    pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    geometry: ?Geometry = null,
    /// The frame's, until it is drawn.
    frame: ?*const srshadow.Frame = null,
    uniforms: Uniforms = .{},

    const Vertex = srshadow.Corner;

    /// The shadows of `quality`, drawn with `code`: OpenReliant's `shadow.glsl`, or a mod's
    /// replacement (`gpu/programs.zig`).
    pub fn init(handle: *c.SDL_GPUDevice, spirv: bool, quality: Quality, code: gpu.programs.Stages) gpu.Error!Shadows {
        const format = depthFormat(handle);
        const maps = try mapsTexture(handle, format, if (quality.settings()) |found| found.texels else 1);
        errdefer c.SDL_ReleaseGPUTexture(handle, maps);
        var sampler_info = std.mem.zeroes(c.SDL_GPUSamplerCreateInfo);
        sampler_info.min_filter = c.SDL_GPU_FILTER_LINEAR;
        sampler_info.mag_filter = c.SDL_GPU_FILTER_LINEAR;
        sampler_info.mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
        sampler_info.address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        sampler_info.address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        sampler_info.address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        sampler_info.enable_compare = true;
        // Lit where the pixel lies no farther from the sun than what the map holds.
        sampler_info.compare_op = c.SDL_GPU_COMPAREOP_LESS_OR_EQUAL;
        const sampler = c.SDL_CreateGPUSampler(handle, &sampler_info) orelse return sdl.fail("SDL_CreateGPUSampler");
        errdefer c.SDL_ReleaseGPUSampler(handle, sampler);
        var shadows: Shadows = .{ .quality = quality, .maps = maps, .sampler = sampler };
        if (quality != .off) {
            errdefer shadows.deinit(handle);
            shadows.vertex_shader = try gpu.shader(handle, spirv, c.SDL_GPU_SHADERSTAGE_VERTEX, code.vertex, 0, 1);
            shadows.fragment_shader = try gpu.shader(handle, spirv, c.SDL_GPU_SHADERSTAGE_FRAGMENT, code.fragment, 0, 0);
            shadows.pipeline = try shadows.depthPipeline(handle, format);
        }
        return shadows;
    }

    pub fn deinit(shadows: *Shadows, handle: *c.SDL_GPUDevice) void {
        Geometry.release(&shadows.geometry, handle);
        if (shadows.pipeline) |made| c.SDL_ReleaseGPUGraphicsPipeline(handle, made);
        if (shadows.vertex_shader) |made| c.SDL_ReleaseGPUShader(handle, made);
        if (shadows.fragment_shader) |made| c.SDL_ReleaseGPUShader(handle, made);
        c.SDL_ReleaseGPUSampler(handle, shadows.sampler);
        c.SDL_ReleaseGPUTexture(handle, shadows.maps);
    }

    /// 32-bit depth where the GPU samples it, 16-bit otherwise.
    fn depthFormat(handle: *c.SDL_GPUDevice) c.SDL_GPUTextureFormat {
        const usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET;
        const wide = c.SDL_GPUTextureSupportsFormat(handle, c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT, c.SDL_GPU_TEXTURETYPE_2D_ARRAY, usage);
        return if (wide) c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT else c.SDL_GPU_TEXTUREFORMAT_D16_UNORM;
    }

    fn mapsTexture(handle: *c.SDL_GPUDevice, format: c.SDL_GPUTextureFormat, across: u32) sdl.Error!*c.SDL_GPUTexture {
        var info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
        info.type = c.SDL_GPU_TEXTURETYPE_2D_ARRAY;
        info.format = format;
        info.usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET;
        info.width = across;
        info.height = across;
        info.layer_count_or_depth = srshadow.map_count;
        info.num_levels = 1;
        return c.SDL_CreateGPUTexture(handle, &info) orelse sdl.fail("SDL_CreateGPUTexture");
    }

    /// Draws the casters' depth alone, both faces, with the bias against self-shadowing, a faint
    /// caster's into a share of the texels as its strength (`shaders/shadow.glsl`). What lies
    /// nearer the sun than the box is held at its near side rather than cut off, so that it still
    /// casts.
    fn depthPipeline(shadows: Shadows, handle: *c.SDL_GPUDevice, format: c.SDL_GPUTextureFormat) sdl.Error!*c.SDL_GPUGraphicsPipeline {
        const attributes = [_]c.SDL_GPUVertexAttribute{
            .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(Vertex, "position") },
            .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT, .offset = @offsetOf(Vertex, "strength") },
        };
        const buffer: c.SDL_GPUVertexBufferDescription = .{ .slot = 0, .pitch = @sizeOf(Vertex), .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX };
        var info = std.mem.zeroes(c.SDL_GPUGraphicsPipelineCreateInfo);
        info.vertex_shader = shadows.vertex_shader;
        info.fragment_shader = shadows.fragment_shader;
        info.vertex_input_state = .{ .vertex_buffer_descriptions = &buffer, .num_vertex_buffers = 1, .vertex_attributes = &attributes, .num_vertex_attributes = attributes.len };
        info.primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
        info.rasterizer_state.fill_mode = c.SDL_GPU_FILLMODE_FILL;
        info.rasterizer_state.cull_mode = c.SDL_GPU_CULLMODE_NONE;
        info.rasterizer_state.enable_depth_bias = true;
        info.rasterizer_state.depth_bias_constant_factor = bias_constant;
        info.rasterizer_state.depth_bias_slope_factor = bias_slope;
        info.rasterizer_state.enable_depth_clip = false;
        info.depth_stencil_state.enable_depth_test = true;
        info.depth_stencil_state.enable_depth_write = true;
        info.depth_stencil_state.compare_op = c.SDL_GPU_COMPAREOP_LESS;
        info.target_info = .{ .num_color_targets = 0, .depth_stencil_format = format, .has_depth_stencil_target = true };
        return c.SDL_CreateGPUGraphicsPipeline(handle, &info) orelse sdl.fail("SDL_CreateGPUGraphicsPipeline");
    }

    /// Takes the frame's shadows, which last until it is drawn.
    pub fn take(shadows: *Shadows, frame: *const srshadow.Frame) void {
        const detail = shadows.quality.detail() orelse return;
        shadows.frame = frame;
        shadows.uniforms = .of(frame, detail);
    }

    /// Forgets the last frame's shadows, as a frame begins.
    pub fn clear(shadows: *Shadows) void {
        shadows.frame = null;
        shadows.uniforms.enabled = 0;
    }

    /// Sends the casters up with the frame's other uploads.
    pub fn upload(shadows: *Shadows, handle: *c.SDL_GPUDevice, copy: *c.SDL_GPUCopyPass) gpu.Error!void {
        const frame = shadows.frame orelse return;
        try Geometry.upload(&shadows.geometry, handle, copy, std.mem.sliceAsBytes(frame.corners), std.mem.sliceAsBytes(frame.indices));
    }

    /// Draws the casters into each map the frame has, each run into the maps it reaches, before
    /// the frame is drawn. A map with no caster is cleared all the same.
    pub fn draw(shadows: *Shadows, commands: *c.SDL_GPUCommandBuffer) sdl.Error!void {
        const frame = shadows.frame orelse return;
        const pipeline = shadows.pipeline orelse return;
        for (0..srshadow.map_count) |map| {
            const box = frame.box(map) orelse continue;
            var depth = std.mem.zeroes(c.SDL_GPUDepthStencilTargetInfo);
            depth.texture = shadows.maps;
            depth.layer = @intCast(map);
            depth.clear_depth = 1;
            depth.load_op = c.SDL_GPU_LOADOP_CLEAR;
            depth.store_op = c.SDL_GPU_STOREOP_STORE;
            depth.stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE;
            depth.stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE;
            const pass = c.SDL_BeginGPURenderPass(commands, null, 0, &depth) orelse return sdl.fail("SDL_BeginGPURenderPass");
            defer c.SDL_EndGPURenderPass(pass);
            const geometry = shadows.geometry orelse continue;
            c.SDL_BindGPUGraphicsPipeline(pass, pipeline);
            geometry.bind(pass);
            c.SDL_PushGPUVertexUniformData(commands, 0, &box.rows, @sizeOf(@TypeOf(box.rows)));
            for (frame.runs) |run| {
                if (run.maps.isSet(map)) c.SDL_DrawGPUIndexedPrimitives(pass, run.count, 1, run.first, 0, 0);
            }
        }
    }

    /// The maps as the device's shader samples them.
    pub fn binding(shadows: Shadows) c.SDL_GPUTextureSamplerBinding {
        return .{ .texture = shadows.maps, .sampler = shadows.sampler };
    }
};

test "Uniforms.of" {
    var frame: srshadow.Frame = .{ .cascades = undefined, .cockpit = null, .corners = &.{}, .indices = &.{}, .runs = &.{} };
    for (&frame.cascades, 0..) |*cascade, index| {
        const n: f32 = @floatFromInt(index);
        cascade.* = .{ .rows = @splat(@splat(n)), .far = 1000 * (n + 1), .texel = n + 0.5, .half = 1 };
    }
    const high = Quality.high.detail().?;
    const uniforms: Uniforms = .of(&frame, high);
    try std.testing.expectEqual(1, uniforms.enabled);
    try std.testing.expectEqual(4, uniforms.across);
    try std.testing.expectEqual(0, uniforms.cockpit);
    try std.testing.expectEqual(2, Uniforms.of(&frame, Quality.low.detail().?).across);
    const third = uniforms.boxes[2];
    try std.testing.expectEqual([4]f32{ 3000, 2.5, 1, 1.4 / 4096.0 }, [4]f32{ third.far, third.texel, third.depth, third.step });
    try std.testing.expectEqual([4]f32{ 3, 3, 3, 3 }, uniforms.boxes[3].rows[1]);
    // With a cockpit, its box follows the cascades', its shadows fainter and softer.
    frame.cockpit = .{ .rows = @splat(@splat(9)), .texel = 0.01, .half = 20 };
    const inside: Uniforms = .of(&frame, high);
    try std.testing.expectEqual(1, inside.cockpit);
    const cockpit = inside.boxes[srshadow.cockpit_map];
    try std.testing.expectEqual([3]f32{ 0.01, 0.4, 3 * 1.4 / 4096.0 }, [3]f32{ cockpit.texel, cockpit.depth, cockpit.step });
}
