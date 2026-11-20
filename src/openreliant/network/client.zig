//! The direct-IP pilot used by the connection screen and the headless client.
const std = @import("std");
const Io = std.Io;
const flight = @import("openreliant").engine.input.flight;
const game = @import("openreliant").engine.game;
const flight_input = @import("flight_input.zig");
const Presses = flight_input.Presses;
const wire = @import("wire.zig");
const net = @import("transport.zig");
const Client = @This();

pub const Controls = union(enum) { keyboard, fixed: Steering };

/// Repeatable controls for the terminal client and loopback workloads.
pub const Steering = enum(i8) {
    left = -1,
    straight = 0,
    right = 1,

    fn command(steering: Steering) flight.Command {
        const axis = @as(f32, @floatFromInt(@backingInt(steering))) * 0.1;
        return .{ .steering = .{ .axes = .{ axis, 0, 0 } }, .throttle = .{ .axis = 1 } };
    }
};

const timeout = 10 * std.time.us_per_s;
const poll_ms = 4;

expected_host: ?[]const u8,
conn: net.Connection = 0,
state: enum { connecting, connected, unverified, closed, lost, dropped } = .connecting,

deadline: i64 = 0,
sent_join: bool = false,
joined: ?wire.Admission = null,
call_sign: ?wire.CallSign = null,
fighter: wire.Fighter = .predator,
latest: ?wire.Snapshot = null,
debrief: ?wire.Debrief = null,
result_tick: ?u32 = null,
campaign_floor: u32 = 0,
next_mission: ?u16 = null,
pending_view: ?PendingView = null,
pilot_pages: [wire.PilotPage.max_extra]?wire.PilotPage = @splat(null),
scenery: ?wire.Scenery = null,
roster: wire.Roster = .{},
sequence: u32 = 0,
next_input: i64 = 0,
leaving: bool = false,
briefed: bool = false,
flight_command: flight.Command = .{},
fire_primary: bool = false,
weapons: ?wire.ordnance.Order = null,
sent_aim: ?wire.ordnance.Aim = null,
projectiles: [wire.ordnance.Page.pages]?wire.ordnance.Page = @splat(null),
scene: [wire.ScenePage.count]?wire.ScenePage = @splat(null),
presses: Presses = .{},

pub fn status(client: *Client, conn: net.Connection, event: net.Status, name: ?[]const u8) void {
    if (conn != client.conn) {
        net.session_close(conn);
        return;
    }
    const accepted = switch (event) {
        .authenticated => if (client.expected_host) |expected|
            name != null and std.mem.eql(u8, name.?, expected)
        else
            true,
        .unverified => client.expected_host == null,
        .incoming, .closed, .lost, .dropped => false,
    };
    if (accepted) {
        client.state = .connected;
    } else {
        net.session_close(conn);
        client.state = switch (event) {
            .closed => .closed,
            .lost => .lost,
            .dropped => .dropped,
            else => .unverified,
        };
    }
}

pub fn open(client: *Client, io: Io, address: [:0]const u8) !void {
    client.conn = net.session_open(address, false);
    if (client.conn == 0) return error.ConnectFailed;
    client.deadline = Io.Clock.awake.now(io).toMicroseconds() + timeout;
}

pub fn local(client: *Client, io: Io, client_end: net.Connection) void {
    client.* = .{
        .expected_host = null,
        .conn = client_end,
        .state = .connected,
        .deadline = Io.Clock.awake.now(io).toMicroseconds() + timeout,
    };
}

pub fn close(client: *Client) void {
    if (client.conn != 0 and (client.state == .connecting or client.state == .connected)) net.session_close(client.conn);
    client.conn = 0;
}

pub fn leave(client: *Client, io: Io) !void {
    if (client.leaving) return;
    try net.send(client.conn, .leave);
    client.deadline = Io.Clock.awake.now(io).toMicroseconds() + timeout;
    client.leaving = true;
}

pub const Event = union(enum) {
    idle,
    admitted,
    lobby,
    beacon_notice: wire.BeaconNotice,
    tag_bomb_notice: wire.TagBombNotice,
    shadow_notice: wire.ShadowNotice,
    vampires_notice: wire.VampiresNotice,
    uber_kill: wire.UberKillNotice,
    pilot_notice: wire.PilotNotice,
    chat_line: wire.ChatLine,
    wreck: wire.Wreck,
    combat: wire.Combat,
    projectiles,
    scene_page,
    scenery,
    campaign_line: wire.CampaignLine,
    campaign_result,
    debrief,
    campaign_next,
    campaign_end,
    snapshot,
    finished,
    closed,
};

pub fn sendChat(client: *Client, request: wire.ChatRequest) void {
    if (client.joined == null or client.leaving or wire.chat.trim(request.text.slice()).len == 0) return;
    net.send(client.conn, .{ .chat_request = request }) catch return;
}

pub fn requestCrewAction(client: *Client, action: enum { jump, land, eject }) void {
    const admission = client.joined orelse return;
    const view = &(client.latest orelse return);
    const mission = view.mission orelse return;
    const ship = view.ships[admission.slot] orelse return;
    if (client.leaving or client.result_tick != null or client.roster.paused) return;
    if (action != .eject and mission.lead != admission.slot) return;
    const request: wire.CrewRequest = .{ .view_tick = view.tick, .reuse = ship.reuse };
    const message: wire.Message = switch (action) {
        .jump => if (mission.travel.any()) .{ .crew_jump = request } else return,
        .land => .{ .crew_land = request },
        .eject => .{ .crew_eject = request },
    };
    net.send(client.conn, message) catch return;
}

pub fn setFlight(client: *Client, command: flight.Command) void {
    client.flight_command = command;
    client.presses.take(&client.flight_command);
}

pub fn releaseFlight(client: *Client) void {
    client.flight_command = flight_input.release(client.flight_command);
    client.presses = .{};
    client.fire_primary = false;
    if (client.weapons) |*pending| {
        pending.presses = .{};
        pending.cockpit = .{};
    }
}

pub fn setWeapons(client: *Client, order: wire.ordnance.Order) void {
    if (client.weapons) |*pending| pending.merge(order) else client.weapons = order;
}

pub fn selectShip(client: *Client, ship: wire.Fighter) !void {
    if (client.latest != null or client.fighter == ship) return;
    if (client.sent_join) try net.send(client.conn, .{ .pick_ship = ship });
    client.fighter = ship;
}

pub fn chooseDebrief(client: *Client, action: @FieldType(wire.DebriefChoice, "action")) void {
    const state = client.debrief orelse return;
    const slot = (client.joined orelse return).slot;
    if (client.leaving or !state.crew.permits(slot, action)) return;
    net.send(client.conn, .{ .debrief_choice = .{ .tick = state.tick, .action = action } }) catch return;
}

fn startNextMission(client: *Client, next: wire.NextMission) void {
    client.result_tick = null;
    client.debrief = null;
    client.campaign_floor = next.after;
    client.next_mission = next.number;
    client.latest = null;
    client.pending_view = null;
    client.pilot_pages = @splat(null);
    client.projectiles = @splat(null);
    client.scene = @splat(null);
    client.scenery = null;
    client.briefed = false;
    client.roster.briefing = false;
    client.roster.mission = next.number;
    client.releaseFlight();
    client.weapons = null;
    client.sent_aim = null;
}

pub fn finishBriefing(client: *Client, fit: ?wire.CampaignLoadout) !void {
    if (!client.roster.briefing or client.briefed or client.leaving) return;
    try net.send(client.conn, .{ .briefed = fit });
    client.briefed = true;
}

/// Advance the connection without waiting for a packet or a simulation tick.
pub fn poll(client: *Client, io: Io) !Event {
    net.session_poll();
    if (client.state == .unverified) return error.UnverifiedServer;
    if (client.state == .closed) return if (client.leaving) .closed else error.Disconnected;
    if (client.state == .dropped) return error.DroppedForLag;
    if (client.state == .lost) return if (client.leaving) .closed else error.TransportLost;
    const now = Io.Clock.awake.now(io).toMicroseconds();
    if (now >= client.deadline) {
        // A close notice can be lost after the host receives our final receipt or leave.
        if (client.leaving) return .closed;
        // An admitted pilot can wait in the lobby or the debrief.
        if (client.joined == null or (client.latest != null and client.result_tick == null)) return error.SessionTimedOut;
    }
    if (client.state == .connected and !client.sent_join) {
        try net.send(client.conn, .{ .join = .local });
        try net.send(client.conn, .{ .pick_ship = client.fighter });
        client.sent_join = true;
    }
    if (client.joined != null and !client.leaving and now >= client.next_input) {
        try net.send(client.conn, .{ .input = .{
            .sequence = client.sequence,
            .command = client.flight_command,
            .fire_for = if (client.fire_primary and client.latest != null)
                if (client.latest.?.ships[client.joined.?.slot]) |ship| ship.reuse else null
            else
                null,
        } });
        if (client.presses.any()) {
            try net.send(client.conn, .{ .flight_press = client.presses });
            client.presses = .{};
        }
        if (client.weapons) |*pending| {
            if (pending.presses.any() or pending.cockpit.any() or !std.meta.eql(client.sent_aim, @as(?wire.ordnance.Aim, pending.aim))) {
                try net.send(client.conn, .{ .weapon_order = pending.* });
                client.sent_aim = pending.aim;
                pending.presses = .{};
                pending.cockpit = .{};
            }
        }
        client.sequence +%= 1;
        client.next_input = now + wire.step_us;
    }
    var buffer: [wire.capacity]u8 = undefined;
    const message = try net.receive(client.conn, &buffer) orelse return .idle;
    switch (message) {
        .joined => |admission| {
            if (!client.sent_join or client.joined != null) return error.UnexpectedAdmission;
            client.joined = admission;
            try net.send(client.conn, .{ .call_sign = client.call_sign orelse .{} });
            client.deadline = now + timeout;
            return .admitted;
        },
        .campaign_seat => |admission| {
            const previous = client.joined orelse return error.UnexpectedAdmission;
            if (client.latest != null or !client.briefed or !client.roster.briefing or
                admission.slot >= previous.slot or admission.slot >= wire.cooperative_slots or
                admission.generation <= previous.generation) return error.UnexpectedAdmission;
            client.joined = admission;
            return .admitted;
        },
        .wrong_protocol => |required| {
            std.debug.print("server requires multiplayer protocol {d} (OpenReliant {s})\n", .{ required.protocol, required.release });
            return error.IncompatibleProtocol;
        },
        .roster => |roster| {
            const admission = client.joined orelse return error.UnexpectedMessage;
            if (client.leaving) return .idle;
            if (roster.pilots[admission.slot] == null or roster.pilots[admission.slot].?.generation != admission.generation)
                return error.UnexpectedMessage;
            client.roster = roster;
            // A paused session sends roster heartbeats while simulation snapshots are stopped.
            if (roster.paused) client.deadline = now + timeout;
            if (client.latest == null and (roster.lobby != null or roster.mission != null)) return .lobby;
            return .idle;
        },
        .tag_bomb_notice => |notice| return if (client.joined != null and !client.leaving) .{ .tag_bomb_notice = notice } else .idle,
        .shadow_notice => |notice| return if (client.joined != null and !client.leaving) .{ .shadow_notice = notice } else .idle,
        .uber_kill => |notice| return if (client.joined != null and !client.leaving) .{ .uber_kill = notice } else .idle,
        .vampires_notice => |notice| return if (client.joined != null and !client.leaving) .{ .vampires_notice = notice } else .idle,
        .beacon_notice => |notice| return if (client.joined != null and !client.leaving) .{ .beacon_notice = notice } else .idle,
        .pilot_notice => |notice| {
            if (client.joined == null or client.leaving) return .idle;
            const entry = &client.roster.pilots[notice.pilot.slot];
            if (notice.kind != .joined_flight and entry.* != null and entry.*.?.generation == notice.pilot.generation)
                entry.* = null;
            return .{ .pilot_notice = notice };
        },
        .chat_line => |line| return if (client.joined != null and !client.leaving) .{ .chat_line = line } else .idle,
        .wreck => |wreck| return if (client.joined != null and !client.leaving) .{ .wreck = wreck } else .idle,
        .combat => |effects| return if (client.latest != null and !client.leaving) .{ .combat = effects } else .idle,
        .projectiles => |page| {
            const view = client.latest orelse return .idle;
            if (client.leaving or !view.hasOrdnance() or page.tick > view.tick +| wire.ordnance.Page.max_age) return .idle;
            const entry = &client.projectiles[page.index()];
            if (entry.* == null or page.tick > entry.*.?.tick) entry.* = page;
            return .projectiles;
        },
        .scene_page => |page| {
            const view = &(client.latest orelse return .idle);
            // A reliable empty page can arrive before the matching pilot view.
            if (client.leaving or view.mission == null or page.tick <= client.campaign_floor) return .idle;
            const entry = &client.scene[page.number];
            if (entry.* == null or page.tick > entry.*.?.tick) entry.* = page;
            return .scene_page;
        },
        .scenery => |scenery| {
            if (client.joined == null or client.leaving) return .idle;
            if (client.latest) |view| {
                if (view.scenario != scenery.scenario or scenery.tick > view.tick +| wire.ordnance.Page.max_age) return .idle;
            }
            if (client.scenery == null or scenery.tick > client.scenery.?.tick) client.scenery = scenery;
            return .scenery;
        },
        .campaign_line => |line| {
            if (client.leaving or client.joined == null or (client.latest == null and client.roster.mission == null)) return .idle;
            if (client.latest) |view| {
                if (view.mission == null or line.tick > (view.tick -| client.campaign_floor) *| game.gameobj.ticks_per_step +| 100) return .idle;
            }
            return .{ .campaign_line = line };
        },
        .pilot_page => |page| {
            if (client.joined == null or client.leaving or page.number > wire.max_pilot_pages) return .idle;
            if (client.latest) |*latest| if (page.tick <= latest.tick) return .idle;
            const entry = &client.pilot_pages[page.number - 1];
            if (entry.* == null or page.tick > entry.*.?.tick) entry.* = page;
            return client.acceptView(now);
        },
        .debrief => |state| {
            const slot = (client.joined orelse return error.UnexpectedMessage).slot;
            if (state.tick != client.result_tick or slot >= wire.cooperative_slots or !state.crew.present.isSet(slot))
                return error.UnexpectedMessage;
            client.debrief = state;
            return .debrief;
        },
        .campaign_next => |next| {
            if (next.after != client.result_tick) return error.UnexpectedMessage;
            client.startNextMission(next);
            return .campaign_next;
        },
        .campaign_end => |tick| {
            if (tick != client.result_tick) return error.UnexpectedMessage;
            try net.send(client.conn, .{ .received_final = tick });
            client.deadline = now + timeout;
            client.leaving = true;
            return .campaign_end;
        },
        .view, .finished, .campaign_result => |view| {
            if (client.joined == null) {
                // Flight updates can arrive before the reliable admission.
                return if (message == .view) .idle else error.UnexpectedMessage;
            }
            if (client.leaving or client.result_tick != null or view.tick <= client.campaign_floor) return .idle;
            if (client.latest) |latest| if (view.tick <= latest.tick) return .idle;
            if (client.next_mission) |number| {
                if (!client.briefed or view.mission == null or view.mission.?.number != number) return .idle;
            }
            if (client.pending_view) |*pending| if (view.tick < pending.view.tick) return .idle;
            client.pending_view = .{ .view = view, .delivery = switch (message) {
                .view => .flight,
                .finished => .final,
                .campaign_result => .debrief,
                else => unreachable,
            } };
            return client.acceptView(now);
        },
        else => return error.UnexpectedMessage,
    }
}

const PendingView = struct { view: wire.Snapshot, delivery: enum { flight, final, debrief } };

fn acceptView(client: *Client, now: i64) !Event {
    const pending = if (client.pending_view) |*pending| pending else return .idle;
    const view = &pending.view;
    for (client.pilot_pages[0..view.pilot_pages]) |*entry| {
        const page = if (entry.*) |*page| page else return .idle;
        if (page.tick != view.tick or page.scenario != view.scenario) return .idle;
        try page.apply(&view.ships);
    }
    const delivery = pending.delivery;
    defer client.pending_view = null;
    if (view.pilot_pages != 0) try view.checkObjectivePilots(true);
    const admission = client.joined.?;
    // A flight view can overtake the reliable campaign seat update.
    if (delivery == .flight and view.mission != null and client.latest == null and client.roster.briefing) {
        const ship = view.ships[admission.slot] orelse return .idle;
        if (ship.generation != admission.generation) return .idle;
    }
    const ship = view.ships[admission.slot] orelse return error.MissingShip;
    if (ship.generation != admission.generation) return error.WrongShip;
    if (client.latest) |*last| {
        const mission = if (view.mission) |state| state.number else null;
        const previous = if (last.mission) |state| state.number else null;
        if (last.scenario != view.scenario or previous != mission) return error.UnexpectedMessage;
    }
    client.latest = view.*;
    client.next_mission = null;
    client.deadline = now + timeout;
    if (delivery == .debrief) {
        client.result_tick = view.tick;
        client.releaseFlight();
        return .campaign_result;
    }
    if (delivery == .final) {
        try net.send(client.conn, .{ .received_final = view.tick });
        client.leaving = true;
        return .finished;
    }
    return .snapshot;
}

pub fn run(client: *Client, io: Io, address: [:0]const u8, controls: Controls, leave_after: ?u32) !void {
    try client.open(io, address);
    defer client.close();
    try client.drive(io, controls, leave_after);
}

pub fn drive(client: *Client, io: Io, controls: Controls, leave_after: ?u32) !void {
    var steering: Steering = switch (controls) {
        .keyboard => .straight,
        .fixed => |value| value,
    };
    if (controls == .keyboard) std.debug.print("A steers left, S flies straight, D steers right, and Q leaves. Press Enter to send a key.\n", .{});
    var views: u32 = 0;
    var objectives: wire.Objectives = .none;
    var mission_view: ?wire.MissionView = null;
    while (true) {
        if (controls == .keyboard and client.joined != null and !client.leaving) switch (net.session_key()) {
            'a', 'A' => steering = .left,
            's', 'S' => steering = .straight,
            'd', 'D' => steering = .right,
            'j', 'J' => client.requestCrewAction(.jump),
            'l', 'L' => client.requestCrewAction(.land),
            'e', 'E' => client.requestCrewAction(.eject),
            'q', 'Q' => try client.leave(io),
            'y', 'Y' => client.chooseDebrief(.ready),
            'r', 'R' => client.chooseDebrief(.replay),
            'n', 'N' => client.chooseDebrief(.advance),
            'c', 'C' => {
                var line: wire.chat.Line = .{};
                line.set("Check my six");
                const lobby = client.latest == null or client.result_tick != null;
                client.sendChat(.{ .to = if (lobby) .lobby else .flight, .text = line });
            },
            else => {},
        };
        client.setFlight(steering.command());
        const event = try client.poll(io);
        switch (event) {
            .idle, .combat, .projectiles, .scene_page, .scenery, .campaign_line => {},
            .chat_line => |line| std.debug.print("chat {t} {d} {s}\n", .{ line.scope, line.sender, line.text.slice() }),
            .lobby => if (client.roster.briefing) try client.finishBriefing(null),
            .tag_bomb_notice => |notice| std.debug.print("notice {s} {d} {d}\n", .{ @tagName(notice.event.kind), notice.event.pilot.slot, notice.event.other.slot }),
            .shadow_notice => |notice| std.debug.print("shadow-notice {s} {d}\n", .{ @tagName(notice.event.kind), notice.event.pilot.slot }),
            .uber_kill => |notice| std.debug.print("nuclear-strike {d} {d}\n", .{ notice.event.owner.slot, notice.event.victim.slot }),
            .vampires_notice => |notice| std.debug.print("vampires-notice {s}\n", .{@tagName(notice.event.change)}),
            .beacon_notice => |notice| std.debug.print("notice {s} {d}\n", .{ @tagName(notice.event.kind), notice.event.pilot.slot }),
            .pilot_notice => |notice| std.debug.print("pilot-notice {s} {d} {d}\n", .{ @tagName(notice.kind), notice.pilot.slot, notice.pilot.generation }),
            .wreck => |wreck| std.debug.print("wreck {d} {d} {d}\n", .{ wreck.pilot.participant.slot, wreck.pilot.ship.reuse, wreck.tick }),
            .campaign_result => std.debug.print("debrief {d} {d} {t}\n", .{ client.latest.?.tick, client.latest.?.mission.?.number, client.latest.?.mission.?.rating }),
            .debrief => {
                const crew = client.debrief.?.crew;
                std.debug.print("debrief-crew {d} {d} {d} {d}\n", .{ crew.lead, crew.present.mask, crew.eligible.mask, crew.ready.mask });
            },
            .campaign_next => std.debug.print("briefing {d}\n", .{client.next_mission.?}),
            .campaign_end, .closed => return,
            .admitted => {
                const admission = client.joined.?;
                std.debug.print("admitted {d} {d}\n", .{ admission.slot, admission.generation });
            },
            .snapshot, .finished => {
                const view = client.latest.?;
                views += 1;
                std.debug.print("view {d}", .{view.tick});
                for (view.ships) |entry| {
                    if (entry) |seen| {
                        std.debug.print(" {d} {d:.3} {d:.3}", .{ seen.generation, seen.position[0], seen.position[2] });
                    } else std.debug.print(" 0 0 0", .{});
                }
                std.debug.print("\n", .{});
                if (!std.meta.eql(objectives, view.objectives)) {
                    objectives = view.objectives;
                    showObjectives(view);
                }
                if (view.mission) |mission| {
                    if (!std.meta.eql(mission_view, @as(?wire.MissionView, mission))) {
                        std.debug.print("mission {d} lead {d} jump {any} warp {any}\n", .{
                            mission.number, mission.lead orelse wire.slots, mission.travel.jump, mission.travel.warp,
                        });
                        mission_view = mission;
                    }
                }
                if (event == .finished) {
                    std.debug.print("finished {d}\n", .{view.tick});
                } else if (leave_after == views) try client.leave(io);
            },
        }
        try io.sleep(.fromMilliseconds(poll_ms), .awake);
    }
}

fn showObjectives(view: wire.Snapshot) void {
    if (view.objectives != .six_beacons) return;
    for (view.objectives.six_beacons, 0..) |beacon, index| switch (beacon) {
        .carried => |slot| std.debug.print("beacon {d} {d} carried {d} {d}\n", .{ view.tick, index, slot, view.ships[slot].?.generation }),
        .loose => |p| std.debug.print("beacon {d} {d} loose {d:.3} {d:.3} {d:.3}\n", .{ view.tick, index, p[0], p[1], p[2] }),
    };
}
