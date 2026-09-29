//! The loadout's panels as their textures are drawn: the title over the page, with the chosen
//! ship's name, and the info panel with the ship's stats, a missile's, or the ship's guns. The game
//! makes each a texture of `size` by `size` pixels and writes its text into it through a VFX pane
//! (`hud.Pane`), and the scene shows it on one face of a two-sided panel (`Face`).

const std = @import("std");

const tga = @import("../../../formats/tga.zig");
const hud = @import("../../game/hud.zig");
const language = @import("../../game/language.zig");
const bars = @import("bars.zig");
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

    /// The info panel's texture: `loadout_draw_stats`, `missile_info_draw` and `guns_draw` name
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

    /// The game's string `id` in capitals, as the panels write their names, labels and
    /// descriptions (`CharUpperBuffA`, `language.upperCase`).
    fn capitals(kit: Kit, id: u16) Line {
        var line: Line = .{};
        line.append(kit.string(id));
        language.upperCase(line.slice());
        return line;
    }
};

/// The info panel's texture as each of its pages begins it (`loadout_draw_stats`,
/// `missile_info_draw`, `guns_draw`): its image cleared, and written through a pane in the info
/// panel's font and colours (`tables.text_remap`).
const InfoPage = struct {
    kit: Kit,
    pane: hud.Pane,
    remap: hud.Remap,

    fn begin(image: *Image, kit: Kit) InfoPage {
        image.* = @splat(.{ 0, 0, 0, 0 });
        return .{
            .kit = kit,
            .pane = .{ .rgba = image, .size = .{ size, size } },
            .remap = .{ .table = &tables.text_remap, .palette = kit.palette },
        };
    }

    /// `text` from `at`, aligned as `alignment` says (`hud_text`).
    fn write(page: InfoPage, at: [2]i32, text: []const u8, alignment: hud.Align) void {
        _ = hud.drawTextInto(page.pane, page.kit.info_font, at, text, page.remap, alignment);
    }

    /// `text` from `at`, broken into lines at most `width` wide, `line_height` apart, at most
    /// `max_lines` of them (`hud_text_wrapped`); returns how many it took.
    fn wrap(page: InfoPage, at: [2]i32, text: []const u8, width: i32, line_height: i32, max_lines: usize) usize {
        return hud.drawWrappedInto(page.pane, page.kit.info_font, at, text, page.remap, .left, width, line_height, max_lines);
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
    var name = kit.capitals(tables.ships[ship].name);
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
    const page: InfoPage = .begin(image, kit);
    const record = tables.ships[ship];

    var class: Line = .{};
    class.append(kit.string(class_label));
    class.append(kit.string(record.class.string()));
    page.write(class_at, class.slice(), .left);
    var access: Line = .{};
    access.append(kit.string(access_label));
    access.append(kit.string(record.access.string()));
    page.write(access_at, access.slice(), .left);

    var y: i32 = first_row_y;
    for (tables.ship_rows, figures) |row, figure| {
        drawRow(page, y, row, figure);
        y += row_step;
    }

    var specials = specialsLine(kit, record.specials);
    language.upperCase(specials.slice());
    _ = page.wrap(specials_at, specials.slice(), specials_width, specials_line_height, specials_lines);
}

/// A row of figures at `y` (`loadout_draw_stats`, `0x00445180` to `0x004452F4`;
/// `missile_info_draw`, `0x0044593B` to `0x00445ADE`): its label in capitals, and beside it the
/// figure, as a number and its suffix or as a bar (`drawBar`), or a dash where there is none.
fn drawRow(page: InfoPage, y: i32, row: tables.Row, figure: ?i32) void {
    const kit = page.kit;
    var label = kit.capitals(row.label);
    page.write(.{ label_x, y }, label.slice(), .left);
    const shown = figure orelse return page.write(.{ figure_x, y }, no_figure, .left);
    switch (row.kind) {
        .number => {
            var number: Line = .{};
            number.print("{d}", .{shown});
            number.append(if (row.suffix) |suffix| kit.string(suffix) else "");
            page.write(.{ figure_x, y }, number.slice(), .left);
        },
        .bar => drawBar(page.pane, kit.palette, .{ figure_x, y }, shown),
    }
}

/// What a row shows for a figure its missile lacks (`0x004EAEB4`).
const no_figure = "-";

/// Where a missile's name and its description start, and the width, the line height and the most
/// lines the description is wrapped to (`0x00445839`, `0x004458BA`, `0x004458A4` to
/// `0x004458A8`).
const missile_name_at: [2]i32 = .{ 2, 12 };
const description_at: [2]i32 = .{ 2, 32 };
const description_width = 252;
const description_line_height = 15;
const description_lines = 6;

/// Where a missile's rows start (`0x0044592E`).
const missile_first_row_y = 127;

/// The two lines under a missile's rows, `CLICK MISSILE` and `TO ATTACH TO SHIP`, and where each is
/// centred (`0x004458C6`, `0x004458F6`).
const click_lines = [2]u16{ 0x220, 0x221 };
const click_at = [2][2]i32{ .{ 128, 195 }, .{ 128, 210 } };

/// `missile_info_draw` (`0x004456F0`): the info panel's texture for `missile`, on a clear image,
/// in the info panel's font and colours (`tables.text_remap`): its name and its description in
/// capitals, the description wrapped; `CLICK MISSILE` and `TO ATTACH TO SHIP` centred low down;
/// and its rows (`tables.missile_rows`), each with its figure of `figures`, or a dash for a figure
/// of -1 and for every row of the fuel pod (`0x004459B2`).
pub fn drawMissile(image: *Image, kit: Kit, missile: tables.Missile, figures: tables.MissileFigures) void {
    const page: InfoPage = .begin(image, kit);
    const record = missile.record();

    var name = kit.capitals(record.name);
    page.write(missile_name_at, name.slice(), .left);
    var description = kit.capitals(record.description);
    _ = page.wrap(description_at, description.slice(), description_width, description_line_height, description_lines);
    for (click_lines, click_at) |line, at| page.write(at, kit.string(line), .centre);

    var y: i32 = missile_first_row_y;
    for (tables.missile_rows, figures) |row, figure| {
        const value: ?i32 = if (missile == .fuel_pod) null else if (row.dash_for_none) bars.MissileBars.shown(figure) else figure;
        drawRow(page, y, row, value);
        y += row_step;
    }
}

/// Where each gun's line starts and how far below it the next thing starts (`0x004455E9`,
/// `0x004455F3`); the width, the line height and the most lines a gun's description is wrapped
/// to, and the room under it (`0x00445677` to `0x0044567B`, `0x0044569B`).
const gun_x = 2;
const gun_step = 20;
const gun_description_width = 252;
const gun_description_line_height = 15;
const gun_description_lines = 20;
const gun_description_gap = 10;

/// What ends the description of a gun that drains no energy (`0x004EAEA8`).
const no_drain = ",";

/// `guns_draw` (`0x00445490`): the info panel's texture for `ships[ship]`'s guns, on a clear image,
/// in the info panel's font and colours (`tables.text_remap`), from the top down: for each kind of
/// its guns, its name and how many the ship has in capitals (`%s X %d`, `0x004EAEAC`), and under
/// it, but for a rear turret (`tables.first_rear_turret` on), its description wrapped: its power,
/// kind, range, rate and drain run together (`%s%s%s%s%s`, `0x004EAE9C`), in the strings' own
/// case.
pub fn drawGuns(image: *Image, kit: Kit, ship: usize) void {
    const page: InfoPage = .begin(image, kit);
    var y: i32 = 0;
    for (tables.ships[ship].guns) |mount| {
        var line: Line = .{};
        line.print("{s} X {d}", .{ kit.string(mount.gun), mount.count });
        language.upperCase(line.slice());
        page.write(.{ gun_x, y }, line.slice(), .left);
        y += gun_step;
        const description = tables.gunDescription(mount.gun) orelse continue;
        var sentence: Line = .{};
        for ([_]u16{ description.power, description.kind, description.range, description.rate }) |part| sentence.append(kit.string(part));
        sentence.append(if (description.drain) |drain| kit.string(drain) else no_drain);
        const lines = page.wrap(.{ gun_x, y }, sentence.slice(), gun_description_width, gun_description_line_height, gun_description_lines);
        y += @as(i32, @intCast(lines)) * gun_description_line_height + gun_description_gap;
    }
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
        .{ 0x20E, "Max Speed" },                .{ 0x205, "Havok" },           .{ 0x1E7, "A big one" },
        .{ 0x220, "CLICK MISSILE" },            .{ 0x218, "Locking Time" },    .{ 0x219, "Speed" },
        .{ 0x23B, "Laser" },                    .{ 0x54E, "Rear" },            .{ 0x244, "ab" },
        .{ 0x24F, "cd" },                       .{ 0x247, "e" },               .{ 0x249, "f" },
        .{ 0x24D, "g" },
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

test drawMissile {
    const font = try @import("../../../formats/fnt.zig").Font.parse(comptime testFont());
    const opened: hud.Opened = .open(font, null);
    const palette = testPalette();
    var buffer: [0x555][]const u8 = undefined;
    const strings = testStrings(&buffer);
    const kit: Kit = .{ .title_font = &opened, .info_font = &opened, .palette = &palette, .strings = &strings };
    const image = try std.testing.allocator.create(Image);
    defer std.testing.allocator.destroy(image);
    const top = colourOf(&palette, tables.text_remap[15]);
    const bar = colourOf(&palette, tables.bar_colour);
    const clear: [4]u8 = .{ 0, 0, 0, 0 };

    drawMissile(image, kit, .havoc, .{ 2, 5, 6, 4 });
    // Its name, `HAVOK`, five letters from its corner.
    const name = missile_name_at[1] * size + missile_name_at[0];
    try std.testing.expectEqual(top, image[name + 4 * 2]);
    try std.testing.expectEqual(clear, image[name + 5 * 2]);
    // `CLICK MISSILE`, thirteen letters, centred.
    const click = click_at[0][1] * size + click_at[0][0];
    try std.testing.expectEqual(top, image[click - 13]);
    try std.testing.expectEqual(clear, image[click - 14]);
    // The locking time in seconds, `2 SECS`, and the speed's bar, five segments filled.
    const locking = missile_first_row_y * size + figure_x;
    try std.testing.expectEqual(top, image[locking + 5 * 2]);
    try std.testing.expectEqual(clear, image[locking + 6 * 2]);
    const speed = (missile_first_row_y + row_step + 3) * size + figure_x;
    try std.testing.expectEqual(bar, image[speed + 4 * segment_step + 2]);
    try std.testing.expectEqual(clear, image[speed + 5 * segment_step + 2]);

    // The fuel pod's rows are dashes, whatever its figures.
    drawMissile(image, kit, .fuel_pod, .{ 2, 5, 6, 4 });
    try std.testing.expectEqual(top, image[locking]);
    try std.testing.expectEqual(clear, image[locking + 2]);
    try std.testing.expectEqual(clear, image[speed + 2]);
}

test drawGuns {
    const font = try @import("../../../formats/fnt.zig").Font.parse(comptime testFont());
    const opened: hud.Opened = .open(font, null);
    const palette = testPalette();
    var buffer: [0x555][]const u8 = undefined;
    const strings = testStrings(&buffer);
    const kit: Kit = .{ .title_font = &opened, .info_font = &opened, .palette = &palette, .strings = &strings };
    const image = try std.testing.allocator.create(Image);
    defer std.testing.allocator.destroy(image);
    image.* = @splat(.{ 9, 9, 9, 9 });
    const top = colourOf(&palette, tables.text_remap[15]);
    const clear: [4]u8 = .{ 0, 0, 0, 0 };

    // The Predator's guns: two lasers, `LASER X 2`, nine letters at the top, on a clear image.
    drawGuns(image, kit, 0);
    try std.testing.expectEqual(top, image[gun_x + 8 * 2]);
    try std.testing.expectEqual(clear, image[gun_x + 9 * 2]);
    // Their description, one line of seven letters.
    const description = gun_step * size + gun_x;
    try std.testing.expectEqual(top, image[description + 6 * 2]);
    try std.testing.expectEqual(clear, image[description + 7 * 2]);
    // Then the rear turret, `REAR X 1`, with no description under it.
    const turret = (gun_step + gun_description_line_height + gun_description_gap) * size + gun_x;
    try std.testing.expectEqual(top, image[turret + 7 * 2]);
    try std.testing.expectEqual(clear, image[turret + 8 * 2]);
    try std.testing.expectEqual(clear, image[turret + gun_step * size]);
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
