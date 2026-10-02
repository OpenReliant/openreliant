//! `C:\lancer\game\winmain.cpp`: the game's entry, `WinMain` (`0x004A8B10`), and its message pump.
//! **Unverified:** the pump (`0x004AAB20`), the queue of characters typed (`0x004AADA0` on) and the
//! list of call signs' reading and writing (`0x004AAE00`, `0x004AAEE0`) lie after the last of the
//! file's code that its assertions place; by what they do they are this file's.
//!
//! Ported so far: what the pump does as the game's window goes inactive and active again, as far
//! as the sound and the pause go; the characters typed, which the window's procedure queues; the
//! list of call signs the settings keep; and what follows a mission of the campaign
//! (`afterMission`). `openreliant`'s own frame loop stands in for the rest.

const std = @import("std");

const main = @import("main.zig");
const Clock = main.Clock;
const input = @import("../input.zig");
const camera = @import("camera.zig");
const hog_snd = @import("hog_snd.zig");
const hudoptions = @import("hudoptions.zig");
const interface = @import("interface.zig");
const pilot_roster = @import("interface/pilot_roster.zig");
const rooms = @import("interface/rooms.zig");
const disc = @import("interface/disc.zig");
const CallSigns = pilot_roster.CallSigns;
const profile = @import("../profile.zig");
const Profile = profile.Profile;
const Sound = hog_snd.Sound;
const Ending = main.Ending;
const gameflow = @import("gameflow.zig");
const vm = @import("../vm.zig");
const landing = @import("xtrabits/landing.zig");
const xtrabits = @import("xtrabits.zig");
const explode = @import("explode.zig");

/// The window's activation, as the pump follows it.
pub const App = struct {
    /// Whether the game's window is the active one. The pump goes by `window_suspended`
    /// (`0x005DDD28`), which `0x004A8260` sets as it puts the window away and `input_init`
    /// clears, while the renderer runs (`app_active`, `0x005D6CAC`). **Unverified:** what puts the
    /// window away.
    active: bool = true,
    /// `app_inactive_paused` (`0x005D6CAD`): whether the pump has paused the game for the window
    /// going inactive.
    paused: bool = false,
};

/// `message_pump` (`0x004AAB20`), the part that follows the window's activation. Going inactive,
/// the music, the 3D voices and the voices pause, and the pump waits on the window's messages
/// until it is active again; then the sound goes on. Only in a multiplayer session with a mission
/// `loaded` (`mission_loaded`, `0x00588734`) does it pause the mission as well (`game_pause`),
/// which it then leaves in its pause menu. The textures, which DirectDraw loses with the window,
/// need nothing in OpenReliant.
///
/// **Improvement.** OpenReliant pauses a mission `loaded` into its menu in single player too, where
/// the game pauses only the sound and the timer's ticks pile up while the window is away. Active
/// again, the music goes on; the rest waits for the menu's CONTINUE.
pub fn followActivation(app: *App, pausing: main.Pausing, loaded: bool) !void {
    if (app.active and app.paused) {
        pausing.sound.pauseMusic(false);
        app.paused = false;
    } else if (!app.active and !app.paused) {
        pausing.sound.pauseMusic(true);
        if (loaded) try main.pause(pausing, true);
        app.paused = true;
    }
}

test followActivation {
    const mss = @import("../mss.zig");
    const fat = @import("../../formats/fat.zig");
    const gpa = std.testing.allocator;
    var mixer: mss.Mixer = .init(22050);
    const driver = mixer.driver();
    var sound: Sound = undefined;
    sound.init(driver, 2, null);
    const bytes = comptime hog_snd.testing.bank(2);
    const v = sound.play(try fat.Bank.parse(&bytes), 1, hog_snd.loudest, hog_snd.forever, hog_snd.centre, hog_snd.own_pitch).?;
    var archive = try hudoptions.testing.fontArchive(gpa);
    defer archive.close(gpa);
    var app: App = .{};
    var clock: Clock = .{};
    var view: camera.Camera = .{};
    const player: u16 = 0;
    var menu: hudoptions.PauseMenu = .{};
    defer menu.close();
    const pausing: main.Pausing = .{
        .gpa = gpa,
        .clock = &clock,
        .sound = &sound,
        .menu = &menu,
        .archive = archive.hog,
        .camera = &view,
        .player = &player,
    };

    // Active, nothing changes.
    try followActivation(&app, pausing, true);
    try std.testing.expectEqual(mss.Status.playing, driver.sampleStatus(sound.voices[v].sample));

    // Inactive with no mission loaded, as in the front end, the clock runs on and the menu stays
    // shut, for a mission started later to find.
    app.active = false;
    try followActivation(&app, pausing, false);
    try std.testing.expect(!clock.paused and app.paused and !menu.isOpen());
    app.active = true;
    try followActivation(&app, pausing, false);
    try std.testing.expect(!app.paused);

    // Inactive with a mission loaded, the sound and the clock stop, once, and the menu opens.
    app.active = false;
    try followActivation(&app, pausing, true);
    try followActivation(&app, pausing, true);
    try std.testing.expect(clock.paused and app.paused and menu.isOpen());
    try std.testing.expectEqual(mss.Status.stopped, driver.sampleStatus(sound.voices[v].sample));

    // Active again, the mission waits in the menu; continuing, the voices go on.
    app.active = true;
    try followActivation(&app, pausing, true);
    try std.testing.expect(clock.paused and !app.paused);
    try main.pause(pausing, false);
    try std.testing.expect(!clock.paused and !menu.isOpen());
    try std.testing.expectEqual(mss.Status.playing, driver.sampleStatus(sound.voices[v].sample));
}

/// What `WinMain` reads of the settings' `[Device]` as the game starts (`0x004A8FB3`) that
/// OpenReliant goes by. **Not ported:** the rest it reads there for the renderer (`Device`, `Xres`,
/// `Yres` and `Windowed`), where OpenReliant's options stand in.
pub const Device = struct {
    /// The options' cockpit setting (`View`, `cockpit_mode_setting`, `0x005D5A78`), 0 where the
    /// file has none.
    view: camera.CockpitSetting,
    /// The brightness, which the file keeps in hundredths (`Gamma`, `device_gamma`, `0x005D6080`),
    /// 100 where it has none: the renderer opens with it (`renderer_open`, `0x004A8600`), and the
    /// settings' video changes it.
    brightness: f32,
    /// Whether the movies between the front end's screens play (`Transitions`, `0x005D5E80`), 1
    /// where the file has none (`0x004A9081`); the settings' video changes it.
    transitions: bool,
    /// The renderer's details.
    details: Details,

    const video = interface.settings.video;
    /// The key `WinMain` reads the brightness from (`0x00509948`); the video screen writes it as
    /// `gamma`, which is the same key, as a key's case does not matter.
    const gamma_key = "Gamma";
    const default_gamma = 100;

    pub fn read(settings: Profile) Device {
        return .{
            .view = @enumFromInt(settings.int(video.section, video.view_key, 0)),
            .brightness = @as(f32, @floatFromInt(settings.int(video.section, gamma_key, default_gamma))) / video.gamma_scale,
            .transitions = settings.int(video.section, video.transitions_key, 1) != 0,
            .details = .read(settings),
        };
    }
};

/// The details `WinMain` reads for the renderer (`0x004A9035` on), which take effect as it starts:
/// the texture detail (`Tdetail`, `texture_detail`, `0x00595D7C`), 1 where the file has none; the
/// graphic detail (`Gdetail`, `graphic_detail`, `0x005D54E0`), 2; and whether the light maps are
/// drawn (`Lmaps`, `light_maps`, `0x005D5618`), 1. The settings' video changes them, and
/// `renderer_open` writes them as it starts the renderer again (`0x004A8716` on).
///
/// **Improvement:** the texture detail is 2, the highest, where the file has none, as the others
/// are; the game's 1 caps the textures at 256, which none of its own pass.
///
/// **Fix:** a graphic detail past 2 counts as 2, where the game's uses of it disagree on one.
pub const Details = struct {
    texture: xtrabits.TextureDetail = .high,
    graphic: explode.Detail = .high,
    light_maps: bool = true,

    /// The keys, in `[Device]` (`0x005095DC`, `0x005095D4`, `0x005095CC`).
    pub const texture_key = "Tdetail";
    pub const graphic_key = "Gdetail";
    pub const light_maps_key = "Lmaps";

    pub fn read(settings: Profile) Details {
        const section = interface.settings.video.section;
        const highest = @intFromEnum(explode.Detail.high);
        return .{
            .texture = @enumFromInt(settings.int(section, texture_key, @intFromEnum(xtrabits.TextureDetail.high))),
            .graphic = @enumFromInt(@min(settings.int(section, graphic_key, highest), highest)),
            .light_maps = settings.int(section, light_maps_key, 1) != 0,
        };
    }
};

test "Device.read" {
    // Without the file, the cockpit's view, at the renderer's own brightness.
    const none: Device = .read(.empty);
    try std.testing.expectEqual(.cockpit, none.view);
    try std.testing.expectEqual(1, none.brightness);
    try std.testing.expect(none.transitions);
    try std.testing.expectEqual(Details{}, none.details);
    // As the video screens write them.
    const saved: Device = .read(.{ .text = "[Device]\nView=2\ngamma=150\nTransitions=0\nTdetail=0\nGdetail=1\nLmaps=0\n" });
    try std.testing.expectEqual(.none, saved.view);
    try std.testing.expectEqual(1.5, saved.brightness);
    try std.testing.expect(!saved.transitions);
    try std.testing.expectEqual(Details{ .texture = .low, .graphic = .medium, .light_maps = false }, saved.details);
    // A graphic detail past the highest counts as it.
    try std.testing.expectEqual(.high, Details.read(.{ .text = "[Device]\nGdetail=7\n" }).graphic);
}

/// The longest name `missionPath` makes; the game's buffer is far larger.
pub const mission_path_size = 32;

/// The mission file `WinMain` names for mission `number` at the mission's start (`0x004A9C42`,
/// `0x004AA40A`): `.\missions\mission<number>.dte`. Mission 25, once its first part is won
/// (`mission25_second_part`, `0x00587CDC`), is `mission251.dte`, its second part; and in a
/// multiplayer game mission 3 is `mission311.dte`.
pub fn missionPath(buffer: *[mission_path_size]u8, number: u16, second_part: bool, multiplayer: bool) []const u8 {
    if (number == second_part_mission and second_part) return second_part_path;
    if (number == multiplayer_mission and multiplayer) return multiplayer_path;
    return std.fmt.bufPrint(buffer, "{s}{d}" ++ file_end, .{ path_start, number }) catch unreachable;
}

/// A mission's file, `mission<number>.dte`, and where it lies.
const file_start = "mission";
const file_end = ".dte";
const path_start = ".\\missions\\" ++ file_start;
/// Mission 25, whose second part is a file of its own (`0x00509728`), and the number `WinMain` takes
/// for that part, which it makes mission 25's second part (`0x004AA43E`); and mission 3, whose
/// multiplayer game is (`0x0050970C`).
pub const second_part_mission = 25;
pub const second_part_number = 251;
const second_part_path = path_start ++ std.fmt.comptimePrint("{d}", .{second_part_number}) ++ file_end;
const multiplayer_mission = 3;
const multiplayer_path = path_start ++ "311" ++ file_end;

/// The number in a mission file's name, `mission<number>.dte` as `missionPath` names it, whatever
/// its case; null for any other name. Added for OpenReliant, which lists the missions a game's
/// folder holds (`openreliant missions`).
pub fn missionNumber(name: []const u8) ?u16 {
    if (name.len <= file_start.len + file_end.len) return null;
    if (!std.ascii.startsWithIgnoreCase(name, file_start) or !std.ascii.endsWithIgnoreCase(name, file_end)) return null;
    return std.fmt.parseInt(u16, name[file_start.len .. name.len - file_end.len], 10) catch null;
}

test missionNumber {
    try std.testing.expectEqual(1, missionNumber("mission1.dte"));
    try std.testing.expectEqual(251, missionNumber("MISSION251.DTE"));
    try std.testing.expectEqual(null, missionNumber("mission.dte"));
    try std.testing.expectEqual(null, missionNumber("missionx.dte"));
    try std.testing.expectEqual(null, missionNumber("mission1.shp"));
    // Every name `missionPath` makes reads back.
    var buffer: [mission_path_size]u8 = undefined;
    try std.testing.expectEqual(25, missionNumber(std.fs.path.basenameWindows(missionPath(&buffer, 25, false, false))));
}

/// What `WinMain` does before the hangar's movie of a mission it flies (`0x004AA3B2` on, and
/// `0x004A9BE2` on after a briefing): the music starts fading out by `music_fade_step` from the
/// timer's count `game_ticks` (`music_fade_out`), and the voices stop (`sound_pause_all`). It then
/// waits `launch_wait`, in which the timer fades the music out. **Unverified:** that the call it
/// waits with, a second's worth of milliseconds its one argument, is `Sleep`, whose import the
/// executable's protection hides.
pub fn launchFade(sound: *Sound, game_ticks: u32) void {
    sound.fadeMusic(music_fade_step, game_ticks);
    sound.pauseAll();
}

/// The step `WinMain` fades the music out by, as a campaign starts and before the hangar's movie.
pub const music_fade_step = 15;
pub const launch_wait = std.time.ns_per_s;

/// What `WinMain` does as a single-player campaign starts, as START GAME starts one, before the
/// Reliant's rooms (`vr_rooms`) for mission `mission` (`0x004AA1BA` on): the music starts fading
/// out by `music_fade_step`, and the archive of the disc that holds the rooms opens
/// (`rooms.Carrier.disc`). Before mission 1, a new pilot's intro (`new_intro`) and induction
/// (`interface.induction`) come first.
pub const CampaignStart = struct {
    disc: disc.Number,
    induction: bool,

    pub fn of(mission: u16) CampaignStart {
        return .{ .disc = rooms.Carrier.of(mission).disc(), .induction = mission == induction_mission };
    }
};

/// The mission a new pilot's induction comes before (`0x004AA229`), and the intro before it,
/// played from the disc on a cleared screen (`play_bink_movie_resourced`, `0x0050967C`).
pub const induction_mission = 1;
pub const new_intro = "new_intro.bik";

test CampaignStart {
    try std.testing.expectEqual(CampaignStart{ .disc = .two, .induction = true }, CampaignStart.of(1));
    try std.testing.expectEqual(CampaignStart{ .disc = .two, .induction = false }, CampaignStart.of(18));
    try std.testing.expectEqual(CampaignStart{ .disc = .one, .induction = false }, CampaignStart.of(19));
}

test launchFade {
    const mss = @import("../mss.zig");
    const fat = @import("../../formats/fat.zig");
    var mixer: mss.Mixer = .init(22050);
    const driver = mixer.driver();
    var sound: Sound = undefined;
    sound.init(driver, 2, null);
    const bytes = comptime hog_snd.testing.bank(2);
    const v = sound.play(try fat.Bank.parse(&bytes), 1, hog_snd.loudest, hog_snd.forever, hog_snd.centre, hog_snd.own_pitch).?;
    // Without music, only the voices stop, where they are.
    launchFade(&sound, 300);
    try std.testing.expect(!sound.music.fading);
    try std.testing.expect(sound.paused[v]);
    try std.testing.expectEqual(mss.Status.stopped, driver.sampleStatus(sound.voices[v].sample));
}

/// Whether `WinMain` plays the landing (`play_landing_movie`, `xtrabits.landing`) after a mission
/// it flew, number `mission`, ended as `ending` (`0x004AA4B2` on): not after the player's ship was
/// destroyed, its pilot captured or the mission left, nor after mission 25's first part, which leads
/// into its second (`second_part`); and not where a lobby launched the game (`lobby_launch`,
/// `0x00595C64`), as OpenReliant never is.
pub fn landsAfter(ending: Ending, mission: u16, second_part: bool) bool {
    return switch (ending) {
        .destroyed, .captured, .left => false,
        else => mission != second_part_mission or second_part,
    };
}

test landsAfter {
    try std.testing.expect(landsAfter(.playing, 1, false));
    try std.testing.expect(landsAfter(.rescued, 1, false));
    try std.testing.expect(!landsAfter(.destroyed, 1, false));
    try std.testing.expect(!landsAfter(.left, 1, false));
    try std.testing.expect(!landsAfter(.playing, 25, false));
    try std.testing.expect(landsAfter(.playing, 25, true));
}

/// What follows a mission of the campaign, as `WinMain` goes on after it (`afterMission`).
pub const AfterMission = union(enum) {
    /// The pilot came through: the next mission and the campaign's tier (`gameflow.endMission`),
    /// the medal's ceremony first where there is one; then the ITAC's debriefing, and the rooms from
    /// where the ITAC leaves the pilot, whose briefing room leads to the next mission
    /// (`0x004AA6A0`, `0x004AA372`).
    goes_on: gameflow.Record,
    /// Mission 25's first part leads straight into its second, flown after the hangar's movie
    /// (`0x004AA597`).
    second_part,
    /// A movie of how the mission ended, where there is one, then the restart screen
    /// (`interface.restart`, `0x004AA557`, `0x004AA756`).
    restart: ?[]const u8,
    /// A movie of the pilot's career ending, then the front end's main menu.
    career_over: []const u8,
    /// The campaign's last mission won: the story's end, then the main menu with the campaign back
    /// at its first mission (`0x004AA6F7`).
    story_end,
};

/// What `WinMain` does as mission `mission` of the campaign ends (`0x004AA4B2` to `0x004AA756`),
/// after the landing where it plays one (`landsAfter`), `variables` being the game's as the mission
/// left them and `second_part` whether it was mission 25's second part, which it sets for what
/// follows:
///
/// - Destroyed, the pilot's funeral; captured, the pilot in the enemy's hands; and each then the
///   restart screen, as leaving the mission from the pause menu turns to it at once (`lost`).
/// - Picked up past the pickups allowed (`gameflow.Campaign.pickedUp`), the pilot's transfer, which
///   ends the career.
/// - Sent home for destroying a friend, the pilot's execution, then the restart screen.
/// - Mission 25's first part leads into its second, unless the script rated it a total failure.
/// - Otherwise the mission's end is recorded (`gameflow.endMission`): the campaign goes on, the
///   story ends after the last mission, and a total failure ends the career in the transfer or
///   the shuttle the story gives (`careerOver`).
pub fn afterMission(campaign: *gameflow.Campaign, player: *input.Player, variables: *vm.Variables, mission: u16, second_part: *bool, tier: u2) AfterMission {
    const carrier = rooms.Carrier.of(mission);
    switch (player.ending) {
        .destroyed => return lost(second_part, funeral.get(carrier)),
        .captured => return lost(second_part, capture),
        .left => return lost(second_part, null),
        .rescued => if (campaign.pickedUp(mission)) return .{ .career_over = transfer.get(carrier) },
        .friendly_fire => return .{ .restart = execution.get(carrier) },
        else => {},
    }
    if (mission == second_part_mission and !second_part.* and variables.mission_success != .total_failure) {
        second_part.* = true;
        return .second_part;
    }
    second_part.* = false;
    const record = gameflow.endMission(player, variables, mission, tier, campaign) orelse return .{ .career_over = careerOver(mission, variables) };
    if (record.next == gameflow.story_end) return .story_end;
    return .{ .goes_on = record };
}

/// The restart screen after `movie`, where there is one, for a pilot lost or a mission left: mission
/// 25 is then replayed from its first part (`0x004AA750`).
fn lost(second_part: *bool, movie: ?[]const u8) AfterMission {
    second_part.* = false;
    return .{ .restart = movie };
}

/// The movies of how a mission ended, each carrier's (`0x00509694` to `0x005096F8`): the funeral,
/// the pilot's execution and the pilot's transfer. The pilot in the enemy's hands and the shuttle at
/// Fort Bear have one each (`0x0050968C`, `0x00509664`).
const funeral = std.EnumArray(rooms.Carrier, []const u8).init(.{ .reliant = "new_funeral.bik", .yamato = "new_funeral2.bik" });
const execution = std.EnumArray(rooms.Carrier, []const u8).init(.{ .reliant = "new_rel_exec.bik", .yamato = "new_y_exec.bik" });
const transfer = std.EnumArray(rooms.Carrier, []const u8).init(.{ .reliant = "new_reliant_transfer.bik", .yamato = "new_a y trans.bik" });
const capture = "int.bik";
const shuttle = "fortbearshuttle_.bik";

/// The movie of a total failure (`0x004AA5AD` on): after missions 25 and 27, the shuttle at Fort
/// Bear where the landing would be none (`landing.lastWithoutLanding`); on the Reliant, the pilot's
/// transfer off it where the game's variable 32 is set, and otherwise, as on the Yamato, off the
/// Yamato.
fn careerOver(mission: u16, variables: *vm.Variables) []const u8 {
    if (landing.lastWithoutLanding(mission, variables)) return shuttle;
    const on_reliant = rooms.Carrier.of(mission) == .reliant and variables.slot(landing.mission8_on_reliant).* != 0;
    return transfer.get(if (on_reliant) .reliant else .yamato);
}

test afterMission {
    var campaign: gameflow.Campaign = .begin();
    var variables = campaign.attempt();
    var player: input.Player = .{};
    var second_part = true;
    // Destroyed, the funeral, the Yamato's after mission 18, and mission 25 replayed from its first
    // part; captured, the capture; and left, the restart screen at once.
    player.ending = .destroyed;
    try std.testing.expectEqualStrings(funeral.get(.reliant), afterMission(&campaign, &player, &variables, 5, &second_part, 0).restart.?);
    try std.testing.expect(!second_part);
    try std.testing.expectEqualStrings(funeral.get(.yamato), afterMission(&campaign, &player, &variables, 20, &second_part, 0).restart.?);
    player.ending = .captured;
    try std.testing.expectEqualStrings(capture, afterMission(&campaign, &player, &variables, 5, &second_part, 0).restart.?);
    player.ending = .left;
    try std.testing.expectEqual(null, afterMission(&campaign, &player, &variables, 5, &second_part, 0).restart);
    // Sent home, the execution, mission 25's part as it was.
    player.ending = .friendly_fire;
    second_part = true;
    try std.testing.expectEqualStrings(execution.get(.reliant), afterMission(&campaign, &player, &variables, 5, &second_part, 0).restart.?);
    try std.testing.expect(second_part);
    // Won, mission 25's first part leads into its second, and the others go on.
    player.ending = .playing;
    variables.mission_success = .success;
    second_part = false;
    try std.testing.expectEqual(.second_part, std.meta.activeTag(afterMission(&campaign, &player, &variables, 25, &second_part, 0)));
    try std.testing.expect(second_part);
    try std.testing.expectEqual(26, afterMission(&campaign, &player, &variables, 25, &second_part, 0).goes_on.next);
    try std.testing.expect(!second_part);
    try std.testing.expectEqual(6, afterMission(&campaign, &player, &variables, 5, &second_part, 0).goes_on.next);
    try std.testing.expectEqual(.story_end, std.meta.activeTag(afterMission(&campaign, &player, &variables, gameflow.last_mission, &second_part, 0)));
    // A total failure ends the career: off the Reliant where variable 32 is set, as a new
    // campaign has it; off the Yamato after mission 18; and after mission 25, where the landing
    // would be none, the shuttle.
    variables.mission_success = .total_failure;
    try std.testing.expectEqualStrings(transfer.get(.reliant), afterMission(&campaign, &player, &variables, 5, &second_part, 0).career_over);
    player.ending = .playing;
    try std.testing.expectEqualStrings(transfer.get(.yamato), afterMission(&campaign, &player, &variables, 20, &second_part, 0).career_over);
    player.ending = .playing;
    variables.slot(landing.last_missions_land).* = 0;
    try std.testing.expectEqualStrings(shuttle, afterMission(&campaign, &player, &variables, 25, &second_part, 0).career_over);
    // Picked up twice, the campaign goes on; the third time, the pilot is transferred.
    variables.mission_success = .success;
    player.ending = .rescued;
    try std.testing.expectEqual(.goes_on, std.meta.activeTag(afterMission(&campaign, &player, &variables, 5, &second_part, 0)));
    try std.testing.expectEqual(.goes_on, std.meta.activeTag(afterMission(&campaign, &player, &variables, 5, &second_part, 0)));
    try std.testing.expectEqualStrings(transfer.get(.reliant), afterMission(&campaign, &player, &variables, 5, &second_part, 0).career_over);
}

/// What `WinMain` does before each single-player mission (`0x004A99CC`): puts back the pilot's
/// kills as the last mission the pilot came through kept them (`gameflow.endMission`), and the
/// mission's as its record keeps them, `kept` (`0x004A9A2D`). **Not ported:** the rank, the medals
/// and the other tallies it puts back with them, which no screen of OpenReliant shows.
pub fn startMission(player: *input.Player, kept: u16) void {
    player.kills.count = player.kills.kept;
    player.kills.mission = kept;
}

test startMission {
    var player: input.Player = .{ .kills = .{ .count = 9, .kept = 4, .mission = 5 } };
    startMission(&player, 0);
    try std.testing.expectEqual(4, player.kills.count);
    try std.testing.expectEqual(0, player.kills.mission);
}

test missionPath {
    var buffer: [mission_path_size]u8 = undefined;
    try std.testing.expectEqualStrings(".\\missions\\mission1.dte", missionPath(&buffer, 1, false, false));
    try std.testing.expectEqualStrings(".\\missions\\mission25.dte", missionPath(&buffer, 25, false, false));
    try std.testing.expectEqualStrings(".\\missions\\mission251.dte", missionPath(&buffer, 25, true, false));
    try std.testing.expectEqualStrings(".\\missions\\mission3.dte", missionPath(&buffer, 3, false, false));
    try std.testing.expectEqualStrings(".\\missions\\mission311.dte", missionPath(&buffer, 3, false, true));
    try std.testing.expectEqualStrings(".\\missions\\mission65535.dte", missionPath(&buffer, 65535, false, false));
}

/// The characters typed into the game's window (`typed_keys`, `0x005D547C`, and their count,
/// `0x00595D70`), in the game's code page, as its procedure queues them from `WM_CHAR`
/// (`window_proc`, `0x004A83CF`): a hundred at most. While `file_names` is set (`0x005D6088`), as the pilot roster sets it for the
/// call sign that names the pilot's saves, the characters a file's name can't hold are refused
/// (`file_name_refused`).
pub const Typed = struct {
    characters: [capacity]u8 = undefined,
    count: usize = 0,
    file_names: bool = false,

    pub const capacity = 100;

    /// The characters a file's name can't hold (`0x0050954C`).
    pub const file_name_refused = "\\/:*?<>|\"";

    /// Queues `character`, unless the queue is full or it is refused.
    pub fn push(typed: *Typed, character: u8) void {
        if (typed.count >= capacity) return;
        if (typed.file_names and std.mem.indexOfScalar(u8, file_name_refused, character) != null) return;
        typed.characters[typed.count] = character;
        typed.count += 1;
    }

    /// `typed_key_pop` (`0x004AADB0`): the first character queued, taken off, or null for none.
    pub fn pop(typed: *Typed) ?u8 {
        if (typed.count == 0) return null;
        const first = typed.characters[0];
        std.mem.copyForwards(u8, typed.characters[0 .. typed.count - 1], typed.characters[1..typed.count]);
        typed.count -= 1;
        return first;
    }

    /// `typed_keys_clear` (`0x004AADA0`).
    pub fn clear(typed: *Typed) void {
        typed.count = 0;
    }
};

test Typed {
    var typed: Typed = .{};
    for ("A1:") |character| typed.push(character);
    try std.testing.expectEqual('A', typed.pop().?);
    // A call sign's file name holds no colon.
    typed.file_names = true;
    typed.push('?');
    typed.push('b');
    try std.testing.expectEqual('1', typed.pop().?);
    try std.testing.expectEqual(':', typed.pop().?);
    try std.testing.expectEqual('b', typed.pop().?);
    try std.testing.expectEqual(null, typed.pop());
    // A hundred at most.
    for (0..Typed.capacity + 5) |_| typed.push('x');
    try std.testing.expectEqual(Typed.capacity, typed.count);
    typed.clear();
    try std.testing.expectEqual(null, typed.pop());
}

/// The settings' section of the call signs, and the key of each place, `name%02d` (`0x00509BC8`,
/// `0x00509BD8`).
const call_signs_section = "CallsignList";

fn callSignKey(buffer: *[8]u8, place: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "name{d:0>2}", .{place}) catch unreachable;
}

/// `callsigns_load` (`0x004AAE00`): the call sign of each of the list's places from `settings`,
/// the first `player` where the settings have none (string `0xBF`, `pilot_roster.String.player`),
/// the rest empty. `WinMain` reads the list as the game starts, and writes it straight back
/// (`saveCallSigns`, `0x004A919B`).
pub fn loadCallSigns(settings: Profile, player: []const u8) CallSigns {
    var list: CallSigns = .{};
    for (&list.names, 0..) |*name, place| {
        var key: [8]u8 = undefined;
        const default: []const u8 = if (place == 0) player else "";
        name.set(settings.value(call_signs_section, callSignKey(&key, place)) orelse default);
    }
    return list;
}

/// `callsigns_save` (`0x004AAEE0`): each place's call sign to `settings`, then the list read back
/// from them (`loadCallSigns`), as the settings give each call sign, without spaces at its ends.
pub fn saveCallSigns(list: *CallSigns, settings: *profile.File) std.mem.Allocator.Error!void {
    for (&list.names, 0..) |*name, place| {
        var key: [8]u8 = undefined;
        try settings.write(call_signs_section, callSignKey(&key, place), name.slice());
    }
    // Every place is in the settings now, so the first needs no call sign in its place.
    list.* = loadCallSigns(settings.profile, "");
}

test loadCallSigns {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    // Without the settings, the first place is PLAYER and the rest are empty.
    var list = loadCallSigns(.empty, "PLAYER");
    try std.testing.expectEqualStrings("PLAYER", list.names[0].slice());
    try std.testing.expectEqual(0, list.names[1].len);
    // The settings keep them, and give them back without spaces at their ends.
    list.names[1].set("Ace ");
    var settings: profile.File = .{ .arena = arena_state.allocator(), .profile = .empty };
    try saveCallSigns(&list, &settings);
    try std.testing.expect(settings.changed);
    try std.testing.expectEqualStrings("PLAYER", settings.profile.value(call_signs_section, "name00").?);
    try std.testing.expectEqualStrings("", settings.profile.value(call_signs_section, "name09").?);
    try std.testing.expectEqualStrings("Ace", list.names[1].slice());
    try std.testing.expectEqualStrings("Ace", loadCallSigns(settings.profile, "PLAYER").names[1].slice());
}
