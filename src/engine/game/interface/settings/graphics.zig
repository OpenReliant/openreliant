//! The VIDEO tab's graphics (`Graphics`): the game's own details and OpenReliant's graphics
//! options, and their presets. GRAPHICS, a row of the video's at the tab's top, sets every option
//! at once: its arrows flip between ORIGINAL, the original's look, and MODERN, OpenReliant's, and it
//! shows CUSTOM once an option differs from both. Below it, the options stand a row each in a pane
//! that shows four of them and scrolls as the controls' list does (`widgets.Pane`).
//!
//! A change is applied and written at once, as the driver keeps it (`settings.Own`), but for the
//! options that take effect at the next start (`Own.Graphics.Running`): the original's look beneath
//! the options, the game's details, LINEAR LIGHT, COLOR DEPTH and OUTLINE FONTS. While one differs
//! from what the game runs with, RESTART TO APPLY stands at GRAPHICS' right, in gold.
//!
//! **Improvement:** the list is OpenReliant's own, and so are its options but the game's details,
//! which its video screen has among its rows.

const std = @import("std");

const input = @import("../../../input.zig");
const profile = @import("../../../profile.zig");
const hud = @import("../../hud.zig");
const explode = @import("../../explode.zig");
const guns = @import("../../guns.zig");
const xtrabits = @import("../../xtrabits.zig");
const canvas_module = @import("../canvas.zig");
const Canvas = canvas_module.Canvas;
const Label = canvas_module.Label;
const settings = @import("../settings.zig");
const Context = settings.Context;
const Own = settings.Own;
const Chosen = Own.Graphics.Chosen;
const Preset = Own.Graphics.Preset;
const widgets = @import("widgets.zig");
const Step = widgets.Step;
const Line = widgets.Line;
const Pane = widgets.Pane;
const steppedChoice = widgets.steppedChoice;
const steppedIndex = widgets.steppedIndex;

/// The rows, from the top: the game's own details, as its video screen has them, then the
/// lighting, the shadows and the shots' lights, then the frame's look, then the motion and the
/// text.
pub const Row = enum {
    texture_detail,
    graphic_detail,
    light_maps,
    pixel_lighting,
    linear_light,
    materials,
    shadows,
    cockpit_shadows,
    shot_lights,
    real_lights,
    bloom,
    dither,
    filter,
    anti_aliasing,
    color_depth,
    smooth_motion,
    outline_fonts,
    mod_effects,

    /// Its label: the game's TEXTURE DETAIL, GRAPHIC DETAIL and LIGHT MAPS (`0x110`, `0x111`,
    /// `0x114`), and OpenReliant's words for its own.
    fn label(row: Row) Label.Text {
        return switch (row) {
            .texture_detail => .{ .string = 0x110 },
            .graphic_detail => .{ .string = 0x111 },
            .light_maps => .{ .string = 0x114 },
            .pixel_lighting => .{ .words = "PER-PIXEL LIGHTING" },
            .linear_light => .{ .words = "LINEAR LIGHT" },
            .materials => .{ .words = "MATERIALS" },
            .shadows => .{ .words = "SHADOWS" },
            .cockpit_shadows => .{ .words = "COCKPIT SHADOWS" },
            .shot_lights => .{ .words = "SHOT LIGHTS" },
            .real_lights => .{ .words = "REAL LIGHTS" },
            .bloom => .{ .words = "BLOOM" },
            .dither => .{ .words = "DITHER" },
            .filter => .{ .words = "TEXTURE FILTER" },
            .anti_aliasing => .{ .words = "ANTI-ALIASING" },
            .color_depth => .{ .words = "COLOR DEPTH" },
            .smooth_motion => .{ .words = "SMOOTH MOTION" },
            .outline_fonts => .{ .words = "OUTLINE FONTS" },
            .mod_effects => .{ .words = "MOD EFFECTS" },
        };
    }

    /// Whether it can be changed, else it is dimmed: the shadows and the material maps are drawn
    /// only where each pixel is lit, the cockpit's shadows only with the shadows, and 16-bit colour
    /// keeps the original's light (`platform.gpu.Settings`).
    fn usable(row: Row, chosen: Chosen) bool {
        return switch (row) {
            .shadows, .materials => chosen.pixel_lighting,
            .cockpit_shadows => chosen.pixel_lighting and chosen.shadows != .off,
            .linear_light => !chosen.sixteen_bit,
            .texture_detail, .graphic_detail, .light_maps, .pixel_lighting, .shot_lights, .real_lights, .bloom, .dither, .filter, .anti_aliasing, .color_depth, .smooth_motion, .outline_fonts, .mod_effects => true,
        };
    }

    /// Its check box or its choice.
    fn kind(row: Row) Kind {
        return switch (row) {
            inline else => |named| if (@hasField(Check, @tagName(named)))
                .{ .check = @field(Check, @tagName(named)) }
            else
                .{ .choice = @field(Choice, @tagName(named)) },
        };
    }
};

const rows = std.enums.values(Row);

const Kind = union(enum) { check: Check, choice: Choice };

/// The rows a check box turns on and off.
pub const Check = enum {
    light_maps,
    pixel_lighting,
    linear_light,
    materials,
    cockpit_shadows,
    real_lights,
    bloom,
    dither,
    smooth_motion,
    outline_fonts,
    mod_effects,

    fn flag(check: Check, chosen: *Chosen) *bool {
        return switch (check) {
            inline else => |named| &@field(chosen, @tagName(named)),
        };
    }
};

/// The rows an arrow box steps through their choices.
pub const Choice = enum {
    texture_detail,
    graphic_detail,
    shadows,
    shot_lights,
    filter,
    anti_aliasing,
    color_depth,

    /// Its choice a step from `graphics`' chosen one, in the choices' order, round from the last to
    /// the first.
    fn step(choice: Choice, graphics: *Own.Graphics, by: Step) void {
        const chosen = &graphics.chosen;
        switch (choice) {
            .texture_detail => chosen.texture_detail = steppedChoice(xtrabits.TextureDetail, chosen.texture_detail, by),
            .graphic_detail => chosen.graphic_detail = steppedChoice(explode.Detail, chosen.graphic_detail, by),
            .shadows => chosen.shadows = steppedChoice(Own.Graphics.Shadows, chosen.shadows, by),
            .shot_lights => chosen.shot_lights = steppedChoice(guns.ShotLights, chosen.shot_lights, by),
            .filter => chosen.filter = steppedChoice(Own.Graphics.Filter, chosen.filter, by),
            .anti_aliasing => chosen.samples = steppedSamples(graphics.*, by),
            .color_depth => chosen.sixteen_bit = !chosen.sixteen_bit,
        }
    }

    fn value(choice: Choice, graphics: Own.Graphics) Label.Text {
        const chosen = graphics.chosen;
        return switch (choice) {
            .texture_detail => .{ .string = detailString(chosen.texture_detail) },
            .graphic_detail => .{ .string = detailString(chosen.graphic_detail) },
            .shadows => .{ .words = switch (chosen.shadows) {
                .off => "OFF",
                .low => "LOW",
                .high => "HIGH",
            } },
            .shot_lights => .{ .words = switch (chosen.shot_lights) {
                .every_shot => "EVERY SHOT",
                .latest_two => "LATEST TWO",
            } },
            .filter => .{ .words = switch (chosen.filter) {
                .original => "ORIGINAL",
                .trilinear => "TRILINEAR",
                .crisp => "CRISP",
            } },
            .anti_aliasing => .{ .words = samplesText(drawnSamples(graphics)) },
            .color_depth => .{ .words = if (chosen.sixteen_bit) "16-BIT" else "32-BIT" },
        };
    }
};

/// The game's word for `detail`, a texture or a graphic detail (`0x0042F44C` on): LOW, MEDIUM or
/// HIGH. Its video screen calls the texture detail's 0 LOW and 1 HIGH, and a file's 2, its highest,
/// LOW.
///
/// **Improvement:** TEXTURE DETAIL steps through all three of the file's, LOW, MEDIUM and HIGH,
/// where the game's screen steps between the first two; a texture detail the game doesn't know,
/// which caps nothing, shows as HIGH.
fn detailString(detail: anytype) u32 {
    return switch (detail) {
        .low => low_string,
        .medium => medium_string,
        else => high_string,
    };
}

const low_string = 0x11D;
const medium_string = 0x11C;
const high_string = 0x11B;

comptime {
    // Each row is a check box's or an arrow box's, and only one's.
    for (rows) |row| {
        const checks = @intFromBool(@hasField(Check, @tagName(row)));
        const choices = @intFromBool(@hasField(Choice, @tagName(row)));
        std.debug.assert(checks + choices == 1);
    }
}

/// The samples a pixel ANTI-ALIASING steps through, as many as the GPU offers, and their words.
const sample_counts = [_]struct { count: u8, words: []const u8 }{
    .{ .count = 1, .words = "OFF" },
    .{ .count = 2, .words = "2 SAMPLES" },
    .{ .count = 4, .words = "4 SAMPLES" },
    .{ .count = 8, .words = "8 SAMPLES" },
};

/// The samples a pixel the frames are drawn with: as many as chosen, up to the most the GPU offers.
fn drawnSamples(graphics: Own.Graphics) u8 {
    return @min(graphics.chosen.samples, graphics.most_samples);
}

/// Where `samples` stand among the counts.
fn sampleIndex(samples: u8) ?usize {
    for (sample_counts, 0..) |entry, index| if (entry.count == samples) return index;
    return null;
}

fn steppedSamples(graphics: Own.Graphics, step: Step) u8 {
    const offered = (sampleIndex(graphics.most_samples) orelse sample_counts.len - 1) + 1;
    return sample_counts[steppedIndex(sampleIndex(drawnSamples(graphics)), offered, step)].count;
}

fn samplesText(samples: u8) []const u8 {
    return sample_counts[sampleIndex(samples) orelse 0].words;
}

/// Where the VIDEO tab's rows end their labels: 20 right of the game's, which leaves room for the
/// check boxes left of the rows below (`video.Check`).
pub const edge = Line.original_edge + 20;

/// The space the tab keeps between what it lays out, from the tabs down to the buttons: the tabs and
/// GRAPHICS, GRAPHICS and the pane, and the pane and the rows below it; and the pane's rows keep
/// `inside` from its frame.
pub const gap = 9;
const inside = 4;

/// How far apart the tab's rows stand, 30: their arrows' boxes a little apart, as the game's video
/// screen keeps its fewer rows, 37 apart.
pub const row_spacing = Line.arrows_height + inside;

/// GRAPHICS, the presets' row, its arrows' box a gap below the tabs' capitals.
const presets_line: Line = .{ .y = 121, .edge = edge };

/// The pane (`widgets.Pane`), a frame as the controls' panes are, from x 45 to where the screen's
/// rows reach, a gap below GRAPHICS' arrows; its rows `inside` it; and its arrows right of its top.
const pane: Pane = pane: {
    const top = presets_line.y - 1 + Line.arrows_height + gap;
    const frame_line = 2;
    const rows_height = (shown_rows - 1) * row_spacing + Line.arrows_height;
    break :pane .{
        .frame = .{ .at = .{ 45, top }, .extent = .{ 520, 2 * frame_line + 2 * inside + rows_height - 1 } },
        .arrows = .{ .at = .{ 570, top } },
        .first = top + frame_line + inside + 1,
        .spacing = row_spacing,
        .edge = edge,
    };
};

/// The rows the pane shows at once.
pub const shown_rows = 4;

/// Where the pane's frame ends, which the rows below stand a gap from.
pub const pane_bottom = pane.frame.at[1] + pane.frame.extent[1];

comptime {
    // The last row's arrows' box stands inside the frame.
    const last = pane.line(shown_rows - 1).arrow(.back);
    std.debug.assert(last.y + Line.arrows_height < pane_bottom);
}

/// The presets in GRAPHICS' order.
const presets = std.enums.values(Preset);

/// GRAPHICS' value: the preset the options are, or CUSTOM.
fn presetWords(preset: ?Preset) []const u8 {
    const set = preset orelse return "CUSTOM";
    return switch (set) {
        .original => "ORIGINAL",
        .modern => "MODERN",
    };
}

/// The preset a step from `preset`'s, round from the last to the first; from CUSTOM, on to the
/// first or back to the last.
fn steppedPreset(preset: ?Preset, step: Step) Preset {
    const at: ?usize = if (preset) |set| std.mem.indexOfScalar(Preset, presets, set) else null;
    return presets[steppedIndex(at, presets.len, step)];
}

/// What the tab says while an option waits for the next start: once, on GRAPHICS' line, ending where
/// the pane does.
const restart_note: Label = .{
    .text = .{ .words = "RESTART TO APPLY" },
    .at = .{ pane.frame.at[0] + pane.frame.extent[0], presets_line.y },
    .alignment = .right,
};

/// What each row shows, for `graphics`.
fn shownRows(graphics: Own.Graphics) [rows.len]Line.Shown {
    var shown: [rows.len]Line.Shown = undefined;
    var chosen = graphics.chosen;
    for (rows, &shown) |row, *each| each.* = .{
        .label = row.label(),
        .control = switch (row.kind()) {
            .check => |check| .{ .check = check.flag(&chosen).* },
            .choice => |choice| .{ .choice = choice.value(graphics) },
        },
        .usable = row.usable(graphics.chosen),
    };
    return shown;
}

/// What the pointer finds: an arrow of GRAPHICS, or an item of the pane.
pub const Item = union(enum) {
    preset: Step,
    pane: Pane.Item,
};

/// The graphics' state.
pub const Graphics = struct {
    /// The options as the screen opened, which CANCEL CHANGES puts back.
    kept: Chosen = .{},
    /// The options as the driver has them.
    graphics: Own.Graphics = .{},
    /// The rows the pane shows.
    list: widgets.List = .of(rows.len, shown_rows, 0),
    /// The pane's item under the pointer, whose arrow is lit, and GRAPHICS' arrow.
    lit: ?Pane.Item = null,
    lit_preset: ?Step = null,

    /// The options as the driver has them, kept for CANCEL CHANGES, and the list at its top.
    pub fn enter(tab: *Graphics, context: Context) void {
        const graphics: Own.Graphics = if (context.own) |own| own.graphics() else .{};
        tab.* = .{ .kept = graphics.chosen, .graphics = graphics, .list = .of(rows.len, shown_rows, context.ticks) };
    }

    /// The item the pointer is over.
    pub fn itemAt(tab: Graphics, at: [2]i32) ?Item {
        if (presets_line.arrowAt(at)) |step| return .{ .preset = step };
        const shown = shownRows(tab.graphics);
        return .{ .pane = pane.itemAt(tab.list, &shown, at) orelse return null };
    }

    /// The pointer over `item` with its button up: an arrow lights.
    pub fn hover(tab: *Graphics, item: Item) void {
        switch (item) {
            .pane => |on_pane| switch (on_pane) {
                .scroll, .step => tab.lit = on_pane,
                .check => {},
            },
            .preset => |step| tab.lit_preset = step,
        }
    }

    /// The wheel and the keys that scroll the pane (`widgets.List.scrollBy`).
    pub fn scroll(tab: *Graphics, context: Context) void {
        tab.list.scrollBy(context.pointer.wheel, &context.devices.keyboard, context.ticks);
    }

    /// A click on `item`: an arrow of GRAPHICS sets every option to the other preset, or from CUSTOM
    /// to ORIGINAL on and MODERN back; an arrow of a row steps its choice back or on, round from the
    /// last to the first, and a check box turns its option on or off, where it can be changed; the
    /// driver applies the change and writes it. An arrow of the pane scrolls it a row, and again
    /// while it is held, which it returns true for.
    pub fn choose(tab: *Graphics, item: Item, context: Context) bool {
        const chosen = &tab.graphics.chosen;
        switch (item) {
            .preset => |step| chosen.* = chosen.withPreset(steppedPreset(chosen.preset(), step)),
            .pane => |on_pane| switch (on_pane) {
                .scroll => |way| {
                    tab.list.scrollHeld(way, context.ticks);
                    return true;
                },
                .check => |row| {
                    if (!rows[row].usable(chosen.*)) return false;
                    switch (rows[row].kind()) {
                        .check => |check| check.flag(chosen).* = !check.flag(chosen).*,
                        .choice => return false,
                    }
                },
                .step => |stepped| {
                    if (!rows[stepped.row].usable(chosen.*)) return false;
                    switch (rows[stepped.row].kind()) {
                        .choice => |choice| choice.step(&tab.graphics, stepped.step),
                        .check => return false,
                    }
                },
            },
        }
        tab.apply(context);
        return false;
    }

    fn apply(tab: *Graphics, context: Context) void {
        if (context.own) |own| own.setGraphics(tab.graphics.chosen);
    }

    /// RESET DEFAULTS: OpenReliant's defaults, MODERN.
    pub fn reset(tab: *Graphics, context: Context) void {
        tab.graphics.chosen = Preset.modern.chosen();
        tab.apply(context);
    }

    /// CANCEL CHANGES: the options as the screen opened.
    pub fn cancel(tab: *Graphics, context: Context) void {
        tab.graphics.chosen = tab.kept;
        tab.apply(context);
    }

    /// GRAPHICS with its arrows, the one under the pointer lit, and its value; the note while an
    /// option waits for the next start; and the pane.
    pub fn draw(tab: Graphics, canvas: Canvas, art: *hud.Art) canvas_module.Error!void {
        try presets_line.draw(canvas, art, .{ .label = .{ .words = "GRAPHICS" }, .control = .{ .choice = .{ .words = presetWords(tab.graphics.chosen.preset()) } } });
        if (tab.lit_preset) |step| try presets_line.drawLit(canvas, art, step);
        if (tab.graphics.waits()) try restart_note.write(canvas, canvas.fonts.small, canvas_module.gold);
        const shown = shownRows(tab.graphics);
        try pane.draw(canvas, art, tab.list, &shown, tab.lit);
    }
};

/// The pane's row `row`'s place on the screen, for the tests: its line, scrolled to show it.
fn lineOf(tab: *Graphics, row: Row) Line {
    const index = @intFromEnum(row);
    while (tab.list.place(index) == null) tab.list.rows.scroll(if (index < tab.list.rows.first) .up else .down);
    return pane.line(tab.list.place(index).?);
}

test "the rows stand in the pane, four shown" {
    // The pane's frame from y 155, a gap below GRAPHICS' arrows, to 282; its rows from 162, 30
    // apart.
    try std.testing.expectEqual(155, pane.frame.at[1]);
    try std.testing.expectEqual(282, pane_bottom);
    try std.testing.expectEqual(162, pane.line(0).y);
    try std.testing.expectEqual(252, pane.line(shown_rows - 1).y);
    var tab: Graphics = .{};
    // MOD EFFECTS, the last, is shown once the list is scrolled to its end.
    try std.testing.expectEqual(252, lineOf(&tab, .mod_effects).y);
    try std.testing.expectEqual(rows.len - shown_rows, tab.list.rows.first);
}

test "the presets leave MOD EFFECTS as it is" {
    var chosen = Preset.modern.chosen();
    chosen.mod_effects = false;
    try std.testing.expectEqual(Preset.modern, chosen.preset().?);
    const applied = chosen.withPreset(.original);
    try std.testing.expect(!applied.mod_effects and applied.original);
    try std.testing.expectEqual(Preset.original, applied.preset().?);
}

test steppedPreset {
    // The arrows flip between the two; from CUSTOM, on to ORIGINAL and back to MODERN.
    try std.testing.expectEqual(Preset.original, steppedPreset(.modern, .on));
    try std.testing.expectEqual(Preset.original, steppedPreset(.modern, .back));
    try std.testing.expectEqual(Preset.modern, steppedPreset(.original, .on));
    try std.testing.expectEqual(Preset.original, steppedPreset(null, .on));
    try std.testing.expectEqual(Preset.modern, steppedPreset(null, .back));
    try std.testing.expectEqualStrings("CUSTOM", presetWords(null));
}

test "the presets set every option, and the rows change them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var file: profile.File = .{ .arena = arena.allocator(), .profile = .empty };
    var devices: input.Devices = .{};
    var recorder: settings.testing.Recorder = .{};
    const context: Context = .{ .pointer = .{}, .devices = &devices, .settings_file = &file, .ticks = 0, .own = recorder.own() };
    var tab: Graphics = .{};
    tab.enter(context);
    try std.testing.expectEqual(Preset.modern, tab.graphics.chosen.preset().?);
    // GRAPHICS' arrow on, found at its row, flips MODERN to ORIGINAL, the original's look, which
    // waits for the next start.
    try std.testing.expectEqual(Item{ .preset = .on }, tab.itemAt(.{ 342, 127 }).?);
    _ = tab.choose(.{ .preset = .on }, context);
    try std.testing.expectEqual(Preset.original.chosen(), recorder.graphics.chosen);
    try std.testing.expect(tab.graphics.waits());
    // With each vertex lit, the shadows can't change, and are dimmed.
    const shadows = lineOf(&tab, .shadows);
    const on: Item = .{ .pane = .{ .step = .{ .row = @intFromEnum(Row.shadows), .step = .on } } };
    try std.testing.expectEqual(on, tab.itemAt(.{ 342, shadows.y + 5 }).?);
    _ = tab.choose(on, context);
    try std.testing.expectEqual(Own.Graphics.Shadows.off, recorder.graphics.chosen.shadows);
    // BLOOM's box turns it on, and the options are CUSTOM.
    const bloom: Item = .{ .pane = .{ .check = @intFromEnum(Row.bloom) } };
    const bloom_line = lineOf(&tab, .bloom);
    try std.testing.expectEqual(bloom, tab.itemAt(.{ 338, bloom_line.y + 8 }).?);
    _ = tab.choose(bloom, context);
    try std.testing.expect(recorder.graphics.chosen.bloom);
    try std.testing.expectEqual(null, tab.graphics.chosen.preset());
    // From CUSTOM, GRAPHICS' arrow back sets MODERN.
    _ = tab.choose(.{ .preset = .back }, context);
    try std.testing.expectEqual(Chosen{}, recorder.graphics.chosen);
    // RESET DEFAULTS sets MODERN, which the game runs with; CANCEL CHANGES puts back what it
    // opened with.
    _ = tab.choose(.{ .preset = .on }, context);
    tab.reset(context);
    try std.testing.expectEqual(Chosen{}, recorder.graphics.chosen);
    try std.testing.expect(!tab.graphics.waits());
    _ = tab.choose(.{ .preset = .on }, context);
    tab.cancel(context);
    try std.testing.expectEqual(Chosen{}, recorder.graphics.chosen);
}

test "the arrows step the choices, and the pane's arrows scroll it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var file: profile.File = .{ .arena = arena.allocator(), .profile = .empty };
    var devices: input.Devices = .{};
    var recorder: settings.testing.Recorder = .{ .graphics = .{ .most_samples = 4 } };
    var context: Context = .{ .pointer = .{}, .devices = &devices, .settings_file = &file, .ticks = 0, .own = recorder.own() };
    var tab: Graphics = .{};
    tab.enter(context);
    // As many samples as the GPU offers: on from 4 round to OFF, back to 2.
    const anti_aliasing = @intFromEnum(Row.anti_aliasing);
    _ = tab.choose(.{ .pane = .{ .step = .{ .row = anti_aliasing, .step = .on } } }, context);
    try std.testing.expectEqual(1, recorder.graphics.chosen.samples);
    _ = tab.choose(.{ .pane = .{ .step = .{ .row = anti_aliasing, .step = .back } } }, context);
    _ = tab.choose(.{ .pane = .{ .step = .{ .row = anti_aliasing, .step = .back } } }, context);
    try std.testing.expectEqual(2, recorder.graphics.chosen.samples);
    try std.testing.expectEqualStrings("2 SAMPLES", Choice.anti_aliasing.value(tab.graphics).words);
    // COLOR DEPTH waits for the next start.
    _ = tab.choose(.{ .pane = .{ .step = .{ .row = @intFromEnum(Row.color_depth), .step = .on } } }, context);
    try std.testing.expect(recorder.graphics.chosen.sixteen_bit and tab.graphics.waits());
    // The pane's down arrow scrolls it a row.
    try std.testing.expectEqual(Item{ .pane = .{ .scroll = .down } }, tab.itemAt(.{ 580, 181 }).?);
    context.ticks = 1;
    try std.testing.expect(tab.choose(.{ .pane = .{ .scroll = .down } }, context));
    try std.testing.expectEqual(1, tab.list.rows.first);
    // A notch of the wheel down, three rows more, as far as the list goes.
    context.pointer.wheel = -1;
    tab.scroll(context);
    try std.testing.expectEqual(4, tab.list.rows.first);
    for (0..rows.len) |_| tab.scroll(context);
    try std.testing.expectEqual(rows.len - shown_rows, tab.list.rows.first);
}
