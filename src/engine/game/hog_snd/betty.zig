//! Betty, the ship's computer, who speaks the cockpit's warnings and the devices' states: the
//! sounds of `betty.fat` (`bank_betty`, `0x0056654C`), which `hog_SND.CPP` plays as it plays any
//! bank's (`hog_snd.Sound.play`).

const std = @import("std");

const fat = @import("../../../formats/fat.zig");
const gameobj = @import("../gameobj.zig");
const hog_snd = @import("../hog_snd.zig");
const mss = @import("../../mss.zig");

/// Her lines, the sounds of `bank_betty`.
pub const Line = enum(u8) {
    /// The armed missile run out.
    missiles_gone = 0,
    /// A quadrant has lost its shield and half its armour (`main.armorWarning`).
    armor_failing = 1,
    /// The armed missile's name, as the missile ring turns to it.
    screamer = 2,
    havoc = 3,
    jack_hammer = 4,
    vagabond = 5,
    imp = 6,
    bandit = 7,
    raptor = 8,
    hawk = 9,
    solomon = 10,
    /// Countermeasures running low, and gone.
    countermeasures_low = 0xD,
    countermeasures_gone = 0xF,
    /// A device turning on, and off.
    cloak_on = 0x10,
    cloak_off = 0x11,
    blind_fire_on = 0x12,
    blind_fire_off = 0x13,
    spectral_shields_on = 0x14,
    spectral_shields_off = 0x15,
    _,
};

/// Betty says `line` through `sound`, as loud as a sound plays, in the middle, once: the voice she
/// says it on, or null where her bank isn't loaded or no voice is free.
pub fn say(sound: *hog_snd.Sound, line: Line) ?u8 {
    const bank = sound.betty orelse return null;
    return sound.play(bank, @intFromEnum(line), hog_snd.loudest, hog_snd.once, hog_snd.centre, hog_snd.own_pitch);
}

/// Betty says `line` in `world`, where anything is heard there.
pub fn sayIn(world: ?gameobj.World, line: Line) void {
    const heard = world orelse return;
    const hearing = heard.hearing orelse return;
    _ = say(hearing.sound, line);
}

test say {
    var speaker: hog_snd.testing.Speaker = undefined;
    try speaker.init(2, null);
    const driver = speaker.mixer.driver();
    const sound = &speaker.sound;
    // Without her bank, she says nothing.
    try std.testing.expectEqual(null, say(sound, .cloak_on));
    // With it, her line plays on a voice, as loud as a sound plays.
    const bytes = comptime hog_snd.testing.bank(@intFromEnum(Line.cloak_on) + 1);
    sound.betty = try fat.Bank.parse(&bytes);
    const voice = say(sound, .cloak_on) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(mss.Status.playing, driver.sampleStatus(sound.voices[voice].sample));
}
