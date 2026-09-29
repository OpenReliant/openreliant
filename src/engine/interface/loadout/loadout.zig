//! `C:\lancer\interface\loadout\loadout.cpp`: the loadout screen, a hologram the briefing runs
//! between the mission's movie and Enriquez's last word (`interface_briefing`, `0x004376D2` on),
//! built on GenILib's 3D interface (`genilib.interf.i3d`). A disc lies before the camera with the
//! ships the pilot may fly on an arc round its rim, the chosen ship turns slowly above it, and
//! panels with the ship's name and figures, and six buttons, stand round it. All of it spins in
//! out of the disc's glow as the loadout begins. Clicking a ship on the arc flies it up to the
//! chosen spot as the chosen one flies back; Exit Loadout Computer spins it all away again, and
//! the ship chosen is the one the pilot flies.
//!
//! Not ported yet: the missile page and the racks the pilot flies with
//! ([#447](https://github.com/vdmkenny/openreliant/issues/447)), and the internal guns view
//! ([#448](https://github.com/vdmkenny/openreliant/issues/448)).
//!
//! The file's code also builds the band a planet's atmosphere is made of (`bandMesh`) and the
//! square the chase view's sights and a jump's flare are drawn on (`squareMesh`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const shp = @import("../../../formats/shp.zig");
const spr = @import("../../../formats/spr.zig");
const tcache = @import("../../../formats/tcache.zig");
const tga = @import("../../../formats/tga.zig");
const input = @import("../../input.zig");
const math = @import("../../surrender/math.zig");
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const srlight = @import("../../surrender/surrenderlib/srlight.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const i3d = @import("../../genilib/interf/i3d.zig");
const camera = @import("../../game/camera.zig");
const cbox = @import("../../game/cbox.zig");
const create = @import("../../game/create.zig");
const explode = @import("../../game/explode.zig");
const gameflow = @import("../../game/gameflow.zig");
const gameobj = @import("../../game/gameobj.zig");
const hog_snd = @import("../../game/hog_snd.zig");
const hud = @import("../../game/hud.zig");
const language = @import("../../game/language.zig");
const matmanager = @import("../../game/matmanager.zig");
const objects = @import("../../game/objects.zig");
const srofiles = @import("../../game/srofiles.zig");
const videoreports = @import("../../game/videoreports.zig");
const xtrabits = @import("../../game/xtrabits.zig");
const canvas = @import("../../game/interface/canvas.zig");
const rooms = @import("../../game/interface/rooms.zig");
const Vector = math.Vector;

pub const anims = @import("anims.zig");
pub const bars = @import("bars.zig");
pub const panels = @import("panels.zig");
pub const hologram = @import("hologram.zig");
pub const tables = @import("tables.zig");

const log = std.log.scoped(.loadout);

/// What the loadout reads, plays and draws with.
pub const Context = struct {
    /// The rooms' own: the allocator, `resource.hog`, the sound, and the speech's archive and how
    /// it sounds.
    rooms: rooms.Context,
    /// The texture cache, which the loadout decodes its own textures from.
    cache: tcache.Cache,
    strings: *const language.Language,
    /// The ship types' stats (`stats_load_ships`), which the ships' figures are worked out of.
    stats: *const create.Stats,
    /// The mission the loadout comes before (`mission_number`).
    mission: u16,
    /// The campaign's tier as the loadout finds it (`campaign_tier`, `0x00562DF0`), which it raises
    /// by the mission (`tierBefore`).
    tier: u2 = 0,
    /// The pilot's rank (`pilot_rank`, `0x00562DEC`), which with the tier sets how many ships the
    /// loadout offers.
    rank: gameflow.Rank = 0,
    /// The campaign's saved loadout, which the loadout starts from and its exit keeps.
    saved: *Saved,
    /// A hardware renderer (`sr + 0x1AC`), which the cursor's light takes its colour by.
    hardware: bool = true,
    /// The options' detail (`0x005D54E0`), which the ships on the arc are drawn at while they move.
    detail: explode.Detail = .high,
};

/// The campaign's saved loadout (`0x00562F18`): the ship the pilot last chose, which `campaign_new`
/// makes the Predator and a restart keeps.
///
/// Not ported yet: its racks (`0x00562F1A`,
/// [#447](https://github.com/vdmkenny/openreliant/issues/447)).
pub const Saved = struct {
    ship: u8 = predator,
};

/// What the loadout leaves the mission: the ship type the pilot flies
/// (`player_loadouts[player_index]`, `0x00588400`), and the campaign's tier as it raised it, which
/// the mission's fighters are armed by (`campaign_tier`).
///
/// Not ported yet: the racks (`player_loadouts + 4` on), which OpenReliant fits by tier meanwhile
/// ([#447](https://github.com/vdmkenny/openreliant/issues/447)).
pub const Result = struct {
    ship: u8,
    tier: u2,
};

/// What a frame of the loadout reads (`loadout_frame`'s arguments): the clock's milliseconds and
/// the pointer.
pub const Frame = struct {
    now: u32,
    mouse: i3d.Interface.Mouse,
};

/// The first mission, whose loadout offers the Predator alone, speaks `loadout.ut` and blinks its
/// exit (`0x00441B6F`, `0x0044340C`), and the mission whose loadout offers the Shroud alone
/// (`0x0044341E`).
const first_mission = 1;
const shroud_mission = 23;

/// The Predator and the Shroud, ship types 0 and 10 (`0x00523994`, the Shroud's object).
const predator = 0;
const shroud = 10;

/// The last mission whose loadout stands on the Reliant, before the Yamato's (`0x004426A0`,
/// below `0x13`).
const last_reliant_mission = 18;

/// The loadout's near plane (`0x00442737`), where the briefing's is `srapi.in_flight_near`.
///
/// Not ported: its far plane, 1000 (`sr + 0x16A2`), which OpenReliant's projection does without.
const near: f32 = 1;

/// The palette and the pictures the loadout loads from `resource.hog`: `palette3.tga`, which it
/// gives the device and VFX while it runs (`0x004EAC54`); the backdrops of the Reliant and the
/// Yamato (`0x004EA9BC`, `0x004EA9CC`); the panels' art (`0x004EA9B0`); its fonts (`0x004EA978`,
/// `0x004EA96C`); and its sounds (`0x004EAC10`).
const palette_name = "palette3.tga";
const reliant_backdrop = "rbackground.tga";
const yamato_backdrop = "background.tga";
const panels_name = "fpanels.tga";
const title_font_name = "ld_handel.fnt";
const stats_font_name = "handels.fnt";
const sounds_name = "ldsmp.fat";

/// The textures the loadout requires (`0x004EAA5C` on): the disc's four quarters, the glow, and the
/// cursor's.
const plate_names = [4][]const u8{ "plate-nw", "plate-ne", "plate-sw", "plate-se" };
const glow_name = "hologlow";
const cursor_name = "ld_cursor";

/// The speech mission 1's loadout says, from `speech_hog` (`0x004EACC8`).
const speech_name = "loadout.ut";

/// The loadout's sounds in `ldsmp.fat`, and their volumes (`sound_play` calls).
const Sound = enum(u8) {
    /// The hologram's hum, looping from the intro, 12 quarter tones down (`0x0044495A`).
    hum = 0,
    /// A button pressed (`0x00447283`).
    button = 1,
    /// Exit Loadout Computer (`0x00447996`).
    exit = 2,
    /// The intro (`0x00444977`).
    intro = 3,
    /// The loadout's end, as the disc has spun away (`0x004466DE`).
    end = 6,
    /// The pointer onto another object (`0x004435BE`).
    hover = 7,
    /// Another ship selected (`0x00448140`).
    select = 8,
    _,
};
/// The volume of the loadout's quieter sounds, the hum, a button's, the hover's and a selection's
/// (`0x28`), and the hum's pitch, 12 quarter tones down (`0x00444950`).
const quiet = 40;
const hum_pitch = -12;

/// A panel's texture (`texture_create_transient`), and the pixels the loadout draws it with.
const PanelTexture = struct {
    pixels: *panels.Image,
    image: srtexture.Image,
};

/// Where the tooltip is written, centred (`0x0044B279`).
const tooltip_at: [2]i32 = .{ 320, 458 };

/// How far a button sinks from the camera while it is pressed (`0x004DC3F8`).
const button_depth: f32 = 0.2;

/// The share of a ship's own scale it is drawn at on the arc (`arc_share`): `arc_unit`
/// (`0x004DC6E0`) times the double `0x004DC6E8`.
const arc_unit: f32 = 0.00175;
const arc_share: f32 = arc_unit * 111.11111111111111;

/// What entering scales each ship on the arc by, over `arc_unit` and the ship's scale
/// (`0x004DC6F0`): near enough the loading's scaling undone.
const enter_scale: f32 = 0.009;

/// How fast the chosen ship turns, radians a millisecond: a turn every four seconds
/// (`0x004DC6D8`), and how far it is tilted back about X (`0x00447197`).
const spin_rate: f32 = std.math.pi / 2000.0;
const spin_tilt: f32 = -0.75;

/// When mission 1's exit blinks, in milliseconds after the loadout's speech began, and how
/// (`0x004433DA`): hidden for the first 250 of every 500.
const blink_from = 15000;
const blink_until = 25000;
const blink_period = 500;
const blink_off = 250;

/// How many frames after a page is built each ship's rectangle is made again (`0x004468C9`).
const rect_frames = 2;

/// The light masks the loadout gives its ships' parts, which the green and the ambient lights reach
/// (`0x00441EF5`), and its cursor, which the cursor's and the ambient light reach (`0x0044690E`).
const ship_light_mask = 0xFFFD;
const cursor_light_mask = 0xFFEF;

/// Which page the loadout shows (`loadout_page`, `0x005245E8`).
const Page = enum(u8) { ships = 1, missiles = 2 };

/// A ship the loadout offers: its tree of parts, the object of the interface that stands for it,
/// each part's level of detail as the loadout picks it, and its zoom with the disc.
const Ship = struct {
    model: objects.Model,
    loaded: *const srofiles.Loaded,
    object: i3d.Object,
    /// A level for each part: the one the loadout shows it at, which it picks by hand.
    levels: []srapiext.Level,
    zoom: anims.Pair,

    /// `node_tree_level` (`0x0044B340`): each part shown at `level`, or its coarsest where it has
    /// fewer, whatever the distance: `ship_object_create` takes the parts' levels away
    /// (`0x0044B2F0`), leaving the mesh the loadout gives each.
    fn showLevel(ship: *Ship, level: usize) void {
        for (ship.model.parts, ship.loaded.parts, ship.levels, 0..) |*part, loaded, *shown, index| {
            if (loaded.levels.len == 0) continue;
            shown.* = .{ .mesh = loaded.levels[@min(level, loaded.levels.len - 1)].mesh, .until = std.math.inf(f32) };
            part.object.levels = ship.levels[index..][0..1];
            part.object.level = 0;
        }
    }

    /// `node_tree_portal` (`0x004492A0`): each part clipped by `portal`, or with none, clipped no
    /// more, the portal it had left as it was.
    fn clip(ship: *Ship, portal: ?*const srapiext.Portal) void {
        for (ship.model.parts) |*part| {
            part.object.flags.portal_clipped = portal != null;
            if (portal) |clipping| part.object.portal = clipping;
        }
    }
};

/// The loadout, as `loadout_load` makes it and `loadout_enter`, `loadout_frame` and `loadout_leave`
/// run it. It must not move once made.
pub const Loadout = struct {
    context: Context,
    /// What the loadout's models, meshes and pictures are made in, let go of all at once.
    arena: std.heap.ArenaAllocator,
    /// What a frame's hit tests work in, emptied each frame.
    frame_arena: std.heap.ArenaAllocator,
    /// `palette3` (`0x00524258`), which the loadout gives the device and VFX while it runs.
    palette: tga.Palette,
    /// The loadout's textures, its ships' and its disc's, decoded with `palette`, as the device
    /// converts them while the loadout has given it the palette (`texture_require`).
    textures: ?srtexture.Table = null,
    /// The device's camera and projection, and its background (`sr`'s, while the loadout runs).
    view: srapi.Context,
    scene: srcore.Scene = .{},
    interface: i3d.Interface,
    /// The campaign's tier as the loadout raises it (`campaign_tier`, `0x00441AA9`).
    tier: u2,
    /// The ship chosen (`loadout_ship`, `0x00523E68`), a ship type.
    chosen: u8,
    /// The ships the tier or the rank offers (`0x00523E84`), from the Predator on, and the first
    /// slot of the arc they stand in (`0x00524754`).
    ships: []Ship = &.{},
    first_slot: usize = 0,
    disc: hologram.Panel = undefined,
    glow: hologram.Panel = undefined,
    /// The panels of the ship's figures, of its name and of the page's title (`0x00523AE8` on).
    info: hologram.Panel = undefined,
    name: hologram.Panel = undefined,
    title: hologram.Panel = undefined,
    buttons: std.EnumArray(hologram.Button, hologram.Panel) = undefined,
    /// Two panels that face away from the camera, which only a view nothing opens turns round
    /// (`0x00523E6C`, `0x00523E70`).
    scrollers: [2]hologram.Panel = undefined,
    /// The 3D cursor, made as the ship page is first built (`0x00523A9C`), and its texture, which
    /// the loading requires (`0x00524224`).
    cursor: ?*i3d.Cursor = null,
    cursor_image: ?*srtexture.Image = null,
    spin_disc: anims.Pair = undefined,
    glow_appears: anims.Pair = undefined,
    button_appears: std.EnumArray(hologram.Button, anims.Pair) = undefined,
    /// The three panels' zooms (`0x00524480`).
    panel_zooms: [3]anims.Pair = undefined,
    flip_info: anims.Pair = undefined,
    flip_name: anims.Pair = undefined,
    /// The latest selection's two flights, where there has been one (`0x00523A98`, `0x00523A00`).
    select: ?anims.Pair = null,
    deselect: ?anims.Pair = null,
    lights: std.EnumArray(hologram.Light, srlight.Light),
    /// The portal in the disc's plane, which clips what sinks below it (`0x00524740`).
    disc_portal: srapiext.Portal = .{},
    /// The device's background as the loadout begins (`0x00523A54`).
    backdrop: srtexture.Image = .{ .levels = &.{} },
    /// The stats panel's textures, `finfo` and `binfo`, and the name panels', `fpanels` and
    /// `bpanels`, which the buttons take their art from too (`0x00524214` on).
    info_textures: std.EnumArray(panels.Face, PanelTexture) = undefined,
    title_textures: std.EnumArray(panels.Face, PanelTexture) = undefined,
    /// `fpanels.tga`'s pixels (`0x00523960`), which the name panels' textures start from.
    panels_art: *panels.Image = undefined,
    /// Each ship's figures as the loadout works them out as it loads (`loadout_ship_stats`,
    /// `0x004EC278`).
    figures: [tables.ship_count]tables.ShipFigures = undefined,
    /// The objects the device's background holds, captured (`capture_background`).
    still: std.ArrayList(*i3d.Object) = .empty,
    title_font: hud.Opened = undefined,
    stats_font: hud.Opened = undefined,
    fonts_open: bool = false,
    /// VFX's palette as the tooltip's font takes it: the text remap's entries of `palette`, in
    /// 6-bit levels.
    tooltip_palette: [spr.palette_size]u8 = @splat(0),
    sounds: ?hog_snd.BankFile = null,
    /// The voice the hum plays on (`0x00524744`).
    hum: ?u8 = null,
    /// Mission 1's speech and its file (`0x005246CC`), and when the loadout began to say it
    /// (`0x0052395C`).
    speech: cbox.Player = .{},
    speech_line: []u8 = &.{},
    speech_start: u32 = 0,
    /// `loadout_entered` (`0x00524975`) and `loadout_running` (`0x0052461C`): the next frame
    /// returns false once it is clear.
    entered: bool = false,
    running: bool = false,
    page: Page = .ships,
    last_page: Page = .ships,
    /// The red light's level and the way it fades (`0x00524734`, `0x00523AA0`): 1 up, -1 down, 0
    /// still.
    red_level: f32 = 0,
    red_fade: f32 = 0,
    /// When the chosen ship began turning (`0x00523CF4`), and its turn (`0x00524758`).
    spin_start: u32 = 0,
    spin: math.Matrix = math.identity,
    /// This frame's time and the last's (`0x005246C8`, `0x00523720`).
    now: u32 = 0,
    last: u32 = 0,
    /// The object under the pointer at the last frame (`0x005246A4`).
    last_hovered: ?*i3d.Object = null,
    /// Frames until each ship's rectangle is made again (`0x00523EA8`).
    rect_countdown: u8 = 0,
    /// The level of detail the ships on the arc are drawn at while they move (`0x00523AB0`).
    coarse: usize = 0,
    /// Set once the ship has turned back from belly up (`0x00523AC8`), which lets its turn go on
    /// while the loadout is busy.
    turned_back: bool = false,
    /// Whether the last frame's O asked for a screenshot, which the caller then saves.
    screenshot: bool = false,

    /// `loadout_load` (`0x00441AA0`), as the briefing loads: everything that takes time. The
    /// tier is raised to what the missions before this one reached, and the ships' figures worked
    /// out; the ships the tier or the rank offers are loaded with their green textures and made,
    /// scaled down to the arc's size but for the chosen one; the disc, its glow, the panels and
    /// the buttons are made and placed, and their animations built.
    ///
    /// Not ported yet: the missiles' and the guns' models and objects
    /// ([#447](https://github.com/vdmkenny/openreliant/issues/447),
    /// [#448](https://github.com/vdmkenny/openreliant/issues/448)).
    pub fn load(context: Context) !*Loadout {
        const gpa = context.rooms.gpa;
        const loadout = try gpa.create(Loadout);
        const tier = @max(context.tier, tierBefore(context.mission));
        loadout.* = .{
            .context = context,
            .arena = .init(gpa),
            .frame_arena = .init(gpa),
            .palette = undefined,
            .view = .{ .projection = canvas.projection(canvas.size, camera.factors), .hardware = context.hardware },
            .interface = .create(gpa, loadout),
            .tier = tier,
            .chosen = chosenFor(context, offeredShips(tier, context.rank)),
            .lights = hologram.lights(context.hardware),
        };
        errdefer loadout.destroy();
        try loadout.loadParts();
        return loadout;
    }

    fn loadParts(loadout: *Loadout) !void {
        const context = loadout.context;
        const arena = loadout.arena.allocator();
        const gpa = context.rooms.gpa;
        const resources = context.rooms.resources;
        loadout.palette = try tga.palette(try resources.readFile(arena, palette_name));
        loadout.sounds = .read(gpa, resources, sounds_name);
        loadout.textures = .init(gpa, context.cache, loadout.palette);
        const textures = &loadout.textures.?;

        // The ships the tier or the rank offers (`loadout_ships_create`, `0x00444760`), each an
        // object of the interface whose tooltip is its name (`0x00441E43` on), reached by the green
        // and the ambient lights alone (`0x00446070`).
        const offered = offeredShips(loadout.tier, context.rank);
        loadout.first_slot = (tables.arc_slot_count - offered) / 2;
        loadout.ships = try arena.alloc(Ship, offered);
        for (loadout.ships, 0..) |*ship, index| {
            try loadout.makeShip(ship, @intCast(index));
            ship.object = .create(0, context.strings.string(tables.ships[index].name), true);
            ship.object.press = pressShip;
            ship.object.target = .{ .tree = &ship.model };
            for (ship.model.parts) |*part| part.object.light_mask = ship_light_mask;
        }
        // Every ship but the chosen shrunk to the arc's share of its scale (`0x00442240` on).
        for (loadout.ships, 0..) |*ship, index| {
            if (index != loadout.chosen) i3d.scaleTree(&ship.model, arc_share * tables.ships[index].scale);
        }

        const backdrop_name = if (context.mission <= last_reliant_mission) reliant_backdrop else yamato_backdrop;
        const backdrop = try tga.decode(arena, try resources.readFile(arena, backdrop_name));
        loadout.backdrop = try matmanager.picture(arena, backdrop);
        loadout.panels_art = try arena.create(panels.Image);
        loadout.panels_art.* = @splat(.{ 0, 0, 0, 0 });
        const art = try tga.decode(arena, try resources.readFile(arena, panels_name));
        for (0..@min(art.height, panels.size)) |y| for (0..@min(art.width, panels.size)) |x| {
            loadout.panels_art[y * panels.size + x] = art.pixel(x, y) ++ .{hud.Pane.opaque_alpha};
        };
        try loadout.openFonts();
        for ([_]*std.EnumArray(panels.Face, PanelTexture){ &loadout.info_textures, &loadout.title_textures }) |faces| {
            for (&faces.values) |*texture| {
                texture.pixels = try arena.create(panels.Image);
                texture.pixels.* = @splat(.{ 0, 0, 0, 0 });
                const levels = try arena.alloc(srtexture.Level, 1);
                levels[0] = .{ .width = panels.size, .height = panels.size, .rgba = std.mem.asBytes(texture.pixels) };
                texture.image = .{ .levels = levels };
            }
        }
        loadout.figures = bars.shipFigures(context.stats);

        for (loadout.ships) |*ship| try loadout.interface.addObject(&ship.object, "");
        try loadout.makeGlow(try matmanager.textureRequire(textures, glow_name));
        var plates: [4]?*srtexture.Image = undefined;
        for (&plates, plate_names) |*plate, plate_name| plate.* = try matmanager.textureRequire(textures, plate_name);
        loadout.cursor_image = try matmanager.textureRequire(textures, cursor_name);
        try loadout.makeDisc(plates);
        try loadout.makePanels();
        loadout.place();
        for (&loadout.button_appears.values, std.enums.values(hologram.Button)) |*appears, button| {
            try anims.buttonAppears(appears, &loadout.interface, &loadout.buttons.getPtr(button).object, &loadout.glow.object, nextButtonAppears);
        }
        // Default and Remove All appear with the missile page alone.
        for ([_]hologram.Button{ .default, .remove_all }) |button| loadout.button_appears.getPtr(button).anim.on_share = null;
        for (&loadout.panel_zooms, [_]*hologram.Panel{ &loadout.info, &loadout.name, &loadout.title }) |*zoom, panel| {
            try anims.panelZoom(zoom, &loadout.interface, &panel.object, &loadout.glow.object);
        }
        for (loadout.ships) |*ship| try anims.shipZoom(&ship.zoom, &loadout.interface, &ship.object);
    }

    /// `ship_object_create` (`0x00445BD0`): ship type `index`'s tree of parts, of its model loaded
    /// with its green textures (`loadout_ship_models`, `0x00524976`), linked and standing at the
    /// origin; each part lit and opaque at its finest level (`0x00445FE0`), and drawn at the level
    /// the loadout gives it whatever the distance (`0x0044B2F0`).
    ///
    /// Not ported: the swap of a part's `Missiles` texture for `gmissiles` (`0x0044B440`), which
    /// the models take already, their textures named with the prefix.
    fn makeShip(loadout: *Loadout, ship: *Ship, index: u8) !void {
        const arena = loadout.arena.allocator();
        const record = tables.ships[index];
        const source = try arena.create(shp.Model);
        source.* = try .parse(arena, try loadout.context.rooms.resources.readFile(arena, record.model));
        const loaded = try arena.create(srofiles.Loaded);
        loaded.* = try srofiles.modelLoad(arena, &loadout.textures.?, source, .{ .hardware = loadout.context.hardware, .prefix = .loadout_ships }, false);
        ship.* = .{
            .model = try .create(arena, source, loaded, .{}),
            .loaded = loaded,
            .object = undefined,
            .levels = try arena.alloc(srapiext.Level, loaded.parts.len),
            .zoom = undefined,
        };
        gameobj.linkParts(&ship.model, source);
        ship.model.place(@splat(0), math.identity);
        for (loaded.parts) |part| {
            if (part.meshes.len == 0) continue;
            for (part.meshes[0].surfaces) |*surface| {
                surface.material.two_pass = false;
                surface.material.lit[0] = true;
                surface.material.blend[0] = .off;
            }
        }
        ship.showLevel(0);
    }

    /// Opens the loadout's two fonts (`font_open`), the title's taking VFX's palette through the
    /// text remap for the tooltip, in 6-bit levels as a font's palette holds them.
    fn openFonts(loadout: *Loadout) !void {
        const arena = loadout.arena.allocator();
        const resources = loadout.context.rooms.resources;
        const remap: hud.Remap = .{ .table = &tables.text_remap, .palette = &loadout.palette };
        for (0..tables.remap_length) |level| {
            const colour = remap.colour(@intCast(level)) orelse continue;
            for (loadout.tooltip_palette[level * 3 ..][0..3], colour) |*to, from| to.* = from >> 2;
        }
        loadout.title_font = .open(try .parse(try resources.readFile(arena, title_font_name)), &loadout.tooltip_palette);
        loadout.stats_font = .open(try .parse(try resources.readFile(arena, stats_font_name)), null);
        loadout.fonts_open = true;
    }

    /// `loadout_glow_create` (`0x00444720`): the disc's glow, a square of `glow` 10 across, and its
    /// Glow Appears.
    fn makeGlow(loadout: *Loadout, glow: ?*srtexture.Image) !void {
        try loadout.glow.make(loadout.arena.allocator(), &loadout.interface, .glow, glow, null, false, .{ 9.999, 9.999 }, .whole);
        try anims.glowAppears(&loadout.glow_appears, &loadout.interface, &loadout.glow.object);
    }

    /// `loadout_disc_create` (`0x00444310`): the disc, 20 across, its four quarters textured with
    /// `plates` (`discMesh`), unlit and added, named `Disc` and clickable; then the disc and its
    /// glow placed, and its Spin Disc built.
    fn makeDisc(loadout: *Loadout, plates: [4]?*srtexture.Image) !void {
        const disc = &loadout.disc;
        disc.mesh = try hologram.discMesh(loadout.arena.allocator(), plates);
        try disc.add(&loadout.interface, .disc);
        loadout.place();
        try anims.spinDisc(&loadout.spin_disc, &loadout.interface, &disc.object, &loadout.glow.object, placeShipsStep, spinDiscEnded);
    }

    /// `loadout_panels_create` (`0x00443C20`): the panels' textures drawn with the chosen ship; the
    /// ship's figures, its name and the page's title as panels turning over to their backs; the
    /// six buttons, each with its tooltip and its press and release, made too small to see until
    /// it appears; the two scrollers, facing away; and the flips of the two ship panels.
    ///
    /// Not ported yet: the ship clipper and the panel's clip object, of the internal guns view
    /// ([#448](https://github.com/vdmkenny/openreliant/issues/448)).
    fn makePanels(loadout: *Loadout) !void {
        loadout.drawPanels(loadout.chosen, loadout.chosen);
        const info = &loadout.info_textures;
        const title_front = &loadout.title_textures.getPtr(.front).image;
        const title_back = &loadout.title_textures.getPtr(.back).image;
        try loadout.info.make(loadout.arena.allocator(), &loadout.interface, .info, &info.getPtr(.front).image, &info.getPtr(.back).image, true, .{ 9.332, 9.332 }, .whole);
        try loadout.name.make(loadout.arena.allocator(), &loadout.interface, .ship_name, title_front, title_back, true, .{ 8.999, 0.667 }, .{ .top = 0.08984375, .left = 0, .bottom = 0.1796875, .right = 0.99609375 });
        try loadout.title.make(loadout.arena.allocator(), &loadout.interface, .page_title, title_front, title_back, true, .{ 9.999, 0.833 }, .{ .top = 0, .left = 0, .bottom = 0.09375, .right = 0.99609375 });
        for (std.enums.values(hologram.Button)) |button| {
            const panel = loadout.buttons.getPtr(button);
            try panel.make(loadout.arena.allocator(), &loadout.interface, button.name(), title_front, null, false, hologram.button_size, button.span());
            panel.scene_object.scale = hologram.button_hidden_scale;
            panel.object.setTooltip(loadout.context.strings.string(button.tooltip()));
            panel.object.press = pressButton;
            panel.object.release = switch (button) {
                .missiles => releaseMissiles,
                .exit => releaseExit,
                .ships => releaseShips,
                .guns => releaseGuns,
                .default => releaseDefault,
                .remove_all => releaseRemoveAll,
            };
        }
        const scroller_spans = [2]hologram.Span{
            .{ .top = 0.3828125, .left = 0.49609375, .bottom = 0.4765625, .right = 0.68359375 },
            .{ .top = 0.48046875, .left = 0.49609375, .bottom = 0.57421875, .right = 0.68359375 },
        };
        const scroller_places = [2]Vector{ .{ -9, 1.2, 0 }, .{ -9, 1.7, 0 } };
        for (&loadout.scrollers, [2]hologram.Name{ .scroller0, .scroller1 }, scroller_spans, scroller_places) |*scroller, name, span, at| {
            try scroller.make(loadout.arena.allocator(), &loadout.interface, name, title_front, null, false, .{ 0.9999, 0.4999 }, span);
            scroller.scene_object.position = at;
            scroller.scene_object.orientation = math.fromAngles(0, std.math.pi, 0);
        }
        try anims.flipInfo(&loadout.flip_info, &loadout.interface, &loadout.info.object);
        try anims.flipName(&loadout.flip_name, &loadout.interface, &loadout.name.object, noop);
    }

    /// `loadout_placements` (`0x0044B5E0`): the camera where the loadout's stands, then each object
    /// the placements name, where the interface has it by name (`0x0044B080`), put in its place and
    /// turned by its angles.
    fn place(loadout: *Loadout) void {
        loadout.view.camera = .{ .position = tables.camera_position, .orientation = math.fromAngleVector(tables.camera_angles) };
        for (tables.placements) |placement| {
            const object = loadout.named(placement.name) orelse continue;
            object.setPosition(placement.position);
            object.setOrientation(math.fromAngleVector(placement.angles));
        }
    }

    /// The first object of the interface named `name`, or null (`0x0044B080`, which finds the
    /// scene object of that name).
    fn named(loadout: *Loadout, name: []const u8) ?*i3d.Object {
        for (loadout.interface.objects.items) |object| {
            if (std.mem.eql(u8, object.name, name)) return object;
        }
        return null;
    }

    /// Draws the panels' textures (`0x00443C20`, `ship_select`): the stats panel's front with ship
    /// `front`'s figures and its back with `back`'s (`loadout_draw_stats`), the name panels' front
    /// with `front`'s name and their back with `back`'s (`panel_title_draw`).
    fn drawPanels(loadout: *Loadout, front: u8, back: u8) void {
        const kit: panels.Kit = .{
            .title_font = &loadout.title_font,
            .info_font = &loadout.stats_font,
            .palette = &loadout.palette,
            .strings = loadout.context.strings,
        };
        const info = &loadout.info_textures;
        const title = &loadout.title_textures;
        panels.drawStats(info.get(.front).pixels, kit, front, loadout.figures[front]);
        panels.drawStats(info.get(.back).pixels, kit, back, loadout.figures[back]);
        panels.drawTitle(title.get(.front).pixels, loadout.panels_art, kit, front);
        panels.drawTitle(title.get(.back).pixels, loadout.panels_art, kit, back);
        for ([_]*std.EnumArray(panels.Face, PanelTexture){ info, title }) |faces| {
            for (&faces.values) |*texture| texture.image.changed = true;
        }
    }

    /// `loadout_enter` (`0x00442720`), once the movie into the hologram has played, at `now`: the
    /// near plane brought in, the backdrop behind, the lights set, the ships placed, mission 1's
    /// speech begun, and the intro started (`loadout_intro`) with the first button's appearing.
    pub fn enter(loadout: *Loadout, now: u32) Allocator.Error!void {
        if (loadout.entered) return;
        loadout.view.projection.near = near;
        loadout.coarse = coarseLevel(loadout.context.detail);
        loadout.last = now;
        loadout.now = now;
        loadout.turned_back = false;
        loadout.chosen = chosenFor(loadout.context, loadout.ships.len);
        loadout.page = .ships;
        loadout.last_page = .ships;
        loadout.last_hovered = null;
        loadout.showBackdrop();
        loadout.placeShips();
        loadout.speech_start = 0;
        if (loadout.context.mission == first_mission) {
            loadout.say();
            loadout.speech_start = now;
        }
        // The ships but the chosen brought back from the arc's share of their scale, which the
        // intro then sets again (`0x00442B8B` on).
        const chosen = &loadout.ships[loadout.chosen];
        chosen.object.shown = false;
        try loadout.interface.scene(loadout.context.rooms.gpa, &loadout.scene, false, treeToScene);
        for (loadout.ships, 0..) |*ship, index| {
            if (index != loadout.chosen) i3d.scaleTree(&ship.model, enter_scale / (arc_unit * tables.ships[index].scale));
        }
        chosen.object.shown = true;
        loadout.button_appears.getPtr(.missiles).play(.forward, now);
        loadout.intro(now);
        loadout.select = null;
        loadout.deselect = null;
        loadout.spin_start = now;
        loadout.rect_countdown = 0;
        loadout.running = true;
        loadout.entered = true;
    }

    /// `loadout_intro` (`0x00444830`), at `now`: the interface busy; each ship a thousandth of the
    /// size it will stand at, the chosen one at its finest level and the rest at the coarse one;
    /// and the disc spinning in, its glow, the ships and the three panels zooming in with it, the
    /// hum and the intro's sound.
    fn intro(loadout: *Loadout, now: u32) void {
        loadout.interface.busy = true;
        for (loadout.ships, 0..) |*ship, index| {
            ship.showLevel(loadout.coarse);
            const scale = tables.ships[index].scale;
            i3d.scaleTree(&ship.model, if (index == loadout.chosen) scale * anims.zoomed_out else arc_share * scale * anims.zoomed_out);
            if (index == loadout.chosen) ship.showLevel(0);
        }
        loadout.spin_disc.play(.forward, now);
        loadout.glow_appears.play(.forward, now);
        for (loadout.ships) |*ship| ship.zoom.play(.forward, now);
        for (&loadout.panel_zooms) |*zoom| zoom.play(.forward, now);
        loadout.hum = loadout.playSound(.hum, quiet, hog_snd.forever, hum_pitch);
        _ = loadout.playSound(.intro, hog_snd.loudest, hog_snd.once, hog_snd.own_pitch);
    }

    /// `loadout_frame` (`0x004433C0`): a frame of the loadout at `in`'s time and pointer, and
    /// whether it runs on (`loadout_running`). The O key asks for a screenshot.
    pub fn frame(loadout: *Loadout, in: Frame, keyboard: *input.Keyboard) Allocator.Error!bool {
        const running = try loadout.step(in);
        loadout.screenshot = keyboard.pressed(@intFromEnum(input.Key.o), .none, true);
        return running;
    }

    /// A frame but for its O key, as the Spin Disc's end runs one again (`0x00446753`): mission
    /// 1's exit blinking and mission 23's ships but the Shroud put away; the scene made of the
    /// objects shown (`0x00443BB0`); the animations stepped and the pointer followed
    /// (`iinterface_frame`); the cursor shown while the interface is not busy; the scene made again
    /// (`iinterface_scene`); the ships' rectangles made again once their frames are up; the red
    /// light faded; the chosen ship turned on the ship page; and a sound as the pointer comes onto
    /// another object.
    fn step(loadout: *Loadout, in: Frame) Allocator.Error!bool {
        _ = loadout.frame_arena.reset(.retain_capacity);
        const arena = loadout.frame_arena.allocator();
        const gpa = loadout.context.rooms.gpa;
        loadout.now = in.now;
        if (loadout.context.mission == first_mission) {
            const since = in.now -% loadout.speech_start;
            const blinking = since > blink_from and since < blink_until and in.now % blink_period < blink_off;
            loadout.buttons.getPtr(.exit).object.shown = !blinking;
        }
        if (loadout.context.mission == shroud_mission) {
            for (loadout.ships, 0..) |*ship, index| {
                if (index == shroud) continue;
                ship.object.clickable = false;
                ship.object.shown = false;
            }
        }
        try loadout.putInScene(false);
        try loadout.interface.frame(arena, &loadout.view, in.now, in.mouse);
        if (loadout.cursor) |cursor| cursor.object.shown = !loadout.interface.busy;
        try loadout.interface.scene(gpa, &loadout.scene, false, treeToScene);
        if (loadout.rect_countdown > 0) {
            loadout.rect_countdown -= 1;
            if (loadout.rect_countdown == 0) for (loadout.ships) |*ship| try ship.object.updateRect(arena, &loadout.view);
        }
        loadout.fadeRed();
        loadout.last = loadout.now;
        if (loadout.page == .ships) loadout.spinShip();
        const hovered = loadout.interface.hovered;
        if (hovered) |object| {
            if (!loadout.interface.busy and object != &loadout.ships[loadout.chosen].object and object != loadout.last_hovered) {
                _ = loadout.playSound(.hover, quiet, hog_snd.once, hog_snd.own_pitch);
            }
        }
        loadout.last_hovered = hovered;
        try loadout.finishScene();
        return loadout.running;
    }

    /// The red light faded on (`0x004434D3` to `0x0044355A`): drawn at twice its level, which moves
    /// by a thousandth a millisecond the way it fades until it reaches 0 or 1, where it stops.
    fn fadeRed(loadout: *Loadout) void {
        if (loadout.red_fade == 0) return;
        loadout.lights.getPtr(.red).intensity = loadout.red_level * hologram.light_intensity;
        loadout.red_level += @as(f32, @floatFromInt(loadout.now -% loadout.last)) * loadout.red_fade * red_fade_rate;
        if (loadout.red_level > 1) {
            loadout.red_level = 1;
        } else if (loadout.red_level < 0) {
            loadout.red_level = 0;
        } else return;
        loadout.red_fade = 0;
    }

    /// How far the red light's level moves a millisecond (`0x004DC418`).
    const red_fade_rate: f32 = 0.001;

    /// `ship_spin` (`0x00447160`): the chosen ship's turn at this frame's time, about Y a turn
    /// every four seconds from when it began, tilted back about X; given to the ship where no
    /// selection is flying it, while the interface is not busy or once it has turned back.
    ///
    /// Not ported yet: the ship turning belly up takes the turn as its first key's angles instead
    /// ([#447](https://github.com/vdmkenny/openreliant/issues/447)), and the gunship turns with it
    /// ([#448](https://github.com/vdmkenny/openreliant/issues/448)).
    fn spinShip(loadout: *Loadout) void {
        const angle = @as(f32, @floatFromInt(loadout.now -% loadout.spin_start)) * spin_rate;
        loadout.spin = math.turned(math.turned(math.fromAngles(0, 0, 0), .y, angle), .x, spin_tilt);
        if (loadout.select) |select| if (!select.stopped()) return;
        if (loadout.turned_back or !loadout.interface.busy) {
            loadout.ships[loadout.chosen].object.setOrientation(loadout.spin);
        }
    }

    /// `loadout_scene` (`0x00443BB0`): the scene emptied but for its lights, and each object of the
    /// interface shown put in it, or where `all_trees`, each tree whether shown or not, its parts
    /// placed as they are put in (`treeToScene`).
    fn putInScene(loadout: *Loadout, all_trees: bool) Allocator.Error!void {
        i3d.clearScene(&loadout.scene);
        for (loadout.interface.objects.items) |object| {
            if (object.shown or (all_trees and object.target == .tree)) try object.addToScene(loadout.context.rooms.gpa, &loadout.scene, treeToScene);
        }
    }

    /// The scene's lights and portals, as `loadout_enter` adds the lights and each frame the disc's
    /// portal; and what the device's background holds.
    ///
    /// **Improvement:** the game renders the hologram's still part once, whenever a page is built,
    /// and grabs it as the device's background, drawn behind every frame after at 640 by 480
    /// (`capture_background`). OpenReliant keeps the objects it would have grabbed and draws them
    /// each frame, at the window's resolution.
    fn finishScene(loadout: *Loadout) Allocator.Error!void {
        const gpa = loadout.context.rooms.gpa;
        const scene = &loadout.scene;
        scene.lights.clearRetainingCapacity();
        for (std.enums.values(hologram.Light)) |light| {
            if (light == .bright_green) continue;
            try xtrabits.sceneAdd(gpa, scene, .{ .light = loadout.lights.getPtr(light) }, .world);
        }
        try xtrabits.sceneAdd(gpa, scene, .{ .portal = &loadout.disc_portal }, .world);
        for (loadout.still.items) |object| {
            if (!object.shown) try object.addToScene(gpa, scene, treeToScene);
        }
    }

    /// `capture_background` (`0x00446180`): nothing under the pointer, and the objects shown
    /// grabbed as the device's background (`finishScene`).
    fn captureBackground(loadout: *Loadout) Allocator.Error!void {
        loadout.interface.hovered = null;
        loadout.still.clearRetainingCapacity();
        for (loadout.interface.objects.items) |object| {
            if (object.shown) try loadout.still.append(loadout.context.rooms.gpa, object);
        }
    }

    /// The backdrop made the device's background again (`sr + 0x50`, `0x00523A54`).
    fn showBackdrop(loadout: *Loadout) void {
        loadout.view.background = &loadout.backdrop;
        loadout.still.clearRetainingCapacity();
    }

    /// `ships_place` (`0x004493B0`): each ship put on its slot of the disc (`slotPlace`), as the
    /// disc stands, the slots across and down scaled by the disc's size while it spins in and their
    /// depth by it always: the chosen ship on the chosen spot, the rest on the arc from the first
    /// slot, facing away from the disc's axis. While the disc spins in, the chosen ship takes its
    /// turn.
    ///
    /// **Fix:** the chosen spot gives no angles (`slot_place` with no facing), and while the disc
    /// spins away the game turns the chosen ship by whatever angles the stack held, the ship's
    /// before it on the arc. OpenReliant leaves it turned as it was.
    fn placeShips(loadout: *Loadout) void {
        const disc = &loadout.disc.scene_object;
        const across = if (loadout.spin_disc.stopped()) hologram.slot_unit else disc.scale * hologram.slot_unit;
        for (loadout.ships, 0..) |*ship, index| {
            var slot = if (index == loadout.chosen) tables.chosen_slot else tables.arc_slots[loadout.first_slot + index];
            slot[2] *= disc.scale;
            const placed = hologram.slotPlace(disc.place(), slot, index != loadout.chosen, across);
            ship.object.setPosition(placed.position);
            if (index != loadout.chosen) ship.object.setOrientation(math.fromAngleVector(placed.angles));
        }
        if (loadout.spin_disc.anim.direction == .forward) loadout.ships[loadout.chosen].object.setOrientation(loadout.spin);
    }

    /// The Spin Disc's step (`ships_place`, `0x004493B0`): the ships follow the disc.
    fn placeShipsStep(context: *anyopaque, _: *i3d.Anim) void {
        of(context).placeShips();
    }

    /// `disc_portal_ship` (`0x00449200`): the disc's portal put in the disc's plane, facing along
    /// its axis, and set on `ship` to clip what sinks below the disc.
    fn clipToDisc(loadout: *Loadout, ship: *Ship) void {
        const disc = &loadout.disc.scene_object;
        loadout.disc_portal.position = disc.position;
        loadout.disc_portal.normal = math.forward(disc.orientation);
        ship.clip(&loadout.disc_portal);
    }

    /// The Spin Disc's end (`0x004466C0`): spun away, the loadout's end sound, and its end; spun
    /// in, the ship page built (`buildShipPage`).
    fn spinDiscEnded(context: *anyopaque, anim: *i3d.Anim) void {
        const loadout = of(context);
        switch (anim.direction) {
            .back => {
                _ = loadout.playSound(.end, hog_snd.loudest, hog_snd.once, hog_snd.own_pitch);
                loadout.running = false;
            },
            .forward => loadout.buildShipPage() catch |err| log.warn("the ship page is left unfinished: {s}", .{@errorName(err)}),
        }
    }

    /// The ship page built as the disc has spun in (`0x004466EC` on): each ship at its finest level
    /// and clipped by the disc; a frame run again; the disc, its glow and the ships on the arc
    /// grabbed as the background, and the chosen ship, the panels, the buttons and the scrollers
    /// shown before it; the rectangles made again two frames on; the interface free; and the cursor
    /// made.
    ///
    /// Not ported yet: the chosen ship's missiles fitted, the tier's default in missions 1 and 23
    /// and the campaign's saved racks otherwise
    /// ([#447](https://github.com/vdmkenny/openreliant/issues/447)).
    fn buildShipPage(loadout: *Loadout) Allocator.Error!void {
        for (loadout.ships, 0..) |*ship, index| {
            if (index != loadout.chosen) ship.showLevel(0);
            loadout.clipToDisc(ship);
        }
        _ = try loadout.step(.{ .now = loadout.now, .mouse = loadout.interface.last });
        try loadout.grabShipPage(true);
        const arena = loadout.arena.allocator();
        const cursor = try arena.create(i3d.Cursor);
        try cursor.create(arena, &loadout.interface, loadout.cursor_image);
        cursor.scene_object.light_mask = cursor_light_mask;
        loadout.cursor = cursor;
    }

    /// The ship page's still part grabbed as the device's background, as the Spin Disc's end and
    /// the resume grab it (`0x0044675A` to `0x004468EF`, `0x0043777F` to `0x004439A5`): the panels,
    /// the buttons, the scrollers, the cursor and the chosen ship put away, and the ships the page
    /// offers, the disc and its glow shown, and grabbed; then the other way round, the ships'
    /// rectangles made again two frames on, and the interface free. Where `placing`, as at the Spin
    /// Disc's end, the ships are placed each time the scene is made.
    fn grabShipPage(loadout: *Loadout, placing: bool) Allocator.Error!void {
        const gpa = loadout.context.rooms.gpa;
        loadout.showPanels(false);
        for (loadout.ships, 0..) |*ship, index| {
            if (loadout.context.mission != shroud_mission or index == shroud) ship.object.shown = true;
        }
        loadout.showStill(true);
        loadout.ships[loadout.chosen].object.shown = false;
        for (&loadout.scrollers) |*scroller| scroller.object.shown = false;
        if (loadout.cursor) |cursor| cursor.object.shown = false;
        try loadout.interface.scene(gpa, &loadout.scene, false, treeToScene);
        if (placing) loadout.placeShips();
        try loadout.captureBackground();
        loadout.showPanels(true);
        for (loadout.ships) |*ship| ship.object.shown = false;
        for (&loadout.scrollers) |*scroller| scroller.object.shown = true;
        loadout.showStill(false);
        if (loadout.cursor) |cursor| cursor.object.shown = true;
        loadout.ships[loadout.chosen].object.shown = true;
        try loadout.interface.scene(gpa, &loadout.scene, false, treeToScene);
        if (placing) loadout.placeShips();
        loadout.rect_countdown = rect_frames;
        loadout.hideShipsButChosen();
        loadout.showStill(false);
        loadout.interface.busy = false;
    }

    /// The three panels and the six buttons shown or put away.
    fn showPanels(loadout: *Loadout, shown: bool) void {
        for ([_]*hologram.Panel{ &loadout.info, &loadout.name, &loadout.title }) |panel| panel.object.shown = shown;
        for (&loadout.buttons.values) |*button| button.object.shown = shown;
    }

    /// The disc and its glow shown or put away.
    fn showStill(loadout: *Loadout, shown: bool) void {
        loadout.disc.object.shown = shown;
        loadout.glow.object.shown = shown;
    }

    /// `0x004470F0`: every ship but the chosen put away.
    fn hideShipsButChosen(loadout: *Loadout) void {
        for (loadout.ships, 0..) |*ship, index| {
            if (index != loadout.chosen) ship.object.shown = false;
        }
    }

    /// hologram.Button Appears' share (`0x00446670`): the next of the first four buttons' appearing started,
    /// the way this one plays.
    fn nextButtonAppears(context: *anyopaque, anim: *i3d.Anim) void {
        const loadout = of(context);
        const first_four = [_]hologram.Button{ .missiles, .exit, .ships, .guns };
        for (first_four[0 .. first_four.len - 1], first_four[1..]) |this, next| {
            if (&loadout.button_appears.getPtr(this).anim != anim) continue;
            loadout.button_appears.getPtr(next).play(anim.direction, loadout.now);
            return;
        }
    }

    /// `noop`, which the name's flip calls half way.
    fn noop(_: *anyopaque, _: *i3d.Anim) void {}

    /// A ship's press (`0x00447C00`): the ship pressed selected, unless a selection is flying.
    ///
    /// Not ported yet: with the internal guns view open, it closes first and the selection follows
    /// ([#448](https://github.com/vdmkenny/openreliant/issues/448)).
    fn pressShip(context: *anyopaque, _: *i3d.Object, press: i3d.Press) void {
        const loadout = of(context);
        if (loadout.select) |select| if (!select.stopped()) return;
        loadout.selectShip(@intCast(press.index)) catch |err| log.warn("the ship is not selected: {s}", .{@errorName(err)});
    }

    /// `ship_select` (`0x00447E20`): ship `new` chosen in place of the chosen one, unless it is
    /// that one. The red light fades out; the old ship and the new are put away and the rest shown,
    /// grabbed as the background with the disc; the new ship can no longer be clicked and the old
    /// one can again; the panels' fronts drawn with the old ship and their backs with the new,
    /// turned front on and then flipped over; the new ship flies to the chosen spot and the old one
    /// back to its slot; and the interface is busy while they fly.
    ///
    /// Not ported yet: the old ship's missiles removed first
    /// ([#447](https://github.com/vdmkenny/openreliant/issues/447)).
    fn selectShip(loadout: *Loadout, new: u8) Allocator.Error!void {
        if (new == loadout.chosen) return;
        const gpa = loadout.context.rooms.gpa;
        const old = loadout.chosen;
        loadout.red_fade = -1;
        loadout.showOthers(old, new, true);
        loadout.ships[old].object.clickable = true;
        loadout.ships[new].object.clickable = false;
        loadout.showStill(true);
        if (loadout.cursor) |cursor| cursor.object.shown = false;
        loadout.showPanels(false);
        for (&loadout.scrollers) |*scroller| scroller.object.shown = false;
        try loadout.interface.scene(gpa, &loadout.scene, false, treeToScene);
        loadout.showBackdrop();
        loadout.placeShips();
        try loadout.captureBackground();
        loadout.showPanels(true);
        for (&loadout.scrollers) |*scroller| scroller.object.shown = true;
        if (loadout.cursor) |cursor| cursor.object.shown = true;
        loadout.showStill(false);
        loadout.showOthers(old, new, false);
        loadout.drawPanels(old, new);
        loadout.info.scene_object.orientation = math.identity;
        loadout.name.scene_object.orientation = math.identity;

        const now = loadout.now;
        const arc = loadout.arcSlot(new);
        if (loadout.select) |*select| loadout.interface.removeAnim(&select.anim);
        loadout.select = @as(anims.Pair, undefined);
        const select = &loadout.select.?;
        try anims.selectShip(select, &loadout.interface, &loadout.ships[new].object, arc, arc_share * tables.ships[new].scale, loadout.spotPlace(), tables.ships[new].scale, selectEnded);
        select.play(.forward, now);
        loadout.flip_name.play(.forward, now);
        loadout.flip_info.play(.forward, now);
        if (loadout.deselect) |*deselect| loadout.interface.removeAnim(&deselect.anim);
        loadout.deselect = @as(anims.Pair, undefined);
        const deselect = &loadout.deselect.?;
        try anims.deselectShip(deselect, &loadout.interface, &loadout.ships[old].object, loadout.spin, tables.ships[old].scale, loadout.arcSlot(old), arc_share * tables.ships[old].scale, deselectEnded);
        deselect.play(.forward, now);
        loadout.chosen = new;
        _ = loadout.playSound(.select, quiet, hog_snd.once, hog_snd.own_pitch);
        loadout.interface.busy = true;
    }

    /// Every ship but `old` and `new` shown and those two put away where `before`, the other way
    /// round otherwise; in mission 23 only the Shroud's changes.
    fn showOthers(loadout: *Loadout, old: u8, new: u8, before: bool) void {
        for (loadout.ships, 0..) |*ship, index| {
            if (index == old or index == new) {
                ship.object.shown = !before;
            } else if (loadout.context.mission != shroud_mission or index == shroud) {
                ship.object.shown = before;
            }
        }
    }

    /// Ship `index`'s slot on the arc, placed as a selection flies from it (`0x004481CD`): as the
    /// disc stands, facing away from its axis.
    fn arcSlot(loadout: *Loadout, index: u8) anims.Placed {
        return hologram.slotPlace(loadout.disc.scene_object.place(), tables.arc_slots[loadout.first_slot + index], true, hologram.slot_unit);
    }

    /// Where the chosen spot stands (`0x0044825D`).
    fn spotPlace(loadout: *Loadout) Vector {
        return hologram.slotPlace(loadout.disc.scene_object.place(), tables.chosen_slot, false, hologram.slot_unit).position;
    }

    /// Select Ship's end (`0x00446EF0`): the chosen ship's turn begins again from now, and the
    /// interface is free.
    ///
    /// Not ported yet: the tier's default missiles fitted to it at once
    /// ([#447](https://github.com/vdmkenny/openreliant/issues/447)), and with the guns view
    /// waiting, the view opened ([#448](https://github.com/vdmkenny/openreliant/issues/448)).
    fn selectEnded(context: *anyopaque, _: *i3d.Anim) void {
        const loadout = of(context);
        loadout.spin_start = loadout.now;
        loadout.interface.busy = false;
    }

    /// Deselect Ship's end (`0x00446F70`): the interface free, and each ship's rectangle made
    /// again.
    fn deselectEnded(context: *anyopaque, _: *i3d.Anim) void {
        const loadout = of(context);
        loadout.interface.busy = false;
        for (loadout.ships) |*ship| {
            ship.object.updateRect(loadout.frame_arena.allocator(), &loadout.view) catch |err|
                log.warn("a ship's rectangle is left as it was: {s}", .{@errorName(err)});
        }
    }

    /// A button's press (`0x00447270`): its sound, and the button sunk from the camera.
    fn pressButton(context: *anyopaque, object: *i3d.Object, _: i3d.Press) void {
        const loadout = of(context);
        _ = loadout.playSound(.button, quiet, hog_snd.once, hog_snd.own_pitch);
        object.target.mesh.position[2] += button_depth;
    }

    /// A button's release (`0x00447500`): the button pressed back where it stood.
    fn releaseButton(object: *i3d.Object) void {
        object.target.mesh.position[2] -= button_depth;
    }

    /// Missile Loadout's release (`0x00447630`): the missile page (`page_switch`).
    fn releaseMissiles(context: *anyopaque, object: *i3d.Object, _: i3d.Press) void {
        releaseButton(object);
        of(context).switchPage(.missiles);
    }

    /// Exit Loadout Computer's release (`0x004476F0`): the loadout's exit, unless it is busy.
    fn releaseExit(context: *anyopaque, object: *i3d.Object, _: i3d.Press) void {
        releaseButton(object);
        const loadout = of(context);
        if (!loadout.interface.busy) loadout.exit();
    }

    /// Ship Selection's release (`0x004475D0`): the ship page.
    ///
    /// Not ported yet: with the internal guns view open, it closes instead
    /// ([#448](https://github.com/vdmkenny/openreliant/issues/448)).
    fn releaseShips(context: *anyopaque, object: *i3d.Object, _: i3d.Press) void {
        releaseButton(object);
        of(context).switchPage(.ships);
    }

    /// View Internal Guns' release (`0x00447670`): the internal guns view, from the ship page.
    ///
    /// Not ported yet: the view ([#448](https://github.com/vdmkenny/openreliant/issues/448)).
    fn releaseGuns(_: *anyopaque, object: *i3d.Object, _: i3d.Press) void {
        releaseButton(object);
        log.info("the loadout's internal guns view is not ported yet", .{});
    }

    /// Use Default Loadout's release (`0x00447530`), on the missile page.
    ///
    /// Not ported yet: the tier's first missile flown to every hardpoint (`0x00449CA0`,
    /// [#447](https://github.com/vdmkenny/openreliant/issues/447)).
    fn releaseDefault(_: *anyopaque, object: *i3d.Object, _: i3d.Press) void {
        releaseButton(object);
        log.info("the loadout's default missiles are not ported yet", .{});
    }

    /// Remove All Missiles' release (`0x00447560`), on the missile page.
    ///
    /// Not ported yet: every rack emptied (`0x0044AEE0`,
    /// [#447](https://github.com/vdmkenny/openreliant/issues/447)).
    fn releaseRemoveAll(_: *anyopaque, object: *i3d.Object, _: i3d.Press) void {
        releaseButton(object);
        log.info("the loadout's missile racks are not ported yet", .{});
    }

    /// `page_switch` (`0x00449D90`): page `page`, where it is not the one shown.
    ///
    /// Not ported yet: the missile page, and the way back from it
    /// ([#447](https://github.com/vdmkenny/openreliant/issues/447)).
    fn switchPage(loadout: *Loadout, page: Page) void {
        if (page == loadout.page) return;
        log.info("the loadout's missile page is not ported yet", .{});
    }

    /// `loadout_exit` (`0x00447730`), once the disc has spun in: Enriquez stops, the interface is
    /// busy and nothing is under the pointer; the disc, its glow and every ship offered shown, the
    /// ships clipped no more and on the arc at the coarse level; everything spins and zooms back
    /// into the glow, easing out, the first buttons after one another; the chosen ship kept in the
    /// campaign's loadout; the hum ends and the exit's sound plays. The disc's spin's end ends the
    /// loadout.
    ///
    /// Not ported yet: the missiles and the markers put away, and on the missile page its two
    /// buttons ([#447](https://github.com/vdmkenny/openreliant/issues/447)); with the internal guns
    /// view open, it closes first ([#448](https://github.com/vdmkenny/openreliant/issues/448)).
    fn exit(loadout: *Loadout) void {
        if (!loadout.spin_disc.stopped()) return;
        const now = loadout.now;
        loadout.stopSpeech();
        loadout.spin_disc.frames[0].scale = .out;
        loadout.info.scene_object.flags.portal_clipped = false;
        loadout.interface.busy = true;
        loadout.interface.hovered = null;
        loadout.showStill(true);
        for (loadout.ships, 0..) |*ship, index| {
            ship.zoom.frames[0].scale = .out;
            ship.zoom.play(.back, now);
            ship.clip(null);
            if (loadout.context.mission != shroud_mission or index == shroud) {
                ship.object.shown = true;
                if (index != loadout.chosen) ship.showLevel(loadout.coarse);
            }
        }
        for (&loadout.panel_zooms) |*zoom| zoom.play(.back, now);
        loadout.button_appears.getPtr(.missiles).play(.back, now);
        loadout.showBackdrop();
        loadout.spin_disc.play(.back, now);
        loadout.glow_appears.play(.back, now);
        loadout.context.saved.ship = loadout.chosen;
        if (loadout.hum) |voice| loadout.context.rooms.sound.endVoice(voice);
        loadout.hum = null;
        _ = loadout.playSound(.exit, hog_snd.loudest, hog_snd.once, hog_snd.own_pitch);
    }

    /// `loadout_resume` (`0x00443760`), after the in-game options' BACK at `now`: once the disc has
    /// spun in, the ship page's background grabbed again with the disc, its glow and the ships on
    /// the arc, a frame run, and the interface free.
    ///
    /// **Fix:** the in-game options end every sound, the hum's among them, and the game never plays
    /// the hum again, leaving the hologram silent for the rest of the loadout. OpenReliant starts it
    /// again, where the exit has not ended it.
    ///
    /// Not ported yet: on the missile page, its missiles grabbed instead
    /// ([#447](https://github.com/vdmkenny/openreliant/issues/447)).
    pub fn resumeAfterOptions(loadout: *Loadout, now: u32) Allocator.Error!void {
        if (loadout.hum != null) loadout.hum = loadout.playSound(.hum, quiet, hog_snd.forever, hum_pitch);
        if (!loadout.spin_disc.stopped()) return;
        loadout.showBackdrop();
        _ = try loadout.step(.{ .now = now, .mouse = loadout.interface.last });
        try loadout.grabShipPage(false);
    }

    /// Mission 1's speech paused, as the in-game options open over the loadout (`0x004377C0`,
    /// `AIL_stop_sample`), and resumed as they close (`AIL_resume_sample`).
    pub fn pauseSpeech(loadout: *Loadout, paused: bool) void {
        if (loadout.context.mission != first_mission) return;
        loadout.speech.pause(loadout.context.rooms.sound, paused);
    }

    /// `loadout_leave` (`0x00442CC0`): what the loadout leaves the mission, the chosen ship, once
    /// it has let go of its sounds and speech (`speech_stop_all`, `sound_end_all`).
    ///
    /// Not ported yet: the racks it writes, to the mission and to the campaign's loadout
    /// ([#447](https://github.com/vdmkenny/openreliant/issues/447)).
    pub fn leave(loadout: *Loadout) Result {
        loadout.stopSpeech();
        if (loadout.entered) loadout.context.rooms.sound.endAll();
        loadout.entered = false;
        return .{ .ship = loadout.chosen, .tier = loadout.tier };
    }

    /// Lets go of everything the loadout holds.
    pub fn destroy(loadout: *Loadout) void {
        const gpa = loadout.context.rooms.gpa;
        loadout.stopSpeech();
        loadout.speech.deinit(gpa);
        if (loadout.fonts_open) {
            loadout.title_font.deinit(gpa);
            loadout.stats_font.deinit(gpa);
        }
        if (loadout.sounds) |sounds| sounds.deinit(gpa);
        if (loadout.textures) |*textures| textures.deinit();
        loadout.still.deinit(gpa);
        loadout.scene.deinit(gpa);
        loadout.interface.deinit();
        loadout.frame_arena.deinit();
        loadout.arena.deinit();
        gpa.destroy(loadout);
    }

    /// The loadout's render hook (`0x0044B200`), while the interface is not busy: the tooltip of
    /// the object under the pointer, but for the chosen ship's, written in the title's font through
    /// the text remap, centred low on the screen.
    pub fn draw(loadout: *Loadout, target: canvas.Canvas) Allocator.Error!void {
        if (loadout.interface.busy) return;
        const hovered = loadout.interface.hovered orelse return;
        if (hovered == &loadout.ships[loadout.chosen].object) return;
        const tooltip = hovered.tooltip orelse return;
        try target.text(&loadout.title_font, tooltip_at, tooltip, canvas.white, .centre);
    }

    /// The device's context as the window shows the loadout, `window` pixels in size: its
    /// projection fitted to the window as the front end's pictures are (`canvas.projection`).
    pub fn viewIn(loadout: *const Loadout, window: [2]u32) srapi.Context {
        var shown = loadout.view;
        shown.projection = canvas.projection(window, camera.factors);
        shown.projection.near = loadout.view.projection.near;
        return shown;
    }

    /// Plays `sound` of the loadout's bank (`sound_play`), in the middle: the voice, or null.
    fn playSound(loadout: *Loadout, sound: Sound, volume: i32, loops: u32, pitch: i32) ?u8 {
        const sounds = loadout.sounds orelse return null;
        return loadout.context.rooms.sound.play(sounds.bank, @intFromEnum(sound), volume, loops, hog_snd.centre, pitch);
    }

    /// Mission 1's speech, `loadout.ut` of `speech_hog`, said at full volume (`speech_play`).
    fn say(loadout: *Loadout) void {
        const context = loadout.context.rooms;
        const lines = context.lines orelse return;
        loadout.speech_line = videoreports.readLine(context.gpa, lines.*, speech_name) orelse return;
        rooms.say(context, &loadout.speech, loadout.speech_line, videoreports.lineName(speech_name), .in_person, null);
    }

    /// `speech_stop_all`: the speech ended and its file let go of.
    fn stopSpeech(loadout: *Loadout) void {
        const context = loadout.context.rooms;
        loadout.speech.stop(context.gpa, context.sound);
        context.gpa.free(loadout.speech_line);
        loadout.speech_line = &.{};
    }

    fn of(context: *anyopaque) *Loadout {
        return @ptrCast(@alignCast(context));
    }
};

/// `node_tree_to_scene` (`0x0044B0F0`): `tree`'s parts placed as its root stands
/// (`node_frame_update`), and each shown one put in the scene.
fn treeToScene(gpa: Allocator, scene: *srcore.Scene, tree: *objects.Model) Allocator.Error!void {
    tree.place(tree.position, tree.orientation);
    for (tree.parts) |*part| {
        if (!part.hidden) try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &part.object }, .world);
    }
}

/// The campaign's tier before mission `mission` (`0x00441AA9` to `0x00441AD9`): the highest the
/// missions before it reach (`gameflow.mission_tiers`).
fn tierBefore(mission: u16) u2 {
    var tier: u2 = 0;
    for (gameflow.mission_tiers[0..@min(mission -| 1, gameflow.mission_tiers.len)]) |reached| tier = @max(tier, reached);
    return tier;
}

/// How many ships the loadout offers at `tier` and `rank` (`loadout_ships_create`, `0x00444760`):
/// as many as the more generous of the two opens, from the Predator on.
fn offeredShips(tier: u2, rank: gameflow.Rank) usize {
    return @max(tables.ships_by_tier[tier], tables.ships_by_rank[rank]);
}

/// The ship the loadout starts on, of the first `offered` (`loadout_reset`, `0x004439D0`): the
/// Shroud in mission 23, the Predator in the first, and the campaign's saved one otherwise.
///
/// **Fix:** a saved ship the loadout does not offer, as a campaign begun again at an earlier
/// mission leaves it, leaves the game without the chosen ship's object, which it then writes to.
/// OpenReliant starts on the Predator.
fn chosenFor(context: Context, offered: usize) u8 {
    const chosen: u8 = switch (context.mission) {
        shroud_mission => shroud,
        first_mission => predator,
        else => context.saved.ship,
    };
    return if (chosen < offered) chosen else predator;
}

/// The level of detail the ships on the arc are drawn at while they move, at the options' `detail`
/// (`0x0044273A`): the finest at high.
fn coarseLevel(detail: explode.Detail) usize {
    return @as(usize, @intFromEnum(explode.Detail.high)) - @intFromEnum(detail);
}

/// `mesh_build_band` (`0x0044F200`): a band of `segments` quads round the Z axis, between a circle
/// of `segments` vertices of `radius` at Z 0 and another like it at `depth`, the first circle's
/// vertices first, from the one at the top going toward X. Each quad is two triangles, from a
/// vertex of the first circle to the next and to the one beside it on the second, then from the
/// next to its own on the second and back; the texture spans each quad once, across it from the
/// first vertex to the next, `v` 1 on the first circle and 0 on the second. Its faces' planes, its
/// vertex normals and its bounds are worked out; its one surface is left for the caller.
///
/// **Improvement:** the sine and cosine come from `std.math` rather than the engine's tables
/// (`sr_sin`, `sr_cos`).
pub fn bandMesh(gpa: Allocator, segments: u16, radius: f32, depth: f32) Allocator.Error!srapiext.Mesh {
    const n: usize = segments;
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = 2 * n, .vertices = 2 * n, .indices = 6 * n });
    errdefer mesh.deinit(gpa);
    const step = 1.0 / @as(f32, @floatFromInt(n)) * 2 * std.math.pi;
    for (0..n) |i| {
        const angle = @as(f32, @floatFromInt(i)) * step;
        const across: Vector = .{ @sin(angle) * radius, @cos(angle) * radius, 0 };
        mesh.positions[i] = across;
        mesh.positions[n + i] = across + Vector{ 0, 0, depth };
    }
    mesh.numberPolygons(3);
    const uv = try mesh.addCoordinates(gpa);
    for (0..n) |i| {
        const next: u16 = @intCast((i + 1) % n);
        const at: u16 = @intCast(i);
        const far: u16 = @intCast(n);
        mesh.indices[6 * i ..][0..6].* = .{ at, next, at + far, next, next + far, at + far };
        uv[6 * i ..][0..6].* = .{ .{ 0, 1 }, .{ 1, 1 }, .{ 0, 0 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
    }
    srapi.calcPolyNormals(&mesh);
    srapi.calcVertexNormals(&mesh);
    srapi.findBoundingBox(&mesh);
    return mesh;
}

/// `mesh_build_square` (`0x0044F000`): a rectangle facing along Z, `width` by `height` about its
/// centre, its corners from the lower left round to the upper left, as two triangles, and where
/// `two_sided` two more facing the other way. The texture spans it from its left edge to
/// `square_span` of the way across, `v` 1 at the top; the callers set `u` to the whole of it. Its
/// faces' planes, its vertex normals and its bounds are worked out; its one surface is left for the
/// caller.
pub fn squareMesh(gpa: Allocator, two_sided: bool, width: f32, height: f32) Allocator.Error!srapiext.Mesh {
    const faces: usize = if (two_sided) 4 else 2;
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = faces, .vertices = 4, .indices = 3 * faces });
    errdefer mesh.deinit(gpa);
    const w = width / 2;
    const h = height / 2;
    mesh.positions[0..4].* = .{ .{ -w, -h, 0 }, .{ w, -h, 0 }, .{ w, h, 0 }, .{ -w, h, 0 } };
    mesh.numberPolygons(3);
    const uv = try mesh.addCoordinates(gpa);
    mesh.indices[0..6].* = .{ 3, 2, 0, 2, 1, 0 };
    uv[0..6].* = .{ .{ 0, 1 }, .{ square_span, 1 }, .{ 0, 0 }, .{ square_span, 1 }, .{ square_span, 0 }, .{ 0, 0 } };
    if (two_sided) {
        mesh.indices[6..12].* = .{ 0, 2, 3, 0, 1, 2 };
        uv[6..12].* = .{ .{ square_span, 0 }, .{ 0, 1 }, .{ square_span, 1 }, .{ square_span, 0 }, .{ 0, 0 }, .{ 0, 1 } };
    }
    srapi.calcPolyNormals(&mesh);
    srapi.calcVertexNormals(&mesh);
    srapi.findBoundingBox(&mesh);
    return mesh;
}

/// How far across its texture `squareMesh` spans (`0x3F3F0000`).
pub const square_span: f32 = 0.74609375;

test squareMesh {
    const gpa = std.testing.allocator;
    var mesh = try squareMesh(gpa, false, 4, 2);
    defer mesh.deinit(gpa);
    try std.testing.expectEqualSlices(Vector, &.{ .{ -2, -1, 0 }, .{ 2, -1, 0 }, .{ 2, 1, 0 }, .{ -2, 1, 0 } }, mesh.positions);
    try std.testing.expectEqualSlices(u16, &.{ 3, 2, 0, 2, 1, 0 }, mesh.indices);
    try std.testing.expectEqual([2]f32{ square_span, 0 }, mesh.uv[0].?[4]);
    // It faces along Z.
    for (mesh.planes) |plane| try std.testing.expectApproxEqAbs(1, @abs(plane.normal[2]), 1e-6);
    // Two-sided, the same corners again the other way round.
    var both = try squareMesh(gpa, true, 4, 2);
    defer both.deinit(gpa);
    try std.testing.expectEqual(4, both.polygons.len);
    try std.testing.expectEqualSlices(u16, &.{ 0, 2, 3, 0, 1, 2 }, both.indices[6..12]);
    try std.testing.expectEqual(-both.planes[0].normal[2], both.planes[2].normal[2]);
}

test bandMesh {
    const gpa = std.testing.allocator;
    var mesh = try bandMesh(gpa, 4, 10, 5);
    defer mesh.deinit(gpa);
    // Two circles of four, the first from the top toward X, the second the same at its depth.
    try std.testing.expectEqual(8, mesh.positions.len);
    try std.testing.expectApproxEqAbs(10, mesh.positions[0][1], 1e-5);
    try std.testing.expectApproxEqAbs(10, mesh.positions[1][0], 1e-5);
    try std.testing.expectEqual(mesh.positions[1] + Vector{ 0, 0, 5 }, mesh.positions[5]);
    // Two triangles a quad, the last wrapping round to the first vertex.
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 4, 1, 5, 4 }, mesh.indices[0..6]);
    try std.testing.expectEqualSlices(u16, &.{ 3, 0, 7, 0, 4, 7 }, mesh.indices[18..24]);
    // The texture across each quad once, `v` 1 on the first circle.
    try std.testing.expectEqual([2]f32{ 0, 1 }, mesh.uv[0].?[0]);
    try std.testing.expectEqual([2]f32{ 1, 0 }, mesh.uv[0].?[4]);
    // Round a band with depth, the normals stand out from its axis, one long.
    for (mesh.normals) |normal| {
        try std.testing.expectApproxEqAbs(0, normal[2], 1e-5);
        try std.testing.expectApproxEqAbs(1, math.length(normal), 1e-5);
    }
}

test {
    _ = anims;
    _ = bars;
    _ = panels;
    _ = hologram;
    _ = tables;
}

test tierBefore {
    // A new campaign's first missions give none; the missions after the 11th, 19th and 21st raise
    // it.
    try std.testing.expectEqual(0, tierBefore(1));
    try std.testing.expectEqual(0, tierBefore(11));
    try std.testing.expectEqual(1, tierBefore(12));
    try std.testing.expectEqual(2, tierBefore(20));
    try std.testing.expectEqual(3, tierBefore(22));
    try std.testing.expectEqual(3, tierBefore(29));
    try std.testing.expectEqual(0, tierBefore(0));
}

test chosenFor {
    var saved: Saved = .{ .ship = 7 };
    var context: Context = .{ .rooms = undefined, .cache = undefined, .strings = undefined, .stats = undefined, .mission = 5, .saved = &saved };
    try std.testing.expectEqual(7, chosenFor(context, 12));
    // A saved ship the loadout does not offer starts it on the Predator.
    try std.testing.expectEqual(predator, chosenFor(context, 4));
    // The first mission starts on the Predator, and mission 23 on the Shroud, whatever was saved.
    context.mission = first_mission;
    try std.testing.expectEqual(predator, chosenFor(context, 12));
    context.mission = shroud_mission;
    try std.testing.expectEqual(shroud, chosenFor(context, 12));
}

test offeredShips {
    // A new pilot at the campaign's start sees the first four; a tier or a rank opens more.
    try std.testing.expectEqual(4, offeredShips(0, 0));
    try std.testing.expectEqual(7, offeredShips(1, 0));
    try std.testing.expectEqual(9, offeredShips(1, 5));
    try std.testing.expectEqual(12, offeredShips(3, 0));
    try std.testing.expectEqual(12, offeredShips(0, gameflow.rank_kills.len - 1));
}

test coarseLevel {
    try std.testing.expectEqual(0, coarseLevel(.high));
    try std.testing.expectEqual(2, coarseLevel(.low));
}
