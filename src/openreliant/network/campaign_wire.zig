//! Campaign-specific records carried by the multiplayer connection.
const std = @import("std");
const engine = @import("openreliant").engine;
const wire = @import("wire.zig");
const slots = wire.slots;
const cooperative_slots = wire.cooperative_slots;
const Facing = wire.Facing;
const Fighter = wire.Fighter;

const saved = engine.game.gameflow.save;
const pilots = engine.game.pilots;

/// The common part of a retail save. Each pilot adds their own profile and result locally.
pub const Checkpoint = struct {
    vars: saved.Vars,
    replacement: saved.Replacement,
    wing: saved.Wing,
    rescues: saved.CoopRescues = .{},
    pub const capacity = @sizeOf(saved.Vars) + @sizeOf(saved.Replacement) + @sizeOf(saved.Wing) + saved.CoopRescues.capacity;

    pub fn capture(variables: *const engine.vm.Variables, wingmen: *const pilots.Wingmen) Checkpoint {
        return .{ .vars = saved.captureVariables(variables), .replacement = wingmen.pool[0], .wing = wingmen.alpha };
    }

    pub fn apply(checkpoint: Checkpoint, variables: *engine.vm.Variables, wingmen: *pilots.Wingmen) void {
        saved.applyVariables(variables, checkpoint.vars);
        wingmen.alpha = checkpoint.wing;
        wingmen.pool[0] = checkpoint.replacement;
    }

    pub fn write(checkpoint: Checkpoint, w: *std.Io.Writer) !void {
        for (checkpoint.vars) |value| try w.writeInt(i32, value, .little);
        try w.writeInt(i16, checkpoint.replacement.pilot, .little);
        try w.writeByte(@backingInt(checkpoint.replacement.status));
        try w.writeByte(checkpoint.replacement._unused);
        for (checkpoint.wing) |pilot| try w.writeInt(i16, pilot, .little);
        try w.writeAll(&checkpoint.rescues.encode());
    }

    pub fn read(r: *std.Io.Reader) !Checkpoint {
        var checkpoint: Checkpoint = undefined;
        for (&checkpoint.vars) |*value| value.* = try r.takeInt(i32, .little);
        checkpoint.replacement = .{
            .pilot = try r.takeInt(i16, .little),
            .status = try r.takeEnum(saved.Replacement.Status, .little),
            ._unused = try r.takeByte(),
        };
        for (&checkpoint.wing) |*pilot| pilot.* = try r.takeInt(i16, .little);
        checkpoint.rescues = saved.CoopRescues.decode(try r.takeArray(saved.CoopRescues.capacity)) orelse return error.InvalidRescueCounts;
        return checkpoint;
    }
};

/// A pilot's requested stock loadout after the briefing. Void uses the mission's authored fit.
pub const CampaignLoadout = struct {
    ship: Fighter,
    racks: engine.game.create.Racks,

    pub fn valid(loadout: CampaignLoadout) bool {
        const tables = engine.interface.loadout.tables;
        if (@backingInt(loadout.ship) >= tables.ships_by_tier[0]) return false;
        var fitted: engine.interface.loadout.racks.Carried = @splat(0);
        for (loadout.racks) |kind| {
            if (kind == .none) continue;
            const missile = tables.Missile.ofType(kind.base()) orelse return false;
            if (kind != missile.missileType() or !missile.offeredAt(0)) return false;
            const count = &fitted[@backingInt(missile)];
            count.* += 1;
            if (count.* > missile.limit()) return false;
        }
        return true;
    }
};
const ObjectivesDisplay = engine.game.hud.Objectives;
pub const MissionView = struct {
    pub const capacity = @sizeOf(u16) + 9 * @sizeOf(u8) + 5 * @sizeOf(f32) + (ObjectivesDisplay.per_mission + 1) * @sizeOf(i16) + @sizeOf(Facing) + Guide.capacity;
    number: u16,
    pilot_slots: u8,
    lead: ?u8,
    travel: Travel = .{},
    objectives: [ObjectivesDisplay.per_mission]ObjectivesDisplay.Status = @splat(.hidden),
    rating: engine.vm.Variables.Outcome = .failure,
    guide: Guide = .{},
    ending: engine.game.main.Ending = .playing,
    ending_scene: engine.game.players.EndingScene = .none,
    kills: u16 = 0,
    rescues: u8 = 0,
    second_part: bool = false,
    landed: bool = false,
    objectives_met: bool = false,
    reliant_alive: bool = true,
    nebula: u8 = engine.game.nebula.default_nebula,
    director: ?Director = null,

    pub fn transferred(mission: MissionView) bool {
        return engine.game.gameflow.transferredAfterRescues(mission.rescues);
    }

    pub fn finale(mission: MissionView) bool {
        return mission.canAdvance() and engine.game.gameflow.nextMission(mission.number) == engine.game.gameflow.story_end;
    }

    pub fn canAdvance(mission: MissionView) bool {
        return (mission.ending == .playing or mission.ending == .rescued) and !mission.transferred() and mission.rating != .total_failure;
    }

    pub const Director = struct {
        position: engine.surrender.math.Vector,
        angles: Facing,
        bars: f32,
    };

    /// Scripted guidance and the active landing view for the receiving pilot.
    pub const Guide = struct {
        const capacity = @sizeOf(u32) + 5 * (@sizeOf(u16) + @sizeOf(u32)) + @sizeOf(i16) + 1 + 3 * @sizeOf(f32);
        aim: u32 = 0,
        target: ?engine.game.players.Target = null,
        escort: ?engine.game.gameobj.ObjectRef = null,
        nav: ?engine.game.gameobj.ObjectRef = null,
        primary: ?engine.game.gameobj.ObjectRef = null,
        landing: ?Landing = null,

        pub const Landing = struct {
            carrier: engine.game.gameobj.ObjectRef,
            view: View,
            tube: [3]f32,

            pub const View = enum(u8) { tube, aside };
        };

        fn write(guide: Guide, w: *std.Io.Writer) !void {
            try w.writeInt(u32, guide.aim, .little);
            try writeObjectRef(w, if (guide.target) |target| target.object else null);
            if (guide.target) |target| try w.writeInt(i16, if (target.component) |part| @intCast(part) else -1, .little);
            for ([_]?engine.game.gameobj.ObjectRef{ guide.escort, guide.nav, guide.primary }) |ref| try writeObjectRef(w, ref);
            try writeObjectRef(w, if (guide.landing) |landing| landing.carrier else null);
            if (guide.landing) |landing| {
                try w.writeByte(@backingInt(landing.view));
                try wire.writePosition(w, landing.tube);
            }
        }

        fn read(r: *std.Io.Reader) !Guide {
            var guide: Guide = .{ .aim = try r.takeInt(u32, .little) };
            if (try readObjectRef(r)) |target| {
                const component = try r.takeInt(i16, .little);
                if (component < -1) return error.InvalidMissionView;
                guide.target = .{ .object = target, .component = if (component == -1) null else @intCast(component) };
            }
            guide.escort = try readObjectRef(r);
            guide.nav = try readObjectRef(r);
            guide.primary = try readObjectRef(r);
            if (try readObjectRef(r)) |carrier| guide.landing = .{
                .carrier = carrier,
                .view = try r.takeEnum(Landing.View, .little),
                .tube = try wire.readPosition(r),
            };
            return guide;
        }
    };

    pub const Travel = packed struct(u8) {
        jump: bool = false,
        warp: bool = false,
        reserved: u6 = 0,

        pub fn any(travel: Travel) bool {
            return travel.jump or travel.warp;
        }
    };

    pub fn write(mission: *const MissionView, w: *std.Io.Writer) !void {
        try w.writeInt(u16, mission.number, .little);
        try w.writeByte(mission.pilot_slots);
        try w.writeByte(mission.lead orelse slots);
        try w.writeByte(@bitCast(mission.travel));
        for (mission.objectives) |objective| try w.writeInt(i16, @backingInt(objective), .little);
        try w.writeInt(i32, @backingInt(mission.rating), .little);
        try mission.guide.write(w);
        try w.writeByte(@backingInt(mission.ending));
        try w.writeByte(@backingInt(mission.ending_scene));
        try w.writeInt(u16, mission.kills, .little);
        try w.writeByte(mission.rescues);
        const landed: u8 = @intFromBool(mission.landed);
        const met: u8 = @intFromBool(mission.objectives_met);
        const reliant: u8 = @intFromBool(mission.reliant_alive);
        const second: u8 = @intFromBool(mission.second_part);
        try w.writeByte(landed | (met << 1) | (reliant << 2) | (second << 3));
        try w.writeByte(mission.nebula);
        try w.writeByte(@intFromBool(mission.director != null));
        if (mission.director) |director| {
            try wire.writePosition(w, director.position);
            for (director.angles) |angle| try w.writeInt(i16, angle, .little);
            try wire.writeFloat(w, director.bars);
        }
    }

    pub fn read(r: *std.Io.Reader) !MissionView {
        const number = try readMissionNumber(r);
        const pilot_slots = try r.takeByte();
        const lead = try r.takeByte();
        const travel: Travel = @bitCast(try r.takeByte());
        if (pilot_slots == 0 or pilot_slots > cooperative_slots or (lead >= pilot_slots and lead != slots) or travel.reserved != 0)
            return error.InvalidMissionView;
        var mission: MissionView = .{ .number = number, .pilot_slots = pilot_slots, .lead = if (lead == slots) null else lead, .travel = travel };
        for (&mission.objectives) |*objective| objective.* = try r.takeEnum(ObjectivesDisplay.Status, .little);
        mission.rating = try r.takeEnum(engine.vm.Variables.Outcome, .little);
        mission.guide = try .read(r);
        const ending = try r.takeByte();
        if (ending > @backingInt(engine.game.main.Ending.ejecting)) return error.InvalidMissionView;
        mission.ending = @fromBackingInt(ending);
        mission.ending_scene = try r.takeEnum(engine.game.players.EndingScene, .little);
        mission.kills = try r.takeInt(u16, .little);
        mission.rescues = try r.takeByte();
        if (mission.rescues > engine.game.gameflow.allowed_rescues + 1) return error.InvalidMissionView;
        const flags = try r.takeByte();
        if (flags > 0b1111) return error.InvalidMissionView;
        mission.landed = flags & 1 != 0;
        mission.objectives_met = flags & 2 != 0;
        mission.reliant_alive = flags & 4 != 0;
        mission.second_part = flags & 8 != 0;
        mission.nebula = try r.takeByte();
        if (mission.nebula >= engine.game.nebula.nebulae.len) return error.InvalidMissionView;
        switch (try r.takeByte()) {
            0 => {},
            1 => {
                const position = try wire.readPosition(r);
                var angles: Facing = undefined;
                for (&angles) |*angle| angle.* = try r.takeInt(i16, .little);
                const bars = try wire.readFloat(r);
                if (bars < 0 or bars > engine.game.camera.letterbox) return error.InvalidMissionView;
                mission.director = .{ .position = position, .angles = angles, .bars = bars };
            },
            else => return error.InvalidMissionView,
        }
        return mission;
    }
};

test "private campaign endings survive the mission view packet" {
    const Scene = engine.game.players.EndingScene;
    for (std.enums.values(Scene)) |ending_scene| {
        const view: MissionView = .{ .number = 1, .pilot_slots = 4, .lead = 1, .ending_scene = ending_scene };
        var buffer: [MissionView.capacity]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try view.write(&writer);
        var reader: std.Io.Reader = .fixed(writer.buffered());
        const read = try MissionView.read(&reader);
        try std.testing.expectEqual(ending_scene, read.ending_scene);
    }
}

fn writeObjectRef(w: *std.Io.Writer, ref: ?engine.game.gameobj.ObjectRef) !void {
    try w.writeInt(u16, if (ref) |object| object.slot else engine.game.gameobj.max_objects, .little);
    if (ref) |object| try w.writeInt(u32, object.reuse, .little);
}

fn readObjectRef(r: *std.Io.Reader) !?engine.game.gameobj.ObjectRef {
    const slot = try r.takeInt(u16, .little);
    if (slot == engine.game.gameobj.max_objects) return null;
    if (slot > engine.game.gameobj.max_objects) return error.InvalidObjectRef;
    return .{ .slot = slot, .reuse = try r.takeInt(u32, .little) };
}

const radio = engine.game.radio;
pub const CampaignLine = struct {
    tick: i32,
    line: radio.RoutedLine,

    pub fn write(line: *const CampaignLine, w: *std.Io.Writer) !void {
        const flags: u32 = @bitCast(line.line.flags);
        if (flags > 15 or @backingInt(line.line.mode) > @backingInt(radio.Mode.if_idle)) return error.InvalidCampaignLine;
        try w.writeInt(i32, line.tick, .little);
        try w.writeInt(i32, line.line.expiry, .little);
        try w.writeInt(u16, line.line.name orelse 0xffff, .little);
        try w.writeByte(@intCast(flags));
        try w.writeByte(@intCast(@backingInt(line.line.mode)));
        switch (line.line.speaker) {
            .ship => |ship| {
                try writeObjectRef(w, ship.object);
                try w.writeInt(u16, @backingInt(ship.side), .little);
            },
            .other => |code| {
                try writeObjectRef(w, null);
                try w.writeInt(i32, code, .little);
            },
        }
        for ([_]*const radio.LineName{ &line.line.speech, &line.line.film }) |name| {
            const text = std.mem.sliceTo(name, 0);
            try w.writeByte(@intCast(text.len));
            try w.writeAll(text);
        }
    }

    pub fn read(r: *std.Io.Reader) !CampaignLine {
        const tick = try r.takeInt(i32, .little);
        const expiry = try r.takeInt(i32, .little);
        const name = try r.takeInt(u16, .little);
        const flags = try r.takeByte();
        const mode = try r.takeByte();
        if (tick < 0 or flags > 15 or mode > @backingInt(radio.Mode.if_idle)) return error.InvalidCampaignLine;
        const speaker: radio.Speaker = if (try readObjectRef(r)) |ref|
            .{ .ship = .{ .object = ref, .side = try r.takeEnum(engine.game.gameobj.Side(u16), .little) } }
        else
            .{ .other = try r.takeInt(i32, .little) };
        return .{ .tick = tick, .line = .{
            .expiry = expiry,
            .name = if (name == 0xffff) null else name,
            .flags = @bitCast(@as(u32, flags)),
            .mode = @fromBackingInt(mode),
            .speaker = speaker,
            .speech = try readName(r),
            .film = try readName(r),
        } };
    }

    fn readName(r: *std.Io.Reader) !radio.LineName {
        var name: radio.LineName = @splat(0);
        const len = try r.takeByte();
        if (len >= name.len) return error.InvalidCampaignLine;
        const bytes = name[0..len];
        try r.readSliceAll(bytes);
        if (bytes.len == 0) return name;
        for (bytes) |byte| switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', ' ', '.', '\\', '/' => {},
            else => return error.InvalidCampaignLine,
        };
        var parts = std.mem.splitAny(u8, bytes, "\\/");
        while (parts.next()) |part| {
            if (part.len == 0 or part[0] == '.') return error.InvalidCampaignLine;
        }
        return name;
    }
};

pub const CrewRequest = struct { view_tick: u32, reuse: u32 };

pub fn campaignNumber(number: u16) bool {
    return number >= engine.game.gameflow.first_mission and number <= engine.game.gameflow.last_mission;
}

pub const Crew = engine.game.interface.Connection.DebriefCrew;

pub const Debrief = struct {
    tick: u32,
    crew: Crew,

    pub fn write(state: Debrief, w: *std.Io.Writer) !void {
        try w.writeInt(u32, state.tick, .little);
        try w.writeByte(state.crew.present.mask);
        try w.writeByte(state.crew.eligible.mask);
        try w.writeByte(state.crew.ready.mask);
        try w.writeByte(state.crew.lead);
    }

    pub fn read(r: *std.Io.Reader) !Debrief {
        const tick = try r.takeInt(u32, .little);
        const present = try r.takeByte();
        const eligible = try r.takeByte();
        const ready = try r.takeByte();
        const lead = try r.takeByte();
        if (tick == 0 or (present | eligible | ready) >= 1 << Crew.size or lead >= Crew.size)
            return error.InvalidDebrief;
        const crew: Crew = .{
            .present = .{ .mask = @intCast(present) },
            .eligible = .{ .mask = @intCast(eligible) },
            .ready = .{ .mask = @intCast(ready) },
            .lead = lead,
        };
        if (!crew.present.isSet(lead) or !crew.eligible.subsetOf(crew.present) or !crew.ready.subsetOf(crew.present))
            return error.InvalidDebrief;
        if (crew.eligible.count() != 0 and !crew.eligible.isSet(lead)) return error.InvalidDebrief;
        return .{ .tick = tick, .crew = crew };
    }
};

pub const DebriefChoice = struct { tick: u32, action: Crew.Choice };
pub const NextMission = struct { after: u32, number: u16, second_part: bool = false };

pub fn readMissionNumber(r: *std.Io.Reader) !u16 {
    const number = try r.takeInt(u16, .little);
    return if (campaignNumber(number)) number else error.InvalidMission;
}
