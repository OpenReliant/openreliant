//! The `openreliant.radio` package, for global and object scripts: lines said on the radio, as a
//! mission's comms commands say them ([#981](https://github.com/OpenReliant/openreliant/issues/981)).
//! A mod can add radio chatter, or voice a mission that has none, such as the Dreamcast's mission
//! 22, which prints its radio as debug text.

const openreliant = @import("openreliant");
const engine = openreliant.engine;
const radio = engine.game.radio;
const pilots = engine.game.pilots;
const hudmovie = engine.game.hudmovie;
const Object = engine.hooks.Object;
const api = @import("api.zig");
const Call = api.Call;

/// What `openreliant.radio` holds.
pub const package = struct {
    pub const say = api.Function("The ship `ship` says the speech file `speech` on the radio, a file of the game's or a mod's such as `ms_dice22_001.ut`, its pilot's face showing, as a mission's CommsFromShip does: at once, ending the line playing, unless `line` says otherwise. The line goes through the `radio_say` hook. A ship being destroyed, or a stand-in, says nothing. Returns whether the mission's radio took the line: false between missions.", &.{ "ship", "speech", "line" }, sayShip);
    pub const say_pilot = api.Function("Pilot `pilot` says the speech file `speech` on the radio, with its face, as a mission's CommsFromPilot does: at once, ending the line playing, unless `line` says otherwise. The pilot is one of the game's by its name or number, or one a mod adds by its qualified name. The line goes through the `radio_say` hook. Returns whether the mission's radio took the line: false between missions.", &.{ "pilot", "speech", "line" }, sayPilot);
};

/// How a line is said, where a script gives more than who says it and what.
pub const Line = struct {
    pub const script_name = "RadioLine";

    /// When it's said: at once, ending the line playing, as the comms commands say theirs; queued,
    /// after the lines before it; or queued unless the radio is busy.
    mode: radio.Mode = .now,
    /// Which of the speaker's face films plays as it's said.
    face: pilots.Head = .talking,
    /// Whether the film plays once, then the dead channel's while the line goes on, as the comms
    /// commands' Once forms play it, rather than for as long as the line does.
    once: bool = false,

    fn flags(line: Line) hudmovie.Flags {
        return if (line.once) .once else .looping;
    }
};

/// `radio.say(ship, speech, line)`: `Radio.sayShip`, as `CommsFromShip` calls it.
fn sayShip(call: Call, ship: Object, speech: []const u8, given: ?Line) bool {
    const line = given orelse Line{};
    const on_air, const ctx = onAir(call) orelse return false;
    on_air.sayShip(ctx, ship.slot(), line.face, speech, line.mode, line.flags(), radio.no_expiry);
    return true;
}

/// `radio.say_pilot(pilot, speech, line)`: `Radio.sayPilot`, as `CommsFromPilot` calls it.
fn sayPilot(call: Call, pilot: pilots.Number, speech: []const u8, given: ?Line) bool {
    if (pilot == .none) call.raise("radio.say_pilot: a line needs a pilot to say it", .{});
    const line = given orelse Line{};
    const on_air, const ctx = onAir(call) orelse return false;
    on_air.sayPilot(ctx, @backingInt(pilot), line.face, speech, line.mode, line.flags(), radio.no_expiry);
    return true;
}

/// The mission's radio and what it reaches, while a mission runs with one that is heard.
fn onAir(call: Call) ?struct { *radio.Radio, radio.Context } {
    const orders = call.runtime().orders orelse return null;
    return radio.onAir(orders.world);
}
