//! Finds files, and models, by the engine's file names in a directory of extracted game files,
//! ignoring case as the game's file system does.

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const files = openreliant.engine.files;
const shp = openreliant.shp;

const Context = @import("main.zig").Context;

pub const Library = struct {
    ctx: Context,
    dir: Io.Dir,
    /// Lower-cased file name to the name on disk.
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Models read so far, by lower-cased file name; null for one the directory lacks.
    models: std.StringHashMapUnmanaged(?shp.Model) = .empty,

    /// The directory holding the file at `path`.
    pub fn beside(ctx: Context, path: []const u8) !Library {
        return open(ctx, std.Io.Dir.path.dirname(path) orelse ".");
    }

    pub fn open(ctx: Context, dir_path: []const u8) !Library {
        var dir = try Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true });
        errdefer dir.close(ctx.io);

        var library: Library = .{ .ctx = ctx, .dir = dir };
        var it = dir.iterate();
        while (try it.next(ctx.io)) |entry| {
            if (entry.kind != .file) continue;
            const name = try ctx.arena.dupe(u8, entry.name);
            try library.names.put(ctx.arena, try std.ascii.allocLowerString(ctx.arena, name), name);
        }
        return library;
    }

    pub fn deinit(library: *Library) void {
        library.dir.close(library.ctx.io);
    }

    /// The bytes of the file `name`, or null when the directory has no such file.
    pub fn read(library: *Library, name: []const u8) !?[]u8 {
        const key = try std.ascii.allocLowerString(library.ctx.arena, name);
        const on_disk = library.names.get(key) orelse return null;
        return try library.dir.readFileAlloc(library.ctx.io, on_disk, library.ctx.arena, .limited(files.max_file_size));
    }

    /// The model the file `name` holds, or null when the directory has no such file.
    pub fn load(library: *Library, name: []const u8) !?shp.Model {
        const key = try std.ascii.allocLowerString(library.ctx.arena, name);
        if (library.models.get(key)) |model| return model;
        const model: ?shp.Model = if (try library.read(name)) |data| try shp.Model.parse(library.ctx.arena, data) else null;
        try library.models.put(library.ctx.arena, key, model);
        return model;
    }

    /// The components an object of the model `name` lists, or null when the model is missing.
    pub fn components(library: *Library, name: []const u8) !?[]const shp.Component {
        const model = try library.load(name) orelse return null;
        return try shp.components(library.ctx.arena, model, name, library);
    }
};

test Library {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buffer: [1024]u8 = undefined;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Ship.SHP", .data = shp.testing.buildModel(&buffer) });

    var out: Io.Writer.Allocating = .init(arena);
    const ctx: Context = .{ .io = std.testing.io, .arena = arena, .stdout = &out.writer };
    const beside_path = try arena.print(".zig-cache/tmp/{s}/MISSION.DTE", .{tmp.sub_path});
    var library: Library = try .beside(ctx, beside_path);
    defer library.deinit();

    // Names match whatever their case, as on the game's file system.
    const model = (try library.load("SHIP.shp")).?;
    try std.testing.expectEqual(1, model.parts.len);
    try std.testing.expectEqual(null, try library.load("missing.shp"));
    // A second load is the model read the first time.
    try std.testing.expectEqual(model.parts.ptr, (try library.load("ship.SHP")).?.parts.ptr);
    // The test model does not ask for components.
    try std.testing.expectEqual(0, (try library.components("ship.shp")).?.len);
    try std.testing.expectEqual(null, try library.components("missing.shp"));
    try std.testing.expectEqualSlices(u8, shp.testing.buildModel(&buffer), (try library.read("SHIP.SHP")).?);
    try std.testing.expectEqual(null, try library.read("missing.tga"));
}
