//! `C:\lancer\game\shieldfx.cpp`: what a hit leaves where it struck (`0x004A0310`, 12 bytes), which
//! `0x004992D0` (`objects.cpp`) hangs from the part struck as a node of kind 6, by what struck:
//!
//! | Kind | Struck by | What it leaves |
//! |---|---|---|
//! | 2 | A shot or a missile through to a hull (`bullet_hull_hit`, `missile_hit_hull`) | The hit's sound (`hullHit`), and an emitter of `0x0049FD20`'s orange template on the part's surface nearest the point (`0x0049FEF0`), facing out from it |
//! | 3 | A shot or a missile on a component (`bullet_hit`, `0x0047B840`, `0x00495AC0`) | On an object with a shield generator that isn't exploding, its capital shield instead (`componentHit`); otherwise a burst of 20 of the orange template's particles |
//! | 4 | Nothing | An emitter of the grey template |
//! | 5 | A shot on a component of an asteroid, a turret asteroid or a hole (`bullet_hit`, `0x0047B840`) | Sound 71, and `0x00472780` |
//!
//! Nothing sends the emitters' particles out: `node_draw` updates a node of kind 6 through
//! `0x00458AB0`, which is the one routine the build keeps of every routine that only returns 1, so
//! a hull's emitter shows nothing.
//!
//! OpenReliant keeps no nodes, as none shows anything once made: it sounds a hull's hit, bursts a
//! component's, and sounds a rock's. The game hangs a part no more than a hundred nodes, so a
//! hull's part struck a hundred times no longer sounds; OpenReliant's sounds every time. A
//! component's are never that many: kind 3 first clears the nodes of earlier hits nearby, and the
//! oldest past ten.
//!
//! A rock's also throws a chunk of rock from the point struck (`explode.rocks.throw`).

const std = @import("std");

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const explode = @import("explode.zig");
const gameobj = @import("gameobj.zig");
const objects = @import("objects.zig");
const particles = @import("particles.zig");
const shield = @import("shield.zig");
const sound3d = @import("sound3d.zig");

/// What a hit leaves where it struck, which `0x004992D0` is handed (the table above).
pub const Kind = enum(i32) {
    hull = 2,
    component = 3,
    grey = 4,
    rock = 5,

    /// What a shot leaves on a component of an object of `object_type` (`bullet_hit`,
    /// `0x0047B840`): `rock` on what is made of rock (`gameobj.Type.rock`).
    pub fn onComponentOf(object_type: gameobj.Type) Kind {
        return if (object_type.rock() != null) .rock else .component;
    }
};

/// `0x004992D0` for a shot or a missile that `crossing` has striking a component of the object in
/// slot `index`, leaving `kind`. On an object with a shield generator that isn't exploding, the
/// part's capital shield glows round the face struck (`shield.flareCapital`); otherwise the hit
/// bursts (`burst`). A rock's sounds `COLL02` where it struck and throws a chunk of rock from
/// there, along the face's normal.
///
/// **Fix:** the game throws the chunk along the normal in the part's own frame, taken for a
/// direction in the world's, so a chunk from a tumbling rock flies off any way. OpenReliant turns
/// the normal into the world's.
pub fn componentHit(world: gameobj.World, index: u16, crossing: objects.Crossing, kind: Kind) void {
    switch (kind) {
        .component => {
            const flags = world.objects.slots[index].object.flags;
            if (flags.shield_generator and !flags.exploding) return shield.flareCapital(world, index, crossing.part, crossing.part.polygon(crossing.face));
            burst(world, crossing);
        },
        .rock => {
            const drawn = crossing.part.part().drawn();
            sound3d.playIn(world, crossing.inWorld(), @splat(0), null, .coll02, 1, .not_reserved);
            explode.throwChunk(world, crossing.point, math.transform(drawn.orientation, crossing.normal), .{ .from_part = drawn });
        },
        .hull, .grey => {},
    }
}

/// What a component's hit bursts into (`shieldfx_orange`, `0x0049FD20`): orange puffs growing from
/// 50 to 100 across as they fade over about a second.
pub const orange: particles.Template = .{
    .life = 100,
    .life_spread = 10,
    .rate = .through(15, 10, 0),
    .size = .through(50, 75, 100),
    .colour = .{ .through(1, 0.25, 0), .through(0.5, 0.25, 0), .through(0, 0.25, 0) },
};

/// How many puffs a component's hit bursts into, and how they leave the point struck: out along
/// the face's normal at 10 to 12 a tick, straying up to an eighth either way across
/// (`shieldfx_create`).
const burst_count = 20;
const burst_speed: f32 = 10;
const burst_speed_range: f32 = 2;
const burst_spread: Vector = .{ 0.25, 0.25, 0 };

/// `shieldfx_create`'s kind 3: an emitter of `orange` hanging from the part at the point struck,
/// facing out along the face's normal, bursts `burst_count` puffs.
fn burst(world: gameobj.World, crossing: objects.Crossing) void {
    var emitter: particles.Emitter = .{
        .life = burst_life,
        .born = world.clock.frame_start,
        .place = .{ .position = crossing.point, .orientation = outFrom(crossing.normal) },
        .direction = .{ 0, 0, 1 },
        .spread = burst_spread,
        .speed = burst_speed,
        .speed_range = burst_speed_range,
        .template = &orange,
    };
    explode.burstWithin(world, &emitter, crossing.part.part().drawn(), burst_count);
}

/// How long the emitter lives, which a burst doesn't read.
const burst_life = 1000;

/// A frame whose forward axis is `normal` (`shieldfx_create`): across it, `X` crossed with the
/// normal, and up, that crossed with the normal again.
///
/// **Fix:** the game's frame is not a number for a normal along `X`; OpenReliant takes the frame
/// `math.lookAt` gives that normal.
fn outFrom(normal: Vector) math.Matrix {
    const forward = math.normalize(normal);
    const side = math.cross(.{ 1, 0, 0 }, forward);
    if (!(math.length(side) > 1e-6)) return math.lookAt(forward);
    const across = math.normalize(side);
    const up = math.normalize(math.cross(across, forward));
    return math.fromAxes(up, across, forward);
}

/// How long after a shot last sounded on the player's hull another does (`0x00593794`).
const player_hit_pause = 30;

/// `0x004A0310`'s sound for a shot through to the hull of the object in slot `index` at `at`:
/// `ARMOUR01` there, facing the camera; on the player's own ship `PLAYERHIT` instead, following it,
/// no more than once in `player_hit_pause` ticks.
///
/// **Improvement:** the game plays `ARMOUR01` at the point struck in the part's own frame, taken
/// for one in the world, so it is heard from near the world's origin; OpenReliant plays it where
/// the shot struck.
pub fn hullHit(world: gameobj.World, index: u16, at: Vector) void {
    const hearing = world.hearing orelse return;
    const all = world.objects;
    const now = world.clock.frame_start;
    const facing = math.normalize(hearing.camera.position - at);
    if (index != all.player) {
        _ = sound3d.play(hearing.sound, hearing.scene(world), at, facing, null, .armour01, 1, .not_reserved);
        return;
    }
    if (now - hearing.sound.player_hit_at < player_hit_pause) return;
    hearing.sound.player_hit_at = now;
    _ = sound3d.play(hearing.sound, hearing.scene(world), all.slots[index].drawn.position, facing, index, .playerhit, 1, .guaranteed);
}

test {
    std.testing.refAllDecls(@This());
}

test hullHit {
    const hog_snd = @import("hog_snd.zig");
    var speaker: hog_snd.testing.Speaker = undefined;
    try speaker.init(2, null);
    const sound = &speaker.sound;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var world = mission.world();
    world.hearing = speaker.hearing(&mission.clock);
    const player = try mission.add(.predator, @splat(0));
    const other = try mission.add(.sabre, .{ 0, 0, 1000 });

    // The player's hull sounds a hit, then none for thirty ticks.
    mission.clock.frame_start = 100;
    hullHit(world, player, .{ 0, 0, 10 });
    try std.testing.expectEqual(100, sound.player_hit_at);
    mission.clock.frame_start = 120;
    hullHit(world, player, .{ 0, 0, 10 });
    try std.testing.expectEqual(100, sound.player_hit_at);
    mission.clock.frame_start = 130;
    hullHit(world, player, .{ 0, 0, 10 });
    try std.testing.expectEqual(130, sound.player_hit_at);
    // Another ship's hull sounds every hit, and leaves the player's pause alone.
    hullHit(world, other, .{ 0, 0, 990 });
    try std.testing.expectEqual(130, sound.player_hit_at);
}

test componentHit {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var image: @import("../surrender/surrenderlib/srtexture.zig").Image = undefined;
    var pool: particles.Pool = try .init(std.testing.allocator, 100, &image, .add);
    defer pool.deinit();
    var watching: @import("camera.zig").Camera = .{};
    var world = mission.world();
    world.particles = &pool;
    world.camera = &watching;
    mission.clock.frame_start = 10;
    const index = try mission.add(.kamov, .{ 0, 0, 1000 });
    var parts: [1]objects.Model.Part = .{.{ .hidden = false, .parent = null, .origin = @splat(0), .object = .{ .flags = .{}, .position = .{ 0, 0, 1000 }, .radius = 100, .levels = &.{} } }};
    var model: objects.Model = .{ .parts = &parts, .order = &.{}, .lights = &.{}, .glows = &.{}, .mounts = &.{} };
    const crossing: objects.Crossing = .{ .part = .{ .model = &model, .index = 0 }, .face = 0, .point = .{ 0, 0, -50 }, .normal = .{ 0, 0, -1 } };

    // A shield generator's ship glows instead, which leaves nothing on the part.
    const flags = &mission.slot(index).object.flags;
    flags.shield_generator = true;
    componentHit(world, index, crossing, .component);
    try std.testing.expectEqual(0, particles.testing.sent(&pool));
    // Without one, the hit bursts into twenty orange puffs, heading out along the face's normal.
    flags.shield_generator = false;
    componentHit(world, index, crossing, .component);
    try std.testing.expectEqual(burst_count, particles.testing.sent(&pool));
    for (pool.particles[0..burst_count]) |particle| {
        try std.testing.expectEqual(&orange, particle.template.?);
        try std.testing.expect(particle.velocity[2] < 0);
    }
    // A rock's leaves no puffs.
    componentHit(world, index, crossing, .rock);
    try std.testing.expectEqual(burst_count, particles.testing.sent(&pool));
}

test outFrom {
    // Its forward axis is the normal, and it is a turn: its axes a right-handed set of units.
    for ([_]Vector{ .{ 0, 0, -1 }, .{ 0.3, 0.8, 0.2 }, .{ 1, 0, 0 } }) |normal| {
        const frame = outFrom(normal);
        const forward: Vector = .{ frame[2], frame[5], frame[8] };
        try std.testing.expectApproxEqAbs(1, math.dot(forward, math.normalize(normal)), 1e-5);
        const up: Vector = .{ frame[0], frame[3], frame[6] };
        const across: Vector = .{ frame[1], frame[4], frame[7] };
        try std.testing.expectApproxEqAbs(1, math.dot(math.cross(up, across), forward), 1e-5);
    }
}
