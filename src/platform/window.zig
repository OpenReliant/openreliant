//! The game's window, its events and its presentation, with SDL3: in place of the Win32 window and
//! message loop `WinMain` (`0x004A8B10`) runs, and of DirectDraw's flip.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("sdl");

const keyboard = @import("keyboard.zig");
const macos = @import("macos.zig");
const sdl = @import("sdl.zig");

pub const Error = sdl.Error;
const fail = sdl.fail;

/// What happened since the last frame.
pub const Event = union(enum) {
    quit,
    /// A key went down or up, by its DirectInput scan code (`keyboard.directInput`): the key's
    /// place on the keyboard, whatever it types. Keys DirectInput has no code for are left out.
    key: struct { scan: keyboard.Key, down: bool },
    /// A joystick or gamepad was plugged in or out (`joystick`).
    controllers,
    /// The window became the active one, or stopped being it (`WM_ACTIVATEAPP`).
    active: bool,
    /// The pointer moved over the window, to a place given as fractions of its size, by a movement
    /// in the mouse's own counts, which `holdMouse` keeps coming at the window's edges.
    pointer: struct { at: [2]f32, moved: [2]f32 },
    /// A mouse button went down or up: the left or the right one, which the game reads.
    button: struct { which: Button, down: bool },
    /// A character typed while the window takes text (`takeText`), as `WM_CHAR` gives one: each
    /// character of what the system's text input makes, and a backspace, 8, at each press of the
    /// key and at each of its repeats.
    typed: u21,

    pub const Button = enum { left, right };

    /// The character a backspace types.
    pub const backspace = 8;
};

pub const Window = struct {
    handle: *c.SDL_Window,
    gpu: *c.SDL_GPUDevice,
    /// A frame drawn in memory, and the texture it goes up to on its way to the screen.
    frame: ?struct { width: u32, height: u32, transfer: *c.SDL_GPUTransferBuffer, texture: *c.SDL_GPUTexture } = null,
    /// Whether it takes text (`takeText`), the text the system's input made that `poll` has yet to
    /// hand out a character at a time, and a backspace to hand out after its key.
    taking_text: bool = false,
    text: [text_room]u8 = undefined,
    text_left: []const u8 = &.{},
    backspace_owed: bool = false,
    /// When the pointer last moved over the window (`nanoseconds`), and whether the system's
    /// pointer shows over it (`showPointer`).
    pointer_moved_at: u64 = 0,
    pointer_shown: bool = true,

    /// The most of one of the system's text events kept, the room SDL gives one.
    const text_room = 32;

    /// A window of `width` by `height` points, or filling the display, drawn into at the display's
    /// own density.
    pub fn open(title: [*:0]const u8, width: u32, height: u32, fullscreen: bool) Error!Window {
        if (builtin.os.tag == .macos) macos.ignoreSavedState();
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return fail("SDL_Init");
        errdefer c.SDL_Quit();
        var flags: c.SDL_WindowFlags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        if (fullscreen) flags |= c.SDL_WINDOW_FULLSCREEN;
        const handle = c.SDL_CreateWindow(title, @intCast(width), @intCast(height), flags) orelse return fail("SDL_CreateWindow");
        errdefer c.SDL_DestroyWindow(handle);
        // The formats the game's shader comes in: Vulkan's everywhere it runs, Metal's on Apple's
        // systems.
        const formats = c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_MSL;
        const gpu = c.SDL_CreateGPUDevice(formats, false, null) orelse return fail("SDL_CreateGPUDevice");
        errdefer c.SDL_DestroyGPUDevice(gpu);
        if (!c.SDL_ClaimWindowForGPUDevice(gpu, handle)) return fail("SDL_ClaimWindowForGPUDevice");
        return .{ .handle = handle, .gpu = gpu, .pointer_moved_at = nanoseconds() };
    }

    pub fn close(window: *Window) void {
        window.releaseFrame();
        c.SDL_ReleaseWindowFromGPUDevice(window.gpu, window.handle);
        c.SDL_DestroyGPUDevice(window.gpu);
        c.SDL_DestroyWindow(window.handle);
        c.SDL_Quit();
    }

    /// The window's size in points, which the game draws at.
    pub fn size(window: Window) [2]u32 {
        var width: c_int = 0;
        var height: c_int = 0;
        _ = c.SDL_GetWindowSize(window.handle, &width, &height);
        return .{ @intCast(@max(width, 1)), @intCast(@max(height, 1)) };
    }

    /// Gathers the system's events into the window's queue, where they wait for `poll`, so that the
    /// system sees the window answer while the game loads, as the game's message pump has it.
    pub fn pump(window: *Window) void {
        _ = window;
        c.SDL_PumpEvents();
    }

    /// The next event waiting, or null. Alt and Enter, added for OpenReliant, switch between the
    /// window and the full screen, and do not reach the game.
    pub fn poll(window: *Window) ?Event {
        if (window.backspace_owed) {
            window.backspace_owed = false;
            return .{ .typed = Event.backspace };
        }
        if (window.nextTyped()) |character| return .{ .typed = character };
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => return .quit,
                c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                    if (event.key.scancode == c.SDL_SCANCODE_RETURN and event.key.mod & c.SDL_KMOD_ALT != 0) {
                        if (event.key.down and !event.key.repeat) window.toggleFullscreen();
                        continue;
                    }
                    if (window.taking_text and event.key.down and event.key.scancode == c.SDL_SCANCODE_BACKSPACE) window.backspace_owed = true;
                    const scan = keyboard.directInput(event.key.scancode) orelse continue;
                    return .{ .key = .{ .scan = scan, .down = event.key.down } };
                },
                c.SDL_EVENT_TEXT_INPUT => {
                    if (!window.taking_text) continue;
                    const made = std.mem.span(event.text.text);
                    const kept = made[0..@min(made.len, text_room)];
                    @memcpy(window.text[0..kept.len], kept);
                    window.text_left = window.text[0..kept.len];
                    if (window.nextTyped()) |character| return .{ .typed = character };
                },
                c.SDL_EVENT_JOYSTICK_ADDED, c.SDL_EVENT_JOYSTICK_REMOVED => return .controllers,
                c.SDL_EVENT_WINDOW_FOCUS_GAINED => return .{ .active = true },
                c.SDL_EVENT_WINDOW_FOCUS_LOST => return .{ .active = false },
                c.SDL_EVENT_MOUSE_MOTION => {
                    window.pointer_moved_at = nanoseconds();
                    const points = window.size();
                    return .{ .pointer = .{
                        .at = .{
                            event.motion.x / @as(f32, @floatFromInt(points[0])),
                            event.motion.y / @as(f32, @floatFromInt(points[1])),
                        },
                        .moved = .{ event.motion.xrel, event.motion.yrel },
                    } };
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    const which: Event.Button = switch (event.button.button) {
                        c.SDL_BUTTON_LEFT => .left,
                        c.SDL_BUTTON_RIGHT => .right,
                        else => continue,
                    };
                    return .{ .button = .{ .which = which, .down = event.button.down } };
                },
                else => {},
            }
        }
        return null;
    }

    /// The next character of the text the system's input made, or null once it is all handed out.
    /// A byte that starts no character of UTF-8, and a character cut short, are passed over.
    fn nextTyped(window: *Window) ?u21 {
        while (window.text_left.len > 0) {
            const length = std.unicode.utf8ByteSequenceLength(window.text_left[0]) catch {
                window.text_left = window.text_left[1..];
                continue;
            };
            if (length > window.text_left.len) {
                window.text_left = &.{};
                return null;
            }
            const bytes = window.text_left[0..length];
            window.text_left = window.text_left[length..];
            return std.unicode.utf8Decode(bytes) catch continue;
        }
        return null;
    }

    /// Takes the text typed into the window from now on, character by character (`Event.typed`),
    /// or stops taking it, as a line to type into comes and goes. The system may show its own
    /// keyboard or its input's window while the window takes text.
    pub fn takeText(window: *Window, on: bool) void {
        if (window.taking_text == on) return;
        window.taking_text = on;
        window.text_left = &.{};
        window.backspace_owed = false;
        _ = if (on) c.SDL_StartTextInput(window.handle) else c.SDL_StopTextInput(window.handle);
    }

    /// Shows the system's pointer over the window, or hides it: where the game draws its own
    /// (`drawn`), in full screen, and once it has rested over the window (`pointerShows`). It
    /// shows again as soon as it moves.
    pub fn showPointer(window: *Window, drawn: bool) void {
        const shown = pointerShows(drawn, window.fillsDisplay(), nanoseconds() -| window.pointer_moved_at);
        if (shown == window.pointer_shown) return;
        window.pointer_shown = shown;
        _ = if (shown) c.SDL_ShowCursor() else c.SDL_HideCursor();
    }

    /// Holds the mouse to the window, its pointer hidden, as DirectInput's exclusive mouse is held
    /// while the game is in the foreground, or lets it go.
    pub fn holdMouse(window: Window, held: bool) Error!void {
        if (!c.SDL_SetWindowRelativeMouseMode(window.handle, held)) return fail("SDL_SetWindowRelativeMouseMode");
    }

    /// Puts a frame drawn in memory, rows of red, green, blue and alpha from the top, on the
    /// screen, scaled to the window.
    pub fn present(window: *Window, rgba: []const u8, width: u32, height: u32) Error!void {
        const frame = try window.frameOf(width, height);
        const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(window.gpu, frame.transfer, true) orelse return fail("SDL_MapGPUTransferBuffer"));
        @memcpy(mapped[0 .. width * height * 4], rgba[0 .. width * height * 4]);
        c.SDL_UnmapGPUTransferBuffer(window.gpu, frame.transfer);

        const commands = c.SDL_AcquireGPUCommandBuffer(window.gpu) orelse return fail("SDL_AcquireGPUCommandBuffer");
        const copy = c.SDL_BeginGPUCopyPass(commands);
        c.SDL_UploadToGPUTexture(
            copy,
            &.{ .transfer_buffer = frame.transfer, .offset = 0, .pixels_per_row = width, .rows_per_layer = height },
            &.{ .texture = frame.texture, .w = width, .h = height, .d = 1 },
            true,
        );
        c.SDL_EndGPUCopyPass(copy);
        var target: ?*c.SDL_GPUTexture = null;
        var target_width: u32 = 0;
        var target_height: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(commands, window.handle, &target, &target_width, &target_height)) {
            _ = c.SDL_CancelGPUCommandBuffer(commands);
            return fail("SDL_WaitAndAcquireGPUSwapchainTexture");
        }
        if (target) |swapchain| {
            var blit = std.mem.zeroes(c.SDL_GPUBlitInfo);
            blit.source = .{ .texture = frame.texture, .w = width, .h = height };
            blit.destination = .{ .texture = swapchain, .w = target_width, .h = target_height };
            blit.load_op = c.SDL_GPU_LOADOP_DONT_CARE;
            blit.filter = c.SDL_GPU_FILTER_LINEAR;
            c.SDL_BlitGPUTexture(commands, &blit);
        }
        if (!c.SDL_SubmitGPUCommandBuffer(commands)) return fail("SDL_SubmitGPUCommandBuffer");
    }

    /// The texture a frame of `width` by `height` goes up to, made again when the size changes.
    fn frameOf(window: *Window, width: u32, height: u32) Error!@typeInfo(@TypeOf(window.frame)).optional.child {
        if (window.frame) |frame| {
            if (frame.width == width and frame.height == height) return frame;
            window.releaseFrame();
        }
        const transfer = c.SDL_CreateGPUTransferBuffer(window.gpu, &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = width * height * 4,
            .props = 0,
        }) orelse return fail("SDL_CreateGPUTransferBuffer");
        errdefer c.SDL_ReleaseGPUTransferBuffer(window.gpu, transfer);
        var info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
        info.type = c.SDL_GPU_TEXTURETYPE_2D;
        info.format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        info.usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER;
        info.width = width;
        info.height = height;
        info.layer_count_or_depth = 1;
        info.num_levels = 1;
        const texture = c.SDL_CreateGPUTexture(window.gpu, &info) orelse return fail("SDL_CreateGPUTexture");
        window.frame = .{ .width = width, .height = height, .transfer = transfer, .texture = texture };
        return window.frame.?;
    }

    fn releaseFrame(window: *Window) void {
        const frame = window.frame orelse return;
        c.SDL_ReleaseGPUTexture(window.gpu, frame.texture);
        c.SDL_ReleaseGPUTransferBuffer(window.gpu, frame.transfer);
        window.frame = null;
    }

    /// Whether the window fills the display.
    pub fn fillsDisplay(window: Window) bool {
        return c.SDL_GetWindowFlags(window.handle) & c.SDL_WINDOW_FULLSCREEN != 0;
    }

    fn toggleFullscreen(window: *Window) void {
        if (!c.SDL_SetWindowFullscreen(window.handle, !window.fillsDisplay())) std.log.scoped(.sdl).warn("SDL_SetWindowFullscreen: {s}", .{c.SDL_GetError()});
    }

    /// The refresh rate of the display the window is on, in frames a second, or null where SDL
    /// does not know it.
    pub fn refreshRate(window: Window) ?f32 {
        const display = c.SDL_GetDisplayForWindow(window.handle);
        if (display == 0) return null;
        const mode = c.SDL_GetCurrentDisplayMode(display);
        if (mode == null or !(mode.*.refresh_rate > 0)) return null;
        return mode.*.refresh_rate;
    }
};

/// Holds frames to a rate where the display does not: with vsync off, or at a rate asked for.
pub const Pacer = struct {
    /// When the next frame may start, in nanoseconds on SDL's clock.
    next: u64 = 0,

    /// Waits until the next frame may start at `rate` frames a second.
    pub fn wait(pacer: *Pacer, rate: f32) void {
        const wanted = pacer.delay(c.SDL_GetTicksNS(), rate);
        if (wanted > 0) c.SDL_DelayPrecise(wanted);
    }

    /// How long to wait at `now` for the next frame to start at `rate` frames a second: until a
    /// period after the last started, or not at all when this frame ran late, the next then
    /// starting a period from now.
    fn delay(pacer: *Pacer, now: u64, rate: f32) u64 {
        const period: u64 = @intFromFloat(std.time.ns_per_s / std.math.clamp(@as(f64, rate), 1, 10_000));
        const start = @max(pacer.next, now);
        pacer.next = start + period;
        return start - now;
    }
};

test Pacer {
    var pacer: Pacer = .{};
    // At 100 frames a second: the first frame goes at once, and a quick one waits out its period.
    try std.testing.expectEqual(0, pacer.delay(1_000_000_000, 100));
    try std.testing.expectEqual(6_000_000, pacer.delay(1_004_000_000, 100));
    // A late frame goes at once, and the next is timed from it.
    try std.testing.expectEqual(0, pacer.delay(1_050_000_000, 100));
    try std.testing.expectEqual(10_000_000, pacer.delay(1_050_000_000, 100));
}

/// How long the pointer rests over a window before the system's pointer hides.
const pointer_rest: u64 = 2 * std.time.ns_per_s;

/// Whether the system's pointer shows over the window: not where the game draws its own (`drawn`),
/// nor in full screen, where the original's screen showed none, nor once it has rested for
/// `pointer_rest` (`rested` nanoseconds).
fn pointerShows(drawn: bool, full_screen: bool, rested: u64) bool {
    return !drawn and !full_screen and rested < pointer_rest;
}

test pointerShows {
    // In a window, the pointer shows while it moves, and hides once it rests.
    try std.testing.expect(pointerShows(false, false, 0));
    try std.testing.expect(pointerShows(false, false, pointer_rest - 1));
    try std.testing.expect(!pointerShows(false, false, pointer_rest));
    // Never where the game draws its own, nor in full screen.
    try std.testing.expect(!pointerShows(true, false, 0));
    try std.testing.expect(!pointerShows(false, true, 0));
}

/// Nanoseconds since SDL started, which the game's ticks are counted from (`ticks`).
pub fn nanoseconds() u64 {
    return c.SDL_GetTicksNS();
}

/// Nanoseconds in each of the game's ticks: `tick_timer` runs 100 times a second.
pub const tick_nanoseconds = 10_000_000;

/// Hundredths of a second since SDL started: the game's ticks.
pub fn ticks() u64 {
    return nanoseconds() / tick_nanoseconds;
}
