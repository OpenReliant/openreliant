//! The GPU device: draws what Surrender's Direct3D driver hands over as Direct3D 7 drew it, with
//! SDL's GPU interface, on Metal, Vulkan or Direct3D 12. It stands where `IDirect3DDevice7` stood
//! ([`device.zig`](../engine/surrender/srd3d/device.zig)); the software device is its reference.
//!
//! The game's textures are small, and its draws are too: the driver draws a strip, a fan or one
//! blended polygon at a time. So each texture is a layer of an array holding the textures of its
//! size and levels, each vertex names its layer, and consecutive draws with the same render states
//! go to the GPU as one. `shaders/device.glsl` does what Direct3D 7's texture stages did.
//!
//! **Improvements**, each of which `Settings.original` turns off: the frame is drawn at the
//! display's own resolution, with several samples a pixel; textures are filtered trilinearly,
//! sixteen times anisotropic, and magnified with a Catmull-Rom filter, where the original filtered
//! bilinearly from the nearest level; colour is 32-bit, where the original drew in 16 bits; the
//! key lights cast shadows (`gpu/shadows.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("sdl");

const openreliant = @import("openreliant");
const device = openreliant.engine.surrender.srd3d.device;
const srd3d = openreliant.engine.surrender.srd3d.srd3d;
const srapiext = openreliant.engine.surrender.surrenderlib.srapiext;
const srshadow = openreliant.engine.surrender.surrenderlib.srshadow;
const srtexture = openreliant.engine.surrender.surrenderlib.srtexture;
const srgb = openreliant.engine.surrender.colour;
const Geometry = @import("gpu/geometry.zig").Geometry;
const shadow = @import("gpu/shadows.zig");
const sdl = @import("sdl.zig");

const log = std.log.scoped(.gpu);

pub const Error = sdl.Error || Allocator.Error;
const fail = sdl.fail;

/// How the frame is drawn beyond what the original did.
pub const Settings = struct {
    /// 16-bit colour, dithered, as the original's 16-bit display modes drew: into a 16-bit colour
    /// buffer where the GPU draws into one, with a 16-bit depth buffer.
    sixteen_bit: bool = false,
    /// Samples a pixel, for anti-aliasing: 1, 2, 4 or 8, cut to what the GPU offers. The original
    /// took one.
    samples: u8 = 4,
    filter: Filter = .crisp,
    /// Bleeds a little light out of the frame's bright parts, its lights, glows, flares and the
    /// sun, as a camera does. The original drew none.
    bloom: bool = true,
    /// Dithers 32-bit colour as well, which keeps a dark gradient from banding.
    dither: bool = true,
    /// Waits for the display to show each frame, as DirectDraw's flip did.
    vsync: bool = true,
    /// Lights each pixel with the game's own directional and point lights, rather than each
    /// vertex, so that hulls of few polygons shade smoothly. The original lit each vertex.
    pixel_lighting: bool = true,
    /// Lights and filters in linear light, where the original lit the encoded colours: textures and
    /// colours are decoded, lit, and encoded again as each pixel is written. What is blended, the
    /// game's effects among it, is blended encoded, as it was made to be, into a frame of floats
    /// that eases what is stacked past white rather than clipping it. 16-bit colour keeps the
    /// original's way.
    linear_light: bool = true,
    /// Shadows from the key lights (`gpu/shadows.zig`), where each pixel is lit. The original drew
    /// none.
    shadows: Shadows = .high,
    /// Shadows in the cockpit as well: the canopy's struts on the dashboard.
    cockpit_shadows: bool = true,
    /// Shades the material maps of a mod's textures (`srtexture.Image.Maps`), where each pixel is
    /// lit: the surface's normals, and the highlights its roughness and its metal give, in place of
    /// the driver's highlight pass. The original had none.
    materials: bool = true,
    /// The frames' size, a share of the window's own at the display's density, or a size in pixels
    /// whatever the window's, which shows them scaled to fit.
    size: device.FrameSize = .window,

    pub const Shadows = shadow.Quality;

    pub const Filter = enum {
        /// As the original: bilinear, from the nearest level.
        original,
        /// Trilinear, sixteen times anisotropic: steady at a distance and sharp at an angle.
        trilinear,
        /// Trilinear, and magnified with a Catmull-Rom filter: as sharp as the textures allow.
        crisp,
    };

    /// The original's look: 16-bit colour, one sample a pixel, bilinear filtering.
    pub const original: Settings = .{
        .sixteen_bit = true,
        .samples = 1,
        .filter = .original,
        .bloom = false,
        .dither = false,
        .pixel_lighting = false,
        .linear_light = false,
        .shadows = .off,
        .materials = false,
    };
};

/// A vertex as the shader takes it: the driver's, less the specular colour, which Direct3D 7 left
/// unused with specular lighting off, and with its texture's layer.
const Vertex = extern struct {
    position: [4]f32,
    /// The driver's colour: its bytes blue, green, red and alpha.
    diffuse: u32,
    uv: [2]f32,
    /// -1 for none.
    layer: i32,
    /// For lighting each pixel: where it stands in the camera's frame, its normal there, and the
    /// lights that don't reach it, all ones for none.
    view: [3]f32,
    normal: [3]f32,
    light_mask: u32,
    /// What its pixels take besides their lights and colours.
    shading: Shading,

    comptime {
        std.debug.assert(@sizeOf(Vertex) == 64);
    }
};

/// A draw's shading as the shader reads it from each vertex, one word: the shadows its pixels take
/// in the low byte, how its texture is magnified in the next two bits, whether the key lights reach
/// past its terminator in the one after, and whether its texture's normal map and material map are
/// shaded in the two after that.
const Shading = packed struct(u32) {
    receives: device.Receives,
    magnify: srtexture.Image.Magnify,
    soft_terminator: bool,
    normal_map: bool = false,
    material_map: bool = false,
    _unused: u19 = 0,

    /// A draw's shading, its texture's maps shaded where `materials` (`Gpu.shadesMaterials`).
    fn of(state: device.State, materials: bool) Shading {
        const maps: srtexture.Image.Maps = if (state.texture) |image| (if (materials) image.maps else .{}) else .{};
        return .{
            .receives = state.receives,
            .magnify = if (state.texture) |image| image.magnify else .sharp,
            .soft_terminator = state.soft_terminator,
            .normal_map = maps.normal != null,
            .material_map = maps.orm != null,
        };
    }
};

/// The textures the device's fragment shader reads: the texture array, the shadows' maps, the
/// array's normal maps and material maps, and the reflections' cube.
const fragment_samplers = 5;

/// The most lights the shader takes in a frame. The driver lights the vertices with the rest.
const max_lights = 64;

/// The frame's directional and point lights as the shader takes them, in std140's layout.
const Lighting = extern struct {
    /// How many of `lights` there are, in the first.
    count: [4]u32 = @splat(0),
    lights: [max_lights]Light = @splat(.{}),

    const Light = extern struct {
        /// Red, green and blue; the fourth is unused.
        colour: [4]f32 = @splat(0),
        /// For a directional light, toward it, as long as its intensity; for a point light, where
        /// it stands, and its reach.
        vector: [4]f32 = @splat(0),
        mask: u32 = 0,
        kind: Kind = .directional,
        /// 1 where a caster shades what it lights.
        shadowed: u32 = 0,
        unused: u32 = 0,

        const Kind = enum(u32) { directional = 0, point = 1 };
    };

    /// Takes as many of `list` as the shader does, from the first, and returns how many: their
    /// colours in linear light, where it is `linear`.
    fn take(lighting: *Lighting, list: []const device.Light, linear: bool) usize {
        const count = @min(list.len, max_lights);
        for (list[0..count], lighting.lights[0..count]) |light, *taken| {
            taken.* = switch (light.kind) {
                .directional => |directional| .{
                    .colour = colourOf(directional.colour, 1, linear),
                    .vector = .{ directional.toward[0], directional.toward[1], directional.toward[2], 0 },
                    .mask = light.mask,
                    .kind = .directional,
                    .shadowed = @intFromBool(light.shadowed),
                },
                .point => |point| .{
                    .colour = colourOf(point.colour, point.intensity, linear),
                    .vector = .{ point.position[0], point.position[1], point.position[2], point.reach },
                    .mask = light.mask,
                    .kind = .point,
                },
            };
        }
        lighting.count[0] = @intCast(count);
        return count;
    }

    /// A light's colour times `intensity`, decoded into linear light first where `linear`.
    fn colourOf(colour: [3]f32, intensity: f32, linear: bool) [4]f32 {
        var taken: [4]f32 = @splat(0);
        for (taken[0..3], colour) |*channel, given| channel.* = (if (linear) srgb.decoded(given) else given) * intensity;
        return taken;
    }

    comptime {
        std.debug.assert(@sizeOf(Light) == 48);
        std.debug.assert(@offsetOf(Lighting, "lights") == 16);
        // SDL's Vulkan device binds 4 KiB of each uniform push, so the shader sees no more.
        std.debug.assert(@sizeOf(Lighting) <= 4096);
    }
};

/// The primitives the shader draws; strips and fans go as lists.
const Topology = enum { points, lines, triangles };

/// What picks a pipeline: the topology and the render states.
const PipelineKey = struct {
    topology: Topology,
    depth: srd3d.Depth,
    blend: ?srd3d.Factors,
    into: Into = .scene,
};

/// What a pass of the device's shader draws into: the scene, in floats where the device lights in
/// linear light, several samples a pixel and with a depth buffer; the finished frame, which the
/// display is drawn over, of one sample and no depth; or a face of the reflections' cube, in the
/// scene's format, of one sample and no depth.
const Into = enum { scene, finished, reflections };

/// The pipelines the device makes as it starts (`Gpu.prepare`): the scene's, for each layer and
/// blend mode in each topology, and those that test no depth again for what is drawn over the
/// finished frame, which has no depth buffer. Each once, though layers and modes share them.
const prepared = keys: {
    const layers = std.enums.values(srd3d.Layer);
    const modes = std.enums.values(srapiext.Material.Blend);
    const topologies = std.enums.values(Topology);
    var found: [layers.len * modes.len * topologies.len * 2]PipelineKey = undefined;
    var count: usize = 0;
    @setEvalBranchQuota(20_000);
    for (layers) |layer| for (modes) |mode| for (topologies) |drawn| {
        const scene: PipelineKey = .{ .topology = drawn, .depth = srd3d.depth(layer, mode), .blend = srd3d.factors(mode) };
        var over = scene;
        over.into = .finished;
        for ([_]PipelineKey{ scene, over }) |key| {
            if (key.into != .scene and key.depth.testing) continue;
            const known = for (found[0..count]) |seen| {
                if (std.meta.eql(seen, key)) break true;
            } else false;
            if (known) continue;
            found[count] = key;
            count += 1;
        }
    };
    break :keys found[0..count].*;
};

/// A texture's size and levels: textures alike share arrays.
const Shape = struct { width: u32, height: u32, levels: u32 };

/// The most layers an array takes: the fewest Vulkan guarantees. More textures of a shape go to a
/// second array.
const max_layers = 256;

/// The layers a new array of the cache's largest textures, 256x256, starts with; it grows as more
/// come (`Gpu.uploadTextures`).
const first_layers = 16;

/// The side of the cache's largest textures.
const cache_side = 256;

/// The layers a new array of `shape` starts with: as many as take the room `first_layers` of the
/// cache's largest textures take, and at least one, so that a mod's large textures reserve no more
/// than they fill.
fn firstLayers(shape: Shape) u32 {
    const room = first_layers * cache_side * cache_side;
    return std.math.clamp(room / (shape.width * shape.height), 1, first_layers);
}

test firstLayers {
    try std.testing.expectEqual(first_layers, firstLayers(.{ .width = 256, .height = 256, .levels = 9 }));
    try std.testing.expectEqual(first_layers, firstLayers(.{ .width = 8, .height = 4, .levels = 1 }));
    try std.testing.expectEqual(4, firstLayers(.{ .width = 512, .height = 512, .levels = 10 }));
    try std.testing.expectEqual(1, firstLayers(.{ .width = 4096, .height = 4096, .levels = 13 }));
}

const Array = struct {
    shape: Shape,
    texture: *c.SDL_GPUTexture,
    capacity: u32,
    count: u32,
    /// Its textures' normal maps and material maps, each at its texture's layer, in linear values
    /// (`map_format`): made as the first texture with such a map goes up.
    normals: ?*c.SDL_GPUTexture = null,
    materials: ?*c.SDL_GPUTexture = null,
};

/// The format of the arrays of material maps, whose values are linear.
const map_format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;

/// The reflections' cube's side in pixels, and its mipmap levels, down to a pixel.
const reflection_side = 256;
const reflection_levels = std.math.log2_int(u32, reflection_side) + 1;

/// A cube's faces.
const cube_face_count = 6;

/// The reflections' sampler: trilinear between the cube's levels, the faces' edges held.
fn reflectionSampler(handle: *c.SDL_GPUDevice) sdl.Error!*c.SDL_GPUSampler {
    var info = std.mem.zeroes(c.SDL_GPUSamplerCreateInfo);
    info.min_filter = c.SDL_GPU_FILTER_LINEAR;
    info.mag_filter = c.SDL_GPU_FILTER_LINEAR;
    info.mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR;
    info.address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    info.address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    info.address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    info.max_lod = reflection_levels;
    return c.SDL_CreateGPUSampler(handle, &info) orelse fail("SDL_CreateGPUSampler");
}

/// Where a texture lies: its array and its layer. The device keeps it in the image's `device`, as
/// the driver's `texture_upload` keeps the device texture it makes; an image never drawn holds 0.
const Slot = packed struct(u32) {
    layer: u16,
    array: u15,
    placed: bool = true,

    fn of(image: srtexture.Image) ?Slot {
        const slot: Slot = @bitCast(@as(u32, @truncate(image.device)));
        return if (slot.placed) slot else null;
    }
};

/// A run of the frame's indices drawn with one pipeline and one array.
const Run = struct {
    key: PipelineKey,
    /// The face of the reflections' cube it is drawn into, or null for the frame.
    face: ?u3 = null,
    /// Null while no vertex of the run has a texture.
    array: ?u15,
    /// Read held at its texture's edges (`edge_sampler`): a point-filtered draw's, which the
    /// original never filtered past its edges.
    held: bool = false,
    first: u32,
    count: u32,
};

/// A texture placed in its layer this frame, with its maps, to go up to the GPU before the frame is
/// drawn.
const Upload = struct { levels: []const srtexture.Level, maps: srtexture.Image.Maps = .{}, slot: Slot };

pub const Gpu = struct {
    gpa: Allocator,
    handle: *c.SDL_GPUDevice,
    window: *c.SDL_Window,
    settings: Settings,
    samples: c.SDL_GPUSampleCount,
    /// Lights in linear light, into a frame of floats (`Settings.linear_light`).
    linear: bool,
    /// What the scene is drawn into: floats where it lights in linear light, the display's own
    /// format otherwise.
    colour_format: c.SDL_GPUTextureFormat,
    /// What the finished frame is kept in, encoded for the display, which the display is drawn over.
    finish_format: c.SDL_GPUTextureFormat,
    /// What the textures are kept in: sRGB in linear light, so that sampling decodes them.
    texture_format: c.SDL_GPUTextureFormat,
    depth_format: c.SDL_GPUTextureFormat,
    vertex_shader: *c.SDL_GPUShader,
    fragment_shader: *c.SDL_GPUShader,
    sampler: *c.SDL_GPUSampler,
    /// What the images drawn over the finished frame, the display's and the menus', and the
    /// point-filtered draws, the background image's, are read with: as `sampler`, but held at their
    /// edges rather than wrapping, as Direct3D 7 wrapped the scene's textures, so that a filter at an
    /// image's edge reads nothing from its far side.
    edge_sampler: *c.SDL_GPUSampler,
    /// What the screen's passes read with: no wrapping, so a blur does not pull in the far edge.
    screen_sampler: *c.SDL_GPUSampler,
    /// The screen's passes (`shaders/bloom.glsl`): the bloom's, and the last, which finishes the
    /// frame, adding the bloom back and easing a frame of floats into the display's.
    screen_vertex_shader: ?*c.SDL_GPUShader = null,
    screen_fragment_shader: ?*c.SDL_GPUShader = null,
    /// Draws the bloom's passes, into targets of the scene's format.
    bloom_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    /// Draws the last pass, into the finished frame.
    finish_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    /// Puts the finished frame on the screen through the gamma ramp, in the swapchain's format,
    /// which it was made for; made the first time the brightness is other than 1.
    gamma_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    gamma_format: c.SDL_GPUTextureFormat = c.SDL_GPU_TEXTUREFORMAT_INVALID,
    /// Whether the GPU takes SPIR-V, rather than Metal's shaders.
    spirv: bool,
    /// The brightness the display's gamma ramp is set to (`Device.gamma`): 1 puts the finished
    /// frame on the screen as it is. Where the ramp's pass can't be made, the frame goes as it is.
    brightness: f32 = 1,
    gamma_failed: bool = false,
    pipelines: std.AutoHashMapUnmanaged(PipelineKey, *c.SDL_GPUGraphicsPipeline) = .empty,
    arrays: std.ArrayList(Array) = .empty,
    uploads: std.ArrayList(Upload) = .empty,
    /// A white texel, bound for runs with no texture.
    blank: Slot = undefined,
    /// A texel bound for the maps of an array without them, which the shader never reads.
    no_maps: *c.SDL_GPUTexture = undefined,
    /// OpenReliant's: the reflections' cube (`srcore.cube_faces`), what a material's pixels
    /// reflect: the surroundings as the scene draws them, in its format. Made as it is first drawn.
    reflections: ?*c.SDL_GPUTexture = null,
    /// A cube bound in place of the reflections where there are none, which the shader never reads.
    no_reflections: *c.SDL_GPUTexture = undefined,
    /// The reflections' sampler: trilinear, the faces' edges held.
    reflection_sampler: *c.SDL_GPUSampler = undefined,
    /// The face of the reflections the draws go to, while they are drawn.
    face: ?u3 = null,
    /// Whether the reflections were drawn this frame.
    reflected: bool = false,
    /// Whether a texture with a material map has gone up: the reflections are drawn only then.
    has_materials: bool = false,
    /// Set where the reflections' cube can't be made, which leaves them out.
    reflections_failed: bool = false,
    vertices: std.ArrayList(Vertex) = .empty,
    indices: std.ArrayList(u32) = .empty,
    runs: std.ArrayList(Run) = .empty,
    /// Where the runs drawn over the finished frame begin; null while the frame holds none.
    overlay_from: ?u32 = null,
    geometry: ?Geometry = null,
    targets: ?Targets = null,
    /// Set when a draw was lost for want of memory: the frame is not shown.
    failed: bool = false,
    /// The frame's lights, for lighting each pixel.
    lighting: Lighting = .{},
    shadows: shadow.Shadows,

    const Targets = struct {
        width: u32,
        height: u32,
        /// Drawn into, with several samples a pixel when anti-aliasing.
        colour: *c.SDL_GPUTexture,
        /// What the samples resolve to, when there are several.
        resolved: ?*c.SDL_GPUTexture,
        depth: *c.SDL_GPUTexture,
        /// Half the frame across and down, which the bloom is worked out in: two, to blur along
        /// one axis into the other and back.
        bloom: ?[2]*c.SDL_GPUTexture,
        bloom_width: u32 = 0,
        bloom_height: u32 = 0,
        /// The frame with its bloom added back, which is what goes to the screen and to a
        /// screenshot; null where nothing blooms and the frame itself is what is shown.
        composed: ?*c.SDL_GPUTexture,

        /// What the frame was drawn into.
        fn frame(targets: Targets) *c.SDL_GPUTexture {
            return targets.resolved orelse targets.colour;
        }

        /// What is shown: the frame, or the frame with its bloom.
        fn finished(targets: Targets) *c.SDL_GPUTexture {
            return targets.composed orelse targets.frame();
        }
    };

    const shaders = struct {
        const vertex_spirv = @embedFile("shaders/device.vert.spv");
        const vertex_msl = @embedFile("shaders/device.vert.msl");
        const fragment_spirv = @embedFile("shaders/device.frag.spv");
        const fragment_msl = @embedFile("shaders/device.frag.msl");
        const bloom_vertex_spirv = @embedFile("shaders/bloom.vert.spv");
        const bloom_vertex_msl = @embedFile("shaders/bloom.vert.msl");
        const bloom_fragment_spirv = @embedFile("shaders/bloom.frag.spv");
        const bloom_fragment_msl = @embedFile("shaders/bloom.frag.msl");
    };

    /// How bright a colour must be before it blooms, and how much of the bloom is added back.
    const bloom_threshold: f32 = 0.35;
    const bloom_strength: f32 = 0.9;

    /// One GPU device a run: the textures' slots it keeps in their images are its own.
    pub fn init(gpa: Allocator, handle: *c.SDL_GPUDevice, window: *c.SDL_Window, settings: Settings) Error!Gpu {
        const formats = c.SDL_GetGPUShaderFormats(handle);
        const spirv = formats & c.SDL_GPU_SHADERFORMAT_SPIRV != 0;
        if (!spirv and formats & c.SDL_GPU_SHADERFORMAT_MSL == 0) {
            log.err("the GPU takes neither SPIR-V nor Metal's shaders", .{});
            return error.Sdl;
        }
        const vertex_shader = try shader(handle, spirv, c.SDL_GPU_SHADERSTAGE_VERTEX, if (spirv) shaders.vertex_spirv else shaders.vertex_msl, 0, 1);
        errdefer c.SDL_ReleaseGPUShader(handle, vertex_shader);
        const fragment_shader = try shader(handle, spirv, c.SDL_GPU_SHADERSTAGE_FRAGMENT, if (spirv) shaders.fragment_spirv else shaders.fragment_msl, fragment_samplers, 3);
        errdefer c.SDL_ReleaseGPUShader(handle, fragment_shader);
        // Shadows darken what each pixel is lit by, so they need each pixel lit.
        var shadows: shadow.Shadows = try .init(handle, spirv, if (settings.pixel_lighting) settings.shadows else .off);
        errdefer shadows.deinit(handle);

        const sampler = try textureSampler(handle, settings.filter, c.SDL_GPU_SAMPLERADDRESSMODE_REPEAT);
        errdefer c.SDL_ReleaseGPUSampler(handle, sampler);
        const edge_sampler = try textureSampler(handle, settings.filter, c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE);
        errdefer c.SDL_ReleaseGPUSampler(handle, edge_sampler);

        // 16-bit colour where the GPU draws into it; elsewhere the shader's dither alone.
        const sixteen = settings.sixteen_bit and c.SDL_GPUTextureSupportsFormat(
            handle,
            c.SDL_GPU_TEXTUREFORMAT_B5G6R5_UNORM,
            c.SDL_GPU_TEXTURETYPE_2D,
            c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        );
        const finish_format: c.SDL_GPUTextureFormat = if (sixteen) c.SDL_GPU_TEXTUREFORMAT_B5G6R5_UNORM else c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        const linear = settings.linear_light and !settings.sixteen_bit;
        const colour_format = if (linear) floatFormat(handle) else finish_format;
        const depth_format: c.SDL_GPUTextureFormat = if (settings.sixteen_bit)
            c.SDL_GPU_TEXTUREFORMAT_D16_UNORM
        else if (c.SDL_GPUTextureSupportsFormat(handle, c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT, c.SDL_GPU_TEXTURETYPE_2D, c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET))
            c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT
        else
            c.SDL_GPU_TEXTUREFORMAT_D24_UNORM;
        const samples = sampleCount(handle, colour_format, depth_format, settings.samples);
        if (!c.SDL_SetGPUSwapchainParameters(handle, window, c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, presentMode(handle, window, settings.vsync))) return fail("SDL_SetGPUSwapchainParameters");

        var screen_info = std.mem.zeroes(c.SDL_GPUSamplerCreateInfo);
        screen_info.min_filter = c.SDL_GPU_FILTER_LINEAR;
        screen_info.mag_filter = c.SDL_GPU_FILTER_LINEAR;
        screen_info.mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
        screen_info.address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        screen_info.address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        screen_info.address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        const screen_sampler = c.SDL_CreateGPUSampler(handle, &screen_info) orelse return fail("SDL_CreateGPUSampler");
        errdefer c.SDL_ReleaseGPUSampler(handle, screen_sampler);

        var gpu: Gpu = .{
            .gpa = gpa,
            .screen_sampler = screen_sampler,
            .handle = handle,
            .window = window,
            .spirv = spirv,
            .settings = settings,
            .samples = samples,
            .linear = linear,
            .colour_format = colour_format,
            .finish_format = finish_format,
            .texture_format = if (linear) c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM_SRGB else c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .depth_format = depth_format,
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .sampler = sampler,
            .edge_sampler = edge_sampler,
            .shadows = shadows,
        };
        gpu.blank = try gpu.place(&blank_levels, .{});
        gpu.no_maps = try gpu.arrayTexture(.{ .width = 1, .height = 1, .levels = 1 }, 1, map_format);
        gpu.no_reflections = try gpu.cubeTexture(1, 1, c.SDL_GPU_TEXTUREUSAGE_SAMPLER);
        gpu.reflection_sampler = try reflectionSampler(handle);
        if (settings.bloom or linear) try gpu.startScreen();
        gpu.prepare();
        return gpu;
    }

    /// The sample counts the frame can take, and how many samples a pixel each is.
    const sample_counts = [_]struct { u8, c.SDL_GPUSampleCount }{
        .{ 1, c.SDL_GPU_SAMPLECOUNT_1 },
        .{ 2, c.SDL_GPU_SAMPLECOUNT_2 },
        .{ 4, c.SDL_GPU_SAMPLECOUNT_4 },
        .{ 8, c.SDL_GPU_SAMPLECOUNT_8 },
    };

    /// The most samples a pixel up to `wanted` that the GPU draws into frames of `colour` and
    /// `depth` with.
    fn sampleCount(handle: *c.SDL_GPUDevice, colour: c.SDL_GPUTextureFormat, depth: c.SDL_GPUTextureFormat, wanted: u8) c.SDL_GPUSampleCount {
        var samples: c.SDL_GPUSampleCount = c.SDL_GPU_SAMPLECOUNT_1;
        for (sample_counts[1..]) |option| {
            if (option[0] <= wanted and
                c.SDL_GPUTextureSupportsSampleCount(handle, colour, option[1]) and
                c.SDL_GPUTextureSupportsSampleCount(handle, depth, option[1])) samples = option[1];
        }
        return samples;
    }

    /// The most samples a pixel the GPU draws the frame with.
    pub fn mostSamples(gpu: Gpu) u8 {
        const most = sampleCount(gpu.handle, gpu.colour_format, gpu.depth_format, std.math.maxInt(u8));
        for (sample_counts) |option| if (option[1] == most) return option[0];
        return 1;
    }

    /// How the frames go to the window: as the display shows each, with vsync; otherwise at once,
    /// or each replacing the last waiting, where the window offers either.
    fn presentMode(handle: *c.SDL_GPUDevice, window: *c.SDL_Window, vsync: bool) c.SDL_GPUPresentMode {
        if (vsync) return c.SDL_GPU_PRESENTMODE_VSYNC;
        if (c.SDL_WindowSupportsGPUPresentMode(handle, window, c.SDL_GPU_PRESENTMODE_IMMEDIATE)) return c.SDL_GPU_PRESENTMODE_IMMEDIATE;
        if (c.SDL_WindowSupportsGPUPresentMode(handle, window, c.SDL_GPU_PRESENTMODE_MAILBOX)) return c.SDL_GPU_PRESENTMODE_MAILBOX;
        return c.SDL_GPU_PRESENTMODE_VSYNC;
    }

    /// Waits for the display to show each frame, or not, from the next frame on.
    fn setVsync(gpu: *Gpu, vsync: bool) void {
        if (gpu.settings.vsync == vsync) return;
        gpu.settings.vsync = vsync;
        if (!c.SDL_SetGPUSwapchainParameters(gpu.handle, gpu.window, c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, presentMode(gpu.handle, gpu.window, vsync)))
            log.warn("vsync is left as it was: {s}", .{c.SDL_GetError()});
    }

    /// Draws the frame with `samples` a pixel from the next frame on, as many as the GPU offers up
    /// to it: the frame's targets are made again, and the pipelines, which the GPU compiles as the
    /// device starts (`prepare`).
    fn setSamples(gpu: *Gpu, samples: u8) void {
        gpu.settings.samples = samples;
        const count = sampleCount(gpu.handle, gpu.colour_format, gpu.depth_format, samples);
        if (count == gpu.samples) return;
        _ = c.SDL_WaitForGPUIdle(gpu.handle);
        gpu.releaseTargets();
        var pipelines = gpu.pipelines.valueIterator();
        while (pipelines.next()) |made| c.SDL_ReleaseGPUGraphicsPipeline(gpu.handle, made.*);
        gpu.pipelines.clearRetainingCapacity();
        gpu.samples = count;
        gpu.prepare();
    }

    /// What reads the textures, filtered as `filter` has them, `address` at their edges.
    fn textureSampler(handle: *c.SDL_GPUDevice, filter: Settings.Filter, address: c.SDL_GPUSamplerAddressMode) sdl.Error!*c.SDL_GPUSampler {
        const modern = filter != .original;
        var info = std.mem.zeroes(c.SDL_GPUSamplerCreateInfo);
        info.min_filter = c.SDL_GPU_FILTER_LINEAR;
        info.mag_filter = c.SDL_GPU_FILTER_LINEAR;
        info.mipmap_mode = if (modern) c.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR else c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
        info.address_mode_u = address;
        info.address_mode_v = address;
        info.address_mode_w = address;
        info.max_lod = 1000;
        info.enable_anisotropy = modern;
        info.max_anisotropy = if (modern) 16 else 1;
        return c.SDL_CreateGPUSampler(handle, &info) orelse fail("SDL_CreateGPUSampler");
    }

    /// Draws with `wanted` from the next frame on, as far as it can while it runs: but for 16-bit
    /// colour and linear light, which change the formats the device made as it started, and the
    /// frames' size, which the driver keeps. What it can't make is logged, and left as it was.
    pub fn apply(gpu: *Gpu, wanted: Settings) void {
        gpu.setVsync(wanted.vsync);
        gpu.setSamples(wanted.samples);
        gpu.settings.dither = wanted.dither;
        gpu.settings.cockpit_shadows = wanted.cockpit_shadows;
        gpu.settings.materials = wanted.materials;
        if (wanted.filter != gpu.settings.filter) gpu.setFilter(wanted.filter) catch |err| log.err("the texture filter is left as it was: {s}", .{@errorName(err)});
        if (wanted.bloom != gpu.settings.bloom) gpu.setBloom(wanted.bloom) catch |err| log.err("the bloom is left as it was: {s}", .{@errorName(err)});
        if (wanted.pixel_lighting != gpu.settings.pixel_lighting or wanted.shadows != gpu.settings.shadows) {
            gpu.setLighting(wanted.pixel_lighting, wanted.shadows) catch |err| log.err("the shadows are left out: {s}", .{@errorName(err)});
        }
    }

    fn setFilter(gpu: *Gpu, filter: Settings.Filter) sdl.Error!void {
        const sampler = try textureSampler(gpu.handle, filter, c.SDL_GPU_SAMPLERADDRESSMODE_REPEAT);
        errdefer c.SDL_ReleaseGPUSampler(gpu.handle, sampler);
        const edge_sampler = try textureSampler(gpu.handle, filter, c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE);
        _ = c.SDL_WaitForGPUIdle(gpu.handle);
        c.SDL_ReleaseGPUSampler(gpu.handle, gpu.sampler);
        c.SDL_ReleaseGPUSampler(gpu.handle, gpu.edge_sampler);
        gpu.sampler = sampler;
        gpu.edge_sampler = edge_sampler;
        gpu.settings.filter = filter;
    }

    /// The bloom on or off: its pipeline made or let go, and the frame's targets made again, with
    /// the bloom's or without.
    fn setBloom(gpu: *Gpu, on: bool) Error!void {
        _ = c.SDL_WaitForGPUIdle(gpu.handle);
        gpu.releaseTargets();
        gpu.settings.bloom = on;
        if (on) return gpu.startScreen();
        if (gpu.bloom_pipeline) |made| c.SDL_ReleaseGPUGraphicsPipeline(gpu.handle, made);
        gpu.bloom_pipeline = null;
    }

    /// Each pixel lit, or each vertex, and the shadows of `quality`, which take each pixel lit: their
    /// maps made again, the ones before let go first. Where the new can't be made, there are none.
    fn setLighting(gpu: *Gpu, pixel_lighting: bool, quality: Settings.Shadows) Error!void {
        gpu.settings.pixel_lighting = pixel_lighting;
        gpu.settings.shadows = quality;
        const drawn: Settings.Shadows = if (pixel_lighting) quality else .off;
        if (drawn == gpu.shadows.quality) return;
        _ = c.SDL_WaitForGPUIdle(gpu.handle);
        const none: shadow.Shadows = try .init(gpu.handle, gpu.spirv, .off);
        gpu.shadows.deinit(gpu.handle);
        gpu.shadows = none;
        if (drawn == .off) return;
        const made: shadow.Shadows = try .init(gpu.handle, gpu.spirv, drawn);
        gpu.shadows.deinit(gpu.handle);
        gpu.shadows = made;
    }

    /// Makes every pipeline the frame can draw with (`prepared`), rather than each the first time
    /// it is drawn: the system compiles a pipeline's shaders for its states, which can take a
    /// quarter of a second the first time, and would hold up the frame in which an effect first
    /// shows. One the system refuses is tried again, and the failure logged, as it is drawn.
    fn prepare(gpu: *Gpu) void {
        for (prepared) |key| _ = gpu.pipeline(key) catch continue;
    }

    /// Floats for a frame that keeps what is stacked past white: 32 bits a pixel where the GPU
    /// draws into them, 64 otherwise.
    fn floatFormat(handle: *c.SDL_GPUDevice) c.SDL_GPUTextureFormat {
        const usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER;
        const packed_floats = c.SDL_GPUTextureSupportsFormat(handle, c.SDL_GPU_TEXTUREFORMAT_R11G11B10_UFLOAT, c.SDL_GPU_TEXTURETYPE_2D, usage);
        return if (packed_floats) c.SDL_GPU_TEXTUREFORMAT_R11G11B10_UFLOAT else c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT;
    }

    pub fn deinit(gpu: *Gpu) void {
        _ = c.SDL_WaitForGPUIdle(gpu.handle);
        var pipelines = gpu.pipelines.valueIterator();
        while (pipelines.next()) |made| c.SDL_ReleaseGPUGraphicsPipeline(gpu.handle, made.*);
        gpu.pipelines.deinit(gpu.gpa);
        for (gpu.arrays.items) |array| {
            for ([_]?*c.SDL_GPUTexture{ array.texture, array.normals, array.materials }) |texture| {
                if (texture) |made| c.SDL_ReleaseGPUTexture(gpu.handle, made);
            }
        }
        c.SDL_ReleaseGPUTexture(gpu.handle, gpu.no_maps);
        if (gpu.reflections) |cube| c.SDL_ReleaseGPUTexture(gpu.handle, cube);
        c.SDL_ReleaseGPUTexture(gpu.handle, gpu.no_reflections);
        c.SDL_ReleaseGPUSampler(gpu.handle, gpu.reflection_sampler);
        gpu.arrays.deinit(gpu.gpa);
        gpu.uploads.deinit(gpu.gpa);
        gpu.vertices.deinit(gpu.gpa);
        gpu.indices.deinit(gpu.gpa);
        gpu.runs.deinit(gpu.gpa);
        Geometry.release(&gpu.geometry, gpu.handle);
        gpu.shadows.deinit(gpu.handle);
        gpu.releaseTargets();
        if (gpu.bloom_pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(gpu.handle, p);
        if (gpu.finish_pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(gpu.handle, p);
        if (gpu.gamma_pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(gpu.handle, p);
        if (gpu.screen_vertex_shader) |shader_| c.SDL_ReleaseGPUShader(gpu.handle, shader_);
        if (gpu.screen_fragment_shader) |shader_| c.SDL_ReleaseGPUShader(gpu.handle, shader_);
        c.SDL_ReleaseGPUSampler(gpu.handle, gpu.screen_sampler);
        c.SDL_ReleaseGPUSampler(gpu.handle, gpu.sampler);
        c.SDL_ReleaseGPUSampler(gpu.handle, gpu.edge_sampler);
        c.SDL_ReleaseGPUShader(gpu.handle, gpu.vertex_shader);
        c.SDL_ReleaseGPUShader(gpu.handle, gpu.fragment_shader);
    }

    /// The shaders and pipelines the screen's passes draw with: a triangle over the whole screen,
    /// so there is nothing to bind but what it reads.
    fn startScreen(gpu: *Gpu) Error!void {
        try gpu.screenShaders();
        if (gpu.settings.bloom and gpu.bloom_pipeline == null) gpu.bloom_pipeline = try gpu.screenPipeline(gpu.colour_format);
        if (gpu.finish_pipeline == null) gpu.finish_pipeline = try gpu.screenPipeline(gpu.finish_format);
    }

    /// The screen's passes' shaders, made the first time they are needed.
    fn screenShaders(gpu: *Gpu) sdl.Error!void {
        const spirv = gpu.spirv;
        if (gpu.screen_vertex_shader == null) gpu.screen_vertex_shader = try shader(gpu.handle, spirv, c.SDL_GPU_SHADERSTAGE_VERTEX, if (spirv) shaders.bloom_vertex_spirv else shaders.bloom_vertex_msl, 0, 1);
        if (gpu.screen_fragment_shader == null) gpu.screen_fragment_shader = try shader(gpu.handle, spirv, c.SDL_GPU_SHADERSTAGE_FRAGMENT, if (spirv) shaders.bloom_fragment_spirv else shaders.bloom_fragment_msl, 2, 1);
    }

    /// The gamma ramp's pass into the swapchain, whose format is `format`: made the first time it
    /// is needed, and again where the format has changed.
    fn gammaPipeline(gpu: *Gpu, format: c.SDL_GPUTextureFormat) sdl.Error!*c.SDL_GPUGraphicsPipeline {
        if (gpu.gamma_pipeline) |made| {
            if (gpu.gamma_format == format) return made;
            c.SDL_ReleaseGPUGraphicsPipeline(gpu.handle, made);
            gpu.gamma_pipeline = null;
        }
        try gpu.screenShaders();
        const made = try gpu.screenPipeline(format);
        gpu.gamma_pipeline = made;
        gpu.gamma_format = format;
        return made;
    }

    fn screenPipeline(gpu: *Gpu, format: c.SDL_GPUTextureFormat) sdl.Error!*c.SDL_GPUGraphicsPipeline {
        var colour = std.mem.zeroes(c.SDL_GPUColorTargetDescription);
        colour.format = format;
        var info = std.mem.zeroes(c.SDL_GPUGraphicsPipelineCreateInfo);
        info.vertex_shader = gpu.screen_vertex_shader;
        info.fragment_shader = gpu.screen_fragment_shader;
        info.primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
        info.rasterizer_state.fill_mode = c.SDL_GPU_FILLMODE_FILL;
        info.rasterizer_state.cull_mode = c.SDL_GPU_CULLMODE_NONE;
        info.multisample_state.sample_count = c.SDL_GPU_SAMPLECOUNT_1;
        info.target_info = .{ .color_target_descriptions = &colour, .num_color_targets = 1 };
        return c.SDL_CreateGPUGraphicsPipeline(gpu.handle, &info) orelse fail("SDL_CreateGPUGraphicsPipeline");
    }

    /// Which of the screen's passes the shader runs, as `frame.settings.x` picks it
    /// (`shaders/bloom.glsl`).
    const ScreenPass = enum(u2) {
        /// Takes the frame's bright parts, past a threshold.
        bright,
        /// Blurs along one axis.
        blur,
        /// Adds the bloom back and finishes the frame.
        finish,
        /// Puts the finished frame on the screen through the gamma ramp.
        gamma,
    };

    /// What the screen's passes read, in std140's layout (`shaders/bloom.glsl`).
    const ScreenUniforms = extern struct {
        /// Which pass, a texel along a blur's axis, and the threshold or the bloom's strength.
        settings: [4]f32,
        /// 1 for a frame of floats, whose highlights are eased before they bloom and as the last
        /// pass finishes it; and 1 for the last pass to dither.
        finish: [4]f32 = @splat(0),

        /// The uniforms of `pass`, stepping `texel` along a blur's axis, with the threshold or the
        /// bloom's strength `level`, and `finishing` as `finish`.
        fn of(pass: ScreenPass, texel: [2]f32, level: f32, finishing: [4]f32) ScreenUniforms {
            return .{ .settings = .{ @floatFromInt(@intFromEnum(pass)), texel[0], texel[1], level }, .finish = finishing };
        }

        comptime {
            std.debug.assert(@offsetOf(ScreenUniforms, "finish") == 16);
            std.debug.assert(@sizeOf(ScreenUniforms) == 32);
        }
    };

    /// One of the screen's passes: draws the screen-wide triangle into `target`, reading `source`
    /// and, for the last pass, the frame itself.
    fn screenPass(
        gpu: *Gpu,
        commands: *c.SDL_GPUCommandBuffer,
        into: *c.SDL_GPUTexture,
        pipeline_: *c.SDL_GPUGraphicsPipeline,
        source: *c.SDL_GPUTexture,
        frame_image: *c.SDL_GPUTexture,
        uniforms: ScreenUniforms,
    ) sdl.Error!void {
        var colour = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
        colour.texture = into;
        colour.load_op = c.SDL_GPU_LOADOP_DONT_CARE;
        colour.store_op = c.SDL_GPU_STOREOP_STORE;
        const pass = c.SDL_BeginGPURenderPass(commands, &colour, 1, null) orelse return fail("SDL_BeginGPURenderPass");
        defer c.SDL_EndGPURenderPass(pass);
        c.SDL_BindGPUGraphicsPipeline(pass, pipeline_);
        const bindings = [_]c.SDL_GPUTextureSamplerBinding{
            .{ .texture = source, .sampler = gpu.screen_sampler },
            .{ .texture = frame_image, .sampler = gpu.screen_sampler },
        };
        c.SDL_BindGPUFragmentSamplers(pass, 0, &bindings, bindings.len);
        c.SDL_PushGPUFragmentUniformData(commands, 0, &uniforms, @sizeOf(ScreenUniforms));
        c.SDL_DrawGPUPrimitives(pass, 3, 1, 0, 0);
    }

    pub fn interface(gpu: *Gpu) device.Device {
        return .{ .ptr = gpu, .vtable = &vtable };
    }

    const vtable: device.Device.VTable = .{
        .begin = begin,
        .end = end,
        .draw = draw,
        .overlay = overlay,
        .lights = lights,
        .shadow_settings = shadowSettings,
        .shadows = takeShadows,
        .gamma = setGamma,
        .materials = materials,
        .reflections = reflectionsFace,
    };

    /// The gamma ramp, which the frame goes to the screen through (`present`).
    fn setGamma(ptr: *anyopaque, brightness: f32) void {
        from(ptr).brightness = brightness;
    }

    fn shadowSettings(ptr: *anyopaque) ?srshadow.Settings {
        const gpu = from(ptr);
        var settings = gpu.shadows.quality.settings() orelse return null;
        settings.cockpit = gpu.settings.cockpit_shadows;
        return settings;
    }

    fn takeShadows(ptr: *anyopaque, frame: *const srshadow.Frame) void {
        from(ptr).shadows.take(frame);
    }

    /// Takes the frame's lights, as many as the shader does, for it to light each pixel with,
    /// unless the settings say otherwise.
    fn lights(ptr: *anyopaque, list: []const device.Light) usize {
        const gpu = from(ptr);
        gpu.lighting.count[0] = 0;
        if (!gpu.settings.pixel_lighting) return 0;
        return gpu.lighting.take(list, gpu.linear);
    }

    /// What follows is drawn over the finished frame rather than into it, so that the bloom, which
    /// the game has none of, does not reach it.
    fn overlay(ptr: *anyopaque) void {
        const gpu = from(ptr);
        gpu.overlay_from = @intCast(gpu.runs.items.len);
    }

    fn from(ptr: *anyopaque) *Gpu {
        return @ptrCast(@alignCast(ptr));
    }

    /// The frame's size in pixels, as the settings have it (`Settings.size`).
    pub fn frameSize(gpu: Gpu) [2]u32 {
        return gpu.settings.size.of(gpu.windowSize());
    }

    /// The window's size in pixels, at the display's own density.
    pub fn windowSize(gpu: Gpu) [2]u32 {
        var width: c_int = 0;
        var height: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(gpu.window, &width, &height);
        return .{ @intCast(@max(width, 1)), @intCast(@max(height, 1)) };
    }

    fn begin(ptr: *anyopaque) void {
        const gpu = from(ptr);
        gpu.vertices.clearRetainingCapacity();
        gpu.indices.clearRetainingCapacity();
        gpu.runs.clearRetainingCapacity();
        gpu.overlay_from = null;
        gpu.failed = false;
        gpu.face = null;
        gpu.reflected = false;
        gpu.shadows.clear();
    }

    fn draw(ptr: *anyopaque, state: device.State, primitive: device.Primitive, vertices: []const device.Vertex, indices: ?[]const u16) void {
        const gpu = from(ptr);
        gpu.record(state, primitive, vertices, indices) catch |err| {
            if (!gpu.failed) log.err("the frame is not shown: {s}", .{@errorName(err)});
            gpu.failed = true;
        };
    }

    /// Adds a draw to the frame: its vertices, with their texture's layer, and its primitives as a
    /// list, run on from the last draw where the pipeline and the array allow.
    fn record(gpu: *Gpu, state: device.State, primitive: device.Primitive, vertices: []const device.Vertex, indices: ?[]const u16) Error!void {
        const slot: ?Slot = if (state.texture) |image| try gpu.slotOf(image) else null;
        const shading: Shading = .of(state, gpu.shadesMaterials());
        const base: u32 = @intCast(gpu.vertices.items.len);
        try gpu.vertices.ensureUnusedCapacity(gpu.gpa, vertices.len);
        for (vertices) |v| gpu.vertices.appendAssumeCapacity(.{
            .position = .{ v.x, v.y, v.z, v.rhw },
            .diffuse = v.diffuse,
            .uv = .{ v.u, v.v },
            .layer = if (slot) |s| s.layer else -1,
            .view = v.view,
            .normal = v.normal,
            .light_mask = v.light_mask,
            .shading = shading,
        });
        const first: u32 = @intCast(gpu.indices.items.len);
        try appendList(gpu.gpa, &gpu.indices, primitive, base, vertices.len, indices);
        const count: u32 = @as(u32, @intCast(gpu.indices.items.len)) - first;
        if (count == 0) return;
        const run: Run = .{
            .key = .{
                .topology = topology(primitive),
                .depth = state.depth,
                .blend = state.blend,
                .into = if (gpu.face != null) .reflections else if (gpu.overlay_from == null) .scene else .finished,
            },
            .face = gpu.face,
            .array = if (slot) |s| s.array else null,
            .held = state.filter == .point,
            .first = first,
            .count = count,
        };
        if (gpu.runs.items.len > 0 and join(&gpu.runs.items[gpu.runs.items.len - 1], run)) return;
        try gpu.runs.append(gpu.gpa, run);
    }

    /// Where an image's texture lies, placing it the first time, and sending its pixels up again
    /// into the same layer when they have changed.
    fn slotOf(gpu: *Gpu, image: *srtexture.Image) Error!?Slot {
        if (image.levels.len == 0) return null;
        if (Slot.of(image.*)) |slot| {
            if (image.changed) {
                try gpu.uploads.append(gpu.gpa, .{ .levels = image.levels, .maps = image.maps, .slot = slot });
                image.changed = false;
            }
            return slot;
        }
        const slot = try gpu.place(image.levels, image.maps);
        image.device = @as(u32, @bitCast(slot));
        image.changed = false;
        return slot;
    }

    /// Gives a texture a layer in an array of its shape with room, or in a new one, to go up to the
    /// GPU with the frame with its maps.
    fn place(gpu: *Gpu, levels: []const srtexture.Level, maps: srtexture.Image.Maps) Error!Slot {
        const shape: Shape = .{ .width = levels[0].width, .height = levels[0].height, .levels = @intCast(levels.len) };
        const index = for (gpu.arrays.items, 0..) |array, i| {
            if (std.meta.eql(array.shape, shape) and array.count < max_layers) break i;
        } else made: {
            const index = std.math.cast(u15, gpu.arrays.items.len) orelse return error.OutOfMemory;
            try gpu.arrays.ensureUnusedCapacity(gpu.gpa, 1);
            const capacity = firstLayers(shape);
            gpu.arrays.appendAssumeCapacity(.{ .shape = shape, .texture = try gpu.arrayTexture(shape, capacity, gpu.texture_format), .capacity = capacity, .count = 0 });
            break :made index;
        };
        try gpu.uploads.ensureUnusedCapacity(gpu.gpa, 1);
        const array = &gpu.arrays.items[index];
        const slot: Slot = .{ .array = @intCast(index), .layer = @intCast(array.count) };
        array.count += 1;
        gpu.uploads.appendAssumeCapacity(.{ .levels = levels, .maps = maps, .slot = slot });
        if (maps.orm != null) gpu.has_materials = true;
        return slot;
    }

    /// Whether it shades material maps: with `Settings.materials`, where each pixel is lit.
    fn shadesMaterials(gpu: *const Gpu) bool {
        return gpu.settings.materials and gpu.settings.pixel_lighting;
    }

    fn materials(ptr: *anyopaque) bool {
        return from(ptr).shadesMaterials();
    }

    /// Sends the draws that follow to the face `face` of the reflections' cube, or back to the
    /// frame. The reflections are drawn where materials are shaded in linear light, once a texture
    /// with a material map has gone up: in a frame of floats, as the scene is, so that what a
    /// material reflects is lit as the frame is.
    fn reflectionsFace(ptr: *anyopaque, face: ?u3) ?u32 {
        const gpu = from(ptr);
        gpu.face = null;
        const chosen = face orelse return null;
        if (!gpu.shadesMaterials() or !gpu.linear or !gpu.has_materials or gpu.reflections_failed) return null;
        if (gpu.reflections == null) {
            gpu.reflections = gpu.cubeTexture(reflection_side, reflection_levels, c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER) catch |err| {
                log.err("the reflections are left out: {s}", .{@errorName(err)});
                gpu.reflections_failed = true;
                return null;
            };
        }
        gpu.face = chosen;
        gpu.reflected = true;
        return reflection_side;
    }

    /// A cube texture of the scene's format, `side` pixels square, of `levels` mipmap levels.
    fn cubeTexture(gpu: *Gpu, side: u32, levels: u32, usage: c.SDL_GPUTextureUsageFlags) sdl.Error!*c.SDL_GPUTexture {
        var info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
        info.type = c.SDL_GPU_TEXTURETYPE_CUBE;
        info.format = gpu.colour_format;
        info.usage = usage;
        info.width = side;
        info.height = side;
        info.layer_count_or_depth = cube_face_count;
        info.num_levels = levels;
        return c.SDL_CreateGPUTexture(gpu.handle, &info) orelse fail("SDL_CreateGPUTexture");
    }

    /// Draws the reflections' faces from their runs, and makes the cube's mipmaps, the blur a rough
    /// surface reflects.
    fn drawReflections(gpu: *Gpu, commands: *c.SDL_GPUCommandBuffer) Error!void {
        const cube = gpu.reflections orelse return;
        for (0..cube_face_count) |face| {
            var colour = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
            colour.texture = cube;
            colour.layer_or_depth_plane = @intCast(face);
            colour.clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
            colour.load_op = c.SDL_GPU_LOADOP_CLEAR;
            colour.store_op = c.SDL_GPU_STOREOP_STORE;
            const pass = c.SDL_BeginGPURenderPass(commands, &colour, 1, null) orelse return fail("SDL_BeginGPURenderPass");
            gpu.drawRuns(commands, pass, .{ reflection_side, reflection_side }, gpu.runs.items, .reflections, @intCast(face));
            c.SDL_EndGPURenderPass(pass);
        }
        c.SDL_GenerateMipmapsForGPUTexture(commands, cube);
    }

    fn arrayTexture(gpu: *Gpu, shape: Shape, layers: u32, format: c.SDL_GPUTextureFormat) sdl.Error!*c.SDL_GPUTexture {
        var info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
        info.type = c.SDL_GPU_TEXTURETYPE_2D_ARRAY;
        info.format = format;
        info.usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER;
        info.width = shape.width;
        info.height = shape.height;
        info.layer_count_or_depth = layers;
        info.num_levels = shape.levels;
        return c.SDL_CreateGPUTexture(gpu.handle, &info) orelse fail("SDL_CreateGPUTexture");
    }

    fn end(ptr: *anyopaque) void {
        const gpu = from(ptr);
        gpu.submit() catch |err| log.err("the frame is not shown: {s}", .{@errorName(err)});
    }

    /// Draws the recorded frame and shows it: the new textures and the frame's vertices go up, the
    /// runs are drawn in order, and the frame goes to the window.
    fn submit(gpu: *Gpu) Error!void {
        if (gpu.failed) return;
        const size = gpu.frameSize();
        try gpu.ensureTargets(size);
        const targets = gpu.targets.?;
        const commands = c.SDL_AcquireGPUCommandBuffer(gpu.handle) orelse return fail("SDL_AcquireGPUCommandBuffer");
        gpu.encode(commands, size, targets) catch |err| {
            _ = c.SDL_CancelGPUCommandBuffer(commands);
            return err;
        };

        // The swapchain's texture, once the display has one free: with vsync, what paces the frames.
        var swapchain: ?*c.SDL_GPUTexture = null;
        var width: u32 = 0;
        var height: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(commands, gpu.window, &swapchain, &width, &height)) {
            _ = c.SDL_CancelGPUCommandBuffer(commands);
            return fail("SDL_WaitAndAcquireGPUSwapchainTexture");
        }
        if (swapchain) |texture| {
            gpu.present(commands, targets, texture, width, height) catch |err| {
                _ = c.SDL_CancelGPUCommandBuffer(commands);
                return err;
            };
        }
        if (!c.SDL_SubmitGPUCommandBuffer(commands)) return fail("SDL_SubmitGPUCommandBuffer");
    }

    /// Puts the finished frame on the screen, with the display drawn over it: through the gamma
    /// ramp, where the brightness is other than 1, as the display's ramp showed the game's whole
    /// screen.
    fn present(gpu: *Gpu, commands: *c.SDL_GPUCommandBuffer, targets: Targets, swapchain: *c.SDL_GPUTexture, width: u32, height: u32) Error!void {
        try gpu.finish(commands, targets);
        try gpu.drawOverlay(commands, targets);
        if (gpu.brightness != 1 and !gpu.gamma_failed) {
            const format = c.SDL_GetGPUSwapchainTextureFormat(gpu.handle, gpu.window);
            if (gpu.gammaPipeline(format)) |pipeline_| {
                const finished = targets.finished();
                return gpu.screenPass(commands, swapchain, pipeline_, finished, finished, .of(.gamma, .{ 0, 0 }, gpu.brightness, @splat(0)));
            } else |err| {
                log.err("the brightness is left out: {s}", .{@errorName(err)});
                gpu.gamma_failed = true;
            }
        }
        var blit = std.mem.zeroes(c.SDL_GPUBlitInfo);
        blit.source = .{ .texture = targets.finished(), .w = targets.width, .h = targets.height };
        blit.destination = .{ .texture = swapchain, .w = width, .h = height };
        blit.load_op = c.SDL_GPU_LOADOP_DONT_CARE;
        blit.filter = c.SDL_GPU_FILTER_LINEAR;
        c.SDL_BlitGPUTexture(commands, &blit);
    }

    /// Finishes the frame into `composed`, where it has one: its bright parts taken into a
    /// half-size target, blurred along each axis in turn and added back, where it blooms; and, for
    /// a frame of floats, what stands past white eased into it, and dithered.
    fn finish(gpu: *Gpu, commands: *c.SDL_GPUCommandBuffer, targets: Targets) sdl.Error!void {
        const composed = targets.composed orelse return;
        const last = gpu.finish_pipeline orelse return;
        const frame_image = targets.frame();
        const finishing = [4]f32{ @floatFromInt(@intFromBool(gpu.linear)), @floatFromInt(@intFromBool(gpu.linear and gpu.settings.dither)), 0, 0 };
        const bloom = targets.bloom orelse
            return gpu.screenPass(commands, composed, last, frame_image, frame_image, .of(.finish, .{ 0, 0 }, 0, finishing));
        const blur = gpu.bloom_pipeline.?;
        const across = 1 / @as(f32, @floatFromInt(targets.bloom_width));
        const down = 1 / @as(f32, @floatFromInt(targets.bloom_height));
        const unfinished: [4]f32 = @splat(0);
        try gpu.screenPass(commands, bloom[0], blur, frame_image, frame_image, .of(.bright, .{ 0, 0 }, bloom_threshold, finishing));
        try gpu.screenPass(commands, bloom[1], blur, bloom[0], frame_image, .of(.blur, .{ across, 0 }, 0, unfinished));
        try gpu.screenPass(commands, bloom[0], blur, bloom[1], frame_image, .of(.blur, .{ 0, down }, 0, unfinished));
        try gpu.screenPass(commands, composed, last, bloom[0], frame_image, .of(.finish, .{ 0, 0 }, bloom_strength, finishing));
    }

    /// The frame's copy pass, the shadows' passes and the frame's render pass.
    fn encode(gpu: *Gpu, commands: *c.SDL_GPUCommandBuffer, size: [2]u32, targets: Targets) Error!void {
        const copy = c.SDL_BeginGPUCopyPass(commands) orelse return fail("SDL_BeginGPUCopyPass");
        const copied = gpu.upload(copy);
        c.SDL_EndGPUCopyPass(copy);
        try copied;
        try gpu.shadows.draw(commands);

        // Every pipeline the frame needs, before the passes.
        for (gpu.runs.items) |run| _ = try gpu.pipeline(run.key);
        if (gpu.reflected) try gpu.drawReflections(commands);

        var colour = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
        colour.texture = targets.colour;
        colour.clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
        colour.load_op = c.SDL_GPU_LOADOP_CLEAR;
        if (targets.resolved) |resolved| {
            colour.store_op = c.SDL_GPU_STOREOP_RESOLVE;
            colour.resolve_texture = resolved;
        } else {
            colour.store_op = c.SDL_GPU_STOREOP_STORE;
        }
        // Depth is reversed, nearer greater, and clears to 0, as the device's `begin` has it.
        var depth = std.mem.zeroes(c.SDL_GPUDepthStencilTargetInfo);
        depth.texture = targets.depth;
        depth.clear_depth = 0;
        depth.load_op = c.SDL_GPU_LOADOP_CLEAR;
        depth.store_op = c.SDL_GPU_STOREOP_DONT_CARE;
        depth.stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE;
        depth.stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE;
        const pass = c.SDL_BeginGPURenderPass(commands, &colour, 1, &depth) orelse return fail("SDL_BeginGPURenderPass");
        defer c.SDL_EndGPURenderPass(pass);
        gpu.drawRuns(commands, pass, size, gpu.runs.items[0 .. gpu.overlay_from orelse gpu.runs.items.len], .scene, null);
    }

    /// Draws those of `runs` that go to `face`, a face of the reflections' cube or the frame for
    /// null, in `pass`, into a target `size` pixels across and down: each with its pipeline and its
    /// texture array, the shadows' maps, the array's maps and the reflections beside it.
    fn drawRuns(gpu: *Gpu, commands: *c.SDL_GPUCommandBuffer, pass: *c.SDL_GPURenderPass, size: [2]u32, runs: []const Run, into: Into, face: ?u3) void {
        const target_size = [4]f32{ @floatFromInt(size[0]), @floatFromInt(size[1]), 0, 0 };
        c.SDL_PushGPUVertexUniformData(commands, 0, &target_size, @sizeOf(@TypeOf(target_size)));
        // A frame of floats is dithered once it is finished; the reflections, in floats too, never
        // are.
        const floats = gpu.linear and into != .finished;
        // The scene's pixels read the reflections drawn this frame: their levels, or 0 for none.
        const reflecting = into == .scene and gpu.reflected;
        const frame_settings = [8]f32{
            @floatFromInt(@intFromBool(!floats and gpu.settings.sixteen_bit)),
            @floatFromInt(@intFromBool(gpu.settings.filter == .crisp)),
            @floatFromInt(@intFromBool(!floats and gpu.settings.dither)),
            @floatFromInt(@intFromBool(gpu.linear)),
            if (reflecting) reflection_levels else 0,
            0,
            0,
            0,
        };
        c.SDL_PushGPUFragmentUniformData(commands, 0, &frame_settings, @sizeOf(@TypeOf(frame_settings)));
        c.SDL_PushGPUFragmentUniformData(commands, 1, &gpu.lighting, @sizeOf(Lighting));
        c.SDL_PushGPUFragmentUniformData(commands, 2, &gpu.shadows.uniforms, @sizeOf(shadow.Uniforms));
        const geometry = gpu.geometry orelse return;
        geometry.bind(pass);
        // The scene's textures wrap; the images drawn over the finished frame are held at their
        // edges.
        const sampler = switch (into) {
            .scene, .reflections => gpu.sampler,
            .finished => gpu.edge_sampler,
        };
        const around = if (reflecting) gpu.reflections orelse gpu.no_reflections else gpu.no_reflections;
        for (runs) |run| {
            if (run.face != face) continue;
            c.SDL_BindGPUGraphicsPipeline(pass, gpu.pipelines.get(run.key).?);
            const array = gpu.arrays.items[run.array orelse gpu.blank.array];
            const read = if (run.held) gpu.edge_sampler else sampler;
            const bindings = [fragment_samplers]c.SDL_GPUTextureSamplerBinding{
                .{ .texture = array.texture, .sampler = read },
                gpu.shadows.binding(),
                .{ .texture = array.normals orelse gpu.no_maps, .sampler = read },
                .{ .texture = array.materials orelse gpu.no_maps, .sampler = read },
                .{ .texture = around, .sampler = gpu.reflection_sampler },
            };
            c.SDL_BindGPUFragmentSamplers(pass, 0, &bindings, bindings.len);
            c.SDL_DrawGPUIndexedPrimitives(pass, run.count, 1, run.first, 0, 0);
        }
    }

    /// Draws what was recorded over the finished frame, after the bloom has been added to it, so
    /// that the display the game drew over its own frame is not bloomed with the scene.
    fn drawOverlay(gpu: *Gpu, commands: *c.SDL_GPUCommandBuffer, targets: Targets) Error!void {
        const first = gpu.overlay_from orelse return;
        const runs = gpu.runs.items[@min(first, gpu.runs.items.len)..];
        if (runs.len == 0) return;
        for (runs) |run| _ = try gpu.pipeline(run.key);

        var colour = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
        colour.texture = targets.finished();
        colour.load_op = c.SDL_GPU_LOADOP_LOAD;
        colour.store_op = c.SDL_GPU_STOREOP_STORE;
        const pass = c.SDL_BeginGPURenderPass(commands, &colour, 1, null) orelse return fail("SDL_BeginGPURenderPass");
        defer c.SDL_EndGPURenderPass(pass);
        gpu.drawRuns(commands, pass, .{ targets.width, targets.height }, runs, .finished, null);
    }

    /// Sends the frame's new textures, its vertices and indices, and the shadows' casters to the
    /// GPU.
    fn upload(gpu: *Gpu, copy: *c.SDL_GPUCopyPass) Error!void {
        try gpu.uploadTextures(copy);
        try Geometry.upload(&gpu.geometry, gpu.handle, copy, std.mem.sliceAsBytes(gpu.vertices.items), std.mem.sliceAsBytes(gpu.indices.items));
        try gpu.shadows.upload(gpu.handle, copy);
    }

    /// Puts the textures placed this frame in their layers, every level, with their maps, first
    /// making larger any array that has run out of layers, and making the arrays of maps the first
    /// maps of an array need.
    fn uploadTextures(gpu: *Gpu, copy: *c.SDL_GPUCopyPass) Error!void {
        if (gpu.uploads.items.len == 0) return;
        defer gpu.uploads.clearRetainingCapacity();
        for (gpu.arrays.items) |*array| {
            if (array.count <= array.capacity) continue;
            const capacity = @min(std.math.ceilPowerOfTwoAssert(u32, array.count), max_layers);
            array.texture = try gpu.grown(copy, array.*, array.texture, capacity, gpu.texture_format);
            if (array.normals) |texture| array.normals = try gpu.grown(copy, array.*, texture, capacity, map_format);
            if (array.materials) |texture| array.materials = try gpu.grown(copy, array.*, texture, capacity, map_format);
            array.capacity = capacity;
        }
        var bytes: usize = 0;
        for (gpu.uploads.items) |item| {
            const array = &gpu.arrays.items[item.slot.array];
            if (item.maps.normal != null and array.normals == null) array.normals = try gpu.arrayTexture(array.shape, array.capacity, map_format);
            if (item.maps.orm != null and array.materials == null) array.materials = try gpu.arrayTexture(array.shape, array.capacity, map_format);
            for ([_]?[]const srtexture.Level{ item.levels, item.maps.normal, item.maps.orm }) |each| {
                for (each orelse &.{}) |level| bytes += level.rgba.len;
            }
        }
        const size = std.math.cast(u32, bytes) orelse return error.OutOfMemory;
        const transfer = c.SDL_CreateGPUTransferBuffer(gpu.handle, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = size }) orelse return fail("SDL_CreateGPUTransferBuffer");
        defer c.SDL_ReleaseGPUTransferBuffer(gpu.handle, transfer);
        const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(gpu.handle, transfer, false) orelse return fail("SDL_MapGPUTransferBuffer"));
        var at: u32 = 0;
        for (gpu.uploads.items) |item| {
            const array = gpu.arrays.items[item.slot.array];
            uploadLevels(copy, transfer, mapped, &at, array.texture, item.slot.layer, item.levels);
            if (item.maps.normal) |levels| if (array.normals) |texture| uploadLevels(copy, transfer, mapped, &at, texture, item.slot.layer, levels);
            if (item.maps.orm) |levels| if (array.materials) |texture| uploadLevels(copy, transfer, mapped, &at, texture, item.slot.layer, levels);
        }
        c.SDL_UnmapGPUTransferBuffer(gpu.handle, transfer);
    }

    /// `texture`, an array of `array`'s shape and layers, made `capacity` layers long: a new one,
    /// its layers copied over, the old let go.
    fn grown(gpu: *Gpu, copy: *c.SDL_GPUCopyPass, array: Array, texture: *c.SDL_GPUTexture, capacity: u32, format: c.SDL_GPUTextureFormat) sdl.Error!*c.SDL_GPUTexture {
        const larger = try gpu.arrayTexture(array.shape, capacity, format);
        for (0..array.capacity) |layer| {
            for (0..array.shape.levels) |level| {
                c.SDL_CopyGPUTextureToTexture(
                    copy,
                    &.{ .texture = texture, .mip_level = @intCast(level), .layer = @intCast(layer) },
                    &.{ .texture = larger, .mip_level = @intCast(level), .layer = @intCast(layer) },
                    @max(array.shape.width >> @intCast(level), 1),
                    @max(array.shape.height >> @intCast(level), 1),
                    1,
                    false,
                );
            }
        }
        c.SDL_ReleaseGPUTexture(gpu.handle, texture);
        return larger;
    }

    /// The frame's colour and depth targets for `size`, made again when it changes.
    fn ensureTargets(gpu: *Gpu, size: [2]u32) sdl.Error!void {
        if (gpu.targets) |targets| {
            if (targets.width == size[0] and targets.height == size[1]) return;
            gpu.releaseTargets();
        }
        const one = c.SDL_GPU_SAMPLECOUNT_1;
        const many = gpu.samples != one;
        const finished = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER;
        const colour = try gpu.target(size, gpu.colour_format, if (many) c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET else finished, gpu.samples);
        errdefer c.SDL_ReleaseGPUTexture(gpu.handle, colour);
        const resolved = if (many) try gpu.target(size, gpu.colour_format, finished, one) else null;
        errdefer if (resolved) |r| c.SDL_ReleaseGPUTexture(gpu.handle, r);
        const depth = try gpu.target(size, gpu.depth_format, c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET, gpu.samples);
        errdefer c.SDL_ReleaseGPUTexture(gpu.handle, depth);
        const half = [2]u32{ @max(size[0] / 2, 1), @max(size[1] / 2, 1) };
        var bloom: ?[2]*c.SDL_GPUTexture = null;
        errdefer if (bloom) |made| for (made) |texture| c.SDL_ReleaseGPUTexture(gpu.handle, texture);
        if (gpu.bloom_pipeline != null) {
            const first = try gpu.target(half, gpu.colour_format, finished, one);
            errdefer c.SDL_ReleaseGPUTexture(gpu.handle, first);
            bloom = .{ first, try gpu.target(half, gpu.colour_format, finished, one) };
        }
        const composed = if (gpu.finish_pipeline != null) try gpu.target(size, gpu.finish_format, finished, one) else null;
        gpu.targets = .{
            .width = size[0],
            .height = size[1],
            .colour = colour,
            .resolved = resolved,
            .depth = depth,
            .bloom = bloom,
            .bloom_width = half[0],
            .bloom_height = half[1],
            .composed = composed,
        };
    }

    fn target(gpu: *Gpu, size: [2]u32, format: c.SDL_GPUTextureFormat, usage: c.SDL_GPUTextureUsageFlags, samples: c.SDL_GPUSampleCount) sdl.Error!*c.SDL_GPUTexture {
        var info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
        info.type = c.SDL_GPU_TEXTURETYPE_2D;
        info.format = format;
        info.usage = usage;
        info.width = size[0];
        info.height = size[1];
        info.layer_count_or_depth = 1;
        info.num_levels = 1;
        info.sample_count = samples;
        return c.SDL_CreateGPUTexture(gpu.handle, &info) orelse fail("SDL_CreateGPUTexture");
    }

    fn releaseTargets(gpu: *Gpu) void {
        const targets = gpu.targets orelse return;
        c.SDL_ReleaseGPUTexture(gpu.handle, targets.colour);
        if (targets.resolved) |r| c.SDL_ReleaseGPUTexture(gpu.handle, r);
        c.SDL_ReleaseGPUTexture(gpu.handle, targets.depth);
        if (targets.bloom) |bloom| for (bloom) |texture| c.SDL_ReleaseGPUTexture(gpu.handle, texture);
        if (targets.composed) |texture| c.SDL_ReleaseGPUTexture(gpu.handle, texture);
        gpu.targets = null;
    }

    /// The pipeline for a topology and render states, made the first time it is needed: depth
    /// tested greater or equal, as the driver's reversed depth has it, and written as the state
    /// says; blended by the driver's factors, or not at all.
    fn pipeline(gpu: *Gpu, key: PipelineKey) Error!*c.SDL_GPUGraphicsPipeline {
        if (gpu.pipelines.get(key)) |found| return found;
        try gpu.pipelines.ensureUnusedCapacity(gpu.gpa, 1);
        const attributes = [_]c.SDL_GPUVertexAttribute{
            .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = @offsetOf(Vertex, "position") },
            .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM, .offset = @offsetOf(Vertex, "diffuse") },
            .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex, "uv") },
            .{ .location = 3, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_INT, .offset = @offsetOf(Vertex, "layer") },
            .{ .location = 4, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(Vertex, "view") },
            .{ .location = 5, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(Vertex, "normal") },
            .{ .location = 6, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_UINT, .offset = @offsetOf(Vertex, "light_mask") },
            .{ .location = 7, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_UINT, .offset = @offsetOf(Vertex, "shading") },
        };
        const buffer: c.SDL_GPUVertexBufferDescription = .{ .slot = 0, .pitch = @sizeOf(Vertex), .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX };
        var colour = std.mem.zeroes(c.SDL_GPUColorTargetDescription);
        // What is drawn over the finished frame goes into its format.
        colour.format = switch (key.into) {
            .scene, .reflections => gpu.colour_format,
            .finished => gpu.finish_format,
        };
        // The original's back buffer kept no alpha, and blending reads only the source's: alpha
        // stays as cleared, opaque.
        colour.blend_state.enable_color_write_mask = true;
        colour.blend_state.color_write_mask = c.SDL_GPU_COLORCOMPONENT_R | c.SDL_GPU_COLORCOMPONENT_G | c.SDL_GPU_COLORCOMPONENT_B;
        if (key.blend) |factors| {
            colour.blend_state.enable_blend = true;
            colour.blend_state.src_color_blendfactor = blendFactor(factors.source);
            colour.blend_state.dst_color_blendfactor = blendFactor(factors.destination);
            colour.blend_state.color_blend_op = c.SDL_GPU_BLENDOP_ADD;
            colour.blend_state.src_alpha_blendfactor = blendFactor(factors.source);
            colour.blend_state.dst_alpha_blendfactor = blendFactor(factors.destination);
            colour.blend_state.alpha_blend_op = c.SDL_GPU_BLENDOP_ADD;
        }
        var info = std.mem.zeroes(c.SDL_GPUGraphicsPipelineCreateInfo);
        info.vertex_shader = gpu.vertex_shader;
        info.fragment_shader = gpu.fragment_shader;
        info.vertex_input_state = .{ .vertex_buffer_descriptions = &buffer, .num_vertex_buffers = 1, .vertex_attributes = &attributes, .num_vertex_attributes = attributes.len };
        info.primitive_type = switch (key.topology) {
            .points => c.SDL_GPU_PRIMITIVETYPE_POINTLIST,
            .lines => c.SDL_GPU_PRIMITIVETYPE_LINELIST,
            .triangles => c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        };
        info.rasterizer_state.fill_mode = c.SDL_GPU_FILLMODE_FILL;
        info.rasterizer_state.cull_mode = c.SDL_GPU_CULLMODE_NONE;
        // Direct3D 7 clipped transformed vertices to the screen but not in depth.
        info.rasterizer_state.enable_depth_clip = false;
        info.multisample_state.sample_count = if (key.into == .scene) gpu.samples else c.SDL_GPU_SAMPLECOUNT_1;
        info.depth_stencil_state.enable_depth_test = key.depth.testing;
        info.depth_stencil_state.enable_depth_write = key.depth.writing;
        info.depth_stencil_state.compare_op = c.SDL_GPU_COMPAREOP_GREATER_OR_EQUAL;
        info.target_info = .{
            .color_target_descriptions = &colour,
            .num_color_targets = 1,
            .depth_stencil_format = gpu.depth_format,
            // What is drawn over the finished frame, or into the reflections, has no depth buffer
            // to go with it.
            .has_depth_stencil_target = key.into == .scene,
        };
        const made = c.SDL_CreateGPUGraphicsPipeline(gpu.handle, &info) orelse return fail("SDL_CreateGPUGraphicsPipeline");
        gpu.pipelines.putAssumeCapacity(key, made);
        return made;
    }

    /// A frame read back: rows of red, green, blue and alpha from the top, `size` pixels across
    /// and down.
    pub const Capture = struct { rgba: []u8, size: [2]u32 };

    /// The last frame drawn: what a screenshot saves.
    pub fn capture(gpu: *Gpu, gpa: Allocator) Error!Capture {
        const targets = gpu.targets orelse {
            log.err("no frame drawn to capture", .{});
            return error.Sdl;
        };
        const size = [2]u32{ targets.width, targets.height };
        const bytes = std.math.cast(u32, @as(u64, size[0]) * size[1] * 4) orelse return error.OutOfMemory;
        const rgba = try gpa.alloc(u8, bytes);
        errdefer gpa.free(rgba);
        // Through a texture of 8-bit channels, whatever the frame's format.
        const plain = try gpu.target(size, c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET, c.SDL_GPU_SAMPLECOUNT_1);
        defer c.SDL_ReleaseGPUTexture(gpu.handle, plain);
        const transfer = c.SDL_CreateGPUTransferBuffer(gpu.handle, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD, .size = bytes }) orelse return fail("SDL_CreateGPUTransferBuffer");
        defer c.SDL_ReleaseGPUTransferBuffer(gpu.handle, transfer);

        const commands = c.SDL_AcquireGPUCommandBuffer(gpu.handle) orelse return fail("SDL_AcquireGPUCommandBuffer");
        var blit = std.mem.zeroes(c.SDL_GPUBlitInfo);
        blit.source = .{ .texture = targets.finished(), .w = size[0], .h = size[1] };
        blit.destination = .{ .texture = plain, .w = size[0], .h = size[1] };
        blit.load_op = c.SDL_GPU_LOADOP_DONT_CARE;
        blit.filter = c.SDL_GPU_FILTER_NEAREST;
        c.SDL_BlitGPUTexture(commands, &blit);
        const copy = c.SDL_BeginGPUCopyPass(commands) orelse {
            _ = c.SDL_CancelGPUCommandBuffer(commands);
            return fail("SDL_BeginGPUCopyPass");
        };
        c.SDL_DownloadFromGPUTexture(
            copy,
            &.{ .texture = plain, .w = size[0], .h = size[1], .d = 1 },
            &.{ .transfer_buffer = transfer, .offset = 0, .pixels_per_row = size[0], .rows_per_layer = size[1] },
        );
        c.SDL_EndGPUCopyPass(copy);
        const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(commands) orelse return fail("SDL_SubmitGPUCommandBufferAndAcquireFence");
        defer c.SDL_ReleaseGPUFence(gpu.handle, fence);
        if (!c.SDL_WaitForGPUFences(gpu.handle, true, &fence, 1)) return fail("SDL_WaitForGPUFences");
        const mapped: [*]const u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(gpu.handle, transfer, false) orelse return fail("SDL_MapGPUTransferBuffer"));
        @memcpy(rgba, mapped[0..bytes]);
        c.SDL_UnmapGPUTransferBuffer(gpu.handle, transfer);
        return .{ .rgba = rgba, .size = size };
    }
};

fn topology(primitive: device.Primitive) Topology {
    return switch (primitive) {
        .points => .points,
        .lines => .lines,
        .triangles, .strip, .fan => .triangles,
    };
}

/// Appends a draw's primitives to `list` as a list of their topology, its vertices numbered from
/// `base`: strips and fans as the triangles they make. Direct3D culled nothing, so a strip's
/// alternating winding is kept as it comes.
fn appendList(gpa: Allocator, list: *std.ArrayList(u32), primitive: device.Primitive, base: u32, vertex_count: usize, indices: ?[]const u16) Allocator.Error!void {
    const count = if (indices) |i| i.len else vertex_count;
    const at = struct {
        fn index(from: u32, picked: ?[]const u16, n: usize) u32 {
            return from + if (picked) |p| p[n] else @as(u32, @intCast(n));
        }
    };
    switch (primitive) {
        .points, .lines, .triangles => {
            try list.ensureUnusedCapacity(gpa, count);
            for (0..count) |n| list.appendAssumeCapacity(at.index(base, indices, n));
        },
        .strip, .fan => if (count >= 3) {
            try list.ensureUnusedCapacity(gpa, (count - 2) * 3);
            for (2..count) |n| {
                const corners: [3]usize = if (primitive == .strip) .{ n - 2, n - 1, n } else .{ 0, n - 1, n };
                for (corners) |m| list.appendAssumeCapacity(at.index(base, indices, m));
            }
        },
    }
}

/// Runs `next` on from `last` when both draw with the same pipeline and array: a run with no
/// texture joins any.
fn join(last: *Run, next: Run) bool {
    if (!std.meta.eql(last.key, next.key) or last.held != next.held or last.face != next.face) return false;
    if (last.array != null and next.array != null and last.array.? != next.array.?) return false;
    if (last.first + last.count != next.first) return false;
    last.count += next.count;
    if (last.array == null) last.array = next.array;
    return true;
}

fn blendFactor(factor: srd3d.BlendFactor) c.SDL_GPUBlendFactor {
    return switch (factor) {
        .zero => c.SDL_GPU_BLENDFACTOR_ZERO,
        .one => c.SDL_GPU_BLENDFACTOR_ONE,
        .source_alpha => c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
        .inverse_source_alpha => c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
    };
}

pub fn shader(handle: *c.SDL_GPUDevice, spirv: bool, stage: c.SDL_GPUShaderStage, code: []const u8, samplers: u32, uniforms: u32) sdl.Error!*c.SDL_GPUShader {
    var info = std.mem.zeroes(c.SDL_GPUShaderCreateInfo);
    info.code_size = code.len;
    info.code = code.ptr;
    info.entrypoint = if (spirv) "main" else "main0";
    info.format = if (spirv) c.SDL_GPU_SHADERFORMAT_SPIRV else c.SDL_GPU_SHADERFORMAT_MSL;
    info.stage = stage;
    info.num_samplers = samplers;
    info.num_uniform_buffers = uniforms;
    return c.SDL_CreateGPUShader(handle, &info) orelse fail("SDL_CreateGPUShader");
}

/// Copies `levels`, a texture's every level, through `transfer`, mapped at `mapped`, from `at` on,
/// into layer `layer` of `texture`, and moves `at` past them.
fn uploadLevels(copy: *c.SDL_GPUCopyPass, transfer: *c.SDL_GPUTransferBuffer, mapped: [*]u8, at: *u32, texture: *c.SDL_GPUTexture, layer: u16, levels: []const srtexture.Level) void {
    for (levels, 0..) |level, index| {
        @memcpy(mapped[at.*..][0..level.rgba.len], level.rgba);
        c.SDL_UploadToGPUTexture(
            copy,
            &.{ .transfer_buffer = transfer, .offset = at.*, .pixels_per_row = level.width, .rows_per_layer = level.height },
            &.{ .texture = texture, .mip_level = @intCast(index), .layer = layer, .w = level.width, .h = level.height, .d = 1 },
            false,
        );
        at.* += @intCast(level.rgba.len);
    }
}

/// A white texel, which runs with no texture bind.
const blank_levels = [1]srtexture.Level{.{ .width = 1, .height = 1, .rgba = &.{ 0xFF, 0xFF, 0xFF, 0xFF } }};

test Shading {
    // The shadows in the low byte and the magnification in the next two bits, as the shader reads
    // them.
    var image: srtexture.Image = .{ .levels = &.{}, .magnify = .smooth };
    const smooth: u32 = @bitCast(Shading.of(.{ .texture = &image, .depth = undefined, .blend = null, .receives = .cockpit }, false));
    try std.testing.expectEqual(0x102, smooth);
    image.magnify = .edge_adaptive;
    const upscaled: u32 = @bitCast(Shading.of(.{ .texture = &image, .depth = undefined, .blend = null, .receives = .nothing }, false));
    try std.testing.expectEqual(0x200, upscaled);
    const plain: u32 = @bitCast(Shading.of(.{ .texture = null, .depth = undefined, .blend = null, .receives = .world }, false));
    try std.testing.expectEqual(0x001, plain);
    // A planet's soft terminator in the bit after.
    const planet: u32 = @bitCast(Shading.of(.{ .texture = null, .depth = undefined, .blend = null, .receives = .world, .soft_terminator = true }, false));
    try std.testing.expectEqual(0x401, planet);
    // A texture's normal map and material map in the two bits after, where materials are shaded.
    const level = [1]srtexture.Level{.{ .width = 1, .height = 1, .rgba = &.{ 0, 0, 0, 0 } }};
    var material: srtexture.Image = .{ .levels = &level, .maps = .{ .normal = &level, .orm = &level } };
    const state: device.State = .{ .texture = &material, .depth = undefined, .blend = null, .receives = .world };
    try std.testing.expectEqual(0x1801, @as(u32, @bitCast(Shading.of(state, true))));
    try std.testing.expectEqual(0x001, @as(u32, @bitCast(Shading.of(state, false))));
    material.maps.normal = null;
    try std.testing.expectEqual(0x1001, @as(u32, @bitCast(Shading.of(state, true))));
}

test appendList {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);
    // A strip of five and a fan of four as triangles, numbered on from their bases.
    try appendList(gpa, &list, .strip, 10, 5, null);
    try std.testing.expectEqualSlices(u32, &.{ 10, 11, 12, 11, 12, 13, 12, 13, 14 }, list.items);
    list.clearRetainingCapacity();
    try appendList(gpa, &list, .fan, 0, 4, null);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 0, 2, 3 }, list.items);
    // Picked by indices, and nothing from a strip too short to make a triangle.
    list.clearRetainingCapacity();
    try appendList(gpa, &list, .triangles, 4, 3, &.{ 2, 0, 1 });
    try appendList(gpa, &list, .strip, 0, 2, null);
    try std.testing.expectEqualSlices(u32, &.{ 6, 4, 5 }, list.items);
}

test "Gpu.ScreenUniforms.of" {
    // The pass as the shader's `int(frame.settings.x)` reads it, then the texel and the level.
    const across = Gpu.ScreenUniforms.of(.blur, .{ 0.25, 0 }, 0, @splat(0));
    try std.testing.expectEqual([4]f32{ 1, 0.25, 0, 0 }, across.settings);
    const last = Gpu.ScreenUniforms.of(.finish, .{ 0, 0 }, 0.5, .{ 1, 1, 0, 0 });
    try std.testing.expectEqual([4]f32{ 2, 0, 0, 0.5 }, last.settings);
    try std.testing.expectEqual([4]f32{ 1, 1, 0, 0 }, last.finish);
    try std.testing.expectEqual(0, Gpu.ScreenUniforms.of(.bright, .{ 0, 0 }, 1, @splat(0)).settings[0]);
}

test join {
    const flat: PipelineKey = .{ .topology = .triangles, .depth = .{ .testing = true, .writing = true }, .blend = null };
    const added: PipelineKey = .{ .topology = .triangles, .depth = .{ .testing = true, .writing = false }, .blend = srd3d.factors(.add) };
    var last: Run = .{ .key = flat, .array = null, .first = 0, .count = 3 };
    // An untextured run takes on the next one's array; the same array joins, another does not.
    try std.testing.expect(join(&last, .{ .key = flat, .array = 2, .first = 3, .count = 6 }));
    try std.testing.expectEqual(9, last.count);
    try std.testing.expectEqual(2, last.array.?);
    try std.testing.expect(join(&last, .{ .key = flat, .array = null, .first = 9, .count = 3 }));
    try std.testing.expect(!join(&last, .{ .key = flat, .array = 1, .first = 12, .count = 3 }));
    // Other render states do not join, nor another face of the reflections.
    try std.testing.expect(!join(&last, .{ .key = added, .array = 2, .first = 12, .count = 3 }));
    try std.testing.expect(!join(&last, .{ .key = flat, .face = 4, .array = 2, .first = 12, .count = 3 }));
    try std.testing.expectEqual(12, last.count);
}

test prepared {
    // The scene's ten sets of states in three topologies, and the five that test no depth again
    // over the finished frame.
    try std.testing.expectEqual(45, prepared.len);
    for (prepared, 0..) |key, index| {
        // The finished frame has no depth to test.
        try std.testing.expect(key.into == .scene or !key.depth.testing);
        for (prepared[index + 1 ..]) |other| try std.testing.expect(!std.meta.eql(key, other));
    }
    // Among them, a blended effect's in the world, and the display's over the finished frame.
    const effect: PipelineKey = .{ .topology = .triangles, .depth = srd3d.depth(.world, .premultiplied), .blend = srd3d.factors(.premultiplied) };
    const display: PipelineKey = .{ .topology = .triangles, .depth = srd3d.depth(.overlay, .alpha), .blend = srd3d.factors(.alpha), .into = .finished };
    for ([_]PipelineKey{ effect, display }) |wanted| {
        const found = for (prepared) |key| {
            if (std.meta.eql(key, wanted)) break true;
        } else false;
        try std.testing.expect(found);
    }
}

test "Lighting.take" {
    var lighting: Lighting = .{};
    const list = [_]device.Light{
        .{ .mask = 0x08, .kind = .{ .directional = .{ .toward = .{ 0, 0, -0.5 }, .colour = .{ 1, 0.9, 0.8 } } } },
        .{ .mask = 0x01, .kind = .{ .point = .{ .position = .{ 3, 4, 50 }, .reach = 200, .colour = .{ 0.25, 0.25, 0.5 }, .intensity = 2 } } },
    };
    try std.testing.expectEqual(2, lighting.take(&list, false));
    try std.testing.expectEqual(2, lighting.count[0]);
    try std.testing.expectEqual(Lighting.Light{ .colour = .{ 1, 0.9, 0.8, 0 }, .vector = .{ 0, 0, -0.5, 0 }, .mask = 0x08, .kind = .directional }, lighting.lights[0]);
    try std.testing.expectEqual(Lighting.Light{ .colour = .{ 0.5, 0.5, 1, 0 }, .vector = .{ 3, 4, 50, 200 }, .mask = 0x01, .kind = .point }, lighting.lights[1]);
    // Past the shader's room it takes the first, and the driver lights the vertices with the rest.
    const many: [max_lights + 1]device.Light = @splat(list[0]);
    try std.testing.expectEqual(max_lights, lighting.take(&many, false));
    try std.testing.expectEqual(max_lights, lighting.count[0]);
}

test {
    _ = shadow;
}

test "Lighting.take in linear light" {
    var lighting: Lighting = .{};
    const list = [_]device.Light{
        .{ .mask = 0x01, .kind = .{ .directional = .{ .toward = .{ 0, 0, -1 }, .colour = .{ 1, 0.5, 0 } } }, .shadowed = true },
        .{ .mask = 0x02, .kind = .{ .point = .{ .position = @splat(0), .reach = 10, .colour = .{ 0.5, 0.5, 0.5 }, .intensity = 2 } } },
    };
    try std.testing.expectEqual(2, lighting.take(&list, true));
    // Each colour decoded, and a point light's intensity applied after: the light, not the
    // encoding, doubled.
    try std.testing.expectApproxEqAbs(srgb.decoded(0.5), lighting.lights[0].colour[1], 1e-6);
    try std.testing.expectApproxEqAbs(2 * srgb.decoded(0.5), lighting.lights[1].colour[0], 1e-6);
    try std.testing.expectEqual(1, lighting.lights[0].shadowed);
}

test Slot {
    var image: srtexture.Image = .{ .levels = &blank_levels };
    try std.testing.expectEqual(null, Slot.of(image));
    const slot: Slot = .{ .array = 3, .layer = 200 };
    image.device = @as(u32, @bitCast(slot));
    try std.testing.expectEqual(slot, Slot.of(image).?);
    // The first layer of the first array is still told from an image never drawn.
    image.device = @as(u32, @bitCast(Slot{ .array = 0, .layer = 0 }));
    try std.testing.expect(Slot.of(image) != null);
}
