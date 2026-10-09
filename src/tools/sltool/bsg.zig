//! `sltool bsg ...`: read Battlestar Galactica's files: its `.dte` missions, which keep StarLancer's
//! records, the command catalogue in its executable, its comms films and its `.hxb` archives
//! ([#1017](https://github.com/OpenReliant/openreliant/issues/1017)). `sltool cd` reads its disc.

const std = @import("std");

const openreliant = @import("openreliant");
const dte = openreliant.dte;
const xbe = openreliant.xbox.xbe;
const bsg = openreliant.games.bsg;
const talkie = openreliant.engine.game.talkie;

const sltool = @import("main.zig");
const Context = sltool.Context;

pub const Command = union(enum) {
    sections: struct { mission: []const u8 },
    parts: struct { mission: []const u8 },
    triggers: struct { mission: []const u8 },
    script: struct { mission: []const u8, executable: []const u8 },
    commands: struct { executable: []const u8 },
    films: struct { index: []const u8, data: []const u8 },
    film: struct { index: []const u8, data: []const u8, number: []const u8, out_dir: []const u8 },
    ls: struct { archive: []const u8 },
    extract: struct { archive: []const u8, out_dir: []const u8 },

    pub const usage =
        \\  bsg sections <mission>          list a Battlestar Galactica mission's sections
        \\  bsg parts <mission>             list its script's routines
        \\  bsg triggers <mission>          list its triggers
        \\  bsg script <mission> <default.xbe>
        \\                                  disassemble its script, naming the commands from the
        \\                                  game's executable
        \\  bsg commands <default.xbe>      list the commands in the game's executable
        \\  bsg films <video.idx> <videodata.dat>
        \\                                  list the comms films
        \\  bsg film <video.idx> <videodata.dat> <number|all> <out-dir>
        \\                                  save the frames of one comms film, or of all of them,
        \\                                  as PNG files
        \\  bsg ls <archive.hxb>            list the files in an archive
        \\  bsg extract <archive.hxb> <out-dir>
        \\                                  unpack every file of an archive, checking each one
        \\
    ;

    pub fn parse(args: []const [:0]const u8) error{Usage}!Command {
        const verb, const operands = try sltool.verbOf(Command, args);
        return switch (verb) {
            inline else => |tag| sltool.positional(Command, tag, operands),
        };
    }

    pub fn run(command: Command, ctx: Context) !void {
        switch (command) {
            .sections => |operands| try sections(ctx, try readMission(ctx, operands.mission)),
            .parts => |operands| {
                var directory: [dte.section_count]dte.DirectoryEntry = undefined;
                try sltool.dte.parts(ctx, (try readMission(ctx, operands.mission)).asDte(&directory));
            },
            .triggers => |operands| {
                var directory: [dte.section_count]dte.DirectoryEntry = undefined;
                try sltool.dte.triggers(ctx, (try readMission(ctx, operands.mission)).asDte(&directory), null);
            },
            .script => |operands| {
                var directory: [dte.section_count]dte.DirectoryEntry = undefined;
                const mission = (try readMission(ctx, operands.mission)).asDte(&directory);
                const names = try bsg.catalogue.names(ctx.arena, try readCatalogue(ctx, operands.executable));
                try sltool.dte.script(ctx, mission, null, .{ .listed = names });
            },
            .commands => |operands| try commands(ctx, try readCatalogue(ctx, operands.executable)),
            .films => |operands| try films(ctx, try readFilms(ctx, operands.index, operands.data)),
            .film => |operands| try film(ctx, try readFilms(ctx, operands.index, operands.data), operands.number, operands.out_dir),
            .ls => |operands| try list(ctx, try readArchive(ctx, operands.archive)),
            .extract => |operands| try extract(ctx, try readArchive(ctx, operands.archive), operands.out_dir),
        }
    }
};

fn readMission(ctx: Context, path: []const u8) !bsg.mission.Mission {
    return .parse(try ctx.readInput(path));
}

fn readCatalogue(ctx: Context, path: []const u8) ![]const bsg.catalogue.Command {
    return bsg.catalogue.read(ctx.arena, try .parse(try ctx.readInput(path)));
}

/// The comms films' index, and the films' bytes.
const Films = struct { index: bsg.comms.Index, data: []u8 };

fn readFilms(ctx: Context, index_path: []const u8, data_path: []const u8) !Films {
    return .{ .index = try .parse(try ctx.readInput(index_path)), .data = try ctx.readInput(data_path) };
}

fn readArchive(ctx: Context, path: []const u8) !bsg.wart.Archive {
    return .parse(try ctx.readInput(path));
}

fn sections(ctx: Context, mission: bsg.mission.Mission) !void {
    try ctx.stdout.writeAll("  #  count   size    offset  section\n");
    for (mission.directory, 0..) |entry, index| {
        if (entry.offset == 0) continue;
        const section: bsg.mission.Section = @fromBackingInt(@intCast(index));
        try ctx.stdout.print("{d:>3}  {d:>5}  {d:>5}  {x:0>8}  {f}", .{ index, entry.count, entry.record_size, entry.offset, section });
        try sltool.dte.printStarLancerSection(ctx, section.asDte());
    }
}

fn commands(ctx: Context, all: []const bsg.catalogue.Command) !void {
    for (all, 0..) |command, number| {
        try ctx.stdout.print("0x{X:0>2}  {s}", .{ number, command.name });
        if (command.description.len != 0) try ctx.stdout.print(": {s}", .{command.description});
        try ctx.stdout.writeByte('\n');
        for (command.params) |param| try ctx.stdout.print("        {s}\n", .{param.label});
    }
}

fn films(ctx: Context, all: Films) !void {
    try ctx.stdout.writeAll("   #     offset  frames  size\n");
    for (all.index.offsets, 0..) |offset, number| {
        const listed = all.index.film(all.data, number) catch {
            try ctx.stdout.print("{d:>4} {d:>10}  not a film\n", .{ number, offset });
            continue;
        };
        try ctx.stdout.print("{d:>4} {d:>10}  {d:>6}  {d}x{d}\n", .{ number, offset, listed.header.frames(), listed.header.size[0], listed.header.size[1] });
    }
}

/// Saves the frames of film `which`, a number or `all`, into `out_path`, each film's as
/// `film_<n>_<frame>.png`.
fn film(ctx: Context, all: Films, which: []const u8, out_path: []const u8) !void {
    const count = all.index.offsets.len;
    const first, const last = if (std.mem.eql(u8, which, "all")) .{ 0, count } else number: {
        const number = std.fmt.parseInt(usize, which, 10) catch count;
        if (number >= count) {
            try ctx.stdout.print("there is no film {s}: give a number from 0 to {d}, or all\n", .{ which, count -| 1 });
            return error.NoSuchFilm;
        }
        break :number .{ number, number + 1 };
    };
    var frames: usize = 0;
    for (first..last) |number| {
        const chosen = try all.index.film(all.data, number);
        const stem = try ctx.arena.print("film_{d:0>3}", .{number});
        frames += try sltool.fm8.saveFrames(ctx, .{ .bytes = chosen.chunks, .scrambled = false }, stem, out_path);
    }
    try ctx.stdout.print("wrote {f} of {f} to {s}\n", .{ sltool.count(frames, "frame"), sltool.count(last - first, "film"), out_path });
}

fn list(ctx: Context, archive: bsg.wart.Archive) !void {
    try ctx.stdout.writeAll("      size    stored  checksum  name\n");
    var stored: usize = 0;
    for (archive.entries) |entry| {
        if (entry.compressed()) {
            try ctx.stdout.print("{d:>10}{d:>10}", .{ entry.size, entry.stored_size });
        } else {
            try ctx.stdout.print("{d:>10}         -", .{entry.size});
            stored += 1;
        }
        try ctx.stdout.print("  {x:0>8}  {s}\n", .{ entry.checksum, try archive.name(entry) });
    }
    try ctx.stdout.print("{f}, {d} stored as they are\n", .{ sltool.count(archive.entries.len, "file"), stored });
}

/// Unpacks each file of `archive` into `out_path`, under its own path, checking its checksum. A file
/// the archive holds more than once is written once.
fn extract(ctx: Context, archive: bsg.wart.Archive, out_path: []const u8) !void {
    const io = ctx.io;
    var out_dir = try ctx.outputDir(out_path);
    defer out_dir.close(io);

    var written: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var files: usize = 0;
    var copies: usize = 0;
    var bytes: u64 = 0;
    for (archive.entries) |entry| {
        const path = try archive.name(entry);
        if (try written.fetchPut(ctx.arena, entry.name_offset, entry.checksum)) |earlier| {
            if (earlier.value != entry.checksum) try ctx.stdout.print("{s}: a later copy differs from the first, and is skipped\n", .{path});
            copies += 1;
            continue;
        }
        const data = try archive.unpackAlloc(ctx.arena, entry);
        if (std.Io.Dir.path.dirnamePosix(path)) |folder| try out_dir.createDirPath(io, folder);
        try out_dir.writeFile(io, .{ .sub_path = path, .data = data });
        ctx.arena.free(data);
        files += 1;
        bytes += entry.size;
    }
    try ctx.stdout.print("extracted {f} ({Bi:.1}) to {s}", .{ sltool.count(files, "file"), bytes, out_path });
    if (copies != 0) try ctx.stdout.print(", skipping {f}", .{sltool.count(copies, "duplicate")});
    try ctx.stdout.writeByte('\n');
}

test extract {
    const gpa = std.testing.allocator;
    const bytes = try bsg.wart.testing.build(gpa, &.{
        .{ .name = "levels/shv1vi00.lvl", .data = "level\r\n{\r\n\tname({SHV1VI00})\r\n}\r\n" },
        .{ .name = "sfx/hud/hud029.bwav", .data = "RIFF", .compressed = false },
        .{ .name = "levels/shv1vi00.lvl", .data = "level\r\n{\r\n\tname({SHV1VI00})\r\n}\r\n" },
    });
    defer gpa.free(bytes);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    const ctx: Context = .{ .io = std.testing.io, .arena = arena_state.allocator(), .stdout = &output.writer };
    const out_path = try std.fmt.allocPrint(arena_state.allocator(), ".zig-cache/tmp/{s}/out", .{tmp.sub_path});

    try extract(ctx, try .parse(bytes), out_path);
    const level = try tmp.dir.readFileAlloc(std.testing.io, "out/levels/shv1vi00.lvl", arena_state.allocator(), .limited(1 << 10));
    try std.testing.expectStringStartsWith(level, "level");
    const sound = try tmp.dir.readFileAlloc(std.testing.io, "out/sfx/hud/hud029.bwav", arena_state.allocator(), .limited(1 << 10));
    try std.testing.expectEqualStrings("RIFF", sound);
    try std.testing.expectStringEndsWith(output.written(), ", skipping 1 duplicate\n");
}

test Command {
    try std.testing.expectEqualStrings("default.xbe", (try Command.parse(&.{ "script", "M1a.dte", "default.xbe" })).script.executable);
    try std.testing.expectEqualStrings("all", (try Command.parse(&.{ "film", "video.idx", "videodata.dat", "all", "out" })).film.number);
    try std.testing.expectError(error.Usage, Command.parse(&.{ "script", "M1a.dte" }));
    try std.testing.expectEqualStrings("out", (try Command.parse(&.{ "extract", "bigwad.hxb", "out" })).extract.out_dir);
    try std.testing.expectError(error.Usage, Command.parse(&.{"play"}));
}
