//! Drawing for player and menu scripts ([#498](https://github.com/OpenReliant/openreliant/issues/498)):
//! text, lines and rectangles a script draws over the flight display (`openreliant.hud`) or over
//! the menus (`openreliant.ui`), and the lines and text it places in the world
//! (`openreliant.debug`).
//!
//! What a script draws in `on_frame` is recorded (`Layer`), and drawn over the frame as it's
//! finished, after the game's own display or menu. Each frame starts with nothing drawn. Places
//! are in the window's pixels, from its top left corner; the debug's are in the world, and drawn
//! where the camera sees them. Text is drawn in the font the display or the menu writes with, at the
//! size the game draws its own (`View.scale`), times the style's `scale`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const engine = openreliant.engine;
const hud = engine.game.hud;
const language = engine.game.language;
const device = engine.surrender.srd3d.device;
const api = @import("api.zig");
const Call = api.Call;
const presentation = @import("presentation.zig");

/// Where a script draws.
pub const Which = enum {
    /// Over the flight display, while the game's own is shown.
    hud,
    /// Over the menus: the front end's screens, and the pause menu.
    ui,
};

/// The most a script can draw on one layer in one frame: things drawn, and bytes of text.
pub const max_commands = 4096;
pub const max_text = 1 << 16;

/// A colour, red, green and blue each from 0 to 1, as a vector.
const Colour = @Vector(3, f32);

/// The colour things are drawn in where the style leaves it out: white.
const default_colour: Colour = @splat(1);

/// How a script's text is drawn.
pub const TextStyle = struct {
    /// Red, green and blue, each from 0 to 1.
    colour: Colour = default_colour,
    /// How opaque it is, from 0 to 1.
    alpha: f32 = 1,
    /// How many times the game's own size it's drawn at.
    scale: f32 = 1,
    /// Where the text stands from the place it's drawn at.
    @"align": hud.Align = .left,
};

/// How a script's line is drawn.
pub const LineStyle = struct {
    colour: Colour = default_colour,
    alpha: f32 = 1,
    /// How many of the game's own pixels wide it is.
    width: f32 = 1,
};

/// How a script's rectangle is filled.
pub const FillStyle = struct {
    colour: Colour = default_colour,
    alpha: f32 = 1,
};

/// How big a line of text is drawn, in the window's pixels.
pub const Size = struct {
    width: f32,
    height: f32,
};

/// What a layer is drawn on this frame, as the driver tells it (`presentation.Host`).
pub const View = struct {
    /// The font the display or the menu writes with, and what its owner keeps its glyphs' images
    /// in.
    font: *hud.Opened,
    gpa: Allocator,
    /// The window's size in pixels.
    screen: [2]u32,
    /// How many of the window's pixels one of the game's own spans.
    scale: f32,
};

/// A place to draw at: in the window's pixels, or in the world.
const Where = union(enum) {
    screen: [2]f32,
    world: @Vector(3, f32),
};

/// Something a script drew, which `Layer.draw` draws.
const Command = union(enum) {
    text: struct { at: Where, start: u32, len: u32, colour: [4]f32, scale: f32, alignment: hud.Align },
    line: struct { from: Where, to: Where, colour: [4]f32, width: f32 },
    rectangle: struct { from: [2]f32, to: [2]f32, colour: [4]f32 },
};

/// What scripts draw on one layer in a frame.
pub const Layer = struct {
    commands: std.ArrayList(Command) = .empty,
    /// The bytes of the text drawn, in the game's code page.
    text: std.ArrayList(u8) = .empty,

    pub fn deinit(layer: *Layer, gpa: Allocator) void {
        layer.commands.deinit(gpa);
        layer.text.deinit(gpa);
    }

    /// Forgets what was drawn, as a frame starts.
    pub fn clear(layer: *Layer) void {
        layer.commands.clearRetainingCapacity();
        layer.text.clearRetainingCapacity();
    }

    fn add(layer: *Layer, gpa: Allocator, call: Call, command: Command) void {
        if (layer.commands.items.len == max_commands) call.raise("at most {d} things can be drawn in one frame", .{max_commands});
        layer.commands.append(gpa, command) catch call.raise("out of memory drawing", .{});
    }

    /// Keeps `words`, UTF-8, in the game's code page, and returns where they went in `text`.
    fn keep(layer: *Layer, gpa: Allocator, call: Call, words: []const u8) struct { u32, u32 } {
        if (layer.text.items.len + words.len > max_text) call.raise("at most {d} bytes of text can be drawn in one frame", .{max_text});
        const start = layer.text.items.len;
        const room = layer.text.addManyAsSlice(gpa, words.len) catch call.raise("out of memory drawing", .{});
        const kept = language.encode(room, words);
        layer.text.shrinkRetainingCapacity(start + kept.len);
        return .{ @intCast(start), @intCast(kept.len) };
    }

    /// Draws what was drawn on `view`, into `into`. `sight` places what was drawn in the world;
    /// where it's null, that's left out.
    pub fn draw(layer: *const Layer, into: device.Device, view: View, sight: ?hud.Sight) Allocator.Error!void {
        for (layer.commands.items) |command| switch (command) {
            .text => |text| {
                const at = place(text.at, sight) orelse continue;
                const words = layer.text.items[text.start..][0..text.len];
                _ = try hud.drawText(view.font, view.gpa, into, .{ hud.round(at[0]), hud.round(at[1]) }, words, text.colour, text.alignment, text.scale * view.scale);
            },
            .line => |line| {
                const from = place(line.from, sight) orelse continue;
                const to = place(line.to, sight) orelse continue;
                hud.drawLine(into, from, to, line.colour, line.width * view.scale);
            },
            .rectangle => |rectangle| hud.drawFilled(into, .{
                .left = @min(rectangle.from[0], rectangle.to[0]),
                .top = @min(rectangle.from[1], rectangle.to[1]),
                .right = @max(rectangle.from[0], rectangle.to[0]),
                .bottom = @max(rectangle.from[1], rectangle.to[1]),
            }, rectangle.colour),
        };
    }
};

/// Where `where` is drawn in the window; null for a place in the world `sight` doesn't see.
fn place(where: Where, sight: ?hud.Sight) ?hud.Point {
    return switch (where) {
        .screen => |at| at,
        .world => |at| {
            const seen = sight orelse return null;
            const pixel = seen.pixel(seen.view(at)) orelse return null;
            return .{ @floatFromInt(pixel[0]), @floatFromInt(pixel[1]) };
        },
    };
}

/// `colour` and `alpha` as the device takes them, each held from 0 to 1.
fn rgba(colour: Colour, alpha: f32) [4]f32 {
    const held = std.math.clamp(colour, @as(Colour, @splat(0)), @as(Colour, @splat(1)));
    return .{ held[0], held[1], held[2], std.math.clamp(alpha, 0, 1) };
}

/// The point of the window a vector names: its first two components.
fn screenPoint(at: @Vector(3, f32)) [2]f32 {
    return .{ at[0], at[1] };
}

/// Records text at `at` on the layer `which`.
fn recordText(call: Call, which: Which, at: Where, words: []const u8, given: ?TextStyle) void {
    const shown = presentation.Presentation.of(call, "text");
    const style = given orelse TextStyle{};
    const layer = shown.layers.getPtr(which);
    const start, const len = layer.keep(shown.gpa, call, words);
    layer.add(shown.gpa, call, .{ .text = .{ .at = at, .start = start, .len = len, .colour = rgba(style.colour, style.alpha), .scale = @max(style.scale, 0), .alignment = style.@"align" } });
}

/// Records a line on the layer `which`.
fn recordLine(call: Call, which: Which, from: Where, to: Where, given: ?LineStyle) void {
    const shown = presentation.Presentation.of(call, "line");
    const style = given orelse LineStyle{};
    shown.layers.getPtr(which).add(shown.gpa, call, .{ .line = .{ .from = from, .to = to, .colour = rgba(style.colour, style.alpha), .width = @max(style.width, 0) } });
}

/// The functions of a package that draws on the layer `which` (`openreliant.hud`,
/// `openreliant.ui`).
pub fn Package(comptime which: Which) type {
    return struct {
        pub const shown = api.Field(bool, "Whether it's shown this frame, which is when what's drawn on it shows, and its other fields can be read.", struct {
            pub fn get(call: Call) bool {
                return presentation.Presentation.of(call, @tagName(which)).views.get(which) != null;
            }
        });

        pub const width = api.Field(u32, "The window's width, in pixels.", struct {
            pub fn get(call: Call) u32 {
                return viewOf(call).screen[0];
            }
        });

        pub const height = api.Field(u32, "The window's height, in pixels.", struct {
            pub fn get(call: Call) u32 {
                return viewOf(call).screen[1];
            }
        });

        pub const text = api.Function("Draws `text` at `at`, in pixels from the window's top left corner, in the game's font, as `style` says.", &.{ "at", "text", "style" }, struct {
            fn draw(call: Call, at: @Vector(3, f32), words: []const u8, style: ?TextStyle) void {
                recordText(call, which, .{ .screen = screenPoint(at) }, words, style);
            }
        }.draw);

        pub const line = api.Function("Draws a line from `from` to `to`, in pixels, as `style` says.", &.{ "from", "to", "style" }, struct {
            fn draw(call: Call, from: @Vector(3, f32), to: @Vector(3, f32), style: ?LineStyle) void {
                recordLine(call, which, .{ .screen = screenPoint(from) }, .{ .screen = screenPoint(to) }, style);
            }
        }.draw);

        pub const rectangle = api.Function("Fills the rectangle between the corners `from` and `to`, in pixels, as `style` says.", &.{ "from", "to", "style" }, struct {
            fn draw(call: Call, from: @Vector(3, f32), to: @Vector(3, f32), given: ?FillStyle) void {
                const scripts = presentation.Presentation.of(call, "rectangle");
                const style = given orelse FillStyle{};
                scripts.layers.getPtr(which).add(scripts.gpa, call, .{ .rectangle = .{ .from = screenPoint(from), .to = screenPoint(to), .colour = rgba(style.colour, style.alpha) } });
            }
        }.draw);

        pub const measure = api.Function("How wide and tall `text` is drawn, in pixels, at `scale` times the game's own size, or at its own size where `scale` is nil.", &.{ "text", "scale" }, struct {
            fn measure(call: Call, words: []const u8, scale: ?f32) Size {
                const view = viewOf(call);
                var buffer: [max_measured]u8 = undefined;
                const encoded = language.encode(&buffer, words);
                const times = view.scale * @max(scale orelse 1, 0);
                return .{
                    .width = @as(f32, @floatFromInt(view.font.textWidth(encoded))) * times,
                    .height = @as(f32, @floatFromInt(view.font.font.header.height)) * times,
                };
            }
        }.measure);

        /// What the layer is drawn on this frame. Raises an error where it isn't shown.
        fn viewOf(call: Call) View {
            const scripts = presentation.Presentation.of(call, @tagName(which));
            return scripts.views.get(which) orelse call.raise("{t} is only drawn while it's shown", .{which});
        }
    };
}

/// The most bytes of text `measure` measures.
const max_measured = 1024;

/// What `openreliant.debug` holds: lines and text placed in the world, drawn over the flight
/// display where the camera sees them.
pub const debug = struct {
    pub const line = api.Function("Draws a line between the points `from` and `to` of the world, as `style` says, where the camera sees them.", &.{ "from", "to", "style" }, struct {
        fn draw(call: Call, from: @Vector(3, f32), to: @Vector(3, f32), style: ?LineStyle) void {
            recordLine(call, .hud, .{ .world = from }, .{ .world = to }, style);
        }
    }.draw);

    pub const text = api.Function("Draws `text` at the point `at` of the world, as `style` says, where the camera sees it.", &.{ "at", "text", "style" }, struct {
        fn draw(call: Call, at: @Vector(3, f32), words: []const u8, style: ?TextStyle) void {
            recordText(call, .hud, .{ .world = at }, words, style);
        }
    }.draw);
};

test rgba {
    try std.testing.expectEqual([4]f32{ 1, 0, 0.5, 1 }, rgba(.{ 2, -1, 0.5 }, 3));
}
