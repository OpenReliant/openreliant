//! Checksum files in the format `sha256sum` writes and `sha256sum -c` checks: a line for each file,
//! with its SHA-256 hash in hexadecimal, a space, a space or a `*`, and the file's name. When a mod
//! loads, OpenReliant checks its archive against the checksum file next to it, named after the
//! archive plus `extension`, and `sltool hog pack --checksum` writes one.

const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// The extension of a checksum file, added to the name of the file it checks.
pub const extension = ".sha256";

pub const Digest = [Sha256.digest_length]u8;

/// The digest's hexadecimal digits on a line.
const digits = Sha256.digest_length * 2;

/// The bytes a file is read in as it is hashed.
const chunk_size = 1 << 20;

/// The digest of `bytes`.
pub fn digest(bytes: []const u8) Digest {
    var out: Digest = undefined;
    Sha256.hash(bytes, &out, .{});
    return out;
}

/// The digest of the file `file`, read a chunk at a time.
pub fn digestFile(io: Io, file: Io.File) (Io.File.ReadPositionalError || error{OutOfMemory})!Digest {
    var hasher: Sha256 = .init(.{});
    var chunk: [chunk_size]u8 = undefined;
    var at: u64 = 0;
    while (true) {
        const read = try file.readPositional(io, &.{&chunk}, at);
        if (read == 0) break;
        hasher.update(chunk[0..read]);
        at += read;
    }
    return hasher.finalResult();
}

pub const ParseError = error{
    /// A line that is no digest and name.
    Malformed,
};

/// The digest the checksum file `text` gives the file `name`: on the line that names it, by the
/// name less its folders, whatever its case, or on the file's one line, which may name it as it
/// was named when it was made. Null where the file holds lines for others alone.
pub fn digestOf(text: []const u8, name: []const u8) ParseError!?Digest {
    var only: ?Digest = null;
    var count: usize = 0;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const entry = try parseLine(line);
        if (std.ascii.eqlIgnoreCase(std.fs.path.basenameWindows(entry.name), name)) return entry.digest;
        only = entry.digest;
        count += 1;
    }
    return if (count == 1) only else null;
}

const Entry = struct { digest: Digest, name: []const u8 };

/// A line: the digest's hexadecimal digits, in either case, a space, a space or a `*`, and a name.
fn parseLine(line: []const u8) ParseError!Entry {
    if (line.len < digits + 3 or line[digits] != ' ' or (line[digits + 1] != ' ' and line[digits + 1] != '*'))
        return error.Malformed;
    var entry: Entry = .{ .digest = undefined, .name = line[digits + 2 ..] };
    _ = std.fmt.hexToBytes(&entry.digest, line[0..digits]) catch return error.Malformed;
    return entry;
}

/// Writes the line `sha256sum` writes for the file `name` of the digest `of`.
pub fn writeLine(writer: *Io.Writer, of: Digest, name: []const u8) Io.Writer.Error!void {
    try writer.print("{x}  {s}\n", .{ of, name });
}

test digestOf {
    const of = digest("abc");
    // SHA-256's own test vector.
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &std.fmt.bytesToHex(of, .lower));

    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try writeLine(&writer, of, "coyote.hog");
    const written = writer.buffered();
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  coyote.hog\n", written);
    // The line names the file, whatever its case and folders, or is the file's only one.
    try std.testing.expectEqual(of, (try digestOf(written, "Coyote.HOG")).?);
    try std.testing.expectEqual(of, (try digestOf(written, "renamed.hog")).?);
    const several = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD *mods/coyote.hog\r\n" ++
        "0000000000000000000000000000000000000000000000000000000000000000  music.hog\r\n";
    try std.testing.expectEqual(of, (try digestOf(several, "coyote.hog")).?);
    try std.testing.expectEqual(null, try digestOf(several, "other.hog"));
    try std.testing.expectError(error.Malformed, digestOf("not a checksum", "coyote.hog"));
    try std.testing.expectError(error.Malformed, digestOf("zz" ++ "0" ** 62 ++ "  coyote.hog", "coyote.hog"));
}

test digestFile {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Past a chunk, so that it is read in more than one.
    const bytes = try std.testing.allocator.alloc(u8, chunk_size + 100);
    defer std.testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, at| byte.* = @truncate(at * 7);
    try tmp.dir.writeFile(io, .{ .sub_path = "big.hog", .data = bytes });
    const file = try tmp.dir.openFile(io, "big.hog", .{});
    defer file.close(io);
    try std.testing.expectEqual(digest(bytes), try digestFile(io, file));
}
