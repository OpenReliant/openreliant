//! `C:\lancer\game\collision.cpp`: what becomes of two objects that meet. `objects_update` finds
//! the pairs whose spheres overlap ([`create.zig`](create.zig)) and hands each to
//! `objects_collide`, which pushes them apart. `docs/engine/loop.md` describes the sweep.
//!
//! **Unverified:** this file's known code lies before `objects_collide`; what is ported here lies
//! between it and `Create.cpp`'s, which no string places.

const std = @import("std");

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const ai = @import("ai.zig");
const events = @import("mission/events.zig");
const aigeneric = @import("aigeneric.zig");
const aifuncs = @import("aifuncs.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const hooks = @import("../hooks.zig");
const main = @import("main.zig");
const motion = @import("motion.zig");
const objects = @import("objects.zig");
const shield = @import("shield.zig");
const hud = @import("hud.zig");
const input = @import("../input.zig");
const camera = @import("camera.zig");
const friendly_fire = @import("friendly_fire.zig");
const radio = @import("radio.zig");
const players = @import("players.zig");
const betty = @import("hog_snd/betty.zig");
const shieldfx = @import("shieldfx.zig");

/// How far apart a collision sets two objects, as a share of each one's radius from the point
/// between them (`0x004DC7C0` and `0x004DC7C4`): a tenth further than touching, so that the next
/// step does not find them overlapping again.
pub const push_apart: f32 = 1.1;

/// `objects_collide` (`0x00466170`): what two objects whose spheres overlap do about it, and
/// whether they were moved, which has `objects_update` look again.
///
/// Two of one type never collide while a torpedo is one of them, nor do two torpedoes, two pieces
/// of debris or two satellites. A torpedo goes off against what it meets and a mine against a
/// fighter, instead of being pushed (`goOff`), and a ship that meets something which lists
/// components is tested against its parts. Anything else is pushed apart along the line between the
/// two, each to `push_apart` of its radius from the point between them, after both have moved
/// again.
///
/// Not ported: what a mine does in a multiplayer game, 5000 and the kill to its owner, and what the
/// destruction tells the other players, which are multiplayer's
/// ([#55](https://github.com/OpenReliant/openreliant/issues/55)).
pub fn collide(world: gameobj.World, first: u16, second: u16, pass: u8) bool {
    const all = world.objects;
    var near = first;
    var far = second;
    const near_class = className(all, near) orelse return false;
    const far_class = className(all, far) orelse return false;
    var classes: [2]create.ShipCombat.Class = .{ near_class, far_class };

    // A torpedo comes first, and never meets another object of its own type or one that is already
    // going off.
    if (classes[0] == .torpedo or classes[1] == .torpedo) {
        if (all.slots[near].object.type == all.slots[far].object.type) return false;
        if (classes[1] == .torpedo) {
            std.mem.swap(u16, &near, &far);
            std.mem.swap(create.ShipCombat.Class, &classes[0], &classes[1]);
        }
        if (all.slots[near].object.flags.exploding) return false;
    }

    const lists_components = all.slots[near].object.flags.components or all.slots[far].object.flags.components;
    if (lists_components) return parts(world, near, far, pass);

    // Two torpedoes and two pieces of debris pass through each other, as do two satellites.
    if (classes[0] == classes[1] and (classes[0] == .torpedo or classes[0] == .debris)) return false;
    // Two satellites never collide, whatever their class.
    if (all.slots[near].object.type.base() == .satellite and all.slots[far].object.type.base() == .satellite) return false;

    // A mine goes off against a fighter, and a torpedo against whatever it met.
    if (classes[0] == .mine or classes[1] == .mine) {
        if (classes[0] != .fighter and classes[1] != .fighter) return false;
        const mine, const fighter = if (classes[0] == .mine) .{ near, far } else .{ far, near };
        goOff(world, mine, fighter, mine_blow, .collision, false);
        return false;
    }
    if (classes[0] == .torpedo) {
        goOff(world, near, far, torpedo_blow, .crash, true);
        return true;
    }

    return push(world, near, far, pass);
}

/// What a torpedo does to what it meets, and a mine to a fighter.
const torpedo_blow: f32 = 5001;
const mine_blow: f32 = 500;

/// A torpedo or a mine in slot `from` going off against what it met in slot `struck`: `blow` to the
/// fore quadrant of what it met as `kind`, which is named its own attacker, and the torpedo or the
/// mine destroyed (`object_destroyed_net`, `0x00402100`), never spinning; a torpedo ejects no
/// pilot.
fn goOff(world: gameobj.World, from: u16, struck: u16, blow: f32, kind: Kind, no_eject: bool) void {
    damage(world, struck, .fore, blow, 1, struck, kind);
    ai.objectDestroyed(.of(world), from, false, no_eject);
}

/// The class of the ship type in a slot, or null for an object with no stats, which the game would
/// follow a null pointer for.
fn className(all: *const create.Objects, index: u16) ?create.ShipCombat.Class {
    const combat = all.slots[index].combat orelse return null;
    return combat.class;
}

/// How hard the two come off each other (`0x004DC4A4`): the impulse carries twice the speed they
/// meet at, so the bounce keeps it.
const bounce: f32 = -2;

/// The speed a pair whose contact points are not closing is pushed apart at, for each pass the
/// sweep has already made (`0x004DC56C`), so a pair that keeps meeting is parted harder each time.
const resting_speed: f32 = 5;

/// `0x00464E80`: the shove two objects give each other where their spheres touch. The contact
/// point lies on the line between their centres, so neither is turned by it.
fn shove(world: gameobj.World, first: u16, second: u16, pass: u8) void {
    const all = world.objects;
    const near = all.slots[first].object.placeAt(.now);
    const far = all.slots[second].object.placeAt(.now);
    const apart = near.position - far.position;
    if (math.lengthSquared(apart) == 0) return;
    const toward = math.normalize(apart);
    const contact = far.position + toward * @as(Vector, @splat(all.slots[second].object.radius));
    const impulse = shoveAt(world, first, second, -toward, .{ near.inverse(contact), far.inverse(contact) }, pass) orelse return;
    impact(world, first, second, impulse, contact);
}

/// `0x00464E80` itself: the impulse where two objects meet. `normal` points from the first to the
/// second, and `levers` gives the contact point in each object's own frame. The impulse follows
/// how fast those points close between this step and the next, each object's mass and its
/// `angular_response`, and both take it through `knock`, equal and opposite. An object held to
/// another, and the Ripper carrying something, take none.
///
/// The move that follows applies the knocks, which is why a colliding pair moves again.
fn shoveAt(world: gameobj.World, first: u16, second: u16, normal: Vector, levers: [2]Vector, pass: u8) ?Vector {
    const all = world.objects;
    const near = &all.slots[first].object;
    const far = &all.slots[second].object;

    // Where each contact point stands now and where the step is taking it.
    const now: [2]Vector = .{ near.placeAt(.now).point(levers[0]), far.placeAt(.now).point(levers[1]) };
    const next: [2]Vector = .{ near.placeAt(.next).point(levers[0]), far.placeAt(.next).point(levers[1]) };
    var closing = (next[0] - now[0]) - (next[1] - now[1]);
    if (math.lengthSquared(closing) == 0 and far.flags.components) {
        closing = normal * @as(Vector, @splat(near.radius - math.distance(now[0], next[0])));
    }
    const speed = math.length(closing);
    if (math.dot(closing, normal) < 0 and speed > 0) {
        closing *= @as(Vector, @splat(-(1 + @as(f32, @floatFromInt(pass))) * resting_speed / speed));
    }

    var give: f32 = 0;
    for ([_]u16{ first, second }, now) |index, at| {
        if (!shoved(all, index)) continue;
        const object = &all.slots[index].object;
        const lever = at - object.position();
        const turn = math.transform(
            object.root.orientation,
            math.transform(object.angular_response, math.transformTransposed(object.root.orientation, math.cross(lever, normal))),
        );
        give += 1 / object.mass + math.dot(math.cross(turn, lever), normal);
    }
    // A tensor or a mass the arithmetic cannot hold would throw the pair across the sky.
    if (!(give > 0) or !std.math.isFinite(give)) return null;
    var force = normal * @as(Vector, @splat(math.dot(closing, normal) * bounce / give));
    if (@reduce(.And, force == @as(Vector, @splat(0)))) force = normal;
    if (!@reduce(.And, @abs(force) < @as(Vector, @splat(std.math.floatMax(f32))))) return null;
    for ([_]u16{ first, second }, now, 0..) |index, at, which| {
        if (!shoved(all, index)) continue;
        gameobj.knock(&all.slots[index].object, if (which == 0) force else -force, at);
    }
    return force;
}

/// Whether the object takes a shove at all: one held to another does not, nor does the Ripper while
/// it is carrying something.
///
/// **Improvement:** neither does an object of no mass, which the game would divide by, since a
/// model whose parts hold no volume leaves one.
fn shoved(all: *const create.Objects, index: u16) bool {
    const slot = &all.slots[index];
    if (slot.object.flags.attached or slot.object.mass <= 0) return false;
    if (slot.object.type.base() != .ripper) return true;
    return slot.running(.ripper_grabs_target_object) == null;
}

/// Both objects shove each other, move again, and are then set apart along the line between them
/// where they still overlap. The move applies the knocks the shove handed them, which is why it
/// runs again here.
fn push(world: gameobj.World, first: u16, second: u16, pass: u8) bool {
    const all = world.objects;
    shove(world, first, second, pass);
    for ([_]u16{ first, second }) |index| motion.moveSlot(world, index);
    const near = &all.slots[first];
    const far = &all.slots[second];
    if (!near.object.overlaps(&far.object, 0)) return true;

    const here = near.object.nextPosition();
    const there = far.object.nextPosition();
    const apart = math.normalize(here - there);
    const between = (here + there) * @as(Vector, @splat(0.5));
    objects.setPosition(&near.object, &near.drawn, between + apart * @as(Vector, @splat(near.object.radius * push_apart)));
    objects.setPosition(&far.object, &far.drawn, between - apart * @as(Vector, @splat(far.object.radius * push_apart)));
    return true;
}

/// What damage counts as (`0x00463EE0`'s last argument). Kinds 0, 1 and 5 count toward
/// `recent_damage` (`counted`); 3 and 4 wreck a component with armour to spare (`heavyKind`).
pub const Kind = enum(i32) {
    /// The name scripts know these values by.
    pub const script_name = "DamageKind";

    /// A shot from a gun (`guns.bulletHit`).
    bullet = 0,
    /// A missile's hit, but a Screamer's (`missiles.collide`), and what an Imp's shockwave does to
    /// the shields (`shockwave.Shockwave.strike`).
    missile = 1,
    collision = 2,
    /// What a torpedo does to what it meets, 5001 (`objects_collide`), and to the part of a hull it
    /// strikes, 5001 (`collision_test_hull`).
    crash = 3,
    /// **Unknown.** Also 5001 from a torpedo striking a hull, to the hull part the hit passes on to
    /// (`collision_test_hull`).
    _unknown_4 = 4,
    /// A Screamer's hit.
    screamer = 5,
    _,
};

/// The quadrants an object's shields and armour are kept in, as `object_armor_conditions` reads
/// them.
pub const Quadrant = enum(u2) {
    left = 0,
    right = 1,
    fore = 2,
    aft = 3,
};

/// `damage_quadrant` (`0x00463CA0`): the quadrant a hit falls in, from where it lies in the
/// object's frame as a share of the object's bounds: whichever of along and across is the larger
/// share decides. For a point of the world, `damage_quadrant_world` (`0x00463D30`) turns it into
/// the object's frame first, as callers do with `placeAt(.now).inverse`.
pub fn quadrant(object: *const gameobj.GameObject, at: Vector) Quadrant {
    const across = at[0] / object.width();
    const along = at[2] / (object.bounds_max.z - object.bounds_min.z);
    if (@abs(across) <= @abs(along)) return if (along <= 0) .aft else .fore;
    return if (across > 0) .right else .left;
}

/// How much of a collision's impulse becomes damage, over the lighter of the two masses
/// (`0x004DC3F8`), and the share of that an object takes (`0x004DC408`).
const impulse_share: f32 = 0.2;
const taken_share: f32 = 0.5;
const damage_share: f32 = impulse_share * taken_share;

/// What the damage is scaled by while either object is held to another (`0x004DC4AC`).
const attached_damage: f32 = 0.02;

/// What a player's ship does to a friendly one (`0x004DC3D4`).
const friendly_damage: f32 = 0.25;

/// `collision_damage` (`0x00465CA0`): the damage two objects do each other as they meet. It
/// follows the impulse the shove handed them, over the lighter of the two masses, and lands on the
/// quadrant each was struck in (`knockDamage`). The Ripper takes none.
fn impact(world: gameobj.World, first: u16, second: u16, impulse: Vector, contact: Vector) void {
    const all = world.objects;
    const near = &all.slots[first].object;
    const far = &all.slots[second].object;
    var value = math.length(impulse) * damage_share / @min(near.mass, far.mass);
    if (near.flags.attached or far.flags.attached) value *= attached_damage;

    for ([_]u16{ first, second }, [_]u16{ second, first }, [_]Flare{ .before, .after }) |index, other, flare| {
        const object = &all.slots[index].object;
        if (object.type.base() == .ripper) continue;
        const struck = quadrant(object, object.placeAt(.now).inverse(contact));
        var share = value;
        // A player's ship is gentler with its own side.
        if (other == all.player and object.side == .friendly and index >= all.players) share *= friendly_damage;
        knockDamage(world, index, struck, share, share, other, contact, flare);
    }
}

/// When a knock's shield flares, as `shield.flare` checks the shields left: the game flares the
/// first of two objects that meet before its damage, and the second, and a ship meeting a hull,
/// after.
const Flare = enum { before, after };

/// What a knock does to one object (`collision_damage`, `collision_test_hull`): subtracts `drain`
/// from the struck player's shield reserve first. If the reserve still holds charge, the shield
/// takes no damage. Otherwise a shield that is down leaves the armour to take `value`; a shield
/// that is up takes the damage (`object_damage`) and flares at `contact`.
fn knockDamage(world: gameobj.World, index: u16, struck: Quadrant, value: f32, drain: f32, attacker: u16, contact: Vector, flare: Flare) void {
    const all = world.objects;
    const object = &all.slots[index].object;
    if (all.playerState(index)) |state| {
        if (state.shield_reserves.spare(struck, drain)) return;
    }
    if (object.shields.get(struck) < 0) return armorDamage(world, index, struck, value, attacker, .collision);
    if (flare == .before) shield.flare(world, index, contact);
    damage(world, index, struck, value, 1, attacker, .collision);
    if (flare == .after) shield.flare(world, index, contact);
}

/// The game's difficulty (`0x00562F14`), which SET GAME DIFFICULTY starts at medium and steps
/// through. It scales damage (`byDifficulty`).
pub const Difficulty = enum(i16) {
    easy = 0,
    medium = 1,
    hard = 2,
    _,

    /// How much harder a shot lands on a hostile object (`0x004DC4E0`, `0x004DC550`).
    fn onHostile(difficulty: Difficulty) f32 {
        return switch (difficulty) {
            .easy => 1.5,
            .hard => 0.75,
            else => 1,
        };
    }

    /// How much harder a hit lands on the player's ship, before `player_share`.
    fn onPlayer(difficulty: Difficulty) f32 {
        return switch (difficulty) {
            .easy => 0.75,
            .hard => 1.5,
            else => 1,
        };
    }
};

/// The share of a hit the player's ship takes, whatever the difficulty (`0x004DC408`).
const player_share: f32 = 0.5;

/// The mission's damage rules. Hosted missions use the bound ships as their pilots.
pub const DamageRules = union(enum) {
    /// The standalone campaign uses the local pilot's slot.
    campaign,
    /// The original starts network campaign missions on Easy (WinMain `0x004A99F3`).
    cooperative,
    /// Arenas use full damage by default. The host can opt into a difficulty grade.
    arena: ?Difficulty,
};

/// `damage_by_difficulty` (`0x00463D70`): damage as the difficulty scales it. A shot lands on a
/// hostile object harder the easier the game is, and anything that hits the player's ship lands
/// at half, then harder or softer by the difficulty: at medium, half as hard.
///
/// The game compares the damage's kind with the player's slot, which in a single-player game is 0,
/// a shot's kind; OpenReliant asks for a shot.
///
/// The original returns the incoming value when `multiplayer_mission` is set, as in the arenas.
pub fn byDifficulty(world: gameobj.World, index: u16, kind: Kind, value: f32) f32 {
    if (hooks.enter(.damage_by_difficulty, byDifficulty, .{ world, index, kind, value })) |result| return result;
    const all = world.objects;
    const difficulty: Difficulty = switch (world.damage_rules) {
        .campaign => world.difficulty,
        .cooperative => .easy,
        .arena => |grade| grade orelse return value,
    };
    const pilot = if (world.damage_rules == .campaign) index == all.player else all.playerBinding(index) != null;
    var scaled = value;
    // In an arena the same preset applies to pilots on either side.
    if (kind == .bullet and all.slots[index].object.side == .hostile and !(world.damage_rules == .arena and pilot)) {
        scaled *= difficulty.onHostile();
    }
    if (pilot) scaled *= difficulty.onPlayer() * player_share;
    return scaled;
}

/// `object_damage` (`0x00463EE0`): applies a hit to an object's shields, scaled by difficulty.
/// The unscaled damage that passes through, times `factor`, goes to the armour. A shield already
/// below zero adds its deficit to that damage. Invulnerability state `_unknown_4` preserves the
/// shields. Kinds 0, 1 and 5 count towards the recent damage used for retaliation.
///
/// Player hits on friends count towards Moose's warning (`friendly_fire.warn`). Smart targeting
/// selects what the player hits, except in collisions. Hits on the player shake the ship and
/// controller and start HUD interference. Finally, the object's ShotAt event is posted (`shotAt`).
///
/// Not ported: what a multiplayer game adds, the damage a network session keeps for the other
/// players among it (`net_quadrant_damage`, `0x004BA9F0`)
/// ([#55](https://github.com/OpenReliant/openreliant/issues/55)).
pub fn damage(world: gameobj.World, index: u16, struck: Quadrant, value: f32, factor: f32, attacker: u16, kind: Kind) void {
    damageFrom(world, index, struck, value, factor, .of(world.objects, attacker), kind);
}

/// The same damage with a retained source, including after its shooter has left the mission.
pub fn damageFrom(world: gameobj.World, index: u16, struck: Quadrant, value: f32, factor: f32, attacker: gameobj.DamageSource, kind: Kind) void {
    if (hooks.enter(.object_damage, damageFrom, .{ world, index, struck, value, factor, attacker, kind })) |done| return done;
    const all = world.objects;
    const object = &all.slots[index].object;
    const held = object.shields.at(struck);
    const blow = scaledBlow(world, index, struck, value, attacker, kind, held.* >= 0) orelse return;
    const scaled = blow.value;
    if (attacker.resolve(all)) |by| friendly_fire.warn(world, index, by, kind, scaled);
    const through = @max(value - held.*, 0);
    if (held.* >= 0 and object.invulnerable != ._unknown_4) held.* -= scaled;
    if (held.* < 0) armorDamageFrom(world, index, struck, through * factor, attacker, kind);
    all.slots[index].setAttacker(attacker.object);
    if (smartTargeting(world, attacker, kind)) |display| input.setPlayerTarget(display, all, @intCast(index), aigeneric.Target.whole, false);
    shotAt(world, index, attacker);
}

/// The ShotAt of a blow to the object in slot `index` by `attacker`, on the object itself
/// (`events.shotAt`), unless a collision's test against a hull runs again
/// (`events.Events.shots_held`).
fn shotAt(world: gameobj.World, index: u16, attacker: gameobj.DamageSource) void {
    if (world.events) |waiting| if (waiting.shots_held) return;
    events.shotAtFrom(world, index, attacker.object, null);
}

/// Holds back the ShotAt of the blows a collision deals, or lets it go again (`0x00545860`).
fn holdShots(world: gameobj.World, held: bool) void {
    if (world.events) |waiting| waiting.shots_held = held;
}

/// Starts shield and armour damage. Jumping objects take no hit. HUD interference comes before
/// the debris check. A hit that gets through is scaled, may trigger a radio taunt, and sends
/// impact feedback to the struck pilot. Shots, missiles and Screamers count toward recent damage.
fn scaledBlow(world: gameobj.World, index: u16, struck: Quadrant, value: f32, attacker: gameobj.DamageSource, kind: Kind, shielded: bool) ?struct { value: f32, audience: ?HitFeedback.Audience } {
    const all = world.objects;
    const slot = &all.slots[index];
    if (slot.object.flags.jumping) return null;
    const audience = HitFeedback.Audience.of(world, index);
    if (audience) |towards| towards.send(world, .interference);
    if (slot.combat) |combat| if (combat.class == .debris) return null;
    const scaled = byDifficulty(world, index, kind, value);
    const counts = counted(kind);
    if (audience) |towards| {
        if (counts and towards.matches(world, index)) {
            if (attacker.resolve(all)) |by| radio.enemyTaunt(world, by, towards);
        }
        towards.send(world, .{ .impact = .{ .struck = struck, .kind = kind, .value = scaled, .shielded = shielded } });
    }
    if (counts) slot.object.recent_damage += scaled;
    return .{ .value = scaled, .audience = audience };
}

/// The display, while smart targeting is on and the blow is the player's ship's but for a
/// collision; null otherwise.
fn smartTargeting(world: gameobj.World, attacker: gameobj.DamageSource, kind: Kind) ?*hud.State {
    const display = world.display orelse return null;
    if (attacker.resolve(world.objects) != world.objects.player or !display.smart_targeting or kind == .collision) return null;
    return display;
}

/// `object_armor_damage` (`0x004641F0`): applies damage to an object's armour after its shields
/// fail. Difficulty is applied twice: once to recent damage, then again to armour damage. At
/// medium difficulty the player's armour therefore takes a quarter of the hit.
///
/// Exploding objects take no more damage. Bullet hits on objects that list components only post
/// ShotAt here; `componentDamage` handles the actual hit. Invulnerability can prevent armour from
/// falling below zero, and state `_unknown_4` prevents all armour damage. Armour conditions and
/// warnings follow the hit. Armour below zero destroys the object (`ai.objectDestroyed`), with no
/// time for the player to eject if the hit exceeds `heavy_blow`.
///
/// Player hits on friends count towards Moose's warning. Destroying a friend sends the player
/// home. Smart targeting selects what the player hit, except in collisions. Hits mark the HUD's
/// ship or target quadrant and open the target display when appropriate. Finally, ShotAt is
/// posted, including for component hits while collision ShotAt events are held.
pub fn armorDamage(world: gameobj.World, index: u16, struck: Quadrant, value: f32, attacker: u16, kind: Kind) void {
    armorDamageFrom(world, index, struck, value, .of(world.objects, attacker), kind);
}

/// The same damage with a retained source, including after its shooter has left the mission.
pub fn armorDamageFrom(world: gameobj.World, index: u16, struck: Quadrant, value: f32, attacker: gameobj.DamageSource, kind: Kind) void {
    if (hooks.enter(.object_armor_damage, armorDamageFrom, .{ world, index, struck, value, attacker, kind })) |done| return done;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const blow = scaledBlow(world, index, struck, value, attacker, kind, false) orelse return;
    const scaled = blow.value;
    if (object.flags.exploding) return;
    if (attacker.resolve(all)) |by| friendly_fire.warn(world, index, by, kind, scaled);
    if (kind == .bullet and object.flags.components) return events.shotAtFrom(world, index, attacker.object, null);

    const shielded = object.invulnerable.protects(attacker.player);
    const worn = byDifficulty(world, index, kind, scaled);
    const armor = object.armor.at(struck);
    const left = armor.* - worn;
    const blocked = (left < 0 and shielded) or object.invulnerable == ._unknown_4;
    if (!blocked) armor.* = left;
    const taken = if (blocked) 0 else worn;
    if (slot.combat) |combat| {
        main.armorConditions(object, combat);
        if (blow.audience) |audience| audience.warnOfArmourDamage(world, index, combat);
    }
    all.slots[index].setAttacker(attacker.object);
    if (armor.* < 0) {
        ai.objectDestroyed(.of(world), index, true, taken > heavy_blow);
        if (attacker.resolve(all)) |by| if (friendly_fire.destroyedFriend(world, index, by, kind)) friendly_fire.friendDestroyed(world);
    }
    const current = &all.slots[all.player].orders[0].target;
    if (smartTargeting(world, attacker, kind) != null) current.* = current.retarget(all, @intCast(index), current.resolve(all).component);
    if (world.display) |display| {
        if (current.slotIn(all) == index) {
            _ = display.bringUp(hud.targetWindow(slot), false);
            display.events.target_hits.getPtr(struck).happen();
        }
    }
    if (blow.audience) |towards| towards.send(world, .{ .armour_hit = struck });
    shotAt(world, index, attacker);
}

/// A blow to the armour heavier than this leaves the player's ship no time to eject (`0x004DC44C`).
const heavy_blow: f32 = 1000;

/// **Improvement:** a hit's presentation effects follow the struck pilot's ship binding.
/// The local game applies them immediately. For admitted participants the host delivers them
/// through the sink, including on a host without any presentation.
pub const HitFeedback = union(enum) {
    interference,
    impact: Impact,
    armour_hit: Quadrant,
    armour_warning,
    own_hull_impact,
    hull_impact: Vector,
    radio_line: radio.RoutedLine,
    shockwave: f32,

    pub const Impact = struct {
        struck: Quadrant,
        kind: Kind,
        value: f32,
        shielded: bool,
    };

    pub const Addressed = struct {
        recipient: players.ControlRef,
        tick: i32,
        effect: HitFeedback,

        /// Applies an event for the current viewer. An old ship or admission cannot receive it.
        pub fn present(notice: Addressed, world: gameobj.World) bool {
            const all = world.objects;
            const viewer = all.playerBinding(all.player) orelse return false;
            if (!std.meta.eql(notice.recipient, viewer)) return false;
            notice.effect.show(world, notice.tick);
            return true;
        }
    };

    /// The host receives events in simulation order. The receiver can enqueue them for delivery.
    pub const Sink = struct {
        context: *anyopaque,
        enqueue: *const fn (*anyopaque, Addressed) void,

        pub fn send(sink: Sink, recipient: players.ControlRef, tick: i32, effect: HitFeedback) void {
            sink.enqueue(sink.context, .{ .recipient = recipient, .tick = tick, .effect = effect });
        }
    };

    pub const Audience = union(enum) {
        local,
        participant: players.ControlRef,

        fn of(world: gameobj.World, index: u16) ?Audience {
            const all = world.objects;
            if (world.damage_rules == .campaign and index == all.player and all.readsLocalPlayerInput()) return .local;
            if (world.hit_feedback == null) return null;
            return .{ .participant = all.playerBinding(index) orelse return null };
        }

        fn send(audience: Audience, world: gameobj.World, effect: HitFeedback) void {
            switch (audience) {
                .local => effect.show(world, world.clock.frame_start),
                .participant => |recipient| {
                    const sink = world.hit_feedback orelse return;
                    sink.send(recipient, world.clock.frame_start, effect);
                },
            }
        }

        pub fn matches(audience: Audience, world: gameobj.World, index: u16) bool {
            return switch (audience) {
                .local => world.objects.player == index,
                .participant => |recipient| if (world.objects.playerBinding(index)) |current|
                    std.meta.eql(recipient, current)
                else
                    false,
            };
        }

        fn warnOfArmourDamage(audience: Audience, world: gameobj.World, index: u16, combat: *const create.ShipCombat) void {
            const all = world.objects;
            if (!audience.matches(world, index) or (audience == .local and world.sounds == null)) return;
            const warned_at = &all.player_states[index].armor_warned_at;
            const now = world.clock.frame_start;
            if (!main.armorWarningDue(&all.slots[index].object, combat, now, warned_at.*)) return;
            warned_at.* = now;
            audience.send(world, .armour_warning);
        }
    };

    pub fn sendTo(effect: HitFeedback, world: gameobj.World, index: u16) void {
        if (Audience.of(world, index)) |audience| audience.send(world, effect);
    }

    fn show(effect: HitFeedback, world: gameobj.World, tick: i32) void {
        switch (effect) {
            .interference => if (world.display) |display| display.startInterference(world),
            .impact => |hit| feedback(world, hit.struck, hit.kind, hit.value, hit.shielded),
            .armour_hit => |struck| if (world.display) |display| {
                display.events.ship_hits.getPtr(struck).happen();
            },
            .armour_warning => betty.sayIn(world, .armor_failing),
            .own_hull_impact => shieldfx.playOwnHullHit(world),
            .hull_impact => |at| shieldfx.playHullHitAt(world, at),
            .radio_line => |*line| line.present(world, tick),
            .shockwave => |strength| {
                world.shake.* = @max(world.shake.*, @min(strength, camera.Cockpit.shake_most));
                if (world.forces) |forces| forces.startUnlessPlaying(.shock, world.clock.frame_start);
            },
        }
    }
};

/// How much each point of a hit's damage shakes the camera (`0x004DC500`), and the most a shot
/// shakes it to.
const shake_per_damage: f32 = 0.05;
const shot_shake_most: f32 = 1;

/// `damage_feedback` (`0x00463E10`): a blow of `value` on the `struck` side of the player's ship,
/// after the difficulty's scaling, where the shields took it or not, while the controller rumbles.
/// A shot's starts the shake from hits on the controller (`input.force.Forces.startUnlessPlaying`)
/// and, while the camera shakes less than `shot_shake_most`, shakes it more by `shake_per_damage`
/// of the damage, up to that. Any other pushes the ship (`input.force.Forces.hit`) and shakes the
/// camera as much more, up to `camera.Cockpit.shake_most`.
///
/// **Improvement:** the camera shakes whatever the controller (`input.force.HitShake.always`).
///
/// **Improvement:** a collision plays `landhard` on the controller, any other blow the shields take
/// `Shield`, and one on the hull the `Hullshock` of the side struck (`input.force.Unread.played`).
fn feedback(world: gameobj.World, struck: Quadrant, kind: Kind, value: f32, shielded: bool) void {
    const forces = world.forces;
    const settings = if (forces) |playing| playing.settings else input.force.Settings{};
    const rumbles = if (forces) |playing| playing.feedback else false;
    if (rumbles or settings.hit_shake == .always) {
        const shake = world.shake;
        const more = value * shake_per_damage;
        if (kind == .bullet) {
            if (shake.* < shot_shake_most) shake.* = @min(shake.* + more, shot_shake_most);
        } else {
            shake.* = @min(shake.* + more, camera.Cockpit.shake_most);
        }
    }
    const playing = forces orelse return;
    const now = world.clock.frame_start;
    if (kind == .bullet) playing.startUnlessPlaying(.shake, now) else playing.hit(struck, value);
    const unread: input.force.Effect = switch (kind) {
        .collision, .crash => .landhard,
        else => if (shielded) .shield else switch (struck) {
            .left => .hullshock,
            .right => .hullshock1,
            .fore => .hullshock2,
            .aft => .hullshock3,
        },
    };
    playing.start(unread, now);
}

/// The damage kinds that hurt a component with armour to spare, whatever its flags.
fn heavyKind(kind: Kind) bool {
    return switch (kind) {
        .crash, ._unknown_4 => true,
        else => false,
    };
}

/// The armour past which a component takes only a heavy hit, and how heavy that is (`0x9C3` and
/// `0x004DC4A8`).
const heavy_component: i32 = 0x9C3;
const heavy_hit: f32 = 500;

/// What a shield generator leaves of a hit below `shielded_hit` (`0x004DC3D4` and `0x004DC44C`).
const shielded_damage: f32 = 0.25;
const shielded_hit: f32 = 1000;

/// `component_damage` (`0x004645C0`): damage to one of an object's components, as the difficulty
/// scales it. A collision does none; guns, missiles and explosions do. Where the component belongs
/// to an assembly, such as a turret and its barrels, the damage goes to the first part of it that
/// still has armour, and a component whose armour runs out marks its model's root as destroyed,
/// for `objects.loseComponents` to act on. The player's hit on a friend not exploding mounts toward
/// Moose's warning (`friendly_fire.warn`), and one that destroys its component has the player sent
/// home (`friendly_fire.friendDestroyed`).
///
/// With smart targeting on, the player's hit on a hostile ship makes the component struck, if it
/// is one the ship lists, the player's target and subtarget, or else the ship alone, unless it is
/// already the target of the player's current order.
///
/// The part struck may be one of a model mounted on the object's: its assembly and its root are
/// that model's.
///
/// Last, whether or not the part took the hit, come the ShotAt events (`componentShotAt`).
///
/// Not ported: what a multiplayer game adds: the object's turrets turning on a player who strikes
/// it, and in a network session, a friend's engines kept from the player's hits and the damage the
/// session keeps for the other players (`net_component_damage`, `0x004BA810`)
/// ([#55](https://github.com/OpenReliant/openreliant/issues/55)).
pub fn componentDamage(world: gameobj.World, index: u16, struck_part: objects.PartRef, value: f32, attacker: u16, kind: Kind) void {
    componentDamageFrom(world, index, struck_part, value, .of(world.objects, attacker), kind);
}

/// The same damage with a retained source, including after its shooter has left the mission.
pub fn componentDamageFrom(world: gameobj.World, index: u16, struck_part: objects.PartRef, value: f32, attacker: gameobj.DamageSource, kind: Kind) void {
    if (hooks.enter(.component_damage, componentDamageFrom, .{ world, index, struck_part, value, attacker, kind })) |done| return done;
    const object = &world.objects.slots[index].object;
    if (object.flags.jumping or kind == .collision or struck_part.part().flags.damaged) return;
    wearComponent(world, index, struck_part, value, attacker, kind);
    componentShotAt(world, index, struck_part, attacker, kind);
}

/// `component_damage` (`0x00464A0A`)'s events for a hit on `struck_part`: the object's own ShotAt,
/// but for a hit of kind `_unknown_4`, then the ShotAt of the component the part counts against
/// (`objects.Model.countedAgainst`), where the object lists it (`create.Slot.componentIndex`), both
/// even while a collision's test against a hull runs again.
fn componentShotAt(world: gameobj.World, index: u16, struck_part: objects.PartRef, attacker: gameobj.DamageSource, kind: Kind) void {
    if (kind != ._unknown_4) events.shotAtFrom(world, index, attacker.object, null);
    const against = struck_part.model.countedAgainst(struck_part.index);
    const component = world.objects.slots[index].componentIndex(against) orelse return;
    events.shotAtFrom(world, index, attacker.object, component);
}

/// What `component_damage` does to the component `struck_part` belongs to, as `componentDamage`
/// describes it.
fn wearComponent(world: gameobj.World, index: u16, struck_part: objects.PartRef, value: f32, attacker: gameobj.DamageSource, kind: Kind) void {
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const model = struck_part.model;
    const component = struck_part.part();
    var share = byDifficulty(world, index, kind, value);
    if (!object.flags.exploding) if (attacker.resolve(all)) |by| friendly_fire.warn(world, index, by, kind, share);

    // The assembly's first part that has armour takes the hit.
    const struck = model.hitPart(component);
    if (struck.component_armor == 0) return;
    // A part with armour to spare takes only a heavy hit, and only a torpedo's unless its flags
    // let any kind's through (`0x00464798`).
    if (struck.component_armor > heavy_component) {
        if (share < heavy_hit) return;
        if (!struck.flags.heavy_hits and !heavyKind(kind)) return;
    }

    if (object.invulnerable != ._unknown_5 and object.flags.shield_generator and share < shielded_hit) share *= shielded_damage;
    const player_hit = attacker.player;
    var protected = object.invulnerable.protects(player_hit);
    // The game reads the invulnerability of the part that takes the hit, the assembly's first with
    // armour, rather than the part struck (`0x00464800`).
    if (std.mem.findScalar(?*objects.Model.Part, slot.listed(), struck)) |n| {
        protected = protected or slot.object.components[n].protects(player_hit);
    }

    const left = struck.armor - share;
    if (left >= 0 or !protected) struck.armor = left;
    all.slots[index].setAttacker(attacker.object);
    if (struck.armor < 0) {
        model.destroyed = true;
        if (attacker.resolve(all)) |by| if (friendly_fire.destroyedFriend(world, index, by, kind)) friendly_fire.friendDestroyed(world);
    }
    const display = smartTargeting(world, attacker, kind) orelse return;
    if (object.side != .hostile) return;
    if (std.mem.findScalar(?*objects.Model.Part, slot.listed(), struck)) |n| {
        input.setPlayerTarget(display, all, @intCast(index), @intCast(n), false);
    } else if (all.slots[all.player].orders[0].target.slotIn(all) != index) {
        input.setPlayerTarget(display, all, @intCast(index), aigeneric.Target.whole, false);
    }
}

/// Whether the damage counts toward what an object has taken lately, which `order_retaliate` reads,
/// and draws an enemy's taunt as it hits the player's ship: a shot's or a missile's.
fn counted(kind: Kind) bool {
    return switch (kind) {
        .bullet, .missile, .screamer => true,
        else => false,
    };
}

/// `objects_collide_parts` (`0x00465C50`), run up to nine times by `objects_collide`: a ship that
/// meets an object listing components is tested against that object's parts, not its sphere; a
/// torpedo once. The two are moved apart and tested again, the tests after the first holding back
/// the ShotAt of the knocks they deal (`holdShots`). Before each test, a ship that meets a training
/// hoop may fly through it (`throughHoop`). Two objects that both list components pass through each
/// other, as does anything meeting the limpet pod.
fn parts(world: gameobj.World, first: u16, second: u16, pass: u8) bool {
    const all = world.objects;
    if (all.slots[first].object.flags.components and all.slots[second].object.flags.components) return false;
    if (all.slots[first].object.type.base() == .limpet_pod or all.slots[second].object.type.base() == .limpet_pod) return false;
    const hull = if (all.slots[first].object.flags.components) first else second;
    const ship = if (hull == first) second else first;

    var tries: u8 = 0;
    while (tries < hull_passes) : (tries += 1) {
        if (all.slots[hull].object.type.base() == .training_hoop) throughHoop(world, ship, hull);
        if (!hullHit(world, ship, hull, pass)) break;
        holdShots(world, false);
        // A torpedo is gone once it has struck.
        if (className(all, ship) == .torpedo) return false;
        for ([_]u16{ ship, hull }) |index| motion.moveSlot(world, index);
        holdShots(world, true);
    }
    holdShots(world, false);
    return tries > 0 and tries < hull_passes;
}

/// How many times a pair is tested against a hull before the sweep gives up on it.
const hull_passes = 9;

/// `collision_test_hoop` (`0x00465B40`): where the ship in slot `ship` flies through the training
/// hoop in slot `hoop` this step (`crossesHoop`), the hoop has its JumpedThroughHoop
/// (`events.jumpedThroughHoop`).
fn throughHoop(world: gameobj.World, ship: u16, hoop: u16) void {
    const all = world.objects;
    if (crossesHoop(&all.slots[hoop].object, &all.slots[ship].object)) events.jumpedThroughHoop(world, hoop, ship);
}

/// Whether `flying` flies through the hoop `ring` this step: in the hoop's frame, it stands behind
/// the hoop's plane now and ahead of it next, crossing it within half the hoop's height of its
/// middle (`hoop_reach`).
fn crossesHoop(ring: *const gameobj.GameObject, flying: *const gameobj.GameObject) bool {
    const before = ring.placeAt(.now).inverse(flying.placeAt(.now).position);
    if (before[2] > 0) return false;
    const after = ring.placeAt(.next).inverse(flying.placeAt(.next).position);
    if (after[2] <= 0) return false;
    const step = after - before;
    const crossing = before + step * @as(Vector, @splat(-before[2] / step[2]));
    const reach = (ring.bounds_max.y - ring.bounds_min.y) * hoop_reach;
    return crossing[0] * crossing[0] + crossing[1] * crossing[1] < reach * reach;
}

test crossesHoop {
    // A hoop 200 high at the origin, facing +Z, standing still.
    var ring = std.mem.zeroes(gameobj.GameObject);
    ring.root.orientation = math.identity;
    ring.root.next_orientation = math.identity;
    ring.bounds_min.y = -100;
    ring.bounds_max.y = 100;
    var flying = std.mem.zeroes(gameobj.GameObject);
    // Through the middle from behind, it flies through.
    flying.root.position = .{ .x = 0, .y = 0, .z = -10 };
    flying.root.next_position = .{ .x = 0, .y = 0, .z = 10 };
    try std.testing.expect(crossesHoop(&ring, &flying));
    // From ahead, back through it, it doesn't.
    flying.root.position = .{ .x = 0, .y = 0, .z = 10 };
    flying.root.next_position = .{ .x = 0, .y = 0, .z = -10 };
    try std.testing.expect(!crossesHoop(&ring, &flying));
    // A path crossing the plane past the hoop's reach misses it; a slanting one crossing within it
    // goes through.
    flying.root.position = .{ .x = 120, .y = 0, .z = -10 };
    flying.root.next_position = .{ .x = 120, .y = 0, .z = 10 };
    try std.testing.expect(!crossesHoop(&ring, &flying));
    flying.root.position = .{ .x = 150, .y = 0, .z = -10 };
    flying.root.next_position = .{ .x = -30, .y = 0, .z = 20 };
    try std.testing.expect(crossesHoop(&ring, &flying));
    // A hoop turned about Y faces +X, so it's flown through along X.
    const turned = math.rotation(.y, std.math.pi / 2.0);
    ring.root.orientation = turned;
    ring.root.next_orientation = turned;
    flying.root.position = .{ .x = -10, .y = 0, .z = 0 };
    flying.root.next_position = .{ .x = 10, .y = 0, .z = 0 };
    try std.testing.expect(crossesHoop(&ring, &flying));
}

/// How far from its middle a hoop takes a ship through it, a share of its height (`0x004DC408`).
const hoop_reach: f32 = 0.5;

/// What a ship's shield reserve is drawn by for each point of damage a hull does it: the game draws
/// the reserve by the damage before the ship takes its share of it (`taken_share`).
const reserve_drain: f32 = 1 / taken_share;

/// `collision_test_hull` (`0x00465380`): first the player's ship is tested against the hull's
/// trigger polygons (`crossTriggers`). Then the nearest face of the hull to the ship's sphere: the
/// ship is shoved at its own centre and the hull at the face, so the hull turns about the hit and
/// the ship does not. A torpedo then strikes the hull (`torpedoStrikes`). Any other ship takes the
/// damage on the quadrant it was struck in (`knockDamage`); its shield reserve is drawn by twice
/// that, as the game halves the damage only once it has drawn the reserve. A force field the ship
/// hits glows whole (`shield.flareCapital`).
fn hullHit(world: gameobj.World, ship: u16, hull: u16, pass: u8) bool {
    crossTriggers(world, ship, hull);
    const all = world.objects;
    const model = if (all.slots[hull].model) |*live| live else return false;
    const object = &all.slots[hull].object;

    // The hull stands where this step is taking it, as the ship's sphere does.
    const at = all.slots[ship].object.nextPosition();
    const found = objects.hitSphere(model, object.placeAt(.next), at, all.slots[ship].object.radius) orelse return false;

    const contact = found.place.point(found.point);
    const normal = math.transform(found.place.orientation, found.normal);
    // The ship takes the shove at its own centre, the hull at the face it was hit on. The game
    // works the hull's lever out in the part's frame; OpenReliant uses the object's, which differs
    // only for a part its model animates.
    const lever = object.placeAt(.now).inverse(contact);
    const impulse = shoveAt(world, ship, hull, -normal, .{ @splat(0), lever }, pass) orelse return true;
    if (className(all, ship) == .torpedo) {
        torpedoStrikes(world, ship, hull, found.part);
        return true;
    }

    const hit = &all.slots[ship].object;
    const value = math.length(impulse) * damage_share / hit.mass;
    const struck = quadrant(hit, hit.placeAt(.now).inverse(contact));
    knockDamage(world, ship, struck, value, value * reserve_drain, hull, contact, .after);
    if (found.part.part().force_field) shield.flareCapital(world, hull, found.part, null);
    return true;
}

/// `collision_test_hull`'s first part (`0x0046539D`): where the ship in slot `ship` is the
/// player's, its step crossing a trigger polygon of one of the hull's parts (`objects.Trigger`),
/// from where it stands to where it goes next, each in the part's frame as the part stands then,
/// posts its InsideObject or its OutsideObject (`events.insideObject`); and where the hull is a
/// Stalag, the player's ship is inside it from then on, or no longer
/// (`create.Objects.in_stalag`). Only the Stalag's model ships trigger polygons.
fn crossTriggers(world: gameobj.World, ship: u16, hull: u16) void {
    const all = world.objects;
    if (ship != all.player) return;
    const slot = &all.slots[hull];
    const model = if (slot.model) |*live| live else return;
    const mover = &all.slots[ship].object;
    var children = model.rootChildren();
    while (children.next()) |child| {
        const data = model.partData(child.index) orelse continue;
        if (data.triggers.len == 0 or data.meshes.len == 0) continue;
        const now = model.placeOf(slot.object.placeAt(.now), child.part, .now) orelse continue;
        const next = model.placeOf(slot.object.placeAt(.next), child.part, .next) orelse continue;
        const from = now.inverse(mover.position());
        const to = next.inverse(mover.nextPosition());
        for (data.triggers) |polygon| {
            const trigger = objects.Trigger.of(polygon, data.meshes[0]) orelse continue;
            const way = trigger.crossing(from, to) orelse continue;
            if (slot.object.type.base() == .stalag) all.in_stalag = way == .inside;
            events.insideObject(world, ship, way == .inside);
        }
    }
}

/// An assembly part holding more armour than this passes a torpedo's hit on to no hull part
/// (`collision_test_hull`, `0x004657A6`).
const passing_armor: i32 = 999;

/// The part whose hit a torpedo passes on to no hull part: the Ulysses' fin (`0x004F7480`).
const ulysses_fin = "Ulysses Fin";

/// `collision_test_hull` (`0x004656CF`), for a torpedo that strikes a hull, which lists components:
/// the hull lurches (`lurch`), the part struck takes `torpedo_blow` as a crash, and a hull part the
/// hit passes on to (`passedTo`) takes it again, of kind `_unknown_4`. The torpedo is destroyed
/// (`object_destroyed`), taking no damage of its own.
fn torpedoStrikes(world: gameobj.World, torpedo: u16, hull: u16, struck: objects.PartRef) void {
    const ctx: aigeneric.Context = .of(world);
    lurch(ctx, torpedo, hull);
    componentDamage(world, hull, struck, torpedo_blow, torpedo, .crash);
    if (passedTo(world.objects, hull, struck)) |part| componentDamage(world, hull, part, torpedo_blow, torpedo, ._unknown_4);
    ai.objectDestroyed(ctx, torpedo, false, false);
}

/// A hull struck by a torpedo lurches away from it: one whose listing is not disabled
/// (`GameObject.Flags.listing_disabled`), unless it is lurching already, jumping or warping, takes
/// Make capship list left or right (`aifuncs.capshipList`), left where the torpedo came in
/// heading to its left.
fn lurch(ctx: aigeneric.Context, torpedo: u16, hull: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[hull];
    if (!slot.object.flags.components or slot.object.flags.listing_disabled) return;
    if (slot.current()) |entry| switch (entry.order) {
        .make_capship_list_left, .make_capship_list_right, .jump_out, .jump_in, .warp_out, .warp_in => return,
        else => {},
    };
    const heading = math.forward(all.slots[torpedo].object.placeAt(.now).orientation);
    const across = math.transformTransposed(slot.object.placeAt(.now).orientation, heading)[0];
    const side: aifuncs.Lurch = if (across < 0) .left else .right;
    _ = aigeneric.give(ctx, hull, side.order(), .none);
}

/// The hull part a torpedo's hit on `struck` passes on to, where it passes on at all: for a part of
/// an assembly holding no more than `passing_armor`, the first hull part the hull's model shows. A
/// part of the hull's own model passes on nothing where it is a hull part itself or the Ulysses'
/// fin, or where that hull part is of its own assembly.
fn passedTo(all: *create.Objects, hull: u16, struck: objects.PartRef) ?objects.PartRef {
    const part = struck.part();
    if (part.link_id == 0 or part.component_armor > passing_armor) return null;
    const model = if (all.slots[hull].model) |*own| own else return null;
    const own = struck.model == model;
    if (own) {
        if (part.class == .hull) return null;
        if (struck.data()) |record| if (std.mem.eql(u8, record.part.name(), ulysses_fin)) return null;
    }
    for (model.parts, 0..) |*candidate, index| {
        if (candidate.removed or candidate.hidden or candidate.class != .hull) continue;
        if (own and candidate.link_id == part.link_id) return null;
        return .{ .model = model, .index = index };
    }
    return null;
}

const testing = struct {
    /// An object at `at`, with a radius of its own and nothing flying it.
    fn ship(mission: *gameobj.testing.Mission, at: Vector, radius: f32) !u16 {
        const index = try mission.add(.of(.predator), at);
        mission.slot(index).object.radius = radius;
        mission.slot(index).motion = null;
        return index;
    }
};

test collide {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const world = mission.world();

    // Two ships of 1000 units, 400 apart: each ends 1100 from the point between them.
    const near = try testing.ship(&mission, .{ -200, 0, 0 }, 1000);
    const far = try testing.ship(&mission, .{ 200, 0, 0 }, 1000);
    try std.testing.expect(collide(world, near, far, 0));
    try std.testing.expectApproxEqAbs(-1100, all.slots[near].object.root.position.x, 0.01);
    try std.testing.expectApproxEqAbs(1100, all.slots[far].object.root.position.x, 0.01);
    // What is drawn moves with them.
    try std.testing.expectApproxEqAbs(-1100, all.slots[near].drawn.position[0], 0.01);

    // Once they are clear of each other, nothing moves them.
    const held = all.slots[near].object.root.position.x;
    try std.testing.expect(collide(world, near, far, 0));
    try std.testing.expectEqual(held, all.slots[near].object.root.position.x);
}

test "a collision shoves both ships" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const world = mission.world();

    // Two ships of the same mass, the first flying into the second.
    const near = try testing.ship(&mission, .{ -900, 0, 0 }, 1000);
    const far = try testing.ship(&mission, .{ 900, 0, 0 }, 1000);
    for ([_]u16{ near, far }) |index| {
        all.slots[index].object.mass = 1000;
        all.slots[index].object.angular_response = math.identity;
    }
    all.slots[near].object.velocity = .{ .x = 100, .y = 0, .z = 0 };
    all.slots[near].object.root.next_position = .{ .x = -800, .y = 0, .z = 0 };

    try std.testing.expect(collide(world, near, far, 0));
    // The one that ran in is thrown back, and the one it struck is pushed on.
    try std.testing.expect(all.slots[near].object.velocity.x < 100);
    try std.testing.expect(all.slots[far].object.velocity.x > 0);
    // What one takes, the other gives: the two shares of the momentum match.
    const given = 100 - all.slots[near].object.velocity.x;
    try std.testing.expectApproxEqAbs(given, all.slots[far].object.velocity.x, 1e-3);
    // Neither is set spinning: the point two spheres meet at lies on the line between their
    // centres, so the shove has no lever to turn them by. A hull's own faces do (#143).
    try std.testing.expectEqual(0, all.slots[near].object.rotation[1]);
    try std.testing.expectEqual(0, all.slots[far].object.rotation[1]);

    // An object held to another takes no shove.
    all.slots[far].object.flags.attached = true;
    all.slots[far].object.velocity = .zero;
    objects.setPosition(&all.slots[near].object, &all.slots[near].drawn, .{ -900, 0, 0 });
    objects.setPosition(&all.slots[far].object, &all.slots[far].drawn, .{ 900, 0, 0 });
    all.slots[near].object.velocity = .{ .x = 100, .y = 0, .z = 0 };
    try std.testing.expect(collide(world, near, far, 0));
    try std.testing.expectEqual(0, all.slots[far].object.velocity.x);
}

test "a ship that meets a hull is shoved off the face it hit" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const all = mission.objects;
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    model.withHull();
    const world = mission.world();

    // A hull of one square part, and a ship flying into its face.
    // The inverse inertia of a body of this mass, about 6 / (mass * size squared), which is what
    // `recentre` works out from a model's parts.
    const hull_turn: math.Matrix = @splat(0);
    const hull = try mission.addWith(model.types(), .of(.predator), @splat(0));
    all.slots[hull].object.flags.components = true;
    all.slots[hull].object.mass = 100000;
    all.slots[hull].object.angular_response = hull_turn;
    all.slots[hull].object.angular_response[0] = 6e-9;
    all.slots[hull].object.angular_response[4] = 6e-9;
    all.slots[hull].object.angular_response[8] = 6e-9;
    all.slots[hull].motion = null;
    // The ship meets the face off to one side, so the hit has a lever on the hull.
    const ship = try mission.add(.of(.predator), .{ 60, 0, -60 });
    all.slots[ship].object.radius = 100;
    all.slots[ship].object.mass = 1000;
    all.slots[ship].object.angular_response = .{ 6e-7, 0, 0, 0, 6e-7, 0, 0, 0, 6e-7 };
    all.slots[ship].motion = null;
    all.slots[ship].object.velocity = .{ .x = 0, .y = 0, .z = 40 };
    all.slots[ship].object.root.next_position = .{ .x = 60, .y = 0, .z = -20 };

    try std.testing.expect(collide(world, ship, hull, 0));
    // It is thrown back off the face, which faces along -Z, and the hull is pushed the other way.
    try std.testing.expect(all.slots[ship].object.velocity.z < 40);
    try std.testing.expect(all.slots[hull].object.velocity.z > 0);
    // The hull turns about the hit, which the ship does not: it is shoved at its own centre.
    try std.testing.expect(all.slots[hull].object.yaw_rate != 0 or all.slots[hull].object.pitch_rate != 0);
    try std.testing.expectEqual(0, all.slots[ship].object.yaw_rate);

    // A ship nowhere near the hull meets nothing.
    objects.setPosition(&all.slots[ship].object, &all.slots[ship].drawn, .{ 0, 0, -5000 });
    all.slots[ship].object.velocity = .zero;
    try std.testing.expect(!collide(world, ship, hull, 0));

    // Two hulls pass through each other.
    all.slots[ship].object.flags.components = true;
    try std.testing.expect(!collide(world, ship, hull, 0));
}

test "a torpedo that strikes a hull is gone, and the hull lurches" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const all = mission.objects;
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    model.withHull();
    model.data[0].part.flags.component = true;
    model.data[0].part.component_armor = 20000;
    const world = mission.world();

    // The player's ship, then a hull of one square part, and a torpedo flying straight into its
    // face.
    _ = try mission.add(.of(.kamov), .{ 0, 50000, 0 });
    const hull = try mission.addWith(model.types(), .of(.mammoth), @splat(0));
    all.slots[hull].object.flags.components = true;
    all.slots[hull].object.mass = 100000;
    all.slots[hull].motion = null;
    const torpedo = try mission.add(.of(.russian_torpedo), .{ 60, 0, -60 });
    mission.tables.combat[@backingInt(gameobj.GameType.russian_torpedo)].class = .torpedo;
    all.slots[torpedo].object.radius = 100;
    all.slots[torpedo].object.mass = 1000;
    all.slots[torpedo].motion = null;
    all.slots[torpedo].object.velocity = .{ .x = 0, .y = 0, .z = 40 };
    all.slots[torpedo].object.root.next_position = .{ .x = 60, .y = 0, .z = -20 };

    // Struck once, the pair is not tested again. The part struck takes the blow, the torpedo is
    // destroyed, taking nothing itself, and the hull lurches to the right of it.
    try std.testing.expect(!collide(world, torpedo, hull, 0));
    try std.testing.expectEqual(20000 - torpedo_blow, all.slots[hull].model.?.parts[0].armor);
    try std.testing.expect(all.slots[torpedo].object.flags.exploding);
    try std.testing.expectEqual(.make_capship_list_right, all.slots[hull].current().?.order);
    // Struck again while it lurches, it lurches no more.
    const again = try mission.add(.of(.russian_torpedo), .{ 60, 0, -60 });
    all.slots[again].object.radius = 100;
    all.slots[again].motion = null;
    all.slots[again].object.root.next_position = .{ .x = 60, .y = 0, .z = -20 };
    _ = collide(world, again, hull, 0);
    try std.testing.expectEqual(1, all.slots[hull].object.order_count);
}

test passedTo {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    _ = try mission.add(.of(.kamov), @splat(0));
    const hull = try mission.addWith(model.types(), .of(.mammoth), @splat(0));
    const live = &mission.objects.slots[hull].model.?;
    const struck: objects.PartRef = .{ .model = live, .index = 0 };
    // A part of no assembly, or of too much armour, passes nothing on.
    live.parts[0].class = .turret;
    try std.testing.expectEqual(null, passedTo(mission.objects, hull, struck));
    live.parts[0].link_id = 2;
    live.parts[0].component_armor = passing_armor + 1;
    try std.testing.expectEqual(null, passedTo(mission.objects, hull, struck));
    // One light enough passes it on to the first hull part shown, unless that is of its own
    // assembly; the model's one part is not a hull part, so there is none.
    live.parts[0].component_armor = passing_armor;
    try std.testing.expectEqual(null, passedTo(mission.objects, hull, struck));
    // A hull part struck passes nothing on.
    live.parts[0].class = .hull;
    try std.testing.expectEqual(null, passedTo(mission.objects, hull, struck));
}

test "damage from a removed shooter still lands without crediting its replacement" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const player = try mission.add(.of(.predator), @splat(0));
    const victim = try mission.add(.of(.sabre), .{ 0, 0, 1000 });
    const slot = mission.slot(victim);
    slot.object.side = .friendly;
    slot.object.shields = .all(100);
    const source: gameobj.DamageSource = .of(all, player);
    create.resetSlot(mission.orders(), player);
    _ = try create.createObject(all, &mission.tables, create.testing.no_models, player, .of(.predator), 0, @splat(0), &mission.random);

    damageFrom(mission.world(), victim, .fore, 20, 1, source, .bullet);
    try std.testing.expectEqual(80, slot.object.shields.fore);
    try std.testing.expectEqual(0, mission.player.friendly_fire.damage);
    try std.testing.expectEqual(source.object, slot.last_attacker.?);
    try std.testing.expectEqual(null, slot.attacker(all));
    // Retaliation must not pick the new ship, even when it is an eligible enemy fighter.
    mission.slot(player).object.side = .hostile;
    mission.slot(player).object.flags.targetable = true;
    slot.object.recent_damage = 10000;
    _ = try aigeneric.push(mission.orders(), victim, .slow_rotate, .none);
    aigeneric.retaliate(mission.orders(), victim);
    try std.testing.expectEqual(.slow_rotate, slot.current().?.order);
    // Killing an enemy with the old source does not give the replacement player a kill.
    slot.object.side = .hostile;
    slot.object.armor = .all(1);
    armorDamageFrom(mission.world(), victim, .fore, 20, source, .missile);
    @import("aiexplode.zig").killCredit(mission.world(), victim);
    try std.testing.expectEqual(0, mission.player.kills.count);
}

test damage {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const world = mission.world();
    // The player's ship, in the first slot, and another, which the difficulty leaves alone.
    _ = try mission.add(.of(.predator), @splat(0));
    const index = try testing.ship(&mission, .{ 0, 0, 1000 }, 1000);
    const object = &all.slots[index].object;
    object.shields = .{ .left = 10, .right = 10, .fore = 10, .aft = 10 };
    object.armor = .{ .left = 20, .right = 20, .fore = 20, .aft = 20 };

    // The shield takes it first.
    damage(world, index, .fore, 4, 1, 1, .collision);
    try std.testing.expectEqual(6, object.shields.fore);
    try std.testing.expectEqual(20, object.armor.fore);
    try std.testing.expectEqual(1, object.last_attacker.index());

    // Past the shield, the rest wears the armour, and the armour's conditions follow.
    damage(world, index, .fore, 10, 1, 1, .collision);
    try std.testing.expect(object.shields.fore < 0);
    try std.testing.expectEqual(16, object.armor.fore);
    try std.testing.expect(object.gun_condition < 1);

    // A collision is not what sends a ship after its attacker; a shot is. What passes a shield
    // that is already down carries the shield's deficit with it, so the armour takes both.
    try std.testing.expectEqual(0, object.recent_damage);
    damage(world, index, .fore, 1, 1, 1, .bullet);
    try std.testing.expectEqual(6, object.recent_damage);

    // Debris takes none, and neither does a ship that is jumping.
    const left = object.armor.fore;
    mission.tables.combat[0].class = .debris;
    damage(world, index, .fore, 100, 1, 1, .collision);
    try std.testing.expectEqual(left, object.armor.fore);
    mission.tables.combat[0].class = .fighter;
    object.flags.jumping = true;
    damage(world, index, .fore, 100, 1, 1, .collision);
    try std.testing.expectEqual(left, object.armor.fore);
}

test "smart targeting takes what the player's ship hits" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const player = try mission.add(.of(.predator), @splat(0));
    try std.testing.expect(try @import("aigeneric.zig").push(mission.orders(), player, .player_control, .none));
    const index = try testing.ship(&mission, .{ 0, 0, 1000 }, 1000);
    const object = &all.slots[index].object;
    object.flags.targetable = true;
    object.shields = .all(100);
    var display: hud.State = .{};
    var world = mission.world();
    world.display = &display;
    const target = &all.slots[player].orders[0].target;

    // Off, a shot takes nothing.
    damage(world, index, .fore, 1, 1, player, .bullet);
    try std.testing.expectEqual(-1, target.resolve(all).index);
    // On, a collision takes nothing either, and another's shot nothing.
    display.smart_targeting = true;
    damage(world, index, .fore, 1, 1, player, .collision);
    damage(world, index, .fore, 1, 1, index, .bullet);
    try std.testing.expectEqual(-1, target.resolve(all).index);
    // The player's shot makes it the target, and brings up the target display.
    damage(world, index, .fore, 1, 1, player, .bullet);
    try std.testing.expectEqual(@as(i32, index), target.resolve(all).index);
    try std.testing.expectEqual(index, display.target.?.slot);
    try std.testing.expect(display.windows.up(.target));

    // Past its shields, a hit on the target marks the quadrant it wore, for the target display;
    // one on the player's ship marks the player's.
    armorDamage(world, index, .left, 1, player, .bullet);
    try std.testing.expectEqual(1, display.events.target_hits.get(.left).count);
    try std.testing.expectEqual(0, display.events.target_hits.get(.fore).count);
    all.slots[player].object.armor = .all(100);
    armorDamage(world, player, .aft, 1, index, .bullet);
    try std.testing.expectEqual(1, display.events.ship_hits.get(.aft).count);
}

test knockDamage {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const world = mission.world();
    const player = try testing.ship(&mission, @splat(0), 100);
    const other = try testing.ship(&mission, .{ 0, 0, 1000 }, 100);
    const object = &mission.slot(player).object;
    const bubble = mission.slot(player).shield.?;
    object.shields = .all(50);
    object.armor = .all(50);
    mission.objects.player_states[mission.objects.player].shield_reserves = .{ .fore = 20, .aft = 0 };

    // The fore reserve takes the knock while it holds, and nothing else happens.
    knockDamage(world, player, .fore, 10, 10, other, .{ 0, 0, 100 }, .after);
    try std.testing.expectEqual(10, mission.objects.player_states[mission.objects.player].shield_reserves.fore);
    try std.testing.expectEqual(50, object.shields.fore);
    try std.testing.expectEqual(null, bubble.struck);
    // Once it runs out, the shield takes the whole knock, halved at medium, and flares.
    knockDamage(world, player, .fore, 30, 30, other, .{ 0, 0, 100 }, .after);
    try std.testing.expectEqual(0, mission.objects.player_states[mission.objects.player].shield_reserves.fore);
    try std.testing.expectEqual(35, object.shields.fore);
    try std.testing.expectEqual(mission.clock.frame_start, bubble.struck);
    // With the shield down the armour takes it, twice halved, and nothing flares.
    bubble.struck = null;
    object.shields.aft = -1;
    knockDamage(world, player, .aft, 40, 40, other, .{ 0, 0, -100 }, .after);
    try std.testing.expectEqual(40, object.armor.aft);
    try std.testing.expectEqual(null, bubble.struck);
}

test armorDamage {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const world = mission.world();
    // The player's ship, in the first slot, and another.
    _ = try mission.add(.of(.predator), @splat(0));
    const index = try testing.ship(&mission, .{ 0, 0, 1000 }, 1000);
    const object = &all.slots[index].object;
    object.armor = .{ .left = 20, .right = 20, .fore = 20, .aft = 20 };

    // An invulnerable ship takes what it has armour to spare for, and no more.
    object.invulnerable = .full;
    armorDamage(world, index, .fore, 15, 0, .bullet);
    try std.testing.expectEqual(5, object.armor.fore);
    armorDamage(world, index, .fore, 15, 0, .bullet);
    try std.testing.expectEqual(5, object.armor.fore);
    try std.testing.expect(!object.flags.exploding);

    // Armour below zero destroys it.
    object.invulnerable = .none;
    armorDamage(world, index, .fore, 15, 0, .bullet);
    try std.testing.expect(object.flags.exploding);
    try std.testing.expectEqual(.explode, all.slots[index].orders[0].order);
    try std.testing.expect(all.slots[index].orders[0].data.destroyed.may_spin);
}

test byDifficulty {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    var world = mission.world();
    const player = try mission.add(.of(.predator), @splat(0));
    const enemy = try mission.add(.of(.sabre), .{ 0, 0, 1000 });
    try std.testing.expectEqual(.hostile, all.slots[enemy].object.side);

    // At medium, the player's ship takes half, and nothing else changes.
    try std.testing.expectEqual(50, byDifficulty(world, player, .bullet, 100));
    try std.testing.expectEqual(50, byDifficulty(world, player, .collision, 100));
    try std.testing.expectEqual(100, byDifficulty(world, enemy, .bullet, 100));
    // Easy: the player's ship takes three eighths, and a shot lands harder on the enemy.
    world.difficulty = .easy;
    try std.testing.expectEqual(37.5, byDifficulty(world, player, .bullet, 100));
    try std.testing.expectEqual(150, byDifficulty(world, enemy, .bullet, 100));
    try std.testing.expectEqual(100, byDifficulty(world, enemy, .collision, 100));
    // Hard: three quarters on the player's ship, and a shot lands softer on the enemy.
    world.difficulty = .hard;
    try std.testing.expectEqual(75, byDifficulty(world, player, .bullet, 100));
    try std.testing.expectEqual(75, byDifficulty(world, enemy, .bullet, 100));

    // The armour's damage scales it twice: at medium the player's armour takes a quarter, and what
    // it has taken lately counts half.
    world.difficulty = .medium;
    const object = &all.slots[player].object;
    object.armor = .all(100);
    armorDamage(world, player, .fore, 40, enemy, .bullet);
    try std.testing.expectEqual(90, object.armor.fore);
    try std.testing.expectEqual(20, object.recent_damage);
}

test "hosted damage rules do not depend on the viewer" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var world = mission.world();
    const all = world.objects;
    const first = try mission.add(.of(.predator), @splat(0));
    const second = try mission.add(.of(.predator), .{ 0, 0, 1000 });
    const enemy = try mission.add(.of(.sabre), .{ 0, 0, 2000 });
    all.players = 2;
    for ([_]u16{ first, second }) |index| {
        const pilot = all.joinParticipant(index).?;
        _ = all.bindParticipant(pilot, .of(all, index)).?;
    }

    all.slots[second].object.side = .hostile;
    world.difficulty = .hard;
    for ([_]u16{ first, second, enemy }) |viewer| {
        all.player = viewer;
        world.damage_rules = .cooperative;
        try std.testing.expectEqual(37.5, byDifficulty(world, first, .collision, 100));
        try std.testing.expectEqual(37.5, byDifficulty(world, second, .collision, 100));
        try std.testing.expectEqual(150, byDifficulty(world, enemy, .bullet, 100));
        world.damage_rules = .{ .arena = null };
        try std.testing.expectEqual(100, byDifficulty(world, first, .collision, 100));
        try std.testing.expectEqual(100, byDifficulty(world, second, .bullet, 100));
        try std.testing.expectEqual(100, byDifficulty(world, enemy, .bullet, 100));
        world.damage_rules = .{ .arena = .hard };
        try std.testing.expectEqual(75, byDifficulty(world, first, .bullet, 100));
        try std.testing.expectEqual(75, byDifficulty(world, second, .bullet, 100));
        try std.testing.expectEqual(75, byDifficulty(world, enemy, .bullet, 100));
    }
}

test quadrant {
    var object = gameobj.testing.object();
    object.bounds_min = .{ .x = -100, .y = -50, .z = -400 };
    object.bounds_max = .{ .x = 100, .y = 50, .z = 400 };
    // Along the ship counts for more than across it, so the nose and tail win the middle ground.
    try std.testing.expectEqual(.fore, quadrant(&object, .{ 0, 0, 300 }));
    try std.testing.expectEqual(.aft, quadrant(&object, .{ 0, 0, -300 }));
    try std.testing.expectEqual(.right, quadrant(&object, .{ 90, 0, 10 }));
    try std.testing.expectEqual(.left, quadrant(&object, .{ -90, 0, 10 }));
}

test componentDamage {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const all = mission.objects;
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    model.data[0].part.flags.component = true;
    model.data[0].part.component_armor = 100;
    const world = mission.world();

    // The player's ship, in the first slot, and another, which the difficulty leaves alone. The
    // player's is of another type, whose model the test's types don't give.
    _ = try mission.add(.of(.kamov), @splat(0));
    const index = try mission.addWith(model.types(), .of(.predator), @splat(0));
    const part = &all.slots[index].model.?.parts[0];
    const struck: objects.PartRef = .{ .model = &all.slots[index].model.?, .index = 0 };
    try std.testing.expectEqual(100, part.armor);

    // A collision does none, whatever it lands on.
    componentDamage(world, index, struck, 40, 1, .collision);
    try std.testing.expectEqual(100, part.armor);

    // A shot wears it down, and the attacker is recorded.
    componentDamage(world, index, struck, 40, 1, .bullet);
    try std.testing.expectEqual(60, part.armor);
    try std.testing.expectEqual(1, all.slots[index].object.last_attacker.index());

    // Past its armour, its model's root is marked destroyed.
    componentDamage(world, index, struck, 100, 1, .bullet);
    try std.testing.expect(part.armor < 0);
    try std.testing.expect(all.slots[index].model.?.destroyed);

    // A part with armour to spare takes only a heavy hit, and only a torpedo's, unless its flags
    // let any kind's through, as a Jack Hammer's breaks the Latov's shaft. The flag for light maps
    // has nothing to do with it.
    part.component_armor = 20000;
    part.armor = 20000;
    componentDamage(world, index, struck, 100, 1, .bullet);
    try std.testing.expectEqual(20000, part.armor);
    componentDamage(world, index, struck, 600, 1, .crash);
    try std.testing.expectEqual(19400, part.armor);
    part.flags.lightmap = true;
    componentDamage(world, index, struck, 600, 1, .missile);
    try std.testing.expectEqual(19400, part.armor);
    part.flags.heavy_hits = true;
    componentDamage(world, index, struck, 100, 1, .missile);
    try std.testing.expectEqual(19400, part.armor);
    componentDamage(world, index, struck, 600, 1, .missile);
    try std.testing.expectEqual(18800, part.armor);

    // Listed component protection prevents a lethal hit, but still permits nonlethal wear.
    all.slots[index].components[0] = part;
    all.slots[index].object.component_count = 1;
    part.component_armor = 100;
    part.armor = 100;
    all.slots[index].object.components[0].invulnerable = @backingInt(gameobj.Invulnerability.full);
    componentDamage(world, index, struck, 40, 1, .bullet);
    try std.testing.expectEqual(60, part.armor);
    componentDamage(world, index, struck, 100, 1, .bullet);
    try std.testing.expectEqual(60, part.armor);
    all.slots[index].object.components[0].invulnerable = @backingInt(gameobj.Invulnerability.player_can_hit);
    componentDamage(world, index, struck, 100, 1, .bullet);
    try std.testing.expectEqual(60, part.armor);
    componentDamage(world, index, struck, 100, 0, .bullet);
    try std.testing.expect(part.armor < 0);
    // A halfword past the byte is none of the values, and keeps off nothing.
    part.armor = 100;
    all.slots[index].object.components[0].invulnerable = 0x102;
    componentDamage(world, index, struck, 150, 1, .bullet);
    try std.testing.expect(part.armor < 0);
}

test goOff {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const world = mission.world();
    _ = try mission.add(.of(.predator), .{ 0, 0, -100000 });

    // The test's stats make every type a fighter; a torpedo, of a type of its own, strikes one's
    // fore quadrant and goes off itself.
    const ship = try testing.ship(&mission, @splat(0), 1000);
    const torpedo = try testing.ship(&mission, .{ 100, 0, 0 }, 1000);
    mission.tables.combat[1].class = .torpedo;
    all.slots[torpedo].object.type = @fromBackingInt(1);
    all.slots[torpedo].combat = &mission.tables.combat[1];
    const shielded = all.slots[ship].object.shields.fore;
    try std.testing.expect(collide(world, ship, torpedo, 0));
    try std.testing.expect(all.slots[ship].object.shields.fore < shielded);
    try std.testing.expectEqual(ship, all.slots[ship].object.last_attacker.index());
    try std.testing.expectEqual(.explode, all.slots[torpedo].current().?.order);

    // A mine goes off against a fighter, which is not pushed.
    const mine = try testing.ship(&mission, .{ 0, 100, 0 }, 1000);
    mission.tables.combat[2].class = .mine;
    all.slots[mine].object.type = @fromBackingInt(2);
    all.slots[mine].combat = &mission.tables.combat[2];
    all.slots[ship].object.shields.fore = 1000;
    try std.testing.expect(!collide(world, ship, mine, 0));
    try std.testing.expectApproxEqAbs(1000 - mine_blow, all.slots[ship].object.shields.fore, 1);
    try std.testing.expectEqual(.explode, all.slots[mine].current().?.order);
    try std.testing.expectEqual(0, all.slots[ship].object.root.position.x);
}

test "what never collides" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const world = mission.world();

    // The test's stats make every type a fighter; two pieces of debris pass through each other.
    const near = try testing.ship(&mission, @splat(0), 1000);
    const far = try testing.ship(&mission, .{ 100, 0, 0 }, 1000);
    mission.tables.combat[0].class = .debris;
    try std.testing.expect(!collide(world, near, far, 0));

    // So do a torpedo and another object of its own type.
    mission.tables.combat[0].class = .torpedo;
    try std.testing.expect(!collide(world, near, far, 0));

    // A torpedo of another type goes off against it instead of pushing it.
    mission.tables.combat[1].class = .fighter;
    all.slots[far].object.type = @fromBackingInt(1);
    all.slots[far].combat = &mission.tables.combat[1];
    try std.testing.expect(collide(world, near, far, 0));
    try std.testing.expectEqual(0, all.slots[near].object.root.position.x);

    // An object that lists components is met by its parts, which aren't ported, so nothing comes
    // of it.
    mission.tables.combat[0].class = .fighter;
    all.slots[far].object.flags.components = true;
    try std.testing.expect(!collide(world, near, far, 0));
    try std.testing.expectEqual(0, all.slots[near].object.root.position.x);
}

test crossTriggers {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const all = mission.objects;
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    // The square part's face is a trigger polygon, facing along +Z.
    var polygons = [_]@import("../../formats/shp.zig").TriggerPolygon{.{ .vertices = .{ 0, 1, 2, 3 } }};
    model.data[0].triggers = &polygons;
    const world = mission.world();
    const player = try mission.add(.of(.predator), .{ 0, 0, 50 });
    const stalag = try mission.addWith(model.types(), .of(.stalag), @splat(0));
    const other = try mission.add(.of(.predator), .{ 0, 0, 50 });
    const ship = &all.slots[player].object;

    // The player's ship going through it from the front is inside the Stalag, whose turrets then
    // aim anywhere; going back out, it isn't.
    ship.root.next_position = .{ .x = 0, .y = 0, .z = -50 };
    crossTriggers(world, player, stalag);
    try std.testing.expect(all.in_stalag and all.holdsPlayer(stalag) and !all.holdsPlayer(player));
    ship.root.position = .{ .x = 0, .y = 0, .z = -50 };
    ship.root.next_position = .{ .x = 0, .y = 0, .z = 50 };
    crossTriggers(world, player, stalag);
    try std.testing.expect(!all.in_stalag);
    // Passing beside it, or another ship going through it, does nothing.
    ship.root.position = .{ .x = 500, .y = 0, .z = 50 };
    ship.root.next_position = .{ .x = 500, .y = 0, .z = -50 };
    crossTriggers(world, player, stalag);
    all.slots[other].object.root.next_position = .{ .x = 0, .y = 0, .z = -50 };
    crossTriggers(world, other, stalag);
    try std.testing.expect(!all.in_stalag);
}

test "a knock draws only on the struck player's reserves" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const first = try testing.ship(&mission, @splat(0), 100);
    const second = try testing.ship(&mission, .{ 0, 0, 1000 }, 100);
    const ordinary = try testing.ship(&mission, .{ 0, 0, 2000 }, 100);
    all.players = 2;
    all.player = second;
    all.playerState(first).?.shield_reserves.fore = 20;
    all.playerState(second).?.shield_reserves.fore = 100;
    all.player_states[ordinary].shield_reserves.fore = 100;
    all.slots[first].object.shields = .all(50);
    all.slots[ordinary].object.shields = .all(50);
    knockDamage(mission.world(), first, .fore, 10, 10, ordinary, .{ 0, 0, 100 }, .after);
    try std.testing.expectEqual(10, all.playerState(first).?.shield_reserves.fore);
    try std.testing.expectEqual(100, all.playerState(second).?.shield_reserves.fore);
    try std.testing.expectEqual(50, all.slots[first].object.shields.fore);
    knockDamage(mission.world(), ordinary, .fore, 10, 10, first, .{ 0, 0, 2100 }, .after);
    try std.testing.expectEqual(40, all.slots[ordinary].object.shields.fore);
    try std.testing.expectEqual(100, all.player_states[ordinary].shield_reserves.fore);
}

test "hit feedback follows the struck participant and rejects an old binding" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var world = mission.world();
    const all = world.objects;
    const first = try mission.add(.of(.predator), @splat(0));
    const second = try mission.add(.of(.sabre), .{ 0, 0, 1000 });
    const attacker = try mission.add(.of(.sabre), .{ 0, 0, 2000 });
    all.players = 2;
    const first_pilot = all.joinParticipant(first).?;
    const second_pilot = all.joinParticipant(second).?;
    const first_binding = all.bindParticipant(first_pilot, .of(all, first)).?;
    const second_binding = all.bindParticipant(second_pilot, .of(all, second)).?;

    const Recorded = struct {
        events: [8]HitFeedback.Addressed = undefined,
        count: usize = 0,

        fn enqueue(context: *anyopaque, notice: HitFeedback.Addressed) void {
            const recorded: *@This() = @ptrCast(@alignCast(context));
            recorded.events[recorded.count] = notice;
            recorded.count += 1;
        }
    };
    var recorded: Recorded = .{};
    world.hit_feedback = .{ .context = &recorded, .enqueue = Recorded.enqueue };
    mission.clock.frame_start = 20;
    all.slots[first].object.armor = .all(100);
    all.slots[second].object.armor = .all(100);
    armorDamage(world, first, .fore, 10, attacker, .bullet);
    armorDamage(world, second, .aft, 10, attacker, .bullet);
    armorDamage(world, attacker, .left, 1, first, .bullet);
    try std.testing.expectEqual(8, recorded.count);
    try std.testing.expectEqual(0, world.shake.*);
    for ([_]players.ControlRef{ first_binding, second_binding }, 0..) |binding, index| {
        const entries = recorded.events[index * 4 ..][0..4];
        for (entries) |entry| {
            try std.testing.expectEqual(binding, entry.recipient);
            try std.testing.expectEqual(20, entry.tick);
        }
        try std.testing.expectEqual(.interference, std.meta.activeTag(entries[0].effect));
        try std.testing.expectEqual(.radio_line, std.meta.activeTag(entries[1].effect));
        try std.testing.expectEqual(.impact, std.meta.activeTag(entries[2].effect));
        try std.testing.expectEqual(.armour_hit, std.meta.activeTag(entries[3].effect));
    }

    // Viewing the first ship delivers its effects and ignores the second pilot's.
    var display: hud.State = .{};
    world.display = &display;
    try std.testing.expect(!recorded.events[4].present(world));
    for (recorded.events[0..4]) |notice| try std.testing.expect(notice.present(world));
    try std.testing.expectEqual(1, display.events.interference_hits.count);
    try std.testing.expectEqual(1, display.events.ship_hits.get(.fore).count);
    try std.testing.expectEqual(0, display.events.ship_hits.get(.aft).count);
    try std.testing.expectApproxEqAbs(0.25, world.shake.*, 1e-6);

    // After respawn, the same participant's new ship cannot receive the previous ship's hit.
    create.resetSlot(mission.orders(), first);
    _ = try create.createObject(all, &mission.tables, create.testing.no_models, first, .of(.predator), 0, @splat(0), &mission.random);
    const respawn = all.bindParticipant(first_pilot, .of(all, first)).?;
    try std.testing.expect(!recorded.events[3].present(world));

    // After a disconnect, a new participant cannot receive a hit even on the same ship.
    try std.testing.expect(create.Objects.leaveParticipant(world, first_pilot));
    const next = all.joinParticipant(first).?;
    _ = all.bindParticipant(next, respawn.ship).?;
    const delayed: HitFeedback.Addressed = .{ .recipient = respawn, .tick = 20, .effect = .{ .armour_hit = .aft } };
    try std.testing.expect(!delayed.present(world));
    try std.testing.expectEqual(0, display.events.ship_hits.get(.aft).count);
}

test "a campaign armour warning uses the local speaker and keeps its cooldown across missions" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var world = mission.world();
    const all = world.objects;
    const pilot = try mission.add(.of(.predator), @splat(0));
    const attacker = try mission.add(.of(.sabre), .{ 0, 0, 1000 });
    const slot = &all.slots[pilot];
    slot.object.shields.fore = 0;
    slot.object.armor.fore = slot.combat.?.startingArmor() / 2;
    const state = all.playerState(pilot).?;

    mission.clock.frame_start = 1000;
    armorDamage(world, pilot, .fore, 1, attacker, .collision);
    try std.testing.expectEqual(0, state.armor_warned_at);

    const hog_snd = @import("hog_snd.zig");
    var speaker: hog_snd.testing.Speaker = undefined;
    try speaker.init(2, null);
    defer speaker.deinit();
    const bytes = comptime hog_snd.testing.bank(2);
    speaker.sound.betty = try @import("../../formats/fat.zig").Bank.parse(&bytes);
    speaker.hear(&world);
    armorDamage(world, pilot, .fore, 1, attacker, .collision);
    try std.testing.expectEqual(1000, state.armor_warned_at);
    try std.testing.expectEqual(1, speaker.asked.list.items.len);
    speaker.heard();
    try std.testing.expect(speaker.playing());

    state.resetMission();
    mission.clock.frame_start = 1500;
    armorDamage(world, pilot, .fore, 1, attacker, .collision);
    try std.testing.expectEqual(1000, state.armor_warned_at);
    try std.testing.expectEqual(0, speaker.asked.list.items.len);
}

test "a headless host warns each pilot with their own armour cooldown" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var world = mission.world();
    world.damage_rules = .{ .arena = null };
    const all = world.objects;
    const first = try mission.add(.of(.predator), @splat(0));
    const second = try mission.add(.of(.predator), .{ 0, 0, 1000 });
    const attacker = try mission.add(.of(.sabre), .{ 0, 0, 2000 });
    all.players = 2;
    const first_pilot = all.joinParticipant(first).?;
    const second_pilot = all.joinParticipant(second).?;
    const first_binding = all.bindParticipant(first_pilot, .of(all, first)).?;
    const second_binding = all.bindParticipant(second_pilot, .of(all, second)).?;
    for ([_]u16{ first, second }) |index| {
        const slot = &all.slots[index];
        slot.object.shields.fore = 0;
        slot.object.armor.fore = slot.combat.?.startingArmor() / 2;
    }

    const Recorded = struct {
        last_warning: ?HitFeedback.Addressed = null,
        warnings: usize = 0,

        fn enqueue(context: *anyopaque, notice: HitFeedback.Addressed) void {
            if (notice.effect != .armour_warning) return;
            const recorded: *@This() = @ptrCast(@alignCast(context));
            recorded.last_warning = notice;
            recorded.warnings += 1;
        }
    };
    var recorded: Recorded = .{};
    world.hit_feedback = .{ .context = &recorded, .enqueue = Recorded.enqueue };

    mission.clock.frame_start = 1000;
    armorDamage(world, first, .fore, 1, attacker, .collision);
    const first_warning = recorded.last_warning.?;
    try std.testing.expectEqual(first_binding, first_warning.recipient);
    try std.testing.expectEqual(1, recorded.warnings);

    mission.clock.frame_start = 1500;
    armorDamage(world, first, .fore, 1, attacker, .collision);
    try std.testing.expectEqual(1, recorded.warnings);
    armorDamage(world, second, .fore, 1, attacker, .collision);
    const second_warning = recorded.last_warning.?;
    try std.testing.expectEqual(second_binding, second_warning.recipient);
    try std.testing.expectEqual(1500, second_warning.tick);
    try std.testing.expectEqual(2, recorded.warnings);

    mission.clock.frame_start = 1501;
    armorDamage(world, first, .fore, 1, attacker, .collision);
    try std.testing.expectEqual(first_binding, recorded.last_warning.?.recipient);
    try std.testing.expectEqual(3, recorded.warnings);
    try std.testing.expect(!second_warning.present(world));
    try std.testing.expect(first_warning.present(world));

    create.resetSlot(mission.orders(), first);
    _ = try create.createObject(all, &mission.tables, create.testing.no_models, first, .of(.predator), 0, @splat(0), &mission.random);
    _ = all.bindParticipant(first_pilot, .of(all, first)).?;
    try std.testing.expect(!first_warning.present(world));
    try std.testing.expectEqual(0, all.playerState(first).?.armor_warned_at);
    try std.testing.expectEqual(1500, all.playerState(second).?.armor_warned_at);
}
