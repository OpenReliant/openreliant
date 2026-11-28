//! A direct-IP host. Only the game thread admits pilots and applies their commands.
const std = @import("std");
const Io = std.Io;
const wire = @import("wire.zig");
const flight = @import("openreliant").engine.input.flight;
const flight_input = @import("flight_input.zig");
const net = @import("transport.zig");
const game = @import("openreliant").engine.game;
const Arena = @import("arena.zig");
const ProjectilePage = wire.ordnance.Page;
const identity = @import("identity.zig");
const lan = @import("lan.zig");
const session = @import("session.zig");
const HandshakeBudget = @import("handshake_budget").Window(wire.slots);
const Host = @This();
const ChatBudget = @import("chat_budget.zig");
const LaunchWait = @import("launch_wait.zig");
const Metrics = @import("metrics.zig");
const Crew = game.interface.Connection.DebriefCrew;
const log = std.log.scoped(.network_host);
/// Steps the host may fall behind its schedule before it starts the schedule over.
const max_late_steps = 5;
const CoopRescues = game.gameflow.save.CoopRescues;
const Results = struct {
    directory: Io.Dir,
    eligible: Crew.Pilots,
    rescues: [wire.cooperative_slots]u8,
    ready: Crew.Pilots = .empty,
    next: ?Crew.Choice = null,
    dirty: bool = true,
};
const Movie = struct { waiting: Crew.Pilots, until: i64 };
const Retiring = struct { conn: net.Connection, until: i64 };

const timeout = 5 * std.time.us_per_s;
const loading_timeout = 60 * std.time.us_per_s;
const held_input_timeout = 250 * std.time.us_per_ms;
const paused_roster_interval = std.time.us_per_s;
// pause_screen_multiplayer (0x0048E62D) shows a drop control past 100 game ticks of round-trip time.
const slow_round_trip = 100 * std.time.ms_per_s / game.main.ticks_per_second;
const packets_per_tick = 4;
const scene_pages_per_tick = 3;
const max_identity = 32;
/// The most connections that may wait to be admitted at once. They wait apart from the pilots'
/// slots, so a connection that never joins keeps no pilot out.
const max_pending = 2 * wire.slots;
/// The most of them that may come from one origin (`sameOrigin`): enough for friends behind one
/// router who join together, and a quarter of the table.
const max_pending_per_origin = 4;
/// The most connections one origin may start in a second.
const starts_per_origin = 4;
pub const pilots_to_start = LaunchWait.minimum_players;

const Peer = struct {
    conn: net.Connection,
    state: enum { connecting, joining, choosing, playing, closing } = .connecting,
    identity: [max_identity]u8 = undefined,
    identity_len: u8 = 0,
    call_sign: ?wire.CallSign = null,
    announce_join: bool = false,
    expires: i64,
    loading_until: i64 = 0,
    sequence: ?u32 = null,
    flight_command: flight.Command = .{},
    /// The command the last step flew for this pilot, echoed to every client so their
    /// simulations carry every ship by its real command (Rocket League GDC 2018).
    flown_command: flight.Command = .{},
    fire_for: ?u32 = null,
    /// Inputs tagged with the client's tick, waiting for the step that reaches it.
    timed: Timed = .{},
    /// How long before its step was due the pilot's newest input arrived, in ticks of real time.
    margin: i8 = 0,
    presses: flight_input.Presses = .{},
    /// A MATCH SPEED press the next step flies.
    match_speed: bool = false,
    weapons: ?wire.ordnance.Order = null,
    briefed: bool = false,
    lobby_ready: bool = false,
    ping_ms: ?u16 = null,
    chat_budget: ChatBudget = .{},
    rescues: u8 = 0,
    attempt_rescues: u8 = 0,
    /// Where the connection comes from, as an IPv6 address, an IPv4 one mapped into it.
    address: [16]u8 = @splat(0),
    /// The host's own pilot, who takes slot zero.
    local: bool = false,

    fn expired(peer: Peer, time: i64) bool {
        return time >= peer.expires and time >= peer.loading_until;
    }
};

io: Io,
arena: *Arena,
signer: ?*const identity.Server = null,
directory_session: ?[16]u8 = null,
player_limit: u8 = wire.slots,
lan_only: bool = false,
/// Whether the host lists its game in the local network's searches, under `discovery_name`.
discovery: bool = false,
discovery_name: lan.Text = .{},
discovery_this_machine_only: bool = false,
arena_directory: ?Io.Dir = null,
arena_floor: u32 = 0,
arena_teams: bool = false,
arena_options: game.deathmatch.Options = .{},
repeat_rounds: bool = false,
launch_wait: LaunchWait = .{},
metrics: ?*Metrics = null,
start: union(enum) {
    automatic,
    lobby: struct { scenario: wire.Scenario = .asteroid_field, mission: ?u16 = null },
    launched,
} = .automatic,
listener: u32 = 0,
/// The admitted pilots, by slot.
peers: [wire.slots]?Peer = @splat(null),
/// Connections not yet admitted: connecting, joining, choosing a ship, or being told why not.
pending: [max_pending]?Peer = @splat(null),
/// The connections last started, to hold one origin to `starts_per_origin` a second.
starts: [max_pending]?struct { address: [16]u8, time: i64 } = @splat(null),
next_start: usize = 0,
retiring: [wire.cooperative_slots]?Retiring = @splat(null),
roster_dirty: bool = false,
paused: bool = false,
paused_view_pending: bool = false,
next_paused_roster: i64 = 0,
projectile_pages: [ProjectilePage.pages]bool = @splat(false),
scene_pages: [wire.ScenePage.count]bool = @splat(false),
next_scene_page: u8 = 0,
campaign_start: ?struct { number: u16, directory: Io.Dir, second_part: bool = false } = null,
campaign_briefing: bool = false,
campaign_directory: ?Io.Dir = null,
campaign_record: ?game.gameflow.Campaign = null,
campaign_wing: game.pilots.Wingmen = .{},
campaign_rescues: CoopRescues = .{},
/// The difficulty a co-op campaign's missions are flown at: the hosting pilot's, or a dedicated
/// server's `Difficulty`.
///
/// **Improvement:** the original starts every network campaign mission on Easy (WinMain
/// `0x004A99F3`).
campaign_difficulty: game.collision.Difficulty = .easy,
campaign_movie: ?Movie = null,
split_restart: ?struct { variables: @import("openreliant").engine.vm.Variables, wing: game.pilots.Wingmen } = null,
debrief: ?Results = null,
budget: HandshakeBudget = .{},
chat_budget: ChatBudget = .{},
tick: u32 = 0,
last_tick: u32 = std.math.maxInt(u32),
/// The combat effects of the step before, sent once more before the next step's.
combat_again: [2 * game.guns.max_bullets + wire.slots]game.guns.FlightEffect = undefined,
combat_again_count: usize = 0,
next_step: i64 = 0,
renew_at: i64 = 0,
final_tick: ?u32 = null,
final_receipts: usize = 0,
drain_until: i64 = 0,

pub fn now(host: *const Host) i64 {
    return Io.Clock.awake.now(host.io).toMicroseconds();
}

fn release(host: *Host, slot: u8) void {
    host.remove(slot, host.final_tick == null, .normal);
}

const Departure = Metrics.Departure;

fn channel(host: *const Host) net.Channel {
    return .{ .traffic = if (host.metrics) |exporter| &exporter.stats.traffic else null };
}

fn joinOutcome(host: *Host, outcome: Metrics.Join) void {
    if (host.metrics) |exporter| exporter.stats.joins.getPtr(outcome).* += 1;
}

fn roundStats(host: *Host) ?*Metrics.Stats.Rounds {
    const exporter = host.metrics orelse return null;
    return if (host.arena.campaign != null) &exporter.stats.cooperative else exporter.stats.rounds.getPtr(host.arena.mode);
}

fn remove(host: *Host, slot: u8, announce: bool, departure: Departure) void {
    const peer = host.peers[slot] orelse return;
    if (host.metrics) |exporter| exporter.stats.departures.getPtr(departure).* += 1;
    if (host.arena.pilots[slot]) |pilot| {
        if (announce and peer.state == .playing) {
            if (host.start == .lobby or host.debrief != null)
                host.pilotNotice(slot, pilot.participant.generation, peer.call_sign, .left_lobby)
            else if (host.tick != 0)
                host.pilotNotice(slot, pilot.participant.generation, peer.call_sign, .left_flight);
        }
        log.info("left {d} {d}", .{ slot, pilot.participant.generation });
        host.arena.leave(slot);
        host.roster_dirty = true;
    }
    host.peers[slot] = null;
    if (host.campaign_movie) |*movie| if (slot < wire.cooperative_slots) {
        movie.waiting.unset(slot);
    };
    if (host.debrief) |*result| {
        result.dirty = true;
        if (slot < wire.cooperative_slots) result.ready.unset(slot);
    }
    if (slot == 0 and host.paused) host.setPaused(false);
    switch (departure) {
        .normal, .timed_out, .rejected => net.session_close(peer.conn),
        .dropped => net.session_drop(peer.conn),
        .retired => {},
    }
}

/// Closes a connection that was never admitted.
fn dropPending(host: *Host, index: usize, departure: Departure) void {
    const peer = host.pending[index] orelse return;
    host.joinOutcome(if (peer.state == .closing) .rejected else switch (departure) {
        .rejected => .rejected,
        .timed_out => .timed_out,
        else => .abandoned,
    });
    host.pending[index] = null;
    net.session_close(peer.conn);
}

fn pendingFor(host: *const Host, conn: net.Connection) ?usize {
    for (host.pending, 0..) |entry, index| {
        if (entry) |peer| if (peer.conn == conn) return index;
    }
    return null;
}

/// Whether two addresses count as one origin: the same IPv4 address, or the same IPv6 /64, which
/// is what one subscriber gets.
fn sameOrigin(a: [16]u8, b: [16]u8) bool {
    const mapped: [12]u8 = @as([10]u8, @splat(0)) ++ [2]u8{ 0xff, 0xff };
    if (std.mem.eql(u8, a[0..12], &mapped) or std.mem.eql(u8, b[0..12], &mapped)) return std.mem.eql(u8, &a, &b);
    return std.mem.eql(u8, a[0..8], b[0..8]);
}

/// Whether a connection from `address` may start now: its origin has room among the pending
/// connections and has not started too many this second. A start that may is counted. This
/// machine's own connections are not held to it.
fn takeStart(host: *Host, address: [16]u8, time: i64) bool {
    if (lan.isLoopback(.{ .ip6 = .{ .bytes = address, .port = 0 } })) return true;
    var waiting: usize = 0;
    for (host.pending) |entry| {
        if (entry) |peer| if (!peer.local and sameOrigin(peer.address, address)) {
            waiting += 1;
        };
    }
    if (waiting >= max_pending_per_origin) return false;
    var recent: usize = 0;
    for (host.starts) |entry| {
        if (entry) |start| if (time -| start.time < std.time.us_per_s and sameOrigin(start.address, address)) {
            recent += 1;
        };
    }
    if (recent >= starts_per_origin) return false;
    host.starts[host.next_start] = .{ .address = address, .time = time };
    host.next_start = (host.next_start + 1) % host.starts.len;
    return true;
}

/// The slot a new pilot would take: slot zero for the host's own pilot, which a player-hosted
/// game keeps for them even while they are away.
fn freeSlot(host: *const Host, local: bool) ?u8 {
    if (local) return if (host.peers[0] == null) 0 else null;
    const first_remote: usize = @intFromBool(host.lan_only);
    for (host.peers[first_remote..host.player_limit], first_remote..) |entry, slot| {
        if (entry == null) return @intCast(slot);
    }
    return null;
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
        if (peer.state == .playing and except != @as(u8, @intCast(slot))) host.channel().send(peer.conn, message) catch continue;
    }
}

const ChatRoute = union(enum) { broadcast, private: net.Connection };

fn chatRoute(host: *Host, slot: u8, peer: *Peer, to: @FieldType(wire.ChatRequest, "to"), time: i64) ?ChatRoute {
    const in_lobby = host.start == .lobby or host.debrief != null;
    if ((to == .lobby) != in_lobby or (!in_lobby and host.tick == 0)) return null;
    if (!peer.chat_budget.take(time, ChatBudget.pilot)) return null;
    const route: ChatRoute = switch (to) {
        .lobby, .flight => .broadcast,
        .private => |target| route: {
            const recipient = host.peers[target.slot] orelse return null;
            const pilot = host.arena.pilots[target.slot] orelse return null;
            if (target.slot == slot or recipient.state != .playing or pilot.participant.generation != target.generation) return null;
            break :route .{ .private = recipient.conn };
        },
    };
    return if (host.chat_budget.take(time, ChatBudget.session)) route else null;
}

// Requests carry only text and a destination. The connection supplies the sender.
fn relayChat(host: *Host, slot: u8, peer: *Peer, request: wire.ChatRequest, time: i64) void {
    const name = peer.call_sign orelse return;
    const route = host.chatRoute(slot, peer, request.to, time) orelse return;
    const message: wire.Message = .{ .chat_line = .{ .scope = std.meta.activeTag(request.to), .sender = slot, .name = name, .text = request.text } };
    switch (route) {
        .broadcast => host.sendPlaying(message, null),
        .private => |recipient| {
            host.channel().send(recipient, message) catch return;
            host.channel().send(peer.conn, message) catch return;
        },
    }
}

fn slotFor(host: *const Host, conn: net.Connection) ?u8 {
    for (host.peers, 0..) |entry, slot| {
        if (entry) |peer| if (peer.conn == conn) return @intCast(slot);
    }
    return null;
}

/// Whether the host takes new pilots: not once the session is ending, nor in a co-op campaign
/// after its lobby.
fn acceptsJoins(host: *const Host) bool {
    return host.final_tick == null and host.arena.campaign == null and !host.campaign_briefing;
}

/// Lists the game in the local network's searches, under `name`, for the game listening on
/// `address`. The host answers the searches on its game port (`lan.answerQuery`). A game bound to
/// loopback is listed on this machine only. Without a key of its own (`signer`), such as with a
/// managed identity, the host can't be joined from a list.
pub fn openDiscovery(host: *Host, address: Io.net.IpAddress, name: []const u8) void {
    if (host.signer == null) {
        log.info("LAN lists show only hosts with a key of their own; join this one by its address", .{});
        return;
    }
    if (!lan.searched(address.getPort())) {
        log.info("LAN lists show games on ports {d} to {d}; join this one by its address", .{ session.default_port, lan.last_searched_port });
        return;
    }
    host.discovery_name = .of(name);
    host.discovery_this_machine_only = lan.isLoopback(address);
    host.discovery = true;
    host.answerDiscovery();
    net.session_datagram_handler(lan.answerQuery);
}

/// Keeps what the host answers the local network's searches with up to date (`lan.publish`).
fn answerDiscovery(host: *Host) void {
    if (host.discovery) lan.publish(host.discoveryGame());
}

/// What the host tells a search about its game, while it has a place for a new pilot.
fn discoveryGame(host: *const Host) ?lan.Game {
    const signer = host.signer orelse return null;
    const players = host.playingCount();
    if (!host.acceptsJoins() or players >= host.player_limit) return null;
    const cooperative = host.campaign_start != null or (host.start == .lobby and host.start.lobby.mission != null);
    const scenario = if (host.start == .lobby) host.start.lobby.scenario else host.arena.mode.scenario();
    const mode = if (cooperative)
        "Co-op"
    else if (scenario) |chosen|
        chosen.record().name
    else switch (host.arena.mode) {
        .@"six-beacons" => "Six Beacons",
        .training => "Training",
        else => "",
    };
    return .{
        .protocol = wire.revision,
        .players = @intCast(players),
        .capacity = host.player_limit,
        .key = signer.issuer.public_key,
        .name = host.discovery_name.slice(),
        .mode = mode,
        .this_machine_only = host.discovery_this_machine_only,
    };
}

fn acceptsRemote(host: *const Host, conn: net.Connection) bool {
    if (!host.lan_only) return true;
    var address: [16]u8 = undefined;
    return net.session_peer_ip(conn, &address) and lan.isLan(address);
}

pub fn takeLocalPilot(host: *Host, server_end: net.Connection, name: wire.CallSign) void {
    std.debug.assert(host.peers[0] == null);
    for (&host.pending) |*entry| {
        if (entry.* != null) continue;
        entry.* = .{ .conn = server_end, .state = .joining, .call_sign = host.chatCallSign(name), .expires = host.now() + timeout, .local = true };
        return;
    }
    unreachable; // The host's own pilot joins before the listener takes anyone.
}

pub fn localCallSign(host: *const Host) wire.CallSign {
    if (host.peers[0]) |peer| return peer.call_sign.?;
    for (host.pending) |entry| {
        if (entry) |peer| if (peer.local) return peer.call_sign.?;
    }
    unreachable;
}

fn localInLobby(host: *const Host) bool {
    const local = host.peers[0] orelse return false;
    return host.start == .lobby and local.state == .playing;
}

pub fn canLaunch(host: *const Host) bool {
    if (host.campaign_briefing or !host.localInLobby()) return false;
    if (host.start.lobby.mission == null) return true;
    if (host.playingCount() < pilots_to_start) return false;
    for (host.peers[1..]) |entry| {
        const peer = entry orelse continue;
        if (peer.state == .playing and !peer.lobby_ready) return false;
    }
    return true;
}

fn markLobbyReady(host: *Host, slot: u8, peer: *Peer, ready: bool) void {
    if (host.start != .lobby or host.start.lobby.mission == null or host.campaign_briefing or slot == 0) return;
    if (peer.lobby_ready == ready) return;
    peer.lobby_ready = ready;
    host.roster_dirty = true;
}

/// The co-op host can remove the selected guest from the waiting lobby. Check the admission
/// again so a click from an old screen cannot remove a newcomer in the same slot.
pub fn removeLobbyPilot(host: *Host, admission: game.players.ParticipantRef) void {
    if (!host.localInLobby() or host.start.lobby.mission == null or host.campaign_briefing or admission.slot == 0 or admission.slot >= host.player_limit) return;
    const pilot = host.arena.pilots[admission.slot] orelse return;
    if (pilot.participant.generation == admission.generation) host.remove(@intCast(admission.slot), true, .dropped);
}

pub fn beginBriefing(host: *Host, number: u16, directory: Io.Dir) void {
    host.campaign_start = .{ .number = number, .directory = directory };
    host.campaign_directory = directory;
    if (host.campaign_record == null) host.campaign_record = game.gameflow.Campaign.begin();
    host.campaign_briefing = true;
    host.roster_dirty = true;
}

/// The co-op lobby's New and Load actions (0x0043D555 and 0x0043D586).
/// Only the host selects the campaign. The roster sends the selected mission to the crew.
pub fn selectCampaign(host: *Host, checkpoint: *const game.gameflow.Campaign, wingmen: *const game.pilots.Wingmen, rescues: CoopRescues) bool {
    if (!host.localInLobby() or host.start.lobby.mission == null or host.campaign_briefing) return false;
    if (!game.gameflow.campaignOrder().has(checkpoint.mission)) return false;
    host.campaign_record = checkpoint.*;
    host.campaign_wing = wingmen.*;
    host.campaign_rescues = rescues;
    host.start.lobby.mission = checkpoint.mission;
    host.roster_dirty = true;
    return true;
}

fn crewBriefed(host: *const Host) bool {
    var count: usize = 0;
    for (host.peers) |maybe| {
        const peer = maybe orelse continue;
        if (peer.state != .playing) continue;
        if (!peer.briefed) return false;
        count += 1;
    }
    return count > 0;
}

/// The mission uses consecutive player slots. Give the remaining crew their flight seats after
/// the briefing so departures do not leave a gap in the authored formation.
fn seatCampaignCrew(host: *Host) !void {
    var seat: u8 = 0;
    for (host.peers, 0..) |maybe, index| {
        const peer = maybe orelse continue;
        if (peer.state != .playing) {
            host.release(@intCast(index));
            continue;
        }
        if (seat != index) {
            const pilot = host.arena.pilots[index].?;
            const admission = try host.arena.join(seat, pilot.fighter);
            host.arena.pilots[seat].?.loadout = pilot.loadout;
            host.arena.leave(@intCast(index));
            host.peers[seat] = peer;
            host.peers[index] = null;
            host.channel().send(peer.conn, .{ .campaign_seat = admission }) catch {
                host.release(seat);
                continue;
            };
        }
        seat += 1;
    }
}

/// Only the local host's menu calls this. Pilots can join an arena after it starts.
pub fn launch(host: *Host) void {
    if (!host.canLaunch()) return;
    host.enterFlight();
}

fn enterFlight(host: *Host) void {
    // Loading the stock mission can take longer than the idle timeout on a slow machine.
    const expires = host.now() + timeout;
    for (&host.peers) |*entry| if (entry.*) |*peer| {
        if (peer.state == .playing) {
            peer.expires = expires;
            peer.loading_until = host.now() + loading_timeout;
        }
    };
    host.start = .launched;
    host.launch_wait.reset();
    host.roster_dirty = true;
}

pub fn selectScenario(host: *Host, scenario: wire.Scenario) void {
    if (host.start != .lobby or host.start.lobby.scenario == scenario) return;
    host.start.lobby.scenario = scenario;
    if (scenario.record().teams == .none) host.arena_teams = false;
    host.roster_dirty = true;
}

pub fn toggleArenaOption(host: *Host, setting: game.deathmatch.Options.Setting) void {
    if (!host.localInLobby() or host.start.lobby.mission != null) return;
    host.arena_options.toggle(setting);
    host.roster_dirty = true;
}

pub fn setArenaTeams(host: *Host, enabled: bool) void {
    if (!host.localInLobby() or host.start.lobby.mission != null) return;
    if (enabled and host.start.lobby.scenario.record().teams == .none) return;
    host.arena_teams = enabled;
    host.roster_dirty = true;
}

pub fn startArena(host: *Host) !void {
    if (host.start != .lobby or host.start.lobby.mission != null or (host.lan_only and !host.canLaunch())) return;
    const directory = host.arena_directory orelse return;
    const staging = host.arena;
    host.arena = try staging.prepareStock(host.start.lobby.scenario, host.arena_teams, host.arena_options, host.io, directory);
    staging.destroy();
    host.enterFlight();
}

/// Retail unloads the arena at 0x004A99A8. Keep the OpenReliant room available for a rematch.
pub fn returnToArenaLobby(host: *Host) !void {
    const directory = host.arena_directory orelse return;
    const scenario = host.arena.mode.scenario() orelse return;
    const flown = host.arena;
    host.arena = try flown.betweenMissions(host.io, directory);
    flown.destroy();
    host.start = .{ .lobby = .{ .scenario = scenario } };
    host.arena_floor = host.tick;
    host.launch_wait.reset();
    host.paused = false;
    host.paused_view_pending = false;
    host.projectile_pages = @splat(false);
    host.clearFlightControls();
    for (&host.peers) |*entry| if (entry.*) |*peer| {
        peer.flight_command = .{};
        peer.weapons = null;
        peer.announce_join = false;
    };
    host.roster_dirty = true;
}

pub fn status(host: *Host, conn: net.Connection, event: net.Status, name: ?[]const u8) void {
    const slot = host.slotFor(conn);
    const waiting = host.pendingFor(conn);
    switch (event) {
        .incoming => {
            if (slot != null or waiting != null) return;
            if (host.acceptsJoins() and host.acceptsRemote(conn) and host.freeSlot(false) != null) accept: {
                var address: [16]u8 = undefined;
                if (!net.session_peer_ip(conn, &address)) break :accept;
                const entry = for (&host.pending) |*entry| {
                    if (entry.* == null) break entry;
                } else break :accept;
                const time = host.now();
                // The origin's own limits come first, so one origin cannot use up the host's.
                if (host.takeStart(address, time) and host.budget.take(time) and net.session_accept(conn)) {
                    entry.* = .{ .conn = conn, .expires = time + timeout, .address = address };
                    return;
                }
            }
            host.joinOutcome(.rejected);
        },
        .authenticated => if (waiting) |index| {
            const peer = &host.pending[index].?;
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
        .unverified => if (waiting) |index| {
            const peer = &host.pending[index].?;
            if (peer.state != .connecting) return;
            // The transport requires encryption. This pilot owns only its new admission.
            peer.state = .joining;
            return;
        },
        .closed, .lost, .dropped => {},
    }
    if (slot) |index| {
        // An admitted pilot is past these.
        if (event == .authenticated or event == .unverified) return;
        host.remove(index, host.final_tick == null, .normal);
    } else if (waiting) |index| {
        host.dropPending(index, if (event == .authenticated) .rejected else .normal);
    } else {
        for (&host.retiring) |*entry| if (entry.* != null and entry.*.?.conn == conn) {
            entry.* = null;
            break;
        };
        net.session_close(conn);
    }
}

/// The player's local LAN host alone can stop the simulation. The network keeps running.
pub fn setPaused(host: *Host, paused: bool) void {
    if (!host.lan_only or host.start != .launched or host.tick == host.arena_floor or host.final_tick != null or host.paused == paused) return;
    host.paused = paused;
    host.paused_view_pending = paused;
    host.roster_dirty = true;
    host.clearFlightControls();
}

fn clearFlightControls(host: *Host) void {
    for (&host.peers) |*entry| if (entry.*) |*peer| {
        peer.flight_command = flight_input.release(peer.flight_command);
        peer.fire_for = null;
        peer.timed = .{};
        peer.presses = .{};
        peer.match_speed = false;
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
    for (host.peers ++ host.pending) |entry| {
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
    for (host.peers ++ host.pending) |entry| {
        const peer = entry orelse continue;
        const used = peer.call_sign orelse continue;
        if (std.ascii.eqlIgnoreCase(name.slice(), used.slice())) return .{};
    }
    return name;
}

/// A message from a connection not yet admitted: the connection keeps waiting, is closed, or
/// has become a pilot.
fn admit(host: *Host, index: usize, message: wire.Message, time: i64) !enum { waiting, refused, admitted } {
    const peer = &host.pending[index].?;
    if (message == .leave or host.final_tick != null) return .refused;
    switch (peer.state) {
        .joining => {
            if (message != .join) return .refused;
            if (!message.join.compatible()) {
                try host.channel().send(peer.conn, .{ .wrong_protocol = .local });
                peer.state = .closing;
                peer.expires = time + timeout;
                return .waiting;
            }
            if (!host.acceptsSession(message.join.session)) return .refused;
            peer.state = .choosing;
            return .waiting;
        },
        .choosing => {
            if (host.arena.campaign != null or host.campaign_briefing or message != .pick_ship) return .refused;
            const slot = host.freeSlot(peer.local) orelse return .refused;
            // Whatever keeps this pilot's ship from being made, it is this pilot who is refused.
            const admitted = host.arena.join(slot, message.pick_ship) catch |err| {
                switch (err) {
                    error.NoFreeSpawn, error.JoinFailed, error.BindFailed => {},
                    else => log.warn("could not make a ship for a joining pilot: {t}", .{err}),
                }
                return .refused;
            };
            host.peers[slot] = peer.*;
            host.pending[index] = null;
            host.welcome(slot, admitted, time) catch |err| {
                log.warn("could not welcome the pilot in slot {d}: {t}", .{ slot, err });
                host.remove(slot, false, .rejected);
            };
            return .admitted;
        },
        .connecting, .closing, .playing => return .refused,
    }
}

/// Tells a pilot just admitted to `slot` what they need to start.
fn welcome(host: *Host, slot: u8, admitted: wire.Admission, time: i64) !void {
    const peer = &host.peers[slot].?;
    peer.state = .playing;
    if (host.start != .lobby) peer.loading_until = time + loading_timeout;
    host.joinOutcome(.admitted);
    peer.announce_join = host.start != .lobby and host.tick != host.arena_floor;
    peer.expires = time + timeout;
    try host.channel().send(peer.conn, .{ .joined = .{ .admission = admitted, .arena_floor = host.arena_floor } });
    host.launch_wait.reset();
    if (host.arena_teams and host.start != .lobby) host.arena.pickTeam(slot, host.arena.leastPopulatedTeam(slot));
    if (host.tick != 0) if (host.arena.last_music) |last| {
        var cue = last;
        cue.now = true;
        try host.channel().send(peer.conn, .{ .mission_music = cue });
    };
    if (host.paused) {
        var view = try host.arena.snapshot(host.tick);
        host.fillPings(&view, false);
        view.countPilotPages();
        var pilots: PilotPackets = undefined;
        try pilots.encode(&view);
        try pilots.send(host.channel(), peer.conn, true);
        var buffer: [wire.capacity]u8 = undefined;
        try host.sendView(&view, slot, .paused, &buffer);
        if (host.arena.scenery(host.tick)) |scenery| try host.channel().send(peer.conn, .{ .scenery = scenery });
    }
    host.roster_dirty = true;
    log.info("joined {d} {d}", .{ slot, admitted.generation });
}

fn receive(host: *Host, slot: u8, peer: *Peer, message: wire.Message, time: i64) !bool {
    if (message == .leave) return false;
    switch (peer.state) {
        // Only an admitted pilot holds a slot (`admit`).
        .connecting, .joining, .choosing, .closing => return false,
        .playing => {
            if (host.final_tick) |tick| {
                if (message == .received_final and message.received_final == tick) host.final_receipts += 1;
                return switch (message) {
                    .input, .flight_press, .weapon_order, .call_sign, .chat_request, .crew_jump, .crew_land, .crew_eject, .debrief_choice, .lobby_ready, .flight_ready => true,
                    else => false,
                };
            }
            switch (message) {
                .input => |input| host.acceptInput(peer, input, time),
                .flight_press => |presses| if (host.acceptsFlight()) peer.presses.merge(presses),
                .weapon_order => |order| if (host.acceptsFlight()) {
                    if (peer.weapons) |*pending| pending.merge(order) else peer.weapons = order;
                },
                .chat_request => |request| host.relayChat(slot, peer, request, time),
                .debrief_choice => |choice| host.takeDebriefChoice(slot, choice),
                .campaign_movie_done => |tick| host.acknowledgeMovie(slot, tick),
                .flight_ready => |floor| if (host.start == .launched and floor == host.arena_floor) {
                    peer.loading_until = 0;
                    peer.expires = time + timeout;
                },
                .lobby_ready => |ready| host.markLobbyReady(slot, peer, ready),
                .crew_jump => |request| if (host.acceptsFlight()) host.arena.crewJump(slot, host.tick, request),
                .crew_land => |request| if (host.acceptsFlight()) host.arena.crewLand(slot, host.tick, request),
                .crew_eject => |request| if (host.acceptsFlight()) host.arena.crewEject(slot, host.tick, request),
                .briefed => |loadout| if (host.campaign_briefing and !peer.briefed) {
                    host.arena.pilots[slot].?.loadout = loadout;
                    peer.briefed = true;
                },
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
                .pick_team => |team| if (host.start == .lobby and host.arena_teams) {
                    host.arena.pickTeam(slot, team);
                    host.roster_dirty = true;
                },
                else => return false,
            }
            return true;
        },
    }
}

fn acceptsSession(host: *const Host, expected: ?[16]u8) bool {
    const requested = expected orelse return true;
    const actual = host.directory_session orelse return false;
    return std.mem.eql(u8, &requested, &actual);
}

test "a pilot can finish a slow arena load without keeping a stale session alive" {
    var host: Host = .{ .io = std.testing.io, .arena = undefined, .start = .launched, .arena_floor = 42 };
    var peer: Peer = .{ .conn = 1, .state = .playing, .expires = timeout, .loading_until = loading_timeout };
    try std.testing.expect(!peer.expired(timeout + 1));
    try std.testing.expect(peer.expired(loading_timeout));
    try std.testing.expect(try host.receive(0, &peer, .{ .flight_ready = 41 }, timeout + 1));
    try std.testing.expectEqual(loading_timeout, peer.loading_until);
    try std.testing.expect(try host.receive(0, &peer, .{ .flight_ready = 42 }, timeout + 1));
    try std.testing.expectEqual(0, peer.loading_until);
    try std.testing.expect(!peer.expired(timeout * 2));
    try std.testing.expect(peer.expired(timeout * 2 + 1));
}

test "directory joins are bound to the current advertised session" {
    var host: Host = .{ .io = std.testing.io, .arena = undefined };
    try std.testing.expect(host.acceptsSession(null));
    try std.testing.expect(!host.acceptsSession(@splat(1)));
    host.directory_session = @splat(1);
    try std.testing.expect(host.acceptsSession(@splat(1)));
    try std.testing.expect(!host.acceptsSession(@splat(2)));
}

/// Measures how long before its step an input with a tick arrived. The host reads its
/// connections once a step, so it goes by when the transport received the message (`arrived`),
/// and by when the step reaching the input's tick is due: the step about to run is due a step
/// before `next_step`, and reaches `mission_ticks` plus a step. The newest input's margin is
/// what the pilot's clock keeps to its target (`FlightFrame.reconcile`). Overwatch (GDC 2017)
/// keeps about a frame of inputs waiting and Rocket League (GDC 2018) asks for a buffer neither
/// empty nor large; counted in whole steps, this one could not go below a step.
fn noteArrival(host: *const Host, peer: *Peer, input: wire.Input, arrived: i64) void {
    const tick = input.tick orelse return;
    if (!host.acceptsFlight() or input.arena_floor != host.arena_floor or !input.follows(peer.sequence)) return;
    if (peer.timed.newest) |newest| if (tick -% newest <= 0) return;
    const reach = host.arena.mission.clock.mission_ticks + game.gameobj.ticks_per_step;
    peer.margin = arrivalMargin(host.next_step - wire.step_us, reach, tick, arrived);
}

/// How long before its step an input reaching `tick` arrived, in ticks of real time, where the
/// step reaching `reach` is due at `due`.
fn arrivalMargin(due: i64, reach: i32, tick: i32, arrived: i64) i8 {
    const step_due = due + @divTrunc(@as(i64, tick -% reach) * wire.step_us, game.gameobj.ticks_per_step);
    const tick_us = std.time.us_per_s / game.main.ticks_per_second;
    return @intCast(std.math.clamp(@divFloor(step_due - arrived, tick_us), std.math.minInt(i8), std.math.maxInt(i8)));
}

test "an input's margin is how long before its step it arrived" {
    const due = 1_000_000;
    // For the step about to run, 25 ms early and 15 ms late.
    try std.testing.expectEqual(2, arrivalMargin(due, 400, 400, due - 25_000));
    try std.testing.expectEqual(-2, arrivalMargin(due, 400, 400, due + 15_000));
    // An input for the step after has that step's 40 ms more, and one for the step before less.
    try std.testing.expectEqual(6, arrivalMargin(due, 400, 404, due - 25_000));
    try std.testing.expectEqual(-2, arrivalMargin(due, 400, 396, due - 25_000));
    try std.testing.expectEqual(std.math.maxInt(i8), arrivalMargin(due, 400, 4000, due));
}

fn acceptInput(host: *const Host, peer: *Peer, input: wire.Input, time: i64) void {
    if (!input.follows(peer.sequence)) return;
    peer.sequence = input.sequence;
    peer.expires = time + timeout;
    if (!host.acceptsFlight() or input.arena_floor != host.arena_floor) return;
    const tick = input.tick orelse {
        peer.timed = .{};
        peer.flight_command = input.command;
        peer.fire_for = if (input.step.fire) input.fire_for else null;
        return;
    };
    for (input.earlier[0..input.earlier_count]) |flown| peer.timed.push(.{ .tick = flown.tick, .command = flown.command, .step = flown.step, .fire_for = input.fire_for });
    peer.timed.push(.{ .tick = tick, .command = input.command, .step = input.step, .fire_for = input.fire_for });
}

/// A pilot's inputs tagged with the ticks the client flew them to. One tagged `t` steers every
/// step after the one before it up to the step reaching `t`, as the client's own steps did.
const Timed = struct {
    /// `fire_for` names the ship a held trigger (`step.fire`) is for.
    const Entry = struct { tick: i32, command: flight.Command, step: flight_input.Step = .{}, fire_for: ?u32 };
    /// 64 steps, the 1.28 seconds that 32 of the original's steps held.
    const length = 64;
    entries: [length]Entry = undefined,
    first: usize = 0,
    count: usize = 0,
    /// The newest tick received, kept after its entry is taken so a redundant copy is not
    /// queued again.
    newest: ?i32 = null,

    fn push(timed: *Timed, entry: Entry) void {
        // A repeat or reordered input adds nothing the queue does not already steer by.
        if (timed.newest) |newest| if (entry.tick -% newest <= 0) return;
        timed.newest = entry.tick;
        if (timed.count == length) {
            timed.first = (timed.first + 1) % length;
            timed.count -= 1;
        }
        timed.entries[(timed.first + timed.count) % length] = entry;
        timed.count += 1;
    }

    /// The newest input whose step has been reached: a late one still takes over, an early
    /// one waits for its step. None means the last input holds. It carries the presses of every
    /// input taken with it, so a late step's press still flies once.
    fn take(timed: *Timed, tick: i32) ?Entry {
        var reached: ?Entry = null;
        var pressed: flight_input.Step = .{};
        while (timed.count > 0) {
            const entry = timed.entries[timed.first];
            if (entry.tick -% tick > 0) break;
            pressed.merge(entry.step);
            reached = entry;
            timed.first = (timed.first + 1) % length;
            timed.count -= 1;
        }
        if (reached) |*entry| entry.step = pressed;
        return reached;
    }
};

test "a late step's press flies once, with the newest command and trigger" {
    var timed: Timed = .{};
    timed.push(.{ .tick = 4, .command = .{}, .step = .{ .toggle = true, .fire = true }, .fire_for = 7 });
    timed.push(.{ .tick = 8, .command = .{ .afterburner = true }, .step = .{ .match_speed = true }, .fire_for = 7 });
    // A repeat of a step already queued adds nothing, so its press can't fly twice.
    timed.push(.{ .tick = 4, .command = .{}, .step = .{ .toggle = true }, .fire_for = 7 });
    timed.push(.{ .tick = 12, .command = .{}, .step = .{ .full = true }, .fire_for = null });

    const taken = timed.take(8).?;
    try std.testing.expect(taken.command.afterburner);
    try std.testing.expectEqual(flight_input.Step{ .toggle = true, .match_speed = true }, taken.step);
    try std.testing.expectEqual(null, timed.take(8));
    try std.testing.expectEqual(flight_input.Step{ .full = true }, timed.take(12).?.step);
}

fn acknowledgeMovie(host: *Host, slot: u8, tick: u32) void {
    if (slot >= wire.cooperative_slots or tick != host.tick) return;
    if (host.campaign_movie) |*movie| movie.waiting.unset(slot);
}

/// Takes what a connection not yet admitted sent, and closes it once its time to join is up.
fn servicePending(host: *Host, index: usize, time: i64) void {
    const peer = if (host.pending[index]) |*peer| peer else return;
    if (time >= peer.expires) return host.dropPending(index, .timed_out);
    if (peer.state == .connecting or peer.state == .closing) return;
    var buf: [wire.capacity]u8 = undefined;
    for (0..packets_per_tick) |_| {
        const received = host.channel().receive(peer.conn, &buf) catch return host.dropPending(index, .rejected);
        const message = received orelse return;
        const outcome = host.admit(index, message, time) catch .refused;
        switch (outcome) {
            .waiting => if (peer.state == .closing) return,
            .refused => return host.dropPending(index, if (message == .leave) .normal else .rejected),
            // The pilot's later messages are read from their slot.
            .admitted => return,
        }
    }
}

fn service(host: *Host, slot: u8, time: i64) void {
    const peer = if (host.peers[slot]) |*peer| peer else return;
    var buf: [wire.capacity]u8 = undefined;
    for (0..packets_per_tick) |_| {
        var age: i64 = 0;
        const message = host.channel().receiveAged(peer.conn, &buf, &age) catch |err| {
            log.warn("a playing pilot's connection failed: {t}", .{err});
            host.remove(slot, host.final_tick == null, .rejected);
            return;
        } orelse break;
        if (message == .input) host.noteArrival(peer, message.input, time - @max(age, 0));
        // Whatever goes wrong with one pilot's message, it is that pilot who leaves.
        const keep = host.receive(slot, peer, message, time) catch |err| failed: {
            if (err != error.SendFailed) log.warn("the message of the pilot in slot {d} failed: {t}", .{ slot, err });
            break :failed false;
        };
        if (!keep) {
            const departure: Departure = if (message == .leave or message == .received_final) .normal else .rejected;
            host.remove(slot, host.final_tick == null, departure);
            return;
        }
    }
    // A headed host can spend time opening a film. Give admitted pilots one bounded receive
    // pass to deliver queued keepalives before expiring them.
    if (peer.expired(time)) host.remove(slot, host.final_tick == null, .timed_out);
}

fn servicePeers(host: *Host, time: i64) void {
    for (0..host.pending.len) |index| host.servicePending(index, time);
    for (0..host.peers.len) |slot| host.service(@intCast(slot), time);
    for (&host.retiring) |*entry| {
        const pilot = entry.* orelse continue;
        if (time < pilot.until) continue;
        net.session_close(pilot.conn);
        entry.* = null;
    }
}

pub fn playingCount(host: *const Host) usize {
    var count: usize = 0;
    for (host.peers) |entry| {
        const peer = entry orelse continue;
        if (peer.state == .playing) count += 1;
    }
    return count;
}

fn publishRoster(host: *Host) !void {
    if (!host.roster_dirty or (host.lan_only and host.start == .lobby and !host.localInLobby())) return;
    host.roster_dirty = false;
    var roster: wire.Roster = .{
        .paused = host.paused,
        .briefing = host.campaign_briefing,
        .dedicated = !host.lan_only,
        .limit = host.player_limit,
        .arena_floor = host.arena_floor,
        .teams = host.arena_teams,
        .options = host.arena_options,
    };
    if (host.start == .lobby) {
        if (host.start.lobby.mission) |number| roster.mission = number else roster.lobby = host.start.lobby.scenario;
    } else if (host.campaign_start) |pending| roster.mission = pending.number;
    for (host.peers, host.arena.pilots, &roster.pilots, 0..) |entry, participant, *listed, slot| {
        const peer = entry orelse continue;
        const pilot = participant orelse continue;
        if (peer.state != .playing) continue;
        listed.* = .{ .generation = pilot.participant.generation, .name = peer.call_sign orelse .{}, .team = pilot.team };
        if (roster.mission != null and !roster.briefing and (slot == 0 or peer.lobby_ready)) roster.ready.set(slot);
    }
    var buffer: [wire.capacity]u8 = undefined;
    const bytes = try (wire.Message{ .roster = roster }).encode(&buffer);
    for (host.peers, 0..) |entry, slot| {
        const peer = entry orelse continue;
        if (peer.state != .playing) continue;
        host.channel().sendBytes(peer.conn, bytes, true) catch host.release(@intCast(slot));
    }
}

/// Whether the host sends the flight view of step `tick`. It steps 50 times a second and sends
/// the view of every second step, 25 a second as the original's steps came, so its upload stays
/// what it was. Each client flies the steps between two views itself, from its own inputs and
/// the others' last commands, by the same code (Rocket League GDC 2018). A paused, final or
/// debrief view is always sent, and so is everything that goes by its own message.
fn sendsFlightView(tick: u32) bool {
    return tick % steps_per_flight_view == 0;
}

const steps_per_flight_view = game.gameobj.original_ticks_per_step / game.gameobj.ticks_per_step;

test sendsFlightView {
    var sent: u32 = 0;
    for (1..51) |tick| {
        if (sendsFlightView(@intCast(tick))) sent += 1;
    }
    try std.testing.expectEqual(25, sent);
}

fn acceptsFlight(host: *const Host) bool {
    return host.start != .lobby and !host.paused and !host.campaign_briefing and host.debrief == null and
        host.campaign_movie == null and host.campaign_start == null;
}

fn applyControls(host: *Host, time: i64) void {
    for (&host.peers, 0..) |*entry, slot| {
        const peer = if (entry.*) |*peer| peer else continue;
        if (peer.state != .playing or peer.sequence == null) continue;
        const reach = host.arena.mission.clock.mission_ticks + game.gameobj.ticks_per_step;
        const taken = peer.timed.take(reach);
        if (taken) |timed| {
            peer.flight_command = timed.command;
            peer.fire_for = if (timed.step.fire) timed.fire_for else null;
            peer.presses.merge(timed.step.presses());
            peer.match_speed = peer.match_speed or timed.step.match_speed;
        }
        const expired = time - (peer.expires - timeout) >= held_input_timeout;
        var command = if (expired) flight_input.release(peer.flight_command) else peer.flight_command;
        peer.presses.apply(&command);
        peer.presses = .{};
        peer.flown_command = command;
        const match_speed = peer.match_speed;
        peer.match_speed = false;
        const order = peer.weapons;
        if (peer.weapons) |*pending| {
            pending.presses = .{};
            pending.cockpit = .{};
        }
        if (!host.arena.input(@intCast(slot), command, if (expired) null else peer.fire_for, order, match_speed))
            host.release(@intCast(slot));
    }
}

fn broadcast(host: *Host, view: wire.Snapshot, delivery: Delivery) !void {
    const reliable = delivery != .flight;
    var buffer: [wire.capacity]u8 = undefined;
    var outgoing = view;
    if (delivery.result()) {
        outgoing.campaign_checkpoint = host.campaignCheckpoint();
    }
    host.fillPings(&outgoing, host.tick == 1 or host.tick % (game.main.ticks_per_second / game.gameobj.ticks_per_step) == 0);
    outgoing.countPilotPages();
    var pilots: PilotPackets = undefined;
    try pilots.encode(&outgoing);
    for (&host.peers, 0..) |*entry, slot| {
        const peer = if (entry.*) |*peer| peer else continue;
        if (peer.state != .playing) continue;
        if (delivery == .split_result and host.debrief.?.eligible.isSet(slot)) continue;
        pilots.send(host.channel(), peer.conn, reliable) catch {
            if (reliable) host.release(@intCast(slot));
            continue;
        };
        host.sendView(&outgoing, @intCast(slot), delivery, &buffer) catch |err| switch (err) {
            error.SendFailed => {
                if (reliable) host.release(@intCast(slot));
                continue;
            },
            else => return err,
        };
        if (reliable) peer.expires = host.now() + timeout;
    }
}

const PilotPackets = struct {
    buffers: [wire.PilotPage.max_extra][wire.capacity]u8,
    lengths: [wire.PilotPage.max_extra]usize,
    count: u8,

    fn encode(packets: *PilotPackets, view: *const wire.Snapshot) !void {
        packets.count = view.pilot_pages;
        for (0..packets.count) |index| {
            const message: wire.Message = .{ .pilot_page = view.pilotPage(@intCast(index + 1)) };
            packets.lengths[index] = (try message.encode(&packets.buffers[index])).len;
        }
    }

    fn send(packets: *const PilotPackets, transport: net.Channel, conn: net.Connection, reliable: bool) !void {
        for (0..packets.count) |index| try transport.sendBytes(conn, packets.buffers[index][0..packets.lengths[index]], reliable);
    }
};

fn fillPings(host: *Host, view: *wire.Snapshot, refresh: bool) void {
    if (!view.hasOrdnance()) return;
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

const Delivery = enum {
    flight,
    paused,
    final,
    debrief,
    split_result,

    fn result(delivery: Delivery) bool {
        return delivery == .debrief or delivery == .split_result;
    }
};

/// A pilot gets the same private cockpit readings during a pause as in flight.
fn sendView(host: *const Host, view: *wire.Snapshot, slot: u8, delivery: Delivery, buffer: *[wire.capacity]u8) !void {
    const all = host.arena.mission.objects;
    if (view.mission) |*mission| {
        const state = &all.player_states[slot];
        mission.guide = host.arena.guide(slot);
        mission.landed = state.landed;
        mission.rescues = if (delivery.result()) host.debrief.?.rescues[slot] else host.peers[slot].?.rescues;
        if (state.membership == .joined) {
            mission.kills = state.membership.joined.kills.mission;
            mission.ending = state.membership.joined.ending;
            mission.ending_scene = state.membership.joined.ending_scene;
        }
    }
    const ship = view.hasOrdnance() and all.playerBinding(slot) != null;
    view.weapons = if (ship) wire.ordnance.Status.capture(all, slot) else null;
    view.power = if (ship and view.scenario != null and view.scenario.?.hasPowerUps()) wire.Power.capture(&all.slots[slot].object) else null;
    const message: wire.Message = switch (delivery) {
        .flight, .paused => .{ .view = view.* },
        .final => .{ .finished = view.* },
        .debrief, .split_result => .{ .campaign_result = view.* },
    };
    try host.channel().sendBytes(host.peers[slot].?.conn, try message.encodeView(buffer), delivery != .flight);
    if (delivery == .flight and ship) try host.sendOwnFlight(slot, buffer);
}

/// The pilot's simulation takes up the host's exact state of its own ship and replays its later
/// inputs (Overwatch GDC 2017, Fiedler "Networked Physics").
fn sendOwnFlight(host: *const Host, slot: u8, buffer: []u8) !void {
    const all = host.arena.mission.objects;
    const own: wire.OwnFlight = .{
        .tick = @intCast(host.arena.mission.clock.mission_ticks),
        .margin = host.peers[slot].?.margin,
        .received = host.peers[slot].?.timed.newest orelse 0,
        .kinematics = .of(&all.slots[slot].object),
        .controls = all.player_states[slot].controls,
    };
    try host.channel().sendBytes(host.peers[slot].?.conn, try (wire.Message{ .own_flight = own }).encode(buffer), false);
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
                host.channel().send(peer.conn, message) catch host.release(@intCast(slot));
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
    // The last step's effects go out once more before this step's: combat datagrams are
    // unreliable and one-shot, and the client's gates make a repeat cost nothing (Overwatch
    // GDC 2017 sends its recent inputs the same way).
    var again = host.combat_again[0..host.combat_again_count];
    host.combat_again_count = 0;
    while (again.len > 0) {
        const batch_len = @min(again.len, wire.Combat.max);
        try host.sendCombat(again[0..batch_len]);
        again = again[batch_len..];
    }
    var remaining = host.arena.combat[0..host.arena.combat_count];
    while (remaining.len > 0) {
        const batch_len = @min(remaining.len, wire.Combat.max);
        try host.sendCombat(remaining[0..batch_len]);
        const kept = host.combat_again_count + batch_len;
        @memcpy(host.combat_again[host.combat_again_count..kept], remaining[0..batch_len]);
        host.combat_again_count = kept;
        remaining = remaining[batch_len..];
    }
}

/// One combat batch, both as this step's fresh effects and as the next step's repeat.
fn sendCombat(host: *Host, effects: []const game.guns.FlightEffect) !void {
    var batch: wire.Combat = .{ .arena_floor = host.arena_floor, .count = @intCast(effects.len) };
    @memcpy(batch.entries[0..effects.len], effects);
    var buffer: [wire.capacity]u8 = undefined;
    const bytes = try (wire.Message{ .combat = batch }).encode(&buffer);
    for (host.peers) |entry| {
        const peer = entry orelse continue;
        if (peer.state == .playing) host.channel().sendBytes(peer.conn, bytes, false) catch continue;
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
                if (peer.state == .playing) host.channel().sendBytes(peer.conn, bytes, false) catch continue;
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
    for (0..host.pending.len) |index| host.dropPending(index, .normal);
    for (&host.retiring) |*entry| {
        if (entry.*) |pilot| net.session_close(pilot.conn);
        entry.* = null;
    }
    if (host.listener != 0) {
        net.session_listen_close(host.listener);
        host.listener = 0;
    }
    if (host.discovery) {
        net.session_datagram_handler(null);
        lan.publish(null);
        host.discovery = false;
    }
}

fn sendCampaignPhase(host: *Host, message: wire.Message) void {
    for (host.peers, 0..) |entry, slot| {
        const peer = entry orelse continue;
        if (peer.state == .playing) host.channel().send(peer.conn, message) catch host.release(@intCast(slot));
    }
}

/// WinMain counts rescues and marks a pilot who cannot continue (0x004A9F09 to 0x004AA09F).
/// Replay restores the counts the crew had at the start of the attempt.
fn beginDebrief(host: *Host, mission: wire.MissionView) void {
    const objects = host.arena.mission.objects;
    var eligible: Crew.Pilots = .empty;
    var counts: [wire.cooperative_slots]u8 = @splat(0);
    for (objects.player_states[0..wire.cooperative_slots], 0..) |state, slot| {
        const peer = host.peers[slot] orelse continue;
        if (state.membership != .joined) continue;
        var result = mission;
        result.ending = state.membership.joined.ending;
        result.rescues = @min(peer.rescues + @intFromBool(result.ending == .rescued), game.gameflow.allowed_rescues + 1);
        counts[slot] = result.rescues;
        if (result.canAdvance()) eligible.set(slot);
    }
    host.debrief = .{ .directory = host.campaign_directory.?, .eligible = eligible, .rescues = counts };
}

fn campaignCheckpoint(host: *const Host) wire.CampaignCheckpoint {
    var point: wire.CampaignCheckpoint = .capture(&host.arena.loaded.?.script.variables, &host.arena.mission.objects.wingmen);
    const results = &host.debrief.?;
    for (host.peers[0..wire.cooperative_slots], results.rescues, 0..) |entry, count, slot| {
        const peer = entry orelse continue;
        if (peer.call_sign) |name| point.rescues.set(slot, name.slice(), count);
    }
    return point;
}

fn debriefCrew(host: *const Host, results: Results) Crew {
    var present: Crew.Pilots = .empty;
    for (host.peers[0..wire.cooperative_slots], 0..) |entry, slot| {
        const peer = entry orelse continue;
        if (peer.state == .playing) present.set(slot);
    }
    var crew: Crew = .{
        .present = present,
        .eligible = present.intersectWith(results.eligible),
        .ready = present.intersectWith(results.ready),
    };
    crew.chooseLead(if (host.lan_only) 0 else null);
    return crew;
}

fn takeDebriefChoice(host: *Host, slot: u8, choice: wire.DebriefChoice) void {
    const results = if (host.debrief) |*results| results else return;
    if (choice.tick != host.tick or results.next != null) return;
    if (!host.debriefCrew(results.*).permits(slot, choice.action)) return;
    switch (choice.action) {
        .ready => {
            results.ready.set(slot);
            results.dirty = true;
        },
        .advance, .replay => results.next = choice.action,
    }
}

fn serviceDebrief(host: *Host, time: i64) !bool {
    const results = if (host.debrief) |*results| results else return false;
    if (results.next) |choice| {
        const previous = host.arena.mission.objects.mission_number;
        const number = if (choice == .replay) previous else game.gameflow.nextMission(previous);
        if (!wire.campaignNumber(number)) {
            host.sendCampaignPhase(.{ .campaign_end = host.tick });
            host.final_tick = host.tick;
            host.drain_until = time + timeout;
            host.debrief = null;
            return true;
        }
        try host.stageCampaign(time, number, false, choice == .advance);
        return true;
    }
    if (results.dirty) {
        results.dirty = false;
        const crew = host.debriefCrew(results.*);
        host.sendCampaignPhase(.{ .debrief = .{ .tick = host.tick, .crew = crew } });
    }
    return true;
}

fn stageCampaign(host: *Host, time: i64, number: u16, second_part: bool, advance: bool) !void {
    const results = host.debrief.?;
    const staging = try host.arena.betweenMissions(host.io, results.directory);
    if (advance) {
        const crew = host.debriefCrew(results);
        var excluded = crew.present.differenceWith(crew.eligible).iterator(.{});
        while (excluded.next()) |slot| {
            const index: u8 = @intCast(slot);
            const peer = host.peers[index].?;
            if (host.channel().send(peer.conn, .{ .campaign_retired = host.tick })) |_| {
                if (host.retiring[index]) |retired| net.session_close(retired.conn);
                host.retiring[index] = .{ .conn = peer.conn, .until = time + wire.campaign_movie_timeout };
                host.remove(index, false, .retired);
            } else |_| host.remove(index, false, .normal);
            staging.leave(index);
        }
        var continuing = crew.eligible.iterator(.{});
        while (continuing.next()) |slot| host.peers[slot].?.rescues = results.rescues[slot];

        const kept = &host.campaign_record.?;
        if (second_part) host.split_restart = .{ .variables = kept.variables, .wing = host.campaign_wing } else host.split_restart = null;
        kept.variables = host.arena.loaded.?.script.variables;
        if (!second_part) kept.variables.last_success = kept.variables.mission_success;
        kept.mission = number;
        host.campaign_wing = host.arena.mission.objects.wingmen;
    }
    host.enterCampaignStage(staging, time, number, second_part, advance);
    host.sendCampaignPhase(.{ .campaign_next = .{ .after = host.tick, .number = number, .second_part = second_part } });
    if (second_part) try host.seatCampaignCrew();
}

fn enterCampaignStage(host: *Host, staging: *Arena, time: i64, number: u16, second_part: bool, advance: bool) void {
    if (!advance) if (host.split_restart) |point| {
        host.campaign_record.?.variables = point.variables;
        host.campaign_wing = point.wing;
        host.split_restart = null;
    };
    const directory = host.debrief.?.directory;
    host.arena.destroy();
    host.arena = staging;
    host.debrief = null;
    host.beginBriefing(number, directory);
    host.campaign_start.?.second_part = second_part;
    host.campaign_briefing = !second_part;
    host.scene_pages = @splat(false);
    host.projectile_pages = @splat(false);
    host.next_scene_page = 0;
    host.clearFlightControls();
    for (&host.peers) |*entry| if (entry.*) |*peer| {
        if (!advance) peer.rescues = peer.attempt_rescues;
        if (!second_part) peer.attempt_rescues = peer.rescues;
        peer.briefed = second_part;
        peer.weapons = null;
        peer.expires = time + timeout;
    };
}

fn beginMovie(host: *Host, time: i64) void {
    var waiting: Crew.Pilots = .empty;
    for (host.peers[0..wire.cooperative_slots], 0..) |entry, slot| {
        if (entry != null and entry.?.state == .playing) waiting.set(slot);
    }
    // A client can pause its movie by changing focus. Bound the time it can hold the mission clock.
    host.campaign_movie = .{ .waiting = waiting, .until = time + wire.campaign_movie_timeout };
    host.clearFlightControls();
    host.sendCampaignPhase(.{ .campaign_movie = host.tick });
}

/// Whether a host goes on, or its session is over.
pub const Pumped = enum { running, finished };

/// `pump`, for a caller that comes round less often than the host steps, such as once a drawn
/// frame: it takes every step that is due, so the game keeps its speed whatever the frame rate.
/// A host more than `max_late_steps` behind starts its schedule over (`pump`), which bounds the
/// steps of one call.
pub fn pumpDue(host: *Host) !Pumped {
    var steps: usize = 0;
    while (true) {
        if (try host.pump() == .finished) return .finished;
        steps += 1;
        if (steps > max_late_steps or host.final_tick != null or host.now() < host.next_step) return .running;
    }
}

/// Services a host without waiting for the next tick. The caller polls transport callbacks.
pub fn pump(host: *Host) !Pumped {
    host.answerDiscovery();
    const time = host.now();
    if (host.final_tick != null) {
        if (time >= host.drain_until or host.playingCount() == 0) return .finished;
        host.servicePeers(time);
        return .running;
    }
    if (time < host.next_step) return .running;
    // Steps keep a fixed schedule, so a late wake costs the next step's wait rather than the
    // mission clock's rate; the clients' clocks track the host's (Fiedler, "Fix Your Timestep").
    // A stall past a few steps starts the schedule over rather than bursting.
    host.next_step += wire.step_us;
    if (time - host.next_step > max_late_steps * wire.step_us) host.next_step = time;
    if (host.signer) |signer| {
        if (time >= host.renew_at) {
            var certificate = try signer.hostCertificate(host.io);
            defer certificate.wipe();
            if (!net.session_set_certificate(certificate.bytes[0..].ptr, @intCast(certificate.len)))
                return error.IdentityRenewalFailed;
            host.renew_at = time + identity.renew_after_us;
        }
    }
    host.servicePeers(time);
    if (host.paused_view_pending) {
        // The last flight view may have been lost. Deliver the frozen tick before the pause roster.
        try host.broadcast(try host.arena.snapshot(host.tick), .paused);
        host.paused_view_pending = false;
    }
    if (host.paused and time >= host.next_paused_roster) {
        host.roster_dirty = true;
        host.next_paused_roster = time + paused_roster_interval;
    }
    try host.publishRoster();
    if (host.debrief != null and host.playingCount() == 0) return .finished;
    if (try host.serviceDebrief(time)) return .running;
    if (host.campaign_movie) |movie| {
        if (movie.waiting.count() != 0 and time < movie.until) return .running;
        host.campaign_movie = null;
    }
    if (host.paused) return .running;
    if (host.campaign_briefing) {
        if (host.start == .automatic and host.playingCount() == 0) {
            host.campaign_briefing = false;
            return .running;
        }
        if (!host.crewBriefed()) return .running;
        try host.seatCampaignCrew();
        if (host.playingCount() == 0) return .running;
        host.campaign_briefing = false;
        host.start = .launched;
        host.roster_dirty = true;
    } else switch (host.start) {
        .lobby => {
            if (!host.lan_only and host.launch_wait.ready(host.playingCount(), time)) try host.startArena();
            return .running;
        },
        .automatic => if (host.tick == 0) {
            if (!host.launch_wait.ready(host.playingCount(), time)) return .running;
            if (host.campaign_start) |pending| {
                host.beginBriefing(pending.number, pending.directory);
                return .running;
            }
        },
        .launched => {},
    }
    const starting_round = host.tick == host.arena_floor or host.campaign_start != null;
    if (host.repeat_rounds and !starting_round and host.playingCount() == 0) {
        try host.returnToArenaLobby();
        return .running;
    }
    if (host.campaign_start) |pending| {
        const staging = host.arena;
        if (host.tick == 0) {
            for (&host.peers, 0..) |*entry, slot| {
                const peer = if (entry.*) |*peer| peer else continue;
                const legacy = if (host.lan_only and slot == 0) host.campaign_record.?.pickups else 0;
                const name: wire.CallSign = peer.call_sign orelse .{};
                const count = host.campaign_rescues.count(name.slice()) orelse legacy;
                peer.rescues = @min(count, game.gameflow.allowed_rescues + 1);
                peer.attempt_rescues = peer.rescues;
            }
        }
        host.arena = try staging.prepareCampaign(.{ .number = pending.number, .after = host.tick, .second_part = pending.second_part }, host.io, pending.directory, &host.campaign_record.?, &host.campaign_wing, host.campaign_difficulty);
        host.campaign_start = null;
        staging.destroy();
        const expires = host.now() + timeout;
        for (&host.peers) |*entry| {
            if (entry.*) |*peer| peer.expires = expires;
        }
    }
    if (starting_round) if (host.roundStats()) |rounds| {
        rounds.started += 1;
    };
    host.applyControls(time);
    host.tick += 1;
    const step_started = if (host.metrics != null) host.now() else 0;
    const step = host.arena.step(host.tick);
    if (host.metrics) |exporter| exporter.stats.recordStep(@intCast(@max(0, host.now() - step_started)));
    const view = step catch |err| switch (err) {
        error.ArenaEnded => if (host.arena_directory != null and host.arena.mode.scenario() != null) {
            if (host.roundStats()) |rounds| rounds.completed += 1;
            try host.returnToArenaLobby();
            return .running;
        } else return err,
        else => return err,
    };
    // A pilot whose ship could not be made leaves; the others fly on.
    for (&host.arena.unspawnable, 0..) |*failed, slot| if (failed.*) {
        failed.* = false;
        host.remove(@intCast(slot), true, .rejected);
    };
    host.broadcastNotices();
    for (host.arena.wrecks) |entry| if (entry) |wreck| host.sendPlaying(.{ .wreck = wreck }, null);
    const capped = host.tick - host.arena_floor == host.last_tick;
    const mission_ended = if (host.arena.campaign) |campaign| campaign.finished else false;
    if (capped or mission_ended) if (host.roundStats()) |rounds| {
        rounds.completed += 1;
    };
    if (capped and host.repeat_rounds) {
        try host.returnToArenaLobby();
        return .running;
    }
    const delivery: Delivery = if (capped) .final else if (mission_ended) .debrief else .flight;
    if (delivery == .final) {
        host.final_tick = host.tick;
        host.drain_until = time + timeout;
    }
    if (delivery == .debrief) {
        const mission = view.mission.?;
        host.beginDebrief(mission);
        if (host.debrief.?.eligible.count() != 0 and game.winmain.continuesToSecondPart(mission.number, mission.second_part, mission.rating)) {
            try host.broadcast(view, .split_result);
            try host.stageCampaign(time, mission.number, true, true);
            return .running;
        }
    }
    const cutaway = delivery == .flight and host.arena.campaign != null and host.arena.campaign.?.display.fosters_last_stand;
    if (cutaway) {
        host.arena.campaign.?.display.fosters_last_stand = false;
        try host.broadcast(view, .paused);
        host.beginMovie(time);
    } else if (delivery != .flight or sendsFlightView(host.tick)) try host.broadcast(view, delivery);
    if (delivery == .flight) {
        for (host.arena.music.take()) |cue| host.sendPlaying(.{ .mission_music = cue }, null);
        if (host.arena.campaign) |campaign| {
            for (campaign.lines[0..campaign.line_count]) |line| host.sendPlaying(.{ .campaign_line = line }, null);
            campaign.line_count = 0;
        }
        try host.broadcastScenery();
        try host.broadcastCombat();
        try host.broadcastCommands();
        if (view.hasOrdnance()) try host.broadcastProjectiles();
        if (view.mission != null) try host.broadcastScene();
    }
    return .running;
}

fn broadcastScenery(host: *Host) !void {
    const scenery = host.arena.scenery(host.tick) orelse return;
    var buffer: [wire.capacity]u8 = undefined;
    const bytes = try (wire.Message{ .scenery = scenery }).encode(&buffer);
    for (host.peers) |entry| {
        const peer = entry orelse continue;
        if (peer.state == .playing) host.channel().sendBytes(peer.conn, bytes, false) catch continue;
    }
}

/// Echoes every pilot's held command as the last step flew it, so each client's simulation
/// carries the other pilots' ships by their real commands rather than a quantized echo of their
/// state (Rocket League GDC 2018).
fn broadcastCommands(host: *Host) !void {
    var commands: wire.Commands = .{ .tick = @intCast(host.arena.mission.clock.mission_ticks) };
    for (host.peers, 0..) |entry, slot| {
        const peer = entry orelse continue;
        if (peer.state != .playing) continue;
        commands.held[slot] = peer.flown_command;
        commands.carried |= @as(u8, 1) << @intCast(slot);
    }
    var buffer: [wire.capacity]u8 = undefined;
    const bytes = try (wire.Message{ .commands = commands }).encode(&buffer);
    for (host.peers) |entry| {
        const peer = entry orelse continue;
        if (peer.state == .playing) host.channel().sendBytes(peer.conn, bytes, false) catch continue;
    }
}

fn broadcastScene(host: *Host) !void {
    var sent: usize = 0;
    var buffer: [wire.capacity]u8 = undefined;
    for (0..wire.ScenePage.count) |_| {
        const number = host.next_scene_page;
        host.next_scene_page = @intCast((@as(usize, number) + 1) % wire.ScenePage.count);
        const page = wire.ScenePage.capture(host.arena.mission.objects, host.tick, number);
        const active = page.mask() != 0;
        const previous = &host.scene_pages[number];
        if (!active and !previous.*) continue;
        const bytes = try (wire.Message{ .scene_page = page }).encode(&buffer);
        var retry_clear = false;
        for (host.peers) |entry| {
            const peer = entry orelse continue;
            if (peer.state != .playing) continue;
            // Keep the empty page if an unreliable final position is lost.
            host.channel().sendBytes(peer.conn, bytes, !active) catch {
                retry_clear = !active;
            };
        }
        previous.* = active or retry_clear;
        sent += 1;
        if (sent == scene_pages_per_tick) break;
    }
}

pub fn run(host: *Host, address: [:0]const u8, ticks: ?u32, invite: ?identity.Invite, advertiser: ?*@import("advertise.zig"), updates: ?*@import("headless_updates.zig")) !void {
    try host.open(address, ticks);
    defer host.close();
    std.debug.print("listening {s}\n", .{address});
    if (invite) |value| {
        std.debug.print("invite {f}\n", .{value});
    } else if (host.signer != null) {
        std.debug.print("Set InviteAddress in server.ini to print an invite for this listener.\n", .{});
    }

    var shared_invite = false;
    while (true) {
        net.session_poll();
        const result = try host.pump();
        if (host.metrics) |exporter| exporter.publish(host.playingCount());
        if (advertiser) |publisher| {
            publisher.tick(host, host.now());
            // The invite through the directory, once the host is registered there.
            var buffer: [256]u8 = undefined;
            if (!shared_invite) if (publisher.invite(&buffer)) |text| {
                std.debug.print("invite {s}\n", .{text});
                shared_invite = true;
            };
        }
        if (updates) |check| check.tick(host.now());
        if (result == .finished) break;
        const wait = if (host.final_tick != null)
            std.time.us_per_ms
        else
            @min(wire.step_us, host.next_step - host.now());
        if (wait > 0) try host.io.sleep(.fromMicroseconds(wait), .awake);
    }
    log.info("finished {d} {d}", .{ host.tick, host.final_receipts });
}

test "one origin can keep only a few connections waiting, and start only a few a second" {
    var host: Host = .{ .io = std.testing.io, .arena = undefined };
    const first: [16]u8 = @as([10]u8, @splat(0)) ++ [2]u8{ 0xff, 0xff } ++ [4]u8{ 192, 0, 2, 1 };
    var other = first;
    other[15] = 2;
    // The same IPv4 address is one origin, another address is not.
    try std.testing.expect(sameOrigin(first, first) and !sameOrigin(first, other));
    // An IPv6 /64 is one origin.
    var home: [16]u8 = @splat(0);
    home[0] = 0x20;
    var neighbour = home;
    neighbour[15] = 9;
    var elsewhere = home;
    elsewhere[7] = 1;
    try std.testing.expect(sameOrigin(home, neighbour) and !sameOrigin(home, elsewhere) and !sameOrigin(home, first));

    for (0..starts_per_origin) |_| try std.testing.expect(host.takeStart(first, 0));
    try std.testing.expect(!host.takeStart(first, std.time.us_per_s - 1));
    try std.testing.expect(host.takeStart(other, std.time.us_per_s - 1));
    try std.testing.expect(host.takeStart(first, std.time.us_per_s));

    // Connections that wait count against their origin, whenever they started.
    for (host.pending[0..max_pending_per_origin]) |*entry| entry.* = .{ .conn = 1, .expires = 0, .address = first };
    try std.testing.expect(!host.takeStart(first, 10 * std.time.us_per_s));
    try std.testing.expect(host.takeStart(other, 10 * std.time.us_per_s));
}

test "connections that wait take no pilot's slot" {
    var host: Host = .{ .io = std.testing.io, .arena = undefined, .lan_only = true, .player_limit = 3 };
    for (&host.pending) |*entry| entry.* = .{ .conn = 1, .expires = 0 };
    // A player-hosted game keeps slot zero for its own pilot.
    try std.testing.expectEqual(1, host.freeSlot(false).?);
    try std.testing.expectEqual(0, host.freeSlot(true).?);
    host.peers[1] = .{ .conn = 2, .expires = 0, .state = .playing };
    host.peers[2] = .{ .conn = 3, .expires = 0, .state = .playing };
    try std.testing.expectEqual(null, host.freeSlot(false));
    try std.testing.expectEqual(0, host.freeSlot(true).?);
}

test "only an admitted local pilot can launch a player-hosted match" {
    var host: Host = .{ .io = std.testing.io, .arena = undefined, .start = .{ .lobby = .{} } };
    host.peers[1] = .{ .conn = 2, .expires = 0, .state = .playing };
    host.launch();
    try std.testing.expect(host.start == .lobby);
    host.pending[0] = .{ .conn = 1, .expires = 0, .state = .joining, .local = true };
    host.launch();
    try std.testing.expect(host.start == .lobby);
    host.peers[0] = host.pending[0];
    host.pending[0] = null;
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
    try std.testing.expect(!host.paused_view_pending);
    try std.testing.expect(host.acceptsFlight());

    host.lan_only = true;
    host.setPaused(true);
    try std.testing.expect(host.paused);
    try std.testing.expect(host.paused_view_pending);
    try std.testing.expect(host.roster_dirty);
    try std.testing.expect(!host.acceptsFlight());
    try std.testing.expectEqual(null, host.peers[0].?.fire_for);
    try std.testing.expect(!host.peers[0].?.flight_command.afterburner);

    host.setPaused(false);
    try std.testing.expect(host.acceptsFlight());
    try std.testing.expect(!host.paused_view_pending);
    try std.testing.expectEqual(8, host.tick);
}

test "co-op waits for every guest and discards a departed guest's readiness" {
    var host: Host = .{ .io = std.testing.io, .arena = undefined, .start = .{ .lobby = .{ .mission = 1 } } };
    const pilot: Peer = .{ .conn = 1, .state = .playing, .expires = 0 };
    host.peers[0] = pilot;
    try std.testing.expect(!host.canLaunch());
    host.peers[1] = pilot;
    host.peers[2] = pilot;
    host.markLobbyReady(1, &host.peers[1].?, true);
    try std.testing.expect(!host.canLaunch());
    host.markLobbyReady(2, &host.peers[2].?, true);
    try std.testing.expect(host.canLaunch());
    host.markLobbyReady(1, &host.peers[1].?, false);
    try std.testing.expect(!host.canLaunch());
    host.peers[1] = null;
    try std.testing.expect(host.canLaunch());
    host.peers[1] = pilot;
    try std.testing.expect(!host.canLaunch());
}

test "a pilot's refused messages leave the other pilots' ships, scores and objectives as they were" {
    const arena = try Arena.create(std.testing.allocator, .@"six-beacons", std.testing.io, .cwd());
    defer arena.destroy();
    for (0..3) |slot| _ = try arena.join(@intCast(slot), .predator);
    const all = arena.mission.objects;
    try std.testing.expect(all.arena_scenario == .six_beacons);
    // Something for the two other pilots to keep: a score, a death, and a beacon in hand.
    all.player_states[0].membership.joined.kills.count = 3;
    all.player_states[1].membership.joined.deaths = 2;
    all.arena_scenario.six_beacons.beacons[0].carrier = all.playerBinding(1).?;

    var host: Host = .{ .io = std.testing.io, .arena = arena, .start = .launched };
    for (host.peers[0..3], 1..) |*entry, conn| entry.* = .{ .conn = @intCast(conn), .state = .playing, .expires = timeout, .sequence = 10 };
    const peer = &host.peers[2].?;

    // What the others hold, byte for byte: each one's ship, with its flight, its guns' charge and
    // its fuel; its record, with its score, its lock and its devices; and the scenario's state,
    // which says who carries what.
    const Kept = struct {
        ships: [2][@sizeOf(game.gameobj.GameObject)]u8,
        records: [2][@sizeOf(game.players.State)]u8,
        scenario: [@sizeOf(@TypeOf(all.arena_scenario))]u8,

        fn of(objects: *const game.create.Objects) @This() {
            var kept: @This() = undefined;
            for (&kept.ships, &kept.records, 0..) |*ship, *record, slot| {
                ship.* = std.mem.asBytes(&objects.slots[slot].object).*;
                record.* = std.mem.asBytes(&objects.player_states[slot]).*;
            }
            kept.scenario = std.mem.asBytes(&objects.arena_scenario).*;
            return kept;
        }
    };
    const before = Kept.of(all);
    const hard_over: flight.Command = .{ .steering = .{ .axes = .{ 1, 1, 1 } }, .throttle = .{ .axis = 1 }, .afterburner = true };

    // An input out of order is passed over, and so is one for another round. The pilot keeps
    // their place, and the command they were flying.
    try std.testing.expect(try host.receive(2, peer, .{ .input = .{ .sequence = 9, .command = hard_over } }, 0));
    try std.testing.expect(try host.receive(2, peer, .{ .input = .{ .sequence = 11, .command = hard_over, .arena_floor = 7 } }, 0));
    try std.testing.expectEqual(flight.Command{}, peer.flight_command);
    try std.testing.expectEqualDeep(before, Kept.of(all));

    // A message only a host may send is refused, and the pilot who sent it leaves. `service`
    // then removes them (`remove`), which takes their ship out of the arena.
    try std.testing.expect(!(try host.receive(2, peer, .{ .roster = .{} }, 0)));
    arena.leave(2);
    try std.testing.expectEqual(null, arena.pilots[2]);
    try std.testing.expectEqualDeep(before, Kept.of(all));
}

test "the host counts a third rescue once and allows the pilot to replay" {
    const arena = try Arena.create(std.testing.allocator, .training, std.testing.io, .cwd());
    defer arena.destroy();
    _ = try arena.join(0, .predator);
    _ = try arena.join(1, .predator);
    arena.mission.objects.player_states[1].membership.joined.ending = .rescued;
    var host: Host = .{ .io = std.testing.io, .arena = arena, .campaign_directory = .cwd(), .tick = 400 };
    host.peers[0] = .{ .conn = 1, .state = .playing, .expires = timeout };
    host.peers[1] = .{ .conn = 2, .state = .playing, .expires = timeout, .rescues = 2, .attempt_rescues = 2 };
    host.beginDebrief(.{ .number = 1, .pilot_slots = 2, .lead = 0 });
    const result = host.debrief.?;
    try std.testing.expectEqual(3, result.rescues[1]);
    try std.testing.expect(!result.eligible.isSet(1));
    try std.testing.expect(host.debriefCrew(result).permits(1, .ready));
    try std.testing.expectEqual(2, host.peers[1].?.rescues);
    host.beginDebrief(.{ .number = 1, .pilot_slots = 2, .lead = 0 });
    try std.testing.expectEqual(result.rescues, host.debrief.?.rescues);
}

test "replaying a split mission restores the first part's campaign and rescue count" {
    var host: Host = .{
        .io = std.testing.io,
        .arena = try Arena.create(std.testing.allocator, .training, std.testing.io, .cwd()),
        .campaign_record = game.gameflow.Campaign.begin(),
        .split_restart = .{ .variables = .{ .reliant_alive = 1 }, .wing = .{} },
        .debrief = .{ .directory = .cwd(), .eligible = .empty, .rescues = @splat(0) },
    };
    defer host.arena.destroy();
    host.campaign_record.?.variables.reliant_alive = 0;
    host.peers[0] = .{ .conn = 1, .expires = timeout, .rescues = 2, .attempt_rescues = 1 };
    const staging = try host.arena.betweenMissions(host.io, host.debrief.?.directory);
    host.enterCampaignStage(staging, 0, 25, false, false);
    try std.testing.expectEqual(1, host.campaign_record.?.variables.reliant_alive);
    try std.testing.expectEqual(1, host.peers[0].?.rescues);
    try std.testing.expectEqual(25, host.campaign_start.?.number);
    try std.testing.expect(!host.campaign_start.?.second_part);
    try std.testing.expect(host.campaign_briefing);
}

test "movie receipts can release only the sending pilot at the held tick" {
    var host: Host = .{ .io = std.testing.io, .arena = undefined, .start = .launched, .tick = 120 };
    var waiting: Crew.Pilots = .empty;
    waiting.set(0);
    waiting.set(1);
    host.campaign_movie = .{ .waiting = waiting, .until = wire.campaign_movie_timeout };
    host.acknowledgeMovie(1, 119);
    try std.testing.expectEqual(waiting, host.campaign_movie.?.waiting);
    host.acknowledgeMovie(1, 120);
    try std.testing.expect(!host.campaign_movie.?.waiting.isSet(1));
    try std.testing.expect(host.campaign_movie.?.waiting.isSet(0));
    try std.testing.expect(!host.acceptsFlight());
}

test "an undeliverable private message spends only the sender's allowance" {
    var host: Host = .{ .io = std.testing.io, .arena = undefined, .tick = 1 };
    host.peers[0] = .{ .conn = 1, .expires = timeout, .state = .playing, .call_sign = wire.lobbyName("Rook") };
    const peer = &host.peers[0].?;
    try std.testing.expectEqual(null, host.chatRoute(0, peer, .{ .private = .{ .slot = 1, .generation = 2 } }, 0));
    try std.testing.expect(peer.chat_budget.ready_at != null);
    try std.testing.expectEqual(null, host.chat_budget.ready_at);
    try std.testing.expect(host.chatRoute(0, peer, .flight, 0).? == .broadcast);
    try std.testing.expect(host.chat_budget.ready_at != null);
}

test "a reordered command or a command for the previous round leaves other controls alone" {
    var host: Host = .{ .io = std.testing.io, .arena = undefined, .arena_floor = 35, .start = .launched };
    host.peers[0] = .{ .conn = 1, .state = .playing, .expires = 50, .flight_command = .{ .afterburner = true } };
    host.peers[1] = .{ .conn = 2, .state = .playing, .expires = 50, .sequence = 14 };
    const peer = &host.peers[1].?;
    host.acceptInput(peer, .{
        .sequence = 13,
        .arena_floor = 35,
        .command = .{ .reverse = true },
        .fire_for = 9,
    }, 25);
    try std.testing.expectEqual(50, peer.expires);
    host.acceptInput(peer, .{
        .sequence = 15,
        .arena_floor = 0,
        .command = .{ .reverse = true },
        .fire_for = 9,
    }, 25);
    try std.testing.expectEqualDeep(flight.Command{}, peer.flight_command);
    try std.testing.expectEqual(null, peer.fire_for);
    try std.testing.expect(host.peers[0].?.flight_command.afterburner);
}

test "a pilot's timed inputs steer the steps reaching their ticks, early ones waiting" {
    var timed: Timed = .{};
    timed.push(.{ .tick = 8, .command = .{ .afterburner = true }, .fire_for = null });
    timed.push(.{ .tick = 8, .command = .{ .reverse = true }, .fire_for = null });
    timed.push(.{ .tick = 12, .command = .{ .reverse = true }, .fire_for = null });
    timed.push(.{ .tick = 20, .command = .{}, .fire_for = null });
    // Early: the step reaching 4 keeps the last command.
    try std.testing.expectEqual(null, timed.take(4));
    try std.testing.expect(timed.take(8).?.command.afterburner);
    // Late: the step reaching 16 takes the newest input already due.
    try std.testing.expect(timed.take(16).?.command.reverse);
    try std.testing.expect(!timed.take(20).?.command.reverse);
    // A redundant copy of a step already flown is not queued again.
    timed.push(.{ .tick = 16, .command = .{ .afterburner = true }, .fire_for = null });
    try std.testing.expectEqual(null, timed.take(24));
}
