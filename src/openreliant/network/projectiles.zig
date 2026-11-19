//! Draw the host's ordnance with the regular missile and countermeasure models.
const std = @import("std");
const game = @import("openreliant").engine.game;
const math = @import("openreliant").engine.surrender.math;
const wire = @import("wire.zig");
const Page = wire.ordnance.Page;
const Projectiles = @This();

const Missile = struct {
    reuse: u32,
    local: u8,
};

models: game.objects.Effects,
decoys: game.cloak.Countermeasures,
trails: game.missiles.trail.Trails,
missiles: [game.missiles.max_missiles]?Missile = @splat(null),
seen: [Page.pages]u32 = @splat(0),
trail_number: u32 = 0,
advanced_at: u32 = 0,

pub fn init(gpa: std.mem.Allocator, models: game.objects.Effects, images: game.missiles.trail.Trails.Images) Projectiles {
    return .{
        .models = models,
        .decoys = .init(gpa, models.mounts),
        .trails = .init(gpa, images),
    };
}

pub fn deinit(shown: *Projectiles) void {
    shown.decoys.reset();
    shown.trails.deinit();
}

pub fn apply(shown: *Projectiles, world: game.gameobj.World, pages: *const [Page.pages]?Page, tick: u32) !void {
    for (pages, &shown.seen) |entry, *applied| {
        const page = entry orelse continue;
        if (page.tick > tick) continue;
        const stale = tick - page.tick > Page.max_age;
        if (stale and applied.* == 0 or !stale and applied.* == page.tick) continue;
        const end = @min(page.first() + Page.width, page.family.records());
        for (page.first()..end, page.entries[0 .. end - page.first()]) |index, pose| {
            const live = if (stale) null else pose;
            switch (page.family) {
                .missile => try shown.applyMissile(world, index, live, !stale),
                .decoy => if (live) |record| {
                    try shown.decoys.showReplica(@intCast(index), .{ .position = record.position, .orientation = wire.unpackFacing(record.angles) });
                } else shown.decoys.hideReplica(@intCast(index)),
            }
        }
        applied.* = if (stale) 0 else page.tick;
    }
    if (shown.advanced_at != tick) {
        shown.trails.frame(world);
        shown.advanced_at = tick;
    }
}

fn applyMissile(shown: *Projectiles, world: game.gameobj.World, index: usize, airborne: ?Page.Pose, witnessed: bool) !void {
    const all = world.objects;
    const tracked = &shown.missiles[index];
    if (tracked.*) |existing| if (airborne == null or airborne.?.reuse != existing.reuse) {
        const missile = all.missiles.get(existing.local).?;
        if (missile.trail) |trail| shown.trails.leave(trail);
        if (witnessed) game.explode.missileBlast(world, missile.slot.drawn.position, @splat(0), missile.slot.object.radius);
        all.missiles.remove(all.gpa, existing.local);
        tracked.* = null;
    };
    const pose = airborne orelse return;
    const spawned = tracked.* == null;
    if (spawned) {
        const local = (try game.missiles.replica(world, .of(pose.kind), shown.models, pose.flight.jettisoned)) orelse return;
        tracked.* = .{ .reuse = pose.reuse, .local = local };
    }
    const local = tracked.*.?.local;
    const missile = all.missiles.get(local).?;
    const slot = &missile.slot;
    const place: math.Place = .{ .position = pose.position, .orientation = wire.unpackFacing(pose.angles) };
    game.objects.setPlace(&slot.object, &slot.drawn, place);
    slot.object.throttle = @as(f32, @floatFromInt(pose.flight.burn)) / std.math.maxInt(u6);
    if (slot.model) |*model| model.place(slot.drawn.position, slot.drawn.orientation);
    if (spawned and pose.flight.launched and !pose.flight.jettisoned) game.missiles.playLaunchSound(world, local, false);
    if (missile.trail == null and !pose.flight.jettisoned) {
        shown.trail_number +%= 1;
        const id = shown.trail_number;
        if (try shown.trails.start(.of(world, id, .{ .missile = local }, missile.type)) != null) missile.trail = id;
    }
}
