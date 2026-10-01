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
const hud = @import("../hud.zig");
const objects = @import("../objects.zig");
const srofiles = @import("../srofiles.zig");

const log = std.log.scoped(.library);

/// The models attachment points mount, by file, each read the first time it is asked for and kept
/// for whoever mounts it: a ship of three of the same turret reads that turret once. A model the
/// game lacks is remembered as missing, so it is looked for only once. Everything is made in `gpa`,
/// an arena, such as a ship type's own, so that letting the type go lets the lot go.
pub const MountCache = struct {
    gpa: Allocator,
    resources: *const bigfile.Hog,
    textures: *srtexture.Table,
    read: std.StringHashMapUnmanaged(?objects.Mounts.Mounted) = .empty,

    pub fn mounts(cache: *MountCache) objects.Mounts {
        return .{ .context = cache, .load = load };
    }

    fn load(context: *anyopaque, file: []const u8) ?objects.Mounts.Mounted {
        const cache: *MountCache = @ptrCast(@alignCast(context));
        if (cache.read.get(file)) |found| return found;
        const mounted = srofiles.readModel(cache.gpa, cache.resources, cache.textures, file) catch |err| missing: {
            log.warn("the model {s} is not mounted: {s}", .{ file, @errorName(err) });
            break :missing null;
        };
        cache.read.put(cache.gpa, file, mounted) catch return mounted;
        return mounted;
    }
};

/// The ship types' models (`ship_type_load`), each read as `create_object` asks for it, with what
/// it mounts and its schematic, in an arena of its own that `sweep` lets go once no object is of
/// the type.
pub const TypeCache = struct {
    gpa: Allocator,
    resources: *const bigfile.Hog,
    textures: *srtexture.Table,
    /// What the types' objects light themselves with; each type mounts from its own `MountCache`.
    looks: objects.Effects,
    /// VFX's global palette, which the schematics are drawn with.
    global_palette: ?*const [spr.palette_size]u8,
    loaded: [create.ship_type_count]?*Cached = @splat(null),
    /// Types the game names no model for, or whose files it lacks, looked for once.
    missing: std.StaticBitSet(create.ship_type_count) = .initEmpty(),

    const Cached = struct {
        arena: std.heap.ArenaAllocator,
        type: create.Type,
        mounted: MountCache,
        /// The schematic the display's ship status indicator draws, where the game has one.
        schematic: ?hud.Art,
    };

    pub fn types(cache: *TypeCache) create.Types {
        return .{ .context = cache, .load = load };
    }

    /// The type's model, loaded the first time; null for a type the game names no model for, and
    /// for one whose model it lacks or can't read, which is logged.
    fn load(context: *anyopaque, ship_type: u8) ?*const create.Type {
        const cache: *TypeCache = @ptrCast(@alignCast(context));
        if (cache.loaded[ship_type]) |cached| return &cached.type;
        if (cache.missing.isSet(ship_type)) return null;
        const files = create.models.ship_types[ship_type];
        const name = files.model orelse {
            cache.missing.set(ship_type);
            return null;
        };
        const cached = cache.build(name, files.schematic) catch |err| {
            log.warn("ship type {d} has no model: {s}", .{ ship_type, @errorName(err) });
            cache.missing.set(ship_type);
            return null;
        };
        cache.loaded[ship_type] = cached;
        return &cached.type;
    }

    fn build(cache: *TypeCache, name: []const u8, schematic_name: ?[]const u8) !*Cached {
        const cached = try cache.gpa.create(Cached);
        errdefer cache.gpa.destroy(cached);
        cached.arena = .init(std.heap.page_allocator);
        errdefer cached.arena.deinit();
        const gpa = cached.arena.allocator();
        const file = try srofiles.readModel(gpa, cache.resources, cache.textures, name);
        cached.mounted = .{ .gpa = gpa, .resources = cache.resources, .textures = cache.textures };
        cached.schematic = if (schematic_name) |schematic| found: {
            const bytes = cache.resources.readFile(gpa, schematic) catch |err| {
                log.warn("the schematic {s} is left out: {s}", .{ schematic, @errorName(err) });
                break :found null;
            };
            break :found try .init(gpa, try spr.Sprite.parse(bytes), cache.global_palette, .of(cache.resources.mods, schematic));
        } else null;
        var effects = cache.looks;
        effects.mounts = cached.mounted.mounts();
        cached.type = .{
            .model = file.model,
            .loaded = file.loaded,
            .effects = effects,
            .schematic = if (cached.schematic) |*art| .{ .art = art, .gpa = gpa } else null,
        };
        return cached;
    }

    /// Lets go of each type no object is of any more, by the objects' count of each (`uses`).
    pub fn sweep(cache: *TypeCache, uses: *const [create.ship_type_count]create.TypeUse) void {
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
    var uses: [create.ship_type_count]create.TypeUse = @splat(.{});
    uses[torpedo].objects = 1;
    cache.sweep(&uses);
    try std.testing.expect(cache.loaded[torpedo] != null);
    uses[torpedo].objects = 0;
    cache.sweep(&uses);
    try std.testing.expectEqual(null, cache.loaded[torpedo]);
}
