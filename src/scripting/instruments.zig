//! What player scripts read of the flight display's instruments (`openreliant.hud`): which of the
//! game's instruments the mods' displays stand in for, where each instrument draws, and what the
//! game's instruments show, so that a display can stand in for one, and how a display's `layout`
//! moves and scales them ([#793](https://github.com/OpenReliant/openreliant/issues/793)).
//!
//! **Improvement:** the original has no scripting apart from its mission scripts.

const std = @import("std");

const openreliant = @import("openreliant");
const engine = openreliant.engine;
const hud = engine.game.hud;
const target_forms = hud.target_display;
const wing_status = hud.wing_status;
const power_window = hud.power;
const power_systems = engine.input.power;
const radio_menu = engine.game.radio.menu;
const Action = engine.input.controls.Action;
const language = engine.game.language;
const gameobj = engine.game.gameobj;
const Object = engine.hooks.Object;
const gun_types = engine.game.guns;
const missile_display = hud.missile_display;
const create = engine.game.create;
const Target = engine.hooks.Target;
const api = @import("api.zig");
const Call = api.Call;
const values = @import("values.zig");
const presentation = @import("presentation.zig");

/// A list of the game's instruments, which holds them all.
pub const Instruments = values.List(hud.Instrument, std.enums.values(hud.Instrument).len);

/// Where a display puts one of the game's instruments (`register_display`'s `layout`).
pub const Layout = struct {
    pub const script_name = "HudLayout";
    /// The most times its own size an instrument can be drawn.
    pub const max_scale = 8;

    /// How far it moves, in the game's pixels, which grow with the window as the display's own do.
    offset: ?@Vector(3, f32) = null,
    /// How many times its own size it's drawn, growing from where it stands on the screen.
    scale: ?f32 = null,

    /// The placement it gives the instrument; null for a scale out of bounds.
    pub fn placement(layout: Layout) ?hud.Placement {
        const scale = layout.scale orelse 1;
        if (!(scale > 0 and scale <= max_scale)) return null;
        const offset: @Vector(3, f32) = layout.offset orelse @splat(0);
        return .{ .offset = .{ offset[0], offset[1] }, .scale = scale };
    }
};

/// The player's guns as the gunnery window and the targeting cluster show them.
pub const Guns = struct {
    pub const script_name = "HudGuns";

    /// The group of guns chosen, counting from 0, which GUNNERY WINDOW moves on.
    group: u8,
    /// How many groups the ship has.
    groups: u8,
    /// Whether every group fires, which FULL GUNS turns on.
    all: bool,
    /// Whether SYNCHRONISE GUNS is on.
    synchronised: bool,
    /// The type of the chosen group's first gun, nil for none.
    gun: ?gun_types.GunType,
    /// The guns' charge, and the most they hold.
    charge: f32,
    full_charge: f32,
};

/// A missile type on the missile window's ring, and how many are left.
pub const RingMissile = struct {
    pub const script_name = "HudMissile";

    type: engine.game.missiles.Type,
    left: i16,
};

/// The player's missiles as the missile window shows them.
pub const Missiles = struct {
    pub const script_name = "HudMissiles";

    /// The armed missile, nil while the ring is empty.
    armed: ?engine.game.missiles.Type,
    /// How many of the armed missile are left.
    left: i16,
    /// Each missile type on the ring, in its order, the armed one among them.
    ring: values.List(RingMissile, missile_display.max_entries),
};

/// The radar's range, and its contacts.
pub const Radar = struct {
    pub const script_name = "HudRadar";

    /// The range, 0 the closest, which RADAR RANGES moves on.
    range: u8,
    /// How far the radar reaches at that range.
    reach: f32,
    /// Whether its rings are still moving to that range's.
    zooming: bool,
    /// What it shows, in the objects' slots' order: the display's nav point, and the objects
    /// within its reach.
    contacts: Contacts,
};

/// A contact on the radar.
pub const Contact = struct {
    pub const script_name = "HudContact";

    /// The object it stands for.
    object: Object,
    /// Where its dot stands from the radar's middle, in the game's pixels, which grow with the
    /// window as the display's own do: across, and down the screen.
    at: @Vector(3, f32),
    /// How far below the rings' plane it stands, in the same pixels: its line runs that far up from
    /// its dot to the plane, or down for one above the plane, below 0.
    height: i32,
    /// How it shows.
    look: hud.Radar.Look,
};

/// The radar's contacts, which hold every object.
pub const Contacts = values.List(Contact, gameobj.max_objects);

/// What the target display shows of its target, in either of its forms.
pub const TargetDisplay = struct {
    pub const script_name = "HudTargetDisplay";

    /// The form the target's type brings up: the small one shows its ship status and its pilot, the
    /// large one its picture, its subtarget and its hull.
    form: target_forms.Form,
    /// The type's name, and its pilot's, which the small form writes; nil for none.
    name: ?Text,
    pilot: ?Text,
    /// Its range in kilometres, and its speed, as both forms write them.
    range: i32,
    speed: i32,
    /// How many of its shields' and its armour's five arcs show in each of its own quadrants, as
    /// the small form shows them; nil for a ship without them.
    shields: ?Arcs,
    armor: ?Arcs,
    /// The class of the subtarget's part, as the large form names it, and how much of the bar for
    /// its armour is lit, from 0 to 1, nil for a part without armour; both nil without a
    /// subtarget the form shows.
    subtarget: ?Text,
    subtarget_armor: ?f32,
    /// How much of the large form's bar for the hull is lit, from 0 to 1; nil for a ship with none.
    hull: ?f32,
};

/// The targeting cluster about the middle of the screen, as it shows the player's speed, throttle
/// and guns.
pub const Gauges = struct {
    pub const script_name = "HudGauges";

    /// The speed made, as the speed's figure shows it.
    speed: i32,
    /// The speed the throttle asks for, as the throttle's figure shows it.
    asked: i32,
    /// Where the speed's marker stands on the left arc, and how far up the arc is lit: the speed
    /// over the top speed, from 0 to 1.
    speed_share: f32,
    /// Where the throttle's marker stands on the left arc: the throttle's size, from 0 to 1.
    throttle_share: f32,
    /// How bright the throttle's marker and figure are, from 0 to 1; nil while they don't show,
    /// as the throttle nears the speed.
    throttle_brightness: ?f32,
    /// How far up the right arc is lit, from 0 to 1: the guns' charge over the most they hold, or,
    /// where `nova` is set, what the Nova Cannon's charge leaves of it, as the arc empties while
    /// the cannon charges.
    charge: f32,
    /// Whether the right arc shows the Nova Cannon's charge rather than the guns'.
    nova: bool,
};

/// How many of a ring's five arcs show in each quadrant, from 0 to 5.
pub const Arcs = struct {
    pub const script_name = "HudArcs";

    left: i32,
    right: i32,
    fore: i32,
    aft: i32,

    /// The arcs that show for the levels of a ring, in the quadrants' order (`hud.ShipStatus.Rings`).
    fn of(levels: [4]i32) Arcs {
        return .{ .left = shownArcs(levels[0]), .right = shownArcs(levels[1]), .fore = shownArcs(levels[2]), .aft = shownArcs(levels[3]) };
    }
};

/// How many arcs show for an arc's level (`hud.ShipStatus.level`): none at 0 or less.
fn shownArcs(level: i32) i32 {
    return std.math.clamp(level, 0, hud.ShipStatus.arc_levels);
}

/// The ship status indicator, as it shows the player's shields and armour.
pub const ShipStatus = struct {
    pub const script_name = "HudShipStatus";

    /// The shields' ring and the armour's.
    shields: Arcs,
    armor: Arcs,
    /// The arcs outside the fore and aft shields for what SHIELD BALANCING has shifted there, from
    /// 0 to 5.
    reserve_fore: i32,
    reserve_aft: i32,
};

/// The damage window: how well each system still works as the armour wears, from 0 to 1.
pub const Damage = struct {
    pub const script_name = "HudDamage";

    weapons: f32,
    engines: f32,
    shields: f32,
};

/// The power window: each system's share of the power, as the whole percentage it writes.
pub const Power = struct {
    pub const script_name = "HudPower";

    shields: i32,
    guns: i32,
    engines: i32,
};

/// A ship of the player's wing, as the wing status window shows it.
pub const Wingman = struct {
    pub const script_name = "HudWingman";

    object: Object,
    /// Its number in the wing, from 1, the player's first.
    number: u8,
    /// How much of the bar for its weakest armour quadrant is lit, from 0 to 1.
    armor: f32,
};

/// The wing status window's ships, which hold the wing.
pub const Wingmen = values.List(Wingman, engine.game.mission.wing_size);

/// An objective the objectives window can show.
pub const Objective = struct {
    pub const script_name = "HudObjective";

    /// Its number among the mission's objectives, from 1.
    number: u8,
    /// Its name; nil where the mission's table gives none, for which the window writes an error.
    name: ?Text,
    /// Whether it is the current objective.
    current: bool,
};

/// The objectives window: the objectives it can show, and the one it shows.
pub const Objectives = struct {
    pub const script_name = "HudObjectives";

    /// The objective the window shows, by its number; nil where it shows none.
    shown: ?u8,
    /// The objectives that aren't hidden, which paging through the window passes, in order.
    list: values.List(Objective, hud.Objectives.per_mission),
};

/// The comms window's items, which hold a page of the radio's menu.
pub const MenuItems = values.List(Text, radio_menu.Menu.capacity);

/// The message lines, oldest first, which hold them all.
pub const Messages = values.List(Text, hud.Messages.capacity);

/// The mission's clock as the display shows it: the countdown where the mission counts down, and
/// the time played otherwise.
pub const Clock = struct {
    pub const script_name = "HudClock";

    minutes: u16,
    seconds: u16,
};

/// The status lights, which hold them all.
pub const Lights = values.List(hud.Light, std.enums.values(hud.Light).len);

/// A short text of the game's, in UTF-8, which scripts get as a string: the bytes up to the first
/// zero.
const Text = [256]u8;

/// `shown`, in the game's code page, as a `Text`.
fn textOf(shown: []const u8) Text {
    var held: Text = @splat(0);
    _ = language.decode(held[0 .. held.len - 1], shown);
    return held;
}

/// The game's string `id` out of `strings`, as a `Text`; null for none.
fn stringOf(strings: ?*const language.Language, id: u32) ?Text {
    const held = strings orelse return null;
    return textOf(held.string(id) orelse return null);
}

/// The flight display's state, and the player's ship, while a mission is shown; null otherwise.
fn flightOf(call: Call, comptime label: []const u8) ?struct { presentation.Host.Flight, *const create.Slot } {
    const host = presentation.Presentation.of(call, label).host orelse return null;
    const flight = host.flight orelse return null;
    const all = call.runtime().objects orelse return null;
    return .{ flight, &all.slots[all.player] };
}

pub const replaced = api.Field(Instruments, "The game's instruments the mods' displays stand in for this frame, which aren't drawn (`register_display`).", struct {
    pub fn get(call: Call) Instruments {
        var list: Instruments = .{};
        const placements = presentation.Presentation.of(call, "replaced").instrumentPlacements();
        for (std.enums.values(hud.Instrument)) |instrument| {
            if (placements.get(instrument).hidden) list.append(instrument);
        }
        return list;
    }
});

pub const bounds = api.Function("Where the game's instrument `instrument` last drew, in the window's pixels, as the mods' displays place it, and even while one stands in for it; nil before it first draws, or outside a mission.", &.{"instrument"}, struct {
    fn get(call: Call, instrument: hud.Instrument) ?hud.Clip {
        const flight, _ = flightOf(call, "bounds") orelse return null;
        return flight.hud.bounds.get(instrument);
    }
}.get);

pub const instruments_shown = api.Field(bool, "Whether the game's instruments show this frame: during a mission, in the view ahead from the cockpit.", struct {
    pub fn get(call: Call) bool {
        const host = presentation.Presentation.of(call, "instruments_shown").host orelse return false;
        const held = host.camera orelse return false;
        return hud.instrumented(held.camera.view);
    }
});

pub const guns = api.Field(?Guns, "The player's guns as the gunnery window and the targeting cluster show them; nil outside a mission.", struct {
    pub fn get(call: Call) ?Guns {
        _, const slot = flightOf(call, "guns") orelse return null;
        const combat = slot.combat orelse return null;
        const mode = slot.object.gun_mode;
        return .{
            .group = mode.group,
            .groups = std.math.lossyCast(u8, combat.gun_groups),
            .all = mode.all,
            .synchronised = mode.synchronised,
            .gun = slot.groupLead(mode.group),
            .charge = slot.object.gun_charge,
            .full_charge = combat.gun_energy,
        };
    }
});

pub const missiles = api.Field(?Missiles, "The player's missiles as the missile window shows them; nil outside a mission.", struct {
    pub fn get(call: Call) ?Missiles {
        const flight, _ = flightOf(call, "missiles") orelse return null;
        const ring = &flight.hud.missiles;
        var shown: Missiles = .{ .armed = null, .left = 0, .ring = .{} };
        for (ring.entries) |entry| {
            const left = entry.left() orelse continue;
            shown.ring.append(.{ .type = entry.type, .left = left });
        }
        if (ring.entries[ring.armed].left()) |left| {
            shown.armed = ring.entries[ring.armed].type;
            shown.left = left;
        }
        return shown;
    }
});

pub const target = api.Field(?Target, "The target the display shows, with its subtarget as `component`; nil for none, or outside a mission.", struct {
    pub fn get(call: Call) ?Target {
        const flight, _ = flightOf(call, "target") orelse return null;
        const shown = flight.hud.target orelse return null;
        return .of(shown.target);
    }
});

pub const radar = api.Field(?Radar, "The radar: its range, and the contacts it shows; nil outside a mission.", struct {
    pub fn get(call: Call) ?Radar {
        const flight, _ = flightOf(call, "radar") orelse return null;
        const all = call.runtime().objects orelse return null;
        const state = flight.hud;
        var shown: Radar = .{ .range = state.radar_range, .reach = hud.Radar.ranges[state.radar_range].reach, .zooming = state.radar_zoom != null, .contacts = .{} };
        var contacts: hud.Radar.Contacts = .of(all, state.radar_range, flight.speaker);
        while (contacts.next()) |contact| shown.contacts.append(.{
            .object = .of(contact.slot),
            .at = .{ @floatFromInt(contact.at[0]), @floatFromInt(contact.at[1]), 0 },
            .height = contact.height,
            .look = contact.look,
        });
        return shown;
    }
});

pub const target_display = api.Field(?TargetDisplay, "What the target display shows of its target, in either form, whether or not its window is open; nil without a target or while the display hides it, and outside a mission.", struct {
    pub fn get(call: Call) ?TargetDisplay {
        const flight, _ = flightOf(call, "target_display") orelse return null;
        const all = call.runtime().objects orelse return null;
        const index = (flight.hud.target orelse return null).slot;
        const slot = &all.slots[index];
        const form = target_forms.Form.of(hud.targetWindow(slot)) orelse return null;
        if (form == .small and target_forms.hidden(slot)) return null;
        const facts: target_forms.Facts = .of(all, index);
        const rings = hud.ShipStatus.rings(slot);
        const part = if (target_forms.showsSubtarget(slot)) target_forms.subtarget(all) else null;
        const bar = target_forms.hull(slot);
        return .{
            .form = form,
            .name = if (facts.name) |id| stringOf(flight.strings, id) else null,
            .pilot = if (target_forms.pilotName(all, slot)) |id| stringOf(flight.strings, id) else null,
            .range = facts.range,
            .speed = facts.speed,
            .shields = if (rings) |found| .of(found.shields) else null,
            .armor = if (rings) |found| .of(found.armor) else null,
            .subtarget = if (part) |found| stringOf(flight.strings, found.named.name) else null,
            .subtarget_armor = if (part) |found| if (found.unlit) |unlit| hud.windows.litShare(unlit, target_forms.armor_bar.rows) else null else null,
            .hull = if (bar) |found| hud.windows.litShare(found.unlit, target_forms.hull_bar.rows) else null,
        };
    }
});

pub const kills = api.Field(?i32, "The kills the skull readout shows; nil outside a mission.", struct {
    pub fn get(call: Call) ?i32 {
        return readout(call, "kills", .skull);
    }
});

pub const fuel = api.Field(?i32, "The seconds of afterburner fuel the fuel readout shows; nil outside a mission.", struct {
    pub fn get(call: Call) ?i32 {
        return readout(call, "fuel", .fuel);
    }
});

pub const countermeasures = api.Field(?i32, "The countermeasures the coil readout shows; nil outside a mission.", struct {
    pub fn get(call: Call) ?i32 {
        return readout(call, "countermeasures", .coil);
    }
});

/// The number `which` shows; null outside a mission.
fn readout(call: Call, comptime label: []const u8, which: hud.Readout) ?i32 {
    const flight, const slot = flightOf(call, label) orelse return null;
    return which.value(slot, flight.player);
}

pub const gauges = api.Field(?Gauges, "The targeting cluster about the middle of the screen, as it shows the player's speed, throttle and guns; nil outside a mission.", struct {
    pub fn get(call: Call) ?Gauges {
        _, const slot = flightOf(call, "gauges") orelse return null;
        const shown = hud.Cluster.Gauges.of(slot) orelse return null;
        const throttle, const speed = hud.Cluster.shares(shown);
        const asked, const made = shown.figures();
        return .{
            .speed = made,
            .asked = asked,
            .speed_share = speed,
            .throttle_share = throttle,
            .throttle_brightness = hud.Cluster.throttleBrightness(throttle, speed),
            .charge = shown.chargeShare(),
            .nova = shown.nova != null,
        };
    }
});

pub const ship_status = api.Field(?ShipStatus, "The ship status indicator, as it shows the player's shields and armour; nil for a ship without them, or outside a mission.", struct {
    pub fn get(call: Call) ?ShipStatus {
        const flight, const slot = flightOf(call, "ship_status") orelse return null;
        const found, const shifted = hud.ShipStatus.playerRings(slot, flight.player.shield_reserves);
        const rings = found orelse return null;
        const reserves = shifted orelse .{ 0, 0 };
        return .{ .shields = .of(rings.shields), .armor = .of(rings.armor), .reserve_fore = shownArcs(reserves[0]), .reserve_aft = shownArcs(reserves[1]) };
    }
});

pub const lights = api.Field(Lights, "The status lights that show, steady or flashing, in the order the display packs them; none outside a mission.", struct {
    pub fn get(call: Call) Lights {
        var list: Lights = .{};
        const flight, const slot = flightOf(call, "lights") orelse return list;
        const lit = flight.hud.lightsShown(&slot.object, flight.player.matching_speed, flight.multiplayer);
        inline for (comptime std.enums.values(hud.Light)) |light| {
            if (@field(lit, @tagName(light))) list.append(light);
        }
        return list;
    }
});

pub const clock = api.Field(?Clock, "The mission's clock as the display shows it: the countdown where the mission counts down, and the time played otherwise; nil outside a mission.", struct {
    pub fn get(call: Call) ?Clock {
        const flight, _ = flightOf(call, "clock") orelse return null;
        const all = call.runtime().objects orelse return null;
        const minutes, const seconds = hud.clockTime(all, flight.play, flight.variables);
        return .{ .minutes = minutes, .seconds = seconds };
    }
});

pub const damage = api.Field(?Damage, "The damage window, as it shows how well the player's weapons, engines and shields still work as the armour wears, each from 0 to 1, whether or not the window is open; nil outside a mission.", struct {
    pub fn get(call: Call) ?Damage {
        _, const slot = flightOf(call, "damage") orelse return null;
        const object = &slot.object;
        return .{
            .weapons = hud.damage.System.weapons.condition(object),
            .engines = hud.damage.System.engines.condition(object),
            .shields = hud.damage.System.shields.condition(object),
        };
    }
});

pub const power = api.Field(?Power, "The power window, as it shows the shields', guns' and engines' shares of the player's power, as the whole percentages it writes, whether or not the window is open; nil outside a mission.", struct {
    pub fn get(call: Call) ?Power {
        _, const slot = flightOf(call, "power") orelse return null;
        const shares = power_window.percentages(power_systems.point(&slot.object));
        return .{ .shields = shares.get(.shields), .guns = shares.get(.guns), .engines = shares.get(.engines) };
    }
});

pub const wingmen = api.Field(Wingmen, "The ships of the player's wing the wing status window shows, the player's first, whether or not the window is open; none outside a mission.", struct {
    pub fn get(call: Call) Wingmen {
        var list: Wingmen = .{};
        _ = flightOf(call, "wingmen") orelse return list;
        const all = call.runtime().objects orelse return list;
        var buffer: [engine.game.mission.wing_size]wing_status.Entry = undefined;
        for (wing_status.entries(all, &buffer)) |entry| list.append(.{ .object = .of(entry.slot), .number = entry.number, .armor = entry.armorShare() });
        return list;
    }
});

pub const objectives = api.Field(?Objectives, "The objectives window: the mission's objectives it can show, and the one it shows, whether or not the window is open; nil outside a mission.", struct {
    pub fn get(call: Call) ?Objectives {
        const flight, _ = flightOf(call, "objectives") orelse return null;
        const held = &flight.hud.objectives;
        var shown: Objectives = .{ .shown = if (held.none_shown) null else @as(u8, held.shown) + 1, .list = .{} };
        for (held.states, 0..) |status, index| {
            if (status == .hidden) continue;
            const name: ?Text = if (held.name(@intCast(index))) |named| switch (named) {
                .string => |id| stringOf(flight.strings, id),
                .text => |text| textOf(text),
            } else null;
            shown.list.append(.{ .number = @intCast(index + 1), .name = name, .current = status == .current });
        }
        return shown;
    }
});

pub const comms = api.Field(MenuItems, "The items of the radio's menu the comms window lists, in order, as the number keys pick them, whether or not the window is open; none outside a mission.", struct {
    pub fn get(call: Call) MenuItems {
        var list: MenuItems = .{};
        const flight, _ = flightOf(call, "comms") orelse return list;
        const strings = flight.strings orelse return list;
        for (flight.player.menu.shown()) |item| {
            var buffer: [radio_menu.Label.room]u8 = undefined;
            list.append(textOf(item.label.words(strings, &buffer)));
        }
        return list;
    }
});

pub const messages = api.Field(Messages, "The message lines the display shows, oldest first; none outside a mission.", struct {
    pub fn get(call: Call) Messages {
        var list: Messages = .{};
        const flight, _ = flightOf(call, "messages") orelse return list;
        const held = &flight.hud.messages;
        for (0..held.count) |at| list.append(textOf(held.line(at)));
        return list;
    }
});

pub const subtitle = api.Field(?Text, "The line `DisplaySubTitle` shows near the foot of the screen in the director's view, whichever view it's in; nil for none, and outside a mission.", struct {
    pub fn get(call: Call) ?Text {
        const flight, _ = flightOf(call, "subtitle") orelse return null;
        return stringOf(flight.strings, flight.hud.subtitle.string orelse return null);
    }
});

pub const key_prompt = api.Field(?Action, "The action whose key `WaitForKey`'s prompt asks the player to press; nil while nothing waits, and outside a mission.", struct {
    pub fn get(call: Call) ?Action {
        const flight, _ = flightOf(call, "key_prompt") orelse return null;
        return flight.hud.key_prompt.action;
    }
});

pub const jump_prompt = api.Field(?hud.JumpPrompt.Kind, "The prompt that flashes in the view ahead for what the mission has ready: the warp's or the jump's; nil for none, and outside a mission.", struct {
    pub fn get(call: Call) ?hud.JumpPrompt.Kind {
        const flight, _ = flightOf(call, "jump_prompt") orelse return null;
        const variables = flight.variables orelse return null;
        return hud.JumpPrompt.shown(variables.ready);
    }
});

pub const view_name = api.Field(?Text, "The view's name the display writes at the top of the screen, in the views it names; nil in the others, the view ahead from the cockpit among them, and outside a mission.", struct {
    pub fn get(call: Call) ?Text {
        const flight, _ = flightOf(call, "view_name") orelse return null;
        return stringOf(flight.strings, hud.viewName(flight.last_view) orelse return null);
    }
});

pub const caption = api.Field(?Text, "The date the launch types out at the foot of the screen, as far as it has typed it; nil while it isn't shown, and outside a mission.", struct {
    pub fn get(call: Call) ?Text {
        const flight, _ = flightOf(call, "caption") orelse return null;
        const typed = flight.hud.caption;
        if (!typed.on) return null;
        const all = call.runtime().objects orelse return null;
        const strings = flight.strings orelse return null;
        const date = strings.string(hud.Caption.date(all.mission_number) orelse return null) orelse return null;
        const shows, _ = typed.showing(date);
        return textOf(shows);
    }
});

pub const open_windows = api.Field(Instruments, "The game's windows that are open, opening or closing; none outside a mission.", struct {
    pub fn get(call: Call) Instruments {
        var list: Instruments = .{};
        const flight, _ = flightOf(call, "open_windows") orelse return list;
        for (std.enums.values(hud.windows.Window)) |window| {
            const instrument = hud.Instrument.ofWindow(window) orelse continue;
            if (flight.hud.windows.status.get(window).phase == .shut) continue;
            // Window 14 shows the radio's menu too, which is listed once.
            if (std.mem.findScalar(hud.Instrument, list.slice(), instrument) == null) list.append(instrument);
        }
        return list;
    }
});
