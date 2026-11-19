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

const timeout = 5 * std.time.us_per_s;
const held_input_timeout = 250 * std.time.us_per_ms;
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
    fighter: wire.Fighter = .predator,
    expires: i64,
    sequence: ?u32 = null,
    flight_command: flight.Command = .{},
    fire_for: ?u32 = null,
    presses: flight_input.Presses = .{},
    weapons: ?wire.ordnance.Order = null,
    ping_ms: ?u16 = null,
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
projectile_pages: [ProjectilePage.pages]bool = @splat(false),
budget: HandshakeBudget = .{},
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
    host.remove(slot, host.final_tick == null);
}

fn remove(host: *Host, slot: u8, announce: bool) void {
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
    net.session_close(peer.conn);
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
    host.peers[0] = .{ .conn = server_end, .state = .joining, .call_sign = name, .expires = host.now() + timeout };
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
    if (host.start != .lobby or host.start.lobby.scenario == scenario or !scenario.available()) return;
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
        .closed, .lost => {},
    }
    if (slot) |index| host.release(index) else net.session_close(conn);
}

fn hasName(host: *const Host, name: []const u8) bool {
    for (host.peers) |entry| {
        const peer = entry orelse continue;
        if (peer.identity_len != 0 and std.mem.eql(u8, peer.identity[0..peer.identity_len], name)) return true;
    }
    return false;
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
            peer.fighter = message.pick_ship;
            const admitted = host.arena.join(slot, peer.fighter) catch |err| switch (err) {
                error.NoFreeSpawn, error.JoinFailed, error.BindFailed => return false,
                else => return err,
            };
            peer.state = .playing;
            peer.announce_join = host.tick != 0;
            peer.expires = time + timeout;
            try net.send(peer.conn, .{ .joined = admitted });
            host.roster_dirty = true;
            std.debug.print("joined {d} {d}\n", .{ slot, admitted.generation });
            return true;
        },
        .playing => {
            if (host.final_tick) |tick| {
                if (message == .received_final and message.received_final == tick) host.final_receipts += 1;
                return message == .input or message == .flight_press or message == .weapon_order or message == .call_sign;
            }
            switch (message) {
                .input => |input| {
                    if (!input.follows(peer.sequence)) return true;
                    peer.sequence = input.sequence;
                    peer.expires = time + timeout;
                    if (host.start != .lobby) {
                        peer.flight_command = input.command;
                        peer.fire_for = input.fire_for;
                    }
                },
                .flight_press => |presses| if (host.start != .lobby) peer.presses.merge(presses),
                .weapon_order => |order| if (host.start != .lobby) {
                    if (peer.weapons) |*pending| pending.merge(order) else peer.weapons = order;
                },
                .call_sign => |name| {
                    // A callsign is a display name. It never identifies or controls a pilot.
                    // Accept it once to keep updates bounded, including during launch.
                    if (peer.call_sign == null) {
                        peer.call_sign = name;
                        host.roster_dirty = true;
                        if (peer.announce_join) {
                            const pilot = host.arena.pilots[slot].?;
                            host.pilotNotice(slot, pilot.participant.generation, name, .joined_flight);
                            peer.announce_join = false;
                        }
                    }
                },
                .pick_ship => |fighter| if (host.tick == 0 and host.start != .automatic) {
                    peer.fighter = fighter;
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
    var roster: wire.Roster = .{ .lobby = if (host.start == .lobby) host.start.lobby.scenario else null };
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

fn applyControls(host: *Host, time: i64) void {
    for (&host.peers, 0..) |*entry, slot| {
        const peer = if (entry.*) |*peer| peer else continue;
        if (peer.state != .playing or peer.sequence == null) continue;
        const expired = time - (peer.expires - timeout) >= held_input_timeout;
        var command = if (expired) flight_input.release(peer.flight_command) else peer.flight_command;
        peer.presses.apply(&command);
        peer.presses = .{};
        const order = peer.weapons;
        if (peer.weapons) |*pending| pending.presses = .{};
        if (!host.arena.input(@intCast(slot), command, if (expired) null else peer.fire_for, order))
            host.release(@intCast(slot));
    }
}

fn broadcast(host: *Host, view: wire.Snapshot, final: bool) !void {
    var buffer: [wire.capacity]u8 = undefined;
    var outgoing = view;
    if (view.scenario != null) {
        const ticks_per_second = game.main.ticks_per_second / game.gameobj.ticks_per_step;
        const sample_ping = host.tick == 1 or host.tick % ticks_per_second == 0;
        for (&host.peers, &outgoing.ships) |*entry, *ship| {
            const peer = if (entry.*) |*peer| peer else continue;
            if (peer.state != .playing or ship.* == null) continue;
            if (sample_ping) {
                const ping = net.session_ping_ms(peer.conn);
                peer.ping_ms = if (ping < 0) null else @intCast(@min(ping, wire.Ship.unknown_ping - 1));
            }
            ship.*.?.ping_ms = peer.ping_ms;
        }
    }
    for (&host.peers, 0..) |*entry, slot| {
        const peer = if (entry.*) |*peer| peer else continue;
        if (peer.state != .playing) continue;
        outgoing.weapons = if (view.scenario != null and view.ships[slot] != null)
            wire.ordnance.Status.capture(host.arena.mission.objects, @intCast(slot))
        else
            null;
        outgoing.power = if (view.scenario == .asteroid_field and view.ships[slot] != null)
            wire.Power.capture(&host.arena.mission.objects.slots[slot].object)
        else
            null;
        const message: wire.Message = if (final) .{ .finished = outgoing } else .{ .view = outgoing };
        const bytes = try message.encode(&buffer);
        net.sendBytes(peer.conn, bytes, final) catch {
            if (final) host.release(@intCast(slot));
            continue;
        };
        if (final) peer.expires = host.now() + timeout;
    }
}

fn broadcastNotices(host: *Host) void {
    for (host.arena.notices[0..host.arena.notice_count]) |notice| {
        const speaker = host.peers[notice.pilot.slot] orelse continue;
        const message: wire.Message = .{ .beacon_notice = .{ .event = notice, .name = speaker.call_sign orelse .{} } };
        for (host.peers, 0..) |entry, slot| {
            const peer = entry orelse continue;
            if (peer.state != .playing) continue;
            if (notice.kind == .waiting_for_players and slot != notice.pilot.slot) continue;
            net.send(peer.conn, message) catch host.release(@intCast(slot));
        }
    }
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
    for (0..host.peers.len) |slot| host.remove(@intCast(slot), false);
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
    try host.publishRoster();
    switch (host.start) {
        .lobby => return .running,
        .automatic => if (host.tick == 0 and host.playingCount() < pilots_to_start) return .running,
        .launched => {},
    }
    if (host.tick == 0 and host.start == .launched) {
        for (host.peers, 0..) |entry, slot| {
            const peer = entry orelse continue;
            if (peer.state == .playing) try host.arena.selectShip(@intCast(slot), peer.fighter);
        }
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
