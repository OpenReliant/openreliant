//! The models objects are made of, read from the game's archive once each and kept while they are
//! used: each ship type's, which `ship_type_load` (`0x00466740`) loads for the type's first object
//! with its schematic (`TypeCache`), and the models the types' attachment points mount
//! (`MountCache`). They answer `create.Types` and `objects.Mounts`, which the tests answer with
//! models of their own.

const std = @import("std");
const Allocator = std.mem.Allocator;

const spr = @import("../../../formats/spr.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const bigfile = @import("../bigfile.zig");
const create = @import("../create.zig");
const additions = @import("../additions.zig");
const hud = @import("../hud.zig");
const objects = @import("../objects.zig");
const srofiles = @import("../srofiles.zig");
const main = @import("../main.zig");

const log = std.log.scoped(.library);

/// The models attachment points mount, by file, each read the first time it is asked for and kept
/// for whoever mounts it: a ship of three of the same turret reads that turret once. A model the
/// game lacks is remembered as missing, so it is looked for only once. Everything is made in `gpa`,
/// an arena, such as a ship type's own, so that letting the type go lets the lot go.
pub const MountCache = struct {
    gpa: Allocator,
    resources: *const bigfile.Hog,
    textures: *srtexture.Table,
    /// What the models are built with: the light maps (`Lmaps`) and the lights.
    models: srofiles.Settings = .{},
    read: std.StringHashMapUnmanaged(?objects.Mounts.Mounted) = .empty,

    pub fn mounts(cache: *MountCache) objects.Mounts {
        return .{ .context = cache, .load = load };
    }

    fn load(context: *anyopaque, file: []const u8) ?objects.Mounts.Mounted {
        const cache: *MountCache = @ptrCast(@alignCast(context));
        if (cache.read.get(file)) |found| return found;
        const mounted = srofiles.readModel(cache.gpa, cache.resources, cache.textures, file, cache.models) catch |err| missing: {
            log.warn("the model {s} is not mounted: {s}", .{ file, @errorName(err) });
            break :missing null;
        };
        cache.read.put(cache.gpa, file, mounted) catch return mounted;
        return mounted;
    }
};

/// Where a ship type's schematic comes from: the sprite set its shapes are read from, and the set
/// name the pictures that replace them are named after (`hud.Art.Pictures`).
const Schematic = struct {
    layout: []const u8,
    pictures: []const u8,
};

/// The schematic named `named` of ship type `ship_type`. A type a mod adds whose schematic no file
/// holds takes its shapes from its base's set, and the mod's pictures named after its own schematic
/// draw over them: `teapotscem_000.png` over the Predator's schematic for a type based on it that
/// names `teapotscem.spr`. A mod can so give its type a schematic without writing a sprite set.
fn schematicOf(resources: *const bigfile.Hog, ship_type: create.TypeIndex, named: ?[]const u8) ?Schematic {
    const own = named orelse return null;
    const added = additions.ships.get(ship_type) orelse return .{ .layout = own, .pictures = own };
    if (resources.has(own)) return .{ .layout = own, .pictures = own };
    const base = create.models.ship_types[@backingInt(added.base)].schematic orelse return null;
    return .{ .layout = base, .pictures = own };
}

/// The ship types' models (`ship_type_load`), each read as `create_object` asks for it, with what
/// it mounts and its schematic, in an arena of its own that `sweep` lets go once no object is of
/// the type.
pub const TypeCache = struct {
    gpa: Allocator,
    resources: *const bigfile.Hog,
    textures: *srtexture.Table,
    /// What the models are built with, the cockpit's among them: the light maps (`Lmaps`) and the
    /// lights.
    models: srofiles.Settings = .{},
    /// What the types' objects light themselves with; each type mounts from its own `MountCache`.
    looks: objects.Effects,
    /// VFX's global palette, which the schematics are drawn with.
    global_palette: ?*const [spr.palette_size]u8,
    /// The display's shapes (`hud.hardware_shapes`), which a mod's type's own wire frame and wing
    /// icon draw over (`ownShapes`); none without them.
    display_shapes: ?spr.Sprite = null,
    loaded: [create.max_ship_types]?*Cached = @splat(null),
    /// Types the game names no model for, or whose files it lacks, looked for once.
    missing: std.StaticBitSet(create.max_ship_types) = .initEmpty(),

    const Cached = struct {
        arena: std.heap.ArenaAllocator,
        type: create.Type,
        mounted: MountCache,
        /// The schematic the display's ship status indicator draws, where the game has one.
        schematic: ?hud.Art,
        /// The display's shapes with a mod's type's own pictures (`ownShapes`).
        wire_frame: ?hud.Art,
        wing_icon: ?hud.Art,
    };

    pub fn types(cache: *TypeCache) create.Types {
        return .{ .context = cache, .load = load };
    }

    /// The type's model, loaded the first time; null for a type the game names no model for, and
    /// for one whose model it lacks or can't read, which is logged.
    fn load(context: *anyopaque, ship_type: create.TypeIndex) ?*const create.Type {
        const cache: *TypeCache = @ptrCast(@alignCast(context));
        if (cache.loaded[ship_type]) |cached| return &cached.type;
        if (cache.missing.isSet(ship_type)) return null;
        const files = create.shipFiles(ship_type);
        const name = files.model orelse {
            cache.missing.set(ship_type);
            return null;
        };
        const cached = cache.build(ship_type, name, schematicOf(cache.resources, ship_type, files.schematic)) catch |err| {
            log.warn("ship type {d} has no model: {s}", .{ ship_type, @errorName(err) });
            cache.missing.set(ship_type);
            return null;
        };
        cache.loaded[ship_type] = cached;
        return &cached.type;
    }

    fn build(cache: *TypeCache, ship_type: create.TypeIndex, name: []const u8, schematic: ?Schematic) !*Cached {
        const cached = try cache.gpa.create(Cached);
        errdefer cache.gpa.destroy(cached);
        cached.arena = .init(std.heap.page_allocator);
        errdefer cached.arena.deinit();
        const gpa = cached.arena.allocator();
        const file = try srofiles.readModel(gpa, cache.resources, cache.textures, name, cache.models);
        cached.mounted = .{ .gpa = gpa, .resources = cache.resources, .textures = cache.textures, .models = cache.models };
        cached.schematic = if (schematic) |files| found: {
            const bytes = cache.resources.readFile(gpa, files.layout) catch |err| {
                log.warn("the schematic {s} is left out: {s}", .{ files.layout, @errorName(err) });
                break :found null;
            };
            break :found try .init(gpa, try spr.Sprite.parse(bytes), cache.global_palette, .of(cache.resources.mods, files.pictures));
        } else null;
        cached.wire_frame = try cache.ownShapes(gpa, ship_type, .wire_frame);
        cached.wing_icon = try cache.ownShapes(gpa, ship_type, .wing_icon);
        var effects = cache.looks;
        effects.mounts = cached.mounted.mounts();
        cached.type = .{
            .model = file.model,
            .loaded = file.loaded,
            .effects = effects,
            .schematic = if (cached.schematic) |*art| .{ .art = art, .gpa = gpa } else null,
            .wire_frame = if (cached.wire_frame) |*art| .{ .art = art, .gpa = gpa } else null,
            .wing_icon = if (cached.wing_icon) |*art| .{ .art = art, .gpa = gpa } else null,
        };
        return cached;
    }

    /// The display's shapes, with the pictures a mod's ship type gives in place of its base's
    /// `which` (`additions.ShipExtra`): the picture numbered 0 stands for the base's shape
    /// (`main.PlayerShip`), and for the wire frame, those after it for the shapes after it, the
    /// groups of guns lit, each drawn over the whole frame. Null for a type that gives none, or a
    /// base the player can't fly.
    fn ownShapes(cache: *const TypeCache, gpa: std.mem.Allocator, ship_type: create.TypeIndex, comptime which: enum { wire_frame, wing_icon }) std.mem.Allocator.Error!?hud.Art {
        const added = additions.ships.get(ship_type) orelse return null;
        const set = @field(added.extra, @tagName(which)) orelse return null;
        const shapes = cache.display_shapes orelse return null;
        const player = main.playerShip(.of(added.base)) orelse return null;
        const pictures: hud.Art.Pictures = .{
            .files = cache.resources.mods.pictures(),
            .set = set,
            .first = @field(player, @tagName(which)),
            .over_first = which == .wire_frame,
        };
        return try .init(gpa, shapes, cache.global_palette, pictures);
    }

    /// Lets go of each type no object is of any more, by the objects' count of each (`uses`).
    pub fn sweep(cache: *TypeCache, uses: *const [create.max_ship_types]create.TypeUse) void {
        for (&cache.loaded, uses) |*held, use| {
            const cached = held.* orelse continue;
            if (use.objects > 0) continue;
            cache.free(cached);
            held.* = null;
        }
    }

    pub fn deinit(cache: *TypeCache) void {
        for (cache.loaded) |held| if (held) |cached| cache.free(cached);
    }

    fn free(cache: *TypeCache, cached: *Cached) void {
        cached.arena.deinit();
        cache.gpa.destroy(cached);
    }
};

/// Files for the tests of what reads models.
pub const testing = struct {
    pub const Files = TestFiles;
};

/// An archive of one model, `file`, whose material is `Yank_1`, in a directory of its own, and a
/// texture table holding that texture.
const TestFiles = struct {
    tmp: std.testing.TmpDir,
    resources: bigfile.Hog,
    textures: *srtexture.testing.Textures,

    pub fn init(gpa: Allocator, file: []const u8) !TestFiles {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        try bigfile.testing.write(gpa, io, tmp.dir, bigfile.resource_name, &.{.{ .name = file, .data = @import("../../../formats/shp.zig").testing.buildModel(&buffer) }});
        var resources: bigfile.Hog = try .open(gpa, io, tmp.dir, bigfile.resource_name);
        errdefer resources.close(gpa);
        return .{ .tmp = tmp, .resources = resources, .textures = try .init(gpa, &.{ "yank_1", "lyank_1", "cloak64" }) };
    }

    pub fn deinit(files: *TestFiles, gpa: Allocator) void {
        files.textures.deinit(gpa);
        files.resources.close(gpa);
        files.tmp.cleanup();
    }
};

test MountCache {
    const gpa = std.testing.allocator;
    var files: TestFiles = try .init(gpa, "Gun.SHP");
    defer files.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var cache: MountCache = .{ .gpa = arena.allocator(), .resources = &files.resources, .textures = &files.textures.table };
    const mounts = cache.mounts();

    // Read once, then kept.
    const gun = mounts.load(mounts.context, "Gun.SHP").?;
    try std.testing.expectEqual(gun.model, mounts.load(mounts.context, "Gun.SHP").?.model);
    try std.testing.expectEqual(1, cache.read.count());
}

test TypeCache {
    const gpa = std.testing.allocator;
    // The torpedo's model, type 74, which has no schematic.
    const torpedo = 74;
    var files: TestFiles = try .init(gpa, create.models.ship_types[torpedo].model.?);
    defer files.deinit(gpa);
    var cache: TypeCache = .{ .gpa = gpa, .resources = &files.resources, .textures = &files.textures.table, .looks = .{}, .global_palette = null };
    defer cache.deinit();
    const types = cache.types();

    const loaded = types.load(types.context, torpedo).?;
    try std.testing.expectEqual(1, loaded.model.parts.len);
    try std.testing.expect(loaded.effects.mounts != null);
    try std.testing.expectEqual(null, loaded.schematic);
    try std.testing.expectEqual(loaded, types.load(types.context, torpedo).?);
    // A type the game names no model for has none.
    const modelless = 14;
    try std.testing.expectEqual(null, create.models.ship_types[modelless].model);
    try std.testing.expectEqual(null, types.load(types.context, modelless));
    try std.testing.expect(cache.missing.isSet(modelless));

    // Swept while an object is of it, the type stays; once none is, it goes.
    var uses: [create.max_ship_types]create.TypeUse = @splat(.{});
    uses[torpedo].objects = 1;
    cache.sweep(&uses);
    try std.testing.expect(cache.loaded[torpedo] != null);
    uses[torpedo].objects = 0;
    cache.sweep(&uses);
    try std.testing.expectEqual(null, cache.loaded[torpedo]);
}
