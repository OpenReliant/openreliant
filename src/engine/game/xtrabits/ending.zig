//! The story's end (`xtrabits.cpp`), which `WinMain` comes to after the campaign's last mission,
//! once its end briefing is over (`0x004AA6F2` on): the movies of how the war ended
//! (`ending_movies_play`, `0x004AC620`), then the credits (`credits_play`, `0x004AC780`). Then
//! `WinMain` puts the campaign back at its first mission (`0x004AA6FC`) and goes back to the main
//! menu.

const std = @import("std");

const input = @import("../../input.zig");
const vm = @import("../../vm.zig");
const gameobj = @import("../gameobj.zig");
const hud = @import("../hud.zig");
const canvas_module = @import("../interface/canvas.zig");
const Canvas = canvas_module.Canvas;
const Label = canvas_module.Label;
const disc = @import("../interface/disc.zig");
const landing = @import("landing.zig");

/// The movies `ending_movies_play` plays, from the first disc's archive, which holds them alone:
/// `first` on a cleared screen (`movie.Kind.cleared_from_disc`), then each of the news reports
/// after the news' transition (`landing.news_transition`), and the transition and `last`, each over
/// the screen (`movie.Kind.over_screen_from_disc`).
pub const Movies = struct {
    reports: landing.Reports,

    pub const source: disc.Number = .one;
    pub const first = "new_chapter6_thread1.bik";
    pub const last = "new_chapter6.bik";
};

/// The news reports of the story's end (`0x004AC64B` on), by the campaign's flags: Kulov's and
/// Ivan Petrov's where they died, and one of Steiner's two, by whether he lives.
pub fn movies(variables: *const vm.Variables) Movies {
    var reports: landing.Reports = .{};
    if (variables.kulov_alive != 1) reports.append("new_chapter6_thread2.bik");
    if (variables.ivan_petrov_alive != 1) reports.append("new_chapter6_thread3.bik");
    reports.append(if (variables.steiner_alive == 1) "new_chapter6_thread5.bik" else "new_chapter6_thread4.bik");
    return .{ .reports = reports };
}

/// The credits' pictures (`0x0050A7EC`) and their music (`0x0050A7D8`), which plays over and over
/// at level 127 (`music_play`). As the credits end, the music fades out by `music_fade_step`
/// (`music_fade_out`), and they wait for it to stop. Their text is in the menus' small font.
pub const shapes_name = "credits.spr";
pub const music_name = "music\\new_sim07.wav";
pub const music_level = 0x7F;
pub const music_fade_step = 15;

/// How many pages the credits show.
const page_count = 8;

/// How long a page shows from when it starts to fade in, and how long it takes to fade out, in game
/// ticks (`0x004AC874`, `0x004AC8C7`).
const standing_ticks = 750;
const fading_ticks = 150;

/// How much brighter a page grows as it fades in, and darker as it fades out, up to full and down
/// to dark (`0x004DC754`).
///
/// **Improvement:** the game takes a step each frame, so that the credits fade the faster the
/// higher the frame rate. OpenReliant takes one for each of the simulation's steps, 25 a second,
/// as the game does at 25 frames a second.
const fade_step: f32 = 0.03;

/// Each page's picture in `credits.spr`, and the block whose palette it's drawn through
/// (`credits_draw`, `0x004ACA9C`, `0x004ACAD5`).
const pictures = [page_count]u8{ 1, 3, 5, 7, 9, 1, 3, 11 };
const palettes = [page_count]u8{ 0, 2, 4, 6, 8, 0, 2, 10 };

/// The colours of the credits' lines (`interface_palette_ramp`, `0x004ACB11`): the headings
/// orange, the names white.
const Colour = enum {
    orange,
    white,

    fn rgb(colour: Colour) [3]f32 {
        return switch (colour) {
            .orange => orange,
            .white => canvas_module.white,
        };
    }
};

const orange = hud.rgb(0xFF7E00);

/// A line of the credits: a string of the game's, where it stands, and its colour. A line at x 0
/// is centred across the screen (`0x004ACB2A`).
const Line = struct {
    string: u16,
    at: [2]i16,
    colour: Colour,

    fn of(string: u16, x: i16, y: i16, colour: Colour) Line {
        return .{ .string = string, .at = .{ x, y }, .colour = colour };
    }

    fn label(line: Line) Label {
        if (line.at[0] == 0) return .of(line.string, .{ centre_x, line.at[1] }, .centre);
        return .of(line.string, .{ line.at[0], line.at[1] }, .left);
    }
};

/// Where a centred line stands across the screen: its middle (`0x004ACB52`).
const centre_x = canvas_module.size[0] / 2;

/// Each page's lines (`credits_lines`, `0x0050A180`, counted at `0x0050A170`).
const pages = [page_count][]const Line{
    &.{
        .of(1135, 81, 53, .orange),
        .of(1136, 95, 66, .white),
        .of(1137, 81, 93, .orange),
        .of(1138, 95, 109, .white),
        .of(1139, 81, 131, .orange),
        .of(1140, 95, 144, .white),
        .of(1141, 95, 157, .white),
        .of(1142, 95, 170, .white),
        .of(1143, 81, 196, .orange),
        .of(1144, 95, 209, .white),
        .of(1145, 95, 222, .white),
        .of(1146, 95, 235, .white),
        .of(1147, 95, 248, .white),
        .of(1148, 95, 261, .white),
        .of(1149, 95, 274, .white),
        .of(1150, 95, 287, .white),
        .of(1151, 95, 300, .white),
        .of(1152, 81, 326, .orange),
        .of(1153, 95, 339, .white),
        .of(1154, 81, 365, .orange),
        .of(1155, 95, 378, .white),
        .of(1156, 95, 391, .white),
        .of(1157, 95, 404, .white),
        .of(1158, 95, 417, .white),
    },
    &.{
        .of(1159, 80, 92, .orange),
        .of(1160, 95, 105, .white),
        .of(1161, 80, 131, .orange),
        .of(1162, 95, 144, .white),
        .of(1163, 95, 157, .white),
        .of(1164, 80, 183, .orange),
        .of(1165, 95, 196, .white),
        .of(1166, 95, 209, .white),
        .of(1167, 95, 222, .white),
        .of(1168, 80, 247, .orange),
        .of(1169, 95, 261, .white),
        .of(1170, 95, 274, .white),
        .of(1171, 80, 300, .orange),
        .of(1172, 95, 313, .white),
        .of(1173, 95, 326, .white),
        .of(1174, 95, 338, .white),
        .of(1175, 95, 352, .white),
        .of(1176, 95, 365, .white),
        .of(1177, 95, 378, .white),
    },
    &.{
        .of(1178, 80, 68, .orange),
        .of(1179, 96, 81, .white),
        .of(1180, 96, 94, .white),
        .of(1181, 96, 107, .white),
        .of(1182, 96, 120, .white),
        .of(1183, 96, 133, .white),
        .of(1184, 96, 146, .white),
        .of(1185, 96, 159, .white),
        .of(1186, 96, 172, .white),
        .of(1187, 80, 198, .orange),
        .of(1188, 96, 211, .orange),
        .of(1189, 96, 224, .white),
        .of(1190, 96, 243, .white),
        .of(1191, 80, 269, .orange),
        .of(1192, 96, 282, .white),
        .of(1193, 96, 295, .white),
        .of(1194, 80, 321, .orange),
        .of(1195, 96, 334, .white),
        .of(1196, 96, 347, .white),
        .of(1197, 96, 360, .white),
        .of(1198, 96, 373, .white),
        .of(1199, 96, 386, .white),
        .of(1200, 96, 398, .white),
    },
    &.{
        .of(1201, 80, 95, .orange),
        .of(1202, 95, 108, .orange),
        .of(1203, 95, 121, .white),
        .of(1204, 95, 140, .white),
        .of(1205, 95, 153, .white),
        .of(1206, 95, 166, .white),
        .of(1207, 95, 179, .white),
        .of(1208, 95, 192, .white),
        .of(1209, 95, 205, .white),
        .of(1210, 95, 218, .white),
        .of(1211, 95, 231, .white),
        .of(1212, 95, 244, .white),
        .of(1213, 95, 257, .white),
        .of(1214, 95, 270, .white),
        .of(1215, 95, 283, .white),
        .of(1216, 95, 296, .white),
        .of(1217, 80, 322, .orange),
        .of(1218, 95, 335, .white),
        .of(1468, 95, 348, .white),
        .of(1219, 80, 374, .orange),
        .of(1220, 95, 387, .white),
    },
    &.{
        .of(1221, 80, 66, .orange),
        .of(1222, 94, 79, .orange),
        .of(1223, 94, 92, .white),
        .of(1224, 94, 111, .white),
        .of(1225, 94, 124, .white),
        .of(1226, 94, 137, .white),
        .of(1227, 94, 150, .white),
        .of(1228, 80, 176, .orange),
        .of(1229, 94, 189, .orange),
        .of(1230, 94, 202, .white),
        .of(1231, 94, 221, .white),
        .of(1232, 94, 234, .white),
        .of(1233, 94, 247, .white),
        .of(1234, 94, 260, .white),
        .of(1235, 94, 273, .white),
        .of(1236, 94, 286, .white),
        .of(1470, 80, 312, .orange),
        .of(1237, 94, 325, .white),
        .of(1238, 94, 338, .white),
        .of(1469, 94, 351, .white),
        .of(1240, 80, 377, .orange),
        .of(1241, 94, 389, .white),
        .of(1242, 94, 403, .white),
        .of(1243, 94, 416, .white),
        .of(1244, 94, 430, .white),
        .of(1404, 94, 443, .white),
        .of(1471, 94, 456, .white),
    },
    &.{
        .of(1472, 80, 68, .orange),
        .of(1473, 96, 81, .white),
        .of(1474, 96, 94, .white),
        .of(1475, 96, 107, .white),
        .of(1476, 96, 120, .white),
        .of(1477, 96, 133, .white),
        .of(1478, 96, 146, .white),
        .of(1479, 96, 159, .white),
        .of(1480, 96, 172, .white),
        .of(1481, 96, 185, .white),
        .of(1482, 96, 198, .white),
        .of(1483, 96, 211, .white),
        .of(1484, 80, 237, .orange),
        .of(1485, 96, 250, .white),
        .of(1486, 80, 276, .orange),
        .of(1487, 96, 289, .white),
        .of(1488, 80, 315, .orange),
        .of(1489, 96, 328, .white),
        .of(1490, 80, 354, .orange),
        .of(1491, 96, 367, .white),
        .of(1492, 80, 393, .orange),
        .of(1493, 96, 406, .white),
        .of(1494, 96, 419, .white),
    },
    &.{
        .of(1495, 80, 68, .orange),
        .of(1496, 96, 81, .white),
        .of(1497, 96, 94, .white),
        .of(1498, 80, 120, .orange),
        .of(1499, 96, 133, .white),
        .of(1500, 96, 146, .white),
        .of(1501, 96, 159, .white),
        .of(1502, 96, 172, .white),
        .of(1503, 96, 185, .white),
        .of(1504, 96, 198, .white),
        .of(1505, 96, 211, .white),
        .of(1506, 96, 224, .white),
        .of(1507, 96, 237, .white),
        .of(1508, 96, 250, .white),
        .of(1509, 96, 263, .white),
        .of(1510, 96, 279, .white),
        .of(1511, 96, 292, .white),
        .of(1512, 80, 318, .orange),
        .of(1513, 96, 331, .white),
        .of(1514, 96, 344, .white),
        .of(1515, 96, 357, .white),
        .of(1516, 96, 370, .white),
        .of(1517, 80, 396, .orange),
        .of(1518, 96, 409, .white),
        .of(1519, 80, 435, .orange),
        .of(1520, 96, 448, .white),
    },
    &.{
        .of(1400, 0, 66, .white),
        .of(1401, 0, 79, .white),
        .of(1402, 0, 105, .white),
        .of(1403, 0, 118, .white),
        .of(1405, 0, 144, .white),
        .of(1458, 0, 170, .white),
        .of(1459, 0, 196, .white),
    },
};

/// The credits as they play, in 16 steps (`0x004AC8A0` on): on each even step a page fades in and
/// stays, and on each odd step it fades out.
pub const Credits = struct {
    step: u8 = 0,
    /// How bright the page is drawn (`credits_brightness`, `0x005D6B34`).
    brightness: f32 = 0,
    /// The game tick the step ends after.
    until: u32 = 0,
    /// The tick the simulation's steps are paced from (`gameobj.stepsDue`).
    paced_at: i32 = 0,

    const steps = 2 * page_count;

    /// The credits as they begin at game tick `now`, the first page fading in.
    pub fn begin(now: u32) Credits {
        return .{ .until = now + standing_ticks, .paced_at = @bitCast(now) };
    }

    /// A pass of the credits' loop at game tick `now`: false once they're over, after the last page
    /// has faded out or Escape was pressed. A page fades in and stays until its time is up, then
    /// fades out over `fading_ticks` and gives way to the next.
    pub fn frame(credits: *Credits, keyboard: *input.Keyboard, now: u32) bool {
        if (credits.step >= steps) return false;
        const escaped = keyboard.pressed(input.scan.escape, .none, true);
        const faded = @as(f32, @floatFromInt(gameobj.stepsDue(&credits.paced_at, @bitCast(now)))) * fade_step;
        const fading_in = credits.step % 2 == 0;
        if (credits.until < now) {
            credits.until = now + @as(u32, if (fading_in) fading_ticks else standing_ticks);
            credits.step += 1;
        } else if (fading_in) {
            credits.brightness = @min(credits.brightness + faded, 1);
        } else {
            credits.brightness = @max(credits.brightness - faded, 0);
        }
        return !escaped;
    }

    /// The page shown (`credits_page`, `0x005D6C94`).
    pub fn page(credits: Credits) usize {
        return @min(credits.step / 2, page_count - 1);
    }

    /// `credits_draw` (`0x004AC9A0`), over a cleared frame at the credits' brightness: the page's
    /// picture through its own palette, then its lines in the menus' small font.
    pub fn draw(credits: Credits, canvas: Canvas, shapes: *canvas_module.Shapes) canvas_module.Error!void {
        const shown = credits.page();
        shapes.usePalette(palettes[shown]);
        var faded = canvas;
        faded.brightness = credits.brightness;
        try faded.shape(&shapes.art, pictures[shown], .{ 0, 0 });
        for (pages[shown]) |line| try line.label().write(faded, faded.fonts.small, line.colour.rgb());
    }
};

test movies {
    var variables: vm.Variables = .{};
    // Kulov and Petrov alive, Steiner dead: Steiner's death alone.
    variables.kulov_alive = 1;
    variables.ivan_petrov_alive = 1;
    try std.testing.expectEqualStrings("new_chapter6_thread4.bik", movies(&variables).reports.slice()[0]);
    try std.testing.expectEqual(1, movies(&variables).reports.count);
    // All three reports, Steiner alive.
    variables = .{ .steiner_alive = 1 };
    const all = movies(&variables).reports;
    try std.testing.expectEqualStrings("new_chapter6_thread2.bik", all.slice()[0]);
    try std.testing.expectEqualStrings("new_chapter6_thread3.bik", all.slice()[1]);
    try std.testing.expectEqualStrings("new_chapter6_thread5.bik", all.slice()[2]);
}

test Credits {
    var keyboard: input.Keyboard = .{};
    var credits: Credits = .begin(1000);
    // A page fades in by a step each 4 ticks, up to full, and stands until its time is up.
    try std.testing.expect(credits.frame(&keyboard, 1040));
    try std.testing.expectApproxEqAbs(10 * fade_step, credits.brightness, 1e-6);
    try std.testing.expect(credits.frame(&keyboard, 1700));
    try std.testing.expectEqual(1, credits.brightness);
    // Then it fades out, and the next page fades in.
    try std.testing.expect(credits.frame(&keyboard, 1751));
    try std.testing.expectEqual(1, credits.step);
    try std.testing.expect(credits.frame(&keyboard, 1791));
    try std.testing.expectApproxEqAbs(1 - 10 * fade_step, credits.brightness, 1e-6);
    try std.testing.expect(credits.frame(&keyboard, 1902));
    try std.testing.expectEqual(1, credits.page());
    // The last page fades out, and the credits are over.
    var now: u32 = 1902;
    while (credits.frame(&keyboard, now)) now += 100;
    try std.testing.expectEqual(Credits.steps, credits.step);
    try std.testing.expectEqual(page_count - 1, credits.page());
    // Escape ends them at once.
    credits = .begin(0);
    keyboard.down[input.scan.escape] = true;
    try std.testing.expect(!credits.frame(&keyboard, 10));
}
