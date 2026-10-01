//! The parts of Direct3D 7 the driver uses (`IDirect3DDevice7`), as OpenReliant provides them: a
//! device that draws transformed, lit vertices with the states `set_material` and `set_depth`
//! choose. `software.zig` draws them as Direct3D 7 rasterizes; the executable's device draws them
//! with SDL's GPU interface.

const std = @import("std");

const math = @import("../math.zig");
const srd3d = @import("srd3d.zig");
const srlight = @import("../surrenderlib/srlight.zig");
const srshadow = @import("../surrenderlib/srshadow.zig");
const srtexture = @import("../surrenderlib/srtexture.zig");

/// A vertex as the driver hands it over (`D3DFVF_XYZRHW | D3DFVF_DIFFUSE | D3DFVF_SPECULAR |
/// D3DFVF_TEX1`, `0x1C4`): on the screen, with pixel centres at whole numbers, as Direct3D 7 has
/// them. The fields after `v` are OpenReliant's, for a device that lights each pixel (`lights`).
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    /// Depth: nearer is greater.
    z: f32,
    /// One over the depth, scaled; texture coordinates and colours are interpolated by it.
    rhw: f32,
    /// Alpha, red, green and blue, from the top byte down (`Diffuse`).
    diffuse: u32,
    specular: u32 = 0,
    u: f32 = 0,
    v: f32 = 0,
    /// Where the vertex stands in the camera's frame, and its normal there.
    view: [3]f32 = .{ 0, 0, 0 },
    normal: [3]f32 = .{ 0, 0, 0 },
    /// The lights that don't reach it, as its object's light mask (`srlight.Light.reaches`). All
    /// ones, as for everything but a lit mesh, when the device lights none of its pixels:
    /// `diffuse` is then its whole colour.
    light_mask: u32 = no_lights,

    comptime {
        // The flexible vertex format's fields, in its order, and OpenReliant's after them.
        std.debug.assert(@offsetOf(Vertex, "rhw") == 12);
        std.debug.assert(@offsetOf(Vertex, "diffuse") == 16);
        std.debug.assert(@offsetOf(Vertex, "specular") == 20);
        std.debug.assert(@offsetOf(Vertex, "u") == 24);
        std.debug.assert(@offsetOf(Vertex, "view") == 32);
        std.debug.assert(@offsetOf(Vertex, "light_mask") == 56);
        std.debug.assert(@sizeOf(Vertex) == 60);
    }
};

/// A vertex's light mask when no light reaches it.
pub const no_lights = srlight.no_lights;

/// A vertex's colour as the device takes it: a byte a channel, blue in the lowest and alpha in the
/// highest (`D3DCOLOR`).
pub const Diffuse = packed struct(u32) {
    blue: u8,
    green: u8,
    red: u8,
    alpha: u8,

    /// `channels`, red, green, blue and alpha, as the driver packs them: each times 255, rounded.
    pub fn of(channels: [4]f32) Diffuse {
        return .{ .red = channel(channels[0]), .green = channel(channels[1]), .blue = channel(channels[2]), .alpha = channel(channels[3]) };
    }

    /// The colour, red, green, blue and alpha, each from 0 to 1.
    pub fn colour(diffuse: Diffuse) [4]f32 {
        return .{ level(diffuse.red), level(diffuse.green), level(diffuse.blue), level(diffuse.alpha) };
    }

    fn channel(c: f32) u8 {
        return std.math.lossyCast(u8, math.roundEven(c * 255));
    }

    fn level(byte: u8) f32 {
        return @as(f32, @floatFromInt(byte)) / 255;
    }
};

/// A directional or point light as a device that lights each pixel takes it (`Device.lights`), in
/// the camera's frame. It reaches a vertex whose light mask shares no bit with `mask`, and adds to
/// the vertex's colour what `srmesh` would add to it, for each pixel instead of each vertex.
pub const Light = struct {
    mask: u32,
    kind: Kind,
    /// Kept off what a caster shades from it, for a device that draws shadows.
    shadowed: bool = false,

    pub const Kind = union(enum) {
        /// `colour` times the dot product of the pixel's normal with `toward`, where that is
        /// positive. `toward` points at the light and is as long as its intensity.
        directional: struct { toward: [3]f32, colour: [3]f32 },
        /// `colour` times `intensity`, times `(1 - r / reach)²` and the cosine of the angle
        /// between the normal and the light, for a pixel `r` from `position` and within `reach`.
        point: struct { position: [3]f32, reach: f32, colour: [3]f32, intensity: f32 },
    };
};

/// Packs a colour, red, green, blue and alpha, into a vertex's `diffuse` as the driver does
/// (`Diffuse.of`).
pub fn pack(colour: [4]f32) u32 {
    return @bitCast(Diffuse.of(colour));
}

/// A vertex's `diffuse` as red, green, blue and alpha, each from 0 to 1.
pub fn unpack(diffuse: u32) [4]f32 {
    return @as(Diffuse, @bitCast(diffuse)).colour();
}

pub const white: u32 = 0xFFFF_FFFF;

/// The primitives the driver draws (`D3DPRIMITIVETYPE`).
pub const Primitive = enum {
    points,
    lines,
    triangles,
    strip,
    fan,
};

/// The render states for a draw: the texture, modulated by the diffuse colour, or the diffuse
/// colour alone without one; the depth test and writes; and the blend factors, or none for blending
/// off.
pub const State = struct {
    texture: ?*srtexture.Image,
    depth: srd3d.Depth,
    blend: ?srd3d.Factors,
    /// OpenReliant's: the shadows the draw's lit pixels are looked up in, for a device that draws
    /// them.
    receives: Receives = .nothing,
    /// OpenReliant's: the key lights reach a little way past the terminator of what it draws
    /// (`srapiext.MeshObject.soft_terminator`), where the device lights each pixel.
    soft_terminator: bool = false,
    /// How its texture is filtered (`D3DTSS_MAGFILTER`, `D3DTSS_MINFILTER`, `D3DTSS_MIPFILTER`).
    filter: Filter = .linear,
};

/// How a draw's texture is filtered: linearly, or from the nearest texel of its finest level, as
/// the background image is (`begin_scene`, `0x100077A0`).
pub const Filter = enum { linear, point };

/// OpenReliant's: the size a device draws its frames at, which the window shows scaled to fit: a
/// share of the window's own each way, in hundredths, 100 for the window's own; or a size in pixels
/// of its own, whatever the window's.
pub const FrameSize = union(enum) {
    share: u8,
    pixels: [2]u32,

    /// The whole of the window, in hundredths.
    pub const whole = 100;

    /// The window's own size.
    pub const window: FrameSize = .{ .share = whole };

    /// The size in pixels for a window `window_size` pixels in size: a share rounded to the nearest
    /// pixel, at least one each way.
    pub fn of(size: FrameSize, window_size: [2]u32) [2]u32 {
        return switch (size) {
            .pixels => |pixels| pixels,
            .share => |share| .{ part(window_size[0], share), part(window_size[1], share) },
        };
    }

    fn part(pixels: u32, share: u8) u32 {
        return std.math.lossyCast(u32, @max((@as(u64, pixels) * share + whole / 2) / whole, 1));
    }
};

test FrameSize {
    try std.testing.expectEqual([2]u32{ 2560, 1440 }, FrameSize.window.of(.{ 2560, 1440 }));
    try std.testing.expectEqual([2]u32{ 1920, 1080 }, (FrameSize{ .share = 75 }).of(.{ 2560, 1440 }));
    // Rounded to the nearest pixel, and never less than one.
    try std.testing.expectEqual([2]u32{ 756, 491 }, (FrameSize{ .share = 25 }).of(.{ 3024, 1964 }));
    try std.testing.expectEqual([2]u32{ 1, 1 }, (FrameSize{ .share = 1 }).of(.{ 10, 10 }));
    try std.testing.expectEqual([2]u32{ 800, 600 }, (FrameSize{ .pixels = .{ 800, 600 } }).of(.{ 2560, 1440 }));
}

/// Which shadows a draw's pixels take, which the layer sets: none, the world's cascades, or the
/// cockpit's map (`srshadow`).
pub const Receives = enum(u8) {
    nothing = 0,
    world = 1,
    cockpit = 2,
};

pub const Device = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Clears to black and to depth 0 (`Clear`), and begins the scene.
        begin: *const fn (*anyopaque) void,
        end: *const fn (*anyopaque) void,
        /// Draws `vertices`, or those `indices` pick, as `primitive` (`DrawPrimitive`,
        /// `DrawIndexedPrimitive`).
        draw: *const fn (*anyopaque, State, Primitive, []const Vertex, ?[]const u16) void,
        /// Marks where the scene ends and what is drawn over it begins. The game drew its display
        /// straight over the finished frame, so a device that adds anything to the frame of its
        /// own, as the GPU's bloom does, leaves out what follows this.
        overlay: *const fn (*anyopaque) void,
        /// OpenReliant's: takes the frame's directional and point lights, most wanted first, and
        /// returns how many of them, from the first, it adds to each pixel. The driver lights
        /// the vertices with the rest. A device without it lights nothing itself, and the
        /// driver's vertices come lit, as Direct3D 7's did.
        lights: ?*const fn (*anyopaque, []const Light) usize = null,
        /// OpenReliant's: how it draws shadows, or null where it draws none. A device without it
        /// draws none.
        shadow_settings: ?*const fn (*anyopaque) ?srshadow.Settings = null,
        /// OpenReliant's: the frame's shadows, after its lights, which last until the scene ends.
        shadows: ?*const fn (*anyopaque, *const srshadow.Frame) void = null,
        /// The display's gamma ramp, which `srd3d.dll` sets to the brightness (`set_gamma`,
        /// `0x10005270`, the payload's `sr + 0x54`): each level of the finished frame, from 0 to 1,
        /// shown at its power 1 / brightness, so that a brightness above 1 lightens the frame and
        /// one below darkens it; a brightness of 0 shows it black. A device without it has no ramp
        /// (`sr + 0x38` bit 0 clear), and the brightness can't be set. A screenshot keeps the frame
        /// as drawn, as the game's did, the ramp being the display's.
        gamma: ?*const fn (*anyopaque, f32) void = null,
        /// OpenReliant's: whether it shades a texture's material maps (`srtexture.Image.Maps`),
        /// whose highlights then stand in for the driver's highlight pass. A device without it
        /// shades none.
        materials: ?*const fn (*anyopaque) bool = null,
    };

    pub fn begin(device: Device) void {
        device.vtable.begin(device.ptr);
    }

    pub fn end(device: Device) void {
        device.vtable.end(device.ptr);
    }

    pub fn draw(device: Device, state: State, primitive: Primitive, vertices: []const Vertex, indices: ?[]const u16) void {
        device.vtable.draw(device.ptr, state, primitive, vertices, indices);
    }

    pub fn overlay(device: Device) void {
        device.vtable.overlay(device.ptr);
    }

    /// Hands the device the frame's lights, most wanted first, and returns how many of them it
    /// adds to each pixel.
    pub fn lights(device: Device, list: []const Light) usize {
        const take = device.vtable.lights orelse return 0;
        return take(device.ptr, list);
    }

    /// How the device draws shadows, or null where it draws none.
    pub fn shadowSettings(device: Device) ?srshadow.Settings {
        const settings = device.vtable.shadow_settings orelse return null;
        return settings(device.ptr);
    }

    /// Hands the device the frame's shadows.
    pub fn shadows(device: Device, frame: *const srshadow.Frame) void {
        const take = device.vtable.shadows orelse return;
        take(device.ptr, frame);
    }

    /// Whether the device has a gamma ramp, which the brightness sets (`sr + 0x38` bit 0).
    pub fn setsGamma(device: Device) bool {
        return device.vtable.gamma != null;
    }

    /// Sets the device's gamma ramp to `brightness`, where it has one.
    pub fn gamma(device: Device, brightness: f32) void {
        const set = device.vtable.gamma orelse return;
        set(device.ptr, brightness);
    }

    /// Whether the device shades material maps.
    pub fn shadesMaterials(device: Device) bool {
        const shades = device.vtable.materials orelse return false;
        return shades(device.ptr);
    }
};

test pack {
    try std.testing.expectEqual(0xFF804000, pack(.{ 0.5, 0.25, 0, 1 }));
    try std.testing.expectEqual(white, pack(.{ 1, 1, 1, 1 }));
    const diffuse: Diffuse = @bitCast(pack(.{ 0.5, 0.25, 0, 1 }));
    try std.testing.expectEqual(0x80, diffuse.red);
    try std.testing.expectEqual(0x40, diffuse.green);
}

test unpack {
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 1 }, unpack(0xFFFF0000));
    try std.testing.expectEqual([4]f32{ 128.0 / 255.0, 64.0 / 255.0, 0, 1 }, unpack(pack(.{ 0.5, 0.25, 0, 1 })));
}

/// Devices for the tests of what draws with one.
pub const testing = struct {
    /// A device that keeps what it is asked to draw, and hands the lights it is given room for.
    pub const Recorder = struct {
        gpa: std.mem.Allocator,
        draws: std.ArrayList(Draw) = .empty,
        vertices: std.ArrayList(Vertex) = .empty,
        /// How many of the frame's lights it adds to each pixel, and the lights it was last handed.
        room: usize = 0,
        lights: std.ArrayList(Light) = .empty,

        /// A draw: its states, and its vertices in `vertices`, as the indices pick them.
        pub const Draw = struct { state: State, primitive: Primitive, first: usize, count: usize };

        pub fn deinit(recorder: *Recorder) void {
            recorder.draws.deinit(recorder.gpa);
            recorder.vertices.deinit(recorder.gpa);
            recorder.lights.deinit(recorder.gpa);
        }

        pub fn interface(recorder: *Recorder) Device {
            return .{ .ptr = recorder, .vtable = &vtable };
        }

        /// Forgets what it was asked to draw.
        pub fn clear(recorder: *Recorder) void {
            recorder.draws.clearRetainingCapacity();
            recorder.vertices.clearRetainingCapacity();
        }

        /// The vertices of draw `n`.
        pub fn drawn(recorder: *const Recorder, n: usize) []const Vertex {
            const made = recorder.draws.items[n];
            return recorder.vertices.items[made.first..][0..made.count];
        }

        /// The vertices of the last draw, or none.
        pub fn last(recorder: *const Recorder) []const Vertex {
            if (recorder.draws.items.len == 0) return &.{};
            return recorder.drawn(recorder.draws.items.len - 1);
        }

        const vtable: Device.VTable = .{ .begin = nothing, .end = nothing, .draw = draw, .overlay = nothing, .lights = take };

        fn from(ptr: *anyopaque) *Recorder {
            return @ptrCast(@alignCast(ptr));
        }

        fn nothing(_: *anyopaque) void {}

        fn draw(ptr: *anyopaque, state: State, primitive: Primitive, vertices: []const Vertex, indices: ?[]const u16) void {
            const recorder = from(ptr);
            const first = recorder.vertices.items.len;
            if (indices) |picked| {
                for (picked) |index| recorder.vertices.append(recorder.gpa, vertices[index]) catch @panic("out of memory");
            } else {
                recorder.vertices.appendSlice(recorder.gpa, vertices) catch @panic("out of memory");
            }
            const made: Draw = .{ .state = state, .primitive = primitive, .first = first, .count = recorder.vertices.items.len - first };
            recorder.draws.append(recorder.gpa, made) catch @panic("out of memory");
        }

        fn take(ptr: *anyopaque, list: []const Light) usize {
            const recorder = from(ptr);
            recorder.lights.clearRetainingCapacity();
            recorder.lights.appendSlice(recorder.gpa, list) catch @panic("out of memory");
            return @min(list.len, recorder.room);
        }
    };
};

test "testing.Recorder" {
    var recorder: testing.Recorder = .{ .gpa = std.testing.allocator };
    defer recorder.deinit();
    const target = recorder.interface();
    const state: State = .{ .texture = null, .depth = .{ .testing = false, .writing = false }, .blend = null };
    const corners = [3]Vertex{ .{ .x = 0, .y = 0, .z = 0, .rhw = 1, .diffuse = white }, .{ .x = 1, .y = 0, .z = 0, .rhw = 1, .diffuse = white }, .{ .x = 0, .y = 1, .z = 0, .rhw = 1, .diffuse = white } };
    target.draw(state, .fan, &corners, null);
    target.draw(state, .triangles, &corners, &.{ 2, 1 });
    try std.testing.expectEqual(2, recorder.draws.items.len);
    try std.testing.expectEqual(3, recorder.drawn(0).len);
    try std.testing.expectEqual(1, recorder.last()[1].x);
    recorder.room = 1;
    try std.testing.expectEqual(1, target.lights(&.{ .{ .mask = 1, .kind = .{ .directional = .{ .toward = .{ 0, 0, 1 }, .colour = .{ 1, 1, 1 } } } }, .{ .mask = 2, .kind = .{ .directional = .{ .toward = .{ 0, 1, 0 }, .colour = .{ 1, 1, 1 } } } } }));
    try std.testing.expectEqual(2, recorder.lights.items.len);
}
