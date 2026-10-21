//! OpenReliant's: what the game frames ask of drawing, in the order they ask it, which drawing takes
//! up as each drawn frame begins (`Cues.takeUp`). Drawing keeps the missiles' trails, the planets'
//! atmospheres, the escort marker, Planet Bombard's flashes, the sky and the backdrop. The game
//! frames only say when one starts or goes, which nebula to show, when to place the backdrop, and
//! when a mission starts, so they write nothing into what drawing keeps. A world with nothing drawn
//! has no cues, and its game frames give none.

const std = @import("std");
const Allocator = std.mem.Allocator;

const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const backdrop = @import("../backdrop.zig");
const create = @import("../create.zig");
const atmosphere = @import("../create/atmosphere.zig");
const escort = @import("../create/escort.zig");
const bombard = @import("../environfx/bombard.zig");
const trail = @import("../missiles/trail.zig");
const nebula = @import("../nebula.zig");

const log = std.log.scoped(.cues);

/// What the game frames ask of drawing.
pub const Cue = union(enum) {
    /// A mission starts (`main.startMission`): drawing lets go of the trails and the atmospheres,
    /// and starts the escort marker's pulse and Planet Bombard's flashes again.
    mission_started,
    /// A missile or a torpedo starts a trail (`trail.Trails.start`).
    trail_started: trail.Start,
    /// The missile a trail follows has ended, so the trail follows nothing, by the trail's number
    /// (`trail.Trails.leave`).
    trail_left: u32,
    /// The mission makes a planet (`atmosphere.Atmospheres.made`).
    planet_made: Made,
    /// The mission lets the planet in this slot go (`atmosphere.Atmospheres.release`).
    planet_gone: u16,
    /// The space's update asks for this nebula (`environfx.Environment.update`), which the sky
    /// shows where it shows another (`nebula.Sky.select`).
    ///
    /// **Fix:** the game stops with the assertion "Error in script: Invalid nebula" for a nebula
    /// past the seventh; OpenReliant logs it, and keeps the nebula it shows.
    nebula_asked: u32,
    /// The script asks for the backdrop to be placed again (`UpdateEnvironmentFXState`), for a
    /// mission of this many ships (`backdrop.Backdrop.place`).
    backdrop_placed: usize,

    /// A planet's slot, how often the slot had been reused as the planet was made
    /// (`create.Objects.reuses`), which tells it from an object made later in its place, and the
    /// radius of its model's first part then, which its atmosphere's ring is as wide as: the
    /// mission moves the planet's meshes onto the middle of their vertices after it makes the
    /// atmosphere (`create.planetMade`).
    pub const Made = struct {
        slot: u16,
        reuses: u32,
        radius: f32,

        /// The planet just made in slot `index` of `all`.
        pub fn of(all: *const create.Objects, index: u16) Made {
            const radius: f32 = if (all.slots[index].model) |model| if (model.parts.len > 0) model.parts[0].object.radius else 0 else 0;
            return .{ .slot = index, .reuses = all.reuses[index], .radius = radius };
        }
    };
};

/// The cues the game frames gave since the last drawn frame took them up.
pub const Cues = struct {
    gpa: Allocator,
    list: std.ArrayList(Cue) = .empty,
    /// How many trails the game frames have started, which numbers the next (`trail.Start`).
    trails: u32 = 0,

    pub fn deinit(cues: *Cues) void {
        cues.list.deinit(cues.gpa);
    }

    /// Gives `cue` after the others. Where there's no room for it, it's left out, with a warning.
    pub fn add(cues: *Cues, cue: Cue) void {
        cues.list.append(cues.gpa, cue) catch log.warn("drawing misses a cue of the game's ({s}): out of memory", .{@tagName(cue)});
    }

    /// The number of the next trail the game frames start.
    pub fn trailNumber(cues: *Cues) u32 {
        defer cues.trails +%= 1;
        return cues.trails;
    }

    /// What drawing keeps, which it takes the cues up into, and the drawn frame's copy of the
    /// objects (`main.Drawn`).
    pub const Kept = struct {
        objects: *create.Objects,
        trails: ?*trail.Trails = null,
        atmospheres: ?*atmosphere.Atmospheres = null,
        escort_marker: ?*escort.Marker = null,
        flashes: ?*bombard.Bombard = null,
        /// The sky, the backdrop, and the textures the sky takes its nebulae from.
        sky: ?*nebula.Sky = null,
        space: ?*backdrop.Backdrop = null,
        textures: ?*srtexture.Table = null,
    };

    /// As a drawn frame begins: each cue, in the order the game frames gave it, done to what drawing
    /// keeps; then none is left. A planet made is taken up from the frame's copy, unless another
    /// object has been made in its slot since.
    pub fn takeUp(cues: *Cues, kept: Kept) void {
        defer cues.list.clearRetainingCapacity();
        for (cues.list.items) |cue| switch (cue) {
            .mission_started => {
                if (kept.trails) |trails| trails.reset();
                if (kept.atmospheres) |atmospheres| atmospheres.reset();
                if (kept.escort_marker) |marker| marker.reset();
                if (kept.flashes) |flashes| flashes.reset();
            },
            .trail_started => |start| if (kept.trails) |trails| {
                _ = trails.start(start) catch |err| log.warn("a trail is left out: {s}", .{@errorName(err)});
            },
            .trail_left => |number| if (kept.trails) |trails| trails.leave(number),
            .planet_made => |made| if (kept.atmospheres) |atmospheres| {
                if (kept.objects.reuses[made.slot] == made.reuses) atmospheres.made(kept.objects, made.slot, made.radius);
            },
            .planet_gone => |slot| if (kept.atmospheres) |atmospheres| atmospheres.release(slot),
            .nebula_asked => |asked| if (kept.sky) |sky| if (kept.space) |space| if (kept.textures) |textures| {
                if (sky.nebula != asked) sky.select(textures, asked, &space.lights) catch |err| {
                    log.warn("nebula {d} is left out: {s}", .{ asked, @errorName(err) });
                };
            },
            .backdrop_placed => |ships| if (kept.sky) |sky| if (kept.space) |space| space.place(sky, kept.objects, ships),
        };
    }
};

test Cues {
    const gpa = std.testing.allocator;
    var mission: @import("../gameobj.zig").testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    var image: @import("../../surrender/surrenderlib/srtexture.zig").Image = .{ .levels = &.{} };
    var atmospheres: atmosphere.Atmospheres = .{ .gpa = gpa, .image = &image };
    defer atmospheres.deinit();
    var cues: Cues = .{ .gpa = gpa };
    defer cues.deinit();
    const all = mission.objects;
    const planet = try mission.addWith(model.types(), .of(.predator), @splat(0));
    all.slots[planet].object.type = .of(.jupiter_hi);
    const kept: Cues.Kept = .{ .objects = all, .atmospheres = &atmospheres };

    // Nothing comes of a cue until drawing takes it up, and then it's gone.
    cues.add(.{ .planet_made = .of(all, planet) });
    try std.testing.expectEqual(0, atmospheres.count);
    cues.takeUp(kept);
    try std.testing.expectEqual(1, atmospheres.count);
    try std.testing.expectEqual(0, cues.list.items.len);

    // In the order given: the planet goes, and a planet made in its slot before another object
    // took it is left out.
    cues.add(.{ .planet_gone = planet });
    cues.add(.{ .planet_made = .{ .slot = planet, .reuses = all.reuses[planet] -% 1, .radius = 0 } });
    cues.takeUp(kept);
    try std.testing.expectEqual(0, atmospheres.count);

    // A mission's start lets go of what drawing kept of the mission before, and what the new one
    // makes after it stays.
    cues.add(.{ .planet_made = .of(all, planet) });
    cues.add(.mission_started);
    cues.add(.{ .planet_made = .of(all, planet) });
    cues.takeUp(kept);
    try std.testing.expectEqual(1, atmospheres.count);

    // The trails are numbered in turn.
    try std.testing.expectEqual(0, cues.trailNumber());
    try std.testing.expectEqual(1, cues.trailNumber());
}

test "the nebula and the backdrop, as the game frames ask" {
    const gpa = std.testing.allocator;
    const textures = try srtexture.testing.Textures.init(gpa, backdrop.testing.names);
    defer textures.deinit(gpa);
    const rgb = try gpa.alloc(u8, backdrop.star_map_size * backdrop.star_map_size * 3);
    defer gpa.free(rgb);
    @memset(rgb, 0);
    var rand: @import("../../random.zig").Random = .{};
    const space = try backdrop.Backdrop.create(gpa, &textures.table, .{ .width = backdrop.star_map_size, .height = backdrop.star_map_size, .rgb = rgb }, &rand, 100, .original);
    defer space.destroy(gpa);
    const sky = try nebula.Sky.create(gpa, &textures.table, .{ .width = nebula.dome_image_size, .height = nebula.dome_image_size, .rgb = rgb[0 .. nebula.dome_image_size * nebula.dome_image_size * 3] });
    defer sky.destroy(gpa);
    var mission: @import("../gameobj.zig").testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var cues: Cues = .{ .gpa = gpa };
    defer cues.deinit();
    const kept: Cues.Kept = .{ .objects = mission.objects, .sky = sky, .space = space, .textures = &textures.table };

    // The sky shows the nebula asked for once drawing takes the cue up; one past the seventh is
    // left out, and the sky keeps the one it shows.
    cues.add(.{ .nebula_asked = nebula.small_patch_nebula });
    try std.testing.expectEqual(nebula.default_nebula, sky.nebula);
    cues.takeUp(kept);
    try std.testing.expectEqual(nebula.small_patch_nebula, sky.nebula);
    cues.add(.{ .nebula_asked = 99 });
    cues.takeUp(kept);
    try std.testing.expectEqual(nebula.small_patch_nebula, sky.nebula);

    // Placed again with no markers, the backdrop's sun goes back to its own direction.
    space.sun_direction = .{ 1, 2, 3 };
    cues.add(.{ .backdrop_placed = 0 });
    cues.takeUp(kept);
    try std.testing.expectEqual(backdrop.sun_direction, space.sun_direction);
}
