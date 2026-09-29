//! The loadout's panels as their textures are drawn: the title over the page, with the chosen
//! ship's name, and the info panel with the ship's stats. The game makes each a texture of `size`
//! by `size` pixels and writes its text into it through a VFX pane (`hud.Pane`), and the scene
//! shows it on one face of a two-sided panel (`Face`).
//!
//! Not ported yet: the info panel's two other contents, the ship's guns (`guns_draw`,
//! `0x00445490`) and a missile's info (`missile_info_draw`, `0x004456F0`).

const std = @import("std");

const tga = @import("../../../formats/tga.zig");
const hud = @import("../../game/hud.zig");
const language = @import("../../game/language.zig");
const tables = @import("tables.zig");

/// The panels' textures' size, across and down (`0x00444D83`, `0x00444F40`).
pub const size = 256;

/// A panel's pixels: `size` across and down, four bytes a pixel (red, green, blue and alpha), rows
/// from the top.
pub const Image = [size * size][4]u8;

/// Which of a panel's two faces a texture is drawn for.
pub const Face = enum {
    front,
    back,

    /// The title's texture: `panel_title_draw` names the front's where its last argument is 7
    /// (`0x004EAE7C`), and the back's otherwise (`0x004EAE74`).
    pub fn titleTexture(face: Face) []const u8 {
        return switch (face) {
            .front => "fpanels",
            .back => "bpanels",
        };
    }

    /// The info panel's texture: `loadout_draw_stats`, `guns_draw` and `missile_info_draw` name
    /// the front's where their last argument is 5 (`0x004EAE94`), and the back's otherwise
    /// (`0x004EAE8C`).
    pub fn infoTexture(face: Face) []const u8 {
        return switch (face) {
            .front => "finfo",
            .back => "binfo",
        };
    }
};

/// What the panels are drawn with.
pub const Kit = struct {
    /// `ld_handel.fnt` (`0x00523964`), the title's font.
    title_font: *const hud.Opened,
    /// `handels.fnt` (`0x00523724`), the info panel's.
    info_font: *const hud.Opened,
    /// VFX's palette while the loadout runs: `palette3.tga`'s colour map (`loadout_palette`,
    /// `0x004436B0`).
    palette: *const tga.Palette,
    strings: *const language.Language,

    /// The game's string `id`. The game stops for an id past its strings; OpenReliant draws
    /// nothing for it.
    fn string(kit: Kit, id: u16) []const u8 {
        return kit.strings.string(id) orelse "";
    }
};

/// The title's line, `SHIPS AND LOADOUT`.
const title_string = 0x222;

/// Where the title's line and the ship's name start (`0x00444EBD`, `0x00444EE4`).
const title_at: [2]i32 = .{ 17, 4 };
const name_at: [2]i32 = .{ 17, 28 };

/// `panel_title_draw` (`0x00444D60`): the title panel's texture for `ships[ship]`. `panels`, the
/// pixels of `fpanels.tga` from the top row down, which the game keeps as `SR_TGA_allocate_raw`
/// gives them (`0x00523960`), then `SHIPS AND LOADOUT` and the ship's name in capitals, in the
/// title's font and colours (`tables.title_remap`).
pub fn drawTitle(image: *Image, panels: *const Image, kit: Kit, ship: usize) void {
    image.* = panels.*;
    const pane: hud.Pane = .{ .rgba = image, .size = .{ size, size } };
    const remap: hud.Remap = .{ .table = &tables.title_remap, .palette = kit.palette };
    _ = hud.drawTextInto(pane, kit.title_font, title_at, kit.string(title_string), remap, .left);
    var name: Line = .{};
    name.append(kit.string(tables.ships[ship].name));
    language.upperCase(name.slice());
    _ = hud.drawTextInto(pane, kit.title_font, name_at, name.slice(), remap, .left);
}

/// The labels before the class and the access, `CLASS : ` and `ACCESS : `.
const class_label = 0x554;
const access_label = 0x555;

/// Where the class and the access stand (`0x004450C2`, `0x00445173`).
const class_at: [2]i32 = .{ 2, 12 };
const access_at: [2]i32 = .{ 2, 32 };

/// Where the rows start and how far apart they stand (`0x0044517F`, `0x004452F4`), and where a
/// row's label and its figure start (`0x004451F9`, `0x004452E2`).
const first_row_y = 57;
const row_step = 15;
const label_x = 2;
const figure_x = 180;

/// Where the specials start, and the width, the line height and the most lines they are wrapped
/// to (`0x00445406` to `0x00445423`).
const specials_at: [2]i32 = .{ 2, 180 };
const specials_width = 252;
const specials_line_height = 15;
const specials_lines = 3;

/// What stands between two specials (`0x004E5A1C`).
const specials_separator = ", ";

/// `loadout_draw_stats` (`0x00444F20`): the info panel's texture for `ships[ship]`'s stats, on a
/// clear image, in the info panel's font and colours (`tables.text_remap`). Its class and its
/// access after their labels; its rows (`tables.ship_rows`), each label in capitals and the
/// figure of `figures` beside it, as a number and its suffix or as a bar (`drawBar`); and the
/// specials it has, in capitals, one after another (`specialsLine`).
pub fn drawStats(image: *Image, kit: Kit, ship: usize, figures: tables.ShipFigures) void {
    image.* = @splat(.{ 0, 0, 0, 0 });
    const pane: hud.Pane = .{ .rgba = image, .size = .{ size, size } };
    const remap: hud.Remap = .{ .table = &tables.text_remap, .palette = kit.palette };
    const font = kit.info_font;
    const record = tables.ships[ship];

    var class: Line = .{};
    class.append(kit.string(class_label));
    class.append(kit.string(record.class.string()));
    _ = hud.drawTextInto(pane, font, class_at, class.slice(), remap, .left);
    var access: Line = .{};
    access.append(kit.string(access_label));
    access.append(kit.string(record.access.string()));
    _ = hud.drawTextInto(pane, font, access_at, access.slice(), remap, .left);

    var y: i32 = first_row_y;
    for (tables.ship_rows, figures) |row, figure| {
        defer y += row_step;
        var label: Line = .{};
        label.append(kit.string(row.label));
        language.upperCase(label.slice());
        _ = hud.drawTextInto(pane, font, .{ label_x, y }, label.slice(), remap, .left);
        switch (row.kind) {
            .number => {
                var number: Line = .{};
                number.print("{d}", .{figure});
                number.append(if (row.suffix) |suffix| kit.string(suffix) else "");
                _ = hud.drawTextInto(pane, font, .{ figure_x, y }, number.slice(), remap, .left);
            },
            .bar => drawBar(pane, kit.palette, .{ figure_x, y }, figure),
        }
    }

    var specials = specialsLine(kit, record.specials);
    language.upperCase(specials.slice());
    _ = hud.drawWrappedInto(pane, font, specials_at, specials.slice(), remap, .left, specials_width, specials_line_height, specials_lines);
}

/// The names of the specials of `specials`, in their bits' order, `specials_separator` between
/// each and the next (`0x0044530B` to `0x004453DC`).
fn specialsLine(kit: Kit, specials: tables.Specials) Line {
    var line: Line = .{};
    var first = true;
    for (tables.special_names, 0..) |name, bit| {
        if (!specials.has(@intCast(bit))) continue;
        if (!first) line.append(specials_separator);
        first = false;
        line.append(kit.string(name));
    }
    return line;
}

/// The segments of a bar: how many, how far apart from the left of one to the next
/// (`0x0044526E`), and how far a segment's right edge and foot lie from its corner
/// (`0x0044524A`, `0x0044524F`).
const segment_count = 10;
const segment_step = 7;
const segment_right = 4;
const segment_foot = 10;

/// A row's figure as a bar from `at` (`0x00445216` to `0x00445278`): `segment_count` segments,
/// the first `figure` of them filled and the rest outlined (`drawSegment`), in the bars' colour
/// (`tables.bar_colour`).
fn drawBar(pane: hud.Pane, palette: *const tga.Palette, at: [2]i32, figure: i32) void {
    const colour = palette[tables.bar_colour];
    for (0..segment_count) |index| {
        const left = at[0] + @as(i32, @intCast(index)) * segment_step;
        const filled = figure >= @as(i32, @intCast(index)) + 1;
        drawSegment(pane, colour, .{ left, at[1] }, .{ left + segment_right, at[1] + segment_foot }, filled);
    }
}

/// `0x00445B20`: a segment of a bar in `colour`, from the corner `from` to the corner `to`, the
/// columns of both taken, as `VFX_line_draw` draws its lines. Filled, it is a line along each row
/// from `from`'s down to the one above `to`'s; outlined, a line round its four sides, the rows of
/// both corners taken.
fn drawSegment(pane: hud.Pane, colour: [3]u8, from: [2]i32, to: [2]i32, filled: bool) void {
    if (filled) {
        var y = from[1];
        while (y < to[1]) : (y += 1) pane.line(colour, .{ from[0], y }, .{ to[0], y });
        return;
    }
    pane.line(colour, from, .{ to[0], from[1] });
    pane.line(colour, .{ to[0], from[1] }, to);
    pane.line(colour, to, .{ from[0], to[1] });
    pane.line(colour, .{ from[0], to[1] }, from);
}

/// A line of text put together from the game's strings, as the game puts its lines together with
/// `strcpy`, `strcat` and `sprintf`. What does not fit is left off, where the game's buffers
/// overrun; the shipped strings fit several times over.
const Line = struct {
    buffer: [room]u8 = undefined,
    len: usize = 0,

    const room = hud.wrapped_line_room;

    fn append(line: *Line, text: []const u8) void {
        const kept = text[0..@min(text.len, room - line.len)];
        @memcpy(line.buffer[line.len..][0..kept.len], kept);
        line.len += kept.len;
    }

    fn print(line: *Line, comptime format: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(line.buffer[line.len..], format, args) catch return;
        line.len += written.len;
    }

    fn slice(line: *Line) []u8 {
        return line.buffer[0..line.len];
    }
};

/// A font for the tests in which every code is the same glyph: two pixels wide and two tall,
/// levels 15 and 1 over 0 and 15.
fn testFont() []const u8 {
    const count = 256;
    const header: @import("../../../formats/fnt.zig").Header = .{ .version = "2.\x00\x00".*, .count = count, .height = 2, ._unknown_0c = 0 };
    const table: [count]u32 = @splat(@sizeOf(@TypeOf(header)) + count * @sizeOf(u32));
    const glyph = std.mem.toBytes(@as(u32, 2)) ++ [_]u8{ 15, 1, 0, 15 };
    return std.mem.toBytes(header) ++ std.mem.sliceAsBytes(&table) ++ glyph;
}

/// The strings of the tests: those the panels draw, each its own English.
fn testStrings(buffer: *[0x555][]const u8) language.Language {
    buffer.* = @splat("");
    const strings = [_]struct { u16, []const u8 }{
        .{ title_string, "SHIPS AND LOADOUT" }, .{ 0x1F7, "Predator" },        .{ 0x201, "Shroud" },
        .{ class_label, "CLASS : " },           .{ access_label, "ACCESS :" }, .{ 0x223, "LIGHT" },
        .{ 0x229, "BRONZE" },                   .{ 0x21C, " SECS" },           .{ 0x1EF, "Reverse Thrust" },
        .{ 0x1F3, "Spectral Shields" },         .{ 0x1F4, "Blind Fire" },      .{ 0x1F5, "Cloaking Device" },
        .{ 0x20E, "Max Speed" },
    };
    for (strings) |entry| buffer[entry[0] - 1] = entry[1];
    return .{ .strings = buffer };
}

/// A palette for the tests, entry `i` of which is `(i, 255 - i, 7)`.
fn testPalette() tga.Palette {
    var palette: tga.Palette = undefined;
    for (&palette, 0..) |*entry, i| entry.* = .{ @intCast(i), @intCast(255 - i), 7 };
    return palette;
}

fn colourOf(palette: *const tga.Palette, entry: u8) [4]u8 {
    return .{ palette[entry][0], palette[entry][1], palette[entry][2], hud.Pane.opaque_alpha };
}

test drawTitle {
    const font = try @import("../../../formats/fnt.zig").Font.parse(comptime testFont());
    const opened: hud.Opened = .open(font, null);
    const palette = testPalette();
    var buffer: [0x555][]const u8 = undefined;
    const strings = testStrings(&buffer);
    const kit: Kit = .{ .title_font = &opened, .info_font = &opened, .palette = &palette, .strings = &strings };

    const panels = try std.testing.allocator.create(Image);
    defer std.testing.allocator.destroy(panels);
    panels.* = @splat(.{ 1, 2, 3, 4 });
    const image = try std.testing.allocator.create(Image);
    defer std.testing.allocator.destroy(image);
    drawTitle(image, panels, kit, 0);

    // The title's letters' tops in black, their edges bright, and the panel's own pixels where
    // they are clear.
    try std.testing.expectEqual(colourOf(&palette, 0), image[title_at[1] * size + title_at[0]]);
    try std.testing.expectEqual(colourOf(&palette, 0xB8), image[title_at[1] * size + title_at[0] + 1]);
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, image[(title_at[1] + 1) * size + title_at[0]]);
    // The name, `PREDATOR`: eight letters.
    const name_end = name_at[0] + 8 * 2;
    try std.testing.expectEqual(colourOf(&palette, 0), image[name_at[1] * size + name_end - 2]);
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, image[name_at[1] * size + name_end]);
}

test drawStats {
    const font = try @import("../../../formats/fnt.zig").Font.parse(comptime testFont());
    const opened: hud.Opened = .open(font, null);
    const palette = testPalette();
    var buffer: [0x555][]const u8 = undefined;
    const strings = testStrings(&buffer);
    const kit: Kit = .{ .title_font = &opened, .info_font = &opened, .palette = &palette, .strings = &strings };

    const image = try std.testing.allocator.create(Image);
    defer std.testing.allocator.destroy(image);
    image.* = @splat(.{ 9, 9, 9, 9 });
    drawStats(image, kit, 0, .{ 6, 6, 10, 5, 3, 5, 100, 2 });
    const top = colourOf(&palette, tables.text_remap[15]);
    const bar = colourOf(&palette, tables.bar_colour);
    const clear: [4]u8 = .{ 0, 0, 0, 0 };

    // The class, `CLASS : LIGHT`, 13 letters from its corner, on a clear image.
    try std.testing.expectEqual(top, image[class_at[1] * size + class_at[0]]);
    try std.testing.expectEqual(top, image[class_at[1] * size + class_at[0] + 12 * 2]);
    try std.testing.expectEqual(clear, image[class_at[1] * size + class_at[0] + 13 * 2]);
    // The first row's label, and its bar: six segments filled, the seventh outlined.
    try std.testing.expectEqual(top, image[first_row_y * size + label_x]);
    const row = first_row_y * size;
    try std.testing.expectEqual(bar, image[row + figure_x]);
    try std.testing.expectEqual(bar, image[row + 3 * size + figure_x + 5 * segment_step + 2]);
    try std.testing.expectEqual(clear, image[row + segment_foot * size + figure_x + 5 * segment_step + 2]);
    try std.testing.expectEqual(bar, image[row + figure_x + 6 * segment_step]);
    try std.testing.expectEqual(clear, image[row + 3 * size + figure_x + 6 * segment_step + 2]);
    try std.testing.expectEqual(bar, image[row + segment_foot * size + figure_x + 6 * segment_step + 2]);
    try std.testing.expectEqual(bar, image[row + 3 * size + figure_x + 9 * segment_step + segment_right]);
    try std.testing.expectEqual(clear, image[row + figure_x + 9 * segment_step + segment_right + 1]);
    // The afterburner fuel as a number and its seconds, `100 SECS`: eight letters.
    const fuel = (first_row_y + 6 * row_step) * size + figure_x;
    try std.testing.expectEqual(top, image[fuel + 7 * 2]);
    try std.testing.expectEqual(clear, image[fuel + 8 * 2]);
    // The Predator's one special.
    try std.testing.expectEqual(top, image[specials_at[1] * size + specials_at[0] + 9 * 2]);
    try std.testing.expectEqual(clear, image[specials_at[1] * size + specials_at[0] + 10 * 2]);
}

test specialsLine {
    var buffer: [0x555][]const u8 = undefined;
    const strings = testStrings(&buffer);
    const palette = testPalette();
    const font = try @import("../../../formats/fnt.zig").Font.parse(comptime testFont());
    const opened: hud.Opened = .open(font, null);
    const kit: Kit = .{ .title_font = &opened, .info_font = &opened, .palette = &palette, .strings = &strings };
    var line = specialsLine(kit, tables.ships[10].specials);
    try std.testing.expectEqualStrings("Reverse Thrust, Spectral Shields, Blind Fire, Cloaking Device", line.slice());
    var none = specialsLine(kit, tables.ships[2].specials);
    try std.testing.expectEqualStrings("", none.slice());
}

test Face {
    try std.testing.expectEqualStrings("fpanels", Face.front.titleTexture());
    try std.testing.expectEqualStrings("binfo", Face.back.infoTexture());
}
