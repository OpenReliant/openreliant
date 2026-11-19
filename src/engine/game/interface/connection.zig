//! **Improvement:** OpenReliant's server browser replaces StarLancer's connection providers on screen 14
//! (0x00432FC0). It uses the buttons from multiplayer_connection_draw (0x004345B0).
const std = @import("std");
const ui = @import("canvas.zig");
const hud = @import("../hud.zig");
const language = @import("../language.zig");
const winmain = @import("../winmain.zig");
const input = @import("../../input.zig");
const Layout = @import("connection/layout.zig");
const Connection = @This();

pub const background = "interface\\sinfade.tga";
pub const shapes = "interface\\frntend3.spr";
pub const Source = enum { internet, lan };
pub const Server = struct {
    name: []const u8,
    description: []const u8,
    mode: []const u8,
    players: u16,
    capacity: u16,
    ping_ms: ?u16 = null,
    target: []const u8,
};
pub const Action = union(enum) { back, host_lan, stop_hosting, join: []const u8 };

pub const Label = struct {
    english: []const u8 = "",
    installed: u16 = 0,

    fn text(label: Label, strings: language.Language) []const u8 {
        const value = strings.string(label.installed) orelse return label.english;
        return if (std.mem.trim(u8, value, " \t\r\n").len == 0) label.english else value;
    }
};

address: language.Text(128) = .{},
message: Label = .{},
busy: bool = false,
host_available: bool = false,
hosting: bool = false,
source: Source = .internet,
// The discovery source owns the strings while its list is displayed.
listings: std.EnumArray(Source, []const Server) = .initFill(&.{}),
selected: usize = 0,
first: usize = 0,
editing: bool = true,
hover: ?Layout.Control = null,

fn servers(screen: *const Connection) []const Server {
    return screen.listings.get(screen.source);
}

fn enabled(screen: *const Connection, control: Layout.Control) bool {
    return switch (control) {
        .back => true,
        .internet, .lan => !screen.busy,
        .connect => !screen.busy and screen.address.len != 0,
        .selected => !screen.busy and screen.selected < screen.servers().len,
        .host => screen.host_available and !screen.busy,
        // Discovery needs its runtime provider (#957).
        .refresh => false,
    };
}

pub fn frame(screen: *Connection, mouse: ui.Pointer, keys: *input.Keyboard, typed: *winmain.Typed, window: [2]u32) ?Action {
    const layout = Layout.init(window);
    const at = layout.point(mouse.at);
    screen.hover = for (std.enums.values(Layout.Control)) |control| {
        if (screen.enabled(control) and layout.control(control).holds(at)) break control;
    } else null;
    if (keys.pressed(input.scan.escape, .none, true) or (mouse.down and screen.hover == .back))
        return if (screen.hosting) .stop_hosting else .back;
    if (screen.busy) return null;
    if (mouse.down) {
        if (screen.hover) |control| switch (control) {
            .internet, .lan => {
                screen.source = if (control == .internet) .internet else .lan;
                screen.first = 0;
                screen.selected = 0;
                screen.editing = false;
            },
            .selected => return .{ .join = screen.servers()[screen.selected].target },
            .connect => return .{ .join = screen.address.slice() },
            .host => return .host_lan,
            else => {},
        } else if (layout.field.holds(at)) {
            screen.editing = true;
        }
    }
    const list = screen.servers();
    var scroll: ui.Scrolled(usize) = .{ .first = @min(screen.first, list.len -| layout.rows()), .count = list.len, .shown = layout.rows() };
    if (layout.list.holds(at)) {
        scroll.wheel(mouse.wheel);
        if (mouse.down and at[1] >= layout.rowTop(0)) {
            const index = scroll.first + @as(usize, @intCast(@divTrunc(at[1] - layout.rowTop(0), Layout.row_height)));
            if (index < scroll.end()) {
                screen.selected = index;
                screen.editing = false;
            }
        }
    }
    screen.first = scroll.first;
    while (typed.pop()) |ch| {
        if (!screen.editing) continue;
        if (ch == 8) {
            screen.address.len -|= 1;
        } else if (std.ascii.isPrint(ch) and screen.address.len < screen.address.bytes.len) {
            screen.address.bytes[screen.address.len] = ch;
            screen.address.len += 1;
        }
    }
    if (keys.pressed(@backingInt(input.Key.enter), .none, true) or keys.pressed(@backingInt(input.Key.keypad_enter), .none, true)) {
        if (screen.editing and screen.enabled(.connect)) return .{ .join = screen.address.slice() };
        if (!screen.editing and screen.enabled(.selected)) return .{ .join = list[screen.selected].target };
    }
    return null;
}

const labels = std.EnumArray(Layout.Control, Label).init(.{
    .internet = .{ .english = "INTERNET", .installed = 0xFD },
    .lan = .{ .english = "LAN", .installed = 0xFC },
    .refresh = .{ .english = "REFRESH" },
    .host = .{ .english = "HOST GAME", .installed = 0x13C },
    .selected = .{ .english = "JOIN GAME", .installed = 0x13B },
    .connect = .{ .english = "CONNECT" },
    .back = .{ .english = "MAIN MENU", .installed = 0xBB },
});
const title: Label = .{ .english = "MULTIPLAYER", .installed = 0x16D };
const details: Label = .{ .english = "SERVER INFO", .installed = 0xE6 };
const headers = [4]Label{
    .{ .english = "SERVER", .installed = 0x137 },
    .{ .english = "MODE", .installed = 0x139 },
    .{ .english = "PILOTS", .installed = 0x138 },
    .{ .english = "PING" },
};

fn panel(canvas: ui.Canvas, rect: ui.Rect) void {
    const start = canvas.point(.{ rect.x, rect.y });
    const end = canvas.point(.{ rect.x + rect.width, rect.y + rect.height });
    hud.drawFilled(canvas.target, .{ .left = @floatFromInt(start[0]), .top = @floatFromInt(start[1]), .right = @floatFromInt(end[0]), .bottom = @floatFromInt(end[1]) }, .{ 0.015, 0.033, 0.048, 0.67 });
    canvas.box(.{ rect.x, rect.y }, .{ rect.width, rect.height });
}

fn fittedLabel(canvas: ui.Canvas, at: [2]i32, width: i16, words: []const u8, colour: [3]f32, alignment: hud.Align) !void {
    const font = canvas.fonts.small;
    const measured: f32 = @floatFromInt(@max(1, font.textWidth(words)));
    const fit = @min(1, @as(f32, @floatFromInt(width)) / measured);
    _ = try hud.drawTextIn(font, canvas.gpa, canvas.target, canvas.point(at), words, hud.atBrightness(colour, canvas.brightness), alignment, canvas.scale() * fit, null);
}

fn cells(canvas: ui.Canvas, layout: Layout, y: i16, words: [4][]const u8, colour: [3]f32, heading: bool) !void {
    const list = layout.list;
    var columns: [5]i16 = undefined;
    for (&columns, [_]i32{ 0, 46, 68, 88, 100 }) |*column, percent| column.* = @intCast(@divTrunc(@as(i32, list.width) * percent, 100));
    for (words, columns[0..4], columns[1..], 0..) |word, left, right, i| {
        const cell: ui.Rect = .{ .x = list.x + left + Layout.inset, .y = y, .width = right - left - 2 * Layout.inset, .height = Layout.row_height };
        const alignment: hud.Align = if (i == 3) .right else if (i == 2) .centre else .left;
        const x = switch (alignment) {
            .right => cell.x + cell.width,
            .centre => cell.centre()[0],
            else => cell.x,
        };
        if (heading) {
            try fittedLabel(canvas, .{ x, y }, cell.width, word, colour, alignment);
        } else {
            try canvas.within(cell).text(canvas.fonts.small, .{ x, y }, word, colour, alignment);
        }
    }
}

pub fn draw(screen: *const Connection, original: ui.Canvas, art: *hud.Art, ticks: u32) !void {
    const layout = Layout.init(original.window);
    var canvas = original;
    canvas.share = layout.share;
    art.global = art.set.paletteAt(0x12);
    defer art.global = art.set.paletteAt(0);
    _ = try hud.drawTextIn(canvas.fonts.large, canvas.gpa, canvas.target, canvas.point(layout.title()), title.text(canvas.strings.*), hud.atBrightness(ui.white, canvas.brightness), .left, canvas.scale() * 1.37, null);
    panel(canvas, layout.list);
    panel(canvas, layout.details);
    panel(canvas, layout.field);
    try screen.drawList(canvas, layout);
    try screen.drawDetails(canvas, layout);
    try screen.drawAddress(canvas, layout, ticks);
    for (std.enums.values(Layout.Control)) |control| {
        const box = layout.control(control);
        const lit = screen.hover == control or switch (control) {
            .internet => screen.source == .internet,
            .lan => screen.source == .lan,
            .selected => screen.enabled(.selected),
            else => false,
        };
        const button = canvas.dimmedUnless(screen.enabled(control));
        try hud.drawShape(art, button.gpa, button.target, if (lit) 0x18 else 0x17, button.point(.{ box.x, box.y + 2 }), hud.atBrightness(ui.white, button.brightness), button.scale() / Layout.text_scale);
        const label: Label = if (control == .back and screen.hosting) .{ .english = "STOP HOSTING" } else labels.get(control);
        try fittedLabel(button, .{ box.x + Layout.label_offset, box.y }, box.width - Layout.label_offset, label.text(canvas.strings.*), if (lit) ui.white else ui.blue, .left);
    }
}

fn drawList(screen: *const Connection, canvas: ui.Canvas, layout: Layout) !void {
    const font = canvas.fonts.small;
    var column_names: [headers.len][]const u8 = undefined;
    for (&column_names, headers) |*name, label| name.* = label.text(canvas.strings.*);
    try cells(canvas, layout, layout.list.y + 3, column_names, hud.rgb(0x85A7B5), true);
    const list = screen.servers();
    const first = @min(screen.first, list.len -| layout.rows());
    for (list[first..][0..@min(list.len - first, layout.rows())], first..) |server, i| {
        const y = layout.rowTop(i - first);
        const chosen = i == screen.selected;
        if (chosen) canvas.wipe(.{ layout.list.x + 2, y }, .{ layout.list.x + layout.list.width - 2, y + Layout.row_height - 1 }, hud.rgb(0x193C4C));
        var counts: [16]u8 = undefined;
        var ping: [5]u8 = undefined;
        const population = std.fmt.bufPrint(&counts, "{d} / {d}", .{ server.players, server.capacity }) catch unreachable;
        const latency = if (server.ping_ms) |ms| std.fmt.bufPrint(&ping, "{d}", .{ms}) catch unreachable else "?";
        try cells(canvas, layout, y + 2, .{ server.name, server.mode, population, latency }, if (chosen) ui.white else ui.blue, false);
    }
    if (list.len == 0) {
        const empty = if (screen.hosting)
            "Waiting for another pilot"
        else if (screen.source == .internet)
            "Internet discovery unavailable"
        else
            "LAN discovery unavailable";
        try canvas.text(font, .{ layout.list.x + Layout.inset, layout.rowTop(0) + 2 }, empty, ui.blue, .left);
    }
}

fn drawDetails(screen: *const Connection, canvas: ui.Canvas, layout: Layout) !void {
    const font = canvas.fonts.small;
    const list = screen.servers();
    const info = layout.details;
    const body = canvas.within(.{ .x = info.x + Layout.inset, .y = info.y + 2, .width = info.width - 2 * Layout.inset, .height = layout.control(.selected).y - info.y - 4 });
    const chosen = if (screen.selected < list.len) list[screen.selected] else null;
    const heading_at = .{ info.x + Layout.inset, info.y + 3 };
    if (chosen) |server| {
        try body.text(font, heading_at, server.name, ui.white, .left);
    } else {
        try fittedLabel(canvas, heading_at, info.width - 2 * Layout.inset, details.text(canvas.strings.*), ui.white, .left);
    }
    canvas.line(.{ info.x + 2, layout.rowTop(0) }, .{ info.x + info.width - 2, layout.rowTop(0) }, hud.rgb(0x324A55));
    if (chosen) |s| try body.wrapped(font, .{ info.x + Layout.inset, layout.rowTop(0) + 2 }, s.description, ui.blue, .left, .{ .width = info.width - 2 * Layout.inset, .height = 16, .most = layout.rows() });
}

fn drawAddress(screen: *const Connection, canvas: ui.Canvas, layout: Layout, ticks: u32) !void {
    const font = canvas.fonts.small;
    const field = layout.field;
    try canvas.text(font, .{ field.x, field.y - 22 }, "DIRECT CONNECT", ui.white, .left);
    var buffer: [129]u8 = undefined;
    @memcpy(buffer[0..screen.address.len], screen.address.slice());
    buffer[screen.address.len] = '_';
    var value = buffer[0 .. screen.address.len + @intFromBool(screen.editing and !screen.busy and ticks % 50 < 25)];
    while (value.len > 0 and font.textWidth(value) > field.width - 2 * Layout.inset) value = value[1..];
    try canvas.within(field).text(font, .{ field.x + Layout.inset, field.y + 3 }, if (screen.address.len == 0) "IP address or invite" else value, if (screen.address.len == 0) hud.rgb(0x85A7B5) else ui.white, .left);
    const left = field.x;
    const right = layout.details.x + layout.details.width;
    try canvas.wrapped(font, .{ left, field.y + field.height + 2 }, screen.message.text(canvas.strings.*), ui.blue, .left, .{
        .width = right - left,
        .height = 16,
        .most = 2,
    });
}

test "browser labels use the installed language and fall back for missing strings" {
    const strings: language.Language = .{ .strings = &.{ "Beitreten", " " } };
    try std.testing.expectEqualStrings("Beitreten", (Label{ .english = "Join", .installed = 1 }).text(strings));
    try std.testing.expectEqualStrings("Host", (Label{ .english = "Host", .installed = 2 }).text(strings));
    try std.testing.expectEqualStrings("Connect", (Label{ .english = "Connect" }).text(strings));
}

test "a LAN host can stop from the browser while waiting for a pilot" {
    const size = [2]u32{ 640, 480 };
    const layout = Layout.init(size);
    const click: ui.Pointer = .{ .at = layout.control(.host).centre(), .down = true };
    var screen: Connection = .{};
    var keys: input.Keyboard = .{};
    var typed: winmain.Typed = .{};
    try std.testing.expectEqual(null, screen.frame(click, &keys, &typed, size));

    screen.host_available = true;
    try std.testing.expect(screen.frame(click, &keys, &typed, size).? == .host_lan);
    screen.busy = true;
    screen.hosting = true;
    try std.testing.expectEqual(null, screen.frame(click, &keys, &typed, size));
    try std.testing.expect(screen.frame(.{ .at = layout.control(.back).centre(), .down = true }, &keys, &typed, size).? == .stop_hosting);
}

test "browser selection and direct entry submit independent targets" {
    const size = [2]u32{ 640, 480 };
    const layout = Layout.init(size);
    const server: Server = .{
        .name = "Squadron",
        .description = "Friday games",
        .mode = "Training",
        .players = 1,
        .capacity = 3,
        .target = "192.0.2.1:27020",
    };
    var screen: Connection = .{};
    screen.listings.set(.internet, &.{server});
    screen.address.set("[::1]:27021");
    var keys: input.Keyboard = .{};
    var typed: winmain.Typed = .{};
    _ = screen.frame(.{ .at = .{ layout.list.x + Layout.inset, layout.rowTop(0) + 4 }, .down = true }, &keys, &typed, size);
    const join = screen.frame(.{ .at = layout.control(.selected).centre(), .down = true }, &keys, &typed, size).?;
    try std.testing.expectEqualStrings(server.target, join.join);
    _ = screen.frame(.{ .at = layout.control(.lan).centre(), .down = true }, &keys, &typed, size);
    try std.testing.expect(!screen.enabled(.selected));
    _ = screen.frame(.{ .at = layout.field.centre(), .down = true }, &keys, &typed, size);
    typed.push(8);
    typed.push('0');
    keys.down[@backingInt(input.Key.enter)] = true;
    keys.read();
    try std.testing.expectEqualStrings("[::1]:27020", screen.frame(.{}, &keys, &typed, size).?.join);
    screen.busy = true;
    keys.down[input.scan.escape] = true;
    keys.read();
    try std.testing.expect(screen.frame(.{}, &keys, &typed, size).? == .back);
}

test "browser panels, columns of controls and hit targets keep their alignment" {
    for ([_][2]u32{ .{ 640, 480 }, .{ 960, 720 }, .{ 1440, 810 }, .{ 1080, 1920 }, .{ 3840, 2160 } }) |size| {
        const layout = Layout.init(size);
        try std.testing.expectEqual(layout.list.y, layout.details.y);
        try std.testing.expectEqual(layout.list.height, layout.details.height);
        try std.testing.expectEqual(layout.list.x, layout.field.x);
        try std.testing.expectEqual(layout.list.width, layout.field.width);
        const join = layout.control(.selected);
        const left_gap = join.x - Layout.button_left_overhang - layout.details.x;
        const bottom_gap = layout.details.y + layout.details.height - (join.y + Layout.button_last_row);
        try std.testing.expectEqual(Layout.footer_inset, left_gap);
        try std.testing.expectEqual(left_gap, bottom_gap);
        try std.testing.expect(join.y + join.height <= layout.details.y + layout.details.height);
        const back = layout.control(.back);
        const end = layout.point(.{ 640, 480 });
        try std.testing.expect(back.y + back.height <= end[1]);
    }
    try std.testing.expect(Layout.init(.{ 1440, 810 }).rows() > Layout.init(.{ 640, 480 }).rows());
}
