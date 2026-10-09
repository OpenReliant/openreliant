//! `sltool tim ...`: read TIM pictures, the PlayStation's own, as the PlayStation games on the
//! original's engine keep them.

const std = @import("std");

const tim = @import("openreliant").playstation.tim;

const sltool = @import("main.zig");
const Context = sltool.Context;

pub const Command = union(enum) {
    info: struct { picture: []const u8 },
    png: struct { picture: []const u8, out: []const u8 },

    pub const usage =
        \\  tim info <picture>              describe a PlayStation TIM picture
        \\  tim png <picture> <out.png>     convert a TIM picture to PNG
        \\
    ;

    pub fn parse(args: []const [:0]const u8) error{Usage}!Command {
        const verb, const operands = try sltool.verbOf(Command, args);
        return switch (verb) {
            inline else => |tag| sltool.positional(Command, tag, operands),
        };
    }

    pub fn run(command: Command, ctx: Context) !void {
        const path = switch (command) {
            inline else => |operands| operands.picture,
        };
        const picture: tim.Picture = try .parse(try ctx.readInput(path));
        switch (command) {
            .info => try ctx.stdout.print("{d}x{d}, {f}, {d} colours in its first palette\n", .{
                picture.width, picture.height, picture.depth, picture.palette.len,
            }),
            .png => |operands| try ctx.writePng(.cwd(), operands.out, picture.width, picture.height, try picture.rgba(ctx.arena)),
        }
    }
};

test Command {
    try std.testing.expectEqualStrings("PHONG1.TIM", (try Command.parse(&.{ "info", "PHONG1.TIM" })).info.picture);
    try std.testing.expectEqualStrings("out.png", (try Command.parse(&.{ "png", "PHONG1.TIM", "out.png" })).png.out);
    try std.testing.expectError(error.Usage, Command.parse(&.{ "png", "PHONG1.TIM" }));
}
