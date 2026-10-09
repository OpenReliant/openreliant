//! A ship's parts for scripts ([#995](https://github.com/OpenReliant/openreliant/issues/995)):
//! `object:parts()` and `object:attachments()` list the parts of the object's model and their
//! attachment points, destroyed parts included. Both use the order the game numbers the parts in
//! (`objects.Model.numbered`): each part, then the parts of the models it carries, such as a
//! turret's gun or a missile on its rail.
//!
//! **Improvement:** the original has no scripting apart from its mission scripts.

const std = @import("std");

const openreliant = @import("openreliant");
const shp = openreliant.shp;
const engine = openreliant.engine;
const create = engine.game.create;
const objects = engine.game.objects;
const values = @import("values.zig");

const Vector = @Vector(3, f32);

/// The most parts and attachments the lists hold. No model in the game has that many.
const max_parts = 256;
const max_attachments = 512;

/// A part of an object's model, as `object:parts()` lists it.
pub const Part = struct {
    pub const script_name = "ShipPart";

    /// Its name in the model.
    name: []const u8,
    /// What it is, such as `engine` or `shield_generator`; nil for a part without a class, as most
    /// are, such as a hull's plating.
    class: ?shp.Part.Class,
    /// The index in the list of the part it hangs from; nil if it hangs from the object itself. The
    /// parts of a model that a part carries, such as a turret's gun, hang from that part.
    parent: ?u16,
    /// Its number among the object's components, counting from 0, as missions, the `destroyed`
    /// event and `object:give_order` use it. It keeps the number after it's destroyed. Nil for a
    /// part that isn't a component.
    component: ?u8,
    /// A component's armour: how much it has left, and how much it starts with. Nil for a part that
    /// isn't a component.
    armor: ?f32,
    full_armor: ?f32,
    /// A component's invulnerability, which a mission sets with SetInvulnerability: `full` keeps
    /// off every hit, and `player_can_hit` every hit a player's ship doesn't deal. Nil for a part
    /// that isn't a component.
    invulnerable: ?engine.game.gameobj.Invulnerability,
    /// Whether it's destroyed.
    destroyed: bool,
    /// Whether it's part of a component's damaged model, which stays hidden until the component is
    /// destroyed and then shows in its place.
    damaged: bool,
    /// Its position in the world; nil once it's destroyed.
    position: ?Vector,
};

/// An attachment point on a part, such as an engine's glow or a missile hardpoint, as
/// `object:attachments()` lists it.
pub const Attachment = struct {
    pub const script_name = "ShipAttachment";

    /// The part that carries it, by its index in `object:parts()`.
    part: u16,
    kind: shp.Attachment.Kind,
    /// Whether its part is destroyed.
    destroyed: bool,
    /// Its position in the world; nil once its part is destroyed.
    position: ?Vector,
};

/// The lists scripts get as tables, in order (`values.push`).
pub const Parts = values.List(Part, max_parts);
pub const Attachments = values.List(Attachment, max_attachments);

/// The parts of the object in `slot`, in the order the game numbers them; none for an object
/// without a model.
pub fn partsOf(slot: *create.Slot) Parts {
    var listing: Listing(Parts) = .{ .slot = slot };
    listing.walk();
    return listing.list;
}

/// The attachments of the object in `slot`, part by part in the order the game numbers the parts.
pub fn attachmentsOf(slot: *create.Slot) Attachments {
    var listing: Listing(Attachments) = .{ .slot = slot };
    listing.walk();
    return listing.list;
}

/// Walks an object's parts and fills `List` with the parts or with their attachments.
fn Listing(comptime List: type) type {
    return struct {
        slot: *create.Slot,
        list: List = .{},
        /// The number of the next part. A part's index in `object:parts()` is its number plus 1.
        number: usize = 0,

        const Self = @This();

        fn walk(listing: *Self) void {
            const root = if (listing.slot.model) |*live| live else return;
            listing.walkModel(root, null);
        }

        /// Adds each part of `model`, numbering on from `number`, and after each part the parts of
        /// the models it carries. `carrier` is the number of the part that carries `model`, or null
        /// for the object's own model.
        fn walkModel(listing: *Self, model: *objects.Model, carrier: ?usize) void {
            for (model.parts, 0..) |*part, index| {
                const number = listing.number;
                if (number >= max_parts) return;
                listing.number += 1;
                listing.add(.{ .model = model, .index = index }, number, if (part.parent) |parent| listing.numberOf(.{ .model = model, .index = parent }) else carrier);
                var each = model.carriedBy(index);
                while (each.next()) |mount| listing.walkModel(&mount.model, number);
            }
        }

        /// The number of `ref` among the object's parts, if it's in the list.
        fn numberOf(listing: *Self, ref: objects.PartRef) ?usize {
            const number = listing.slot.model.?.numberOf(ref) orelse return null;
            return if (number < max_parts) number else null;
        }

        fn add(listing: *Self, ref: objects.PartRef, number: usize, parent: ?usize) void {
            const part = ref.part();
            const destroyed = part.destroyed();
            const place = if (destroyed) null else listing.slot.partPlace(part);
            if (List == Parts) {
                const sources = ref.model.source.parts;
                const component = listing.slot.componentNumber(part);
                listing.list.append(.{
                    .name = if (ref.index < sources.len) sources[ref.index].part.name() else "",
                    .class = if (part.class == shp.Part.Class.none) null else part.class,
                    .parent = if (parent) |found| @intCast(found + 1) else null,
                    .component = component,
                    .armor = if (component != null) @max(part.armor, 0) else null,
                    .full_armor = if (component != null) @floatFromInt(part.component_armor) else null,
                    .invulnerable = if (component) |n| listing.slot.object.components[n].invulnerability() else null,
                    .destroyed = destroyed,
                    .damaged = part.flags.damaged,
                    .position = if (place) |found| found.position else null,
                });
            } else {
                for (part.attachments) |attachment| {
                    if (listing.list.len == max_attachments) return;
                    listing.list.append(.{
                        .part = @intCast(number + 1),
                        .kind = attachment.kind,
                        .destroyed = destroyed,
                        .position = if (place) |found| found.point(attachment.position.vector()) else null,
                    });
                }
            }
        }
    };
}

test partsOf {
    const gpa = std.testing.allocator;
    // A hull, an engine hanging from it, and the engine's damaged look.
    var parts: objects.testing.Parts(3) = undefined;
    parts.init();
    for (&parts.data, [_][]const u8{ "hull", "engine", "engine wreck" }) |*data, name| @memcpy(data.part.name_bytes[0..name.len], name);
    parts.components(.{ true, true, false }, .{ 1, 2, 2 });
    parts.data[0].part.class = .hull;
    parts.data[1].part.class = .engine;
    parts.data[1].part.parent = 0;
    parts.data[1].part.component_armor = 50;
    var slot: create.Slot = .{ .object = std.mem.zeroes(engine.game.gameobj.GameObject) };
    slot.model = try parts.create(gpa);
    defer slot.model.?.deinit(gpa);
    create.collectComponents(&slot);
    slot.model.?.parts[1].armor = 20;
    slot.object.components[1].invulnerable = @backingInt(engine.game.gameobj.Invulnerability.full);

    const listed = partsOf(&slot);
    try std.testing.expectEqual(3, listed.len);
    const hull, const engine_part, const wreck = listed.items[0..3].*;
    try std.testing.expectEqualStrings("hull", hull.name);
    try std.testing.expectEqual(.hull, hull.class);
    try std.testing.expectEqual(null, hull.parent);
    try std.testing.expectEqual(0, hull.component);
    try std.testing.expectEqual(.none, hull.invulnerable);
    // The engine hangs from the hull, the first in the list, and has 20 of its 50 left.
    try std.testing.expectEqualStrings("engine", engine_part.name);
    try std.testing.expectEqual(1, engine_part.parent);
    try std.testing.expectEqual(1, engine_part.component);
    try std.testing.expectEqual(20, engine_part.armor);
    try std.testing.expectEqual(50, engine_part.full_armor);
    try std.testing.expectEqual(.full, engine_part.invulnerable);
    try std.testing.expectEqual(@as(Vector, @splat(0)), engine_part.position.?);
    // Its damaged model has no class, and isn't a component.
    try std.testing.expectEqual(null, wreck.class);
    try std.testing.expectEqual(null, wreck.component);
    try std.testing.expectEqual(null, wreck.armor);
    try std.testing.expect(wreck.damaged and !wreck.destroyed);
    // Once destroyed, the engine stays in the list and keeps its number, though the object no
    // longer lists it, and it has no position.
    objects.destroyPart(&slot, .{ .model = &slot.model.?, .index = 1 });
    try std.testing.expectEqual(null, slot.componentIndex(&slot.model.?.parts[1]));
    const destroyed = partsOf(&slot).items[1];
    try std.testing.expect(destroyed.destroyed and destroyed.position == null);
    try std.testing.expectEqual(1, destroyed.component);
}

test "the parts of a model that a part carries hang from it, after it" {
    const gpa = std.testing.allocator;
    var gun: create.testing.Model = undefined;
    try gun.init(gpa);
    defer gun.deinit(gpa);
    // One part, whose gun attachment 100 along X mounts the gun's model.
    var carrier: objects.testing.Carrier = undefined;
    carrier.init(.{ 100, 0, 0 });
    var slot: create.Slot = .{ .object = std.mem.zeroes(engine.game.gameobj.GameObject) };
    slot.model = try carrier.build(gpa, &gun);
    defer slot.model.?.deinit(gpa);
    slot.drawn.position = .{ 0, 0, 10 };

    const listed = partsOf(&slot);
    try std.testing.expectEqual(2, listed.len);
    try std.testing.expectEqual(null, listed.items[0].parent);
    try std.testing.expectEqual(1, listed.items[1].parent);
    const attached = attachmentsOf(&slot);
    try std.testing.expectEqual(1, attached.len);
    try std.testing.expectEqual(1, attached.items[0].part);
    try std.testing.expectEqual(.gun, attached.items[0].kind);
    try std.testing.expectEqual(Vector{ 100, 0, 10 }, attached.items[0].position.?);
}
