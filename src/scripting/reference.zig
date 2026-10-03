//! The reference of the scripting API, generated from its declarations: the definitions file for
//! Luau's language server (`openreliant.d.luau`), which editors complete names and check types
//! with, the reference page (`reference.md`), and the list `openreliant hooks` prints.
//!
//! `docs/guide` holds the definitions and the reference page as generated, and tests check that
//! they haven't changed. Everything scripts see is in them: the engine handlers, the packages, the
//! fields and methods of objects, the hooks and the fields of their `e`, the records, and the names
//! of values. So a change to OpenReliant's code that would change what scripts see fails the tests,
//! and the scripting API only changes on purpose: then `make definitions` writes the files again.

const std = @import("std");
const Writer = std.Io.Writer;

const openreliant = @import("openreliant");
const engine = openreliant.engine;
const engine_hooks = engine.hooks;
const Hook = engine_hooks.Hook;
const Object = engine_hooks.Object;
const values = @import("values.zig");
const objects = @import("objects.zig");
const records = @import("records.zig");
const bind = @import("bind.zig");
const script = @import("script.zig");
const api = @import("api.zig");
const data = @import("data.zig");
const packages = @import("packages.zig");

/// Whether `T` is a value that scripts hold as a handle or a reference, which has a type of its
/// own in the definitions rather than fields to list.
fn held(comptime T: type) bool {
    return T == Object or T == objects.Handle or T == data.Data or T == values.Table or T == []const u8;
}

/// Whether `T` is one of the records' structs, which the definitions declare as classes.
fn isRecord(comptime T: type) bool {
    return std.mem.indexOfScalar(type, records.Values.kinds, T) != null;
}

/// The types of what a declared function takes and gives; nothing for a native one.
fn functionTypes(comptime F: type) []const type {
    return if (@hasDecl(F, "Parameters")) &(F.Parameters ++ .{F.Result}) else &.{};
}

/// The types at the roots of what scripts see, which `gather` follows.
const roots: []const type = list: {
    @setEvalBranchQuota(1_000_000);
    var found: []const type = namespaceTypes(objects.fields) ++ namespaceTypes(objects.methods);
    for (std.enums.values(script.Package)) |package| {
        if (packages.namespace(package)) |Namespace| found = found ++ namespaceTypes(Namespace);
    }
    for (std.enums.values(script.Handler)) |handler| {
        for (@typeInfo(handler.Arguments()).@"struct".fields) |field| found = found ++ .{field.type};
    }
    for (std.enums.values(Hook)) |hook| {
        const declared = engine_hooks.declaration(hook);
        for (values.shownFields(declared.Fields)) |field| found = found ++ .{field.type};
        if (declared.Result != void) found = found ++ .{declared.Result};
    }
    break :list found ++ records.Values.kinds;
};

/// The types of what scripts pass the functions and methods declared, which `given` follows.
const passed: []const type = list: {
    @setEvalBranchQuota(1_000_000);
    var found: []const type = namespaceParameters(objects.methods);
    for (std.enums.values(script.Package)) |package| {
        if (packages.namespace(package)) |Namespace| found = found ++ namespaceParameters(Namespace);
    }
    break :list found;
};

/// The types of the parameters of the functions `Namespace` declares; none for a native one.
fn namespaceParameters(comptime Namespace: type) []const type {
    var found: []const type = &.{};
    for (api.declared(Namespace, .function)) |name| {
        const F = @field(Namespace, name);
        if (@hasDecl(F, "Parameters")) found = found ++ F.Parameters;
    }
    return found;
}

/// The tables scripts give, reached from what declared functions take.
const given_tables: []const type = found: {
    @setEvalBranchQuota(10_000_000);
    var seen: Gathered = .{};
    for (passed) |T| seen = gather(T, seen);
    break :found seen.tables;
};

/// The types of the fields and functions `Namespace` declares.
fn namespaceTypes(comptime Namespace: type) []const type {
    var found: []const type = &.{};
    for (api.declared(Namespace, .field)) |name| found = found ++ .{@field(Namespace, name).Type};
    for (api.declared(Namespace, .function)) |name| found = found ++ functionTypes(@field(Namespace, name));
    return found;
}

/// The enums and the tables (structs given as tables) scripts see, each once, in the order `roots`
/// reaches them.
const Gathered = struct {
    enums: []const type = &.{},
    tables: []const type = &.{},
};

const gathered: Gathered = found: {
    @setEvalBranchQuota(10_000_000);
    var seen: Gathered = .{};
    for (roots) |T| seen = gather(T, seen);
    // Each takes a name of its own.
    const all = seen.enums ++ seen.tables;
    for (all, 0..) |T, at| {
        for (all[at + 1 ..]) |other| {
            if (std.mem.eql(u8, bind.noun(T), bind.noun(other))) @compileError("two types scripts see are named " ++ bind.noun(T) ++ ": give one a script_name");
        }
    }
    break :found seen;
};

fn gather(comptime T: type, comptime seen: Gathered) Gathered {
    if (held(T) or T == void) return seen;
    if (values.isList(T)) return gather(T.Item, seen);
    return switch (@typeInfo(T)) {
        .optional => |optional| gather(optional.child, seen),
        .array => |array| if (array.child == u8) seen else gather(array.child, seen),
        .@"enum" => if (std.mem.indexOfScalar(type, seen.enums, T) != null) seen else .{ .enums = seen.enums ++ .{T}, .tables = seen.tables },
        .@"struct" => fields: {
            if (std.mem.indexOfScalar(type, seen.tables, T) != null) break :fields seen;
            var next = seen;
            if (!isRecord(T)) next.tables = next.tables ++ .{T};
            for (values.shownFields(T)) |field| next = gather(field.type, next);
            break :fields next;
        },
        else => seen,
    };
}

/// The Luau type of a value of `T` (`values.push`).
fn luauType(comptime T: type) []const u8 {
    comptime {
        if (T == Object or T == objects.Handle) return "Object";
        if (values.isList(T)) return "{ " ++ luauType(T.Item) ++ " }";
        if (T == data.Data) return "any";
        if (T == values.Table) return "{ [any]: any }";
        return switch (@typeInfo(T)) {
            .@"union" => |info| unionType(info),
            .void => api.nothing,
            .float, .int => "number",
            .bool => "boolean",
            .@"enum", .@"struct" => bind.noun(T),
            .optional => |optional| if (@typeInfo(optional.child) == .@"union") "(" ++ luauType(optional.child) ++ ")?" else luauType(optional.child) ++ "?",
            .vector => "vector",
            .array => |array| if (array.child == u8) "string" else "{ " ++ luauType(array.child) ++ " }",
            .pointer => "string",
            else => @compileError("no Luau type for " ++ @typeName(T)),
        };
    }
}

/// The Luau type of a union of booleans, numbers and strings: whichever of them.
fn unionType(comptime info: std.builtin.Type.Union) []const u8 {
    comptime {
        var text: []const u8 = "";
        for (info.fields, 0..) |field, at| text = text ++ (if (at == 0) "" else " | ") ++ luauType(field.type);
        return text;
    }
}

/// The parameters of the declared function `F`, as Luau writes them, without the first `skipped`
/// (a method's receiver).
fn parameterList(comptime F: type, comptime skipped: usize) []const u8 {
    comptime {
        if (@hasDecl(F, "luau_parameters")) return F.luau_parameters;
        var text: []const u8 = "";
        for (F.names[skipped..], F.Parameters[skipped..], 0..) |name, P, at| {
            text = text ++ (if (at == 0) "" else ", ") ++ name ++ ": " ++ luauType(P);
        }
        return text;
    }
}

/// What the declared function `F` returns, as Luau writes it.
fn resultType(comptime F: type) []const u8 {
    return if (@hasDecl(F, "luau_result")) F.luau_result else luauType(F.Result);
}

/// The name of the class of `hook`'s `e`: its name in Pascal case, or `OrderRoutine` for the
/// order table's routines, which all see the same fields.
fn eventClass(comptime hook: Hook) []const u8 {
    comptime {
        if (engine_hooks.Fields(hook) == engine_hooks.RoutineFields) return "OrderRoutine";
        return pascal(@tagName(hook));
    }
}

/// `name`, in snake case, in Pascal case.
fn pascal(comptime name: []const u8) []const u8 {
    comptime {
        var text: []const u8 = "";
        var upper = true;
        for (name) |c| {
            if (c == '_') {
                upper = true;
                continue;
            }
            text = text ++ .{if (upper) std.ascii.toUpper(c) else c};
            upper = false;
        }
        return text;
    }
}

/// Whether this version runs scripts of `family`.
fn familyRuns(comptime family: script.Family) bool {
    for (std.enums.values(script.Kind)) |kind| {
        if (kind.family() == family and kind.runs()) return true;
    }
    return false;
}

/// The families of scripts this version runs, in order.
const running_families: []const script.Family = list: {
    var found: []const script.Family = &.{};
    for (std.enums.values(script.Family)) |family| {
        if (familyRuns(family)) found = found ++ .{family};
    }
    break :list found;
};

/// Whether the engine calls `handler` for a family it runs.
fn called(comptime handler: script.Handler) bool {
    for (running_families) |family| {
        if (handler.givenBy(family)) return true;
    }
    return false;
}

/// The arguments of `handler`, as Luau writes them.
fn handlerParameters(comptime handler: script.Handler) []const u8 {
    comptime {
        var text: []const u8 = "";
        for (@typeInfo(handler.Arguments()).@"struct".fields, 0..) |field, at| {
            text = text ++ (if (at == 0) "" else ", ") ++ field.name ++ ": " ++ luauType(field.type);
        }
        return text;
    }
}

/// Writes the definitions file.
pub fn writeDefinitions(w: *Writer) Writer.Error!void {
    @setEvalBranchQuota(10_000_000);
    try w.writeAll(
        \\-- The types of OpenReliant's scripting API, for Luau's language server (luau-lsp). Point its
        \\-- luau-lsp.types.definitionFiles setting at this file, and give each package's local its type,
        \\-- such as `local hooks: Hooks = require("openreliant.hooks")`, for completion and type checks.
        \\-- Generated by `openreliant hooks --definitions` from OpenReliant's bindings; don't change it
        \\-- by hand.
        \\
        \\
    );

    try w.writeAll("-- Names of values. A value without a name is a number.\n\n");
    inline for (gathered.enums) |T| {
        try w.print("type {s} = ", .{comptime bind.noun(T)});
        inline for (comptime values.names(T), 0..) |name, at| {
            if (at > 0) try w.writeAll(" | ");
            try w.print("\"{s}\"", .{name});
        }
        if (comptime values.takesNumbers(T)) try w.writeAll(" | number");
        try w.writeAll("\n");
    }

    try w.writeAll("\n-- Tables of values, which scripts can only read.\n\n");
    inline for (gathered.tables) |T| try writeTable(w, comptime bind.noun(T), T);

    try w.writeAll("\n-- Objects, which scripts hold by handles.\n\n");
    try w.writeAll("declare class Object\n");
    inline for (comptime api.declared(objects.fields, .field)) |name| {
        const field = @field(objects.fields, name);
        try w.print("    -- {s}\n    {s}: {s}\n", .{ field.description, name, comptime luauType(field.Type) });
    }
    inline for (comptime api.declared(objects.methods, .function)) |name| {
        const method = @field(objects.methods, name);
        const parameters = comptime parameterList(method, 1);
        try w.print("    -- {s}\n    function {s}(self{s}{s}): {s}\n", .{ method.description, name, if (parameters.len > 0) ", " else "", parameters, comptime resultType(method) });
    }
    try w.writeAll("end\n");

    try w.writeAll("\n-- The records (`openreliant.records`).\n\n");
    inline for (comptime records.Values.kinds) |T| {
        if (@typeInfo(T) != .@"struct") continue;
        try w.print("declare class {s}\n", .{comptime bind.noun(T)});
        inline for (comptime values.shownFields(T)) |field| try w.print("    {s}: {s}\n", .{ field.name, comptime luauType(field.type) });
        try w.writeAll("end\n");
    }
    try w.writeAll("type Records = {\n");
    inline for (comptime std.enums.values(records.Set)) |set| {
        const Element = set.Element();
        const element = comptime if (Element == []const u8) "string" else bind.noun(Element);
        try w.print("    {s}: {{ [number | string]: {s} }},\n", .{ @tagName(set), element });
    }
    try w.writeAll("}\n");

    try w.writeAll("\n-- The packages made from declarations. `openreliant.self` is the script's own Object.\n");
    inline for (comptime std.enums.values(script.Package)) |package| {
        if (comptime packages.namespace(package)) |Namespace| {
            try w.print("\n-- {s}\ntype {s} = {{\n", .{ package.about(), comptime pascal(@tagName(package)) });
            inline for (comptime api.declared(Namespace, .field)) |name| {
                const field = @field(Namespace, name);
                try w.print("    -- {s}\n    {s}: {s},\n", .{ field.description, name, comptime luauType(field.Type) });
            }
            inline for (comptime api.declared(Namespace, .function)) |name| {
                const function = @field(Namespace, name);
                try w.print("    -- {s}\n    {s}: ({s}) -> {s},\n", .{ function.description, name, comptime parameterList(function, 0), comptime resultType(function) });
            }
            try w.writeAll("}\n");
        }
    }
    try w.print("\n-- {s}\ntype Interfaces = {{ [string]: any }}\n", .{script.Package.interfaces.about()});
    try w.writeAll("\n-- A section of a mod's storage: its fields by name, each plain data. Reading one gives a copy.\ntype Section = { [string]: any }\n");

    try w.writeAll(
        \\
        \\-- The hooks (`openreliant.hooks`). Each handler gets `e`, whose class is named after the hook.
        \\
        \\declare class HookHandle
        \\    -- Removes the handler. Returns whether it was there.
        \\    function remove(self): boolean
        \\end
        \\
        \\-- The objects a handler is for: each test that's given must hold.
        \\type Filter = {
        \\    object: Object?,
        \\    type: (ShipType | { ShipType })?,
        \\    class: (ShipClass | { ShipClass })?,
        \\    side: (Side | { Side })?,
        \\}
        \\
    );
    comptime var declared: []const []const u8 = &.{};
    inline for (comptime std.enums.values(Hook)) |hook| {
        const class = comptime eventClass(hook);
        const seen = comptime for (declared) |name| {
            if (std.mem.eql(u8, name, class)) break true;
        } else false;
        if (!seen) {
            declared = declared ++ .{class};
            try writeEventClass(w, hook, class);
        }
    }
    try writeAdd(w, false);
    try writeAdd(w, true);
    try w.writeAll(
        \\type Hooks = {
        \\    -- Adds a handler that runs before the hook's function, or when its event happens.
        \\    add: HooksAdd,
        \\    -- Adds a handler that runs after the hook's function, which sees its result in e.result.
        \\    after: HooksAfter,
        \\}
        \\
        \\-- What scripts return.
        \\
    );
    inline for (running_families) |family| {
        try w.print("\ntype {s}Script = {{\n    engine_handlers: {{\n", .{comptime pascal(@tagName(family))});
        inline for (comptime std.enums.values(script.Handler)) |handler| {
            if (comptime called(handler) and handler.givenBy(family)) {
                try w.print("        {t}: (({s}) -> {s})?,\n", .{ handler, comptime handlerParameters(handler), comptime luauType(handler.Result()) });
            }
        }
        try w.writeAll("    }?,\n");
        if (comptime script.Offer.event_handlers.offeredBy(family)) {
            try w.writeAll(
                \\    event_handlers: { [string]: (data: any) -> boolean? }?,
                \\    interface_name: string?,
                \\    interface: { [any]: any }?,
                \\
            );
        }
        try w.writeAll("}\n");
    }
}

/// Writes the class of `hook`'s `e`.
fn writeEventClass(w: *Writer, comptime hook: Hook, comptime class: []const u8) Writer.Error!void {
    const declared = comptime engine_hooks.declaration(hook);
    if (comptime engine_hooks.Fields(hook) == engine_hooks.RoutineFields) {
        try w.print("\n-- What a hook on one of the order table's routines sees.\ndeclare class {s}\n", .{class});
    } else {
        try w.print("\n-- {s}\ndeclare class {s}\n", .{ declared.about, class });
    }
    inline for (comptime values.shownFields(declared.Fields)) |field| try w.print("    {s}: {s}\n", .{ field.name, comptime luauType(field.type) });
    if (declared.Result != void) try w.print("    result: {s}\n", .{comptime luauType(declared.Result)});
    if (declared.on == .function) {
        const returned = comptime if (declared.Result == void) api.nothing else luauType(declared.Result) ++ "?";
        try w.print("    -- Runs the rest of the call now: the handlers after this one, then the function.\n    function original(self): {s}\n", .{returned});
    }
    try w.writeAll("end\n");
}

/// Writes the type of `hooks.add`, or of `hooks.after`, whose hooks are only the functions'.
fn writeAdd(w: *Writer, comptime functions_only: bool) Writer.Error!void {
    try w.print("\ntype Hooks{s} = ", .{if (functions_only) "After" else "Add"});
    var first = true;
    inline for (comptime std.enums.values(Hook)) |hook| {
        const declared = comptime engine_hooks.declaration(hook);
        if (functions_only and declared.on != .function) continue;
        const class = comptime eventClass(hook);
        const filter = if (declared.subject != null) "Filter | " else "";
        try w.print("{s}\n    ((name: \"{s}\", handler: (e: {s}) -> boolean?, filter: ({s}(e: {s}) -> boolean)?) -> HookHandle)", .{
            if (first) "" else " &", @tagName(hook), class, filter, class,
        });
        first = false;
    }
    try w.writeAll("\n");
}

/// Writes a table type of `T`'s fields, as `values.pushTable` gives them.
fn writeTable(w: *Writer, comptime name: []const u8, comptime T: type) Writer.Error!void {
    try w.print("type {s} = {{\n", .{name});
    inline for (comptime values.shownFields(T)) |field| {
        // A field with a default can be left out of a table a script gives.
        const optional = if (comptime given(T) and field.defaultValue() != null and @typeInfo(field.type) != .optional) "?" else "";
        try w.print("    {s}: {s}{s},\n", .{ field.name, comptime luauType(field.type), optional });
    }
    try w.writeAll("}\n");
}

/// Whether `T` is a table scripts give, such as a style, to a function that takes one.
fn given(comptime T: type) bool {
    return std.mem.indexOfScalar(type, given_tables, T) != null;
}

/// How many of the fields scripts see of `T` have a default, which a table scripts give may leave
/// out.
fn defaulted(comptime T: type) usize {
    var count: usize = 0;
    for (values.shownFields(T)) |field| count += @intFromBool(field.defaultValue() != null);
    return count;
}

/// A field's default, as a script would write it.
fn defaultText(comptime field: std.builtin.Type.StructField) []const u8 {
    comptime {
        const value = field.defaultValue().?;
        return switch (@typeInfo(field.type)) {
            .float, .int => std.fmt.comptimePrint("{d}", .{value}),
            .bool => if (value) "true" else "false",
            .@"enum" => "`\"" ++ @tagName(value) ++ "\"`",
            .vector => std.fmt.comptimePrint("`vector.create({d}, {d}, {d})`", .{ value[0], value[1], value[2] }),
            .optional => "nil",
            .pointer => "`\"" ++ value ++ "\"`",
            .@"struct" => if (values.isList(field.type) and value.len == 0) "none" else @compileError("no way to write the default of " ++ @typeName(field.type)),
            else => @compileError("no way to write the default of " ++ @typeName(field.type)),
        };
    }
}

/// Writes the reference page, `docs/guide/reference.md`: the engine handlers, the packages, the
/// fields and methods of objects, each hook with the fields of its `e`, the tables, and the names of
/// values.
pub fn writeMarkdown(w: *Writer) Writer.Error!void {
    @setEvalBranchQuota(10_000_000);
    try w.writeAll(
        \\# Scripting reference
        \\
        \\This page lists everything mods' scripts can use: the engine handlers, the packages, the fields
        \\and methods of objects, the hooks with the fields each handler sees in `e`, and the names of
        \\values. [Scripting](scripting.md) explains how to use them. `openreliant hooks` prints the list of
        \\hooks, and `openreliant hooks <name>` one hook.
        \\
        \\This page is generated from OpenReliant's code by `make definitions`, so don't change it by hand.
        \\
        \\- [Engine handlers](#engine-handlers)
        \\- [Packages](#packages)
        \\- [Objects](#objects)
        \\- [The game's functions](#the-games-functions)
        \\- [The order routines](#the-order-routines)
        \\- [The mission's events](#the-missions-events)
        \\- [The engine's events](#the-engines-events)
        \\- [Tables](#tables)
        \\- [Names of values](#names-of-values)
        \\
        \\## Engine handlers
        \\
        \\The functions a script returns in `engine_handlers`, which OpenReliant calls. Global scripts
        \\include mission scripts.
        \\
        \\| Handler | Scripts | When it's called |
        \\|---|---|---|
        \\
    );
    inline for (comptime std.enums.values(script.Handler)) |handler| {
        if (comptime called(handler)) {
            try w.print("| `{t}({s})`{s} | ", .{ handler, comptime handlerParameters(handler), comptime if (handler.Result() == void) "" else ": " ++ markdownType(handler.Result()) });
            try writeFamilies(w, handler);
            try w.print(" | {s} |\n", .{handler.about()});
        }
    }

    try w.writeAll(
        \\
        \\## Packages
        \\
        \\What `require("openreliant.<name>")` gives.
        \\
    );
    inline for (comptime std.enums.values(script.Package)) |package| {
        if (comptime package.ready()) try writePackageSection(w, package);
    }

    try w.writeAll(
        \\
        \\## Objects
        \\
        \\Scripts see objects through handles. A handle stays valid until its object is removed or its
        \\mission ends; reading a field of a handle that isn't valid is an error. Every script can read the
        \\fields; global scripts can change those marked *changes* on any object, and an object's own
        \\scripts on their object.
        \\
        \\| Field | Type | What it is |
        \\|---|---|---|
        \\
    );
    inline for (comptime api.declared(objects.fields, .field)) |name| {
        const field = @field(objects.fields, name);
        try w.print("| `{s}` | {s} | {s}{s} |\n", .{ name, comptime markdownType(field.Type), if (field.writable) "*Changes.* " else "", field.description });
    }
    try w.writeAll(
        \\
        \\| Method | Returns | What it does |
        \\|---|---|---|
        \\
    );
    inline for (comptime api.declared(objects.methods, .function)) |name| {
        const method = @field(objects.methods, name);
        try w.print("| `{s}({s})` | {s} | {s} |\n", .{ name, comptime cell(parameterList(method, 1)), comptime markdownResult(method), method.description });
    }

    try w.writeAll(
        \\
        \\## The game's functions
        \\
        \\Each is a function of the original game, under its name. `hooks.add` runs a handler before the
        \\function, and `hooks.after` runs one after it. Changing a field of `e` changes what the function
        \\does, and a handler that returns `false` stops it.
        \\
    );
    inline for (comptime std.enums.values(Hook)) |hook| {
        const declared = comptime engine_hooks.declaration(hook);
        if (declared.on == .function and engine_hooks.Fields(hook) != engine_hooks.RoutineFields) try writeHookSection(w, hook);
    }
    try w.writeAll(
        \\
        \\## The order routines
        \\
        \\Each order an object follows, such as Fight or Run Away, runs routines of the original game:
        \\an `init` as the order starts, an `update` each frame, and for a few an `exit` as it ends. Each
        \\routine is a hook under its name. Its handlers see the object that runs the order as `e.object`,
        \\and `e.object.order` is the order. Where OpenReliant doesn't run a routine yet, its handlers
        \\still run, and the function does nothing.
        \\
        \\| Hook | What it is |
        \\|---|---|
        \\
    );
    inline for (comptime std.enums.values(Hook)) |hook| {
        if (comptime engine_hooks.Fields(hook) == engine_hooks.RoutineFields) {
            try w.print("| `{s}` | {s} |\n", .{ @tagName(hook), comptime engine_hooks.declaration(hook).about });
        }
    }
    try w.writeAll(
        \\
        \\## The mission's events
        \\
        \\The events a mission's triggers can wait for, under the names of their conditions. Each comes
        \\for the mission's ships, those its file lists, whether or not a trigger waits for it. Their
        \\fields can only be read, and a handler that returns `false` stops the handlers after it.
        \\
    );
    inline for (comptime std.enums.values(Hook)) |hook| {
        if (comptime engine_hooks.declaration(hook).on == .mission_event) try writeHookSection(w, hook);
    }
    try w.writeAll(
        \\
        \\## The engine's events
        \\
        \\Their fields can only be read, and a handler that returns `false` stops the handlers after it.
        \\
    );
    inline for (comptime std.enums.values(Hook)) |hook| {
        if (comptime engine_hooks.declaration(hook).on == .engine_event) try writeHookSection(w, hook);
    }

    try w.writeAll(
        \\
        \\## Tables
        \\
        \\Values given as tables of fields. Scripts can only read the ones OpenReliant gives them.
        \\
    );
    inline for (gathered.tables) |T| {
        if (comptime given(T) and defaulted(T) > 0) {
            const left_out = comptime if (defaulted(T) == values.shownFields(T).len) "any field" else "a field with a default";
            try w.print("\n### {s}\n\nA table a script gives, which may leave out {s}.\n\n| Field | Type | Default |\n|---|---|---|\n", .{ comptime bind.noun(T), left_out });
            inline for (comptime values.shownFields(T)) |field| try w.print("| `{s}` | {s} | {s} |\n", .{ field.name, comptime markdownType(field.type), comptime if (field.defaultValue() != null) defaultText(field) else "needed" });
        } else {
            try w.print("\n### {s}\n\n| Field | Type |\n|---|---|\n", .{comptime bind.noun(T)});
            inline for (comptime values.shownFields(T)) |field| try w.print("| `{s}` | {s} |\n", .{ field.name, comptime markdownType(field.type) });
        }
    }

    try w.writeAll(
        \\
        \\## Names of values
        \\
        \\A value that has a name in OpenReliant is given as a string: its name. One without a name is a
        \\number. A script can set a field to either.
        \\
    );
    inline for (gathered.enums) |T| {
        try w.print("\n### {s}\n\n", .{comptime bind.noun(T)});
        inline for (comptime values.names(T), 0..) |name, at| try w.print("{s}`{s}`", .{ if (at == 0) "" else ", ", name });
        try w.writeAll(if (comptime values.takesNumbers(T)) ", or a number.\n" else ".\n");
    }
}

/// `text` for a cell of a markdown table, its `|` escaped.
fn cell(comptime text: []const u8) []const u8 {
    comptime {
        var escaped: []const u8 = "";
        for (text) |c| escaped = escaped ++ if (c == '|') "\\|" else .{c};
        return escaped;
    }
}

/// What the declared function `F` returns, for the reference page.
fn markdownResult(comptime F: type) []const u8 {
    if (!@hasDecl(F, "Result")) return if (comptime std.mem.eql(u8, F.luau_result, api.nothing)) "nothing" else cell(F.luau_result);
    return if (F.Result == void) "nothing" else markdownType(F.Result);
}

/// Writes the names of `families`, as in "global and object".
fn writeFamilyNames(w: *Writer, comptime families: []const script.Family) Writer.Error!void {
    inline for (families, 0..) |family, at| {
        const separator = if (at == 0) "" else if (at == families.len - 1) " and " else ", ";
        try w.print("{s}{t}", .{ separator, family });
    }
}

/// The families this version runs that `wanted` holds of.
fn familiesWhere(comptime wanted: fn (script.Family) bool) []const script.Family {
    comptime {
        var found: []const script.Family = &.{};
        for (running_families) |family| {
            if (wanted(family)) found = found ++ .{family};
        }
        return found;
    }
}

/// Writes the families of scripts that may give `handler`, among those this version runs.
fn writeFamilies(w: *Writer, comptime handler: script.Handler) Writer.Error!void {
    try writeFamilyNames(w, comptime familiesWhere(struct {
        fn gives(family: script.Family) bool {
            return handler.givenBy(family);
        }
    }.gives));
}

/// Writes the section of `package` on the reference page.
fn writePackageSection(w: *Writer, comptime package: script.Package) Writer.Error!void {
    try w.print("\n### `{s}{t}`\n\n{s} For ", .{ script.Package.prefix, package, package.about() });
    try writePackageFamilies(w, package);
    try w.writeAll(" scripts.\n");
    const declared = comptime packages.namespace(package);
    if (declared == null) return;
    const Namespace = declared.?;
    try w.writeAll("\n| Name | Type | What it is |\n|---|---|---|\n");
    inline for (comptime api.declared(Namespace, .field)) |name| {
        const field = @field(Namespace, name);
        try w.print("| `{s}` | {s} | {s} |\n", .{ name, comptime markdownType(field.Type), field.description });
    }
    inline for (comptime api.declared(Namespace, .function)) |name| {
        const function = @field(Namespace, name);
        try w.print("| `{s}({s})` | {s} | {s} |\n", .{ name, comptime cell(parameterList(function, 0)), comptime markdownResult(function), function.description });
    }
}

/// Writes the families of scripts that can require `package`.
fn writePackageFamilies(w: *Writer, comptime package: script.Package) Writer.Error!void {
    try writeFamilyNames(w, comptime familiesWhere(struct {
        fn reaches(family: script.Family) bool {
            return package.reachableFrom(family);
        }
    }.reaches));
}

/// Writes the section of `hook` on the reference page.
fn writeHookSection(w: *Writer, comptime hook: Hook) Writer.Error!void {
    const declared = comptime engine_hooks.declaration(hook);
    try w.print("\n### {s}\n\n{s}\n\n", .{ @tagName(hook), declared.about });
    const fields = comptime values.shownFields(declared.Fields);
    if (fields.len == 0 and declared.Result == void) return;
    try w.writeAll("| Field | Type |\n|---|---|\n");
    inline for (fields) |field| try w.print("| `{s}` | {s} |\n", .{ field.name, comptime markdownType(field.type) });
    if (declared.Result != void) try w.print("| `result` | {s} |\n", .{comptime markdownType(declared.Result)});
}

/// A type on the reference page: its Luau type, with a link to the names of an enum's values.
fn markdownType(comptime T: type) []const u8 {
    comptime {
        const Plain = switch (@typeInfo(T)) {
            .optional => |optional| optional.child,
            else => T,
        };
        const optional = if (Plain == T) "" else ", or nil";
        if (Plain == Object or Plain == objects.Handle) return "[object](#objects)" ++ optional;
        if (values.isList(Plain)) return "list of " ++ (if (Plain.Item == Object) "[objects](#objects)" else markdownType(Plain.Item)) ++ optional;
        if (Plain == data.Data) return "plain data";
        if (std.mem.indexOfScalar(type, gathered.enums ++ gathered.tables, Plain) != null) {
            const name = bind.noun(Plain);
            var anchor: []const u8 = "";
            for (name) |c| anchor = anchor ++ .{std.ascii.toLower(c)};
            return "[" ++ name ++ "](#" ++ anchor ++ ")" ++ optional;
        }
        return cell(luauType(Plain)) ++ optional;
    }
}

/// Writes the list of hooks `openreliant hooks` prints: every hook, or only the one named `only`.
/// Returns false if there's no hook of that name.
pub fn writeList(w: *Writer, only: ?[]const u8) Writer.Error!bool {
    @setEvalBranchQuota(1_000_000);
    var found = false;
    var last: ?engine_hooks.On = null;
    inline for (comptime std.enums.values(Hook)) |hook| {
        const declared = comptime engine_hooks.declaration(hook);
        const matches = if (only) |name| std.mem.eql(u8, name, @tagName(hook)) else true;
        if (matches) {
            found = true;
            if (only == null and last != declared.on) {
                if (last != null) try w.writeAll("\n");
                try w.writeAll(switch (declared.on) {
                    .function => "The game's functions. hooks.add runs a handler before the function, hooks.after after it.\n",
                    .mission_event => "The mission's events, for the mission's ships. Their fields can only be read.\n",
                    .engine_event => "The engine's events. Their fields can only be read.\n",
                });
                last = declared.on;
            }
            try w.print("\n{s}", .{@tagName(hook)});
            if (declared.address) |address| try w.print(" (0x{X:0>8})", .{address});
            try w.print("\n    {s}\n", .{declared.about});
            inline for (comptime values.shownFields(declared.Fields)) |field| {
                try w.print("    e.{s}: {s}", .{ field.name, comptime luauType(field.type) });
                try writeChoices(w, field.type);
                try w.writeAll("\n");
            }
            if (declared.Result != void) try w.print("    e.result: {s}\n", .{comptime luauType(declared.Result)});
        }
    }
    return found;
}

/// Writes what the console's `help` says of `name`: a package, with or without `openreliant.`
/// before it, an engine handler or a hook. Returns false if nothing has that name.
pub fn writeHelp(w: *Writer, name: []const u8) Writer.Error!bool {
    @setEvalBranchQuota(1_000_000);
    const package_name = if (std.mem.startsWith(u8, name, script.Package.prefix)) name[script.Package.prefix.len..] else name;
    inline for (comptime std.enums.values(script.Package)) |package| {
        if (std.mem.eql(u8, package_name, @tagName(package))) {
            try writePackageHelp(w, package);
            return true;
        }
    }
    inline for (comptime std.enums.values(script.Handler)) |handler| {
        if (comptime called(handler)) if (std.mem.eql(u8, name, @tagName(handler))) {
            try w.print("{t}({s}) -> {s}\n    {s}\n    For ", .{ handler, comptime handlerParameters(handler), comptime luauType(handler.Result()), handler.about() });
            try writeFamilies(w, handler);
            try w.writeAll(" scripts.\n");
            return true;
        };
    }
    return writeList(w, name);
}

/// Writes what `help` says of `package`: what it holds, who can require it, and its fields and
/// functions.
fn writePackageHelp(w: *Writer, comptime package: script.Package) Writer.Error!void {
    try w.print("{s}{t}\n    {s}\n    For ", .{ script.Package.prefix, package, package.about() });
    try writePackageFamilies(w, package);
    try w.writeAll(" scripts.\n");
    if (!package.ready()) return w.writeAll("    Not available in this version of OpenReliant.\n");
    const declared = comptime packages.namespace(package);
    if (declared == null) return;
    const Namespace = declared.?;
    inline for (comptime api.declared(Namespace, .field)) |field_name| {
        const field = @field(Namespace, field_name);
        try w.print("{s}: {s}\n    {s}\n", .{ field_name, comptime luauType(field.Type), field.description });
    }
    inline for (comptime api.declared(Namespace, .function)) |function_name| {
        const function = @field(Namespace, function_name);
        try w.print("{s}({s}) -> {s}\n    {s}\n", .{ function_name, comptime parameterList(function, 0), comptime resultType(function), function.description });
    }
}

/// The most names of an enum's values that `openreliant hooks` lists after a field's type.
const listed_names = 12;

/// Writes the names a field's enum takes, where there are few.
fn writeChoices(w: *Writer, comptime T: type) Writer.Error!void {
    const Plain = switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };
    if (comptime @typeInfo(Plain) != .@"enum" or Plain == Object) return;
    const names = comptime values.names(Plain);
    if (names.len > listed_names) return;
    try w.writeAll(" (");
    inline for (names, 0..) |name, at| try w.print("{s}\"{s}\"", .{ if (at == 0) "" else ", ", name });
    if (comptime values.takesNumbers(Plain)) try w.writeAll(", or a number");
    try w.writeAll(")");
}

test writeHelp {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    try std.testing.expect(try writeHelp(&buffer.writer, "openreliant.storage"));
    try std.testing.expect(std.mem.indexOf(u8, buffer.written(), "game_section(name: string) -> Section") != null);
    buffer.clearRetainingCapacity();
    try std.testing.expect(try writeHelp(&buffer.writer, "on_update"));
    try std.testing.expect(std.mem.startsWith(u8, buffer.written(), "on_update(seconds: number) -> ()"));
    buffer.clearRetainingCapacity();
    try std.testing.expect(try writeHelp(&buffer.writer, "object_damage"));
    try std.testing.expect(std.mem.indexOf(u8, buffer.written(), "e.object") != null);
    try std.testing.expect(!try writeHelp(&buffer.writer, "no_such_thing"));
}

test "the definitions don't change unless the scripting API does" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    try writeDefinitions(&buffer.writer);
    const pinned = @embedFile("openreliant.d.luau");
    if (!std.mem.eql(u8, buffer.written(), pinned)) {
        std.debug.print("the scripting API has changed: if that's meant, run `make definitions` to update docs/guide/openreliant.d.luau\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "the reference page doesn't change unless the scripting API does" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    try writeMarkdown(&buffer.writer);
    const pinned = @embedFile("reference.md");
    if (!std.mem.eql(u8, buffer.written(), pinned)) {
        std.debug.print("the scripting API has changed: if that's meant, run `make definitions` to update docs/guide/reference.md\n", .{});
        return error.TestUnexpectedResult;
    }
}

test writeList {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    try std.testing.expect(try writeList(&buffer.writer, "object_damage"));
    try std.testing.expect(std.mem.indexOf(u8, buffer.written(), "e.quadrant: Quadrant (\"left\", \"right\", \"fore\", \"aft\")") != null);
    try std.testing.expect(!try writeList(&buffer.writer, "nothing"));
}
