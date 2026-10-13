//! `build-mission <source> <mission>`: compiles mission source into a mission file for the build,
//! with the compiler `sltool dte build` uses (`source_parser.build`), built for the host. The build
//! makes mission 0 with it, from `src/openreliant/mission0.mission.luau`
//! ([Mission source](../../docs/formats/mission-source.md)).

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const source_parser = @import("source_parser");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: build-mission <source> <mission>\n", .{});
        return 2;
    }
    var failure: openreliant.dte.source.compile.Failure = undefined;
    source_parser.buildFile(init.io, arena, Io.Dir.cwd(), args[1], args[2], &failure) catch |err| switch (err) {
        error.Invalid => {
            std.debug.print("{s}:{f}\n", .{ args[1], failure });
            return 1;
        },
        else => return err,
    };
    return 0;
}
