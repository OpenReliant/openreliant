//! `C:\lancer\game\guns.cpp`'s muzzle flashes: a flare at each gun muzzle a model carries, which a
//! shot from the muzzle lights and which then shrinks away over its gun type's `flash_ticks`.
//! `guns_init` (`0x00478990`) builds the flares' meshes once (`muzzle_flash_mesh_build`,
//! `0x004786E0`), `node_mount_muzzle` (`0x00499680`) gives each muzzle its flash as a model is
//! made (`muzzle_flash_create`, `0x0047B150`), `bullet_fire` (`0x0047C5F0`) lights it, and
//! `node_draw` draws it while it lasts (`muzzle_flash_draw`, `0x0047BA80`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const shp = @import("../../../formats/shp.zig");
const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srlight = @import("../../surrender/surrenderlib/srlight.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const additions = @import("../additions.zig");
const environfx = @import("../environfx.zig");
const guns = @import("../guns.zig");
const matmanager = @import("../matmanager.zig");
const objects = @import("../objects.zig");
const stats = @import("stats.zig");

const log = std.log.scoped(.guns);

/// A light that takes no colour of its own.
const white: [3]f32 = .{ 1, 1, 1 };

/// How the flashes are drawn where OpenReliant does more than the game.
pub const Settings = struct {
    lights: Lights = .cast,
    guns: Guns = .turrets_too,

    /// The original's: flashes that light nothing, on the fighters' guns alone.
    pub const original: Settings = .{ .lights = .none, .guns = .original };
};

/// Whether a flash lights what stands round it.
pub const Lights = enum {
    /// **Improvement:** a flash casts a point light while it lasts, dimming and drawing in as the
    /// flare shrinks, so that each shot lights up the hull round the gun. It reaches
    /// `reach_per_length` times the flare's length at its brightest, and is its flares' own colour
    /// (`flareColour`), or a turret's shot's.
    cast,
    /// As the original: a flash lights nothing, its glow being in its textures alone.
    none,
};

/// Which guns' muzzles flash.
pub const Guns = enum {
    /// **Improvement:** the turrets' guns flash too: the Turret Flak, the Turret Lasers and both
    /// Huge Guns, whose flashes the original makes last no time. A turret's lasts `turret_ticks`,
    /// sized by the Turret Lasers' bolt as the others are by the Laser Cannon's, in the colour of
    /// its shot's light: blue, or orange from a hostile ship (`Look.turret`).
    turrets_too,
    /// As the original: the fighters' guns but the Nova Cannon.
    original,

    /// How long a flash lasts after a shot of `kind` (`gun_flash_ticks`).
    fn ticks(which: Guns, kind: guns.GunType) i32 {
        if (which == .turrets_too and kind.base().onTurrets()) return turret_ticks;
        return stats.flash_ticks[kind.base().number()];
    }
};

/// How long a turret's flash lasts, where they flash: as long as most guns' do.
const turret_ticks = 50;

/// What a flash is drawn with: every gun type's flare but one, that one's sheet, and the turrets'.
pub const Look = enum {
    /// `matflarea3` across the muzzle and `matflareb3` down the flare.
    flare,
    /// The Gattling Plasma Cannon's: `gunflare\sfxalpha1` for both, a sheet of frames the flash
    /// plays through (`animate`).
    sheet,
    /// OpenReliant's, for the turrets' guns (`Guns.turrets_too`): the white flares, `matflarea7`
    /// and `matflareb7`, coloured by the flash's own colours (`Flash.colours`), paler across the
    /// muzzle, and twice as wide and as high as the Turret Lasers' bolt and half as long.
    turret,

    /// The look of a flash of `gun_type`, where `which` guns flash. `guns_init` builds a mesh for
    /// each type, all alike but the Gattling Plasma Cannon's; OpenReliant builds the ones that
    /// differ.
    pub fn of(gun_type: guns.GunType, which: Guns) Look {
        if (which == .turrets_too and gun_type.base().onTurrets()) return .turret;
        return if (gun_type.base() == .gattling_plasma_cannon) .sheet else .flare;
    }

    /// The textures it draws with across the muzzle and down the flare.
    fn images(look: Look) [2][]const u8 {
        return switch (look) {
            .flare => .{ "matflarea3", "matflareb3" },
            .sheet => .{ "gunflare\\sfxalpha1", "gunflare\\sfxalpha1" },
            .turret => .{ "matflarea7", "matflareb7" },
        };
    }

    /// How large it is drawn: twice as wide and as high as a bolt, and half as long
    /// (`muzzle_flash_mesh_build`), the Laser Cannon's or the Turret Lasers'.
    fn size(look: Look) Vector {
        const bolt: Vector = switch (look) {
            .flare, .sheet => stats.gun_types[guns.GunType.of(.laser_cannon).number()].bolt,
            .turret => guns.turret_lasers_bolt,
        };
        return bolt * Vector{ 2, 2, 0.5 };
    }

    /// Its material: drawn with the flash's own texture coordinates, and added to what stands
    /// behind it; coloured by the flash's own colours for a turret's, else white.
    fn material(look: Look) srapiext.Material {
        return .onePass(.{ .coordinates = .generated, .lit = look == .turret, .blend = .add });
    }

    /// The object flags of a flash's mesh (`muzzle_flash_create`): never culled, with its own
    /// texture coordinates, and its own colours for a turret's.
    fn flags(look: Look) srapiext.ObjectFlags {
        return .{ .not_culled = true, .own_first = true, .baked_object = look == .turret };
    }
};

/// The gun type a muzzle naming `number` flashes as: a mod's gun, which flashes as its base, or
/// else its number clamped to the game's types, as `muzzle_flash_create` and `muzzle_flash_draw`
/// clamp it.
pub fn typeOf(number: u32) guns.GunType {
    if (additions.guns.get(number) != null) return @enumFromInt(number);
    return @enumFromInt(std.math.clamp(number, 1, guns.max_types - 1));
}

/// How far a flash's light reaches at its brightest, for each unit of its flare's length.
const reach_per_length: f32 = 2.5;

/// How much of the way to white a turret's flash is across the muzzle.
const turret_core_paling: f32 = 0.5;

/// The flares' meshes (`muzzle_flash_meshes`, `0x00563108`), built once and shared by every flash,
/// and the colours of their lights. Whatever holds these must outlive the models pointing at them.
pub const Looks = struct {
    meshes: std.EnumArray(Look, srapiext.Mesh),
    colours: std.EnumArray(Look, [3]f32),
    settings: Settings,
    /// OpenReliant's: the flash of each gun a mod adds, in their order (`additions.GunExtra.flash`);
    /// null for one that flashes as its base does, or whose picture can't be found.
    mods: []?Own = &.{},

    /// A mod gun's own flash: its flare, drawn as the game's are, its light's colour, and its
    /// length.
    pub const Own = struct {
        mesh: srapiext.Mesh,
        colour: [3]f32,
        length: f32,
    };

    /// Builds them all (`guns_init`): each a plume (`environfx.plumeMesh`) of its look's size; and
    /// for each gun a mod adds with a flash picture, a plume of that picture, its base's size or as
    /// long as the gun gives, in proportion.
    ///
    /// **Improvement:** the original's guns are its own.
    pub fn create(gpa: Allocator, textures: *srtexture.Table, settings: Settings) (Allocator.Error || matmanager.Error)!Looks {
        var looks: Looks = .{ .meshes = undefined, .colours = undefined, .settings = settings };
        errdefer looks.deinitOwn(gpa);
        try looks.createOwn(gpa, textures);
        var made: usize = 0;
        errdefer for (std.enums.values(Look)[0..made]) |look| looks.meshes.get(look).deinit(gpa);
        for (std.enums.values(Look)) |look| {
            const names = look.images();
            const nozzle = try matmanager.textureRequire(textures, names[0]);
            const blades = try matmanager.textureRequire(textures, names[1]);
            looks.meshes.set(look, try environfx.plumeMesh(gpa, look.size(), look.material(), nozzle, blades));
            made += 1;
            looks.colours.set(look, switch (look) {
                .flare, .turret => flareColour(&.{ .{ .image = nozzle }, .{ .image = blades } }),
                .sheet => flareColour(&.{ .{ .image = nozzle, .low = sheet.nozzle_low, .high = sheet.nozzle_high }, .{ .image = blades, .high = sheet.blades_high } }),
            });
        }
        return looks;
    }

    pub fn deinit(looks: *const Looks, gpa: Allocator) void {
        for (looks.meshes.values) |mesh| mesh.deinit(gpa);
        looks.deinitOwn(gpa);
    }

    /// The mods' guns' own flashes (`mods`).
    fn createOwn(looks: *Looks, gpa: Allocator, textures: *srtexture.Table) Allocator.Error!void {
        const all = additions.guns.all();
        looks.mods = try gpa.alloc(?Own, all.len);
        @memset(looks.mods, null);
        for (looks.mods, all, additions.guns.first..) |*slot, gun, number| {
            const name = gun.extra.flash orelse continue;
            const image = try textures.find(name) orelse {
                log.warn("{s}: the gun's flash {s} is left out: the mod has no picture of that name", .{ gun.name, name });
                continue;
            };
            const base = Look.of(@enumFromInt(number), looks.settings.guns).size();
            const size = if (gun.extra.flash_size) |length| base * @as(Vector, @splat(length / base[2])) else base;
            // Each part made before the slot holds it, so that a failure leaves the slot empty.
            const mesh = try environfx.plumeMesh(gpa, size, Look.flare.material(), image, image);
            errdefer mesh.deinit(gpa);
            const colour = try ownColour(gpa, textures, name, image);
            slot.* = .{ .mesh = mesh, .colour = colour, .length = size[2] };
        }
    }

    /// The colour of the light of a mod gun's own flash, whose picture `name` the table found as
    /// `image` (`flareColour`): read from the mod's PNG file of the name where the table holds the
    /// picture compressed. White where there's none.
    fn ownColour(gpa: Allocator, textures: *srtexture.Table, name: []const u8, image: *const srtexture.Image) Allocator.Error![3]f32 {
        if (image.levels[0].format == .rgba8) return flareColour(&.{.{ .image = image }});
        const files = textures.files orelse return white;
        const file = try std.fmt.allocPrint(gpa, "{s}{s}", .{ name, srtexture.picture_extension });
        defer gpa.free(file);
        const picture = try files.picture(gpa, file) orelse return white;
        defer picture.deinit(gpa);
        const level = [1]srtexture.Level{.{ .width = picture.width, .height = picture.height, .texels = picture.rgba }};
        const decoded: srtexture.Image = .{ .levels = &level };
        return flareColour(&.{.{ .image = &decoded }});
    }

    fn deinitOwn(looks: *const Looks, gpa: Allocator) void {
        for (looks.mods) |slot| if (slot) |made| made.mesh.deinit(gpa);
        gpa.free(looks.mods);
    }

    /// The own flash of `kind`, a gun a mod adds with a flash picture.
    pub fn own(looks: *const Looks, kind: guns.GunType) ?*const Own {
        if (kind.added() == null) return null;
        const at = kind.number() - additions.guns.first;
        if (at >= looks.mods.len) return null;
        return if (looks.mods[at]) |*made| made else null;
    }
};

/// A stretch of a texture a flash draws from, from `low` to `high` in texture coordinates.
pub const Region = struct {
    image: *const srtexture.Image,
    low: [2]f32 = .{ 0, 0 },
    high: [2]f32 = .{ 1, 1 },
};

/// OpenReliant's: the colour of a flash's light, what its flare adds over `regions` brought up to
/// full brightness, so that the light is the flare's own colour. A region whose texture isn't held
/// as 8-bit RGBA, such as a mod's picture the table holds compressed, adds nothing. White, for a
/// flare that adds nothing.
pub fn flareColour(regions: []const Region) [3]f32 {
    var sum: Vector = @splat(0);
    for (regions) |region| {
        const level = region.image.levels[0];
        if (level.format != .rgba8 or level.texels.len < level.format.size(level.width, level.height)) continue;
        const x = texels(region.low[0], region.high[0], level.width);
        const y = texels(region.low[1], region.high[1], level.height);
        for (y[0]..y[1]) |row| {
            for (x[0]..x[1]) |column| {
                const texel = level.texels[(row * level.width + column) * 4 ..][0..3];
                sum += .{ @floatFromInt(texel[0]), @floatFromInt(texel[1]), @floatFromInt(texel[2]) };
            }
        }
    }
    const most = @reduce(.Max, sum);
    if (!(most > 0)) return white;
    return sum / @as(Vector, @splat(most));
}

/// The texels from `low` to `high`, in texture coordinates, of a side `count` texels long.
fn texels(low: f32, high: f32, count: u32) [2]usize {
    const across: f32 = @floatFromInt(count);
    const first = std.math.lossyCast(usize, @floor(low * across));
    const last = std.math.lossyCast(usize, @ceil(high * across));
    return .{ @min(first, count), @min(last, count) };
}

/// The texture coordinates a flash is made with, one pair a corner of each of its four quads: a
/// texel inside each edge of its flares (`muzzle_flash_create`).
const made_uv: [16][2]f32 = @bitCast(@as([4][4][2]f32, @splat(.{ .{ 0.984375, 0.984375 }, .{ 0.984375, 0.015625 }, .{ 0.015625, 0.015625 }, .{ 0.015625, 0.984375 } })));

/// The Gattling Plasma Cannon's sheet, as `muzzle_flash_draw` reads it: a texture 256 texels
/// square, holding three frames side by side, each 32 texels on from the last and 30 across. The
/// nozzle's frames stand a quarter of the way down, 30 texels high, and the blades' at the top, 62
/// high. Each corner falls half a texel in from its frame's edge.
const sheet = struct {
    const texel: f32 = 1.0 / 256.0;
    const frames = 3;
    const frame_step: f32 = 32;
    const frame_width: f32 = 30;
    const nozzle_top: f32 = 0.25;
    const nozzle_height: f32 = 30;
    const blades_height: f32 = 62;
    /// Where in its frame each corner of a quad stands, before `muzzle_flash_draw` scales it to
    /// the frame.
    const corners = [4][2]f32{ .{ 1, 0.984375 }, .{ 1, 0 }, .{ 0, 0 }, .{ 0, 0.984375 } };

    /// The stretches of the sheet the frames lie in, for their light's colour.
    const nozzle_low: [2]f32 = .{ 0, nozzle_top };
    const nozzle_high: [2]f32 = .{ frames * frame_step * texel, nozzle_top + nozzle_height * texel };
    const blades_high: [2]f32 = .{ frames * frame_step * texel, blades_height * texel };
};

/// Shows the sheet's frame for `now`, one a tick in turn, on each quad of `uv`
/// (`muzzle_flash_draw`).
fn animate(uv: *[16][2]f32, now: i32) void {
    const along = @as(f32, @floatFromInt(@mod(now, sheet.frames))) * sheet.frame_step * sheet.texel;
    for (0..4) |quad| {
        const high: f32 = if (quad == 0) sheet.nozzle_height else sheet.blades_height;
        const down: f32 = if (quad == 0) sheet.nozzle_top else 0;
        for (uv[quad * 4 ..][0..4], sheet.corners) |*at, corner| {
            at.* = .{
                (corner[0] * sheet.frame_width + 0.5) * sheet.texel + along,
                (corner[1] * high + 0.5) * sheet.texel + down,
            };
        }
    }
}

/// A muzzle's flash (`node_mount_muzzle`, node kind 4), hung from the part that carries the
/// muzzle, standing and turned as the muzzle's attachment does.
pub const Flash = struct {
    /// The part that carries it, and the muzzle's attachment on that part.
    part: usize,
    attachment: *const shp.Attachment,
    look: Look,
    /// The flares it's drawn with.
    looks: *const Looks,
    /// OpenReliant's: the own flash of the mod's gun the last shot was of, which it's drawn as in
    /// place of `look`; null for a gun that flashes as its base does.
    own: ?*const Looks.Own = null,
    /// Which guns flash, which says how long a shot lights it for.
    guns: Guns,
    /// How long it takes to shrink away, the ticks of the gun type its muzzle names.
    ticks: i32,
    /// The tick it goes out after (`+0xBC`); null while it is hidden, as it is until a shot lights
    /// it and once it has gone out.
    until: ?i32 = null,
    uv: [16][2]f32 = made_uv,
    /// Its own colours, one a corner, for a turret's (`Look.turret`), which each shot sets.
    colours: [16][4]f32 = @splat(@splat(0)),
    level: [1]srapiext.Level,
    object: srapiext.MeshObject,
    /// Its light, where the flashes cast them (`Lights.cast`). Its place and brightness are set as
    /// it is drawn.
    light: ?srlight.Light,

    /// `muzzle_flash_create`: a hidden flash of the look its muzzle's gun type draws, for
    /// `attachment` on part `part`. It points into itself, so it is made where it stays.
    pub fn init(flash: *Flash, looks: *const Looks, part: usize, attachment: *const shp.Attachment) void {
        const which = looks.settings.guns;
        const gun_type = typeOf(attachment.gun_type);
        const look: Look = .of(gun_type, which);
        const mesh = looks.meshes.getPtrConst(look);
        flash.* = .{
            .part = part,
            .attachment = attachment,
            .look = look,
            .looks = looks,
            .guns = which,
            .ticks = which.ticks(gun_type),
            .level = .{.{ .mesh = mesh, .until = std.math.inf(f32) }},
            .object = .{ .flags = look.flags(), .position = @splat(0), .radius = mesh.radius, .levels = &.{} },
            .light = switch (looks.settings.lights) {
                .cast => .{
                    .mask = 0,
                    .intensity = 0,
                    .colour = looks.colours.get(look),
                    .kind = .{ .point = .{ .position = @splat(0), .range = reach_per_length * look.size()[2] } },
                },
                .none => null,
            },
        };
        flash.object.levels = &flash.level;
        flash.object.own_uv[0] = &flash.uv;
        if (look == .turret) flash.object.baked = &flash.colours;
    }

    /// `bullet_fire`'s: lights the flash for a shot of `kind` fired at `now`, to go out once the
    /// shot's type's ticks have passed. A turret's flash, and its light, take `colour`, the shot's
    /// light's, the flare paler across the muzzle.
    ///
    /// **Improvement:** a shot of a gun a mod adds with a flash of its own draws that flash, in its
    /// own colour (`Looks.own`).
    pub fn fire(flash: *Flash, kind: guns.GunType, now: i32, colour: [3]f32) void {
        flash.until = now + flash.guns.ticks(kind);
        flash.drawAs(flash.looks.own(kind));
        if (flash.own != null or flash.look != .turret) return;
        const full: Vector = colour;
        const pale = math.lerp(full, @as(Vector, @splat(1)), turret_core_paling);
        for (&flash.colours, 0..) |*corner, at| {
            const shade = if (at < 4) pale else full;
            corner.* = .{ shade[0], shade[1], shade[2], 1 };
        }
        if (flash.light) |*light| light.colour = colour;
    }

    /// Draws the flash with the mod gun's own flash `own`, or with its look's flare where it's null.
    fn drawAs(flash: *Flash, own: ?*const Looks.Own) void {
        if (own == flash.own) return;
        flash.own = own;
        const shown: Look = if (own != null) .flare else flash.look;
        const mesh = if (own) |made| &made.mesh else flash.looks.meshes.getPtrConst(flash.look);
        flash.level[0].mesh = mesh;
        flash.object.radius = mesh.radius;
        flash.object.flags = shown.flags();
        flash.object.baked = if (shown == .turret) &flash.colours else null;
        if (flash.light) |*light| {
            light.colour = if (own) |made| made.colour else flash.looks.colours.get(flash.look);
            light.kind.point.range = reach_per_length * if (own) |made| made.length else flash.look.size()[2];
        }
    }

    /// `muzzle_flash_draw`: readies the flash to be drawn at `now`, standing on its part at
    /// `carrier`, and says whether it shows. Once its tick has passed it goes out. It stands and is
    /// turned as its attachment is, and is drawn as large as the share of its ticks it has left,
    /// its light as bright; the sheet shows the frame for `now`.
    ///
    /// A gun type whose flash lasts no time shows none: the game divides by its ticks, and takes
    /// the share it gets for none.
    pub fn show(flash: *Flash, now: i32, carrier: math.Place) bool {
        const until = flash.until orelse return false;
        if (until < now) {
            flash.until = null;
            return false;
        }
        const share: f32 = if (flash.ticks > 0) @min(@as(f32, @floatFromInt(until - now)) / @as(f32, @floatFromInt(flash.ticks)), 1) else 0;
        const place = objects.attachmentPlace(flash.attachment).within(carrier);
        flash.object.position = place.position;
        flash.object.orientation = place.orientation;
        flash.object.scale = share;
        if (flash.own == null and flash.look == .sheet) animate(&flash.uv, now);
        if (flash.light) |*light| {
            light.intensity = share;
            light.kind.point.position = place.position;
        }
        return true;
    }
};

pub const testing = struct {
    /// The flashes' looks built over a table holding nothing but their textures.
    pub const Built = struct {
        textures: *@import("../../surrender/surrenderlib/srtexture.zig").testing.Textures,
        looks: Looks,

        pub fn init(gpa: Allocator, settings: Settings) !Built {
            // The texture cache keeps each file's name, without the directory the game names it by.
            const textures = try @import("../../surrender/surrenderlib/srtexture.zig").testing.Textures.init(gpa, &.{ "matflarea3", "matflareb3", "sfxalpha1", "matflarea7", "matflareb7" });
            errdefer textures.deinit(gpa);
            return .{ .textures = textures, .looks = try .create(gpa, &textures.table, settings) };
        }

        pub fn deinit(built: Built, gpa: Allocator) void {
            built.looks.deinit(gpa);
            built.textures.deinit(gpa);
        }
    };
};

test Looks {
    const gpa = std.testing.allocator;
    const built: testing.Built = try .init(gpa, .{});
    defer built.deinit(gpa);
    const looks = &built.looks;

    // The guns' plumes are the Laser Cannon's bolt, twice as wide and half as long, and added
    // unlit with the flash's own coordinates.
    const flare = looks.meshes.getPtrConst(.flare);
    try std.testing.expectEqual(@as(Vector, .{ 60, 60, 600 }), flare.bounds[1]);
    try std.testing.expectEqual(Look.flare.material(), flare.surfaces[1].material);
    try std.testing.expect(!flare.surfaces[1].material.lit[0]);
    try std.testing.expect(flare.surfaces[0].textures[0].image != flare.surfaces[1].textures[0].image);
    const plasma = looks.meshes.getPtrConst(.sheet);
    try std.testing.expectEqual(plasma.surfaces[0].textures[0].image, plasma.surfaces[1].textures[0].image);
    // The turrets' is the Turret Lasers' bolt, coloured by the flash's own colours.
    const turret = looks.meshes.getPtrConst(.turret);
    try std.testing.expectEqual(@as(Vector, .{ 400, 400, 1200 }), turret.bounds[1]);
    try std.testing.expect(turret.surfaces[0].material.lit[0]);
}

test Look {
    try std.testing.expectEqual(Look.sheet, Look.of(.of(.gattling_plasma_cannon), .turrets_too));
    try std.testing.expectEqual(Look.flare, Look.of(.of(.laser_cannon), .turrets_too));
    try std.testing.expectEqual(Look.turret, Look.of(.of(.turret_lasers), .turrets_too));
    try std.testing.expectEqual(Look.turret, Look.of(.of(.allied_huge_gun), .turrets_too));
    try std.testing.expectEqual(Look.flare, Look.of(.of(.turret_lasers), .original));
    // A muzzle's number is clamped to the types there are.
    try std.testing.expectEqual(guns.GunType.of(.laser_cannon), typeOf(0));
    try std.testing.expectEqual(guns.GunType.of(.gattling_plasma_cannon), typeOf(9));
    try std.testing.expectEqual(guns.GunType.of(.coalition_huge_gun), typeOf(99));
    // A mod's gun flashes as itself, and so as its base.
    var list = [_]additions.guns.Added{.{ .name = "a:flare", .mod = "a", .base = .pulse_cannon, .extra = .{} }};
    additions.guns.install(&list);
    defer additions.guns.reset();
    try std.testing.expectEqual(Look.flare, Look.of(typeOf(additions.guns.first), .turrets_too));
}

test Guns {
    // The turrets' guns flash where OpenReliant lets them; the Nova Cannon's never does.
    try std.testing.expectEqual(turret_ticks, Guns.turrets_too.ticks(.of(.turret_flak)));
    try std.testing.expectEqual(0, Guns.original.ticks(.of(.turret_flak)));
    try std.testing.expectEqual(0, Guns.turrets_too.ticks(.of(.nova_cannon)));
    try std.testing.expectEqual(30, Guns.original.ticks(.of(.messon_blaster)));
}

test flareColour {
    // A yellow texel and a dark blue one: the light is their sum brought up to full brightness.
    const rgba = [_]u8{ 200, 200, 0, 255, 0, 0, 100, 255 };
    const level: srtexture.Level = .{ .width = 2, .height = 1, .texels = &rgba };
    const image: srtexture.Image = .{ .levels = &.{level} };
    try std.testing.expectEqual([3]f32{ 1, 1, 0.5 }, flareColour(&.{.{ .image = &image }}));
    // Over the left texel alone.
    try std.testing.expectEqual([3]f32{ 1, 1, 0 }, flareColour(&.{.{ .image = &image, .high = .{ 0.5, 1 } }}));
    // Nothing added, white.
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, flareColour(&.{.{ .image = &image, .high = .{ 0, 1 } }}));
    // A texture held compressed, or whose pixels the device took, adds nothing.
    const blocks: [16]u8 = @splat(0xFF);
    const compressed: srtexture.Image = .{ .levels = &.{.{ .width = 4, .height = 4, .format = .bc7, .texels = &blocks }} };
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, flareColour(&.{.{ .image = &compressed }}));
    const released: srtexture.Image = .{ .levels = &.{.{ .width = 2, .height = 1, .texels = &.{} }} };
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, flareColour(&.{.{ .image = &released }}));
}

test "a mod's flash held compressed takes its light's colour from its PNG file" {
    const gpa = std.testing.allocator;
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try @import("../../../formats/png.zig").writeRgba(gpa, &written.writer, 2, 1, &.{ 200, 100, 0, 255, 0, 0, 0, 255 });
    const pictures: srtexture.testing.Pictures = .{ .held = &.{.{ .name = "peel.png", .bytes = written.written() }} };
    const textures = try srtexture.testing.Textures.init(gpa, &.{});
    defer textures.deinit(gpa);
    textures.table.files = pictures.files();
    const blocks: [16]u8 = @splat(0xFF);
    const compressed: srtexture.Image = .{ .levels = &.{.{ .width = 4, .height = 4, .format = .bc7, .texels = &blocks }} };
    try std.testing.expectEqual([3]f32{ 1, 0.5, 0 }, try Looks.ownColour(gpa, &textures.table, "peel", &compressed));
    try std.testing.expectEqual(white, try Looks.ownColour(gpa, &textures.table, "missing", &compressed));
}

test animate {
    var uv = made_uv;
    // The first frame: the nozzle's from a quarter down, the blades' from the top.
    animate(&uv, 0);
    try std.testing.expectApproxEqAbs((30 + 0.5) / 256.0, uv[0][0], 1e-6);
    try std.testing.expectApproxEqAbs((0.984375 * 30 + 0.5) / 256.0 + 0.25, uv[0][1], 1e-6);
    try std.testing.expectApproxEqAbs(0.5 / 256.0 + 0.25, uv[1][1], 1e-6);
    try std.testing.expectApproxEqAbs((0.984375 * 62 + 0.5) / 256.0, uv[4][1], 1e-6);
    // Each tick the next frame, 32 texels on, then round again.
    animate(&uv, 4);
    try std.testing.expectApproxEqAbs((0.5 + 32) / 256.0, uv[2][0], 1e-6);
    animate(&uv, 3);
    try std.testing.expectApproxEqAbs(0.5 / 256.0, uv[2][0], 1e-6);
}

test Flash {
    const gpa = std.testing.allocator;
    const built: testing.Built = try .init(gpa, .{});
    defer built.deinit(gpa);
    var attachment = std.mem.zeroes(shp.Attachment);
    attachment.kind = .gun_muzzle;
    attachment.gun_type = 1;
    attachment.position = .{ .x = 10, .y = 0, .z = 0 };
    attachment.orientation = math.identity;
    var flash: Flash = undefined;
    flash.init(&built.looks, 2, &attachment);
    try std.testing.expectEqual(1, flash.object.levels.len);
    try std.testing.expectEqual(Look.flare, flash.look);
    try std.testing.expectEqual(50, flash.ticks);
    try std.testing.expectEqual(null, flash.object.baked);
    try std.testing.expectEqual(1500, flash.light.?.kind.point.range);

    // Hidden until a shot lights it.
    const carrier: math.Place = .{ .position = .{ 0, 0, 100 } };
    try std.testing.expect(!flash.show(0, carrier));

    // Full size as it is lit, standing where the muzzle does on its part, its light as bright and
    // its flares' colour whatever the shot's.
    const colour = flash.light.?.colour;
    flash.fire(.of(.laser_cannon), 100, .{ 1, 0.5, 0 });
    try std.testing.expectEqual(colour, flash.light.?.colour);
    try std.testing.expect(flash.show(100, carrier));
    try std.testing.expectEqual(1, flash.object.scale);
    try std.testing.expectEqual(@as(Vector, .{ 10, 0, 100 }), flash.object.position);
    try std.testing.expectEqual(1, flash.light.?.intensity);
    try std.testing.expectEqual(@as([3]f32, .{ 10, 0, 100 }), flash.light.?.kind.point.position);

    // Shrinking by the share of its ticks left, gone at the end and out after it.
    try std.testing.expect(flash.show(125, carrier));
    try std.testing.expectEqual(0.5, flash.object.scale);
    try std.testing.expect(flash.show(150, carrier));
    try std.testing.expectEqual(0, flash.object.scale);
    try std.testing.expect(!flash.show(151, carrier));
    try std.testing.expectEqual(null, flash.until);
}

test "a mod's gun flashes with a picture of its own" {
    const gpa = std.testing.allocator;
    var list = [_]additions.guns.Added{
        .{ .name = "a:peel", .mod = "a", .base = .laser_cannon, .extra = .{ .flash = "peel", .flash_size = 300 } },
        .{ .name = "a:plain", .mod = "a", .base = .laser_cannon, .extra = .{} },
    };
    additions.guns.install(&list);
    defer additions.guns.reset();
    const textures = try srtexture.testing.Textures.init(gpa, &.{ "matflarea3", "matflareb3", "sfxalpha1", "matflarea7", "matflareb7", "peel" });
    defer textures.deinit(gpa);
    const looks: Looks = try .create(gpa, &textures.table, .{});
    defer looks.deinit(gpa);

    // Its own flare, of its own length and in its base's proportions; none for a gun without one,
    // nor for the game's.
    const peel: guns.GunType = @enumFromInt(additions.guns.first);
    const own = looks.own(peel).?;
    try std.testing.expectEqual(@as(Vector, .{ 30, 30, 300 }), own.mesh.bounds[1]);
    try std.testing.expectEqual(null, looks.own(@enumFromInt(additions.guns.first + 1)));
    try std.testing.expectEqual(null, looks.own(.of(.laser_cannon)));

    // A muzzle draws it for a shot of the mod's gun, its light reaching as far as its length
    // says, and its flare again for a shot of the game's.
    var attachment = std.mem.zeroes(shp.Attachment);
    attachment.kind = .gun_muzzle;
    attachment.gun_type = 1;
    attachment.orientation = math.identity;
    var flash: Flash = undefined;
    flash.init(&looks, 0, &attachment);
    flash.fire(peel, 100, .{ 1, 1, 1 });
    try std.testing.expectEqual(&own.mesh, flash.level[0].mesh);
    try std.testing.expectEqual(own.colour, flash.light.?.colour);
    try std.testing.expectEqual(reach_per_length * 300, flash.light.?.kind.point.range);
    flash.fire(.of(.laser_cannon), 200, .{ 1, 1, 1 });
    try std.testing.expectEqual(looks.meshes.getPtrConst(.flare), flash.level[0].mesh);
    try std.testing.expectEqual(1500, flash.light.?.kind.point.range);
}

test "a turret's flash takes its shot's colour" {
    const gpa = std.testing.allocator;
    const built: testing.Built = try .init(gpa, .{});
    defer built.deinit(gpa);
    var attachment = std.mem.zeroes(shp.Attachment);
    attachment.gun_type = guns.GunType.of(.turret_lasers).number();
    attachment.orientation = math.identity;
    var flash: Flash = undefined;
    flash.init(&built.looks, 0, &attachment);
    try std.testing.expectEqual(Look.turret, flash.look);
    try std.testing.expectEqual(turret_ticks, flash.ticks);
    try std.testing.expect(flash.object.flags.baked_object);
    try std.testing.expectEqual(3000, flash.light.?.kind.point.range);

    // Orange from a hostile ship, paler across the muzzle; its light the same.
    flash.fire(.of(.turret_lasers), 10, .{ 1, 0.5, 0 });
    try std.testing.expectEqual(10 + turret_ticks, flash.until);
    try std.testing.expectEqual([4]f32{ 1, 0.75, 0.5, 1 }, flash.object.baked.?[0]);
    try std.testing.expectEqual([4]f32{ 1, 0.5, 0, 1 }, flash.object.baked.?[4]);
    try std.testing.expectEqual([3]f32{ 1, 0.5, 0 }, flash.light.?.colour);
    try std.testing.expect(flash.show(10, .{}));
    try std.testing.expectEqual(1, flash.object.scale);
}

test "a flash of a gun type that lasts no time shows at no size" {
    const gpa = std.testing.allocator;
    const built: testing.Built = try .init(gpa, .original);
    defer built.deinit(gpa);
    var attachment = std.mem.zeroes(shp.Attachment);
    attachment.gun_type = guns.GunType.of(.turret_lasers).number();
    attachment.orientation = math.identity;
    var flash: Flash = undefined;
    flash.init(&built.looks, 0, &attachment);
    // And casts no light where the flashes cast none.
    try std.testing.expectEqual(null, flash.light);
    try std.testing.expectEqual(Look.flare, flash.look);
    flash.fire(.of(.turret_lasers), 10, .{ 0, 0.5, 1 });
    try std.testing.expect(flash.show(10, .{}));
    try std.testing.expectEqual(0, flash.object.scale);
    try std.testing.expect(!flash.show(11, .{}));
}
