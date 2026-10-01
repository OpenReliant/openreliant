//! `C:\lancer\interface\loadout\loadout.cpp`: the loadout screen, a hologram the briefing runs
//! between the mission's movie and Enriquez's last word (`interface_briefing`, `0x004376D2` on),
//! built on GenILib's 3D interface (`genilib.interf.i3d`). A disc lies before the camera with the
//! ships the pilot may fly on an arc round its rim, the chosen ship turns slowly above it, and
//! panels with the ship's name and figures, and six buttons, stand round it. All of it spins in
//! out of the disc's glow as the loadout begins. Clicking a ship on the arc flies it up to the
//! chosen spot as the chosen one flies back. On the missile page the other ships sink into the disc
//! and the missiles rise out of it, the chosen ship turns belly up, and a missile clicked flies to
//! a hardpoint of it. The internal guns view sweeps a glowing plane across the chosen ship, which
//! turns into its guns as the plane passes. Exit Loadout Computer spins it all away again, and the
//! ship chosen, with the missiles on its racks, is the one the pilot flies.
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
const missiles = @import("../../game/missiles.zig");
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
pub const racks = @import("racks.zig");
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
    /// The missile types' stats (`missile_stats`), which the missiles' figures are worked out of.
    missile_stats: *const missiles.Table,
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

/// The campaign's saved loadout (`0x00562F18`): the ship the pilot last chose and the missiles on
/// its racks (`0x00562F1A`), which `campaign_new` makes the Predator with none, and a restart keeps.
pub const Saved = struct {
    ship: u8 = predator,
    racks: racks.Saved = @splat(null),
};

/// What the loadout leaves the mission (`player_loadouts[player_index]`, `0x00588400`): the ship
/// type the pilot flies and the missile types on its racks, which `create_object` fits it with
/// (`create.Objects.loadout_racks`); and the campaign's tier as it raised it, which the mission's
/// fighters are armed by (`campaign_tier`).
pub const Result = struct {
    ship: u8,
    racks: create.Racks,
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

/// The textures the loadout requires (`0x004EAA5C` on): the disc's four quarters, the glow, the
/// cursor's, and the hardpoints' markers'.
const plate_names = [4][]const u8{ "plate-nw", "plate-ne", "plate-sw", "plate-se" };
const glow_name = "hologlow";
const cursor_name = "ld_cursor";
const marker_name = "hpoints";

/// The Ship Missile objects' name (`0x004EAAB8`).
const ship_missile_name = "Ship Missile";

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
    /// A missile flying to a hardpoint (`0x00447384`), and one flying back to its icon
    /// (`0x004474E3`).
    attach = 4,
    detach = 5,
    /// The loadout's end, as the disc has spun away (`0x004466DE`).
    end = 6,
    /// The pointer onto another object (`0x004435BE`).
    hover = 7,
    /// Another ship selected (`0x00448140`).
    select = 8,
    /// The internal guns view opened or closed (`0x0044A453`, `0x0044A240`).
    guns = 10,
    _,
};
/// The volume of the loadout's quieter sounds, the hum, a button's, the hover's, a selection's and
/// a missile's flights (`0x28`), and the hum's pitch, 12 quarter tones down (`0x00444950`).
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

/// The share of a ship's own scale it is drawn at on the arc (`arc_share`): the arc's unit of
/// scale (`anims.arc_unit`) times the double `0x004DC6E8`.
const arc_share: f32 = anims.arc_unit * 111.11111111111111;

/// What entering scales each ship on the arc by, over `anims.arc_unit` and the ship's scale
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

/// The light mask of a gunship's part drawn in lines (`gunship_light_masks`, `0x004460E0`): the
/// bright green light's, which the loadout never adds, so the ambient light alone reaches it.
const gunship_line_light_mask = 0xFFFB;

/// How many corners a mesh's polygon of a line has (`0x0044610C`).
const line_corners = 2;

/// The colour of a gunship's own, red, green, blue and alpha (`node_tree_colour`, `0x0044204D`): a
/// faint green its lights add to.
const gunship_colour: [4]f32 = .{ 0, 0.03, 0, 1 };

/// How far back along X from the chosen ship's place the ship clipper's sweep starts, and how far
/// along X it goes (`0x004DC5E8`, `0x004DC718`).
const clip_back: f32 = 5.5;
const clip_sweep: f32 = 11;

/// Which way the guns view's portals face as the ship clipper sweeps (`0x0044912E`,
/// `0x0044917B`): the gunship's along X, keeping what lies behind the plane, and the ship's back
/// along it, keeping what lies ahead.
const gunship_normal: Vector = .{ 1, 0, 0 };
const ship_normal: Vector = .{ -1, 0, 0 };

/// How long the portals' normals are as the guns view opens (`0x0044A2C6`, `0x0044A320`): a quarter
/// turn, as if they were angles, until the sweep's first step makes them 1.
const opening_normal_length: f32 = std.math.pi / 2.0;

/// Which page the loadout shows (`loadout_page`, `0x005245E8`).
const Page = enum(u8) { ships = 1, missiles = 2 };

/// The missile page's own buttons, Use Default Loadout and Remove All Missiles, which appear with
/// it alone (`0x005245DC`, `0x005245E0`).
const missile_buttons = [_]hologram.Button{ .default, .remove_all };

/// A ship the loadout offers: its tree of parts, the object of the interface that stands for it
/// (`0x0052396C`), each part's level of detail as the loadout picks it, its zoom with the disc, its
/// sinking into it (`0x00524564`), and its gunship. What it carries are the missiles hung on its
/// racks, as the missile page fits them.
const Ship = struct {
    model: objects.Model,
    loaded: *const srofiles.Loaded,
    object: i3d.Object,
    /// A level for each part: the one the loadout shows it at, which it picks by hand.
    levels: []srapiext.Level,
    zoom: anims.Pair,
    sink: anims.Pair,
    gunship: Gunship,

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

    /// Its parts clipped by `portal`, or clipped no more (`clipTree`).
    fn clip(ship: *Ship, portal: ?*const srapiext.Portal) void {
        clipTree(&ship.model, portal);
    }
};

/// A ship's gunship, which the internal guns view shows in the ship's place (`0x00523A64`): a tree
/// of the ship's gun model, and the object of the interface that stands for it.
const Gunship = struct {
    model: objects.Model,
    object: i3d.Object,
};

/// `gunship_light_masks` (`0x004460E0`): each part of a gunship's tree, whose meshes `loaded`
/// holds, reached by the green light and the ambient one, as the ships' parts are, but a part whose
/// finest mesh begins with a line, which the ambient light alone reaches
/// (`gunship_line_light_mask`).
fn gunshipLightMasks(tree: *objects.Model, loaded: *const srofiles.Loaded) void {
    for (tree.parts, loaded.parts) |*part, file| {
        if (file.meshes.len == 0 or file.meshes[0].surfaces.len == 0) continue;
        const polygons = file.meshes[0].polygons;
        const lines = polygons.len > 0 and polygons[0].count == line_corners;
        part.object.light_mask = if (lines) gunship_line_light_mask else ship_light_mask;
    }
}

/// `node_tree_portal` (`0x004492A0`): each part of `tree` clipped by `portal`, or with none, clipped
/// no more, the portal it had left as it was; and the parts of what it carries, the missiles hung
/// on its racks.
fn clipTree(tree: *objects.Model, portal: ?*const srapiext.Portal) void {
    for (tree.parts) |*part| {
        part.object.flags.portal_clipped = portal != null;
        if (portal) |clipping| part.object.portal = clipping;
    }
    var each = tree.carried();
    while (each.next()) |mount| clipTree(&mount.model, portal);
}

/// The missile hung in `held` let go of, its tree freed.
fn unhang(gpa: Allocator, held: *?objects.Model.Mount) void {
    if (held.*) |mount| mount.model.deinit(gpa);
    held.* = null;
}

/// `node_tree_lit_blend` (`0x00445FE0`): every surface of the mesh each part of a model loaded as
/// `loaded` draws, its finest, made one pass, lit or not, and blended as `blend` says. The parts of
/// every tree made of `loaded` share its meshes.
fn litBlend(loaded: *const srofiles.Loaded, lit: bool, blend: srapiext.Material.Blend) void {
    for (loaded.parts) |part| {
        if (part.meshes.len == 0) continue;
        for (part.meshes[0].surfaces) |*surface| {
            surface.material.two_pass = false;
            surface.material.lit[0] = lit;
            surface.material.blend[0] = blend;
        }
    }
}

/// A missile's icon on the arc of the missile page (`0x00523CFC`, `missile_icon_create`,
/// `0x00445EF0`): a tree of its model at `anims.missile_scale`, lit and opaque, the object of the
/// interface that stands for it, whose press flies a copy of the missile to the chosen ship, and
/// its sinking into the disc (`0x005239CC`).
const Icon = struct {
    model: objects.Model,
    object: i3d.Object,
    sink: anims.Pair,
};

/// A missile flying to a hardpoint of the chosen ship's, or back to its icon (`0x00523A04`,
/// `missile_flight_create`, `0x00445D80`): a copy of its model with meshes of its own
/// (`node_tree_meshes_copy`, `0x0044B3B0`), unlit and added, at `anims.missile_scale`; the object
/// of the interface that stands for it, shown and not clickable; its Attach Missile, and the
/// missile.
const Flight = struct {
    loaded: srofiles.Loaded,
    model: objects.Model,
    object: i3d.Object,
    attach: anims.Pair,
    missile: tables.Missile,
};

/// How many missiles may fly at once (`0x00523A04`, 20 slots).
const max_flights = 20;

/// The chosen ship's racks the loadout keeps account of, as it empties them and fits them
/// (`0x00524560`): those its missile hardpoints' markers stand for once they are made
/// (`markers_make`), or every rack once a missile has been hung on it at once (`rack_fit`), until
/// the markers are made again.
const Counted = union(enum) {
    markers: usize,
    every_rack,

    /// How many racks it counts.
    fn count(counted: Counted) usize {
        return switch (counted) {
            .markers => |made| made,
            .every_rack => gameobj.max_racks,
        };
    }
};

/// How a missile comes to hang on the chosen ship (`rack_fit`'s last argument): at once, as the
/// racks are fitted all together, or flown there from its icon.
const Hanging = enum { at_once, flown };

/// Where an Attach Missile takes a copy of a missile (`anim_attach_missile`'s data,
/// `0x00448B8A`): to the next empty hardpoint of the chosen ship's, or back to its icon from the
/// hardpoint of rack `from_rack`.
const Route = union(enum) {
    to_next_empty,
    from_rack: usize,
};

/// The light masks of the missiles hung on the chosen ship, which the red light and the ambient
/// light reach (`0x0044AC40`), so that they glow in with the red light's fade.
const hung_light_mask = 0xFFFE;

/// The share of the chosen ship's scale a missile hung on it takes (`0x0044B064`, `0x004DC410`).
const hung_share: f32 = 0.8;

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
    /// The plane the internal guns view sweeps across the chosen ship (`0x00523958`), and its sweep
    /// (`0x005245C4`); the two portals that follow the plane, the first clipping the gunship and
    /// the second the ship, on either side of it (`gun portal1`, `0x00523EB4`; `gun portal2`,
    /// `0x00523EB0`); and whether the view is open (`loadout_guns_open`, `0x00524610`).
    clipper: hologram.Panel = undefined,
    clip_sweep: anims.Pair = undefined,
    gunship_portal: srapiext.Portal = .{},
    ship_portal: srapiext.Portal = .{},
    guns_open: bool = false,
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
    /// Each missile's figures, worked out as it loads (`loadout_missile_bars_init`, `0x0044B680`).
    missile_figures: [tables.missile_count]tables.MissileFigures = undefined,
    /// The missiles' models (`0x00524450`), loaded with their red textures
    /// (`loadout_weapon_models`, `0x00524977`), whose meshes their icons and the missiles hung on
    /// the chosen ship share; and their icons on the arc.
    missile_models: [tables.missile_count]srofiles.ModelFile = undefined,
    icons: [tables.missile_count]Icon = undefined,
    /// The Ship Missile objects (`0x00524228`): each stands for the missile hung on a rack of the
    /// chosen ship's, whose press flies it back to its icon.
    ship_missiles: [racks.max_hardpoints]i3d.Object = undefined,
    /// The chosen ship's racks.
    fitted: racks.Racks = .{},
    /// The markers of the chosen ship's missile hardpoints (`0x005246D4`), and the racks the
    /// loadout keeps account of (`0x00524560`).
    markers: [racks.max_hardpoints]?*hologram.Marker = @splat(null),
    counted: Counted = .{ .markers = 0 },
    /// The markers' texture (`hpoints`, `0x005245E4`), which the loading requires.
    marker_image: ?*srtexture.Image = null,
    /// The missiles flying to the chosen ship or back to their icons.
    flights: [max_flights]?*Flight = @splat(null),
    /// How many Attach Missiles have been made and have not ended (`0x00524750`): the next
    /// missile clicked flies past as many empty hardpoints.
    attaching: usize = 0,
    /// The missile the info panel shows (`0x00523968`), none while it shows the chosen ship.
    shown_missile: ?tables.Missile = null,
    /// Ship to Belly Up (`0x00523E80`), made again each time the missile page is turned to.
    belly_up: ?anims.Pair = null,
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
    /// The missiles' models are loaded with their red textures and made into their icons, the
    /// ships' gun models into their gunships, and the ships' and the missiles' sinkings built.
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
        textures.files = resources.mods.textures();

        // The ships the tier or the rank offers (`loadout_ships_create`, `0x00444760`), each an
        // object of the interface whose tooltip is its name (`0x00441E43` on), reached by the green
        // and the ambient lights alone (`0x00446070`).
        const offered = offeredShips(loadout.tier, context.rank);
        loadout.first_slot = (tables.arc_slot_count - offered) / 2;
        loadout.ships = try arena.alloc(Ship, offered);
        // Nothing hung on any ship yet, as `destroy` finds them should the loading stop part way.
        for (loadout.ships) |*ship| ship.model.hung = &.{};
        for (loadout.ships, 0..) |*ship, index| {
            try loadout.makeShip(ship, @intCast(index));
            ship.object = .create(0, context.strings.string(tables.ships[index].name), true);
            ship.object.press = pressShip;
            ship.object.target = .{ .tree = &ship.model };
            for (ship.model.parts) |*part| part.object.light_mask = ship_light_mask;
        }
        // The missiles' models with their red textures (`0x00441D84` on), and their icons
        // (`missiles_create`, `0x004447F0`).
        for (&loadout.missile_models, &loadout.icons, tables.missiles) |*file, *icon, record| {
            file.* = try loadout.loadModel(record.model, .loadout_weapons);
            try loadout.makeIcon(icon, file.*, record);
        }
        // Each ship's gunship (`0x00441E08` on, `gunships_create`, `0x004447C0`).
        for (loadout.ships, 0..) |*ship, index| try loadout.makeGunship(&ship.gunship, @intCast(index));
        // The Ship Missile objects, not clickable and standing for nothing until a missile is hung
        // on their rack (`0x0044218A` on).
        for (&loadout.ship_missiles) |*object| {
            object.* = .create(0, null, false);
            object.press = pressShipMissile;
            object.shown = false;
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
        loadout.missile_figures = bars.missileFigures(context.missile_stats);

        for (loadout.ships) |*ship| try loadout.interface.addObject(&ship.object, "");
        for (&loadout.icons) |*icon| try loadout.interface.addObject(&icon.object, "");
        for (loadout.ships) |*ship| try loadout.interface.addObject(&ship.gunship.object, "");
        for (&loadout.ship_missiles) |*object| try loadout.interface.addObject(object, ship_missile_name);
        const glow = try matmanager.textureRequire(textures, glow_name);
        try loadout.makeGlow(glow);
        var plates: [4]?*srtexture.Image = undefined;
        for (&plates, plate_names) |*plate, plate_name| plate.* = try matmanager.textureRequire(textures, plate_name);
        loadout.cursor_image = try matmanager.textureRequire(textures, cursor_name);
        loadout.marker_image = try matmanager.textureRequire(textures, marker_name);
        try loadout.makeDisc(plates);
        try loadout.makePanels(glow);
        loadout.place();
        for (&loadout.button_appears.values, std.enums.values(hologram.Button)) |*appears, button| {
            try anims.buttonAppears(appears, &loadout.interface, &loadout.buttons.getPtr(button).object, &loadout.glow.object, nextButtonAppears);
        }
        // Default and Remove All appear with the missile page alone.
        for (missile_buttons) |button| loadout.button_appears.getPtr(button).anim.on_share = null;
        for (&loadout.panel_zooms, [_]*hologram.Panel{ &loadout.info, &loadout.name, &loadout.title }) |*zoom, panel| {
            try anims.panelZoom(zoom, &loadout.interface, &panel.object, &loadout.glow.object);
        }
        // Each ship's sinking from its slot on the arc, and each missile's from its slot of the
        // tier's (`0x004425DA`, `0x00442600`); then the missiles put away.
        for (loadout.ships, 0..) |*ship, index| {
            try anims.sinkShip(&ship.sink, &loadout.interface, &ship.object, loadout.arcSlot(@intCast(index)), sinkShipShare, sinkShipEnded);
        }
        for (&loadout.icons, tables.missile_slots[loadout.tier]) |*icon, slot| {
            try anims.sinkMissile(&icon.sink, &loadout.interface, &icon.object, loadout.missileSlot(slot), sinkMissileShare, sinkMissileEnded);
        }
        loadout.hideMissiles();
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
        const file = try loadout.loadModel(tables.ships[index].model, .loadout_ships);
        ship.* = .{
            .model = try .create(arena, file.model, file.loaded, .{}),
            .loaded = file.loaded,
            .object = undefined,
            .levels = try arena.alloc(srapiext.Level, file.loaded.parts.len),
            .zoom = undefined,
            .sink = undefined,
            .gunship = undefined,
        };
        // Room for the missiles the missile page hangs on its racks.
        ship.model.hung = try arena.alloc(?objects.Model.Mount, gameobj.max_racks);
        @memset(ship.model.hung, null);
        gameobj.linkParts(&ship.model, file.model);
        ship.model.place(@splat(0), math.identity);
        litBlend(file.loaded, true, .off);
        ship.showLevel(0);
    }

    /// `model_load` (`0x004A44D0`) of `file` from `resource.hog`, its textures named with
    /// `prefix`'s letter and decoded with the loadout's palette, made in the loadout's arena.
    fn loadModel(loadout: *Loadout, file: []const u8, prefix: srofiles.Prefix) !srofiles.ModelFile {
        const arena = loadout.arena.allocator();
        const source = try arena.create(shp.Model);
        source.* = try .parse(arena, try loadout.context.rooms.resources.readFile(arena, file));
        const loaded = try arena.create(srofiles.Loaded);
        loaded.* = try srofiles.modelLoad(arena, &loadout.textures.?, source, .{ .hardware = loadout.context.hardware, .prefix = prefix }, false);
        return .{ .model = source, .loaded = loaded };
    }

    /// `missile_icon_create` (`0x00445EF0`) and the icon's object (`0x00441F64` on): a tree of
    /// `file`'s model standing at the origin, lit and opaque, at `anims.missile_scale`; an object of
    /// the interface whose tooltip is the missile's name, not clickable until the missile page
    /// offers it, whose press flies a copy of the missile to the chosen ship (`pressIcon`) and
    /// whose pointer's coming onto it shows the missile on the info panel (`enterIcon`); reached
    /// by the green and the ambient lights alone.
    fn makeIcon(loadout: *Loadout, icon: *Icon, file: srofiles.ModelFile, record: tables.MissileRecord) !void {
        icon.model = try .create(loadout.arena.allocator(), file.model, file.loaded, .{});
        gameobj.linkParts(&icon.model, file.model);
        icon.model.place(@splat(0), math.identity);
        litBlend(file.loaded, true, .off);
        i3d.scaleTree(&icon.model, anims.missile_scale);
        icon.object = .create(0, loadout.context.strings.string(record.name), false);
        icon.object.press = pressIcon;
        icon.object.enter = enterIcon;
        icon.object.target = .{ .tree = &icon.model };
        for (icon.model.parts) |*part| part.object.light_mask = ship_light_mask;
    }

    /// `gunship_object_create` (`0x00445CC0`) and its object (`0x00442059` on): ship type `index`'s
    /// gunship, a tree of the ship's gun model loaded with its red textures
    /// (`loadout_weapon_models`, `0x00524977`), linked and standing at the origin, its parts lit as
    /// `gunshipLightMasks` says and given a faint green of their own (`node_tree_colour`,
    /// `0x00449310`); an object of the interface whose tooltip is the ship's name, not clickable,
    /// and put away. The game names the object after its ship with ` GS` after it
    /// (`0x00442103`), a name nothing looks for, and makes the gunships of all twelve ships, where
    /// OpenReliant makes those of the ships offered, the only ones the view shows.
    fn makeGunship(loadout: *Loadout, gunship: *Gunship, index: u8) !void {
        const file = try loadout.loadModel(tables.ships[index].guns_model, .loadout_weapons);
        gunship.model = try .create(loadout.arena.allocator(), file.model, file.loaded, .{});
        gameobj.linkParts(&gunship.model, file.model);
        gunship.model.place(@splat(0), math.identity);
        gunshipLightMasks(&gunship.model, file.loaded);
        for (gunship.model.parts) |*part| part.object.colour = gunship_colour;
        gunship.object = .create(0, loadout.context.strings.string(tables.ships[index].name), false);
        gunship.object.target = .{ .tree = &gunship.model };
        gunship.object.shown = false;
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
    /// it appears; the two scrollers, facing away; the ship clipper, a square of `glow` on both its
    /// faces, put away, and its sweep (Move Clip Point); and the flips of the two ship panels.
    ///
    /// **Fix:** the game makes the ship clipper clickable, as it makes every panel, and the pointer
    /// finds it though it is put away. Standing at the origin at its whole size until the guns
    /// view first sweeps it, it covers the chosen ship and takes the pointer from the hardpoints'
    /// markers, which come after it, so that their tooltip shows only once the view has been
    /// opened. OpenReliant's is not clickable.
    ///
    /// Not ported: the panel's clip object and its own Move Clip Point (`0x00523E7C`,
    /// `0x00448EF0`), which belong to a view nothing opens (`0x0044A470`).
    fn makePanels(loadout: *Loadout, glow: *srtexture.Image) !void {
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
        try loadout.clipper.make(loadout.arena.allocator(), &loadout.interface, .ship_clipper, glow, glow, true, hologram.clipper_size, .whole);
        loadout.clipper.object.shown = false;
        loadout.clipper.object.clickable = false;
        try anims.moveClipPoint(&loadout.clip_sweep, &loadout.interface, &loadout.clipper.object, sweepStep, sweepEnded);
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
    /// `front`'s figures and its back with `back`'s (`drawInfo`), the name panels' front with
    /// `front`'s name and their back with `back`'s (`panel_title_draw`).
    fn drawPanels(loadout: *Loadout, front: u8, back: u8) void {
        loadout.drawInfo(.front, .{ .ship = front });
        loadout.drawInfo(.back, .{ .ship = back });
        const title = &loadout.title_textures;
        panels.drawTitle(title.get(.front).pixels, loadout.panels_art, loadout.kit(), front);
        panels.drawTitle(title.get(.back).pixels, loadout.panels_art, loadout.kit(), back);
        for (&title.values) |*texture| texture.image.changed = true;
    }

    /// What the info panel shows on a face: a ship's figures, a missile's, or a ship's guns.
    const Info = union(enum) {
        ship: u8,
        missile: tables.Missile,
        guns: u8,
    };

    /// The info panel's `face` drawn with `info` (`loadout_draw_stats`, `0x00444F20`;
    /// `missile_info_draw`, `0x004456F0`; `guns_draw`, `0x00445490`).
    fn drawInfo(loadout: *Loadout, face: panels.Face, info: Info) void {
        const texture = loadout.info_textures.getPtr(face);
        switch (info) {
            .ship => |ship| panels.drawStats(texture.pixels, loadout.kit(), ship, loadout.figures[ship]),
            .missile => |missile| panels.drawMissile(texture.pixels, loadout.kit(), missile, loadout.missile_figures[@intFromEnum(missile)]),
            .guns => |ship| panels.drawGuns(texture.pixels, loadout.kit(), ship),
        }
        texture.image.changed = true;
    }

    /// What the panels are drawn with.
    fn kit(loadout: *const Loadout) panels.Kit {
        return .{
            .title_font = &loadout.title_font,
            .info_font = &loadout.stats_font,
            .palette = &loadout.palette,
            .strings = loadout.context.strings,
        };
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
            if (index != loadout.chosen) i3d.scaleTree(&ship.model, enter_scale / (anims.arc_unit * tables.ships[index].scale));
        }
        // Each gunship at its ship's own scale (`0x00442BD0` on).
        for (loadout.ships, 0..) |*ship, index| i3d.scaleTree(&ship.gunship.model, tables.ships[index].scale);
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
        for (loadout.ships, 0..) |*ship, index| {
            if (loadout.showsShip(index)) continue;
            ship.object.clickable = false;
            ship.object.shown = false;
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
        if (loadout.page == .missiles and !loadout.interface.busy) loadout.highlightMissile(hovered);
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
    /// every four seconds from when it began, tilted back about X. Where no selection is flying
    /// the ship: while it turns back from belly up, Ship to Belly Up's first key takes the turn's
    /// angles, which it turns back to; otherwise the ship takes the turn while the interface is
    /// not busy, once it has turned back, or while the internal guns view is open, and then its
    /// gunship too (`0x00447235` on).
    fn spinShip(loadout: *Loadout) void {
        const angle = @as(f32, @floatFromInt(loadout.now -% loadout.spin_start)) * spin_rate;
        loadout.spin = math.turned(math.turned(math.fromAngles(0, 0, 0), .y, angle), .x, spin_tilt);
        if (loadout.select) |select| if (!select.stopped()) return;
        if (loadout.belly_up) |*belly_up| if (!belly_up.stopped()) {
            belly_up.frames[0].key.angles = math.angles(loadout.spin);
            return;
        };
        if (loadout.turned_back or !loadout.interface.busy or loadout.guns_open) {
            const ship = &loadout.ships[loadout.chosen];
            ship.object.setOrientation(loadout.spin);
            if (loadout.guns_open) ship.gunship.object.setOrientation(loadout.spin);
        }
    }

    /// The missile page's highlight (`0x004435C3` to `0x00443639`): each missile's icon lit but
    /// the one under the pointer, and a missile hung on the ship under the pointer unlit. The
    /// icons and the missiles hung on the ship share their models' meshes, so a missile under the
    /// pointer lights up with every other of its kind.
    fn highlightMissile(loadout: *Loadout, hovered: ?*i3d.Object) void {
        for (&loadout.icons, &loadout.missile_models) |*icon, file| litBlend(file.loaded, hovered != &icon.object, .off);
        for (&loadout.ship_missiles, loadout.fitted.racks[0..racks.max_hardpoints]) |*object, rack| {
            if (object.target == .none or hovered != object) continue;
            litBlend(loadout.missile_models[@intFromEnum(rack.missile)].loaded, false, .off);
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
    /// portal and the internal guns view's two (`0x00443657`, `0x00443667`); and what the device's
    /// background holds.
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
        for ([_]*srapiext.Portal{ &loadout.disc_portal, &loadout.gunship_portal, &loadout.ship_portal }) |portal| {
            try xtrabits.sceneAdd(gpa, scene, .{ .portal = portal }, .world);
        }
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

    /// `disc_portal_ship` (`0x00449200`) and `disc_portal_missile` (`0x00449250`): the disc's
    /// portal put in the disc's plane, facing along its axis, and set on a ship's or a missile's
    /// `tree` to clip what sinks below the disc.
    fn clipToDisc(loadout: *Loadout, tree: *objects.Model) void {
        const disc = &loadout.disc.scene_object;
        loadout.disc_portal.position = disc.position;
        loadout.disc_portal.normal = math.forward(disc.orientation);
        clipTree(tree, &loadout.disc_portal);
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
    /// and clipped by the disc, and each missile's icon clipped by it; a frame run again; the disc,
    /// its glow and the ships on the arc grabbed as the background, and the chosen ship, the
    /// panels, the buttons and the scrollers shown before it; the rectangles made again two frames
    /// on; the interface free; the cursor made; and the chosen ship's missiles hung on it
    /// (`fitStartingRacks`).
    fn buildShipPage(loadout: *Loadout) Allocator.Error!void {
        for (loadout.ships, 0..) |*ship, index| {
            if (index != loadout.chosen) ship.showLevel(0);
            loadout.clipToDisc(&ship.model);
        }
        for (&loadout.icons) |*icon| loadout.clipToDisc(&icon.model);
        _ = try loadout.step(.{ .now = loadout.now, .mouse = loadout.interface.last });
        try loadout.grabShipPage(true);
        const arena = loadout.arena.allocator();
        const cursor = try arena.create(i3d.Cursor);
        try cursor.create(arena, &loadout.interface, loadout.cursor_image);
        cursor.scene_object.light_mask = cursor_light_mask;
        loadout.cursor = cursor;
        try loadout.fitStartingRacks();
    }

    /// The chosen ship's missiles as the ship page is first built (`0x00446918`): the tier's
    /// (`fitTierDefault`) in the first mission and in mission 23, the campaign's saved racks
    /// (`fitSaved`) otherwise, each glowing in with the red light's fade.
    ///
    /// **Fix:** where the saved ship is one the loadout does not offer, OpenReliant starts on the
    /// Predator (`chosenFor`) and fits it the tier's missiles, where the saved racks are another
    /// ship's.
    fn fitStartingRacks(loadout: *Loadout) Allocator.Error!void {
        const mission = loadout.context.mission;
        if (mission == first_mission or mission == shroud_mission or loadout.context.saved.ship != loadout.chosen) {
            return loadout.fitTierDefault();
        }
        try loadout.fitSaved();
    }

    /// The page's still part grabbed as the device's background, as the Spin Disc's end and the
    /// resume grab it (`0x0044675A` to `0x004468EF`, `0x0043777F` to `0x004439A5`): the panels,
    /// the buttons, the scrollers and the cursor put away, and the disc and its glow shown, with
    /// the ships the page offers but the chosen one on the ship page, and on the missile page the
    /// missiles it offers (`missilesAvailable`) and the chosen ship, and grabbed; then the other
    /// way round, the missiles put away, the ships' rectangles made again two frames on, and the
    /// interface free. Where `placing`, as at the Spin Disc's end, the ships are placed each time
    /// the scene is made.
    ///
    /// The resume puts the ship clipper away, and the gunship with the ship while it is grabbed
    /// where the internal guns view is open (`0x00443883` to `0x0044389B`, `0x00443970`); as the
    /// Spin Disc ends, the view is closed and the clipper put away already.
    fn grabShipPage(loadout: *Loadout, placing: bool) Allocator.Error!void {
        const gpa = loadout.context.rooms.gpa;
        const gunship = &loadout.ships[loadout.chosen].gunship;
        loadout.showPanels(false);
        if (loadout.page == .missiles) {
            loadout.missilesAvailable();
        } else for (loadout.ships, 0..) |*ship, index| {
            if (loadout.showsShip(index)) ship.object.shown = true;
        }
        loadout.showStill(true);
        if (loadout.page != .missiles) loadout.ships[loadout.chosen].object.shown = false;
        for (&loadout.scrollers) |*scroller| scroller.object.shown = false;
        if (loadout.cursor) |cursor| cursor.object.shown = false;
        loadout.clipper.object.shown = false;
        if (loadout.guns_open) gunship.object.shown = false;
        try loadout.interface.scene(gpa, &loadout.scene, false, treeToScene);
        if (placing) loadout.placeShips();
        try loadout.captureBackground();
        loadout.showPanels(true);
        for (loadout.ships) |*ship| ship.object.shown = false;
        for (&loadout.scrollers) |*scroller| scroller.object.shown = true;
        loadout.showStill(false);
        if (loadout.cursor) |cursor| cursor.object.shown = true;
        loadout.ships[loadout.chosen].object.shown = true;
        if (loadout.guns_open) gunship.object.shown = true;
        loadout.hideMissiles();
        try loadout.interface.scene(gpa, &loadout.scene, false, treeToScene);
        if (placing) loadout.placeShips();
        loadout.rect_countdown = rect_frames;
        loadout.hideShipsButChosen();
        loadout.showStill(false);
        loadout.interface.busy = false;
    }

    /// Whether the loadout shows ship `index`: every ship it offers, but in mission 23 the Shroud
    /// alone (`0x0044341E`).
    fn showsShip(loadout: *const Loadout, index: usize) bool {
        return loadout.context.mission != shroud_mission or index == shroud;
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

    /// A ship's press (`0x00447C00`): the ship pressed selected, unless a selection is flying. With
    /// the internal guns view open, the view closes first, unless the ship pressed is the chosen
    /// one; the selection waits on the interface's stack until it has, and the view waits under it
    /// to open again once the ship has arrived (`selectEnded`).
    fn pressShip(context: *anyopaque, _: *i3d.Object, press: i3d.Press) void {
        const loadout = of(context);
        const ship: u8 = @intCast(press.index);
        if (loadout.guns_open and ship == loadout.chosen) return;
        if (loadout.select) |select| if (!select.stopped()) return;
        if (!loadout.guns_open) {
            loadout.selectShip(ship) catch |err| log.warn("the ship is not selected: {s}", .{@errorName(err)});
            return;
        }
        loadout.toggleGuns();
        loadout.interface.push(stackGunsView, 0) catch |err| log.warn("the internal guns view stays closed: {s}", .{@errorName(err)});
        loadout.interface.push(stackSelectShip, ship) catch |err| log.warn("the ship is not selected: {s}", .{@errorName(err)});
    }

    /// `ship_select` (`0x00447E20`): ship `new` chosen in place of the chosen one, unless it is
    /// that one. The red light fades out; the old ship and the new are put away and the rest shown,
    /// grabbed as the background with the disc; the new ship can no longer be clicked and the old
    /// one can again; the panels' fronts drawn with the old ship and their backs with the new,
    /// turned front on and then flipped over; the new ship flies to the chosen spot and the old one
    /// back to its slot; and the interface is busy while they fly.
    ///
    /// The old ship's missiles are taken off first (`clearRacks`).
    fn selectShip(loadout: *Loadout, new: u8) Allocator.Error!void {
        if (new == loadout.chosen) return;
        const gpa = loadout.context.rooms.gpa;
        const old = loadout.chosen;
        loadout.red_fade = -1;
        loadout.clearRacks();
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
            } else if (loadout.showsShip(index)) {
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

    /// Select Ship's end (`0x00446EF0`): the chosen ship's turn begins again from now, the
    /// interface is free, and the tier's missiles are hung on it at once (`fitTierDefault`). Where
    /// the internal guns view waits on top of the interface's stack, as a ship pressed with the
    /// view open leaves it, it opens (`0x00446F57`).
    fn selectEnded(context: *anyopaque, _: *i3d.Anim) void {
        const loadout = of(context);
        loadout.spin_start = loadout.now;
        loadout.interface.busy = false;
        loadout.fitTierDefault() catch |err| log.warn("the ship's missiles are left off: {s}", .{@errorName(err)});
        const waiting = loadout.interface.stack.getLastOrNull() orelse return;
        if (waiting.function == &stackGunsView) loadout.interface.runDeferred();
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

    /// Ship Selection's release (`0x004475D0`): the internal guns view closed where it is open,
    /// and otherwise the ship page.
    fn releaseShips(context: *anyopaque, object: *i3d.Object, _: i3d.Press) void {
        releaseButton(object);
        const loadout = of(context);
        if (loadout.guns_open) return loadout.toggleGuns();
        loadout.switchPage(.ships);
    }

    /// View Internal Guns' release (`0x00447670`): the internal guns view opened or closed
    /// (`toggleGuns`). On the missile page, the view waits on the interface's stack while the ship
    /// page is turned to, and opens once the page is built.
    fn releaseGuns(context: *anyopaque, object: *i3d.Object, _: i3d.Press) void {
        releaseButton(object);
        const loadout = of(context);
        if (loadout.page != .missiles) return loadout.toggleGuns();
        loadout.interface.push(stackGunsView, 0) catch |err| log.warn("the internal guns view stays closed: {s}", .{@errorName(err)});
        loadout.switchPage(.ships);
    }

    /// Use Default Loadout's release (`0x00447530`), on the missile page: tier 0's missiles flown
    /// to the hardpoints (`fitDefault`).
    fn releaseDefault(context: *anyopaque, object: *i3d.Object, _: i3d.Press) void {
        releaseButton(object);
        of(context).fitDefault();
    }

    /// Remove All Missiles' release (`0x00447560`), on the missile page: every rack emptied
    /// (`clearRacks`) and every marker shown; the missile page's objects shown and the missiles
    /// offered again.
    fn releaseRemoveAll(context: *anyopaque, object: *i3d.Object, _: i3d.Press) void {
        releaseButton(object);
        const loadout = of(context);
        loadout.clearRacks();
        loadout.showMarkers(true);
        loadout.showMissilePage();
        loadout.missilesAvailable();
    }

    /// `page_switch` (`0x00449D90`): page `page`, where it is not the one shown, the one shown
    /// kept as the last (`loadout_last_page`, `0x00524620`). With the internal guns view open, the
    /// missile page waits on the interface's stack while the view closes, and the ship page stays
    /// the page shown until it does (`0x00449DB9` on).
    fn switchPage(loadout: *Loadout, page: Page) void {
        if (page == loadout.page) return;
        loadout.last_page = loadout.page;
        loadout.page = page;
        switch (page) {
            .ships => loadout.toShipPage(),
            .missiles => {
                if (loadout.guns_open) {
                    loadout.interface.push(stackMissilePage, 0) catch |err| log.warn("the missile page is not turned to: {s}", .{@errorName(err)});
                    loadout.toggleGuns();
                    loadout.page = .ships;
                    return;
                }
                loadout.toMissilePage() catch |err| log.warn("the missile page is left unfinished: {s}", .{@errorName(err)});
            },
        }
    }

    /// `page_switch`'s way back to the ship page (`0x00449DB8` to `0x00449F10`): the interface
    /// busy; the missiles offered, and not clickable; every ship the page offers clickable, those
    /// on the arc at the coarse level; the markers not clickable; the chosen ship, the disc and
    /// its glow shown over the backdrop. The markers zoom away one after another and the ship
    /// turns back from belly up after them, or at once with none; the missiles sink one after
    /// another; the info panel's front drawn with the chosen ship; Use Default Loadout and Remove
    /// All Missiles fly back into the glow, and the info panel flips back to its front.
    fn toShipPage(loadout: *Loadout) void {
        const now = loadout.now;
        loadout.interface.busy = true;
        loadout.missilesAvailable();
        for (&loadout.icons) |*icon| icon.object.clickable = false;
        for (loadout.ships, 0..) |*ship, index| {
            if (loadout.showsShip(index)) {
                ship.object.clickable = true;
                if (index != loadout.chosen) ship.showLevel(loadout.coarse);
            }
        }
        for (loadout.shownMarkers()) |maybe| if (maybe) |marker| {
            marker.panel.object.clickable = false;
        };
        loadout.ships[loadout.chosen].object.shown = true;
        loadout.showStill(true);
        loadout.showBackdrop();
        if (loadout.counted.count() == 0) {
            loadout.turnBack() catch |err| log.warn("the ship is left belly up: {s}", .{@errorName(err)});
        } else loadout.nextMarkerZooms(null, .back);
        loadout.nextMissileSinks(null);
        loadout.drawInfo(.front, .{ .ship = loadout.chosen });
        loadout.missileButtonsAppear(.back);
        loadout.flip_info.play(.back, now);
    }

    /// `page_switch`'s way to the missile page (`0x00449F18` on): the interface busy; the missiles
    /// offered; every ship the page offers shown but not clickable, those on the arc at the coarse
    /// level; the backdrop behind the disc and its glow, shown; the info panel showing no missile;
    /// Use Default Loadout and Remove All Missiles flying out of the glow; the chosen ship turning
    /// belly up (`anims.bellyUp`); the missiles offered put on their slots of the arc, sunk into
    /// the disc; and from the ship page, the ships on the arc sinking one after another, which the
    /// missiles rise after; otherwise the missiles rising at once.
    fn toMissilePage(loadout: *Loadout) Allocator.Error!void {
        const now = loadout.now;
        loadout.interface.busy = true;
        loadout.missilesAvailable();
        for (loadout.ships, 0..) |*ship, index| {
            if (loadout.showsShip(index)) {
                ship.object.shown = true;
                ship.object.clickable = false;
                if (index != loadout.chosen) ship.showLevel(loadout.coarse);
            }
        }
        loadout.showBackdrop();
        loadout.showStill(true);
        loadout.shown_missile = null;
        if (loadout.belly_up) |*old| loadout.interface.removeAnim(&old.anim);
        loadout.missileButtonsAppear(.forward);
        loadout.belly_up = @as(anims.Pair, undefined);
        const belly_up = &loadout.belly_up.?;
        try anims.bellyUp(belly_up, &loadout.interface, &loadout.ships[loadout.chosen].object, loadout.spin, tables.ships[loadout.chosen].scale, bellyUpEnded);
        belly_up.play(.forward, now);
        loadout.missilesAvailable();
        loadout.placeMissiles();
        for (&loadout.icons) |*icon| icon.object.setPosition(icon.object.position() + Vector{ 0, anims.sink_depth, 0 });
        if (loadout.last_page == .ships) loadout.nextShipSinks(null, .forward) else loadout.nextMissileRises(null);
    }

    /// `loadout_exit` (`0x00447730`), once the disc has spun in: Enriquez stops, the interface is
    /// busy and nothing is under the pointer; the disc, its glow and every ship offered shown, the
    /// ships clipped no more and on the arc at the coarse level; everything spins and zooms back
    /// into the glow, easing out, the first buttons after one another; the chosen ship kept in the
    /// campaign's loadout; the hum ends and the exit's sound plays. The disc's spin's end ends the
    /// loadout.
    ///
    /// The markers, the Ship Missiles and the missiles' icons are put away, and on the missile
    /// page Use Default Loadout and Remove All Missiles fly back into the glow too.
    ///
    /// With the internal guns view open, the view closes first, and the exit waits on the
    /// interface's stack until it has (`0x00447767` on).
    fn exit(loadout: *Loadout) void {
        if (!loadout.spin_disc.stopped()) return;
        const now = loadout.now;
        loadout.stopSpeech();
        loadout.spin_disc.frames[0].scale = .out;
        loadout.info.scene_object.flags.portal_clipped = false;
        if (loadout.guns_open) {
            loadout.interface.push(stackExit, 0) catch |err| log.warn("the loadout's exit is left undone: {s}", .{@errorName(err)});
            loadout.toggleGuns();
            return;
        }
        loadout.interface.busy = true;
        loadout.interface.hovered = null;
        loadout.showStill(true);
        for (loadout.ships, 0..) |*ship, index| {
            ship.zoom.frames[0].scale = .out;
            ship.zoom.play(.back, now);
            ship.clip(null);
            if (loadout.showsShip(index)) {
                ship.object.shown = true;
                if (index != loadout.chosen) ship.showLevel(loadout.coarse);
            }
        }
        loadout.showMarkers(false);
        for (&loadout.ship_missiles) |*object| object.shown = false;
        loadout.hideMissiles();
        for (&loadout.panel_zooms) |*zoom| zoom.play(.back, now);
        loadout.button_appears.getPtr(.missiles).play(.back, now);
        loadout.showBackdrop();
        loadout.spin_disc.play(.back, now);
        loadout.glow_appears.play(.back, now);
        if (loadout.page == .missiles) loadout.missileButtonsAppear(.back);
        loadout.context.saved.ship = loadout.chosen;
        if (loadout.hum) |voice| loadout.context.rooms.sound.endVoice(voice);
        loadout.hum = null;
        _ = loadout.playSound(.exit, hog_snd.loudest, hog_snd.once, hog_snd.own_pitch);
    }

    /// `loadout_resume` (`0x00443760`), after the in-game options' BACK at `now`: once the disc has
    /// spun in, a frame run, and the page's background grabbed again (`grabShipPage`): the disc,
    /// its glow and the ships on the arc, or on the missile page the missiles and the chosen ship;
    /// and the interface free.
    ///
    /// **Fix:** the in-game options end every sound, the hum's among them, and the game never plays
    /// the hum again, leaving the hologram silent for the rest of the loadout. OpenReliant starts it
    /// again, where the exit has not ended it.
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

    /// `loadout_leave` (`0x00442CC0`): what the loadout leaves the mission, the chosen ship and
    /// the missile types on its racks, once it has let go of its sounds and speech
    /// (`speech_stop_all`, `sound_end_all`); the racks kept in the campaign's saved loadout too.
    pub fn leave(loadout: *Loadout) Result {
        loadout.stopSpeech();
        if (loadout.entered) {
            loadout.context.rooms.sound.endAll();
            loadout.context.saved.racks = loadout.fitted.saved();
        }
        loadout.entered = false;
        return .{ .ship = loadout.chosen, .racks = loadout.fitted.flown(), .tier = loadout.tier };
    }

    /// Lets go of everything the loadout holds.
    pub fn destroy(loadout: *Loadout) void {
        const gpa = loadout.context.rooms.gpa;
        for (&loadout.flights) |*slot| if (slot.*) |flight| {
            freeFlight(gpa, flight);
            slot.* = null;
        };
        for (loadout.ships) |*ship| for (ship.model.hung) |*held| unhang(gpa, held);
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
        loadout.speech_line = context.readLine(speech_name) orelse return;
        rooms.say(context, &loadout.speech, loadout.speech_line, videoreports.lineName(speech_name), .in_person, null);
    }

    /// `speech_stop_all`: the speech ended and its file let go of.
    fn stopSpeech(loadout: *Loadout) void {
        const context = loadout.context.rooms;
        loadout.speech.stop(context.gpa, context.sound);
        context.gpa.free(loadout.speech_line);
        loadout.speech_line = &.{};
    }

    // --- The missile page --------------------------------------------------------------------

    /// The markers of the racks the loadout counts (`counted`), as far as the markers reach.
    fn shownMarkers(loadout: *Loadout) []?*hologram.Marker {
        return loadout.markers[0..@min(loadout.counted.count(), loadout.markers.len)];
    }

    /// The markers of the racks the loadout counts shown or put away.
    fn showMarkers(loadout: *Loadout, shown: bool) void {
        for (loadout.shownMarkers()) |maybe| if (maybe) |marker| {
            marker.panel.object.shown = shown;
        };
    }

    /// Use Default Loadout's and Remove All Missiles' appearing played `direction`'s way.
    fn missileButtonsAppear(loadout: *Loadout, direction: i3d.Direction) void {
        for (missile_buttons) |button| loadout.button_appears.getPtr(button).play(direction, loadout.now);
    }

    /// Where missile slot `slot` of the arc stands as the disc stands, facing away from its axis,
    /// which a missile's sinking starts from (`0x0044881E`). A missile the tier doesn't offer has
    /// none, where the game reads what lies before the slots; OpenReliant sinks its icon, which
    /// is never shown, from the disc's centre.
    fn missileSlot(loadout: *Loadout, slot: ?u8) anims.Placed {
        const disc = loadout.disc.scene_object.place();
        const at = slot orelse return .{ .position = disc.position, .angles = @splat(0) };
        return hologram.slotPlace(disc, tables.arc_slots[at], true, hologram.slot_unit);
    }

    /// `missiles_place` (`0x00449590`): each missile the tier offers put on its slot of the arc as
    /// the disc stands (`tables.missile_slots`), facing away from its axis, across and down scaled
    /// by the disc's size while it spins.
    fn placeMissiles(loadout: *Loadout) void {
        const disc = &loadout.disc.scene_object;
        const across = if (loadout.spin_disc.stopped()) hologram.slot_unit else disc.scale * hologram.slot_unit;
        for (&loadout.icons, tables.missile_slots[loadout.tier]) |*icon, slot| {
            const at = slot orelse continue;
            const placed = hologram.slotPlace(disc.place(), tables.arc_slots[at], true, across);
            icon.object.setPosition(placed.position);
            icon.object.setOrientation(math.fromAngleVector(placed.angles));
        }
    }

    /// `missiles_hide` (`0x00447130`): every missile's icon put away.
    fn hideMissiles(loadout: *Loadout) void {
        for (&loadout.icons) |*icon| icon.object.shown = false;
    }

    /// `missiles_available` (`0x0044B870`): the icon of each missile the tier offers shown and
    /// clickable while fewer than its limit are carried (`racks.available`), hung on the chosen
    /// ship, their Ship Missiles clickable, or shown flying to it or back; the rest put away.
    ///
    /// **Fix:** the game frees the data of a missile flying back to its icon as its flight begins,
    /// and counts it by what the freed memory holds. OpenReliant counts it as the missile it is.
    fn missilesAvailable(loadout: *Loadout) void {
        var carried: [tables.missile_count]u16 = @splat(0);
        for (&loadout.ship_missiles, loadout.fitted.racks[0..racks.max_hardpoints]) |*object, rack| {
            if (object.clickable) carried[@intFromEnum(rack.missile)] += 1;
        }
        for (loadout.flights) |maybe| {
            const flight = maybe orelse continue;
            if (flight.object.shown) carried[@intFromEnum(flight.missile)] += 1;
        }
        const offered = racks.available(loadout.tier, carried);
        for (&loadout.icons, std.enums.values(tables.Missile)) |*icon, missile| {
            icon.object.shown = offered.has(missile);
            icon.object.clickable = offered.has(missile);
        }
    }

    /// `ships_sink_next` (`0x004479A0`) and `ships_rise_next` (`0x00447A10`): the ship on the arc
    /// after the one whose sinking is `after`, or with none the first, the chosen passed over,
    /// sinking `direction`'s way; none past the last.
    fn nextShipSinks(loadout: *Loadout, after: ?*const i3d.Anim, direction: i3d.Direction) void {
        const next: usize = if (after) |anim| next: {
            for (loadout.ships, 0..) |*ship, index| {
                if (&ship.sink.anim != anim) continue;
                break :next if (index + 1 == loadout.chosen) index + 2 else index + 1;
            }
            return;
        } else @intFromBool(loadout.chosen == 0);
        if (next < loadout.ships.len) loadout.ships[next].sink.play(direction, loadout.now);
    }

    /// Whether `anim` is the sinking of the last ship on the arc to sink: the last's, or the one
    /// before it where the last is the chosen one (`0x0044661F` to `0x00446641`).
    fn lastToSink(loadout: *const Loadout, anim: *const i3d.Anim) bool {
        const last = loadout.ships.len - 1;
        if (anim == &loadout.ships[last].sink.anim) return true;
        return loadout.chosen == last and last > 0 and anim == &loadout.ships[last - 1].sink.anim;
    }

    /// `missiles_sink_next` (`0x00447A80`): the missile after the one whose sinking is `after`, or
    /// with none the first, sinking; none past the last.
    fn nextMissileSinks(loadout: *Loadout, after: ?*const i3d.Anim) void {
        const next = if (after) |anim| (loadout.missileSinking(anim) orelse return) + 1 else 0;
        if (next < loadout.icons.len) loadout.icons[next].sink.play(.forward, loadout.now);
    }

    /// `missiles_rise_next` (`0x00447AE0`): the missile before the one whose sinking is `after`,
    /// or with none the last, rising: its sinking played back; none before the first.
    fn nextMissileRises(loadout: *Loadout, after: ?*const i3d.Anim) void {
        const from = if (after) |anim| loadout.missileSinking(anim) orelse return else loadout.icons.len;
        if (from == 0) return;
        loadout.icons[from - 1].sink.play(.back, loadout.now);
    }

    /// Which missile's sinking `anim` is.
    fn missileSinking(loadout: *Loadout, anim: *const i3d.Anim) ?usize {
        for (&loadout.icons, 0..) |*icon, index| {
            if (&icon.sink.anim == anim) return index;
        }
        return null;
    }

    /// `markers_zoom_next` (`0x00447B40`) and `markers_unzoom_next` (`0x00447BA0`): the marker
    /// after the one whose zoom is `after`, or with none the first, zooming `direction`'s way; none
    /// past the chosen ship's hardpoints.
    fn nextMarkerZooms(loadout: *Loadout, after: ?*const i3d.Anim, direction: i3d.Direction) void {
        const markers = loadout.shownMarkers();
        const next: usize = if (after) |anim| next: {
            for (markers, 0..) |maybe, index| {
                const marker = maybe orelse continue;
                if (&marker.zoom.anim == anim) break :next index + 1;
            }
            return;
        } else 0;
        if (next >= markers.len) return;
        const marker = markers[next] orelse return;
        marker.zoom.play(direction, loadout.now);
    }

    /// Sink Ship's share (`sink_ship_share`, `0x00446610`): sinking, the next ship sinks, and as
    /// the last to sink passes its share, the missiles begin to rise, from the last; rising, the
    /// next ship rises.
    fn sinkShipShare(context: *anyopaque, anim: *i3d.Anim) void {
        const loadout = of(context);
        switch (anim.direction) {
            .forward => {
                loadout.nextShipSinks(anim, .forward);
                if (loadout.lastToSink(anim)) loadout.nextMissileRises(null);
            },
            .back => loadout.nextShipSinks(anim, .back),
        }
    }

    /// Sink Ship's end (`0x00447010`): the last ship on the arc sunk, every ship put away but the
    /// chosen; the last to rise risen, the ship page built again (`shipPageBack`).
    fn sinkShipEnded(context: *anyopaque, anim: *i3d.Anim) void {
        const loadout = of(context);
        switch (anim.direction) {
            .forward => if (anim == &loadout.ships[loadout.ships.len - 1].sink.anim) {
                for (loadout.ships) |*ship| ship.object.shown = false;
                loadout.ships[loadout.chosen].object.shown = true;
            },
            .back => if (loadout.lastToSink(anim)) {
                loadout.shipPageBack() catch |err| log.warn("the ship page is left unfinished: {s}", .{@errorName(err)});
            },
        }
    }

    /// Sink Missile's share (`0x00446660`): sinking, the next missile sinks; rising, the one
    /// before it rises.
    fn sinkMissileShare(context: *anyopaque, anim: *i3d.Anim) void {
        const loadout = of(context);
        switch (anim.direction) {
            .forward => loadout.nextMissileSinks(anim),
            .back => loadout.nextMissileRises(anim),
        }
    }

    /// Sink Missile's end (`0x00446FB0`): a missile sunk, every ship the page offers shown and the
    /// first on the arc rising, which each missile's end starts again, the last's for good; the
    /// first missile risen, the missile page ready (`missilesRisen`).
    fn sinkMissileEnded(context: *anyopaque, anim: *i3d.Anim) void {
        const loadout = of(context);
        switch (anim.direction) {
            .back => if (anim == &loadout.icons[0].sink.anim) loadout.missilesRisen(),
            .forward => {
                for (loadout.ships, 0..) |*ship, index| {
                    if (loadout.showsShip(index)) ship.object.shown = true;
                }
                loadout.nextShipSinks(null, .back);
            },
        }
    }

    /// `missiles_risen` (`0x00446950`): on the missile page, its objects shown and the interface
    /// free (`showMissilePage`), then what waits on the interface's stack; back on the ship page,
    /// the missiles put away.
    fn missilesRisen(loadout: *Loadout) void {
        if (loadout.page == .ships) return loadout.hideMissiles();
        loadout.showMissilePage();
        loadout.interface.runDeferred();
    }

    /// `missile_page_show` (`0x00446B90`): the ships put away but the chosen one; the panels, the
    /// buttons, the markers of the racks that hold nothing, the scrollers and the cursor shown;
    /// and the interface free.
    fn showMissilePage(loadout: *Loadout) void {
        for (loadout.ships) |*ship| ship.object.shown = false;
        loadout.showPanels(true);
        for (loadout.shownMarkers(), 0..) |maybe, index| if (maybe) |marker| {
            if (!loadout.fitted.racks[index].fitted) marker.panel.object.shown = true;
        };
        for (&loadout.scrollers) |*scroller| scroller.object.shown = true;
        if (loadout.cursor) |cursor| cursor.object.shown = true;
        loadout.ships[loadout.chosen].object.shown = true;
        loadout.interface.busy = false;
    }

    /// `ship_page_rebuild` (`0x004469A0`), as the last ship has risen back onto the arc: the
    /// panels, the buttons, the missiles, the markers, the scrollers, the chosen ship and the
    /// cursor put away, the disc and its glow shown, and the interface free; the ships on the arc
    /// at their finest; the disc, its glow and the ships on the arc grabbed as the background; the
    /// ships put away, those the page offers clickable again with their rectangles made again,
    /// the rest shown again as the ship page has it; and what waits on the interface's stack run.
    fn shipPageBack(loadout: *Loadout) Allocator.Error!void {
        const gpa = loadout.context.rooms.gpa;
        loadout.showPanels(false);
        loadout.hideMissiles();
        loadout.showMarkers(false);
        for (&loadout.scrollers) |*scroller| scroller.object.shown = false;
        loadout.ships[loadout.chosen].object.shown = false;
        loadout.showStill(true);
        if (loadout.cursor) |cursor| cursor.object.shown = false;
        loadout.interface.busy = false;
        for (loadout.ships, 0..) |*ship, index| {
            if (index != loadout.chosen) ship.showLevel(0);
        }
        try loadout.interface.scene(gpa, &loadout.scene, false, treeToScene);
        try loadout.captureBackground();
        for (loadout.ships, 0..) |*ship, index| {
            ship.object.shown = false;
            if (loadout.showsShip(index)) {
                ship.object.clickable = true;
                try ship.object.updateRect(loadout.frame_arena.allocator(), &loadout.view);
            }
        }
        loadout.showPanels(true);
        for (&loadout.scrollers) |*scroller| scroller.object.shown = true;
        loadout.ships[loadout.chosen].object.shown = true;
        loadout.showStill(false);
        if (loadout.cursor) |cursor| cursor.object.shown = true;
        loadout.turned_back = false;
        loadout.interface.runDeferred();
    }

    /// `belly_up_back` (`0x00446E90`): the markers put away, the scene made, and the chosen ship
    /// turning back from belly up: Ship to Belly Up started from its start as it plays forward,
    /// then turned round.
    fn turnBack(loadout: *Loadout) Allocator.Error!void {
        loadout.showMarkers(false);
        try loadout.interface.scene(loadout.context.rooms.gpa, &loadout.scene, false, treeToScene);
        const belly_up = if (loadout.belly_up) |*pair| &pair.anim else return;
        belly_up.reset(.forward);
        belly_up.direction = .back;
        belly_up.start(loadout.now);
    }

    /// Ship to Belly Up's end (`0x00446C70`): turned over, the markers made (`makeMarkers`) and
    /// the first zooming in; turned back, the ship's turn given it again (`turned_back`).
    fn bellyUpEnded(context: *anyopaque, anim: *i3d.Anim) void {
        const loadout = of(context);
        switch (anim.direction) {
            .forward => {
                loadout.makeMarkers() catch |err| log.warn("the hardpoints' markers are left out: {s}", .{@errorName(err)});
                loadout.nextMarkerZooms(null, .forward);
            },
            .back => loadout.turned_back = true,
        }
    }

    /// Zoom Hardpoint's share (`0x004465F0`): the next marker zooms the same way.
    fn markerZoomShare(context: *anyopaque, anim: *i3d.Anim) void {
        of(context).nextMarkerZooms(anim, anim.direction);
    }

    /// Zoom Hardpoint's end (`0x00447090`): the last marker gone, the ship turns back from belly
    /// up (`turnBack`).
    fn markerZoomEnded(context: *anyopaque, anim: *i3d.Anim) void {
        const loadout = of(context);
        if (anim.direction != .back) return;
        const markers = loadout.shownMarkers();
        if (markers.len == 0) return;
        const last = markers[markers.len - 1] orelse return;
        if (anim != &last.zoom.anim) return;
        loadout.turnBack() catch |err| log.warn("the ship is left belly up: {s}", .{@errorName(err)});
    }

    /// The share of its way at which a marker's zoom starts the next's (`0x0044AA35`).
    const marker_share: f32 = 0.2;

    /// `markers_make` (`0x0044A750`), as the chosen ship has turned belly up: a marker made for
    /// each of its missile hardpoints in turn, in place of the one before it (`hologram.Marker`),
    /// the markers counted as they are made (`counted`): at a thousandth of its size, `hologram.marker_lift`
    /// along the hardpoint's Y axis from it and `hologram.marker_nearer` nearer the camera, where
    /// the ship's parts stood as the frame's scene was made, facing the camera; shown where its
    /// rack holds nothing; and its zoom, each starting the next a fifth of its way.
    fn makeMarkers(loadout: *Loadout) Allocator.Error!void {
        const arena = loadout.arena.allocator();
        const ship = &loadout.ships[loadout.chosen];
        const scale = tables.ships[loadout.chosen].scale;
        loadout.counted = .{ .markers = 0 };
        var each = create.hardpoints(&ship.model);
        while (each.next()) |hardpoint| {
            const index = loadout.counted.markers;
            if (index == loadout.markers.len) break;
            var at = hologram.hardpointPlace(ship.model.parts[hardpoint.part].drawn(), hardpoint.attachment, hologram.marker_lift, scale);
            at[2] -= hologram.marker_nearer;
            if (loadout.markers[index]) |old| {
                loadout.interface.removeObject(&old.panel.object);
                loadout.interface.removeAnim(&old.zoom.anim);
            }
            const marker = try arena.create(hologram.Marker);
            try marker.make(arena, &loadout.interface, loadout.marker_image);
            const shown = &marker.panel.scene_object;
            shown.scale = anims.zoomed_out;
            shown.position = at;
            shown.orientation = loadout.view.camera.orientation;
            try anims.zoomHardpoint(&marker.zoom, &loadout.interface, &marker.panel.object);
            marker.zoom.anim.on_share = markerZoomShare;
            marker.zoom.anim.share = marker_share;
            marker.zoom.anim.on_end = markerZoomEnded;
            marker.panel.object.shown = !loadout.fitted.racks[index].fitted;
            loadout.markers[index] = marker;
            loadout.counted = .{ .markers = index + 1 };
        }
    }

    /// The missile the icon `object` stands for.
    fn iconMissile(loadout: *Loadout, object: *const i3d.Object) ?tables.Missile {
        for (&loadout.icons, std.enums.values(tables.Missile)) |*icon, missile| {
            if (&icon.object == object) return missile;
        }
        return null;
    }

    /// The rack the Ship Missile `object` stands for the missile of.
    fn shipMissileRack(loadout: *Loadout, object: *const i3d.Object) ?usize {
        for (&loadout.ship_missiles, 0..) |*each, rack| {
            if (each == object) return rack;
        }
        return null;
    }

    /// A missile's icon pressed (`missile_icon_press`, `0x004472B0`): a copy of the missile flies
    /// to the chosen ship (`attachMissile`).
    fn pressIcon(context: *anyopaque, object: *i3d.Object, _: i3d.Press) void {
        const loadout = of(context);
        const missile = loadout.iconMissile(object) orelse return;
        loadout.attachMissile(missile) catch |err| log.warn("the missile is not fitted: {s}", .{@errorName(err)});
    }

    /// The pointer onto a missile's icon (`0x00447D80`): the missile shown on the info panel.
    fn enterIcon(context: *anyopaque, object: *i3d.Object, _: i3d.Press) void {
        const loadout = of(context);
        const missile = loadout.iconMissile(object) orelse return;
        loadout.showMissileInfo(missile);
    }

    /// A Ship Missile pressed (`0x004473B0`), but on the ship page: a copy of its missile flies
    /// back to its icon (`detachMissile`).
    fn pressShipMissile(context: *anyopaque, object: *i3d.Object, _: i3d.Press) void {
        const loadout = of(context);
        if (loadout.page == .ships) return;
        const rack = loadout.shipMissileRack(object) orelse return;
        loadout.detachMissile(rack) catch |err| log.warn("the missile is not taken off: {s}", .{@errorName(err)});
    }

    /// The pointer onto a Ship Missile (`0x00447DB0`), on the missile page: its missile shown on
    /// the info panel.
    fn enterShipMissile(context: *anyopaque, object: *i3d.Object, _: i3d.Press) void {
        const loadout = of(context);
        if (loadout.page != .missiles) return;
        const rack = loadout.shipMissileRack(object) orelse return;
        loadout.showMissileInfo(loadout.fitted.racks[rack].missile);
    }

    /// `missile_hover` (`0x00447CC0`): the info panel's front drawn with what it showed, the
    /// chosen ship or the missile shown before (`panels.drawMissile`), its back with `missile`,
    /// and the panel turned to show its back.
    fn showMissileInfo(loadout: *Loadout, missile: tables.Missile) void {
        loadout.drawInfo(.front, if (loadout.shown_missile) |shown| .{ .missile = shown } else .{ .ship = loadout.chosen });
        loadout.shown_missile = missile;
        loadout.drawInfo(.back, .{ .missile = missile });
        loadout.info.scene_object.orientation = math.fromAngleVector(anims.flipped);
    }

    /// `missile_icon_press`'s work (`0x004472B0`): a copy of `missile` flying from its icon to
    /// the chosen ship (`fly`), with sound 4; then the missile page's objects shown and the
    /// missiles offered again.
    fn attachMissile(loadout: *Loadout, missile: tables.Missile) !void {
        const flight = try loadout.fly(missile, .to_next_empty) orelse return;
        flight.attach.play(.forward, loadout.now);
        _ = loadout.playSound(.attach, quiet, hog_snd.once, hog_snd.own_pitch);
        loadout.showMissilePage();
        loadout.missilesAvailable();
    }

    /// The Ship Missile's press's work (`0x004473E7` on): a copy of the missile on rack `rack`
    /// flying back from its hardpoint to its icon (`fly`, played back), shown, unlit and added;
    /// the rack emptied (`emptyRack`), with sound 5.
    fn detachMissile(loadout: *Loadout, rack: usize) !void {
        const flight = try loadout.fly(loadout.fitted.racks[rack].missile, .{ .from_rack = rack }) orelse return;
        flight.attach.play(.back, loadout.now);
        flight.object.shown = true;
        litBlend(&flight.loaded, false, .add);
        loadout.emptyRack(rack);
        _ = loadout.playSound(.detach, quiet, hog_snd.once, hog_snd.own_pitch);
    }

    /// A copy of `missile` made to fly between its icon and a hardpoint of the chosen ship's
    /// (`anim_attach_missile`, `0x00448B10`, and `missile_flight_create`, `0x00445D80`), the one
    /// `route` leads to (`flightHardpoint`), where the missile hangs on its centre of mass at the
    /// ship's scale. Its Attach Missile counts as flying from then on (`attaching`), even where
    /// no room is left for the copy; with room, the copy stands where its flight starts, the
    /// icon's place, turned as the icon is.
    fn fly(loadout: *Loadout, missile: tables.Missile, route: Route) !?*Flight {
        const ship = &loadout.ships[loadout.chosen];
        const hardpoint = loadout.flightHardpoint(route) orelse return null;
        const scale = tables.ships[loadout.chosen].scale;
        const icon = &loadout.icons[@intFromEnum(missile)];
        const lift = icon.model.centre * @as(Vector, @splat(scale));
        const at = hologram.hardpointPlace(ship.model.parts[hardpoint.part].drawn(), hardpoint.attachment, lift, scale);
        loadout.attaching += 1;
        const slot = std.mem.indexOfScalar(?*Flight, &loadout.flights, null) orelse return null;
        const flight = try loadout.makeFlight(missile);
        loadout.flights[slot] = flight;
        try anims.attachMissile(&flight.attach, &loadout.interface, &icon.object, &flight.object, at, attachEnded);
        const start = flight.attach.frames[0].key;
        flight.object.setPosition(start.position);
        flight.object.setOrientation(math.fromAngleVector(start.angles));
        return flight;
    }

    /// The missile hardpoint of the chosen ship's an Attach Missile flies to or from
    /// (`0x00448B8A` to `0x00448C8F`): the one of the first empty rack after as many empty ones
    /// as Attach Missiles fly, or the one of the rack it flies back from; none where there is no
    /// such rack.
    fn flightHardpoint(loadout: *Loadout, route: Route) ?create.Hardpoint {
        const ship = &loadout.ships[loadout.chosen];
        switch (route) {
            .from_rack => |rack| return hardpointOfRack(ship, rack),
            .to_next_empty => {
                var each = create.hardpoints(&ship.model);
                var passing = loadout.attaching;
                var index: usize = 0;
                while (each.next()) |hardpoint| : (index += 1) {
                    if (index < loadout.fitted.racks.len and loadout.fitted.racks[index].fitted) continue;
                    if (passing == 0) return hardpoint;
                    passing -= 1;
                }
                return null;
            },
        }
    }

    /// `missile_flight_create` (`0x00445D80`): a copy of `missile`'s model standing at the origin
    /// with meshes of its own (`node_tree_meshes_copy`, `0x0044B3B0`), unlit and added, at
    /// `anims.missile_scale`, and an object of the interface standing for it, shown and not
    /// clickable, its tooltip empty.
    fn makeFlight(loadout: *Loadout, missile: tables.Missile) !*Flight {
        const gpa = loadout.context.rooms.gpa;
        const file = loadout.missile_models[@intFromEnum(missile)];
        const flight = try gpa.create(Flight);
        errdefer gpa.destroy(flight);
        flight.loaded = try srofiles.modelLoad(gpa, &loadout.textures.?, file.model, .{ .hardware = loadout.context.hardware, .prefix = .loadout_weapons }, false);
        errdefer flight.loaded.deinit(gpa);
        flight.model = try .create(gpa, file.model, &flight.loaded, .{});
        errdefer flight.model.deinit(gpa);
        gameobj.linkParts(&flight.model, file.model);
        flight.model.place(@splat(0), math.identity);
        litBlend(&flight.loaded, false, .add);
        i3d.scaleTree(&flight.model, anims.missile_scale);
        flight.object = .create(0, "", false);
        flight.object.target = .{ .tree = &flight.model };
        flight.missile = missile;
        try loadout.interface.addObject(&flight.object, "");
        return flight;
    }

    /// The flight whose Attach Missile `anim` is.
    fn flightOf(loadout: *Loadout, anim: *const i3d.Anim) ?*Flight {
        for (loadout.flights) |maybe| {
            const flight = maybe orelse continue;
            if (&flight.attach.anim == anim) return flight;
        }
        return null;
    }

    /// Attach Missile's end (`0x00446C90`): the copy lit and opaque, and one fewer flying; come to
    /// its hardpoint, the missile hung on the chosen ship's first empty rack (`fitMissile`) and the
    /// interface free; come back to its icon, the copy put away and the missiles offered again.
    /// Either way the copy goes (`dropFlight`).
    fn attachEnded(context: *anyopaque, anim: *i3d.Anim) void {
        const loadout = of(context);
        const flight = loadout.flightOf(anim) orelse return;
        litBlend(&flight.loaded, true, .off);
        loadout.attaching -= 1;
        switch (anim.direction) {
            .forward => {
                flight.object.shown = true;
                loadout.fitMissile(flight.missile, .flown) catch |err| log.warn("the missile is not hung: {s}", .{@errorName(err)});
                loadout.dropFlight(flight);
                loadout.interface.busy = false;
            },
            .back => {
                flight.object.shown = false;
                loadout.dropFlight(flight);
                loadout.missilesAvailable();
            },
        }
    }

    /// A flight's copy let go: out of the missiles flying, its object and its Attach Missile out
    /// of the interface, its model and meshes freed.
    fn dropFlight(loadout: *Loadout, flight: *Flight) void {
        for (&loadout.flights) |*slot| {
            if (slot.* == flight) slot.* = null;
        }
        loadout.interface.removeObject(&flight.object);
        loadout.interface.removeAnim(&flight.attach.anim);
        freeFlight(loadout.context.rooms.gpa, flight);
    }

    fn freeFlight(gpa: Allocator, flight: *Flight) void {
        flight.model.deinit(gpa);
        flight.loaded.deinit(gpa);
        gpa.destroy(flight);
    }

    /// The missile hardpoint of rack `rack` on `ship`: its rack-th in the order the flight fits
    /// them (`create.hardpoints`).
    fn hardpointOfRack(ship: *const Ship, rack: usize) ?create.Hardpoint {
        var each = create.hardpoints(&ship.model);
        var index: usize = 0;
        while (each.next()) |hardpoint| : (index += 1) {
            if (index == rack) return hardpoint;
        }
        return null;
    }

    /// `rack_fit` (`0x0044AAC0`): `missile` hung on the chosen ship's first empty rack of those
    /// the loadout counts (`racks.Racks.take`), every rack from now on where it hangs at once
    /// (`counted`): a tree of its model (`missile_object_create`, `0x0044AFA0`), lit and opaque at
    /// `hung_share` of the ship's scale, hung on the rack's hardpoint standing on its centre of
    /// mass at the ship's scale, reached by the red and the ambient lights alone; its Ship Missile
    /// standing for it, clickable, the missile's name its tooltip; and where it was flown there,
    /// the rack's marker put away and not clickable.
    fn fitMissile(loadout: *Loadout, missile: tables.Missile, hanging: Hanging) Allocator.Error!void {
        if (hanging == .at_once) loadout.counted = .every_rack;
        const rack = loadout.fitted.take(missile, loadout.counted.count()) orelse return;
        const ship = &loadout.ships[loadout.chosen];
        const hardpoint = hardpointOfRack(ship, rack) orelse return;
        const gpa = loadout.context.rooms.gpa;
        const file = loadout.missile_models[@intFromEnum(missile)];
        var model: objects.Model = try .create(gpa, file.model, file.loaded, .{});
        gameobj.linkParts(&model, file.model);
        litBlend(file.loaded, true, .off);
        const scale = tables.ships[loadout.chosen].scale;
        i3d.scaleTree(&model, scale * hung_share);
        model.centre *= @as(Vector, @splat(scale));
        for (model.parts) |*part| part.object.light_mask = hung_light_mask;
        ship.model.hung[rack] = .{
            .part = hardpoint.part,
            .attachment = hardpoint.index,
            .origin = gameobj.vector(hardpoint.attachment.position) * @as(Vector, @splat(scale)),
            .orientation = hardpoint.attachment.orientation,
            .model = model,
        };
        // Past the Ship Missile objects, which no shipped ship's racks go, nothing stands for it:
        // the game writes past them.
        if (rack >= loadout.ship_missiles.len) return;
        const object = &loadout.ship_missiles[rack];
        object.target = .{ .tree = &ship.model.hung[rack].?.model };
        object.press = pressShipMissile;
        object.enter = enterShipMissile;
        object.setTooltip(loadout.context.strings.string(missile.record().name));
        object.clickable = true;
        object.shown = false;
        if (hanging == .at_once) return;
        const marker = loadout.markers[rack] orelse return;
        marker.panel.object.shown = false;
        marker.panel.object.clickable = false;
    }

    /// `rack_empty` (`0x0044AE40`): rack `rack` of the chosen ship's emptied: its missile's tree
    /// let go, its Ship Missile standing for nothing, put away and not clickable; its marker
    /// shown and clickable again; one fewer fitted.
    fn emptyRack(loadout: *Loadout, rack: usize) void {
        unhang(loadout.context.rooms.gpa, &loadout.ships[loadout.chosen].model.hung[rack]);
        const object = &loadout.ship_missiles[rack];
        object.target = .none;
        object.clickable = false;
        object.shown = false;
        loadout.fitted.empty(rack);
        const marker = loadout.markers[rack] orelse return;
        marker.panel.object.shown = true;
        marker.panel.object.clickable = true;
    }

    /// `racks_clear` (`0x0044AEE0`): the chosen ship's racks the loadout counts emptied
    /// (`counted`), and every missile hung on them let go; every Ship Missile standing for nothing
    /// and not clickable.
    fn clearRacks(loadout: *Loadout) void {
        const gpa = loadout.context.rooms.gpa;
        const limit = loadout.counted.count();
        for (loadout.ships[loadout.chosen].model.hung[0..limit]) |*held| unhang(gpa, held);
        loadout.fitted.clear(limit);
        for (&loadout.ship_missiles) |*object| {
            object.target = .none;
            object.clickable = false;
        }
    }

    /// `racks_fit_tier` (`0x00449AD0`): the red light fading in from nothing, the racks cleared,
    /// and on each missile hardpoint in turn the missile its word names for the campaign's tier,
    /// hung at once.
    fn fitTierDefault(loadout: *Loadout) Allocator.Error!void {
        try loadout.fitEach(.{ .tier = loadout.tier });
    }

    /// `racks_fit_saved` (`0x00449BB0`): as `fitTierDefault`, each missile hardpoint in turn taking
    /// the campaign's saved rack of its turn, where it holds a missile.
    fn fitSaved(loadout: *Loadout) Allocator.Error!void {
        try loadout.fitEach(.saved);
    }

    /// What `fitEach` hangs on the hardpoints.
    const Fitting = union(enum) {
        tier: u2,
        saved,
    };

    fn fitEach(loadout: *Loadout, fitting: Fitting) Allocator.Error!void {
        loadout.red_level = 0;
        loadout.red_fade = 1;
        loadout.clearRacks();
        var each = create.hardpoints(&loadout.ships[loadout.chosen].model);
        var index: usize = 0;
        while (each.next()) |hardpoint| : (index += 1) {
            const missile = switch (fitting) {
                .tier => |tier| tables.Missile.ofId(hardpoint.attachment.wordFor(tier)),
                .saved => if (index < loadout.context.saved.racks.len) loadout.context.saved.racks[index] else null,
            } orelse continue;
            try loadout.fitMissile(missile, .at_once);
        }
    }

    /// `racks_default` (`0x00449CA0`), Use Default Loadout's: the interface busy, the racks
    /// cleared, and on each missile hardpoint in turn the missile its word names for tier 0,
    /// flown to it as the missile's icon's press flies it; then the missiles offered again and the
    /// missile page's objects shown.
    fn fitDefault(loadout: *Loadout) void {
        loadout.interface.busy = true;
        loadout.clearRacks();
        var each = create.hardpoints(&loadout.ships[loadout.chosen].model);
        while (each.next()) |hardpoint| {
            const missile = tables.Missile.ofId(hardpoint.attachment.wordFor(0)) orelse continue;
            loadout.attachMissile(missile) catch |err| log.warn("the missile is not fitted: {s}", .{@errorName(err)});
        }
        loadout.missilesAvailable();
        loadout.showMissilePage();
    }

    // --- The internal guns view --------------------------------------------------------------

    /// `guns_view_toggle` (`0x0044A110`): the internal guns view opened, or closed where it is open,
    /// the interface busy while the ship clipper sweeps across the chosen ship along X, from
    /// `clip_back` before its place to as far past it (Move Clip Point). Opening, the gunship is
    /// put where the ship stands, turned as it is, and the two portals are set on the gunship and
    /// on the ship where the sweep starts, so that the ship turns into its guns as the plane
    /// passes (`sweepStep`); closing, the sweep plays back. The info panel's front is drawn with
    /// what it shows and its back with what it is to show, the ship's figures or its guns, turned
    /// front on and flipped over; and sound 10 plays.
    ///
    /// The game sets the flip's time to 1500 ms each time, the time it is made with.
    fn toggleGuns(loadout: *Loadout) void {
        const now = loadout.now;
        const ship = &loadout.ships[loadout.chosen];
        const gunship = &ship.gunship;
        const opening = !loadout.guns_open;
        loadout.interface.busy = true;
        if (opening) {
            gunship.object.setPosition(ship.object.position());
            gunship.object.setOrientation(ship.object.orientation());
        }
        const from = gunship.object.position() - Vector{ clip_back, 0, 0 };
        if (opening) {
            const length: Vector = @splat(opening_normal_length);
            loadout.gunship_portal.position = from;
            loadout.gunship_portal.normal = gunship_normal * length;
            clipTree(&gunship.model, &loadout.gunship_portal);
            loadout.ship_portal.position = from;
            loadout.ship_portal.normal = ship_normal * length;
            ship.clip(&loadout.ship_portal);
        }
        loadout.clipper.object.setPosition(from);
        const sweep = &loadout.clip_sweep;
        sweep.frames[0].key.position = from;
        sweep.frames[1].key.position = from + Vector{ clip_sweep, 0, 0 };
        sweep.play(if (opening) .forward else .back, now);
        const figures: Info = .{ .ship = loadout.chosen };
        const guns: Info = .{ .guns = loadout.chosen };
        loadout.drawInfo(.front, if (opening) figures else guns);
        loadout.drawInfo(.back, if (opening) guns else figures);
        loadout.info.scene_object.orientation = math.identity;
        loadout.flip_info.play(.forward, now);
        _ = loadout.playSound(.guns, hog_snd.loudest, hog_snd.once, hog_snd.own_pitch);
        if (opening) loadout.guns_open = true;
    }

    /// Move Clip Point's step (`0x004490E0`): the ship clipper, the gunship and the ship shown;
    /// the two portals moved to the plane, the gunship's facing along X and the ship's back along
    /// it, and set on them, so that the gunship shows behind the plane and the ship ahead of it;
    /// and the plane turned across X (`hologram.clipper_angles`).
    fn sweepStep(context: *anyopaque, _: *i3d.Anim) void {
        const loadout = of(context);
        const ship = &loadout.ships[loadout.chosen];
        loadout.clipper.object.shown = true;
        ship.gunship.object.shown = true;
        ship.object.shown = true;
        const at = loadout.clipper.object.position();
        loadout.gunship_portal.position = at;
        loadout.gunship_portal.normal = gunship_normal;
        clipTree(&ship.gunship.model, &loadout.gunship_portal);
        loadout.ship_portal.position = at;
        loadout.ship_portal.normal = ship_normal;
        ship.clip(&loadout.ship_portal);
        loadout.clipper.object.setOrientation(math.fromAngleVector(hologram.clipper_angles));
    }

    /// Move Clip Point's end (`0x00446E30`): the interface free and the ship clipper put away.
    /// Opened, the ship is put away, leaving its gunship; closed, the gunship is put away, the view
    /// is closed and the ship is clipped by the disc's portal again (`clipToDisc`). Then what waits
    /// on the interface's stack runs.
    fn sweepEnded(context: *anyopaque, anim: *i3d.Anim) void {
        const loadout = of(context);
        const ship = &loadout.ships[loadout.chosen];
        loadout.interface.busy = false;
        loadout.clipper.object.shown = false;
        switch (anim.direction) {
            .forward => ship.object.shown = false,
            .back => {
                ship.gunship.object.shown = false;
                loadout.guns_open = false;
                loadout.clipToDisc(&ship.model);
            },
        }
        loadout.interface.runDeferred();
    }

    /// `stack_guns_view` (`0x00449AA0`): a function-stack entry, the internal guns view toggled.
    fn stackGunsView(context: *anyopaque, _: usize) void {
        of(context).toggleGuns();
    }

    /// `stack_select_ship` (`0x00447E00`): a function-stack entry, the ship it holds selected.
    fn stackSelectShip(context: *anyopaque, ship: usize) void {
        of(context).selectShip(@truncate(ship)) catch |err| log.warn("the ship is not selected: {s}", .{@errorName(err)});
    }

    /// `stack_switch_page` (`0x00449AB0`) as `page_switch` pushes it: a function-stack entry, the
    /// missile page turned to.
    fn stackMissilePage(context: *anyopaque, _: usize) void {
        of(context).switchPage(.missiles);
    }

    /// `loadout_exit` as a function-stack entry, as the exit leaves itself to run once the
    /// internal guns view has closed (`0x0044777C`).
    fn stackExit(context: *anyopaque, _: usize) void {
        of(context).exit();
    }

    fn of(context: *anyopaque) *Loadout {
        return @ptrCast(@alignCast(context));
    }
};

/// `node_tree_to_scene` (`0x0044B0F0`): `tree`'s parts placed as its root stands
/// (`node_frame_update`), with what they carry, the missiles hung on a ship, and each shown part
/// put in the scene (`partsToScene`).
fn treeToScene(gpa: Allocator, scene: *srcore.Scene, tree: *objects.Model) Allocator.Error!void {
    tree.place(tree.position, tree.orientation);
    try partsToScene(gpa, scene, tree);
}

/// Each shown part of `tree` put in the scene, then those of each model it carries, however deep.
fn partsToScene(gpa: Allocator, scene: *srcore.Scene, tree: *objects.Model) Allocator.Error!void {
    for (tree.parts) |*part| {
        if (!part.hidden) try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &part.object }, .world);
    }
    var each = tree.carried();
    while (each.next()) |mount| try partsToScene(gpa, scene, &mount.model);
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
    _ = racks;
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
    var context: Context = .{ .rooms = undefined, .cache = undefined, .strings = undefined, .stats = undefined, .missile_stats = undefined, .mission = 5, .saved = &saved };
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

/// A ship of one part for the tests, carrying a missile of one part on its first rack, each part
/// showing `levels`.
const TestTree = struct {
    parts: [1]objects.Model.Part,
    missile_parts: [1]objects.Model.Part,
    hung: [2]?objects.Model.Mount,
    ship: objects.Model,

    const first_part = [_]usize{0};

    fn init(tree: *TestTree, levels: []const srapiext.Level) void {
        const shown: srapiext.MeshObject = .{ .flags = .{}, .position = @splat(0), .radius = 0, .levels = levels };
        tree.parts = .{.{ .hidden = false, .parent = null, .origin = .{ 1, 0, 0 }, .object = shown }};
        tree.missile_parts = .{.{ .hidden = false, .parent = null, .origin = @splat(0), .object = shown }};
        tree.hung = .{ .{
            .part = 0,
            .attachment = 0,
            .origin = .{ 0, 2, 0 },
            .orientation = math.identity,
            .model = .{ .parts = &tree.missile_parts, .order = &first_part, .lights = &.{}, .glows = &.{}, .mounts = &.{} },
        }, null };
        tree.ship = .{ .parts = &tree.parts, .order = &first_part, .lights = &.{}, .glows = &.{}, .mounts = &.{}, .hung = &tree.hung };
    }
};

test clipTree {
    var tree: TestTree = undefined;
    tree.init(&.{});
    const portal: srapiext.Portal = .{};
    // The ship's parts and the missile it carries clipped alike.
    clipTree(&tree.ship, &portal);
    try std.testing.expect(tree.parts[0].object.flags.portal_clipped);
    try std.testing.expect(tree.missile_parts[0].object.flags.portal_clipped);
    try std.testing.expectEqual(&portal, tree.missile_parts[0].object.portal.?);
    // Clipped no more, each keeps the portal it had.
    clipTree(&tree.ship, null);
    try std.testing.expect(!tree.missile_parts[0].object.flags.portal_clipped);
    try std.testing.expectEqual(&portal, tree.missile_parts[0].object.portal.?);
}

test treeToScene {
    const gpa = std.testing.allocator;
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    var mesh = try squareMesh(gpa, false, 1, 1);
    defer mesh.deinit(gpa);
    const levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};
    var tree: TestTree = undefined;
    tree.init(&levels);
    // The ship's part and the missile it carries, placed on it.
    try treeToScene(gpa, &scene, &tree.ship);
    try std.testing.expectEqual(2, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(Vector{ 1, 2, 0 }, tree.missile_parts[0].object.position);
    // A hidden part is left out.
    tree.missile_parts[0].hidden = true;
    i3d.clearScene(&scene);
    try treeToScene(gpa, &scene, &tree.ship);
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
}

test gunshipLightMasks {
    const gpa = std.testing.allocator;
    var faces = try squareMesh(gpa, false, 1, 1);
    defer faces.deinit(gpa);
    var lines = try squareMesh(gpa, false, 1, 1);
    defer lines.deinit(gpa);
    lines.polygons[0] = .{ .kind = .lines, .continues = 0, .first = 0, .count = line_corners };
    var face_meshes = [_]srapiext.Mesh{faces};
    var line_meshes = [_]srapiext.Mesh{lines};
    var no_meshes = [_]srapiext.Mesh{};
    var loaded_parts = [_]srofiles.LoadedPart{
        .{ .flags = .{}, .meshes = &face_meshes, .levels = &.{} },
        .{ .flags = .{}, .meshes = &line_meshes, .levels = &.{} },
        .{ .flags = .{}, .meshes = &no_meshes, .levels = &.{} },
    };
    const loaded: srofiles.Loaded = .{ .parts = &loaded_parts };
    const object: srapiext.MeshObject = .{ .flags = .{}, .position = @splat(0), .radius = 0, .levels = &.{}, .light_mask = 0x1234 };
    var parts: [3]objects.Model.Part = @splat(.{ .hidden = false, .parent = null, .origin = @splat(0), .object = object });
    var tree: objects.Model = .{ .parts = &parts, .order = &.{}, .lights = &.{}, .glows = &.{}, .mounts = &.{} };
    gunshipLightMasks(&tree, &loaded);
    // A part drawn in faces takes the green light, as the ships' parts do, and one drawn in lines
    // the ambient light alone.
    try std.testing.expectEqual(ship_light_mask, parts[0].object.light_mask);
    try std.testing.expectEqual(gunship_line_light_mask, parts[1].object.light_mask);
    // A part with no mesh keeps its own.
    try std.testing.expectEqual(0x1234, parts[2].object.light_mask);
}

test litBlend {
    const gpa = std.testing.allocator;
    var mesh = try squareMesh(gpa, false, 1, 1);
    defer mesh.deinit(gpa);
    mesh.surfaces[0].material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .off });
    mesh.surfaces[0].material.two_pass = true;
    var meshes = [_]srapiext.Mesh{mesh};
    var parts = [_]srofiles.LoadedPart{.{ .flags = .{}, .meshes = &meshes, .levels = &.{} }};
    const loaded: srofiles.Loaded = .{ .parts = &parts };
    // A missile flying: one pass, unlit and added.
    litBlend(&loaded, false, .add);
    const material = meshes[0].surfaces[0].material;
    try std.testing.expect(!material.two_pass and !material.lit[0]);
    try std.testing.expectEqual(srapiext.Material.Blend.add, material.blend[0]);
}
