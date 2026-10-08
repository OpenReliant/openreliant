//! The log file ([#752](https://github.com/OpenReliant/openreliant/issues/752)): `openreliant.log`
//! in the game folder, which a player can attach to a bug report. OpenReliant writes each message
//! of the log to it as well as to the terminal, the C libraries' among them
//! (`platform.logs`), and what a crash or a memory fault says, with its stack trace. The file
//! starts afresh each run. A message that comes again straight after itself is counted rather
//! than written again, and the file stops growing at `max_size`. When it's full, the file, the
//! terminal and the scripting console say so.
//!
//! **Improvement:** the original keeps no log.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// The log file's name, in the game folder.
pub const name = "openreliant.log";

/// How large the file can grow. Each run starts it afresh, so it never takes more of the disk.
/// Messages past it only go to the terminal, and a crash is still written.
pub const max_size = 8 * 1024 * 1024;

/// What the terminal, the scripting console and the log file itself say once the log is full.
pub const full_message = std.fmt.comptimePrint("the log file {s} is full at {d} MiB, so the rest of this run's messages only go to the terminal. A script that writes a message every frame can fill it.", .{ name, max_size >> 20 });

const full_line = "warning: " ++ full_message ++ "\n";

/// A log written to `writer` the way the terminal shows it, without colours. A message that comes
/// again straight after itself, such as one a script writes every frame, is counted rather than
/// written again.
pub const Log = struct {
    writer: *Io.Writer,
    /// How many bytes it can hold.
    room: usize = max_size,
    /// How many bytes are written so far.
    written: usize = 0,
    /// The last message written: a hash of its level, scope and text.
    last: ?u64 = null,
    /// How many times the last message came again since it was written.
    repeats: usize = 0,

    /// What `add` did with a message.
    pub const Added = enum {
        written,
        /// It's the last message again, and counted.
        repeated,
        /// It didn't fit, and the log is full now.
        filled,
        /// The log was full already.
        full,
    };

    /// Writes a message as `std.log.defaultLog` does, or counts it if it's the last one again. The
    /// message that would take the log past its room is left out, and a line says the log is full.
    pub fn add(log: *Log, comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) Added {
        if (log.full()) return .full;
        const key = hash(level, scope, format, args);
        if (log.last == key) {
            log.repeats += 1;
            return .repeated;
        }
        const prefix = comptime level.asText().len + (if (scope == .default) 0 else @tagName(scope).len + 2) + ": ".len;
        const size = prefix + std.fmt.count(format ++ "\n", args);
        if (!log.endRepeats() or log.written + size > log.room) return log.fill();
        std.log.defaultLogFileTerminal(level, scope, format, args, log.terminal()) catch {};
        log.written += size;
        log.last = key;
        log.writer.flush() catch {};
        return .written;
    }

    /// Whether it holds as much as it can.
    pub fn full(log: Log) bool {
        return log.written >= log.room;
    }

    /// Ends the log: says how many times the last message came again.
    pub fn finish(log: *Log) void {
        if (log.full()) return;
        if (!log.endRepeats()) _ = log.fill();
        log.writer.flush() catch {};
    }

    /// Writes what a panic says, and the stack trace from the address `first`, even when the log is
    /// full.
    pub fn crash(log: *Log, message: []const u8, first: usize) void {
        if (!log.full()) _ = log.endRepeats();
        log.writer.print("panic: {s}\n", .{message}) catch return;
        std.debug.writeCurrentStackTrace(.{ .first_address = first, .allow_unsafe_unwind = true }, log.terminal()) catch {};
        log.writer.flush() catch {};
    }

    /// Writes what a memory fault was, `what`, at `address`, and the stack trace from `context`,
    /// even when the log is full.
    pub fn fault(log: *Log, address: ?usize, what: []const u8, context: ?std.debug.CpuContextPtr) void {
        if (!log.full()) _ = log.endRepeats();
        if (address) |at| {
            log.writer.print("{s} at address 0x{x}\n", .{ what, at }) catch return;
        } else {
            log.writer.print("{s} (no address available)\n", .{what}) catch return;
        }
        if (context) |from| std.debug.writeCurrentStackTrace(.{ .context = from, .allow_unsafe_unwind = true }, log.terminal()) catch {};
        log.writer.flush() catch {};
    }

    /// Writes how many times the last message came again, if it did, and starts the count again.
    /// False if that doesn't fit.
    fn endRepeats(log: *Log) bool {
        defer log.repeats = 0;
        if (log.repeats == 0) return true;
        const times = .{ log.repeats, if (log.repeats == 1) "time" else "times" };
        const size = std.fmt.count(repeats_format, times);
        if (log.written + size > log.room) return false;
        log.writer.print(repeats_format, times) catch {};
        log.written += size;
        return true;
    }

    const repeats_format = "(the message above came {d} more {s})\n";

    /// Says the log is full, and leaves out the rest.
    fn fill(log: *Log) Added {
        log.writer.writeAll(full_line) catch {};
        log.writer.flush() catch {};
        log.written = log.room;
        return .filled;
    }

    fn terminal(log: *Log) Io.Terminal {
        return .{ .writer = log.writer, .mode = .no_color };
    }

    /// A hash of a message's level, scope and text.
    fn hash(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) u64 {
        var bytes: [64]u8 = undefined;
        var hashing: Io.Writer.Hashing(std.hash.Wyhash) = .initHasher(.init(0), &bytes);
        hashing.writer.print(level.asText() ++ "(" ++ @tagName(scope) ++ "): " ++ format, args) catch {};
        hashing.writer.flush() catch {};
        return hashing.hasher.final();
    }
};

/// The log file while it's open.
const Opened = struct {
    file_writer: Io.File.Writer,
    log: Log,
};

var opened: ?Opened = null;
var buffer: [4096]u8 = undefined;
/// Set by the first crash, so that a crash while writing one doesn't write again.
var crashing: std.atomic.Value(bool) = .init(false);

/// Starts the log file afresh in the game folder `directory`, and logs OpenReliant's `version`, the
/// system and the time. If the file can't be written, the log only goes to the terminal, which says
/// so.
pub fn open(io: Io, directory: Io.Dir, version: []const u8) void {
    const file = directory.createFile(io, name, .{}) catch |err| {
        std.log.warn("can't write the log to {s}: {s}", .{ name, @errorName(err) });
        return;
    };
    opened = .{ .file_writer = file.writerStreaming(io, &buffer), .log = undefined };
    opened.?.log = .{ .writer = &opened.?.file_writer.interface };
    const now: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, Io.Clock.real.now(io).toSeconds())) };
    const date = now.getEpochDay().calculateYearDay();
    const day = date.calculateMonthDay();
    const time = now.getDaySeconds();
    std.log.info("openreliant {s} on {s}-{s}, started {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{
        version,
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        date.year,
        day.month.numeric(),
        day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
    });
}

/// Closes the log file.
pub fn close(io: Io) void {
    _ = std.debug.lockStderr(&.{});
    defer std.debug.unlockStderr();
    if (opened) |*file| {
        file.log.finish();
        file.file_writer.file.close(io);
    }
    opened = null;
}

/// Writes a message of the log to the terminal, as `std.log.defaultLog` does, and to the log file.
/// True if it filled the log file, which the caller should then say (`full_message`).
pub fn logLine(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) bool {
    const io = std.Options.debug_io;
    const before = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(before);
    var stderr_buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&stderr_buffer).terminal();
    defer std.debug.unlockStderr();
    std.log.defaultLogFileTerminal(level, scope, format, args, stderr) catch {};
    const file = if (opened) |*file| file else return false;
    return file.log.add(level, scope, format, args) == .filled;
}

/// Writes a crash to the log file: the panic's `message`, and the stack trace from the address
/// `first`.
pub fn crash(message: []const u8, first: usize) void {
    if (crashing.swap(true, .acq_rel)) return;
    if (opened) |*file| file.log.crash(message, first);
}

/// Writes a memory fault to the log file: what it was, `what`, at `address`, and the stack trace
/// from `context`.
pub fn fault(address: ?usize, what: []const u8, context: ?std.debug.CpuContextPtr) void {
    if (crashing.swap(true, .acq_rel)) return;
    if (opened) |*file| file.log.fault(address, what, context);
}

test "Log.add" {
    var written: Io.Writer.Allocating = .init(std.testing.allocator);
    defer written.deinit();
    var log: Log = .{ .writer = &written.writer, .room = 140 };
    // Messages are written as the terminal shows them, without colours.
    try std.testing.expectEqual(.written, log.add(.info, .mods, "mod {d} of {d}", .{ 1, 2 }));
    try std.testing.expectEqual(.written, log.add(.warn, .default, "no controller", .{}));
    // A message that comes again straight after itself is counted, and the count written before the
    // next one.
    for (0..3) |_| try std.testing.expectEqual(.repeated, log.add(.warn, .default, "no controller", .{}));
    try std.testing.expectEqual(.written, log.add(.info, .mods, "mod {d} of {d}", .{ 2, 2 }));
    const before =
        \\info(mods): mod 1 of 2
        \\warning: no controller
        \\(the message above came 3 more times)
        \\info(mods): mod 2 of 2
        \\
    ;
    try std.testing.expectEqualStrings(before, written.written());
    try std.testing.expectEqual(written.written().len, log.written);
    // The same text at another level is another message.
    try std.testing.expectEqual(.written, log.add(.err, .mods, "mod {d} of {d}", .{ 2, 2 }));
    // The message that doesn't fit is left out, a line says the log is full, and nothing follows.
    try std.testing.expectEqual(.filled, log.add(.info, .fonts, "{s}", .{"a message that takes the log past its room"}));
    try std.testing.expectEqual(.full, log.add(.err, .default, "short", .{}));
    try std.testing.expectEqualStrings(before ++ "error(mods): mod 2 of 2\n" ++ full_line, written.written());
}

test "Log.finish" {
    var written: Io.Writer.Allocating = .init(std.testing.allocator);
    defer written.deinit();
    var log: Log = .{ .writer = &written.writer };
    // A count still open at the end is written.
    for (0..2) |_| _ = log.add(.info, .scripts, "tick", .{});
    log.finish();
    try std.testing.expectEqualStrings("info(scripts): tick\n(the message above came 1 more time)\n", written.written());
}

test "Log.fault" {
    var written: Io.Writer.Allocating = .init(std.testing.allocator);
    defer written.deinit();
    var log: Log = .{ .writer = &written.writer, .room = 0 };
    // A fault is written into a full log too, with its address where it has one.
    log.fault(0x10, "Segmentation fault", null);
    log.fault(null, "Stack overflow", null);
    try std.testing.expectEqualStrings("Segmentation fault at address 0x10\nStack overflow (no address available)\n", written.written());
}

test "Log.crash" {
    var written: Io.Writer.Allocating = .init(std.testing.allocator);
    defer written.deinit();
    var log: Log = .{ .writer = &written.writer, .room = 0 };
    // A crash is written into a full log too.
    log.crash("index out of bounds", @returnAddress());
    try std.testing.expect(std.mem.startsWith(u8, written.written(), "panic: index out of bounds\n"));
}
