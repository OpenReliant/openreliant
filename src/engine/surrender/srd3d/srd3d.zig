//! `C:\lancer\surrender\srD3D\srD3D.cpp`: Surrender's Direct3D 7 driver, `srd3d.dll`. It draws what
//! the payload's pipelines hand it: it turns materials into render states, draws what is opaque at
//! once, puts what is blended aside for the payload to sort, and clips. OpenReliant's driver draws
//! on a `device.Device`, the parts of Direct3D 7 it uses.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../math.zig");
const srapi = @import("../surrenderlib/srapi.zig");
const srapiext = @import("../surrenderlib/srapiext.zig");
const srbmo = @import("../surrenderlib/srbmo.zig");
const srclip = @import("../surrenderlib/srclip.zig");
const srlight = @import("../surrenderlib/srlight.zig");
const srcore = @import("../surrenderlib/srcore.zig");
const srmesh = @import("../surrenderlib/srmesh.zig");
const srshadow = @import("../surrenderlib/srshadow.zig");
const srstars = @import("../surrenderlib/srstars.zig");
const srtexture = @import("../surrenderlib/srtexture.zig");
const device = @import("device.zig");
const Material = srapiext.Material;
const Vector = math.Vector;
const Vertex = device.Vertex;

pub const Layer = srcore.Layer;

pub const Depth = struct {
    testing: bool,
    writing: bool,
};

/// How a pass uses the depth buffer (`0x100018B0`). Depth is stored reversed: nearer is greater.
pub fn depth(layer: Layer, mode: Material.Blend) Depth {
    return switch (layer) {
        .background, .overlay => .{ .testing = false, .writing = false },
        .world => .{ .testing = true, .writing = mode == .off },
    };
}

/// Direct3D 7's blend factors (`D3DBLEND`), those the driver uses.
pub const BlendFactor = enum(u32) {
    zero = 1,
    one = 2,
    source_alpha = 5,
    inverse_source_alpha = 6,
};

pub const Factors = struct {
    source: BlendFactor,
    destination: BlendFactor,
};

/// The factors a blend mode sets (`SR_driver_init`, `0x100056B0`), or null where blending is off.
/// Values past `add_alpha` index beyond the driver's tables.
pub fn factors(mode: Material.Blend) ?Factors {
    return switch (mode) {
        .off => null,
        .add => .{ .source = .one, .destination = .one },
        .premultiplied => .{ .source = .one, .destination = .inverse_source_alpha },
        .alpha => .{ .source = .source_alpha, .destination = .inverse_source_alpha },
        .add_alpha => .{ .source = .source_alpha, .destination = .one },
        _ => null,
    };
}

/// A pass's colour and alpha before blending (`set_material`, `0x10001B20`): the texel times the
/// vertex colour, or the vertex colour alone without a texture. An unlit pass's vertex colour is
/// white.
pub fn shade(texel: ?[4]f32, vertex: [4]f32, lit: bool) [4]f32 {
    const colour: @Vector(4, f32) = if (lit) vertex else @splat(1);
    return if (texel) |t| @as(@Vector(4, f32), t) * colour else colour;
}

/// A pass's colour, `source`, blended over `destination` with the factors, or replacing it without
/// them, each channel clamped to 1.
pub fn blend(with: ?Factors, source: [4]f32, destination: [3]f32) [3]f32 {
    const f = with orelse return .{ source[0], source[1], source[2] };
    const s = factor(f.source, source[3]);
    const d = factor(f.destination, source[3]);
    var out: [3]f32 = undefined;
    for (&out, 0..) |*c, i| c.* = @min(source[i] * s + destination[i] * d, 1);
    return out;
}

fn factor(f: BlendFactor, source_alpha: f32) f32 {
    return switch (f) {
        .zero => 0,
        .one => 1,
        .source_alpha => source_alpha,
        .inverse_source_alpha => 1 - source_alpha,
    };
}

/// Sides of a highlight texture, in texels.
pub const highlight_size = 64;

pub const Highlight = [highlight_size][highlight_size][4]u8;

/// Sharpness of the highlights, by index modulo 4.
const highlight_exponents = [4]f32{ 1.01, 2.01, 5.01, 10.01 };

/// The brightness a highlight falls to at its rim and keeps outside it (`0x100223AC`).
const highlight_floor: f32 = 0.4;

/// The level `make_highlight` scales a texel's brightness to, the floor coming to a little over a
/// third of it (`0x10020400`).
const highlight_scale: f32 = 200;

/// How `make_highlight` makes a texel of its level, in whole numbers, by numbers in its code:
/// indices 4 to 7 take `dimmed_tenths` tenths of the level; the grey is what the level runs past
/// `grey_from`, over `grey_over`; and the alpha is the level times `alpha_times`, over
/// `alpha_over`.
const dimmed_tenths = 7;
const grey_from = 200;
const grey_over = 3;
const alpha_times = 3;
const alpha_over = 2;

/// Texel `(x, y)` of highlight texture `index` as red, green, blue and alpha: grey, brightest at
/// the centre (`make_highlight`, `0x10001620`). Indices 4 to 7 repeat 0 to 3 at seven tenths the
/// brightness. The driver makes the eight at start-up; a material whose image is below 8 names
/// one.
pub fn highlightTexel(index: u3, x: u6, y: u6) [4]u8 {
    const e: f32 = highlight_exponents[index & 3];
    const peak: f32 = @floatCast(std.math.pow(f64, @as(f64, e) + 1, 1 / @as(f64, e)));
    const fx = centred(x);
    const fy = centred(y);
    const fy2: f32 = @floatCast(fy * fy);
    const d2: f32 = @floatCast(fx * fx + fy2);
    const intensity: f64 = if (d2 <= 1)
        std.math.pow(f64, (1 - @as(f64, @sqrt(d2))) * peak, e) + highlight_floor
    else
        highlight_floor;
    const scaled: f32 = @floatCast(intensity / (highlight_floor + 1) * highlight_scale);
    var level: i32 = std.math.lossyCast(i32, @round(scaled));
    if (index > 3) level = @divTrunc(level * dimmed_tenths, 10);
    const grey = std.math.lossyCast(u8, @divTrunc(level - grey_from, grey_over));
    const alpha = std.math.lossyCast(u8, @divTrunc(level * alpha_times, alpha_over));
    return .{ grey, grey, grey, alpha };
}

/// A texel's place across the texture, from -1 at the first to just short of 1 at the last.
fn centred(i: u6) f64 {
    return @as(f64, @floatFromInt(@as(i32, i) * 2 - highlight_size)) / highlight_size;
}

/// Highlight texture `index`, row by row from the top.
pub fn highlight(index: u3) Highlight {
    var texels: Highlight = undefined;
    for (&texels, 0..) |*row, y| {
        for (row, 0..) |*texel, x| texel.* = highlightTexel(index, @intCast(x), @intCast(y));
    }
    return texels;
}

// --- The driver ---------------------------------------------------------------------------------

/// The driver (`SR_driver_init`, `0x100056B0`, fills `sr`'s table with these). OpenReliant draws a
/// material's two passes one after the other, as the driver does on a device that cannot draw both
/// at once, to the same effect.
pub const Driver = struct {
    gpa: Allocator,
    target: device.Device,
    /// The eight highlight textures (`make_highlights`, `0x10001820`).
    highlights: [8]srtexture.Image,
    context: *srapi.Context = undefined,
    /// The vertices and triangles a pass gathers before drawing them at once.
    vertices: std.ArrayList(Vertex) = .empty,
    indices: std.ArrayList(u16) = .empty,
    /// A polygon drawn on its own, clipped or put aside, apart from what a pass is gathering.
    single: std.ArrayList(Vertex) = .empty,

    pub fn init(gpa: Allocator, target: device.Device) Allocator.Error!Driver {
        var driver: Driver = .{ .gpa = gpa, .target = target, .highlights = undefined };
        var made: usize = 0;
        errdefer for (driver.highlights[0..made]) |h| h.deinit(gpa);
        for (&driver.highlights, 0..) |*h, index| {
            const texels = highlight(@intCast(index));
            const rgba = try gpa.dupe(u8, std.mem.asBytes(&texels));
            errdefer gpa.free(rgba);
            h.* = try .single(gpa, highlight_size, highlight_size, rgba);
            made += 1;
        }
        return driver;
    }

    pub fn deinit(driver: *Driver) void {
        for (driver.highlights) |h| h.deinit(driver.gpa);
        driver.vertices.deinit(driver.gpa);
        driver.indices.deinit(driver.gpa);
        driver.single.deinit(driver.gpa);
    }

    /// Hands the mark to the device, which keeps what follows out of anything it adds to the
    /// frame of its own.
    fn overlayMark(ptr: *anyopaque) void {
        from(ptr).target.overlay();
    }

    /// The driver as `srcore.render` takes it.
    pub fn interface(driver: *Driver) srcore.Driver {
        return .{ .ptr = driver, .vtable = &vtable };
    }

    const vtable: srcore.Driver.VTable = .{
        .begin = begin,
        .lights = lights,
        .mesh = drawMesh,
        .sprites = drawSprites,
        .stars = drawStars,
        .flush = flushBlended,
        .end = end,
        .overlay = overlayMark,
        .shadows = shadows,
    };

    /// OpenReliant's: hands the device the frame's shadows.
    fn shadows(ptr: *anyopaque, frame: *const srshadow.Frame) void {
        from(ptr).target.shadows(frame);
    }

    fn from(ptr: *anyopaque) *Driver {
        return @ptrCast(@alignCast(ptr));
    }

    /// `begin_scene` (`0x100077A0`): the depth scale for the frame, then clears, and draws the
    /// background image where there is one (`drawBackground`). OpenReliant hands the device the
    /// brightness first, for its gamma ramp, where the driver sets the ramp only as the brightness
    /// changes (`set_gamma`, `0x10005270`).
    fn begin(ptr: *anyopaque, context: *srapi.Context) void {
        const driver = from(ptr);
        driver.context = context;
        context.projection.depth_scale = srapi.depthScale(context.projection.near);
        driver.target.gamma(context.brightness);
        driver.target.begin();
        if (context.background) |image| driver.drawBackground(image, context.projection.viewport);
    }

    /// The background image over `viewport`, the screen's pixels left, top, right and bottom, from
    /// the nearest texel, white, with neither depth nor blending (`0x10007843` on). The driver draws
    /// it in squares of up to 256 texels, the most a texture of its time held; OpenReliant draws it
    /// as one.
    fn drawBackground(driver: *Driver, image: *srtexture.Image, viewport: [4]f32) void {
        const left, const top, const right, const bottom = viewport;
        const corners = [4]Vertex{
            .{ .x = left, .y = top, .z = background_depth, .rhw = 1, .diffuse = device.white, .u = 0, .v = 0 },
            .{ .x = right, .y = top, .z = background_depth, .rhw = 1, .diffuse = device.white, .u = 1, .v = 0 },
            .{ .x = right, .y = bottom, .z = background_depth, .rhw = 1, .diffuse = device.white, .u = 1, .v = 1 },
            .{ .x = left, .y = bottom, .z = background_depth, .rhw = 1, .diffuse = device.white, .u = 0, .v = 1 },
        };
        const look: device.State = .{ .texture = image, .depth = depth(.background, .off), .blend = null, .filter = .point };
        driver.target.draw(look, .fan, &corners, null);
    }

    /// The depth the background's corners stand at (`0x3F000000`), which neither tests nor writes.
    const background_depth: f32 = 0.5;

    fn end(ptr: *anyopaque) void {
        from(ptr).target.end();
    }

    /// OpenReliant's: hands the device the frame's directional and point lights in the camera's
    /// frame, the directional lights first and then the point lights nearest the camera, and
    /// marks those it adds to each pixel. The pipeline adds the rest to each vertex.
    fn lights(ptr: *anyopaque, list: []srlight.Light) Allocator.Error!void {
        const driver = from(ptr);
        const context = driver.context;
        var wanted: std.ArrayList(Wanted) = .empty;
        defer wanted.deinit(driver.gpa);
        for (list, 0..) |*l, index| {
            l.per_pixel = false;
            const away: f32 = switch (l.kind) {
                .ambient => continue,
                .directional => -1,
                .point => |point| math.lengthSquared(context.view(point.position)),
            };
            try wanted.append(driver.gpa, .{ .index = index, .away = away });
        }
        std.mem.sort(Wanted, wanted.items, {}, Wanted.before);
        var taken: std.ArrayList(device.Light) = .empty;
        defer taken.deinit(driver.gpa);
        for (wanted.items) |w| {
            const l = list[w.index];
            const kind: device.Light.Kind = switch (l.kind) {
                .ambient => unreachable,
                .directional => |forward| .{ .directional = .{
                    .toward = math.normalize(context.turn(forward)) * @as(math.Vector, @splat(l.intensity)),
                    .colour = l.colour,
                } },
                .point => |point| .{ .point = .{
                    .position = context.view(point.position),
                    .reach = l.reach(point),
                    .colour = l.colour,
                    .intensity = l.intensity,
                } },
            };
            try taken.append(driver.gpa, .{ .mask = l.mask, .kind = kind, .shadowed = l.shadowed });
        }
        const count = @min(driver.target.lights(taken.items), wanted.items.len);
        for (wanted.items[0..count]) |w| list[w.index].per_pixel = true;
        context.pixel_lighting = count > 0;
        // Shadows darken what the device adds to each pixel alone.
        context.shadows = if (context.pixel_lighting) driver.target.shadowSettings() else null;
    }

    /// A light the device may add to each pixel, and how far it stands from the camera, squared;
    /// a directional light stands before them all.
    const Wanted = struct {
        index: usize,
        away: f32,

        fn before(_: void, a: Wanted, b: Wanted) bool {
            return a.away < b.away;
        }
    };

    /// The light mask a corner of `drawn` goes to the device with: its object's, for a pass lit
    /// in a frame whose device lights each pixel, and none otherwise.
    fn pixelMask(drawn: *const srmesh.Drawn, material: Material, pass: u1) u32 {
        if (drawn.normals == null or !material.lit[pass]) return device.no_lights;
        return drawn.object.light_mask;
    }

    /// Whether a surface's second pass is drawn: where its material has one, but for a highlight
    /// pass over a texture whose material map the device shades, whose highlights stand in for it.
    ///
    /// **Improvement:** a material of a mod's lights its own highlights, as its maps describe them.
    fn drawsSecond(driver: *const Driver, surface: *const srapiext.Surface) bool {
        if (!surface.material.two_pass) return false;
        if (surface.textures[1] != .highlight) return true;
        const image = switch (surface.textures[0]) {
            .image => |image| image,
            .none, .highlight => return true,
        };
        return image.maps.orm == null or !driver.target.shadesMaterials();
    }

    /// The render states for a pass (`set_material`, `0x10001B20`, and `set_depth`, `0x100018B0`).
    fn state(driver: *Driver, surface: *const srapiext.Surface, pass: u1, layer: Layer) device.State {
        const material = surface.material;
        return .{
            .texture = if (material.coordinates[pass] == .none) null else switch (surface.textures[pass]) {
                .none => null,
                .highlight => |index| &driver.highlights[index],
                .image => |image| image,
            },
            .depth = depth(layer, material.blend[pass]),
            .blend = factors(material.blend[pass]),
            .receives = receives(layer),
        };
    }

    /// The shadows a layer's pixels take: the world's the world's, the overlay's, which holds the
    /// cockpit, the cockpit's, and the background's none.
    fn receives(layer: Layer) device.Receives {
        return switch (layer) {
            .background => .nothing,
            .world => .world,
            .overlay => .cockpit,
        };
    }

    /// `draw_mesh` (`0x10006AD0`): each surface's visible polygons, opaque ones now, the rest put
    /// aside keyed by depth. On the overlay layer, or for an object flagged `sorted`, all of them
    /// sorted and drawn at once.
    fn drawMesh(ptr: *anyopaque, drawn: *const srmesh.Drawn, layer: Layer, blended: *srcore.Blended) Allocator.Error!void {
        const driver = from(ptr);
        if (drawn.object.flags.sorted or layer == .overlay) return driver.drawMeshSorted(drawn, layer, blended.arena);
        var at: usize = 0;
        for (drawn.mesh.surfaces, drawn.counts, 0..) |*surface, count, index| {
            defer at += count;
            if (count == 0) continue;
            const visible = drawn.visible[at..][0..count];
            if (surface.material.blend[0] == .off) {
                try driver.drawPass(drawn, visible, surface, 0, layer);
                if (driver.drawsSecond(surface)) try driver.drawPass(drawn, visible, surface, 1, layer);
            } else {
                for (visible) |v| try blended.add(polygonDeferred(drawn, surface, @intCast(index), v));
            }
        }
    }

    /// `draw_mesh_sorted` (`0x10002D10`).
    fn drawMeshSorted(driver: *Driver, drawn: *const srmesh.Drawn, layer: Layer, arena: Allocator) Allocator.Error!void {
        var list: std.ArrayList(srcore.Deferred) = .empty;
        var at: usize = 0;
        for (drawn.mesh.surfaces, drawn.counts, 0..) |*surface, count, index| {
            defer at += count;
            for (drawn.visible[at..][0..count]) |v| try list.append(arena, polygonDeferred(drawn, surface, @intCast(index), v));
        }
        srcore.depthSort(list.items);
        flushBlended(driver, list.items, layer);
    }

    /// A polygon put aside (`defer_blended`, `0x10002400`), keyed by its corners' mean depth plus
    /// its bias.
    fn polygonDeferred(drawn: *const srmesh.Drawn, surface: *const srapiext.Surface, index: u32, v: srmesh.Visible) srcore.Deferred {
        const mesh = drawn.mesh;
        const p = mesh.polygons[v.polygon];
        var sum: f32 = 0;
        for (mesh.indices[p.first..][0..p.count]) |i| sum += drawn.view[i][2];
        const count: f32 = @floatFromInt(p.count);
        return .{
            .key = if (sum >= 0) srcore.key(sum / count + mesh.biases[v.polygon]) else 0,
            .surface = surface,
            .item = .{ .polygon = .{ .drawn = drawn, .surface = index, .visible = v } },
        };
    }

    /// A corner of a polygon as the driver draws it, `position` its place in the mesh's indices.
    fn corner(drawn: *const srmesh.Drawn, position: usize, material: Material, pass: u1) Vertex {
        const mesh = drawn.mesh;
        const vertex = mesh.indices[position];
        const screen = drawn.screen[vertex];
        return .{
            .x = screen.x,
            .y = screen.y,
            .z = screen.depth,
            .rhw = screen.rhw,
            .diffuse = if (!material.lit[pass]) device.white else if (drawn.colours) |c| device.pack(c[vertex]) else 0,
            .u = coordinates(drawn, position, material, pass)[0],
            .v = coordinates(drawn, position, material, pass)[1],
            .view = drawn.view[vertex],
            .normal = if (drawn.normals) |n| n[vertex] else @splat(0),
            .light_mask = pixelMask(drawn, material, pass),
        };
    }

    fn coordinates(drawn: *const srmesh.Drawn, position: usize, material: Material, pass: u1) [2]f32 {
        if (material.coordinates[pass] == .mesh) {
            if (drawn.mesh.uv[pass]) |uv| return uv[position];
        } else if (drawn.generated[pass]) |g| {
            return g[drawn.mesh.indices[position]];
        }
        return .{ 0, 0 };
    }

    /// `draw_pass` (`0x10002920`): a surface's visible polygons for one pass. A polygon runs on
    /// into the records of its strip or fan after it, while they are visible and unclipped; the lot
    /// is drawn as one list of triangles. Clipped polygons are drawn on their own as they come.
    fn drawPass(driver: *Driver, drawn: *const srmesh.Drawn, visible: []const srmesh.Visible, surface: *const srapiext.Surface, pass: u1, layer: Layer) Allocator.Error!void {
        const gpa = driver.gpa;
        const mesh = drawn.mesh;
        const material = surface.material;
        var st = driver.state(surface, pass, layer);
        st.soft_terminator = drawn.object.soft_terminator;
        driver.vertices.clearRetainingCapacity();
        driver.indices.clearRetainingCapacity();
        var start: usize = 0;
        var k: usize = 0;
        while (k < visible.len) {
            if (visible[k].clip.any()) {
                try driver.drawClipped(drawn, visible[k], material, pass, st);
                k += 1;
                continue;
            }
            var q = visible[k].polygon;
            const kind = mesh.polygons[q].kind;
            var skip: usize = 0;
            while (true) {
                const p = mesh.polygons[q];
                for (skip..p.count) |c| try driver.vertices.append(gpa, corner(drawn, p.first + c, material, pass));
                k += 1;
                if (p.continues == 0) break;
                q += 1;
                if (k >= visible.len or visible[k].clip.any() or visible[k].polygon != q) break;
                skip = 2;
            }
            const count = driver.vertices.items.len;
            switch (kind) {
                .triangle, .fan => {
                    var i = start + 2;
                    while (i < count) : (i += 1) try driver.indices.appendSlice(gpa, &.{ @intCast(start), @intCast(i - 1), @intCast(i) });
                },
                .strip_even, .strip_odd => {
                    var odd = kind == .strip_odd;
                    var i = start + 2;
                    while (i < count) : (i += 1) {
                        const t: [3]u16 = if (odd) .{ @intCast(i - 1), @intCast(i - 2), @intCast(i) } else .{ @intCast(i - 2), @intCast(i - 1), @intCast(i) };
                        try driver.indices.appendSlice(gpa, &t);
                        odd = !odd;
                    }
                },
                .lines => {
                    driver.target.draw(st, .lines, driver.vertices.items[start..], null);
                    driver.vertices.shrinkRetainingCapacity(start);
                    continue;
                },
                _ => {},
            }
            start = driver.vertices.items.len;
        }
        if (driver.indices.items.len == 0) return;
        if (hidesSun(drawn, material, pass)) {
            var t: usize = 0;
            while (t < driver.indices.items.len and driver.context.sun_visibility > 0) : (t += 3) {
                const i = driver.indices.items[t..][0..3];
                driver.sunTest(driver.vertices.items[i[0]], driver.vertices.items[i[1]], driver.vertices.items[i[2]]);
            }
        }
        driver.target.draw(st, .triangles, driver.vertices.items, driver.indices.items);
    }

    /// `flush_blended` (`0x10003390`): every first pass, then the second passes of two-pass
    /// materials.
    fn flushBlended(ptr: *anyopaque, list: []const srcore.Deferred, layer: Layer) void {
        const driver = from(ptr);
        for (list) |item| driver.drawDeferred(item, 0, layer);
        for (list) |item| {
            if (driver.drawsSecond(item.surface)) driver.drawDeferred(item, 1, layer);
        }
    }

    fn drawDeferred(driver: *Driver, item: srcore.Deferred, pass: u1, layer: Layer) void {
        const st = driver.state(item.surface, pass, layer);
        const material = item.surface.material;
        switch (item.item) {
            .polygon => |p| {
                if (p.visible.clip.any()) {
                    driver.drawClipped(p.drawn, p.visible, material, pass, st) catch {};
                } else {
                    driver.drawPolygon(p.drawn, p.visible, material, pass, st) catch {};
                }
            },
            .sprite => |s| driver.drawSprite(s.drawn, s.index, material, pass, st),
            .stars => |stars| driver.drawStarPoints(stars, material, pass, st),
        }
    }

    /// `draw_polygon` (`0x10006F90`): one polygon as a fan, or its lines. **Improvement:** the
    /// driver tests a sorted polygon's triangles against the sun with indices left over from the
    /// last list it drew; OpenReliant tests the polygon's own, where it is solid (`hidesSun`).
    fn drawPolygon(driver: *Driver, drawn: *const srmesh.Drawn, v: srmesh.Visible, material: Material, pass: u1, st: device.State) Allocator.Error!void {
        const p = drawn.mesh.polygons[v.polygon];
        driver.single.clearRetainingCapacity();
        for (0..p.count) |c| try driver.single.append(driver.gpa, corner(drawn, p.first + c, material, pass));
        const vertices = driver.single.items;
        if (p.kind == .lines) return driver.target.draw(st, .lines, vertices, null);
        driver.target.draw(st, .fan, vertices, null);
        if (hidesSun(drawn, material, pass)) driver.sunTestFan(vertices);
    }

    /// `draw_clipped` (`0x10003100`): a polygon clipped triangle by triangle, each piece drawn as a
    /// fan.
    fn drawClipped(driver: *Driver, drawn: *const srmesh.Drawn, v: srmesh.Visible, material: Material, pass: u1, st: device.State) Allocator.Error!void {
        const mesh = drawn.mesh;
        const p = mesh.polygons[v.polygon];
        const lines = p.kind == .lines;
        const pieces: usize = if (lines) p.count -| 1 else p.count -| 2;
        for (0..pieces) |t| {
            var polygon: [srclip.capacity]srclip.Vertex = undefined;
            const positions: []const usize = if (lines) &.{ p.first, p.first + 1 } else &.{ p.first, p.first + t + 1, p.first + t + 2 };
            for (positions, 0..) |position, i| polygon[i] = clipCorner(drawn, position);
            const portal = if (drawn.object.portal) |portal| portal.view else null;
            const count = srclip.clip(driver.context.projection, v.clip, portal, &polygon, positions.len);
            if (count < (if (lines) @as(usize, 2) else 3)) continue;
            driver.single.clearRetainingCapacity();
            for (polygon[0..count]) |c| {
                const screen = driver.context.projection.transform(c.view);
                const uv = if (material.coordinates[pass] == .mesh) c.mesh_uv[pass] else c.generated[pass];
                try driver.single.append(driver.gpa, .{
                    .x = screen.x,
                    .y = screen.y,
                    .z = screen.depth,
                    .rhw = screen.rhw,
                    .diffuse = if (material.lit[pass]) device.pack(c.colour) else device.white,
                    .u = uv[0],
                    .v = uv[1],
                    .view = c.view,
                    .normal = c.normal,
                    .light_mask = pixelMask(drawn, material, pass),
                });
            }
            const vertices = driver.single.items;
            if (lines) {
                driver.target.draw(st, .lines, vertices[0..2], null);
                continue;
            }
            driver.target.draw(st, .fan, vertices, null);
            if (hidesSun(drawn, material, pass)) driver.sunTestFan(vertices);
        }
    }

    /// A corner of a polygon as the clipper takes it.
    fn clipCorner(drawn: *const srmesh.Drawn, position: usize) srclip.Vertex {
        const mesh = drawn.mesh;
        const vertex = mesh.indices[position];
        var c: srclip.Vertex = .{
            .view = drawn.view[vertex],
            .colour = if (drawn.colours) |colours| colours[vertex] else @splat(0),
            .mesh_uv = @splat(.{ 0, 0 }),
            .generated = @splat(.{ 0, 0 }),
            .normal = if (drawn.normals) |n| n[vertex] else @splat(0),
        };
        for (0..2) |pass| {
            if (mesh.uv[pass]) |uv| c.mesh_uv[pass] = uv[position];
            if (drawn.generated[pass]) |g| c.generated[pass] = g[vertex];
        }
        return c;
    }

    /// `draw_sprites` (`0x10006BF0`): with a blended material, each sprite put aside keyed by its
    /// depth plus its bias, to be drawn with its own material (`draw_blended_sprite`,
    /// `0x10007200`); else each drawn now with the set's.
    fn drawSprites(ptr: *anyopaque, drawn: *const srbmo.Drawn, layer: Layer, blended: *srcore.Blended) Allocator.Error!void {
        const driver = from(ptr);
        const surface = &drawn.set.surface;
        if (surface.material.blend[0] != .off) {
            for (drawn.sprites, 0..) |p, index| {
                const sprite = drawn.set.sprites[p.index];
                try blended.add(.{
                    .key = srcore.key(p.depth + sprite.bias),
                    .surface = sprite.surface orelse surface,
                    .item = .{ .sprite = .{ .drawn = drawn, .index = @intCast(index) } },
                });
            }
            return;
        }
        const st = driver.state(surface, 0, layer);
        for (0..drawn.sprites.len) |index| driver.drawSprite(drawn, @intCast(index), surface.material, 0, st);
    }

    /// `draw_sprite` (`0x10007220`): a sprite's rectangle, cut to the view, as a strip of two
    /// triangles at its depth.
    fn drawSprite(driver: *Driver, drawn: *const srbmo.Drawn, index: u32, material: Material, pass: u1, st: device.State) void {
        const projection = driver.context.projection;
        const p = drawn.sprites[index];
        const sprite = drawn.set.sprites[p.index];
        const rect, const uv = srbmo.cut(p.rect, sprite.uv, projection.bounds);
        const left, const top = projection.toScreen(.{ rect[0], rect[1] });
        const right, const bottom = projection.toScreen(.{ rect[2], rect[3] });
        const z = @sqrt(p.reciprocal) * projection.depth_scale;
        const f = sprite.fade;
        var colour = device.pack(.{ f, f, f, f });
        if (material.lit[0]) colour = device.pack(.{ sprite.colour[0] * f, sprite.colour[1] * f, sprite.colour[2] * f, 0 });
        if (!material.lit[pass]) colour = device.pack(.{ f, f, f, f });
        const vertices = [4]Vertex{
            .{ .x = left, .y = top, .z = z, .rhw = sprite_rhw, .diffuse = colour, .u = uv[0], .v = uv[2] },
            .{ .x = right, .y = top, .z = z, .rhw = sprite_rhw, .diffuse = colour, .u = uv[1], .v = uv[2] },
            .{ .x = left, .y = bottom, .z = z, .rhw = sprite_rhw, .diffuse = colour, .u = uv[0], .v = uv[3] },
            .{ .x = right, .y = bottom, .z = z, .rhw = sprite_rhw, .diffuse = colour, .u = uv[1], .v = uv[3] },
        };
        driver.target.draw(st, .strip, &vertices, null);
    }

    /// The reciprocal depth `draw_sprite` (`0x10007220`) gives every corner of a sprite, which
    /// faces the camera flat: a number in its code.
    const sprite_rhw: f32 = 0.5;

    /// How bright `draw_star_points` draws a star's tail against its head (`0x1002041C`).
    const tail_brightness: f32 = 0.5;

    /// `draw_stars` (`0x10006C80`): with a blended material, the whole field put aside with key 0;
    /// else drawn now.
    fn drawStars(ptr: *anyopaque, drawn: *const srstars.Drawn, layer: Layer, blended: *srcore.Blended) Allocator.Error!void {
        const driver = from(ptr);
        const surface = &drawn.field.surface;
        if (surface.material.blend[0] != .off) {
            return blended.add(.{ .key = 0, .surface = surface, .item = .{ .stars = drawn } });
        }
        driver.drawStarPoints(drawn, surface.material, 0, driver.state(surface, 0, layer));
    }

    /// `draw_star_points` (`0x10007450`): each visible star a point, or, moved more than a pixel
    /// since last frame, a line back to where it was with the tail at half brightness.
    fn drawStarPoints(driver: *Driver, drawn: *const srstars.Drawn, material: Material, pass: u1, st: device.State) void {
        const projection = driver.context.projection;
        for (drawn.visible) |star| {
            const colour = drawn.field.stars[star.index].colour;
            var lit: [3]f32 = undefined;
            for (&lit, colour) |*c, x| c.* = x * star.brightness;
            const now = projection.toScreen(star.now);
            const before = projection.toScreen(star.before);
            var head: Vertex = .{ .x = now[0], .y = now[1], .z = 0, .rhw = 0, .diffuse = device.pack(.{ lit[0], lit[1], lit[2], 0 }) };
            if (!material.lit[pass]) head.diffuse = device.white;
            const dx = now[0] - before[0];
            const dy = now[1] - before[1];
            if (dx * dx + dy * dy > 1) {
                const dim = tail_brightness;
                var tail: Vertex = .{ .x = before[0], .y = before[1], .z = 0, .rhw = 0, .diffuse = device.pack(.{ lit[0] * dim, lit[1] * dim, lit[2] * dim, 0 }) };
                if (!material.lit[pass]) tail.diffuse = device.white;
                driver.target.draw(st, .lines, &.{ head, tail }, null);
            } else {
                driver.target.draw(st, .points, &.{head}, null);
            }
        }
    }

    /// Whether a polygon's first pass, drawn with `material`, is tested against the sun: an object
    /// flagged `sun_occluder` has its polygons tested. **Improvement:** only a solid one, which
    /// blends with nothing; OpenReliant lets the sun through what is blended, such as a canopy's
    /// glass.
    fn hidesSun(drawn: *const srmesh.Drawn, material: Material, pass: u1) bool {
        return pass == 0 and drawn.object.flags.sun_occluder and material.blend[0] == .off;
    }

    /// Each triangle of the fan of `vertices` against the sun (`sunTest`), until the sun is hidden.
    fn sunTestFan(driver: *Driver, vertices: []const Vertex) void {
        var i: usize = 2;
        while (i < vertices.len and driver.context.sun_visibility > 0) : (i += 1) driver.sunTest(vertices[0], vertices[i - 1], vertices[i]);
    }

    /// `sun_test` (`0x10001FD0`): lessens the sun's visibility to a triangle's nearest edge,
    /// measured across plus down, or to 0 when the triangle covers the sun's point. It stops at the
    /// first edge no nearer than the visibility.
    fn sunTest(driver: *Driver, a: Vertex, b: Vertex, c: Vertex) void {
        const sun = driver.context.sun;
        const visibility = &driver.context.sun_visibility;
        const v = visibility.*;
        const xs = [3]f32{ a.x, b.x, c.x };
        const ys = [3]f32{ a.y, b.y, c.y };
        const near_x = (xs[0] - v <= sun[0] or xs[1] - v <= sun[0] or xs[2] - v <= sun[0]) and
            (sun[0] <= v + xs[0] or sun[0] <= v + xs[1] or sun[0] <= v + xs[2]);
        const near_y = (ys[0] - v <= sun[1] or ys[1] - v <= sun[1] or ys[2] - v <= sun[1]) and
            (sun[1] <= v + ys[0] or sun[1] <= v + ys[1] or sun[1] <= v + ys[2]);
        if (!(near_x and near_y)) return;
        var inner: u32 = 0;
        for (0..3) |i| {
            const j = (i + 1) % 3;
            const ex = xs[j] - xs[i];
            const ey = ys[j] - ys[i];
            const fx = sun[0] - xs[i];
            const fy = sun[1] - ys[i];
            if (fy * ex - fx * ey < 0) {
                inner += 1;
                continue;
            }
            const along = fx * ex + fy * ey;
            if (!(0 < along)) continue;
            const length = ex * ex + ey * ey;
            const t = if (along < length) along / length else 1;
            const distance = @abs(t * ey - fy) + @abs(t * ex - fx);
            if (visibility.* <= distance) return;
            visibility.* = distance;
        }
        if (inner == 3) visibility.* = 0;
    }
};

test "a frame from the scene to the device" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var screen: @import("software.zig").Software = try .init(gpa, 64, 48);
    defer screen.deinit(gpa);
    var driver: Driver = try .init(gpa, screen.interface());
    defer driver.deinit();

    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    const levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = 50000 }};
    var object: srapiext.MeshObject = .{ .flags = .{ .lit = true }, .position = .{ 0, 0, 1000 }, .radius = mesh.radius, .levels = &levels };

    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try scene.layers.getPtr(.world).append(gpa, .{ .mesh = &object });
    try scene.lights.append(gpa, .{ .mask = 0x04, .intensity = 1, .colour = .{ 0.25, 0.25, 0.25 }, .kind = .ambient });
    var context: srapi.Context = .{ .projection = .init(64, 48, srapi.full_screen, .{ 0.6, 0.8 }) };

    try srcore.render(arena, &context, &scene, driver.interface(), null);
    // The square covers the middle, lit by the ambient light alone.
    const middle = screen.colour[24 * 64 + 32];
    for (middle) |c| try std.testing.expectApproxEqAbs(64.0 / 255.0, c, 1e-5);
    try std.testing.expect(screen.depth[24 * 64 + 32] > 0);
    // The corners stay black.
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, screen.colour[0]);

    // Moved across the near plane, it is clipped, not dropped: the middle is still drawn.
    object.position = .{ 0, 0, 120 };
    object.orientation = math.rotation(.y, 1.2);
    try srcore.render(arena, &context, &scene, driver.interface(), null);
    var lit: usize = 0;
    for (screen.colour) |c| lit += @intFromBool(c[0] > 0);
    try std.testing.expect(lit > 0);
}

test "a pass keeps what it gathers while it clips a polygon" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var screen: @import("software.zig").Software = try .init(gpa, 64, 48);
    defer screen.deinit(gpa);
    var driver: Driver = try .init(gpa, screen.interface());
    defer driver.deinit();

    // Three triangles facing the camera: one to the left, one above the middle through the near
    // plane, one to the right. The pass gathers the first, clips the second, and draws the first
    // with the third.
    var positions = [_]math.Vector{
        .{ -300, -100, 1000 }, .{ -100, 100, 1000 }, .{ -100, -100, 1000 },
        .{ 0, -20, 60 },       .{ -40, -150, 600 },  .{ 40, -150, 600 },
        .{ 100, -100, 1000 },  .{ 300, 100, 1000 },  .{ 300, -100, 1000 },
    };
    var normals: [9]math.Vector = @splat(.{ 0, 0, -1 });
    var polygons = [_]srapiext.Polygon{
        .{ .kind = .triangle, .continues = 0, .first = 0, .count = 3 },
        .{ .kind = .triangle, .continues = 0, .first = 3, .count = 3 },
        .{ .kind = .triangle, .continues = 0, .first = 6, .count = 3 },
    };
    var indices = [_]u16{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    var planes: [3]srapiext.Plane = undefined;
    var biases = [_]f32{ 0, 0, 0 };
    var surfaces = [_]srapiext.Surface{.{
        .polygons = 3,
        .material = .onePass(.{ .coordinates = .none, .lit = false, .blend = .off }),
    }};
    var mesh: srapiext.Mesh = .{
        .positions = &positions,
        .normals = &normals,
        .polygons = &polygons,
        .indices = &indices,
        .uv = .{ null, null },
        .planes = &planes,
        .biases = &biases,
        .surfaces = &surfaces,
        .bounds = undefined,
        .radius = undefined,
    };
    srapi.calcPolyNormals(&mesh);
    srapi.findBoundingBox(&mesh);
    const levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};
    var object: srapiext.MeshObject = .{ .flags = .{}, .position = @splat(0), .radius = mesh.radius, .levels = &levels };

    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try scene.layers.getPtr(.world).append(gpa, .{ .mesh = &object });
    var context: srapi.Context = .{ .projection = .init(64, 48, srapi.full_screen, .{ 0.6, 0.8 }) };
    try srcore.render(arena, &context, &scene, driver.interface(), null);

    // Unlit, the triangles draw white, each where it lies; below the middle stays black.
    for ([_][2]usize{ .{ 26, 22 }, .{ 42, 22 }, .{ 32, 14 } }) |at| {
        try std.testing.expectApproxEqAbs(1, screen.colour[at[1] * 64 + at[0]][0], 1e-5);
    }
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, screen.colour[40 * 64 + 32]);
}

test "a device that lights each pixel" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Takes as many of the frame's lights as it has room for, and keeps what it draws.
    var recorder: device.testing.Recorder = .{ .gpa = gpa, .room = 4 };
    defer recorder.deinit();
    var driver: Driver = try .init(gpa, recorder.interface());
    defer driver.deinit();

    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    const levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = 50000 }};
    var object: srapiext.MeshObject = .{ .flags = .{ .lit = true }, .position = .{ 0, 0, 1000 }, .radius = mesh.radius, .levels = &levels, .light_mask = 0x02 };

    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try scene.layers.getPtr(.world).append(gpa, .{ .mesh = &object });
    try scene.lights.append(gpa, .{ .mask = 0x04, .intensity = 1, .colour = .{ 0.25, 0.25, 0.25 }, .kind = .ambient });
    try scene.lights.append(gpa, .{ .mask = 0x01, .intensity = 0.5, .colour = .{ 1, 1, 1 }, .kind = .{ .directional = .{ 0, 0, -2 } } });
    try scene.lights.append(gpa, .{ .mask = 0x08, .intensity = 2, .colour = .{ 1, 0.5, 0 }, .kind = .{ .point = .{ .position = .{ 0, 0, 900 }, .range = 100 } } });
    var context: srapi.Context = .{ .projection = .init(64, 48, srapi.full_screen, .{ 0.6, 0.8 }) };
    context.camera.position = .{ 10, 0, 0 };

    try srcore.render(arena, &context, &scene, driver.interface(), null);
    try std.testing.expect(context.pixel_lighting);
    // The directional light first, then the point light, in the camera's frame: the direction
    // made as long as the intensity, the point's reach scaled by it.
    const lights = recorder.lights.items;
    try std.testing.expectEqual(2, lights.len);
    try std.testing.expectEqual(0x01, lights[0].mask);
    try std.testing.expectEqual([3]f32{ 0, 0, -0.5 }, lights[0].kind.directional.toward);
    try std.testing.expectEqual(0x08, lights[1].mask);
    try std.testing.expectEqual(math.Vector{ -10, 0, 900 }, lights[1].kind.point.position);
    try std.testing.expectEqual(200, lights[1].kind.point.reach);
    try std.testing.expectEqual([3]f32{ 1, 0.5, 0 }, lights[1].kind.point.colour);
    try std.testing.expectEqual(2, lights[1].kind.point.intensity);
    // The vertices come with the ambient light alone, their normals and their object's mask.
    try std.testing.expect(recorder.last().len > 0);
    for (recorder.last()) |v| {
        try std.testing.expectEqual(device.pack(.{ 0.25, 0.25, 0.25, 0 }), v.diffuse);
        try std.testing.expectEqual([3]f32{ 0, 0, -1 }, v.normal);
        try std.testing.expectEqual(0x02, v.light_mask);
        try std.testing.expectEqual(1000, v.view[2]);
    }

    // With room for one, the device takes the directional light, and the point light is added to
    // each vertex: a corner within its reach and facing it is redder than the ambient light.
    recorder.room = 1;
    try srcore.render(arena, &context, &scene, driver.interface(), null);
    try std.testing.expectEqual(2, recorder.lights.items.len);
    var reddened: usize = 0;
    for (recorder.last()) |v| {
        try std.testing.expectEqual(0x02, v.light_mask);
        const colour: device.Diffuse = @bitCast(v.diffuse);
        try std.testing.expectEqual(64, colour.blue);
        reddened += @intFromBool(colour.red > 64);
    }
    try std.testing.expect(reddened > 0);
    // With no room, every light goes to the vertices.
    recorder.room = 0;
    try srcore.render(arena, &context, &scene, driver.interface(), null);
    try std.testing.expect(!context.pixel_lighting);
    for (recorder.last()) |v| try std.testing.expectEqual(device.no_lights, v.light_mask);
    recorder.room = 4;

    // A pass that is not lit takes no lights.
    mesh.surfaces[0].material.lit[0] = false;
    try srcore.render(arena, &context, &scene, driver.interface(), null);
    for (recorder.last()) |v| {
        try std.testing.expectEqual(device.white, v.diffuse);
        try std.testing.expectEqual(device.no_lights, v.light_mask);
    }
}

test depth {
    try std.testing.expectEqual(Depth{ .testing = true, .writing = true }, depth(.world, .off));
    try std.testing.expectEqual(Depth{ .testing = true, .writing = false }, depth(.world, .add));
    try std.testing.expectEqual(Depth{ .testing = false, .writing = false }, depth(.background, .off));
    try std.testing.expectEqual(Depth{ .testing = false, .writing = false }, depth(.overlay, .alpha));
}

test factors {
    try std.testing.expectEqual(null, factors(.off));
    try std.testing.expectEqual(Factors{ .source = .one, .destination = .one }, factors(.add).?);
    try std.testing.expectEqual(
        Factors{ .source = .source_alpha, .destination = .inverse_source_alpha },
        factors(.alpha).?,
    );
    try std.testing.expectEqual(null, factors(@enumFromInt(9)));
}

test shade {
    try std.testing.expectEqual([4]f32{ 0.25, 0.5, 0.5, 1 }, shade(.{ 0.5, 1, 1, 1 }, .{ 0.5, 0.5, 0.5, 1 }, true));
    try std.testing.expectEqual([4]f32{ 0.5, 1, 1, 1 }, shade(.{ 0.5, 1, 1, 1 }, .{ 0.5, 0.5, 0.5, 1 }, false));
    try std.testing.expectEqual([4]f32{ 0.5, 0.5, 0.5, 1 }, shade(null, .{ 0.5, 0.5, 0.5, 1 }, true));
}

test blend {
    try std.testing.expectEqual([3]f32{ 0.5, 0.5, 0.5 }, blend(factors(.off), .{ 0.5, 0.5, 0.5, 0 }, .{ 1, 1, 1 }));
    try std.testing.expectEqual([3]f32{ 0.75, 1, 1 }, blend(factors(.add), .{ 0.5, 0.5, 0.5, 0 }, .{ 0.25, 0.75, 1 }));
    try std.testing.expectEqual([3]f32{ 0.5, 0.5, 0.5 }, blend(factors(.alpha), .{ 1, 1, 1, 0.5 }, .{ 0, 0, 0 }));
}

test highlightTexel {
    // The centre, bright to saturated as the exponent grows, then dimmer for the upper four.
    const centres = [8]u8{ 48, 95, 238, 255, 13, 46, 147, 255 };
    for (centres, 0..) |grey, index| {
        try std.testing.expectEqual([4]u8{ grey, grey, grey, 255 }, highlightTexel(@intCast(index), 32, 32));
    }
    // Outside the circle only the floor is left: black, partly opaque.
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 85 }, highlightTexel(0, 0, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 58 }, highlightTexel(7, 0, 0));
    // Along a radius: sharper exponents fall off sooner.
    try std.testing.expectEqual([4]u8{ 24, 24, 24, 255 }, highlightTexel(0, 40, 32));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 217 }, highlightTexel(3, 40, 32));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 126 }, highlightTexel(1, 56, 32));
}

test highlight {
    const texels = highlight(2);
    try std.testing.expectEqual(highlightTexel(2, 5, 60), texels[60][5]);
    // Symmetric about the centre texel.
    try std.testing.expectEqual(texels[32][20], texels[20][32]);
    try std.testing.expectEqual(texels[32][20], texels[32][44]);
}
