//! Reads mission source with Luau's own parser
//! ([Mission source](../docs/formats/mission-source.md)): `source_parser/luau.cpp` parses the
//! text and writes the syntax tree into flat arrays, and `parse` copies them into the library's
//! tree (`dte.source.syntax`). `build` compiles the text into a mission file. It is a module of its
//! own because it links Luau's parser, which the library the tools share doesn't, and so it holds
//! the tests that compile source, the tests that the definitions files OpenReliant writes for
//! luau-lsp parse and can be loaded together, and the tests that build and play the missions of the
//! guide to writing missions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const openreliant = @import("openreliant");
const dte = openreliant.dte;
const game = openreliant.engine.game;
const syntax = dte.source.syntax;
const compile = dte.source.compile;
const luau = @import("luau_syntax");

/// Parses `text` as Luau, into a tree in `arena` with the errors Luau's parser found.
pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!syntax.Tree {
    return read(arena, text, false);
}

/// The errors Luau's parser finds in `text`, a definitions file read as luau-lsp reads one, with
/// declarations such as `declare function`.
pub fn definitionErrors(arena: Allocator, text: []const u8) Allocator.Error![]const syntax.Error {
    return (try read(arena, text, true)).errors;
}

/// Parses `text` as Luau, with the declarations of a definitions file where `declarations` is set.
fn read(arena: Allocator, text: []const u8, declarations: bool) Allocator.Error!syntax.Tree {
    const parsed: ?*luau.OrTree = luau.openreliant_parse_luau(text.ptr, text.len, @intFromBool(declarations));
    const tree = parsed orelse return error.OutOfMemory;
    defer luau.openreliant_luau_tree_free(tree);
    const nodes: [*]const syntax.Node = @ptrCast(tree.nodes);
    const own_text = try arena.dupe(u8, tree.text[0..tree.text_length]);
    const errors = try arena.alloc(syntax.Error, tree.error_count);
    for (errors, tree.errors[0..tree.error_count]) |*made, found| made.* = .{
        .at = .{ .line = found.line, .column = found.column },
        .message = own_text[found.message_start..][0..found.message_length],
    };
    return .{
        .nodes = try arena.dupe(syntax.Node, nodes[0..tree.node_count]),
        .children = try arena.dupe(syntax.Index, tree.children[0..tree.child_count]),
        .text = own_text,
        .errors = errors,
        .root = tree.root,
    };
}

/// Compiles the mission source `text` into a mission file in `arena` (`dte.source.compile`). Where
/// the source has an error, the parser's or the compiler's, `failure` says what and where.
pub fn build(arena: Allocator, text: []const u8, failure: *compile.Failure) compile.Error![]u8 {
    return compile.compile(arena, try parse(arena, text), failure);
}

/// `build`, with the map of the script's statements to the source's lines, for a debugger
/// (`compile.compileMapped`).
pub fn buildMapped(arena: Allocator, text: []const u8, failure: *compile.Failure) compile.Error!compile.Compiled {
    return compile.compileMapped(arena, try parse(arena, text), failure);
}

/// Compiles the mission source file `source` into the mission file `mission`, both in `dir`, as
/// `sltool dte build` and the build's `build-mission` do. Where the source has an error, `failure`
/// says what and where, the error is `Invalid`, and no file is written.
pub fn buildFile(io: std.Io, arena: Allocator, dir: std.Io.Dir, source: []const u8, mission: []const u8, failure: *compile.Failure) !void {
    const text = try dir.readFileAlloc(io, source, arena, .limited(openreliant.engine.files.max_file_size));
    try dir.writeFile(io, .{ .sub_path = mission, .data = try build(arena, text, failure) });
}

// The bridge's nodes have the library's layout, and the header gives every kind of node, operator
// and form of a table's item the library's number.
comptime {
    assert(@sizeOf(syntax.Node) == @sizeOf(luau.OrNode));
    for ([_][]const u8{ "kind", "op", "first", "count", "text_start", "text_length", "number" }) |field| {
        assert(@offsetOf(syntax.Node, field) == @offsetOf(luau.OrNode, field));
    }
    assert(@offsetOf(syntax.Node, "at") + @offsetOf(syntax.Position, "line") == @offsetOf(luau.OrNode, "line"));
    assert(@offsetOf(syntax.Node, "at") + @offsetOf(syntax.Position, "column") == @offsetOf(luau.OrNode, "column"));
    sameNumbers(syntax.Kind, "OR_", &.{ "OR_UNARY_", "OR_BINARY_", "OR_ITEM_" });
    sameNumbers(syntax.UnaryOperator, "OR_UNARY_", &.{});
    sameNumbers(syntax.BinaryOperator, "OR_BINARY_", &.{});
    sameNumbers(syntax.ItemKind, "OR_ITEM_", &.{});
}

/// Checks that each of the header's constants whose name starts with `prefix`, and with none of
/// `others`, is a tag of `Enum` in capitals with the same number, and that every tag has one.
fn sameNumbers(comptime Enum: type, comptime prefix: []const u8, comptime others: []const []const u8) void {
    @setEvalBranchQuota(100_000);
    var count = 0;
    for (std.meta.declarations(luau)) |name| {
        if (!std.mem.startsWith(u8, name, prefix) or startsWithAny(name, others)) continue;
        var lower: [name.len - prefix.len]u8 = undefined;
        _ = std.ascii.lowerString(&lower, name[prefix.len..]);
        const tag = std.meta.stringToEnum(Enum, &lower) orelse @compileError(name ++ " has no tag in " ++ @typeName(Enum));
        if (@backingInt(tag) != @field(luau, name)) @compileError(name ++ " has another number than " ++ @typeName(Enum));
        count += 1;
    }
    if (count != std.enums.values(Enum).len) @compileError("luau.h lacks tags of " ++ @typeName(Enum));
}

fn startsWithAny(name: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| if (std.mem.startsWith(u8, name, prefix)) return true;
    return false;
}

/// Checks that `text` parses without an error into the statements `expected`, one per line as
/// `syntax.Tree.dump` writes them.
fn expectTree(text: []const u8, expected: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try parse(arena, text);
    for (tree.errors) |found| std.debug.print("{f}: {s}\n", .{ found.at, found.message });
    try std.testing.expectEqual(0, tree.errors.len);
    var out: std.Io.Writer.Allocating = .init(arena);
    for (tree.get(tree.root).block, 0..) |statement, index| {
        if (index > 0) try out.writer.writeByte('\n');
        try tree.dump(statement, &out.writer);
    }
    try std.testing.expectEqualStrings(expected, out.written());
}

test "records" {
    try expectTree(
        \\-- A comment, which leaves nothing.
        \\reliant_group = flight_group("(FG)Reliant", { wing = "player" })
        \\
        \\position = { -11608147, (-0.5), 1.5e6 }
        \\point = sabres[2]
    ,
        \\(assign (global_name "reliant_group") (call (global_name "flight_group") (string "(FG)Reliant") (table (item record (string "wing") (string "player")))))
        \\(assign (global_name "position") (table (item list (unary minus (number 11608147))) (item list (unary minus (number 0.5))) (item list (number 1500000))))
        \\(assign (global_name "point") (index (global_name "sabres") (number 2)))
    );
}

test "triggers and parts" {
    try expectTree(
        \\on(convoy, "shot_at", { attacker = any_ship }, function(attacker: MissionShip, hull_damage) end)
        \\go_home = part("(F)GO HOME", function(arg0) return 1 end, { start = true })
    ,
        \\(call_statement (call (global_name "on") (global_name "convoy") (string "shot_at") (table (item record (string "attacker") (global_name "any_ship"))) (function (name "attacker") (name "hull_damage") (block))))
        \\(assign (global_name "go_home") (call (global_name "part") (string "(F)GO HOME") (function (name "arg0") (block (return (number 1)))) (table (item record (string "start") (boolean true)))))
    );
}

test "the script" {
    try expectTree(
        \\if hits >= 50 then hits += 1 elseif lost then go_home() else end
        \\local roll: number = random()
        \\SetAI(attacker, "find_new_target", 1, nil)
        \\spawn(go_home, roll)
        \\over = game.mission_over == 0 and result() ~= game[37] or not done
        \\return 1
    ,
        \\(if (binary greater_equal (global_name "hits") (number 50)) (block (compound_assign add (global_name "hits") (number 1))) (if (global_name "lost") (block (call_statement (call (global_name "go_home")))) (block)))
        \\(local (name "roll") (call (global_name "random")))
        \\(call_statement (call (global_name "SetAI") (global_name "attacker") (string "find_new_target") (number 1) (nil)))
        \\(call_statement (call (global_name "spawn") (global_name "go_home") (local_name "roll")))
        \\(assign (global_name "over") (binary or (binary and (binary equal (field "mission_over" (global_name "game")) (number 0)) (binary not_equal (call (global_name "result")) (index (global_name "game") (number 37)))) (unary not (global_name "done"))))
        \\(return (number 1))
    );
}

test "constructs mission source doesn't use" {
    try expectTree(
        \\while true do end
        \\function f() end
        \\ship:fire()
        \\x = function(...) end
        \\y = `{x} hits`
        \\z = if x then 1 else 2
        \\plain = `plain`
    ,
        \\(unsupported "a loop")
        \\(unsupported "a function declared by name")
        \\(call_statement (unsupported "a method call"))
        \\(assign (global_name "x") (unsupported "a function that takes `...`"))
        \\(assign (global_name "y") (unsupported "a string with values put into it"))
        \\(assign (global_name "z") (unsupported "an if expression"))
        \\(assign (global_name "plain") (string "plain"))
    );
}

test "a local that hides a parameter is told apart from it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const tree = try parse(arena_state.allocator(),
        \\f = function(roll)
        \\    local roll = roll
        \\    return roll
        \\end
    );
    try std.testing.expectEqual(0, tree.errors.len);
    const function = tree.get(tree.get(tree.get(tree.root).block[0]).assign.values[0]).function;
    const parameter = tree.get(function.parameters[0]).name;
    const lines = tree.get(function.body).block;
    const local = tree.get(lines[0]).local;
    const hiding = tree.get(local.targets[0]).name;
    // The local's value is the parameter, and what it returns is the local.
    try std.testing.expect(parameter.number != hiding.number);
    try std.testing.expectEqual(parameter.number, tree.get(local.values[0]).local_name.number);
    try std.testing.expectEqual(hiding.number, tree.get(tree.get(lines[1]).@"return"[0]).local_name.number);
}

test "the parser's errors and their places" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try parse(arena,
        \\x = ship("Player",
        \\y = 2
    );
    try std.testing.expect(tree.errors.len > 0);
    try std.testing.expectEqual(syntax.Position{ .line = 1, .column = 2 }, tree.errors[0].at);
    try std.testing.expect(tree.errors[0].message.len > 0);
    // Nothing at all is an empty chunk.
    const empty = try parse(arena, "");
    try std.testing.expectEqual(0, empty.errors.len);
    try std.testing.expectEqual(0, empty.get(empty.root).block.len);
}

test definitionErrors {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The definitions files, as `make definitions` writes them, parse as luau-lsp reads them, so a
    // Luau update that changes the syntax fails here rather than in modders' editors.
    inline for (.{ "openreliant.d.luau", "mission.d.luau" }) |file| {
        const errors = try definitionErrors(arena, @embedFile(file));
        for (errors) |found| std.debug.print(file ++ ":{f}: {s}\n", .{ found.at, found.message });
        try std.testing.expectEqual(0, errors.len);
    }
    // Declarations parse only in a definitions file, and the syntax Luau has dropped doesn't.
    const declaration = "declare function launch(gate: number): ()\n";
    try std.testing.expectEqual(0, (try definitionErrors(arena, declaration)).len);
    try std.testing.expect((try parse(arena, declaration)).errors.len > 0);
    try std.testing.expect((try definitionErrors(arena, "declare class Ship\nend\n")).len > 0);
}

test "both definitions files can be loaded together" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // luau-lsp loads every definitions file into one scope, where a name declared twice gets the
    // later declaration. So a mod's folder can hold both scripts and missions only while a name
    // that both files declare is the same one-line type in each, as the names of values are.
    const definitions = dte.source.definitions.testing;
    var scripting: std.StringHashMapUnmanaged([]const u8) = .empty;
    var each = definitions.declarations(@embedFile("openreliant.d.luau"));
    while (each.next()) |declaration| try scripting.put(arena, declaration.name, declaration.line);
    var shared: usize = 0;
    each = definitions.declarations(@embedFile("mission.d.luau"));
    while (each.next()) |declaration| {
        const other = scripting.get(declaration.name) orelse continue;
        const line = declaration.line;
        const one_line = std.mem.startsWith(u8, line, "export type ") and !std.mem.endsWith(u8, line, "{") and !std.mem.endsWith(u8, line, "= ");
        if (!one_line or !std.mem.eql(u8, line, other)) {
            std.debug.print("both definitions files declare {s}, but not the same way: rename one of them\n", .{declaration.name});
            return error.TestUnexpectedResult;
        }
        shared += 1;
    }
    // The names of values, such as `ShipType`, are the ones they share.
    try std.testing.expect(shared > 0);
}

test buildFile {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "patrol.mission.luau", .data = "player = ship(\"Player\", { type = \"grendel\" })\n" });
    var failure: compile.Failure = undefined;
    try buildFile(io, arena, tmp.dir, "patrol.mission.luau", "patrol.dte", &failure);
    const mission: dte.Mission = try .parse(try tmp.dir.readFileAlloc(io, "patrol.dte", arena, .unlimited));
    try std.testing.expectEqualStrings("Player", mission.name((try mission.player()).?.name));
    // A source with an error says where, and writes no mission.
    try tmp.dir.writeFile(io, .{ .sub_path = "broken.mission.luau", .data = "player = nobody\n" });
    try std.testing.expectError(error.Invalid, buildFile(io, arena, tmp.dir, "broken.mission.luau", "broken.dte", &failure));
    try std.testing.expectEqual(syntax.Position{ .line = 0, .column = 9 }, failure.at);
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(io, "broken.dte", arena, .unlimited));
}

/// A mission with every kind of record, every form of the script and each way a line that doesn't
/// fit is broken, as `sltool dte decompile` writes it.
const patrol =
    \\mission({ name = "Patrol" })
    \\
    \\-- Globals
    \\
    \\convoy_hits = global("(GV)convoy hits", 0)
    \\lost = global("(GV)lost", 4294967295)
    \\
    \\-- Flight groups
    \\
    \\alpha = flight_group("(FG)Alpha", { wing = "player" })
    \\sabres = flight_group("(FG)Sabres", { formation = vee })
    \\
    \\-- Ships
    \\
    \\player = ship("Player", {
    \\    type = "grendel",
    \\    group = alpha,
    \\    position = { 100, -200, 300.5 },
    \\    yaw = 90,
    \\})
    \\wingman = ship("Wingman", {
    \\    type = "wolverine",
    \\    group = alpha,
    \\    pilot = "bandit_tigers_leader",
    \\    launch = { from = "reliant", gate = 2 },
    \\    tier = 3,
    \\})
    \\sabre_1 = ship("Sabre 1", { type = "sabre", group = sabres, yaw = 180, formation_point = vee[1] })
    \\sabre_2 = ship("Sabre 2", {
    \\    type = "sabre",
    \\    group = sabres,
    \\    yaw = 180,
    \\    roll = -45,
    \\    formation_point = vee[2],
    \\})
    \\home = nav_point("Home", { position = { 0, 0, 50000 } })
    \\halfway = point("Halfway", { marker = { curve = curve_0, at = 0.5 } })
    \\start = curve_point("Start")
    \\end_ship = curve_point("End", { position = { 1000, 0, 0 } })
    \\escort_carrier_of_the_convoy = ship("Escort carrier of the convoy", { type = "reliant" })
    \\
    \\-- Squads
    \\
    \\targets = squad("(AI)targets", { sabre_1, component(sabre_2, 2), sabres })
    \\everyone = squad("(AI)everyone", { targets, player })
    \\convoy_and_escorts = squad("(AI)convoy and escorts", {
    \\    player,
    \\    wingman,
    \\    sabre_1,
    \\    sabre_2,
    \\    escort_carrier_of_the_convoy,
    \\    targets,
    \\})
    \\
    \\-- Formations
    \\
    \\vee = formation("vee", { { 0, 0, 0 }, { -400, 0, 300 } })
    \\
    \\-- Curves
    \\
    \\curve_0 = curve({
    \\    start = start,
    \\    finish = end_ship,
    \\    from = { 0, 0, 0 },
    \\    to = { 1000, 0, 0 },
    \\    leaving_handle = start,
    \\    arriving_handle = end_ship,
    \\    leaving = { 10, 0, 0 },
    \\    arriving = { 0, 0, -10 },
    \\})
    \\
    \\-- Code more than one trigger runs
    \\
    \\sabre_1_shot_at = handler(function(attacker, shield_damage, hull_damage, victim, weapon_fired)
    \\    convoy_hits += 1
    \\    if hull_damage >= 50 then
    \\        SetAI(targets, "find_new_target", 1, nil)
    \\    end
    \\    return 1
    \\end)
    \\
    \\-- Triggers
    \\
    \\on(sabre_1, "shot_at", { repeats = "always", attacker = any_ship }, sabre_1_shot_at)
    \\on(sabre_2, "shot_at", {
    \\    repeats = { counted = 3, left = 1 },
    \\    component = 2,
    \\    deferred = true,
    \\}, sabre_1_shot_at)
    \\on(sabres, "destroyed", function(killer, victim)
    \\    if last_event(targets, "shot_at", "Hull Damage") > 20 and result() ~= 0 then
    \\        go_home(5)
    \\    elseif game.mission_over == 0 then
    \\        spawn(go_home, killer)
    \\    else
    \\    end
    \\    local roll = random()
    \\    if roll < 50 then
    \\        lost = 1
    \\    elseif roll < 100 then
    \\        game.ion_cannons_hold_lock = thread_value(3)
    \\    else
    \\        add_assign_f(lost, 1065353216)
    \\    end
    \\    return 1
    \\end)
    \\on(nil, "destroyed")
    \\on(escort_carrier_of_the_convoy, "shot_at",
    \\    function(attacker, shield_damage, hull_damage, victim, weapon_fired)
    \\        return 1
    \\    end)
    \\
    \\-- Parts
    \\
    \\go_home = part("(F)go home", function(arg0)
    \\    PlayMusic("new_launch.wav", 0)
    \\    CreateTimer(3, go_home, 30, arg0 + 1)
    \\    command(250, "a mod's command")
    \\    if in_flight_group(player, alpha) or greater_f(arg0, 0) then
    \\        arg0 = component(sabre_2, 1)
    \\    end
    \\    return 1
    \\end)
    \\launch = part("(F)launch", function()
    \\    StartLaunch(alpha)
    \\    return 1
    \\end, { start = true })
    \\not_written_yet = part("(F)not written yet")
    \\
;

test "a mission built from its source decompiles to that source" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure: compile.Failure = undefined;
    const built = build(arena, patrol, &failure) catch |err| {
        std.debug.print("{f}\n", .{failure});
        return err;
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    try dte.source.write.write(&out.writer, arena, try .parse(built));
    try std.testing.expectEqualStrings(patrol, out.written());
}

test "the objects that last_event names are numbered first" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var failure: compile.Failure = undefined;
    const mission: dte.Mission = try .parse(try build(arena_state.allocator(),
        \\a = ship("A", { type = "grendel" })
        \\b = ship("B", { type = "grendel" })
        \\g = flight_group("G")
        \\s = squad("S", { a })
        \\on(a, "destroyed", function()
        \\    return last_event(s, "destroyed", "Killer")
        \\end)
    , &failure));
    // The script names the object `last_event` reads by a byte, so it comes first; then the ships,
    // the flight groups and the squads.
    try std.testing.expectEqual(0, (try mission.squads())[0].object_id);
    try std.testing.expectEqual(1, (try mission.ships())[0].object_id);
    try std.testing.expectEqual(2, (try mission.ships())[1].object_id);
    try std.testing.expectEqual(3, (try mission.flightGroups())[0].object_id);
    const objects = try mission.objects();
    try std.testing.expectEqual(.squad, objects[0].kind);
    try std.testing.expectEqual(.flight_group, objects[3].kind);
    // `a`'s entry holds its trigger, and marks it as the original's tools mark ship 0.
    try std.testing.expectEqual(1, objects[1].count);
    try std.testing.expect(objects[1].tool_flags.player);
    try std.testing.expectEqual(dte.Object.no_triggers, objects[2].first);
}

test "the compiler's errors and their places" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]struct { []const u8, []const u8 }{
        .{ "on(nobody, \"destroyed\")", "1:4: `nobody` is not declared" },
        .{ "a = global(\"a\", 0)\na = global(\"b\", 0)", "2:1: `a` is declared already, at 1:5" },
        .{ "ship = global(\"x\", 0)", "1:1: `ship` is a name mission source keeps for itself" },
        .{ "Wait = global(\"x\", 0)", "1:1: `Wait` is a name mission source keeps for itself" },
        .{ "x = 1", "1:5: `x` is declared by a constructor, such as `ship(...)`" },
        .{ "p = ship(\"P\")", "1:5: a ship needs its `type`" },
        .{ "p = ship(\"P\", { type = \"rubber_duck\" })", "1:24: the game has no ship type named \"rubber_duck\"" },
        .{ "p = ship(\"P\", { type = \"grendel\", colour = 1 })", "1:35: `colour` isn't a field here, which takes `type`, `group`, `pilot`, `position`, `yaw`, `pitch`, `roll`, `launch`, `formation_point` and `tier`" },
        .{ "p = ship(\"P\", { type = \"grendel\", yaw = 40000 })", "1:41: a whole number from -32768 to 32767 goes here" },
        .{ "g = global(\"g\", 0)\np = ship(\"P\", { type = \"grendel\", group = g })", "2:43: `g` is a global, not a flight group" },
        .{ "a = ship(\"A\", { type = \"grendel\" })\nb = ship(\"B\", { type = \"grendel\" })\non(a, \"destroyed\")\non(b, \"destroyed\")\non(a, \"destroyed\")", "5:1: an object's triggers follow one another" },
        .{ "on(nil, \"destroyed\", { attacker = any_ship })", "1:24: `attacker` isn't a field here, which takes `repeats`, `component`, `deferred`, `killer` and `victim`" },
        .{ "p = part(\"p\", function()\n    while true do end\nend)", "2:5: a loop, which mission source doesn't use" },
        .{ "p = part(\"p\", function()\n    local roll = random()\n    return 1\nend)", "3:5: a random choice's roll is followed by the `if` over its arms" },
        .{ "on(nil, \"destroyed\", function(killer)\n    killer = 1\nend)", "2:5: `killer` is a value of the event, which can't be assigned" },
        .{ "p = part(\"p\", function()\n    return not result()\nend)", "2:12: the script has no `not`" },
        .{ "p = part(\"p\", function()\n    Wait(\"long\" .. \"er\")\nend)", "2:10: the script has no `..`" },
        .{ "p = part(\"p\", function()\n    SetAI(nil, \"dance\", 1, nil)\nend)", "2:16: the game has no order named \"dance\"" },
        .{ "p = part(\"p\", function()\n    Wait(5)\nend)", "1:15: the code must end with a `return`, such as `return 1`" },
        .{ "on(nil, \"destroyed\", function() end)", "1:22: the code must end with a `return`, such as `return 1`" },
        .{ "p = part(\"p\", function()\n    if result() == 0 then\n        return 1\n    end\nend)", "1:15: the code must end with a `return`, such as `return 1`" },
    }) |case| {
        var failure: compile.Failure = undefined;
        try std.testing.expectError(error.Invalid, build(arena, case[0], &failure));
        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.print("{f}", .{failure});
        try std.testing.expectEqualStrings(case[1], out.written());
    }
    // The parser's errors come first, with their places.
    var failure: compile.Failure = undefined;
    try std.testing.expectError(error.Invalid, build(arena, "x = ship(\"A\",\ny = 2", &failure));
    try std.testing.expectEqual(1, failure.at.line);
}

/// The guide to writing missions, whose missions the tests below build and play, so that its
/// examples keep working.
const guide = @embedFile("missions.md");

/// A complete mission that the guide shows: a `luau` block whose first line names its file, as
/// `-- mission90.mission.luau: ...` does.
const GuideMission = struct {
    file: []const u8,
    source: []const u8,
};

/// The guide's complete missions, in its order.
fn guideMissions(arena: Allocator) Allocator.Error![]const GuideMission {
    var found: std.ArrayList(GuideMission) = .empty;
    var rest: []const u8 = guide;
    while (std.mem.cut(u8, rest, "\n```luau\n")) |opened| {
        const end = std.mem.find(u8, opened[1], "\n```\n") orelse break;
        const source = opened[1][0 .. end + 1];
        rest = opened[1][end + 1 ..];
        const first_line = source[0 .. std.mem.findScalar(u8, source, '\n') orelse source.len];
        const named = std.mem.cutPrefix(u8, first_line, "-- ") orelse continue;
        const file = (std.mem.cut(u8, named, ":") orelse continue)[0];
        if (!std.mem.endsWith(u8, file, ".mission.luau")) continue;
        try found.append(arena, .{ .file = file, .source = source });
    }
    return found.items;
}

test "the guide's missions build" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const missions = try guideMissions(arena);
    // The first mission at least, so that a change to the guide's blocks can't leave this test
    // with nothing to build.
    try std.testing.expect(missions.len > 0);
    try std.testing.expectEqualStrings("mission90.mission.luau", missions[0].file);
    for (missions) |mission| {
        var failure: compile.Failure = undefined;
        _ = build(arena, mission.source, &failure) catch |err| {
            std.debug.print("{s}:{f}\n", .{ mission.file, failure });
            return err;
        };
    }
}

test buildMapped {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = (try guideMissions(arena))[0];
    var failure: compile.Failure = undefined;
    const compiled = try buildMapped(arena, first.source, &failure);
    const script = try (try dte.Mission.parse(compiled.file)).script();
    try std.testing.expect(compiled.statements.len > 0);
    // The statements in the script's order, each on an instruction of its kind: a stop before a
    // statement, or a `return` or a random choice, which the VM doesn't stop before.
    var last: ?u32 = null;
    for (compiled.statements) |statement| {
        if (last) |before| try std.testing.expect(statement.offset > before);
        last = statement.offset;
        const opcode: dte.Opcode = @fromBackingInt(script[statement.offset]);
        const info = opcode.info().?;
        try std.testing.expectEqual(info.starts_statement, statement.stops);
        try std.testing.expect(info.starts_statement or opcode == .@"return" or opcode == .random_branch);
    }
    // A line's statement is found by its line: the command the Sabres attack with stops before
    // `command`, the assignment that wins before its store, and the `return` after it doesn't stop.
    const lines = try lineNumbers(arena, first.source, &.{ "    SetAI(enemies, \"fight\", 1, player)", "    game.mission_success = 3", "    return 1" });
    const attack = statementOn(compiled, lines[0]).?;
    try std.testing.expect(attack.stops);
    try std.testing.expectEqual(dte.Opcode.command, @as(dte.Opcode, @fromBackingInt(script[attack.offset])));
    const success = statementOn(compiled, lines[1]).?;
    try std.testing.expect(success.stops);
    try std.testing.expectEqual(dte.Opcode.assign, @as(dte.Opcode, @fromBackingInt(script[success.offset])));
    try std.testing.expect(!statementOn(compiled, lines[2]).?.stops);
}

/// The number, counting from 0, of the first line of `text` that is each of `wanted`, in order.
fn lineNumbers(arena: Allocator, text: []const u8, wanted: []const []const u8) ![]u32 {
    const found = try arena.alloc(u32, wanted.len);
    for (wanted, found) |line_text, *number| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var index: u32 = 0;
        number.* = while (lines.next()) |line| : (index += 1) {
            if (std.mem.eql(u8, line, line_text)) break index;
        } else return error.TestUnexpectedResult;
    }
    return found;
}

/// The first statement of `compiled` on `line`.
fn statementOn(compiled: compile.Compiled, line: u32) ?compile.Compiled.Statement {
    for (compiled.statements) |statement| if (statement.at.line == line) return statement;
    return null;
}

test "the guide's mistake is reported as the guide shows it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = (try guideMissions(arena))[0];
    // `enemy` in place of `enemies`, on line 52.
    const right = "on(enemies, \"destroyed\"";
    try std.testing.expectEqual(1, std.mem.count(u8, first.source, right));
    const wrong = try std.mem.replaceOwned(u8, arena, first.source, right, "on(enemy, \"destroyed\"");
    var failure: compile.Failure = undefined;
    try std.testing.expectError(error.Invalid, build(arena, wrong, &failure));
    const said = try arena.print("{s}:{f}\n", .{ first.file, failure });
    try std.testing.expect(std.mem.find(u8, guide, said) != null);
}

test "the guide's first mission plays as the guide says" {
    const gpa = std.testing.allocator;
    const Order = game.ai.orders.Order;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure: compile.Failure = undefined;
    const built = try build(arena, (try guideMissions(arena))[0].source, &failure);

    var world: game.gameobj.testing.Mission = undefined;
    try world.init(gpa);
    defer world.deinit();
    var orders = world.orders();
    orders.world.spawn = world.spawn(game.create.testing.no_models);
    const loaded = try game.mission.Loaded.create(gpa, try gpa.dupe(u8, built), &world.random);
    defer loaded.destroy();
    orders.world.mission = &loaded.bound;
    orders.world.events = &loaded.events;
    try loaded.start(orders);
    const variables = &loaded.script.variables;

    // The ships stand in the slots of their records. The display points the player to the nav
    // point, and the Sabres wait.
    const player = 0;
    const nav = 1;
    const sabres = [_]u16{ 2, 3 };
    const slots = &world.objects.slots;
    for ([_]u16{ player, nav } ++ sabres) |ship| try std.testing.expect(slots[ship].object.created);
    try std.testing.expectEqual(1, world.player.flyback.count);
    try std.testing.expectEqual(nav, world.player.flyback.markers[0].slot);
    for (sabres) |sabre| try std.testing.expectEqual(Order.do_nothing, slots[sabre].current().?.order);
    // The Sabres stand within 4000 of the nav point too, but only the player's ship sets off its
    // trigger.
    playTo(loaded, orders, 1);
    for (sabres) |sabre| try std.testing.expectEqual(Order.do_nothing, slots[sabre].current().?.order);
    // Once the player's ship comes within 4000 of the nav point, the Sabres attack it.
    game.objects.setPosition(&slots[player].object, &slots[player].drawn, .{ 0, 0, 38000 });
    playTo(loaded, orders, 2);
    for (sabres) |sabre| {
        const entry = slots[sabre].current().?;
        try std.testing.expectEqual(Order.fight, entry.order);
        try std.testing.expectEqual(player, entry.target.slot().?);
    }
    // Once both are destroyed, the mission is a success, and five seconds later, it is over.
    game.mission.events.destroyed(orders.world, sabres[0], null);
    playTo(loaded, orders, 3);
    try std.testing.expectEqual(.failure, variables.mission_success);
    game.mission.events.destroyed(orders.world, sabres[1], null);
    playTo(loaded, orders, 4);
    try std.testing.expectEqual(.success, variables.mission_success);
    playTo(loaded, orders, 8);
    try std.testing.expectEqual(0, variables.mission_over);
    playTo(loaded, orders, 10);
    try std.testing.expectEqual(1, variables.mission_over);
}

/// Plays the mission `loaded` on to `seconds` in, as two of the game's frames do: the script's
/// clock ticks and the watches look for ships close by, then the events go off on the triggers,
/// and the threads run.
fn playTo(loaded: *game.mission.Loaded, orders: game.aigeneric.Context, seconds: u32) void {
    loaded.tickClock(seconds * game.main.ticks_per_second);
    loaded.process(orders);
    loaded.flush(orders);
    loaded.process(orders);
}
