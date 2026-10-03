//! Mods' storage ([#498](https://github.com/OpenReliant/openreliant/issues/498)): named sections
//! of plain data, kept for each mod outside Luau, so that the game's scripts and the player's see
//! the same (`Storage`), and scripts reach them through `openreliant.storage` (`package`).
//!
//! - A game section (`storage.game_section`) is kept with the saved game, and starts empty with
//!   each new game. Global and object scripts change it, since it's part of what happens; other
//!   scripts read it.
//! - A global section (`storage.global_section`) is kept across every game, in the game folder's
//!   `storage` folder, a file for each mod (`file_extension`). Any script changes it: it suits
//!   settings, and what a mod keeps from game to game.
//!
//! A section is a table of fields, each named by a string and holding plain data. Reading a field
//! gives a copy, so changing a table read from a section changes nothing until it's stored again.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.scripts);

const openreliant = @import("openreliant");
const Mod = openreliant.engine.game.bigfile.mods.Mod;
const luau = @import("luau.zig");
const State = luau.State;
const stored = @import("stored.zig");
const Value = stored.Value;
const runtime_module = @import("runtime.zig");
const api = @import("api.zig");
const Call = api.Call;

/// Where a section is kept.
pub const Scope = enum {
    /// With the saved game.
    game,
    /// In the game folder, across every game.
    global,
};

/// The folder in the game folder that keeps the global sections, and its files' extension.
pub const folder_name = "storage";
pub const file_extension = ".data";

/// What a global sections' file starts with, and the version of its form.
const magic = "ORST";
const version: u16 = 1;

/// The longest file a mod's global sections may take.
const max_file = 16 << 20;

/// A section: its mod, its name and where it's kept, and its fields.
const Section = struct {
    mod: []const u8,
    name: []const u8,
    scope: Scope,
    fields: std.ArrayList(Field) = .empty,

    const Field = struct { key: []const u8, value: Value };

    fn deinit(section: *Section, gpa: Allocator) void {
        for (section.fields.items) |field| {
            gpa.free(field.key);
            field.value.deinit(gpa);
        }
        section.fields.deinit(gpa);
        gpa.free(section.mod);
        gpa.free(section.name);
    }

    fn find(section: *const Section, key: []const u8) ?usize {
        for (section.fields.items, 0..) |field, at| {
            if (std.mem.eql(u8, field.key, key)) return at;
        }
        return null;
    }
};

/// Every mod's sections.
pub const Storage = struct {
    gpa: Allocator,
    /// The game folder, where the global sections are kept; null where they're kept nowhere, as in
    /// a test.
    folder: ?Folder = null,
    sections: std.ArrayList(*Section) = .empty,
    /// The mods whose global sections changed since they were written.
    changed: std.StringArrayHashMapUnmanaged(void) = .empty,

    pub const Folder = struct { io: Io, dir: Io.Dir };

    pub fn deinit(storage: *Storage) void {
        for (storage.sections.items) |section| {
            section.deinit(storage.gpa);
            storage.gpa.destroy(section);
        }
        storage.sections.deinit(storage.gpa);
        for (storage.changed.keys()) |mod| storage.gpa.free(mod);
        storage.changed.deinit(storage.gpa);
    }

    fn find(storage: *const Storage, mod: []const u8, name: []const u8, scope: Scope) ?*Section {
        for (storage.sections.items) |section| {
            if (section.scope == scope and std.mem.eql(u8, section.mod, mod) and std.mem.eql(u8, section.name, name)) return section;
        }
        return null;
    }

    /// The section `name` of `mod` kept in `scope`, made empty if there's none yet.
    fn obtain(storage: *Storage, mod: []const u8, name: []const u8, scope: Scope) Allocator.Error!*Section {
        if (storage.find(mod, name, scope)) |section| return section;
        try storage.sections.ensureUnusedCapacity(storage.gpa, 1);
        const section = try storage.gpa.create(Section);
        errdefer storage.gpa.destroy(section);
        const mod_copy = try storage.gpa.dupe(u8, mod);
        errdefer storage.gpa.free(mod_copy);
        section.* = .{ .mod = mod_copy, .name = try storage.gpa.dupe(u8, name), .scope = scope };
        storage.sections.appendAssumeCapacity(section);
        return section;
    }

    /// Sets the field `key` of `section` to `value`, which it takes over; nil takes the field out.
    fn set(storage: *Storage, section: *Section, key: []const u8, value: Value) Allocator.Error!void {
        if (section.scope == .global) try storage.markChanged(section.mod);
        if (section.find(key)) |at| {
            const field = &section.fields.items[at];
            field.value.deinit(storage.gpa);
            if (value == .nil) {
                storage.gpa.free(field.key);
                _ = section.fields.orderedRemove(at);
            } else field.value = value;
            return;
        }
        if (value == .nil) return;
        try section.fields.ensureUnusedCapacity(storage.gpa, 1);
        section.fields.appendAssumeCapacity(.{ .key = try storage.gpa.dupe(u8, key), .value = value });
    }

    fn markChanged(storage: *Storage, mod: []const u8) Allocator.Error!void {
        if (storage.changed.contains(mod)) return;
        const copy = try storage.gpa.dupe(u8, mod);
        errdefer storage.gpa.free(copy);
        try storage.changed.put(storage.gpa, copy, {});
    }

    /// The field `key` of the section `name` of `mod` kept in `scope`; null for none.
    pub fn read(storage: *const Storage, mod: []const u8, name: []const u8, scope: Scope, key: []const u8) ?Value {
        const held = storage.find(mod, name, scope) orelse return null;
        const at = held.find(key) orelse return null;
        return held.fields.items[at].value;
    }

    /// Empties every game section, as a new game starts. The sections themselves stay, since
    /// scripts hold them.
    pub fn clearGame(storage: *Storage) void {
        for (storage.sections.items) |section| {
            if (section.scope != .game) continue;
            for (section.fields.items) |held| {
                storage.gpa.free(held.key);
                held.value.deinit(storage.gpa);
            }
            section.fields.clearRetainingCapacity();
        }
    }

    /// Writes the game sections in the binary form (`stored.encode`).
    pub fn encodeGame(storage: *const Storage, w: *Io.Writer) Io.Writer.Error!void {
        var count: u32 = 0;
        for (storage.sections.items) |section| count += @intFromBool(section.scope == .game and section.fields.items.len > 0);
        try w.writeInt(u32, count, .little);
        for (storage.sections.items) |section| {
            if (section.scope != .game or section.fields.items.len == 0) continue;
            try stored.encode(w, .{ .string = section.mod });
            try encodeSection(w, section);
        }
    }

    /// Reads game sections written by `encodeGame`, in place of the game sections there are.
    pub fn decodeGame(storage: *Storage, r: *Io.Reader) stored.DecodeError!void {
        storage.clearGame();
        const count = r.takeInt(u32, .little) catch return error.Damaged;
        for (0..count) |_| {
            const mod = try stored.decode(r, storage.gpa);
            defer mod.deinit(storage.gpa);
            const mod_name = switch (mod) {
                .string => |bytes| bytes,
                else => return error.Damaged,
            };
            try storage.decodeSection(r, mod_name, .game);
        }
    }

    fn encodeSection(w: *Io.Writer, section: *const Section) Io.Writer.Error!void {
        try stored.encode(w, .{ .string = section.name });
        try w.writeInt(u32, @intCast(section.fields.items.len), .little);
        for (section.fields.items) |field| {
            try stored.encode(w, .{ .string = field.key });
            try stored.encode(w, field.value);
        }
    }

    fn decodeSection(storage: *Storage, r: *Io.Reader, mod: []const u8, scope: Scope) stored.DecodeError!void {
        const name = try stored.decode(r, storage.gpa);
        defer name.deinit(storage.gpa);
        const section_name = switch (name) {
            .string => |bytes| bytes,
            else => return error.Damaged,
        };
        const section = try storage.obtain(mod, section_name, scope);
        const count = r.takeInt(u32, .little) catch return error.Damaged;
        for (0..count) |_| {
            const key = try stored.decode(r, storage.gpa);
            defer key.deinit(storage.gpa);
            const field_key = switch (key) {
                .string => |bytes| bytes,
                else => return error.Damaged,
            };
            const value = try stored.decode(r, storage.gpa);
            storage.set(section, field_key, value) catch |err| {
                value.deinit(storage.gpa);
                return err;
            };
        }
    }

    /// Reads the global sections of the mods `opened` from the game folder, as OpenReliant starts.
    /// A file that can't be read is logged and left out.
    pub fn readGlobal(storage: *Storage, opened: []const Mod) Allocator.Error!void {
        const folder = storage.folder orelse return;
        for (opened) |*each| {
            const mod = each.name;
            var name_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&name_buffer, folder_name ++ "/{s}" ++ file_extension, .{mod}) catch continue;
            const bytes = folder.dir.readFileAlloc(folder.io, path, storage.gpa, .limited(max_file)) catch |err| switch (err) {
                error.FileNotFound => continue,
                error.OutOfMemory => |e| return e,
                else => {
                    log.warn("{s}: its storage can't be read: {s}", .{ mod, @errorName(err) });
                    continue;
                },
            };
            defer storage.gpa.free(bytes);
            var r: Io.Reader = .fixed(bytes);
            storage.decodeGlobal(&r, mod) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.Damaged => log.warn("{s}: its storage is damaged, and left out", .{mod}),
            };
        }
        for (storage.changed.keys()) |mod| storage.gpa.free(mod);
        storage.changed.clearRetainingCapacity();
    }

    fn decodeGlobal(storage: *Storage, r: *Io.Reader, mod: []const u8) stored.DecodeError!void {
        const start = r.take(magic.len) catch return error.Damaged;
        if (!std.mem.eql(u8, start, magic)) return error.Damaged;
        if ((r.takeInt(u16, .little) catch return error.Damaged) != version) return error.Damaged;
        const count = r.takeInt(u32, .little) catch return error.Damaged;
        for (0..count) |_| try storage.decodeSection(r, mod, .global);
    }

    /// Writes the global sections of each mod whose sections changed to the game folder. Called
    /// once a frame, and as OpenReliant quits. A file that can't be written is logged.
    pub fn flush(storage: *Storage) void {
        const folder = storage.folder orelse return;
        if (storage.changed.count() == 0) return;
        folder.dir.createDirPath(folder.io, folder_name) catch |err| {
            log.warn("the mods' storage can't be kept: {s}", .{@errorName(err)});
            return;
        };
        for (storage.changed.keys()) |mod| {
            storage.writeGlobal(folder, mod) catch |err| log.warn("{s}: its storage can't be kept: {s}", .{ mod, @errorName(err) });
            storage.gpa.free(mod);
        }
        storage.changed.clearRetainingCapacity();
    }

    fn writeGlobal(storage: *Storage, folder: Folder, mod: []const u8) !void {
        var bytes: Io.Writer.Allocating = .init(storage.gpa);
        defer bytes.deinit();
        const w = &bytes.writer;
        try w.writeAll(magic);
        try w.writeInt(u16, version, .little);
        var count: u32 = 0;
        for (storage.sections.items) |section| count += @intFromBool(section.scope == .global and std.mem.eql(u8, section.mod, mod));
        try w.writeInt(u32, count, .little);
        for (storage.sections.items) |section| {
            if (section.scope == .global and std.mem.eql(u8, section.mod, mod)) try encodeSection(w, section);
        }
        var name_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&name_buffer, folder_name ++ "/{s}" ++ file_extension, .{mod});
        try folder.dir.writeFile(folder.io, .{ .sub_path = path, .data = bytes.written() });
    }

    /// Registers the metatable of a section's handle.
    pub fn register(state: *State) void {
        state.registerUserdata(Handle.tag, "section", &.{
            .{ "__index", luau.wrap(get) },
            .{ "__newindex", luau.wrap(setField) },
            .{ "__iter", luau.wrap(iterate) },
        });
    }
};

/// A section as scripts hold it.
const Handle = struct {
    section: *Section,

    const tag = @intFromEnum(runtime_module.Tag.section);

    fn of(state: *State, at: i32) *Section {
        return (state.toUserdata(Handle, at, tag) orelse state.raise("expected a storage section, got {s}", .{state.typeName(at)})).section;
    }
};

/// `section[key]`: a copy of the field `key`, or nil.
fn get(state: *State) i32 {
    const section = Handle.of(state, 1);
    const key = state.toString(2) orelse state.raise("a storage section's fields are named by strings, not {s}", .{state.typeName(2)});
    const at = section.find(key) orelse {
        state.pushNil();
        return 1;
    };
    stored.push(state, section.fields.items[at].value);
    return 1;
}

/// `section[key] = value`: keeps a copy of `value`, which must be plain data; nil takes the field
/// out. A game section can only be changed by global and object scripts.
fn setField(state: *State) i32 {
    const section = Handle.of(state, 1);
    const key = state.toString(2) orelse state.raise("a storage section's fields are named by strings, not {s}", .{state.typeName(2)});
    const call: Call = .of(state, "storage");
    if (section.scope == .game) switch (call.context.family) {
        .global, .object => {},
        .load, .player, .menu => state.raise("{t} scripts can only read a game section", .{call.context.family}),
    };
    const storage = storageOf(call);
    const gpa = storage.gpa;
    const value = stored.capture(state, gpa, 3, "storage");
    storage.set(section, key, value) catch {
        value.deinit(gpa);
        state.raise("storage: out of memory", .{});
    };
    return 0;
}

/// `__iter`: each field's name and a copy of its value, from a copy of the section made as the
/// loop starts, so that the loop can change the section, such as to empty it.
fn iterate(state: *State) i32 {
    const section = Handle.of(state, 1);
    if (!state.checkStack(4)) state.raise("storage: out of memory", .{});
    _ = state.getGlobal("next");
    state.newTable(0, @intCast(@min(section.fields.items.len, std.math.maxInt(u16))));
    const copy = state.top();
    for (section.fields.items) |field| {
        state.pushString(field.key);
        stored.push(state, field.value);
        state.rawSet(copy);
    }
    state.pushNil();
    return 3;
}

fn storageOf(call: Call) *Storage {
    return call.runtime().options.shared.storage orelse call.raise("storage isn't kept here", .{});
}

/// The handle of the calling mod's section `name` in `scope`.
fn sectionOf(call: Call, name: []const u8, scope: Scope) Handle {
    const storage = storageOf(call);
    return .{ .section = storage.obtain(call.context.modOf().name, name, scope) catch call.raise("storage: out of memory", .{}) };
}

/// What `openreliant.storage` holds.
pub const package = struct {
    pub const game_section = api.Native("The section `name` of the calling mod's storage that's kept with the saved game, and starts empty with each new game. Global and object scripts change it; other scripts read it.", "name: string", "Section", gameSection);
    pub const global_section = api.Native("The section `name` of the calling mod's storage that's kept in the game folder, across every game. Any script changes it.", "name: string", "Section", globalSection);
};

fn gameSection(state: *State) i32 {
    return pushSection(state, .game);
}

fn globalSection(state: *State) i32 {
    return pushSection(state, .global);
}

fn pushSection(state: *State, scope: Scope) i32 {
    const call: Call = .of(state, "storage");
    const name = state.toString(1) orelse state.raise("storage: expected a section's name, got {s}", .{state.typeName(1)});
    const handle = sectionOf(call, name, scope);
    state.newUserdata(Handle, Handle.tag).* = handle;
    return 1;
}

test "scripts read, change and go through sections" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const load = @import("load.zig");
    const mods = openreliant.engine.game.bigfile.mods;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try load.testing.makeMods(io, tmp.dir, &.{.{
        "a",
        &.{
            .{ "mod.ini", "[Scripts]\nLoad=best.luau\n" },
            .{
                "best.luau",
                \\local storage = require("openreliant.storage")
                \\local best = storage.global_section("best")
                \\best.a = 1
                \\best.b = { 2, 3 }
                \\best.c = "x"
                \\local list = best.b
                \\list[1] = 5
                \\assert(best.b[1] == 2)
                \\local count = 0
                \\for name, value in best do
                \\    count += 1
                \\    best[name] = nil
                \\end
                \\assert(count == 3 and best.a == nil and best.b == nil and best.c == nil)
                \\assert(not pcall(function() storage.game_section("tally").x = 1 end))
                \\assert(not pcall(function() best.f = print end))
                \\best.done = vector.create(1, 2, 3)
            },
        },
    }});
    var opened: mods.Mods = try .open(gpa, io, tmp.dir, null);
    defer opened.close(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var held = try load.testing.records3(arena.allocator());
    var storage: Storage = .{ .gpa = gpa };
    defer storage.deinit();
    try load.run(gpa, io, opened.list, &held, "0.7.0", .{ .storage = &storage });
    try std.testing.expectEqual(@Vector(3, f32){ 1, 2, 3 }, storage.read("a", "best", .global, "done").?.vector);
    try std.testing.expectEqual(1, storage.find("a", "best", .global).?.fields.items.len);
}

test "sections keep their fields, and go to a file and back" {
    const gpa = std.testing.allocator;
    var storage: Storage = .{ .gpa = gpa };
    defer storage.deinit();
    const game = try storage.obtain("a", "tally", .game);
    try storage.set(game, "kills", .{ .number = 3 });
    try storage.set(game, "best", .{ .number = 5 });
    try storage.set(game, "best", .nil);
    const global = try storage.obtain("a", "settings", .global);
    try storage.set(global, "reach", .{ .number = 50000 });
    try std.testing.expect(storage.changed.contains("a"));

    var bytes: Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try storage.encodeGame(&bytes.writer);
    storage.clearGame();
    try std.testing.expectEqual(null, storage.read("a", "tally", .game, "kills"));
    var r: Io.Reader = .fixed(bytes.written());
    try storage.decodeGame(&r);
    const back = storage.find("a", "tally", .game).?;
    try std.testing.expectEqual(1, back.fields.items.len);
    try std.testing.expectEqual(3, back.fields.items[0].value.number);
    // The global section stays as it was.
    try std.testing.expectEqual(50000, storage.find("a", "settings", .global).?.fields.items[0].value.number);
}
