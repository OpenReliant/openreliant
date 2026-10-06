//! `sltool render ...`: draw a model against the backdrop as the game does, through Surrender's
//! pipeline and its Direct3D driver onto the software device.

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const png = openreliant.png;
const shp = openreliant.shp;
const tcache = openreliant.tcache;
const tga = openreliant.tga;
const engine = openreliant.engine;
const math = engine.surrender.math;
const srapi = engine.surrender.surrenderlib.srapi;
const srcore = engine.surrender.surrenderlib.srcore;
const srtexture = engine.surrender.surrenderlib.srtexture;
const srd3d = engine.surrender.srd3d;
const backdrop = engine.game.backdrop;
const camera = engine.game.camera;
const nebula = engine.game.nebula;
const objects = engine.game.objects;
const srofiles = engine.game.srofiles;

const Context = @import("main.zig").Context;
const Library = @import("library.zig").Library;

pub const Command = struct {
    /// The extracted `resource.hog`: the palette, `starref12.tga`, `space.tga` and the models.
    resources: []const u8,
    /// `tcachehw.dat`.
    cache: []const u8,
    out: []const u8,
    model: ?[]const u8 = null,
    nebula: usize = nebula.default_nebula,
    width: u32 = 1280,
    height: u32 = 720,
    /// Where the camera looks.
    toward: [3]f32 = .{ -1, 0, 0 },
    /// Where the model's nose points.
    heading: [3]f32 = .{ 1, -0.25, 0.75 },
    /// How far ahead of the camera the model is; by default, far enough to fill most of the view.
    distance: ?f32 = null,
    /// The view the camera is in, which decides whether the lens flares show.
    view: camera.View = .chase,

    pub const usage =
        \\  render <resource-dir> <tcachehw.dat> <out.png> [--model <file>] [--nebula <0-6>]
        \\         [--size <w>x<h>] [--toward <x,y,z>] [--heading <x,y,z>] [--distance <d>]
        \\         [--cockpit]
        \\                                  draw a model against the backdrop as the game does,
        \\                                  looking along a direction with Y down; the flares show
        \\                                  but from the cockpit
        \\
    ;

    pub fn parse(args: []const [:0]const u8) error{Usage}!Command {
        if (args.len < 3) return error.Usage;
        var command: Command = .{ .resources = args[0], .cache = args[1], .out = args[2] };
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--cockpit")) {
                command.view = .cockpit;
                continue;
            }
            const option = std.meta.stringToEnum(Option, args[i]) orelse return error.Usage;
            i += 1;
            if (i == args.len) return error.Usage;
            const value = args[i];
            switch (option) {
                .@"--model" => command.model = value,
                .@"--nebula" => {
                    command.nebula = std.fmt.parseInt(usize, value, 10) catch return error.Usage;
                    if (command.nebula >= nebula.nebulae.len) return error.Usage;
                },
                .@"--size" => {
                    const x = std.mem.findScalar(u8, value, 'x') orelse return error.Usage;
                    command.width = std.fmt.parseInt(u32, value[0..x], 10) catch return error.Usage;
                    command.height = std.fmt.parseInt(u32, value[x + 1 ..], 10) catch return error.Usage;
                    if (command.width == 0 or command.height == 0 or command.width > max_side or command.height > max_side) return error.Usage;
                },
                .@"--toward" => command.toward = try direction(value),
                .@"--heading" => command.heading = try direction(value),
                .@"--distance" => command.distance = std.fmt.parseFloat(f32, value) catch return error.Usage,
            }
        }
        return command;
    }

    /// The options that take a value.
    const Option = enum { @"--model", @"--nebula", @"--size", @"--toward", @"--heading", @"--distance" };

    /// The widest and tallest picture `--size` asks for.
    const max_side = 16384;

    /// The share of the picture's height the model's radius takes at the default distance.
    const fill = 0.35;

    pub fn run(command: Command, ctx: Context) !void {
        try draw(ctx, command);
    }
};

/// `x,y,z`, not zero.
fn direction(text: []const u8) error{Usage}![3]f32 {
    var out: [3]f32 = undefined;
    var parts = std.mem.splitScalar(u8, text, ',');
    for (&out) |*c| c.* = std.fmt.parseFloat(f32, parts.next() orelse return error.Usage) catch return error.Usage;
    if (parts.next() != null or math.length(out) == 0 or !std.math.isFinite(math.length(out))) return error.Usage;
    return out;
}

fn draw(ctx: Context, command: Command) !void {
    const gpa = ctx.arena;
    var resources: Library = try .open(ctx, command.resources);
    defer resources.deinit();

    const cache: tcache.Cache = try .parse(gpa, try ctx.readInput(command.cache));
    const palette = try tga.palette(try need(&resources, "palette.tga"));
    var textures: srtexture.Table = .init(gpa, cache, palette);
    defer textures.deinit();

    // The game's view, unstretched, from the middle of the backdrop.
    var context: srapi.Context = .{
        .camera = .{ .position = @splat(0), .orientation = math.lookAt(math.normalize(command.toward)) },
        .projection = (camera.Camera{}).projection(command.width, command.height),
    };

    var rand: openreliant.engine.random.Random = .{};
    const star_map = try tga.decode(gpa, try need(&resources, backdrop.star_map_name));
    const space = try backdrop.Backdrop.create(gpa, &textures, star_map, &rand, context.projection.near, .original);
    defer space.destroy(gpa);
    const sky = try nebula.Sky.create(gpa, &textures, try tga.decode(gpa, try need(&resources, nebula.dome_image_name)));
    defer sky.destroy(gpa);
    try sky.select(&textures, command.nebula, &space.lights);

    var object: ?objects.Model = null;
    var polygons: usize = 0;
    if (command.model) |name| {
        const model = try gpa.create(shp.Model);
        model.* = try resources.load(name) orelse {
            std.debug.print("no model {s} in {s}\n", .{ name, command.resources });
            return error.FileNotFound;
        };
        const loaded = try srofiles.modelLoad(gpa, &textures, model, .{}, false);
        var placed: objects.Model = try .create(gpa, model, &loaded, .{ .light_sprites = try .load(&textures) });
        engine.game.gameobj.linkParts(&placed, model);
        const distance = command.distance orelse @max(placed.radius, 1) * context.projection.scale[1] / (Command.fill * @as(f32, @floatFromInt(command.height)));
        placed.place(math.normalize(command.toward) * @as(math.Vector, @splat(distance)), math.lookAt(math.normalize(command.heading)));
        for (loaded.parts) |part| polygons += part.meshes[0].polygons.len;
        object = placed;
    }

    var software: srd3d.software.Software = try .init(gpa, command.width, command.height);
    defer software.deinit(gpa);
    var driver: srd3d.srd3d.Driver = try .init(gpa, software.interface());
    defer driver.deinit();
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);

    // Two frames, as the game draws them one after another: the first finds how much of the sun
    // shows, which the second draws by.
    for (0..2) |_| {
        var frame_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer frame_arena.deinit();
        scene.clear();
        if (object) |*o| try o.draw(gpa, &scene, .world, .{ .camera = context.camera.position });
        try space.frame(gpa, &scene, &context, command.view, .open);
        try sky.frame(gpa, &scene, &context);
        try srcore.render(frame_arena.allocator(), &context, &scene, driver.interface(), null);
    }

    if (std.Io.Dir.path.dirname(command.out)) |dir| try Io.Dir.cwd().createDirPath(ctx.io, dir);
    const file = try Io.Dir.cwd().createFile(ctx.io, command.out, .{});
    defer file.close(ctx.io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(ctx.io, &buffer);
    try png.writeRgba(gpa, &writer.interface, command.width, command.height, try software.rgba(gpa));
    try writer.interface.flush();
    try ctx.stdout.print("wrote {s}: {d} polygons in the model's finest levels, sun visibility {d:.1}\n", .{ command.out, polygons, context.sun_visibility });
}

fn need(resources: *Library, name: []const u8) ![]u8 {
    return try resources.read(name) orelse {
        std.debug.print("no {s} in the resource directory\n", .{name});
        return error.FileNotFound;
    };
}

test Command {
    const plain = try Command.parse(&.{ "resource", "tcachehw.dat", "out.png" });
    try std.testing.expectEqual(null, plain.model);
    try std.testing.expectEqual(1280, plain.width);
    try std.testing.expectEqual(camera.View.chase, plain.view);

    const full = try Command.parse(&.{
        "resource", "tcachehw.dat", "out.png",   "--model",  "USLF_Prd.SHP", "--nebula",   "5",
        "--size",   "640x480",      "--cockpit", "--toward", "1,-0.5,0.2",   "--distance", "900",
    });
    try std.testing.expectEqualStrings("USLF_Prd.SHP", full.model.?);
    try std.testing.expectEqual(5, full.nebula);
    try std.testing.expectEqual(480, full.height);
    try std.testing.expectEqual(camera.View.cockpit, full.view);
    try std.testing.expectEqual([3]f32{ 1, -0.5, 0.2 }, full.toward);
    try std.testing.expectEqual(900, full.distance.?);

    try std.testing.expectError(error.Usage, Command.parse(&.{ "resource", "tcachehw.dat" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "resource", "tcachehw.dat", "out.png", "--nebula", "7" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "resource", "tcachehw.dat", "out.png", "--size", "640" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "resource", "tcachehw.dat", "out.png", "--toward", "0,0,0" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "resource", "tcachehw.dat", "out.png", "--toward", "1,2" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "resource", "tcachehw.dat", "out.png", "--model" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "resource", "tcachehw.dat", "out.png", "--bogus" }));
}
