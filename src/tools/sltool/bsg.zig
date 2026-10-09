//! `sltool bsg ...`: read Battlestar Galactica's files: its `.dte` missions, which keep StarLancer's
//! records, the command catalogue in its executable, and its comms films
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

test Command {
    try std.testing.expectEqualStrings("default.xbe", (try Command.parse(&.{ "script", "M1a.dte", "default.xbe" })).script.executable);
    try std.testing.expectEqualStrings("all", (try Command.parse(&.{ "film", "video.idx", "videodata.dat", "all", "out" })).film.number);
    try std.testing.expectError(error.Usage, Command.parse(&.{ "script", "M1a.dte" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{"play"}));
}
