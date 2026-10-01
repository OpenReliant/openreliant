//! `C:\lancer\game\wgate.cpp`: the gates' tunnels. A Coalition gate stands with a tunnel open in
//! it from the start, and Fixed Gate Open grows one at any object, a nav point among them; each is
//! a record of the gates (`Gates`), drawn each frame as a funnel of rings that sways and scrolls
//! (`Gates.draw`). A ship jumps out through the nearest tunnel (Fixed Gate Jump Out), the player's
//! riding the worm between gates, and jumps in through its order's (Fixed Gate Jump In), a portal
//! at the tunnel's throat cutting it as it passes. Fixed Gate Close shrinks a tunnel away, and
//! Fixed Gate Collapse brings a gate down. [Gates](../../../docs/engine/gates.md) describes them.
//!
//! **Unverified:** the file of the tunnel's colours and the easings beside them (`0x0041D7D0` to
//! `0x0041DD6F`), which lie between `tractor.cpp`'s known code and this file's, and do this
//! file's work.
//!
//! Not ported: the warps' tunnels (kind 0, `order_warp_out`, `order_warp_in`), with their
//! particles and beams ([#481](https://github.com/vdmkenny/openreliant/issues/481)); the Boridin's
//! projection (kind 3, `order_start_warp_projection_from_boridin`)
//! ([#30](https://github.com/vdmkenny/openreliant/issues/30)); and the Krasny's split, as it jumps
//! in through the gate collapsing behind it in missions 16 and 66 (`0x00422CA0`)
//! ([#407](https://github.com/vdmkenny/openreliant/issues/407)).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const ease = @import("../genilib/interf/ease.zig");
const libcmt = @import("../libcmt.zig");
const loadout = @import("../interface/loadout/loadout.zig");
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const create = @import("create.zig");
const events = @import("mission/events.zig");
const explode = @import("explode.zig");
const Detail = explode.Detail;
const gameobj = @import("gameobj.zig");
const matmanager = @import("matmanager.zig");
const objects = @import("objects.zig");
const sound3d = @import("sound3d.zig");
const xtrabits = @import("xtrabits.zig");

const log = std.log.scoped(.wgate);

/// The records the gates keep (`0x0051D1A4`, 32 of them), each flagged in use in `0x0051D224`.
pub const max_records = 32;

/// What a record's tunnel serves (`+0x00`).
pub const Kind = enum(u32) {
    /// A warp's (`order_warp_out`, `order_warp_in`), not ported.
    warp = 0,
    /// A fixed gate's, while no advanced gate is among the objects: blue.
    proto = 1,
    /// A fixed gate's, with an advanced gate among the objects: red.
    advanced = 2,
    /// The Boridin's projection's, not ported.
    boridin = 3,
};

/// How many segments a tunnel has round (`0x004E3F50`) and how many rings along
/// (`0x004E3F5C`), by the options' detail, which the gates' start takes (`0x0041E280`).
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

    /// The most vertices a grid of the game's has, at the high detail.
    const most_vertices = of(.high).vertices();
};

comptime {
    for (std.enums.values(Detail)) |detail| {
        assert(Grid.of(detail).rings > Grid.throat_back);
        assert(Grid.of(detail).vertices() <= Grid.most_vertices);
    }
}

/// How the gates are shown.
pub const Settings = struct {
    tunnels: Tunnels = .fine,
    rumbles: Rumbles = .steady,

    /// The original's: tunnels on its grid, and a ride through the worm that may rumble each frame.
    pub const original: Settings = .{ .tunnels = .original, .rumbles = .original };
};

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
    fn split(tunnels: Tunnels) usize {
        return switch (tunnels) {
            .fine => fine_split,
            .original => 1,
        };
    }
};

const fine_split = 4;

/// How often the ride through the worm rumbles: the view shaking and flashing, and heard.
pub const Rumbles = enum {
    /// **Improvement:** a chance of `rumble_chance` for each of the simulation's steps, 25 a
    /// second, the ride rumbling on a frame where any comes up, so that it rumbles as often
    /// whatever the frame rate: as the game does at 25 frames a second.
    steady,
    /// A chance of `rumble_chance` each frame, as the game has it, so that the ride rumbles the
    /// more often the higher the frame rate.
    original,
};

/// The four vertices of the game's grid about a vertex of a tunnel drawn on a grid `split` times as
/// fine (`Tunnels`), and how much each counts toward it: in a straight line between them, round and
/// along, as the game's vertices' values are drawn between them.
const Corners = struct {
    vertices: [4]usize = @splat(0),
    weights: [4]f32 = .{ 1, 0, 0, 0 },

    /// The corners of drawn vertex `vertex`; the centre's is the game's centre.
    fn of(grid: Grid, split: usize, vertex: usize) Corners {
        if (vertex == 0) return .{};
        const drawn = grid.finer(split);
        const ring = (vertex - 1) / drawn.segments;
        const segment = (vertex - 1) % drawn.segments;
        const near = ring / split;
        const far = @min(near + 1, grid.rings);
        const first = segment / split;
        const next = (first + 1) % grid.segments;
        const along = @as(f32, @floatFromInt(ring % split)) / @as(f32, @floatFromInt(split));
        const round = @as(f32, @floatFromInt(segment % split)) / @as(f32, @floatFromInt(split));
        return .{
            .vertices = .{ vertexOf(grid, near, first), vertexOf(grid, near, next), vertexOf(grid, far, first), vertexOf(grid, far, next) },
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

/// How far along the game's rings drawn ring `ring` stands, where each of the game's bands is split
/// `split` ways along.
fn ringAlong(ring: usize, split: usize) f32 {
    return @as(f32, @floatFromInt(ring)) / @as(f32, @floatFromInt(split));
}

/// The gates' state, `wgate.cpp`'s globals: the textures, the grid its tunnels are built on, its
/// records, and the worm the player's ship rides between gates.
pub const Gates = struct {
    gpa: Allocator,
    /// The tunnels' texture (`0x0051D1A0`): `warp128`, or `ddwarp128` without a hardware renderer.
    warp: *srtexture.Image,
    /// The jumps' flashes' texture (`warpin3`).
    flash: *srtexture.Image,
    /// Whether a hardware renderer draws them, which gives the tunnels their colours and their
    /// highlight (`Tunnel.colour`).
    hardware: bool,
    /// The grid the options' detail gives the tunnels (`0x0051D198`, `0x0051D128`).
    grid: Grid,
    settings: Settings,
    records: [max_records]?*Record = @splat(null),
    /// `0x0051D13C`: set while a ship jumps out through a tunnel, which the next waits for.
    exiting: bool = false,
    /// `0x0051D13E`: set while the player's ship rides the worm, which hides the gates' tunnels.
    riding: bool = false,
    /// `0x0051D19C`: the worm the player's ship rides between gates.
    worm: ?*Worm = null,
    /// Whether the worm is in this frame's scene, as Jump Out puts it for the player's ship.
    worm_shown: bool = false,
    /// `0x004E3F68`: where the next ship to jump in comes out, turned `spread_step` about the
    /// tunnel's axis for each step, from -2 to 2. It starts at -2 as the game does, and nothing
    /// sets it back between missions.
    spread: i32 = -2,
    /// The tick the ride's rumbles were last drawn for, in the steady style (`Rumbles`).
    rumbled_at: i32 = 0,

    /// The gates' start (`0x0041E280`), without the warps' and the Boridin's textures and
    /// particles: the tunnels' texture, the flashes', and the grid by `detail`.
    pub fn init(gpa: Allocator, textures: *srtexture.Table, detail: Detail, hardware: bool, settings: Settings) matmanager.Error!Gates {
        return .{
            .gpa = gpa,
            .warp = try matmanager.textureRequire(textures, if (hardware) warp_texture else software_warp_texture),
            .flash = try matmanager.textureRequire(textures, flash_texture),
            .hardware = hardware,
            .grid = .of(detail),
            .settings = settings,
        };
    }

    /// The gates' end with a mission (`0x0041E4A0`) and their start with the next: every record
    /// and the worm let go, and nothing jumping.
    ///
    /// **Fix:** the game makes the worm anew for each of the player's jumps out and never lets the
    /// last one go; OpenReliant lets it go with the rest.
    pub fn reset(gates: *Gates) void {
        for (0..max_records) |index| gates.free(index);
        if (gates.worm) |worm| worm.destroy(gates.gpa);
        gates.worm = null;
        gates.worm_shown = false;
        gates.exiting = false;
        gates.riding = false;
    }

    pub fn deinit(gates: *Gates) void {
        gates.reset();
    }

    /// `0x00420920`: the first record whose tunnel stands at the object in slot `index`.
    pub fn of(gates: *const Gates, index: u16) ?*Record {
        for (gates.records) |held| {
            const record = held orelse continue;
            if (record.slot == index) return record;
        }
        return null;
    }

    /// `0x0041FE60`: a record for a tunnel of `kind` at the object in slot `index`, in the first
    /// free place, standing at `at` in the object's frame and turned a half turn about its Y axis,
    /// fully open; null where every place is taken, or for a kind not ported.
    pub fn make(gates: *Gates, world: gameobj.World, index: u16, kind: Kind, at: Vector) Allocator.Error!?*Record {
        switch (kind) {
            .proto, .advanced => {},
            .warp, .boridin => {
                log.warn("the tunnel of kind {s} at object {d} is left out: it is not ported", .{ @tagName(kind), index });
                return null;
            },
        }
        const place = for (&gates.records) |*held| {
            if (held.* == null) break held;
        } else return null;
        const record = try gates.gpa.create(Record);
        errdefer gates.gpa.destroy(record);
        const now = world.clock.frame_start;
        record.* = .{
            .kind = kind,
            .slot = index,
            .made_at = now,
            .drawn_at = now,
            .at = at,
            .tunnel = undefined,
            .squares = undefined,
        };
        try record.tunnel.build(gates, kind, tunnelSize(kind, world.objects.mission_number));
        errdefer record.tunnel.deinit(gates.gpa);
        try record.squares[0].build(gates.gpa, gates.flash);
        errdefer record.squares[0].deinit(gates.gpa);
        try record.squares[1].build(gates.gpa, gates.flash);
        place.* = record;
        return record;
    }

    /// `0x00420830`: lets record `index` go, where it is in use.
    pub fn free(gates: *Gates, index: usize) void {
        const record = gates.records[index] orelse return;
        record.tunnel.deinit(gates.gpa);
        for (&record.squares) |*square| square.deinit(gates.gpa);
        gates.gpa.destroy(record);
        gates.records[index] = null;
    }

    /// `free` for the record `record` is.
    fn freeRecord(gates: *Gates, record: *const Record) void {
        for (gates.records, 0..) |held, index| {
            if (held == record) return gates.free(index);
        }
    }

    /// Whether the ride through the worm rumbles on the frame at tick `now`: where a number drawn
    /// from `random` comes up, `rumble_chance` of the time, once a frame as the game draws it; or
    /// in the steady style once for each simulation step since the last were drawn (`Rumbles`).
    fn rumbles(gates: *Gates, random: *libcmt.Rand, now: i32) bool {
        const draws: u32 = switch (gates.settings.rumbles) {
            .original => 1,
            .steady => gameobj.stepsDue(&gates.rumbled_at, now),
        };
        var rumbled = false;
        for (0..draws) |_| {
            if (random.fraction() < rumble_chance) rumbled = true;
        }
        return rumbled;
    }

    /// The gates' frame (`0x00420A00`), which `shield_bubbles_draw` runs before the bubbles, for
    /// each record of a fixed gate in turn: its rings sway, each of the game's `ring_spacing`
    /// deeper than the last, by `ring_sway` as its time since it was made goes by (`per_tick`), a
    /// radian every 10 seconds, and its tunnel takes its shape from them (`Tunnel.shape`) and its
    /// lighting and bounds from that. Its portal goes into the world's layer, and its tunnel too
    /// unless the player's ship rides the worm. Before them go the flashes a ship jumping in shows
    /// (`jumpIn`), and after them the worm while the player's ship rides it (`jumpOut`).
    ///
    /// Where the game has the tunnel's frame hang from the object's and its portal's from the
    /// tunnel's, OpenReliant places them from where the object is drawn. The game scrolls the
    /// tunnel's texture as it draws it (`0x00420950`), which OpenReliant does here.
    ///
    /// Not ported: the ships the game would have each dent the tunnel as it passes, a list at
    /// `+0x80` that nothing fills (`0x00422540`).
    pub fn draw(gates: *Gates, gpa: Allocator, scene: *srcore.Scene, all: *const create.Objects, frame_start: i32) Allocator.Error!void {
        for (gates.records) |held| {
            const record = held orelse continue;
            record.drawn_at = frame_start;
            const since = @as(f32, @floatFromInt(frame_start -% record.made_at)) * per_tick;
            for (record.tunnel.depths, 0..) |*depth, ring| {
                const along = ringAlong(ring, record.tunnel.split);
                depth.* = along * ring_spacing + @sin(along + since) * ring_sway;
            }
            const tunnel = &record.tunnel;
            tunnel.shape(record.kind, frame_start);
            srapi.calcPolyNormals(&tunnel.mesh);
            srapi.calcVertexNormals(&tunnel.mesh);
            srapi.findBoundingBox(&tunnel.mesh);
            tunnel.object.radius = tunnel.mesh.radius;
            const place = record.tunnelPlace(all);
            tunnel.object.position = place.position;
            tunnel.object.orientation = place.orientation;
            record.portal.position = place.point(record.portal_at);
            record.portal.orientation = place.orientation;
            tunnel.scroll(&record.scrolled_at, frame_start);
            if (record.squares_shown) {
                record.squares_shown = false;
                for (&record.squares) |*square| {
                    square.object.position = place.point(.{ 0, 0, square.depth });
                    square.object.orientation = place.orientation;
                    try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &square.object }, .world);
                }
            }
            try xtrabits.sceneAdd(gpa, scene, .{ .portal = &record.portal }, .world);
            if (!gates.riding) try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &tunnel.object }, .world);
        }
        if (gates.worm_shown) if (gates.worm) |worm| {
            gates.worm_shown = false;
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &worm.object }, .world);
        };
    }
};

/// The textures (`0x004E3FA4`, `0x004E3FB8`, `0x004E1C2C`).
const warp_texture = "warp128";
const software_warp_texture = "ddwarp128";
const flash_texture = "warpin3";

/// A tunnel's size, which scales its radii: the prototype's 70, the advanced gate's 40, and 70 again
/// in mission 8 (`0x0041FE60`).
fn tunnelSize(kind: Kind, mission_number: u16) f32 {
    return switch (kind) {
        .advanced => if (mission_number == wide_advanced_mission) proto_size else advanced_size,
        else => proto_size,
    };
}

const proto_size: f32 = 70;
const advanced_size: f32 = 40;
const wide_advanced_mission = 8;

/// What the gates count their time in (`0x004DC418`): a thousandth for each tick of the timer,
/// which makes a hundred to the second, so that a rate of 1 runs from 0 to 1 in 10 seconds.
const per_tick: f32 = 0.001;

/// How far apart the rings stand, and how far each sways either way (`0x004DC4B8`,
/// `0x004DC544`).
const ring_spacing: f32 = 1500;
const ring_sway: f32 = 300;

/// A record of the gates (`0x88` bytes): a tunnel at an object, its portal, and the two flashes a
/// ship jumping in through it shows.
pub const Record = struct {
    kind: Kind,
    /// The object it stands at (`+0x14`).
    slot: u16,
    /// The frame's tick it was made on (`+0x08`), and the tick of the last frame that drew it
    /// (`+0x0C`), which Open, Close and Collapse count their time from.
    made_at: i32,
    drawn_at: i32,
    /// The tick of the last frame that scrolled its texture (`+0x10`), 0 until one has.
    scrolled_at: i32 = 0,
    /// How far Open or Close has grown or shrunk it (`+0x20`).
    progress: f32 = 0,
    /// Where its tunnel stands in the object's frame.
    at: Vector,
    tunnel: Tunnel,
    /// `+0x70`: what cuts a ship jumping through it, where it stands in the tunnel's frame
    /// (`portalSetUp`), and whether its flashes are in this frame's scene (`+0x74`, `+0x78`).
    portal: srapiext.Portal = .{},
    portal_at: Vector = @splat(0),
    squares: [2]Square,
    squares_shown: bool = false,
    /// `+0x84`: set while a ship comes through it, until it is half way, which the next waits for.
    busy: bool = false,

    /// Where its tunnel stands in the world: at `at` in its object's frame, as the object is
    /// drawn, turned a half turn about its Y axis.
    pub fn tunnelPlace(record: *const Record, all: *const create.Objects) math.Place {
        const turned: math.Place = .{ .position = record.at, .orientation = tunnel_turn };
        return turned.within(all.slots[record.slot].drawn);
    }

    /// `0x0041FDF0`: its portal faces along the tunnel's axis, at the throat's ring
    /// (`Tunnel.throat`) as the tunnel stands now.
    fn portalSetUp(record: *Record) void {
        record.portal.normal = .{ 0, 0, 1 };
        record.portal_at = record.tunnel.throat();
    }
};

/// How a tunnel stands in its object's frame: a half turn about the Y axis (`0x0041FE60`).
const tunnel_turn = math.fromAngles(0, std.math.pi, 0);

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

    fn build(tunnel: *Tunnel, gates: *const Gates, kind: Kind, size: f32) Allocator.Error!void {
        const gpa = gates.gpa;
        const grid = gates.grid;
        const split = gates.settings.tunnels.split();
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
        for (radii, 0..) |*radius, ring| radius.* = ringRadius(kind, grid.rings, ringAlong(ring, split), size);
        for (0..drawn.rings + 1) |ring| {
            for (0..drawn.segments) |segment| {
                const turn = segmentTurn(segment, drawn.segments);
                mesh.positions[vertexOf(drawn, ring, segment)] = .{ @sin(turn) * radii[ring], @cos(turn) * radii[ring], 0 };
            }
        }
        const uv = try mesh.addCoordinates(gpa);
        numberBands(&mesh, drawn.segments, drawn.rings);
        for (mesh.indices, uv) |index, *pair| pair.* = coordinatesOf(grid, split, index);
        // The game's last band, however finely it is split.
        const last_band = 2 * drawn.segments * split;
        mesh.surfaces[0] = .{
            .polygons = @intCast(polygons - last_band),
            .material = .{
                .two_pass = gates.hardware,
                ._unknown_01 = 0,
                .coordinates = .{ .mesh, .generated },
                .lit = .{ true, true },
                .blend = .{ .add, .add },
                .image = .{ .null, .null },
            },
            .textures = .{ .{ .image = gates.warp }, .{ .highlight = highlightOf(kind) } },
        };
        mesh.surfaces[1] = .{
            .polygons = @intCast(last_band),
            .material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .add }),
            .textures = .{ .{ .image = gates.warp }, .none },
        };
        srapi.calcPolyNormals(&mesh);
        srapi.calcVertexNormals(&mesh);
        srapi.findBoundingBox(&mesh);
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
        tunnel.colour(kind, gates.hardware);
    }

    fn deinit(tunnel: *Tunnel, gpa: Allocator) void {
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
    fn throat(tunnel: *const Tunnel) Vector {
        return tunnel.mesh.positions[vertexOf(tunnel.drawnGrid(), tunnel.grid.throat() * tunnel.split, 0)];
    }

    /// Each drawn vertex's colour from the game's vertices' about it (`Corners`).
    fn lay(tunnel: *Tunnel) void {
        for (tunnel.drawn_colours, 0..) |*shade, vertex| shade.* = Corners.of(tunnel.grid, tunnel.split, vertex).blend(@Vector(4, f32), tunnel.colours);
    }

    /// `0x0041D7D0`: each ring's colour on each of its vertices. The mouth's and the last ring are
    /// black and clear, and the ring before the last is the tunnel's deep colour. Between them a
    /// hardware renderer's tunnel runs from the mouth's colour to the middle's in a straight line
    /// over the first `palette_turn` of the rings, then to the end's by the square root
    /// (`Palette.at`): a proto gate's blue, an advanced gate's red. A software renderer's runs from
    /// white down to black, and its ring before the last is a mid grey.
    fn colour(tunnel: *Tunnel, kind: Kind, hardware: bool) void {
        const grid = tunnel.grid;
        const palette: Palette = if (kind == .advanced) .red else .blue;
        for (0..grid.rings + 1) |ring| {
            const shade: [4]f32 = if (ring == 0 or ring == grid.rings)
                @splat(0)
            else if (ring == grid.rings - 1)
                (if (hardware) opaque_(palette.last) else software_last)
            else if (hardware)
                opaque_(palette.at(ringShare(ring, grid.rings)))
            else
                grey(ease.linear(1, 0, ringShare(ring, grid.rings)));
            for (0..grid.segments) |segment| tunnel.colours[vertexOf(grid, ring, segment)] = shade;
        }
        tunnel.lay();
    }

    /// `0x0041FA50`: each vertex of each ring, `radii` from the axis at its segment's turn and at
    /// its ring's depth, the game's last ring at the depth of the one before. At the high detail
    /// the game's vertices each sway either way across the axis by `wobbleOf` times the segments,
    /// each at its own pace, by the frame's tick; a drawn vertex between them sways as those about
    /// it do (`Corners`).
    ///
    /// **Improvement:** the sines and cosines come from `std.math` rather than the engine's table.
    fn shape(tunnel: *Tunnel, kind: Kind, frame_start: i32) void {
        const grid = tunnel.grid;
        const drawn = tunnel.drawnGrid();
        const ticks: f32 = @floatFromInt(frame_start);
        const reach = @as(f32, @floatFromInt(grid.segments)) * wobbleOf(kind);
        var sways: [Grid.most_vertices]Vector = @splat(@splat(0));
        if (grid.segments == Grid.of(.high).segments) {
            for (sways[1..grid.vertices()], 1..) |*sway, vertex| sway.* = .{
                @sin(ticks * wobble_rate[0] + @as(f32, @floatFromInt(vertex * wobble_step[0])) * wobble_spread[0]) * reach,
                @sin(ticks * wobble_rate[1] + @as(f32, @floatFromInt(vertex * wobble_step[1])) * wobble_spread[1]) * reach,
                0,
            };
        }
        const last = (grid.rings - 1) * tunnel.split;
        for (tunnel.mesh.positions[1..], 1..) |*position, vertex| {
            const ring = (vertex - 1) / drawn.segments;
            const turn = segmentTurn((vertex - 1) % drawn.segments, drawn.segments);
            const across: Vector = .{ @sin(turn) * tunnel.radii[ring], @cos(turn) * tunnel.radii[ring], tunnel.depths[@min(ring, last)] };
            position.* = across + Corners.of(grid, tunnel.split, vertex).blend(Vector, &sways);
        }
    }

    /// `0x00422380`, as a gate collapses: the tunnel burns out, a flickering share of its vertices,
    /// `(sin(at * burn_flicker) + 1) / 2`, taking the burning colours (`wipe`).
    fn burnOut(tunnel: *Tunnel, at: f32) void {
        tunnel.wipe((@sin(at * burn_flicker) + 1) * 0.5, .burning);
    }

    /// `0x004221E0`, as the collapse ends: the tunnel fades, `at` of its vertices taking the fading
    /// colours (`wipe`).
    fn fadeOut(tunnel: *Tunnel, at: f32) void {
        tunnel.wipe(at, .fading);
    }

    /// The game's vertices, counted from the tunnel's centre, a vertex short of their rings' own as
    /// the game counts them, up to `share` of them all, take `look`'s colours, brightest where the
    /// share has just reached them (`Wipe.shade`): their rings' first and last black and clear.
    fn wipe(tunnel: *Tunnel, share: f32, look: Wipe) void {
        const grid = tunnel.grid;
        const count: f32 = @floatFromInt(tunnel.colours.len);
        const reach = count * share;
        for (0..grid.rings + 1) |ring| {
            for (0..grid.segments) |segment| {
                const vertex = ring * grid.segments + segment;
                const at: f32 = @floatFromInt(vertex);
                if (!(at <= reach)) continue;
                tunnel.colours[vertex] = if (ring == 0 or ring == grid.rings)
                    @splat(0)
                else
                    look.shade((reach - at) * (1 / (count - reach)), ring == grid.rings - 1);
            }
        }
        tunnel.lay();
    }

    /// `0x00420950`: scrolls the tunnel's texture across and along it by the time since it last
    /// did (`per_tick`, `scroll_rate`), from the tick `last` holds, which it moves on; the first
    /// time it only notes the tick.
    fn scroll(tunnel: *Tunnel, last: *i32, frame_start: i32) void {
        if (last.* == 0) {
            last.* = frame_start;
            return;
        }
        const time = @as(f32, @floatFromInt(frame_start -% last.*)) * per_tick;
        last.* = frame_start;
        for (tunnel.mesh.uv[0].?) |*pair| {
            pair[0] -= time * scroll_rate[0];
            pair[1] -= time * scroll_rate[1];
        }
    }
};

/// How fast the burning flickers (`0x004DC44C`).
const burn_flicker: f32 = 1000;

/// The colours a collapsing gate's tunnel wipes through: burning, then fading (`0x00422380`,
/// `0x004221E0`).
const Wipe = enum {
    burning,
    fading,

    /// Its colours at their brightest, on most rings and on the ring before the last: burning, a
    /// dull red and blue; fading, a pale grey and green.
    fn colours(look: Wipe) [2][3]f32 {
        return switch (look) {
            .burning => .{ .{ 1, 0.3, 0.5 }, .{ 0, 0.5, 1 } },
            .fading => .{ .{ 0.6, 0.7, 0.7 }, .{ 0.3, 1, 0.8 } },
        };
    }

    /// The colour of a vertex `past` of the way behind the wipe, clamped to 0 to 1: bright where
    /// the wipe has just reached it and dark well behind (`0x0041DCD0`, `ease.cosine`), and
    /// `last_level` as bright on the ring before the last.
    fn shade(look: Wipe, past: f32, last: bool) [4]f32 {
        const through: f32 = if (!(past <= 1)) 1 else if (past < 0) 0 else past;
        const level = ease.cosine(if (last) last_level else 1, 0, through);
        const colour = look.colours()[@intFromBool(last)];
        return .{ colour[0] * level, colour[1] * level, colour[2] * level, 1 };
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

/// The vertex of ring `ring` at segment `segment`, after the centre.
fn vertexOf(grid: Grid, ring: usize, segment: usize) usize {
    return 1 + ring * grid.segments + segment;
}

/// How far round the axis segment `segment` of `segments` stands, in radians (`0x004DC3EC`).
fn segmentTurn(segment: usize, segments: usize) f32 {
    return @as(f32, @floatFromInt(segment)) * std.math.tau / @as(f32, @floatFromInt(segments));
}

/// How far along the tunnel ring `ring` of `rings` stands, from 0 at the mouth to 1 at the last.
fn ringShare(ring: usize, rings: usize) f32 {
    return @as(f32, @floatFromInt(ring)) / @as(f32, @floatFromInt(rings));
}

/// The radius of a tunnel of `rings` at `ring` (`0x0041DD70`), which a fine tunnel takes between
/// the game's rings too (`Tunnels`). A gate's shrinks by a sixth at each ring from the mouth,
/// `size` times 344 or so there, whatever the rings; a warp's is 344 or so all along, whatever its
/// size. The game works it out in double precision as `profile_base` to the `profile_rings` times
/// `profile_rings`, over `profile_base` to the `rings` times `rings`; times `profile_base` to the
/// `rings` times `rings` for a warp, or to the `rings - ring` times `rings` times `size` for a
/// gate; times `radius_scale`.
fn ringRadius(kind: Kind, rings: usize, ring: f32, size: f32) f32 {
    const base: f64 = profile_base;
    const count: f64 = @floatFromInt(rings);
    const scale = std.math.pow(f64, base, profile_rings) * profile_rings / (std.math.pow(f64, base, count) * count);
    const radius = switch (kind) {
        .warp, .boridin => std.math.pow(f64, base, count) * scale * count,
        .proto, .advanced => std.math.pow(f64, base, count - ring) * count * scale * size,
    };
    return @floatCast(radius * radius_scale);
}

/// The tunnel's profile (`0x004DC5D0`, `0x004DC5C8`, `0x004DC5C0`).
const profile_base: f32 = 1.2;
const profile_rings: f64 = 8;
const radius_scale: f64 = 10;

/// The coordinates of a gate's tunnel on `grid` at `index` of the grid `split` times as fine it is
/// drawn on (`0x0041DD70`): how far along the game's rings it stands over `rings_per_u`, and its
/// height across a warp's tunnel's radius (`ringRadius`) in thousandths, as the game copies them
/// from a warp's tunnel 1000 across.
fn coordinatesOf(grid: Grid, split: usize, index: u16) [2]f32 {
    const vertex: usize = index;
    if (vertex == 0) return .{ 0, 0 };
    const drawn = grid.finer(split);
    const along = ringAlong((vertex - 1) / drawn.segments, split);
    const turn = segmentTurn((vertex - 1) % drawn.segments, drawn.segments);
    const radius = ringRadius(.warp, grid.rings, along, uv_size);
    return .{ along / rings_per_u, @cos(turn) * radius * uv_across };
}

/// The warp's tunnel the coordinates come from, its rings a unit of `u` apart for eight
/// (`0x004DC5B8`), and its height's scale (`0x004DC49C`).
const uv_size: f32 = 1000;
const rings_per_u: f32 = 8;
const uv_across: f32 = 0.001;

/// Numbers a tube's triangles, two for each segment between ring `ring - 1` and ring `ring`, from
/// the first ring on, and the indices of their corners: the near ring's corner and the far one's,
/// then the near ring's next; the near ring's next, the far ring's corner and its next.
fn numberBands(mesh: *srapiext.Mesh, segments: usize, rings: usize) void {
    mesh.numberPolygons(3);
    var at: usize = 0;
    for (1..rings + 1) |ring| {
        for (0..segments) |segment| {
            const next = (segment + 1) % segments;
            const near = 1 + (ring - 1) * segments;
            const far = 1 + ring * segments;
            const corners = [6]usize{ near + segment, far + segment, near + next, near + next, far + segment, far + next };
            for (corners) |corner| {
                mesh.indices[at] = @intCast(corner);
                at += 1;
            }
        }
    }
}

/// The colours a tunnel runs through, from its mouth to its end (`0x0041D7D0`, `0x00422AD0`): the
/// mouth's, the middle's `palette_turn` of the way along, the end's, and the ring before the
/// last's, in 256ths as the game writes them.
const Palette = struct {
    mouth: [3]f32,
    middle: [3]f32,
    end: [3]f32,
    last: [3]f32,

    const blue: Palette = .{
        .mouth = .{ 0.921875, 0.921875, 0.6640625 },
        .middle = .{ 0.19921875, 0.4296875, 0.76953125 },
        .end = .{ 0.046875, 0, 0.3125 },
        .last = .{ 0.1171875, 0.05859375, 0.625 },
    };
    const red: Palette = .{
        .mouth = .{ 1, 1, 0.859375 },
        .middle = .{ 0.76953125, 0.4296875, 0.19921875 },
        .end = .{ 0.3125, 0, 0.046875 },
        .last = .{ 0.625, 0.05859375, 0.1171875 },
    };

    /// The colour `share` of the way along: in a straight line from the mouth's to the middle's,
    /// then from the middle's to the end's by the square root.
    ///
    /// **Improvement:** the game scales the share by 3.3333 and 1.4286; OpenReliant divides by the
    /// spans those round.
    fn at(palette: Palette, share: f32) [3]f32 {
        var shade: [3]f32 = undefined;
        for (&shade, palette.mouth, palette.middle, palette.end) |*channel, mouth, middle, end| {
            channel.* = if (share < palette_turn)
                ease.linear(mouth, middle, share / palette_turn)
            else
                ease.out(middle, end, (share - palette_turn) / (1 - palette_turn));
        }
        return shade;
    }
};

/// How far along a tunnel its colours turn (`0x004DC4C0`).
const palette_turn: f32 = 0.3;

/// A software renderer's ring before the last (`0x0041D7D0`).
const software_last: [4]f32 = .{ 0.5, 0.5, 0.5, 1 };

fn opaque_(shade: [3]f32) [4]f32 {
    return .{ shade[0], shade[1], shade[2], 1 };
}

fn grey(level: f32) [4]f32 {
    return .{ level, level, level, 1 };
}

/// One of the two flashes a ship jumping in shows at the tunnel's throat (`+0x74`, `+0x78`): a
/// square (`loadout.squareMesh`, 25000 across) over the whole of the flashes' texture, added to
/// what is behind it by colours of its own.
pub const Square = struct {
    mesh: srapiext.Mesh,
    level: [1]srapiext.Level,
    object: srapiext.MeshObject,
    colours: [4][4]f32 = @splat(@splat(0)),
    /// How deep it stands in the tunnel's frame.
    depth: f32 = 0,

    fn build(square: *Square, gpa: Allocator, image: *srtexture.Image) Allocator.Error!void {
        var mesh = try loadout.squareMesh(gpa, false, square_side, square_side);
        errdefer mesh.deinit(gpa);
        // The corners the loadout's square leaves `loadout.square_span` across reach the texture's
        // far edge.
        const uv = mesh.uv[0].?;
        for ([_]usize{ 1, 3, 4 }) |index| uv[index][0] = 1;
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

    fn deinit(square: *Square, gpa: Allocator) void {
        square.mesh.deinit(gpa);
    }

    /// Sizes it `half` either way of its centre and colours it `shade` grey.
    fn set(square: *Square, half: f32, shade: f32) void {
        square.mesh.positions[0..4].* = .{ .{ -half, -half, 0 }, .{ half, -half, 0 }, .{ half, half, 0 }, .{ -half, half, 0 } };
        square.colours = @splat(.{ shade, shade, shade, square.colours[0][3] });
    }
};

const square_side: f32 = 25000;

/// The worm (`0x00422700`), which the player's ship rides from one gate to the next: a tube of
/// `worm_rings` rings, `worm_segments` round, `worm_radius` across and `worm_ring_spacing` apart,
/// drawn solid with the gates' texture by coordinates of its own and colours of its own (`colour`),
/// and a highlight added by its normals. Its last band is drawn in one pass.
pub const Worm = struct {
    mesh: srapiext.Mesh,
    level: [1]srapiext.Level,
    object: srapiext.MeshObject,
    colours: [][4]f32,

    const grid: Grid = .{ .segments = worm_segments, .rings = worm_rings - 1 };

    fn create(gpa: Allocator, image: *srtexture.Image) Allocator.Error!*Worm {
        const worm = try gpa.create(Worm);
        errdefer gpa.destroy(worm);
        const polygons = grid.polygons();
        var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = polygons, .vertices = grid.vertices(), .indices = polygons * 3, .surfaces = 2 });
        errdefer mesh.deinit(gpa);
        for (0..worm_rings) |ring| {
            for (0..worm_segments) |segment| {
                const turn = segmentTurn(segment, worm_segments);
                mesh.positions[vertexOf(grid, ring, segment)] = .{ @sin(turn) * worm_radius, @cos(turn) * worm_radius, @as(f32, @floatFromInt(ring)) * worm_ring_spacing };
            }
        }
        numberBands(&mesh, worm_segments, grid.rings);
        const uv = try mesh.addCoordinates(gpa);
        for (mesh.indices, uv) |index, *pair| {
            const at = mesh.positions[index];
            pair.* = .{ at[2] * worm_uv_along, at[1] * worm_uv_across };
        }
        mesh.surfaces[0] = .{
            .polygons = @intCast(polygons - 2 * worm_segments),
            .material = .{
                .two_pass = true,
                ._unknown_01 = 0,
                .coordinates = .{ .mesh, .generated },
                .lit = .{ true, true },
                .blend = .{ .off, .add },
                .image = .{ .null, .null },
            },
            .textures = .{ .{ .image = image }, .{ .highlight = worm_highlight } },
        };
        mesh.surfaces[1] = .{
            .polygons = @intCast(2 * worm_segments),
            .material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .off }),
            .textures = .{ .{ .image = image }, .none },
        };
        srapi.calcPolyNormals(&mesh);
        srapi.calcVertexNormals(&mesh);
        srapi.findBoundingBox(&mesh);
        const colours = try gpa.alloc([4]f32, grid.vertices());
        @memset(colours, @splat(0));
        worm.* = .{ .mesh = mesh, .level = undefined, .object = undefined, .colours = colours };
        worm.level = .{.{ .mesh = &worm.mesh, .until = std.math.inf(f32) }};
        worm.object = .{
            .flags = .{ .normals_second = true, .not_culled = true, .unbounded = true, .owns_mesh = true, .baked_object = true },
            .position = @splat(0),
            .radius = mesh.radius,
            .levels = &worm.level,
            .baked = colours,
        };
        worm.colour();
        return worm;
    }

    fn destroy(worm: *Worm, gpa: Allocator) void {
        worm.mesh.deinit(gpa);
        gpa.free(worm.colours);
        gpa.destroy(worm);
    }

    /// `0x00422AD0`: a proto gate's colours (`Palette.blue`) along its rings, its first and last
    /// black and clear.
    fn colour(worm: *Worm) void {
        for (0..worm_rings) |ring| {
            const shade: [4]f32 = if (ring == 0 or ring == grid.rings)
                @splat(0)
            else if (ring == grid.rings - 1)
                opaque_(Palette.blue.last)
            else
                opaque_(Palette.blue.at(@as(f32, @floatFromInt(ring)) * worm_ring_share));
            for (0..worm_segments) |segment| worm.colours[vertexOf(grid, ring, segment)] = shade;
        }
    }

    /// `0x004229B0`: each vertex, the centre too, swaying across and down by up to `worm_sway`, at
    /// its own pace by the frame's tick, about its place round the tube; the centre takes the place
    /// of the last segment.
    fn wobble(worm: *Worm, frame_start: i32) void {
        const ticks: f32 = @floatFromInt(frame_start);
        for (worm.mesh.positions, 0..) |*position, vertex| {
            const segment = @mod(@as(i64, @intCast(vertex)) - 1, worm_segments);
            const turn = segmentTurn(@intCast(segment), worm_segments);
            position[0] = @sin(turn) * worm_radius + @sin(ticks * wobble_rate[0] + @as(f32, @floatFromInt(vertex * wobble_step[0])) * worm_spread[0]) * worm_sway;
            position[1] = @cos(turn) * worm_radius + @sin(ticks * wobble_rate[1] + @as(f32, @floatFromInt(vertex * wobble_step[1])) * worm_spread[1]) * worm_sway;
        }
    }

    /// Scrolls its texture along it and across it by `time`, as the gates count it
    /// (`order_fixed_gate_jump_out`).
    fn scroll(worm: *Worm, time: f32) void {
        for (worm.mesh.uv[0].?) |*pair| {
            pair[0] += time * worm_scroll[0];
            pair[1] -= time * worm_scroll[1];
        }
    }
};

/// The worm's tube (`0x00422700`): its segments and rings, its radius (`0x004DC43C`), how far apart
/// its rings stand (`0x004DC640`), and its coordinates' scale along it (`0x004DC63C` times
/// `0x004DC638`) and across (`0x004DC4B0`).
const worm_segments = 16;
const worm_rings = 31;
const worm_radius: f32 = 10000;
const worm_ring_spacing: f32 = 200000;
const worm_uv_along: f32 = 3.3333333e-6 * 1.6;
const worm_uv_across: f32 = 1e-4;
/// The driver's highlight texture its second pass takes (`0x00422809`).
const worm_highlight = 0;
/// How far along its colours each ring stands (`0x004DC64C`).
const worm_ring_share: f32 = 1.0 / 30.0;
/// How far its vertices sway (`0x004DC438`), and their offsets' spread (`0x004DC648`,
/// `0x004DC644`).
const worm_sway: f32 = 2000;
const worm_spread = [2]f32{ 5.3, 4.4 };
/// How fast its texture scrolls along it and across it as the gates count time, 1.05 and 0.05 of it
/// a second (`0x004DC61C`, `0x004DC408`).
const worm_scroll = [2]f32{ 10.5, 0.5 };

// --- The orders ---------------------------------------------------------------------------

/// What the gates' orders keep in the object's order state.
pub const State = extern struct {
    _unknown_00: u32,
    /// Its step (`+0x04`).
    step: u32,
    /// The frame's tick of its last update (`+0x08`), which `progress` counts from.
    updated: i32,
    /// How far through its step it is (`+0x0C`).
    progress: f32,
    /// Jump In: whether it has let the tunnel go for the next ship (`+0x10`).
    let_go: bool,
    _unknown_11: [3]u8,
    /// Collapse: how many of its fireballs have gone off (`+0x14`).
    fireballs: i32,
    /// Jump In: whether it moves in a straight line, rather than easing in and out (`+0x18`).
    linear: bool,
    _unknown_19: [3]u8,
    /// Jump In: where it comes from, deep in the tunnel (`+0x1C`); where it goes, out beyond the
    /// mouth for Jump In and down the tunnel for Jump Out (`+0x28`).
    from: shp.Vec3,
    to: shp.Vec3,
    /// The portal that cuts it (`+0x34`), which OpenReliant reaches through its record.
    _unknown_34: u32,

    comptime {
        assert(@offsetOf(State, "progress") == 0x0C);
        assert(@offsetOf(State, "fireballs") == 0x14);
        assert(@offsetOf(State, "from") == 0x1C);
        assert(@offsetOf(State, "to") == 0x28);
        assert(@sizeOf(State) == 0x38);
    }
};

/// The steps of Jump In.
const InStep = enum(u32) {
    /// Waiting for the tunnel to be free.
    waiting = 0,
    coming = 1,
    done = 2,
    _,
};

/// The steps of Jump Out.
const OutStep = enum(u32) {
    /// Waiting for the last ship to go through.
    waiting = 0,
    /// Drawn down the tunnel.
    entering = 1,
    /// Gone, the player's ship riding the worm.
    riding = 2,
    done = 3,
    /// OpenReliant's: no gate has a tunnel to go out through, and the order ends.
    stranded = 4,
    _,
};

/// The time since the order last updated, as the gates count it (`per_tick`), the tick moved on
/// (`+0x08`).
fn sinceUpdate(state: *State, frame_start: i32) f32 {
    const since = frame_start -% state.updated;
    state.updated = frame_start;
    return @as(f32, @floatFromInt(since)) * per_tick;
}

/// Where `local`, in the tunnel's frame, stands in the world.
fn inTunnel(record: *const Record, all: *const create.Objects, local: Vector) Vector {
    return record.tunnelPlace(all).point(local);
}

/// The record of the gate the current order of the ship in slot `index` names; null, logged, for
/// none.
fn aimedRecord(ctx: aigeneric.Context, index: u16) ?*Record {
    const gates = ctx.world.gates orelse return null;
    const slot = &ctx.world.objects.slots[index];
    const target = slot.orders[0].target.slotIn(ctx.world.objects) orelse {
        log.warn("Bug in script - in a \"set_ai\" with ai function \"fixedgate_jump_in\", the target is NULL.  Sort it out!", .{});
        return null;
    };
    return gates.of(target) orelse {
        log.warn("object {d} has no gate to jump through at object {d}", .{ index, target });
        return null;
    };
}

/// `order_fixed_gate_jump_in_init` (`0x00420B80`): the ship in slot `index` comes in through the
/// tunnel at the object its order names. The portal cuts it (`xtrabits.clipTree`), from where it
/// comes, `start_player` or `start_other` in the tunnel's frame, to where it goes, `end_friendly`
/// or `end_other` beyond the mouth, turned about the tunnel's axis by `spread_step` for each step
/// of `Gates.spread`, which moves on: from -2 to 2, 0 passed over but by the player's ship, which
/// sets it to 0. It faces the way it goes, its lights' sprites hidden, untargetable, unpowered
/// and frozen, colliding with nothing where it lists no components; it goes in a straight line,
/// and the portal is set up (`Record.portalSetUp`). A Krasny in missions 16 and 66 comes out
/// straight ahead, and leaves the spread as it is.
///
/// **Fix:** the game asserts where the order names nothing, and reads the record before the first
/// where the object has no tunnel; OpenReliant logs either, and the order ends at its update.
pub fn jumpInInit(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const gates = world.gates orelse return;
    const slot = &all.slots[index];
    const state = &slot.state.gate;
    const record = aimedRecord(ctx, index) orelse return;
    state.let_go = false;
    if (slot.model) |*model| xtrabits.clipTree(model, &record.portal);
    const player = index == all.player;
    state.from = gameobj.vec3(inTunnel(record, all, if (player) start_player else start_other));
    const friendly = if (slot.combat) |combat| combat.side == .friendly else false;
    const beyond: Vector = .{ 0, 0, if (friendly) end_friendly else end_other };
    const turn = if (krasnyRun(all, index)) math.identity else spread: {
        const step: f32 = @floatFromInt(gates.spread);
        gates.spread += 1;
        break :spread math.fromAngles(0, step * spread_step, 0);
    };
    state.to = gameobj.vec3(inTunnel(record, all, math.transform(turn, beyond)));
    if (slot.model) |*model| showLightSprites(model, false);
    if (gates.spread > spread_most) gates.spread = -spread_most;
    if (player) {
        gates.spread = 0;
    } else if (gates.spread == 0) {
        gates.spread = 1;
    }
    ai.setTargetable(&slot.object, slot.combat, false);
    slot.object.flags.unpowered = true;
    slot.object.flags.frozen = true;
    objects.setOrientation(&slot.object, &slot.drawn, math.lookAt(gameobj.vector(state.to) - gameobj.vector(state.from)));
    if (!slot.object.flags.components) slot.object.flags.no_collisions = true;
    state.linear = true;
    record.portalSetUp();
    state.progress = 0;
    state.updated = ctx.clock.frame_start;
}

/// Where a ship comes from in the tunnel's frame: the player's a little above the axis, the rest
/// on it (`0x00420BF1`); where it goes, a friend farther out than the rest (`0x00420C52`); how far
/// the spread turns a ship's way out for each step (`0x004DC4C0`), and its bounds.
const start_player: Vector = .{ 0, 2000, 18000 };
const start_other: Vector = .{ 0, 0, 26000 };
const end_friendly: f32 = -53000;
const end_other: f32 = -25000;
const spread_step: f32 = 0.3;
const spread_most = 2;

/// Whether the ship in slot `index` is a Krasny in mission 16 or 66, which comes through its gate
/// as it collapses.
fn krasnyRun(all: *const create.Objects, index: u16) bool {
    return all.slots[index].object.type == .krasny and (all.mission_number == krasny_missions[0] or all.mission_number == krasny_missions[1]);
}

const krasny_missions = [2]u16{ 0x10, 0x42 };

/// `order_fixed_gate_jump_in` (`0x00420FD0`): Jump In's update, a step at a time (`InStep`).
///
/// It waits while another ship comes through the tunnel (`Record.busy`), save the player's ship,
/// which does not. Then it holds the tunnel, the flashes stand at the throat, and it starts where
/// it comes from, heard (`warpin`); for the player's ship the mission's space takes on what its
/// script asked of it (`environfx.Environment.update`). It goes to where it goes in 5 seconds
/// (`in_rate`), in a straight line (or easing in and out), letting the tunnel go half way.
/// Over the first `flash_share` of the way, while the player's ship is not riding the worm, the
/// flashes show: the first shrinking from `square_most` as it brightens, the second growing to it
/// as it dims, each by the square of how far through. Then it is powered, collides and can be
/// targeted again, its lights' sprites show, the portal lets it go, and the order ends; the ship's
/// FixedGateJumpedIn is posted, with the gate's (`events.fixedGateJumpedIn`).
///
/// A Krasny in missions 16 and 66 goes at `krasny_rate` instead and shows no flashes.
pub fn jumpIn(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.gate;
    const elapsed = sinceUpdate(state, ctx.clock.frame_start);
    const target = slot.orders[0].target.slotIn(all);
    const record = aimedRecord(ctx, index) orelse {
        _ = aigeneric.pop(ctx, index);
        return;
    };
    const gates = world.gates.?;
    switch (@as(InStep, @enumFromInt(state.step))) {
        .waiting => {
            if (record.busy and index != all.player) return;
            record.busy = true;
            for (&record.squares) |*square| square.depth = record.tunnel.throat()[2];
            state.progress = 0;
            state.step = @intFromEnum(InStep.coming);
            objects.setPosition(&slot.object, &slot.drawn, gameobj.vector(state.from));
            sound3d.playIn(world, null, null, index, .warpin, 1, .not_reserved);
            if (index == all.player) if (world.environment) |environment| environment.update();
        },
        .coming => {
            state.progress += elapsed * (if (krasnyRun(all, index)) krasny_rate else in_rate);
            var at: Vector = undefined;
            inline for (0..3) |axis| {
                const from = gameobj.vector(state.from)[axis];
                const to = gameobj.vector(state.to)[axis];
                at[axis] = if (state.linear) ease.linear(from, to, state.progress) else ease.cosine(from, to, state.progress);
            }
            objects.setPosition(&slot.object, &slot.drawn, at);
            slot.object.root.flags.committed = true;
            slot.object.root.flags.unframed = true;
            if (state.progress <= 1) {
                if (state.progress > let_go_at and !state.let_go) {
                    record.busy = false;
                    state.let_go = true;
                }
            } else {
                state.progress = 0;
                state.step = @intFromEnum(InStep.done);
            }
            if (gates.riding or !(state.progress < flash_share)) return;
            const through = state.progress / flash_share;
            record.squares[0].set(ease.in(square_most, square_least, through), through);
            record.squares[1].set(ease.in(square_least, square_most, through), 1 - through);
            if (!krasnyRun(all, index)) record.squares_shown = true;
        },
        .done => {
            slot.object.flags.no_collisions = false;
            slot.object.flags.unpowered = false;
            slot.object.flags.frozen = false;
            if (slot.model) |*model| {
                showLightSprites(model, true);
                xtrabits.clipTree(model, null);
            }
            ai.setTargetable(&slot.object, slot.combat, true);
            _ = aigeneric.pop(ctx, index);
            if (target) |gate| events.fixedGateJumpedIn(world, index, gate);
        },
        _ => {},
    }
}

/// How fast a ship comes through, twice the time passed (`0x004210C8`), and a Krasny in its
/// missions (`0x004DC618`); how far through it lets the tunnel go (`0x004DC408`); over how
/// much of the way the flashes show (`0x004DC3F8`), their pace through them (`0x004DC56C`), and
/// their sizes (`0x00421258`).
const in_rate: f32 = 2;
const krasny_rate: f32 = 0.13;
const let_go_at: f32 = 0.5;
const flash_share: f32 = 0.2;
const square_most: f32 = 12500;
const square_least: f32 = 0.001;

/// `0x00423050`: hides the sprites of every light of `model` and of the models it carries
/// (node kind 3), or shows them again.
fn showLightSprites(model: *objects.Model, shown: bool) void {
    for (model.lights) |*light| {
        if (light.sprites) |*sprites| sprites.set.flags.hidden = !shown;
    }
    for (0..model.parts.len) |index| {
        var each = model.carriedBy(index);
        while (each.next()) |mount| showLightSprites(&mount.model, shown);
    }
}

/// `order_fixed_gate_jump_out_init` (`0x00420DD0`): the ship in slot `index` goes out through the
/// nearest gate's tunnel, whatever its order names: its inputs, its rates and its speed at nothing,
/// colliding with nothing, frozen and unpowered, the portal cutting it, and where it goes
/// `exit_player` or `exit_other` down the tunnel. The portal is set up (`Record.portalSetUp`), the
/// player's ship's worm made (`Worm`), and it can no longer be targeted.
///
/// **Fix:** the game takes the record its order names for the portal that cuts the ship, and the
/// record before the first where no gate has a tunnel; OpenReliant takes the nearest gate's for
/// both, and ends the order where there is none.
pub fn jumpOutInit(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const gates = world.gates orelse return;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.gate;
    const record = nearest(gates, all, slot.drawn.position) orelse {
        log.warn("object {d} has no gate to jump out through", .{index});
        state.step = @intFromEnum(OutStep.stranded);
        return;
    };
    object.yaw_input = 0;
    object.pitch_input = 0;
    object.roll_input = 0;
    object.speed = 0;
    object.yaw_rate = 0;
    object.pitch_rate = 0;
    object.roll_rate = 0;
    object.flags.no_collisions = true;
    object.flags.frozen = true;
    object.flags.unpowered = true;
    if (slot.model) |*model| xtrabits.clipTree(model, &record.portal);
    state.to = gameobj.vec3(inTunnel(record, all, .{ 0, 0, if (index == all.player) exit_player else exit_other }));
    record.portalSetUp();
    if (index == all.player) {
        if (gates.worm) |worm| worm.destroy(gates.gpa);
        gates.worm = Worm.create(gates.gpa, gates.warp) catch |err| worm: {
            log.warn("the worm is left out: {s}", .{@errorName(err)});
            break :worm null;
        };
    }
    state.progress = 0;
    state.updated = ctx.clock.frame_start;
    ai.setTargetable(object, slot.combat, false);
}

/// How far down the tunnel a ship goes out: the player's and the rest (`0x00420E9B`).
const exit_player: f32 = 12000;
const exit_other: f32 = 26000;

/// The record of the fixed gate whose tunnel stands nearest `at`.
fn nearest(gates: *const Gates, all: *const create.Objects, at: Vector) ?*Record {
    var best: ?*Record = null;
    var best_distance = std.math.floatMax(f32);
    for (gates.records) |held| {
        const record = held orelse continue;
        const distance = math.distanceSquared(record.tunnelPlace(all).position, at);
        if (distance < best_distance) {
            best = record;
            best_distance = distance;
        }
    }
    return best;
}

/// `order_fixed_gate_jump_out` (`0x00421510`): Jump Out's update, a step at a time (`OutStep`).
///
/// It waits while another ship goes out through a tunnel (`Gates.exiting`), then holds it. It is
/// drawn toward where it goes, a share of the rest of the way each frame that grows by `out_rate`
/// as the gates count time, until it is within `arrived_within`: then it is gone to `slot` times
/// `away_spacing` along X and `away_depth` along Z, and the player's ship rides the worm, which
/// stands where the ship does, turned as it is, the screen flashing. While it rides, the worm sways
/// (`Worm.wobble`) and its texture scrolls, and at random the view shakes and flashes and the ride
/// rumbles (`Gates.rumbles`, `ride_sound`); whatever the ship, the ride lasts 4 seconds
/// (`ride_rate`). Then the player's ship leaves the worm, flashing and shaking, the tunnels are
/// free, the ship is powered and collides again, the portal lets it go, and its order gives way to
/// Fixed Gate Jump In through the gate its order names.
///
/// **Fix:** the game turns the ship as it is drawn toward the angles of a matrix it never fills,
/// whatever the stack holds there; OpenReliant leaves it turned as it is.
pub fn jumpOut(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const gates = world.gates orelse return;
    const slot = &all.slots[index];
    const state = &slot.state.gate;
    const elapsed = sinceUpdate(state, ctx.clock.frame_start);
    const player = index == all.player;
    switch (@as(OutStep, @enumFromInt(state.step))) {
        .waiting => {
            if (gates.exiting) return;
            gates.exiting = true;
            state.progress = 0;
            state.step = @intFromEnum(OutStep.entering);
        },
        .entering => {
            const at = math.lerp(gameobj.vector(slot.object.root.position), gameobj.vector(state.to), state.progress);
            objects.setPosition(&slot.object, &slot.drawn, at);
            slot.object.root.flags.committed = true;
            slot.object.root.flags.unframed = true;
            state.progress += elapsed * out_rate;
            if (!(math.distance(slot.drawn.position, gameobj.vector(state.to)) < arrived_within)) return;
            state.progress = 0;
            state.step = @intFromEnum(OutStep.riding);
            objects.setPosition(&slot.object, &slot.drawn, .{ @as(f32, @floatFromInt(index)) * away_spacing, 0, away_depth });
            if (!player) return;
            gates.riding = true;
            gates.rumbled_at = ctx.clock.frame_start;
            if (gates.worm) |worm| {
                worm.object.position = gameobj.vector(slot.object.root.position);
                worm.object.orientation = slot.object.root.orientation;
            }
            if (world.flash) |flash| flash.start();
        },
        .riding => {
            if (player) {
                if (gates.worm) |worm| {
                    gates.worm_shown = true;
                    worm.wobble(ctx.clock.frame_start);
                    worm.scroll(elapsed);
                }
                if (gates.rumbles(world.random, ctx.clock.frame_start)) {
                    if (world.camera) |view| view.hit_shake = ride_shake;
                    if (world.flash) |flash| flash.start();
                    if (world.hearing) |hearing| hearing.sound.bufferAt(ride_sound, slot.drawn.position, hearing.camera.*, slot.object.radius * ride_loudness);
                }
            }
            state.progress += elapsed * ride_rate;
            if (!(state.progress > 1)) return;
            state.progress = 0;
            state.step = @intFromEnum(OutStep.done);
        },
        .done => {
            if (player) {
                if (world.flash) |flash| flash.start();
                if (world.camera) |view| view.hit_shake = ride_shake;
                gates.riding = false;
            }
            gates.exiting = false;
            slot.object.flags.no_collisions = false;
            slot.object.flags.frozen = false;
            slot.object.flags.unpowered = false;
            if (slot.model) |*model| xtrabits.clipTree(model, null);
            const gate = slot.orders[0].target;
            _ = aigeneric.pop(ctx, index);
            _ = aigeneric.pushShip(ctx, index, .fixed_gate_jump_in, gate.slot() orelse return, aigeneric.Target.whole) catch |err| {
                log.warn("object {d} does not jump in: {s}", .{ index, @errorName(err) });
            };
        },
        .stranded => _ = aigeneric.pop(ctx, index),
        _ => {},
    }
}

/// How fast a ship is drawn down the tunnel (`0x004DC484`), how near it must come (`0x004DC5A8`),
/// where it waits while it is gone (`0x004DC4F8`, `0x0042166D`), how fast the ride goes
/// (`0x004DC59C`), and the chance it rumbles at each draw (`0x004DC53C`, `Gates.rumbles`), with its
/// shake, its sound in `bank_stdsmp` and its loudness by the ship's radius (`0x004DC438`).
const out_rate: f32 = 0.7;
const arrived_within: f32 = 400;
const away_spacing: f32 = 1e6;
const away_depth: f32 = -2.5e7;
const ride_rate: f32 = 2.5;
const rumble_chance: f32 = 0.025;
const ride_shake: f32 = 3;
const ride_sound = 10;
const ride_loudness: f32 = 2000;

/// `order_fixed_gate_open_init` (`0x004218A0`): a tunnel of a proto gate's colours, or an advanced
/// gate's where one is among the objects, is made at the object in slot `index` (`Gates.make`),
/// and the gate is heard opening (`gateopen`).
pub fn openInit(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const gates = world.gates orelse return;
    const advanced = for (all.slots[0..all.count]) |*slot| {
        if (slot.object.type == .advanced_gate) break true;
    } else false;
    _ = gates.make(world, index, if (advanced) .advanced else .proto, @splat(0)) catch |err| {
        log.warn("object {d} opens no tunnel: {s}", .{ index, @errorName(err) });
    };
    sound3d.playIn(world, null, null, index, .gateopen, 1, .guaranteed);
}

/// `order_fixed_gate_close_init` (`0x00421920`): the gate at the object in slot `index` is heard
/// closing (`gateclos`).
pub fn closeInit(ctx: aigeneric.Context, index: u16) void {
    sound3d.playIn(ctx.world, null, null, index, .gateclos, 1, .guaranteed);
}

/// `order_fixed_gate_open` (`0x00421940`): the tunnel at the object in slot `index` grows, easing
/// in and out from `closed_scale` to its full size over 1.1 seconds (`open_rate`) by the time since
/// it was last drawn (`Record.drawn_at`); then the order ends.
///
/// **Fix:** the game reads the record before the first where the object has no tunnel;
/// OpenReliant ends the order.
pub fn open(ctx: aigeneric.Context, index: u16) void {
    swing(ctx, index, .opening);
}

/// `order_fixed_gate_close` (`0x00421A00`): the tunnel shrinks likewise from its full size to
/// `closed_scale`; then it is let go of (`Gates.free`), and the order ends.
///
/// **Fix:** as for Open.
pub fn close(ctx: aigeneric.Context, index: u16) void {
    swing(ctx, index, .closing);
}

const Swing = enum { opening, closing };

/// The steps of Open and Close.
const SwingStep = enum(u32) {
    swinging = 0,
    done = 1,
    _,
};

fn swing(ctx: aigeneric.Context, index: u16, way: Swing) void {
    const gates = ctx.world.gates orelse return;
    const state = &ctx.world.objects.slots[index].state.gate;
    const record = gates.of(index) orelse {
        log.warn("object {d} has no tunnel for {s}", .{ index, @tagName(way) });
        _ = aigeneric.pop(ctx, index);
        return;
    };
    switch (@as(SwingStep, @enumFromInt(state.step))) {
        .swinging => {
            const since: u32 = @bitCast(ctx.clock.frame_start -% record.drawn_at);
            record.progress += @as(f32, @floatFromInt(since)) * per_tick * open_rate;
            record.tunnel.object.scale = switch (way) {
                .opening => ease.cosine(closed_scale, 1, record.progress),
                .closing => ease.cosine(1, closed_scale, record.progress),
            };
            if (record.progress > 1) {
                record.progress = 0;
                state.step = @intFromEnum(SwingStep.done);
            }
        },
        .done => {
            if (way == .closing) gates.freeRecord(record);
            _ = aigeneric.pop(ctx, index);
        },
        _ => {},
    }
}

/// How fast a tunnel opens and closes, as the gates count time, and its size closed (`0x004DC620`,
/// `0x38D1B717`).
const open_rate: f32 = 9;
const closed_scale: f32 = 0.0001;

/// `order_fixed_gate_collapse_init` (`0x00421AC0`): the gate in slot `index` starts to collapse,
/// logged; a proto gate's hull burns (`explode.burnPart`) with flickering rays alone, for a while,
/// and the screen flashes.
///
/// Not ported: in missions 16 and 66, the Krasny's split where it is coming through the gate
/// ([#407](https://github.com/vdmkenny/openreliant/issues/407)).
pub fn collapseInit(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    log.info(">>>>>>Starting gate collapse at {d}", .{ctx.clock.frame_start});
    const state = &world.objects.slots[index].state.gate;
    state.progress = 0;
    state.fireballs = 0;
    if (world.objects.slots[index].object.type == .proto_gate) explode.burnPart(world, index, proto_hull, .{ .forever = false, .flickers = true, .lights = false });
    if (world.flash) |flash| flash.start();
}

/// The gates' parts the collapse works on (`0x004E4138`, `0x004E41B8`, `0x004E4198`, `0x004E41AC`,
/// `0x004E41A4`, `0x004E4168`).
const proto_hull = "Protogate";
const advanced_hull = "OuterRing";
const proto_ring = "forcering";
const advanced_rings = [2][]const u8{ "InnerRing", "Tube11" };
const force_field = "forcefield";

/// How fast the gates' rings turn: an advanced gate's inner ring at four times its track's pace
/// (`0x004682E2`, `0x00421DD8`), the rest at their tracks' pace (`0x00467DCE`, `0x00421E13`), which
/// `create.gateMade` starts them at and the collapse slows them from.
pub const inner_ring_speed: f32 = 4;
pub const ring_speed: f32 = 1;

/// `order_fixed_gate_collapse` (`0x00421B80`): the collapse's update, a step at a time
/// (`CollapseStep`), its time counted from the tunnel's last frame (`Record.drawn_at`), which it
/// moves on.
///
/// 1. Fireballs go off, `collapse_fireballs` over its 10 seconds, at each point of the hull's cut
///    list in turn (a proto gate's `Protogate`, any other's `OuterRing`), `collapse_large` across,
///    a seventh of them heard (`explosion02`); each frame the hull's parts lose their second pass,
///    at random, `pass_off_chance` of the time (`secondPasses`). After 10 seconds they lose it for
///    good, and the screen flashes.
/// 2. Over the first `ring_stop_share` its rings slow to a stop from their pace: a proto gate's
///    `forcering` from `ring_speed`, an advanced gate's `InnerRing` from `inner_ring_speed` and
///    `Tube11` from `ring_speed`. At random, `fireball_chance` of the frames, a fireball goes off at
///    a random point of the cut list, `collapse_small` across. The tunnel burns out (`burnOut`),
///    and the gate shakes, unpowered, by `shake` along each axis at random; a proto gate's step
///    lasts 20 seconds, any other's 40, its tunnel burning out twice as fast.
/// 3. The tunnel fades to black (`fadeOut`) over 1.7 seconds.
/// 4. It is logged; any gate but a proto gate lets its tunnel go, an advanced gate losing its hull
///    (`ai.hullLost`); a gate's `forcefield` is hidden, and the order ends.
///
/// **Fix:** the game logs where the gate has no tunnel and reads the record before the first;
/// OpenReliant ends the order.
///
/// Not ported: the Krasny's split in missions 16 and 66, which holds the second step
/// ([#407](https://github.com/vdmkenny/openreliant/issues/407)).
pub fn collapse(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const gates = world.gates orelse return;
    const slot = &all.slots[index];
    const state = &slot.state.gate;
    const record = gates.of(index) orelse {
        log.info(">>>>>>>>>Can't find gate (index = -1) at {d}", .{ctx.clock.frame_start});
        _ = aigeneric.pop(ctx, index);
        return;
    };
    const frame_start = ctx.clock.frame_start;
    const since: u32 = @bitCast(frame_start -% record.drawn_at);
    record.drawn_at = frame_start;
    const elapsed = @as(f32, @floatFromInt(since)) * per_tick;
    const proto = slot.object.type == .proto_gate;
    switch (@as(CollapseStep, @enumFromInt(state.step))) {
        .fireballs => {
            state.progress += elapsed;
            if (math.round(state.progress * collapse_fireballs) > state.fireballs) {
                if (cutPoint(slot, proto, std.math.cast(usize, state.fireballs) orelse 0)) |at| {
                    explode.fireballAt(world, at, .{ .size = world.random.fraction() * collapse_large[1] + collapse_large[0], .life = fireball_life, .light = true });
                    state.fireballs += 1;
                    if (@rem(state.fireballs, heard_every) == 0) sound3d.playIn(world, at, null, -1, .explosion02, 1, .not_reserved);
                } else state.fireballs += 1;
            }
            secondPasses(slot, !(world.random.fraction() < pass_off_chance));
            if (!(state.progress >= 1)) return;
            if (world.flash) |flash| flash.start();
            secondPasses(slot, false);
            state.progress = 0;
            state.step = @intFromEnum(CollapseStep.burning);
        },
        .burning => {
            if (state.progress < ring_stop_share) if (slot.model) |*model| {
                const share = state.progress / ring_stop_share;
                if (proto) {
                    setSpeed(model, proto_ring, ease.linear(ring_speed, 0, share));
                } else if (slot.object.type == .advanced_gate) {
                    setSpeed(model, advanced_rings[0], ease.linear(inner_ring_speed, 0, share));
                    setSpeed(model, advanced_rings[1], ease.linear(ring_speed, 0, share));
                }
            };
            if (world.random.fraction() < fireball_chance) {
                const point = std.math.cast(usize, math.round(world.random.fraction() * collapse_fireballs)) orelse 0;
                if (cutPoint(slot, proto, point)) |at| {
                    explode.fireballAt(world, at, .{ .size = world.random.fraction() * collapse_small[1] + collapse_small[0], .life = fireball_life, .light = true });
                }
            }
            const rate: f32 = if (proto) proto_burn_rate else other_burn_rate;
            record.tunnel.burnOut(if (proto) state.progress else state.progress + state.progress);
            state.progress += elapsed * rate;
            slot.object.flags.unpowered = true;
            var shaken = slot.drawn.position;
            inline for (0..3) |axis| shaken[axis] += if (world.random.centred() < 0) -shake else shake;
            objects.setPosition(&slot.object, &slot.drawn, shaken);
            if (!(state.progress >= 1)) return;
            state.progress = 0;
            state.step = @intFromEnum(CollapseStep.fading);
        },
        .fading => {
            record.tunnel.fadeOut(state.progress);
            state.progress += elapsed * fade_rate;
            if (state.progress >= 1) state.step = @intFromEnum(CollapseStep.fallen);
        },
        .fallen => {
            log.info(">>>>>>Gate fully collapsed at {d}", .{frame_start});
            if (!proto) gates.freeRecord(record);
            if (slot.object.type == .advanced_gate) ai.hullLost(ctx, index);
            if (proto or slot.object.type == .advanced_gate) if (slot.model) |*model| {
                if (model.partNamed(force_field)) |ref| ref.part().hidden = true;
            };
            _ = aigeneric.pop(ctx, index);
        },
        _ => {},
    }
}

/// The steps of Collapse.
const CollapseStep = enum(u32) {
    /// The fireballs go off along the hull.
    fireballs = 0,
    /// The rings stop, and the tunnel burns out.
    burning = 1,
    fading = 2,
    fallen = 3,
    _,
};

/// The collapse's fireballs: how many go off along the cut list over its first step (`0x004DC630`),
/// how large they are, from the first to the first and second together (`0x004DC62C`,
/// `0x004DC508`; `0x004DC628`, `0x004DC44C`), how long they last, how often one is heard, and how
/// often one goes off at random in the second step (`0x004DC474`).
const collapse_fireballs: f32 = 55;
const collapse_large = [2]f32{ 5500, 3000 };
const collapse_small = [2]f32{ 3500, 1000 };
const fireball_life = 150;
const heard_every = 7;
const fireball_chance: f32 = 0.05;
/// How often a frame of the first step drops the second passes (`0x004DC4C0`).
const pass_off_chance: f32 = 0.3;
/// How far through the second step the rings stop (`0x004DC3F8`).
const ring_stop_share: f32 = 0.2;
/// How fast the second step goes, as the gates count time, for a proto gate and for the rest
/// (`0x004DC408`, `0x004DC3D4`); how far the gate shakes (`0x004DC624`); how fast the tunnel
/// fades (`0x004DC400`).
const proto_burn_rate: f32 = 0.5;
const other_burn_rate: f32 = 0.25;
const shake: f32 = 15;
const fade_rate: f32 = 6;

/// Point `point` of the cut list of the gate's hull, `Protogate` or `OuterRing`, in the world as
/// the part is drawn; null where the gate has no such part or point.
fn cutPoint(slot: *create.Slot, proto: bool, point: usize) ?Vector {
    const model = if (slot.model) |*live| live else return null;
    const ref = model.partNamed(if (proto) proto_hull else advanced_hull) orelse return null;
    const data = ref.data() orelse return null;
    const cut = data.pointList(.cut) orelse return null;
    if (point >= cut.points.len) return null;
    return ref.part().drawn().point(gameobj.vector(cut.points[point].position));
}

/// Sets the animation speed of the part of `model` named `name`, where it has one.
fn setSpeed(model: *objects.Model, name: []const u8, speed: f32) void {
    const ref = model.partNamed(name) orelse return;
    ref.part().animation.speed = speed;
}

/// `0x00422680`: turns the second pass on or off of each surface with a second texture of every
/// part of the gate in `slot`, which its type's meshes hold, so that every gate of the type goes
/// with it.
///
/// Not ported: the parts of models the gate carries, which the game's walk of its nodes reaches
/// too; no gate carries any.
fn secondPasses(slot: *create.Slot, on: bool) void {
    const loaded = (slot.type orelse return).loaded;
    for (loaded.parts) |*part| {
        for (part.meshes) |*mesh| {
            for (mesh.surfaces) |*surface| {
                if (surface.textures[1] != .none) surface.material.two_pass = on;
            }
        }
    }
}

pub const testing = struct {
    /// The gates over a table holding nothing but their textures.
    pub const Built = struct {
        textures: *srtexture.testing.Textures,
        gates: Gates,

        pub fn init(built: *Built, gpa: Allocator) !void {
            built.textures = try .init(gpa, &.{ warp_texture, software_warp_texture, flash_texture });
            errdefer built.textures.deinit(gpa);
            built.gates = try .init(gpa, &built.textures.table, .high, true, .{});
        }

        pub fn deinit(built: *Built, gpa: Allocator) void {
            built.gates.deinit();
            built.textures.deinit(gpa);
        }
    };
};

test Grid {
    const high: Grid = .of(.high);
    try std.testing.expectEqual(16 * 13 + 1, high.vertices());
    try std.testing.expectEqual(12 * 16 * 2, high.polygons());
    try std.testing.expectEqual(7, high.throat());
    try std.testing.expectEqual(1, Grid.of(.low).throat());
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

test Tunnel {
    const gpa = std.testing.allocator;
    var built: testing.Built = undefined;
    try built.init(gpa);
    defer built.deinit(gpa);
    built.gates.settings = .original;
    const grid = built.gates.grid;
    var tunnel: Tunnel = undefined;
    try tunnel.build(&built.gates, .proto, proto_size);
    defer tunnel.deinit(gpa);

    // A ring of vertices round the axis at each ring's radius, flat until it is shaped.
    const first = tunnel.mesh.positions[vertexOf(grid, 0, 0)];
    try std.testing.expectApproxEqRel(tunnel.radii[0], first[1], 1e-5);
    try std.testing.expectEqual(0, first[2]);
    // Each band two triangles a segment, the last band drawn in one pass.
    try std.testing.expectEqualSlices(u16, &.{ 1, 17, 2, 2, 17, 18 }, tunnel.mesh.indices[0..6]);
    try std.testing.expectEqual(grid.polygons() - 32, tunnel.mesh.surfaces[0].polygons);
    try std.testing.expect(tunnel.mesh.surfaces[0].material.two_pass and !tunnel.mesh.surfaces[1].material.two_pass);
    try std.testing.expectEqual(srapiext.Texture{ .highlight = 7 }, tunnel.mesh.surfaces[0].textures[1]);
    // The coordinates run a unit along for eight rings.
    try std.testing.expectEqual(1, coordinatesOf(grid, 1, @intCast(vertexOf(grid, 8, 0)))[0]);
    // Black and clear at the mouth and at the end, the deep colour on the ring before it, and
    // drawn so.
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, tunnel.colours[vertexOf(grid, 0, 3)]);
    try std.testing.expectEqual(opaque_(Palette.blue.last), tunnel.colours[vertexOf(grid, grid.rings - 1, 3)]);
    try std.testing.expectEqualSlices([4]f32, tunnel.colours, tunnel.drawn_colours);

    // Shaped, each ring stands at its depth, the last at the one before's, and sways at the high
    // detail.
    for (tunnel.depths, 0..) |*depth, ring| depth.* = @floatFromInt(ring * 100);
    tunnel.shape(.proto, 0);
    try std.testing.expectEqual(500, tunnel.mesh.positions[vertexOf(grid, 5, 2)][2]);
    try std.testing.expectEqual(1100, tunnel.mesh.positions[vertexOf(grid, grid.rings, 2)][2]);
    try std.testing.expect(tunnel.mesh.positions[vertexOf(grid, 5, 2)][0] != @sin(segmentTurn(2, 16)) * tunnel.radii[5]);
    try std.testing.expectEqual(tunnel.mesh.positions[vertexOf(grid, grid.throat(), 0)], tunnel.throat());

    // The collapse's fade reaches its share of the vertices, from the centre on.
    tunnel.fadeOut(0.5);
    try std.testing.expect(tunnel.colours[vertexOf(grid, 2, 3)][3] == 1 and tunnel.colours[vertexOf(grid, 2, 3)][0] < 0.6);
    try std.testing.expectEqual(opaque_(Palette.blue.last), tunnel.colours[vertexOf(grid, grid.rings - 1, 3)]);
    try std.testing.expectEqualSlices([4]f32, tunnel.colours, tunnel.drawn_colours);
}

test "a fine tunnel passes through the game's vertices and follows its curves between them" {
    const gpa = std.testing.allocator;
    var built: testing.Built = undefined;
    try built.init(gpa);
    defer built.deinit(gpa);
    const grid = built.gates.grid;
    var fine: Tunnel = undefined;
    try fine.build(&built.gates, .advanced, advanced_size);
    defer fine.deinit(gpa);
    built.gates.settings = .original;
    var game: Tunnel = undefined;
    try game.build(&built.gates, .advanced, advanced_size);
    defer game.deinit(gpa);

    const split = fine_split;
    const drawn = grid.finer(split);
    try std.testing.expectEqual(drawn.vertices(), fine.mesh.positions.len);
    // The game's last band is drawn in one pass, however finely it is split.
    try std.testing.expectEqual(2 * drawn.segments * split, fine.mesh.surfaces[1].polygons);
    try std.testing.expectEqual(drawn.polygons(), fine.mesh.surfaces[0].polygons + fine.mesh.surfaces[1].polygons);

    // Shaped at the same tick, with the game's spacing, it stands where the game's does at the
    // game's vertices, sway and all, and is as long.
    for (fine.depths, 0..) |*depth, ring| depth.* = ringAlong(ring, split) * ring_spacing;
    for (game.depths, 0..) |*depth, ring| depth.* = ringAlong(ring, 1) * ring_spacing;
    fine.shape(.advanced, 1234);
    game.shape(.advanced, 1234);
    for (0..grid.rings + 1) |ring| {
        for (0..grid.segments) |segment| {
            const expected = game.mesh.positions[vertexOf(grid, ring, segment)];
            const found = fine.mesh.positions[vertexOf(drawn, ring * split, segment * split)];
            inline for (0..3) |axis| try std.testing.expectApproxEqAbs(expected[axis], found[axis], 1e-2);
        }
    }
    try std.testing.expectEqual(game.throat(), fine.throat());
    // Between the game's rings, its radius follows the game's curve, a sixth narrower a ring.
    try std.testing.expectApproxEqRel(fine.radii[0] / std.math.sqrt(1.2), fine.radii[split / 2], 1e-5);
    // Its colours are the game's at the game's vertices, and between them as the game's are drawn.
    try std.testing.expectEqual(game.drawn_colours[vertexOf(grid, 3, 5)], fine.drawn_colours[vertexOf(drawn, 3 * split, 5 * split)]);
    const halfway = fine.drawn_colours[vertexOf(drawn, 3 * split + split / 2, 5 * split)];
    for (halfway, game.colours[vertexOf(grid, 3, 5)], game.colours[vertexOf(grid, 4, 5)]) |found, near, far| {
        try std.testing.expectApproxEqAbs((near + far) / 2, found, 1e-6);
    }
    // Its texture lies along it as the game's does, a unit for eight of the game's rings.
    try std.testing.expectEqual(coordinatesOf(grid, 1, @intCast(vertexOf(grid, 8, 0))), coordinatesOf(grid, split, @intCast(vertexOf(drawn, 8 * split, 0))));
    try std.testing.expectEqual(0.5, coordinatesOf(grid, split, @intCast(vertexOf(drawn, 4 * split, 0)))[0]);
}

test "the ride through the worm draws its rumbles at the pace of the simulation's steps" {
    const gpa = std.testing.allocator;
    var built: testing.Built = undefined;
    try built.init(gpa);
    defer built.deinit(gpa);
    const gates = &built.gates;
    var random: libcmt.Rand = .{};
    var expected = random;

    // A frame each tick draws a number on every fourth.
    for (1..4) |now| _ = gates.rumbles(&random, @intCast(now));
    try std.testing.expectEqual(expected, random);
    _ = gates.rumbles(&random, 4);
    _ = expected.fraction();
    try std.testing.expectEqual(expected, random);
    // A frame of twelve ticks draws three.
    _ = gates.rumbles(&random, 16);
    for (0..3) |_| _ = expected.fraction();
    try std.testing.expectEqual(expected, random);
    // The original's draws one each frame.
    gates.settings.rumbles = .original;
    _ = gates.rumbles(&random, 17);
    _ = expected.fraction();
    try std.testing.expectEqual(expected, random);
}

test "a tunnel opens at an object and closes again" {
    const gpa = std.testing.allocator;
    var built: testing.Built = undefined;
    try built.init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const point = try mission.addOther(@splat(0));
    var ctx = mission.orders();
    ctx.world.gates = &built.gates;

    _ = try aigeneric.push(ctx, point, .fixed_gate_open, .none);
    aigeneric.objectOrders(ctx, point);
    const record = built.gates.of(point).?;
    try std.testing.expectEqual(Kind.proto, record.kind);
    // Over a ninth of a thousand ticks it grows to its full size, drawn each frame, and the order
    // ends.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    for (0..120) |_| {
        mission.clock.frame_start += 1;
        aigeneric.objectOrders(ctx, point);
        scene.clear();
        try built.gates.draw(gpa, &scene, mission.objects, mission.clock.frame_start);
    }
    try std.testing.expectApproxEqAbs(1, record.tunnel.object.scale, 1e-3);
    try std.testing.expectEqual(0, mission.slot(point).object.order_count);
    // Drawn, its portal and its tunnel are in the world's layer.
    try std.testing.expectEqual(1, scene.portals.items.len);
    try std.testing.expectEqual(&record.tunnel.object, scene.layers.get(.world).items[0].mesh);

    _ = try aigeneric.push(ctx, point, .fixed_gate_close, .none);
    for (0..120) |_| {
        mission.clock.frame_start += 1;
        aigeneric.objectOrders(ctx, point);
        if (built.gates.of(point) != null) try built.gates.draw(gpa, &scene, mission.objects, mission.clock.frame_start);
    }
    try std.testing.expectEqual(null, built.gates.of(point));
    try std.testing.expectEqual(0, mission.slot(point).object.order_count);
}

test "a ship comes in through a gate" {
    const gpa = std.testing.allocator;
    var built: testing.Built = undefined;
    try built.init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    _ = try mission.add(.predator, @splat(0));
    const ship = try mission.add(.predator, .{ 0, 0, -100000 });
    const gate = try mission.add(.proto_gate, @splat(0));
    var ctx = mission.orders();
    ctx.world.gates = &built.gates;
    const record = (try built.gates.make(ctx.world, gate, .proto, @splat(0))).?;

    _ = try aigeneric.pushShip(ctx, ship, .fixed_gate_jump_in, gate, aigeneric.Target.whole);
    aigeneric.objectOrders(ctx, ship);
    const slot = mission.slot(ship);
    const object = &slot.object;
    // Held for the jump, it starts deep in the tunnel, which faces the gate's back: the gate's -Z.
    try std.testing.expect(object.flags.frozen and object.flags.unpowered and !object.flags.targetable);
    try std.testing.expectApproxEqAbs(-26000, gameobj.vector(object.root.position)[2], 1e-2);
    try std.testing.expect(record.busy);
    // It comes out beyond the mouth, a friend 53000 off, turned by the spread.
    const to = gameobj.vector(slot.state.gate.to);
    try std.testing.expectApproxEqRel(53000, math.length(to), 1e-4);
    try std.testing.expect(to[2] > 0);
    try std.testing.expectEqual(-1, built.gates.spread);

    // Half way it lets the tunnel go; the flashes showed near the start.
    mission.clock.frame_start += 50;
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expect(record.squares_shown);
    for (0..25) |_| {
        mission.clock.frame_start += 10;
        aigeneric.objectOrders(ctx, ship);
    }
    try std.testing.expect(!record.busy);
    // Through, it is free, and the order ends.
    for (0..30) |_| {
        mission.clock.frame_start += 10;
        aigeneric.objectOrders(ctx, ship);
    }
    try std.testing.expectEqual(0, object.order_count);
    try std.testing.expect(!object.flags.frozen and !object.flags.unpowered and object.flags.targetable);
    // It overshoots by the last update's step past the end, as the game's ships do.
    try std.testing.expectApproxEqRel(53000, math.length(gameobj.vector(object.root.position)), 0.05);
}

test "the player's ship goes out through the nearest gate and rides the worm" {
    const gpa = std.testing.allocator;
    var built: testing.Built = undefined;
    try built.init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const player = try mission.add(.predator, .{ 0, 0, 30000 });
    const near = try mission.add(.proto_gate, @splat(0));
    const far = try mission.add(.proto_gate, .{ 0, 0, 5e6 });
    var ctx = mission.orders();
    ctx.world.gates = &built.gates;
    _ = (try built.gates.make(ctx.world, near, .proto, @splat(0))).?;
    _ = (try built.gates.make(ctx.world, far, .proto, @splat(0))).?;

    _ = try aigeneric.pushShip(ctx, player, .fixed_gate_jump_out, far, aigeneric.Target.whole);
    aigeneric.objectOrders(ctx, player);
    const slot = mission.slot(player);
    // It goes down the nearest tunnel, whatever its order names.
    try std.testing.expectApproxEqAbs(-12000, gameobj.vector(slot.state.gate.to)[2], 1e-2);
    try std.testing.expect(built.gates.exiting and built.gates.worm != null);
    var ticks: usize = 0;
    while (!built.gates.riding and ticks < 1000) : (ticks += 1) {
        mission.clock.frame_start += 1;
        aigeneric.objectOrders(ctx, player);
    }
    try std.testing.expect(built.gates.riding);
    try std.testing.expectEqual(math.Vector{ 0, 0, away_depth }, gameobj.vector(slot.object.root.position));
    // While it rides, the tunnels are left out of the scene and the worm is in it.
    mission.clock.frame_start += 1;
    aigeneric.objectOrders(ctx, player);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try built.gates.draw(gpa, &scene, mission.objects, mission.clock.frame_start);
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(2, scene.portals.items.len);
    // After the ride, it comes in through the gate its order names.
    for (0..420) |_| {
        mission.clock.frame_start += 1;
        aigeneric.objectOrders(ctx, player);
    }
    try std.testing.expect(!built.gates.riding and !built.gates.exiting);
    try std.testing.expectEqual(@import("ai/orders.zig").Order.fixed_gate_jump_in, slot.orders[0].order);
    try std.testing.expectEqual(@as(i16, @intCast(far)), slot.orders[0].target.index);
}
