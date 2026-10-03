//! The mods' scripts' state kept with a saved game ([#498](https://github.com/OpenReliant/openreliant/issues/498)):
//! a file of its own beside the saved game's (`extension`), so that the saved game stays as the
//! original writes it. The same state goes with the campaign's restart point. The game is saved
//! between missions, so it holds what lasts a whole game: the storage's game sections, each global
//! and player script that runs with what its `on_save` returned, and their timers. Mission and
//! object scripts don't run then.
//!
//! The form, little-endian: `magic` and `version` as a `u16`; the game sections
//! (`Storage.encodeGame`); the count of scripts as a `u32`, and for each its mod's name, its
//! family as a byte, its file's name and what it saved; then the count of timers as a `u32`, and
//! for each its mod's name, its family, its name, the seconds left as an `f64`, and its data. Names
//! and data are values of `stored.zig`'s form.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.scripts);

const script = @import("script.zig");
const runtime = @import("runtime.zig");
const Context = runtime.Context;
const running = @import("running.zig");
const stored = @import("stored.zig");
const Value = stored.Value;
const storage_module = @import("storage.zig");
const Storage = storage_module.Storage;
const game_module = @import("game.zig");
const Game = game_module.Game;
const Presentation = @import("presentation.zig").Presentation;

/// The extension of the file beside each saved game (`save.companionName`).
pub const extension = ".scripts";

/// The most a file of scripts' state may take.
pub const max_size = 16 << 20;

/// What the file starts with, and the version of its form.
const magic = "ORSV";
const version: u16 = 1;

/// Where the scripts that are kept with a game run: one list of a side, and the family of its
/// scripts that's kept.
const Kept = struct {
    runner: *running.Runner,
    list: *running.List,
    family: script.Family,

    /// The global scripts of `game`, but the mission's, and the player scripts of `shown`.
    fn of(game: ?*Game, shown: ?*Presentation) [2]?Kept {
        return .{
            if (game) |held| .{ .runner = &held.runner, .list = held.global(), .family = .global } else null,
            if (shown) |held| .{ .runner = &held.runner, .list = held.lists.getPtr(.player), .family = .player } else null,
        };
    }
};

/// The scripts' state, written in the file's form, in `gpa`.
pub fn take(gpa: Allocator, game: ?*Game, shown: ?*Presentation, storage: ?*Storage) Allocator.Error![]u8 {
    var bytes: Io.Writer.Allocating = .init(gpa);
    errdefer bytes.deinit();
    write(&bytes.writer, gpa, game, shown, storage) catch return error.OutOfMemory;
    return bytes.toOwnedSlice();
}

fn write(w: *Io.Writer, gpa: Allocator, game: ?*Game, shown: ?*Presentation, storage: ?*Storage) Io.Writer.Error!void {
    try w.writeAll(magic);
    try w.writeInt(u16, version, .little);
    if (storage) |held| try held.encodeGame(w) else try w.writeInt(u32, 0, .little);

    const sides = Kept.of(game, shown);
    var saved: std.ArrayList(struct { context: *const Context, name: []const u8, value: Value }) = .empty;
    defer {
        for (saved.items) |entry| entry.value.deinit(gpa);
        saved.deinit(gpa);
    }
    for (sides) |maybe| {
        const side = maybe orelse continue;
        for (side.list.items) |held| {
            if (held.stopped or held.mission or held.context.family != side.family) continue;
            // Each script is kept, so that it gets `on_load` rather than `on_init`: with nil where
            // it has no `on_save`, or where that failed.
            const function = held.offered.handlers.get(.on_save);
            const value: Value = if (function) |saving| side.runner.runtime.callKeeping(held.context, saving, gpa) orelse .nil else .nil;
            saved.append(gpa, .{ .context = held.context, .name = held.name, .value = value }) catch {
                value.deinit(gpa);
                return error.WriteFailed;
            };
        }
    }
    try w.writeInt(u32, @intCast(saved.items.len), .little);
    for (saved.items) |entry| {
        try stored.encode(w, .{ .string = entry.context.modOf().name });
        try w.writeByte(@intFromEnum(entry.context.family));
        try stored.encode(w, .{ .string = entry.name });
        try stored.encode(w, entry.value);
    }

    var timers: u32 = 0;
    for (sides) |maybe| {
        const side = maybe orelse continue;
        for (side.runner.timers.items) |timer| timers += @intFromBool(keptTimer(side, timer));
    }
    try w.writeInt(u32, timers, .little);
    for (sides) |maybe| {
        const side = maybe orelse continue;
        for (side.runner.timers.items) |timer| {
            if (!keptTimer(side, timer)) continue;
            const data: Value = if (timer.data) |ref| side.runner.runtime.keep(timer.context, ref, gpa, "a timer's data") orelse .nil else .nil;
            defer data.deinit(gpa);
            try stored.encode(w, .{ .string = timer.context.modOf().name });
            try w.writeByte(@intFromEnum(timer.context.family));
            try stored.encode(w, .{ .string = timer.name.slice() });
            try w.writeInt(u64, @bitCast(timer.left), .little);
            try stored.encode(w, data);
        }
    }
}

/// Whether `timer` is kept with the game: its script's, a global script's but a mission's, or a
/// player script's.
fn keptTimer(side: Kept, timer: running.Timer) bool {
    if (timer.context.closed or timer.context.family != side.family) return false;
    return for (side.list.items) |held| {
        if (!held.stopped and !held.mission and held.context == timer.context) break true;
    } else false;
}

/// Puts back the scripts' state `bytes` hold, as a saved game's scripts start without their
/// `on_init` (`Game.start`'s `loading`): the game sections into `storage`, what each script saved
/// into its `on_load`, and the timers. The scripts the state doesn't hold, such as those of a mod
/// added since, get their `on_init` instead. A file of another version, or a damaged one, is
/// logged, and what's left of it goes unread.
pub fn restore(gpa: Allocator, bytes: []const u8, game: ?*Game, shown: ?*Presentation, storage: ?*Storage) Allocator.Error!void {
    const sides = Kept.of(game, shown);
    var loaded: [sides.len]std.DynamicBitSetUnmanaged = undefined;
    for (&loaded, sides, 0..) |*set, maybe, at| {
        errdefer for (loaded[0..at]) |*made| made.deinit(gpa);
        set.* = try .initEmpty(gpa, if (maybe) |side| side.list.items.len else 0);
    }
    defer for (&loaded) |*set| set.deinit(gpa);
    var r: Io.Reader = .fixed(bytes);
    read(&r, gpa, sides, &loaded, storage) catch |err| switch (err) {
        error.Damaged => log.warn("the scripts' state kept with the saved game is damaged, and left out", .{}),
        error.OutOfMemory => log.warn("out of memory putting back the scripts' state", .{}),
    };
    for (sides, &loaded) |maybe, *set| {
        const side = maybe orelse continue;
        for (0..set.bit_length) |at| {
            if (set.isSet(at)) continue;
            const held = side.list.items[at];
            if (held.stopped or held.mission or held.context.family != side.family) continue;
            side.runner.callOne(side.list, at, .on_init, .{ .data = null });
        }
    }
}

fn read(r: *Io.Reader, gpa: Allocator, sides: [2]?Kept, loaded: *[2]std.DynamicBitSetUnmanaged, storage: ?*Storage) stored.DecodeError!void {
    const start = r.take(magic.len) catch return error.Damaged;
    if (!std.mem.eql(u8, start, magic)) return error.Damaged;
    if ((r.takeInt(u16, .little) catch return error.Damaged) != version) return error.Damaged;
    if (storage) |held| try held.decodeGame(r) else {
        var ignored: Storage = .{ .gpa = gpa };
        defer ignored.deinit();
        try ignored.decodeGame(r);
    }

    const scripts = r.takeInt(u32, .little) catch return error.Damaged;
    for (0..scripts) |_| {
        const mod = try decodeString(r, gpa);
        defer gpa.free(mod);
        const family = try decodeFamily(r);
        const name = try decodeString(r, gpa);
        defer gpa.free(name);
        const value = try stored.decode(r, gpa);
        defer value.deinit(gpa);
        const which = sideOf(sides, family) orelse continue;
        const side = sides[which].?;
        for (side.list.items, 0..) |held, at| {
            if (held.stopped or held.mission or at >= loaded[which].bit_length) continue;
            if (!std.mem.eql(u8, held.context.modOf().name, mod) or !std.mem.eql(u8, held.name, name)) continue;
            const ref = side.runner.runtime.make(stored.push, .{value}) orelse return error.OutOfMemory;
            defer side.runner.runtime.release(ref);
            loaded[which].set(at);
            // `callOne` passes the reference without letting it go.
            side.runner.callOne(side.list, at, .on_load, .{ .saved = .{ .ref = ref } });
            break;
        }
    }

    const timers = r.takeInt(u32, .little) catch return error.Damaged;
    for (0..timers) |_| {
        const mod = try decodeString(r, gpa);
        defer gpa.free(mod);
        const family = try decodeFamily(r);
        const name = try decodeString(r, gpa);
        defer gpa.free(name);
        const left: f64 = @bitCast(r.takeInt(u64, .little) catch return error.Damaged);
        const value = try stored.decode(r, gpa);
        defer value.deinit(gpa);
        const side = sides[sideOf(sides, family) orelse continue].?;
        const context = for (side.list.items) |held| {
            if (!held.stopped and !held.mission and std.mem.eql(u8, held.context.modOf().name, mod)) break held.context;
        } else continue;
        const timer_name = runtime.Name.of(name) orelse return error.Damaged;
        const ref = side.runner.runtime.make(stored.push, .{value}) orelse return error.OutOfMemory;
        side.runner.addTimer(.{ .context = context, .name = timer_name, .left = left, .data = ref }) catch {
            side.runner.runtime.release(ref);
            return error.OutOfMemory;
        };
    }
}

/// Which of `sides` keeps the scripts of `family`.
fn sideOf(sides: [2]?Kept, family: script.Family) ?usize {
    for (sides, 0..) |maybe, at| {
        const side = maybe orelse continue;
        if (side.family == family) return at;
    }
    return null;
}

fn decodeString(r: *Io.Reader, gpa: Allocator) stored.DecodeError![]u8 {
    const value = try stored.decode(r, gpa);
    return switch (value) {
        .string => |bytes| @constCast(bytes),
        else => {
            value.deinit(gpa);
            return error.Damaged;
        },
    };
}

fn decodeFamily(r: *Io.Reader) stored.DecodeError!script.Family {
    const byte = r.takeByte() catch return error.Damaged;
    return std.enums.fromInt(script.Family, byte) orelse error.Damaged;
}

test "a script's state, its timers and its game sections go with a saved game and come back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const load = @import("load.zig");
    const mods = @import("openreliant").engine.game.bigfile.mods;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try load.testing.makeMods(io, tmp.dir, &.{.{
        "a",
        &.{
            .{ "mod.ini", "[Scripts]\nGlobal=tally.luau\n" },
            .{
                "tally.luau",
                \\local async = require("openreliant.async")
                \\local tally = require("openreliant.storage").game_section("tally")
                \\local count = 0
                \\async.register_timer("Tick", function(data)
                \\    count += data.step
                \\    tally.ticks = (tally.ticks or 0) + 1
                \\end)
                \\return { engine_handlers = {
                \\    on_init = function() count = 1; async.after(2, "Tick", { step = 10 }) end,
                \\    on_save = function() return { count = count } end,
                \\    on_load = function(saved) count = saved.count + 100 end,
                \\    on_update = function() tally.count = count end,
                \\} }
            },
        },
    }});
    var opened: mods.Mods = try .open(gpa, io, tmp.dir, null);
    defer opened.close(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var held = try load.testing.records3(arena.allocator());
    var mission: @import("openreliant").engine.game.gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    _ = try mission.add(.predator, @splat(0));
    var storage: Storage = .{ .gpa = gpa };
    defer storage.deinit();

    // A game runs a second, and is saved.
    const first = (try Game.start(gpa, io, opened.list, &held, "0.7.0", mission.objects, .{ .storage = &storage }, false)).?;
    first.scripts.update(1);
    try std.testing.expectEqual(1, storage.read("a", "tally", .game, "count").?.number);
    const bytes = try take(gpa, first, null, &storage);
    defer gpa.free(bytes);
    first.stop();
    storage.clearGame();

    // Loaded, the script gets its state back without on_init, and its timer goes on from where
    // it was: a second later it runs, once.
    const second = (try Game.start(gpa, io, opened.list, &held, "0.7.0", mission.objects, .{ .storage = &storage }, true)).?;
    defer second.stop();
    try restore(gpa, bytes, second, null, &storage);
    try std.testing.expectEqual(1, storage.read("a", "tally", .game, "count").?.number);
    second.scripts.update(0.5);
    try std.testing.expectEqual(101, storage.read("a", "tally", .game, "count").?.number);
    try std.testing.expectEqual(null, storage.read("a", "tally", .game, "ticks"));
    second.scripts.update(0.75);
    try std.testing.expectEqual(111, storage.read("a", "tally", .game, "count").?.number);
    try std.testing.expectEqual(1, storage.read("a", "tally", .game, "ticks").?.number);
    second.scripts.update(5);
    try std.testing.expectEqual(1, storage.read("a", "tally", .game, "ticks").?.number);

    // A damaged file is left out, and the script starts with on_init.
    const third = (try Game.start(gpa, io, opened.list, &held, "0.7.0", mission.objects, .{ .storage = &storage }, true)).?;
    defer third.stop();
    storage.clearGame();
    try restore(gpa, "ORSV", third, null, &storage);
    third.scripts.update(0.1);
    try std.testing.expectEqual(1, storage.read("a", "tally", .game, "count").?.number);
}
