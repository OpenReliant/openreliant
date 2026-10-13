//! Mission source's own words and the tables of fields its declarations take, declared once
//! ([Mission source](../../../../docs/formats/mission-source.md)): what each word takes and gives,
//! and each field's type and description. The compiler checks the fields a table gives against
//! these tables (`compile.zig`), and the definitions file for luau-lsp declares the words and the
//! tables from here (`definitions.zig`). Types are written as Luau writes them, under the names the
//! definitions give them.

const std = @import("std");
const assert = std.debug.assert;

const names = @import("names.zig");
const Word = names.Word;

/// A field of a table that a declaration takes.
pub const Field = struct {
    name: []const u8,
    /// Its type, as Luau writes it. A field that may be left out has an optional type, such as
    /// `FlightGroup?`.
    type: []const u8,
    /// What it is.
    about: []const u8,
};

/// A table of fields, which the definitions declare as a type of its own.
pub const Table = struct {
    /// The type's name in the definitions.
    name: []const u8,
    fields: []const Field,
    /// Whether it also takes the values of its condition's events that a trigger checks, by the
    /// names the trigger's function gives them (`script.eventNames`).
    events: bool = false,

    /// The names of its fields, which a table of the source can give.
    pub inline fn names(comptime table: Table) []const []const u8 {
        comptime {
            var list: [table.fields.len][]const u8 = undefined;
            for (&list, table.fields) |*name, field| name.* = field.name;
            const final = list;
            return &final;
        }
    }
};

/// `mission(...)`'s table.
pub const mission_fields: Table = .{ .name = "MissionFields", .fields = &.{
    .{ .name = "name", .type = "string?", .about = "OpenReliant's name for the mission, which the game doesn't read." },
} };

/// A flight group's table.
pub const flight_group_fields: Table = .{ .name = "FlightGroupFields", .fields = &.{
    .{ .name = "wing", .type = "Wing?", .about = "The wing the group's ships are listed in: \"player\", \"second\", \"third\" or \"none\", the default." },
    .{ .name = "formation", .type = "Formation?", .about = "The formation the group flies in." },
} };

/// The fields of a ship and of a marker, a ship's but its `type`.
const marker_list = [_]Field{
    .{ .name = "group", .type = "FlightGroup?", .about = "Its flight group." },
    .{ .name = "pilot", .type = "Pilot?", .about = "Its pilot, by its record of pilotstats.bin." },
    .{ .name = "position", .type = "Vector?", .about = "Where it is, `{ x, y, z }`, in the game's coordinates, Y down; `{ 0, 0, 0 }` by default." },
    .{ .name = "yaw", .type = "number?", .about = "Its yaw, in whole degrees; -1 where the mission leaves the angle unset. 0 by default." },
    .{ .name = "pitch", .type = "number?", .about = "Its pitch, in whole degrees; -1 where the mission leaves the angle unset. 0 by default." },
    .{ .name = "roll", .type = "number?", .about = "Its roll, in whole degrees; -1 where the mission leaves the angle unset. 0 by default." },
    .{ .name = "launch", .type = "Launch?", .about = "Where it launches from: `{ from = \"reliant\", gate = 2 }`. By default it doesn't launch." },
    .{ .name = "formation_point", .type = "FormationPoint?", .about = "Its place in a formation: `sabres[2]` is the second point of the formation `sabres`." },
    .{ .name = "tier", .type = "number?", .about = "The loadout tier its missile racks are fitted by; 255, the default, asks for the campaign's." },
};

/// A ship's table.
pub const ship_fields: Table = .{ .name = "ShipFields", .fields = &([_]Field{
    .{ .name = "type", .type = "ShipType", .about = "The ship's type." },
} ++ marker_list) };

/// The table of a nav point, a waypoint and a curve point.
pub const marker_fields: Table = .{ .name = "MarkerFields", .fields = &marker_list };

/// A point's table: a marker's, and the place on a curve it can mark.
pub const point_fields: Table = .{ .name = "PointFields", .fields = &(marker_list ++ [_]Field{
    .{ .name = "marker", .type = "Marker?", .about = "For a point that marks a place on a curve: `{ curve = camera_curve, at = 0.5 }`." },
}) };

/// A ship's `launch`.
pub const launch_fields: Table = .{ .name = "Launch", .fields = &.{
    .{ .name = "from", .type = "ShipType", .about = "The type of ship it launches from, the first of that type in the mission." },
    .{ .name = "gate", .type = "number", .about = "The gate it launches through." },
} };

/// A point's `marker`.
pub const marker_place_fields: Table = .{ .name = "Marker", .fields = &.{
    .{ .name = "curve", .type = "Curve", .about = "The curve it marks a place on." },
    .{ .name = "at", .type = "number?", .about = "The share of the way along the curve." },
} };

/// A curve's table.
pub const curve_fields: Table = .{ .name = "CurveFields", .fields = &.{
    .{ .name = "start", .type = "Ship?", .about = "The ship the curve starts at; none by default." },
    .{ .name = "finish", .type = "Ship?", .about = "The ship the curve ends at; none by default." },
    .{ .name = "from", .type = "Vector?", .about = "Where the curve starts." },
    .{ .name = "to", .type = "Vector?", .about = "Where the curve ends." },
    .{ .name = "leaving_handle", .type = "Ship?", .about = "The ship the curve's leaving tangent is drawn to." },
    .{ .name = "arriving_handle", .type = "Ship?", .about = "The ship the curve's arriving tangent is drawn to." },
    .{ .name = "leaving", .type = "Vector?", .about = "The curve's leaving tangent." },
    .{ .name = "arriving", .type = "Vector?", .about = "The curve's arriving tangent." },
} };

/// A part's table.
pub const part_fields: Table = .{ .name = "PartFields", .fields = &.{
    .{ .name = "start", .type = "boolean?", .about = "`true` runs the part as the mission starts, before any trigger is armed." },
} };

/// A trigger's table, besides the values of its condition's events that it checks
/// ([Triggers](../../../../docs/formats/mission-source.md#triggers)).
pub const trigger_fields: Table = .{ .name = "TriggerFields", .events = true, .fields = &.{
    .{ .name = "repeats", .type = "Repeats?", .about = "\"once\", the default, which disarms the trigger as it fires; \"always\"; or `{ counted = 3 }`, which fires that many times each time the script arms it." },
    .{ .name = "component", .type = "number?", .about = "The subject's component it watches, by its index; by default the subject itself." },
    .{ .name = "deferred", .type = "boolean?", .about = "`true` leaves the trigger's thread to the scheduler rather than running it inside the event." },
} };

/// A counted trigger's `repeats`.
pub const counted_fields: Table = .{ .name = "Counted", .fields = &.{
    .{ .name = "counted", .type = "number", .about = "How many times the trigger fires each time the script arms it." },
    .{ .name = "left", .type = "number?", .about = "How many firings are left as the mission starts; by default as many as it counts." },
} };

/// The tables the definitions declare, in the order they write them.
pub const tables = [_]Table{
    mission_fields,      flight_group_fields, ship_fields, marker_fields,  point_fields,   launch_fields,
    marker_place_fields, curve_fields,        part_fields, trigger_fields, counted_fields,
};

/// A type the definitions declare, besides the tables and the names of the game's values.
pub const Type = struct {
    name: []const u8,
    /// What it is.
    about: []const u8,
    definition: union(enum) {
        /// A distinct type, with what its declaration holds, such as an indexer.
        own: []const u8,
        /// Another name for a type, as Luau writes it.
        alias: []const u8,
    },
};

/// The records a mission declares, and the other types its words take and give.
pub const types = [_]Type{
    .{ .name = "Ship", .about = "A ship, a capital ship, a station or a marker, such as a nav point.", .definition = .{ .own = "" } },
    .{ .name = "FlightGroup", .about = "A flight group.", .definition = .{ .own = "" } },
    .{ .name = "Squad", .about = "A squad.", .definition = .{ .own = "" } },
    .{ .name = "Curve", .about = "A camera or flight curve.", .definition = .{ .own = "" } },
    .{ .name = "FormationPoint", .about = "A point of a formation.", .definition = .{ .own = "" } },
    .{ .name = "Formation", .about = "A formation, whose points a ship names as `sabres[1]` for the first.", .definition = .{ .own = "[number]: FormationPoint" } },
    .{ .name = "Entity", .about = "A ship, a flight group or a squad: what a trigger watches, and what most commands act on.", .definition = .{ .alias = "Ship | FlightGroup | Squad" } },
    .{ .name = "Vector", .about = "A place or a direction: `{ x, y, z }`.", .definition = .{ .alias = "{ number }" } },
    .{ .name = "Code", .about = "The code a trigger runs: a function whose parameters are the values its condition's events carry.", .definition = .{ .alias = "(...any) -> number" } },
    .{ .name = "Part", .about = "A part, which runs as `go_home()`, and which commands such as `CreateTimer` take.", .definition = .{ .alias = "(...any) -> number" } },
    .{ .name = "Repeats", .about = "How a trigger repeats.", .definition = .{ .alias = "\"once\" | \"always\" | Counted | number" } },
};

/// How the definitions declare a word: a function with its parameters and result, or a value of
/// a type.
pub const Declaration = struct {
    /// What it is or does.
    about: []const u8,
    /// Its type parameters, such as `<A...>`.
    generics: []const u8 = "",
    /// Its parameters, as Luau writes them; null for a value, such as `any_ship`.
    parameters: ?[]const u8 = null,
    /// A function's result, or a value's type.
    result: []const u8,
};

/// How the definitions declare `word`.
pub fn declaration(word: Word) Declaration {
    return switch (word) {
        .mission => .{ .about = "Gives the mission's own details.", .parameters = "fields: MissionFields", .result = "()" },
        .global => .{ .about = "Declares a global: its display name and the value it starts with.", .parameters = "name: string, value: number", .result = "number" },
        .flight_group => .{ .about = "Declares a flight group, by its display name.", .parameters = "name: string, fields: FlightGroupFields?", .result = "FlightGroup" },
        .ship => .{ .about = "Places a ship, a capital ship or a station, by its display name.", .parameters = "name: string, fields: ShipFields", .result = "Ship" },
        .nav_point => .{ .about = "Places a nav point, by its display name.", .parameters = "name: string, fields: MarkerFields?", .result = "Ship" },
        .waypoint => .{ .about = "Places a waypoint, by its display name.", .parameters = "name: string, fields: MarkerFields?", .result = "Ship" },
        .point => .{ .about = "Places a point, by its display name, such as one a camera curve runs to.", .parameters = "name: string, fields: PointFields?", .result = "Ship" },
        .curve_point => .{ .about = "Places a curve point, by its display name.", .parameters = "name: string, fields: MarkerFields?", .result = "Ship" },
        .squad => .{ .about = "Declares a squad: its display name and its members in their order, ships, ships' components, flight groups and other squads.", .parameters = "name: string, members: { Entity }", .result = "Squad" },
        .formation => .{ .about = "Declares a formation: its display name and its points, each where it stands from the formation's origin. A ship names a point as `sabres[1]` for the first.", .parameters = "name: string, points: { Vector }", .result = "Formation" },
        .curve => .{ .about = "Declares a curve, which has no display name.", .parameters = "fields: CurveFields", .result = "Curve" },
        .part => .{ .about = "Declares a part: its display name and its code, a function whose parameters are the part's arguments. A part without a function has no block.", .generics = "<A...>", .parameters = "name: string, code: ((A...) -> number)?, fields: PartFields?", .result = "(A...) -> number" },
        .handler => .{ .about = "Declares code that more than one trigger runs.", .generics = "<A...>", .parameters = "code: (A...) -> number", .result = "(A...) -> number" },
        .on => .{ .about = "Declares a trigger: its subject, the ship, flight group or squad whose events it watches, or nil for none; its condition; its fields, which can be left out; and the code its events run, whose parameters are the values the condition's events carry.", .parameters = "subject: Entity?, condition: Condition, fields: (TriggerFields | Code)?, code: Code?", .result = "()" },
        .component => .{ .about = "A ship's component, by its index.", .generics = "<T>", .parameters = "object: T, index: number", .result = "T" },
        .any_ship => .{ .about = "Any of the players' ships, as a value a trigger checks.", .result = "Ship" },
        .command => .{ .about = "Runs a command the catalogue doesn't have, by its number.", .parameters = "number: number, ...: any", .result = "()" },
        .spawn => .{ .about = "Starts a part on a thread of its own, with its arguments after the part.", .generics = "<A...>", .parameters = "part: (A...) -> number, ...: A...", .result = "()" },
        .random => .{ .about = "Rolls a random choice: `local roll = random()`, then an `if` over the arms' thresholds, `if roll < 50 then`, with the default as `else`.", .parameters = "", .result = "number" },
        .result => .{ .about = "The result of the last command.", .parameters = "", .result = "number" },
        .game => .{ .about = "The game's variables, by their names, or by their numbers, as in `game[37]`, for those without.", .result = "GameVariables" },
        .thread_value => .{ .about = "A value of the event that started the thread, by its place, in a part.", .parameters = "place: number", .result = "any" },
        .last_event => .{ .about = "A value an object keeps of its last event of a condition, by its label in the condition catalogue: `last_event(ship, \"shot_at\", \"Hull Damage\")`.", .parameters = "object: Entity, condition: Condition, value: EventValue", .result = "any" },
        .ship_index => .{ .about = "A ship past the mission's records, by its index.", .parameters = "index: number", .result = "Ship" },
        .flight_group_index => .{ .about = "A flight group past the mission's records, by its index.", .parameters = "index: number", .result = "FlightGroup" },
        .squad_index => .{ .about = "A squad past the mission's records, by its index.", .parameters = "index: number", .result = "Squad" },
        .curve_index => .{ .about = "A curve past the mission's records, by its index.", .parameters = "index: number", .result = "Curve" },
        .global_index => .{ .about = "A global past the mission's records, by its index.", .parameters = "index: number", .result = "number" },
        .part_index => .{ .about = "A part past the mission's records, by its index.", .parameters = "index: number", .result = "Part" },
        .object_index => .{ .about = "An object by its number in the built mission. A number past its records gets an entry of no record in the object table.", .parameters = "id: number", .result = "Entity" },
        .formation_index => .{ .about = "A formation past the mission's records, by its index.", .parameters = "index: number", .result = "Formation" },
        .formation_point_index => .{ .about = "A formation point by its index among all the mission's points.", .parameters = "index: number", .result = "FormationPoint" },
        .in_flight_group => .{ .about = "Whether a ship is in a flight group.", .parameters = "object: Entity, group: FlightGroup", .result = "boolean" },
        .not_in_flight_group => .{ .about = "Whether a ship isn't in a flight group.", .parameters = "object: Entity, group: FlightGroup", .result = "boolean" },
        .in_squad => .{ .about = "Whether an object is in a squad.", .parameters = "object: Entity, squad: Squad", .result = "boolean" },
        .not_in_squad => .{ .about = "Whether an object isn't in a squad.", .parameters = "object: Entity, squad: Squad", .result = "boolean" },
        .greater_f => .{ .about = "`a > b`, comparing floating-point numbers.", .parameters = "a: number, b: number", .result = "boolean" },
        .greater_equal_f => .{ .about = "`a >= b`, comparing floating-point numbers.", .parameters = "a: number, b: number", .result = "boolean" },
        .less_f => .{ .about = "`a < b`, comparing floating-point numbers.", .parameters = "a: number, b: number", .result = "boolean" },
        .less_equal_f => .{ .about = "`a <= b`, comparing floating-point numbers.", .parameters = "a: number, b: number", .result = "boolean" },
        .add_f => .{ .about = "`a + b`, in floating point.", .parameters = "a: number, b: number", .result = "number" },
        .sub_f => .{ .about = "`a - b`, in floating point.", .parameters = "a: number, b: number", .result = "number" },
        .mul_f => .{ .about = "`a * b`, in floating point.", .parameters = "a: number, b: number", .result = "number" },
        .div_f => .{ .about = "`a / b`, in floating point.", .parameters = "a: number, b: number", .result = "number" },
        .add_assign_f => .{ .about = "`target += value`, in floating point.", .parameters = "target: number, value: number", .result = "()" },
        .sub_assign_f => .{ .about = "`target -= value`, in floating point.", .parameters = "target: number, value: number", .result = "()" },
        .mul_assign_f => .{ .about = "`target *= value`, in floating point.", .parameters = "target: number, value: number", .result = "()" },
        .div_assign_f => .{ .about = "`target /= value`, in floating point.", .parameters = "target: number, value: number", .result = "()" },
    };
}

// Each table names each field once, which the compiler's check of a table's fields relies on.
comptime {
    for (tables) |table| {
        for (table.fields, 0..) |field, place| {
            for (table.fields[place + 1 ..]) |other| assert(!std.mem.eql(u8, field.name, other.name));
        }
    }
}

test Table {
    // A table's names are its fields', in their order.
    const listed = launch_fields.names();
    try std.testing.expectEqual(2, listed.len);
    try std.testing.expectEqualStrings("from", listed[0]);
    try std.testing.expectEqualStrings("gate", listed[1]);
}
