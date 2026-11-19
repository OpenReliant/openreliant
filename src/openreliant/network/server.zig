//! A direct-IP host. Only the game thread admits pilots and applies their commands.
const std = @import("std");
const Io = std.Io;
const Ip6Address = Io.net.Ip6Address;
const wire = @import("wire.zig");
const flight = @import("openreliant").engine.input.flight;
const flight_input = @import("flight_input.zig");
const net = @import("transport.zig");
const game = @import("openreliant").engine.game;
const Arena = @import("arena.zig");
const ProjectilePage = wire.ordnance.Page;
const identity = @import("identity.zig");
const HandshakeBudget = @import("handshake_budget");
const Host = @This();
const ChatBudget = @import("chat_budget.zig");

const timeout = 5 * std.time.us_per_s;
const held_input_timeout = 250 * std.time.us_per_ms;
const paused_roster_interval = std.time.us_per_s;
// pause_screen_multiplayer (0x0048E62D) shows a drop control past 100 game ticks of round-trip time.
const slow_round_trip = 100 * std.time.ms_per_s / game.main.ticks_per_second;
const packets_per_tick = 4;
const max_identity = 32;
pub const pilots_to_start = 2;

const Peer = struct {
    conn: net.Connection,
    state: enum { connecting, joining, choosing, playing, closing } = .connecting,
    identity: [max_identity]u8 = undefined,
    identity_len: u8 = 0,
    call_sign: ?wire.CallSign = null,
    announce_join: bool = false,
    expires: i64,
    sequence: ?u32 = null,
    flight_command: flight.Command = .{},
    fire_for: ?u32 = null,
    presses: flight_input.Presses = .{},
    weapons: ?wire.ordnance.Order = null,
    ping_ms: ?u16 = null,
    chat_budget: ChatBudget = .{},
};

io: Io,
arena: *Arena,
signer: ?*const identity.Server = null,
player_limit: u8 = wire.slots,
lan_only: bool = false,
start: union(enum) {
    automatic,
    lobby: struct { scenario: wire.Scenario = .nuclear_threat },
    launched,
} = .automatic,
listener: u32 = 0,
peers: [wire.slots]?Peer = @splat(null),
roster_dirty: bool = false,
paused: bool = false,
next_paused_roster: i64 = 0,
projectile_pages: [ProjectilePage.pages]bool = @splat(false),
budget: HandshakeBudget = .{},
chat_budget: ChatBudget = .{},
tick: u32 = 0,
last_tick: u32 = std.math.maxInt(u32),
next_step: i64 = 0,
renew_at: i64 = 0,
final_tick: ?u32 = null,
final_receipts: usize = 0,
drain_until: i64 = 0,

fn now(host: *const Host) i64 {
    return Io.Clock.awake.now(host.io).toMicroseconds();
}

fn release(host: *Host, slot: u8) void {
    host.remove(slot, host.final_tick == null, .normal);
}

const Departure = enum { normal, dropped };

fn remove(host: *Host, slot: u8, announce: bool, departure: Departure) void {
    const peer = host.peers[slot] orelse return;
    if (host.arena.pilots[slot]) |pilot| {
        if (announce and peer.state == .playing) {
            if (host.start == .lobby)
                host.pilotNotice(slot, pilot.participant.generation, peer.call_sign, .left_lobby)
            else if (host.tick != 0)
                host.pilotNotice(slot, pilot.participant.generation, peer.call_sign, .left_flight);
        }
        std.debug.print("left {d} {d}\n", .{ slot, pilot.participant.generation });
        host.arena.leave(slot);
        host.roster_dirty = true;
    }
    host.peers[slot] = null;
    if (slot == 0 and host.paused) host.setPaused(false);
    switch (departure) {
        .normal => net.session_close(peer.conn),
        .dropped => net.session_drop(peer.conn),
    }
}

fn pilotNotice(host: *Host, slot: u8, generation: u64, name: ?wire.CallSign, kind: wire.PilotNotice.Kind) void {
    const message: wire.Message = .{ .pilot_notice = .{
        .pilot = .{ .slot = slot, .generation = generation },
        .name = name orelse .{},
        .tick = host.arena.mission.clock.frame_start,
        .kind = kind,
    } };
    host.sendPlaying(message, slot);
}

fn sendPlaying(host: *const Host, message: wire.Message, except: ?u8) void {
    for (host.peers, 0..) |entry, slot| {
        const peer = entry orelse continue;
        if (peer.state == .playing and except != @as(u8, @intCast(slot))) net.send(peer.conn, message) catch continue;
    }
}

// Requests carry only text and a destination. The connection supplies the sender.
fn relayChat(host: *Host, slot: u8, peer: *Peer, request: wire.ChatRequest, time: i64) void {
    const name = peer.call_sign orelse return;
    const scope = std.meta.activeTag(request.to);
    const in_lobby = host.start == .lobby;
    if ((scope == .lobby) != in_lobby or (!in_lobby and host.tick == 0)) return;
    if (!peer.chat_budget.take(time, ChatBudget.pilot)) return;
    const message: wire.Message = .{ .chat_line = .{ .scope = scope, .sender = slot, .name = name, .text = request.text } };
    switch (request.to) {
        .lobby, .flight => if (host.chat_budget.take(time, ChatBudget.session)) host.sendPlaying(message, null),
        .private => |to| {
            const recipient = host.peers[to.slot] orelse return;
            const pilot = host.arena.pilots[to.slot] orelse return;
            if (to.slot == slot or recipient.state != .playing or pilot.participant.generation != to.generation) return;
            if (!host.chat_budget.take(time, ChatBudget.session)) return;
            net.send(recipient.conn, message) catch return;
            net.send(peer.conn, message) catch return;
        },
    }
}

fn slotFor(host: *const Host, conn: net.Connection) ?u8 {
    for (host.peers, 0..) |entry, slot| {
        if (entry) |peer| if (peer.conn == conn) return @intCast(slot);
    }
    return null;
}

fn isLan(address: [16]u8) bool {
    const ipv6: Ip6Address = .{ .bytes = address, .port = 0 };
    if (Io.net.Ip4Address.fromIp6(ipv6)) |ipv4| {
        const first, const second, _, _ = ipv4.bytes;
        return first == 127 or first == 10 or (first == 172 and second >= 16 and second <= 31) or
            (first == 192 and second == 168) or (first == 169 and second == 254);
    }
    return ipv6.isLoopBack() or ipv6.isLinkLocal() or address[0] & 0xfe == 0xfc;
}

fn acceptsRemote(host: *const Host, conn: net.Connection) bool {
    if (!host.lan_only) return true;
    var address: [16]u8 = undefined;
    return net.session_peer_ip(conn, &address) and isLan(address);
}

pub fn takeLocalPilot(host: *Host, server_end: net.Connection, name: wire.CallSign) void {
    std.debug.assert(host.peers[0] == null);
    host.peers[0] = .{ .conn = server_end, .state = .joining, .call_sign = host.chatCallSign(name), .expires = host.now() + timeout };
}

pub fn localCallSign(host: *const Host) wire.CallSign {
    return host.peers[0].?.call_sign.?;
}

pub fn canLaunch(host: *const Host) bool {
    const local = host.peers[0] orelse return false;
    return host.start == .lobby and local.state == .playing;
}

/// Only the local host's menu calls this. Pilots can join an arena after it starts.
pub fn launch(host: *Host) void {
    if (!host.canLaunch()) return;
    // Loading the stock mission can take longer than the idle timeout on a slow machine.
    const expires = host.now() + timeout;
    for (&host.peers) |*entry| if (entry.*) |*peer| {
        if (peer.state == .playing) peer.expires = expires;
    };
    host.start = .launched;
    host.roster_dirty = true;
}

pub fn selectScenario(host: *Host, scenario: wire.Scenario) void {
    if (host.start != .lobby or host.start.lobby.scenario == scenario) return;
    host.start.lobby.scenario = scenario;
    host.roster_dirty = true;
}

pub fn status(host: *Host, conn: net.Connection, event: net.Status, name: ?[]const u8) void {
    const slot = host.slotFor(conn);
    switch (event) {
        .incoming => {
            if (slot != null) return;
            if (host.final_tick == null and host.acceptsRemote(conn)) {
                // A player-hosted game keeps slot zero for the local connection even if it closes.
                const first_remote: usize = @intFromBool(host.start != .automatic);
                for (host.peers[first_remote..host.player_limit]) |*entry| {
                    if (entry.* != null) continue;
                    const time = host.now();
                    if (host.budget.take(time) and net.session_accept(conn)) {
                        entry.* = .{ .conn = conn, .expires = time + timeout };
                        return;
                    }
                    break;
                }
            }
        },
        .authenticated => if (slot) |index| {
            const peer = &host.peers[index].?;
            if (peer.state != .connecting) return;
            if (name) |pilot_name| {
                if (pilot_name.len > 0 and pilot_name.len <= max_identity and !host.hasName(pilot_name)) {
                    @memcpy(peer.identity[0..pilot_name.len], pilot_name);
                    peer.identity_len = @intCast(pilot_name.len);
                    peer.state = .joining;
                    return;
                }
            }
        },
        .unverified => if (slot) |index| {
            const peer = &host.peers[index].?;
            if (peer.state != .connecting) return;
            // The transport requires encryption. This pilot owns only its new admission.
            peer.state = .joining;
            return;
        },
        .closed, .lost, .dropped => {},
    }
    if (slot) |index| host.release(index) else net.session_close(conn);
}

/// The player's local LAN host alone can stop the simulation. The network keeps running.
pub fn setPaused(host: *Host, paused: bool) void {
    if (!host.lan_only or host.start != .launched or host.tick == 0 or host.final_tick != null or host.paused == paused) return;
    host.paused = paused;
    host.roster_dirty = true;
    for (&host.peers) |*entry| if (entry.*) |*peer| {
        peer.flight_command = flight_input.release(peer.flight_command);
        peer.fire_for = null;
        peer.presses = .{};
        if (peer.weapons) |*weapons| {
            weapons.presses = .{};
            weapons.cockpit = .{};
        }
    };
}

pub fn canDropPausedPilot(host: *const Host, admission: wire.Admission) bool {
    if (!host.paused or admission.slot == 0 or admission.slot >= wire.slots) return false;
    const peer = host.peers[admission.slot] orelse return false;
    const pilot = host.arena.pilots[admission.slot] orelse return false;
    if (peer.state != .playing or pilot.participant.generation != admission.generation) return false;
    const ping = net.session_ping_ms(peer.conn);
    return ping > slow_round_trip or host.now() - (peer.expires - timeout) > slow_round_trip * std.time.us_per_ms;
}

pub fn dropPausedPilot(host: *Host, admission: wire.Admission) void {
    if (host.canDropPausedPilot(admission)) host.remove(admission.slot, true, .dropped);
}

fn hasName(host: *const Host, name: []const u8) bool {
    for (host.peers) |entry| {
        const peer = entry orelse continue;
        if (peer.identity_len != 0 and std.mem.eql(u8, peer.identity[0..peer.identity_len], name)) return true;
    }
    return false;
}

// A peer cannot claim a callsign that is already shown for another admission,
// or use the English system notice name.
fn chatCallSign(host: *const Host, claimed: wire.CallSign) wire.CallSign {
    const name = wire.lobbyName(claimed.slice());
    if (name.len == 0 or std.ascii.eqlIgnoreCase(name.slice(), "SYSTEM")) return .{};
    for (host.peers) |entry| {
        const peer = entry orelse continue;
        const used = peer.call_sign orelse continue;
        if (std.ascii.eqlIgnoreCase(name.slice(), used.slice())) return .{};
    }
    return name;
}

fn receive(host: *Host, slot: u8, peer: *Peer, message: wire.Message, time: i64) !bool {
    if (message == .leave) return false;
    switch (peer.state) {
        .joining => {
            if (host.final_tick != null or message != .join) return false;
            if (!message.join.compatible()) {
                try net.send(peer.conn, .{ .wrong_protocol = .local });
                peer.state = .closing;
                peer.expires = time + timeout;
                return true;
            }
            peer.state = .choosing;
            return true;
        },
        .choosing => {
            if (host.final_tick != null or message != .pick_ship) return false;
            const admitted = host.arena.join(slot, message.pick_ship) catch |err| switch (err) {
                error.NoFreeSpawn, error.JoinFailed, error.BindFailed => return false,
                else => return err,
            };
            peer.state = .playing;
            peer.announce_join = host.tick != 0;
            peer.expires = time + timeout;
            try net.send(peer.conn, .{ .joined = admitted });
            if (host.paused) {
                var view = try host.arena.snapshot(host.tick);
                host.fillPings(&view, false);
                var buffer: [wire.capacity]u8 = undefined;
                try host.sendView(&view, slot, .paused_join, &buffer);
            }
            host.roster_dirty = true;
            std.debug.print("joined {d} {d}\n", .{ slot, admitted.generation });
            return true;
        },
        .playing => {
            if (host.final_tick) |tick| {
                if (message == .received_final and message.received_final == tick) host.final_receipts += 1;
                return message == .input or message == .flight_press or message == .weapon_order or message == .call_sign or message == .chat_request;
            }
            switch (message) {
                .input => |input| {
                    if (!input.follows(peer.sequence)) return true;
                    peer.sequence = input.sequence;
                    peer.expires = time + timeout;
                    if (host.acceptsFlight()) {
                        peer.flight_command = input.command;
                        peer.fire_for = input.fire_for;
                    }
                },
                .flight_press => |presses| if (host.acceptsFlight()) peer.presses.merge(presses),
                .weapon_order => |order| if (host.acceptsFlight()) {
                    if (peer.weapons) |*pending| pending.merge(order) else peer.weapons = order;
                },
                .chat_request => |request| host.relayChat(slot, peer, request, time),
                .call_sign => |name| {
                    // A callsign is a display name. It never identifies or controls a pilot.
                    // Accept it once to keep updates bounded, including during launch.
                    if (peer.call_sign == null) {
                        const accepted = host.chatCallSign(name);
                        peer.call_sign = accepted;
                        host.roster_dirty = true;
                        if (peer.announce_join) {
                            const pilot = host.arena.pilots[slot].?;
                            host.pilotNotice(slot, pilot.participant.generation, accepted, .joined_flight);
                            peer.announce_join = false;
                        }
                    }
                },
                .pick_ship => |fighter| if (host.start == .lobby) {
                    host.arena.pilots[slot].?.fighter = fighter;
                },
                else => return false,
            }
            return true;
        },
        .connecting, .closing => return false,
    }
}

fn service(host: *Host, slot: u8, time: i64) !void {
    const peer = if (host.peers[slot]) |*peer| peer else return;
    if (time >= peer.expires) {
        host.release(slot);
        return;
    }
    if (peer.state == .connecting or peer.state == .closing) return;
    var buf: [wire.capacity]u8 = undefined;
    for (0..packets_per_tick) |_| {
        const message = net.receive(peer.conn, &buf) catch {
            host.release(slot);
            return;
        } orelse return;
        const keep = host.receive(slot, peer, message, time) catch |err| switch (err) {
            error.SendFailed => false,
            else => return err,
        };
        if (!keep) {
            host.release(slot);
            return;
        }
        if (peer.state == .closing) return;
    }
}

fn servicePeers(host: *Host, time: i64) !void {
    for (0..host.peers.len) |slot| try host.service(@intCast(slot), time);
}

fn playingCount(host: *const Host) usize {
    var count: usize = 0;
    for (host.peers) |entry| {
        const peer = entry orelse continue;
        if (peer.state == .playing) count += 1;
    }
    return count;
}

fn publishRoster(host: *Host) !void {
    if (!host.roster_dirty or (host.start == .lobby and !host.canLaunch())) return;
    host.roster_dirty = false;
    var roster: wire.Roster = .{ .lobby = if (host.start == .lobby) host.start.lobby.scenario else null, .paused = host.paused };
    for (host.peers, host.arena.pilots, &roster.pilots) |entry, participant, *listed| {
        const peer = entry orelse continue;
        const pilot = participant orelse continue;
        if (peer.state == .playing) listed.* = .{ .generation = pilot.participant.generation, .name = peer.call_sign orelse .{} };
    }
    var buffer: [wire.capacity]u8 = undefined;
    const bytes = try (wire.Message{ .roster = roster }).encode(&buffer);
    for (host.peers, 0..) |entry, slot| {
        const peer = entry orelse continue;
        if (peer.state != .playing) continue;
        net.sendBytes(peer.conn, bytes, true) catch host.release(@intCast(slot));
    }
}

fn acceptsFlight(host: *const Host) bool {
    return host.start != .lobby and !host.paused;
}

fn applyControls(host: *Host, time: i64) void {
    for (&host.peers, 0..) |*entry, slot| {
        const peer = if (entry.*) |*peer| peer else continue;
        if (peer.state != .playing or peer.sequence == null) continue;
        const expired = time - (peer.expires - timeout) >= held_input_timeout;
        var command = if (expired) flight_input.release(peer.flight_command) else peer.flight_command;
        peer.presses.apply(&command);
        peer.presses = .{};
        const order = peer.weapons;
        if (peer.weapons) |*pending| {
            pending.presses = .{};
            pending.cockpit = .{};
        }
        if (!host.arena.input(@intCast(slot), command, if (expired) null else peer.fire_for, order))
            host.release(@intCast(slot));
    }
}

fn broadcast(host: *Host, view: wire.Snapshot, final: bool) !void {
    var buffer: [wire.capacity]u8 = undefined;
    var outgoing = view;
    host.fillPings(&outgoing, host.tick == 1 or host.tick % (game.main.ticks_per_second / game.gameobj.ticks_per_step) == 0);
    for (&host.peers, 0..) |*entry, slot| {
        const peer = if (entry.*) |*peer| peer else continue;
        if (peer.state != .playing) continue;
        host.sendView(&outgoing, @intCast(slot), if (final) .final else .flight, &buffer) catch |err| switch (err) {
            error.SendFailed => {
                if (final) host.release(@intCast(slot));
                continue;
            },
            else => return err,
        };
        if (final) peer.expires = host.now() + timeout;
    }
}

fn fillPings(host: *Host, view: *wire.Snapshot, refresh: bool) void {
    if (view.scenario == null) return;
    for (&host.peers, &view.ships) |*entry, *ship| {
        const peer = if (entry.*) |*peer| peer else continue;
        if (peer.state != .playing or ship.* == null) continue;
        if (refresh) {
            const ping = net.session_ping_ms(peer.conn);
            peer.ping_ms = if (ping < 0) null else @intCast(@min(ping, wire.Ship.unknown_ping - 1));
        }
        ship.*.?.ping_ms = peer.ping_ms;
    }
}

const Delivery = enum { flight, paused_join, final };

/// A pilot gets the same private cockpit readings on admission during a pause as in flight.
fn sendView(host: *const Host, view: *wire.Snapshot, slot: u8, delivery: Delivery, buffer: []u8) !void {
    const all = host.arena.mission.objects;
    const ship = view.scenario != null and all.playerBinding(slot) != null;
    view.weapons = if (ship) wire.ordnance.Status.capture(all, slot) else null;
    view.power = if (ship and view.scenario.?.hasPowerUps()) wire.Power.capture(&all.slots[slot].object) else null;
    const message: wire.Message = if (delivery == .final) .{ .finished = view.* } else .{ .view = view.* };
    try net.sendBytes(host.peers[slot].?.conn, try message.encode(buffer), delivery != .flight);
}

fn noticeName(host: *const Host, pilot: game.players.ParticipantRef) wire.CallSign {
    if (pilot.slot >= wire.slots) return .{};
    const joined = host.arena.pilots[pilot.slot] orelse return .{};
    if (joined.participant.generation != pilot.generation) return .{};
    const peer = host.peers[pilot.slot] orelse return .{};
    return peer.call_sign orelse .{};
}

fn broadcastNotices(host: *Host) void {
    // A departure can queue a notice before the arena step.
    defer host.arena.notice_count = 0;
    for (host.arena.notices[0..host.arena.notice_count]) |entry| switch (entry) {
        .beacon => |notice| {
            const message: wire.Message = .{ .beacon_notice = .{ .event = notice, .name = host.noticeName(notice.pilot) } };
            for (host.peers, 0..) |maybe, slot| {
                const peer = maybe orelse continue;
                if (peer.state != .playing) continue;
                if (notice.kind == .waiting_for_players and slot != notice.pilot.slot) continue;
                net.send(peer.conn, message) catch host.release(@intCast(slot));
            }
        },
        .uber_kill => |notice| host.sendPlaying(.{ .uber_kill = .{
            .event = notice,
            .owner_name = host.noticeName(notice.owner),
            .victim_name = host.noticeName(notice.victim),
        } }, null),
        .tag_bomb => |notice| host.sendPlaying(.{ .tag_bomb_notice = .{
            .event = notice,
            .name = host.noticeName(notice.pilot),
            .other_name = host.noticeName(notice.other),
        } }, null),
        .shadow => |notice| host.sendPlaying(.{ .shadow_notice = .{
            .event = notice,
            .name = host.noticeName(notice.pilot),
            .other_name = if (notice.other) |other| host.noticeName(other) else .{},
        } }, null),
        .vampires => |notice| host.sendPlaying(.{ .vampires_notice = .{
            .event = notice,
            .name = if (notice.change.pilot()) |pilot| host.noticeName(pilot) else .{},
        } }, null),
    };
}

fn broadcastCombat(host: *Host) !void {
    var remaining = host.arena.combat[0..host.arena.combat_count];
    while (remaining.len > 0) {
        var batch: wire.Combat = .{ .count = @min(remaining.len, wire.Combat.max) };
        @memcpy(batch.entries[0..batch.count], remaining[0..batch.count]);
        remaining = remaining[batch.count..];
        var buffer: [wire.capacity]u8 = undefined;
        const bytes = try (wire.Message{ .combat = batch }).encode(&buffer);
        for (host.peers) |entry| {
            const peer = entry orelse continue;
            if (peer.state == .playing) net.sendBytes(peer.conn, bytes, false) catch continue;
        }
    }
}

fn broadcastProjectiles(host: *Host) !void {
    const all = host.arena.mission.objects;
    for (std.enums.values(ProjectilePage.Family)) |family| {
        for (0..family.pageCount()) |number| {
            var page: ProjectilePage = .{ .tick = host.tick, .family = family, .number = @intCast(number) };
            const active = &host.projectile_pages[page.index()];
            const end = @min(page.first() + ProjectilePage.width, family.records());
            for (page.first()..end, page.entries[0 .. end - page.first()]) |index, *entry| {
                entry.* = switch (family) {
                    .missile => if (all.missiles.records[index]) |*record| .{
                        .kind = record.type.base(),
                        .reuse = all.missiles.reuses[index],
                        .position = record.slot.object.nextPosition(),
                        .angles = wire.packFacing(record.slot.object.root.next_orientation),
                        .flight = .{
                            .burn = @intFromFloat(@round(std.math.clamp(record.slot.object.throttle, 0, 1) * std.math.maxInt(u6))),
                            .jettisoned = record.order == .jettison,
                            .launched = host.arena.mission.clock.frame_start -| record.started < @import("openreliant").engine.game.gameobj.ticks_per_step,
                        },
                    } else null,
                    .decoy => if (host.arena.decoys) |*decoys| if (decoys.records[index]) |*record| .{
                        .reuse = @bitCast(record.until),
                        .position = record.model.position,
                        .angles = wire.packFacing(record.model.orientation),
                    } else null else null,
                };
            }
            const nonempty = page.mask() != 0;
            if (!nonempty and !active.*) continue;
            active.* = nonempty;
            var buffer: [wire.capacity]u8 = undefined;
            const bytes = try (wire.Message{ .projectiles = page }).encode(&buffer);
            for (host.peers) |entry| {
                const peer = entry orelse continue;
                if (peer.state == .playing) net.sendBytes(peer.conn, bytes, false) catch continue;
            }
        }
    }
}

pub fn open(host: *Host, address: [:0]const u8, ticks: ?u32) !void {
    const listener = net.session_open(address, true);
    if (listener == 0) return error.ListenFailed;
    host.listener = listener;
    host.last_tick = ticks orelse std.math.maxInt(u32);
    host.next_step = host.now();
    host.renew_at = host.next_step + identity.renew_after_us;
}

pub fn close(host: *Host) void {
    for (0..host.peers.len) |slot| host.remove(@intCast(slot), false, .normal);
    if (host.listener != 0) {
        net.session_listen_close(host.listener);
        host.listener = 0;
    }
}

/// Services a host without waiting for the next tick. The caller polls transport callbacks.
pub fn pump(host: *Host) !enum { running, finished } {
    const time = host.now();
    if (host.final_tick != null) {
        if (time >= host.drain_until or host.playingCount() == 0) return .finished;
        try host.servicePeers(time);
        return .running;
    }
    if (time < host.next_step) return .running;
    host.next_step = @max(host.next_step + wire.step_us, time);
    if (host.signer) |signer| {
        if (time >= host.renew_at) {
            var certificate = try signer.hostCertificate(host.io);
            defer certificate.wipe();
            if (!net.session_set_certificate(certificate.bytes[0..].ptr, @intCast(certificate.len)))
                return error.IdentityRenewalFailed;
            host.renew_at = time + identity.renew_after_us;
        }
    }
    try host.servicePeers(time);
    if (host.paused and time >= host.next_paused_roster) {
        host.roster_dirty = true;
        host.next_paused_roster = time + paused_roster_interval;
    }
    try host.publishRoster();
    if (host.paused) return .running;
    switch (host.start) {
        .lobby => return .running,
        .automatic => if (host.tick == 0 and host.playingCount() < pilots_to_start) return .running,
        .launched => {},
    }
    host.applyControls(time);
    host.tick += 1;
    const view = try host.arena.step(host.tick);
    host.broadcastNotices();
    for (host.arena.wrecks) |entry| if (entry) |wreck| host.sendPlaying(.{ .wreck = wreck }, null);
    const final = host.tick == host.last_tick;
    if (final) {
        host.final_tick = host.tick;
        host.drain_until = time + timeout;
    }
    try host.broadcast(view, final);
    if (!final) {
        try host.broadcastCombat();
        if (view.scenario != null) try host.broadcastProjectiles();
    }
    return .running;
}

pub fn run(host: *Host, address: [:0]const u8, ticks: ?u32, invite: ?identity.Invite) !void {
    try host.open(address, ticks);
    defer host.close();
    std.debug.print("listening {s}\n", .{address});
    if (invite) |value| {
        std.debug.print("invite {f}\n", .{value});
    } else if (host.signer != null) {
        std.debug.print("Set InviteAddress in server.ini to print an invite for this listener.\n", .{});
    }

    while (true) {
        net.session_poll();
        if (try host.pump() == .finished) break;
        const wait = if (host.final_tick != null)
            std.time.us_per_ms
        else
            @min(wire.step_us, host.next_step - host.now());
        if (wait > 0) try host.io.sleep(.fromMicroseconds(wait), .awake);
    }
    std.debug.print("finished {d} {d}\n", .{ host.tick, host.final_receipts });
}

test "a LAN listener accepts private, link-local and loopback peers" {
    const allowed = [_][]const u8{ "127.0.0.1", "::1", "10.0.1.7", "172.31.0.2", "192.168.1.9", "169.254.1.2", "fe80::1", "fd12::8" };
    for (allowed) |ip| try std.testing.expect(isLan(Ip6Address.fromAny(try Io.net.IpAddress.parse(ip, 0)).bytes));
    const denied = [_][]const u8{ "192.0.2.1", "172.32.1.1", "2001:db8::1", "::", "0.0.0.0" };
    for (denied) |ip| try std.testing.expect(!isLan(Ip6Address.fromAny(try Io.net.IpAddress.parse(ip, 0)).bytes));
}

test "only an admitted local pilot can launch a player-hosted match" {
    var host: Host = .{ .io = std.testing.io, .arena = undefined, .start = .{ .lobby = .{} } };
    host.peers[1] = .{ .conn = 2, .expires = 0, .state = .playing };
    host.launch();
    try std.testing.expect(host.start == .lobby);
    host.peers[0] = .{ .conn = 1, .expires = 0, .state = .joining };
    host.launch();
    try std.testing.expect(host.start == .lobby);
    host.peers[0].?.state = .playing;
    host.launch();
    try std.testing.expect(host.start == .launched);
}

test "chat display names cannot take a name already on the host roster" {
    var host: Host = .{ .io = std.testing.io, .arena = undefined };
    host.peers[0] = .{ .conn = 1, .expires = 0, .call_sign = wire.lobbyName("Rook") };
    try std.testing.expectEqual(0, host.chatCallSign(wire.lobbyName(" rook ")).len);
    try std.testing.expectEqual(0, host.chatCallSign(wire.lobbyName("System")).len);
    try std.testing.expectEqualStrings("Falcon", host.chatCallSign(wire.lobbyName("Falcon")).slice());
}

test "only a launched local LAN host pauses and drops stale flight commands" {
    var host: Host = .{ .io = std.testing.io, .arena = undefined, .start = .launched, .tick = 8 };
    host.peers[0] = .{
        .conn = 1,
        .expires = timeout,
        .state = .playing,
        .fire_for = 4,
        .flight_command = .{ .afterburner = true },
    };
    host.setPaused(true);
    try std.testing.expect(!host.paused);
    try std.testing.expect(host.acceptsFlight());

    host.lan_only = true;
    host.setPaused(true);
    try std.testing.expect(host.paused);
    try std.testing.expect(host.roster_dirty);
    try std.testing.expect(!host.acceptsFlight());
    try std.testing.expectEqual(null, host.peers[0].?.fire_for);
    try std.testing.expect(!host.peers[0].?.flight_command.afterburner);

    host.setPaused(false);
    try std.testing.expect(host.acceptsFlight());
    try std.testing.expectEqual(8, host.tick);
}

test "an undeliverable private message spends only the sender's allowance" {
    var host: Host = .{ .io = std.testing.io, .arena = undefined, .tick = 1 };
    host.peers[0] = .{ .conn = 1, .expires = timeout, .state = .playing, .call_sign = wire.lobbyName("Rook") };
    var request: wire.ChatRequest = .{ .to = .{ .private = .{ .slot = 1, .generation = 2 } }, .text = .{} };
    request.text.set("Hello");
    host.relayChat(0, &host.peers[0].?, request, 0);
    try std.testing.expect(host.peers[0].?.chat_budget.ready_at != null);
    try std.testing.expectEqual(null, host.chat_budget.ready_at);
}
