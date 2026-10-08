//! The language of the combat maneuvers' scripts, and a compiler for it that does what the
//! payload's own does (`maneuver_compile_line`, `0x00405010`). `docs/engine/maneuvers.md` describes
//! what each command does when it runs.
//!
//! A script is a list of lines, each one command. A command is a word, then for some commands a
//! list of arguments in parentheses, separated by commas, of which the payload reads four at most.
//! A word is letters, digits and `_ . : -`, and spaces and tabs around words and arguments are
//! skipped. Commands compare without regard to case. A line whose first word ends in `:` is a
//! label, which `Goto` names without the colon.
//!
//! The payload compiles a line the first time it runs it; `compileLine` compiles one line the same
//! way, and `compile` all of them.

const std = @import("std");

const maneuvers = @import("../aidefend.zig");
const profile = @import("../../profile.zig");
pub const Opcode = maneuvers.Opcode;
pub const Condition = maneuvers.Condition;

/// A value picked at random from `min` to `max`.
pub const Range = struct { min: f32, max: f32 };

/// A number of ticks picked at random from `min` to `max`.
pub const Ticks = struct { min: u16, max: u16 };

pub const If = struct {
    condition: Condition,
    /// The line of the matching `Else` or `Endif`, after which it goes on when the condition
    /// fails.
    otherwise: u8,
};

/// A compiled line, holding what the payload's compiled record holds.
pub const Instruction = union(Opcode) {
    set_yaw: Range,
    set_pitch: Range,
    set_roll: Range,
    set_speed: Range,
    wait: Ticks,
    /// The line of the label.
    goto: u8,
    label,
    set_afterburner: bool,
    runaway: Ticks,
    attack: Ticks,
    attack_massive,
    out_of_action_sphere: Ticks,
    set_mirror,
    @"if": If,
    /// The line of the matching `Endif`.
    @"else": u8,
    endif,
    avoid: Ticks,
    cloak: bool,
    attack_medium_fighter: Ticks,
    new_attack_run: bool,
    run_to_ship,
    end_script,
};

pub const Error = error{
    /// A command the payload does not know, which it stops on with "Syntax error %s".
    UnknownCommand,
    /// Arguments that do not open with `(` and close with `)`, commas between.
    SyntaxError,
    /// A `Goto` whose label no line holds: "Invalid goto".
    InvalidGoto,
    /// An `If` or `Else` with no `Endif` after it: "no endif for if".
    NoEndif,
    /// An `If` asking anything but `Goingtocrash`, whose condition the payload leaves unwritten.
    UnknownCondition,
    /// A jump to a line past 255, which the payload's one byte cannot hold.
    LineOutOfRange,
};

/// The longest word the payload's buffers hold, and the arguments it reads.
const max_word = 127;
const max_args = 4;

/// Command words, which compare without regard to case.
const Keyword = enum {
    setyaw,
    setpitch,
    setroll,
    setspeed,
    setafterburner,
    wait,
    attack,
    attackmassive,
    runaway,
    outofactionsphere,
    goto,
    setmirror,
    @"if",
    @"else",
    endif,
    avoid,
    cloak,
    attackmediumfighter,
    newattackrun,
    runtoship,
    endscript,

    /// The keyword `word` spells, in any case, or null for none.
    fn of(word: []const u8) ?Keyword {
        if (word.len > max_word) return null;
        var lowered: [max_word]u8 = undefined;
        return std.meta.stringToEnum(Keyword, std.ascii.lowerString(&lowered, word));
    }
};

/// A cursor over one line.
const Cursor = struct {
    text: []const u8,
    at: usize = 0,

    /// `script_skip_spaces` (`0x00404F00`): moves past spaces and tabs.
    fn skipSpaces(cursor: *Cursor) void {
        while (cursor.at < cursor.text.len and (cursor.text[cursor.at] == ' ' or cursor.text[cursor.at] == '\t')) {
            cursor.at += 1;
        }
    }

    /// The character at the cursor, or null at the line's end.
    fn peek(cursor: Cursor) ?u8 {
        return if (cursor.at < cursor.text.len) cursor.text[cursor.at] else null;
    }

    /// The next word, possibly empty.
    fn word(cursor: *Cursor) []const u8 {
        cursor.skipSpaces();
        const start = cursor.at;
        while (cursor.peek()) |c| switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '.', ':', '-' => cursor.at += 1,
            else => break,
        };
        return cursor.text[start..cursor.at];
    }

    /// An argument list: `(`, words separated by commas, `)`. After the fourth argument a comma
    /// ends the list, the rest of the line unread, as in the payload.
    fn args(cursor: *Cursor, out: *[max_args][]const u8) Error![]const []const u8 {
        cursor.skipSpaces();
        if (cursor.peek() != '(') return error.SyntaxError;
        cursor.at += 1;
        var count: usize = 0;
        while (true) {
            out[count] = cursor.word();
            count += 1;
            cursor.skipSpaces();
            const c = cursor.peek() orelse return error.SyntaxError;
            cursor.at += 1;
            switch (c) {
                ')' => return out[0..count],
                ',' => if (count == max_args) return out[0..count],
                else => return error.SyntaxError,
            }
        }
    }
};

/// The line's first word.
fn firstWord(text: []const u8) []const u8 {
    var cursor: Cursor = .{ .text = text };
    return cursor.word();
}

/// C's `atoi`, which reads as `atol` does (`profile.atol`): an optional sign and the digits after
/// it, or 0; kept to the low 16 bits, as the payload stores it.
fn atoi(text: []const u8) u16 {
    return @truncate(@as(u32, @bitCast(profile.atol(text))));
}

/// C's `atof`, for the numbers words can hold: an optional sign, digits and a point, or 0.
fn atof(text: []const u8) f32 {
    var end: usize = 0;
    if (end < text.len and (text[end] == '-' or text[end] == '+')) end += 1;
    var point = false;
    while (end < text.len) : (end += 1) {
        switch (text[end]) {
            '0'...'9' => {},
            '.' => if (point) break else {
                point = true;
            },
            else => break,
        }
    }
    return std.fmt.parseFloat(f32, text[0..end]) catch 0;
}

/// A command's range of numbers: its first argument and its second, or its only one for both
/// (`atof`).
fn range(cursor: *Cursor) Error!Range {
    var buffer: [max_args][]const u8 = undefined;
    const list = try cursor.args(&buffer);
    return if (list.len == 1)
        .{ .min = atof(list[0]), .max = atof(list[0]) }
    else
        .{ .min = atof(list[0]), .max = atof(list[1]) };
}

/// The same for a range of ticks (`atoi`).
fn ticks(cursor: *Cursor) Error!Ticks {
    var buffer: [max_args][]const u8 = undefined;
    const list = try cursor.args(&buffer);
    return if (list.len == 1)
        .{ .min = atoi(list[0]), .max = atoi(list[0]) }
    else
        .{ .min = atoi(list[0]), .max = atoi(list[1]) };
}

/// Whether the first argument is `on`.
fn onOff(cursor: *Cursor) Error!bool {
    var buffer: [max_args][]const u8 = undefined;
    const list = try cursor.args(&buffer);
    return std.ascii.eqlIgnoreCase(list[0], "on");
}

/// Line `index` as an instruction holds it, in a byte: a script too long for that fails to compile
/// (`error.LineOutOfRange`).
fn line(index: usize) Error!u8 {
    return std.math.cast(u8, index) orelse error.LineOutOfRange;
}

/// The line of the `Endif` that closes the block opening at `after`, or with `stop_at_else` of an
/// `Else` at the same depth, whichever comes first.
fn matchingEnd(lines: []const []const u8, after: usize, stop_at_else: bool) Error!u8 {
    var depth: usize = 0;
    for (lines[after + 1 ..], after + 1..) |text, index| {
        const keyword = Keyword.of(firstWord(text)) orelse continue;
        switch (keyword) {
            .@"if" => depth += 1,
            .endif => if (depth == 0) return line(index) else {
                depth -= 1;
            },
            .@"else" => if (stop_at_else and depth == 0) return line(index),
            else => {},
        }
    }
    return error.NoEndif;
}

/// Compiles line `index` of `lines`, which it needs whole for jumps.
pub fn compileLine(lines: []const []const u8, index: usize) Error!Instruction {
    var cursor: Cursor = .{ .text = lines[index] };
    const first = cursor.word();
    if (first.len != 0 and first[first.len - 1] == ':') return .label;

    const keyword = Keyword.of(first) orelse return error.UnknownCommand;
    return switch (keyword) {
        .setyaw => .{ .set_yaw = try range(&cursor) },
        .setpitch => .{ .set_pitch = try range(&cursor) },
        .setroll => .{ .set_roll = try range(&cursor) },
        .setspeed => .{ .set_speed = try range(&cursor) },
        .setafterburner => .{ .set_afterburner = try onOff(&cursor) },
        .cloak => .{ .cloak = try onOff(&cursor) },
        .wait => .{ .wait = try ticks(&cursor) },
        .runaway => .{ .runaway = try ticks(&cursor) },
        .attack => .{ .attack = try ticks(&cursor) },
        .outofactionsphere => .{ .out_of_action_sphere = try ticks(&cursor) },
        .avoid => .{ .avoid = try ticks(&cursor) },
        .attackmediumfighter => .{ .attack_medium_fighter = try ticks(&cursor) },
        .attackmassive => .attack_massive,
        .setmirror => .set_mirror,
        .endif => .endif,
        .runtoship => .run_to_ship,
        .endscript => .end_script,
        .newattackrun => blk: {
            var buffer: [max_args][]const u8 = undefined;
            const list = try cursor.args(&buffer);
            break :blk .{ .new_attack_run = list.len == 1 and std.ascii.eqlIgnoreCase(list[0], "true") };
        },
        .goto => blk: {
            const label = cursor.word();
            for (lines, 0..) |text, target| {
                if (text.len == label.len + 1 and text[label.len] == ':' and
                    std.ascii.eqlIgnoreCase(text[0..label.len], label))
                {
                    break :blk .{ .goto = try line(target) };
                }
            }
            return error.InvalidGoto;
        },
        .@"if" => blk: {
            const condition: Condition = if (std.ascii.eqlIgnoreCase(cursor.word(), "Goingtocrash"))
                .going_to_crash
            else
                return error.UnknownCondition;
            break :blk .{ .@"if" = .{ .condition = condition, .otherwise = try matchingEnd(lines, index, true) } };
        },
        .@"else" => .{ .@"else" = try matchingEnd(lines, index, false) },
    };
}

/// Compiles every line of a script known at compile time, where a line that does not compile is a
/// compile error.
pub fn compile(comptime lines: []const []const u8) [lines.len]Instruction {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var out: [lines.len]Instruction = undefined;
        for (&out, 0..) |*instruction, index| {
            instruction.* = compileLine(lines, index) catch |err|
                @compileError(std.fmt.comptimePrint("line {d}, \"{s}\": {s}", .{ index, lines[index], @errorName(err) }));
        }
        break :blk out;
    };
}

test "commands and their arguments" {
    const script = [_][]const u8{
        "Cloak(on)",
        "SetAfterburner(off)",
        "loop:",
        "\tSetMirror",
        "\tSetPitch(0.5, 1)",
        "\tSetRoll(-1)",
        "\tRunAway(50, 100)",
        "\tWait(1000)",
        "\tAttackMediumFighter(100)",
        "\tNewAttackRun(true)",
        "\tNewAttackRun(false)",
        "\tAttackmassive()",
        "RunToShip()",
        "EndScript()",
        "\tGoto loop",
    };
    const compiled = compile(&script);
    try std.testing.expectEqual(true, compiled[0].cloak);
    try std.testing.expectEqual(false, compiled[1].set_afterburner);
    try std.testing.expectEqual(Opcode.label, std.meta.activeTag(compiled[2]));
    try std.testing.expectEqual(Opcode.set_mirror, std.meta.activeTag(compiled[3]));
    try std.testing.expectEqual(Range{ .min = 0.5, .max = 1 }, compiled[4].set_pitch);
    try std.testing.expectEqual(Range{ .min = -1, .max = -1 }, compiled[5].set_roll);
    try std.testing.expectEqual(Ticks{ .min = 50, .max = 100 }, compiled[6].runaway);
    try std.testing.expectEqual(Ticks{ .min = 1000, .max = 1000 }, compiled[7].wait);
    try std.testing.expectEqual(Ticks{ .min = 100, .max = 100 }, compiled[8].attack_medium_fighter);
    try std.testing.expect(compiled[9].new_attack_run);
    try std.testing.expect(!compiled[10].new_attack_run);
    try std.testing.expectEqual(Opcode.attack_massive, std.meta.activeTag(compiled[11]));
    try std.testing.expectEqual(Opcode.run_to_ship, std.meta.activeTag(compiled[12]));
    try std.testing.expectEqual(Opcode.end_script, std.meta.activeTag(compiled[13]));
    try std.testing.expectEqual(2, compiled[14].goto);
}

test "if, else and endif find their ends, nested ones aside" {
    const script = [_][]const u8{
        "loop:",
        "\tIf Goingtocrash",
        "\t\tIf Goingtocrash",
        "\t\t\tAvoid(300)",
        "\t\tEndif",
        "\tElse",
        "\t\tAttack(25)",
        "\tEndif",
        "\tGoto loop",
    };
    const compiled = compile(&script);
    try std.testing.expectEqual(If{ .condition = .going_to_crash, .otherwise = 5 }, compiled[1].@"if");
    try std.testing.expectEqual(If{ .condition = .going_to_crash, .otherwise = 4 }, compiled[2].@"if");
    try std.testing.expectEqual(7, compiled[5].@"else");
    try std.testing.expectEqual(Opcode.endif, std.meta.activeTag(compiled[7]));
}

test "errors" {
    const lines = [_][]const u8{ "Fly(1)", "Wait 10", "Goto nowhere", "If Goingtocrash", "If Lost", "Else", "SetYaw(1; 2)" };
    try std.testing.expectError(error.UnknownCommand, compileLine(&lines, 0));
    try std.testing.expectError(error.SyntaxError, compileLine(&lines, 1));
    try std.testing.expectError(error.InvalidGoto, compileLine(&lines, 2));
    try std.testing.expectError(error.NoEndif, compileLine(&lines, 3));
    try std.testing.expectError(error.UnknownCondition, compileLine(&lines, 4));
    try std.testing.expectError(error.NoEndif, compileLine(&lines, 5));
    try std.testing.expectError(error.SyntaxError, compileLine(&lines, 6));
}

test "keywords ignore case, labels do not need to match it either" {
    const lines = [_][]const u8{ "LOOP:", "setspeed(1)", "GOTO loop", "Runtoship()" };
    try std.testing.expectEqual(Range{ .min = 1, .max = 1 }, (try compileLine(&lines, 1)).set_speed);
    try std.testing.expectEqual(0, (try compileLine(&lines, 2)).goto);
    try std.testing.expectEqual(Opcode.run_to_ship, std.meta.activeTag(try compileLine(&lines, 3)));
}

test "four arguments at most" {
    const lines = [_][]const u8{"SetYaw(1, 2, 3, 4, 5, 6"};
    try std.testing.expectEqual(Range{ .min = 1, .max = 2 }, (try compileLine(&lines, 0)).set_yaw);
}

test "numbers read as C reads them" {
    try std.testing.expectEqual(1000, atoi("1000"));
    try std.testing.expectEqual(0, atoi("abc"));
    try std.testing.expectEqual(0xFFFF, atoi("-1"));
    try std.testing.expectEqual(0.5, atof("0.5"));
    try std.testing.expectEqual(-1, atof("-1"));
    try std.testing.expectEqual(0, atof("on"));
    try std.testing.expectEqual(2.5, atof("2.5.1"));
}
