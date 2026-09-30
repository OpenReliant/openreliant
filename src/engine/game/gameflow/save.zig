//! The saved games (`gameflow.cpp`): `game_save` (`0x00475650`) writes the campaign as it stands to
//! an IFF file in the game's `saves` folder, and `game_load` (`0x00475430`) reads it back
//! ([docs/formats/save.md](../../../../docs/formats/save.md)). The file is a form of type `SAVE`
//! holding the save's name, then a chunk for each of the game's records it keeps, each record's
//! bytes as the game holds them in memory (`Save`). `Game` takes those records from the campaign as
//! OpenReliant holds it, and puts them back, and `Folder` reads and writes the files.
//!
//! **Unverified:** that `game_load` is this file's: it lies just before `game_save`, the file's
//! known code.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const files = @import("../../files.zig");
const input = @import("../../input.zig");
const loadout = @import("../../interface/loadout/loadout.zig");
const loadout_tables = @import("../../interface/loadout/tables.zig");
const collision = @import("../collision.zig");
const gameflow = @import("../gameflow.zig");
const iff = @import("../iff.zig");
const pilot_roster = @import("../interface/pilot_roster.zig");
const winmain = @import("../winmain.zig");

/// The saved games' form type.
pub const form_type = "SAVE";

/// The name's chunk, which `game_save` writes first.
pub const name_id = "NAME";

/// The saves' folder, in the game's.
pub const folder_name = "saves";

/// The slots the saved games screen lists, from the autosave's on (`saved_games_scan`,
/// `0x004315C0`).
pub const slots = 100;

/// The autosave's slot, which each mission's end writes (`mission_end_record`, `0x00475C28`), and
/// the restart point's, which `WinMain` writes as each attempt at a mission begins (`restart_save`,
/// `0x00475D20`), with its name.
pub const autosave_slot = 0;
pub const restart_slot = 100;
pub const restart_name = "restart";

/// The file of saved game `slot` of the pilot `call_sign` (`0x004756FD`, `0x004E86E4`), in the
/// game's folder: `saves\<call sign>GAME<slot>.IFF`, the slot in two digits at least.
pub fn fileName(buffer: []u8, call_sign: []const u8, slot: u8) std.fmt.BufPrintError![]const u8 {
    return std.fmt.bufPrint(buffer, folder_name ++ "\\{s}GAME{d:0>2}.IFF", .{ call_sign, slot });
}

/// The campaign's missions, which each keep a record.
pub const missions = gameflow.last_mission;

/// The pilot's medals and ribbons, each kept whether it is awarded.
pub const medals = 6;
pub const ribbons = 6;

comptime {
    assert(std.enums.values(gameflow.Medal).len == medals);
}

/// `MISS`: the campaign as it stands, the `0x17C` bytes from `mission_number` (`0x00562DC8`).
pub const Miss = extern struct {
    /// The mission the campaign is at, the next to fly (`mission_number`).
    mission: i32,
    /// The pilot's call sign, up to its terminator (`call_sign`, `0x00562DCC`).
    call_sign: [32]u8,
    /// The pilot's rank, 0 to 8 (`pilot_rank`, `0x00562DEC`).
    rank: i32,
    /// The campaign's tier (`campaign_tier`, `0x00562DF0`).
    tier: i32,
    /// The pilot's kills over the campaign (`skull_count`, `0x00562DF4`).
    kills: i32,
    /// The local player's deaths in a multiplayer mission (`mp_deaths`, `0x00562DF8`), which
    /// `deaths_add` (`0x004B1580`) counts only there.
    mp_deaths: i32,
    /// The pilot's medals, 1 where awarded (`pilot_medals`, `0x00562DFC`).
    medals: [medals]i32,
    /// The pilot's ribbons, 1 where awarded (`pilot_ribbons`, `0x00562E14`).
    ribbons: [ribbons]i32,
    /// Each mission's rating, by its number less one, -1 for none (`mission_ratings`,
    /// `0x00562E2C`).
    ratings: [missions]i16,
    /// The pilot's kills in each mission, by its number, missions 0 to 27 (`mission_kills`,
    /// `0x00562E64`; `kills_add`, `0x004B1534`).
    mission_kills: [missions]i16,
    /// The campaign's pickups where a nanny ship picked the pilot up in each mission, by its number
    /// less one, 0 where none did (`mission_pickups`, `0x00562E9C`).
    mission_pickups: [missions]i16,
    /// The times a nanny ship has picked the pilot up (`pickups`, `0x00562ED4`).
    pickups: i16,
    /// The rank each mission's end promoted the pilot to, by its number less one, 0 for none
    /// (`mission_promotions`, `0x00562ED6`).
    promotions: [missions]i16,
    /// Two bytes nothing uses (`0x00562F0E`).
    _unused_146: [2]u8,
    /// The seed of the ITAC's KILLBOARD (`killboard_seed`, `0x00562F10`).
    killboard_seed: i32,
    /// The game's difficulty (`difficulty`, `0x00562F14`).
    difficulty: collision.Difficulty,
    /// Whether the pilot is female (`pilot_female`, `0x00562F16`).
    female: i16,
    /// The loadout's saved ship (`campaign_saved_ship`, `0x00562F18`).
    saved_ship: i16,
    /// The loadout's saved racks, a missile each or -1 for none (`campaign_saved_racks`,
    /// `0x00562F1A`).
    saved_racks: [racks]i16,
    /// Two bytes nothing uses (`0x00562F42`).
    _unused_17a: [2]u8,

    /// The racks of the loadout's saved ship.
    pub const racks = 20;

    /// The mission, the pilot's rank and the campaign's tier as OpenReliant takes them: the
    /// nearest each can be.
    ///
    /// **Fix:** a rank or a tier past those the game has is taken as the nearest it has, where the
    /// game reads past its tables with it.
    pub fn missionNumber(miss: Miss) u16 {
        return std.math.lossyCast(u16, miss.mission);
    }

    pub fn pilotRank(miss: Miss) gameflow.Rank {
        return gameflow.rankOf(miss.rank);
    }

    pub fn campaignTier(miss: Miss) u2 {
        return std.math.lossyCast(u2, miss.tier);
    }

    comptime {
        assert(@offsetOf(Miss, "rank") == 0x24);
        assert(@offsetOf(Miss, "medals") == 0x34);
        assert(@offsetOf(Miss, "ratings") == 0x64);
        assert(@offsetOf(Miss, "pickups") == 0x10C);
        assert(@offsetOf(Miss, "promotions") == 0x10E);
        assert(@offsetOf(Miss, "killboard_seed") == 0x148);
        assert(@offsetOf(Miss, "difficulty") == 0x14C);
        assert(@offsetOf(Miss, "saved_racks") == 0x152);
        assert(@sizeOf(Miss) == 0x17C);
    }
};

/// `VERS`: the saves' version (`save_version`, `0x00562F44`), which `game_save` sets to 1
/// (`0x0047589F`). `game_load` never checks it.
pub const version: i32 = 1;

/// `VARS`: the game's variables the campaign keeps (`saved_variables`, `0x00562F78`), those of
/// `kept_variables` in order, then five words nothing writes.
pub const Vars = [30]i32;

/// The game's variables a saved game keeps, by number, in the order `VARS` holds them
/// (`game_save`, `0x004757A0`; `game_load`, `0x004754DC`).
pub const kept_variables = [_]u8{ 16, 17, 18, 19, 20, 21, 5, 22, 23, 6, 7, 8, 11, 12, 13, 24, 25, 26, 27, 29, 30, 31, 32, 34, 36 };

/// The game's variables `game_load` clears before it puts back those the save keeps
/// (`0x004754DA`).
const cleared_variables = 32;

comptime {
    assert(kept_variables.len <= @typeInfo(Vars).array.len);
}

/// `PILO`: the first record of the pool of pilots that replace the wingmen who die (`pilot_pool`,
/// `0x005047D0`, 65 records): a pilot, by the pilot stats' number, and whether the pilot is free,
/// in the wing or dead. **Unverified:** that the whole pool was meant, `0x104` bytes; the game
/// saves the first record alone, and sends it alone to the other players too (`0x004BA338`).
pub const Replacement = extern struct {
    pilot: i16,
    status: Status,
    _unused: u8 = 0,

    pub const Status = enum(u8) {
        dead = 0,
        in_wing = 1,
        free = 2,
        _,
    };

    comptime {
        assert(@sizeOf(Replacement) == 4);
    }
};

/// `ALPH`: the pilots of the player's wing, Alpha 1 to 6 (`alpha_pilots`, `0x0058A958`): -1 for the
/// player, then the five wingmen's, by the pilot stats' number.
pub const Wing = [6]i16;

/// The name a saved game shows, which `NAME` holds with its terminator: 47 characters at most, as
/// the saved games' list keeps 48 bytes of each, its terminator too (`saved_games_names`,
/// `0x0051EE70`).
pub const Name = pilot_roster.Text(name_room);
pub const name_room = 47;

/// What a saved game holds: its name, and the records its chunks keep.
pub const Save = struct {
    name: Name = .{},
    miss: Miss,
    version: i32 = version,
    vars: Vars,
    pilo: Replacement,
    alph: Wing,
};

/// The chunks after the name, in the order `game_save` writes them, each with the field of
/// `Save` whose bytes it holds (`save_chunks`, `0x00500A20`: an id, an address and a size a chunk).
const chunks = [_]struct { id: iff.Id, field: []const u8 }{
    .{ .id = "MISS".*, .field = "miss" },
    .{ .id = "VERS".*, .field = "version" },
    .{ .id = "VARS".*, .field = "vars" },
    .{ .id = "PILO".*, .field = "pilo" },
    .{ .id = "ALPH".*, .field = "alph" },
};

/// `game_save`'s file (`0x00475650`): a form of type `SAVE` holding `save`'s name with its
/// terminator, then its records' chunks (`chunks`). The form's length, written as a zero first, is
/// set once the chunks are written (`0x004758E4`).
pub fn write(gpa: std.mem.Allocator, save: *const Save) std.mem.Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    writeFile(&out.writer, save) catch return error.OutOfMemory;
    const bytes = out.written();
    std.mem.writeInt(u32, bytes[4..8], @intCast(bytes.len - @sizeOf(iff.ChunkHeader)), .big);
    return out.toOwnedSlice();
}

fn writeFile(w: *std.Io.Writer, save: *const Save) std.Io.Writer.Error!void {
    try writeDword(w, iff.form_id.*);
    try w.writeInt(u32, 0, .big);
    try writeDword(w, form_type.*);
    var name: [name_room + 1]u8 = undefined;
    @memcpy(name[0..save.name.len], save.name.slice());
    name[save.name.len] = 0;
    try writeChunk(w, name_id, name[0 .. save.name.len + 1]);
    inline for (chunks) |chunk| try writeChunk(w, &chunk.id, std.mem.asBytes(&@field(save, chunk.field)));
}

/// `iff_write_dword` (`0x004759D0`) of an id, which it writes as it lies in memory.
fn writeDword(w: *std.Io.Writer, id: iff.Id) std.Io.Writer.Error!void {
    try w.writeAll(&id);
}

/// `iff_write_chunk` (`0x00475930`): `id`, the length of `body` big-endian, `body`, and after an odd
/// length a zero byte (`iff_write_byte`, `0x00475A20`), which the length leaves out.
fn writeChunk(w: *std.Io.Writer, id: *const iff.Id, body: []const u8) std.Io.Writer.Error!void {
    try w.writeStruct(iff.ChunkHeader{ .id = id.*, .size = .of(@intCast(body.len)) }, .little);
    try w.writeAll(body);
    if (body.len % 2 == 1) try w.writeByte(0);
}

/// `game_load`'s reading (`0x00475430`): enters the `SAVE` form, then reads each record's chunk
/// into `save`, a chunk the file lacks leaving its record as it was. Searching each from the form's
/// first chunk, the first of an id counts, and chunks the game doesn't know are passed over. The
/// name is read as the saved games' list reads it (`saved_games_scan`, `0x004315C0`). False where
/// the file holds no `SAVE` form, `save` left as it was.
///
/// **Fix:** the game reads each chunk by the length the file gives, so that a longer one runs past
/// its record into what follows it in memory; OpenReliant reads no more than its record holds, and
/// a shorter one leaves the rest as it was. Where the file holds no `SAVE` form, the game searches
/// the file's own chunks for the records instead, and goes on to put back the game's variables
/// from whatever `saved_variables` held. The saved games' list reads each name up to its
/// terminator whatever its length (`iff_read_string`, `0x00490D50`), into the next one's place;
/// OpenReliant keeps what fits.
pub fn read(bytes: []const u8, save: *Save) bool {
    var reader: iff.Reader = .init(bytes);
    if (!reader.enter(form_type)) return false;
    if (reader.chunk(name_id)) |name| save.name.set(std.mem.sliceTo(name, 0));
    inline for (chunks) |chunk| if (reader.chunk(&chunk.id)) |body| {
        const into = std.mem.asBytes(&@field(save, chunk.field));
        const len = @min(body.len, into.len);
        @memcpy(into[0..len], body[0..len]);
    };
    return true;
}

/// Where OpenReliant keeps what a saved game holds, which the game keeps in the globals its
/// records cover: the campaign, the pilot's kills and rank, the campaign's tier, the pilot the
/// roster set, and the loadout's saved choice.
pub const Game = struct {
    campaign: *gameflow.Campaign,
    player: *input.Player,
    tier: *u2,
    pilot: *pilot_roster.Pilot,
    saved: *loadout.Saved,

    /// `campaign_new`'s clearing of the pilot's tallies as START GAME begins a campaign
    /// (`0x004751DE` to `0x00475203`): the pilot's rank, the campaign's tier and the pilot's kills
    /// 0, and the loadout's saved choice the Predator with no missiles.
    pub fn clearPilot(game: Game) void {
        game.player.rank = 0;
        game.tier.* = 0;
        game.player.kills = .{};
        game.saved.* = .{};
    }

    /// What `game_save` writes of the game (`0x0047579B` to `0x004758E2`), under `name`: the
    /// records as they stand, `VERS` 1, and the variables the campaign keeps.
    pub fn capture(game: Game, name: []const u8) Save {
        const campaign = game.campaign;
        var save: Save = .{
            .miss = std.mem.zeroes(Miss),
            .vars = @splat(0),
            .pilo = campaign.first_replacement,
            .alph = campaign.wing,
        };
        save.name.set(name);
        const miss = &save.miss;
        miss.mission = campaign.mission;
        const call_sign = game.pilot.call_sign.slice();
        @memcpy(miss.call_sign[0..call_sign.len], call_sign);
        miss.rank = game.player.rank;
        miss.tier = game.tier.*;
        miss.kills = game.player.kills.count;
        miss.mp_deaths = campaign.mp_deaths;
        for (&miss.medals, 1..) |*flag, medal| flag.* = @intFromBool(campaign.medals.contains(@enumFromInt(medal)));
        for (&miss.ribbons, 0..) |*flag, ribbon| flag.* = @intFromBool(campaign.ribbons.isSet(ribbon));
        for (campaign.records, 0..) |record, index| {
            miss.ratings[index] = if (record.rating) |rating| @truncate(@intFromEnum(rating)) else no_rating;
            miss.mission_pickups[index] = record.pickups;
            miss.promotions[index] = record.promotion orelse 0;
            if (index + 1 < missions) miss.mission_kills[index + 1] = @bitCast(record.kills);
        }
        miss.pickups = campaign.pickups;
        miss.killboard_seed = campaign.killboard_seed;
        miss.difficulty = game.pilot.difficulty;
        miss.female = @intFromBool(game.pilot.female);
        miss.saved_ship = game.saved.ship;
        for (&miss.saved_racks, game.saved.racks) |*rack, missile| rack.* = if (missile) |kind| @intFromEnum(kind) else no_missile;
        for (kept_variables, save.vars[0..kept_variables.len]) |number, *value| value.* = @bitCast(campaign.variables.slot(number).*);
        return save;
    }

    /// What `game_load` puts back of `save` (`0x00475488` to `0x004755F0`): each record, then the
    /// game's variables 0 to 31 cleared and those the save keeps put back. Variables 33, 35 and
    /// from 37 on keep what they held.
    ///
    /// **Fix:** a ship or a missile past those the game has is taken as the Predator, or none,
    /// where the game reads past its tables with it; so are a rank and a tier (`Miss.pilotRank`).
    pub fn apply(game: Game, save: *const Save) void {
        const campaign = game.campaign;
        const miss = &save.miss;
        campaign.mission = miss.missionNumber();
        game.pilot.call_sign.set(std.mem.sliceTo(&miss.call_sign, 0));
        game.player.rank = miss.pilotRank();
        game.tier.* = miss.campaignTier();
        game.player.kills.count = miss.kills;
        game.player.kills.kept = miss.kills;
        campaign.mp_deaths = miss.mp_deaths;
        campaign.medals = .initEmpty();
        for (miss.medals, 1..) |flag, medal| if (flag != 0) campaign.medals.insert(@enumFromInt(medal));
        campaign.ribbons = .initEmpty();
        for (miss.ribbons, 0..) |flag, ribbon| campaign.ribbons.setValue(ribbon, flag != 0);
        for (&campaign.records, 0..) |*record, index| record.* = .{
            .rating = if (miss.ratings[index] == no_rating) null else @enumFromInt(miss.ratings[index]),
            .kills = if (index + 1 < missions) @bitCast(miss.mission_kills[index + 1]) else 0,
            .pickups = std.math.lossyCast(u8, miss.mission_pickups[index]),
            .promotion = if (miss.promotions[index] == 0) null else gameflow.rankOf(miss.promotions[index]),
        };
        campaign.pickups = std.math.lossyCast(u8, miss.pickups);
        campaign.killboard_seed = miss.killboard_seed;
        game.pilot.difficulty = miss.difficulty;
        game.pilot.female = miss.female != 0;
        game.saved.ship = if (miss.saved_ship >= 0 and miss.saved_ship < loadout_tables.ship_count) @intCast(miss.saved_ship) else (loadout.Saved{}).ship;
        for (&game.saved.racks, miss.saved_racks) |*rack, missile| rack.* = if (std.math.cast(u32, missile)) |id| loadout_tables.Missile.ofId(id) else null;
        campaign.first_replacement = save.pilo;
        campaign.wing = save.alph;
        const variables = &campaign.variables;
        for (0..cleared_variables) |number| variables.slot(@intCast(number)).* = 0;
        for (kept_variables, save.vars[0..kept_variables.len]) |number, value| variables.slot(number).* = @bitCast(value);
    }
};

/// A mission's rating where it has none, and a rack with no missile.
const no_rating = -1;
const no_missile = -1;

/// The autosave's name (`0x00475BF6` to `0x00475C1A`): the game's string `AUTOSAVE: Mission `
/// (`autosave_string`) and the number the player sees for `mission`, the mission the campaign has
/// moved on to (`gameflow.displayNumber`).
pub fn autosaveName(buffer: []u8, prefix: []const u8, mission: u16) std.fmt.BufPrintError![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}{d}", .{ prefix, gameflow.displayNumber(mission) });
}

pub const autosave_string = 0x18A;

/// `mission_end_record`'s save (`0x00475BF6` to `0x00475C28`), once a mission's end has moved the
/// campaign on: the game as saved game 0 of the pilot, named for the mission it has moved on to,
/// `prefix` being the game's string `autosave_string`.
pub fn autosave(game: Game, folder: Folder, gpa: std.mem.Allocator, prefix: []const u8) (Folder.Error || std.mem.Allocator.Error)!void {
    var buffer: [name_room]u8 = undefined;
    const name = autosaveName(&buffer, prefix, game.campaign.mission) catch prefix;
    const saved = game.capture(name);
    try folder.store(gpa, game.pilot.call_sign.slice(), autosave_slot, &saved);
}

/// `restart_load` (`0x00475D30`) of the restart point `point`, `restart_save`'s save of the game as
/// an attempt at a mission began: the game put back as it was, but for the loadout's choice, which
/// it keeps as it stands (`restart_choice_keep`, `0x00475D70`; `restart_choice_put_back`,
/// `0x00475DA0`).
pub fn restartLoad(game: Game, point: *const Save) void {
    const kept = game.saved.*;
    game.apply(point);
    game.saved.* = kept;
}

/// The saved games in the game's folder (`install_directory`, which each of `game_save`,
/// `game_load` and the saved games screen make the working folder first): each found whatever the
/// case of its name, as the game's reader upper-cases every name it opens (`bin_file_open`,
/// `0x0045E6B0`) on a system that finds a file whatever its case.
pub const Folder = struct {
    io: Io,
    dir: Io.Dir,

    pub const Error = error{ BadCallSign, NoSpaceLeft } || Io.Dir.WriteFileError || Io.Dir.CreateDirPathError;

    /// The bytes of saved game `slot` of `call_sign`; null where there is none, or it can't be
    /// read.
    pub fn file(folder: Folder, gpa: std.mem.Allocator, call_sign: []const u8, slot: u8) ?[]u8 {
        var name: [files.max_path]u8 = undefined;
        const path = fileName(&name, call_sign, slot) catch return null;
        return files.readFile(folder.io, gpa, folder.dir, path, .limited(most_read)) catch null;
    }

    /// Writes `bytes` as saved game `slot` of `call_sign`: over the file found whatever the case of
    /// its name, else under the name `game_save` gives it.
    ///
    /// **Improvement:** OpenReliant makes the `saves` folder where the game's folder lacks it,
    /// which the game leaves to its installer, failing to save without it.
    ///
    /// **Fix:** a call sign with a character a file's name can't hold saves nothing, where the game
    /// would take a separator in it for a folder's. The game checks the disk by writing `0x1400`
    /// bytes to `saves\test.bin` first (`0x0047568E`), then writes the save without checking it;
    /// OpenReliant checks the save's own write.
    pub fn put(folder: Folder, call_sign: []const u8, slot: u8, bytes: []const u8) Error!void {
        if (std.mem.indexOfAny(u8, call_sign, winmain.Typed.file_name_refused) != null) return error.BadCallSign;
        var spelled: [files.max_path]u8 = undefined;
        const saves = files.find(folder.io, folder.dir, folder_name, &spelled) orelse made: {
            try folder.dir.createDirPath(folder.io, folder_name);
            break :made folder_name;
        };
        var name: [files.max_path]u8 = undefined;
        const path = try fileName(&name, call_sign, slot);
        var found: [files.max_path]u8 = undefined;
        var joined: [files.max_path]u8 = undefined;
        const written = files.find(folder.io, folder.dir, path, &found) orelse
            try std.fmt.bufPrint(&joined, "{s}/{s}", .{ saves, path[folder_name.len + 1 ..] });
        try folder.dir.writeFile(folder.io, .{ .sub_path = written, .data = bytes });
    }

    /// Removes saved game `slot` of `call_sign`, where there is one.
    pub fn remove(folder: Folder, call_sign: []const u8, slot: u8) void {
        var name: [files.max_path]u8 = undefined;
        const path = fileName(&name, call_sign, slot) catch return;
        var found: [files.max_path]u8 = undefined;
        const found_path = files.find(folder.io, folder.dir, path, &found) orelse return;
        folder.dir.deleteFile(folder.io, found_path) catch {};
    }

    /// When saved game `slot` of `call_sign` was last written, in nanoseconds from 1970 in UTC;
    /// null where there is none.
    pub fn modified(folder: Folder, call_sign: []const u8, slot: u8) ?i96 {
        var name: [files.max_path]u8 = undefined;
        const path = fileName(&name, call_sign, slot) catch return null;
        var found: [files.max_path]u8 = undefined;
        const found_path = files.find(folder.io, folder.dir, path, &found) orelse return null;
        const stat = folder.dir.statFile(folder.io, found_path, .{}) catch return null;
        return stat.mtime.nanoseconds;
    }

    /// Reads saved game `slot` of `call_sign` into `save`; false where there is none, or it holds
    /// no `SAVE` form.
    pub fn load(folder: Folder, gpa: std.mem.Allocator, call_sign: []const u8, slot: u8, save: *Save) bool {
        const bytes = folder.file(gpa, call_sign, slot) orelse return false;
        defer gpa.free(bytes);
        return read(bytes, save);
    }

    /// Writes `save` as saved game `slot` of `call_sign` (`game_save`).
    pub fn store(folder: Folder, gpa: std.mem.Allocator, call_sign: []const u8, slot: u8, save: *const Save) (Error || std.mem.Allocator.Error)!void {
        const bytes = try write(gpa, save);
        defer gpa.free(bytes);
        try folder.put(call_sign, slot, bytes);
    }

    /// The most OpenReliant reads of a saved game, far past the game's.
    const most_read = 1 << 16;
};

/// A save of records all zero, for filling from a file.
pub fn empty() Save {
    return .{ .miss = std.mem.zeroes(Miss), .vars = @splat(0), .pilo = .{ .pilot = 0, .status = .dead }, .alph = @splat(0) };
}

/// A save for the tests: a name, and records as a new campaign's.
fn testSave(name: []const u8) Save {
    var save = empty();
    save.name.set(name);
    save.miss.mission = 2;
    @memcpy(save.miss.call_sign[0..2], "RA");
    save.miss.ratings = @splat(-1);
    save.miss.saved_racks = @splat(-1);
    save.vars[0] = 1;
    save.pilo = .{ .pilot = 0x77, .status = .free };
    save.alph = .{ -1, 0x55, 0x6C, 0x56, 0xAC, 7 };
    return save;
}

test write {
    const gpa = std.testing.allocator;
    const save = testSave("Mission02");
    const bytes = try write(gpa, &save);
    defer gpa.free(bytes);
    // The form's header, then the name with its terminator, and each record's chunk: 590 bytes, as
    // the game writes a save.
    try std.testing.expectEqual(590, bytes.len);
    try expectAt(bytes, 0, "FORM\x00\x00\x02\x46SAVENAME\x00\x00\x00\x0AMission02\x00MISS\x00\x00\x01\x7C\x02\x00\x00\x00RA");
    try expectAt(bytes, 0x1A2, "VERS\x00\x00\x00\x04\x01\x00\x00\x00VARS\x00\x00\x00\x78\x01");
    try expectAt(bytes, 0x22E, "PILO\x00\x00\x00\x04\x77\x00\x02\x00ALPH\x00\x00\x00\x0C\xFF\xFF\x55\x00");

    // A name of odd length takes a zero byte after it, which its length leaves out and the form's
    // counts.
    const odd = testSave("AUTOSAVE: Mission 10");
    const padded = try write(gpa, &odd);
    defer gpa.free(padded);
    try std.testing.expectEqual(bytes.len + 12, padded.len);
    try expectAt(padded, 12, "NAME\x00\x00\x00\x15AUTOSAVE: Mission 10\x00\x00MISS");
    try std.testing.expectEqual(padded.len - 8, std.mem.readInt(u32, padded[4..8], .big));
}

/// Checks that `bytes` hold `expected` from `at` on.
fn expectAt(bytes: []const u8, at: usize, expected: []const u8) !void {
    try std.testing.expectEqualSlices(u8, expected, bytes[at..][0..expected.len]);
}

test read {
    const gpa = std.testing.allocator;
    const save = testSave("AUTOSAVE: Mission 10");
    const bytes = try write(gpa, &save);
    defer gpa.free(bytes);

    // What the game writes comes back as it was.
    var back = testSave("");
    back.miss.mission = 9;
    back.alph = @splat(0);
    try std.testing.expect(read(bytes, &back));
    try std.testing.expectEqualStrings("AUTOSAVE: Mission 10", back.name.slice());
    try std.testing.expectEqualDeep(save, back);

    // A record's chunk longer than its record fills the record alone, a shorter one leaves the rest
    // as it was, and a chunk missing leaves its record.
    const Chunk = iff.testing.chunk;
    const odd = comptime iff.testing.form(form_type, Chunk("NAME", "x\x00") ++ Chunk("PILO", "\x01\x02\x03\x04\x05\x06") ++ Chunk("ALPH", "\x07") ++ Chunk("PILO", "\x09\x09\x09\x09"));
    try std.testing.expect(read(odd, &back));
    try std.testing.expectEqualStrings("x", back.name.slice());
    try std.testing.expectEqual(Replacement{ .pilot = 0x0201, .status = @enumFromInt(3), ._unused = 4 }, back.pilo);
    try std.testing.expectEqual(Wing{ @bitCast(@as(u16, 0xFF07)), 0x55, 0x6C, 0x56, 0xAC, 7 }, back.alph);
    try std.testing.expectEqual(2, back.miss.mission);

    // Another form's file loads nothing.
    try std.testing.expect(!read(comptime iff.testing.form("LOAD", Chunk("PILO", "\x00\x00\x00\x00")), &back));
    try std.testing.expectEqual(0x0201, back.pilo.pilot);
}

test fileName {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("saves\\RAGAME01.IFF", try fileName(&buffer, "RA", 1));
    try std.testing.expectEqualStrings("saves\\ManiacGAME100.IFF", try fileName(&buffer, "Maniac", restart_slot));
}

test autosaveName {
    var buffer: [32]u8 = undefined;
    // Mission 14 is the twelfth the campaign flies.
    try std.testing.expectEqualStrings("AUTOSAVE: Mission 12", try autosaveName(&buffer, "AUTOSAVE: Mission ", 14));
}

/// A campaign under way, and the pilot flying it, for the tests.
const TestGame = struct {
    campaign: gameflow.Campaign = .begin(),
    player: input.Player = .{},
    tier: u2 = 0,
    pilot: pilot_roster.Pilot = .{},
    saved: loadout.Saved = .{},

    fn game(state: *TestGame) Game {
        return .{ .campaign = &state.campaign, .player = &state.player, .tier = &state.tier, .pilot = &state.pilot, .saved = &state.saved };
    }
};

test Game {
    var state: TestGame = .{};
    const campaign = &state.campaign;
    campaign.mission = 14;
    campaign.medals.insert(.black_eagle);
    campaign.ribbons.set(1);
    campaign.records[4] = .{ .rating = .success, .kills = 7, .pickups = 1, .promotion = 1 };
    campaign.records[13] = .{ .rating = .partial_failure, .kills = 3 };
    campaign.pickups = 1;
    campaign.wing[3] = -1;
    campaign.variables.slot(16).* = 0;
    campaign.variables.slot(36).* = 5;
    campaign.variables.slot(33).* = 9;
    campaign.variables.slot(2).* = 4;
    state.player.rank = 1;
    state.player.kills = .{ .count = 40, .kept = 40 };
    state.tier = 1;
    state.pilot.call_sign.set("Ace");
    state.pilot.female = true;
    state.pilot.difficulty = .hard;
    state.saved.ship = 3;
    state.saved.racks[2] = .havoc;

    const save = state.game().capture("Mission14");
    const miss = &save.miss;
    try std.testing.expectEqual(14, miss.mission);
    try std.testing.expectEqualStrings("Ace", std.mem.sliceTo(&miss.call_sign, 0));
    try std.testing.expectEqual(0, miss.call_sign[31]);
    try std.testing.expectEqual(40, miss.kills);
    try std.testing.expectEqual([medals]i32{ 0, 1, 0, 0, 0, 0 }, miss.medals);
    try std.testing.expectEqual([ribbons]i32{ 0, 1, 0, 0, 0, 0 }, miss.ribbons);
    // Each mission's record by its number less one, but its kills by its number.
    try std.testing.expectEqual(3, miss.ratings[4]);
    try std.testing.expectEqual(-1, miss.ratings[0]);
    try std.testing.expectEqual(7, miss.mission_kills[5]);
    try std.testing.expectEqual(3, miss.mission_kills[14]);
    try std.testing.expectEqual(0, miss.mission_kills[0]);
    try std.testing.expectEqual(1, miss.promotions[4]);
    try std.testing.expectEqual(.hard, miss.difficulty);
    try std.testing.expectEqual(1, miss.female);
    try std.testing.expectEqual(-1, miss.saved_racks[0]);
    try std.testing.expectEqual(@intFromEnum(loadout_tables.Missile.havoc), miss.saved_racks[2]);
    // The variables kept, in their order, and nothing after them.
    try std.testing.expectEqual(0, save.vars[0]);
    try std.testing.expectEqual(1, save.vars[6]);
    try std.testing.expectEqual(5, save.vars[24]);
    try std.testing.expectEqual(0, save.vars[25]);
    try std.testing.expectEqual(-1, save.alph[3]);

    // Put back into another game, the records return; the variables 0 to 31 not kept are
    // cleared, and 33 keeps what it held.
    var other: TestGame = .{};
    other.campaign.variables.slot(2).* = 8;
    other.campaign.variables.slot(33).* = 6;
    other.campaign.medals.insert(.silver);
    other.saved.racks[0] = .raptor;
    other.game().apply(&save);
    try std.testing.expectEqual(14, other.campaign.mission);
    try std.testing.expectEqualStrings("Ace", other.pilot.call_sign.slice());
    try std.testing.expect(other.pilot.female);
    try std.testing.expectEqual(.hard, other.pilot.difficulty);
    try std.testing.expectEqual(1, other.player.rank);
    try std.testing.expectEqual(input.Player.Kills{ .count = 40, .kept = 40 }, other.player.kills);
    try std.testing.expectEqual(1, other.tier);
    try std.testing.expect(!other.campaign.medals.contains(.silver) and other.campaign.medals.contains(.black_eagle));
    try std.testing.expectEqualDeep(campaign.records, other.campaign.records);
    try std.testing.expectEqual(1, other.campaign.pickups);
    try std.testing.expectEqual(3, other.saved.ship);
    try std.testing.expectEqual(null, other.saved.racks[0]);
    try std.testing.expectEqual(.havoc, other.saved.racks[2].?);
    try std.testing.expectEqual(0, other.campaign.variables.slot(2).*);
    try std.testing.expectEqual(6, other.campaign.variables.slot(33).*);
    try std.testing.expectEqual(5, other.campaign.variables.slot(36).*);
    try std.testing.expectEqual(0, other.campaign.variables.slot(16).*);
    try std.testing.expectEqual(1, other.campaign.variables.slot(17).*);
    try std.testing.expectEqual(campaign.wing, other.campaign.wing);
    // Written and read again, the same.
    try std.testing.expectEqualDeep(save, other.game().capture("Mission14"));

    // A new campaign clears the pilot's tallies.
    var cleared = other;
    cleared.game().clearPilot();
    try std.testing.expectEqual(0, cleared.player.rank);
    try std.testing.expectEqual(0, cleared.player.kills.count);
    try std.testing.expectEqual(0, cleared.tier);
    try std.testing.expectEqual(null, cleared.saved.racks[2]);

    // A rank, a ship and a missile past the game's are the nearest it has, or none.
    var odd = save;
    odd.miss.rank = 40;
    odd.miss.saved_ship = 30;
    odd.miss.saved_racks[1] = 25;
    other.game().apply(&odd);
    try std.testing.expectEqual(8, other.player.rank);
    try std.testing.expectEqual((loadout.Saved{}).ship, other.saved.ship);
    try std.testing.expectEqual(null, other.saved.racks[1]);
}

test autosave {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const folder: Folder = .{ .io = std.testing.io, .dir = tmp.dir };
    var state: TestGame = .{};
    state.pilot.call_sign.set("Ace");
    state.campaign.mission = 14;
    try autosave(state.game(), folder, gpa, "AUTOSAVE: Mission ");
    // Saved game 0 of the pilot, named for the mission the campaign has moved on to.
    var back = empty();
    try std.testing.expect(folder.load(gpa, "Ace", autosave_slot, &back));
    try std.testing.expectEqualStrings("AUTOSAVE: Mission 12", back.name.slice());
    try std.testing.expectEqual(14, back.miss.mission);
}

test restartLoad {
    var state: TestGame = .{};
    state.campaign.mission = 5;
    state.player.kills = .{ .count = 12, .kept = 12 };
    const point = state.game().capture(restart_name);
    // The attempt changes the game and the loadout's choice; the restart point puts back the game
    // but keeps the choice.
    state.campaign.mission = 6;
    state.player.kills.count = 20;
    state.saved.ship = 3;
    state.saved.racks[0] = .raptor;
    restartLoad(state.game(), &point);
    try std.testing.expectEqual(5, state.campaign.mission);
    try std.testing.expectEqual(12, state.player.kills.count);
    try std.testing.expectEqual(3, state.saved.ship);
    try std.testing.expectEqual(.raptor, state.saved.racks[0].?);
}

test Folder {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const folder: Folder = .{ .io = std.testing.io, .dir = tmp.dir };
    // Without the saves folder there is no save, and the first write makes it.
    try std.testing.expectEqual(null, folder.file(gpa, "Ace", 1));
    try std.testing.expectEqual(null, folder.modified("Ace", 1));
    var save = testSave("First");
    try folder.store(gpa, "Ace", 1, &save);
    var back = empty();
    try std.testing.expect(folder.load(gpa, "Ace", 1, &back));
    try std.testing.expectEqualStrings("First", back.name.slice());
    try std.testing.expect(folder.modified("Ace", 1) != null);
    // Another spelling of the call sign finds the same file, which a write replaces.
    save.name.set("Second");
    try folder.store(gpa, "ACE", 1, &save);
    try std.testing.expect(folder.load(gpa, "ace", 1, &back));
    try std.testing.expectEqualStrings("Second", back.name.slice());
    var saves = try tmp.dir.openDir(std.testing.io, folder_name, .{ .iterate = true });
    defer saves.close(std.testing.io);
    var entries = saves.iterate();
    var count: usize = 0;
    while (try entries.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("AceGAME01.IFF", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(1, count);
    // A call sign that would make the file's name a folder's saves nothing.
    try std.testing.expectError(error.BadCallSign, folder.store(gpa, "..\\x", 2, &save));
    // Removed, it is gone.
    folder.remove("Ace", 1);
    try std.testing.expectEqual(null, folder.file(gpa, "Ace", 1));
}
