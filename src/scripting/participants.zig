//! Luau compares participant IDs as strings. Keep the full admission counter even when it
//! exceeds the range of integers that a Luau number can represent exactly.

const std = @import("std");
const engine = @import("openreliant").engine;
const Objects = engine.game.create.Objects;
const Ref = engine.game.players.ParticipantRef;

const slot_bytes = @sizeOf(@FieldType(Ref, "slot"));
const size = slot_bytes + @sizeOf(@FieldType(Ref, "generation"));
pub const Id = [size * 2]u8;

pub fn idForShip(all: *const Objects, slot: u16) ?Id {
    const ref = (all.playerBinding(slot) orelse return null).participant;
    var bytes: [size]u8 = undefined;
    std.mem.writeInt(u16, bytes[0..slot_bytes], ref.slot, .big);
    std.mem.writeInt(u64, bytes[slot_bytes..], ref.generation, .big);
    return std.fmt.bytesToHex(bytes, .lower);
}

pub fn shipForId(all: *const Objects, id: []const u8) ?engine.hooks.Object {
    if (id.len != @sizeOf(Id)) return null;
    var bytes: [size]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, id) catch return null;
    const binding = all.playerBinding(std.mem.readInt(u16, bytes[0..slot_bytes], .big)) orelse return null;
    if (binding.participant.generation != std.mem.readInt(u64, bytes[slot_bytes..], .big)) return null;
    return .retained(binding.ship);
}
