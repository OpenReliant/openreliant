//! The scripting console ([#557](https://github.com/OpenReliant/openreliant/issues/557)): a screen
//! that F11 brings up over the menus and the paused mission while a mod has scripts. It shows what
//! the scripts write to the log, and runs the lines typed into it: its own commands (`Command`),
//! Luau in the context of a mod's scripts (`Mode`), or, for any other line, the player and menu
//! scripts' `on_console_command`. The screen is laid out and drawn as the front end's are
//! ([`console/screen.zig`](console/screen.zig)).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const openreliant = @import("openreliant");
const engine = openreliant.engine;
const input = engine.input;
const language = engine.game.language;
const pilot_roster = engine.game.interface.pilot_roster;
const Mod = engine.game.bigfile.mods.Mod;
const script = @import("script.zig");
const runtime_module = @import("runtime.zig");
const Context = runtime_module.Context;
const running = @import("running.zig");
const Game = @import("game.zig").Game;
const Presentation = @import("presentation.zig").Presentation;
const reference = @import("reference.zig");

pub const screen = @import("console/screen.zig");

test {
    _ = screen;
}

/// The key that brings the console up and takes it away.
pub const key: input.Key = .f11;

/// Whether the console is there: where a mod has scripts.
pub fn available(opened: []const Mod) bool {
    for (opened) |*mod| {
        var names = mod.scripts();
        if (names.next() != null) return true;
    }
    return false;
}

/// How a line of the output is drawn.
pub const Tone = enum {
    /// What the scripts print, and the console's answers.
    info,
    warning,
    failure,
    /// A line typed into the console, as it runs.
    typed,
};

/// The most lines the output keeps, and the most bytes of each, UTF-8; a longer line is cut.
pub const max_lines = 512;
pub const max_line = 256;

/// The spaces a tab is written as.
const tab_spaces = 4;

/// A line of the output.
pub const Line = struct {
    tone: Tone,
    len: u16,
    bytes: [max_line]u8,

    pub fn text(line: *const Line) []const u8 {
        return line.bytes[0..line.len];
    }
};

/// What the console shows: the latest `max_lines` lines written to it, the oldest first. The log
/// writes to it from any thread, so it's locked while it changes and while it's read.
pub const Output = struct {
    lines: [max_lines]Line = undefined,
    /// Where the oldest line is, and how many there are.
    first: usize = 0,
    count: usize = 0,
    lock: std.atomic.Mutex = .unlocked,

    /// Adds `text` in `tone`, a line for each of its lines.
    pub fn add(kept: *Output, tone: Tone, text: []const u8) void {
        kept.acquire();
        defer kept.lock.unlock();
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| kept.addLine(tone, std.mem.trimEnd(u8, line, "\r"));
    }

    fn addLine(kept: *Output, tone: Tone, text: []const u8) void {
        const at = (kept.first + kept.count) % max_lines;
        if (kept.count == max_lines) kept.first = (kept.first + 1) % max_lines else kept.count += 1;
        const line = &kept.lines[at];
        line.tone = tone;
        var len: usize = 0;
        for (text) |byte| {
            const spaces: usize = if (byte == '\t') tab_spaces else 1;
            if (len + spaces > max_line) break;
            @memset(line.bytes[len..][0..spaces], if (byte == '\t') ' ' else byte);
            len += spaces;
        }
        line.len = @intCast(len);
    }

    /// Waits for the lock, which `lock.unlock` lets go.
    pub fn acquire(kept: *Output) void {
        while (!kept.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// The line `index` from the oldest, while the lock is held.
    pub fn lineAt(kept: *const Output, index: usize) *const Line {
        return &kept.lines[(kept.first + index) % max_lines];
    }

    pub fn clear(kept: *Output) void {
        kept.acquire();
        defer kept.lock.unlock();
        kept.count = 0;
    }
};

/// The console's output, which the log writes to (`log`).
pub var output: Output = .{};

/// Writes a message of the log to the console's output, as the driver's log function passes on the
/// scripts' messages: errors and warnings in their tones.
pub fn log(comptime level: std.log.Level, comptime format: []const u8, args: anytype) void {
    var buffer: [max_line * max_message_lines]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    w.print(format, args) catch {};
    output.add(switch (level) {
        .err => .failure,
        .warn => .warning,
        .info, .debug => .info,
    }, std.mem.trimEnd(u8, w.buffered(), "\n"));
}

/// The most lines of a message the log writes to the output, such as an error's traceback.
const max_message_lines = 16;

/// What a line typed into the console runs as.
pub const Mode = union(enum) {
    /// The console's commands.
    commands,
    /// Luau, in the context of a mod's scripts (`Command.global`, `player` and `menu`).
    luau: Target,
};

/// The scripts of a mod of a family, whose context the console runs Luau in.
pub const Target = struct {
    mod: u16,
    family: script.Family,
};

/// The console's commands.
pub const Command = enum {
    help,
    mods,
    reload,
    clear,
    global,
    player,
    menu,
    exit,

    /// What `help` says of it.
    pub fn about(command: Command) []const u8 {
        return switch (command) {
            .help => "help [name]: the commands, or what a package, an engine handler or a hook is",
            .mods => "mods: the mods, and their scripts that run",
            .reload => "reload: reads the folder mods' scripts again, and starts them from where they were",
            .clear => "clear: empties the console",
            .global => "global <mod>: runs Luau in the context of the mod's global scripts",
            .player => "player <mod>: runs Luau in the context of the mod's player scripts",
            .menu => "menu <mod>: runs Luau in the context of the mod's menu scripts",
            .exit => "exit: goes back to the commands from Luau",
        };
    }

    /// The family whose context it runs Luau in, for `global`, `player` and `menu`.
    fn family(command: Command) ?script.Family {
        return switch (command) {
            .global => .global,
            .player => .player,
            .menu => .menu,
            .help, .mods, .reload, .clear, .exit => null,
        };
    }
};

/// What the driver does for a line the console ran.
pub const Request = enum {
    /// Reads the folder mods' scripts again, and starts them from where they were.
    reload,
};

/// The scripts a line can reach.
pub const Scripts = struct {
    game: ?*Game = null,
    presentation: ?*Presentation = null,
};

/// The most bytes of a line typed, in the game's code page.
pub const max_typed = 200;

/// The most bytes UTF-8 takes for a character, which a line typed takes as it runs.
const max_utf8 = 4;

/// A line typed, in the game's code page, as the front end keeps one (`pilot_roster.Text`).
pub const Typed = pilot_roster.Text(max_typed);

/// The lines typed, the latest last, which Up and Down bring back.
pub const History = struct {
    lines: [max_history]Typed = undefined,
    /// Where the oldest is, and how many there are.
    first: usize = 0,
    count: usize = 0,

    pub const max_history = 32;

    fn add(history: *History, typed: []const u8) void {
        if (history.count > 0 and std.mem.eql(u8, history.typedAt(history.count - 1).slice(), typed)) return;
        const at = (history.first + history.count) % max_history;
        if (history.count == max_history) history.first = (history.first + 1) % max_history else history.count += 1;
        history.lines[at].set(typed);
    }

    /// The line `index` from the oldest.
    pub fn typedAt(history: *const History, index: usize) *const Typed {
        return &history.lines[(history.first + index) % max_history];
    }
};

/// The console: whether it's up, the line being typed, what was typed before, and what lines run
/// as.
pub const Console = struct {
    gpa: Allocator,
    /// The mods, whose scripts it reaches.
    mods: []const Mod,
    open: bool = false,
    /// Whether it has come up before, the first time with a line saying what to type.
    shown_before: bool = false,
    typed: Typed = .{},
    history: History = .{},
    /// The line of the history Up and Down have brought back; null for a new one.
    recalled: ?usize = null,
    mode: Mode = .commands,
    /// What the screen keeps from one pass to the next.
    view: screen.View = .{},

    /// Brings the console up, the pointer's button counting once the press that's down now comes
    /// up; the first time, with a line saying how to start.
    pub fn show(console: *Console) void {
        console.open = true;
        console.view.press = .{};
        if (console.shown_before) return;
        console.shown_before = true;
        console.say(.info, "OpenReliant's script console: help lists the commands", .{});
    }

    /// Brings Up's line of the history back, or Down's: the one before or after the line brought
    /// back, and after the latest, an empty line.
    pub fn recall(console: *Console, way: enum { back, on }) void {
        const count = console.history.count;
        if (count == 0) return;
        console.recalled = switch (way) {
            .back => if (console.recalled) |at| at -| 1 else count - 1,
            .on => if (console.recalled) |at| if (at + 1 < count) at + 1 else null else null,
        };
        if (console.recalled) |at| console.typed.set(console.history.typedAt(at).slice()) else console.typed.len = 0;
    }

    /// The prompt before the line typed: `>` for the commands, and the mod and the family whose
    /// context Luau runs in.
    pub fn prompt(console: *const Console, buffer: []u8) []const u8 {
        return switch (console.mode) {
            .commands => ">",
            .luau => |target| std.fmt.bufPrint(buffer, "{s} {t}>", .{ console.mods[target.mod].name, target.family }) catch ">",
        };
    }

    /// Runs the line typed, and empties it: a command, Luau, or a line for the scripts.
    pub fn run(console: *Console, scripts: Scripts) Allocator.Error!?Request {
        const typed = console.typed.slice();
        var utf8_buffer: [max_typed * max_utf8]u8 = undefined;
        const utf8 = toUtf8(&utf8_buffer, typed);
        if (typed.len > 0) console.history.add(typed);
        console.typed.len = 0;
        console.recalled = null;
        console.view.back = 0;
        var prompt_buffer: [prompt_room]u8 = undefined;
        console.say(.typed, "{s} {s}", .{ console.prompt(&prompt_buffer), utf8 });
        const line = std.mem.trim(u8, utf8, " ");
        if (line.len == 0) return null;
        switch (console.mode) {
            .commands => return console.command(line, scripts),
            .luau => |target| {
                if (std.mem.eql(u8, line, "exit") or std.mem.eql(u8, line, "exit()")) {
                    console.mode = .commands;
                    return null;
                }
                try console.luau(target, line, scripts);
                return null;
            },
        }
    }

    fn command(console: *Console, line: []const u8, scripts: Scripts) Allocator.Error!?Request {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const first = words.next().?;
        const rest = std.mem.trim(u8, words.rest(), " ");
        const named = std.meta.stringToEnum(Command, first) orelse {
            if (scripts.presentation) |shown| if (shown.runner.offers(.on_console_command)) {
                shown.runner.callAll(.on_console_command, .{ .text = line });
                return null;
            };
            console.say(.warning, "there's no command {s}: help lists them", .{first});
            return null;
        };
        switch (named) {
            .help => try console.help(rest),
            .mods => try console.listMods(scripts),
            .reload => return .reload,
            .clear => output.clear(),
            .global, .player, .menu => if (rest.len == 0) {
                console.say(.warning, "{t} takes a mod's name: {s}", .{ named, named.about() });
            } else if (console.modNamed(rest)) |mod| {
                console.enter(.{ .mod = mod, .family = named.family().? }, scripts);
            } else console.say(.warning, "there's no mod {s}: mods lists them", .{rest}),
            .exit => console.say(.info, "exit leaves Luau, from global, player or menu", .{}),
        }
        return null;
    }

    fn help(console: *Console, name: []const u8) Allocator.Error!void {
        var text: Io.Writer.Allocating = .init(console.gpa);
        defer text.deinit();
        const found = writeHelp(&text.writer, name) catch return error.OutOfMemory;
        if (!found) return console.say(.warning, "there's no command, package, engine handler or hook named {s}", .{name});
        output.add(.info, std.mem.trimEnd(u8, text.written(), "\n"));
    }

    /// Writes what `help` says of `name`: the commands where it's empty, a command, or what the
    /// reference says of it. Returns false where nothing has that name.
    fn writeHelp(w: *Io.Writer, name: []const u8) Io.Writer.Error!bool {
        if (name.len == 0) {
            for (std.enums.values(Command)) |each| try w.print("{s}\n", .{each.about()});
            try w.writeAll("Any other line goes to the player and menu scripts' on_console_command.");
            return true;
        }
        if (std.meta.stringToEnum(Command, name)) |named| {
            try w.writeAll(named.about());
            return true;
        }
        return reference.writeHelp(w, name);
    }

    /// Lists each mod, and its scripts that run, by family, with how many run where several do.
    fn listMods(console: *Console, scripts: Scripts) Allocator.Error!void {
        var text: Io.Writer.Allocating = .init(console.gpa);
        defer text.deinit();
        console.writeMods(&text.writer, scripts) catch return error.OutOfMemory;
        output.add(.info, std.mem.trimEnd(u8, text.written(), "\n"));
    }

    fn writeMods(console: *Console, w: *Io.Writer, scripts: Scripts) (Allocator.Error || Io.Writer.Error)!void {
        var found: std.ArrayList(Found) = .empty;
        defer found.deinit(console.gpa);
        for (console.mods, 0..) |*mod, at| {
            found.clearRetainingCapacity();
            for ([_]?*running.Runner{ if (scripts.game) |held| &held.runner else null, if (scripts.presentation) |held| &held.runner else null }) |maybe| {
                const runner = maybe orelse continue;
                for (runner.lists) |list| for (list.items) |held| {
                    if (held.stopped or held.context.mod != at) continue;
                    const kind: Found.Kind = if (held.mission) .mission else .{ .family = held.context.family };
                    for (found.items) |*seen| {
                        if (std.meta.eql(seen.kind, kind) and std.mem.eql(u8, seen.name, held.name)) {
                            seen.count += 1;
                            break;
                        }
                    } else try found.append(console.gpa, .{ .kind = kind, .name = held.name });
                };
            }
            try w.print("{s}:", .{mod.name});
            if (found.items.len == 0) try w.writeAll(" no scripts run");
            for (found.items, 0..) |seen, place| {
                try w.print("{s} {f} {s}", .{ if (place == 0) "" else ",", seen.kind, seen.name });
                if (seen.count > 1) try w.print(" ({d})", .{seen.count});
            }
            try w.writeByte('\n');
        }
        if (console.mods.len == 0) try w.writeAll("no mods");
    }

    /// A script that runs, as `mods` counts them.
    const Found = struct {
        kind: Kind,
        name: []const u8,
        count: usize = 1,

        const Kind = union(enum) {
            family: script.Family,
            mission,

            pub fn format(kind: Kind, writer: *Io.Writer) Io.Writer.Error!void {
                return switch (kind) {
                    .family => |family| writer.print("{t}", .{family}),
                    .mission => writer.writeAll("mission"),
                };
            }
        };
    };

    /// The mod named `name`, in any case, with or without its archive's extension.
    fn modNamed(console: *const Console, name: []const u8) ?u16 {
        for (console.mods, 0..) |mod, at| {
            const stem = if (std.ascii.endsWithIgnoreCase(mod.name, archive_extension)) mod.name[0 .. mod.name.len - archive_extension.len] else mod.name;
            if (std.ascii.eqlIgnoreCase(mod.name, name) or std.ascii.eqlIgnoreCase(stem, name)) return @intCast(at);
        }
        return null;
    }

    /// Runs Luau in `target`'s context from now on, where its scripts run.
    fn enter(console: *Console, target: Target, scripts: Scripts) void {
        if (contextOf(target, scripts) == null) return console.notRunning(target);
        console.mode = .{ .luau = target };
        console.say(.info, "Luau runs in the context of the {t} scripts of {s}; exit goes back to the commands", .{ target.family, console.mods[target.mod].name });
    }

    /// Says that `target`'s scripts don't run, so Luau can't run in their context.
    fn notRunning(console: *const Console, target: Target) void {
        console.say(.warning, "no {t} scripts of {s} run now", .{ target.family, console.mods[target.mod].name });
    }

    fn luau(console: *Console, target: Target, line: []const u8, scripts: Scripts) Allocator.Error!void {
        const context = contextOf(target, scripts) orelse return console.notRunning(target);
        var result: Io.Writer.Allocating = .init(console.gpa);
        defer result.deinit();
        if (try context.runtime.evaluate(context, line, &result.writer) and result.written().len > 0) output.add(.info, result.written());
    }

    /// Writes a line of the console's own to the output.
    fn say(_: *const Console, tone: Tone, comptime format: []const u8, args: anytype) void {
        var buffer: [max_line]u8 = undefined;
        var w: Io.Writer = .fixed(&buffer);
        w.print(format, args) catch {};
        output.add(tone, w.buffered());
    }
};

/// Watches the folder mods' scripts and shaders, so that the scripts reload when either is saved.
/// A player script registers its post effects again as it starts, which compiles a changed shader.
pub const Watch = struct {
    /// When the newest of them last changed, as last seen; null before the first look.
    newest: ?i96 = null,
    /// When it next looks, in nanoseconds of the window's clock.
    next_at: u64 = 0,

    /// How often it looks.
    pub const interval = std.time.ns_per_s;

    /// Whether a folder mod's script or shader has changed since the last look, at `now`. It
    /// looks at most every `interval`. The first look only notes what is there.
    pub fn changed(watch: *Watch, io: Io, opened: []const Mod, now: u64) bool {
        if (now < watch.next_at) return false;
        watch.next_at = now + interval;
        var newest: i96 = std.math.minInt(i96);
        for (opened) |*mod| {
            const folder = switch (mod.source) {
                .folder => |*folder| folder,
                .archive => continue,
            };
            for ([_]Mod.Names{ mod.scripts(), mod.shaders() }) |listed| {
                var names = listed;
                while (names.next()) |name| {
                    const stat = folder.dir.statFile(io, name, .{}) catch continue;
                    newest = @max(newest, stat.mtime.nanoseconds);
                }
            }
        }
        defer watch.newest = newest;
        const seen = watch.newest orelse return false;
        return newest > seen;
    }
};

/// The room a prompt takes: a mod's name, a family and the mark after them.
pub const prompt_room = 96;

/// The extension of a mod's archive, which `global`, `player` and `menu` take its name with or
/// without.
const archive_extension = ".hog";

/// The context of `target`'s scripts, where they run.
fn contextOf(target: Target, scripts: Scripts) ?*Context {
    const runtime = switch (target.family) {
        .global, .object, .load => (scripts.game orelse return null).runtime,
        .player, .menu => (scripts.presentation orelse return null).runtime,
    };
    for (runtime.contexts.items) |context| {
        if (!context.closed and context.mod == target.mod and context.family == target.family and context.object == null) return context;
    }
    return null;
}

/// `typed`, in the game's code page, as UTF-8 in `buffer`.
fn toUtf8(buffer: *[max_typed * max_utf8]u8, typed: []const u8) []const u8 {
    var len: usize = 0;
    for (typed) |byte| len += std.unicode.utf8Encode(language.toUnicode(byte), buffer[len..]) catch continue;
    return buffer[0..len];
}

test Output {
    var lines: Output = .{};
    lines.add(.info, "one\ntwo\tthree");
    try std.testing.expectEqual(2, lines.count);
    try std.testing.expectEqualStrings("two    three", lines.lineAt(1).text());
    for (0..max_lines) |_| lines.add(.warning, "more");
    try std.testing.expectEqual(max_lines, lines.count);
    try std.testing.expectEqual(Tone.warning, lines.lineAt(0).tone);
    // A line too long is cut.
    lines.add(.info, &(@as([max_line + 10]u8, @splat('x'))));
    try std.testing.expectEqual(max_line, lines.lineAt(max_lines - 1).text().len);
}

test Watch {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const load = @import("load.zig");
    try load.testing.makeMods(io, tmp.dir, &.{.{ "a", &.{ .{ "mod.ini", "[Scripts]\nGlobal=a.luau\n" }, .{ "a.luau", "" } } }});
    var opened: engine.game.bigfile.Mods = try .open(std.testing.allocator, io, tmp.dir, null);
    defer opened.close(std.testing.allocator);
    var watch: Watch = .{};
    // The first look sees what there is, and the next waits for the interval.
    try std.testing.expect(!watch.changed(io, opened.list, 0));
    try std.testing.expect(watch.newest != null);
    watch.newest = watch.newest.? - 1;
    try std.testing.expect(!watch.changed(io, opened.list, Watch.interval - 1));
    try std.testing.expect(watch.changed(io, opened.list, Watch.interval));
    try std.testing.expect(!watch.changed(io, opened.list, 2 * Watch.interval));
}

test "the watch sees a folder mod's shaders" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const load = @import("load.zig");
    try load.testing.makeMods(io, tmp.dir, &.{.{ "a", &.{ .{ "mod.ini", "[Mod]\nName=A\n" }, .{ "crt.frag", "" } } }});
    var opened: engine.game.bigfile.Mods = try .open(std.testing.allocator, io, tmp.dir, null);
    defer opened.close(std.testing.allocator);
    var watch: Watch = .{};
    // The mod has no script, so what the watch saw is the shader.
    _ = watch.changed(io, opened.list, 0);
    const stat = try tmp.dir.statFile(io, "mods/a/crt.frag", .{});
    try std.testing.expectEqual(stat.mtime.nanoseconds, watch.newest.?);
}

test "the console runs its commands, and Luau in a mod's context" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const load = @import("load.zig");
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try load.testing.makeMods(io, tmp.dir, &.{.{ "a", &.{
        .{ "mod.ini", "[Scripts]\nGlobal=a.luau\n" },
        .{ "a.luau", "return {}" },
        .{ "shared.luau", "return { value = 7 }" },
    } }});
    var opened: engine.game.bigfile.Mods = try .open(gpa, io, tmp.dir, null);
    defer opened.close(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var held = try load.testing.records3(arena.allocator());
    var mission: engine.game.gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const game = (try Game.start(gpa, io, opened.list, &held, "0.7.0", mission.objects, .{}, false)).?;
    defer game.stop();
    const scripts: Scripts = .{ .game = game };
    var console: Console = .{ .gpa = gpa, .mods = opened.list };
    output.clear();

    const Expect = struct {
        fn last(text: []const u8) !void {
            try std.testing.expectEqualStrings(text, output.lineAt(output.count - 1).text());
        }
    };
    try std.testing.expectEqual(null, try runLine(&console, scripts, "mods"));
    try Expect.last("a: global a.luau");
    try std.testing.expectEqual(Request.reload, try runLine(&console, scripts, "reload"));
    _ = try runLine(&console, scripts, "nope");
    try Expect.last("there's no command nope: help lists them");
    _ = try runLine(&console, scripts, "player a");
    try Expect.last("no player scripts of a run now");
    _ = try runLine(&console, scripts, "global");
    try Expect.last("global takes a mod's name: global <mod>: runs Luau in the context of the mod's global scripts");
    // Luau keeps its variables from one line to the next, and requires the mod's scripts.
    _ = try runLine(&console, scripts, "global a");
    try std.testing.expectEqual(Mode{ .luau = .{ .mod = 0, .family = .global } }, console.mode);
    _ = try runLine(&console, scripts, "x = 6 * 7");
    try Expect.last("a global> x = 6 * 7");
    _ = try runLine(&console, scripts, "x, require('shared').value + x");
    try Expect.last("42    49");
    _ = try runLine(&console, scripts, "exit");
    try std.testing.expectEqual(Mode.commands, console.mode);
}

/// Types `line` into `console` and runs it.
fn runLine(console: *Console, scripts: Scripts, line: []const u8) Allocator.Error!?Request {
    console.typed.set(line);
    return console.run(scripts);
}

test "Console.recall" {
    var console: Console = .{ .gpa = std.testing.allocator, .mods = &.{} };
    for ([_][]const u8{ "one", "two", "two", "three" }) |line| console.history.add(line);
    try std.testing.expectEqual(3, console.history.count);
    console.recall(.back);
    try std.testing.expectEqualStrings("three", console.typed.slice());
    console.recall(.back);
    console.recall(.back);
    console.recall(.back);
    try std.testing.expectEqualStrings("one", console.typed.slice());
    console.recall(.on);
    try std.testing.expectEqualStrings("two", console.typed.slice());
    console.recall(.on);
    console.recall(.on);
    try std.testing.expectEqualStrings("", console.typed.slice());
}
