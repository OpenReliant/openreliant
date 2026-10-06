//! The files of OpenReliant's caches in the game folder's `cache` (`shader_cache.zig`,
//! `texture_cache.zig`): one file for each name, named by a hash of the name, that starts with a
//! `Header` and holds the cache's own payload after it. The header has the cache's magic and the
//! version of its layout, the key of what the payload was made from, and the size and a hash of
//! the payload. A file that is damaged, cut short, of another layout or of another key is ignored,
//! and a file is written whole or not at all. A cache's folder can be deleted at any time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const XxHash3 = std.hash.XxHash3;

/// A cache file's extension.
const extension = ".bin";

/// What sets a cache's files apart.
pub const Spec = struct {
    /// Where its files are, in the game folder, such as `cache/shaders`.
    folder: []const u8,
    /// What its files start with.
    magic: [4]u8,
    /// The version of its files' layout: change it when the header or the payload changes.
    version: u32,
    /// The key of what a payload was made from.
    Key: type,
    /// The largest file it reads.
    max_bytes: usize,
    /// Whether names that differ only in case share a file, as texture names do.
    any_case: bool = false,
};

pub fn Files(comptime spec: Spec) type {
    return struct {
        io: Io,
        /// The game folder, or null to keep nothing.
        root: ?Io.Dir,

        const Self = @This();
        pub const Key = spec.Key;

        /// The start of a cache file.
        pub const Header = extern struct {
            magic: [4]u8 = spec.magic,
            version: u32 = spec.version,
            key: Key,
            /// The XxHash3 of the payload, and its size in bytes.
            check: u64,
            size: u64,
        };

        /// The path of `name`'s file in the game folder.
        pub const Path = [spec.folder.len + 1 + Sha256.digest_length * 2 + extension.len]u8;

        /// A file read: its bytes and the payload in them.
        pub const Read = struct {
            bytes: []u8,
            payload: []const u8,

            pub fn deinit(file: Read, gpa: Allocator) void {
                gpa.free(file.bytes);
            }
        };

        pub fn pathOf(name: []const u8) Path {
            var digest: [Sha256.digest_length]u8 = undefined;
            if (spec.any_case) {
                var hash: Sha256 = .init(.{});
                for (name) |c| hash.update(&.{std.ascii.toLower(c)});
                hash.final(&digest);
            } else Sha256.hash(name, &digest, .{});
            return (spec.folder ++ "/").* ++ std.fmt.bytesToHex(digest, .lower) ++ extension.*;
        }

        /// The payload of `name`'s file, if its key is `key` and it is whole; null where there is
        /// none, or it can't be read.
        pub fn read(files: Self, gpa: Allocator, name: []const u8, key: Key) Allocator.Error!?Read {
            const root = files.root orelse return null;
            const path = pathOf(name);
            const bytes = root.readFileAlloc(files.io, &path, gpa, .limited(spec.max_bytes)) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => return null,
            };
            const payload = payloadOf(bytes, key) orelse {
                gpa.free(bytes);
                return null;
            };
            return .{ .bytes = bytes, .payload = payload };
        }

        /// Writes `name`'s file with the key `key` and a payload of `parts` one after the other,
        /// in place of what was there. Without a game folder, it keeps nothing.
        pub fn write(files: Self, name: []const u8, key: Key, parts: []const []const u8) !void {
            const root = files.root orelse return;
            var check: XxHash3 = .init(0);
            var size: u64 = 0;
            for (parts) |part| {
                check.update(part);
                size += part.len;
            }
            const header: Header = .{ .key = key, .check = check.final(), .size = size };
            const path = pathOf(name);
            var file = try root.createFileAtomic(files.io, &path, .{ .make_path = true, .replace = true });
            defer file.deinit(files.io);
            try file.file.writeStreamingAll(files.io, std.mem.asBytes(&header));
            for (parts) |part| try file.file.writeStreamingAll(files.io, part);
            try file.replace(files.io);
        }

        /// The payload in the file `bytes`, if it is of this cache's layout, its key is `key` and
        /// it is whole; else null.
        pub fn payloadOf(bytes: []const u8, key: Key) ?[]const u8 {
            if (bytes.len < @sizeOf(Header)) return null;
            const header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
            if (!std.mem.eql(u8, &header.magic, &spec.magic) or header.version != spec.version) return null;
            if (!std.mem.eql(u8, std.mem.asBytes(&header.key), std.mem.asBytes(&key))) return null;
            const payload = bytes[@sizeOf(Header)..];
            if (header.size != payload.len or XxHash3.hash(0, payload) != header.check) return null;
            return payload;
        }
    };
}

test Files {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const Test = Files(.{ .folder = "cache/test", .magic = "ORTS".*, .version = 1, .Key = u64, .max_bytes = 1024, .any_case = true });
    const files: Test = .{ .io = io, .root = tmp.dir };

    // Written in parts and read back whole, by a name in any case.
    try files.write("Hull", 7, &.{ "ab", "cd" });
    const kept = (try files.read(gpa, "hull", 7)).?;
    defer kept.deinit(gpa);
    try std.testing.expectEqualStrings("abcd", kept.payload);
    // Another key, and a name with no file.
    try std.testing.expectEqual(null, try files.read(gpa, "hull", 8));
    try std.testing.expectEqual(null, try files.read(gpa, "other", 7));
    // Without a game folder, it keeps nothing and finds nothing.
    const none: Test = .{ .io = io, .root = null };
    try none.write("hull", 7, &.{"ab"});
    try std.testing.expectEqual(null, try none.read(gpa, "hull", 7));

    // A file cut short, with a changed byte, or of another version is ignored.
    const bytes = try tmp.dir.readFileAlloc(io, &Test.pathOf("hull"), gpa, .limited(1024));
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("abcd", Test.payloadOf(bytes, 7).?);
    try std.testing.expectEqual(null, Test.payloadOf(bytes[0 .. bytes.len - 1], 7));
    try std.testing.expectEqual(null, Test.payloadOf(bytes[0..10], 7));
    bytes[bytes.len - 1] ^= 1;
    try std.testing.expectEqual(null, Test.payloadOf(bytes, 7));
    bytes[bytes.len - 1] ^= 1;
    bytes[4] +%= 1;
    try std.testing.expectEqual(null, Test.payloadOf(bytes, 7));
}
