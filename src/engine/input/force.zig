//! Force feedback, in the device code after `input_shutdown`: the effects `load_force_effects`
//! (`0x004BD800`) reads from `forces\*.frc` ([`frc.zig`](../../formats/frc.zig)) when the joystick
//! has force feedback, what starts them, and the pushes the player's ship takes from hits
//! (`force_hit_pushes`, `0x004BE060`).
//!
//! The game hands each file to the SideWinder Force Feedback SDK (`force_effects_read`,
//! `0x004BDB10`, the SDK's `SWFF_CreateDIEffectFromFileEx`), whose Visual Force Effects server
//! makes DirectInput effects of it, and starts them on the joystick. OpenReliant plays them itself
//! instead, as rumble: each frame `Forces.motors` works out how hard every effect playing pushes at
//! that moment, and the platform drives the controller's two motors by it. A waveform slower than
//! `buzz_frequency` shakes the low motor as it swings; a faster one buzzes the high motor at its
//! strength. The way an effect pushes, which a force-feedback joystick shows, rumble cannot
//! ([#244](https://github.com/OpenReliant/openreliant/issues/244)).
//!
//! **Improvement:** any controller that rumbles plays the effects, gamepads among them, where the
//! game plays them on a DirectInput joystick with force feedback alone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const frc = @import("../../formats/frc.zig");
const files = @import("../files.zig");
const bigfile = @import("../game/bigfile.zig");
const collision = @import("../game/collision.zig");
const main = @import("../game/main.zig");

/// The effects, each read from its own file.
pub const Effect = enum {
    // The game's, in the order `load_force_effects` reads them into `force_effects`: a gun type's
    // each, from the Laser Cannon's to the Nova Cannon's, then a missile's launch and the shake
    // from hits.
    lc,
    pc,
    mb,
    prc,
    gl,
    tc,
    np,
    cg,
    gp,
    vb,
    nc,
    missile,
    shake,
    // OpenReliant's, from files the game ships but never reads (`Unread`).
    shield,
    hullshock,
    hullshock1,
    hullshock2,
    hullshock3,
    shock,
    landhard,
    afterburn,

    /// The file it is read from, in `forces\`, as the game spells the name.
    pub fn fileName(effect: Effect) []const u8 {
        return switch (effect) {
            .missile => "Missile.frc",
            .shake => "Shake.frc",
            .shield => "Shield.frc",
            .hullshock => "Hullshock.frc",
            .hullshock1 => "Hullshock1.frc",
            .hullshock2 => "Hullshock2.frc",
            .hullshock3 => "Hullshock3.frc",
            .shock => "Shock.frc",
            .afterburn => "Afterburn.frc",
            inline else => |named| @tagName(named) ++ ".frc",
        };
    }

    /// Whether it is one of the files the game never reads.
    pub fn unread(effect: Effect) bool {
        return @intFromEnum(effect) > @intFromEnum(Effect.shake);
    }
};

/// Whether the effects the game ships but never reads play.
pub const Unread = enum {
    /// **Improvement:** each where it fits: `Shield` as a hit strikes the player's shields,
    /// `Hullshock` to `Hullshock3` as one strikes the hull, by the side struck, `Shock` as a
    /// shockwave strikes the ship, `landhard` as it collides, and `Afterburn` as the afterburner
    /// lights. The rest, `Guns` (the same as `lc`), `Accl`, `Decl`, `AcDc` and `shiver`, fit
    /// nothing the game does and stay unread.
    played,
    /// As the original: none of them.
    left,
};

/// When a hit on the player's ship shakes the camera (`damage_feedback`).
pub const HitShake = enum {
    /// **Improvement:** whatever the controller, as it shakes for a shockwave or a split.
    always,
    /// As the original: only while the joystick has force feedback, since the code that raises
    /// the shake is its force feedback's.
    with_force_feedback,
};

/// How OpenReliant plays the force feedback where it does more than the game.
pub const Settings = struct {
    unread: Unread = .played,
    hit_shake: HitShake = .always,

    pub const original: Settings = .{ .unread = .left, .hit_shake = .with_force_feedback };
};

/// The effects as read, a file each where the game has it.
pub const Library = struct {
    files: std.EnumArray(Effect, ?frc.File) = .initFill(null),
};

/// The effects `load` read, and those the game lacks.
pub const Found = struct {
    library: Library = .{},
    /// The effects whose files are missing, can't be read or aren't effect files, which play
    /// nothing.
    lacking: std.EnumSet(Effect) = .initFull(),
};

/// The folder the effects' files are in (`0x0050E1D8`).
const folder = "forces\\";

/// `load_force_effects` (`0x004BD800`): reads each effect's file in `folder` under the game folder
/// `directory` into `arena`, finding the folder and files ignoring case as Windows does, with a mod
/// file of the same name taking priority (`bigfile.Mods.readLoose`). OpenReliant also reads the
/// effect files the game ships but never reads (`Unread`), and reads them all whatever the
/// controller.
pub fn load(io: Io, arena: Allocator, directory: Io.Dir, mods: *const bigfile.Mods) Found {
    var found: Found = .{};
    for (std.enums.values(Effect)) |effect| {
        var path: [files.max_path]u8 = undefined;
        const name = std.fmt.bufPrint(&path, folder ++ "{s}", .{effect.fileName()}) catch continue;
        const bytes = (mods.readLoose(io, arena, directory, name, .limited(files.max_file_size)) catch continue) orelse continue;
        const file = frc.File.parse(arena, bytes) catch continue;
        found.library.files.set(effect, file);
        found.lacking.remove(effect);
    }
    return found;
}

/// How hard the controller's two motors turn, from 0 to 1: the low-frequency one, a heavy rumble,
/// and the high-frequency one, a light buzz.
pub const Motors = struct {
    low: f32 = 0,
    high: f32 = 0,

    fn add(motors: *Motors, more: Motors) void {
        motors.low += more.low;
        motors.high += more.high;
    }

    fn scaled(motors: Motors, by: f32) Motors {
        return .{ .low = motors.low * by, .high = motors.high * by };
    }

    fn clamped(motors: Motors) Motors {
        return .{ .low = std.math.clamp(motors.low, 0, 1), .high = std.math.clamp(motors.high, 0, 1) };
    }
};

/// The frequency from which a waveform buzzes the high motor rather than swinging the low one.
pub const buzz_frequency = 10;

/// How many play slots the pushes take in turn (`force_slots`, `0x005DDCDC`).
pub const push_slots = 9;

/// How many hits a frame the game keeps for the pushes (`force_hits`, `0x005457B8`).
pub const frame_hits = 20;

/// A push from hits (`force_periodic_create`, `0x004BDD30`, the SDK's `SWFF_CreatePeriodicEffect`):
/// a sine of two swings a second for a second, as strong as the hits' push.
const push_ms = 1000;
const push_frequency = 2;

/// Each hit's push, for each point of damage, in DirectInput's units, of which 10000 is the
/// strongest (`0x004F7408`).
pub const push_per_damage = 300;
const push_most: f32 = 10000;

/// A hit on the player's ship the pushes count this frame, and the side it struck.
const Hit = struct { push: f32 = 0, side: collision.Quadrant = .left };

/// A push playing: when it started, and how strong it is, from 0 to 1.
const Push = struct { started: i32, strength: f32 };

/// The force feedback as it plays.
pub const Forces = struct {
    library: *const Library,
    settings: Settings = .{},
    /// Whether the player's controller rumbles: the game's `force_feedback` (`0x0050E1A4`), set
    /// while its joystick has force feedback.
    feedback: bool = false,
    /// `ForceFeedback` (`0x0051DA4C`), the player's switch, which each place that starts an
    /// effect tests as well.
    setting: bool = true,
    /// Whether the afterburner burned at the last frame's orders (`afterburner`).
    afterburning: bool = false,
    /// The tick each effect started on, while it plays. An effect started again starts over, as a
    /// DirectInput effect does.
    started: std.EnumArray(Effect, ?i32) = .initFill(null),
    pushes: [push_slots]?Push = @splat(null),
    next_push: u8 = 0,
    hits: [frame_hits]Hit = @splat(.{}),
    next_hit: u8 = 0,

    /// Whether the effects play: the controller rumbles and the setting lets it.
    pub fn on(forces: *const Forces) bool {
        return forces.feedback and forces.setting;
    }

    /// Starts `effect` at the tick `now`, where the effects play and the game has its file. One the
    /// game never reads plays only where `Settings.unread` lets it.
    pub fn start(forces: *Forces, effect: Effect, now: i32) void {
        if (!forces.on() or forces.library.files.get(effect) == null) return;
        if (effect.unread() and forces.settings.unread == .left) return;
        forces.started.set(effect, now);
    }

    /// Stops `effect`.
    pub fn stop(forces: *Forces, effect: Effect) void {
        forces.started.set(effect, null);
    }

    /// Whether `effect` is still playing at `now` (`GetEffectStatus`).
    pub fn playing(forces: *const Forces, effect: Effect, now: i32) bool {
        const started = forces.started.get(effect) orelse return false;
        const file = forces.library.files.get(effect) orelse return false;
        return millis(now - started) < fileLength(file);
    }

    /// Starts `effect` unless it is already playing (`GetEffectStatus`), as `force_shake`
    /// (`0x004BE000`) starts the shake from hits each frame while the camera shakes.
    pub fn startUnlessPlaying(forces: *Forces, effect: Effect, now: i32) void {
        if (!forces.playing(effect, now)) forces.start(effect, now);
    }

    /// OpenReliant's, each frame the player's orders run (`Unread.played`): `Afterburn` plays as
    /// the afterburner lights, and stops as it goes out.
    pub fn afterburner(forces: *Forces, burning: bool, now: i32) void {
        defer forces.afterburning = burning;
        if (burning == forces.afterburning) return;
        if (burning) forces.start(.afterburn, now) else forces.stop(.afterburn);
    }

    /// A hit's push on `side` of the player's ship (`damage_feedback`), `damage` strong, which the
    /// frame's pushes then count. The game keeps the latest `frame_hits`, from the first again.
    pub fn hit(forces: *Forces, side: collision.Quadrant, damage: f32) void {
        if (!forces.feedback) return;
        if (forces.next_hit >= frame_hits) forces.next_hit = 0;
        forces.hits[forces.next_hit] = .{ .push = damage * push_per_damage, .side = side };
        forces.next_hit += 1;
        // The next hit ends the list, which the pushes read up to.
        if (forces.next_hit < frame_hits) forces.hits[forces.next_hit].push = 0;
    }

    /// `force_hit_pushes` (`0x004BE060`), each frame while the setting lets it: the frame's hits,
    /// up to the first of no push, summed by the side they struck, push the ship across by the
    /// left's less the right's, and along by the fore's less the aft's. Each push that way,
    /// stronger than 1, plays for a second in the next play slot, in the place of what played
    /// there.
    ///
    /// Not ported: a second list the pass sums the same way (`force_knocks`), which nothing fills;
    /// and the joystick's reset the game sends for a push of 1 or less, which stops every effect
    /// playing. The way each push pushes rumble cannot show; the game aims one from the left at
    /// 900 degrees, which DirectInput turns down (#244).
    pub fn pushFrame(forces: *Forces, now: i32) void {
        if (!forces.setting) return;
        var sides: std.EnumArray(collision.Quadrant, f32) = .initFill(0);
        for (&forces.hits) |*each| {
            if (!(each.push > 0)) break;
            sides.getPtr(each.side).* += each.push;
            each.push = 0;
        }
        forces.next_hit = 0;
        for ([_][2]collision.Quadrant{ .{ .left, .right }, .{ .fore, .aft } }) |pair| {
            const across = sides.get(pair[0]) - sides.get(pair[1]);
            if (across == 0) continue;
            if (forces.next_push >= push_slots) forces.next_push = 0;
            const slot = &forces.pushes[forces.next_push];
            slot.* = if (@abs(across) > 1) .{ .started = now, .strength = @min(@abs(across), push_most) / push_most } else null;
            forces.next_push += 1;
        }
    }

    /// How hard the motors turn at `now`, from every effect and push playing. Those that have run
    /// their course stop.
    pub fn motors(forces: *Forces, now: i32) Motors {
        var sum: Motors = .{};
        for (std.enums.values(Effect)) |effect| {
            const started = forces.started.get(effect) orelse continue;
            const file = forces.library.files.get(effect) orelse continue;
            const at = millis(now - started);
            if (at >= fileLength(file)) {
                forces.started.set(effect, null);
                continue;
            }
            sum.add(fileAt(file, at));
        }
        for (&forces.pushes) |*slot| {
            const push = slot.* orelse continue;
            const at = millis(now - push.started);
            if (at >= push_ms) {
                slot.* = null;
                continue;
            }
            sum.low += push.strength * @abs(@sin(at / 1000 * push_frequency * std.math.tau));
        }
        return sum.clamped();
    }
};

/// Ticks as milliseconds.
fn millis(ticks: i32) f32 {
    return @as(f32, @floatFromInt(ticks)) * ms_per_tick;
}

/// The milliseconds in each of the game's ticks.
const ms_per_tick = std.time.ms_per_s / main.ticks_per_second;

comptime {
    std.debug.assert(ms_per_tick * main.ticks_per_second == std.time.ms_per_s);
}

/// How deep groups may hold groups; one deeper plays nothing, as a group that holds itself would.
const max_depth = 4;

/// How long a file plays: its longest effect that no group holds, which the file plays all at once.
fn fileLength(file: frc.File) f32 {
    var most: f32 = 0;
    for (file.effects) |*effect| {
        if (!file.grouped(effect.id)) most = @max(most, length(file, effect, 0));
    }
    return most;
}

/// How long `effect` lasts: a group's members one after the other, or the longest of them.
fn length(file: frc.File, effect: *const frc.Effect, depth: u8) f32 {
    const group = switch (effect.kind) {
        .group => |group| group,
        else => return @floatFromInt(effect.duration),
    };
    if (depth >= max_depth) return 0;
    var total: f32 = 0;
    for (group.ids) |id| {
        const member = file.find(id) orelse continue;
        const each = length(file, member, depth + 1);
        total = switch (group.order) {
            .sequence => total + each,
            else => @max(total, each),
        };
    }
    return total;
}

/// How hard a file's effects push `at` milliseconds in: those no group holds, all at once.
fn fileAt(file: frc.File, at: f32) Motors {
    var sum: Motors = .{};
    for (file.effects) |*effect| {
        if (!file.grouped(effect.id)) sum.add(effectAt(file, effect, at, 0));
    }
    return sum;
}

/// How hard `effect` pushes `at` milliseconds in, by its envelope and its gain: a waveform on the
/// motor its frequency picks, a group by the member playing then or by them all.
fn effectAt(file: frc.File, effect: *const frc.Effect, at: f32, depth: u8) Motors {
    const lasts = length(file, effect, depth);
    if (!(at >= 0 and at < lasts)) return .{};
    const scale = envelopeAt(effect.envelope, at / lasts) * @as(f32, @floatFromInt(effect.gain)) / 100;
    return switch (effect.kind) {
        .pause => .{},
        .wave => |wave| waveAt(wave, at, lasts).scaled(scale),
        .group => |group| grouped: {
            if (depth >= max_depth) break :grouped .{};
            var sum: Motors = .{};
            var from: f32 = 0;
            for (group.ids) |id| {
                const member = file.find(id) orelse continue;
                switch (group.order) {
                    .sequence => {
                        sum.add(effectAt(file, member, at - from, depth + 1));
                        from += length(file, member, depth + 1);
                    },
                    else => sum.add(effectAt(file, member, at, depth + 1)),
                }
            }
            break :grouped sum.scaled(scale);
        },
    };
}

/// The envelope's share of the effect's strength, `share` of the way through it: rising from its
/// start to its level over the attack, holding, then falling to its end over the decay.
fn envelopeAt(envelope: frc.Envelope, share: f32) f32 {
    const in = share * 100;
    const attack: f32 = @floatFromInt(envelope.attack);
    const sustain: f32 = @floatFromInt(envelope.sustain);
    const decay: f32 = @floatFromInt(envelope.decay);
    const start: f32 = @floatFromInt(envelope.start);
    const end: f32 = @floatFromInt(envelope.end);
    const level: f32 = @floatFromInt(envelope.level);
    const at = if (in < attack)
        std.math.lerp(start, level, in / attack)
    else if (in < attack + sustain)
        level
    else if (in < attack + sustain + decay)
        std.math.lerp(level, end, (in - attack - sustain) / decay)
    else
        end;
    return at / 100;
}

/// How hard a waveform pushes `at` milliseconds into an effect lasting `lasts`: one slower than
/// `buzz_frequency` swinging the low motor as it swings, a faster one buzzing the high motor at the
/// most it reaches.
fn waveAt(wave: frc.Wave, at: f32, lasts: f32) Motors {
    const high = @as(f32, @floatFromInt(wave.high)) / 100;
    const low = @as(f32, @floatFromInt(wave.low)) / 100;
    if (wave.frequency >= buzz_frequency) return .{ .high = @max(@abs(high), @abs(low)) };
    const turn = @mod(at / 1000 * @as(f32, @floatFromInt(wave.frequency)), 1);
    const through = at / lasts;
    const middle = (high + low) / 2;
    const swing = (high - low) / 2;
    // Up and back down again over a turn, from nothing.
    const triangle = 1 - @abs(2 * turn - 1);
    const force: f32 = switch (wave.shape) {
        .constant => high,
        .ramp_up => std.math.lerp(low, high, through),
        .ramp_down => std.math.lerp(high, low, through),
        .sine => middle + swing * @sin(turn * std.math.tau),
        .cosine => middle + swing * @cos(turn * std.math.tau),
        .square_high => if (turn < 0.5) high else low,
        .square_low => if (turn < 0.5) low else high,
        .triangle_up => std.math.lerp(low, high, triangle),
        .triangle_down => std.math.lerp(high, low, triangle),
        .sawtooth_up => std.math.lerp(low, high, turn),
        .sawtooth_down => std.math.lerp(high, low, turn),
        _ => 0,
    };
    return .{ .low = @abs(force) };
}

pub const testing = struct {
    /// A library of files made for tests, each parsed from bytes it keeps.
    pub const Made = struct {
        library: Library = .{},
        bytes: std.EnumArray(Effect, ?[]u8) = .initFill(null),

        pub fn add(made: *Made, gpa: std.mem.Allocator, effect: Effect, effects: []const frc.testing.Made) !void {
            const bytes = try frc.testing.file(gpa, effects);
            errdefer gpa.free(bytes);
            made.library.files.set(effect, try .parse(gpa, bytes));
            made.bytes.set(effect, bytes);
        }

        pub fn deinit(made: *Made, gpa: std.mem.Allocator) void {
            for (std.enums.values(Effect)) |effect| {
                if (made.library.files.get(effect)) |file| file.deinit(gpa);
                if (made.bytes.get(effect)) |bytes| gpa.free(bytes);
            }
        }
    };
};

test load {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Without the folder, nothing plays.
    try std.testing.expect(load(io, arena, tmp.dir, &bigfile.Mods.none).lacking.contains(.lc));

    // The folder and its files are found whatever the case of their names; a file that isn't one
    // is left out.
    try tmp.dir.createDirPath(io, "Forces");
    const bytes = try frc.testing.file(arena, &.{.{ .id = 0, .name = "Sine1", .kind = 2, .type = 102, .duration = 305, .rest = &.{ 4, 30, @bitCast(@as(i32, -30)) } }});
    try tmp.dir.writeFile(io, .{ .sub_path = "Forces/Lc.FRC", .data = bytes });
    try tmp.dir.writeFile(io, .{ .sub_path = "Forces/SHAKE.frc", .data = "not an effect" });
    const found = load(io, arena, tmp.dir, &bigfile.Mods.none);
    try std.testing.expectEqual(305, found.library.files.get(.lc).?.effects[0].duration);
    try std.testing.expect(!found.lacking.contains(.lc));
    try std.testing.expectEqual(null, found.library.files.get(.shake));
    try std.testing.expect(found.lacking.contains(.shake) and found.lacking.contains(.missile));
}

test millis {
    // A tick is a hundredth of a second.
    try std.testing.expectEqual(10, millis(1));
    try std.testing.expectEqual(1000, millis(main.ticks_per_second));
}

test "Effect.fileName" {
    try std.testing.expectEqualStrings("lc.frc", Effect.lc.fileName());
    try std.testing.expectEqualStrings("Missile.frc", Effect.missile.fileName());
    try std.testing.expectEqualStrings("landhard.frc", Effect.landhard.fileName());
    try std.testing.expect(!Effect.shake.unread() and Effect.shield.unread());
}

test envelopeAt {
    // Rising over the first half from nothing, then falling to nothing.
    const envelope: frc.Envelope = .{ .attack = 50, .sustain = 0, .decay = 50, .start = 0, .end = 0, .level = 100 };
    try std.testing.expectApproxEqAbs(0.5, envelopeAt(envelope, 0.25), 1e-6);
    try std.testing.expectApproxEqAbs(1, envelopeAt(envelope, 0.5), 1e-6);
    try std.testing.expectApproxEqAbs(0.5, envelopeAt(envelope, 0.75), 1e-6);
    // Full throughout, as the editor leaves an envelope.
    try std.testing.expectEqual(1, envelopeAt(.{}, 0.9));
}

test waveAt {
    // A slow sine between 100 and -100 swings the low motor, strongest a quarter of the way round.
    const slow: frc.Wave = .{ .shape = .sine, .frequency = 2, .high = 100, .low = -100 };
    try std.testing.expectApproxEqAbs(1, waveAt(slow, 125, 1000).low, 1e-5);
    try std.testing.expectApproxEqAbs(0, waveAt(slow, 250, 1000).low, 1e-5);
    // A fast one buzzes the high motor at the most it reaches.
    const fast: frc.Wave = .{ .shape = .cosine, .frequency = 24, .high = 25, .low = -25 };
    try std.testing.expectEqual(Motors{ .high = 0.25 }, waveAt(fast, 10, 1000));
    // A ramp runs once over the effect.
    const ramp: frc.Wave = .{ .shape = .ramp_up, .frequency = 1, .high = 100, .low = 0 };
    try std.testing.expectApproxEqAbs(0.25, waveAt(ramp, 250, 1000).low, 1e-6);
}

test Forces {
    const gpa = std.testing.allocator;
    var made: testing.Made = .{};
    defer made.deinit(gpa);
    // A shot of a quarter second, and a shake of a second.
    try made.add(gpa, .lc, &.{.{ .id = 0, .name = "Square", .kind = 2, .type = 105, .duration = 250, .rest = &.{ 1, 100, 100 } }});
    try made.add(gpa, .shake, &.{.{ .id = 0, .name = "Cosine1", .kind = 2, .type = 103, .duration = 1000, .rest = &.{ 14, 30, @bitCast(@as(i32, -30)) } }});
    try made.add(gpa, .shield, &.{.{ .id = 0, .name = "Cosine1", .kind = 2, .type = 103, .duration = 1000, .rest = &.{ 24, 25, @bitCast(@as(i32, -25)) } }});
    var forces: Forces = .{ .library = &made.library };

    // Nothing plays while they are off.
    forces.start(.lc, 0);
    try std.testing.expect(!forces.playing(.lc, 0));

    forces.feedback = true;
    forces.start(.lc, 0);
    try std.testing.expect(forces.playing(.lc, 10));
    try std.testing.expectEqual(Motors{ .low = 1 }, forces.motors(10));
    // A quarter of a second later it has stopped.
    try std.testing.expectEqual(Motors{}, forces.motors(25));
    try std.testing.expect(!forces.playing(.lc, 25));

    // The shake starts only while it isn't playing.
    forces.startUnlessPlaying(.shake, 100);
    forces.startUnlessPlaying(.shake, 150);
    try std.testing.expectEqual(100, forces.started.get(.shake));
    try std.testing.expectEqual(Motors{ .high = 0.3 }, forces.motors(150));

    // An effect the game never reads plays only where OpenReliant lets it.
    forces.settings = .original;
    forces.start(.shield, 200);
    try std.testing.expect(!forces.playing(.shield, 200));
    forces.settings = .{};
    forces.start(.shield, 200);
    try std.testing.expect(forces.playing(.shield, 200));

    // Nothing starts while the setting is off.
    forces.setting = false;
    forces.start(.lc, 300);
    try std.testing.expect(!forces.playing(.lc, 300));
}

test "Forces.afterburner" {
    const gpa = std.testing.allocator;
    var made: testing.Made = .{};
    defer made.deinit(gpa);
    try made.add(gpa, .afterburn, &.{.{ .id = 0, .name = "Constant", .kind = 2, .type = 101, .duration = 5000, .rest = &.{ 1, 100, 100 } }});
    var forces: Forces = .{ .library = &made.library, .feedback = true };
    // It lights, burns on without starting again, and goes out.
    forces.afterburner(true, 0);
    forces.afterburner(true, 10);
    try std.testing.expectEqual(0, forces.started.get(.afterburn));
    forces.afterburner(false, 20);
    try std.testing.expect(!forces.playing(.afterburn, 20));
}

test "a file of a sequence plays each of its effects in turn" {
    const gpa = std.testing.allocator;
    var made: testing.Made = .{};
    defer made.deinit(gpa);
    // A constant for 100 milliseconds, a pause of 50, then a fast buzz for 100; the group names
    // them out of order.
    try made.add(gpa, .afterburn, &.{
        .{ .id = 0, .name = "Constant", .kind = 2, .type = 101, .duration = 100, .rest = &.{ 1, 80, 80 } },
        .{ .id = 1, .name = "Delay", .kind = 1, .type = 10, .duration = 50, .rest = &.{} },
        .{ .id = 2, .name = "Buzz", .kind = 2, .type = 102, .duration = 100, .rest = &.{ 30, 50, @bitCast(@as(i32, -50)) } },
        .{ .id = 3, .name = "Sequence", .kind = 3, .type = 202, .duration = 1000, .rest = &.{ 0, 1, 2 } },
    });
    var forces: Forces = .{ .library = &made.library, .feedback = true };
    try std.testing.expectEqual(250, fileLength(made.library.files.get(.afterburn).?));
    forces.start(.afterburn, 0);
    try std.testing.expectApproxEqAbs(0.8, forces.motors(5).low, 1e-6);
    try std.testing.expectEqual(Motors{}, forces.motors(12));
    try std.testing.expectEqual(Motors{ .high = 0.5 }, forces.motors(20));
    try std.testing.expectEqual(Motors{}, forces.motors(25));
}

test "the frame's hits push the ship" {
    const gpa = std.testing.allocator;
    var made: testing.Made = .{};
    defer made.deinit(gpa);
    var forces: Forces = .{ .library = &made.library, .feedback = true };

    // Two hits on the left, one on the right: across by the difference, along not at all.
    forces.hit(.left, 10);
    forces.hit(.left, 10);
    forces.hit(.right, 5);
    forces.pushFrame(0);
    try std.testing.expectEqual(Push{ .started = 0, .strength = 0.45 }, forces.pushes[0].?);
    try std.testing.expectEqual(null, forces.pushes[1]);
    // It swings the low motor twice a second, for a second.
    try std.testing.expectApproxEqAbs(0.45, forces.motors(12).low, 1e-3);
    try std.testing.expectEqual(Motors{}, forces.motors(100));

    // The pushes take their slots in turn, and one of 1 or less empties the slot it takes.
    forces.hit(.fore, 100);
    forces.pushFrame(10);
    try std.testing.expectEqual(1, forces.pushes[1].?.strength);
    forces.hit(.aft, 0.001);
    forces.pushFrame(20);
    try std.testing.expectEqual(null, forces.pushes[2]);
    try std.testing.expectEqual(3, forces.next_push);
}
