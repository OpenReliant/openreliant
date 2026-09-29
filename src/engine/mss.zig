//! The Miles Sound System (`MSS32.DLL`), as far as the game calls it: a digital driver that mixes
//! samples, 3D samples and streams of WAVE sounds. OpenReliant's own stand-in, in software: the
//! library is not the game's, and nothing of it is carried over but the calls' meanings. Each
//! function stands for the `AIL_` call it names; the game's code in
//! [`game/hog_snd.zig`](game/hog_snd.zig) makes them as it made Miles's.
//!
//! `Driver` is what the game calls: an interface two drivers stand behind, as the renderer's device
//! has two. `Mixer` mixes in software, plainly, as Miles is taken to have mixed; the platform's
//! OpenAL renderer places the sounds with OpenAL Soft. The platform plays either on a thread of its
//! own, so the mixer holds the platform's `Lock` through each call; `Mixer.mix` expects its caller
//! to hold it. Three calls are not Miles's, the listener's velocity, a 3D sample's radius and a
//! sample's room: they serve OpenAL's improvements, and the software mixer, the reference, leaves
//! them out.
//!
//! Volumes and pans run from 0 to 127 (`max_level`), a pan of 64 in the middle (`centre_pan`), as
//! Miles's do. How Miles turned them into gains is not known here: OpenReliant takes a volume's
//! share of 127 as its gain (`gain`), and a pan as a balance that keeps the middle at full volume
//! in both ears.

const std = @import("std");

pub const voice = @import("mss/voice.zig");
pub const positional = @import("mss/positional.zig");
pub const master = @import("mss/master.zig");
pub const loudness = @import("mss/loudness.zig");

pub const Status = voice.Status;
pub const Vector = positional.Vector;

/// A sample (`HSAMPLE`): a sound played as it is, with a volume and a pan.
pub const Sample = enum(u32) { _ };

/// A 3D sample (`H3DSAMPLE`): a sound placed around the listener.
pub const Sample3D = enum(u32) { _ };

/// A stream (`HSTREAM`): a long sound, such as a piece of music, that plays and loops as a sample
/// does, from a file of its own.
pub const Stream = enum(u32) { _ };

/// Not Miles's: where a sample is heard, for the reverbs OpenReliant adds.
pub const Room = enum {
    /// Nowhere in particular, with no reverb.
    none,
    /// The cockpit's cabin, for the ship's own voice.
    cockpit,
    /// What surrounds the camera, as the 3D sounds are (`Surroundings`): for a sound of the scene
    /// that plays as a sample, as a launch's hangar doors do.
    scene,
};

/// Not Miles's: what surrounds the camera, which the 3D sounds, and the samples of the scene
/// (`Room.scene`), ring in.
pub const Surroundings = enum {
    /// Space, as the game has it: the generic room it asks EAX for.
    space,
    /// A carrier's hangar, as a launch shows it from within.
    hangar,
    /// A carrier's inside, its rooms and its briefing room, which the pilot walks through between
    /// missions.
    inside,
};

/// What keeps the platform's mixing thread out while the game changes the driver.
pub const Lock = struct {
    context: ?*anyopaque = null,
    acquire_fn: *const fn (?*anyopaque) void = noop,
    release_fn: *const fn (?*anyopaque) void = noop,

    /// For a driver nothing mixes from another thread, as in the tests.
    pub const none: Lock = .{};

    fn noop(_: ?*anyopaque) void {}

    pub fn acquire(lock: Lock) void {
        lock.acquire_fn(lock.context);
    }

    pub fn release(lock: Lock) void {
        lock.release_fn(lock.context);
    }
};

/// The one 3D provider OpenReliant offers.
pub const provider_name = "Miles Fast 2D Positional Audio";

/// `AIL_3D_provider_attribute`'s "Maximum supported samples" for it.
pub const max_3d_samples = 32;

pub const max_samples = 32;
pub const max_streams = 4;

/// The top of Miles's volumes and pans, which run from 0: full volume, and a pan full right.
pub const max_level = 127;

/// A pan in the middle.
pub const centre_pan = 64;

/// A volume or a pan held within Miles's range, 0 to `max_level`.
pub fn clampLevel(level: i32) i32 {
    return std.math.clamp(level, 0, max_level);
}

/// The gain OpenReliant plays a volume at: its share of `max_level`.
pub fn gain(volume: i32) f32 {
    return @as(f32, @floatFromInt(volume)) / max_level;
}

/// The bytes a sound of `frames` frames of `channels` channels takes as 16-bit PCM, which is what
/// `AIL_3D_sample_length` counts.
pub fn pcmLength(frames: u32, channels: u32) u32 {
    return frames * channels * @sizeOf(i16);
}

test clampLevel {
    try std.testing.expectEqual(0, clampLevel(-5));
    try std.testing.expectEqual(80, clampLevel(80));
    try std.testing.expectEqual(max_level, clampLevel(300));
}

test gain {
    try std.testing.expectEqual(1, gain(max_level));
    try std.testing.expectEqual(0, gain(0));
    try std.testing.expectApproxEqAbs(0.5, gain(centre_pan), 0.01);
}

test pcmLength {
    try std.testing.expectEqual(4096, pcmLength(1024, 2));
    try std.testing.expectEqual(8, pcmLength(4, 1));
}

/// A digital driver (`HDIGDRIVER`, `AIL_waveOutOpen`) and its 3D provider: the calls the game makes
/// of Miles, each named for the `AIL_` function it stands for.
pub const Driver = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        allocateSample: *const fn (*anyopaque) ?Sample,
        initSample: *const fn (*anyopaque, Sample) void,
        setSampleFile: *const fn (*anyopaque, Sample, []const u8) bool,
        setSampleRoom: *const fn (*anyopaque, Sample, Room) void,
        setSurroundings: *const fn (*anyopaque, Surroundings) void,
        setSampleVolume: *const fn (*anyopaque, Sample, i32) void,
        sampleVolume: *const fn (*anyopaque, Sample) i32,
        setSamplePan: *const fn (*anyopaque, Sample, i32) void,
        setSamplePlaybackRate: *const fn (*anyopaque, Sample, u32) void,
        setSampleLoopCount: *const fn (*anyopaque, Sample, u32) void,
        startSample: *const fn (*anyopaque, Sample) void,
        stopSample: *const fn (*anyopaque, Sample) void,
        resumeSample: *const fn (*anyopaque, Sample) void,
        endSample: *const fn (*anyopaque, Sample) void,
        sampleStatus: *const fn (*anyopaque, Sample) Status,
        allocate3DSample: *const fn (*anyopaque) ?Sample3D,
        release3DSample: *const fn (*anyopaque, Sample3D) void,
        set3DSampleFile: *const fn (*anyopaque, Sample3D, []const u8) bool,
        set3DSampleVolume: *const fn (*anyopaque, Sample3D, i32) void,
        set3DSamplePlaybackRate: *const fn (*anyopaque, Sample3D, u32) void,
        set3DSampleLoopCount: *const fn (*anyopaque, Sample3D, u32) void,
        set3DPosition: *const fn (*anyopaque, Sample3D, Vector) void,
        set3DOrientation: *const fn (*anyopaque, Sample3D, Vector, Vector) void,
        set3DVelocity: *const fn (*anyopaque, Sample3D, Vector) void,
        set3DSampleDistances: *const fn (*anyopaque, Sample3D, f32, f32) void,
        set3DSampleCone: *const fn (*anyopaque, Sample3D, f32, f32, i32) void,
        set3DSampleRadius: *const fn (*anyopaque, Sample3D, f32) void,
        set3DListenerVelocity: *const fn (*anyopaque, Vector) void,
        start3DSample: *const fn (*anyopaque, Sample3D) void,
        stop3DSample: *const fn (*anyopaque, Sample3D) void,
        resume3DSample: *const fn (*anyopaque, Sample3D) void,
        end3DSample: *const fn (*anyopaque, Sample3D) void,
        sample3DStatus: *const fn (*anyopaque, Sample3D) Status,
        sample3DLength: *const fn (*anyopaque, Sample3D) u32,
        openStream: *const fn (*anyopaque, []const u8) ?Stream,
        closeStream: *const fn (*anyopaque, Stream) void,
        startStream: *const fn (*anyopaque, Stream) void,
        pauseStream: *const fn (*anyopaque, Stream, bool) void,
        streamStatus: *const fn (*anyopaque, Stream) Status,
        setStreamVolume: *const fn (*anyopaque, Stream, i32) void,
        setStreamLoopCount: *const fn (*anyopaque, Stream, u32) void,
        setStreamLoopBlock: *const fn (*anyopaque, Stream, i32, i32) void,
        setStreamPosition: *const fn (*anyopaque, Stream, i32) void,
        setStreamRoom: *const fn (*anyopaque, Stream, Room) void,
    };

    /// The driver `implementation` is: a `T` with a method for each of `VTable`'s, taking a `*T`.
    pub fn of(comptime T: type, implementation: *T) Driver {
        const table = comptime table: {
            var vtable: VTable = undefined;
            for (@typeInfo(VTable).@"struct".fields) |field| @field(vtable, field.name) = thunk(T, field.name, field.type);
            break :table vtable;
        };
        const holder = struct {
            const vtable = table;
        };
        return .{ .context = implementation, .vtable = &holder.vtable };
    }

    /// `T`'s method `name`, called through a pointer of type `F` that takes the `T` as
    /// `*anyopaque`.
    fn thunk(comptime T: type, comptime name: []const u8, comptime F: type) F {
        const params = @typeInfo(@typeInfo(F).pointer.child).@"fn".params;
        const R = @typeInfo(@typeInfo(F).pointer.child).@"fn".return_type.?;
        const method = @field(T, name);
        const Args = struct {
            fn self(context: *anyopaque) *T {
                return @ptrCast(@alignCast(context));
            }
        };
        return switch (params.len) {
            1 => &struct {
                fn call(c: *anyopaque) R {
                    return method(Args.self(c));
                }
            }.call,
            2 => &struct {
                fn call(c: *anyopaque, a: params[1].type.?) R {
                    return method(Args.self(c), a);
                }
            }.call,
            3 => &struct {
                fn call(c: *anyopaque, a: params[1].type.?, b: params[2].type.?) R {
                    return method(Args.self(c), a, b);
                }
            }.call,
            4 => &struct {
                fn call(c: *anyopaque, a: params[1].type.?, b: params[2].type.?, d: params[3].type.?) R {
                    return method(Args.self(c), a, b, d);
                }
            }.call,
            5 => &struct {
                fn call(c: *anyopaque, a: params[1].type.?, b: params[2].type.?, d: params[3].type.?, e: params[4].type.?) R {
                    return method(Args.self(c), a, b, d, e);
                }
            }.call,
            else => @compileError("no thunk for " ++ name),
        };
    }

    pub fn allocateSample(driver: Driver) ?Sample {
        return driver.vtable.allocateSample(driver.context);
    }
    pub fn initSample(driver: Driver, handle: Sample) void {
        driver.vtable.initSample(driver.context, handle);
    }
    pub fn setSampleFile(driver: Driver, handle: Sample, file: []const u8) bool {
        return driver.vtable.setSampleFile(driver.context, handle, file);
    }
    pub fn setSampleRoom(driver: Driver, handle: Sample, room: Room) void {
        driver.vtable.setSampleRoom(driver.context, handle, room);
    }
    pub fn setSurroundings(driver: Driver, surroundings: Surroundings) void {
        driver.vtable.setSurroundings(driver.context, surroundings);
    }
    pub fn setSampleVolume(driver: Driver, handle: Sample, volume: i32) void {
        driver.vtable.setSampleVolume(driver.context, handle, volume);
    }
    pub fn sampleVolume(driver: Driver, handle: Sample) i32 {
        return driver.vtable.sampleVolume(driver.context, handle);
    }
    pub fn setSamplePan(driver: Driver, handle: Sample, pan: i32) void {
        driver.vtable.setSamplePan(driver.context, handle, pan);
    }
    pub fn setSamplePlaybackRate(driver: Driver, handle: Sample, rate: u32) void {
        driver.vtable.setSamplePlaybackRate(driver.context, handle, rate);
    }
    pub fn setSampleLoopCount(driver: Driver, handle: Sample, count: u32) void {
        driver.vtable.setSampleLoopCount(driver.context, handle, count);
    }
    pub fn startSample(driver: Driver, handle: Sample) void {
        driver.vtable.startSample(driver.context, handle);
    }
    pub fn stopSample(driver: Driver, handle: Sample) void {
        driver.vtable.stopSample(driver.context, handle);
    }
    pub fn resumeSample(driver: Driver, handle: Sample) void {
        driver.vtable.resumeSample(driver.context, handle);
    }
    pub fn endSample(driver: Driver, handle: Sample) void {
        driver.vtable.endSample(driver.context, handle);
    }
    pub fn sampleStatus(driver: Driver, handle: Sample) Status {
        return driver.vtable.sampleStatus(driver.context, handle);
    }
    pub fn allocate3DSample(driver: Driver) ?Sample3D {
        return driver.vtable.allocate3DSample(driver.context);
    }
    pub fn release3DSample(driver: Driver, handle: Sample3D) void {
        driver.vtable.release3DSample(driver.context, handle);
    }
    pub fn set3DSampleFile(driver: Driver, handle: Sample3D, file: []const u8) bool {
        return driver.vtable.set3DSampleFile(driver.context, handle, file);
    }
    pub fn set3DSampleVolume(driver: Driver, handle: Sample3D, volume: i32) void {
        driver.vtable.set3DSampleVolume(driver.context, handle, volume);
    }
    pub fn set3DSamplePlaybackRate(driver: Driver, handle: Sample3D, rate: u32) void {
        driver.vtable.set3DSamplePlaybackRate(driver.context, handle, rate);
    }
    pub fn set3DSampleLoopCount(driver: Driver, handle: Sample3D, count: u32) void {
        driver.vtable.set3DSampleLoopCount(driver.context, handle, count);
    }
    pub fn set3DPosition(driver: Driver, handle: Sample3D, position: Vector) void {
        driver.vtable.set3DPosition(driver.context, handle, position);
    }
    pub fn set3DOrientation(driver: Driver, handle: Sample3D, face: Vector, up: Vector) void {
        driver.vtable.set3DOrientation(driver.context, handle, face, up);
    }
    pub fn set3DVelocity(driver: Driver, handle: Sample3D, velocity: Vector) void {
        driver.vtable.set3DVelocity(driver.context, handle, velocity);
    }
    pub fn set3DSampleDistances(driver: Driver, handle: Sample3D, max: f32, min: f32) void {
        driver.vtable.set3DSampleDistances(driver.context, handle, max, min);
    }
    pub fn set3DSampleCone(driver: Driver, handle: Sample3D, inner: f32, outer: f32, outer_volume: i32) void {
        driver.vtable.set3DSampleCone(driver.context, handle, inner, outer, outer_volume);
    }
    pub fn set3DSampleRadius(driver: Driver, handle: Sample3D, radius: f32) void {
        driver.vtable.set3DSampleRadius(driver.context, handle, radius);
    }
    pub fn set3DListenerVelocity(driver: Driver, velocity: Vector) void {
        driver.vtable.set3DListenerVelocity(driver.context, velocity);
    }
    pub fn start3DSample(driver: Driver, handle: Sample3D) void {
        driver.vtable.start3DSample(driver.context, handle);
    }
    pub fn stop3DSample(driver: Driver, handle: Sample3D) void {
        driver.vtable.stop3DSample(driver.context, handle);
    }
    pub fn resume3DSample(driver: Driver, handle: Sample3D) void {
        driver.vtable.resume3DSample(driver.context, handle);
    }
    pub fn end3DSample(driver: Driver, handle: Sample3D) void {
        driver.vtable.end3DSample(driver.context, handle);
    }
    pub fn sample3DStatus(driver: Driver, handle: Sample3D) Status {
        return driver.vtable.sample3DStatus(driver.context, handle);
    }
    pub fn sample3DLength(driver: Driver, handle: Sample3D) u32 {
        return driver.vtable.sample3DLength(driver.context, handle);
    }
    pub fn openStream(driver: Driver, file: []const u8) ?Stream {
        return driver.vtable.openStream(driver.context, file);
    }
    pub fn closeStream(driver: Driver, handle: Stream) void {
        driver.vtable.closeStream(driver.context, handle);
    }
    pub fn startStream(driver: Driver, handle: Stream) void {
        driver.vtable.startStream(driver.context, handle);
    }
    pub fn pauseStream(driver: Driver, handle: Stream, paused: bool) void {
        driver.vtable.pauseStream(driver.context, handle, paused);
    }
    pub fn streamStatus(driver: Driver, handle: Stream) Status {
        return driver.vtable.streamStatus(driver.context, handle);
    }
    pub fn setStreamVolume(driver: Driver, handle: Stream, volume: i32) void {
        driver.vtable.setStreamVolume(driver.context, handle, volume);
    }
    pub fn setStreamRoom(driver: Driver, handle: Stream, room: Room) void {
        driver.vtable.setStreamRoom(driver.context, handle, room);
    }
    pub fn setStreamLoopCount(driver: Driver, handle: Stream, count: u32) void {
        driver.vtable.setStreamLoopCount(driver.context, handle, count);
    }
    pub fn setStreamLoopBlock(driver: Driver, handle: Stream, start: i32, end: i32) void {
        driver.vtable.setStreamLoopBlock(driver.context, handle, start, end);
    }
    pub fn setStreamPosition(driver: Driver, handle: Stream, offset: i32) void {
        driver.vtable.setStreamPosition(driver.context, handle, offset);
    }
};

/// OpenReliant's own digital driver, in software: the handles and their mix, as plain as Miles's
/// own mixer is taken to have been. The reference the OpenAL renderer is measured against, and what
/// `--original` plays through.
pub const Mixer = struct {
    /// The output's frames a second.
    rate: u32,
    lock: Lock = .none,
    samples: [max_samples]Slot(SampleState) = @splat(.{}),
    samples_3d: [max_3d_samples]Slot(Sample3DState) = @splat(.{}),
    streams: [max_streams]Slot(StreamState) = @splat(.{}),

    fn Slot(comptime State: type) type {
        return struct {
            allocated: bool = false,
            state: State = .{},
        };
    }

    const SampleState = struct {
        playing: ?voice.Voice = null,
        volume: i32 = max_level,
        pan: i32 = centre_pan,
    };

    const Sample3DState = struct {
        playing: ?voice.Voice = null,
        volume: i32 = max_level,
        placing: positional.Placing = .{},
    };

    const StreamState = struct {
        playing: ?voice.Voice = null,
        volume: i32 = max_level,
        /// The frame it starts from.
        position: u32 = 0,
    };

    pub fn init(rate: u32) Mixer {
        return .{ .rate = rate };
    }

    /// The driver it is, for the game to call.
    pub fn driver(mixer: *Mixer) Driver {
        return .of(Mixer, mixer);
    }

    fn Handle(comptime State: type) type {
        return switch (State) {
            SampleState => Sample,
            Sample3DState => Sample3D,
            StreamState => Stream,
            else => unreachable,
        };
    }

    fn allocate(comptime State: type, slots: []Slot(State)) ?Handle(State) {
        for (slots, 0..) |*slot, index| {
            if (slot.allocated) continue;
            slot.* = .{ .allocated = true };
            return @enumFromInt(index);
        }
        return null;
    }

    fn statusOf(playing: ?voice.Voice) Status {
        return if (playing) |held| held.status else .done;
    }

    // --- Samples ---------------------------------------------------------------------------------

    /// `AIL_allocate_sample_handle`: a free sample, or null when all are taken.
    pub fn allocateSample(mixer: *Mixer) ?Sample {
        mixer.lock.acquire();
        defer mixer.lock.release();
        return allocate(SampleState, &mixer.samples);
    }

    fn sample(mixer: *Mixer, handle: Sample) *SampleState {
        return &mixer.samples[@intFromEnum(handle)].state;
    }

    /// `AIL_init_sample`: back to no sound, full volume and the middle.
    pub fn initSample(mixer: *Mixer, handle: Sample) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        mixer.sample(handle).* = .{};
    }

    /// `AIL_set_sample_file`: the WAVE sound it is to play, which must outlive it. False for a
    /// file the driver cannot play, as Miles's null.
    pub fn setSampleFile(mixer: *Mixer, handle: Sample, file: []const u8) bool {
        mixer.lock.acquire();
        defer mixer.lock.release();
        mixer.sample(handle).playing = voice.Voice.init(file) catch return false;
        return true;
    }

    /// Not Miles's: where a sample is heard. The software mixer has no reverbs.
    pub fn setSampleRoom(mixer: *Mixer, handle: Sample, room: Room) void {
        _ = mixer;
        _ = handle;
        _ = room;
    }

    /// Not Miles's: what surrounds the camera. The software mixer has no reverbs.
    pub fn setSurroundings(mixer: *Mixer, surroundings: Surroundings) void {
        _ = mixer;
        _ = surroundings;
    }

    /// Not Miles's: where a stream is heard. The software mixer has no reverbs.
    pub fn setStreamRoom(mixer: *Mixer, handle: Stream, room: Room) void {
        _ = mixer;
        _ = handle;
        _ = room;
    }

    pub fn setSampleVolume(mixer: *Mixer, handle: Sample, volume: i32) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        mixer.sample(handle).volume = clampLevel(volume);
    }

    pub fn sampleVolume(mixer: *Mixer, handle: Sample) i32 {
        mixer.lock.acquire();
        defer mixer.lock.release();
        return mixer.sample(handle).volume;
    }

    pub fn setSamplePan(mixer: *Mixer, handle: Sample, pan: i32) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        mixer.sample(handle).pan = clampLevel(pan);
    }

    /// `AIL_set_sample_playback_rate`: frames a second.
    pub fn setSamplePlaybackRate(mixer: *Mixer, handle: Sample, rate: u32) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        if (mixer.sample(handle).playing) |*held| held.rate = rate;
    }

    /// `AIL_set_sample_loop_count`: times to play it, 0 for ever.
    pub fn setSampleLoopCount(mixer: *Mixer, handle: Sample, count: u32) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        if (mixer.sample(handle).playing) |*held| held.loop_count = count;
    }

    pub fn startSample(mixer: *Mixer, handle: Sample) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        if (mixer.sample(handle).playing) |*held| held.start();
    }

    /// `AIL_stop_sample`: stops it where it is, to be resumed.
    pub fn stopSample(mixer: *Mixer, handle: Sample) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        if (mixer.sample(handle).playing) |*held| held.stop();
    }

    pub fn resumeSample(mixer: *Mixer, handle: Sample) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        if (mixer.sample(handle).playing) |*held| held.resumePlaying();
    }

    /// `AIL_end_sample`: stops it for good.
    pub fn endSample(mixer: *Mixer, handle: Sample) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        if (mixer.sample(handle).playing) |*held| held.status = .done;
    }

    pub fn sampleStatus(mixer: *Mixer, handle: Sample) Status {
        mixer.lock.acquire();
        defer mixer.lock.release();
        return statusOf(mixer.sample(handle).playing);
    }

    // --- 3D samples ------------------------------------------------------------------------------

    /// `AIL_allocate_3D_sample_handle`.
    pub fn allocate3DSample(mixer: *Mixer) ?Sample3D {
        mixer.lock.acquire();
        defer mixer.lock.release();
        return allocate(Sample3DState, &mixer.samples_3d);
    }

    /// `AIL_release_3D_sample_handle`.
    pub fn release3DSample(mixer: *Mixer, handle: Sample3D) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        mixer.samples_3d[@intFromEnum(handle)] = .{};
    }

    fn sample3D(mixer: *Mixer, handle: Sample3D) *Sample3DState {
        return &mixer.samples_3d[@intFromEnum(handle)].state;
    }

    /// `AIL_set_3D_sample_file`: its sound, which must outlive it. Miles's 3D samples play PCM
    /// only, which is why the game decompresses its ADPCM first (`AIL_decompress_ADPCM`);
    /// OpenReliant's play either.
    pub fn set3DSampleFile(mixer: *Mixer, handle: Sample3D, file: []const u8) bool {
        mixer.lock.acquire();
        defer mixer.lock.release();
        const state = mixer.sample3D(handle);
        state.playing = voice.Voice.init(file) catch return false;
        return true;
    }

    pub fn set3DSampleVolume(mixer: *Mixer, handle: Sample3D, volume: i32) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        mixer.sample3D(handle).volume = clampLevel(volume);
    }

    pub fn set3DSamplePlaybackRate(mixer: *Mixer, handle: Sample3D, rate: u32) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        if (mixer.sample3D(handle).playing) |*held| held.rate = rate;
    }

    pub fn set3DSampleLoopCount(mixer: *Mixer, handle: Sample3D, count: u32) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        if (mixer.sample3D(handle).playing) |*held| held.loop_count = count;
    }

    /// `AIL_set_3D_position`, from the listener.
    pub fn set3DPosition(mixer: *Mixer, handle: Sample3D, position: Vector) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        mixer.sample3D(handle).placing.position = position;
    }

    /// `AIL_set_3D_orientation`: which way it faces, and its up, which nothing here needs.
    pub fn set3DOrientation(mixer: *Mixer, handle: Sample3D, face: Vector, up: Vector) void {
        _ = up;
        mixer.lock.acquire();
        defer mixer.lock.release();
        mixer.sample3D(handle).placing.face = face;
    }

    /// `AIL_set_3D_velocity_vector`: a millisecond's movement.
    pub fn set3DVelocity(mixer: *Mixer, handle: Sample3D, velocity: Vector) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        mixer.sample3D(handle).placing.velocity = velocity;
    }

    /// `AIL_set_3D_sample_distances`: past `max` no quieter, within `min` no louder.
    pub fn set3DSampleDistances(mixer: *Mixer, handle: Sample3D, max: f32, min: f32) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        const placing = &mixer.sample3D(handle).placing;
        placing.max_distance = max;
        placing.min_distance = min;
    }

    /// `AIL_set_3D_sample_cone`: the angles in degrees, and the volume outside the outer one.
    pub fn set3DSampleCone(mixer: *Mixer, handle: Sample3D, inner: f32, outer: f32, outer_volume: i32) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        const placing = &mixer.sample3D(handle).placing;
        placing.inner_angle = inner;
        placing.outer_angle = outer;
        placing.outer_volume = @floatFromInt(clampLevel(outer_volume));
    }

    /// Not Miles's: how far a 3D sample's sound spreads around where it is, in the same units as
    /// its distances. The software mixer places every sound at a point, as the providers did.
    pub fn set3DSampleRadius(mixer: *Mixer, handle: Sample3D, radius: f32) void {
        _ = mixer;
        _ = handle;
        _ = radius;
    }

    /// Not a call the game makes: `AIL_set_3D_velocity_vector` on the provider's listener, a
    /// millisecond's movement. The game opens no listener, so the software mixer's stays still.
    pub fn set3DListenerVelocity(mixer: *Mixer, velocity: Vector) void {
        _ = mixer;
        _ = velocity;
    }

    pub fn start3DSample(mixer: *Mixer, handle: Sample3D) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        if (mixer.sample3D(handle).playing) |*held| held.start();
    }

    pub fn stop3DSample(mixer: *Mixer, handle: Sample3D) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        if (mixer.sample3D(handle).playing) |*held| held.stop();
    }

    pub fn resume3DSample(mixer: *Mixer, handle: Sample3D) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        if (mixer.sample3D(handle).playing) |*held| held.resumePlaying();
    }

    pub fn end3DSample(mixer: *Mixer, handle: Sample3D) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        if (mixer.sample3D(handle).playing) |*held| held.status = .done;
    }

    pub fn sample3DStatus(mixer: *Mixer, handle: Sample3D) Status {
        mixer.lock.acquire();
        defer mixer.lock.release();
        return statusOf(mixer.sample3D(handle).playing);
    }

    /// `AIL_3D_sample_length`: the bytes its sound would take as 16-bit PCM, which is what Miles
    /// held once the game had decompressed it.
    pub fn sample3DLength(mixer: *Mixer, handle: Sample3D) u32 {
        mixer.lock.acquire();
        defer mixer.lock.release();
        const held = mixer.sample3D(handle).playing orelse return 0;
        return pcmLength(held.decoder.frames, held.decoder.wave.channels);
    }

    // --- Streams ---------------------------------------------------------------------------------

    /// `AIL_open_stream`: a stream of `file`, a WAVE sound that must outlive it, not yet playing;
    /// null for a file the driver cannot play, or when all streams are taken.
    pub fn openStream(mixer: *Mixer, file: []const u8) ?Stream {
        mixer.lock.acquire();
        defer mixer.lock.release();
        const opened = voice.Voice.init(file) catch return null;
        const handle = allocate(StreamState, &mixer.streams) orelse return null;
        mixer.stream(handle).playing = opened;
        return handle;
    }

    fn stream(mixer: *Mixer, handle: Stream) *StreamState {
        return &mixer.streams[@intFromEnum(handle)].state;
    }

    pub fn closeStream(mixer: *Mixer, handle: Stream) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        mixer.streams[@intFromEnum(handle)] = .{};
    }

    pub fn startStream(mixer: *Mixer, handle: Stream) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        const state = mixer.stream(handle);
        // It starts from wherever its position was set.
        if (state.playing) |*held| held.startFrom(state.position);
    }

    /// `AIL_pause_stream`: pauses it, or with `paused` false carries on.
    pub fn pauseStream(mixer: *Mixer, handle: Stream, paused: bool) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        if (mixer.stream(handle).playing) |*held| {
            if (paused) held.stop() else held.resumePlaying();
        }
    }

    pub fn streamStatus(mixer: *Mixer, handle: Stream) Status {
        mixer.lock.acquire();
        defer mixer.lock.release();
        return statusOf(mixer.stream(handle).playing);
    }

    pub fn setStreamVolume(mixer: *Mixer, handle: Stream, volume: i32) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        mixer.stream(handle).volume = clampLevel(volume);
    }

    pub fn setStreamLoopCount(mixer: *Mixer, handle: Stream, count: u32) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        if (mixer.stream(handle).playing) |*held| held.loop_count = count;
    }

    /// `AIL_set_stream_loop_block`: where in the data a loop starts again and ends, in bytes; an
    /// end of -1 for the end of the sound.
    pub fn setStreamLoopBlock(mixer: *Mixer, handle: Stream, start: i32, end: i32) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        const held = &(mixer.stream(handle).playing orelse return);
        held.loop_start = held.frameAt(@intCast(@max(start, 0)));
        held.loop_end = if (end < 0) held.decoder.frames else held.frameAt(@intCast(end));
    }

    /// `AIL_set_stream_position`: where it plays from, in bytes into the data. A negative offset
    /// changes nothing.
    pub fn setStreamPosition(mixer: *Mixer, handle: Stream, offset: i32) void {
        mixer.lock.acquire();
        defer mixer.lock.release();
        if (offset < 0) return;
        const state = mixer.stream(handle);
        const held = state.playing orelse return;
        state.position = held.frameAt(@intCast(offset));
    }

    // --- The mix ---------------------------------------------------------------------------------

    /// Mixes `out.len` frames of everything playing into `out`, left and right from -1 to 1. The
    /// caller holds the lock.
    pub fn mix(mixer: *Mixer, out: [][2]f32) void {
        @memset(out, .{ 0, 0 });
        for (&mixer.samples) |*slot| {
            if (!slot.allocated) continue;
            const state = &slot.state;
            const held = &(state.playing orelse continue);
            const volume = gain(state.volume);
            const pan = @as(f32, @floatFromInt(state.pan));
            // Full in the left ear up to the middle, and in the right from it.
            const gains: [2]f32 = .{ volume * @min(1, (max_level - pan) / (max_level - centre_pan)), volume * @min(1, pan / centre_pan) };
            held.mix(out, mixer.rate, gains, 1);
        }
        for (&mixer.samples_3d) |*slot| {
            if (!slot.allocated) continue;
            const state = &slot.state;
            const held = &(state.playing orelse continue);
            const heard = positional.hear(state.placing, @floatFromInt(state.volume));
            held.mix(out, mixer.rate, heard.gains, heard.pitch);
        }
        for (&mixer.streams) |*slot| {
            if (!slot.allocated) continue;
            const state = &slot.state;
            const held = &(state.playing orelse continue);
            const volume = gain(state.volume);
            held.mix(out, mixer.rate, .{ volume, volume }, 1);
        }
        for (out) |*frame| {
            for (frame) |*channel| channel.* = std.math.clamp(channel.*, -1, 1);
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}

test Mixer {
    const file = comptime @import("../formats/wave.zig").testing.pcm(&std.mem.toBytes([4]i16{ 16384, 16384, 16384, 16384 }));
    var mixer: Mixer = .init(22050);
    const driver = mixer.driver();
    const handle = driver.allocateSample().?;
    try std.testing.expectEqual(Status.done, driver.sampleStatus(handle));
    try std.testing.expect(driver.setSampleFile(handle, file));
    try std.testing.expect(!driver.setSampleFile(handle, "not a wave"));
    try std.testing.expect(driver.setSampleFile(handle, file));

    // Full left: the left ear only, at the volume's share.
    driver.setSamplePan(handle, 0);
    driver.setSampleVolume(handle, 127);
    driver.startSample(handle);
    try std.testing.expectEqual(Status.playing, driver.sampleStatus(handle));
    var out: [2][2]f32 = undefined;
    mixer.mix(&out);
    try std.testing.expectEqual([2]f32{ 0.5, 0 }, out[0]);

    // Stopped, it holds its place and adds nothing; resumed, it goes on to the end.
    driver.stopSample(handle);
    try std.testing.expectEqual(Status.stopped, driver.sampleStatus(handle));
    mixer.mix(&out);
    try std.testing.expectEqual([2]f32{ 0, 0 }, out[0]);
    driver.resumeSample(handle);
    var rest: [4][2]f32 = undefined;
    mixer.mix(&rest);
    try std.testing.expectEqual(Status.done, driver.sampleStatus(handle));

    // In the middle, both ears at full volume.
    driver.setSamplePan(handle, 64);
    driver.startSample(handle);
    mixer.mix(&out);
    try std.testing.expectEqual([2]f32{ 0.5, 0.5 }, out[0]);
}

test "Mixer places 3D samples and plays streams" {
    const file = comptime @import("../formats/wave.zig").testing.pcm(&std.mem.toBytes([4]i16{ 16384, 16384, 16384, 16384 }));
    var mixer: Mixer = .init(22050);
    const driver = mixer.driver();
    const placed = driver.allocate3DSample().?;
    try std.testing.expect(driver.set3DSampleFile(placed, file));
    driver.set3DPosition(placed, .{ 1, 0, 0 });
    driver.start3DSample(placed);
    try std.testing.expectEqual(8, driver.sample3DLength(placed));
    var out: [1][2]f32 = undefined;
    mixer.mix(&out);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[0][1], 1e-6);
    driver.release3DSample(placed);

    // A stream loops its block for ever once told to.
    const music = driver.openStream(file).?;
    driver.setStreamLoopCount(music, 0);
    driver.setStreamLoopBlock(music, 4, -1);
    driver.setStreamVolume(music, 127);
    driver.startStream(music);
    var long: [32][2]f32 = undefined;
    mixer.mix(&long);
    try std.testing.expectEqual(Status.playing, driver.streamStatus(music));
    driver.pauseStream(music, true);
    try std.testing.expectEqual(Status.stopped, driver.streamStatus(music));
    driver.closeStream(music);
    try std.testing.expect(driver.openStream("not a wave") == null);
}
