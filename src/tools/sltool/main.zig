//! sltool: command-line front end to the `openreliant` format library.

const std = @import("std");
const Io = std.Io;

const files = @import("openreliant").engine.files;
const version = @import("version");

const cd = @import("cd.zig");
const dte = @import("dte.zig");
const fat = @import("fat.zig");
const fm8 = @import("fm8.zig");
const fnt = @import("fnt.zig");
const hog = @import("hog.zig");
const render = @import("render.zig");
const save = @import("save.zig");
const shp = @import("shp.zig");
const speech = @import("speech.zig");
const spr = @import("spr.zig");
const stats = @import("stats.zig");
const tcache = @import("tcache.zig");

/// What every subcommand needs to do its work.
pub const Context = struct {
    io: Io,
    arena: std.mem.Allocator,
    stdout: *Io.Writer,

    /// The bytes of the file at `path`, in the arena.
    pub fn readInput(ctx: Context, path: []const u8) ![]u8 {
        return Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(files.max_file_size));
    }

    /// The directory at `path`, made where it is missing, open to write files into.
    pub fn outputDir(ctx: Context, path: []const u8) !Io.Dir {
        try Io.Dir.cwd().createDirPath(ctx.io, path);
        return Io.Dir.cwd().openDir(ctx.io, path, .{});
    }
};

/// The verb of a group's command, the first of `args`, and the operands after it. `Group` is a
/// group's command type, a union with a field for each verb.
pub fn verbOf(comptime Group: type, args: []const [:0]const u8) error{Usage}!struct { std.meta.Tag(Group), []const [:0]const u8 } {
    if (args.len == 0) return error.Usage;
    const verb = std.meta.stringToEnum(std.meta.Tag(Group), args[0]) orelse return error.Usage;
    return .{ verb, args[1..] };
}

/// The command `verb` makes of `operands`: one for each of its fields, which are all strings, in
/// their order.
pub fn positional(comptime Group: type, comptime verb: std.meta.Tag(Group), operands: []const [:0]const u8) error{Usage}!Group {
    const Operands = @FieldType(Group, @tagName(verb));
    const fields = @typeInfo(Operands).@"struct".fields;
    if (operands.len != fields.len) return error.Usage;
    var command: Operands = undefined;
    inline for (fields, 0..) |field, i| @field(command, field.name) = operands[i];
    return @unionInit(Group, @tagName(verb), command);
}

const Command = union(enum) {
    cd: cd.Command,
    dte: dte.Command,
    fat: fat.Command,
    fm8: fm8.Command,
    fnt: fnt.Command,
    hog: hog.Command,
    render: render.Command,
    save: save.Command,
    shp: shp.Command,
    speech: speech.Command,
    spr: spr.Command,
    stats: stats.Command,
    tcache: tcache.Command,
    help,
    @"--version",

    /// What `--version` shows, as `openreliant --version` shows its own.
    const version_line = "sltool " ++ version.string ++ "\n";

    const usage = "sltool " ++ version.string ++ " reads and writes StarLancer's files.\n\n" ++
        \\usage: sltool <command> ...
        \\
        \\commands:
        \\
    ++ cd.Command.usage ++ dte.Command.usage ++ fat.Command.usage ++ fm8.Command.usage ++ fnt.Command.usage ++ hog.Command.usage ++ render.Command.usage ++ save.Command.usage ++ shp.Command.usage ++ speech.Command.usage ++ spr.Command.usage ++ stats.Command.usage ++ tcache.Command.usage ++
        \\  help                            show this text
        \\  --version                       show the version
        \\
    ;

    fn parse(args: []const [:0]const u8) error{Usage}!Command {
        const group, const rest = try verbOf(Command, args);
        return switch (group) {
            .help => .help,
            .@"--version" => .@"--version",
            inline else => |tag| @unionInit(Command, @tagName(tag), try .parse(rest)),
        };
    }

    fn run(command: Command, ctx: Context) !void {
        switch (command) {
            .help => try ctx.stdout.writeAll(usage),
            .@"--version" => try ctx.stdout.writeAll(version_line),
            inline else => |group| try group.run(ctx),
        }
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    // Streaming, not positional: stdout may be a file that other processes also append to.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);

    const command = Command.parse(args[1..]) catch {
        std.debug.print("{s}", .{Command.usage});
        return 2;
    };
    run(command, init, arena, &stdout) catch |err| switch (err) {
        // The reader went away, as `sltool ... | head` does: stop quietly, not with a trace.
        error.WriteFailed => {
            const cause = stdout.err orelse return err;
            return if (cause == error.BrokenPipe) 0 else err;
        },
        else => return err,
    };
    return 0;
}

fn run(command: Command, init: std.process.Init, arena: std.mem.Allocator, stdout: *Io.File.Writer) !void {
    try command.run(.{ .io = init.io, .arena = arena, .stdout = &stdout.interface });
    try stdout.interface.flush();
}

test Command {
    try std.testing.expectEqual(Command.help, try Command.parse(&.{"help"}));
    // The version, alone and at the top of the usage, the build's as openreliant's is.
    try std.testing.expectEqual(Command.@"--version", try Command.parse(&.{"--version"}));
    try std.testing.expectEqualStrings("sltool " ++ version.string ++ "\n", Command.version_line);
    try std.testing.expect(std.mem.startsWith(u8, Command.usage, "sltool " ++ version.string ++ " reads"));
    try std.testing.expectError(error.Usage, Command.parse(&.{}));
    try std.testing.expectError(error.Usage, Command.parse(&.{"bogus"}));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "cd", "extract", "disc.bin" }));

    const extract = try Command.parse(&.{ "cd", "extract", "disc.bin", "out" });
    try std.testing.expectEqualStrings("disc.bin", extract.cd.extract.image);
    try std.testing.expectEqualStrings("out", extract.cd.extract.out_dir);
}

test positional {
    const Sample = union(enum) {
        one: struct { a: []const u8 },
        two: struct { a: []const u8, b: []const u8 },
    };
    const verb, const operands = try verbOf(Sample, &.{ "two", "x", "y" });
    try std.testing.expectEqual(.two, verb);
    try std.testing.expectEqualStrings("y", (try positional(Sample, .two, operands)).two.b);
    // One operand too many, and a verb the command lacks.
    try std.testing.expectError(error.Usage, positional(Sample, .one, operands));
    try std.testing.expectError(error.Usage, verbOf(Sample, &.{"three"}));
    try std.testing.expectError(error.Usage, verbOf(Sample, &.{}));
}

test Context {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out: Io.Writer.Allocating = .init(arena);
    const ctx: Context = .{ .io = std.testing.io, .arena = arena, .stdout = &out.writer };
    const base = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var made = try ctx.outputDir(try std.fmt.allocPrint(arena, "{s}/a/b", .{base}));
    defer made.close(ctx.io);
    try made.writeFile(ctx.io, .{ .sub_path = "f.txt", .data = "hello" });
    try std.testing.expectEqualStrings("hello", try ctx.readInput(try std.fmt.allocPrint(arena, "{s}/a/b/f.txt", .{base})));
}

test {
    std.testing.refAllDecls(@This());
}
