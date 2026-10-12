//! The names mission source declares records under
//! ([Mission source](../../../../docs/formats/mission-source.md#the-round-trip)): Luau identifiers
//! made from the records' display names, each unique in its file.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Luau's keywords, the contextual ones too, which no name can be.
const keywords = [_][]const u8{
    "and",   "break",  "continue", "do",   "else", "elseif", "end",   "export",
    "false", "for",    "function", "if",   "in",   "local",  "nil",   "not",
    "or",    "repeat", "return",   "then", "true", "type",   "until", "while",
};

/// The names mission source gives itself, which no record's name can be either: its constructors,
/// its functions, and the forms the script writes some opcodes in.
pub const reserved = [_][]const u8{
    "mission",            "global",          "flight_group",          "ship",            "nav_point",
    "waypoint",           "point",           "curve_point",           "squad",           "component",
    "formation",          "curve",           "part",                  "handler",         "on",
    "any_ship",           "command",         "spawn",                 "random",          "result",
    "game",               "thread_value",    "last_event",            "in_flight_group", "not_in_flight_group",
    "in_squad",           "not_in_squad",    "greater_f",             "greater_equal_f", "less_f",
    "less_equal_f",       "add_f",           "sub_f",                 "mul_f",           "div_f",
    "add_assign_f",       "sub_assign_f",    "mul_assign_f",          "div_assign_f",    "ship_index",
    "flight_group_index", "squad_index",     "curve_index",           "global_index",    "part_index",
    "object_index",       "formation_index", "formation_point_index",
};

/// Whether `name` is taken by Luau or by mission source itself, a part's argument such as `arg0`
/// among them.
pub fn isReserved(name: []const u8) bool {
    for (keywords ++ reserved) |word| {
        if (std.mem.eql(u8, word, name)) return true;
    }
    const number = std.mem.cutPrefix(u8, name, "arg") orelse return false;
    return number.len > 0 and for (number) |byte| {
        if (!std.ascii.isDigit(byte)) break false;
    } else true;
}

/// Makes the names of a file's records, each unique among those it has made.
pub const Namer = struct {
    arena: Allocator,
    taken: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(arena: Allocator) Namer {
        return .{ .arena = arena };
    }

    /// Keeps `name` from the records, such as a name the script gives an event's value.
    pub fn reserve(namer: *Namer, name_taken: []const u8) Allocator.Error!void {
        try namer.taken.put(namer.arena, name_taken, {});
    }

    /// A name for record `index` of its kind, `kind`, whose display name is `display`: the display
    /// name in lower case, a leading tag of letters such as `(F)` or `(GV)` left out, each run of
    /// other characters an underscore, and an underscore where a small letter meets a capital. The
    /// kind and the index stand in where that leaves nothing, and the kind goes before a name that
    /// starts with a digit and after one that is reserved. A name already made gets `_2`, `_3` and
    /// so on after it.
    pub fn name(namer: *Namer, display: []const u8, kind: []const u8, index: usize) Allocator.Error![]const u8 {
        var made: std.ArrayList(u8) = .empty;
        var gap = false;
        var after_small = false;
        for (withoutTag(display)) |byte| {
            if (std.ascii.isAlphanumeric(byte)) {
                if ((gap or (after_small and std.ascii.isUpper(byte))) and made.items.len > 0) try made.append(namer.arena, '_');
                try made.append(namer.arena, std.ascii.toLower(byte));
                gap = false;
                after_small = std.ascii.isLower(byte);
            } else {
                gap = true;
                after_small = false;
            }
        }
        const base: []const u8 = if (made.items.len == 0)
            try std.fmt.allocPrint(namer.arena, "{s}_{d}", .{ kind, index })
        else if (std.ascii.isDigit(made.items[0]))
            try std.fmt.allocPrint(namer.arena, "{s}_{s}", .{ kind, made.items })
        else if (isReserved(made.items))
            try std.fmt.allocPrint(namer.arena, "{s}_{s}", .{ made.items, kind })
        else
            made.items;
        var unique = base;
        var count: usize = 2;
        while (namer.taken.contains(unique)) : (count += 1) unique = try std.fmt.allocPrint(namer.arena, "{s}_{d}", .{ base, count });
        try namer.taken.put(namer.arena, unique, {});
        return unique;
    }
};

/// `display` without a leading tag of letters in brackets, such as `(F)`, `<F>` or `(GV)`, which
/// the developers' tools put before names to say what they name.
fn withoutTag(display: []const u8) []const u8 {
    if (display.len < 3) return display;
    const close: u8 = switch (display[0]) {
        '(' => ')',
        '<' => '>',
        else => return display,
    };
    const end = std.mem.findScalar(u8, display, close) orelse return display;
    if (end < 2) return display;
    for (display[1..end]) |byte| if (!std.ascii.isAlphabetic(byte)) return display;
    return display[end + 1 ..];
}

/// Whether `name` is a Luau identifier that no keyword or name of the source's own takes.
pub fn isName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    return !isReserved(name);
}

test Namer {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var namer: Namer = .init(arena_state.allocator());
    try std.testing.expectEqualStrings("jumping_to_convoy", try namer.name("(F)Jumping to CONVOY", "part", 1));
    try std.testing.expectEqualStrings("convoykilled", try namer.name("(GV)convoykilled", "global", 0));
    try std.testing.expectEqualStrings("start_launch", try namer.name("<F>Start Launch", "part", 0));
    // A tag with a digit is part of the name.
    try std.testing.expectEqualStrings("a1_naginata", try namer.name("(A1)Naginata", "ship", 1));
    try std.testing.expectEqualStrings("player_ship", try namer.name("Player_Ship", "ship", 0));
    try std.testing.expectEqualStrings("viper_s_coyote", try namer.name("(WL)Viper's Coyote", "ship", 5));
    // A small letter meeting a capital starts a word; capitals together and digits don't.
    try std.testing.expectEqualStrings("jumped_in_ship", try namer.name("JumpedInShip", "value", 0));
    try std.testing.expectEqualStrings("ussr_sabre1b", try namer.name("USSR_Sabre1b", "ship", 6));
    // A name taken, nothing left, a leading digit, and a reserved word.
    try std.testing.expectEqualStrings("player_ship_2", try namer.name("player ship", "ship", 9));
    try std.testing.expectEqualStrings("curve_3", try namer.name("", "curve", 3));
    try std.testing.expectEqualStrings("ship_1st_wing", try namer.name("1st wing", "ship", 4));
    try std.testing.expectEqualStrings("end_part", try namer.name("(F)end", "part", 7));
    try std.testing.expectEqualStrings("game_global", try namer.name("game", "global", 2));
}

test isName {
    try std.testing.expect(isName("convoy_hit"));
    try std.testing.expect(isName("_private"));
    try std.testing.expect(!isName("2nd"));
    try std.testing.expect(!isName("with-dash"));
    try std.testing.expect(!isName("repeat"));
    try std.testing.expect(!isName("ship"));
    try std.testing.expect(!isName("arg3"));
    try std.testing.expect(isName("argument"));
}
