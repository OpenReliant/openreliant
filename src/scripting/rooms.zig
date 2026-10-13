//! The `openreliant.rooms` package ([#1169](https://github.com/OpenReliant/openreliant/issues/1169)),
//! for player and menu scripts: where the player is in the carrier's rooms, and the page the CD
//! player shows ([#1170](https://github.com/OpenReliant/openreliant/issues/1170)) (`package`).
//!
//! The driver tells the scripts where the player is with each frame (`presentation.Host.rooms`).
//! A script asks for a page, and the CD player turns to it once the scripts' frame has run
//! (`Presentation.takeCdPlayerPage`), so that nothing a script calls reaches into a screen that
//! may have closed since the last frame.

const openreliant = @import("openreliant");
const rooms = openreliant.engine.game.interface.rooms;
const cd_player = openreliant.engine.game.interface.cd_player;
const api = @import("api.zig");
const Call = api.Call;
const presentation = @import("presentation.zig");
const Presentation = presentation.Presentation;

/// What `openreliant.rooms` holds.
pub const package = struct {
    pub const carrier = api.Field(?rooms.Carrier, "The carrier whose rooms are on screen; nil while they aren't, as in flight, in the front end, the in-game options and the briefing.", struct {
        pub fn get(call: Call) ?rooms.Carrier {
            const where = whereOf(call) orelse return null;
            return where.carrier;
        }
    });

    pub const view = api.Field(?u32, "The view the player stands in, or walks into, by its number in `records.room_views`; nil while the rooms aren't on screen.", struct {
        pub fn get(call: Call) ?u32 {
            const where = whereOf(call) orelse return null;
            return @as(u32, where.view) + 1;
        }
    });

    pub const place = api.Field(?rooms.Place, "The place whose screen shows: `itac`, `simulator`, `locker` or `cd_player`, or `news` while the television's report plays. Nil while the player walks the rooms, and while they aren't on screen.", struct {
        pub fn get(call: Call) ?rooms.Place {
            const where = whereOf(call) orelse return null;
            return where.place;
        }
    });

    pub const cd_player_pages = api.Field(u32, "How many pages the CD player has: `records.cd_player`'s tracks twelve to a page, the Reliant's list on page 1, the Yamato's on page 2, and the tracks mods add on the pages after them.", struct {
        pub fn get(_: Call) u32 {
            return @intCast(cd_player.pageCount());
        }
    });

    pub const cd_player_page = api.Field(?u32, "The page the CD player shows while it's open, from 1 to `cd_player_pages`; nil while it isn't open. It opens on its carrier's page, numbered 1 to 12 as the game numbers each list.", struct {
        pub fn get(call: Call) ?u32 {
            const where = whereOf(call) orelse return null;
            const shown = where.cd_player_page orelse return null;
            return @intCast((Presentation.of(call).cd_player_request orelse shown) + 1);
        }
    });

    pub const set_cd_player_page = api.Function("Turns the CD player to page `page`, from 1 to `cd_player_pages`, while it's open, its rows numbered as `records.cd_player` numbers its tracks, from 13 on page 2. The piece chosen plays on, and the pieces that follow it come from its own page. Returns whether the CD player is open.", &.{"page"}, setCdPlayerPage);
};

/// Where the last frame had the player in the rooms; null while they weren't on screen, and before
/// the first frame.
fn whereOf(call: Call) ?presentation.Host.Rooms {
    const host = Presentation.of(call).host orelse return null;
    return host.rooms;
}

/// `rooms.set_cd_player_page(page)`.
fn setCdPlayerPage(call: Call, page: u32) bool {
    const pages = cd_player.pageCount();
    if (page < 1 or page > pages) call.raise("no page {d}: the CD player's pages are 1 to {d}", .{ page, pages });
    const where = whereOf(call) orelse return false;
    if (where.cd_player_page == null) return false;
    Presentation.of(call).cd_player_request = page - 1;
    return true;
}
