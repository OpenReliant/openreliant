//! Other games on StarLancer's engine, whose files `sltool` reads. Their missions keep StarLancer's
//! records, so StarLancer's mission reader reads them, while their archives, models and pictures
//! are their own. OpenReliant doesn't play them: comparing them with StarLancer shows what a shared
//! engine would have to keep apart
//! ([#181](https://github.com/OpenReliant/openreliant/issues/181),
//! [#1017](https://github.com/OpenReliant/openreliant/issues/1017)).

/// Star Trek: Invasion, for the PlayStation.
pub const trek = @import("games/trek.zig");
/// Battlestar Galactica (2003), for the Xbox.
pub const bsg = @import("games/bsg.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
