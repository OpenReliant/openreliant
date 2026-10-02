//! `openreliant missions`: lists the missions in a game folder (in its mods, as loose files in its
//! `missions` folder, and in `resource.hog`) and binds each one as starting a mission does, to show
//! that it loads. OpenReliant's mission 0 is included if the game has none. A custom mission, added
//! to `missions` or a mod, is checked the same way. Each is shown with what its file contains: its
//! counts, its format flags, the ship type and name of the player's record, and the name in
//! OpenReliant's section, if the file has one (`dte.OpenReliantName`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const version = @import("version");
const help = @import("help.zig");
const mission0 = @import("mission0.zig");
const engine = openreliant.engine;
const game = engine.game;
const files = engine.files;

pub const usage =
    \\usage: openreliant missions [<game-directory>] [--no-mods]
    \\  <game-directory>  the folder StarLancer is installed in; the current directory by default
    \\  --no-mods         only the game's missions, without the mods in its mods folder
    \\  -h, --help        show this page
    \\
    \\Lists the missions in the game's mods, its missions folder and resource.hog, plus OpenReliant's
    \\built-in mission 0 if the game has none, and binds each one as starting a mission does. A
    \\mod's file takes priority over the others, and a loose file over the archive's copy, as in the
    \\game. Each is shown with what its file contains: its counts, its format flags, the ship type
    \\and name of the player's record, and the mission's name if the file has OpenReliant's section.
    \\
;

/// Runs `openreliant missions` with the given arguments. Returns the exit code: 1 where a mission
/// fails to bind.
pub fn main(io: Io, gpa: Allocator, args: []const [:0]const u8) !u8 {
    var out_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .initStreaming(.stdout(), io, &out_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    if (help.asked(args)) {
        try out.writeAll(usage);
        return 0;
    }
    var directory_name: ?[]const u8 = null;
    var with_mods = true;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--no-mods")) {
            with_mods = false;
        } else if (std.mem.startsWith(u8, arg, "-") or directory_name != null) {
            std.debug.print("{s}", .{usage});
            return 2;
        } else directory_name = arg;
    }
    const directory_path = directory_name orelse ".";
    var directory = Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true }) catch |err| {
        std.debug.print("openreliant: {s} can't be opened: {s}\n", .{ directory_path, @errorName(err) });
        return 1;
    };
    defer directory.close(io);
    var hog_name: [files.max_path]u8 = undefined;
    const archive_name = files.find(io, directory, game.bigfile.resource_name, &hog_name) orelse {
        std.debug.print("openreliant: {s} has no {s}: is it the game's folder?\n", .{ directory_path, game.bigfile.resource_name });
        return 1;
    };
    var resources: game.bigfile.Hog = try .open(gpa, io, directory, archive_name);
    defer resources.close(gpa);
    var mods: game.bigfile.Mods = if (with_mods) try .open(gpa, io, directory, version.semantic) else .none;
    defer mods.close(gpa);
    resources.mods = &mods;

    const numbers = try listed(io, gpa, directory, resources);
    defer gpa.free(numbers);
    try out.writeAll("mission  file      ships  groups  triggers  script  formats  type  " ++ std.fmt.comptimePrint(player_field, .{"player"}) ++ "  name\n");
    var failed: usize = 0;
    // OpenReliant's own mission 0, where the game has none.
    const built_in = std.mem.indexOfScalar(u16, numbers, mission0.number) == null;
    if (built_in) {
        try out.print("{d:>7}  ", .{mission0.number});
        if (show(gpa, try gpa.dupe(u8, @embedFile("mission0.dte")), "built-in", out)) |_| {} else |err| {
            try out.print("fails to bind: {s}\n", .{@errorName(err)});
            failed += 1;
        }
    }
    for (numbers) |number| {
        var path_buffer: [game.winmain.mission_path_size]u8 = undefined;
        const path = game.winmain.missionPath(&path_buffer, number, false, false);
        try out.print("{d:>7}  ", .{number});
        if (check(io, gpa, directory, &resources, path, out)) |_| {} else |err| {
            try out.print("fails to bind: {s}\n", .{@errorName(err)});
            failed += 1;
        }
    }
    try out.print("{d} missions, {d} failing\n", .{ numbers.len + @intFromBool(built_in), failed });
    return if (failed == 0) 0 else 1;
}

/// Reads and binds the mission at `path`, and prints what it holds.
fn check(io: Io, gpa: Allocator, directory: Io.Dir, resources: *const game.bigfile.Hog, path: []const u8, out: *Io.Writer) !void {
    const file = try game.mission.bind.read(io, gpa, directory, resources, path) orelse return error.FileMissing;
    return show(gpa, file.image, @tagName(file.source), out);
}

/// Binds the mission `image`, made in `gpa`, which binding then owns, and prints what it holds,
/// with where the file came from.
fn show(gpa: Allocator, image: []u8, source: []const u8, out: *Io.Writer) !void {
    var mission: game.mission.Mission = try .bind(gpa, image);
    defer mission.deinit();
    try out.print("{s:<8}  {d:>5}  {d:>6}  {d:>8}  {d:>6}  0x{x:<5}  ", .{
        source,
        (try mission.ships()).len,
        (try mission.flightGroups()).len,
        (try mission.file.triggers()).len,
        (try mission.file.script()).len,
        mission.formats.byte(),
    });
    // The player's own record: its ship type and its name, as the file holds them.
    if (try mission.file.player()) |player| {
        try out.print("{d:>4}  " ++ player_field ++ "  ", .{ player.kind, mission.file.name(player.name) });
    } else {
        try out.print("{s:>4}  " ++ player_field ++ "  ", .{ "-", "-" });
    }
    // The name OpenReliant keeps in a mission of its own making, where the file has one.
    try out.print("{s}\n", .{mission.file.openReliantName() orelse "-"});
}

/// The columns the player's name takes: the longest the shipped missions give it, 21, and one more;
/// and the field it is printed in.
const player_width = 22;
const player_field = std.fmt.comptimePrint("{{s:<{d}}}", .{player_width});

/// The numbers of the missions in `directory`, in the mods, as loose files in its `missions`
/// folder or in `resources`, in order and without duplicates.
fn listed(io: Io, gpa: Allocator, directory: Io.Dir, resources: game.bigfile.Hog) ![]u16 {
    var numbers: std.ArrayList(u16) = .empty;
    errdefer numbers.deinit(gpa);
    for (resources.mods.list) |*mod| {
        var names = mod.names();
        while (names.next()) |name| {
            if (game.winmain.missionNumber(name)) |number| try numbers.append(gpa, number);
        }
    }
    for (resources.archive.entries) |entry| {
        if (game.winmain.missionNumber(entry.name)) |number| try numbers.append(gpa, number);
    }
    var folder_name: [files.max_path]u8 = undefined;
    if (files.find(io, directory, "missions", &folder_name)) |name| {
        var folder = try directory.openDir(io, name, .{ .iterate = true });
        defer folder.close(io);
        var entries = folder.iterate();
        while (try entries.next(io)) |entry| {
            if (game.winmain.missionNumber(entry.name)) |number| try numbers.append(gpa, number);
        }
    }
    std.mem.sort(u16, numbers.items, {}, std.sort.asc(u16));
    var kept: usize = 0;
    for (numbers.items) |number| {
        if (kept > 0 and numbers.items[kept - 1] == number) continue;
        numbers.items[kept] = number;
        kept += 1;
    }
    numbers.shrinkRetainingCapacity(kept);
    return numbers.toOwnedSlice(gpa);
}
