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
const runtime = @import("runtime.zig");
const srtexture = engine.surrender.surrenderlib.srtexture;

/// Built-in font choices; the layer's default remains the default for existing scripts.
pub const Font = enum { default, hud, menu_small, menu_large };

/// Assets are cached by context and filename. Keep them until presentation shutdown because the
/// renderer may still hold images used by a preceding frame. Limits include retired contexts.
pub const max_assets = 128;
pub const max_asset_bytes = 64 * 1024 * 1024;

pub const Assets = struct {
    pictures: std.ArrayList(Picture) = .empty,
    fonts: std.ArrayList(CustomFont) = .empty,
    bytes: usize = 0,

    const Picture = struct { context: *runtime.Context, name: []u8, image: *srtexture.Image };
    const CustomFont = struct {
        context: *runtime.Context,
        name: []u8,
        outline_layout: bool,
        bytes: []u8,
        opened: *hud.Opened,
        outline: ?*hud.outline.Outline = null,
    };

    pub fn deinit(assets: *Assets, gpa: Allocator) void {
        for (assets.pictures.items) |picture| {
            picture.image.deinit(gpa);
            gpa.destroy(picture.image);
            gpa.free(picture.name);
        }
        assets.pictures.deinit(gpa);
        for (assets.fonts.items) |font| {
            font.opened.deinit(gpa);
            gpa.destroy(font.opened);
            if (font.outline) |outline| {
                outline.deinit();
                gpa.destroy(outline);
            }
            gpa.free(font.bytes);
            gpa.free(font.name);
        }
        assets.fonts.deinit(gpa);
        assets.* = .{};
    }

    fn loadPicture(assets: *Assets, call: Call, path: []const u8) !*srtexture.Image {
        for (assets.pictures.items) |picture| {
            if (picture.context == call.context and std.ascii.eqlIgnoreCase(picture.name, path)) return picture.image;
        }
        const gpa = call.runtime().gpa;
        if (assets.pictures.items.len + assets.fonts.items.len == max_assets) return error.TooManyAssets;
        const file = try readAsset(call, path);
        defer gpa.free(file);
        const pixels = try openreliant.png.readLimited(gpa, file, max_asset_bytes - assets.bytes);
        const needed = pixels.rgba.len;
        errdefer pixels.deinit(gpa);
        const name = try gpa.dupe(u8, path);
        errdefer gpa.free(name);
        const image = try gpa.create(srtexture.Image);
        errdefer gpa.destroy(image);
        try assets.pictures.ensureUnusedCapacity(gpa, 1);
        image.* = try srtexture.Image.single(gpa, pixels.width, pixels.height, pixels.rgba);
        assets.pictures.appendAssumeCapacity(.{ .context = call.context, .name = name, .image = image });
        assets.bytes += needed;
        return image;
    }

    fn loadFont(assets: *Assets, call: Call, path: []const u8, base: Font, view: View) !*hud.Opened {
        const bitmap = view.fontOf(base) orelse return error.FontUnavailable;
        const is_bitmap = std.ascii.endsWithIgnoreCase(path, ".fnt");
        if (!is_bitmap and !std.ascii.endsWithIgnoreCase(path, ".ttf") and !std.ascii.endsWithIgnoreCase(path, ".otf")) return error.InvalidFontExtension;
        // A layer's default can change across menus and flight. Cache its actual layout, not
        // the word "default", so drawing and measurement keep using the selected font's metrics.
        for (assets.fonts.items) |font| {
            const same_layout = if (is_bitmap) !font.outline_layout else font.outline_layout and std.mem.eql(u8, font.bytes, bitmap.font.bytes);
            if (font.context == call.context and same_layout and std.ascii.eqlIgnoreCase(font.name, path)) return font.opened;
        }
        if (assets.pictures.items.len + assets.fonts.items.len == max_assets) return error.TooManyAssets;
        const gpa = call.runtime().gpa;
        const file = try readAsset(call, path);
        defer gpa.free(file);
        const needed = if (is_bitmap) file.len else file.len + bitmap.font.bytes.len;
        if (needed > max_asset_bytes - assets.bytes) return error.AssetsTooLarge;
        const bytes = try gpa.dupe(u8, if (is_bitmap) file else bitmap.font.bytes);
        errdefer gpa.free(bytes);
        const opened = try gpa.create(hud.Opened);
        errdefer gpa.destroy(opened);
        opened.* = .ramp(try openreliant.fnt.Font.parse(bytes));
        var outline: ?*hud.outline.Outline = null;
        errdefer if (outline) |made| {
            made.deinit();
            gpa.destroy(made);
        };
        if (!is_bitmap) {
            const rasterizer = view.rasterizer orelse return error.OutlineFontsUnavailable;
            const kept = try gpa.dupe(u8, file);
            errdefer gpa.free(kept);
            const face = rasterizer.open(kept) orelse return error.InvalidFont;
            errdefer rasterizer.close(face);
            const fit = try hud.outline.Fit.of(rasterizer, face, opened.font, &hud.outline.level_cover, .own, gpa) orelse return error.InvalidFont;
            const made = try gpa.create(hud.outline.Outline);
            made.* = .{ .gpa = gpa, .rasterizer = rasterizer, .face = face, .file = kept, .fit = fit };
            outline = made;
            opened.outline = made;
        }
        const name = try gpa.dupe(u8, path);
        errdefer gpa.free(name);
        try assets.fonts.append(gpa, .{ .context = call.context, .name = name, .outline_layout = !is_bitmap, .bytes = bytes, .opened = opened, .outline = outline });
        assets.bytes += needed;
        return opened;
    }
};

fn readAsset(call: Call, path: []const u8) ![]u8 {
    if (!openreliant.hog.validName(path)) return error.InvalidAssetName;
    return (try call.context.modOf().readFile(call.runtime().gpa, path)) orelse error.AssetNotFound;
}

fn selectedFont(call: Call, view: View, name: ?[]const u8, base: Font) *hud.Opened {
    const asked = name orelse return view.font;
    if (std.meta.stringToEnum(Font, asked)) |builtin| return view.fontOf(builtin) orelse call.raise("font '{s}' is unavailable this frame", .{asked});
    return presentation.Presentation.of(call, "font").assets.loadFont(call, asked, base, view) catch |err| call.raise("font {s}: {s}", .{ asked, @errorName(err) });
}

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
    /// Built-in name or a font filename in the calling mod.
    font: ?[]const u8 = null,
    /// Layout/fallback for a custom outline font.
    base_font: Font = .default,
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

pub const ShapeStyle = struct {
    colour: Colour = default_colour,
    alpha: f32 = 1,
    scale: f32 = 1,
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
    fonts: std.EnumArray(Font, ?*hud.Opened) = .initFill(null),
    art: ?*hud.Art = null,
    rasterizer: ?hud.outline.Rasterizer = null,

    pub fn fontOf(view: View, font: Font) ?*hud.Opened {
        return if (font == .default) view.font else view.fonts.get(font);
    }
};

/// A place to draw at: in the window's pixels, or in the world.
const Where = union(enum) {
    screen: [2]f32,
    world: @Vector(3, f32),
};

/// Something a script drew, which `Layer.draw` draws.
const Command = union(enum) {
    text: struct { at: Where, start: u32, len: u32, colour: [4]f32, scale: f32, alignment: hud.Align, font: ?*hud.Opened, gpa: ?Allocator },
    line: struct { from: Where, to: Where, colour: [4]f32, width: f32 },
    rectangle: struct { from: [2]f32, to: [2]f32, colour: [4]f32 },
    picture: struct { image: *srtexture.Image, at: [2]f32, size: [2]f32, colour: [4]f32 },
    shape: struct { index: usize, at: [2]f32, colour: [4]f32, scale: f32 },
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
                _ = try hud.drawText(text.font orelse view.font, text.gpa orelse view.gpa, into, .{ hud.round(at[0]), hud.round(at[1]) }, words, text.colour, text.alignment, text.scale * view.scale);
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
            .picture => |picture| hud.drawImageOver(into, picture.image, .{ .left = picture.at[0], .top = picture.at[1], .right = picture.at[0] + picture.size[0], .bottom = picture.at[1] + picture.size[1] }, picture.colour),
            .shape => |shape| if (view.art) |art| {
                hud.drawShape(art, view.gpa, into, shape.index, .{ hud.round(shape.at[0]), hud.round(shape.at[1]) }, shape.colour, shape.scale * view.scale) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                };
            },
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
    // Hidden layers keep accepting commands, as before; they are not rendered this frame.
    const font = if (shown.views.get(which)) |view| selectedFont(call, view, style.font, style.base_font) else null;
    const layer = shown.layers.getPtr(which);
    const start, const len = layer.keep(shown.gpa, call, words);
    const custom = if (style.font) |name| std.meta.stringToEnum(Font, name) == null else false;
    layer.add(shown.gpa, call, .{ .text = .{ .at = at, .start = start, .len = len, .colour = rgba(style.colour, style.alpha), .scale = @max(style.scale, 0), .alignment = style.@"align", .font = font, .gpa = if (custom) shown.gpa else null } });
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
        pub const picture = api.Function("Draws a PNG from the calling mod at `at`, with `size` in window pixels (nil uses its native size), tinted by `style`. Files are cached for the script context.", &.{ "at", "file", "size", "style" }, struct {
            fn draw(call: Call, at: @Vector(3, f32), path: []const u8, size: ?@Vector(3, f32), given: ?FillStyle) void {
                const scripts = presentation.Presentation.of(call, "picture");
                const image = scripts.assets.loadPicture(call, path) catch |err| call.raise("picture {s}: {s}", .{ path, @errorName(err) });
                const style = given orelse FillStyle{};
                const extent: [2]f32 = if (size) |asked| .{ @max(asked[0], 0), @max(asked[1], 0) } else .{ @floatFromInt(image.width()), @floatFromInt(image.height()) };
                scripts.layers.getPtr(which).add(scripts.gpa, call, .{ .picture = .{ .image = image, .at = screenPoint(at), .size = extent, .colour = rgba(style.colour, style.alpha) } });
            }
        }.draw);

        pub const shape = api.Function("Draws an existing shape from this layer's game sprite set at its anchor in window pixels. style.scale multiplies the game's scale; shape IDs are the existing set indices.", &.{ "at", "index", "style" }, struct {
            fn draw(call: Call, at: @Vector(3, f32), index: u32, given: ?ShapeStyle) void {
                const view = viewOf(call);
                const art = view.art orelse call.raise("this layer has no sprite set this frame", .{});
                if (art.shape(index) == null) call.raise("no shape {d} in this layer's sprite set", .{index});
                const style = given orelse ShapeStyle{};
                const scripts = presentation.Presentation.of(call, "shape");
                scripts.layers.getPtr(which).add(scripts.gpa, call, .{ .shape = .{ .index = index, .at = screenPoint(at), .scale = @max(style.scale, 0), .colour = rgba(style.colour, style.alpha) } });
            }
        }.draw);
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

        pub const measure = api.Function("Measures text in window pixels. style may be a numeric scale (existing API) or a TextStyle selecting the same font and scale as drawing.", &.{ "text", "style" }, struct {
            fn measure(call: Call, words: []const u8, given: ?union(enum) { scale: f32, style: TextStyle }) Size {
                const view = viewOf(call);
                const style: TextStyle = if (given) |asked| switch (asked) {
                    .scale => |scale| .{ .scale = scale },
                    .style => |style| style,
                } else .{};
                const font = selectedFont(call, view, style.font, style.base_font);
                if (words.len > max_measured) call.raise("measure accepts at most {d} bytes of text", .{max_measured});
                var buffer: [max_measured]u8 = undefined;
                const encoded = language.encode(&buffer, words);
                const times = view.scale * @max(style.scale, 0);
                return .{
                    .width = @as(f32, @floatFromInt(font.textWidth(encoded))) * times,
                    .height = @as(f32, @floatFromInt(font.font.header.height)) * times,
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
