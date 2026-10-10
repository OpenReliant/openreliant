//! Battlestar Galactica's binary files, the meshes (`.bmsh`), textures (`.btga`), sounds (`.bwav`),
//! music (`.bxm`) and `.banr` files: a 12-byte start, then sections to the end of the file. A
//! section is a count of items, their total size, each item's size, then the items back to back.
//! What the items hold depends on the kind of file. Many hold what look like the addresses they had
//! in the Xbox's memory when the file was written.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const layout = @import("../../layout.zig");

/// The start of a binary file.
pub const Start = extern struct {
    /// When the file was written, as a Unix time.
    written: u32,
    /// 4 in a mesh, 1 in the other kinds. **Unknown:** whether it is a version.
    version: u32,
    /// The same in every file of a kind but the textures, whose files have five values among them.
    /// **Unknown:** what it is.
    kind: u32,

    comptime {
        assert(@sizeOf(Start) == 12);
    }
};

/// A section's count of items and their total size, before the items' sizes.
const SectionHead = extern struct {
    count: u32,
    total: u32,
};

pub const Section = struct {
    /// Each item's bytes.
    items: []const []const u8,

    /// Item `index`'s bytes, or null where the section has fewer items.
    pub fn item(section: Section, index: usize) ?[]const u8 {
        return if (index < section.items.len) section.items[index] else null;
    }
};

pub const Error = error{
    /// A section runs past the end of the file, or its items' sizes don't add up to its total.
    BadSection,
} || layout.Error;

pub const Resource = struct {
    start: *align(1) const Start,
    sections: []const Section,

    /// The file in `bytes`, its sections in the arena, which must outlive the file's bytes' use.
    pub fn parse(arena: Allocator, bytes: []const u8) (Error || Allocator.Error)!Resource {
        const start = try layout.view(Start, bytes);
        var sections: std.ArrayList(Section) = .empty;
        var at: usize = @sizeOf(Start);
        while (at < bytes.len) {
            const head = layout.view(SectionHead, bytes[at..]) catch return error.BadSection;
            const sizes = layout.array(u32, bytes[at + @sizeOf(SectionHead) ..], head.count) catch return error.BadSection;
            at += @sizeOf(SectionHead) + sizes.len * @sizeOf(u32);
            if (bytes.len - at < head.total) return error.BadSection;
            const items = try arena.alloc([]const u8, sizes.len);
            var total: u64 = 0;
            for (items, sizes) |*item, size| {
                total += size;
                if (total > head.total) return error.BadSection;
                item.* = bytes[at..][0..size];
                at += size;
            }
            if (total != head.total) return error.BadSection;
            try sections.append(arena, .{ .items = items });
        }
        return .{ .start = start, .sections = sections.items };
    }
};

/// Builds binary files, for tests.
pub const testing = struct {
    /// A file of `sections`, each a list of items, written at `written`.
    pub fn build(arena: Allocator, version: u32, kind: u32, sections: []const []const []const u8) Allocator.Error![]u8 {
        var bytes: std.ArrayList(u8) = .empty;
        const start: Start = .{ .written = 1062962210, .version = version, .kind = kind };
        try bytes.appendSlice(arena, std.mem.asBytes(&start));
        for (sections) |items| {
            var total: u32 = 0;
            for (items) |item| total += @intCast(item.len);
            const head: SectionHead = .{ .count = @intCast(items.len), .total = total };
            try bytes.appendSlice(arena, std.mem.asBytes(&head));
            for (items) |item| try bytes.appendSlice(arena, std.mem.asBytes(&@as(u32, @intCast(item.len))));
            for (items) |item| try bytes.appendSlice(arena, item);
        }
        return bytes.items;
    }
};

test Resource {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = try testing.build(arena, 1, 0x7491EC11, &.{
        &.{ "head", "", "body!" },
        &.{"tail"},
    });
    const resource: Resource = try .parse(arena, bytes);
    try std.testing.expectEqual(1062962210, resource.start.written);
    try std.testing.expectEqual(2, resource.sections.len);
    try std.testing.expectEqualStrings("body!", resource.sections[0].item(2).?);
    try std.testing.expectEqualStrings("", resource.sections[0].item(1).?);
    try std.testing.expectEqual(null, resource.sections[1].item(1));

    // A section whose items run past the file is refused.
    try std.testing.expectError(error.BadSection, Resource.parse(arena, bytes[0 .. bytes.len - 1]));
}
