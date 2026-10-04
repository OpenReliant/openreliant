//! OpenReliant's mods: archives and folders in the game's `mods` folder whose files replace or add
//! to the game's files. A file in a mod replaces every game file with the same name, wherever the
//! game keeps it: inside its archives (`resource.hog`, and the speech, pilot face and CD archives)
//! or as a loose file, such as the music, movies, missions and stat tables. Files with new names
//! are added. PNG pictures in a mod (`Mods.pictures`) replace the game's images at any size:
//! textures from the texture cache, with their material maps, sprite shapes and TGA pictures.
//! TrueType and OpenType fonts in a mod replace the game's fonts, and are drawn at the window's
//! resolution (`hud.outline`).
//!
//! A mod is an archive in the game's format (a `.hog` file) or a folder of files, which is handy
//! while making a mod. A folder is read the same way as the archive `sltool hog pack` would make
//! from it. Names have no folders, as in the archives, and where the game has several files with
//! the same name, they are copies of each other. Mods take priority over the game's files, and a
//! mod that loads later over an earlier one. Mods load in the order of their names unless the mods
//! screen has set an order and turned some off (`Order`). Each mod can describe itself in a
//! manifest, `mod.ini`. [docs/guide/modding.md](../../../../docs/guide/modding.md) is the
//! modding guide.
//!
//! **Improvement:** the original can't load mods.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const checksums = @import("../../../formats/checksums.zig");
const fnt = @import("../../../formats/fnt.zig");
const hog = @import("../../../formats/hog.zig");
const spr = @import("../../../formats/spr.zig");
const tcache = @import("../../../formats/tcache.zig");
const tga = @import("../../../formats/tga.zig");
const refpack = @import("../../../formats/refpack.zig");
const files = @import("../../files.zig");
const profile = @import("../../profile.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const bigfile = @import("../bigfile.zig");
const order_module = @import("order.zig");

/// The order the mods load in and which are on (`Mods.openOrdered`).
pub const Order = order_module.Order;
pub const Listed = order_module.Listed;

const log = std.log.scoped(.mods);

/// The folder in the game folder that holds the mods. Its name is matched ignoring case.
pub const folder_name = "mods";

/// The file extension of a mod archive, matched ignoring case.
pub const archive_extension = ".hog";

/// The mod's manifest, in its archive or folder: an ini file with the `Field` keys in
/// `manifest_section`. The game never reads a file with this name, so the manifest doesn't replace
/// a game file, and the archive still works with the original.
pub const manifest_name = "mod.ini";

/// The manifest's section that describes the mod.
pub const manifest_section = "Mod";

/// A PNG picture of the mod, in its archive or folder, for a mod manager to show
/// ([#497](https://github.com/OpenReliant/openreliant/issues/497)). Like the manifest, it doesn't
/// replace a game file.
pub const thumbnail_name = "mod.png";

/// The file extension of a mod's scripts (`src/scripting.zig`), matched ignoring case. Scripts
/// don't replace game files.
pub const script_extension = ".luau";

/// The file extensions of the shaders for a mod's post effects (`scripting.postprocessing`),
/// matched ignoring case. Like scripts, shaders don't replace game files.
pub const shader_extensions = [_][]const u8{ ".frag", ".glsl" };

/// Files that belong to the mod itself rather than replacing game files, besides its scripts and
/// shaders.
const own_files = [_][]const u8{ manifest_name, thumbnail_name };

/// The fields of a mod's manifest, each under its key in `manifest_section`.
pub const Field = enum {
    /// The mod's display name.
    name,
    version,
    author,
    /// A one-line description of what it changes.
    description,
    /// The mod's web page.
    url,
    /// The OpenReliant version the mod needs, such as `0.7` or `0.7.1`. Mods that need a newer
    /// version are skipped (`Mods.open`).
    openreliant,

    /// Its key in the manifest, matched ignoring case.
    pub fn key(field: Field) []const u8 {
        return switch (field) {
            .name => "Name",
            .version => "Version",
            .author => "Author",
            .description => "Description",
            .url => "Url",
            .openreliant => "OpenReliant",
        };
    }
};

/// How a file is read: decompressed if it holds RefPack data, as `hog_read_file` (`0x004C7F60`)
/// reads an archive member, or as stored, the way Bink reads a movie and the radio a face film.
const Reading = enum { expanded, stored };

/// A mod: its files and its manifest.
pub const Mod = struct {
    /// The name of its archive or folder in the `mods` folder, as spelled there.
    name: []const u8,
    source: Source,
    /// Its manifest; empty if it has none.
    manifest: profile.Profile = .empty,

    pub const Source = union(enum) {
        archive: hog.Archive,
        folder: Folder,

        /// Opens the entry `name` of the `mods` folder `folder`, of kind `kind`: an archive if it's
        /// a `.hog` file, a folder mod if it's a folder, and `error.NotAMod` otherwise.
        fn open(gpa: Allocator, io: Io, folder: Io.Dir, name: []const u8, kind: Io.File.Kind) !Source {
            return switch (kind) {
                .directory => .{ .folder = try .open(gpa, io, folder, name) },
                .file => if (isArchive(name)) .{ .archive = try .open(gpa, io, folder, name) } else error.NotAMod,
                else => error.NotAMod,
            };
        }

        fn close(source: *Source, gpa: Allocator) void {
            switch (source.*) {
                .archive => |*archive| archive.close(gpa),
                .folder => |*folder| folder.close(gpa),
            }
        }
    };

    /// The value of `field` in its manifest; null if it's missing or empty.
    pub fn about(mod: Mod, field: Field) ?[]const u8 {
        const text = mod.manifest.value(manifest_section, field.key()) orelse return null;
        return if (text.len > 0) text else null;
    }

    /// Formats the mod for the log: the name, version and author from its manifest, followed by its
    /// name in the `mods` folder, or just that name if the manifest gives no name.
    pub fn format(mod: Mod, writer: *Io.Writer) Io.Writer.Error!void {
        const title = mod.about(.name);
        try writer.writeAll(title orelse mod.name);
        if (mod.about(.version)) |version| try writer.print(" {s}", .{version});
        if (mod.about(.author)) |author| try writer.print(", by {s}", .{author});
        if (title != null) try writer.print(" ({s})", .{mod.name});
    }

    /// The bytes of its thumbnail; null if it has none.
    pub fn thumbnail(mod: Mod, gpa: Allocator) bigfile.ReadError!?[]u8 {
        const file = mod.find(thumbnail_name) orelse return null;
        return try mod.read(gpa, file, .expanded);
    }

    /// The names of the mod's files that replace or add game files, in order. Files that belong to
    /// the mod itself, such as the manifest, are skipped (`isOwn`).
    pub fn names(mod: *const Mod) Names {
        return .{ .mod = mod, .keeps = isGameFile };
    }

    /// The names of the mod's scripts (its `.luau` files), in order.
    pub fn scripts(mod: *const Mod) Names {
        return .{ .mod = mod, .keeps = isScript };
    }

    /// The names of the mod's shaders (`shader_extensions`), in order.
    pub fn shaders(mod: *const Mod) Names {
        return .{ .mod = mod, .keeps = isShader };
    }

    pub const Names = struct {
        mod: *const Mod,
        /// Which files to list.
        keeps: *const fn (name: []const u8) bool,
        file: usize = 0,

        /// How many names are left to list.
        pub fn count(listed: Names) usize {
            var left = listed;
            var total: usize = 0;
            while (left.next()) |_| total += 1;
            return total;
        }

        pub fn next(listed: *Names) ?[]const u8 {
            while (listed.file < listed.mod.count()) {
                const name = listed.mod.fileName(listed.file);
                listed.file += 1;
                if (listed.keeps(name)) return name;
            }
            return null;
        }
    };

    /// Reads the mod's file `name`, ignoring case, and decompresses RefPack data. Returns
    /// null if the mod doesn't have the file.
    pub fn readFile(mod: Mod, gpa: Allocator, name: []const u8) bigfile.ReadError!?[]u8 {
        const file = mod.find(name) orelse return null;
        return try mod.read(gpa, file, .expanded);
    }

    /// The OpenReliant version the mod needs (`Field.openreliant`), if it's newer than `running`.
    /// Returns null otherwise. An invalid version is logged and ignored.
    fn needsLater(mod: Mod, running: std.SemanticVersion) ?std.SemanticVersion {
        const text = mod.about(.openreliant) orelse return null;
        const needed = parseVersion(text) orelse {
            log.warn("{s}: {s}: ignoring {s}={s}, which is not a valid version", .{ mod.name, manifest_name, Field.openreliant.key(), text });
            return null;
        };
        return if (needed.order(running) == .gt) needed else null;
    }

    /// The number of files in the mod, including its manifest, thumbnail and scripts.
    fn count(mod: Mod) usize {
        return switch (mod.source) {
            .archive => |archive| archive.entries.len,
            .folder => |folder| folder.names.len,
        };
    }

    /// The name of file number `file`, as spelled.
    fn fileName(mod: Mod, file: usize) []const u8 {
        return switch (mod.source) {
            .archive => |archive| archive.entries[file].name,
            .folder => |folder| folder.names[file],
        };
    }

    /// The first file named `name`, ignoring case; null if there's none.
    fn find(mod: Mod, name: []const u8) ?usize {
        for (0..mod.count()) |file| {
            if (std.ascii.eqlIgnoreCase(mod.fileName(file), name)) return file;
        }
        return null;
    }

    /// Reads file number `file` as `reading` says.
    fn read(mod: Mod, gpa: Allocator, file: usize, reading: Reading) bigfile.ReadError![]u8 {
        switch (mod.source) {
            .archive => |archive| {
                const entry = archive.entries[file];
                return switch (reading) {
                    .expanded => try bigfile.readMember(archive, gpa, entry),
                    .stored => try archive.readRaw(gpa, entry),
                };
            },
            .folder => |folder| return folder.read(gpa, folder.names[file], reading),
        }
    }

    /// Opens the mod `name` in the `mods` folder `folder` (`Source.open`), with its manifest if it
    /// has one. Returns null, with a message in the log, if it isn't a mod, can't be opened, or, if
    /// `check` is set, is an archive that fails its checksum (`intact`).
    fn open(gpa: Allocator, io: Io, folder: Io.Dir, name: []const u8, kind: Io.File.Kind, check: bool) Allocator.Error!?Mod {
        if (check and kind == .file and isArchive(name) and !try intact(gpa, io, folder, name)) return null;
        var source = Source.open(gpa, io, folder, name, kind) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.NotAMod => {
                log.warn("skipping {s}: a mod must be a {s} archive or a folder", .{ name, archive_extension });
                return null;
            },
            else => {
                log.warn("skipping the mod {s}: {s}", .{ name, @errorName(err) });
                return null;
            },
        };
        errdefer source.close(gpa);
        var mod: Mod = .{ .name = try gpa.dupe(u8, name), .source = source };
        errdefer gpa.free(mod.name);
        const manifest = mod.find(manifest_name) orelse return mod;
        if (mod.read(gpa, manifest, .expanded)) |text| {
            mod.manifest = .{ .text = text };
        } else |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => log.warn("{s}: can't read {s}: {s}", .{ name, manifest_name, @errorName(err) }),
        }
        return mod;
    }

    fn close(mod: *Mod, gpa: Allocator) void {
        mod.source.close(gpa);
        gpa.free(mod.manifest.text);
        gpa.free(mod.name);
    }
};

/// Whether the archive `name` in the `mods` folder `folder` can be used: true if there's no
/// checksum file next to it (the archive's name plus `checksums.extension`, matched ignoring case),
/// or if the checksum matches. If it doesn't match or can't be read, the archive is damaged or
/// isn't the one the checksum was made for, and the log says so.
fn intact(gpa: Allocator, io: Io, folder: Io.Dir, name: []const u8) Allocator.Error!bool {
    var named: [files.max_path]u8 = undefined;
    const checksum_name = std.fmt.bufPrint(&named, "{s}" ++ checksums.extension, .{name}) catch return true;
    var found: [files.max_path]u8 = undefined;
    const path = files.find(io, folder, checksum_name, &found) orelse return true;
    const failure: []const u8 = failed: {
        const text = files.readFile(io, gpa, folder, path, .limited(max_checksum_size)) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => break :failed @errorName(err),
        } orelse break :failed "it can't be found";
        defer gpa.free(text);
        const wanted = (checksums.digestOf(text, name) catch break :failed "it isn't a checksum file") orelse
            break :failed "it has no checksum for the archive";
        const file = folder.openFile(io, name, .{}) catch |err| break :failed @errorName(err);
        defer file.close(io);
        const digest = checksums.digestFile(io, file) catch |err| break :failed @errorName(err);
        if (!std.mem.eql(u8, &digest, &wanted)) break :failed "the archive is damaged, or isn't the one it was made for";
        log.info("{s} matches {s}", .{ name, path });
        return true;
    };
    log.warn("skipping the mod {s}: checking {s} failed: {s}", .{ name, path, failure });
    return false;
}

/// The largest checksum file `intact` reads, far more than a line for each file of a mod.
const max_checksum_size = 1 << 16;

/// A folder mod. Each file in the folder is one of the mod's files, as `sltool hog pack` would pack
/// it, and is read the same way as the archive member it would become.
pub const Folder = struct {
    io: Io,
    dir: Io.Dir,
    /// The file names as spelled, in the order `sltool hog pack` packs them (`hog.nameOrder`).
    names: []const []const u8,

    /// Opens the folder `name` in `parent`. Subfolders, and files whose names can't be archive
    /// member names (`hog.validName`), are skipped with a message in the log, as `sltool hog pack`
    /// skips them.
    pub fn open(gpa: Allocator, io: Io, parent: Io.Dir, name: []const u8) !Folder {
        var dir = try parent.openDir(io, name, .{ .iterate = true });
        errdefer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        errdefer for (names.items) |file| gpa.free(file);
        var entries = dir.iterate();
        while (try entries.next(io)) |entry| {
            if (hidden(entry.name)) continue;
            switch (kindOf(io, dir, entry) orelse continue) {
                .file => {},
                .directory => {
                    log.warn("skipping {s}/{s}: a mod's files must be directly in its folder", .{ name, entry.name });
                    continue;
                },
                else => continue,
            }
            if (!hog.validName(entry.name)) {
                log.warn("skipping {s}/{s}: file names must be printable ASCII, like archive member names", .{ name, entry.name });
                continue;
            }
            const owned = try gpa.dupe(u8, entry.name);
            errdefer gpa.free(owned);
            try names.append(gpa, owned);
        }
        std.mem.sort([]const u8, names.items, {}, hog.nameOrder);
        return .{ .io = io, .dir = dir, .names = try names.toOwnedSlice(gpa) };
    }

    pub fn close(folder: *Folder, gpa: Allocator) void {
        for (folder.names) |name| gpa.free(name);
        gpa.free(folder.names);
        folder.dir.close(folder.io);
    }

    /// Reads its file `name` as `reading` says. Decompressing reads it the same way as the member
    /// `hog.packMember` would make of it: RefPack data that the game would decompress, such as a
    /// member extracted with `--raw`, is decompressed, and any other file is read as it is.
    fn read(folder: Folder, gpa: Allocator, name: []const u8, reading: Reading) bigfile.ReadError![]u8 {
        const bytes = try folder.dir.readFileAlloc(folder.io, name, gpa, .limited(files.max_file_size));
        if (reading == .stored or !refpack.gameExpands(bytes)) return bytes;
        errdefer gpa.free(bytes);
        const expanded = refpack.decompressAlloc(gpa, bytes) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.BadSignature, error.UnexpectedEnd, error.BadReference, error.SizeMismatch => return bytes,
        };
        gpa.free(bytes);
        return expanded;
    }
};

/// The loaded mods, and which mod each file name is read from.
pub const Mods = struct {
    /// The mods, in load order.
    list: []Mod = &.{},
    /// The mods that are off (`Order`), opened so that the mods screen can list them. Their files
    /// and scripts aren't used.
    off: []Mod = &.{},
    /// Every file in the mods, by its name in lower case, pointing to the last mod that has it.
    index: std.StringHashMapUnmanaged(Place) = .empty,

    /// No mods, as with `--no-mods`.
    pub const none: Mods = .{};

    /// A file in a mod: the mod's index in the list, and the file's index in the mod.
    const Place = struct { mod: usize, file: usize };

    /// Opens the mods in the `mods` folder of the game folder `game` with every mod on, in the order
    /// of their names (`openOrdered`).
    pub fn open(gpa: Allocator, io: Io, game: Io.Dir, running: ?std.SemanticVersion) Allocator.Error!Mods {
        return openOrdered(gpa, io, game, running, .none);
    }

    /// Opens the mods in the `mods` folder of the game folder `game`: each `.hog` file is an
    /// archive and each folder a folder mod. `order` says which are on and the order they load in:
    /// the mods it lists first, in its order, then the others sorted by name, ignoring case. The
    /// mods that are off go to `off`. Anything else, mods that fail to open, and mods that need a
    /// newer OpenReliant than `running` are skipped and logged. If `running` is null, the version
    /// check is skipped. Returns no mods if there's no `mods` folder. The log lists each mod and
    /// what each of its files replaces or adds (`report`).
    pub fn openOrdered(gpa: Allocator, io: Io, game: Io.Dir, running: ?std.SemanticVersion, order: Order) Allocator.Error!Mods {
        return openListing(gpa, io, game, running, order, true);
    }

    /// Opens the mods as `openOrdered` does, for the mods screen to list them again: it doesn't log
    /// what each mod's files replace or add (`report`).
    pub fn installed(gpa: Allocator, io: Io, game: Io.Dir, running: ?std.SemanticVersion, order: Order) Allocator.Error!Mods {
        return openListing(gpa, io, game, running, order, false);
    }

    fn openListing(gpa: Allocator, io: Io, game: Io.Dir, running: ?std.SemanticVersion, order: Order, report_files: bool) Allocator.Error!Mods {
        var path: [files.max_path]u8 = undefined;
        const found = files.find(io, game, folder_name, &path) orelse return .none;
        var folder = game.openDir(io, found, .{ .iterate = true }) catch |err| {
            log.warn("can't open {s}: {s}; no mods are loaded", .{ found, @errorName(err) });
            return .none;
        };
        defer folder.close(io);

        const Entry = struct { name: []const u8, kind: Io.File.Kind };
        var entries: std.ArrayList(Entry) = .empty;
        defer {
            for (entries.items) |entry| gpa.free(entry.name);
            entries.deinit(gpa);
        }
        var iterator = folder.iterate();
        while (iterator.next(io) catch |err| {
            log.warn("can't list {s}: {s}; no mods are loaded", .{ found, @errorName(err) });
            return .none;
        }) |entry| {
            // A checksum file belongs to the archive it checks (`intact`).
            if (hidden(entry.name) or isChecksum(entry.name)) continue;
            const kind = kindOf(io, folder, entry) orelse continue;
            const name = try gpa.dupe(u8, entry.name);
            errdefer gpa.free(name);
            try entries.append(gpa, .{ .name = name, .kind = kind });
        }
        std.mem.sort(Entry, entries.items, order, struct {
            fn lessThan(sorted: Order, a: Entry, b: Entry) bool {
                return sorted.before(a.name, b.name);
            }
        }.lessThan);

        var list: std.ArrayList(Mod) = .empty;
        defer list.deinit(gpa);
        errdefer for (list.items) |*mod| mod.close(gpa);
        var off: std.ArrayList(Mod) = .empty;
        defer off.deinit(gpa);
        errdefer for (off.items) |*mod| mod.close(gpa);
        for (entries.items) |entry| {
            // A mod that is off isn't checked against its checksum, as none of it is used.
            const on = order.isOn(entry.name);
            var mod = try Mod.open(gpa, io, folder, entry.name, entry.kind, on) orelse continue;
            if (running) |version| if (mod.needsLater(version)) |needed| {
                log.warn("skipping the mod {f}: it needs OpenReliant {f}, and this is {f}", .{ mod, needed, version });
                mod.close(gpa);
                continue;
            };
            if (!on) log.info("the mod {f} is off", .{mod});
            (if (on) &list else &off).append(gpa, mod) catch |err| {
                mod.close(gpa);
                return err;
            };
        }
        var mods: Mods = .{ .list = try list.toOwnedSlice(gpa) };
        errdefer mods.close(gpa);
        mods.off = try off.toOwnedSlice(gpa);
        try mods.makeIndex(gpa);
        if (report_files) try mods.report(gpa, io, game);
        return mods;
    }

    pub fn close(mods: *Mods, gpa: Allocator) void {
        freeIndex(Place, &mods.index, gpa);
        for (mods.list) |*mod| mod.close(gpa);
        gpa.free(mods.list);
        for (mods.off) |*mod| mod.close(gpa);
        gpa.free(mods.off);
        mods.* = .none;
    }

    /// Whether a mod has the file `name`, ignoring case.
    pub fn has(mods: *const Mods, name: []const u8) bool {
        return mods.place(name) != null;
    }

    /// The mod the file `name` is read from: the last mod that has it, ignoring case. Null if no
    /// mod has it.
    pub fn holder(mods: *const Mods, name: []const u8) ?*const Mod {
        const found = mods.place(name) orelse return null;
        return &mods.list[found.mod];
    }

    /// Reads the file `name`, ignoring case, from the last mod that has it, decompressing RefPack
    /// data as `hog_read_file` (`0x004C7F60`) does for an archive member. Null if no mod has it.
    pub fn readFile(mods: *const Mods, gpa: Allocator, name: []const u8) bigfile.ReadError!?[]u8 {
        const found = mods.place(name) orelse return null;
        return try mods.list[found.mod].read(gpa, found.file, .expanded);
    }

    /// Reads the file `name`, ignoring case, from the last mod that has it, as stored, the way Bink
    /// reads a movie and the radio a face film. Null if no mod has it.
    pub fn readStored(mods: *const Mods, gpa: Allocator, name: []const u8) bigfile.ReadError!?[]u8 {
        const found = mods.place(name) orelse return null;
        return try mods.list[found.mod].read(gpa, found.file, .stored);
    }

    /// Reads the mod file that replaces the game's loose file `path`: the file with the same name
    /// (the part of the path after the last `\` or `/`) from the last mod that has it, as
    /// `readFile` reads it. Null if no mod has it.
    pub fn readInPlaceOf(mods: *const Mods, gpa: Allocator, path: []const u8) bigfile.ReadError!?[]u8 {
        return mods.readFile(gpa, std.fs.path.basenameWindows(path));
    }

    /// Reads the game's loose file `path` under the game folder `dir`: a mod's replacement if there
    /// is one (`readInPlaceOf`), otherwise the file itself, found by `files.readFile`, of at most
    /// `limit` bytes. Null if neither exists.
    pub fn readLoose(mods: *const Mods, io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8, limit: Io.Limit) bigfile.ReadError!?[]u8 {
        if (try mods.readInPlaceOf(gpa, path)) |bytes| return bytes;
        return files.readFile(io, gpa, dir, path, limit);
    }

    /// The mod files that the pictures replacing the game's images are read from
    /// (`srtexture.Files`): textures from the texture cache, and the interface's shapes and
    /// pictures.
    pub fn pictures(mods: *const Mods) srtexture.Files {
        return .{ .context = mods, .readFn = readPicture };
    }

    fn readPicture(context: *const anyopaque, gpa: Allocator, name: []const u8) Allocator.Error!?[]u8 {
        const mods: *const Mods = @ptrCast(@alignCast(context));
        return mods.readFile(gpa, name) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                log.warn("can't read {s}: {s}", .{ name, @errorName(err) });
                return null;
            },
        };
    }

    fn place(mods: *const Mods, name: []const u8) ?Place {
        var buffer: [files.max_path]u8 = undefined;
        return mods.index.get(lowered(&buffer, name) orelse return null);
    }

    /// Indexes each mod file by its name. Within a mod, the first file with a name is used, as in
    /// an archive lookup, and a later mod's file replaces an earlier mod's. Files that belong to
    /// the mod itself, such as manifests, are skipped.
    fn makeIndex(mods: *Mods, gpa: Allocator) Allocator.Error!void {
        for (mods.list, 0..) |*mod, at| {
            for (0..mod.count()) |file| {
                const name = mod.fileName(file);
                if (isOwn(name)) continue;
                var buffer: [files.max_path]u8 = undefined;
                const key = try gpa.dupe(u8, lowered(&buffer, name) orelse continue);
                const slot = mods.index.getOrPut(gpa, key) catch |err| {
                    gpa.free(key);
                    return err;
                };
                if (slot.found_existing) {
                    gpa.free(key);
                    if (slot.value_ptr.mod == at) continue;
                }
                slot.value_ptr.* = .{ .mod = at, .file = file };
            }
        }
    }

    /// Logs each mod, in load order, and what each of its files does: replaces an earlier mod's
    /// file, replaces a game file (`GameFiles`), or adds a file.
    fn report(mods: *const Mods, gpa: Allocator, io: Io, game: Io.Dir) Allocator.Error!void {
        if (mods.list.len == 0) return;
        var own: GameFiles = try .gather(gpa, io, game);
        defer own.deinit(gpa);
        for (mods.list, 0..) |*mod, at| {
            log.info("mod {d} of {d}: {f}", .{ at + 1, mods.list.len, mod.* });
            var names = mod.names();
            while (names.next()) |name| switch (effectOf(mods.list, at, own, name)) {
                .over => |earlier| log.info("{s} replaces {s}'s {s}", .{ mod.name, earlier.name, name }),
                .file => log.info("{s} replaces {s}", .{ mod.name, name }),
                .texture => |texture| log.info("{s} replaces the texture {s}", .{ mod.name, texture }),
                .map => |map| log.info("{s} adds the {s} of the texture {s}", .{ mod.name, map.kind.label(), map.texture }),
                .shape => |shape| log.info("{s} replaces shape {d} of the sprite set {s}", .{ mod.name, shape.index, shape.set }),
                .picture => |picture| log.info("{s} replaces the picture {s}", .{ mod.name, picture }),
                .font => |font| log.info("{s} replaces the font {s}", .{ mod.name, font }),
                .added => log.info("{s} adds {s}", .{ mod.name, name }),
            };
        }
    }
};

/// What a mod's file does, for the log.
const Effect = union(enum) {
    /// It replaces an earlier mod's file with the same name.
    over: *const Mod,
    /// It replaces the game file with the same name.
    file,
    /// It replaces the texture cache image with its name (`srtexture.Files`), given without the
    /// picture extension.
    texture: []const u8,
    /// It's one of the material maps of a texture in the cache.
    map: GameFiles.Map,
    /// It replaces a shape in one of the game's sprite sets (`spr.pictureName`).
    shape: GameFiles.Shape,
    /// It replaces the game's TGA picture with its name, given without the extension
    /// (`game.matmanager.pictureName`).
    picture: []const u8,
    /// It's an outline font that replaces one of the game's fonts (`fnt.outlineName`), given
    /// without the extension.
    font: []const u8,
    /// It adds a new file.
    added,
};

/// What the file `name` of the mod at `at` in `list` does. An earlier mod's file with the same name
/// is checked first, then the game's files (`own`).
fn effectOf(list: []const Mod, at: usize, own: GameFiles, name: []const u8) Effect {
    if (lastHolder(list[0..at], name)) |earlier| return .{ .over = earlier };
    if (own.kindOf(name)) |kind| return switch (kind) {
        .file => .file,
        .texture => .{ .texture = GameFiles.pictureStem(name) orelse name },
    };
    if (own.mapOf(name)) |map| return .{ .map = map };
    if (own.shapeOf(name)) |shape| return .{ .shape = shape };
    if (own.pictureOf(name)) |picture| return .{ .picture = picture };
    if (own.fontOf(name)) |font| return .{ .font = font };
    return .added;
}

/// The last mod in `list` that has the file `name`, ignoring case.
fn lastHolder(list: []const Mod, name: []const u8) ?*const Mod {
    var at = list.len;
    while (at > 0) {
        at -= 1;
        if (list[at].find(name) != null) return &list[at];
    }
    return null;
}

/// The names of the game's files, in lower case: the members of each archive in the game folder,
/// the loose files outside the `mods` folder, and the names of the pictures that replace texture
/// cache images (`srtexture.Files`).
const GameFiles = struct {
    names: std.StringHashMapUnmanaged(Kind) = .empty,

    const Kind = enum { file, texture };

    fn gather(gpa: Allocator, io: Io, game: Io.Dir) Allocator.Error!GameFiles {
        var gathered: GameFiles = .{};
        errdefer gathered.deinit(gpa);
        var dir = game.openDir(io, ".", .{ .iterate = true }) catch return gathered;
        defer dir.close(io);
        var walker = try dir.walkSelectively(gpa);
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (hidden(entry.basename)) continue;
            switch (entry.kind) {
                .directory => {
                    if (entry.depth() == 1 and std.ascii.eqlIgnoreCase(entry.basename, folder_name)) continue;
                    walker.enter(io, entry) catch {};
                },
                .file => if (isArchive(entry.basename)) {
                    var archive = hog.Archive.open(gpa, io, entry.dir, entry.basename) catch |err| switch (err) {
                        error.OutOfMemory => |e| return e,
                        else => continue,
                    };
                    defer archive.close(gpa);
                    for (archive.entries) |member| try gathered.add(gpa, member.name, .file);
                } else try gathered.add(gpa, entry.basename, .file),
                else => {},
            }
        }
        try gathered.addTextures(gpa, io, game);
        return gathered;
    }

    /// Adds the names of the pictures that replace the images in the texture cache,
    /// `tcachehw.dat`. Only the cache's directory is read.
    fn addTextures(gathered: *GameFiles, gpa: Allocator, io: Io, game: Io.Dir) Allocator.Error!void {
        var found: [files.max_path]u8 = undefined;
        const path = files.find(io, game, tcache.hardware_name, &found) orelse return;
        const file = game.openFile(io, path, .{}) catch return;
        defer file.close(io);
        const bytes = try gpa.alloc(u8, tcache.data_start);
        defer gpa.free(bytes);
        const read = file.readPositionalAll(io, bytes, 0) catch return;
        const entries = tcache.Cache.directory(bytes[0..read]) catch return;
        for (entries) |*entry| {
            if (entry.image.flags.transient) continue;
            var named: [files.max_path]u8 = undefined;
            const picture = std.fmt.bufPrint(&named, "{s}" ++ srtexture.picture_extension, .{entry.name()}) catch continue;
            try gathered.add(gpa, picture, .texture);
        }
    }

    /// Adds `name` as a file of `kind`, unless it's already there.
    fn add(gathered: *GameFiles, gpa: Allocator, name: []const u8, kind: Kind) Allocator.Error!void {
        var buffer: [files.max_path]u8 = undefined;
        const slot = try gathered.names.getOrPut(gpa, lowered(&buffer, name) orelse return);
        if (slot.found_existing) return;
        slot.key_ptr.* = gpa.dupe(u8, slot.key_ptr.*) catch |err| {
            gathered.names.removeByPtr(slot.key_ptr);
            return err;
        };
        slot.value_ptr.* = kind;
    }

    /// A material map of one of the cache's textures (`srtexture.MapFile`).
    const Map = struct { texture: []const u8, kind: srtexture.MapFile };

    /// If the file `name` is a material map of a texture in the cache, `<texture>_<map>.png`, the
    /// texture and which map it is; null otherwise.
    fn mapOf(gathered: GameFiles, name: []const u8) ?Map {
        const stem = pictureStem(name) orelse return null;
        for (std.enums.values(srtexture.MapFile)) |kind| {
            const suffix = kind.suffix();
            if (stem.len <= suffix.len or !std.ascii.endsWithIgnoreCase(stem, suffix)) continue;
            const texture = stem[0 .. stem.len - suffix.len];
            var buffer: [files.max_path]u8 = undefined;
            const picture = std.fmt.bufPrint(&buffer, "{s}" ++ srtexture.picture_extension, .{texture}) catch continue;
            if (gathered.kindOf(picture) == .texture) return .{ .texture = texture, .kind = kind };
        }
        return null;
    }

    /// A shape in one of the game's sprite sets: the set's name from the picture name, without the
    /// extension, and the shape's index in the set.
    const Shape = struct { set: []const u8, index: usize };

    /// The sprite set shape that the file `name` replaces, using the name the interface looks up
    /// (`spr.pictureName`); null if it doesn't replace one.
    fn shapeOf(gathered: GameFiles, name: []const u8) ?Shape {
        const stem = pictureStem(name) orelse return null;
        const mark = std.mem.lastIndexOfScalar(u8, stem, '_') orelse return null;
        const set = stem[0..mark];
        const index = std.fmt.parseUnsigned(usize, stem[mark + 1 ..], 10) catch return null;
        var buffer: [files.max_path]u8 = undefined;
        const looked_up = spr.pictureName(&buffer, set, index) catch return null;
        if (!std.ascii.eqlIgnoreCase(looked_up, name)) return null;
        const set_file = std.fmt.bufPrint(&buffer, "{s}" ++ spr.extension, .{set}) catch return null;
        if (gathered.kindOf(set_file) != .file) return null;
        return .{ .set = set, .index = index };
    }

    /// The name, without the extension, of the game's TGA picture that the file `name`,
    /// `<picture>.png`, replaces; null if it doesn't replace one.
    fn pictureOf(gathered: GameFiles, name: []const u8) ?[]const u8 {
        const stem = pictureStem(name) orelse return null;
        var buffer: [files.max_path]u8 = undefined;
        const picture = std.fmt.bufPrint(&buffer, "{s}" ++ tga.extension, .{stem}) catch return null;
        if (gathered.kindOf(picture) != .file) return null;
        return stem;
    }

    /// The name, without the extension, of the game's font that the outline font `name`,
    /// `<font>.ttf` or `<font>.otf` (`fnt.outline_extensions`), replaces; null if it doesn't
    /// replace one.
    fn fontOf(gathered: GameFiles, name: []const u8) ?[]const u8 {
        for (fnt.outline_extensions) |extension| {
            if (!std.ascii.endsWithIgnoreCase(name, extension)) continue;
            const stem = name[0 .. name.len - extension.len];
            var buffer: [files.max_path]u8 = undefined;
            const font = std.fmt.bufPrint(&buffer, "{s}" ++ fnt.extension, .{stem}) catch return null;
            if (gathered.kindOf(font) == .file) return stem;
        }
        return null;
    }

    /// The file `name` without the picture extension; null if it has a different extension.
    fn pictureStem(name: []const u8) ?[]const u8 {
        if (!std.ascii.endsWithIgnoreCase(name, srtexture.picture_extension)) return null;
        return name[0 .. name.len - srtexture.picture_extension.len];
    }

    /// The kind of the game file named `name`, ignoring case; null if there's no such file.
    fn kindOf(gathered: GameFiles, name: []const u8) ?Kind {
        var buffer: [files.max_path]u8 = undefined;
        return gathered.names.get(lowered(&buffer, name) orelse return null);
    }

    fn deinit(gathered: *GameFiles, gpa: Allocator) void {
        freeIndex(Kind, &gathered.names, gpa);
    }
};

/// `name` in lower case, written to `buffer`, as the indexes use it; null for a name longer than
/// any path the game builds, which no index can contain.
fn lowered(buffer: *[files.max_path]u8, name: []const u8) ?[]const u8 {
    return if (name.len <= buffer.len) std.ascii.lowerString(buffer, name) else null;
}

/// Frees an index of names, including the names it allocated.
fn freeIndex(comptime Value: type, index: *std.StringHashMapUnmanaged(Value), gpa: Allocator) void {
    var keys = index.keyIterator();
    while (keys.next()) |key| gpa.free(key.*);
    index.deinit(gpa);
}

/// Whether the file `name` belongs to the mod itself (`own_files` or a script), ignoring case.
fn isOwn(name: []const u8) bool {
    for (own_files) |own| {
        if (std.ascii.eqlIgnoreCase(name, own)) return true;
    }
    return isScript(name) or isShader(name);
}

/// Whether `name` is a shader, ignoring case.
fn isShader(name: []const u8) bool {
    return hasExtension(name, &shader_extensions);
}

/// Whether `name` ends in one of `extensions`, ignoring case.
fn hasExtension(name: []const u8, extensions: []const []const u8) bool {
    const extension = std.fs.path.extension(name);
    for (extensions) |each| if (std.ascii.eqlIgnoreCase(extension, each)) return true;
    return false;
}

/// Whether `name` is a file that replaces or adds a game file: anything except the manifest, the
/// thumbnail and scripts.
fn isGameFile(name: []const u8) bool {
    return !isOwn(name);
}

/// Whether `name` has the script extension, ignoring case.
fn isScript(name: []const u8) bool {
    return hasExtension(name, &.{script_extension});
}

/// Parses a version such as `0.7` or `0.7.1`. A missing patch number counts as 0. Returns null if
/// `text` isn't a version.
fn parseVersion(text: []const u8) ?std.SemanticVersion {
    var buffer: [max_version]u8 = undefined;
    const full = if (std.mem.count(u8, text, ".") == 1)
        std.fmt.bufPrint(&buffer, "{s}.0", .{text}) catch return null
    else
        text;
    return std.SemanticVersion.parse(full) catch null;
}

/// The longest version string `parseVersion` accepts.
const max_version = 64;

/// Whether `name` is a checksum file, by its extension, ignoring case.
fn isChecksum(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(name), checksums.extension);
}

/// Whether `name` is an archive, by its extension, ignoring case.
fn isArchive(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(name), archive_extension);
}

/// Whether a file or folder name is hidden, such as `.DS_Store` or `.git`. Mods skip them.
fn hidden(name: []const u8) bool {
    return std.mem.startsWith(u8, name, ".");
}

/// The kind of `entry` in `dir`, following symbolic links; null if it can't be determined.
fn kindOf(io: Io, dir: Io.Dir, entry: Io.Dir.Entry) ?Io.File.Kind {
    return switch (entry.kind) {
        .sym_link, .unknown => (dir.statFile(io, entry.name, .{}) catch return null).kind,
        else => entry.kind,
    };
}

test Mods {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Two mods, sorted by name ignoring case: a folder, `Alpha`, and an archive, `beta.hog`, which
    // loads after it, so its files take priority. The folder has a manifest, a file with RefPack
    // data and a subfolder, which is skipped, as is a file in the mods folder that isn't a mod.
    try tmp.dir.createDirPath(io, "Mods/Alpha/textures");
    try tmp.dir.writeFile(io, .{ .sub_path = "Mods/Alpha/Ship.SHP", .data = "alpha's ship" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Mods/Alpha/logo.tga", .data = "alpha's logo" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Mods/Alpha/textures/hull.png", .data = "left out" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Mods/Alpha/MOD.INI", .data = "[Mod]\r\nName=Alpha\r\nVersion=1.2\r\nAuthor=Someone\r\nDescription=\r\nURL=https://example.com/alpha\r\n" });
    const stream = try refpack.compressAlloc(gpa, "abcdabcdabcdabcdabcd");
    defer gpa.free(stream);
    try tmp.dir.writeFile(io, .{ .sub_path = "Mods/Alpha/packed.dat", .data = stream });
    try hog.testing.write(gpa, io, tmp.dir, "Mods/beta.hog", &.{
        .{ .name = "ship.shp", .data = "beta's ship" },
        .{ .name = "ABRT_001", .data = "beta's line" },
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "Mods/readme.txt", .data = "no mod" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Mods/.DS_Store", .data = "" });
    // A loose game file that no mod replaces.
    try tmp.dir.createDirPath(io, "music");
    try tmp.dir.writeFile(io, .{ .sub_path = "music/theme.wav", .data = "the game's theme" });

    var mods: Mods = try .open(gpa, io, tmp.dir, null);
    defer mods.close(gpa);
    try std.testing.expectEqual(2, mods.list.len);
    try std.testing.expectEqualStrings("Alpha", mods.list[0].name);
    try std.testing.expectEqualStrings("beta.hog", mods.list[1].name);

    // The last mod with a file wins, ignoring case; an earlier mod's file is used if no later mod
    // has it.
    const ship = (try mods.readFile(gpa, "SHIP.shp")).?;
    defer gpa.free(ship);
    try std.testing.expectEqualStrings("beta's ship", ship);
    try std.testing.expectEqual(&mods.list[1], mods.holder("Ship.SHP").?);
    const logo = (try mods.readFile(gpa, "LOGO.TGA")).?;
    defer gpa.free(logo);
    try std.testing.expectEqualStrings("alpha's logo", logo);
    try std.testing.expectEqual(null, try mods.readFile(gpa, "missing.tga"));
    try std.testing.expect(!mods.has("hull.png"));
    // RefPack data is decompressed, as `hog_read_file` does for a member, unless it's read as
    // stored.
    const expanded = (try mods.readFile(gpa, "packed.dat")).?;
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings("abcdabcdabcdabcdabcd", expanded);
    const stored = (try mods.readStored(gpa, "packed.dat")).?;
    defer gpa.free(stored);
    try std.testing.expectEqualSlices(u8, stream, stored);

    // The manifest describes the mod, and doesn't replace a game file.
    const alpha = mods.list[0];
    try std.testing.expectEqualStrings("Alpha", alpha.about(.name).?);
    try std.testing.expectEqualStrings("1.2", alpha.about(.version).?);
    try std.testing.expectEqual(null, alpha.about(.description));
    try std.testing.expectEqualStrings("https://example.com/alpha", alpha.about(.url).?);
    try std.testing.expect(!mods.has("mod.ini"));
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Alpha 1.2, by Someone (Alpha)", try std.fmt.bufPrint(&buffer, "{f}", .{alpha}));
    try std.testing.expectEqualStrings("beta.hog", try std.fmt.bufPrint(&buffer, "{f}", .{mods.list[1]}));
    var names = alpha.names();
    for ([_][]const u8{ "Ship.SHP", "logo.tga", "packed.dat" }) |name| try std.testing.expectEqualStrings(name, names.next().?);
    try std.testing.expectEqual(null, names.next());

    // A loose game file comes from a mod if one has it, and from the game folder otherwise.
    const line = (try mods.readLoose(io, gpa, tmp.dir, "ms_speech\\abrt_001", .unlimited)).?;
    defer gpa.free(line);
    try std.testing.expectEqualStrings("beta's line", line);
    const theme = (try mods.readLoose(io, gpa, tmp.dir, "music\\THEME.wav", .unlimited)).?;
    defer gpa.free(theme);
    try std.testing.expectEqualStrings("the game's theme", theme);
}

test "scripts and shaders don't replace game files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "mods/balance");
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/balance/mod.ini", .data = "[Scripts]\nLoad=balance.luau\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/balance/balance.luau", .data = "return {}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/balance/util.LUAU", .data = "return 1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/balance/gunstats.bin", .data = "guns" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/balance/crt.FRAG", .data = "void main() {}" });

    var mods: Mods = try .open(gpa, io, tmp.dir, null);
    defer mods.close(gpa);
    const balance = mods.list[0];
    // A shader belongs to the mod, and is read as its own file.
    try std.testing.expect(!mods.has("crt.frag"));
    const shader = (try balance.readFile(gpa, "crt.frag")).?;
    defer gpa.free(shader);
    // Scripts are found ignoring case, and aren't treated as replacement game files.
    var scripts = balance.scripts();
    try std.testing.expectEqualStrings("balance.luau", scripts.next().?);
    try std.testing.expectEqualStrings("util.LUAU", scripts.next().?);
    try std.testing.expectEqual(null, scripts.next());
    try std.testing.expect(!mods.has("balance.luau"));
    var names = balance.names();
    try std.testing.expectEqualStrings("gunstats.bin", names.next().?);
    try std.testing.expectEqual(null, names.next());
    // Files are read by name, ignoring case.
    const script = (try balance.readFile(gpa, "BALANCE.luau")).?;
    defer gpa.free(script);
    try std.testing.expectEqualStrings("return {}", script);
    try std.testing.expectEqual(null, try balance.readFile(gpa, "missing.luau"));
    try std.testing.expectEqualStrings("balance.luau", balance.manifest.value("Scripts", "Load").?);
}

test "a mod that needs a newer version is skipped" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_]struct { []const u8, []const u8 }{
        .{ "later", "OpenReliant=0.8" },
        .{ "same", "OpenReliant=0.7" },
        .{ "earlier", "OpenReliant=0.6.2" },
        .{ "unread", "OpenReliant=soon" },
        .{ "any", "Name=Any" },
    }) |mod| {
        const folder = try std.fmt.allocPrint(gpa, "mods/{s}", .{mod[0]});
        defer gpa.free(folder);
        try tmp.dir.createDirPath(io, folder);
        const manifest = try std.fmt.allocPrint(gpa, "{s}/mod.ini", .{folder});
        defer gpa.free(manifest);
        const text = try std.fmt.allocPrint(gpa, "[Mod]\n{s}\n", .{mod[1]});
        defer gpa.free(text);
        try tmp.dir.writeFile(io, .{ .sub_path = manifest, .data = text });
    }

    var played: Mods = try .open(gpa, io, tmp.dir, .{ .major = 0, .minor = 7, .patch = 1 });
    defer played.close(gpa);
    try std.testing.expectEqual(4, played.list.len);
    for (played.list) |mod| try std.testing.expect(!std.mem.eql(u8, mod.name, "later"));
    // Without a version, no mod is skipped.
    var every: Mods = try .open(gpa, io, tmp.dir, null);
    defer every.close(gpa);
    try std.testing.expectEqual(5, every.list.len);
}

test "the order says which mods are on and when they load" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_][]const u8{ "a", "b", "c", "d" }) |name| {
        const path = try std.fmt.allocPrint(gpa, "mods/{s}/ship.shp", .{name});
        defer gpa.free(path);
        try tmp.dir.createDirPath(io, std.fs.path.dirname(path).?);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = name });
    }
    // C goes first, then A, then D; B is off, and the mods the list lacks would follow.
    const order: Order = .{ .profile = .{ .text = "[OpenReliantMods]\nC=1\na=1\nB=0\nD=1\n" } };
    var mods: Mods = try .openOrdered(gpa, io, tmp.dir, null, order);
    defer mods.close(gpa);
    try std.testing.expectEqual(3, mods.list.len);
    for ([_][]const u8{ "c", "a", "d" }, mods.list) |name, mod| try std.testing.expectEqualStrings(name, mod.name);
    // The last mod to load wins; the one that is off is opened, and none of its files are used.
    try std.testing.expectEqual(&mods.list[2], mods.holder("ship.shp").?);
    try std.testing.expectEqual(1, mods.off.len);
    try std.testing.expectEqualStrings("b", mods.off[0].name);
    // A mod the list lacks loads after the listed ones, by name, and is on.
    try tmp.dir.createDirPath(io, "mods/aa");
    var more: Mods = try .openOrdered(gpa, io, tmp.dir, null, order);
    defer more.close(gpa);
    try std.testing.expectEqual(4, more.list.len);
    try std.testing.expectEqualStrings("aa", more.list[3].name);
}

test parseVersion {
    try std.testing.expectEqual(std.SemanticVersion{ .major = 0, .minor = 7, .patch = 0 }, parseVersion("0.7").?);
    try std.testing.expectEqual(std.SemanticVersion{ .major = 1, .minor = 2, .patch = 3 }, parseVersion("1.2.3").?);
    try std.testing.expectEqual(null, parseVersion("soon"));
    try std.testing.expectEqual(null, parseVersion("1"));
}

test "no mods folder" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var mods: Mods = try .open(gpa, std.testing.io, tmp.dir, null);
    defer mods.close(gpa);
    try std.testing.expectEqual(0, mods.list.len);
    try std.testing.expect(!mods.has("ship.shp"));
}

test "an archive is only loaded if it matches its checksum" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, folder_name);
    const bytes = try hog.build(gpa, &.{
        .{ .name = "ship.shp", .data = "a mod's ship" },
        .{ .name = "Mod.PNG", .data = "a picture of the mod" },
    });
    defer gpa.free(bytes);
    // `good.hog` matches its checksum; the checksum file next to `bad.hog`, whose name differs in
    // case, is for another archive; `plain.hog` has none.
    for ([_][]const u8{ "mods/good.hog", "mods/bad.hog", "mods/plain.hog" }) |path| {
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = bytes });
    }
    var buffer: [128]u8 = undefined;
    var line: Io.Writer = .fixed(&buffer);
    try checksums.writeLine(&line, checksums.digest(bytes), "good.hog");
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/good.hog.sha256", .data = line.buffered() });
    line = .fixed(&buffer);
    try checksums.writeLine(&line, checksums.digest("another archive"), "bad.hog");
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/BAD.HOG.SHA256", .data = line.buffered() });

    var mods: Mods = try .open(gpa, io, tmp.dir, null);
    defer mods.close(gpa);
    try std.testing.expectEqual(2, mods.list.len);
    try std.testing.expectEqualStrings("good.hog", mods.list[0].name);
    try std.testing.expectEqualStrings("plain.hog", mods.list[1].name);

    // The thumbnail belongs to the mod and doesn't replace a game file.
    const thumbnail = (try mods.list[0].thumbnail(gpa)).?;
    defer gpa.free(thumbnail);
    try std.testing.expectEqualStrings("a picture of the mod", thumbnail);
    try std.testing.expect(!mods.has("mod.png"));
    try std.testing.expect(mods.has("ship.shp"));
}

test GameFiles {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // An archive's members, a loose file in a folder, a texture cache image, and a mod file, which
    // isn't a game file.
    try hog.testing.write(gpa, io, tmp.dir, "resource.hog", &.{
        .{ .name = "Ship.SHP", .data = "ship" },
        .{ .name = "HUDHARD.SPR", .data = "shapes" },
        .{ .name = "Back.TGA", .data = "picture" },
    });
    try tmp.dir.createDirPath(io, "music");
    try tmp.dir.writeFile(io, .{ .sub_path = "music/theme.wav", .data = "theme" });
    const cache = try tcache.testing.build(gpa, &.{.{ .name = "yank_2", .encoding = .index8, .width = 2, .height = 2 }});
    defer gpa.free(cache);
    try tmp.dir.writeFile(io, .{ .sub_path = tcache.hardware_name, .data = cache });
    try tmp.dir.createDirPath(io, "Mods/own");
    try tmp.dir.writeFile(io, .{ .sub_path = "Mods/own/new.tga", .data = "new" });

    var own: GameFiles = try .gather(gpa, io, tmp.dir);
    defer own.deinit(gpa);
    try std.testing.expectEqual(.file, own.kindOf("SHIP.shp").?);
    try std.testing.expectEqual(.file, own.kindOf("theme.wav").?);
    try std.testing.expectEqual(.texture, own.kindOf("Yank_2.png").?);
    try std.testing.expectEqual(null, own.kindOf("new.tga"));
    const map = own.mapOf("yank_2_ROUGHNESS.png").?;
    try std.testing.expectEqualStrings("yank_2", map.texture);
    try std.testing.expectEqual(.roughness, map.kind);
    try std.testing.expectEqual(null, own.mapOf("hull_normal.png"));
    // A sprite set shape, by the picture name the interface looks up, and a picture.
    const shape = own.shapeOf("hudhard_021.PNG").?;
    try std.testing.expectEqualStrings("hudhard", shape.set);
    try std.testing.expectEqual(21, shape.index);
    try std.testing.expectEqual(1234, own.shapeOf("HUDHARD_1234.png").?.index);
    try std.testing.expectEqual(null, own.shapeOf("hudhard_21.png"));
    try std.testing.expectEqual(null, own.shapeOf("ship_001.png"));
    try std.testing.expectEqualStrings("BACK", own.pictureOf("BACK.png").?);
    try std.testing.expectEqual(null, own.pictureOf("ship.png"));
    try std.testing.expectEqual(null, own.pictureOf("back.tga"));
}

test effectOf {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // Two mods: `a`, and `b`, which loads after it.
    try tmp.dir.createDirPath(io, "mods/a");
    try tmp.dir.createDirPath(io, "mods/b");
    for ([_][]const u8{ "mods/a/hull.tga", "mods/b/hull.tga", "mods/b/ship.shp", "mods/b/yank_2.png", "mods/b/yank_2_normal.png", "mods/b/hudhard_021.png", "mods/b/back.png", "mods/b/logo.tga", "mods/b/OPTFNT.ttf" }) |path| {
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = path });
    }
    var mods: Mods = try .open(gpa, io, tmp.dir, null);
    defer mods.close(gpa);
    var own: GameFiles = .{};
    defer own.deinit(gpa);
    try own.add(gpa, "ship.shp", .file);
    try own.add(gpa, "yank_2.png", .texture);
    try own.add(gpa, "hudhard.spr", .file);
    try own.add(gpa, "back.tga", .file);
    try own.add(gpa, "optfnt.fnt", .file);

    // An earlier mod's file, a game file, a texture and one of its maps, a sprite set shape, a
    // picture, an outline font, and new files.
    try std.testing.expectEqual(&mods.list[0], effectOf(mods.list, 1, own, "hull.tga").over);
    try std.testing.expectEqual(.file, effectOf(mods.list, 1, own, "ship.shp"));
    try std.testing.expectEqualStrings("yank_2", effectOf(mods.list, 1, own, "yank_2.png").texture);
    try std.testing.expectEqual(.normal, effectOf(mods.list, 1, own, "yank_2_normal.png").map.kind);
    try std.testing.expectEqual(21, effectOf(mods.list, 1, own, "hudhard_021.png").shape.index);
    try std.testing.expectEqualStrings("back", effectOf(mods.list, 1, own, "back.png").picture);
    try std.testing.expectEqualStrings("OPTFNT", effectOf(mods.list, 1, own, "OPTFNT.ttf").font);
    try std.testing.expectEqual(.added, effectOf(mods.list, 1, own, "optfnt.woff"));
    try std.testing.expectEqual(.added, effectOf(mods.list, 1, own, "logo.tga"));
    // The first mod has no earlier mod's files to replace.
    try std.testing.expectEqual(.added, effectOf(mods.list, 0, own, "hull.tga"));
}
