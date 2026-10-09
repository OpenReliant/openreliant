//! Other games on StarLancer's engine, whose files `sltool` reads. Their missions have StarLancer's
//! format, so StarLancer's mission reader reads them, while their archives, models and pictures are
//! their own. OpenReliant doesn't play them: comparing them with StarLancer shows what a shared
//! engine would have to keep apart
//! ([#181](https://github.com/OpenReliant/openreliant/issues/181)).

/// Star Trek: Invasion, for the PlayStation.
pub const trek = @import("games/trek.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
