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

/// The most a file of scripts' state may take, as loading reads it (`GameScripts.loaded`): far more
/// than mods keep, with room for several at their limits for storage and `on_save` at once, while a
/// damaged file can't make loading take any amount of memory. `take` keeps within it.
pub const max_size = 256 << 20;

/// What the file starts with, and the version of its form.
const magic = "ORSV";
const version: u16 = 1;

/// What a file holds besides the mods' state: its magic, its version, and the counts of game
/// sections, scripts and timers.
const overhead = magic.len + @sizeOf(u16) + 3 * @sizeOf(u32);

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

/// The scripts' state, written in the file's form, in `gpa`. Where it would take more than
/// `max_size`, the mods that keep the most are left out until the rest fits, which the log says.
/// When the game is loaded, their scripts get `on_init`, like those of a mod added since.
pub fn take(gpa: Allocator, game: ?*Game, shown: ?*Presentation, storage: ?*Storage) Allocator.Error![]u8 {
    return takeWithin(gpa, game, shown, storage, max_size);
}

/// `take`, with the file kept within `limit`.
fn takeWithin(gpa: Allocator, game: ?*Game, shown: ?*Presentation, storage: ?*Storage, limit: usize) Allocator.Error![]u8 {
    std.debug.assert(limit >= overhead);
    var gathered: Gathered = .{};
    defer gathered.deinit(gpa);
    try gathered.gather(gpa, Kept.of(game, shown));
    var left_out = try gathered.fit(gpa, storage, limit);
    defer left_out.deinit(gpa);
    var bytes: Io.Writer.Allocating = .init(gpa);
    errdefer bytes.deinit();
    gathered.write(&bytes.writer, storage, &left_out) catch return error.OutOfMemory;
    return bytes.toOwnedSlice();
}

/// The mods whose state is left out of a file, by name.
const LeftOut = std.array_hash_map.String(void);

/// The bytes each mod's state takes in a file, by the mod's name.
const Shares = std.array_hash_map.String(usize);

/// What the scripts keep with a game, gathered before it's written, so that each mod's share of the
/// file can be measured first.
const Gathered = struct {
    scripts: std.ArrayList(Saved) = .empty,
    timers: std.ArrayList(Timer) = .empty,

    /// A script, and what its `on_save` returned.
    const Saved = struct {
        mod: []const u8,
        family: script.Family,
        name: []const u8,
        value: Value,

        fn encode(w: *Io.Writer, saved: *const Saved) Io.Writer.Error!void {
            try stored.encode(w, .{ .string = saved.mod });
            try w.writeByte(@backingInt(saved.family));
            try stored.encode(w, .{ .string = saved.name });
            try stored.encode(w, saved.value);
        }
    };

    /// A timer, and its data.
    const Timer = struct {
        mod: []const u8,
        family: script.Family,
        name: runtime.Name,
        left: f64,
        data: Value,

        fn encode(w: *Io.Writer, timer: *const Timer) Io.Writer.Error!void {
            try stored.encode(w, .{ .string = timer.mod });
            try w.writeByte(@backingInt(timer.family));
            try stored.encode(w, .{ .string = timer.name.slice() });
            try w.writeInt(u64, @bitCast(timer.left), .little);
            try stored.encode(w, timer.data);
        }
    };

    fn deinit(gathered: *Gathered, gpa: Allocator) void {
        for (gathered.scripts.items) |saved| saved.value.deinit(gpa);
        gathered.scripts.deinit(gpa);
        for (gathered.timers.items) |timer| timer.data.deinit(gpa);
        gathered.timers.deinit(gpa);
    }

    /// Asks each script kept with the game for its state (`on_save`), then copies their timers'
    /// data.
    fn gather(gathered: *Gathered, gpa: Allocator, sides: [2]?Kept) Allocator.Error!void {
        for (sides) |maybe| {
            const side = maybe orelse continue;
            for (side.list.items) |held| {
                if (held.stopped or held.mission or held.context.family != side.family) continue;
                // Each script is kept, so that it gets `on_load` rather than `on_init`: with nil
                // where it has no `on_save`, or where that failed.
                const function = held.offered.handlers.get(.on_save);
                const value: Value = if (function) |saving| side.runner.runtime.callKeeping(held.context, saving, gpa) orelse .nil else .nil;
                errdefer value.deinit(gpa);
                try gathered.scripts.append(gpa, .{ .mod = held.context.modOf().name, .family = held.context.family, .name = held.name, .value = value });
            }
        }
        for (sides) |maybe| {
            const side = maybe orelse continue;
            for (side.runner.timers.items) |timer| {
                if (!keptTimer(side, timer)) continue;
                const data: Value = if (timer.data) |ref| side.runner.runtime.keep(timer.context, ref, gpa, "a timer's data") orelse .nil else .nil;
                errdefer data.deinit(gpa);
                try gathered.timers.append(gpa, .{ .mod = timer.context.modOf().name, .family = timer.context.family, .name = timer.name, .left = timer.left, .data = data });
            }
        }
    }

    /// The mods to leave out so that the file fits in `limit`: the one whose share of it is the
    /// largest, then the next, until the rest fits. Each is logged.
    fn fit(gathered: *const Gathered, gpa: Allocator, storage: ?*const Storage, limit: usize) Allocator.Error!LeftOut {
        var shares: Shares = .empty;
        defer shares.deinit(gpa);
        if (storage) |held| try held.measureGame(gpa, &shares);
        try measureEach(Saved, gpa, &shares, gathered.scripts.items);
        try measureEach(Timer, gpa, &shares, gathered.timers.items);
        var size: usize = overhead;
        for (shares.values()) |share| size += share;
        var left_out: LeftOut = .empty;
        errdefer left_out.deinit(gpa);
        // Past `limit`, which holds the overhead, some mod still has a share.
        while (size > limit) {
            const largest = std.mem.findMax(usize, shares.values());
            const mod = shares.keys()[largest];
            try left_out.put(gpa, mod, {});
            size -= shares.values()[largest];
            shares.values()[largest] = 0;
            log.warn("{s}'s scripts' state is left out, as all the mods' state together would take more than {Bi}", .{ mod, limit });
        }
        return left_out;
    }

    /// Adds the bytes each of `entries` takes to its mod's share in `shares`.
    fn measureEach(comptime Entry: type, gpa: Allocator, shares: *Shares, entries: []const Entry) Allocator.Error!void {
        for (entries) |*entry| {
            const share = try shares.getOrPutValue(gpa, entry.mod, 0);
            share.value_ptr.* += stored.encodedSize(Entry.encode, .{entry});
        }
    }

    /// Writes the file, without the state of the mods in `left_out`.
    fn write(gathered: *const Gathered, w: *Io.Writer, storage: ?*const Storage, left_out: *const LeftOut) Io.Writer.Error!void {
        try w.writeAll(magic);
        try w.writeInt(u16, version, .little);
        if (storage) |held| try held.encodeGame(w, left_out) else try w.writeInt(u32, 0, .little);
        try writeEach(Saved, w, gathered.scripts.items, left_out);
        try writeEach(Timer, w, gathered.timers.items, left_out);
    }

    /// Writes how many of `entries` aren't those of the mods in `left_out`, then each of them.
    fn writeEach(comptime Entry: type, w: *Io.Writer, entries: []const Entry, left_out: *const LeftOut) Io.Writer.Error!void {
        var count: u32 = 0;
        for (entries) |entry| count += @intFromBool(!left_out.contains(entry.mod));
        try w.writeInt(u32, count, .little);
        for (entries) |*entry| if (!left_out.contains(entry.mod)) try Entry.encode(w, entry);
    }
};

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
    var loaded: [sides.len]std.bit_set.Dynamic = undefined;
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

fn read(r: *Io.Reader, gpa: Allocator, sides: [2]?Kept, loaded: *[2]std.bit_set.Dynamic, storage: ?*Storage) stored.DecodeError!void {
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
    _ = try mission.add(.of(.predator), @splat(0));
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

test "the mods that keep the most are left out of a state that would pass its limit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const load = @import("load.zig");
    const mods = @import("openreliant").engine.game.bigfile.mods;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // Three mods, each with a game section and a script that saves a string, b's the longest.
    const ini = "[Scripts]\nGlobal=kept.luau\n";
    const saving = struct {
        fn of(comptime length: u32) []const u8 {
            return std.fmt.comptimePrint(
                \\local kept = require("openreliant.storage").game_section("kept")
                \\return {{ engine_handlers = {{
                \\    on_init = function() kept.started = "init" end,
                \\    on_save = function() kept.saved = true; return string.rep("x", {d}) end,
                \\    on_load = function(saved) kept.started = "load " .. #saved end,
                \\}} }}
            , .{length});
        }
    }.of;
    try load.testing.makeMods(io, tmp.dir, &.{
        .{ "a", &.{ .{ "mod.ini", ini }, .{ "kept.luau", saving(100) } } },
        .{ "b", &.{ .{ "mod.ini", ini }, .{ "kept.luau", saving(4000) } } },
        .{ "c", &.{ .{ "mod.ini", ini }, .{ "kept.luau", saving(100) } } },
    });
    var opened: mods.Mods = try .open(gpa, io, tmp.dir, null);
    defer opened.close(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var held = try load.testing.records3(arena.allocator());
    var mission: @import("openreliant").engine.game.gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    _ = try mission.add(.of(.predator), @splat(0));
    var storage: Storage = .{ .gpa = gpa };
    defer storage.deinit();

    // With room for every mod's state, the file holds it all. With 1000 bytes less, b is left out,
    // and the rest fits.
    const first = (try Game.start(gpa, io, opened.list, &held, "0.7.0", mission.objects, .{ .storage = &storage }, false)).?;
    const whole = try take(gpa, first, null, &storage);
    defer gpa.free(whole);
    const limit = whole.len - 1000;
    const fitted = try takeWithin(gpa, first, null, &storage, limit);
    defer gpa.free(fitted);
    try std.testing.expect(fitted.len <= limit);
    first.stop();

    // Loaded, a and c get their state back, while b starts as a new mod: on_init, and its game
    // section empty.
    const second = (try Game.start(gpa, io, opened.list, &held, "0.7.0", mission.objects, .{ .storage = &storage }, true)).?;
    defer second.stop();
    try restore(gpa, fitted, second, null, &storage);
    for ([_][]const u8{ "a", "c" }) |kept| {
        try std.testing.expectEqualStrings("load 100", storage.read(kept, "kept", .game, "started").?.string);
        try std.testing.expect(storage.read(kept, "kept", .game, "saved").?.boolean);
    }
    try std.testing.expectEqualStrings("init", storage.read("b", "kept", .game, "started").?.string);
    try std.testing.expectEqual(null, storage.read("b", "kept", .game, "saved"));
}
