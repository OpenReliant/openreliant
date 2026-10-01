//! OpenReliant's mods: the archives and folders in the `mods` folder of the game's, whose files
//! stand in for the game's own of the same names wherever the game keeps them: the members of its
//! archives, `resource.hog`, the speech's, the pilots' films' and the discs', and its loose files,
//! such as its music, its movies, its missions and its tables. So a mod replaces a model, a
//! picture of the interface, a sound, a piece of music, a line of speech or a movie alike, with a
//! file of the name of the one it replaces, and adds a file under a name of its own.
//!
//! A mod is an archive of the game's own format, a `.hog`, or a folder of files, as for a mod while
//! it is being made, read as the archive `sltool hog pack` makes of the folder reads. Its names are
//! flat, as the archives' are, and the game keeps no two files of one name but as copies of one
//! another. The mods come before the game's own files, the last in the order of their names
//! first. Each may describe itself in a manifest, `mod.ini`.
//! [docs/guide/modding.md](../../../../docs/guide/modding.md) is the modder's guide.
//!
//! **Improvement:** the original reads its own files alone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const checksums = @import("../../../formats/checksums.zig");
const hog = @import("../../../formats/hog.zig");
const refpack = @import("../../../formats/refpack.zig");
const files = @import("../../files.zig");
const profile = @import("../../profile.zig");
const bigfile = @import("../bigfile.zig");

const log = std.log.scoped(.mods);

/// The folder of the game's that holds the mods, found whatever the case of its name.
pub const folder_name = "mods";

/// The extension of a mod's archive, whatever its case.
pub const archive_extension = ".hog";

/// The file a mod describes itself in, in its archive or its folder: an ini file whose
/// `manifest_section` holds what `Field` names. The game asks for no file of the name, so that it
/// stays the mod's own, and the archive one of the game's format.
pub const manifest_name = "mod.ini";

/// The manifest's section that describes the mod.
pub const manifest_section = "Mod";

/// A picture of the mod, in its archive or its folder, which a mod manager shows
/// ([#497](https://github.com/vdmkenny/openreliant/issues/497)): a PNG file. Like the manifest, it
/// is the mod's own.
pub const thumbnail_name = "mod.png";

/// The files a mod keeps of its own, which stand in for none of the game's.
const own_files = [_][]const u8{ manifest_name, thumbnail_name };

/// What a mod's manifest says of it, each under its key in `manifest_section`.
pub const Field = enum {
    /// The name a player knows it by.
    name,
    version,
    author,
    /// What it changes, in a line.
    description,
    /// Its page on the web, where it comes from.
    url,

    /// Its key, which the manifest gives in any case.
    pub fn key(field: Field) []const u8 {
        return switch (field) {
            .name => "Name",
            .version => "Version",
            .author => "Author",
            .description => "Description",
            .url => "Url",
        };
    }
};

/// How a file is read: as `hog_read_file` (`0x004C7F60`) reads a member, expanded where RefPack
/// packed it, or as it is stored, as Bink reads a movie and the radio a face film where they lie.
const Reading = enum { expanded, stored };

/// A mod: its files, and what its manifest says of it.
pub const Mod = struct {
    /// Its archive's or its folder's name in the `mods` folder, as it is spelled there.
    name: []const u8,
    source: Source,
    /// Its manifest; empty where it has none.
    manifest: profile.Profile = .empty,

    pub const Source = union(enum) {
        archive: hog.Archive,
        folder: Folder,

        /// The entry `name` of the `mods` folder `folder`, of the kind `kind`: an archive where it
        /// is a `.hog` file, a folder of files where it is a folder, and `error.NotAMod` otherwise.
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

    /// What its manifest says of `field`; null where it says nothing.
    pub fn about(mod: Mod, field: Field) ?[]const u8 {
        const text = mod.manifest.value(manifest_section, field.key()) orelse return null;
        return if (text.len > 0) text else null;
    }

    /// It as the log names it: by the name, the version and the author its manifest gives, with
    /// its name in the `mods` folder after them, or by that name alone.
    pub fn format(mod: Mod, writer: *Io.Writer) Io.Writer.Error!void {
        const title = mod.about(.name);
        try writer.writeAll(title orelse mod.name);
        if (mod.about(.version)) |version| try writer.print(" {s}", .{version});
        if (mod.about(.author)) |author| try writer.print(", by {s}", .{author});
        if (title != null) try writer.print(" ({s})", .{mod.name});
    }

    /// Its thumbnail's bytes, as the file holds them; null where it has none.
    pub fn thumbnail(mod: Mod, gpa: Allocator) bigfile.ReadError!?[]u8 {
        const file = mod.find(thumbnail_name) orelse return null;
        return try mod.read(gpa, file, .expanded);
    }

    /// The names of its files, in its order, its own left out (`own_files`).
    pub fn names(mod: *const Mod) Names {
        return .{ .mod = mod };
    }

    pub const Names = struct {
        mod: *const Mod,
        file: usize = 0,

        pub fn next(listed: *Names) ?[]const u8 {
            while (listed.file < listed.mod.count()) {
                const name = listed.mod.fileName(listed.file);
                listed.file += 1;
                if (!isOwn(name)) return name;
            }
            return null;
        }
    };

    /// How many files it holds, its own among them.
    fn count(mod: Mod) usize {
        return switch (mod.source) {
            .archive => |archive| archive.entries.len,
            .folder => |folder| folder.names.len,
        };
    }

    /// The name of its file `file`, as it is spelled.
    fn fileName(mod: Mod, file: usize) []const u8 {
        return switch (mod.source) {
            .archive => |archive| archive.entries[file].name,
            .folder => |folder| folder.names[file],
        };
    }

    /// Its first file of the name `name`, whatever its case; null where it holds none.
    fn find(mod: Mod, name: []const u8) ?usize {
        for (0..mod.count()) |file| {
            if (std.ascii.eqlIgnoreCase(mod.fileName(file), name)) return file;
        }
        return null;
    }

    /// Its file `file`, read as `reading` has it.
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

    /// The mod `name` of the `mods` folder `folder` (`Source.open`), with its manifest where it has
    /// one. Null where it is no mod, can't be opened, or is an archive that fails its checksum
    /// (`intact`), which the log says.
    fn open(gpa: Allocator, io: Io, folder: Io.Dir, name: []const u8, kind: Io.File.Kind) Allocator.Error!?Mod {
        if (kind == .file and isArchive(name) and !try intact(gpa, io, folder, name)) return null;
        var source = Source.open(gpa, io, folder, name, kind) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.NotAMod => {
                log.warn("{s} is left out: a mod is an archive, {s}, or a folder", .{ name, archive_extension });
                return null;
            },
            else => {
                log.warn("the mod {s} is left out: {s}", .{ name, @errorName(err) });
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
            else => log.warn("{s}'s {s} is left out: {s}", .{ name, manifest_name, @errorName(err) }),
        }
        return mod;
    }

    fn close(mod: *Mod, gpa: Allocator) void {
        mod.source.close(gpa);
        gpa.free(mod.manifest.text);
        gpa.free(mod.name);
    }
};

/// Whether the archive `name` of the `mods` folder `folder` may be read: where no checksum file lies
/// beside it, the archive's name with `checksums.extension` added, found whatever its case, or where
/// the file gives the archive's digest. Where it gives another, or can't be read, the archive is
/// damaged or not the one the checksum was made for, and the log says so.
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
        const wanted = (checksums.digestOf(text, name) catch break :failed "it is no checksum file") orelse
            break :failed "it gives no checksum for the archive";
        const file = folder.openFile(io, name, .{}) catch |err| break :failed @errorName(err);
        defer file.close(io);
        const digest = checksums.digestFile(io, file) catch |err| break :failed @errorName(err);
        if (!std.mem.eql(u8, &digest, &wanted)) break :failed "the archive is damaged, or not the one it was made for";
        log.info("{s} matches {s}", .{ name, path });
        return true;
    };
    log.warn("the mod {s} is left out: it fails {s}: {s}", .{ name, path, failure });
    return false;
}

/// The most of a checksum file `intact` reads, far past a line for each file of a mod.
const max_checksum_size = 1 << 16;

/// A mod's folder: each file in it one of the mod's, by its own name, as `sltool hog pack` packs
/// them, and read as the member it packs would be.
pub const Folder = struct {
    io: Io,
    dir: Io.Dir,
    /// Its files' names as they are spelled, in the order `sltool hog pack` packs them
    /// (`hog.nameOrder`).
    names: []const []const u8,

    /// The files of the folder `name` in `parent`. A folder in it, and a file of a name no
    /// archive's member has (`hog.validName`), are left out, as `sltool hog pack` leaves them,
    /// which the log says.
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
                    log.warn("{s}/{s} is left out: a mod's files lie in its folder itself", .{ name, entry.name });
                    continue;
                },
                else => continue,
            }
            if (!hog.validName(entry.name)) {
                log.warn("{s}/{s} is left out: a file's name is printable ASCII, as an archive's members' are", .{ name, entry.name });
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

    /// Its file `name`, read as `reading` has it. Expanded, it reads as the member `hog.packMember`
    /// makes of it would: a RefPack stream the game expands, as a member extracted as stored holds,
    /// expanded, and any other file as it is.
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

/// The mods the game is played with, and where the file of each name is read from.
pub const Mods = struct {
    /// The mods, in their order.
    list: []Mod = &.{},
    /// Each file the mods hold, by its name in lower case: the last mod's of the name.
    index: std.StringHashMapUnmanaged(Place) = .empty,

    /// No mods, as with `--no-mods`.
    pub const none: Mods = .{};

    /// A file of a mod: the mod, by its place in the list, and the file, by its place in the mod.
    const Place = struct { mod: usize, file: usize };

    /// The mods in the game's folder `game`: each `.hog` in its `mods` folder an archive, and each
    /// folder in it a folder of files, in the order of their names, whatever their case. Anything
    /// else there, and a mod that can't be opened, is left out, which the log says; none where the
    /// game's folder has no `mods` folder. The log lists each mod, and what each of its files
    /// replaces or adds (`report`).
    pub fn open(gpa: Allocator, io: Io, game: Io.Dir) Allocator.Error!Mods {
        var path: [files.max_path]u8 = undefined;
        const found = files.find(io, game, folder_name, &path) orelse return .none;
        var folder = game.openDir(io, found, .{ .iterate = true }) catch |err| {
            log.warn("{s} can't be opened: {s}; no mod is read", .{ found, @errorName(err) });
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
            log.warn("{s} can't be listed: {s}; no mod is read", .{ found, @errorName(err) });
            return .none;
        }) |entry| {
            // A checksum file belongs to the archive it checks (`intact`).
            if (hidden(entry.name) or isChecksum(entry.name)) continue;
            const kind = kindOf(io, folder, entry) orelse continue;
            const name = try gpa.dupe(u8, entry.name);
            errdefer gpa.free(name);
            try entries.append(gpa, .{ .name = name, .kind = kind });
        }
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.lessThan);

        var list: std.ArrayList(Mod) = .empty;
        defer list.deinit(gpa);
        errdefer for (list.items) |*mod| mod.close(gpa);
        for (entries.items) |entry| {
            var mod = try Mod.open(gpa, io, folder, entry.name, entry.kind) orelse continue;
            list.append(gpa, mod) catch |err| {
                mod.close(gpa);
                return err;
            };
        }
        var mods: Mods = .{ .list = try list.toOwnedSlice(gpa) };
        errdefer mods.close(gpa);
        try mods.makeIndex(gpa);
        try mods.report(gpa, io, game);
        return mods;
    }

    pub fn close(mods: *Mods, gpa: Allocator) void {
        freeIndex(Place, &mods.index, gpa);
        for (mods.list) |*mod| mod.close(gpa);
        gpa.free(mods.list);
        mods.* = .none;
    }

    /// Whether a mod holds the file `name`, whatever its case.
    pub fn has(mods: *const Mods, name: []const u8) bool {
        return mods.place(name) != null;
    }

    /// The mod the file `name` is read from, whatever its case: the last that holds one; null where
    /// none does.
    pub fn holder(mods: *const Mods, name: []const u8) ?*const Mod {
        const found = mods.place(name) orelse return null;
        return &mods.list[found.mod];
    }

    /// The file `name`, whatever its case, from the last mod that holds one, as `hog_read_file`
    /// (`0x004C7F60`) reads a member: expanded where RefPack packed it. Null where no mod holds it.
    pub fn readFile(mods: *const Mods, gpa: Allocator, name: []const u8) bigfile.ReadError!?[]u8 {
        const found = mods.place(name) orelse return null;
        return try mods.list[found.mod].read(gpa, found.file, .expanded);
    }

    /// The file `name`, whatever its case, from the last mod that holds one, as it is stored, as
    /// Bink reads a movie and the radio a face film where they lie. Null where no mod holds it.
    pub fn readStored(mods: *const Mods, gpa: Allocator, name: []const u8) bigfile.ReadError!?[]u8 {
        const found = mods.place(name) orelse return null;
        return try mods.list[found.mod].read(gpa, found.file, .stored);
    }

    /// The file that stands in for the game's loose file `path`: the file of its name, the part of
    /// the path past its last `\` or `/`, from the last mod that holds one, as `readFile` reads it.
    /// Null where no mod holds one.
    pub fn readInPlaceOf(mods: *const Mods, gpa: Allocator, path: []const u8) bigfile.ReadError!?[]u8 {
        return mods.readFile(gpa, std.fs.path.basenameWindows(path));
    }

    /// The game's loose file `path` under its folder `dir`: a mod's in its place
    /// (`readInPlaceOf`), else the file itself, found as `files.readFile` finds it, of at most
    /// `limit`. Null where there is neither.
    pub fn readLoose(mods: *const Mods, io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8, limit: Io.Limit) bigfile.ReadError!?[]u8 {
        if (try mods.readInPlaceOf(gpa, path)) |bytes| return bytes;
        return files.readFile(io, gpa, dir, path, limit);
    }

    fn place(mods: *const Mods, name: []const u8) ?Place {
        var buffer: [files.max_path]u8 = undefined;
        return mods.index.get(lowered(&buffer, name) orelse return null);
    }

    /// Indexes each file of the mods by its name: the first of a name in one mod, as an archive's
    /// lookup takes the first, and a later mod's in place of an earlier's. Manifests are left out.
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

    /// Lists each mod in the log, in its order, and each of its files: in place of an earlier
    /// mod's, in place of one of the game's own (`GameFiles`), or added.
    fn report(mods: *const Mods, gpa: Allocator, io: Io, game: Io.Dir) Allocator.Error!void {
        if (mods.list.len == 0) return;
        var own: GameFiles = try .gather(gpa, io, game);
        defer own.deinit(gpa);
        for (mods.list, 0..) |*mod, at| {
            log.info("mod {d} of {d}: {f}", .{ at + 1, mods.list.len, mod.* });
            var names = mod.names();
            while (names.next()) |name| {
                if (lastHolder(mods.list[0..at], name)) |earlier| {
                    log.info("{s} replaces {s}'s {s}", .{ mod.name, earlier.name, name });
                } else if (own.has(name)) {
                    log.info("{s} replaces {s}", .{ mod.name, name });
                } else {
                    log.info("{s} adds {s}", .{ mod.name, name });
                }
            }
        }
    }
};

/// The last of `list` that holds the file `name`, whatever its case.
fn lastHolder(list: []const Mod, name: []const u8) ?*const Mod {
    var at = list.len;
    while (at > 0) {
        at -= 1;
        if (list[at].find(name) != null) return &list[at];
    }
    return null;
}

/// The names of the game's own files, in lower case: the members of each archive in its folder and
/// its loose files, those of the `mods` folder left out.
const GameFiles = struct {
    names: std.StringHashMapUnmanaged(void) = .empty,

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
                    for (archive.entries) |member| try gathered.add(gpa, member.name);
                } else try gathered.add(gpa, entry.basename),
                else => {},
            }
        }
        return gathered;
    }

    fn add(gathered: *GameFiles, gpa: Allocator, name: []const u8) Allocator.Error!void {
        var buffer: [files.max_path]u8 = undefined;
        const slot = try gathered.names.getOrPut(gpa, lowered(&buffer, name) orelse return);
        if (slot.found_existing) return;
        slot.key_ptr.* = gpa.dupe(u8, slot.key_ptr.*) catch |err| {
            gathered.names.removeByPtr(slot.key_ptr);
            return err;
        };
    }

    fn has(gathered: GameFiles, name: []const u8) bool {
        var buffer: [files.max_path]u8 = undefined;
        return gathered.names.contains(lowered(&buffer, name) orelse return false);
    }

    fn deinit(gathered: *GameFiles, gpa: Allocator) void {
        freeIndex(void, &gathered.names, gpa);
    }
};

/// `name` in lower case, in `buffer`, as the indexes key it; null for a name longer than any path
/// the game builds, which no index holds.
fn lowered(buffer: *[files.max_path]u8, name: []const u8) ?[]const u8 {
    return if (name.len <= buffer.len) std.ascii.lowerString(buffer, name) else null;
}

/// Lets an index of names go, with the names it made.
fn freeIndex(comptime Value: type, index: *std.StringHashMapUnmanaged(Value), gpa: Allocator) void {
    var keys = index.keyIterator();
    while (keys.next()) |key| gpa.free(key.*);
    index.deinit(gpa);
}

/// Whether the file `name` is one a mod keeps of its own (`own_files`), whatever its case.
fn isOwn(name: []const u8) bool {
    for (own_files) |own| {
        if (std.ascii.eqlIgnoreCase(name, own)) return true;
    }
    return false;
}

/// Whether `name` is a checksum file's, by its extension, whatever its case.
fn isChecksum(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(name), checksums.extension);
}

/// Whether `name` is an archive's, by its extension, whatever its case.
fn isArchive(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(name), archive_extension);
}

/// Whether a file or folder is hidden by its name, as `.DS_Store` and `.git` are, which the mods
/// pass over.
fn hidden(name: []const u8) bool {
    return std.mem.startsWith(u8, name, ".");
}

/// What the entry `entry` of `dir` is, a link taken as what it leads to; null where that can't be
/// told.
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

    // Two mods, in the order of their names whatever their case: a folder, `Alpha`, and an archive,
    // `beta.hog`, which comes after it, so that its files come first. The folder holds a manifest,
    // a file extracted as stored, a RefPack stream, and a folder of its own, which is left out, as
    // is what the mods folder holds that is no mod.
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
    // The game's own loose file, which a mod's of its name stands in for.
    try tmp.dir.createDirPath(io, "music");
    try tmp.dir.writeFile(io, .{ .sub_path = "music/theme.wav", .data = "the game's theme" });

    var mods: Mods = try .open(gpa, io, tmp.dir);
    defer mods.close(gpa);
    try std.testing.expectEqual(2, mods.list.len);
    try std.testing.expectEqualStrings("Alpha", mods.list[0].name);
    try std.testing.expectEqualStrings("beta.hog", mods.list[1].name);

    // The last mod's file of a name, whatever its case; an earlier mod's where no later has one.
    const ship = (try mods.readFile(gpa, "SHIP.shp")).?;
    defer gpa.free(ship);
    try std.testing.expectEqualStrings("beta's ship", ship);
    try std.testing.expectEqual(&mods.list[1], mods.holder("Ship.SHP").?);
    const logo = (try mods.readFile(gpa, "LOGO.TGA")).?;
    defer gpa.free(logo);
    try std.testing.expectEqualStrings("alpha's logo", logo);
    try std.testing.expectEqual(null, try mods.readFile(gpa, "missing.tga"));
    try std.testing.expect(!mods.has("hull.png"));
    // A stream reads expanded, as `hog_read_file` reads a member, and as it is when stored.
    const expanded = (try mods.readFile(gpa, "packed.dat")).?;
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings("abcdabcdabcdabcdabcd", expanded);
    const stored = (try mods.readStored(gpa, "packed.dat")).?;
    defer gpa.free(stored);
    try std.testing.expectEqualSlices(u8, stream, stored);

    // The manifest describes its mod, and is none of the game's files.
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

    // A loose file of the game's, from a mod where one holds its name, and from its folder
    // otherwise.
    const line = (try mods.readLoose(io, gpa, tmp.dir, "ms_speech\\abrt_001", .unlimited)).?;
    defer gpa.free(line);
    try std.testing.expectEqualStrings("beta's line", line);
    const theme = (try mods.readLoose(io, gpa, tmp.dir, "music\\THEME.wav", .unlimited)).?;
    defer gpa.free(theme);
    try std.testing.expectEqualStrings("the game's theme", theme);
}

test "no mods folder" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var mods: Mods = try .open(gpa, std.testing.io, tmp.dir);
    defer mods.close(gpa);
    try std.testing.expectEqual(0, mods.list.len);
    try std.testing.expect(!mods.has("ship.shp"));
}

test "an archive is read where it matches its checksum" {
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
    // `good.hog` matches its checksum; the checksum beside `bad.hog`, whatever its case, is
    // another's; `plain.hog` has none.
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

    var mods: Mods = try .open(gpa, io, tmp.dir);
    defer mods.close(gpa);
    try std.testing.expectEqual(2, mods.list.len);
    try std.testing.expectEqualStrings("good.hog", mods.list[0].name);
    try std.testing.expectEqualStrings("plain.hog", mods.list[1].name);

    // The thumbnail is the mod's own, and stands in for none of the game's files.
    const thumbnail = (try mods.list[0].thumbnail(gpa)).?;
    defer gpa.free(thumbnail);
    try std.testing.expectEqualStrings("a picture of the mod", thumbnail);
    try std.testing.expect(!mods.has("mod.png"));
    try std.testing.expect(mods.has("ship.shp"));
}
