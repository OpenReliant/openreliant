//! The settings screen's audio (`Audio`): the original's sound configuration, screen 3 of the front
//! end (`audio_screen`, `0x0042DAB0`), with its drawing (`audio_screen_draw`, `0x0042E2E0`), laid out
//! where the original lays it out on the front end's screen. Its four volumes are dragged along
//! their sliders, and change the sound at once; they are written to `starlancer.ini` as the screen
//! is left (`save`).
//!
//! **Improvement:** its 3D SOUND chooses how OpenAL Soft renders the 3D sounds, by the output,
//! for headphones or for speakers, where the game chooses one of Miles's 3D providers; REVERB and
//! COMPRESSOR turn OpenReliant's reverb and compressor on and off. OpenReliant's options change at
//! once, as the driver applies them (`settings.Own`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../../../input.zig");
const profile = @import("../../../profile.zig");
const hud = @import("../../hud.zig");
const hog_snd = @import("../../hog_snd.zig");
const canvas_module = @import("../canvas.zig");
const Canvas = canvas_module.Canvas;
const Rect = canvas_module.Rect;
const Label = canvas_module.Label;
const settings = @import("../settings.zig");
const Context = settings.Context;
const Own = settings.Own;
const Box = settings.Box;
const Slider = settings.Slider;
const Step = settings.Step;
const steppedChoice = settings.steppedChoice;

const Volumes = hog_snd.Volumes;
const Volume = std.meta.FieldEnum(Volumes);

/// Each slider's row, from the top, and its label, right of which the slider starts (`0x0042E426`
/// on): SPEECH VOLUME, SOUND EFFECTS VOLUME, MUSIC VOLUME and MASTER VOLUME.
const sliders = std.EnumArray(Volume, struct { y: i32, label: u32 }).init(.{
    .speech = .{ .y = 126, .label = 0x576 },
    .effects = .{ .y = 186, .label = 0x2EE },
    .music = .{ .y = 246, .label = 0x2EF },
    .master = .{ .y = 306, .label = 0x577 },
});
const slider_label_x = 295;
/// The labels stand a little below their knob's top.
const label_drop = 5;

/// The slider of `volume`: its knob from x 313 to 488 for the volume from 0 to 127, and its track
/// until 538 (`0x0042E5E3` on).
fn sliderOf(volume: Volume) Slider {
    return .{ .from = .{ 313, sliders.get(volume).y }, .end = 538 };
}

/// The order the volumes are written in as the screen is left (`0x0042E0AE` on).
const saved = [_]Volume{ .effects, .music, .speech, .master };

/// The sound `stdsmp.fat` plays, once, in the middle, at its own pitch, as the effects' knob is let
/// go, to try the volume (`0x0042DF22`).
const test_sound = 14;

/// 3D SOUND (`0x2F0`), its arrows and its choice (`0x0042E4E4` on): the label to the left of
/// (291, 371), the arrows, shapes `0x13` and `0x14`, `0x15` and `0x16` under the pointer, at
/// (300, 369) and (322, 369), each found 19 by 26, and the choice from (346, 371).
const sound_3d: Label = .of(0x2F0, .{ 291, 371 }, .right);
const choice_at: [2]i32 = .{ 346, 371 };
const step_rects = std.EnumArray(Step, Rect).init(.{
    .back = .{ .x = 300, .y = 369, .width = 19, .height = 26 },
    .on = .{ .x = 322, .y = 369, .width = 19, .height = 26 },
});
const step_shapes = std.EnumArray(Step, struct { off: usize, lit: usize }).init(.{
    .back = .{ .off = 0x13, .lit = 0x15 },
    .on = .{ .off = 0x14, .lit = 0x16 },
});

/// The words for 3D SOUND's choices, OpenReliant's own.
fn renderedFor(hrtf: Own.Hrtf) []const u8 {
    return switch (hrtf) {
        .auto => "AUTOMATIC",
        .on => "HEADPHONES",
        .off => "SPEAKERS",
    };
}

/// OpenReliant's check boxes, in the place the controls have their controllers: the box at x 45,
/// the label at x 67, OpenReliant's own words.
pub const Check = enum {
    reverb,
    compressor,

    const box_x = 45;
    const label_x = 67;

    fn y(check: Check) i32 {
        return switch (check) {
            .reverb => 349,
            .compressor => 373,
        };
    }

    fn label(check: Check) Label {
        const words = switch (check) {
            .reverb => "REVERB",
            .compressor => "COMPRESSOR",
        };
        return .{ .text = .{ .words = words }, .at = .{ label_x, check.y() } };
    }

    fn rect(check: Check) Rect {
        return .{ .x = box_x, .y = @intCast(check.y()), .width = Box.size, .height = Box.size };
    }

    fn on(check: Check, own: Own.Audio) bool {
        return switch (check) {
            .reverb => own.reverb,
            .compressor => own.compressor,
        };
    }

    /// Whether it can be changed, else it is dimmed: the reverb is OpenAL Soft's, which the
    /// software Miles of `--original` hasn't.
    fn usable(check: Check, own: Own.Audio) bool {
        return switch (check) {
            .reverb => own.openal,
            .compressor => true,
        };
    }
};

/// What the pointer finds on the tab.
pub const Item = union(enum) {
    knob: Volume,
    step: Step,
    check: Check,
};

/// The item the pointer is over: an arrow, a check box, or a knob at its volume's place.
pub fn itemAt(context: Context, at: [2]i32) ?Item {
    for (std.enums.values(Step)) |step| if (step_rects.get(step).holds(at)) return .{ .step = step };
    for (std.enums.values(Check)) |check| if (check.rect().holds(at)) return .{ .check = check };
    return .{ .knob = knobAt(volumesOf(context), at) orelse return null };
}

/// The tab's state, which the game keeps on `audio_screen`'s stack and in globals.
pub const Audio = struct {
    /// The volumes as the screen opened, which CANCEL CHANGES puts back.
    kept: Volumes = .{},
    /// OpenReliant's own options as the screen opened, and as they stand.
    kept_own: Own.Audio = .{},
    own: Own.Audio = .{},
    /// The knob the pointer holds (`0x00520188`), and the one it held last pass (`0x0051D550`),
    /// whose letting go tries the effects' volume.
    held: ?Volume = null,
    held_last: ?Volume = null,
    /// The arrow under the pointer, lit.
    arrow: ?Step = null,

    /// `audio_screen`'s start: what CANCEL CHANGES puts back kept.
    pub fn enter(tab: *Audio, context: Context) void {
        const own: Own.Audio = if (context.own) |driver| driver.audio() else .{};
        tab.* = .{
            .kept = if (context.sound) |sound| sound.volumes else .{},
            .kept_own = own,
            .own = own,
        };
    }

    /// The pointer over `item` with its button up: an arrow lights.
    pub fn hover(tab: *Audio, item: Item) void {
        switch (item) {
            .step => |step| tab.arrow = step,
            .knob, .check => {},
        }
    }

    /// A pass's knobs (`0x0042DEA4` on): the knob held follows the pointer, and changes its volume
    /// at once; the effects' knob let go tries its volume. While the pointer's button is down, the
    /// knob under it is held, until the button comes up.
    ///
    /// **Improvement:** every volume changes as its knob moves, where the game changes the music
    /// and the master volume so, and the effects' and the speech's as the screen is left.
    ///
    /// **Improvement:** the volume is the knob's place over its travel, exactly, where the game
    /// multiplies by its rounded reciprocal (`0x004DC6A4`).
    pub fn slide(tab: *Audio, context: Context) void {
        const sound = context.sound orelse return;
        if (tab.held) |volume| {
            const share = @as(f32, @floatFromInt(sliderOf(volume).held(context.pointer.at[0]))) / Slider.travel;
            setLevel(&sound.volumes, volume, @intFromFloat(@round(share * hog_snd.loudest)));
            sound.applyVolumes();
        } else if (tab.held_last == .effects) {
            if (sound.stdsmp) |bank| _ = sound.play(bank, test_sound, sound.volumes.effects, hog_snd.once, hog_snd.centre, hog_snd.own_pitch);
        }
        tab.held_last = tab.held;
        tab.held = if (context.pointer.down) knobAt(sound.volumes, context.pointer.at) else null;
    }

    /// A click on `item` (`0x0042DC3C`): an arrow steps 3D SOUND's choice back or on, round from
    /// the last to the first; a check box that can be changed changes. OpenReliant's options are
    /// applied, and written, as they change.
    pub fn choose(tab: *Audio, item: Item, context: Context) void {
        switch (item) {
            .knob => {},
            .step => |step| if (tab.own.openal) {
                tab.own.hrtf = steppedChoice(Own.Hrtf, tab.own.hrtf, step);
                tab.applyOwn(context);
            },
            .check => |check| if (check.usable(tab.own)) {
                switch (check) {
                    .reverb => tab.own.reverb = !tab.own.reverb,
                    .compressor => tab.own.compressor = !tab.own.compressor,
                }
                tab.applyOwn(context);
            },
        }
    }

    fn applyOwn(tab: *Audio, context: Context) void {
        if (context.own) |driver| driver.setAudio(tab.own);
    }

    /// RESET DEFAULTS (`0x0042DC43` on): the volumes at their defaults, written at once, and
    /// OpenReliant's options at theirs.
    pub fn reset(tab: *Audio, context: Context) Allocator.Error!void {
        if (context.sound) |sound| {
            sound.volumes = .{};
            sound.applyVolumes();
        }
        tab.own = .{ .openal = tab.own.openal };
        tab.applyOwn(context);
        try tab.save(context);
    }

    /// CANCEL CHANGES (`0x0042DDDA` on): the volumes and OpenReliant's options as the screen opened.
    pub fn cancel(tab: *Audio, context: Context) void {
        if (context.sound) |sound| {
            sound.volumes = tab.kept;
            sound.applyVolumes();
        }
        tab.own = tab.kept_own;
        tab.applyOwn(context);
    }

    /// As the screen is left: the volumes written to `[Sound]` (`0x0042E0AE` on).
    pub fn save(_: *Audio, context: Context) Allocator.Error!void {
        const sound = context.sound orelse return;
        for (saved) |volume| try context.settings_file.writeInt(Volumes.section, Volumes.keys.get(volume), level(sound.volumes, volume));
    }

    /// `audio_screen_draw`'s part (`0x0042E2E0`): the sliders' labels, their tracks and knobs, 3D
    /// SOUND with its arrows, the one under the pointer lit, and its choice, and OpenReliant's check
    /// boxes, dimmed where they can't be used.
    pub fn draw(tab: Audio, canvas: Canvas, art: *hud.Art, sound: ?*const hog_snd.Sound) canvas_module.Error!void {
        const small = canvas.fonts.small;
        const blue = canvas_module.blue;
        const volumes = if (sound) |playing| playing.volumes else Volumes{};
        for (std.enums.values(Volume)) |volume| {
            const slider = sliders.get(volume);
            try Label.of(slider.label, .{ slider_label_x, slider.y + label_drop }, .right).write(canvas, small, blue);
            try sliderOf(volume).drawTrack(canvas, art);
        }
        for (std.enums.values(Volume)) |volume| try sliderOf(volume).drawKnob(canvas, art, along(level(volumes, volume)));
        try sound_3d.write(canvas, small, blue);
        const dim_3d = canvas.dimmedUnless(tab.own.openal);
        for (std.enums.values(Step)) |step| {
            const rect = step_rects.get(step);
            const shapes = step_shapes.get(step);
            try dim_3d.shape(art, shapes.off, .{ rect.x, rect.y });
            if (tab.arrow == step) try dim_3d.shape(art, shapes.lit, .{ rect.x, rect.y });
        }
        try dim_3d.text(small, choice_at, renderedFor(tab.own.hrtf), blue, .left);
        for (std.enums.values(Check)) |check| {
            const usable = check.usable(tab.own);
            const shown = canvas.dimmedUnless(usable);
            try check.label().write(shown, small, blue);
            try Box.draw(shown, art, .{ Check.box_x, check.y() }, usable and check.on(tab.own));
        }
    }
};

/// The volumes the screen changes, the sound's; the defaults without one.
fn volumesOf(context: Context) Volumes {
    return if (context.sound) |sound| sound.volumes else .{};
}

/// How far along its travel the knob of a volume at `value` stands: its share of the travel, cut
/// to a whole pixel as the game cuts it (`0x0042DAF1` on).
fn along(value: i32) i32 {
    return @divTrunc(value * Slider.travel, hog_snd.loudest);
}

/// The knob under `at`, of `volumes`' knobs.
fn knobAt(volumes: Volumes, at: [2]i32) ?Volume {
    for (std.enums.values(Volume)) |volume| if (sliderOf(volume).knob(along(level(volumes, volume))).holds(at)) return volume;
    return null;
}

fn level(volumes: Volumes, volume: Volume) i32 {
    return switch (volume) {
        inline else => |named| @field(volumes, @tagName(named)),
    };
}

fn setLevel(volumes: *Volumes, volume: Volume, value: i32) void {
    switch (volume) {
        inline else => |named| @field(volumes, @tagName(named)) = value,
    }
}

const Recorder = settings.testing.Recorder;

test "the knobs change the volumes as they are dragged" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var file: profile.File = .{ .arena = arena.allocator(), .profile = .empty };
    var devices: input.Devices = .{};
    var sound: hog_snd.Sound = .{};
    var context: Context = .{ .pointer = .{}, .devices = &devices, .settings_file = &file, .ticks = 0, .sound = &sound };
    var tab: Audio = .{};
    tab.enter(context);
    // The music's knob, at 80, stands from x 423: the pointer's button down on it holds it, and it
    // follows the pointer from the next pass, the volume with it.
    try std.testing.expectEqual(Item{ .knob = .music }, itemAt(context, .{ 430, 260 }).?);
    context.pointer = .{ .at = .{ 430, 260 }, .down = true };
    tab.slide(context);
    try std.testing.expectEqual(.music, tab.held.?);
    context.pointer.at = .{ 340, 262 };
    tab.slide(context);
    try std.testing.expectEqual(17, sound.volumes.music);
    // Past the track's start, nothing.
    context.pointer.at = .{ 100, 262 };
    tab.slide(context);
    try std.testing.expectEqual(0, sound.volumes.music);
    // Let go, it is held no more; CANCEL CHANGES puts the volume back, and leaving writes it.
    context.pointer.down = false;
    tab.slide(context);
    try std.testing.expectEqual(null, tab.held);
    tab.cancel(context);
    try std.testing.expectEqual(80, sound.volumes.music);
    sound.volumes.speech = 100;
    try tab.save(context);
    try std.testing.expectEqualStrings("100", file.profile.value("Sound", "Speechvolume").?);
}

test "3D SOUND's arrows and the check boxes change OpenReliant's options" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var file: profile.File = .{ .arena = arena.allocator(), .profile = .empty };
    var devices: input.Devices = .{};
    var sound: hog_snd.Sound = .{};
    var recorder: Recorder = .{};
    const context: Context = .{ .pointer = .{}, .devices = &devices, .settings_file = &file, .ticks = 0, .sound = &sound, .own = recorder.own() };
    var tab: Audio = .{};
    tab.enter(context);
    // The arrows step round AUTOMATIC, HEADPHONES and SPEAKERS, each step given to the driver.
    try std.testing.expectEqual(Item{ .step = .on }, itemAt(context, .{ 330, 380 }).?);
    tab.choose(.{ .step = .on }, context);
    try std.testing.expectEqual(.on, recorder.audio.hrtf);
    tab.choose(.{ .step = .back }, context);
    tab.choose(.{ .step = .back }, context);
    try std.testing.expectEqual(.off, recorder.audio.hrtf);
    tab.choose(.{ .check = .reverb }, context);
    try std.testing.expect(!recorder.audio.reverb);
    try std.testing.expectEqual(4, recorder.given);
    // RESET DEFAULTS sets them back, and the volumes, which it writes at once.
    sound.volumes.master = 3;
    try tab.reset(context);
    try std.testing.expectEqual(Own.Audio{}, recorder.audio);
    try std.testing.expectEqualStrings("127", file.profile.value("Sound", "Mastervolume").?);
    // With the software Miles, the HRTF and the reverb are dimmed, and stay as they are.
    recorder.audio = .{ .openal = false };
    tab.enter(context);
    tab.choose(.{ .step = .on }, context);
    tab.choose(.{ .check = .reverb }, context);
    try std.testing.expectEqual(Own.Hrtf.auto, recorder.audio.hrtf);
    try std.testing.expect(recorder.audio.reverb);
    tab.choose(.{ .check = .compressor }, context);
    try std.testing.expect(!recorder.audio.compressor);
}
