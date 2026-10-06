//! Reads the engine's model tables out of the payload: a model and a comms sprite for each ship
//! type, and the models it mounts on attachment points, by kind and id.
//!
//! The ship type table is data in the image. The attachment table is filled when the game starts,
//! by `0x0045DE70`, which loads each file with `MOV ECX, name` and a `CALL`, then stores what the
//! call returns; this reader follows those instructions in Ghidra's exported listing.

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const Kind = openreliant.shp.Attachment.Kind;
const create = openreliant.engine.game.create;
const ShipTypeEntry = create.ShipType;

const image = @import("image.zig");
const testing = @import("testing.zig");
const x86 = @import("x86.zig");

/// The ship type table: a `create.ShipType` for each of the 256 types, which names the model file
/// and the comms sprite.
pub const ship_types: u32 = 0x004F7490;
pub const ship_type_count = create.ship_type_count;

/// The function that fills `attachment_table`.
pub const attachment_loader: u32 = 0x0045DE70;
pub const attachment_table: u32 = 0x00538CA8;
pub const attachment_size = @sizeOf(Stored);
pub const ids_per_kind = 20;
pub const attachment_kinds = 9;

const load_model: u32 = 0x004A44D0;
const load_sprite: u32 = 0x00494A30;

/// An entry of `attachment_table`, as the loader fills it: what each of its stores writes.
const Stored = extern struct {
    model: u32,
    second_model: u32,
    count: u32,
    sprite: u32,

    comptime {
        std.debug.assert(@sizeOf(Stored) == 0x10);
    }
};

pub const ShipType = struct {
    model: ?[]const u8,
    schematic: ?[]const u8,
};

pub const Attachment = struct {
    model: ?[]const u8 = null,
    second_model: ?[]const u8 = null,
    count: u32 = 1,
    sprite: ?[]const u8 = null,
};

pub const Tables = struct {
    ship_types: []const ShipType,
    attachments: [attachment_kinds][ids_per_kind]Attachment,
};

pub const Error = image.Error || error{ NoLoader, UnexpectedStore };

pub fn read(
    arena: std.mem.Allocator,
    reader: image.Reader,
    functions: []const x86.Function,
) (Error || std.mem.Allocator.Error)!Tables {
    const types = try arena.alloc(ShipType, ship_type_count);
    for (types, try reader.records(ShipTypeEntry, ship_types, ship_type_count)) |*ship_type, entry| {
        ship_type.* = .{
            .model = try optionalString(reader, @backingInt(entry.model_name)),
            .schematic = try optionalString(reader, @backingInt(entry.schematic_name)),
        };
    }

    const loader = for (functions) |function| {
        if (function.address == attachment_loader) break function;
    } else return error.NoLoader;

    var tables: Tables = .{ .ship_types = types, .attachments = @splat(@splat(.{})) };
    var ecx: ?u32 = null;
    const Loaded = struct { name: u32, sprite: bool };
    var loaded: ?Loaded = null;
    for (loader.instructions) |instruction| switch (instruction.mnemonic) {
        .call => {
            const target = instruction.target orelse continue;
            if (target != load_model and target != load_sprite) continue;
            loaded = .{ .name = ecx orelse return error.UnexpectedStore, .sprite = target == load_sprite };
            ecx = null;
        },
        .mov => {
            const destination = instruction.destination orelse continue;
            const source = instruction.source orelse continue;
            switch (destination) {
                .register => |register| if (register == .ecx) {
                    ecx = switch (source) {
                        .immediate => |value| std.math.cast(u32, value),
                        else => null,
                    };
                },
                .memory => |address| {
                    if (address.base != null or address.index != null) continue;
                    const slot = std.math.cast(u32, address.displacement) orelse continue;
                    const end = attachment_table + attachment_kinds * ids_per_kind * attachment_size;
                    if (slot < attachment_table or slot >= end) continue;
                    const offset = slot - attachment_table;
                    const index = offset / attachment_size;
                    const entry = &tables.attachments[index / ids_per_kind][index % ids_per_kind];
                    switch (source) {
                        .register => |register| {
                            if (register != .eax) return error.UnexpectedStore;
                            const file = loaded orelse return error.UnexpectedStore;
                            loaded = null;
                            const name = try reader.string(file.name);
                            switch (offset % attachment_size) {
                                @offsetOf(Stored, "model") => if (!file.sprite) {
                                    entry.model = name;
                                } else return error.UnexpectedStore,
                                @offsetOf(Stored, "second_model") => if (!file.sprite) {
                                    entry.second_model = name;
                                } else return error.UnexpectedStore,
                                @offsetOf(Stored, "sprite") => if (file.sprite) {
                                    entry.sprite = name;
                                } else return error.UnexpectedStore,
                                else => return error.UnexpectedStore,
                            }
                        },
                        .immediate => |value| {
                            if (offset % attachment_size != @offsetOf(Stored, "count")) return error.UnexpectedStore;
                            entry.count = std.math.cast(u32, value) orelse return error.UnexpectedStore;
                        },
                        else => return error.UnexpectedStore,
                    }
                },
                else => {},
            }
        },
        else => {},
    };
    return tables;
}

/// A file name, or null for a null pointer or an empty name, neither of which names a file.
fn optionalString(reader: image.Reader, va: u32) image.Error!?[]const u8 {
    if (va == 0) return null;
    const name = try reader.string(va);
    return if (name.len == 0) null else name;
}

/// Writes `models.zig`.
pub fn emit(w: *Io.Writer, tables: Tables) !void {
    try w.print(
        \\//! The models the engine loads by number: one for each ship type, and those it mounts on
        \\//! attachment points, by kind and id.
        \\//!
        \\//! Generated by `src/tools/tablegen` from the payload executable: the ship type table at
        \\//! 0x{X:0>8}, and the loader at 0x{X:0>8} that fills the attachment table at 0x{X:0>8}. The
        \\//! file names are the engine's own. Do not edit by hand; run `make model-tables`.
        \\
        \\const Kind = @import("../../../formats/shp.zig").Attachment.Kind;
        \\
        \\/// A ship type's model, and the sprite of it the comms screen shows. Types are numbered like
        \\/// the records of `shipstats.bin`.
        \\pub const ShipType = struct {{
        \\    model: ?[]const u8,
        \\    schematic: ?[]const u8,
        \\}};
        \\
        \\/// What the engine loads for attachment points of one kind and id.
        \\pub const Attachment = struct {{
        \\    model: ?[]const u8 = null,
        \\    /// A second model loaded with the first: the missile, for a missile pod.
        \\    second_model: ?[]const u8 = null,
        \\    /// **Unknown.** 1 unless the loader sets it.
        \\    count: u32 = 1,
        \\    sprite: ?[]const u8 = null,
        \\}};
        \\
        \\pub const ids_per_kind = {d};
        \\
        \\pub const ship_types = [_]ShipType{{
        \\
    , .{ ship_types, attachment_loader, attachment_table, ids_per_kind });

    for (tables.ship_types, 0..) |ship_type, index| {
        try w.print("    // 0x{X:0>2}\n    .{{ .model = ", .{index});
        try optional(w, ship_type.model);
        try w.writeAll(", .schematic = ");
        try optional(w, ship_type.schematic);
        try w.writeAll(" },\n");
    }

    try w.print(
        \\}};
        \\
        \\/// Indexed by kind, then id.
        \\pub const attachments = [{d}][ids_per_kind]Attachment{{
        \\
    , .{attachment_kinds});
    for (tables.attachments, 0..) |kind, kind_index| {
        const name = std.enums.tagName(Kind, @fromBackingInt(@intCast(kind_index))) orelse "unknown";
        try w.print("    // Kind {d}: {s}\n    .{{\n", .{ kind_index, name });
        for (kind) |entry| {
            if (entry.model == null and entry.second_model == null and entry.sprite == null and entry.count == 1) {
                try w.writeAll("        .{},\n");
                continue;
            }
            try w.writeAll("        .{");
            var first = true;
            inline for (.{ "model", "second_model", "sprite" }) |name_field| {
                if (@field(entry, name_field)) |text| {
                    try w.print("{s} .{s} = \"{f}\"", .{ if (first) "" else ",", name_field, std.zig.fmtString(text) });
                    first = false;
                }
            }
            if (entry.count != 1) try w.print("{s} .count = {d}", .{ if (first) "" else ",", entry.count });
            try w.writeAll(" },\n");
        }
        try w.writeAll("    },\n");
    }

    try w.writeAll(
        \\};
        \\
        \\/// The ship type numbered `index`, or null past the table.
        \\pub fn shipType(index: usize) ?ShipType {
        \\    return if (index < ship_types.len) ship_types[index] else null;
        \\}
        \\
        \\/// What the engine loads for an attachment point, or null when it loads nothing for it.
        \\pub fn attachment(kind: Kind, id: u32) ?Attachment {
        \\    const index = @intFromEnum(kind);
        \\    if (index >= attachments.len or id >= ids_per_kind) return null;
        \\    const entry = attachments[index][id];
        \\    if (entry.model == null and entry.sprite == null) return null;
        \\    return entry;
        \\}
        \\
        \\test attachment {
        \\    const std = @import("std");
        \\    try std.testing.expect(attachment(.gun, 0) != null);
        \\    try std.testing.expect(attachment(.gun, ids_per_kind) == null);
        \\    try std.testing.expect(shipType(0).?.model != null);
        \\}
        \\
    );
}

fn optional(w: *Io.Writer, text: ?[]const u8) !void {
    if (text) |value| {
        try w.print("\"{f}\"", .{std.zig.fmtString(value)});
    } else {
        try w.writeAll("null");
    }
}

/// A synthetic payload holding the ship type table and the file names the loader passes.
const TestPayload = struct {
    data: [0x2000]u8 = @splat(0),

    const data_va = ship_types & ~@as(u32, 0xFFF);
    /// Past the ship type table; `test_loader` names the files at the third and fourth slots.
    const strings: u32 = 0x004F8C00;

    comptime {
        std.debug.assert(strings >= ship_types + ship_type_count * @sizeOf(ShipTypeEntry));
    }

    fn region(payload: *TestPayload) testing.Region {
        return .{ .va = data_va, .bytes = &payload.data };
    }

    /// Writes `name` at the `index`th string slot and returns its address.
    fn name(payload: *TestPayload, index: u32, text: []const u8) u32 {
        const at = strings + index * 0x20;
        payload.region().putString(at, text);
        return at;
    }

    fn tables(payload: *TestPayload, arena: std.mem.Allocator, listing: []const u8) !Tables {
        const reader = try testing.reader(arena, &.{payload.region()});
        return read(arena, reader, try x86.parse(arena, listing));
    }
};

// The loader for kind 1 (gun), id 3: its entry is the 23rd, at 0x00538E18. As in the payload, the
// name for the next call goes into ECX between a call and the store of what it returned.
const test_loader =
    \\; ==== attachment_loader @ 0045de70 ====
    \\0045de70  b9408c4f00               MOV ECX,0x4f8c40
    \\0045de75  e800000000               CALL 0x004a44d0
    \\0045de7a  b9608c4f00               MOV ECX,0x4f8c60
    \\0045de7f  a3188e5300               MOV [0x00538e18],EAX
    \\0045de84  e800000000               CALL 0x00494a30
    \\0045de89  a3248e5300               MOV [0x00538e24],EAX
    \\0045de8e  c705208e53000200000000   MOV dword ptr [0x00538e20],0x2
    \\0045de98  c3                       RET
    \\
;

test read {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var payload: TestPayload = .{};
    const region = payload.region();
    var first = std.mem.zeroes(ShipTypeEntry);
    first.model_name = @fromBackingInt(@intCast(payload.name(0, "SHIP0.SHP")));
    first.schematic_name = @fromBackingInt(@intCast(payload.name(1, "ship0.spr")));
    region.putRecord(ship_types, first);
    try std.testing.expectEqual(0x004F8C40, payload.name(2, "GUN.SHP"));
    try std.testing.expectEqual(0x004F8C60, payload.name(3, "gun.spr"));
    var third = std.mem.zeroes(ShipTypeEntry);
    third.model_name = @fromBackingInt(@intCast(payload.name(4, "")));
    region.putRecord(ship_types + 2 * @sizeOf(ShipTypeEntry), third);

    const tables = try payload.tables(arena.allocator(), test_loader);
    try std.testing.expectEqual(ship_type_count, tables.ship_types.len);
    try std.testing.expectEqualStrings("SHIP0.SHP", tables.ship_types[0].model.?);
    try std.testing.expectEqualStrings("ship0.spr", tables.ship_types[0].schematic.?);
    try std.testing.expectEqual(null, tables.ship_types[1].model);
    try std.testing.expectEqual(null, tables.ship_types[2].model);

    const gun = tables.attachments[@backingInt(Kind.gun)][3];
    try std.testing.expectEqualStrings("GUN.SHP", gun.model.?);
    try std.testing.expectEqualStrings("gun.spr", gun.sprite.?);
    try std.testing.expectEqual(2, gun.count);
    try std.testing.expectEqual(null, gun.second_model);
    try std.testing.expectEqual(null, tables.attachments[0][0].model);
    try std.testing.expectEqual(1, tables.attachments[0][0].count);
}

test "a store follows a load" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var payload: TestPayload = .{};
    const store_first =
        \\; ==== attachment_loader @ 0045de70 ====
        \\0045de70  a3188e5300               MOV [0x00538e18],EAX
        \\
    ;
    try std.testing.expectError(error.UnexpectedStore, payload.tables(arena.allocator(), store_first));

    const sprite_as_model =
        \\; ==== attachment_loader @ 0045de70 ====
        \\0045de70  b9608c4f00               MOV ECX,0x4f8c60
        \\0045de75  e800000000               CALL 0x00494a30
        \\0045de7a  a3188e5300               MOV [0x00538e18],EAX
        \\
    ;
    _ = payload.name(3, "gun.spr");
    try std.testing.expectError(error.UnexpectedStore, payload.tables(arena.allocator(), sprite_as_model));
}

test "read needs the loader" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var payload: TestPayload = .{};
    const elsewhere =
        \\; ==== FUN_00401000 @ 00401000 ====
        \\00401000  c3                       RET
        \\
    ;
    try std.testing.expectError(error.NoLoader, payload.tables(arena.allocator(), elsewhere));
}

test "emit writes Zig that parses" {
    var types: [2]ShipType = .{ .{ .model = "SHIP0.SHP", .schematic = null }, .{ .model = null, .schematic = null } };
    var tables: Tables = .{ .ship_types = &types, .attachments = @splat(@splat(.{})) };
    tables.attachments[1][3] = .{ .model = "GUN.SHP", .sprite = "gun.spr", .count = 2 };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try emit(&out.writer, tables);
    try testing.expectZig(out.written());
    try std.testing.expect(std.mem.indexOf(u8, out.written(), ".{ .model = \"GUN.SHP\", .sprite = \"gun.spr\", .count = 2 },") != null);
}
