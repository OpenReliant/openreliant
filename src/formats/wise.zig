//! The Wise installer of the Russian release
//! ([docs/formats/russian-release.md](../../docs/formats/russian-release.md#the-installer)): a
//! small Windows program, and after it the files it installs, each deflated and followed by its
//! CRC-32. One of the first of them is the installer's script, which names the rest.
//!
//! Wise made many versions of this format. This reads the one that release's `setup.EXE` is in.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Crc32 = std.hash.Crc32;

const layout = @import("layout.zig");
const pe = @import("pe.zig");

/// A deflated file as the installer holds it: raw deflate, then for some a byte of padding, then
/// the CRC-32 of what it inflates to.
pub const Stream = struct {
    /// Where its deflate data starts in the installer.
    offset: usize,
    /// How many bytes it takes there, its padding and CRC among them.
    len: usize,
    /// What it inflates to: how many bytes, and their CRC-32.
    size: usize,
    crc: u32,

    /// Where the next stream starts.
    pub fn end(stream: Stream) usize {
        return stream.offset + stream.len;
    }
};

/// The most bytes of padding between a stream's deflate data and its CRC.
const most_padding = 3;

/// How far past the program's end the first stream may start: the installer's own header lies
/// between, whose length differs from version to version.
const header_reach = 0x2000;

/// The streams that come before the files the script lists, at most: a picture, the script and
/// the installer's own libraries.
const most_leading = 16;

pub const Error = error{ NotWise, Corrupt } || Allocator.Error;

/// Inflates the stream that starts at the front of `bytes` into `out`, and gives what it took and
/// made; `error.Corrupt` where `bytes` hold no stream that ends in its own CRC.
pub fn inflate(bytes: []const u8, out: *std.Io.Writer) error{ Corrupt, WriteFailed }!Stream {
    var input: std.Io.Reader = .fixed(bytes);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&input, .raw, &window);
    var crc: Crc32 = .init();
    var size: usize = 0;
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = decompress.reader.readSliceShort(&chunk) catch return error.Corrupt;
        if (n == 0) break;
        crc.update(chunk[0..n]);
        size += n;
        try out.writeAll(chunk[0..n]);
    }
    const sum = crc.final();
    // The decoder reads a little ahead, so the CRC is looked for round where it stopped.
    const stopped = input.seek;
    var back: usize = 0;
    while (back <= 8 and back <= stopped) : (back += 1) {
        for (0..most_padding + 1) |padding| {
            const at = stopped - back + padding;
            if (at + 4 > bytes.len) continue;
            if (std.mem.readInt(u32, bytes[at..][0..4], .little) == sum) return .{ .offset = 0, .len = at + 4, .size = size, .crc = sum };
        }
    }
    return error.Corrupt;
}

/// Where the installer's data starts in `bytes`, the front of a Wise installer: after the last
/// section of its program. Null for bytes that aren't a Windows program's.
pub fn overlay(bytes: []u8) ?usize {
    const image = pe.Image.parse(bytes) catch return null;
    var last: usize = 0;
    for (image.sections) |section| last = @max(last, @as(usize, section.raw_offset) + section.raw_size);
    return if (last != 0 and last < bytes.len) last else null;
}

/// The first stream in `bytes` from `from` on, within `header_reach`: the first place a stream of
/// some size inflates and ends in its own CRC.
pub fn firstStream(gpa: Allocator, bytes: []const u8, from: usize) Error!Stream {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var at = from;
    while (at < bytes.len and at < from + header_reach) : (at += 1) {
        out.clearRetainingCapacity();
        var found = inflate(bytes[at..], &out.writer) catch |err| switch (err) {
            error.Corrupt => continue,
            error.WriteFailed => return error.OutOfMemory,
        };
        // A few bytes can inflate to nothing by chance.
        if (found.size < least_first) continue;
        found.offset = at;
        return found;
    }
    return error.NotWise;
}

/// The fewest bytes the installer's first stream, a picture, inflates to.
const least_first = 1024;

/// A file the script installs.
pub const File = struct {
    /// Where the installer puts it, as the script writes it, such as `%MAINDIR%\Language.dll`.
    name: []const u8,
    /// Where its stream starts and ends, counted from the first file's.
    start: u32,
    end: u32,
    /// What it inflates to.
    size: u32,
    crc: u32,

    /// Its path in the game's folder, `/` between its folders, or null for a file that goes
    /// elsewhere, such as the installer's own in the system's folders.
    pub fn gamePath(file: File, buffer: []u8) ?[]const u8 {
        const rest = std.mem.cutPrefix(u8, file.name, game_folder) orelse return null;
        if (rest.len == 0 or rest.len > buffer.len) return null;
        for (rest, buffer[0..rest.len]) |from, *to| to.* = if (from == '\\') '/' else from;
        return buffer[0..rest.len];
    }
};

/// What the script calls the folder the game is installed in.
const game_folder = "%MAINDIR%\\";

/// A file's record in the script, before its name, which ends in a zero byte. The record follows
/// the byte of its command, 0, and two bytes of flags.
const Record = extern struct {
    start: u32 align(1),
    end: u32 align(1),
    /// When the file was last changed, as MS-DOS writes dates and times.
    date: u16 align(1),
    time: u16 align(1),
    size: u32 align(1),
    _unknown_10: [20]u8,
    crc: u32 align(1),

    comptime {
        assert(@sizeOf(Record) == 40);
    }
};

/// What comes before a record: its command and its flags.
const record_lead = 3;
const install_file = 0;

/// The longest name a record is read with.
const longest_name = 260;

/// The files `script` installs, in its order, their names within `script`. The script is a run
/// of commands of many kinds, which this doesn't read: it finds each file's record by its shape,
/// a command of 0, offsets that run on, and a name that starts with one of the script's
/// variables.
pub fn files(gpa: Allocator, script: []const u8) Allocator.Error![]File {
    var found: std.ArrayList(File) = .empty;
    errdefer found.deinit(gpa);
    var at: usize = record_lead;
    while (at + @sizeOf(Record) < script.len) {
        if (recordAt(script, at)) |file| {
            try found.append(gpa, file);
            at += @sizeOf(Record) + file.name.len + 1 + record_lead;
        } else at += 1;
    }
    return found.toOwnedSlice(gpa);
}

fn recordAt(script: []const u8, at: usize) ?File {
    if (script[at - record_lead] != install_file) return null;
    const record = layout.view(Record, script[at..]) catch return null;
    if (record.end <= record.start or record.size == 0) return null;
    // Deflate makes a file a little larger at worst, never many times so.
    const stored = record.end - record.start;
    if (stored > @as(u64, record.size) + record.size / 8 + stored_slack) return null;
    const name_at = at + @sizeOf(Record);
    const name_end = std.mem.indexOfScalarPos(u8, script, name_at, 0) orelse return null;
    const name = script[name_at..name_end];
    if (name.len > longest_name or !startsWithVariable(name)) return null;
    for (name) |character| if (character < ' ') return null;
    return .{ .name = name, .start = record.start, .end = record.end, .size = record.size, .crc = record.crc };
}

/// How many bytes more than a file's own a stream may take beside deflate's worst: its CRC, its
/// padding and deflate's own framing.
const stored_slack = 64;

/// Whether `name` starts with one of the script's variables, such as `%MAINDIR%`: a percent sign,
/// capitals, digits or underscores, and a percent sign.
fn startsWithVariable(name: []const u8) bool {
    if (name.len < 3 or name[0] != '%') return false;
    for (name[1..], 1..) |character, at| switch (character) {
        'A'...'Z', '0'...'9', '_' => {},
        '%' => return at > 1,
        else => return false,
    };
    return false;
}

/// A Wise installer read as far as its script: the files it installs, and where the first of
/// them lies.
pub const Installer = struct {
    files: []File,
    /// The script, which the files' names lie in.
    script: []u8,
    /// Where the files' streams start: each file's `start` counts from here.
    base: usize,

    pub fn deinit(installer: Installer, gpa: Allocator) void {
        gpa.free(installer.files);
        gpa.free(installer.script);
    }

    /// Reads `front`, the start of an installer, which has to reach past its script and the
    /// streams before its files: a megabyte does.
    pub fn read(gpa: Allocator, front: []u8) Error!Installer {
        const data = overlay(front) orelse return error.NotWise;
        var stream = try firstStream(gpa, front, data);
        var kept: ?[]u8 = null;
        errdefer if (kept) |script| gpa.free(script);
        var listed: []File = &.{};
        errdefer gpa.free(listed);
        for (0..most_leading) |_| {
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            var next = inflate(front[stream.offset..], &out.writer) catch |err| switch (err) {
                error.Corrupt => return error.Corrupt,
                error.WriteFailed => return error.OutOfMemory,
            };
            next.offset = stream.offset;
            if (kept == null) {
                // The script is the first stream that lists files.
                const maybe = try files(gpa, out.written());
                if (maybe.len == 0) {
                    gpa.free(maybe);
                } else {
                    gpa.free(maybe);
                    kept = try out.toOwnedSlice();
                    listed = try files(gpa, kept.?);
                }
            } else if (next.size == listed[0].size and next.crc == listed[0].crc) {
                // The first file the script lists: the files' streams start here.
                return .{ .files = listed, .script = kept.?, .base = next.offset - listed[0].start };
            }
            stream.offset = next.end();
            if (stream.offset >= front.len) break;
        }
        return error.NotWise;
    }
};

/// A Wise installer for the tests, with `named` as its files: a small program, a picture, the
/// script, and each file deflated.
pub const testing = struct {
    pub const Named = struct { name: []const u8, data: []const u8 };

    pub fn installer(gpa: Allocator, named: []const Named) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const writer = &out.writer;
        const program = try pe.testing.buildWith(gpa, 0x400000, &.{.{ .name = ".text", .rva = 0x1000, .data = "code" }}, &.{});
        defer gpa.free(program);
        try writer.writeAll(program);
        // The installer's own header, which the reader steps over.
        try writer.splatByteAll(0xA5, 40);

        // Each file's stream, to know its extent before the script is written.
        var streams: std.ArrayList([]u8) = .empty;
        defer {
            for (streams.items) |stream| gpa.free(stream);
            streams.deinit(gpa);
        }
        for (named) |file| try streams.append(gpa, try deflated(gpa, file.data));

        var script: std.Io.Writer.Allocating = .init(gpa);
        defer script.deinit();
        try script.writer.splatByteAll(0x11, 8);
        var start: u32 = 0;
        for (named, streams.items) |file, stream| {
            try script.writer.writeAll(&.{ install_file, 0x80, 0 });
            try script.writer.writeInt(u32, start, .little);
            start += @intCast(stream.len);
            try script.writer.writeInt(u32, start, .little);
            try script.writer.splatByteAll(0, 4);
            try script.writer.writeInt(u32, @intCast(file.data.len), .little);
            try script.writer.splatByteAll(0, 20);
            try script.writer.writeInt(u32, Crc32.hash(file.data), .little);
            try script.writer.writeAll(file.name);
            try script.writer.writeByte(0);
        }
        try script.writer.splatByteAll(0x22, 8);

        var picture: [2048]u8 = undefined;
        for (&picture, 0..) |*byte, at| byte.* = @truncate(at * 7);
        for ([_][]const u8{ &picture, script.written() }) |leading| {
            const stream = try deflated(gpa, leading);
            defer gpa.free(stream);
            try writer.writeAll(stream);
        }
        for (streams.items) |stream| try writer.writeAll(stream);
        return out.toOwnedSlice();
    }

    /// `data` as the installer holds it: raw deflate, then its CRC-32.
    fn deflated(gpa: Allocator, data: []const u8) ![]u8 {
        // The compressor wants room in its output from the start.
        var out: std.Io.Writer.Allocating = try .initCapacity(gpa, data.len / 2 + 64);
        errdefer out.deinit();
        const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
        defer gpa.free(window);
        var compress: std.compress.flate.Compress = try .init(&out.writer, window, .raw, .default);
        try compress.writer.writeAll(data);
        try compress.finish();
        try out.writer.writeInt(u32, Crc32.hash(data), .little);
        return out.toOwnedSlice();
    }
};

test Installer {
    const gpa = std.testing.allocator;
    const helper = "one of the installer's own files, which goes to the system's folder";
    // Files long enough to deflate smaller: a phrase over and over.
    var strings: [480]u8 = undefined;
    for (&strings, 0..) |*byte, at| byte.* = "the strings "[at % 12];
    var speech: [5100]u8 = undefined;
    for (&speech, 0..) |*byte, at| byte.* = "a line of speech "[at % 17];
    const bytes = try testing.installer(gpa, &.{
        .{ .name = "%SYS%\\helper.dll", .data = helper },
        .{ .name = "%MAINDIR%\\Language.dll", .data = &strings },
        .{ .name = "%MAINDIR%\\Ms_speech\\Msspeech.hog", .data = &speech },
    });
    defer gpa.free(bytes);
    const read: Installer = try .read(gpa, bytes);
    defer read.deinit(gpa);
    try std.testing.expectEqual(3, read.files.len);
    var buffer: [64]u8 = undefined;
    // A file outside the game's folder has no path in it.
    try std.testing.expectEqual(null, read.files[0].gamePath(&buffer));
    try std.testing.expectEqualStrings("Language.dll", read.files[1].gamePath(&buffer).?);
    try std.testing.expectEqualStrings("Ms_speech/Msspeech.hog", read.files[2].gamePath(&buffer).?);
    // Each file inflates from its place to what the script says of it.
    for (read.files[1..], [_][]const u8{ &strings, &speech }) |file, expected| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const stream = try inflate(bytes[read.base + file.start .. read.base + file.end], &out.writer);
        try std.testing.expectEqualStrings(expected, out.written());
        try std.testing.expectEqual(file.crc, stream.crc);
        try std.testing.expectEqual(file.size, stream.size);
    }
    // A program with nothing after it, and bytes that aren't one, are no installer.
    const short = try gpa.dupe(u8, bytes[0..overlay(bytes).?]);
    defer gpa.free(short);
    try std.testing.expectError(error.NotWise, Installer.read(gpa, short));
    var junk = "neither a program nor an installer".*;
    try std.testing.expectError(error.NotWise, Installer.read(gpa, &junk));
}
