//! The game's random numbers.
//!
//! **Improvement:** they come from Zig's `std.Random`, its default generator, where the game
//! draws them from the C runtime's `rand` (`0x004CF555`), a linear congruential generator seeded
//! by `srand` (`0x004CF548`). They keep `rand`'s range, 0 to 32767, so the game's code uses them
//! unchanged. The sequences differ from the original's. Each mission's start seeds them afresh, as
//! the game's does (`main.Start.seed`).

const std = @import("std");

pub const Random = struct {
    numbers: std.Random.DefaultPrng = .init(default_seed),

    /// The largest number `rand` gives, as the runtime's `RAND_MAX`.
    pub const max = std.math.maxInt(u15);

    /// The seed a generator starts from until it is given one, as the runtime's starts from 1.
    pub const default_seed = 1;

    pub fn init(seed: u64) Random {
        return .{ .numbers = .init(seed) };
    }

    /// The next number, from 0 to `max`, as the game's code draws one from `rand`.
    pub fn rand(r: *Random) u15 {
        return r.numbers.random().int(u15);
    }

    /// Whether the next number is a multiple of `odds`, about one draw in `odds`, as the game's code
    /// tests `rand() % odds == 0`.
    pub fn oneIn(r: *Random, odds: u15) bool {
        return r.rand() % odds == 0;
    }

    /// The next number modulo `n`, from 0 to `n` less one, as the game's code takes `rand() % n`.
    pub fn below(r: *Random, n: u15) u15 {
        return r.rand() % n;
    }

    /// One of `items`, by the next number modulo their count, as the game's code picks one with
    /// `rand() % count`.
    pub fn pick(r: *Random, items: anytype) @TypeOf(items[0]) {
        return items[r.rand() % items.len];
    }

    /// `number` divided by `max`, a fraction from 0 to 1, as the game's code scales `rand`'s: it
    /// multiplies by the reciprocal (`0x004DC4C8`).
    pub fn share(number: u15) f32 {
        return @as(f32, @floatFromInt(number)) * (1.0 / @as(f32, max));
    }

    /// The next number as a fraction from 0 to 1 (`share`).
    pub fn fraction(r: *Random) f32 {
        return share(r.rand());
    }

    /// `fraction` less a half, from -0.5 to 0.5, as the game's code takes it for a direction or a
    /// turn either way.
    pub fn centred(r: *Random) f32 {
        return r.fraction() - 0.5;
    }

    /// Three `fraction`s times `reach`, drawn z first, as the game's code draws a vector: its
    /// compiler evaluates a call's arguments from last to first.
    pub fn fractionVector(r: *Random, reach: @Vector(3, f32)) @Vector(3, f32) {
        const z = r.fraction();
        const y = r.fraction();
        const x = r.fraction();
        return @Vector(3, f32){ x, y, z } * reach;
    }

    /// `fractionVector`, each less a half: from -0.5 to 0.5 times `reach`.
    pub fn centredVector(r: *Random, reach: @Vector(3, f32)) @Vector(3, f32) {
        return (r.fractionVector(@splat(1)) - @as(@Vector(3, f32), @splat(0.5))) * reach;
    }

    /// A number made from this generator's state, without drawing from it, for seeding another
    /// generator such as the mods' scripts'.
    pub fn fingerprint(r: *const Random) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&r.numbers.s));
    }
};

test "the numbers keep rand's range" {
    var random: Random = .{};
    var largest: u15 = 0;
    for (0..1000) |_| {
        const drawn = random.rand();
        largest = @max(largest, drawn);
        const share = random.fraction();
        try std.testing.expect(share >= 0 and share <= 1);
    }
    try std.testing.expect(largest > Random.max / 2);
}

test "a vector's numbers are drawn last first" {
    var drawn: Random = .{};
    const vector = drawn.centredVector(.{ 1, 2, 4 });
    var one_by_one: Random = .{};
    const z = one_by_one.centred() * 4;
    const y = one_by_one.centred() * 2;
    const x = one_by_one.centred();
    try std.testing.expectEqual(@Vector(3, f32){ x, y, z }, vector);
    try std.testing.expectEqual(one_by_one.fingerprint(), drawn.fingerprint());
}

test "a seed gives the same numbers each time, and the fingerprint follows them" {
    var first: Random = .init(7);
    var second: Random = .init(7);
    try std.testing.expectEqual(first.fingerprint(), second.fingerprint());
    for (0..10) |_| try std.testing.expectEqual(first.rand(), second.rand());
    const before = first.fingerprint();
    _ = first.rand();
    try std.testing.expect(first.fingerprint() != before);
}

test "oneIn, below and pick each take one draw, modulo" {
    var random: Random = .init(7);
    var same: Random = .init(7);
    const choices = [_]u8{ 10, 20, 30 };
    for (0..100) |_| {
        try std.testing.expectEqual(same.rand() % 4 == 0, random.oneIn(4));
        try std.testing.expectEqual(same.rand() % 5, random.below(5));
        try std.testing.expectEqual(choices[same.rand() % choices.len], random.pick(&choices));
    }
}
