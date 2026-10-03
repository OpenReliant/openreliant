//! Part of `C:\lancer\game\wgate.cpp`: the meshes of the gates' tunnels. A tunnel (`Tunnel`) is a
//! funnel of rings round its axis, on the game's grid by the options' detail (`Grid`) or on one
//! split finer (`Tunnels`), coloured ring by ring (`Palette`), and wiped through as its gate
//! collapses (`Wipe`); a ship jumping in through it shows two flashes at its throat (`Square`). The
//! worm (`worm.zig`) is a tube built the same way.
//! [Gates](../../../../docs/engine/gates.md#the-tunnel) describes them.
//!
//! **Unverified:** the file of the tunnel's colours and the easings beside them (`0x0041D7D0` to
//! `0x0041DD6F`), which lie between `tractor.cpp`'s known code and this file's, and do this
//! file's work.
//!
//! **Improvement:** the sines and cosines come from `std.math` rather than the engine's tables
//! (`sr_sin`, `sr_cos`).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const ease = @import("../../genilib/interf/ease.zig");
const loadout = @import("../../interface/loadout/loadout.zig");
const Detail = @import("../explode.zig").Detail;

/// What a tunnel serves, its record's kind (`+0x00`).
pub const Kind = enum(u32) {
    /// A ship's independent warp tunnel (`order_warp_out`, `order_warp_in`).
    warp = 0,
    /// A fixed gate's, while no advanced gate is among the objects: blue.
    proto = 1,
    /// A fixed gate's, with an advanced gate among the objects: red.
    advanced = 2,
    /// The Boridin's projection's, not ported
    /// ([#30](https://github.com/OpenReliant/openreliant/issues/30)).
    boridin = 3,
};

/// How many segments a tunnel has round (`0x004E3F50`) and how many rings along
/// (`0x004E3F5C`), by the options' detail, which the gates' start takes (`0x0041E280`); and how
/// a tube's vertices are numbered on it.
pub const Grid = struct {
    segments: usize,
    rings: usize,

    pub fn of(detail: Detail) Grid {
        return switch (detail) {
            .low => .{ .segments = 9, .rings = 6 },
            .medium => .{ .segments = 12, .rings = 8 },
            .high => .{ .segments = 16, .rings = 12 },
        };
    }

    /// The vertices of a tunnel: a ring of `segments` for each of `rings + 1` rings, after the
    /// centre.
    pub fn vertices(grid: Grid) usize {
        return (grid.rings + 1) * grid.segments + 1;
    }

    /// Its triangles: two for each segment between two rings.
    pub fn polygons(grid: Grid) usize {
        return grid.rings * grid.segments * 2;
    }

    /// The ring the portal and the jumps' flashes stand at, five short of the last (`0x0041FDF0`).
    pub fn throat(grid: Grid) usize {
        return grid.rings - throat_back;
    }

    const throat_back = 5;

    /// The grid each of whose bands is split `split` ways round and along.
    pub fn finer(grid: Grid, split: usize) Grid {
        return .{ .segments = grid.segments * split, .rings = grid.rings * split };
    }

    /// The vertex of ring `ring` at segment `segment`, after the centre.
    pub fn vertex(grid: Grid, ring: usize, segment: usize) usize {
        return 1 + ring * grid.segments + segment;
    }

    /// The ring and the segment of vertex `number` (`vertex`); null for the centre.
    pub fn place(grid: Grid, number: usize) ?Place {
        if (number == 0) return null;
        return .{ .ring = (number - 1) / grid.segments, .segment = (number - 1) % grid.segments };
    }

    pub const Place = struct { ring: usize, segment: usize };

    /// Whether ring `ring` is the mouth or the last, which a tube's colours leave black and clear.
    pub fn edge(grid: Grid, ring: usize) bool {
        return ring == 0 or ring == grid.rings;
    }

    /// The most vertices a grid of the game's has, at the high detail.
    const most_vertices = of(.high).vertices();
};

comptime {
    for (std.enums.values(Detail)) |detail| {
        assert(Grid.of(detail).rings > Grid.throat_back);
        assert(Grid.of(detail).vertices() <= Grid.most_vertices);
        // The meshes number their vertices in 16 bits, however finely a tunnel is built.
        for (std.enums.values(Tunnels)) |tunnels| {
            assert(Grid.of(detail).finer(tunnels.split()).vertices() <= std.math.maxInt(u16));
        }
    }
}

/// How finely a tunnel is built.
pub const Tunnels = enum {
    /// **Improvement:** each of the game's bands split `fine_split` ways round and along, its rings
    /// a `fine_split`th as far apart so that the tunnel keeps its length. The rings' radii and
    /// depths follow the game's curves between the game's rings, so that the tunnel is round and
    /// its rings' wave smooth, and the sway and the colours run between the game's vertices', as
    /// the game's are drawn between them (`Corners`).
    fine,
    /// On the game's grid, by the options' detail (`Grid`).
    original,

    /// How many ways each of the game's bands is split round and along.
    pub fn split(tunnels: Tunnels) usize {
        return switch (tunnels) {
            .fine => fine_split,
            .original => 1,
        };
    }
};

const fine_split = 4;

/// The four vertices of the game's grid about a vertex of a tunnel drawn on a grid `split` times as
/// fine (`Tunnels`), and how much each counts toward it: in a straight line between them, round and
/// along, as the game's vertices' values are drawn between them.
const Corners = struct {
    vertices: [4]usize = @splat(0),
    weights: [4]f32 = .{ 1, 0, 0, 0 },

    /// The corners of drawn vertex `vertex`; the centre's is the game's centre.
    fn of(grid: Grid, split: usize, vertex: usize) Corners {
        const at = grid.finer(split).place(vertex) orelse return .{};
        const near = at.ring / split;
        const far = @min(near + 1, grid.rings);
        const first = at.segment / split;
        const next = (first + 1) % grid.segments;
        const along = share(at.ring % split, split);
        const round = share(at.segment % split, split);
        return .{
            .vertices = .{ grid.vertex(near, first), grid.vertex(near, next), grid.vertex(far, first), grid.vertex(far, next) },
            .weights = .{ (1 - along) * (1 - round), (1 - along) * round, along * (1 - round), along * round },
        };
    }

    /// The sum of `values`' values at the corners, each by its weight, as a vector `V`.
    fn blend(corners: Corners, comptime V: type, values: anytype) V {
        var sum: V = @splat(0);
        for (corners.vertices, corners.weights) |vertex, weight| sum += @as(V, values[vertex]) * @as(V, @splat(weight));
        return sum;
    }
};

/// `part` over `whole`: how far along the game's rings drawn ring `part` stands where each of the
/// game's bands is split `whole` ways along, or how far along a tunnel ring `part` of `whole`
/// stands, from 0 at the mouth to 1 at the last.
fn share(part: usize, whole: usize) f32 {
    return @as(f32, @floatFromInt(part)) / @as(f32, @floatFromInt(whole));
}

/// A tunnel (`0x0041DD70`): a funnel of rings, `Grid.segments` round, the widest at the mouth,
/// drawn with the gates' texture by coordinates of its own and colours of its own, and a second
/// pass of a highlight texture by its normals. Its last band is drawn in one pass.
pub const Tunnel = struct {
    mesh: srapiext.Mesh,
    level: [1]srapiext.Level,
    object: srapiext.MeshObject,
    /// The game's grid, and how many ways each of its bands is split round and along to draw the
    /// tunnel (`Tunnels`).
    grid: Grid,
    split: usize,
    /// Each of the game's vertices' colour (`+0x110`), and each drawn vertex's, laid out from them
    /// (`lay`).
    colours: [][4]f32,
    drawn_colours: [][4]f32,
    /// Each drawn ring's radius (the record's `+0x30`, for the game's rings) and its depth
    /// (`+0x7C`).
    radii: []f32,
    depths: []f32,

    /// `0x0041DD70`: a tunnel of `kind`, `size` across (`ringRadius`), on `grid` with each of its
    /// bands split `split` ways (`Tunnels`), drawn with `image` and, for a `hardware` renderer, its
    /// highlight and its colours (`colour`).
    pub fn build(tunnel: *Tunnel, gpa: Allocator, grid: Grid, split: usize, hardware: bool, image: *srtexture.Image, kind: Kind, size: f32) Allocator.Error!void {
        const drawn = grid.finer(split);
        const polygons = drawn.polygons();
        var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = polygons, .vertices = drawn.vertices(), .indices = polygons * 3, .surfaces = 2 });
        errdefer mesh.deinit(gpa);
        const radii = try gpa.alloc(f32, drawn.rings + 1);
        errdefer gpa.free(radii);
        const depths = try gpa.alloc(f32, drawn.rings + 1);
        errdefer gpa.free(depths);
        @memset(depths, 0);
        const colours = try gpa.alloc([4]f32, grid.vertices());
        errdefer gpa.free(colours);
        @memset(colours, @splat(0));
        const drawn_colours = try gpa.alloc([4]f32, drawn.vertices());
        errdefer gpa.free(drawn_colours);
        for (radii, 0..) |*radius, ring| radius.* = ringRadius(kind, grid.rings, share(ring, split), size);
        for (0..drawn.rings + 1) |ring| {
            for (0..drawn.segments) |segment| {
                const turn = segmentTurn(segment, drawn.segments);
                mesh.positions[drawn.vertex(ring, segment)] = .{ @sin(turn) * radii[ring], @cos(turn) * radii[ring], 0 };
            }
        }
        const uv = try mesh.addCoordinates(gpa);
        numberBands(&mesh, drawn);
        for (mesh.indices, uv) |index, *pair| pair.* = coordinatesOf(grid, split, index);
        // The game's last band, however finely it is split.
        tubeSurfaces(&mesh, 2 * drawn.segments * split, image, highlightOf(kind), hardware, .add);
        tunnel.* = .{
            .mesh = mesh,
            .level = undefined,
            .object = undefined,
            .grid = grid,
            .split = split,
            .colours = colours,
            .drawn_colours = drawn_colours,
            .radii = radii,
            .depths = depths,
        };
        tunnel.level = .{.{ .mesh = &tunnel.mesh, .until = std.math.inf(f32) }};
        tunnel.object = .{
            .flags = .{ .normals_second = true, .not_culled = true, .unbounded = true, .owns_mesh = true, .baked_object = true },
            .position = @splat(0),
            .radius = mesh.radius,
            .levels = &tunnel.level,
            .baked = drawn_colours,
        };
        tunnel.colour(kind, hardware);
    }

    pub fn deinit(tunnel: *Tunnel, gpa: Allocator) void {
        tunnel.mesh.deinit(gpa);
        gpa.free(tunnel.colours);
        gpa.free(tunnel.drawn_colours);
        gpa.free(tunnel.radii);
        gpa.free(tunnel.depths);
    }

    /// The grid it is drawn on.
    fn drawnGrid(tunnel: *const Tunnel) Grid {
        return tunnel.grid.finer(tunnel.split);
    }

    /// Where the throat's ring (`Grid.throat`) meets the first segment, as the tunnel stands now
    /// (`0x0041FDF0`).
    pub fn throat(tunnel: *const Tunnel) Vector {
        return tunnel.mesh.positions[tunnel.drawnGrid().vertex(tunnel.grid.throat() * tunnel.split, 0)];
    }

    /// Each drawn vertex's colour from the game's vertices' about it (`Corners`).
    fn lay(tunnel: *Tunnel) void {
        for (tunnel.drawn_colours, 0..) |*shade, vertex| shade.* = Corners.of(tunnel.grid, tunnel.split, vertex).blend(@Vector(4, f32), tunnel.colours);
    }

    /// `0x0041D7D0`: each ring's colour on each of its vertices (`ringShade`). The mouth's and the
    /// last ring are black and clear, and the ring before the last is the tunnel's deep colour.
    /// Between them a hardware renderer's tunnel runs from the mouth's colour to the middle's in a
    /// straight line over the first `palette_turn` of the rings, then to the end's by the square
    /// root (`Palette.at`): a proto gate's blue, an advanced gate's red. A software renderer's runs
    /// from white down to black, and its ring before the last is a mid grey.
    pub fn colour(tunnel: *Tunnel, kind: Kind, hardware: bool) void {
        const grid = tunnel.grid;
        const palette: Palette = if (kind == .advanced) .red else .blue;
        for (0..grid.rings + 1) |ring| {
            const along = share(ring, grid.rings);
            const shade = if (hardware)
                ringShade(grid, ring, srapiext.solid(palette.last), srapiext.solid(palette.at(along)))
            else
                ringShade(grid, ring, software_last, srapiext.grey(ease.linear(1, 0, along)));
            fillRing(tunnel.colours, grid, ring, shade);
        }
        tunnel.lay();
    }

    /// What the gates' frame does with the tunnel (`0x00420A00`), `since` after it was made as the
    /// gates count time: its rings sway (`swayRings`), its vertices follow, `deeper` deeper
    /// (`shape`), and its lighting, its bounds and its radius follow them.
    pub fn reshape(tunnel: *Tunnel, kind: Kind, since: f32, frame_start: i32, deeper: f32) void {
        tunnel.swayRings(since);
        tunnel.reshapeWith(kind, frame_start, deeper);
    }

    /// Updates mesh lighting and bounds after placing the rings.
    fn reshapeWith(tunnel: *Tunnel, kind: Kind, frame_start: i32, deeper: f32) void {
        tunnel.shape(kind, frame_start, deeper);
        srapi.calcPolyNormals(&tunnel.mesh);
        srapi.calcVertexNormals(&tunnel.mesh);
        srapi.findBoundingBox(&tunnel.mesh);
        tunnel.object.radius = tunnel.mesh.radius;
    }

    /// Shapes a warp from radii and depths updated by its order. Fixed-gate sway must not
    /// overwrite these values (`order_warp_out`, `order_warp_in`, `wgate_tunnel_shape`).
    pub fn reshapeWarp(tunnel: *Tunnel, frame_start: i32, deeper: f32) void {
        tunnel.reshapeWith(.warp, frame_start, deeper);
    }

    /// Each ring stands the game's `ring_spacing` deeper than the last, swaying by `ring_sway` as
    /// `since` goes by, a radian every 10 seconds (`0x00420A00`).
    fn swayRings(tunnel: *Tunnel, since: f32) void {
        for (tunnel.depths, 0..) |*depth, ring| {
            const along = share(ring, tunnel.split);
            depth.* = along * ring_spacing + @sin(along + since) * ring_sway;
        }
    }

    /// `0x0041FA50`: each vertex of each ring, `radii` from the axis at its segment's turn and at
    /// its ring's depth and `deeper` (the record's `+0x1C`), the game's last ring at the depth of
    /// the one before. At the high detail the game's vertices each sway either way across the axis
    /// by `wobbleOf` times the segments, each at its own pace, by the frame's tick (`sway`); a
    /// drawn vertex between them sways as those about it do (`Corners`).
    fn shape(tunnel: *Tunnel, kind: Kind, frame_start: i32, deeper: f32) void {
        const grid = tunnel.grid;
        const drawn = tunnel.drawnGrid();
        const ticks: f32 = @floatFromInt(frame_start);
        const reach = @as(f32, @floatFromInt(grid.segments)) * wobbleOf(kind);
        var sways: [Grid.most_vertices]Vector = @splat(@splat(0));
        if (grid.segments == Grid.of(.high).segments) {
            for (sways[1..grid.vertices()], 1..) |*each, vertex| {
                const swayed = sway(ticks, vertex, wobble_spread, reach);
                each.* = .{ swayed[0], swayed[1], 0 };
            }
        }
        const last = (grid.rings - 1) * tunnel.split;
        for (0..drawn.rings + 1) |ring| {
            for (0..drawn.segments) |segment| {
                const vertex = drawn.vertex(ring, segment);
                const turn = segmentTurn(segment, drawn.segments);
                const across: Vector = .{ @sin(turn) * tunnel.radii[ring], @cos(turn) * tunnel.radii[ring], tunnel.depths[@min(ring, last)] + deeper };
                tunnel.mesh.positions[vertex] = across + Corners.of(grid, tunnel.split, vertex).blend(Vector, &sways);
            }
        }
    }

    /// `0x00422380`, as a gate collapses: the tunnel burns out, a flickering share of its vertices,
    /// `(sin(at * burn_flicker) + 1) / 2`, taking the burning colours (`wipe`, with its **Fix**).
    pub fn burnOut(tunnel: *Tunnel, at: f32) void {
        tunnel.wipe((@sin(at * burn_flicker) + 1) * 0.5, .burning);
    }

    /// `0x004221E0`, as the collapse ends: the tunnel fades, `at` of its vertices taking the fading
    /// colours (`wipe`, with its **Fix**).
    pub fn fadeOut(tunnel: *Tunnel, at: f32) void {
        tunnel.wipe(at, .fading);
    }

    /// The game's vertices, counted from the tunnel's centre up to `portion` of them all, take
    /// `look`'s colours, brightest where the portion has just reached them (`Wipe.shade`): their
    /// rings' first and last black and clear (`Grid.edge`).
    ///
    /// **Fix:** the game writes each colour to the vertex before its own, lighting the last vertex
    /// of the mouth's black rim and blacking out one of the ring before the last; OpenReliant
    /// writes each vertex's own.
    fn wipe(tunnel: *Tunnel, portion: f32, look: Wipe) void {
        const grid = tunnel.grid;
        const count: f32 = @floatFromInt(tunnel.colours.len);
        const reach = count * portion;
        for (0..grid.rings + 1) |ring| {
            for (0..grid.segments) |segment| {
                const at: f32 = @floatFromInt(ring * grid.segments + segment);
                if (!(at <= reach)) continue;
                tunnel.colours[grid.vertex(ring, segment)] = if (grid.edge(ring))
                    @splat(0)
                else
                    look.shade((reach - at) * (1 / (count - reach)), ring == grid.rings - 1);
            }
        }
        tunnel.lay();
    }

    /// Scrolls its texture across and along it by `time` as the gates count it (`scroll_rate`),
    /// as the game does as it draws it (`0x00420950`).
    pub fn scroll(tunnel: *Tunnel, time: f32) void {
        scrollBy(&tunnel.mesh, .{ -(time * scroll_rate[0]), -(time * scroll_rate[1]) });
    }

    /// `order_warp_in` (`0x0041F260`) also scrolls U forward and V back before its update.
    /// The draw callback then applies the shared tunnel scroll.
    pub fn scrollArrival(tunnel: *Tunnel, time: f32) void {
        scrollBy(&tunnel.mesh, .{ time * scroll_rate[0], -(time * scroll_rate[1]) });
    }
};

/// How far apart the rings stand, and how far each sways either way (`0x004DC4B8`,
/// `0x004DC544`).
const ring_spacing: f32 = 1500;
const ring_sway: f32 = 300;

/// How fast the burning flickers (`0x004DC44C`).
const burn_flicker: f32 = 1000;

/// The colours a collapsing gate's tunnel wipes through: burning, then fading (`0x00422380`,
/// `0x004221E0`).
const Wipe = enum {
    burning,
    fading,

    /// Its colours at their brightest, on most rings and on the ring before the last: burning, a
    /// dull red and blue; fading, a pale grey and green.
    fn colours(look: Wipe) Colours {
        return switch (look) {
            .burning => .{ .most = .{ 1, 0.3, 0.5 }, .last = .{ 0, 0.5, 1 } },
            .fading => .{ .most = .{ 0.6, 0.7, 0.7 }, .last = .{ 0.3, 1, 0.8 } },
        };
    }

    const Colours = struct { most: [3]f32, last: [3]f32 };

    /// The colour of a vertex `past` of the way behind the wipe, clamped to 0 to 1: bright where
    /// the wipe has just reached it and dark well behind (`0x0041DCD0`, `ease.cosine`), and
    /// `last_level` as bright on the ring before the last.
    fn shade(look: Wipe, past: f32, last: bool) [4]f32 {
        const through: f32 = if (!(past <= 1)) 1 else if (past < 0) 0 else past;
        const level = ease.cosine(if (last) last_level else 1, 0, through);
        const pair = look.colours();
        const colour: @Vector(3, f32) = if (last) pair.last else pair.most;
        return srapiext.solid(colour * @as(@Vector(3, f32), @splat(level)));
    }

    const last_level: f32 = 0.5;
};

/// The sway of a gate's vertices at the high detail, across and down (`0x0041FA50`): its pace by
/// the tick (`0x004DC610`, `0x004DC608`), and each vertex's own offset into it, its number times 8
/// and 4 (the game rotates it), times `wobble_spread` (`0x004DC4C0`, `0x004DC4DC`); and its reach
/// for each segment, a gate's (`0x004DC604`) or a warp's (`0x004DC60C`).
const wobble_rate = [2]f32{ 0.04, 0.034 };
const wobble_step = [2]usize{ 8, 4 };
const wobble_spread = [2]f32{ 0.3, 0.4 };

/// How far vertex `vertex` of a tube sways across and down at tick `ticks`, by up to `reach`, its
/// offsets spread by `spread` (`wobble_rate`): a tunnel's (`0x0041FA50`) and the worm's
/// (`0x004229B0`) alike.
pub fn sway(ticks: f32, vertex: usize, spread: [2]f32, reach: f32) [2]f32 {
    var swayed: [2]f32 = undefined;
    for (&swayed, wobble_rate, wobble_step, spread) |*each, rate, step, offset| {
        each.* = @sin(ticks * rate + @as(f32, @floatFromInt(vertex * step)) * offset) * reach;
    }
    return swayed;
}

fn wobbleOf(kind: Kind) f32 {
    return switch (kind) {
        .proto, .advanced => 41.7,
        .warp, .boridin => 5.83,
    };
}

/// The driver's highlight texture a tunnel's second pass takes: 7, or 0 for an advanced gate's
/// (`0x0041DF75`).
fn highlightOf(kind: Kind) u3 {
    return switch (kind) {
        .advanced => 0,
        .warp, .proto, .boridin => 7,
    };
}

/// How fast a tunnel's texture scrolls across it and along it as the gates count time, 0.35 and
/// 0.06 of it a second (`0x004DC600`, `0x004DC4B4`).
const scroll_rate = [2]f32{ 3.5, 0.6 };

/// Moves a mesh's coordinates by `by`, as the tunnels and the worm scroll their textures.
pub fn scrollBy(mesh: *srapiext.Mesh, by: [2]f32) void {
    const uv = mesh.uv[0] orelse return;
    for (uv) |*pair| pair.* = .{ pair[0] + by[0], pair[1] + by[1] };
}

/// How far round the axis segment `segment` of `segments` stands, in radians.
///
/// **Improvement:** the turn by `std.math.tau` over the segments, where the game multiplies by
/// 6.2831855 (`0x004DC3EC`) and by one over the segments (`wgate_segment_step`, `0x0051D130`).
pub fn segmentTurn(segment: usize, segments: usize) f32 {
    return @as(f32, @floatFromInt(segment)) * std.math.tau / @as(f32, @floatFromInt(segments));
}

/// The radius of a tunnel of `rings` at `ring` (`0x0041DD70`), which a fine tunnel takes between
/// the game's rings too (`Tunnels`). A gate's shrinks by a sixth at each ring from the mouth,
/// `size` times 344 or so there, whatever the rings; a warp's is 344 or so all along, whatever its
/// size. The game works it out in double precision as `profile_base` to the `profile_rings` times
/// `profile_rings`, over `profile_base` to the `rings` times `rings`; times `profile_base` to the
/// `rings` times `rings` for a warp, or to the `rings - ring` times `rings` times `size` for a
/// gate; times `radius_scale`.
fn ringRadius(kind: Kind, rings: usize, ring: f32, size: f32) f32 {
    const count: f64 = @floatFromInt(rings);
    const scale = std.math.pow(f64, profile_base, profile_rings) * profile_rings / (std.math.pow(f64, profile_base, count) * count);
    const radius = switch (kind) {
        .warp, .boridin => std.math.pow(f64, profile_base, count) * scale * count,
        .proto, .advanced => std.math.pow(f64, profile_base, count - ring) * count * scale * size,
    };
    return @floatCast(radius * radius_scale);
}

/// The tunnel's profile (`0x004DC5D0`, `0x004DC5C8`, `0x004DC5C0`), doubles as the game loads
/// them.
const profile_base: f64 = 1.2;
const profile_rings: f64 = 8;
const radius_scale: f64 = 10;

/// The coordinates of a gate's tunnel on `grid` at `index` of the grid `split` times as fine it is
/// drawn on (`0x0041DD70`): how far along the game's rings it stands over `rings_per_u`, and its
/// height across a warp's tunnel's radius (`ringRadius`) in thousandths, as the game copies them
/// from a warp's tunnel 1000 across.
fn coordinatesOf(grid: Grid, split: usize, index: u16) [2]f32 {
    const drawn = grid.finer(split);
    const at = drawn.place(index) orelse return .{ 0, 0 };
    const along = share(at.ring, split);
    const turn = segmentTurn(at.segment, drawn.segments);
    const radius = ringRadius(.warp, grid.rings, along, uv_size);
    return .{ along / rings_per_u, @cos(turn) * radius * uv_across };
}

/// The warp's tunnel the coordinates come from, its rings a unit of `u` apart for eight
/// (`0x004DC5B8`), and its height's scale (`0x004DC49C`).
const uv_size: f32 = 1000;
const rings_per_u: f32 = 8;
const uv_across: f32 = 0.001;

/// Numbers a tube's triangles on `grid`, two for each segment between ring `ring - 1` and ring
/// `ring`, from the first ring on, and the indices of their corners: the near ring's corner and
/// the far one's, then the near ring's next; the near ring's next, the far ring's corner and its
/// next.
pub fn numberBands(mesh: *srapiext.Mesh, grid: Grid) void {
    mesh.numberPolygons(3);
    var at: usize = 0;
    for (1..grid.rings + 1) |ring| {
        for (0..grid.segments) |segment| {
            const next = (segment + 1) % grid.segments;
            const corners = [6]usize{
                grid.vertex(ring - 1, segment), grid.vertex(ring, segment), grid.vertex(ring - 1, next),
                grid.vertex(ring - 1, next),    grid.vertex(ring, segment), grid.vertex(ring, next),
            };
            for (corners) |corner| {
                mesh.indices[at] = @intCast(corner);
                at += 1;
            }
        }
    }
}

/// A tube's two surfaces (`0x0041DD70`, `0x00422700`): all but its last band of `last_band`
/// polygons drawn with `image` by its own coordinates and `blend`, and where `two_pass` a second
/// pass of the driver's highlight texture `highlight` by its normals, added; its last band in one
/// pass of `image`. Its faces' planes, its vertex normals and its bounds follow.
pub fn tubeSurfaces(mesh: *srapiext.Mesh, last_band: usize, image: *srtexture.Image, highlight: u3, two_pass: bool, blend: srapiext.Material.Blend) void {
    mesh.surfaces[0] = .{
        .polygons = @intCast(mesh.polygons.len - last_band),
        .material = .{
            .two_pass = two_pass,
            ._unknown_01 = 0,
            .coordinates = .{ .mesh, .generated },
            .lit = .{ true, true },
            .blend = .{ blend, .add },
            .image = .{ .null, .null },
        },
        .textures = .{ .{ .image = image }, .{ .highlight = highlight } },
    };
    mesh.surfaces[1] = .{
        .polygons = @intCast(last_band),
        .material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = blend }),
        .textures = .{ .{ .image = image }, .none },
    };
    srapi.calcPolyNormals(mesh);
    srapi.calcVertexNormals(mesh);
    srapi.findBoundingBox(mesh);
}

/// The colours a tunnel runs through, from its mouth to its end (`0x0041D7D0`, `0x00422AD0`): the
/// mouth's, the middle's `palette_turn` of the way along, the end's, and the ring before the
/// last's, in 256ths as the game writes them.
pub const Palette = struct {
    mouth: [3]f32,
    middle: [3]f32,
    end: [3]f32,
    last: [3]f32,

    pub const blue: Palette = .{
        .mouth = .{ 0.921875, 0.921875, 0.6640625 },
        .middle = .{ 0.19921875, 0.4296875, 0.76953125 },
        .end = .{ 0.046875, 0, 0.3125 },
        .last = .{ 0.1171875, 0.05859375, 0.625 },
    };
    pub const red: Palette = .{
        .mouth = .{ 1, 1, 0.859375 },
        .middle = .{ 0.76953125, 0.4296875, 0.19921875 },
        .end = .{ 0.3125, 0, 0.046875 },
        .last = .{ 0.625, 0.05859375, 0.1171875 },
    };

    /// The colour `along` of the way along: in a straight line from the mouth's to the middle's,
    /// then from the middle's to the end's by the square root.
    ///
    /// **Improvement:** the game scales the share by 3.3333 and 1.4286; OpenReliant divides by the
    /// spans those round.
    pub fn at(palette: Palette, along: f32) [3]f32 {
        var shade: [3]f32 = undefined;
        for (&shade, palette.mouth, palette.middle, palette.end) |*channel, mouth, middle, end| {
            channel.* = if (along < palette_turn)
                ease.linear(mouth, middle, along / palette_turn)
            else
                ease.out(middle, end, (along - palette_turn) / (1 - palette_turn));
        }
        return shade;
    }
};

/// How far along a tunnel its colours turn (`0x004DC4C0`).
const palette_turn: f32 = 0.3;

/// A software renderer's ring before the last (`0x0041D7D0`).
const software_last: [4]f32 = .{ 0.5, 0.5, 0.5, 1 };

/// The colour of ring `ring` of a tube on `grid` (`0x0041D7D0`, `0x00422AD0`): black and clear at
/// the mouth and the last ring (`Grid.edge`), `last` on the ring before the last, and `between`
/// on the rest.
pub fn ringShade(grid: Grid, ring: usize, last: [4]f32, between: [4]f32) [4]f32 {
    if (grid.edge(ring)) return @splat(0);
    return if (ring == grid.rings - 1) last else between;
}

/// Each vertex of ring `ring` of a tube on `grid` takes the colour `shade`.
pub fn fillRing(colours: [][4]f32, grid: Grid, ring: usize, shade: [4]f32) void {
    @memset(colours[grid.vertex(ring, 0)..][0..grid.segments], shade);
}

/// One of the two flashes a ship jumping in shows at the tunnel's throat (`+0x74`, `+0x78`): a
/// square (`loadout.squareMesh`, `square_side` across) over the whole of the flashes' texture,
/// added to what is behind it by colours of its own.
pub const Square = struct {
    mesh: srapiext.Mesh,
    level: [1]srapiext.Level,
    object: srapiext.MeshObject,
    colours: [4][4]f32 = @splat(@splat(0)),
    /// How deep it stands in the tunnel's frame.
    depth: f32 = 0,

    pub fn build(square: *Square, gpa: Allocator, image: *srtexture.Image) Allocator.Error!void {
        var mesh = try loadout.squareMesh(gpa, false, square_side, square_side);
        errdefer mesh.deinit(gpa);
        loadout.spanWhole(&mesh);
        mesh.surfaces[0] = .{
            .polygons = 2,
            .material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .add }),
            .textures = .{ .{ .image = image }, .none },
        };
        square.* = .{ .mesh = mesh, .level = undefined, .object = undefined };
        square.level = .{.{ .mesh = &square.mesh, .until = std.math.inf(f32) }};
        square.object = .{
            .flags = .{ .not_culled = true, .owns_mesh = true, .baked_object = true },
            .position = @splat(0),
            .radius = mesh.radius,
            .levels = &square.level,
            .baked = &square.colours,
        };
    }

    pub fn deinit(square: *Square, gpa: Allocator) void {
        square.mesh.deinit(gpa);
    }

    /// Sizes it `half` either way of its centre and colours it `shade` grey, its alpha as it was,
    /// as the game sets only the red, the green and the blue.
    pub fn set(square: *Square, half: f32, shade: f32) void {
        square.mesh.positions[0..4].* = loadout.squareCorners(2 * half, 2 * half);
        const alpha = square.colours[0][3];
        square.colours = @splat(.{ shade, shade, shade, alpha });
    }
};

/// How far across a flash's square is (`0x0041FE60`).
const square_side: f32 = 25000;

/// A size of tunnel for the tests, a proto gate's.
const test_size: f32 = 70;

test Grid {
    const high: Grid = .of(.high);
    try std.testing.expectEqual(16 * 13 + 1, high.vertices());
    try std.testing.expectEqual(12 * 16 * 2, high.polygons());
    try std.testing.expectEqual(7, high.throat());
    try std.testing.expectEqual(1, Grid.of(.low).throat());
    // Its vertices are numbered ring by ring after the centre, and back again.
    try std.testing.expectEqual(1 + 2 * 16 + 3, high.vertex(2, 3));
    try std.testing.expectEqual(Grid.Place{ .ring = 2, .segment = 3 }, high.place(high.vertex(2, 3)).?);
    try std.testing.expectEqual(null, high.place(0));
    try std.testing.expect(high.edge(0) and high.edge(12) and !high.edge(11));
}

test ringRadius {
    // A gate's mouth is 344 or so times its size, and each ring a sixth narrower than the last,
    // whatever the rings.
    const mouth = 80 * std.math.pow(f32, 1.2, 8);
    try std.testing.expectApproxEqRel(mouth * 70, ringRadius(.proto, 12, 0, 70), 1e-5);
    try std.testing.expectApproxEqRel(mouth * 70, ringRadius(.proto, 6, 0, 70), 1e-5);
    try std.testing.expectApproxEqRel(ringRadius(.proto, 12, 3, 40) / 1.2, ringRadius(.proto, 12, 4, 40), 1e-5);
    // A warp's is the same all along.
    try std.testing.expectApproxEqRel(mouth / 10 * 10, ringRadius(.warp, 12, 7, 999), 1e-5);
}

test Palette {
    // The mouth's colour at the mouth, the middle's at the turn, the end's at the end.
    try std.testing.expectEqual(Palette.blue.mouth, Palette.blue.at(0));
    for (Palette.red.middle, Palette.red.at(palette_turn)) |expected, found| try std.testing.expectApproxEqAbs(expected, found, 1e-6);
    for (Palette.red.end, Palette.red.at(1)) |expected, found| try std.testing.expectApproxEqAbs(expected, found, 1e-6);
}

test "Wipe.shade" {
    const most = Wipe.burning.colours().most;
    // Brightest where the wipe has just reached a vertex, dark well behind, clamped either way.
    try std.testing.expectEqual(srapiext.solid(most), Wipe.burning.shade(-1, false));
    try std.testing.expectEqual(srapiext.solid(.{ 0.5, 0.15, 0.25 }), Wipe.burning.shade(0.5, false));
    try std.testing.expectEqual(srapiext.solid(@splat(0)), Wipe.burning.shade(2, false));
    try std.testing.expectEqual(srapiext.solid(@splat(0)), Wipe.burning.shade(std.math.nan(f32), false));
    // Half as bright on the ring before the last, in its own colour.
    try std.testing.expectEqual(srapiext.solid(.{ 0.15, 0.5, 0.4 }), Wipe.fading.shade(0, true));
}

test sway {
    // At the start, the first vertex's offsets alone: its number times 8 and 4, spread.
    const swayed = sway(0, 1, wobble_spread, 100);
    try std.testing.expectApproxEqAbs(@sin(@as(f32, 8 * 0.3)) * 100, swayed[0], 1e-4);
    try std.testing.expectApproxEqAbs(@sin(@as(f32, 4 * 0.4)) * 100, swayed[1], 1e-4);
}

test scrollBy {
    const gpa = std.testing.allocator;
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = 1, .vertices = 3, .indices = 3 });
    defer mesh.deinit(gpa);
    // Without coordinates, nothing moves.
    scrollBy(&mesh, .{ 1, 1 });
    const uv = try mesh.addCoordinates(gpa);
    uv[0] = .{ 0.5, 0.25 };
    scrollBy(&mesh, .{ 1, -0.25 });
    try std.testing.expectEqual([2]f32{ 1.5, 0 }, uv[0]);
}

test Tunnel {
    const gpa = std.testing.allocator;
    var image: srtexture.Image = undefined;
    const grid: Grid = .of(.high);
    var tunnel: Tunnel = undefined;
    try tunnel.build(gpa, grid, 1, true, &image, .proto, test_size);
    defer tunnel.deinit(gpa);

    // A ring of vertices round the axis at each ring's radius, flat until it is shaped.
    const first = tunnel.mesh.positions[grid.vertex(0, 0)];
    try std.testing.expectApproxEqRel(tunnel.radii[0], first[1], 1e-5);
    try std.testing.expectEqual(0, first[2]);
    // Each band two triangles a segment, the last band drawn in one pass.
    try std.testing.expectEqualSlices(u16, &.{ 1, 17, 2, 2, 17, 18 }, tunnel.mesh.indices[0..6]);
    try std.testing.expectEqual(grid.polygons() - 32, tunnel.mesh.surfaces[0].polygons);
    try std.testing.expect(tunnel.mesh.surfaces[0].material.two_pass and !tunnel.mesh.surfaces[1].material.two_pass);
    try std.testing.expectEqual(srapiext.Texture{ .highlight = 7 }, tunnel.mesh.surfaces[0].textures[1]);
    // The coordinates run a unit along for eight rings.
    try std.testing.expectEqual(1, coordinatesOf(grid, 1, @intCast(grid.vertex(8, 0)))[0]);
    // Black and clear at the mouth and at the end, the deep colour on the ring before it, and
    // drawn so.
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, tunnel.colours[grid.vertex(0, 3)]);
    try std.testing.expectEqual(srapiext.solid(Palette.blue.last), tunnel.colours[grid.vertex(grid.rings - 1, 3)]);
    try std.testing.expectEqualSlices([4]f32, tunnel.colours, tunnel.drawn_colours);

    // Shaped, each ring stands at its depth, the last at the one before's, every vertex the
    // record's depth deeper, and sways at the high detail.
    for (tunnel.depths, 0..) |*depth, ring| depth.* = @floatFromInt(ring * 100);
    tunnel.shape(.proto, 0, 0);
    try std.testing.expectEqual(500, tunnel.mesh.positions[grid.vertex(5, 2)][2]);
    try std.testing.expectEqual(1100, tunnel.mesh.positions[grid.vertex(grid.rings, 2)][2]);
    try std.testing.expect(tunnel.mesh.positions[grid.vertex(5, 2)][0] != @sin(segmentTurn(2, 16)) * tunnel.radii[5]);
    try std.testing.expectEqual(tunnel.mesh.positions[grid.vertex(grid.throat(), 0)], tunnel.throat());
    tunnel.shape(.proto, 0, 15000);
    try std.testing.expectEqual(15500, tunnel.mesh.positions[grid.vertex(5, 2)][2]);
    tunnel.shape(.proto, 0, 0);

    // The collapse's fade reaches its share of the vertices, from the centre on, each vertex
    // taking its own colour: the mouth stays black and clear to its last vertex.
    tunnel.fadeOut(0.5);
    try std.testing.expect(tunnel.colours[grid.vertex(2, 3)][3] == 1 and tunnel.colours[grid.vertex(2, 3)][0] < 0.6);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, tunnel.colours[grid.vertex(0, grid.segments - 1)]);
    try std.testing.expectEqual(srapiext.solid(Palette.blue.last), tunnel.colours[grid.vertex(grid.rings - 1, 3)]);
    try std.testing.expectEqualSlices([4]f32, tunnel.colours, tunnel.drawn_colours);

    // Burning, the share of the vertices the flicker gives, half of them where its sine is 0,
    // takes the burning colours.
    tunnel.burnOut(0);
    const burnt = tunnel.colours[grid.vertex(2, 3)];
    const burning = Wipe.burning.colours().most;
    try std.testing.expectApproxEqRel(burning[1] / burning[0], burnt[1] / burnt[0], 1e-5);

    // Its texture scrolls back across and along it.
    const before = tunnel.mesh.uv[0].?[7];
    tunnel.scroll(0.1);
    const after = tunnel.mesh.uv[0].?[7];
    try std.testing.expectApproxEqAbs(before[0] - 0.1 * scroll_rate[0], after[0], 1e-6);
    try std.testing.expectApproxEqAbs(before[1] - 0.1 * scroll_rate[1], after[1], 1e-6);
}

test "a fine tunnel passes through the game's vertices and follows its curves between them" {
    const gpa = std.testing.allocator;
    var image: srtexture.Image = undefined;
    const grid: Grid = .of(.high);
    const split = fine_split;
    var fine: Tunnel = undefined;
    try fine.build(gpa, grid, split, true, &image, .advanced, test_size);
    defer fine.deinit(gpa);
    var game: Tunnel = undefined;
    try game.build(gpa, grid, 1, true, &image, .advanced, test_size);
    defer game.deinit(gpa);

    const drawn = grid.finer(split);
    try std.testing.expectEqual(drawn.vertices(), fine.mesh.positions.len);
    // The game's last band is drawn in one pass, however finely it is split.
    try std.testing.expectEqual(2 * drawn.segments * split, fine.mesh.surfaces[1].polygons);
    try std.testing.expectEqual(drawn.polygons(), fine.mesh.surfaces[0].polygons + fine.mesh.surfaces[1].polygons);

    // Shaped at the same tick, with the game's spacing, it stands where the game's does at the
    // game's vertices, sway and all, and is as long.
    for (fine.depths, 0..) |*depth, ring| depth.* = share(ring, split) * ring_spacing;
    for (game.depths, 0..) |*depth, ring| depth.* = share(ring, 1) * ring_spacing;
    fine.shape(.advanced, 1234, 0);
    game.shape(.advanced, 1234, 0);
    for (0..grid.rings + 1) |ring| {
        for (0..grid.segments) |segment| {
            const expected = game.mesh.positions[grid.vertex(ring, segment)];
            const found = fine.mesh.positions[drawn.vertex(ring * split, segment * split)];
            try math.testing.expectVectorWithin(expected, found, 1e-2);
        }
    }
    try std.testing.expectEqual(game.throat(), fine.throat());
    // Between the game's rings, its radius follows the game's curve, a sixth narrower a ring.
    try std.testing.expectApproxEqRel(fine.radii[0] / std.math.sqrt(1.2), fine.radii[split / 2], 1e-5);
    // Its colours are the game's at the game's vertices, and between them as the game's are drawn.
    try std.testing.expectEqual(game.drawn_colours[grid.vertex(3, 5)], fine.drawn_colours[drawn.vertex(3 * split, 5 * split)]);
    const halfway = fine.drawn_colours[drawn.vertex(3 * split + split / 2, 5 * split)];
    for (halfway, game.colours[grid.vertex(3, 5)], game.colours[grid.vertex(4, 5)]) |found, near, far| {
        try std.testing.expectApproxEqAbs((near + far) / 2, found, 1e-6);
    }
    // Its texture lies along it as the game's does, a unit for eight of the game's rings.
    try std.testing.expectEqual(coordinatesOf(grid, 1, @intCast(grid.vertex(8, 0))), coordinatesOf(grid, split, @intCast(drawn.vertex(8 * split, 0))));
    try std.testing.expectEqual(0.5, coordinatesOf(grid, split, @intCast(drawn.vertex(4 * split, 0)))[0]);
}

test Square {
    const gpa = std.testing.allocator;
    var image: srtexture.Image = undefined;
    var square: Square = undefined;
    try square.build(gpa, &image);
    defer square.deinit(gpa);
    // Over the whole of its texture.
    try std.testing.expectEqual([2]f32{ 1, 0 }, square.mesh.uv[0].?[4]);
    // Sized and shaded, its alpha left as it was.
    square.colours[0][3] = 0.25;
    square.set(10, 0.5);
    try std.testing.expectEqual(Vector{ 10, -10, 0 }, square.mesh.positions[1]);
    try std.testing.expectEqual([4]f32{ 0.5, 0.5, 0.5, 0.25 }, square.colours[3]);
}
