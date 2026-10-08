//! The scripting console as the driver shows it (`scripting.console`), while a mod has scripts.
//! F11 brings it up over the front end, the Reliant's rooms or the mission, and takes it away; it
//! pauses the mission. While it's up it takes the keyboard and the characters typed, and it's
//! drawn last over the frame.

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const scripting = @import("scripting");
const version = @import("version");
const engine = openreliant.engine;
const game = engine.game;
const input = engine.input;
const canvas = game.interface.canvas;
const device = engine.surrender.srd3d.device;
const drawn = @import("presenter.zig").drawn;
const console_module = scripting.console;
const screen = console_module.screen;
const Mod = game.bigfile.mods.Mod;

pub const Driver = struct {
    console: console_module.Console,
    /// The fonts and shapes it draws with, opened the first time it comes up.
    resources: ?screen.Resources = null,
    pointer: canvas.Pointer = .{},
    /// Whether bringing it up paused the mission, which taking it away resumes.
    paused_mission: bool = false,
    /// The window's ticks at the last pass, which the pointer's animation runs by.
    ticks: u64 = 0,
    /// Watches the folder mods' scripts and shaders, which reload the scripts when saved.
    watch: console_module.Watch = .{},

    /// The console, where a mod of `opened` has scripts.
    pub fn init(gpa: Allocator, opened: []const Mod) ?Driver {
        if (!console_module.available(opened)) return null;
        return .{ .console = .{ .gpa = gpa, .mods = opened } };
    }

    pub fn deinit(driver: *Driver) void {
        if (driver.resources) |*open| open.close();
    }

    pub fn isUp(driver: *const Driver) bool {
        return driver.console.open;
    }

    /// Whether F11 has just been pressed, which brings the console up.
    pub fn asked(keyboard: *input.Keyboard) bool {
        return keyboard.pressed(@backingInt(console_module.key), .none, true);
    }

    /// Shows the console, with its fonts and shapes from `archive`, and lets go of the characters
    /// typed before.
    pub fn show(driver: *Driver, gpa: Allocator, archive: *const game.bigfile.Hog, outlines: ?*game.hud.outline.Outlines, typed: *game.winmain.Typed) !void {
        if (driver.resources == null) driver.resources = try .open(gpa, archive, outlines);
        typed.clear();
        driver.console.show();
        driver.ticks = platform.window.ticks();
    }

    /// Shows the console with its fonts and shapes from `pausing`'s archive. A mission that runs,
    /// `mission`, pauses as the pause menu pauses it.
    pub fn bringUp(driver: *Driver, pausing: game.main.Pausing, mission: bool, typed: *game.winmain.Typed) !void {
        try driver.show(pausing.gpa, &pausing.archive, pausing.outlines, typed);
        if (mission and !pausing.clock.paused) {
            try game.main.pause(pausing, true);
            driver.paused_mission = true;
        }
    }

    /// Takes the console away.
    pub fn hide(driver: *Driver) void {
        driver.console.open = false;
    }

    /// Takes the console away, and resumes the mission if bringing it up paused it.
    pub fn takeAway(driver: *Driver, pausing: game.main.Pausing) !void {
        driver.hide();
        if (driver.paused_mission) try game.main.pause(pausing, false);
        driver.paused_mission = false;
    }

    /// What a pass of the console asks for: to take it away, or to reload the scripts.
    pub const Asked = enum { close, reload };

    /// A pass of the console while it's up, in a window `window` pixels across and down. A line
    /// typed runs in `scripts`. Returns what the pass asks for, if anything.
    pub fn frame(driver: *Driver, devices: *input.Devices, typed: *game.winmain.Typed, window: [2]u32, scripts: console_module.Scripts) Allocator.Error!?Asked {
        const ticks = platform.window.ticks();
        const elapsed = std.math.cast(i32, ticks -| driver.ticks) orelse std.math.maxInt(i32);
        driver.ticks = ticks;
        driver.pointer.update(&devices.mouse, window, canvas.fitted, elapsed);
        const action = screen.frame(&driver.console, .{
            .keyboard = &devices.keyboard,
            .typed = typed,
            .pointer = driver.pointer,
            .ticks = @truncate(ticks),
        }) orelse return null;
        return switch (action) {
            .close => .close,
            .reload => .reload,
            .run => if (try driver.console.run(scripts)) |request| switch (request) {
                .reload => .reload,
            } else null,
        };
    }

    /// Draws the console over the frame drawn into `target`, a window `window` pixels across and
    /// down, while it's up, over `backdrop`.
    pub fn draw(driver: *Driver, target: device.Device, window: [2]u32, strings: *const game.language.Language, backdrop: screen.Backdrop) Allocator.Error!void {
        if (!driver.console.open) return;
        const resources = if (driver.resources) |*open| open else return;
        try drawn(screen.draw(&driver.console, .{
            .gpa = resources.gpa,
            .target = target,
            .window = window,
            .fonts = resources.fonts(),
            .strings = strings,
            .version = version.string,
        }, &resources.shapes.art, driver.pointer, backdrop));
    }
};
