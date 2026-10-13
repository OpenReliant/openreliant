//! The planets as scripts see them in `openreliant.records.planets`
//! ([#1092](https://github.com/OpenReliant/openreliant/issues/1092)): proxies for the planets' table
//! (`game.create.planets.Planet`), numbered from 1. Load scripts can change how each planet turns
//! and leans and its atmosphere, and add planets after the original's, such as Earth, which the
//! game then sets up as planets.

const std = @import("std");

const openreliant = @import("openreliant");
const game = openreliant.engine.game;
const planets = game.create.planets;
const gameobj = game.gameobj;
const luau = @import("../luau.zig");
const State = luau.State;
const values = @import("../values.zig");
const runtime = @import("../runtime.zig");
const records = @import("../records.zig");
const api = @import("../api.zig");
const Parameters = @import("../shaders.zig").Parameters;
const Records = records.Records;
const table = @import("table.zig");

/// The name scripts know a planet by.
pub const script_name = "Planet";

/// How the reference and the definitions introduce the planets.
pub const each = "Each of the planets";
pub const entries_about = "The object types that the game sets up as planets when a mission makes them: lit by the sun alone, always drawn, and colliding with nothing. Each turns about its axis and leans as its entry says, and has its atmosphere. The original's are Neptune to Venus and their far models, in the order of their types. Load scripts can change their fields and add planets after the last one, such as Earth.";

/// What the proxies need of the planets (`table.Table`).
pub const list_name = "planets";
pub const described = "the planets";
pub const item_noun = "a planet";
pub const list_tag = @backingInt(runtime.Tag.planets);
pub const item_tag = @backingInt(runtime.Tag.planet);
pub const most = planets.most;

/// How many planets the records hold.
pub fn count(held: *const Records) usize {
    return held.planets.len;
}

/// Adds a planet after the last one. Until its type is set, it has the marker's type, which is
/// never made.
pub fn append(state: *State, held: *Records) void {
    held.planets = table.appended(planets.Planet, state, held, held.planets, .{ .type = .of(.marker) }, list_name);
}

/// The proxies of the planets (`table.Table`).
const proxies = table.Table(@This());
pub const register = proxies.register;
pub const push = proxies.push;

/// A planet's fields, as scripts name them.
pub const Field = enum {
    type,
    spin,
    tilt,
    tilt_toward,
    atmosphere_color,
    atmosphere_inner,
    atmosphere_outer,
    atmosphere_surface,
    atmosphere_parameters,
};

/// The type of `field`'s value as scripts read it, which the definitions and the reference show.
pub fn TypeOf(comptime field: Field) type {
    return switch (field) {
        .type => gameobj.Type,
        .spin, .tilt, .tilt_toward, .atmosphere_inner, .atmosphere_outer => f32,
        .atmosphere_color => ?@Vector(3, f32),
        .atmosphere_surface => ?[]const u8,
        .atmosphere_parameters => Parameters,
    };
}

/// What the reference says of `field`.
pub fn about(field: Field) []const u8 {
    return switch (field) {
        .type => "Its object type, such as `neptune_hi` or `earth`: OpenReliant's name or the type's number, or the qualified name of a type a mod adds. A type a mod adds uses its base type's entry unless the table has an entry for it. If a type has several entries, the first one counts. A planet added without a type has the marker's type, which is never made, until its type is set.",
        .spin => "How fast it turns about its north pole, in radians a second. Positive turns it eastward, as most planets turn, which is counter-clockwise seen from above its north pole. Negative turns it westward. Its north pole is its model's -Y, which is up on the screen when the planet isn't turned. The original turns the planets that have an atmosphere westward at -0.07, one turn every 90 seconds, and doesn't turn the others.",
        .tilt => "How far its north pole leans away from north, in radians. North is the up direction of the planet as the mission places it, which is the world's up if the mission doesn't turn the planet.",
        .tilt_toward => "Which way its north pole leans, as an angle in radians around north: 0 leans it toward +Z, and `math.pi / 2` toward +X, both of the planet as the mission places it.",
        .atmosphere_color => "The colour of its atmosphere, or nil for none. The atmosphere is a band that faces the camera and fades from this colour at its inner edge to nothing at its outer edge. It is added over the sky behind the planet, and is brighter toward the sun. In the original, Neptune, Uranus, Jupiter and Venus have one.",
        .atmosphere_inner => "Where its atmosphere's band starts, as a share of the planet's radius as the camera sees it: 0.85 in the original. With a surface function, its ring starts here, in the radii of the planet's sphere.",
        .atmosphere_outer => "Where its atmosphere's band ends, as a share of the planet's radius as the camera sees it: 0.95 for Neptune and Uranus, and 1.005 for Jupiter and Venus, in the original. The planet hides the band within its edge. With a surface function, its ring ends here, in the radii of the planet's sphere.",
        .atmosphere_surface => "The surface function that draws its atmosphere in place of the band, by the calling mod's own name or the qualified one, or nil. It draws on a ring that faces the camera through the middle of the planet's sphere, from `atmosphere_inner` to `atmosphere_outer` times the sphere's radius as the camera sees it, and its light is added over what lies behind it. The planet hides the ring within its edge. The function works in the planet's own frame, with the sphere's middle as the origin and its radius as the unit, so it can trace the line of sight through each pixel. Where no mod registers a function of that name, the planet keeps its band. The scripting guide shows one.",
        .atmosphere_parameters => "The numbers its atmosphere's surface function reads, up to four; those left out are 0.",
    };
}

/// The planet `item`.
fn planetOf(item: table.Item) *planets.Planet {
    return &item.records.planets[item.place];
}

/// Pushes the value of `field` of the planet `item`. The colour is kept as an array, and scripts
/// see it as a vector.
pub fn getField(state: *State, item: table.Item, field: Field) void {
    const planet = planetOf(item);
    switch (field) {
        .atmosphere_color => values.push(state, TypeOf(.atmosphere_color), if (planet.atmosphere_colour) |colour| colour else null),
        .atmosphere_parameters => values.push(state, Parameters, .{ .items = planet.atmosphere_parameters, .len = planet.atmosphere_parameters.len }),
        inline else => |name| values.push(state, TypeOf(name), @field(planet, @tagName(name))),
    }
}

/// Sets `field` of the planet `item` from the value at `given`.
pub fn setField(state: *State, item: table.Item, field: Field, given: i32) void {
    const planet = planetOf(item);
    switch (field) {
        .atmosphere_color => {
            const colour = values.read(state, TypeOf(.atmosphere_color), given, script_name ++ ".atmosphere_color");
            planet.atmosphere_colour = if (colour) |set| set else null;
        },
        .atmosphere_surface => {
            const label = script_name ++ ".atmosphere_surface";
            const name = values.read(state, TypeOf(.atmosphere_surface), given, label) orelse {
                planet.atmosphere_surface = null;
                return;
            };
            // A mod's own name is qualified with the mod's, which needs a mod's script to ask.
            var buffer: [runtime.max_name]u8 = undefined;
            const qualified = if (std.mem.findScalar(u8, name, ':') != null) name else api.Call.of(state, label).named(name, &buffer) orelse state.raise("{s}: '{s}' can't be a function's name", .{ label, name });
            planet.atmosphere_surface = item.records.arena.dupe(u8, qualified) catch state.raise("records." ++ list_name ++ ": out of memory", .{});
        },
        .atmosphere_parameters => planet.atmosphere_parameters = values.read(state, Parameters, given, script_name ++ ".atmosphere_parameters").padded(0),
        inline else => |name| @field(planet, @tagName(name)) = values.read(state, TypeOf(name), given, script_name ++ "." ++ @tagName(name)),
    }
}

test "the planets" {
    const bind = @import("../bind.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // The original's planets, and no other records.
    var held: Records = try .init(arena.allocator(), .{ .ships = &.{}, .ship_types = &.{}, .guns = &.{}, .missiles = &.{}, .pilots = &.{}, .faces = &.{}, .text = &.{}, .itac_text = &.{} });
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    records.register(state);
    records.push(state, &held, true);
    state.setGlobal("records");
    state.sandbox();
    const thread = state.newSandboxedThread();

    try bind.testing.runSource(thread,
        \\local all = records.planets
        \\assert(#all == 22 and tostring(all[1]) == "Planet")
        \\assert(all[1].type == "neptune_hi" and all[1].spin < 0 and all[1].atmosphere_color ~= nil)
        \\assert(all[4].type == "saturn_hi" and all[4].spin == 0 and all[4].atmosphere_color == nil)
        \\-- Saturn turns eastward, leaning toward its right, and Earth is a planet.
        \\all[4].spin = 0.6
        \\all[4].tilt = 0.47
        \\all[4].tilt_toward = math.pi / 2
        \\all[#all + 1] = { type = "earth", spin = 0.3, atmosphere_color = vector.create(0.3, 0.5, 1), atmosphere_outer = 1.02 }
        \\assert(#all == 23 and all[23].type == "earth" and math.abs(all[23].atmosphere_inner - 0.85) < 1e-6)
        \\all[1].atmosphere_color = nil
        \\-- A mod's surface function draws Earth's atmosphere, by its qualified name, reading two numbers.
        \\assert(all[23].atmosphere_surface == nil)
        \\all[23].atmosphere_surface = "air:limb"
        \\all[23].atmosphere_parameters = { 0.5, 2 }
        \\assert(all[23].atmosphere_surface == "air:limb" and all[23].atmosphere_parameters[2] == 2 and all[23].atmosphere_parameters[4] == 0)
    );
    try std.testing.expectEqual(0.6, held.planets[3].spin);
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, held.planets[3].tilt_toward, 1e-6);
    const earth = held.planets[22];
    try std.testing.expectEqual(gameobj.Type.of(.earth), earth.type);
    try std.testing.expectEqual([3]f32{ 0.3, 0.5, 1 }, earth.atmosphere_colour.?);
    try std.testing.expectApproxEqAbs(1.02, earth.atmosphere_outer, 1e-6);
    try std.testing.expectEqual(null, held.planets[0].atmosphere_colour);
    try std.testing.expectEqualStrings("air:limb", earth.atmosphere_surface.?);
    try std.testing.expectEqual([4]f32{ 0.5, 2, 0, 0 }, earth.atmosphere_parameters);
    // A name of its own is the calling mod's, which needs a mod's script to ask.
    try bind.testing.expectSourceError(thread, "records.planets[23].atmosphere_surface = 'limb'", "Planet.atmosphere_surface can only be used by mod scripts");
    try bind.testing.expectSourceError(thread, "records.planets[30] = {}", "records.planets[30] does not exist: the planets are 1 to 23; assign to records.planets[24] to add one, up to 64 in all");
    try bind.testing.expectSourceError(thread, "records.planets[1].moons = 3", "Planet has no field 'moons'");
}
