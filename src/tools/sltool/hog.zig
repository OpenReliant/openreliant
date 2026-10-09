//! `sltool hog ...`: read the game's `.HOG` asset archives, and pack new ones.

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const files = openreliant.engine.files;
const checksums = openreliant.checksums;
const hog = openreliant.hog;
const refpack = openreliant.refpack;

const sltool = @import("main.zig");
const Context = sltool.Context;

pub const Command = union(enum) {
    info: struct { archive: []const u8 },
    ls: struct { archive: []const u8 },
    /// Extracts every member, decompressing unless `--raw`.
    extract: struct { archive: []const u8, out_dir: []const u8, flags: ExtractFlags = .{} },
    /// Packs every file of a folder into a new archive, compressing unless `--store`, with a
    /// checksum file beside it with `--checksum`.
    pack: struct { dir: []const u8, archive: []const u8, flags: PackFlags = .{} },

    const ExtractFlags = struct { raw: bool = false };
    const PackFlags = struct { store: bool = false, checksum: bool = false };

    pub const usage =
        \\  hog info <archive>              describe a .HOG archive
        \\  hog ls <archive>                list its members
        \\  hog extract <archive> <out-dir> [--raw]
        \\                                  extract every member, decompressing by default
        \\  hog pack <dir> <archive> [--store] [--checksum]
        \\                                  pack every file of a folder, compressing by default;
        \\                                  --checksum writes <archive>.sha256 beside it
        \\
    ;

    pub fn parse(args: []const [:0]const u8) error{Usage}!Command {
        const verb, const operands = try sltool.verbOf(Command, args);
        switch (verb) {
            .extract => {
                const flags = try flagsAfterTwo(ExtractFlags, operands);
                return .{ .extract = .{ .archive = operands[0], .out_dir = operands[1], .flags = flags } };
            },
            .pack => {
                const flags = try flagsAfterTwo(PackFlags, operands);
                return .{ .pack = .{ .dir = operands[0], .archive = operands[1], .flags = flags } };
            },
            inline else => |tag| return sltool.positional(Command, tag, operands),
        }
    }

    pub fn run(command: Command, ctx: Context) !void {
        switch (command) {
            .pack => |operands| try pack(ctx, operands.dir, operands.archive, operands.flags),
            inline .info, .ls, .extract => |operands, verb| {
                var archive = try hog.Archive.open(ctx.arena, ctx.io, .cwd(), operands.archive);
                defer archive.close(ctx.arena);
                switch (verb) {
                    .info => try info(ctx, archive),
                    .ls => try list(ctx, archive),
                    .extract => try extract(ctx, archive, operands.out_dir, operands.flags.raw),
                    .pack => comptime unreachable,
                }
            },
        }
    }
};

/// The flags that follow a command's two operands, in any order, each once: a field of `Flags`
/// for each, named as the flag less its `--`. A usage error for anything else.
fn flagsAfterTwo(comptime Flags: type, operands: []const [:0]const u8) error{Usage}!Flags {
    if (operands.len < 2) return error.Usage;
    var flags: Flags = .{};
    next: for (operands[2..]) |operand| {
        inline for (@typeInfo(Flags).@"struct".field_names) |name| {
            if (std.mem.eql(u8, operand, "--" ++ name)) {
                if (@field(flags, name)) return error.Usage;
                @field(flags, name) = true;
                continue :next;
            }
        }
        return error.Usage;
    }
    return flags;
}

fn info(ctx: Context, archive: hog.Archive) !void {
    var compressed: usize = 0;
    var stored_total: u64 = 0;
    var real_total: u64 = 0;

    for (archive.entries) |entry| {
        stored_total += entry.size;
        if (try archive.expandedSize(entry)) |size| {
            compressed += 1;
            real_total += size;
        } else {
            real_total += entry.size;
        }
    }

    try ctx.stdout.print(
        \\archive size: {Bi:.1}
        \\members:      {d}
        \\directory:    {d} bytes, members start at {x:0>6}
        \\contiguous:   {}
        \\compressed:   {d} of {d} members (RefPack)
        \\stored:       {Bi:.1}
        \\uncompressed: {Bi:.1}
        \\
    , .{
        archive.header.archive_size.get(),
        archive.entries.len,
        archive.header.data_offset.get() - @sizeOf(hog.Header),
        archive.header.data_offset.get(),
        archive.isContiguous(),
        compressed,
        archive.entries.len,
        stored_total,
        real_total,
    });

    if (archive.phantom_entries > 0) {
        try ctx.stdout.print(
            "\nthe header counts {d} more entr{s}, which the directory does not hold: trailing\n" ++
                "filler left by the packer, past the last real member\n",
            .{ archive.phantom_entries, if (archive.phantom_entries == 1) "y" else "ies" },
        );
    }
}

fn list(ctx: Context, archive: hog.Archive) !void {
    for (archive.entries) |entry| {
        if (try archive.expandedSize(entry)) |size| {
            try ctx.stdout.print("{x:0>8}  {d:>9} {d:>10}  {s}\n", .{ entry.offset, entry.size, size, entry.name });
        } else {
            try ctx.stdout.print("{x:0>8}  {d:>9} {s:>10}  {s}\n", .{ entry.offset, entry.size, "-", entry.name });
        }
    }
}

fn extract(ctx: Context, archive: hog.Archive, out_path: []const u8, raw: bool) !void {
    const io = ctx.io;
    var out_dir = try ctx.outputDir(out_path);
    defer out_dir.close(io);

    // Member names are not unique, and several duplicates hold different data, so a later member
    // must not overwrite an earlier one.
    var names: sltool.UniqueNames = .{};
    var written: u64 = 0;
    for (archive.entries) |entry| {
        const bytes = if (raw)
            try archive.readRaw(ctx.arena, entry)
        else
            (try archive.read(ctx.arena, entry)).bytes;
        defer ctx.arena.free(bytes);

        try out_dir.writeFile(io, .{ .sub_path = try names.of(ctx.arena, entry.name), .data = bytes });
        written += bytes.len;
    }

    try ctx.stdout.print("extracted {f} ({Bi:.1}{s}) to {s}\n", .{
        sltool.count(archive.entries.len, "member"),
        written,
        if (raw) ", as stored" else ", decompressed",
        out_path,
    });
    try names.report(ctx, "member");
}

/// Packs every file of the folder `dir_path` into a new archive at `path`, each file a member of
/// its own name, in name order so that a folder packs the same wherever it is. Each member is
/// stored as `hog.packMember` finds best, or with `store` compressed only where it must be
/// (`hog.Packing.store`). The `~N` suffix `extract` gives a repeated name stays part of the
/// member's name. With `checksum`, a checksum file of the archive goes beside it, as
/// `sha256sum` writes one (`checksums`).
fn pack(ctx: Context, dir_path: []const u8, path: []const u8, flags: Command.PackFlags) !void {
    const io = ctx.io;
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!hog.validName(entry.name)) {
            std.debug.print("{s}: a member's name is printable ASCII\n", .{entry.name});
            return error.BadName;
        }
        try names.append(ctx.arena, try ctx.arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, hog.nameOrder);

    var compressor: refpack.Compressor = try .init(ctx.arena);
    defer compressor.deinit(ctx.arena);
    const packing: hog.Packing = if (flags.store) .store else .compress;
    var counts: std.EnumArray(hog.Storage, usize) = .initFill(0);
    const members = try ctx.arena.alloc(hog.Member, names.items.len);
    for (names.items, members) |name, *member| {
        const data = try dir.readFileAlloc(io, name, ctx.arena, .limited(files.max_file_size));
        const stored = hog.packMember(ctx.arena, &compressor, packing, name, data) catch |err| switch (err) {
            error.Unloadable => {
                std.debug.print("{s}: begins 10 FB, so the game would expand it, and no stream of it loads\n", .{name});
                return err;
            },
            error.OutOfMemory => |e| return e,
        };
        member.* = .{ .name = name, .data = stored.bytes };
        counts.getPtr(stored.storage).* += 1;
    }

    const bytes = try hog.build(ctx.arena, members);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    if (flags.checksum) {
        var line: Io.Writer.Allocating = .init(ctx.arena);
        try checksums.writeLine(&line.writer, checksums.digest(bytes), std.Io.Dir.path.basename(path));
        const checksum_path = try ctx.arena.print("{s}" ++ checksums.extension, .{path});
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = checksum_path, .data = line.written() });
        try ctx.stdout.print("wrote {s}\n", .{checksum_path});
    }
    try ctx.stdout.print("packed {f} ({Bi:.1}) into {s}: {d} compressed, {d} already compressed, {d} stored\n", .{
        sltool.count(members.len, "member"),
        bytes.len,
        path,
        counts.get(.compressed),
        counts.get(.already_compressed),
        counts.get(.stored),
    });
}

test Command {
    const parsed = try Command.parse(&.{ "extract", "LANCER.HOG", "out", "--raw" });
    try std.testing.expect(parsed.extract.flags.raw);
    try std.testing.expectEqualStrings("out", parsed.extract.out_dir);
    try std.testing.expect(!(try Command.parse(&.{ "extract", "LANCER.HOG", "out" })).extract.flags.raw);
    try std.testing.expectEqualStrings("A.HOG", (try Command.parse(&.{ "info", "A.HOG" })).info.archive);

    try std.testing.expectError(error.Usage, Command.parse(&.{ "extract", "LANCER.HOG", "out", "--fast" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{"ls"}));
    try std.testing.expectError(error.Usage, Command.parse(&.{}));

    const packing = try Command.parse(&.{ "pack", "mod", "MOD.HOG" });
    try std.testing.expectEqualStrings("mod", packing.pack.dir);
    try std.testing.expectEqualStrings("MOD.HOG", packing.pack.archive);
    try std.testing.expectEqual(Command.PackFlags{}, packing.pack.flags);
    try std.testing.expect((try Command.parse(&.{ "pack", "mod", "MOD.HOG", "--store" })).pack.flags.store);
    // Flags in any order, each once.
    const both = try Command.parse(&.{ "pack", "mod", "MOD.HOG", "--checksum", "--store" });
    try std.testing.expectEqual(Command.PackFlags{ .store = true, .checksum = true }, both.pack.flags);
    try std.testing.expectError(error.Usage, Command.parse(&.{ "pack", "mod", "MOD.HOG", "--store", "--store" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "pack", "mod", "MOD.HOG", "--raw" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "pack", "mod" }));
}

/// A sentence the test repeats into a text worth packing.
const fox = "The quick brown fox jumps over the lazy dog. ";

test pack {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A folder of a text worth packing, a movie, a member extracted as stored, and a folder
    // `pack` passes over.
    const text: []const u8 = @ptrCast(&@as([20][fox.len]u8, @splat(fox.*)));
    const already = try refpack.compressAlloc(arena, "abcdabcdabcdabcdabcd");
    var mod = try tmp.dir.createDirPathOpen(io, "mod", .{});
    defer mod.close(io);
    try mod.writeFile(io, .{ .sub_path = "readme.txt", .data = text });
    try mod.writeFile(io, .{ .sub_path = "warty_.bik", .data = text });
    try mod.writeFile(io, .{ .sub_path = "Ship.SHP", .data = already });
    try mod.createDirPath(io, "folder");

    var out: Io.Writer.Allocating = .init(arena);
    const ctx: Context = .{ .io = io, .arena = arena, .stdout = &out.writer };
    const base = try arena.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    const archive_path = try arena.print("{s}/MOD.HOG", .{base});
    try pack(ctx, try arena.print("{s}/mod", .{base}), archive_path, .{ .checksum = true });
    try std.testing.expect(std.mem.find(u8, out.written(), "1 compressed, 1 already compressed, 1 stored") != null);

    // The archive reads back as the files it was packed from, in name order.
    var archive: hog.Archive = try .open(arena, io, tmp.dir, "MOD.HOG");
    defer archive.close(arena);
    try std.testing.expect(archive.isContiguous());
    try std.testing.expectEqual(3, archive.entries.len);
    try std.testing.expectEqualStrings("Ship.SHP", archive.entries[0].name);
    const readme = try archive.read(arena, archive.find("README.TXT").?);
    try std.testing.expect(readme.compressed);
    try std.testing.expectEqualStrings(text, readme.bytes);
    try std.testing.expectEqualSlices(u8, already, try archive.readRaw(arena, archive.find("ship.shp").?));
    try std.testing.expectEqualStrings(text, try archive.readRaw(arena, archive.find("warty_.bik").?));

    // The checksum file beside it gives the archive's digest, under the archive's name.
    const packed_bytes = try tmp.dir.readFileAlloc(io, "MOD.HOG", arena, .unlimited);
    const checksum = try tmp.dir.readFileAlloc(io, "MOD.HOG" ++ checksums.extension, arena, .unlimited);
    try std.testing.expectEqual(checksums.digest(packed_bytes), (try checksums.digestOf(checksum, "MOD.HOG")).?);
    try std.testing.expect(std.mem.endsWith(u8, checksum, "  MOD.HOG\n"));
}
