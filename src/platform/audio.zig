//! The game's sound output, with SDL3: in place of the wave-out device Miles opened
//! (`AIL_waveOutOpen`). A stream on the default playback device pulls the mix on SDL's audio
//! thread, at the device's own rate, from one of two players of Miles's calls: OpenAL Soft
//! ([`openal.zig`](openal.zig)), in as many channels as the device has, or OpenReliant's software
//! Miles (`engine.mss.Mixer`), in stereo. The master bus (`engine.mss.master`) comes last.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const c = @import("sdl");
const mss = @import("openreliant").engine.mss;
const macos = @import("macos.zig");
const sdl = @import("sdl.zig");

pub const openal = @import("openal.zig");

pub const Error = sdl.Error || Allocator.Error;
const fail = sdl.fail;

const log = std.log.scoped(.sdl);

/// The frames the callback renders at a time.
const chunk = 512;

/// What plays Miles's calls.
pub const Player = union(enum) {
    /// OpenAL Soft, with these settings.
    openal: openal.Settings,
    /// OpenReliant's software Miles, as `--original` has it.
    software,
};

pub const Options = struct {
    player: Player = .{ .openal = .{} },
    /// The master bus, or null to leave it out.
    master: ?mss.master.Settings = .{},
};

pub const Output = struct {
    gpa: Allocator,
    stream: *c.SDL_AudioStream,
    rate: u32,
    channels: u8,
    source: Source,
    master: ?mss.master.Master,
    /// When `update` last looked at what the output is, in SDL's milliseconds.
    looked_at: u64 = 0,

    const Source = union(enum) {
        openal: *openal.Renderer,
        software: mss.Mixer,
    };

    /// Opens the default playback device and has it play what the player makes of Miles's calls
    /// at the device's rate. When OpenAL Soft cannot start, the software Miles plays instead.
    pub fn create(gpa: Allocator, options: Options) Error!*Output {
        if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) return fail("SDL_InitSubSystem");
        errdefer c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
        var device: c.SDL_AudioSpec = .{ .format = c.SDL_AUDIO_F32, .channels = 2, .freq = 44100 };
        var device_frames: c_int = 0;
        _ = c.SDL_GetAudioDeviceFormat(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &device, &device_frames);
        const rate: u32 = @intCast(@max(device.freq, 8000));

        const output = try gpa.create(Output);
        errdefer gpa.destroy(output);
        output.* = .{ .gpa = gpa, .stream = undefined, .rate = rate, .channels = 2, .source = .{ .software = .init(rate) }, .master = null };
        switch (options.player) {
            .openal => |settings| if (openal.Renderer.create(gpa, rate, @intCast(std.math.clamp(device.channels, 1, mss.master.max_channels)), settings, headphones())) |renderer| {
                output.source = .{ .openal = renderer };
                output.channels = renderer.channels;
            } else |err| log.warn("OpenAL Soft cannot start ({s}); the software mixer plays instead", .{@errorName(err)}),
            .software => {},
        }
        errdefer if (output.source == .openal) output.source.openal.destroy();
        if (options.master) |settings| output.master = .init(rate, output.channels, settings);

        const spec: c.SDL_AudioSpec = .{ .format = c.SDL_AUDIO_F32, .channels = output.channels, .freq = @intCast(rate) };
        output.stream = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, feed, output) orelse return fail("SDL_OpenAudioDeviceStream");
        // The device starts paused, so nothing plays before the player is ready.
        if (output.source == .software) output.source.software.lock = lockOf(output.stream);
        if (!c.SDL_ResumeAudioStreamDevice(output.stream)) {
            c.SDL_DestroyAudioStream(output.stream);
            return fail("SDL_ResumeAudioStreamDevice");
        }
        return output;
    }

    pub fn destroy(output: *Output) void {
        c.SDL_DestroyAudioStream(output.stream);
        switch (output.source) {
            .openal => |renderer| renderer.destroy(),
            .software => {},
        }
        c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
        output.gpa.destroy(output);
    }

    /// Once a frame: now and then, whether the output has changed between headphones and anything
    /// else, for OpenAL's HRTF.
    pub fn update(output: *Output) void {
        const renderer = switch (output.source) {
            .openal => |renderer| renderer,
            .software => return,
        };
        if (renderer.settings.hrtf != .auto or renderer.channels != 2) return;
        const now = c.SDL_GetTicks();
        if (now -% output.looked_at < 1000) return;
        output.looked_at = now;
        const on = headphones();
        if (on == renderer.hrtf) return;
        _ = c.SDL_LockAudioStream(output.stream);
        defer _ = c.SDL_UnlockAudioStream(output.stream);
        renderer.followOutput(on);
    }

    /// Sets when OpenAL Soft renders for headphones, where it plays.
    pub fn setHrtf(output: *Output, hrtf: openal.Hrtf) void {
        const renderer = switch (output.source) {
            .openal => |renderer| renderer,
            .software => return,
        };
        _ = c.SDL_LockAudioStream(output.stream);
        defer _ = c.SDL_UnlockAudioStream(output.stream);
        renderer.setHrtf(hrtf, headphones());
    }

    /// Turns OpenAL Soft's reverbs on or off, where it plays.
    pub fn setReverb(output: *Output, on: bool) void {
        const renderer = switch (output.source) {
            .openal => |renderer| renderer,
            .software => return,
        };
        _ = c.SDL_LockAudioStream(output.stream);
        defer _ = c.SDL_UnlockAudioStream(output.stream);
        renderer.setReverb(on);
    }

    /// Sets the master bus to `settings`, or leaves it out.
    pub fn setMaster(output: *Output, settings: ?mss.master.Settings) void {
        _ = c.SDL_LockAudioStream(output.stream);
        defer _ = c.SDL_UnlockAudioStream(output.stream);
        output.master = if (settings) |chosen| .init(output.rate, output.channels, chosen) else null;
    }

    /// What the game calls.
    pub fn driver(output: *Output) mss.Driver {
        return switch (output.source) {
            .openal => |renderer| renderer.driver(),
            .software => |*mixer| mixer.driver(),
        };
    }

    /// Renders `samples.len / channels` frames, through the master bus.
    fn render(output: *Output, samples: []f32) void {
        switch (output.source) {
            .openal => |renderer| renderer.render(samples),
            .software => |*mixer| mixer.mix(std.mem.bytesAsSlice([2]f32, std.mem.sliceAsBytes(samples))),
        }
        if (output.master) |*bus| bus.process(samples);
    }
};

/// Whether the default playback device is a pair of headphones, as far as the system says: Core
/// Audio on macOS, and everywhere the device's name.
fn headphones() bool {
    if (builtin.os.tag == .macos and macos.outputIsHeadphones()) return true;
    const name = c.SDL_GetAudioDeviceName(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK) orelse return false;
    return namesHeadphones(std.mem.span(name));
}

/// Whether a device's name makes it headphones, as Windows names them ("Headphones (...)",
/// "Headset Earphone (...)") and as the common models are named.
fn namesHeadphones(name: []const u8) bool {
    const words = [_][]const u8{ "headphone", "headset", "earphone", "airpods", "buds" };
    for (words) |word| {
        if (std.ascii.indexOfIgnoreCase(name, word) != null) return true;
    }
    return false;
}

test namesHeadphones {
    try std.testing.expect(namesHeadphones("Headphones (WH-1000XM4 Stereo)"));
    try std.testing.expect(namesHeadphones("AirPods Pro"));
    try std.testing.expect(namesHeadphones("Galaxy Buds2"));
    try std.testing.expect(!namesHeadphones("MacBook Pro Speakers"));
    try std.testing.expect(!namesHeadphones("Speakers (Realtek(R) Audio)"));
}

/// The stream's own lock, which SDL holds while it asks for more.
fn lockOf(stream: *c.SDL_AudioStream) mss.Lock {
    return .{ .context = stream, .acquire_fn = acquire, .release_fn = release };
}

fn acquire(context: ?*anyopaque) void {
    _ = c.SDL_LockAudioStream(@ptrCast(context));
}

fn release(context: ?*anyopaque) void {
    _ = c.SDL_UnlockAudioStream(@ptrCast(context));
}

/// SDL's call for `additional` more bytes: the mix, a chunk at a time, up to a second's.
fn feed(userdata: ?*anyopaque, stream: ?*c.SDL_AudioStream, additional: c_int, total: c_int) callconv(.c) void {
    _ = total;
    const output: *Output = @ptrCast(@alignCast(userdata));
    const channels: usize = output.channels;
    const bytes: usize = @intCast(@max(additional, 0));
    var frames: usize = @min(std.math.divCeil(usize, bytes, channels * @sizeOf(f32)) catch 0, output.rate);
    var buffer: [chunk * mss.master.max_channels]f32 = undefined;
    while (frames > 0) {
        const count: usize = @min(frames, chunk);
        const samples = buffer[0 .. count * channels];
        output.render(samples);
        if (!c.SDL_PutAudioStreamData(stream, samples.ptr, @intCast(samples.len * @sizeOf(f32)))) return;
        frames -= count;
    }
}

/// An output with no device behind it: a stream that takes what the callback puts, as the
/// device's would.
fn testOutput(source: Output.Source, channels: u8, master: ?mss.master.Settings) !Output {
    const spec: c.SDL_AudioSpec = .{ .format = c.SDL_AUDIO_F32, .channels = channels, .freq = 22050 };
    const stream = c.SDL_CreateAudioStream(&spec, &spec) orelse return error.SkipZigTest;
    return .{
        .gpa = std.testing.allocator,
        .stream = stream,
        .rate = 22050,
        .channels = channels,
        .source = source,
        .master = if (master) |settings| .init(22050, channels, settings) else null,
    };
}

const test_file = @import("openreliant").wave.testing.pcm(&std.mem.toBytes([_]i16{16384} ** 4096));

test "feed from the software mixer" {
    var output = try testOutput(.{ .software = .init(22050) }, 2, null);
    defer c.SDL_DestroyAudioStream(output.stream);
    output.source.software.lock = lockOf(output.stream);
    const driver = output.driver();
    const sample = driver.allocateSample().?;
    try std.testing.expect(driver.setSampleFile(sample, test_file));
    driver.startSample(sample);

    feed(&output, output.stream, 3 * @sizeOf([2]f32), 0);
    try std.testing.expectEqual(3 * @sizeOf([2]f32), c.SDL_GetAudioStreamAvailable(output.stream));
    var got: [3][2]f32 = undefined;
    try std.testing.expectEqual(@sizeOf(@TypeOf(got)), c.SDL_GetAudioStreamData(output.stream, &got, @sizeOf(@TypeOf(got))));
    try std.testing.expectEqual([2]f32{ 0.5, 0.5 }, got[0]);
}

test "feed from OpenAL Soft through the master bus" {
    const renderer = openal.Renderer.create(std.testing.allocator, 22050, 2, .{}, false) catch return error.SkipZigTest;
    defer renderer.destroy();
    var output = try testOutput(.{ .openal = renderer }, 2, .{});
    defer c.SDL_DestroyAudioStream(output.stream);
    const driver = output.driver();
    // Four loud streams at once, and still under the ceiling.
    for (0..4) |_| {
        const music = driver.openStream(test_file).?;
        driver.startStream(music);
    }

    const frames = 2048;
    feed(&output, output.stream, frames * @sizeOf([2]f32), 0);
    var got: [frames][2]f32 = undefined;
    try std.testing.expectEqual(@sizeOf(@TypeOf(got)), c.SDL_GetAudioStreamData(output.stream, &got, @sizeOf(@TypeOf(got))));
    var highest: f32 = 0;
    for (got) |frame| highest = @max(highest, @abs(frame[0]), @abs(frame[1]));
    try std.testing.expect(highest > 0.1);
    try std.testing.expect(highest <= std.math.pow(f32, 10, -0.3 / 20.0) + 1e-6);
}
