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
    const text = try Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .limited(openreliant.engine.files.max_file_size));
    var failure: openreliant.dte.source.compile.Failure = undefined;
    const bytes = source_parser.build(arena, text, &failure) catch |err| switch (err) {
        error.Invalid => {
            std.debug.print("{s}:{f}\n", .{ args[1], failure });
            return 1;
        },
        else => return err,
    };
    try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = bytes });
    return 0;
}
