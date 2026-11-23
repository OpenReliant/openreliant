//! The co-op session and deathmatch loadout screens. Both show a roster and the front-end chat.
const std = @import("std");
const ui = @import("../canvas.zig");
const hud = @import("../../hud.zig");
const chat = @import("../../chat.zig");
const Language = @import("../../language.zig").Language;
pub const chat_panel = @import("chat_panel.zig");
const Typed = @import("../../winmain.zig").Typed;
const input = @import("../../../input.zig");
const scenarios = @import("../../dmscenarios.zig");
const CallSign = @import("../pilot_roster.zig").CallSign;
const widgets = @import("widgets.zig");
const choices = @import("choice_list.zig");
const ShipPicker = @import("ship_picker.zig");
const pager_widgets = @import("../settings/widgets.zig");
const tooltips = @import("../../itac/tooltips.zig");
const Label = widgets.Label;
const Lobby = @This();
const ArenaOptions = @import("../../deathmatch.zig").Options;
pub const History = chat_panel.History;

const Crew = @import("debrief_crew.zig");
pub const Team = @import("../../players.zig").ArenaTeam;
pub const Pilot = struct { generation: u64, name: CallSign = .{}, team: Team = .first };
pub const Admission = @import("../../players.zig").ParticipantRef;
pub const Action = union(enum) { leave, main_menu, quit, launch, new_campaign, load_campaign, ready: bool, remove: Admission, choose_ship, choose_team: Team, team_play: bool, arena_option: ArenaOptions.Setting, send_chat: chat.Line, open_to: Reach, copy_invite };
/// Who a hosted game is open to. An OpenReliant addition: the original's games are found on the
/// local network or joined by address.
pub const Reach = enum {
    /// Players on the host's own network, and players given its address.
    lan,
    /// Also the players the host sends its invite to, wherever they are.
    invite,
    /// Also everyone, through the server list.
    public,

    /// Whether players beyond the local network can join.
    fn internet(open_to: Reach) bool {
        return open_to != .lan;
    }
};
/// The invite a host hands to the players it wants, as the lobby shows it.
pub const Invite = union(enum) {
    /// The game is for the local network, which needs none.
    none,
    /// The directory is being asked for one.
    preparing,
    /// The directory can't be reached, or passes no connections.
    unavailable,
    ready: struct { text: []const u8, copied: bool = false },
};
const Role = union(enum) {
    host: struct {
        can_launch: bool = false,
        port: u16,
        /// Who the game is open to, or null where it can only be a LAN game.
        reach: ?Reach = null,
        invite: Invite = .none,
    },
    guest,
};
const Control = enum { back, main_menu, quit, launch, new_campaign, load_campaign, ready, remove, ship, team, ai_turrets, target_players, teams, mode, setup };

role: Role,
roster: []const ?Pilot,
notices: ?*const History = null,
editor: chat_panel.Editor = .{},
caret: chat_panel.Caret = .{},
older_chat: usize = 0,
chat_hover: ?ui.Arrow = null,
local_slot: usize,
dedicated: bool = false,
ready: Crew.Pilots = .empty,
scenario: scenarios.Scenario = .asteroid_field,
mission: ?u16 = null,
loaded_campaign: bool = false,
ship: scenarios.Fighter = .predator,
teams: bool = false,
options: ArenaOptions = .{},
team_open: bool = false,
hover: ?Control = null,
mode_open: bool = false,
/// Whether the host setup is up, and what the pointer is over in it.
setup_open: bool = false,
setup_hover: enum { none, internet, listed, copy, done } = .none,
option_under: ?usize = null,
preview: scenarios.Scenario = .asteroid_field,
first_pilot: usize = 0,
page_under: ?pager_widgets.Step = null,
selected: ?Admission = null,
pointer_held: bool = false,
description_y: i32 = 0,
description_for: ?scenarios.Scenario = null,
description_hover: ?ui.Arrow = null,
help: tooltips.Tooltips = .{},
shown_help: ?tooltips.Tooltip = null,

const coop_chat: chat_panel.Setup = .{ .history = .{ .x = 45, .y = 264, .width = 379, .height = 117 }, .rows = 9 };
const arena_chat: chat_panel.Setup = .{ .history = .{ .x = 45, .y = 300, .width = 379, .height = 81 }, .rows = 6 };
const coop_roster: ui.Rect = .{ .x = 355, .y = 179, .width = 240, .height = 59 };
const arena_roster: ui.Rect = .{ .x = 431, .y = 126, .width = 164, .height = 120 };
const coop_row_height = 13;
const arena_row_height = 14;
const role_label: Label = .{ .english = "HOST CALLSIGN", .installed = 0x13F };
const callsign: Label = .{ .english = "CALLSIGN", .installed = 0x143 };
const players_label: Label = .{ .english = "PLAYERS", .installed = 0x141 };
const fallback_player: Label = .{ .english = "PILOT", .installed = 0xBF };
const ready_label: Label = .{ .english = "READY", .installed = 0x145 };
const unready_label: Label = .{ .english = "NOT READY", .installed = 0x5A8 };
const game_label: Label = .{ .english = "GAME", .installed = 0xC0 };
const ship_label: Label = .{ .english = "SHIP", .installed = 0x2C3 };
const cancel: Label = .{ .english = "BACK", .installed = 0xF7 };
const change_mode: Label = .{ .english = "GAME TYPE", .installed = 0x139 };
const select_mode: Label = .{ .english = "OK", .installed = 0x316 };
const team_play: Label = .{ .english = "TEAM PLAY", .installed = 0x2C6 };
const control_height = 20;
const modal_rows: ui.Rect = .{ .x = 72, .y = 168, .width = 168, .height = choices.height * scenario_options.len };
const details_y = 194;
const details_lines: ui.Canvas.Lines = .{ .width = 302, .height = 15, .most = 8 };
const team_heading_y = details_y + details_lines.height * details_lines.most + 4;
const modal_actions_y = team_heading_y + 53;
const modal_select: ui.Rect = .{ .x = 261, .y = modal_actions_y, .width = 160, .height = control_height };
const modal_cancel: ui.Rect = .{ .x = 72, .y = modal_actions_y, .width = 160, .height = control_height };

const scenario_options = options: {
    var options: [std.enums.values(scenarios.Scenario).len]Label = undefined;
    for (std.enums.values(scenarios.Scenario), &options) |scenario, *option| {
        option.* = .{ .english = scenario.record().name, .installed = scenario.nameString() };
    }
    break :options options;
};

fn sceneChat(lobby: Lobby) chat_panel.Setup {
    return if (lobby.mission == null) arena_chat else coop_chat;
}

fn rosterPanel(lobby: Lobby) ui.Rect {
    return if (lobby.mission == null) arena_roster else coop_roster;
}

fn rowHeight(lobby: Lobby) i16 {
    return if (lobby.mission == null) arena_row_height else coop_row_height;
}

const Field = struct {
    box: ui.Rect,
    label: Label,

    fn draw(field: Field, canvas: ui.Canvas, value: []const u8, lit: bool) !void {
        try write(canvas, .{ field.box.x + 4, field.box.y - 17 }, field.label, ui.blue, .left);
        outline(canvas, field.box);
        try widgets.fittedLabel(canvas, .{ field.box.x + 4, field.box.y + 2 }, field.box.width - 8, value, if (lit) ui.white else ui.blue, .left);
    }
};

const ArtButton = struct {
    at: [2]i32,
    box: ui.Rect,
    shapes: ui.Button.Pair,

    fn draw(button: ArtButton, canvas: ui.Canvas, art: *hud.Art, lit: bool, enabled: bool) !void {
        try canvas.dimmedUnless(enabled).shape(art, if (lit) button.shapes.lit else button.shapes.off, button.at);
    }
};

const standard: ui.Button.Pair = .{ .off = 0x17, .lit = 0x18 };
const large: ui.Button.Pair = .{ .off = 0x13, .lit = 0x14 };
const dropdown: ui.Button.Pair = .{ .off = 0x15, .lit = 0x16 };
const coop_back: ArtButton = .{ .at = .{ 324, 421 }, .box = .{ .x = 323, .y = 420, .width = 82, .height = 16 }, .shapes = standard };
const arena_back: ArtButton = .{ .at = .{ 323, 421 }, .box = coop_back.box, .shapes = standard };
const main_menu_button: ArtButton = .{ .at = .{ 292, 441 }, .box = .{ .x = 198, .y = 441, .width = 119, .height = 16 }, .shapes = standard };
const quit_button: ArtButton = .{ .at = .{ 324, 441 }, .box = .{ .x = 323, .y = 441, .width = 81, .height = 16 }, .shapes = standard };
const coop_start: ArtButton = .{ .at = .{ 464, 386 }, .box = .{ .x = 463, .y = 380, .width = 107, .height = 27 }, .shapes = large };
const coop_remove: ArtButton = .{ .at = .{ 567, 242 }, .box = .{ .x = 495, .y = 239, .width = 101, .height = 24 }, .shapes = large };
const coop_new: ArtButton = .{ .at = .{ 469, 300 }, .box = .{ .x = 468, .y = 300, .width = 86, .height = 16 }, .shapes = standard };
const coop_load: ArtButton = .{ .at = .{ 469, 343 }, .box = .{ .x = 468, .y = 343, .width = 86, .height = 16 }, .shapes = standard };
const arena_start: ArtButton = .{ .at = .{ 463, 388 }, .box = coop_start.box, .shapes = large };
const ship_arrow: ArtButton = .{ .at = .{ 399, 168 }, .box = .{ .x = 398, .y = 164, .width = 27, .height = 21 }, .shapes = dropdown };
const ship_field: Field = .{ .box = .{ .x = 201, .y = 164, .width = 192, .height = 21 }, .label = ship_label };
const team_field: Field = .{ .box = .{ .x = 201, .y = 126, .width = 59, .height = 21 }, .label = .{ .english = "TEAM", .installed = 0x2C2 } };
const team_arrow: ArtButton = .{ .at = .{ 266, 130 }, .box = .{ .x = 264, .y = 126, .width = 29, .height = 21 }, .shapes = dropdown };
const ArenaSwitch = struct {
    control: Control,
    label: Label,
    help_id: u16,
    help_text: []const u8,
    y: i16,

    fn box(setting: ArenaSwitch) ui.Rect {
        return .{ .x = 463, .y = setting.y - 4, .width = 133, .height = 22 };
    }

    fn visible(setting: ArenaSwitch, lobby: *const Lobby) bool {
        return lobby.mission == null and lobby.role == .host and
            (setting.control != .teams or lobby.scenario.record().teams != .none);
    }

    fn draw(setting: ArenaSwitch, lobby: *const Lobby, canvas: ui.Canvas, art: *hud.Art) !void {
        const checked = switch (setting.control) {
            .ai_turrets => lobby.options.ai_turrets,
            .target_players => lobby.options.target_players,
            .teams => lobby.teams,
            else => unreachable,
        };
        try drawCheck(canvas, art, .{ 578, setting.y }, checked);
        try write(canvas, .{ 572, setting.y - 1 }, setting.label, if (lobby.hover == setting.control) ui.white else ui.blue, .right);
    }
};

const arena_switches = [_]ArenaSwitch{
    .{ .control = .ai_turrets, .label = .{ .english = "AI TURRETS", .installed = 0x30A }, .help_id = 0x5A0, .help_text = "Click to toggle AI turrets.", .y = 312 },
    .{ .control = .target_players, .label = .{ .english = "TARGET PLAYERS", .installed = 0x30B }, .help_id = 0x5A1, .help_text = "Click to toggle player targeting.", .y = 334 },
    .{ .control = .teams, .label = .{ .english = "TEAMPLAY", .installed = 0x30C }, .help_id = 0x5A2, .help_text = "Click to toggle team play.", .y = 356 },
};
const team_step = 22; // 0x0044DC18
const team_colours: std.EnumArray(Team, [3]f32) = .init(.{
    .first = hud.rgb(0xAD0000),
    .second = hud.rgb(0x2AC900),
    .third = hud.rgb(0xFFF600),
    .fourth = hud.rgb(0x004AC4),
}); // RGB triples at 0x0044CC58 to 0x0044CC8F.

fn teamOption(team: Team) ui.Rect {
    return .{ .x = 201, .y = 148 + @as(i16, @backingInt(team)) * team_step, .width = 59, .height = 21 };
}

fn drawSwatch(canvas: ui.Canvas, team: Team, box: ui.Rect, inset: i16) void {
    canvas.wipe(.{ box.x + inset, box.y + inset }, .{ box.x + box.width - inset, box.y + box.height - inset }, team_colours.get(team));
}
const coop_lead: Field = .{ .box = .{ .x = 45, .y = 179, .width = 149, .height = 21 }, .label = role_label };
const coop_game: Field = .{ .box = .{ .x = 45, .y = 217, .width = 149, .height = 21 }, .label = game_label };
const coop_mission: Field = .{ .box = .{ .x = 201, .y = 217, .width = 84, .height = 21 }, .label = .{ .english = "MISSION", .installed = 0xE5 } };
const arena_lead: Field = .{ .box = .{ .x = 45, .y = 164, .width = 149, .height = 21 }, .label = role_label };

/// The button that opens the host setup, where the host's port is shown otherwise.
const setup_button: ui.Rect = .{ .x = 460, .y = 432, .width = 135, .height = control_height };
const setup_label: Label = .{ .english = "HOST SETUP" };
const help_setup = "Click to choose who can join, and to copy the invite for your friends.";
// The host setup, a dialog of OpenReliant's own in the style of the game type's.
const setup_top = 107;
/// A switch of the host setup: a checkbox, its name, and a line that says what its setting does.
const SetupSwitch = struct {
    y: i16,
    label: Label,
    on: Label,
    off: Label,

    fn box(setting: SetupSwitch) ui.Rect {
        return .{ .x = 72, .y = setting.y - 4, .width = 496, .height = 38 };
    }

    fn draw(setting: SetupSwitch, canvas: ui.Canvas, art: *hud.Art, checked: bool, lit: bool) !void {
        try drawCheck(canvas, art, .{ 72, setting.y }, checked);
        try write(canvas, .{ 98, setting.y - 1 }, setting.label, if (lit) ui.white else ui.blue, .left);
        try write(canvas, .{ 98, setting.y + 16 }, if (checked) setting.on else setting.off, ui.blue, .left);
    }
};
const internet_switch: SetupSwitch = .{
    .y = 160,
    .label = .{ .english = "INTERNET GAME" },
    .on = .{ .english = "Friends anywhere can join over the internet. Works on most networks." },
    .off = .{ .english = "Only players on your network can join." },
};
const listed_switch: SetupSwitch = .{
    .y = 206,
    .label = .{ .english = "SHOW IN SERVER LIST" },
    .on = .{ .english = "Everyone can find the game in the INTERNET list." },
    .off = .{ .english = "Private: only friends you send the invite to can join." },
};
const invite_heading: Label = .{ .english = "INVITE" };
const invite_box: ui.Rect = .{ .x = 72, .y = 270, .width = 384, .height = 21 };
const invite_copy: ui.Rect = .{ .x = 468, .y = 270, .width = 100, .height = control_height };
const copy_label: Label = .{ .english = "COPY" };
const invite_help: Label = .{ .english = "Send it to your friends. They paste it as the address and connect." };
const invite_copied: Label = .{ .english = "Copied. Paste it in a message to your friends." };
const invite_preparing: Label = .{ .english = "Getting ready..." };
const invite_unavailable: Label = .{ .english = "Not available: the directory can't be reached." };
const setup_done: ui.Rect = .{ .x = 72, .y = 328, .width = 160, .height = control_height };
const setup_modal: ui.Rect = .{ .x = 44, .y = setup_top, .width = 552, .height = setup_done.y + 35 - setup_top };

/// The host's reach, where the lobby offers the choice.
fn reach(lobby: *const Lobby) ?Reach {
    return if (lobby.role == .host) lobby.role.host.reach else null;
}

/// The invite to show, where the game is open beyond the local network.
fn invite(lobby: *const Lobby) Invite {
    return if (lobby.reach() != null) lobby.role.host.invite else .none;
}

const help_start: tooltips.Tooltip = .{ .rect = arena_start.box, .string = 0x598, .fallback = "Click to start the game currently selected." };
const help_lead = "Displays the host's callsign.";

/// The original setup screens register their controls with `tooltip_add` (0x0043CFE2,
/// 0x0043D060, 0x0044C210 and 0x0044C22C). Use the game's strings and the ITAC tooltip style.
pub fn updateHelp(lobby: *Lobby, at: ?[2]i32, ticks: u32) void {
    lobby.shown_help = null;
    const pointer = at orelse {
        lobby.help = .{};
        return;
    };
    const host = lobby.role == .host;
    const start_help: tooltips.Tooltip = if (host)
        .{ .rect = coop_start.box, .string = 0x599, .fallback = "Click to start the game" }
    else if (lobby.isReady(lobby.local_slot))
        .{ .rect = coop_start.box, .string = 0x5A7, .fallback = "Click if not ready to start game" }
    else
        help_start;
    const coop = [_]tooltips.Tooltip{
        .{ .rect = coop_lead.box, .string = 0x592, .fallback = help_lead },
        .{ .rect = coop_mission.box, .string = 0x594, .fallback = "Displays the mission number." },
        start_help,
        .{ .rect = coop_game.box, .string = 0x59C, .fallback = "Displays the session name." },
        .{ .rect = coop_remove.box, .string = 0x595, .fallback = "Click to remove the player currently selected in Players box from the session." },
        .{ .rect = coop_new.box, .string = 0x596, .fallback = "Click to start a new game" },
        .{ .rect = coop_load.box, .string = 0x597, .fallback = "Click to bring up a list of saved games." },
    };
    const arena = [_]tooltips.Tooltip{
        .{ .rect = ship_arrow.box, .string = 0x5A3, .fallback = "Click to select a list of ships to fly" },
        if (host) help_start else .{ .rect = arena_lead.box, .string = 0x592, .fallback = help_lead },
        .{ .rect = if (lobby.teams) team_arrow.box else tooltips.Tooltip.no_rect, .string = 0x59F, .fallback = "Click to select a team colour." },
    } ++ switches: {
        var tips: [arena_switches.len]tooltips.Tooltip = undefined;
        for (arena_switches, &tips) |setting, *tip| {
            tip.* = .{ .rect = if (setting.visible(lobby)) setting.box() else tooltips.Tooltip.no_rect, .string = setting.help_id, .fallback = setting.help_text };
        }
        break :switches tips;
    };
    const sharing = [_]tooltips.Tooltip{
        .{ .rect = if (lobby.reach() != null) setup_button else tooltips.Tooltip.no_rect, .string = 0, .fallback = help_setup },
    };
    const arena_help = arena ++ sharing;
    const coop_help = coop ++ sharing;
    const help = if (lobby.mission == null) &arena_help else if (host) coop_help[0..] else coop_help[0..4];
    if (lobby.help.update(help, pointer, ticks)) |index| lobby.shown_help = help[index];
}

const mode_list: ui.Rect = .{ .x = 45, .y = 164, .width = 149, .height = 90 };
const mode_first_y = 166;
const mode_step = 14;
const description_box: ui.Rect = .{ .x = 201, .y = 202, .width = 223, .height = 81 };
const description_arrows: widgets.ScrollArrows = .{ .x = 428, .y = 251 };
// Match the neighbouring fields' text inset and leave room for the outline edges.
const description_inset = 4;
const description_text: ui.Rect = .{
    .x = description_box.x + description_inset,
    .y = description_box.y + description_inset,
    .width = description_box.width - 2 * description_inset,
    .height = description_box.height - 2 * description_inset,
};
const description_lines: ui.Canvas.Lines = .{ .width = description_text.width, .height = 12, .most = 14 };

/// The stock description arrows move the text in the clipped pane (0x0044C7C5).
pub fn scrollDescription(lobby: *Lobby, pointer: ui.Pointer, font: *hud.Opened, strings: Language) void {
    if (lobby.mission != null or lobby.mode_open) return;
    if (lobby.description_for != lobby.scenario) {
        lobby.description_for = lobby.scenario;
        lobby.description_y = 0;
    }
    lobby.description_hover = description_arrows.under(pointer.at);
    var change: i32 = 0;
    if (pointer.down) if (lobby.description_hover) |way| {
        change = if (way == .up) -1 else 1;
    };
    const max_notches: i32 = @intCast(description_lines.most);
    if (description_box.holds(pointer.at)) change -= std.math.clamp(pointer.wheel, -max_notches, max_notches) * description_lines.height;
    if (change == 0) return;
    var buffer: [2048]u8 = undefined;
    const words = descriptionText(lobby.scenario, strings, &buffer);
    const lines: i32 = @intCast(description_lines.count(font, words));
    const limit = @max(0, lines - 3) * description_lines.height;
    lobby.description_y = std.math.clamp(lobby.description_y + change, 0, limit);
}

fn controlAt(lobby: *const Lobby, at: [2]i32) ?Control {
    const coop = lobby.mission != null;
    if (coop_back.box.holds(at)) return .back;
    if (main_menu_button.box.holds(at)) return .main_menu;
    if (quit_button.box.holds(at)) return .quit;
    if (coop_start.box.holds(at)) {
        if (lobby.role == .host and lobby.role.host.can_launch) return .launch;
        if (coop and lobby.role == .guest and lobby.local_slot < Crew.size) return .ready;
    }
    if (coop and lobby.role == .host and coop_remove.box.holds(at) and lobby.selectedPilot() != null) return .remove;
    if (coop and lobby.role == .host) {
        if (coop_new.box.holds(at)) return .new_campaign;
        if (coop_load.box.holds(at)) return .load_campaign;
    }
    if (!coop and (ship_field.box.holds(at) or ship_arrow.box.holds(at))) return .ship;
    if (!coop and lobby.teams and (team_field.box.holds(at) or team_arrow.box.holds(at))) return .team;
    for (arena_switches) |setting| {
        if (setting.visible(lobby) and setting.box().holds(at)) return setting.control;
    }
    if (!coop and lobby.role == .host and mode_list.holds(at)) return .mode;
    if (lobby.reach() != null and setup_button.holds(at)) return .setup;
    return null;
}

fn modeFrame(lobby: *Lobby, pointer: ui.Pointer, escape: bool) void {
    lobby.option_under = choices.hit(modal_rows, pointer.at);
    if (escape) {
        lobby.mode_open = false;
    } else if (pointer.down) {
        if (lobby.option_under) |index| {
            lobby.preview = @fromBackingInt(@intCast(index));
        } else if (modal_cancel.holds(pointer.at)) {
            lobby.mode_open = false;
        } else if (modal_select.holds(pointer.at)) {
            lobby.scenario = lobby.preview;
            if (lobby.scenario.record().teams == .none) lobby.teams = false;
            lobby.mode_open = false;
        }
    }
}

/// The host setup: who the game is open to, and the invite to hand out. A choice takes effect
/// at once, so the dialog has one button, which closes it.
fn setupFrame(lobby: *Lobby, pointer: ui.Pointer, escape: bool) ?Action {
    const open_to = lobby.reach() orelse {
        lobby.setup_open = false;
        return null;
    };
    lobby.setup_hover = if (internet_switch.box().holds(pointer.at))
        .internet
    else if (open_to.internet() and listed_switch.box().holds(pointer.at))
        .listed
    else if (lobby.invite() == .ready and (invite_copy.holds(pointer.at) or invite_box.holds(pointer.at)))
        .copy
    else if (setup_done.holds(pointer.at))
        .done
    else
        .none;
    if (escape) lobby.setup_open = false;
    if (escape or !pointer.down) return null;
    switch (lobby.setup_hover) {
        .none => return null,
        // An internet game starts for invited players only: the host lists it if they want.
        .internet => return .{ .open_to = if (open_to.internet()) .lan else .invite },
        .listed => return .{ .open_to = if (open_to == .public) .invite else .public },
        .copy => return .copy_invite,
        .done => {
            lobby.setup_open = false;
            return null;
        },
    }
}

/// `session_loadout_draw` draws the stock checkbox and mark at 0x0044D898 and 0x0044D91A. The
/// mark goes underneath the frame and overlaps its inner edge by one source pixel.
fn drawCheck(canvas: ui.Canvas, art: *hud.Art, at: [2]i32, checked: bool) !void {
    const factor = canvas.scale();
    const anchor = canvas.point(at);
    const overhang = hud.round(factor);
    const corner = [2]i32{ anchor[0] - overhang, anchor[1] - overhang };
    const size_pixels = hud.round(17 * factor);
    if (checked) try canvas.squareShape(art, 0x1D, .{ corner[0] + overhang, corner[1] + overhang }, size_pixels - 2 * overhang);
    try canvas.squareShape(art, 0x1C, corner, size_pixels);
}

fn drawSetup(lobby: *const Lobby, canvas: ui.Canvas, art: *hud.Art) !void {
    const open_to = lobby.reach() orelse return;
    const strings = canvas.strings.*;
    widgets.modal(canvas, setup_modal);
    try widgets.title(canvas, .{ 72, 122 }, setup_label);
    try internet_switch.draw(canvas, art, open_to.internet(), lobby.setup_hover == .internet);
    try listed_switch.draw(canvas.dimmedUnless(open_to.internet()), art, open_to == .public, lobby.setup_hover == .listed);
    const shared = lobby.invite();
    if (shared != .none) {
        try write(canvas, .{ invite_box.x, invite_box.y - 17 }, invite_heading, ui.blue, .left);
        outline(canvas, invite_box);
        const inside: ui.Rect = .{ .x = invite_box.x + 4, .y = invite_box.y, .width = invite_box.width - 8, .height = invite_box.height };
        const below: [2]i32 = .{ invite_box.x, invite_box.y + invite_box.height + 6 };
        switch (shared) {
            .none => unreachable,
            .preparing => try canvas.text(canvas.fonts.small, .{ inside.x, inside.y + 2 }, invite_preparing.text(strings), ui.blue, .left),
            .unavailable => try canvas.text(canvas.fonts.small, .{ inside.x, inside.y + 2 }, invite_unavailable.text(strings), ui.blue, .left),
            .ready => |ready| {
                // The invite is longer than the field, which shows its end, as a text field
                // does once its text is typed.
                try canvas.within(inside).text(canvas.fonts.small, .{ inside.x + inside.width, inside.y + 2 }, ready.text, ui.white, .right);
                try write(canvas, below, if (ready.copied) invite_copied else invite_help, if (ready.copied) ui.white else ui.blue, .left);
            },
        }
        try widgets.button(canvas, art, invite_copy, copy_label, shared == .ready, lobby.setup_hover == .copy);
    }
    try widgets.button(canvas, art, setup_done, select_mode, true, lobby.setup_hover == .done);
}

fn isReady(lobby: Lobby, slot: usize) bool {
    return slot == 0 or (slot < Crew.size and lobby.ready.isSet(slot));
}

fn playerWindow(lobby: Lobby) ui.Scrolled(usize) {
    var count: usize = 0;
    for (lobby.roster) |entry| count += @intFromBool(entry != null);
    const shown: usize = @intCast(@divFloor(lobby.rosterPanel().height - 3, lobby.rowHeight()));
    return .{ .first = @min(lobby.first_pilot, count -| shown), .count = count, .shown = shown };
}

fn selectedPilot(lobby: *const Lobby) ?Admission {
    const selected = lobby.selected orelse return null;
    if (selected.slot == 0 or selected.slot >= lobby.roster.len) return null;
    const pilot = lobby.roster[selected.slot] orelse return null;
    return if (pilot.generation == selected.generation) selected else null;
}

fn pilotAt(lobby: *const Lobby, at: [2]i32) ?Admission {
    const panel = lobby.rosterPanel();
    if (!panel.holds(at)) return null;
    const list = lobby.playerWindow();
    const selected = list.first + @as(usize, @intCast(@divFloor(at[1] - panel.y, lobby.rowHeight())));
    if (selected >= list.end()) return null;
    var row: usize = 0;
    for (lobby.roster, 0..) |entry, slot| {
        const pilot = entry orelse continue;
        if (row == selected) return .{ .slot = @intCast(slot), .generation = pilot.generation };
        row += 1;
    }
    return null;
}

fn playerPager(panel: ui.Rect) pager_widgets.Line {
    return .withArrowsAt(.{ panel.x + panel.width - 50, panel.y - 16 });
}

fn scrollPlayers(lobby: *Lobby, pointer: ui.Pointer) void {
    var list = lobby.playerWindow();
    const panel = lobby.rosterPanel();
    lobby.page_under = null;
    if (list.count > list.shown) {
        if (panel.holds(pointer.at)) list.wheel(pointer.wheel);
        if (playerPager(panel).arrowAt(pointer.at)) |arrow| {
            lobby.page_under = arrow;
            if (pointer.down) list.scroll(if (arrow == .back) .up else .down);
        }
    }
    lobby.first_pilot = list.first;
}

pub fn frame(lobby: *Lobby, mouse: ui.Pointer, keys: *input.Keyboard, typed: *Typed, _: [2]u32) ?Action {
    var pointer = mouse;
    pointer.down = mouse.down and !lobby.pointer_held;
    lobby.pointer_held = mouse.down;
    const escape = keys.pressed(input.scan.escape, .none, true);
    if (lobby.mode_open) {
        typed.clear();
        lobby.modeFrame(pointer, escape);
        return null;
    }
    if (lobby.setup_open) {
        typed.clear();
        return lobby.setupFrame(pointer, escape);
    }
    if (lobby.team_open) {
        const chosen = for (std.enums.values(Team)) |team| {
            if (teamOption(team).holds(pointer.at)) break team;
        } else null;
        if (escape or !lobby.teams) lobby.team_open = false;
        if (!pointer.down or !lobby.team_open) return null;
        lobby.team_open = false;
        return if (chosen) |team| .{ .choose_team = team } else null;
    }
    lobby.scrollPlayers(pointer);
    const setup = lobby.sceneChat();
    setup.frame(lobby.notices, &lobby.older_chat, pointer, &lobby.chat_hover);
    const was_focused = lobby.editor.focused;
    if (lobby.editor.frameIn(setup.entry(), pointer, keys, typed, escape)) |line| {
        lobby.older_chat = 0;
        return .{ .send_chat = line };
    }
    if (escape) return if (was_focused) null else .leave;
    lobby.hover = lobby.controlAt(pointer.at);
    if (!pointer.down) return null;
    if (lobby.mission != null and lobby.role == .host and lobby.rosterPanel().holds(pointer.at)) {
        lobby.selected = lobby.pilotAt(pointer.at);
    }
    return switch (lobby.hover orelse return null) {
        .back => .leave,
        .main_menu => .main_menu,
        .quit => .quit,
        .launch => .launch,
        .new_campaign => .new_campaign,
        .load_campaign => .load_campaign,
        .ready => .{ .ready = !lobby.isReady(lobby.local_slot) },
        .remove => .{ .remove = lobby.selectedPilot().? },
        .ship => .choose_ship,
        .teams => .{ .team_play = !lobby.teams },
        .setup => open: {
            lobby.setup_open = true;
            lobby.option_under = null;
            break :open null;
        },
        .ai_turrets => .{ .arena_option = .ai_turrets },
        .target_players => .{ .arena_option = .target_players },
        .team => open: {
            lobby.team_open = true;
            lobby.option_under = null;
            break :open null;
        },
        .mode => mode: {
            // The original list and description remain visible. Use the approved picker for
            // expanded descriptions and confirmation.
            lobby.mode_open = true;
            lobby.preview = @fromBackingInt(@as(u8, @intCast(@min(scenario_options.len - 1, @divFloor(@max(pointer.at[1] - mode_first_y, 0), mode_step)))));
            lobby.option_under = null;
            break :mode null;
        },
    };
}

fn write(canvas: ui.Canvas, at: [2]i32, label: Label, colour: [3]f32, alignment: hud.Align) !void {
    try canvas.text(canvas.fonts.small, at, label.text(canvas.strings.*), colour, alignment);
}

fn outline(canvas: ui.Canvas, box: ui.Rect) void {
    canvas.box(.{ box.x, box.y }, .{ box.width, box.height });
}

fn pilotName(canvas: ui.Canvas, slot: usize, name: *const CallSign, fallback: []u8) []const u8 {
    if (name.len != 0) return name.slice();
    const label = fallback_player.text(canvas.strings.*);
    return std.fmt.bufPrint(fallback, "{s} {d}", .{ label, slot + 1 }) catch label;
}

fn nameAt(lobby: Lobby, canvas: ui.Canvas, slot: usize, fallback: []u8) []const u8 {
    if (slot >= lobby.roster.len) return "";
    return if (lobby.roster[slot]) |*pilot| pilotName(canvas, slot, &pilot.name, fallback) else "";
}

fn drawPlayers(lobby: *const Lobby, canvas: ui.Canvas, paging_art: ?*hud.Art) !void {
    const coop = lobby.mission != null;
    const panel = lobby.rosterPanel();
    const left = panel.x + 4;
    const right = panel.x + panel.width - 4;
    const heading = panel.y - 17;
    const list = lobby.playerWindow();
    const label: Label = if (coop) .{ .english = "STATUS", .installed = 0x142 } else .{ .english = "TEAM", .installed = 0x2C2 };
    try write(canvas, .{ left, heading }, players_label, ui.blue, .left);
    try write(canvas, .{ right, heading }, label, ui.blue, .right);
    outline(canvas, panel);
    if (list.count > list.shown) {
        const pager = playerPager(panel);
        if (paging_art) |art| {
            try pager.drawArrows(canvas, art);
            if (lobby.page_under) |which| try pager.drawLit(canvas, art, which);
        }
    }
    if (list.count == 0) try write(canvas, .{ left, panel.y }, .{ .english = "No players found.", .installed = 0x144 }, ui.blue, .left);
    var row: usize = 0;
    for (lobby.roster, 0..) |*entry, slot| {
        const pilot = if (entry.*) |*present| present else continue;
        defer row += 1;
        if (row < list.first) continue;
        if (row == list.end()) break;
        const y = panel.y + @as(i16, if (coop) 0 else 2) + @as(i16, @intCast(row - list.first)) * lobby.rowHeight();
        var fallback: [64]u8 = undefined;
        const selected = if (lobby.selectedPilot()) |adm| adm.slot == slot else false;
        const colour = if (slot == lobby.local_slot or selected) ui.white else ui.blue;
        const status: Label = if (coop) ready_label else .{ .english = "N/A", .installed = 0x310 };
        const available: i16 = if (coop) 167 else 118;
        try widgets.fittedLabel(canvas, .{ left, y }, available, pilotName(canvas, slot, &pilot.name, &fallback), colour, .left);
        if (lobby.teams) {
            drawSwatch(canvas, pilot.team, .{ .x = right - 28, .y = y, .width = 28, .height = 11 }, 0);
        } else if (!coop or lobby.isReady(slot)) try write(canvas, .{ right, y }, status, ui.blue, .right);
    }
}

/// `multiplayer_sessions_draw` (0x0043DA40) uses the stock co-op positions and palette. The
/// transport has already opened the session. It uses the profile callsign and sets the mission
/// when the host starts a new campaign.
fn drawCoop(lobby: *const Lobby, canvas: ui.Canvas, art: *hud.Art) !void {
    const host = lobby.role == .host;
    const title: Label = if (host) .{ .english = "COOPERATIVE MULTIPLAYER HOST", .installed = 0x147 } else .{ .english = "COOPERATIVE MULTIPLAYER JOIN", .installed = 0x146 };
    try write(canvas, .{ 320, 98 }, title, ui.blue, .centre);
    const call: Field = .{ .box = .{ .x = 45, .y = 140, .width = 149, .height = 21 }, .label = callsign };
    var local_name: [64]u8 = undefined;
    var host_name: [64]u8 = undefined;
    if (!host) try call.draw(canvas, lobby.nameAt(canvas, lobby.local_slot, &local_name), false);
    try coop_lead.draw(canvas, if (lobby.dedicated) canvas.strings.stringOr(0x310, "N/A") else lobby.nameAt(canvas, 0, &host_name), false);
    // multiplayer_sessions_screen starts with the installed default (0x0043D020).
    try coop_game.draw(canvas, canvas.strings.stringOr(0x414, "New Session"), false);
    var number: [16]u8 = undefined;
    try coop_mission.draw(canvas, std.fmt.bufPrint(&number, "{d}", .{lobby.mission.?}) catch unreachable, false);
    const lit = lobby.hover == .launch or lobby.hover == .ready;
    try coop_start.draw(canvas, art, lit, !host or lobby.role.host.can_launch);
    if (host) {
        try coop_new.draw(canvas, art, !lobby.loaded_campaign or lobby.hover == .new_campaign, true);
        try write(canvas, .{ 499, 300 }, .{ .english = "NEW", .installed = 0x148 }, ui.blue, .left);
        try coop_load.draw(canvas, art, lobby.loaded_campaign or lobby.hover == .load_campaign, true);
        try write(canvas, .{ 499, 343 }, .{ .english = "LOAD", .installed = 0x149 }, ui.blue, .left);
        try coop_remove.draw(canvas, art, lobby.hover == .remove, lobby.selectedPilot() != null);
        try write(canvas, .{ 563, 237 }, .{ .english = "REMOVE", .installed = 0x2C5 }, ui.blue, .right);
        try write(canvas, .{ 563, 249 }, fallback_player, ui.blue, .right);
        try write(canvas, .{ 498, 382 }, .{ .english = "START", .installed = 0x14A }, ui.blue, .left);
        try write(canvas, .{ 498, 394 }, game_label, ui.blue, .left);
    } else {
        try write(canvas, .{ 494, 390 }, if (lobby.isReady(lobby.local_slot)) unready_label else ready_label, ui.blue, .left);
    }
}

/// `session_loadout_draw` (0x0044CB60) places setup controls and chat beside the pilot list.
/// The detailed mode and illustrated fighter pickers are OpenReliant additions.
fn drawArena(lobby: *const Lobby, canvas: ui.Canvas, art: *hud.Art) !void {
    const host = lobby.role == .host;
    const title: Label = if (host) .{ .english = "DEATHMATCH HOST", .installed = 0x2C1 } else .{ .english = "DEATHMATCH JOIN", .installed = 0x2D3 };
    try write(canvas, .{ 320, if (host) 98 else 95 }, title, ui.blue, .centre);
    const local: Field = .{ .box = .{ .x = 45, .y = 126, .width = 149, .height = 21 }, .label = if (host) role_label else callsign };
    var local_name: [64]u8 = undefined;
    var host_name: [64]u8 = undefined;
    try local.draw(canvas, lobby.nameAt(canvas, lobby.local_slot, &local_name), false);
    const selected: Field = .{ .box = .{ .x = 45, .y = 202, .width = 149, .height = 18 }, .label = game_label };
    if (host) {
        try write(canvas, .{ 49, 147 }, game_label, ui.blue, .left);
        outline(canvas, mode_list);
        for (scenario_options, 0..) |label, index| {
            const colour = if (@backingInt(lobby.scenario) == index) ui.white else ui.blue;
            try widgets.fittedLabel(canvas, .{ 48, mode_first_y + mode_step * @as(i32, @intCast(index)) }, mode_list.width - 6, label.text(canvas.strings.*), colour, .left);
        }
    } else {
        try arena_lead.draw(canvas, if (lobby.dedicated) canvas.strings.stringOr(0x310, "N/A") else lobby.nameAt(canvas, 0, &host_name), false);
        try selected.draw(canvas, scenario_options[@backingInt(lobby.scenario)].text(canvas.strings.*), false);
    }
    const member = if (lobby.local_slot < lobby.roster.len) lobby.roster[lobby.local_slot] else null;
    const team = if (member) |pilot| pilot.team else .first;
    try team_field.draw(canvas, if (lobby.teams) "" else canvas.strings.stringOr(0x310, "N/A"), lobby.hover == .team);
    if (lobby.teams) {
        drawSwatch(canvas, team, team_field.box, 2);
        try team_arrow.draw(canvas, art, lobby.hover == .team or lobby.team_open, true);
    }
    for (arena_switches) |setting| {
        if (setting.visible(lobby)) try setting.draw(lobby, canvas, art);
    }
    try ship_field.draw(canvas, ShipPicker.label(lobby.ship).text(canvas.strings.*), lobby.hover == .ship);
    try ship_arrow.draw(canvas, art, lobby.hover == .ship, true);
    try write(canvas, .{ 205, 185 }, .{ .english = "GAME DESCRIPTION", .installed = 0x2C4 }, ui.blue, .left);
    outline(canvas, description_box);
    var room: [2048]u8 = undefined;
    const words = descriptionText(lobby.scenario, canvas.strings.*, &room);
    const scroll = if (lobby.description_for == lobby.scenario) lobby.description_y else 0;
    try canvas.within(description_text).wrapped(canvas.fonts.small, .{ description_text.x, description_text.y - scroll }, words, ui.blue, .left, description_lines);
    try description_arrows.draw(canvas, art, lobby.description_hover);
    if (host) try arena_start.draw(canvas, art, lobby.hover == .launch, lobby.role.host.can_launch);
    const top: Label = if (host) .{ .english = "START", .installed = 0x5B6 } else .{ .english = "WAITING", .installed = 0x30E };
    const bottom: Label = if (host) .{ .english = "GAME", .installed = 0x5B7 } else .{ .english = "FOR HOST", .installed = 0x30F };
    try write(canvas, .{ 496, 384 }, top, ui.blue, .left);
    try write(canvas, .{ 496, 396 }, bottom, ui.blue, .left);
}

pub fn draw(lobby: *const Lobby, canvas: ui.Canvas, art: *hud.Art, paging_art: ?*hud.Art) !void {
    if (lobby.mission == null) try lobby.drawArena(canvas, art) else try lobby.drawCoop(canvas, art);
    try lobby.drawPlayers(canvas, paging_art);
    try lobby.sceneChat().draw(canvas, art, lobby.notices, lobby.older_chat, lobby.chat_hover, &lobby.editor, lobby.caret);
    const back = if (lobby.mission == null) arena_back else coop_back;
    try back.draw(canvas, art, lobby.hover == .back, true);
    try write(canvas, .{ if (lobby.mission == null) 351 else 353, 421 }, cancel, ui.blue, .left);
    try main_menu_button.draw(canvas, art, lobby.hover == .main_menu, true);
    try write(canvas, .{ 287, 441 }, .{ .english = "MAIN MENU", .installed = 0xBB }, ui.blue, .right);
    try quit_button.draw(canvas, art, lobby.hover == .quit, true);
    try write(canvas, .{ if (lobby.mission == null) 351 else 353, 441 }, .{ .english = "QUIT", .installed = 0xBC }, ui.blue, .left);
    if (lobby.reach() != null) {
        try widgets.button(canvas, art, setup_button, setup_label, true, lobby.hover == .setup);
    } else if (lobby.role == .host) {
        var port: [16]u8 = undefined;
        try write(canvas, .{ 460, 427 }, .{ .english = "PORT", .installed = 0x1A7 }, ui.blue, .left);
        try canvas.text(canvas.fonts.small, .{ 460, 441 }, std.fmt.bufPrint(&port, "UDP {d}", .{lobby.role.host.port}) catch unreachable, ui.blue, .left);
    }
    if (lobby.mode_open) try lobby.drawModes(canvas, art);
    if (lobby.setup_open) try lobby.drawSetup(canvas, art);
    if (lobby.team_open and lobby.teams) for (std.enums.values(Team)) |team| {
        const box = teamOption(team);
        outline(canvas, box);
        drawSwatch(canvas, team, box, 2);
    };
}

fn description(mode: scenarios.Scenario) Label {
    return .{ .english = mode.record().description, .installed = mode.descriptionString() };
}

fn teamDescription(mode: scenarios.Scenario) Label {
    return .{ .installed = mode.teamPlayString(), .english = switch (mode.record().teams) {
        .most_frags => "The team with the most frags wins.",
        .controls_tower => "The tower cannot target the team carrying the relay.",
        .none => "No.",
    } };
}

fn descriptionText(mode: scenarios.Scenario, strings: Language, room: []u8) []const u8 {
    const text = description(mode).text(strings);
    return std.fmt.bufPrint(room, "{s}\n\n{s}\n{s}", .{ text, team_play.text(strings), teamDescription(mode).text(strings) }) catch text;
}

fn drawModes(lobby: *const Lobby, canvas: ui.Canvas, art: *hud.Art) !void {
    const top = 107;
    const modal: ui.Rect = .{ .x = 44, .y = top, .width = 552, .height = modal_actions_y + 35 - top };
    widgets.modal(canvas, modal);
    try widgets.title(canvas, .{ 72, 122 }, change_mode);
    try choices.drawList(canvas, modal_rows, &scenario_options, @backingInt(lobby.preview), lobby.option_under);
    const strings = canvas.strings.*;
    const heading = scenario_options[@backingInt(lobby.preview)];
    try canvas.text(canvas.fonts.small, .{ 261, modal_rows.y + 3 }, heading.text(strings), ui.white, .left);
    try canvas.wrapped(canvas.fonts.small, .{ 261, details_y }, description(lobby.preview).text(strings), ui.blue, .left, details_lines);
    try canvas.text(canvas.fonts.small, .{ 261, team_heading_y }, team_play.text(strings), ui.white, .left);
    try canvas.wrapped(canvas.fonts.small, .{ 261, team_heading_y + 15 }, teamDescription(lobby.preview).text(strings), ui.blue, .left, .{ .width = 302, .height = 14, .most = 2 });
    try widgets.button(canvas, art, modal_cancel, cancel, true, false);
    try widgets.button(canvas, art, modal_select, select_mode, true, false);
}

test "the retail lobby gates launch, host options and guest readiness" {
    const guests = [_]?Pilot{ .{ .generation = 1 }, .{ .generation = 2 } };
    var lobby: Lobby = .{ .role = .guest, .roster = &guests, .local_slot = 1 };
    try std.testing.expectEqual(Control.ship, lobby.controlAt(ship_field.box.centre()).?);
    try std.testing.expectEqual(null, lobby.controlAt(mode_list.centre()));
    lobby.role = .{ .host = .{ .port = 27020 } };
    try std.testing.expectEqual(Control.mode, lobby.controlAt(mode_list.centre()).?);
    try std.testing.expectEqual(null, lobby.controlAt(arena_start.box.centre()));
    lobby.role.host.can_launch = true;
    try std.testing.expectEqual(Control.launch, lobby.controlAt(arena_start.box.centre()).?);
    lobby.role = .guest;
    lobby.mission = 1;
    try std.testing.expectEqual(Control.ready, lobby.controlAt(coop_start.box.centre()).?);
    try std.testing.expectEqual(null, lobby.controlAt(ship_field.box.centre()));
}

test "the retail roster fits all stock slots and scrolls within its frame" {
    const names: [10]?Pilot = @splat(.{ .generation = 1 });
    var lobby: Lobby = .{ .role = .guest, .roster = &names, .local_slot = 7 };
    const panel = lobby.rosterPanel();
    try std.testing.expectEqual(8, lobby.playerWindow().shown);
    lobby.scrollPlayers(.{ .at = panel.centre(), .wheel = -8 });
    try std.testing.expectEqual(names.len, lobby.playerWindow().end());
    lobby.roster = names[0..2];
    lobby.scrollPlayers(.{});
    try std.testing.expectEqual(0, lobby.first_pilot);
    lobby.mission = 1;
    try std.testing.expectEqual(4, lobby.playerWindow().shown);
}

test "each click requests readiness once even while the mouse is held" {
    var lobby: Lobby = .{ .role = .guest, .roster = &.{}, .local_slot = 1, .mission = 1 };
    var keys: input.Keyboard = .{};
    var typed: Typed = .{};
    const click: ui.Pointer = .{ .at = coop_start.box.centre(), .down = true };
    const window = ui.size;
    try std.testing.expect(lobby.frame(click, &keys, &typed, window).?.ready);
    lobby.ready.set(1);
    try std.testing.expectEqual(null, lobby.frame(click, &keys, &typed, window));
    try std.testing.expectEqual(null, lobby.frame(.{}, &keys, &typed, window));
    try std.testing.expect(!lobby.frame(click, &keys, &typed, window).?.ready);
}

test "co-op help follows the guest's readiness and clears behind a modal" {
    var lobby: Lobby = .{ .role = .guest, .roster = &.{}, .local_slot = 1, .mission = 1 };
    const start = coop_start.box.centre();
    lobby.updateHelp(start, 1000);
    try std.testing.expectEqual(null, lobby.shown_help);
    lobby.updateHelp(start, 1100);
    try std.testing.expectEqual(0x598, lobby.shown_help.?.string);
    lobby.ready.set(1);
    lobby.updateHelp(start, 1101);
    try std.testing.expectEqual(0x5A7, lobby.shown_help.?.string);
    lobby.updateHelp(null, 1102);
    try std.testing.expectEqual(null, lobby.shown_help);
    lobby.updateHelp(start, 1103);
    try std.testing.expectEqual(null, lobby.shown_help);
}

test {
    std.testing.refAllDecls(@This());
}

test "a host chooses who its game is open to, and copies its invite" {
    var keys: input.Keyboard = .{};
    var typed: Typed = .{};
    var lobby: Lobby = .{ .role = .{ .host = .{ .port = 27020 } }, .roster = &.{}, .local_slot = 0 };
    const click = struct {
        fn at(clicked: *Lobby, held: *input.Keyboard, text: *Typed, point: [2]i32) ?Action {
            _ = clicked.frame(.{ .at = point }, held, text, .{ 640, 480 });
            return clicked.frame(.{ .at = point, .down = true }, held, text, .{ 640, 480 });
        }
    }.at;
    // A game that can only be a LAN game has no setup to open.
    try std.testing.expectEqual(null, click(&lobby, &keys, &typed, setup_button.centre()));
    try std.testing.expect(!lobby.setup_open);
    lobby.role.host.reach = .lan;
    try std.testing.expectEqual(null, click(&lobby, &keys, &typed, setup_button.centre()));
    try std.testing.expect(lobby.setup_open);
    // A LAN game can't be listed. The internet switch opens it to invited players first.
    try std.testing.expectEqual(null, click(&lobby, &keys, &typed, listed_switch.box().centre()));
    try std.testing.expectEqual(Reach.invite, click(&lobby, &keys, &typed, internet_switch.box().centre()).?.open_to);
    lobby.role.host.reach = .invite;
    try std.testing.expectEqual(Reach.public, click(&lobby, &keys, &typed, listed_switch.box().centre()).?.open_to);
    lobby.role.host.reach = .public;
    try std.testing.expectEqual(Reach.invite, click(&lobby, &keys, &typed, listed_switch.box().centre()).?.open_to);
    try std.testing.expectEqual(Reach.lan, click(&lobby, &keys, &typed, internet_switch.box().centre()).?.open_to);
    // An invite is copied only once there is one, from its button or its field.
    lobby.role.host.reach = .invite;
    lobby.role.host.invite = .preparing;
    try std.testing.expectEqual(null, click(&lobby, &keys, &typed, invite_copy.centre()));
    lobby.role.host.invite = .{ .ready = .{ .text = "orl3:directory.example/key/session" } };
    try std.testing.expect(click(&lobby, &keys, &typed, invite_copy.centre()).? == .copy_invite);
    try std.testing.expect(click(&lobby, &keys, &typed, invite_box.centre()).? == .copy_invite);
    // While it is up, the lobby under it takes no clicks, and OK closes it.
    try std.testing.expectEqual(null, click(&lobby, &keys, &typed, coop_back.box.centre()));
    try std.testing.expect(lobby.setup_open);
    try std.testing.expectEqual(null, click(&lobby, &keys, &typed, setup_done.centre()));
    try std.testing.expect(!lobby.setup_open);
    // A guest has none.
    lobby.role = .guest;
    try std.testing.expectEqual(null, click(&lobby, &keys, &typed, setup_button.centre()));
    try std.testing.expect(!lobby.setup_open);
}
