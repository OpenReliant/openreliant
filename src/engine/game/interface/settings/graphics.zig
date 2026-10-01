//! The settings screen's graphics (`Graphics`): OpenReliant's own graphics options, a row each, laid
//! out as the video's rows are (`settings.Line`), 26 apart from the video's first to its last. They
//! change at once, as the driver applies them (`settings.Own`), and are written at once, but for
//! LINEAR LIGHT and COLOR DEPTH, which change the GPU's formats and take effect at the next start:
//! their rows say so once they differ from what the game runs with.
//!
//! **Improvement:** the tab is OpenReliant's own, and so are its options: the original has none of
//! them.

const std = @import("std");

const input = @import("../../../input.zig");
const profile = @import("../../../profile.zig");
const hud = @import("../../hud.zig");
const guns = @import("../../guns.zig");
const canvas_module = @import("../canvas.zig");
const Canvas = canvas_module.Canvas;
const Label = canvas_module.Label;
const settings = @import("../settings.zig");
const Context = settings.Context;
const Own = settings.Own;
const Box = settings.Box;
const Step = settings.Step;
const Line = settings.Line;
const steppedChoice = settings.steppedChoice;
const Chosen = Own.Graphics.Chosen;

/// The rows, from the top: the lighting, the shadows and the shots' lights, then the frame's look,
/// then the motion.
pub const Row = enum {
    pixel_lighting,
    linear_light,
    materials,
    shadows,
    cockpit_shadows,
    shot_lights,
    bloom,
    dither,
    filter,
    color_depth,
    smooth_motion,

    /// Its line: 26 apart from y 129, so that the eleven fill the video's eight rows' height.
    fn line(row: Row) Line {
        return .{ .y = first_row + @as(i32, @intFromEnum(row)) * row_spacing };
    }

    fn label(row: Row) Label {
        return row.line().label(.{ .words = switch (row) {
            .pixel_lighting => "PER-PIXEL LIGHTING",
            .linear_light => "LINEAR LIGHT",
            .materials => "MATERIALS",
            .shadows => "SHADOWS",
            .cockpit_shadows => "COCKPIT SHADOWS",
            .shot_lights => "SHOT LIGHTS",
            .bloom => "BLOOM",
            .dither => "DITHER",
            .filter => "TEXTURE FILTER",
            .color_depth => "COLOR DEPTH",
            .smooth_motion => "SMOOTH MOTION",
        } });
    }

    /// Whether it takes effect at the next start, and has changed from what the game runs with.
    fn waits(row: Row, graphics: Own.Graphics) bool {
        return switch (row) {
            .linear_light => graphics.chosen.linear_light != graphics.running.linear_light,
            .color_depth => graphics.chosen.sixteen_bit != graphics.running.sixteen_bit,
            .pixel_lighting, .materials, .shadows, .cockpit_shadows, .shot_lights, .bloom, .dither, .filter, .smooth_motion => false,
        };
    }
};

const first_row = 129;
const row_spacing = 26;

/// What a row that waits for the next start says beside its value, and where.
const restart_note = "CHANGES APPLY AFTER RESTART";
const note_x = 420;

/// The rows a check box turns on and off.
pub const Check = enum {
    pixel_lighting,
    linear_light,
    materials,
    cockpit_shadows,
    bloom,
    dither,
    smooth_motion,

    fn row(check: Check) Row {
        return switch (check) {
            inline else => |named| @field(Row, @tagName(named)),
        };
    }

    fn flag(check: Check, chosen: *Chosen) *bool {
        return switch (check) {
            inline else => |named| &@field(chosen, @tagName(named)),
        };
    }
};

/// The rows an arrow box steps through their choices.
pub const Choice = enum {
    shadows,
    shot_lights,
    filter,
    color_depth,

    fn row(choice: Choice) Row {
        return switch (choice) {
            inline else => |named| @field(Row, @tagName(named)),
        };
    }

    /// Its choice a step from `chosen`'s, in the choices' order, round from the last to the first.
    fn step(choice: Choice, chosen: *Chosen, by: Step) void {
        switch (choice) {
            .shadows => chosen.shadows = steppedChoice(Own.Graphics.Shadows, chosen.shadows, by),
            .shot_lights => chosen.shot_lights = steppedChoice(guns.ShotLights, chosen.shot_lights, by),
            .filter => chosen.filter = steppedChoice(Own.Graphics.Filter, chosen.filter, by),
            .color_depth => chosen.sixteen_bit = !chosen.sixteen_bit,
        }
    }

    fn value(choice: Choice, chosen: Chosen) []const u8 {
        return switch (choice) {
            .shadows => switch (chosen.shadows) {
                .off => "OFF",
                .low => "LOW",
                .high => "HIGH",
            },
            .shot_lights => switch (chosen.shot_lights) {
                .every_shot => "EVERY SHOT",
                .latest_two => "LATEST TWO",
            },
            .filter => switch (chosen.filter) {
                .original => "ORIGINAL",
                .trilinear => "TRILINEAR",
                .crisp => "CRISP",
            },
            .color_depth => if (chosen.sixteen_bit) "16-BIT" else "32-BIT",
        };
    }
};

comptime {
    // Each row is a check box's or an arrow box's, and only one's.
    for (std.enums.values(Row)) |row| {
        const checks = @intFromBool(@hasField(Check, @tagName(row)));
        const choices = @intFromBool(@hasField(Choice, @tagName(row)));
        std.debug.assert(checks + choices == 1);
    }
}

/// An arrow of a row's box.
pub const Arrow = struct { choice: Choice, step: Step };

/// What the pointer finds on the tab.
pub const Item = union(enum) {
    arrow: Arrow,
    check: Check,
};

/// The item the pointer is over: an arrow of a row with choices, or a row's check box.
pub fn itemAt(at: [2]i32) ?Item {
    for (std.enums.values(Choice)) |choice| for (std.enums.values(Step)) |step| {
        if (choice.row().line().arrow(step).holds(at)) return .{ .arrow = .{ .choice = choice, .step = step } };
    };
    for (std.enums.values(Check)) |check| if (check.row().line().boxRect().holds(at)) return .{ .check = check };
    return null;
}

/// The tab's state.
pub const Graphics = struct {
    /// The options as the screen opened, which CANCEL CHANGES puts back.
    kept: Chosen = .{},
    /// The options as the driver has them.
    graphics: Own.Graphics = .{},
    /// The arrow under the pointer, lit.
    arrow: ?Arrow = null,

    pub fn enter(tab: *Graphics, context: Context) void {
        const graphics: Own.Graphics = if (context.own) |own| own.graphics() else .{};
        tab.* = .{ .kept = graphics.chosen, .graphics = graphics };
    }

    /// The pointer over `item` with its button up: an arrow lights.
    pub fn hover(tab: *Graphics, item: Item) void {
        switch (item) {
            .arrow => |arrow| tab.arrow = arrow,
            .check => {},
        }
    }

    /// A click on `item`: an arrow steps its row's choice back or on, round from the last to the
    /// first; a check box turns its option on or off. The driver applies the change and writes it.
    pub fn choose(tab: *Graphics, item: Item, context: Context) void {
        const chosen = &tab.graphics.chosen;
        switch (item) {
            .check => |check| {
                const on = check.flag(chosen);
                on.* = !on.*;
            },
            .arrow => |arrow| arrow.choice.step(chosen, arrow.step),
        }
        tab.apply(context);
    }

    fn apply(tab: *Graphics, context: Context) void {
        if (context.own) |own| own.setGraphics(tab.graphics.chosen);
    }

    /// RESET DEFAULTS: OpenReliant's defaults, every improvement on.
    pub fn reset(tab: *Graphics, context: Context) void {
        tab.graphics.chosen = .{};
        tab.apply(context);
    }

    /// CANCEL CHANGES: the options as the screen opened.
    pub fn cancel(tab: *Graphics, context: Context) void {
        tab.graphics.chosen = tab.kept;
        tab.apply(context);
    }

    /// The rows' labels, the arrows' boxes and their values, the check boxes, the note of the rows
    /// that wait for the next start, and the arrow under the pointer lit.
    pub fn draw(tab: Graphics, canvas: Canvas, art: *hud.Art) canvas_module.Error!void {
        const small = canvas.fonts.small;
        const blue = canvas_module.blue;
        var chosen = tab.graphics.chosen;
        for (std.enums.values(Row)) |row| {
            try row.label().write(canvas, small, blue);
            if (row.waits(tab.graphics)) try canvas.text(small, .{ note_x, row.line().y }, restart_note, canvas_module.gold, .left);
        }
        for (std.enums.values(Choice)) |choice| {
            const line = choice.row().line();
            try line.drawArrows(canvas, art);
            try line.value(.{ .words = choice.value(chosen) }).write(canvas, small, blue);
        }
        for (std.enums.values(Check)) |check| try Box.draw(canvas, art, check.row().line().box(), check.flag(&chosen).*);
        if (tab.arrow) |arrow| try arrow.choice.row().line().drawLit(canvas, art, arrow.step);
    }
};

test "the rows fill the video's rows' height, each clear of the next" {
    try std.testing.expectEqual(129, Row.pixel_lighting.line().y);
    try std.testing.expectEqual(389, Row.smooth_motion.line().y);
    const first = Row.shadows.line().arrow(.back);
    try std.testing.expect(first.y + first.height < Row.cockpit_shadows.line().arrow(.back).y);
}

test "the arrows and the boxes change the options, and the next start's say so" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var file: profile.File = .{ .arena = arena.allocator(), .profile = .empty };
    var devices: input.Devices = .{};
    var recorder: settings.testing.Recorder = .{};
    const context: Context = .{ .pointer = .{}, .devices = &devices, .settings_file = &file, .ticks = 0, .own = recorder.own() };
    var tab: Graphics = .{};
    tab.enter(context);
    // BLOOM's box, found at its row, turns it off; SHADOWS' arrows step round OFF, LOW and HIGH.
    try std.testing.expectEqual(Item{ .check = .bloom }, itemAt(.{ 318, Row.bloom.line().y + 8 }).?);
    tab.choose(.{ .check = .bloom }, context);
    try std.testing.expect(!recorder.graphics.chosen.bloom);
    try std.testing.expectEqual(Item{ .arrow = .{ .choice = .shadows, .step = .on } }, itemAt(.{ 322, Row.shadows.line().y + 5 }).?);
    tab.choose(.{ .arrow = .{ .choice = .shadows, .step = .on } }, context);
    try std.testing.expectEqual(Own.Graphics.Shadows.off, recorder.graphics.chosen.shadows);
    tab.choose(.{ .arrow = .{ .choice = .shadows, .step = .back } }, context);
    tab.choose(.{ .arrow = .{ .choice = .shadows, .step = .back } }, context);
    try std.testing.expectEqual(Own.Graphics.Shadows.low, recorder.graphics.chosen.shadows);
    // COLOR DEPTH waits for the next start, and says so, until it is as the game runs again.
    try std.testing.expect(!Row.color_depth.waits(tab.graphics));
    tab.choose(.{ .arrow = .{ .choice = .color_depth, .step = .on } }, context);
    try std.testing.expect(recorder.graphics.chosen.sixteen_bit);
    try std.testing.expect(Row.color_depth.waits(tab.graphics));
    // CANCEL CHANGES puts all back; RESET DEFAULTS sets every improvement on.
    tab.cancel(context);
    try std.testing.expectEqual(Chosen{}, recorder.graphics.chosen);
    try std.testing.expect(!Row.color_depth.waits(tab.graphics));
    recorder.graphics.chosen.dither = false;
    tab.enter(context);
    tab.reset(context);
    try std.testing.expect(recorder.graphics.chosen.dither);
}
