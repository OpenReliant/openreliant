//! `.frc` force-feedback effects (`forces\`), as the SideWinder Force Feedback SDK's force editor
//! saves them and its Visual Force Effects server (`vfx.dll`, `CLSID_VFX`) reads them: a RIFF form
//! `FORC` holding an `INFO` list, the GUID of the device it was made for (`trgt`), and a `trak`
//! list with an `efct` list for each effect, each an `id  ` and a `data` chunk. See
//! [docs/formats/frc.md](../../docs/formats/frc.md).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const layout = @import("layout.zig");
const riff = @import("riff.zig");

/// The RIFF form of an effect file.
pub const form = "FORC";

pub const Error = error{NotAnEffectFile} || Allocator.Error;

/// One effect: a waveform, a pause, or a group of the file's other effects.
pub const Effect = struct {
    /// Its `id  `, which a group names it by.
    id: u32,
    /// As the editor named it, such as `Sine1`; it points into the file's bytes.
    name: []const u8,
    /// The way it pushes, in degrees.
    direction: u32,
    /// How long it lasts, in milliseconds. A group's is its own members'.
    duration: u32,
    /// How strong it is, in percent.
    gain: u32,
    envelope: Envelope,
    kind: Kind,

    pub const Kind = union(enum) {
        pause,
        wave: Wave,
        group: Group,
    };
};

/// How an effect's strength rises and falls over its duration: from `start` to `level` over the
/// first `attack` percent of it, at `level` for the next `sustain` percent, and on to `end` over the
/// `decay` percent after that. The levels are percentages too.
pub const Envelope = struct {
    attack: u32 = 0,
    sustain: u32 = 100,
    decay: u32 = 0,
    start: i32 = 0,
    end: i32 = 0,
    level: i32 = 100,
};

/// A waveform between `low` and `high`, in percent of full force, repeating `frequency` times a
/// second. A constant force stands at `high`, and a ramp runs between the two once over the whole
/// effect.
pub const Wave = struct {
    shape: Shape,
    frequency: u32,
    high: i32,
    low: i32,
};

pub const Shape = enum(u32) {
    constant = 101,
    sine,
    cosine,
    /// A square wave that starts low, and one that starts high.
    square_low,
    square_high,
    ramp_up,
    ramp_down,
    triangle_up,
    triangle_down,
    sawtooth_up,
    sawtooth_down,
    _,
};

/// Other effects of the file by their ids, played one after the other or all at once.
pub const Group = struct {
    order: Order,
    ids: []align(1) const u32,

    pub const Order = enum(u32) { sequence = 202, superimpose = 203, _ };
};

/// A `data` chunk's record, 104 bytes, before the envelope.
const Record = extern struct {
    /// 104, the record's own size.
    size: u32,
    name: [64]u8,
    kind: Kind,
    /// A waveform's `Shape`, a group's `Group.Order`, and 10 for a pause.
    type: u32,
    /// 3 in every shipped file: both axes.
    axes: u32,
    direction: u32,
    /// 0 in every shipped file.
    _unknown_54: u32,
    duration: u32,
    gain: u32,
    /// 100 in every shipped file.
    _unknown_5c: u32,
    /// 0, or 1 in a few groups and effects.
    _unknown_60: u32,

    const Kind = enum(u32) { pause = 1, wave = 2, group = 3, _ };

    comptime {
        assert(@sizeOf(Record) == 104);
    }
};

/// The envelope's record, after the effect's (32 bytes).
const EnvelopeRecord = extern struct {
    size: u32,
    /// 0 in every shipped file.
    _unknown_04: u32,
    attack: u32,
    sustain: u32,
    decay: u32,
    start: i32,
    end: i32,
    level: i32,

    comptime {
        assert(@sizeOf(EnvelopeRecord) == 32);
    }
};

/// A waveform's record, after the envelope (20 bytes).
const WaveRecord = extern struct {
    size: u32,
    frequency: u32,
    /// 100, or 0 for a constant force.
    _unknown_08: u32,
    high: i32,
    low: i32,

    comptime {
        assert(@sizeOf(WaveRecord) == 20);
    }
};

/// A group's record, after the envelope (12 bytes), which the ids of its members follow.
const GroupRecord = extern struct {
    size: u32,
    count: u32,
    /// Where the editor held the ids in memory as it saved the file.
    _pointer: u32,

    comptime {
        assert(@sizeOf(GroupRecord) == 12);
    }
};

/// A file's effects, in the order it holds them. They point into the file's bytes.
pub const File = struct {
    effects: []const Effect,

    pub fn parse(gpa: Allocator, bytes: []const u8) Error!File {
        const header = riff.header(bytes, form) orelse return error.NotAnEffectFile;
        var effects: std.ArrayList(Effect) = .empty;
        errdefer effects.deinit(gpa);
        var id: ?u32 = null;
        // The chunks, as far as the header says they run, each list's walked in its place.
        const rest = bytes[@sizeOf(riff.Header)..];
        var chunks: riff.Chunks = .{ .rest = rest[0..@min(rest.len, header.size -| riff.form_len)], .into_lists = true };
        while (chunks.next() catch return error.NotAnEffectFile) |chunk| {
            if (std.mem.eql(u8, &chunk.id, "id  ")) {
                id = (layout.view(u32, chunk.body) catch return error.NotAnEffectFile).*;
            } else if (std.mem.eql(u8, &chunk.id, "data")) {
                try effects.append(gpa, try effect(id orelse return error.NotAnEffectFile, chunk.body));
                id = null;
            }
        }
        return .{ .effects = try effects.toOwnedSlice(gpa) };
    }

    pub fn deinit(file: File, gpa: Allocator) void {
        gpa.free(file.effects);
    }

    /// The effect `id` names, where the file has one.
    pub fn find(file: File, id: u32) ?*const Effect {
        for (file.effects) |*each| {
            if (each.id == id) return each;
        }
        return null;
    }

    /// Whether `id` is a member of one of the file's groups.
    pub fn grouped(file: File, id: u32) bool {
        for (file.effects) |each| {
            const group = switch (each.kind) {
                .group => |group| group,
                else => continue,
            };
            for (group.ids) |member| {
                if (member == id) return true;
            }
        }
        return false;
    }
};

/// The effect a `data` chunk holds.
fn effect(id: u32, body: []const u8) Error!Effect {
    const record = layout.view(Record, body) catch return error.NotAnEffectFile;
    const shaped = layout.view(EnvelopeRecord, body[@sizeOf(Record)..]) catch return error.NotAnEffectFile;
    if (record.size != @sizeOf(Record) or shaped.size != @sizeOf(EnvelopeRecord)) return error.NotAnEffectFile;
    const rest = body[@sizeOf(Record) + @sizeOf(EnvelopeRecord) ..];
    const kind: Effect.Kind = switch (record.kind) {
        .pause => .pause,
        .wave => wave: {
            const wave = layout.view(WaveRecord, rest) catch return error.NotAnEffectFile;
            const shape: Shape = @fromBackingInt(record.type);
            if (std.enums.tagName(Shape, shape) == null) return error.NotAnEffectFile;
            break :wave .{ .wave = .{ .shape = shape, .frequency = wave.frequency, .high = wave.high, .low = wave.low } };
        },
        .group => group: {
            const group = layout.view(GroupRecord, rest) catch return error.NotAnEffectFile;
            const order: Group.Order = @fromBackingInt(record.type);
            if (std.enums.tagName(Group.Order, order) == null) return error.NotAnEffectFile;
            const ids = layout.array(u32, rest[@sizeOf(GroupRecord)..], group.count) catch return error.NotAnEffectFile;
            break :group .{ .group = .{ .order = order, .ids = ids } };
        },
        _ => return error.NotAnEffectFile,
    };
    return .{
        .id = id,
        .name = std.mem.sliceTo(&record.name, 0),
        .direction = record.direction,
        .duration = record.duration,
        .gain = record.gain,
        .envelope = .{
            .attack = shaped.attack,
            .sustain = shaped.sustain,
            .decay = shaped.decay,
            .start = shaped.start,
            .end = shaped.end,
            .level = shaped.level,
        },
        .kind = kind,
    };
}

/// Builds a file of `effects` as the editor saves one, for tests.
pub const testing = struct {
    pub const Made = struct {
        id: u32,
        name: []const u8,
        kind: u32,
        type: u32,
        duration: u32,
        envelope: Envelope = .{},
        /// A waveform's frequency, high and low, or a group's ids.
        rest: []const u32,
    };

    pub fn file(gpa: Allocator, effects: []const Made) Allocator.Error![]u8 {
        var trak: std.ArrayList(u8) = .empty;
        defer trak.deinit(gpa);
        for (effects) |made| {
            var data: std.ArrayList(u8) = .empty;
            defer data.deinit(gpa);
            var record = std.mem.zeroes(Record);
            record.size = @sizeOf(Record);
            @memcpy(record.name[0..made.name.len], made.name);
            record.kind = @fromBackingInt(made.kind);
            record.type = made.type;
            record.axes = 3;
            record.duration = made.duration;
            record.gain = 100;
            record._unknown_5c = 100;
            try data.appendSlice(gpa, std.mem.asBytes(&record));
            const envelope: EnvelopeRecord = .{
                .size = @sizeOf(EnvelopeRecord),
                ._unknown_04 = 0,
                .attack = made.envelope.attack,
                .sustain = made.envelope.sustain,
                .decay = made.envelope.decay,
                .start = made.envelope.start,
                .end = made.envelope.end,
                .level = made.envelope.level,
            };
            try data.appendSlice(gpa, std.mem.asBytes(&envelope));
            switch (made.kind) {
                2 => {
                    const wave: WaveRecord = .{ .size = @sizeOf(WaveRecord), .frequency = made.rest[0], ._unknown_08 = 100, .high = @bitCast(made.rest[1]), .low = @bitCast(made.rest[2]) };
                    try data.appendSlice(gpa, std.mem.asBytes(&wave));
                },
                3 => {
                    const group: GroupRecord = .{ .size = @sizeOf(GroupRecord), .count = @intCast(made.rest.len), ._pointer = 0 };
                    try data.appendSlice(gpa, std.mem.asBytes(&group));
                    try data.appendSlice(gpa, std.mem.sliceAsBytes(made.rest));
                },
                else => {},
            }
            var efct: std.ArrayList(u8) = .empty;
            defer efct.deinit(gpa);
            try efct.appendSlice(gpa, "efct");
            try appendChunk(gpa, &efct, "id  ", std.mem.asBytes(&made.id));
            try appendChunk(gpa, &efct, "data", data.items);
            try appendChunk(gpa, &trak, riff.list_id, efct.items);
        }
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        try body.appendSlice(gpa, form);
        try appendChunk(gpa, &body, riff.list_id, "INFO");
        try appendChunk(gpa, &body, "trgt", &@as([16]u8, @splat(0)));
        const tracks = try std.mem.concat(gpa, u8, &.{ "trak", trak.items });
        defer gpa.free(tracks);
        try appendChunk(gpa, &body, riff.list_id, tracks);
        var out: std.ArrayList(u8) = .empty;
        try appendChunk(gpa, &out, riff.Header.riff_id, body.items);
        return out.toOwnedSlice(gpa);
    }

    const appendChunk = riff.testing.appendChunk;
};

test File {
    const gpa = std.testing.allocator;
    const bytes = try testing.file(gpa, &.{
        .{ .id = 0, .name = "Sine1", .kind = 2, .type = 102, .duration = 395, .envelope = .{ .attack = 43, .sustain = 14, .decay = 43 }, .rest = &.{ 11, 54, @bitCast(@as(i32, -53)) } },
        .{ .id = 1, .name = "Delay95", .kind = 1, .type = 10, .duration = 3, .rest = &.{} },
        .{ .id = 2, .name = "Sequence73", .kind = 3, .type = 202, .duration = 1000, .rest = &.{ 0, 1 } },
    });
    defer gpa.free(bytes);
    const file: File = try .parse(gpa, bytes);
    defer file.deinit(gpa);

    try std.testing.expectEqual(3, file.effects.len);
    const sine = file.find(0).?;
    try std.testing.expectEqualStrings("Sine1", sine.name);
    try std.testing.expectEqual(395, sine.duration);
    try std.testing.expectEqual(Envelope{ .attack = 43, .sustain = 14, .decay = 43 }, sine.envelope);
    try std.testing.expectEqual(Wave{ .shape = .sine, .frequency = 11, .high = 54, .low = -53 }, sine.kind.wave);
    try std.testing.expectEqual(Effect.Kind.pause, file.find(1).?.kind);
    const group = file.find(2).?.kind.group;
    try std.testing.expectEqual(Group.Order.sequence, group.order);
    try std.testing.expectEqual(2, group.ids.len);
    try std.testing.expectEqual(1, group.ids[1]);

    // The sine and the pause are the sequence's; the sequence is no group's.
    try std.testing.expect(file.grouped(0) and file.grouped(1));
    try std.testing.expect(!file.grouped(2));
    try std.testing.expectEqual(null, file.find(9));
}

test "a file that isn't one" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NotAnEffectFile, File.parse(gpa, "RIFF\x04\x00\x00\x00WAVE"));
    try std.testing.expectError(error.NotAnEffectFile, File.parse(gpa, "RI"));
    // An effect of a shape no editor saves.
    const bytes = try testing.file(gpa, &.{.{ .id = 0, .name = "Odd", .kind = 2, .type = 150, .duration = 1, .rest = &.{ 1, 1, 1 } }});
    defer gpa.free(bytes);
    try std.testing.expectError(error.NotAnEffectFile, File.parse(gpa, bytes));
}
