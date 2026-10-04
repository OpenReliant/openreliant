//! The declarations that scripts' packages and handles are made from
//! ([#498](https://github.com/OpenReliant/openreliant/issues/498)). A package, such as
//! `openreliant.world`, is a Zig namespace whose public declarations are its fields (`Field`) and
//! its functions (`Function`), and a handle's fields and methods are declared the same way. The
//! bindings, the reference page and the definitions for editors are all made from these
//! declarations at compile time, so what scripts see is declared in one place.
//!
//! - A field has a type, a description, and a getter; with a setter, scripts can change it.
//! - A function has a description and its parameters' names. Its Zig parameters give their types:
//!   the first is a `Call`, and the rest are what scripts pass, read as `values.read` reads them.
//!   Its result is what scripts get, pushed as `values.push` pushes it.

const std = @import("std");

const luau = @import("luau.zig");
const State = luau.State;
const values = @import("values.zig");
const script = @import("script.zig");
const runtime_module = @import("runtime.zig");
const Runtime = runtime_module.Runtime;
const Context = runtime_module.Context;

/// What a declared function gets besides what the script passes: the state it runs on, and the
/// script that calls it.
pub const Call = struct {
    state: *State,
    context: *Context,

    pub fn runtime(call: Call) *Runtime {
        return call.context.runtime;
    }

    /// Raises an error from the script's call. Never returns.
    pub fn raise(call: Call, comptime format: []const u8, arguments: anytype) noreturn {
        call.state.raise(format, arguments);
    }

    /// The calling mod's name `local` qualified with the mod's own, in `buffer`: `crt` in the mod
    /// `retro` is `retro:crt`, and `retro:crt` stays as it is. Raises an error, starting with
    /// `label`, if the name isn't an identifier.
    pub fn qualified(call: Call, comptime label: []const u8, local: []const u8, buffer: *[runtime_module.max_name]u8) []const u8 {
        const mod = call.context.modOf().name;
        const own = if (std.mem.startsWith(u8, local, mod) and local.len > mod.len and local[mod.len] == ':') local[mod.len + 1 ..] else local;
        if (!@import("openreliant").dte.source.validId(own)) call.raise(label ++ ": a name must be an identifier, not '{s}'", .{local});
        return std.fmt.bufPrint(buffer, "{s}:{s}", .{ mod, own }) catch call.raise(label ++ ": the name '{s}' is too long", .{local});
    }

    /// The call of the script running on `state`. Raises an error if no mod's script runs there.
    pub fn of(state: *State, label: []const u8) Call {
        const context = state.threadData(Context) orelse state.raise("{s} can only be used by mod scripts", .{label});
        if (context.closed) state.raise("{s}: this script has stopped", .{label});
        return .{ .state = state, .context = context };
    }
};

/// What a declaration is.
pub const Declaration = enum { field, function };

/// A field of type `T`, described by `about`, which `access` reads with its `get`, and changes with
/// its `set` where it has one. For a package's field they take a `Call`; for a handle's, the
/// receiver's arguments (`objects.fields`).
pub fn Field(comptime T: type, comptime about: []const u8, comptime access: type) type {
    return struct {
        pub const declaration: Declaration = .field;
        pub const Type = T;
        pub const description = about;
        pub const get = access.get;
        pub const writable = @hasDecl(access, "set");
        pub const set = if (writable) access.set else {};
    };
}

/// A function described by `about`, whose parameters scripts pass are named `parameters`. `function`
/// takes a `Call`, then those parameters.
pub fn Function(comptime about: []const u8, comptime parameters: []const []const u8, comptime function: anytype) type {
    const info = @typeInfo(@TypeOf(function)).@"fn";
    if (info.params.len == 0 or info.params[0].type != Call) @compileError("a declared function takes a Call first");
    if (info.params.len - 1 != parameters.len) @compileError("name each parameter of a declared function");
    return struct {
        pub const declaration: Declaration = .function;
        pub const description = about;
        pub const names = parameters;
        pub const Parameters = types: {
            var found: [parameters.len]type = undefined;
            for (&found, info.params[1..]) |*parameter, param| parameter.* = param.type.?;
            break :types found;
        };
        pub const Result = info.return_type.?;
        pub const call = function;

        /// The C function that scripts call: reads the parameters, calls `function`, and pushes its
        /// result.
        pub fn wrapped(state: *State) i32 {
            const caller: Call = .of(state, "this function");
            var arguments: std.meta.ArgsTuple(@TypeOf(function)) = undefined;
            arguments[0] = caller;
            inline for (Parameters, parameters, 1..) |P, name, at| arguments[at] = values.read(state, P, at, name);
            const result = @call(.auto, function, arguments);
            if (Result == void) return 0;
            values.push(state, Result, result);
            return 1;
        }
    };
}

/// What a function that returns nothing returns, as Luau writes it: the result of a `Native` that
/// returns nothing.
pub const nothing = "()";

/// A function described by `about` that reads what scripts pass it itself, such as one that takes
/// a script's function, with the Luau types of its `parameters` and its `result` for the reference.
pub fn Native(comptime about: []const u8, comptime parameters: []const u8, comptime result: []const u8, comptime function: fn (*State) i32) type {
    return struct {
        pub const declaration: Declaration = .function;
        pub const description = about;
        pub const luau_parameters = parameters;
        pub const luau_result = result;
        pub const wrapped = function;
    };
}

/// Whether `D` is a declaration of `kind` (`Field`, `Function`).
pub fn is(comptime D: anytype, comptime kind: Declaration) bool {
    return @TypeOf(D) == type and @hasDecl(D, "declaration") and D.declaration == kind;
}

/// The names of `Namespace`'s declarations of `kind`, in the order they're declared.
pub fn declared(comptime Namespace: type, comptime kind: Declaration) []const []const u8 {
    comptime {
        var found: []const []const u8 = &.{};
        for (std.meta.declarations(Namespace)) |decl| {
            if (is(@field(Namespace, decl.name), kind)) found = found ++ .{decl.name};
        }
        return found;
    }
}

/// Pushes `package`, declared by `Package`: a read-only table of its functions, which reads its
/// fields as scripts look them up.
pub fn pushPackage(state: *State, comptime package: script.Package, comptime Package: type) void {
    const functions = comptime declared(Package, .function);
    state.newTable(0, functions.len);
    inline for (functions) |name| {
        state.pushFunction(luau.wrap(@field(Package, name).wrapped), name ++ "");
        state.rawSetField(-2, name ++ "");
    }
    if (comptime declared(Package, .field).len > 0) {
        state.newTable(0, 1);
        state.pushFunction(luau.wrap(PackageFields(package, Package).get), "__index");
        state.rawSetField(-2, "__index");
        state.setReadonly(-1, true);
        state.setMetatable(-2);
    }
    state.setReadonly(-1, true);
}

/// Reads the fields of `package`, declared by `Package`.
fn PackageFields(comptime package: script.Package, comptime Package: type) type {
    return struct {
        /// `__index`: a field's value.
        fn get(state: *State) i32 {
            const key = state.toString(2) orelse state.raise("expected a field's name, got {s}", .{state.typeName(2)});
            const caller: Call = .of(state, key);
            inline for (comptime declared(Package, .field)) |name| {
                if (std.mem.eql(u8, key, name)) {
                    const field = @field(Package, name);
                    values.push(state, field.Type, field.get(caller));
                    return 1;
                }
            }
            state.raise("{s}{t} has no field '{s}'", .{ script.Package.prefix, package, key });
        }
    };
}

test Function {
    const Example = struct {
        fn twice(_: Call, number: f32, label: []const u8) f32 {
            return if (std.mem.eql(u8, label, "double")) number * 2 else number;
        }
    };
    const twice = Function("Doubles a number.", &.{ "number", "label" }, Example.twice);
    try std.testing.expectEqual(2, twice.Parameters.len);
    try std.testing.expectEqual(f32, twice.Result);
    try std.testing.expect(is(twice, .function));
    try std.testing.expect(!is(twice, .field));
}
