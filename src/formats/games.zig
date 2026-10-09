//! Other games on the original's engine, whose files `sltool` reads. Their missions have the
//! original's format, so the original's mission reader reads them, while their archives, models
//! and pictures are their own. OpenReliant doesn't play them: what they share with the original
//! shows what a shared engine has to keep apart
//! ([#181](https://github.com/OpenReliant/openreliant/issues/181)).

/// Star Trek: Invasion, for the PlayStation.
pub const trek = @import("games/trek.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
