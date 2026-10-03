//! `openreliant hooks`: lists what mods' scripts can hook, with the fields each hook's handlers see
//! in `e`, or writes the definitions file for Luau's language server
//! ([`scripting.reference`](../scripting/reference.zig)).

const std = @import("std");
const Io = std.Io;

const scripting = @import("scripting");
const help = @import("help.zig");

pub const usage =
    \\usage: openreliant hooks [<hook>] [--definitions | --markdown]
    \\  <hook>         show only this hook, such as object_damage
    \\  --definitions  write the definitions file for Luau's language server (openreliant.d.luau)
    \\                 instead of the list
    \\  --markdown     write the reference page of the hooks (hooks.md) instead of the list
    \\  -h, --help     show this page
    \\
    \\Lists every hook mods' scripts can add handlers to: the game's functions, the mission's
    \\events and the engine's events, each with what it is and the fields its handlers see in e.
    \\
;

/// The files `openreliant hooks` writes in place of its list.
const Written = enum { definitions, markdown };

/// Runs `openreliant hooks` with the given arguments. Returns the exit code.
pub fn main(io: Io, args: []const [:0]const u8) !u8 {
    var out_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .initStreaming(.stdout(), io, &out_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    if (help.asked(args)) {
        try out.writeAll(usage);
        return 0;
    }
    var only: ?[]const u8 = null;
    var written: ?Written = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--definitions") and written == null) {
            written = .definitions;
        } else if (std.mem.eql(u8, arg, "--markdown") and written == null) {
            written = .markdown;
        } else if (std.mem.startsWith(u8, arg, "-") or only != null) {
            std.debug.print("{s}", .{usage});
            return 2;
        } else only = arg;
    }
    if (written) |file| {
        if (only != null) {
            std.debug.print("{s}", .{usage});
            return 2;
        }
        switch (file) {
            .definitions => try scripting.reference.writeDefinitions(out),
            .markdown => try scripting.reference.writeMarkdown(out),
        }
        return 0;
    }
    if (!try scripting.reference.writeList(out, only)) {
        std.debug.print("openreliant: there's no hook named {s}\n", .{only.?});
        return 1;
    }
    return 0;
}
