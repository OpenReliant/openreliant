//! Windows 3 and 8 of the display, the target display's small and large forms (`hud_window_draw`'s
//! cases for them, at `0x00487B72` and `0x004875C0`). A change of target brings up the form its
//! type's combat stats ask for (`create.ShipCombat.display`), closing the other
//! (`hud.State.targetChanged`).
//!
//! The small form shows the target's ship status, turned to face the player
//! (`hud.ShipStatus`, mode 1), its type's name, its range in kilometres and its speed. The large
//! form shows the type's own picture, its name, the subtarget with an icon for its part's class and
//! a bar for the part's armour, a bar for the ship's hull, and the range and the speed. Every line
//! is in the display's font.
//!
//! As a form closes, `hud_window_close` draws what it shows once more into a picture
//! (`hud_window_picture`, `0x00566600`), and the window closes with that.
//!
//! **Improvement.** The game keeps one picture for both forms, and draws it again as a form
//! starts closing: for the target it last showed, but with whatever target the display now has
//! for the range, the name and the rest. OpenReliant keeps what each form last showed and closes it
//! with that.
//!
//! Not ported: the pilot's name under the type's, for a named pilot (`GameObject.pilot_record`),
//! which a mission gives ([#529](https://github.com/vdmkenny/openreliant/issues/529)); and in a
//! multiplayer game the players' names and one more line of the small form
//! ([#55](https://github.com/vdmkenny/openreliant/issues/55)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const shp = @import("../../../formats/shp.zig");
const create = @import("../create.zig");
const hud = @import("../hud.zig");
const windows = @import("windows.zig");

/// The target display's two forms: window 3, the small one, and window 8, the large one.
pub const Form = enum {
    small,
    large,

    pub fn of(window: windows.Window) ?Form {
        return switch (window) {
            .target => .small,
            .big_target => .large,
            else => null,
        };
    }
};

/// What the two forms read of the game for a frame.
pub const Scene = struct {
    /// The display's own state: the target, the hits on it, the windows and what each form last
    /// showed.
    state: *hud.State,
    all: *const create.Objects,

    /// Draws `form`: what it shows now, and while it closes what it last showed.
    pub fn draw(scene: Scene, form: Form, closing: bool, canvas: windows.Canvas) windows.Canvas.Error!void {
        const context: Context = .{ .canvas = canvas };
        switch (form) {
            inline else => |which| {
                const name = @tagName(which);
                const kept = &@field(scene.state.target_pictures, name);
                if (!closing) kept.* = @field(Scene, name)(scene);
                if (kept.*) |shown| try shown.draw(context);
            },
        }
    }

    /// What the small form shows now. A cloaked hostile target closes it.
    pub fn small(scene: Scene) ?Small {
        const index = (scene.state.target orelse return null).slot;
        const slot = &scene.all.slots[index];
        if (slot.object.flags.cloaked and slot.object.side == .hostile) {
            scene.state.windows.close(.target);
            return null;
        }
        return .{ .status = hud.ShipStatus.ofTarget(slot, &scene.state.target_hits), .facts = .of(scene.all, index) };
    }

    /// What the large form shows now.
    pub fn large(scene: Scene) ?Large {
        const index = (scene.state.target orelse return null).slot;
        const slot = &scene.all.slots[index];
        const shown_subtarget = switch (slot.object.type) {
            .proximity_mine, .black_box => false,
            else => true,
        };
        return .{
            .picture = if (slot.type) |loaded| loaded.schematic else null,
            .subtarget = if (shown_subtarget) subtarget(scene.all) else null,
            .hull = hull(slot),
            .facts = .of(scene.all, index),
        };
    }
};

/// What both forms show of the target: its type's name, and its range and speed.
pub const Facts = struct {
    /// The type's name, a string of the game's.
    name: ?u16,
    /// The range in kilometres (`hud.kilometres`).
    range: i32,
    /// The speed, rounded.
    speed: i32,

    pub fn of(all: *const create.Objects, index: u16) Facts {
        const slot = &all.slots[index];
        const name = if (slot.combat) |combat| combat.name else 0;
        return .{
            .name = if (name != 0) name else null,
            .range = hud.kilometres(all, index),
            .speed = hud.round(slot.object.speed),
        };
    }
};

/// Where a form writes the target's facts, from the window's place, and how it aligns them.
pub const Lines = struct {
    name: [2]i32,
    range: [2]i32,
    speed: [2]i32,
    alignment: hud.Align,
};

/// What the small form shows.
pub const Small = struct {
    status: hud.ShipStatus.Shown,
    facts: Facts,

    /// Where the ship status stands from the window's place.
    pub const status_at: [2]i32 = .{ -4, -0x2C };
    pub const lines: Lines = .{ .name = .{ 0x37, -0x43 }, .range = .{ 0x37, -0x2B }, .speed = .{ 0x37, -0x1F }, .alignment = .left };

    fn draw(small: Small, context: Context) windows.Canvas.Error!void {
        const canvas = context.canvas;
        try hud.ShipStatus.draw(small.status, .target, canvas.pen, canvas.place(status_at), canvas.clip);
        try context.name(small.facts, lines);
        try context.figures(small.facts, lines);
    }
};

/// What the large form shows.
pub const Large = struct {
    /// The type's own picture: its sprite's first shape, the schematic the small form draws.
    picture: ?hud.Schematic = null,
    subtarget: ?Subtarget = null,
    hull: ?Bar = null,
    facts: Facts,

    /// Where the picture stands from the window's place.
    pub const picture_at: [2]i32 = .{ -0xD0, -0x80 };
    pub const lines: Lines = .{ .name = .{ -2, -0x9D }, .range = .{ -3, -0x1D }, .speed = .{ -3, -0x11 }, .alignment = .right };

    fn draw(shown: Large, context: Context) windows.Canvas.Error!void {
        if (shown.picture) |picture| try context.canvas.drawing(picture).shaky(0, picture_at);
        try context.name(shown.facts, lines);
        if (shown.subtarget) |part| try part.draw(context);
        if (shown.hull) |bar| try bar.draw(context, hull_bar);
        try context.figures(shown.facts, lines);
    }
};

/// The subtarget as the large form shows it: the name and the icon of its part's class, and how
/// much of the bar for its armour is dark, where the part has armour.
pub const Subtarget = struct {
    named: Named,
    /// The rows of `armor_bar` its lost armour darkens, from the top: `armor_rows` less its share
    /// of its first armour, rounded.
    unlit: ?i32,

    pub const name_at: [2]i32 = .{ -0x78, -0x33 };
    pub const icon_at: [2]i32 = .{ -0xBA, -0x34 };

    fn draw(part: Subtarget, context: Context) windows.Canvas.Error!void {
        try context.canvas.string(part.named.name, name_at, .left);
        try context.canvas.shape(part.named.icon, icon_at);
        if (part.unlit) |unlit| {
            try context.canvas.shape(armor_bar.lit, armor_bar.at);
            try armor_bar.darken(context, unlit, armor_bar.dark_top);
        }
    }
};

/// A bar of the large form: a lit shape, and a dark one drawn over it from the top down as far as
/// what it measures is lost, each into a VFX pane four pixels wide (`0x0057BDFC`).
pub const BarShapes = struct {
    lit: u16,
    dark: u16,
    /// Where both shapes hang from, from the window's place.
    at: [2]i32,
    /// The rows the bar runs, and the left edge and top row of its lit pane.
    rows: i32,
    pane: [2]i32,
    /// The top row of the dark shape's pane.
    dark_top: i32,

    /// The dark shape over the top `unlit` rows from `top`.
    fn darken(bar: BarShapes, context: Context, unlit: i32, top: i32) windows.Canvas.Error!void {
        if (unlit == 0) return;
        try context.canvas.shapeIn(bar.dark, bar.at, .{ bar.pane[0], top, bar.pane[0] + pane_reach, top + unlit });
    }
};

/// How far across from its left edge a bar's panes reach.
const pane_reach = 4;

/// The subtarget's armour bar: shape `0xDE`, darkened by `0xDB`, 38 rows.
pub const armor_bar: BarShapes = .{ .lit = 0xDE, .dark = 0xDB, .at = .{ -0xC6, -0x32 }, .rows = 38, .pane = .{ -0xC7, -0x33 }, .dark_top = -0x33 };
/// The hull's bar at the window's right: shape `0xDC`, darkened by `0xDB`, 98 rows.
pub const hull_bar: BarShapes = .{ .lit = 0xDC, .dark = 0xDB, .at = .{ -6, -0x7E }, .rows = 98, .pane = .{ -7, -0x7F }, .dark_top = -0x75 };

/// The hull as the large form's bar shows it: how many of its rows are dark, and the top row of
/// the dark shape's pane, `torpedo_rise` higher for a torpedo's.
pub const Bar = struct {
    unlit: i32,
    top: i32,

    fn draw(bar: Bar, context: Context, shapes: BarShapes) windows.Canvas.Error!void {
        try context.canvas.shapeIn(shapes.lit, shapes.at, .{ shapes.pane[0], shapes.pane[1] + bar.unlit, shapes.pane[0] + pane_reach, shapes.pane[1] + shapes.rows });
        try shapes.darken(context, bar.unlit, bar.top);
    }
};

/// The subtarget of the player's current order, as the large form shows it: a component the
/// target lists, whose part's class has a name and an icon.
fn subtarget(all: *const create.Objects) ?Subtarget {
    const current = all.slots[all.player].orders[0].target;
    const component = current.part() orelse return null;
    if (current.index < 0) return null;
    const holder = &all.slots[@intCast(current.index)];
    if (holder.object.component_count == 0 or component >= holder.components.len) return null;
    const part = holder.components[component] orelse return null;
    const found = named(part.class) orelse return null;
    const unlit: ?i32 = if (part.component_armor > 0)
        windows.unlitRows(part.armor / @as(f32, @floatFromInt(part.component_armor)), armor_bar.rows)
    else
        null;
    return .{ .named = found, .unlit = unlit };
}

/// The hull as the large form's bar shows it. For a torpedo, its weakest armour quadrant, no more
/// than `weakest_seed`, against six times its armour class; for the rest, the armour of the first
/// of its model's parts, in its root's child list, that is hull and has armour; for one with
/// neither, no bar.
fn hull(slot: *const create.Slot) ?Bar {
    const combat = slot.combat orelse return null;
    if (combat.class == .torpedo) {
        const weakest = @min(weakest_seed, slot.object.armor.weakest());
        const full = combat.fullArmor();
        const share = if (full > 0) weakest / full else 0;
        return .{ .unlit = windows.unlitRows(share, hull_bar.rows), .top = hull_bar.dark_top - torpedo_rise };
    }
    const model = if (slot.model) |*model| model else return null;
    for (model.parts) |part| {
        if (part.removed or part.class != .hull or part.component_armor <= 0) continue;
        const share = part.armor / @as(f32, @floatFromInt(part.component_armor));
        return .{ .unlit = windows.unlitRows(share, hull_bar.rows), .top = hull_bar.dark_top };
    }
    return null;
}

/// What the large form starts a torpedo's search for its weakest quadrant from (`0x004DC4F8`), and
/// how many rows higher it starts the dark part of a torpedo's bar (a number in its case's code).
const weakest_seed: f32 = 1_000_000;
const torpedo_rise = 3;

/// The icon the large form draws for a subtarget of a part's class, and the string that names
/// the class (`hud_window_draw`'s two tables of them).
pub const Named = struct { icon: u16, name: u16 };

/// A part class's icon and name, or null for a class the large form does not show.
pub fn named(class: shp.Part.Class) ?Named {
    return switch (class) {
        .turret, .laser_turret => .{ .icon = 0x18C, .name = 0x39C },
        .engine => .{ .icon = 0x18A, .name = 0x39D },
        .shield_generator => .{ .icon = 0x192, .name = 0x39E },
        .comms_transmitter => .{ .icon = 0x189, .name = 0x39F },
        .gravity_drive => .{ .icon = 0x18B, .name = 0x3A0 },
        .missile_turret => .{ .icon = 0x18D, .name = 0x3A1 },
        .power_core => .{ .icon = 0x18E, .name = 0x3A2 },
        .satellite_dish => .{ .icon = 0x18F, .name = 0x3A3 },
        .service_door => .{ .icon = 0x190, .name = 0x3A4 },
        .shaft => .{ .icon = 0x191, .name = 0x3A5 },
        .surface_building => .{ .icon = 0x193, .name = 0x3A6 },
        .twin_power_cores => .{ .icon = 0x194, .name = 0x3A7 },
        .vent_hatch => .{ .icon = 0x195, .name = 0x3A8 },
        .ion_cannon => .{ .icon = 0x196, .name = 0x3B6 },
        .armored_plate => .{ .icon = 0x197, .name = 0x46E },
        .cap_gun => .{ .icon = 0x198, .name = 0x5F4 },
        .warp_projector => .{ .icon = 0x199, .name = 0x5F5 },
        .fuel_pod => .{ .icon = 0x19A, .name = 0x5F6 },
        else => null,
    };
}

/// What the two forms keep of what each last showed, which each closes with.
pub const Pictures = struct {
    small: ?Small = null,
    large: ?Large = null,
};

/// What a form of the display is drawn with: the window's canvas, and the text both forms show.
const Context = struct {
    canvas: windows.Canvas,

    /// The type's name, where it has one, as `lines` places it.
    fn name(context: Context, shown: Facts, lines: Lines) Allocator.Error!void {
        if (shown.name) |id| try context.canvas.string(id, lines.name, lines.alignment);
    }

    /// The range and the speed, as `lines` places them.
    fn figures(context: Context, shown: Facts, lines: Lines) Allocator.Error!void {
        var buffer: [16]u8 = undefined;
        try context.canvas.text(hud.rangeText(&buffer, shown.range), lines.range, lines.alignment);
        try context.canvas.print("{d} kps", .{shown.speed}, lines.speed, lines.alignment);
    }
};

test named {
    // Both kinds of Laser Turret share an icon and a name; a hull section has neither.
    try std.testing.expectEqual(named(.turret), named(.laser_turret));
    try std.testing.expectEqual(null, named(.hull));
    try std.testing.expectEqual(0x192, named(.shield_generator).?.icon);
    // The icons run from 0x189 to 0x19A, each class but the Laser Turrets its own.
    var seen: std.StaticBitSet(0x12) = .initEmpty();
    for (std.enums.values(shp.Part.Class)) |class| {
        const found = named(class) orelse continue;
        try std.testing.expect(found.icon >= 0x189 and found.icon <= 0x19A);
        seen.set(found.icon - 0x189);
    }
    try std.testing.expectEqual(0x12, seen.count());
}

test "the forms show the target" {
    const gameobj = @import("../gameobj.zig");
    const objects = @import("../objects.zig");
    const aigeneric = @import("../aigeneric.zig");
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const player = try mission.add(.predator, @splat(0));
    try std.testing.expect(try aigeneric.push(mission.orders(), player, .player_control, .none));
    const sabre = try mission.add(.sabre, .{ 0, 0, 3400 });
    const slot = mission.slot(sabre);
    slot.object.speed = 212.6;
    var state: hud.State = .{ .target = .{ .target = .at(sabre, null), .slot = sabre } };
    const scene: Scene = .{ .state = &state, .all = all };

    // Its type's name, its range in whole kilometres and its speed.
    const facts = scene.small().?.facts;
    try std.testing.expectEqual(slot.combat.?.name, facts.name.?);
    try std.testing.expectEqual(3, facts.range);
    try std.testing.expectEqual(213, facts.speed);

    // A cloaked hostile target closes the small form.
    _ = state.windows.open(.target, false);
    slot.object.flags.cloaked = true;
    try std.testing.expectEqual(null, scene.small());
    try std.testing.expectEqual(windows.Phase.closing, state.windows.status.get(.target).phase);
    slot.object.flags.cloaked = false;

    // The large form shows the subtarget the player's order names, with its armour's bar.
    var part: objects.Model.Part = .{ .hidden = false, .parent = null, .origin = @splat(0), .object = .{ .flags = .{}, .position = @splat(0), .radius = 0, .levels = &.{} } };
    part.class = .engine;
    part.component_armor = 200;
    part.armor = 50;
    slot.components[0] = &part;
    slot.object.component_count = 1;
    mission.slot(player).orders[0].target = .at(sabre, 0);
    const shown = scene.large().?.subtarget.?;
    try std.testing.expectEqual(named(.engine).?, shown.named);
    try std.testing.expectEqual(armor_bar.rows - 10, shown.unlit.?);
    // A class the form has no icon for shows nothing.
    part.class = .hull;
    try std.testing.expectEqual(null, scene.large().?.subtarget);
}

test "a torpedo's bar is its weakest armour" {
    const gameobj = @import("../gameobj.zig");
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    _ = try mission.add(.predator, @splat(0));
    const index = try mission.add(.torpedo, .{ 0, 0, 1000 });
    const slot = mission.slot(index);
    const full = slot.combat.?.fullArmor();
    slot.object.armor = .all(full);
    slot.object.armor.aft = full / 2;
    const bar = hull(slot).?;
    try std.testing.expectEqual(49, bar.unlit);
    // Its dark part starts 3 higher than a hull's.
    try std.testing.expectEqual(hull_bar.dark_top - 3, bar.top);
}
