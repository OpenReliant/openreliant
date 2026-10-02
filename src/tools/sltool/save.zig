//! `sltool save ...`: read the game's saved games, the IFF files in its `saves` folder.

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const layout = openreliant.layout;
const gameflow = openreliant.engine.game.gameflow;
const save = gameflow.save;
const Outcome = openreliant.engine.vm.Variables.Outcome;
const loadout = openreliant.engine.interface.loadout;

const sltool = @import("main.zig");
const Context = sltool.Context;

pub const Command = union(enum) {
    info: struct { file: []const u8 },
    ls: struct { folder: []const u8 },

    pub const usage =
        \\  save info <file.IFF>            show everything a saved game holds
        \\  save ls <folder>                list the saved games in a folder, such as the game's saves
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
            .info => |operands| try info(ctx, operands.file),
            .ls => |operands| try list(ctx, operands.folder),
        }
    }
};

/// The saved game in `bytes`, or null where they hold none.
fn parse(bytes: []const u8) ?save.Save {
    var read = save.empty();
    return if (save.read(bytes, &read)) read else null;
}

fn info(ctx: Context, path: []const u8) !void {
    const read = parse(try ctx.readInput(path)) orelse {
        try ctx.stdout.writeAll("not a saved game: no SAVE form\n");
        return;
    };
    try show(ctx.stdout, &read);
}

/// Writes what `read` holds, field by field.
fn show(w: *Io.Writer, read: *const save.Save) Io.Writer.Error!void {
    const miss = &read.miss;
    try w.print("name        {s}\n", .{read.name.slice()});
    try w.print("mission     {d}\n", .{miss.mission});
    try w.print("call sign   {s}\n", .{std.mem.sliceTo(&miss.call_sign, 0)});
    try w.print("rank        {d}\n", .{miss.rank});
    try w.print("tier        {d}\n", .{miss.tier});
    try w.print("kills       {d}\n", .{miss.kills});
    try w.writeAll("difficulty  ");
    try layout.formatTag(@TypeOf(miss.difficulty), miss.difficulty, w);
    try w.print("\npilot       {s}\n", .{if (miss.female != 0) "female" else "male"});
    try w.writeAll("medals     ");
    try awarded(w, &miss.medals);
    try w.writeAll("ribbons    ");
    try awarded(w, &miss.ribbons);
    try w.print("pickups     {d}\n", .{miss.pickups});
    try w.print("loadout     ship {d}", .{miss.saved_ship});
    if (std.math.cast(usize, miss.saved_ship)) |ship| if (ship < loadout.tables.ships.len) try w.print(" ({s})", .{loadout.tables.ships[ship].model});
    try w.writeAll(", racks");
    var fitted = false;
    for (miss.saved_racks, 0..) |rack, place| {
        if (rack == -1) continue;
        fitted = true;
        try w.print(" {d}:", .{place});
        if (std.math.cast(u32, rack)) |id| if (loadout.tables.Missile.ofId(id)) |missile| {
            try w.writeAll(@tagName(missile));
            continue;
        };
        try w.print("{d}", .{rack});
    }
    if (!fitted) try w.writeAll(" empty");
    try w.writeByte('\n');

    try w.writeAll("missions    each with a rating, kills, a pickup or a promotion\n");
    for (0..save.missions) |index| {
        const rating = miss.ratings[index];
        if (rating == -1 and miss.mission_kills[index] == 0 and miss.mission_pickups[index] == 0 and miss.promotions[index] == 0) continue;
        try w.print("  {d:>2}        rating ", .{index + 1});
        if (rating == -1) try w.writeAll("none") else try w.print("{f}", .{@as(Outcome, @enumFromInt(rating))});
        try w.print(", kills {d}, pickups {d}, promotion {d}\n", .{ miss.mission_kills[index], miss.mission_pickups[index], miss.promotions[index] });
    }

    try w.writeAll("variables  ");
    for (save.kept_variables, read.vars[0..save.kept_variables.len]) |number, value| try w.print(" {d}={d}", .{ number, value });
    try w.writeAll("\nunwritten  ");
    for (read.vars[save.kept_variables.len..]) |value| try w.print(" {d}", .{value});
    try w.print("\nversion     {d}\n", .{read.version});
    try w.writeAll("wing       ");
    for (read.alph) |pilot| try w.print(" {d}", .{pilot});
    try w.print("\npool        pilot {d}, ", .{read.pilo.pilot});
    try layout.formatTag(save.Replacement.Status, read.pilo.status, w);
    try w.print("\nmp deaths   {d}\nkillboard   seed {d}\n", .{ miss.mp_deaths, miss.killboard_seed });
}

/// Writes which of `flags` are set, by number from 1.
fn awarded(w: *Io.Writer, flags: []const i32) Io.Writer.Error!void {
    var any = false;
    for (flags, 1..) |flag, number| if (flag != 0) {
        any = true;
        try w.print(" {d}", .{number});
    };
    if (!any) try w.writeAll(" none");
    try w.writeByte('\n');
}

fn list(ctx: Context, path: []const u8) !void {
    var folder = try Io.Dir.cwd().openDir(ctx.io, path, .{ .iterate = true });
    defer folder.close(ctx.io);
    var names: std.ArrayList([]const u8) = .empty;
    var entries = folder.iterate();
    while (try entries.next(ctx.io)) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, ".iff")) continue;
        try names.append(ctx.arena, try ctx.arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    for (names.items) |name| {
        const bytes = try folder.readFileAlloc(ctx.io, name, ctx.arena, .limited(openreliant.engine.files.max_file_size));
        const read = parse(bytes) orelse {
            try ctx.stdout.print("{s}: not a saved game\n", .{name});
            continue;
        };
        try ctx.stdout.print("{s}: {s}, mission {d}, {s}\n", .{ name, read.name.slice(), read.miss.mission, std.mem.sliceTo(&read.miss.call_sign, 0) });
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

test show {
    var read = save.empty();
    read.vars = @splat(1);
    read.name.set("Mission02");
    read.miss.mission = 2;
    @memcpy(read.miss.call_sign[0..2], "RA");
    read.miss.ratings = @splat(-1);
    read.miss.ratings[0] = @intFromEnum(Outcome.success);
    read.miss.mission_kills[0] = 12;
    read.miss.saved_racks = @splat(-1);
    read.miss.saved_racks[1] = 2;
    read.miss.medals[0] = 1;
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try show(&out.writer, &read);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "name        Mission02\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call sign   RA\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "medals      1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ship 0 (USLF_prd.SHP), racks 1:havoc\n") != null);
    // Mission 1 alone has a record.
    try std.testing.expect(std.mem.indexOf(u8, text, "   1        rating success, kills 12, pickups 0, promotion 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "   2        rating") == null);
}
