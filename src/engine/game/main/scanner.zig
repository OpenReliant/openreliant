//! The scanner, in `C:\lancer\game\main.cpp`: the mission script's `Scanner` command has the player
//! look for an object (`scanner_object`, `0x0057E060`), which the display shows with a hand sending
//! rings out (`hud_scanner`, [`hud.zig`](../hud.zig)), and toward which `mission_frame` beeps
//! (`0x004929D8` to `0x00492B30`), quicker the nearer the object stands and the more nearly ahead
//! of the player's ship. [`hud.md`](../../../../docs/engine/hud.md#the-jump-prompt-the-eject-marker-and-the-scanner)
//! describes it.
//!
//! **Unverified:** `mission_frame`'s beep (`0x004929D8`) lies after `language.cpp`'s code and
//! before `main.cpp`'s known code (`0x004934F0`); by what it does it is this file's.

const std = @import("std");

const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const gameobj = @import("../gameobj.zig");
const hog_snd = @import("../hog_snd.zig");

/// What the scanner keeps between frames, which the game holds in globals.
pub const Scanner = struct {
    /// `scanner_object` (`0x0057E060`): the slot of the object the player looks for; none while the
    /// scanner is off, as it is from a mission's start (`mission_start`, `0x004935DD`).
    object: ?u16 = null,
    /// Whether the beep loops on a voice kept for it (`scanner_voice`, `0x005883C4`,
    /// `hog_snd.commands.Kept.scanner`), as it does while it comes at its quickest. It doesn't
    /// otherwise, or from a mission's start.
    loop_kept: bool = false,
    /// `scanner_beeped_at` (`0x005883C8`): the frame's start the beep last came at.
    beeped_at: i32 = 0,

    /// The `Scanner` command's part (`cmd_Scanner`, `0x00459CB0`): the scanner looks for the object
    /// of slot `object`, or is off for none, the beep due at once. A beep looping goes on until the
    /// next frame's (`frame`).
    pub fn set(scanner: *Scanner, object: ?u16) void {
        scanner.object = object;
        scanner.beeped_at = 0;
    }

    /// `mission_frame`'s beep (`0x004929D8`), in the frame starting at `frame_start`. While the
    /// scanner is off, a loop playing ends. While the object it looks for explodes, it turns off.
    /// Otherwise, once `interval` has passed since the last beep, the beep comes again: at its
    /// quickest it loops on a voice of its own, started where none plays; slower, a loop playing
    /// ends and the beep plays once. It is heard in every view, where anything is heard
    /// (`gameobj.World.sounds`). Where no voice is free for the loop, the game asks again at the
    /// next beep; OpenReliant's game frames ask once, and the loop waits for a voice
    /// (`hog_snd.commands.Sample.waits`).
    pub fn frame(scanner: *Scanner, world: gameobj.World, frame_start: i32) void {
        const index = scanner.object orelse return scanner.endLoop(world.sounds);
        const all = world.objects;
        const sought = &all.slots[index].object;
        if (sought.flags.exploding) {
            scanner.object = null;
            return;
        }
        const ship = &all.slots[all.player].object;
        const ticks = interval(sought.nextPosition() - ship.nextPosition(), ship.nextHeading());
        if (scanner.beeped_at + ticks >= frame_start) return;
        scanner.beeped_at = frame_start;
        const asked = world.sounds orelse return;
        if (ticks <= quickest) {
            if (scanner.loop_kept) return;
            asked.add(.{ .sample = .{ .bank = .stdsmp, .index = beep_sample, .loops = hog_snd.forever, .kept = .scanner, .waits = true } });
            scanner.loop_kept = true;
        } else {
            scanner.endLoop(asked);
            asked.add(.{ .sample = .{ .bank = .stdsmp, .index = beep_sample } });
        }
    }

    /// Ends the loop playing, where one is (`sound_voice_end`).
    fn endLoop(scanner: *Scanner, sounds: ?*hog_snd.commands.Commands) void {
        if (!scanner.loop_kept) return;
        if (sounds) |asked| asked.add(.{ .ended = .scanner });
        scanner.loop_kept = false;
    }
};

/// The quickest and the slowest the beep comes, in ticks (`0x00492A76`); at the quickest it loops.
pub const quickest = 10;
pub const slowest = 200;

/// What the cosine of the object's angle off the nose is taken from (`0x004DC480`), and the ticks
/// for each unit of its distance (`0x004DC49C`).
const bearing_base: f32 = 2;
const ticks_per_unit: f32 = 0.001;

/// The beep: `bank_stdsmp`'s sound 7, at full volume, in the middle (`0x00492ABE`).
const beep_sample = 7;

/// The ticks from one beep to the next for an object `offset` from the player's ship, whose nose
/// points along `heading`: a thousandth of the distance, times 2 less the cosine of the angle the
/// object stands off the nose, so three times as long behind as ahead, rounded as `sr_round` rounds
/// and kept from `quickest` to `slowest`. An object where the ship stands comes at the quickest, as
/// `sr_round` turns the game's 0 over 0 into the least integer.
pub fn interval(offset: Vector, heading: Vector) i32 {
    const distance = math.length(offset);
    const cosine = math.cosineOff(offset, heading);
    return std.math.clamp(math.round((bearing_base - cosine) * distance * ticks_per_unit), quickest, slowest);
}

test interval {
    const ahead: Vector = .{ 0, 0, 1 };
    // Dead ahead, a thousandth of the distance; abeam, twice that; behind, three times.
    try std.testing.expectEqual(50, interval(.{ 0, 0, 50000 }, ahead));
    try std.testing.expectEqual(100, interval(.{ 50000, 0, 0 }, ahead));
    try std.testing.expectEqual(150, interval(.{ 0, 0, -50000 }, ahead));
    // Near, the quickest; far, the slowest; and where the ship stands, the quickest.
    try std.testing.expectEqual(quickest, interval(.{ 0, 0, 4000 }, ahead));
    try std.testing.expectEqual(slowest, interval(.{ 0, 0, 900000 }, ahead));
    try std.testing.expectEqual(quickest, interval(@splat(0), ahead));
}

test "the scanner beeps toward its object, looping at its quickest" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    _ = try mission.add(.of(.predator), @splat(0));
    const sought = try mission.add(.of(.sabre), .{ 0, 0, 4000 });
    var speaker: hog_snd.testing.Speaker = undefined;
    const bank = comptime hog_snd.testing.bank(beep_sample + 1);
    try speaker.init(4, &bank);
    defer speaker.deinit();
    const sound = &speaker.sound;
    var world = mission.world();
    speaker.hear(&world);
    const kept = &speaker.asked.kept;
    var scanner: Scanner = .{};

    // Off, it is silent.
    scanner.frame(world, 100);
    speaker.heard();
    try std.testing.expectEqual(0, scanner.beeped_at);
    // Near and ahead, the beep loops at once, and comes again only once the interval has passed.
    scanner.set(sought);
    scanner.frame(world, 100);
    speaker.heard();
    const loop = kept.get(.scanner).voice.?;
    try std.testing.expect(sound.voicePlaying(loop));
    try std.testing.expectEqual(100, scanner.beeped_at);
    scanner.frame(world, 110);
    speaker.heard();
    try std.testing.expectEqual(100, scanner.beeped_at);
    // Further off, the loop goes on until the slower interval has passed; then it ends, and the beep
    // plays once.
    mission.slot(sought).object.root.next_position.z = 100000;
    scanner.frame(world, 200);
    speaker.heard();
    try std.testing.expect(sound.voicePlaying(loop));
    scanner.frame(world, 201);
    speaker.heard();
    try std.testing.expect(!scanner.loop_kept);
    try std.testing.expectEqual(201, scanner.beeped_at);
    scanner.frame(world, 301);
    speaker.heard();
    try std.testing.expectEqual(201, scanner.beeped_at);

    // Near again it loops, and off, the loop ends the next frame.
    mission.slot(sought).object.root.next_position.z = 4000;
    scanner.frame(world, 400);
    speaker.heard();
    const again = kept.get(.scanner).voice.?;
    try std.testing.expect(sound.voicePlaying(again));
    scanner.set(null);
    scanner.frame(world, 401);
    speaker.heard();
    try std.testing.expect(!scanner.loop_kept);
    try std.testing.expect(!sound.voicePlaying(again));
    // An object that explodes turns the scanner off.
    scanner.set(sought);
    mission.slot(sought).object.flags.exploding = true;
    scanner.frame(world, 500);
    try std.testing.expectEqual(null, scanner.object);
}
