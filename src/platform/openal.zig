//! The Miles Sound System's calls ([`engine/mss.zig`](../engine/mss.zig)'s `Driver`), played by
//! OpenAL Soft in place of the 3D providers the game chose between: Miles's own, DirectSound3D, EAX,
//! A3D. OpenAL renders into memory through its loopback device, which the platform's audio stream
//! pulls from, so none of its own device backends are used.
//!
//! What the game asked of its provider maps across as it is: each 3D sample's distances, as the
//! inverse distance clamped model DirectSound3D had; its cone; its velocity's Doppler shift; its
//! pitch and volume. Samples play by their pan from ahead, streams stereo straight to the
//! speakers. **Improvements:** OpenAL's band-limited sinc resampler and its smoothing of every
//! change; UHJ stereo, or HRTF for headphones, where Miles panned left and right; as many speakers as
//! the device has; a listener that moves, a stronger Doppler shift, sounds with a size, high
//! frequencies fading with distance, a subwoofer; a reverb on the 3D sounds, of the generic room
//! the game asks EAX for with its effect volume at nothing, or of a hangar while a launch shows one
//! from within, and on the sounds of a carrier's rooms and its briefing room, of a room of the
//! ship; and one of a cabin on the cockpit's own voice.

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("al");
const openreliant = @import("openreliant");
const mss = openreliant.engine.mss;
const math = openreliant.engine.surrender.math;
const wave = openreliant.wave;

const log = std.log.scoped(.openal);

pub const Settings = struct {
    /// Head-related transfer functions, for headphones, on a stereo device; UHJ otherwise. `auto`
    /// has them while the output is headphones.
    hrtf: Hrtf = .auto,
    /// The reverbs: the room the 3D sounds play in, and the cockpit's cabin the ship's own voice
    /// plays in; and how much of each is heard.
    reverb: bool = true,
    reverb_level: f32 = 0.35,
    cabin_level: f32 = 0.5,
    /// High frequencies fading with distance.
    air_absorption: bool = true,
    /// On a device with a subwoofer, how much of the 3D sounds goes to it.
    low_frequency_level: f32 = 0.5,
};

pub const Hrtf = enum { auto, on, off };

pub const Error = error{OpenAl} || Allocator.Error;

/// 3D samples: as many as the game takes of a provider, twice the software mixer's. The game picks
/// the same row of voice classes for either and leaves the rest to any sound.
pub const max_3d_samples = 64;

/// The resampler it asks for by name, the best OpenAL Soft has.
const resampler_name = "23rd order Sinc";

/// Miles's units are metres; its velocities are a millisecond's, OpenAL's a second's.
const velocity_scale = std.time.ms_per_s;
/// The software mixer's speed of sound, a second's.
const speed_of_sound: f32 = mss.positional.speed_of_sound * velocity_scale;
/// **Improvement:** the Doppler shift ten times as strong as the game's velocities make it. Turned
/// into Miles's metres, a missile flies at a few metres a second, which shifts a sound by a
/// hundredth or two, where at the models' scale, about a centimetre a unit, it flies at over a
/// hundred; ten times goes a good part of the way there. The velocities are held within half the
/// speed of sound over this, so the shift keeps within the bounds it had.
const doppler_factor: f32 = 10;

/// A sound decoded into an OpenAL buffer.
const Buffer = struct {
    name: c.ALuint,
    rate: u32,
    frames: u32,
    channels: u16,
};

/// A sample or 3D sample: an OpenAL source and what the game asked of it.
const Voice = struct {
    allocated: bool = false,
    source: c.ALuint = 0,
    buffer: ?Buffer = null,
    volume: i32 = mss.max_level,
    pan: i32 = mss.centre_pan,
    loops: u32 = 1,
    rate: u32 = 0,
    /// A sample's room.
    room: mss.Room = .none,
    /// A 3D sample's position and velocity, in Miles's frame.
    position: mss.Vector = @splat(0),
    velocity: mss.Vector = @splat(0),
};

/// A stream: its source, and its sound, whole in a buffer of its own.
const Stream = struct {
    source: c.ALuint = 0,
    open: ?struct {
        buffer: Buffer,
        wave: wave.Wave,
        loops: u32 = 1,
        loop_start: u32 = 0,
        loop_end: ?u32 = null,
        position: u32 = 0,
    } = null,
};

/// An effect in an auxiliary slot that sources send to.
const Effect = struct {
    effect: c.ALuint,
    slot: c.ALuint,

    /// An effect `set` makes, in a slot heard at `level`; null where EFX refuses it.
    fn create(level: f32, set: *const fn (c.ALuint) void) ?Effect {
        var made: Effect = .{ .effect = 0, .slot = 0 };
        c.alGenEffects(1, &made.effect);
        set(made.effect);
        c.alGenAuxiliaryEffectSlots(1, &made.slot);
        c.alAuxiliaryEffectSloti(made.slot, c.AL_EFFECTSLOT_EFFECT, @intCast(made.effect));
        c.alAuxiliaryEffectSlotf(made.slot, c.AL_EFFECTSLOT_GAIN, level);
        if (c.alGetError() != c.AL_NO_ERROR) {
            log.warn("EFX refused an effect", .{});
            made.delete();
            return null;
        }
        return made;
    }

    /// A reverb of `preset`.
    fn reverb(comptime preset: Reverb, level: f32) ?Effect {
        return create(level, struct {
            fn set(name: c.ALuint) void {
                preset.apply(name);
            }
        }.set);
    }

    fn delete(effect: Effect) void {
        if (effect.slot != 0) c.alDeleteAuxiliaryEffectSlots(1, &effect.slot);
        if (effect.effect != 0) c.alDeleteEffects(1, &effect.effect);
    }

    /// The slot to send to, or none.
    fn slotOf(effect: ?Effect) c.ALint {
        return if (effect) |held| @intCast(held.slot) else c.AL_EFFECTSLOT_NULL;
    }
};

/// An EAX reverb, as `efx-presets.h` gives its presets (`EFXEAXREVERBPROPERTIES`), less the pans,
/// which are all ahead.
const Reverb = struct {
    density: f32,
    diffusion: f32,
    gain: f32,
    gain_hf: f32,
    gain_lf: f32,
    decay_time: f32,
    decay_hf_ratio: f32,
    decay_lf_ratio: f32,
    reflections_gain: f32,
    reflections_delay: f32,
    late_reverb_gain: f32,
    late_reverb_delay: f32,
    echo_time: f32,
    echo_depth: f32,
    modulation_time: f32,
    modulation_depth: f32,
    air_absorption_gain_hf: f32,
    hf_reference: f32,
    lf_reference: f32,
    room_rolloff_factor: f32,
    decay_hf_limit: bool,

    /// `EFX_REVERB_PRESET_GENERIC`: EAX's generic room (`EAX_ENVIRONMENT_GENERIC`), room type 0,
    /// which the game asks its provider for.
    const generic: Reverb = .{
        .density = 1,
        .diffusion = 1,
        .gain = 0.3162,
        .gain_hf = 0.8913,
        .gain_lf = 1,
        .decay_time = 1.49,
        .decay_hf_ratio = 0.83,
        .decay_lf_ratio = 1,
        .reflections_gain = 0.05,
        .reflections_delay = 0.007,
        .late_reverb_gain = 1.2589,
        .late_reverb_delay = 0.011,
        .echo_time = 0.25,
        .echo_depth = 0,
        .modulation_time = 0.25,
        .modulation_depth = 0,
        .air_absorption_gain_hf = 0.9943,
        .hf_reference = 5000,
        .lf_reference = 250,
        .room_rolloff_factor = 0,
        .decay_hf_limit = true,
    };

    /// `EFX_REVERB_PRESET_SPACESTATION_LARGEROOM`: a large room of a space station, metal and
    /// ringing for about four seconds, the nearest of the presets to a carrier's hangar.
    const hangar: Reverb = .{
        .density = 0.3645,
        .diffusion = 0.81,
        .gain = 0.3162,
        .gain_hf = 0.631,
        .gain_lf = 0.8913,
        .decay_time = 3.89,
        .decay_hf_ratio = 0.38,
        .decay_lf_ratio = 0.61,
        .reflections_gain = 0.3162,
        .reflections_delay = 0.056,
        .late_reverb_gain = 0.8913,
        .late_reverb_delay = 0.035,
        .echo_time = 0.233,
        .echo_depth = 0.28,
        .modulation_time = 0.25,
        .modulation_depth = 0,
        .air_absorption_gain_hf = 0.9943,
        .hf_reference = 3316.1001,
        .lf_reference = 458.2,
        .room_rolloff_factor = 0,
        .decay_hf_limit = true,
    };

    /// `EFX_REVERB_PRESET_SPACESTATION_CUPBOARD`: the smallest room of a space station's, metal
    /// and ringing for under a second, for a carrier's inside; its gain 5 dB under the preset's,
    /// 0.3162, so that it rings subtly under the voices.
    const inside: Reverb = .{
        .density = 0.1715,
        .diffusion = 0.56,
        .gain = 0.1778,
        .gain_hf = 0.7079,
        .gain_lf = 0.8913,
        .decay_time = 0.79,
        .decay_hf_ratio = 0.81,
        .decay_lf_ratio = 0.55,
        .reflections_gain = 1.4125,
        .reflections_delay = 0.007,
        .late_reverb_gain = 1.7783,
        .late_reverb_delay = 0.018,
        .echo_time = 0.181,
        .echo_depth = 0.31,
        .modulation_time = 0.25,
        .modulation_depth = 0,
        .air_absorption_gain_hf = 0.9943,
        .hf_reference = 3316.1001,
        .lf_reference = 458.2,
        .room_rolloff_factor = 0,
        .decay_hf_limit = true,
    };

    /// The room for what surrounds the camera.
    fn of(surroundings: mss.Surroundings) Reverb {
        return switch (surroundings) {
            .space => generic,
            .hangar => hangar,
            .inside => inside,
        };
    }

    /// `EFX_REVERB_PRESET_DRIVING_INCAR_RACER`: a race car's bare cabin, short and hard, the
    /// nearest of the presets to a fighter's cockpit.
    const race_car_cabin: Reverb = .{
        .density = 0.0832,
        .diffusion = 0.8,
        .gain = 0.3162,
        .gain_hf = 1,
        .gain_lf = 0.7943,
        .decay_time = 0.17,
        .decay_hf_ratio = 2,
        .decay_lf_ratio = 0.41,
        .reflections_gain = 1.7783,
        .reflections_delay = 0.007,
        .late_reverb_gain = 0.7079,
        .late_reverb_delay = 0.015,
        .echo_time = 0.25,
        .echo_depth = 0,
        .modulation_time = 0.25,
        .modulation_depth = 0,
        .air_absorption_gain_hf = 0.9943,
        .hf_reference = 10268.2,
        .lf_reference = 251,
        .room_rolloff_factor = 0,
        .decay_hf_limit = true,
    };

    fn apply(reverb: Reverb, effect: c.ALuint) void {
        c.alEffecti(effect, c.AL_EFFECT_TYPE, c.AL_EFFECT_EAXREVERB);
        const parameters = [_]struct { c.ALenum, f32 }{
            .{ c.AL_EAXREVERB_DENSITY, reverb.density },
            .{ c.AL_EAXREVERB_DIFFUSION, reverb.diffusion },
            .{ c.AL_EAXREVERB_GAIN, reverb.gain },
            .{ c.AL_EAXREVERB_GAINHF, reverb.gain_hf },
            .{ c.AL_EAXREVERB_GAINLF, reverb.gain_lf },
            .{ c.AL_EAXREVERB_DECAY_TIME, reverb.decay_time },
            .{ c.AL_EAXREVERB_DECAY_HFRATIO, reverb.decay_hf_ratio },
            .{ c.AL_EAXREVERB_DECAY_LFRATIO, reverb.decay_lf_ratio },
            .{ c.AL_EAXREVERB_REFLECTIONS_GAIN, reverb.reflections_gain },
            .{ c.AL_EAXREVERB_REFLECTIONS_DELAY, reverb.reflections_delay },
            .{ c.AL_EAXREVERB_LATE_REVERB_GAIN, reverb.late_reverb_gain },
            .{ c.AL_EAXREVERB_LATE_REVERB_DELAY, reverb.late_reverb_delay },
            .{ c.AL_EAXREVERB_ECHO_TIME, reverb.echo_time },
            .{ c.AL_EAXREVERB_ECHO_DEPTH, reverb.echo_depth },
            .{ c.AL_EAXREVERB_MODULATION_TIME, reverb.modulation_time },
            .{ c.AL_EAXREVERB_MODULATION_DEPTH, reverb.modulation_depth },
            .{ c.AL_EAXREVERB_AIR_ABSORPTION_GAINHF, reverb.air_absorption_gain_hf },
            .{ c.AL_EAXREVERB_HFREFERENCE, reverb.hf_reference },
            .{ c.AL_EAXREVERB_LFREFERENCE, reverb.lf_reference },
            .{ c.AL_EAXREVERB_ROOM_ROLLOFF_FACTOR, reverb.room_rolloff_factor },
        };
        for (parameters) |parameter| c.alEffectf(effect, parameter[0], parameter[1]);
        c.alEffecti(effect, c.AL_EAXREVERB_DECAY_HFLIMIT, @intFromBool(reverb.decay_hf_limit));
    }
};

pub const Renderer = struct {
    gpa: Allocator,
    device: *c.ALCdevice,
    context: *c.ALCcontext,
    rate: u32,
    channels: u8,
    settings: Settings,
    /// Whether HRTF is on.
    hrtf: bool,
    resampler: ?c.ALint = null,
    /// The room's reverb and the cabin's; on a device with a subwoofer, the effect that feeds it,
    /// and the filter that takes the highs off what goes to it. Null or 0 for none.
    room: ?Effect = null,
    cabin: ?Effect = null,
    low_frequency: ?Effect = null,
    /// What surrounds the camera, whose reverb the room plays.
    surroundings: mss.Surroundings = .space,
    low_frequency_filter: c.ALuint = 0,
    samples: [mss.max_samples]Voice = @splat(.{}),
    samples_3d: [max_3d_samples]Voice = @splat(.{}),
    streams: [mss.max_streams]Stream = @splat(.{}),
    /// The banks' sounds, decoded once each, by a hash of their files.
    buffers: std.AutoHashMapUnmanaged(u64, Buffer) = .empty,

    /// A renderer at `rate`, into `channels` interleaved float channels: 2, 4, 6 for 5.1 or 8 for
    /// 7.1; any other count renders stereo. `headphones` says whether the output is, for HRTF's
    /// `auto`.
    pub fn create(gpa: Allocator, rate: u32, channels: u8, settings: Settings, headphones: bool) Error!*Renderer {
        const layout: struct { c.ALCint, u8 } = switch (channels) {
            4 => .{ c.ALC_QUAD_SOFT, 4 },
            6 => .{ c.ALC_5POINT1_SOFT, 6 },
            8 => .{ c.ALC_7POINT1_SOFT, 8 },
            else => .{ c.ALC_STEREO_SOFT, 2 },
        };
        const device = c.alcLoopbackOpenDeviceSOFT(null) orelse return fail("alcLoopbackOpenDeviceSOFT");
        errdefer _ = c.alcCloseDevice(device);
        const hrtf = switch (settings.hrtf) {
            .on => true,
            .off => false,
            .auto => headphones,
        };
        const attributes = deviceAttributes(layout[0], rate, hrtf);
        const context = c.alcCreateContext(device, &attributes) orelse return fail("alcCreateContext");
        errdefer c.alcDestroyContext(context);
        if (c.alcMakeContextCurrent(context) == c.ALC_FALSE) return fail("alcMakeContextCurrent");

        const renderer = try gpa.create(Renderer);
        errdefer gpa.destroy(renderer);
        renderer.* = .{ .gpa = gpa, .device = device, .context = context, .rate = rate, .channels = layout[1], .settings = settings, .hrtf = hrtf };

        // The listener stands still at the origin, looking ahead: the game places every sound
        // from the camera.
        c.alDistanceModel(c.AL_INVERSE_DISTANCE_CLAMPED);
        c.alDopplerFactor(doppler_factor);
        c.alSpeedOfSound(speed_of_sound);
        c.alListener3f(c.AL_POSITION, 0, 0, 0);
        c.alListener3f(c.AL_VELOCITY, 0, 0, 0);
        const orientation = [6]c.ALfloat{ 0, 0, -1, 0, 1, 0 };
        c.alListenerfv(c.AL_ORIENTATION, &orientation);
        c.alListenerf(c.AL_METERS_PER_UNIT, 1);
        renderer.resampler = findResampler();
        // The reverbs are made either way, silent while off, so that they can be turned on.
        renderer.room = .reverb(Reverb.generic, if (settings.reverb) settings.reverb_level else 0);
        renderer.cabin = .reverb(Reverb.race_car_cabin, if (settings.reverb) settings.cabin_level else 0);
        if (renderer.channels >= 6) renderer.createLowFrequency();

        for (&renderer.samples) |*voice| c.alGenSources(1, &voice.source);
        for (&renderer.samples_3d) |*voice| c.alGenSources(1, &voice.source);
        for (&renderer.streams) |*slot| c.alGenSources(1, &slot.source);
        // The context takes its sources with it.
        if (c.alGetError() != c.AL_NO_ERROR) return fail("alGenSources");
        return renderer;
    }

    pub fn destroy(renderer: *Renderer) void {
        for (&renderer.samples) |*voice| deleteSource(voice.source);
        for (&renderer.samples_3d) |*voice| deleteSource(voice.source);
        for (&renderer.streams) |*slot| {
            releaseStream(slot);
            deleteSource(slot.source);
        }
        var buffers = renderer.buffers.valueIterator();
        while (buffers.next()) |buffer| c.alDeleteBuffers(1, &buffer.name);
        renderer.buffers.deinit(renderer.gpa);
        for ([_]?Effect{ renderer.room, renderer.cabin, renderer.low_frequency }) |held| {
            if (held) |effect| effect.delete();
        }
        if (renderer.low_frequency_filter != 0) c.alDeleteFilters(1, &renderer.low_frequency_filter);
        _ = c.alcMakeContextCurrent(null);
        c.alcDestroyContext(renderer.context);
        _ = c.alcCloseDevice(renderer.device);
        renderer.gpa.destroy(renderer);
    }

    /// How it renders to stereo: UHJ, HRTF or plain panning.
    pub fn outputMode(renderer: *const Renderer) c.ALCint {
        var mode: c.ALCint = 0;
        c.alcGetIntegerv(renderer.device, c.ALC_OUTPUT_MODE_SOFT, 1, &mode);
        return mode;
    }

    /// With HRTF's `auto`, turns it on or off as the output changes between headphones and
    /// anything else. Nothing may render meanwhile.
    pub fn followOutput(renderer: *Renderer, headphones: bool) void {
        if (renderer.settings.hrtf == .auto) renderer.useHrtf(headphones);
    }

    /// Sets when HRTF is used, `headphones` saying whether the output is, for `auto`. Nothing may
    /// render meanwhile.
    pub fn setHrtf(renderer: *Renderer, hrtf: Hrtf, headphones: bool) void {
        renderer.settings.hrtf = hrtf;
        renderer.useHrtf(switch (hrtf) {
            .on => true,
            .off => false,
            .auto => headphones,
        });
    }

    /// Turns HRTF on or off, on a stereo output, the device reset to it.
    fn useHrtf(renderer: *Renderer, on: bool) void {
        if (renderer.channels != 2 or renderer.hrtf == on) return;
        renderer.hrtf = on;
        const attributes = deviceAttributes(c.ALC_STEREO_SOFT, renderer.rate, on);
        if (c.alcResetDeviceSOFT(renderer.device, &attributes) == c.ALC_FALSE) log.warn("OpenAL Soft kept its output mode", .{});
    }

    /// Turns the reverbs on or off: the room's and the cabin's heard at their levels, or not at
    /// all.
    pub fn setReverb(renderer: *Renderer, on: bool) void {
        renderer.settings.reverb = on;
        for ([_]?Effect{ renderer.room, renderer.cabin }, [_]f32{ renderer.settings.reverb_level, renderer.settings.cabin_level }) |held, level| {
            const effect = held orelse continue;
            c.alAuxiliaryEffectSlotf(effect.slot, c.AL_EFFECTSLOT_GAIN, if (on) level else 0);
        }
    }

    pub fn driver(renderer: *Renderer) mss.Driver {
        return .of(Renderer, renderer);
    }

    /// Renders `samples.len / channels` frames, interleaved.
    pub fn render(renderer: *Renderer, samples: []f32) void {
        const frames = samples.len / renderer.channels;
        if (frames > 0) c.alcRenderSamplesSOFT(renderer.device, samples.ptr, @intCast(frames));
    }

    /// On a device with a subwoofer, the 3D sounds send to it too, through OpenAL Soft's
    /// dedicated low-frequency effect, with their highs taken off; the receiver's crossover takes
    /// the rest.
    fn createLowFrequency(renderer: *Renderer) void {
        const effect = Effect.create(renderer.settings.low_frequency_level, struct {
            fn set(name: c.ALuint) void {
                c.alEffecti(name, c.AL_EFFECT_TYPE, c.AL_EFFECT_DEDICATED_LOW_FREQUENCY_EFFECT);
                c.alEffectf(name, c.AL_DEDICATED_GAIN, 1);
            }
        }.set) orelse return;
        var filter: c.ALuint = 0;
        c.alGenFilters(1, &filter);
        c.alFilteri(filter, c.AL_FILTER_TYPE, c.AL_FILTER_LOWPASS);
        c.alFilterf(filter, c.AL_LOWPASS_GAIN, 1);
        c.alFilterf(filter, c.AL_LOWPASS_GAINHF, c.AL_LOWPASS_MIN_GAINHF);
        if (c.alGetError() != c.AL_NO_ERROR) {
            log.warn("no subwoofer: EFX refused its filter", .{});
            effect.delete();
            c.alDeleteFilters(1, &filter);
            return;
        }
        renderer.low_frequency = effect;
        renderer.low_frequency_filter = filter;
    }

    // --- Buffers ---------------------------------------------------------------------------------

    /// A bank's sound as a buffer, decoded the first time it is asked for.
    fn bufferOf(renderer: *Renderer, file: []const u8) ?Buffer {
        const key = std.hash.Wyhash.hash(0, file);
        if (renderer.buffers.get(key)) |buffer| return buffer;
        const buffer = decode(renderer.gpa, file) orelse return null;
        renderer.buffers.put(renderer.gpa, key, buffer) catch {
            c.alDeleteBuffers(1, &buffer.name);
            return null;
        };
        return buffer;
    }

    // --- Samples ---------------------------------------------------------------------------------

    fn sample(renderer: *Renderer, handle: mss.Sample) *Voice {
        return &renderer.samples[@intFromEnum(handle)];
    }

    pub fn allocateSample(renderer: *Renderer) ?mss.Sample {
        for (&renderer.samples, 0..) |*voice, index| {
            if (voice.allocated) continue;
            voice.* = .{ .allocated = true, .source = voice.source };
            renderer.setUpFlat(voice);
            return @enumFromInt(index);
        }
        return null;
    }

    pub fn initSample(renderer: *Renderer, handle: mss.Sample) void {
        const voice = renderer.sample(handle);
        stopVoice(voice);
        voice.* = .{ .allocated = true, .source = voice.source };
        renderer.setUpFlat(voice);
    }

    pub fn setSampleFile(renderer: *Renderer, handle: mss.Sample, file: []const u8) bool {
        const voice = renderer.sample(handle);
        stopVoice(voice);
        voice.buffer = renderer.bufferOf(file) orelse return false;
        voice.rate = voice.buffer.?.rate;
        renderer.setUpFlat(voice);
        return true;
    }

    /// **Improvement:** the cockpit's voice plays in the cockpit's cabin.
    pub fn setSampleRoom(renderer: *Renderer, handle: mss.Sample, room: mss.Room) void {
        const voice = renderer.sample(handle);
        voice.room = room;
        renderer.sendToRoom(voice);
    }

    /// **Improvement:** the room the 3D sounds, and the samples of the scene, ring in follows what
    /// surrounds the camera: a hangar's while a launch shows one from within, and a small room of
    /// the ship's in a carrier's rooms and its briefing room.
    pub fn setSurroundings(renderer: *Renderer, surroundings: mss.Surroundings) void {
        if (surroundings == renderer.surroundings) return;
        renderer.surroundings = surroundings;
        const room = renderer.room orelse return;
        Reverb.of(surroundings).apply(room.effect);
        // A slot takes an effect's settings as it is loaded into it.
        c.alAuxiliaryEffectSloti(room.slot, c.AL_EFFECTSLOT_EFFECT, @intCast(room.effect));
    }

    fn sendToRoom(renderer: *Renderer, voice: *Voice) void {
        c.alSource3i(voice.source, c.AL_AUXILIARY_SEND_FILTER, Effect.slotOf(renderer.effectOf(voice.room)), 0, c.AL_FILTER_NULL);
    }

    /// The reverb a sound heard in `room` sends to, where there is one.
    fn effectOf(renderer: *Renderer, room: mss.Room) ?Effect {
        return switch (room) {
            .none => null,
            .cockpit => renderer.cabin,
            .scene => renderer.room,
        };
    }

    pub fn setSampleVolume(renderer: *Renderer, handle: mss.Sample, volume: i32) void {
        const voice = renderer.sample(handle);
        voice.volume = mss.clampLevel(volume);
        c.alSourcef(voice.source, c.AL_GAIN, mss.gain(voice.volume));
    }

    pub fn sampleVolume(renderer: *Renderer, handle: mss.Sample) i32 {
        return renderer.sample(handle).volume;
    }

    pub fn setSamplePan(renderer: *Renderer, handle: mss.Sample, pan: i32) void {
        const voice = renderer.sample(handle);
        voice.pan = mss.clampLevel(pan);
        renderer.placeFlat(voice);
    }

    pub fn setSamplePlaybackRate(renderer: *Renderer, handle: mss.Sample, rate: u32) void {
        const voice = renderer.sample(handle);
        voice.rate = rate;
        setPitch(voice);
    }

    pub fn setSampleLoopCount(renderer: *Renderer, handle: mss.Sample, count: u32) void {
        renderer.sample(handle).loops = count;
    }

    pub fn startSample(renderer: *Renderer, handle: mss.Sample) void {
        startVoice(renderer.sample(handle));
    }

    pub fn stopSample(renderer: *Renderer, handle: mss.Sample) void {
        pauseSource(renderer.sample(handle).source);
    }

    pub fn resumeSample(renderer: *Renderer, handle: mss.Sample) void {
        resumeSource(renderer.sample(handle).source);
    }

    pub fn endSample(renderer: *Renderer, handle: mss.Sample) void {
        c.alSourceStop(renderer.sample(handle).source);
    }

    pub fn sampleStatus(renderer: *Renderer, handle: mss.Sample) mss.Status {
        return statusOf(renderer.sample(handle).source);
    }

    /// A sample plays from ahead, turned by its pan, with no distance; a stereo one straight to the
    /// speakers. In the cockpit, it sends to the cabin's reverb.
    fn setUpFlat(renderer: *Renderer, voice: *Voice) void {
        const source = voice.source;
        c.alSourcei(source, c.AL_SOURCE_RELATIVE, c.AL_TRUE);
        c.alSourcef(source, c.AL_ROLLOFF_FACTOR, 0);
        renderer.sendToRoom(voice);
        const stereo = if (voice.buffer) |buffer| buffer.channels == 2 else false;
        c.alSourcei(source, c.AL_DIRECT_CHANNELS_SOFT, if (stereo) c.AL_REMIX_UNMATCHED_SOFT else c.AL_FALSE);
        renderer.useResampler(source);
        c.alSourcef(source, c.AL_GAIN, mss.gain(voice.volume));
        setPitch(voice);
        renderer.placeFlat(voice);
    }

    fn placeFlat(renderer: *Renderer, voice: *Voice) void {
        _ = renderer;
        const side = std.math.clamp(@as(f32, @floatFromInt(voice.pan - mss.centre_pan)) / mss.centre_pan, -1, 1);
        const angle = side * std.math.pi / 2;
        c.alSource3f(voice.source, c.AL_POSITION, @sin(angle), 0, -@cos(angle));
    }

    // --- 3D samples ------------------------------------------------------------------------------

    fn sample3D(renderer: *Renderer, handle: mss.Sample3D) *Voice {
        return &renderer.samples_3d[@intFromEnum(handle)];
    }

    pub fn allocate3DSample(renderer: *Renderer) ?mss.Sample3D {
        for (&renderer.samples_3d, 0..) |*voice, index| {
            if (voice.allocated) continue;
            voice.* = .{ .allocated = true, .source = voice.source };
            renderer.setUp3D(voice);
            return @enumFromInt(index);
        }
        return null;
    }

    pub fn release3DSample(renderer: *Renderer, handle: mss.Sample3D) void {
        const voice = renderer.sample3D(handle);
        stopVoice(voice);
        voice.* = .{ .source = voice.source };
    }

    pub fn set3DSampleFile(renderer: *Renderer, handle: mss.Sample3D, file: []const u8) bool {
        const voice = renderer.sample3D(handle);
        stopVoice(voice);
        voice.buffer = renderer.bufferOf(file) orelse return false;
        voice.rate = voice.buffer.?.rate;
        setPitch(voice);
        return true;
    }

    pub fn set3DSampleVolume(renderer: *Renderer, handle: mss.Sample3D, volume: i32) void {
        const voice = renderer.sample3D(handle);
        voice.volume = mss.clampLevel(volume);
        c.alSourcef(voice.source, c.AL_GAIN, mss.gain(voice.volume));
    }

    pub fn set3DSamplePlaybackRate(renderer: *Renderer, handle: mss.Sample3D, rate: u32) void {
        const voice = renderer.sample3D(handle);
        voice.rate = rate;
        setPitch(voice);
    }

    pub fn set3DSampleLoopCount(renderer: *Renderer, handle: mss.Sample3D, count: u32) void {
        renderer.sample3D(handle).loops = count;
    }

    pub fn set3DPosition(renderer: *Renderer, handle: mss.Sample3D, position: mss.Vector) void {
        const voice = renderer.sample3D(handle);
        voice.position = position;
        const at = openAl(position);
        c.alSource3f(voice.source, c.AL_POSITION, at[0], at[1], at[2]);
        setVelocity(voice);
    }

    pub fn set3DOrientation(renderer: *Renderer, handle: mss.Sample3D, face: mss.Vector, up: mss.Vector) void {
        _ = up;
        const toward = openAl(face);
        c.alSource3f(renderer.sample3D(handle).source, c.AL_DIRECTION, toward[0], toward[1], toward[2]);
    }

    pub fn set3DVelocity(renderer: *Renderer, handle: mss.Sample3D, velocity: mss.Vector) void {
        const voice = renderer.sample3D(handle);
        voice.velocity = velocity;
        setVelocity(voice);
    }

    pub fn set3DSampleDistances(renderer: *Renderer, handle: mss.Sample3D, max: f32, min: f32) void {
        const source = renderer.sample3D(handle).source;
        c.alSourcef(source, c.AL_REFERENCE_DISTANCE, @max(min, 0.001));
        c.alSourcef(source, c.AL_MAX_DISTANCE, @max(max, min));
    }

    pub fn set3DSampleCone(renderer: *Renderer, handle: mss.Sample3D, inner: f32, outer: f32, outer_volume: i32) void {
        const source = renderer.sample3D(handle).source;
        c.alSourcef(source, c.AL_CONE_INNER_ANGLE, inner);
        c.alSourcef(source, c.AL_CONE_OUTER_ANGLE, outer);
        c.alSourcef(source, c.AL_CONE_OUTER_GAIN, mss.gain(mss.clampLevel(outer_volume)));
    }

    /// **Improvement:** a large ship's sound spreads around the listener as it comes close, rather
    /// than staying at a point (`AL_SOURCE_RADIUS`).
    pub fn set3DSampleRadius(renderer: *Renderer, handle: mss.Sample3D, radius: f32) void {
        c.alSourcef(renderer.sample3D(handle).source, c.AL_SOURCE_RADIUS, @max(radius, 0));
    }

    /// **Improvement:** the listener moves, so a sound's Doppler shift comes of how the two move
    /// against each other. Its speed is held within half the speed of sound, as a sample's is along
    /// the line to it.
    pub fn set3DListenerVelocity(renderer: *Renderer, velocity: mss.Vector) void {
        _ = renderer;
        const speed = @sqrt(math.dot(velocity, velocity));
        const most = speed_of_sound / velocity_scale / 2 / doppler_factor;
        const held = if (speed > most) velocity * @as(mss.Vector, @splat(most / speed)) else velocity;
        const moving = openAl(held) * @as(mss.Vector, @splat(velocity_scale));
        c.alListener3f(c.AL_VELOCITY, moving[0], moving[1], moving[2]);
    }

    pub fn start3DSample(renderer: *Renderer, handle: mss.Sample3D) void {
        startVoice(renderer.sample3D(handle));
    }

    pub fn stop3DSample(renderer: *Renderer, handle: mss.Sample3D) void {
        pauseSource(renderer.sample3D(handle).source);
    }

    pub fn resume3DSample(renderer: *Renderer, handle: mss.Sample3D) void {
        resumeSource(renderer.sample3D(handle).source);
    }

    pub fn end3DSample(renderer: *Renderer, handle: mss.Sample3D) void {
        c.alSourceStop(renderer.sample3D(handle).source);
    }

    pub fn sample3DStatus(renderer: *Renderer, handle: mss.Sample3D) mss.Status {
        return statusOf(renderer.sample3D(handle).source);
    }

    pub fn sample3DLength(renderer: *Renderer, handle: mss.Sample3D) u32 {
        const buffer = renderer.sample3D(handle).buffer orelse return 0;
        return mss.pcmLength(buffer.frames, buffer.channels);
    }

    /// A 3D sample is placed from the listener, falls off with distance, and sends to the
    /// reverb, which falls off as it does; a stereo one is spatialized all the same.
    fn setUp3D(renderer: *Renderer, voice: *Voice) void {
        const source = voice.source;
        c.alSourcei(source, c.AL_SOURCE_RELATIVE, c.AL_TRUE);
        c.alSourcef(source, c.AL_ROLLOFF_FACTOR, 1);
        c.alSourcef(source, c.AL_ROOM_ROLLOFF_FACTOR, 1);
        c.alSourcef(source, c.AL_CONE_INNER_ANGLE, 360);
        c.alSourcef(source, c.AL_CONE_OUTER_ANGLE, 360);
        c.alSourcef(source, c.AL_SOURCE_RADIUS, 0);
        c.alSourcei(source, c.AL_SOURCE_SPATIALIZE_SOFT, c.AL_TRUE);
        c.alSourcef(source, c.AL_AIR_ABSORPTION_FACTOR, if (renderer.settings.air_absorption) 1 else 0);
        c.alSource3i(source, c.AL_AUXILIARY_SEND_FILTER, Effect.slotOf(renderer.room), 0, c.AL_FILTER_NULL);
        if (renderer.low_frequency) |effect| {
            c.alSource3i(source, c.AL_AUXILIARY_SEND_FILTER, @intCast(effect.slot), 1, @intCast(renderer.low_frequency_filter));
        }
        renderer.useResampler(source);
        c.alSourcef(source, c.AL_GAIN, mss.gain(voice.volume));
    }

    // --- Streams ---------------------------------------------------------------------------------

    fn stream(renderer: *Renderer, handle: mss.Stream) *Stream {
        return &renderer.streams[@intFromEnum(handle)];
    }

    pub fn openStream(renderer: *Renderer, file: []const u8) ?mss.Stream {
        for (&renderer.streams, 0..) |*slot, index| {
            if (slot.open != null) continue;
            const sound = wave.Wave.parse(file) catch return null;
            const buffer = decode(renderer.gpa, file) orelse return null;
            slot.open = .{ .buffer = buffer, .wave = sound };
            const source = slot.source;
            c.alSourcei(source, c.AL_SOURCE_RELATIVE, c.AL_TRUE);
            c.alSourcef(source, c.AL_ROLLOFF_FACTOR, 0);
            c.alSource3f(source, c.AL_POSITION, 0, 0, 0);
            c.alSourcei(source, c.AL_DIRECT_CHANNELS_SOFT, c.AL_REMIX_UNMATCHED_SOFT);
            c.alSource3i(source, c.AL_AUXILIARY_SEND_FILTER, c.AL_EFFECTSLOT_NULL, 0, c.AL_FILTER_NULL);
            renderer.useResampler(source);
            c.alSourcef(source, c.AL_GAIN, 1);
            return @enumFromInt(index);
        }
        return null;
    }

    pub fn closeStream(renderer: *Renderer, handle: mss.Stream) void {
        releaseStream(renderer.stream(handle));
    }

    /// Plays it from its position. Its loop block is the buffer's loop points
    /// (`AL_SOFT_loop_points`), and a loop count other than once loops it for ever.
    pub fn startStream(renderer: *Renderer, handle: mss.Stream) void {
        const slot = renderer.stream(handle);
        const held = &(slot.open orelse return);
        const frames = held.buffer.frames;
        c.alSourceStop(slot.source);
        c.alSourcei(slot.source, c.AL_BUFFER, 0);
        const end = held.loop_end orelse frames;
        const points = [2]c.ALint{ @intCast(@min(held.loop_start, end -| 1)), @intCast(end) };
        c.alBufferiv(held.buffer.name, c.AL_LOOP_POINTS_SOFT, &points);
        c.alSourcei(slot.source, c.AL_BUFFER, @intCast(held.buffer.name));
        c.alSourcei(slot.source, c.AL_LOOPING, if (held.loops == 1) c.AL_FALSE else c.AL_TRUE);
        c.alSourcei(slot.source, c.AL_SAMPLE_OFFSET, @intCast(@min(held.position, frames)));
        c.alSourcePlay(slot.source);
    }

    pub fn pauseStream(renderer: *Renderer, handle: mss.Stream, paused: bool) void {
        const source = renderer.stream(handle).source;
        if (paused) pauseSource(source) else resumeSource(source);
    }

    pub fn streamStatus(renderer: *Renderer, handle: mss.Stream) mss.Status {
        return statusOf(renderer.stream(handle).source);
    }

    pub fn setStreamVolume(renderer: *Renderer, handle: mss.Stream, volume: i32) void {
        c.alSourcef(renderer.stream(handle).source, c.AL_GAIN, mss.gain(mss.clampLevel(volume)));
    }

    /// **Improvement:** a stream heard in `room`, as a movie's sound on a screen of the scene is.
    pub fn setStreamRoom(renderer: *Renderer, handle: mss.Stream, room: mss.Room) void {
        c.alSource3i(renderer.stream(handle).source, c.AL_AUXILIARY_SEND_FILTER, Effect.slotOf(renderer.effectOf(room)), 0, c.AL_FILTER_NULL);
    }

    pub fn setStreamLoopCount(renderer: *Renderer, handle: mss.Stream, count: u32) void {
        const held = &(renderer.stream(handle).open orelse return);
        held.loops = count;
    }

    pub fn setStreamLoopBlock(renderer: *Renderer, handle: mss.Stream, start: i32, end: i32) void {
        const held = &(renderer.stream(handle).open orelse return);
        held.loop_start = held.wave.frameAt(@intCast(@max(start, 0)));
        held.loop_end = if (end < 0) null else held.wave.frameAt(@intCast(end));
    }

    pub fn setStreamPosition(renderer: *Renderer, handle: mss.Stream, offset: i32) void {
        if (offset < 0) return;
        const held = &(renderer.stream(handle).open orelse return);
        held.position = held.wave.frameAt(@intCast(offset));
    }

    fn useResampler(renderer: *Renderer, source: c.ALuint) void {
        if (renderer.resampler) |index| c.alSourcei(source, c.AL_SOURCE_RESAMPLER_SOFT, index);
    }
};

/// The loopback device's attributes: its channels, float samples at `rate`, and UHJ or HRTF on
/// stereo.
fn deviceAttributes(channels: c.ALCint, rate: u32, hrtf: bool) [19]c.ALCint {
    const stereo_mode: c.ALCint = if (hrtf) c.ALC_STEREO_HRTF_SOFT else c.ALC_STEREO_UHJ_SOFT;
    return .{
        c.ALC_FORMAT_CHANNELS_SOFT, channels,
        c.ALC_FORMAT_TYPE_SOFT,     c.ALC_FLOAT_SOFT,
        c.ALC_FREQUENCY,            @intCast(rate),
        // The platform's master bus limits the mix; OpenAL's own limiter would come first.
        c.ALC_OUTPUT_LIMITER_SOFT,  c.ALC_FALSE,
        c.ALC_HRTF_SOFT,            if (hrtf) c.ALC_TRUE else c.ALC_FALSE,
        c.ALC_OUTPUT_MODE_SOFT,     if (channels == c.ALC_STEREO_SOFT) stereo_mode else c.ALC_ANY_SOFT,
        c.ALC_MONO_SOURCES,         128,
        c.ALC_STEREO_SOURCES,       16,
        c.ALC_MAX_AUXILIARY_SENDS,  2,
        0,
    };
}

fn fail(what: []const u8) Error {
    log.err("{s} failed", .{what});
    return error.OpenAl;
}

/// The resampler of `resampler_name`, if OpenAL Soft has it.
fn findResampler() ?c.ALint {
    const count = c.alGetInteger(c.AL_NUM_RESAMPLERS_SOFT);
    var index: c.ALint = 0;
    while (index < count) : (index += 1) {
        const name: ?[*:0]const u8 = c.alGetStringiSOFT(c.AL_RESAMPLER_NAME_SOFT, index);
        const found = name orelse continue;
        if (std.mem.eql(u8, std.mem.span(found), resampler_name)) return index;
    }
    return null;
}

/// A WAVE sound decoded into 16-bit samples in a new buffer.
fn decode(gpa: Allocator, file: []const u8) ?Buffer {
    const header = wave.Wave.parse(file) catch return null;
    var decoder = wave.Decoder.init(header) catch return null;
    const channels: usize = if (header.channels == 2) 2 else 1;
    const samples = gpa.alloc(i16, decoder.frames * channels) catch return null;
    defer gpa.free(samples);
    var at: usize = 0;
    while (decoder.next()) |frame| : (at += channels) @memcpy(samples[at..][0..channels], frame[0..channels]);
    var name: c.ALuint = 0;
    c.alGenBuffers(1, &name);
    const format: c.ALenum = if (channels == 2) c.AL_FORMAT_STEREO16 else c.AL_FORMAT_MONO16;
    c.alBufferData(name, format, samples.ptr, @intCast(samples.len * @sizeOf(i16)), @intCast(header.rate));
    if (c.alGetError() != c.AL_NO_ERROR) {
        c.alDeleteBuffers(1, &name);
        return null;
    }
    return .{ .name = name, .rate = header.rate, .frames = decoder.frames, .channels = @intCast(channels) };
}

/// A vector in Miles's frame, `+z` ahead, in OpenAL's, `-z` ahead.
fn openAl(v: mss.Vector) mss.Vector {
    return .{ v[0], v[1], -v[2] };
}

/// A 3D sample's velocity, held along the line to the listener as the software mixer holds it, for
/// a shift `doppler_factor` times as strong.
fn setVelocity(voice: *Voice) void {
    const factor: mss.Vector = @splat(doppler_factor);
    const held = mss.positional.dopplerVelocity(voice.position, voice.velocity * factor) / factor;
    const moving = openAl(held) * @as(mss.Vector, @splat(velocity_scale));
    c.alSource3f(voice.source, c.AL_VELOCITY, moving[0], moving[1], moving[2]);
}

fn setPitch(voice: *Voice) void {
    const buffer = voice.buffer orelse return;
    if (buffer.rate == 0) return;
    const pitch = @as(f32, @floatFromInt(voice.rate)) / @as(f32, @floatFromInt(buffer.rate));
    c.alSourcef(voice.source, c.AL_PITCH, @max(pitch, 0.001));
}

fn releaseStream(slot: *Stream) void {
    c.alSourceStop(slot.source);
    c.alSourcei(slot.source, c.AL_BUFFER, 0);
    if (slot.open) |held| c.alDeleteBuffers(1, &held.buffer.name);
    slot.open = null;
}

fn deleteSource(source: c.ALuint) void {
    c.alSourceStop(source);
    c.alDeleteSources(1, &source);
}

fn stopVoice(voice: *Voice) void {
    c.alSourceStop(voice.source);
    c.alSourcei(voice.source, c.AL_BUFFER, 0);
}

/// Plays the voice's sound from the start, as many times as its loop count says: for ever, once,
/// or queued that many times.
fn startVoice(voice: *Voice) void {
    const buffer = voice.buffer orelse return;
    stopVoice(voice);
    switch (voice.loops) {
        0, 1 => {
            c.alSourcei(voice.source, c.AL_BUFFER, @intCast(buffer.name));
            c.alSourcei(voice.source, c.AL_LOOPING, if (voice.loops == 0) c.AL_TRUE else c.AL_FALSE);
        },
        else => {
            c.alSourcei(voice.source, c.AL_LOOPING, c.AL_FALSE);
            const names: [64]c.ALuint = @splat(buffer.name);
            c.alSourceQueueBuffers(voice.source, @intCast(@min(voice.loops, names.len)), &names);
        },
    }
    c.alSourcePlay(voice.source);
}

fn pauseSource(source: c.ALuint) void {
    if (sourceState(source) == c.AL_PLAYING) c.alSourcePause(source);
}

fn resumeSource(source: c.ALuint) void {
    if (sourceState(source) == c.AL_PAUSED) c.alSourcePlay(source);
}

fn sourceState(source: c.ALuint) c.ALint {
    var state: c.ALint = 0;
    c.alGetSourcei(source, c.AL_SOURCE_STATE, &state);
    return state;
}

/// Miles's status for a source's state: paused is stopped part of the way, and a source that has
/// never played or has finished is done.
fn statusOf(source: c.ALuint) mss.Status {
    return switch (sourceState(source)) {
        c.AL_PLAYING => .playing,
        c.AL_PAUSED => .stopped,
        else => .done,
    };
}

test Renderer {
    const gpa = std.testing.allocator;
    const renderer = Renderer.create(gpa, 22050, 2, .{}, false) catch return error.SkipZigTest;
    defer renderer.destroy();
    const driver = renderer.driver();
    try std.testing.expect(renderer.resampler != null);
    try std.testing.expect(renderer.room != null and renderer.cabin != null);
    try std.testing.expectEqual(c.ALC_STEREO_UHJ_SOFT, renderer.outputMode());
    // HRTF turned on and back by the output; the reverbs silenced and heard again.
    renderer.setHrtf(.on, false);
    try std.testing.expectEqual(c.ALC_STEREO_HRTF_SOFT, renderer.outputMode());
    renderer.setHrtf(.auto, false);
    try std.testing.expectEqual(c.ALC_STEREO_UHJ_SOFT, renderer.outputMode());
    var gain: c.ALfloat = 1;
    renderer.setReverb(false);
    c.alGetAuxiliaryEffectSlotf(renderer.room.?.slot, c.AL_EFFECTSLOT_GAIN, &gain);
    try std.testing.expectEqual(0, gain);
    renderer.setReverb(true);
    c.alGetAuxiliaryEffectSlotf(renderer.room.?.slot, c.AL_EFFECTSLOT_GAIN, &gain);
    try std.testing.expectApproxEqAbs(renderer.settings.reverb_level, gain, 1e-6);

    // A 3D sample to the right, heard in the right ear more than the left.
    const file = comptime openreliant.wave.testing.pcm(&std.mem.toBytes([_]i16{16384} ** 2048));
    const placed = driver.allocate3DSample().?;
    try std.testing.expect(driver.set3DSampleFile(placed, file));
    try std.testing.expectEqual(4096, driver.sample3DLength(placed));
    driver.set3DPosition(placed, .{ 1, 0, 0 });
    driver.set3DSampleDistances(placed, 100, 1);
    try std.testing.expectEqual(mss.Status.done, driver.sample3DStatus(placed));
    driver.start3DSample(placed);
    try std.testing.expectEqual(mss.Status.playing, driver.sample3DStatus(placed));
    var out: [2 * 1024]f32 = undefined;
    renderer.render(&out);
    var left: f32 = 0;
    var right: f32 = 0;
    for (0..1024) |frame| {
        left += @abs(out[2 * frame]);
        right += @abs(out[2 * frame + 1]);
    }
    try std.testing.expect(right > left);

    // Paused, it is stopped part of the way; ended, done.
    driver.stop3DSample(placed);
    try std.testing.expectEqual(mss.Status.stopped, driver.sample3DStatus(placed));
    driver.end3DSample(placed);
    try std.testing.expectEqual(mss.Status.done, driver.sample3DStatus(placed));

    // A stream with a loop block plays for ever from its loop point.
    const music = driver.openStream(file).?;
    driver.setStreamLoopCount(music, 0);
    driver.setStreamLoopBlock(music, 1024, -1);
    driver.startStream(music);
    try std.testing.expectEqual(mss.Status.playing, driver.streamStatus(music));
    driver.closeStream(music);
}

test "Doppler" {
    const renderer = Renderer.create(std.testing.allocator, 22050, 2, .{}, false) catch return error.SkipZigTest;
    defer renderer.destroy();
    const driver = renderer.driver();
    try std.testing.expectEqual(doppler_factor, c.alGetFloat(c.AL_DOPPLER_FACTOR));

    // A sample flying off ahead faster than the shift allows is held to half the speed of sound
    // over the factor, in OpenAL's frame, where ahead is `-z`.
    const placed = driver.allocate3DSample().?;
    driver.set3DPosition(placed, .{ 0, 0, 10 });
    driver.set3DVelocity(placed, .{ 0, 0, 1 });
    var velocity: [3]c.ALfloat = undefined;
    c.alGetSource3f(renderer.sample3D(placed).source, c.AL_VELOCITY, &velocity[0], &velocity[1], &velocity[2]);
    try std.testing.expectApproxEqAbs(-speed_of_sound / 2 / doppler_factor, velocity[2], 1e-3);
    // A slow one keeps its velocity.
    driver.set3DVelocity(placed, .{ 0, 0, 0.005 });
    c.alGetSource3f(renderer.sample3D(placed).source, c.AL_VELOCITY, &velocity[0], &velocity[1], &velocity[2]);
    try std.testing.expectApproxEqAbs(-0.005 * velocity_scale, velocity[2], 1e-3);
}

test "HRTF" {
    const forced = Renderer.create(std.testing.allocator, 44100, 2, .{ .hrtf = .on }, false) catch return error.SkipZigTest;
    forced.followOutput(false);
    try std.testing.expectEqual(c.ALC_STEREO_HRTF_SOFT, forced.outputMode());
    forced.destroy();

    // On its own, it follows the output: HRTF for headphones, UHJ for anything else.
    const auto = try Renderer.create(std.testing.allocator, 44100, 2, .{}, true);
    defer auto.destroy();
    try std.testing.expectEqual(c.ALC_STEREO_HRTF_SOFT, auto.outputMode());
    auto.followOutput(false);
    try std.testing.expectEqual(c.ALC_STEREO_UHJ_SOFT, auto.outputMode());
}

test "subwoofer" {
    // On 5.1, a 3D sound ahead reaches the subwoofer too.
    const renderer = Renderer.create(std.testing.allocator, 22050, 6, .{}, false) catch return error.SkipZigTest;
    defer renderer.destroy();
    try std.testing.expect(renderer.low_frequency != null);
    const driver = renderer.driver();
    const file = comptime openreliant.wave.testing.pcm(&std.mem.toBytes([_]i16{16384} ** 4096));
    const placed = driver.allocate3DSample().?;
    try std.testing.expect(driver.set3DSampleFile(placed, file));
    driver.set3DPosition(placed, .{ 0, 0, 2 });
    driver.set3DSampleDistances(placed, 100, 1);
    driver.set3DSampleRadius(placed, 0.5);
    driver.set3DListenerVelocity(.{ 0, 0, 0.01 });
    driver.start3DSample(placed);
    var out: [6 * 1024]f32 = undefined;
    renderer.render(&out);
    var low: f32 = 0;
    for (0..1024) |frame| low += @abs(out[6 * frame + 3]);
    try std.testing.expect(low > 0);
}

/// A burst of a 1 kHz tone at 22050 Hz that fades in and out, for the reverbs' tests: one that
/// stopped short would leave OpenAL's click removal ringing on.
const tone_burst = file: {
    var tone: [220]i16 = undefined;
    for (&tone, 0..) |*value, i| {
        const at: f64 = @floatFromInt(i);
        const fade = 0.5 - 0.5 * @cos(2 * std.math.pi * at / (tone.len - 1));
        value.* = @intFromFloat(16384 * fade * @sin(2 * std.math.pi * 1000 * at / 22050));
    }
    break :file openreliant.wave.testing.pcm(&std.mem.toBytes(tone));
};

/// How long after a tone burst a test listens for its ring: over the rest of the first block, or
/// from about a second on.
const Listen = enum { soon, a_second_on };

/// What the tone burst just started leaves ringing, summed over the output as `listen` has it; the
/// room then let fall quiet for the next.
fn ringing(renderer: *Renderer, listen: Listen) f32 {
    var out: [2 * 4096]f32 = undefined;
    var sum: f32 = 0;
    switch (listen) {
        .soon => {
            renderer.render(&out);
            for (out[2 * 1500 ..]) |value| sum += @abs(value);
        },
        .a_second_on => for (0..8) |block| {
            renderer.render(&out);
            if (block >= 5) for (out) |value| {
                sum += @abs(value);
            };
        },
    }
    for (0..24) |_| renderer.render(&out);
    return sum;
}

/// The tone burst started on a sample of `driver`, heard in `room`.
fn startBurst(driver: mss.Driver, room: mss.Room) !void {
    const sample = driver.allocateSample().?;
    try std.testing.expect(driver.setSampleFile(sample, tone_burst));
    driver.setSampleRoom(sample, room);
    driver.startSample(sample);
}

test "the cockpit's cabin" {
    // A short sound in the cockpit rings on in the cabin after it ends; one nowhere in particular
    // doesn't.
    const renderer = Renderer.create(std.testing.allocator, 22050, 2, .{}, false) catch return error.SkipZigTest;
    defer renderer.destroy();
    var tails: [2]f32 = undefined;
    for ([_]mss.Room{ .none, .cockpit }, &tails) |room, *tail| {
        try startBurst(renderer.driver(), room);
        tail.* = ringing(renderer, .soon);
    }
    try std.testing.expect(tails[1] > 10 * tails[0] + 1e-3);
}

test "a hangar rings on longer than space and the ship's inside" {
    // A short sound of the scene still rings a second on in a hangar, where space's room and the
    // ship's small rooms have all but died away.
    const renderer = Renderer.create(std.testing.allocator, 22050, 2, .{}, false) catch return error.SkipZigTest;
    defer renderer.destroy();
    const driver = renderer.driver();
    var tails: [3]f32 = undefined;
    for ([_]mss.Surroundings{ .space, .inside, .hangar }, &tails) |surroundings, *tail| {
        driver.setSurroundings(surroundings);
        try startBurst(driver, .scene);
        tail.* = ringing(renderer, .a_second_on);
    }
    try std.testing.expectEqual(.hangar, renderer.surroundings);
    try std.testing.expect(tails[2] > 4 * tails[0] + 1e-3);
    try std.testing.expect(tails[2] > 4 * tails[1] + 1e-3);
}

test "a stream heard in the scene rings on in its room" {
    // A short stream rings on after it ends where it is heard in the scene; one heard nowhere in
    // particular doesn't.
    const renderer = Renderer.create(std.testing.allocator, 22050, 2, .{}, false) catch return error.SkipZigTest;
    defer renderer.destroy();
    const driver = renderer.driver();
    driver.setSurroundings(.inside);
    var tails: [2]f32 = undefined;
    for ([_]mss.Room{ .none, .scene }, &tails) |room, *tail| {
        const stream = driver.openStream(tone_burst).?;
        defer driver.closeStream(stream);
        driver.setStreamRoom(stream, room);
        driver.startStream(stream);
        tail.* = ringing(renderer, .soon);
    }
    try std.testing.expect(tails[1] > 10 * tails[0] + 1e-3);
}
