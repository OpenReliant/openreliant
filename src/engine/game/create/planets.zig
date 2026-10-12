//! The planets (`Create.cpp`): the object types that `create_object` sets up as planets
//! (`create.planetMade`), how fast each one turns about its axis, how its axis leans, and the
//! atmosphere of each one that has one (`atmosphere.Atmospheres`). The original's are Neptune to
//! Venus and their far models (`original`), and only the four with an atmosphere turn. Scripts can
//! change the table and add planets to it, such as Earth, through `records.planets`
//! ([#1092](https://github.com/OpenReliant/openreliant/issues/1092)).
//!
//! **Improvement:** the original keeps the planets' types in `create_object`'s code, and their
//! atmospheres and their turn in the atmospheres' table and code, where nothing can change them.

const std = @import("std");

const math = @import("../../surrender/math.zig");
const atmosphere = @import("atmosphere.zig");
const gameobj = @import("../gameobj.zig");
const ticks_per_second = @import("../main.zig").ticks_per_second;

/// A planet.
pub const Planet = struct {
    type: gameobj.Type,
    /// How fast it turns about its north pole, in radians a second. Its north pole is its model's
    /// -Y, which is up on the screen when it isn't turned. Positive turns it eastward, as most
    /// planets turn, which is counter-clockwise seen from above its north pole. Negative turns it
    /// westward.
    spin: f32 = 0,
    /// How far its north pole leans away from north, in radians. North is the up direction (-Y)
    /// of the planet as the mission places it, which is the world's up if the mission doesn't turn
    /// the planet.
    tilt: f32 = 0,
    /// Which way its north pole leans, as an angle in radians around north: 0 leans it toward +Z,
    /// and a quarter turn toward +X, both of the planet as the mission places it.
    tilt_toward: f32 = 0,
    /// The colour of its atmosphere at the inner edge, or null for no atmosphere, and where the
    /// atmosphere's edges are, as shares of its radius (`atmosphere.Look`).
    atmosphere_colour: ?[3]f32 = null,
    atmosphere_inner: f32 = atmosphere.inner_edge,
    atmosphere_outer: f32 = 1,
    /// The surface function that draws its atmosphere, by its qualified name, such as
    /// `realistic-planets:titan_haze`, in place of the band the colour gives
    /// (`atmosphere.Shell`); null for none. The mods register their functions after they set the
    /// planets, so the name is looked up as a mission makes the planet.
    atmosphere_surface: ?[]const u8 = null,
    /// The numbers that function reads.
    atmosphere_parameters: [4]f32 = @splat(0),

    /// The planet with the atmosphere `given`, if there is one.
    fn withLook(planet: Planet, given: ?atmosphere.Look) Planet {
        var with = planet;
        const each = given orelse return with;
        with.atmosphere_colour = each.colour;
        with.atmosphere_inner = each.inner_edge;
        with.atmosphere_outer = each.outer_edge;
        return with;
    }

    /// Its atmosphere, if it has one.
    pub fn look(planet: Planet) ?atmosphere.Look {
        const colour = planet.atmosphere_colour orelse return null;
        return .{ .colour = colour, .inner_edge = planet.atmosphere_inner, .outer_edge = planet.atmosphere_outer };
    }

    /// The rotation, in the planet's own frame, that leans its north pole as `tilt` and
    /// `tilt_toward` say. It turns about the axis at right angles to both north and the direction
    /// of the lean.
    pub fn lean(planet: Planet) math.Matrix {
        if (planet.tilt == 0) return math.identity;
        const toward = math.rotation(.y, planet.tilt_toward);
        const back = math.rotation(.y, -planet.tilt_toward);
        return math.product(toward, math.product(math.rotation(.x, -planet.tilt), back));
    }

    /// How far it turns about its own Y each tick, as an angle for `math.turned`. Y points down, so
    /// a positive angle turns it westward.
    pub fn turnPerTick(planet: Planet) f32 {
        return -planet.spin / ticks_per_second;
    }
};

/// How far each of the original's planets with an atmosphere turns about its own Y each tick
/// (`0x00467B75`), westward: 0.07 radians a second, one turn every 90 seconds.
pub const original_turn: f32 = 0.0007;

/// The types `create_object` sets up as planets (`create.planetMade`, `0x00467BAB`): Neptune to
/// Venus, and their models of less detail.
const original_types = [_][2]u32{ .{ 0x5F, 0x69 }, .{ 0xC9, 0xD3 } };

/// The original's planets. The four with an atmosphere (`atmosphere.Look.of`) turn westward at
/// `original_turn`, and none of them leans.
pub const original = planets: {
    var count = 0;
    for (original_types) |range| count += range[1] - range[0] + 1;
    var all: [count]Planet = undefined;
    var at = 0;
    for (original_types) |range| {
        for (range[0]..range[1] + 1) |number| {
            const planet_type: gameobj.Type = @fromBackingInt(number);
            const given = atmosphere.Look.of(planet_type);
            const plain: Planet = .{ .type = planet_type, .spin = if (given == null) 0 else -original_turn * ticks_per_second };
            all[at] = plain.withLook(given);
            at += 1;
        }
    }
    break :planets all;
};

/// The most planets the table can hold, including the ones scripts add.
pub const most = 64;

var installed: []const Planet = &original;
var installed_light: ?[3]f32 = null;

/// Installs `all`, the planets as the records have them, up to `most`. They must stay in memory
/// until the next install.
pub fn install(all: []const Planet) void {
    installed = all[0..@min(all.len, most)];
}

/// Installs the colour of the planets' own light (`backdrop.LightRole.planets_40`), as the records
/// have it, or null for the key lights' colour, as the original lights the planets.
pub fn installLight(colour: ?[3]f32) void {
    installed_light = colour;
}

/// The installed colour of the planets' light, or null for the key lights' colour.
pub fn light() ?[3]f32 {
    return installed_light;
}

/// Puts the original's planets back, lit by the key lights' colour.
pub fn installOriginal() void {
    installed = &original;
    installed_light = null;
}

/// The installed entry for `planet_type`: the first entry with that type, or else, for a type a mod
/// adds, the first entry with its base type. Null if it isn't a planet.
pub fn of(planet_type: gameobj.Type) ?*const Planet {
    if (first(planet_type)) |planet| return planet;
    const base: gameobj.Type = .of(planet_type.base());
    return if (base == planet_type) null else first(base);
}

/// The first installed entry with the type `planet_type`, if any.
fn first(planet_type: gameobj.Type) ?*const Planet {
    for (installed) |*planet| {
        if (planet.type == planet_type) return planet;
    }
    return null;
}

test original {
    // Neptune to Venus and their far models: 22 types, and Earth isn't one of them.
    try std.testing.expectEqual(22, original.len);
    try std.testing.expect(of(.of(.neptune_hi)) != null);
    try std.testing.expect(of(.of(.venus_lo)) != null);
    try std.testing.expectEqual(null, of(.of(.earth)));
    try std.testing.expectEqual(null, of(.of(.predator)));
    // The four with an atmosphere turn westward at 0.07 radians a second, the others not at all.
    try std.testing.expectApproxEqAbs(-0.07, of(.of(.jupiter_lo)).?.spin, 1e-6);
    try std.testing.expectApproxEqAbs(original_turn, of(.of(.jupiter_lo)).?.turnPerTick(), 1e-9);
    try std.testing.expectEqual(0, of(.of(.saturn_hi)).?.spin);
    try std.testing.expectEqual(atmosphere.Look.of(.of(.uranus_hi)), of(.of(.uranus_hi)).?.look());
    try std.testing.expectEqual(null, of(.of(.titan_hi)).?.look());
}

test install {
    defer installOriginal();
    // A table with Earth added: Earth is a planet, and the first entry of a type wins.
    var table = original ++ [_]Planet{ .{ .type = .of(.earth), .spin = 0.3 }, .{ .type = .of(.earth), .spin = 0.9 } };
    install(&table);
    try std.testing.expectEqual(0.3, of(.of(.earth)).?.spin);
    // Past `most`, the rest are left out.
    var many: [most + 1]Planet = @splat(.{ .type = .of(.predator) });
    many[most] = .{ .type = .of(.earth) };
    install(&many);
    try std.testing.expectEqual(null, of(.of(.earth)));
    installOriginal();
    try std.testing.expectEqual(null, of(.of(.earth)));
}

test "a planet leans its north pole the way it says" {
    const north: math.Vector = .{ 0, -1, 0 };
    // Upright, it doesn't turn at all.
    try std.testing.expectEqual(math.identity, (Planet{ .type = .of(.earth) }).lean());
    // Leaning a quarter turn toward +X, its north pole lies along +X.
    const sideways: Planet = .{ .type = .of(.uranus_hi), .tilt = std.math.pi / 2.0, .tilt_toward = std.math.pi / 2.0 };
    const pole = math.transform(sideways.lean(), north);
    try std.testing.expectApproxEqAbs(1, pole[0], 1e-6);
    try std.testing.expectApproxEqAbs(0, pole[1], 1e-6);
    try std.testing.expectApproxEqAbs(0, pole[2], 1e-6);
    // Earth's 23.44 degrees toward +Z: the pole leans that far toward +Z, and the point of its
    // equator at right angles to the lean stays where it is.
    const tilt = std.math.degreesToRadians(23.44);
    const earth: Planet = .{ .type = .of(.earth), .tilt = tilt };
    const leaned = math.transform(earth.lean(), north);
    try std.testing.expectApproxEqAbs(-@cos(tilt), leaned[1], 1e-6);
    try std.testing.expectApproxEqAbs(@sin(tilt), leaned[2], 1e-6);
    const side = math.transform(earth.lean(), .{ 1, 0, 0 });
    try std.testing.expectApproxEqAbs(1, side[0], 1e-6);
}
