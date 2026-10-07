//! Reads the ITAC's tables out of the payload: the shapes it lights where the pointer is over them
//! (`itac_lit_draw`, `0x00440F90`), the debriefings its DEBRIEFINGS shows, by the rating a
//! mission's script gave it (`debrief_text_draw`, `0x00424CF0`), and the items of its NEWS REPORTS
//! (`news_list_build`, `0x0044E490`).
//!
//! The lit shapes are rows of twelve bytes, up to one whose x is -1: where the shape stands, its
//! index in `itacgfx.spr`, a halfword never read, and a mask of the sections it lights in.
//!
//! The payload holds a table of debriefings for each rating, from success with its bonus at
//! `first_debriefings` down to failure, each of `missions` rows of nine halfwords: the string that
//! heads the debriefing, then those of its paragraphs, up to `end_mark`, which ends them.
//!
//! The news items are records of 32 bytes (`StoredNews`): the links the section's list threads
//! them on, the string of the item's title, those of up to five paragraphs ended by
//! `no_paragraph`, the picture's shape, a halfword never read, and the mission after which the item
//! is listed.

const std = @import("std");
const Io = std.Io;

const image = @import("image.zig");
const testing = @import("testing.zig");

/// The lit shapes (`itac_lit_shapes`).
pub const lit_table: u32 = 0x004E94D8;

/// The x that ends the lit shapes.
const lit_end = -1;

/// A lit shape as the payload lays it out.
const StoredLit = extern struct {
    x: i16,
    y: i16,
    shape: u16,
    _unread: u16,
    sections: u32,

    comptime {
        std.debug.assert(@sizeOf(StoredLit) == 12);
    }
};

/// A shape the ITAC lights where the pointer is over it, while a section its mask holds shows.
pub const LitShape = struct {
    at: [2]i16,
    shape: u16,
    sections: u32,
};

/// The table of success with its bonus (rating 4), which the others follow a rating lower each.
pub const first_debriefings: u32 = 0x004E4A68;

/// The ratings, failure (0) to success with its bonus (4), and the missions a table holds.
pub const ratings = 5;
pub const missions = 28;

/// The halfwords of a row: the header, then at most eight paragraphs.
const row_halfwords = 9;

/// The string that ends a row's paragraphs, where there are fewer than eight (`0x00424FB2`).
pub const end_mark = 9;

/// The bytes of a table of debriefings.
const table_size = missions * row_halfwords * @sizeOf(i16);

/// A debriefing: the string that heads it, and those of its paragraphs.
pub const Text = struct {
    header: u16,
    paragraphs: []const u16,
};

/// NEWS REPORTS' items (`news_items`), and how many there are.
pub const news_table: u32 = 0x004EB0E8;
pub const news_count = 24;

/// The paragraph that ends an item's paragraphs, where there are fewer than five.
const no_paragraph = -1;

/// A news item as the payload lays it out.
const StoredNews = extern struct {
    links: [3]u32,
    title: u16,
    paragraphs: [5]i16,
    shape: u16,
    _unread: u16,
    mission: i32,

    comptime {
        std.debug.assert(@sizeOf(StoredNews) == 0x20);
    }
};

/// A news item: the string of its title, those of its paragraphs, the shape of its picture, and
/// the mission after which it is listed.
pub const News = struct {
    title: u16,
    paragraphs: []const u16,
    shape: u16,
    mission: i32,
};

/// What the tables hold.
pub const Tables = struct {
    lit_shapes: []const LitShape,
    debriefings: [ratings][missions]Text,
    news: [news_count]News,
};

/// The table of rating `rating`.
fn debriefingsOf(rating: usize) u32 {
    return first_debriefings + @as(u32, @intCast((ratings - 1 - rating) * table_size));
}

/// The most lit shapes read before the end is taken to be missing.
const most_lit = 100;

pub fn read(arena: std.mem.Allocator, reader: image.Reader) (image.Error || std.mem.Allocator.Error || error{NoEnd})!Tables {
    var lit: std.ArrayList(LitShape) = .empty;
    for (0..most_lit) |index| {
        const stored = try reader.recordAt(StoredLit, lit_table, index);
        if (stored.x == lit_end) break;
        try lit.append(arena, .{ .at = .{ stored.x, stored.y }, .shape = stored.shape, .sections = stored.sections });
    } else return error.NoEnd;

    var debriefings: [ratings][missions]Text = undefined;
    for (&debriefings, 0..) |*table, rating| {
        for (table, 0..) |*text, mission| {
            var row: [row_halfwords]u16 = undefined;
            for (&row, 0..) |*id, n| id.* = try reader.recordAt(u16, debriefingsOf(rating), mission * row_halfwords + n);
            const paragraphs = row[1..];
            const count = std.mem.findScalar(u16, paragraphs, end_mark) orelse paragraphs.len;
            text.* = .{ .header = row[0], .paragraphs = try arena.dupe(u16, paragraphs[0..count]) };
        }
    }

    var news: [news_count]News = undefined;
    for (&news, 0..) |*item, index| {
        const stored = try reader.recordAt(StoredNews, news_table, index);
        const count = std.mem.findScalar(i16, &stored.paragraphs, no_paragraph) orelse stored.paragraphs.len;
        const paragraphs = try arena.alloc(u16, count);
        for (paragraphs, stored.paragraphs[0..count]) |*id, read_id| id.* = @bitCast(read_id);
        item.* = .{ .title = stored.title, .paragraphs = paragraphs, .shape = stored.shape, .mission = stored.mission };
    }
    return .{ .lit_shapes = try lit.toOwnedSlice(arena), .debriefings = debriefings, .news = news };
}

/// The names the emitted tables of debriefings go by, from failure up.
const rating_names = [ratings][]const u8{ "failure", "partial failure", "partial success", "success", "success with its bonus" };

/// Writes `tables.zig`.
pub fn emit(w: *Io.Writer, tables: Tables) Io.Writer.Error!void {
    try w.print(
        \\//! The ITAC's tables: the shapes it lights where the pointer is over them, the debriefings its
        \\//! DEBRIEFINGS shows, and the items of its NEWS REPORTS.
        \\//!
        \\//! Generated by `src/tools/tablegen` from the payload executable's lit shapes at 0x{X:0>8}, {d}
        \\//! rows, its debriefings from 0x{X:0>8}, {d} tables of {d} rows, and its news items at
        \\//! 0x{X:0>8}, {d} rows. Do not edit by hand; run `make itac-tables`.
        \\
        \\/// A shape the ITAC lights where the pointer is over it, while a section its mask holds shows.
        \\pub const LitShape = struct {{ at: [2]i16, shape: u16, sections: u32 }};
        \\
        \\pub const lit_shapes = [_]LitShape{{
        \\
    , .{ lit_table, tables.lit_shapes.len, first_debriefings, ratings, missions, news_table, news_count });
    for (tables.lit_shapes) |lit| {
        try w.print("    .{{ .at = .{{ {d}, {d} }}, .shape = 0x{X}, .sections = 0x{X} }},\n", .{ lit.at[0], lit.at[1], lit.shape, lit.sections });
    }
    try w.print(
        \\}};
        \\
        \\/// A debriefing: the string that heads it, and those of its paragraphs.
        \\pub const Text = struct {{ header: u16, paragraphs: []const u16 }};
        \\
        \\/// By the rating, failure (0) to success with its bonus (4), then by the mission number less one.
        \\pub const debriefings = [{d}][{d}]Text{{
        \\
    , .{ ratings, missions });
    for (tables.debriefings, rating_names) |table, name| {
        try w.print("    .{{ // {s}\n", .{name});
        for (table, 1..) |text, mission| {
            try w.print("        .{{ .header = {d}, .paragraphs = &.{{", .{text.header});
            for (text.paragraphs, 0..) |id, n| try w.print("{s}{d}", .{ if (n == 0) " " else ", ", id });
            try w.print(" }} }}, // {d}\n", .{mission});
        }
        try w.writeAll("    },\n");
    }
    try w.writeAll(
        \\};
        \\
        \\/// A news item: the string of its title, those of its paragraphs, the shape of its picture in
        \\/// `newsrep.spr`, and the mission after which it is listed.
        \\pub const NewsItem = struct { title: u16, paragraphs: []const u16, shape: u16, mission: i32 };
        \\
        \\pub const news = [_]NewsItem{
        \\
    );
    for (tables.news) |item| {
        try w.print("    .{{ .title = {d}, .paragraphs = &.{{", .{item.title});
        for (item.paragraphs, 0..) |id, n| try w.print("{s}{d}", .{ if (n == 0) " " else ", ", id });
        try w.print(" }}, .shape = {d}, .mission = {d} }},\n", .{ item.shape, item.mission });
    }
    try w.writeAll(
        \\};
        \\
    );
}

test read {
    const allocator = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two lit shapes, then the end.
    const lit_bytes = try allocator.alloc(u8, 3 * @sizeOf(StoredLit));
    defer allocator.free(lit_bytes);
    const lit_region: testing.Region = .{ .va = lit_table, .bytes = lit_bytes };
    lit_region.putRecord(lit_table, StoredLit{ .x = 16, .y = 422, .shape = 0x24, ._unread = 0, .sections = 0xFFFF_FFFF });
    lit_region.putRecord(lit_table + 12, StoredLit{ .x = 221, .y = 322, .shape = 0x1F, ._unread = 0, .sections = 1 });
    lit_region.putRecord(lit_table + 24, StoredLit{ .x = lit_end, .y = 0, .shape = 0, ._unread = 0, .sections = 0 });

    const bytes = try allocator.alloc(u8, ratings * table_size);
    defer allocator.free(bytes);
    @memset(bytes, 0);
    for (0..ratings * missions) |row| std.mem.writeInt(u16, bytes[row * row_halfwords * 2 ..][0..2], 10, .little);
    // Success with its bonus leads the tables, failure ends them: mission 1's full row of each, and
    // mission 2's two paragraphs of success.
    const region: testing.Region = .{ .va = first_debriefings, .bytes = bytes };
    for (0..8) |n| region.putRecord(first_debriefings + @as(u32, @intCast(2 + 2 * n)), @as(u16, @intCast(1641 + n)));
    for (0..8) |n| region.putRecord(debriefingsOf(0) + @as(u32, @intCast(2 + 2 * n)), @as(u16, @intCast(500 + n)));
    const success_row_2 = debriefingsOf(3) + row_halfwords * 2;
    for ([_]u16{ 369, 370, end_mark, 1 }, 0..) |id, n| region.putRecord(success_row_2 + @as(u32, @intCast(2 + 2 * n)), id);

    // The first news item with five paragraphs, the second with two, the rest zeros.
    const news_bytes = try allocator.alloc(u8, news_count * @sizeOf(StoredNews));
    defer allocator.free(news_bytes);
    @memset(news_bytes, 0);
    const news_region: testing.Region = .{ .va = news_table, .bytes = news_bytes };
    news_region.putRecord(news_table, StoredNews{ .links = @splat(0), .title = 537, .paragraphs = .{ 565, 566, 567, 568, 569 }, .shape = 1, ._unread = 0, .mission = 0 });
    news_region.putRecord(news_table + @sizeOf(StoredNews), StoredNews{ .links = @splat(0), .title = 538, .paragraphs = .{ 570, 571, no_paragraph, no_paragraph, no_paragraph }, .shape = 2, ._unread = 0, .mission = 1 });

    const payload = try testing.reader(allocator, &.{ lit_region, region, news_region });
    defer testing.freeReader(allocator, payload);
    const tables = try read(arena, payload);
    try std.testing.expectEqual(2, tables.lit_shapes.len);
    try std.testing.expectEqual(LitShape{ .at = .{ 221, 322 }, .shape = 0x1F, .sections = 1 }, tables.lit_shapes[1]);
    try std.testing.expectEqual(10, tables.debriefings[4][0].header);
    try std.testing.expectEqual(8, tables.debriefings[4][0].paragraphs.len);
    try std.testing.expectEqual(1641, tables.debriefings[4][0].paragraphs[0]);
    try std.testing.expectEqual(500, tables.debriefings[0][0].paragraphs[0]);
    try std.testing.expectEqualSlices(u16, &.{ 369, 370 }, tables.debriefings[3][1].paragraphs);
    try std.testing.expectEqual(5, tables.news[0].paragraphs.len);
    try std.testing.expectEqualSlices(u16, &.{ 570, 571 }, tables.news[1].paragraphs);
    try std.testing.expectEqual(2, tables.news[1].shape);
    try std.testing.expectEqual(1, tables.news[1].mission);

    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try emit(&out.writer, tables);
    try testing.expectZig(out.written());
}
