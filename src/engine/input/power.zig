//! The power distribution and the shield balance, which the player's controls set. The player
//! shares the ship's power between its shields, guns and engines by moving a point on the power
//! ball (`GameObject.power_setting`), and each system's share scales how fast its shields or guns
//! recharge, or how fast it flies. The code lies with the player's controls
//! ([`input.zig`](../input.zig)).

const std = @import("std");

const gameobj = @import("../game/gameobj.zig");
const create = @import("../game/create.zig");
const math = @import("../surrender/math.zig");

/// The radius of the disc the power setting stays in (`0x004DC548` holds its square).
pub const radius: f32 = 64;

/// What the power goes to, each system with an anchor on the ball.
pub const System = enum { shields, guns, engines };

/// The direction of each system's anchor from the middle of the ball (`0x00412560`): the three a
/// third of a turn apart.
///
/// **Improvement:** the game writes the guns' and engines' `x`, √3/2, as 0.866. OpenReliant uses
/// √3/2 itself, which sets those anchors 0.00002 further from the middle.
pub const anchors = std.EnumArray(System, [2]f32).init(.{
    .shields = .{ 0, 1 },
    .guns = .{ half_root_three, -0.5 },
    .engines = .{ -half_root_three, -0.5 },
});

const half_root_three: f32 = @sqrt(3.0) / 2.0;

/// `0x004124E0`: how far the setting is toward `direction`: the distance from it to the edge of the
/// disc going the opposite way. At the anchor that is the whole width of the disc, 128; in the
/// middle, 64; opposite the anchor, 0.
pub fn reach(setting: [2]f32, direction: [2]f32) f32 {
    const along = direction[0] * setting[0] + direction[1] * setting[1];
    const square = along * along - ((setting[1] * setting[1] + setting[0] * setting[0]) - radius * radius);
    if (square < 0) return 0;
    const found = @sqrt(square) + along;
    return if (found < 0) 0 else found;
}

/// Each system's share of the power for a setting: its `reach` over the three together.
pub fn shares(setting: [2]f32) std.EnumArray(System, f32) {
    var reaches: std.EnumArray(System, f32) = undefined;
    for (std.enums.values(System)) |system| reaches.set(system, reach(setting, anchors.get(system)));
    const whole = 1 / (reaches.get(.engines) + reaches.get(.guns) + reaches.get(.shields));
    var found: std.EnumArray(System, f32) = undefined;
    for (std.enums.values(System)) |system| found.set(system, whole * reaches.get(system));
    return found;
}

/// The factor a share of the power gives its system (`0x00412560`): 1 for an even third, 1.5 for
/// all of the power and `least_factor` for none, rising by `factor_rise` less `factor_ease` for
/// each share.
pub fn factor(share: f32) f32 {
    return (factor_rise - share * factor_ease) * share + least_factor;
}

/// How fast the factor rises from no share (`0x004DC54C`), and how much of that the share itself
/// takes back (`0x004DC550`).
const factor_rise: f32 = 1.75;
const factor_ease: f32 = 0.75;

/// The factor of no share of the power at all (`0x004DC408`).
const least_factor: f32 = 0.5;

/// The setting's `x` and `y`, the point on the ball.
pub fn point(object: *const gameobj.GameObject) [2]f32 {
    return .{ object.power_setting.x, object.power_setting.y };
}

/// `0x00412560`: sets the object's `shield_factor`, `gun_factor` and `speed_factor` from its power
/// setting.
pub fn distribute(object: *gameobj.GameObject) void {
    const found = shares(point(object));
    object.shield_factor = factor(found.get(.shields));
    object.gun_factor = factor(found.get(.guns));
    object.speed_factor = factor(found.get(.engines));
}

/// Where FULL POWER TO GUNNERY, ENGINES and SHIELDS and EQUALIZE POWER put the setting
/// (`frame_controls`): near each system's anchor, and near the middle.
pub const Preset = enum { guns, engines, shields, equal };

pub const presets = std.EnumArray(Preset, [2]f32).init(.{
    .guns = .{ 54.17, -30.32 },
    .engines = .{ -55.79, -27.94 },
    .shields = .{ 0.699, 61.98 },
    .equal = .{ 1, 1 },
});

/// Puts the setting at a preset and distributes the power, as the power keys do.
pub fn choose(object: *gameobj.GameObject, preset: Preset) void {
    const at = presets.get(preset);
    object.power_setting.x = at[0];
    object.power_setting.y = at[1];
    distribute(object);
}

/// `0x00413180`: while POWERBALL WINDOW is held, the stick moves the setting against itself by
/// `frame_duration` times `x` and `y`, which run from -1 to 1. A setting that leaves the disc is
/// brought back to its edge, and the power is distributed again.
pub fn move(object: *gameobj.GameObject, x: f32, y: f32, frame_duration: i32) void {
    const ticks: f32 = @floatFromInt(frame_duration);
    object.power_setting.x -= ticks * x;
    object.power_setting.z = 0;
    object.power_setting.y -= ticks * y;
    const setting = object.power_setting.vector();
    if (math.lengthSquared(setting) > radius * radius) {
        object.power_setting = .of(math.normalize(setting) * @as(math.Vector, @splat(radius)));
    }
    distribute(object);
}

/// `0x00412D40`: while SHIELD BALANCING is held, pulling the stick back past half-way shifts a
/// quarter of the shield power a step from the fore shield to the aft one, and pushing it forward
/// past half-way shifts it back. The step comes out of the fore shield's reserve first, then out of
/// the shield itself. The shield it goes to holds at most five times the shield power, and what
/// goes beyond that is added to its reserve, which holds as much again.
pub fn balanceShields(object: *gameobj.GameObject, reserves: *gameobj.ShieldReserves, combat: *const create.ShipCombat, y: f32) void {
    const step: f32 = @floatFromInt(@divTrunc(combat.shield_power, steps_per_power));
    const most: f32 = @floatFromInt(combat.shield_power * shield_most);
    const fore = &object.shields.fore;
    const aft = &object.shields.aft;
    if (y >= 0) {
        if (y > pushed_past and fore.* > 0) shift(fore, &reserves.fore, aft, &reserves.aft, step, most);
    } else if (y < pulled_past and aft.* > 0) {
        shift(aft, &reserves.aft, fore, &reserves.fore, step, most);
    }
}

/// A step of the shield balance is the shield power over this, a quarter (`shield_balance`,
/// `0x00412D40`).
const steps_per_power = 4;

/// A shield holds at most this many times the shield power, and its reserve as much again
/// (`shield_balance`, `0x00412D40`).
const shield_most = 5;

/// How far past half-way the stick must be pushed forward (`0x004DC408`) or pulled back
/// (`0x004DC41C`) to shift the shields.
const pushed_past: f32 = 0.5;
const pulled_past: f32 = -0.5;

/// Moves `step` of shield from `from`, taking its reserve first, to `to`, keeping `to` at `most`
/// and its reserve at `most` too.
fn shift(from: *f32, from_reserve: *f32, to: *f32, to_reserve: *f32, step: f32, most: f32) void {
    from_reserve.* -= step;
    if (from_reserve.* < 0) {
        // The reserve fell short: the rest comes out of the shield, as far as it goes.
        from.* -= -from_reserve.*;
        if (from.* <= 0) {
            const short = from.*;
            from.* = 0;
            to.* = -from_reserve.* + short + to.*;
        } else {
            to.* = -from_reserve.* + to.*;
        }
        from_reserve.* = 0;
    } else {
        to.* = step + to.*;
    }
    if (to.* > most) {
        to_reserve.* = (to.* - most) + to_reserve.*;
        to.* = most;
        if (to_reserve.* > most) to_reserve.* = most;
    }
}

fn testingObject() gameobj.GameObject {
    var object = std.mem.zeroes(gameobj.GameObject);
    object.power_setting = .{ .x = 1, .y = 1, .z = 1 };
    return object;
}

test anchors {
    // A third of a turn apart, each a unit from the middle.
    for (std.enums.values(System)) |system| {
        const at = anchors.get(system);
        try std.testing.expectApproxEqAbs(1, at[0] * at[0] + at[1] * at[1], 1e-6);
    }
    const guns = anchors.get(.guns);
    try std.testing.expectApproxEqAbs(-0.5, guns[0] * anchors.get(.engines)[0] + guns[1] * anchors.get(.engines)[1], 1e-6);
}

test reach {
    // From the middle, every system has half the disc's width.
    try std.testing.expectEqual(64, reach(.{ 0, 0 }, anchors.get(.shields)));
    // At an anchor, the whole of it; opposite, none.
    try std.testing.expectApproxEqAbs(128, reach(.{ 0, 64 }, anchors.get(.shields)), 1e-4);
    try std.testing.expectEqual(0, reach(.{ 0, -64 }, anchors.get(.shields)));
    // Outside the disc there is nothing to reach.
    try std.testing.expectEqual(0, reach(.{ 100, 0 }, anchors.get(.shields)));
}

test distribute {
    // EQUALIZE POWER's point is a little off the middle, toward the shields.
    var object = testingObject();
    choose(&object, .equal);
    try std.testing.expect(object.shield_factor > 1 and object.speed_factor < 1);
    try std.testing.expectApproxEqAbs(1, object.gun_factor, 0.01);
    // FULL POWER TO ENGINES gives the engines nearly all of it.
    choose(&object, .engines);
    try std.testing.expect(object.speed_factor > 1.45);
    try std.testing.expect(object.gun_factor < 0.55 and object.shield_factor < 0.55);
    // The factors run from 0.5 to 1.5.
    try std.testing.expectEqual(0.5, factor(0));
    try std.testing.expectEqual(1.5, factor(1));
    try std.testing.expectApproxEqAbs(1, factor(1.0 / 3.0), 1e-6);
}

test move {
    var object = testingObject();
    // The stick moves the point against itself, by the frame's ticks.
    move(&object, 1, 0, 10);
    try std.testing.expectEqual(-9, object.power_setting.x);
    try std.testing.expectEqual(0, object.power_setting.z);
    // It stays in the disc, at its edge.
    move(&object, 1, 0, 100);
    const setting = object.power_setting.vector();
    try std.testing.expectApproxEqAbs(radius, math.length(setting), 1e-4);
    try std.testing.expect(object.power_setting.x < 0);
    // Toward the engines' side, the ship flies faster.
    try std.testing.expect(object.speed_factor > 1);
}

test balanceShields {
    var object = testingObject();
    var reserves: gameobj.ShieldReserves = .{};
    const combat = std.mem.zeroInit(create.ShipCombat, .{ .shield_power = 8 });
    object.shields = .{ .left = 47, .right = 47, .fore = 47, .aft = 47 };
    // Only past half-way, and a quarter of the power a step: the aft shield holds five times the
    // power, and its reserve takes the rest.
    balanceShields(&object, &reserves, &combat, 0.5);
    try std.testing.expectEqual(47, object.shields.fore);
    balanceShields(&object, &reserves, &combat, 1);
    try std.testing.expectEqual(gameobj.Quadrants{ .left = 47, .right = 47, .fore = 45, .aft = 40 }, object.shields);
    try std.testing.expectEqual(9, reserves.aft);
    try std.testing.expectEqual(0, reserves.fore);
    // Shifting back takes the aft reserve first.
    balanceShields(&object, &reserves, &combat, -1);
    try std.testing.expectEqual(7, reserves.aft);
    try std.testing.expectEqual(40, object.shields.aft);
    try std.testing.expectEqual(40, object.shields.fore);
    try std.testing.expectEqual(7, reserves.fore);
}
