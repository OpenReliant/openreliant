//! Drawing for player and menu scripts ([#498](https://github.com/OpenReliant/openreliant/issues/498)):
//! text, lines and rectangles a script draws over the flight display (`openreliant.hud`) or over
//! the menus (`openreliant.ui`), and the lines and text it places in the world
//! (`openreliant.debug`).
//!
//! What a script draws in `on_frame` is recorded (`Layer`), and drawn over the frame as it's
//! finished, after the game's display or menu. Each frame starts with nothing drawn. Places
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
const front_end = @import("front_end.zig");
const instruments = @import("instruments.zig");
const runtime = @import("runtime.zig");
const srtexture = engine.surrender.surrenderlib.srtexture;

/// Built-in font choices; the layer's default remains the default for existing scripts.
pub const Font = enum { default, hud, menu_small, menu_large };

/// The most files the mods' pictures and fonts can keep in the cache at once.
pub const max_assets = 128;
/// The most bytes their pixels and font files can take at once. A picture takes 4 bytes a pixel,
/// so a 4096x4096 picture takes 64 MiB.
pub const max_asset_bytes = 128 * 1024 * 1024;
/// How many frames a drawn picture stays in the cache, whatever needs room: the device may still
/// be drawing one drawn in the last frame.
pub const kept_frames = 2;

/// The scripts' pictures and fonts, cached by script context and file name. Each picture notes the
/// frame it was last drawn in. When a new picture or font needs room, the pictures drawn longest
/// ago make room for it (`makeRoom`), but never one drawn in the last `kept_frames`. A font stays
/// until the presentation stops.
///
/// Once the device holds a picture's pixels (`srtexture.Image.held`), the cache lets go of its own
/// copy, so a picture takes its memory only once.
pub const Assets = struct {
    pictures: std.ArrayList(Picture) = .empty,
    fonts: std.ArrayList(CustomFont) = .empty,
    bytes: usize = 0,
    /// The frame the scripts draw, from 1 for the first (`startFrame`).
    frame: u64 = 0,
    /// The pictures taken out of the cache, which `release` frees once the device lets go of them.
    taken_out: std.ArrayList(*srtexture.Image) = .empty,

    const Picture = struct {
        context: *runtime.Context,
        name: []u8,
        image: *srtexture.Image,
        /// What its pixels take of `max_asset_bytes`.
        bytes: usize,
        /// The frame it was last drawn in.
        drawn: u64,
    };
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
            picture.image.destroy(gpa);
            gpa.free(picture.name);
        }
        assets.pictures.deinit(gpa);
        for (assets.taken_out.items) |image| image.destroy(gpa);
        assets.taken_out.deinit(gpa);
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

    /// Counts a new frame of drawing, and starts it for the mods' outline fonts
    /// (`hud.outline.Outline.startFrame`), so that each keeps the sizes the frame draws it at.
    pub fn startFrame(assets: *Assets) void {
        assets.frame += 1;
        for (assets.fonts.items) |font| if (font.outline) |outline| outline.startFrame();
    }

    /// Frees the pictures taken out of the cache, which hand their textures back to the device, and
    /// lets go of the pixels of the pictures the device now holds.
    pub fn release(assets: *Assets, gpa: Allocator) void {
        for (assets.taken_out.items) |image| image.destroy(gpa);
        assets.taken_out.clearRetainingCapacity();
        for (assets.pictures.items) |picture| {
            if (picture.image.held and picture.image.readable()) picture.image.releasePixels(gpa);
        }
    }

    /// The picture `path` of the script of `call`, loaded the first time, and noted as drawn this
    /// frame.
    fn loadPicture(assets: *Assets, call: Call, path: []const u8) !*srtexture.Image {
        for (assets.pictures.items) |*picture| {
            if (picture.context != call.context or !std.ascii.eqlIgnoreCase(picture.name, path)) continue;
            picture.drawn = assets.frame;
            return picture.image;
        }
        const gpa = call.runtime().gpa;
        const file = try readAsset(call, path);
        defer gpa.free(file);
        // The header gives the room the pixels need, so that room is made before they're read.
        const across, const down = try openreliant.png.size(file);
        const needed = srtexture.Level.Format.rgba8.size(across, down);
        if (needed > max_asset_bytes) return error.PictureTooLarge;
        try assets.makeRoom(gpa, needed);
        const pixels = try openreliant.png.readLimited(gpa, file, needed);
        errdefer pixels.deinit(gpa);
        const name = try gpa.dupe(u8, path);
        errdefer gpa.free(name);
        const image = try gpa.create(srtexture.Image);
        errdefer gpa.destroy(image);
        try assets.pictures.ensureUnusedCapacity(gpa, 1);
        image.* = try srtexture.Image.single(gpa, pixels.width, pixels.height, pixels.rgba);
        assets.pictures.appendAssumeCapacity(.{ .context = call.context, .name = name, .image = image, .bytes = pixels.rgba.len, .drawn = assets.frame });
        assets.bytes += pixels.rgba.len;
        return image;
    }

    /// Takes pictures out of the cache until one more file of `needed` bytes fits, the one drawn
    /// longest ago first. Fails where the fonts and the pictures drawn in the last `kept_frames`
    /// leave no room.
    fn makeRoom(assets: *Assets, gpa: Allocator, needed: usize) !void {
        while (true) {
            const full = assets.pictures.items.len + assets.fonts.items.len == max_assets;
            if (!full and assets.bytes + needed <= max_asset_bytes) return;
            const index = assets.stalest() orelse return if (full) error.TooManyAssets else error.AssetsTooLarge;
            try assets.taken_out.ensureUnusedCapacity(gpa, 1);
            const picture = assets.pictures.swapRemove(index);
            assets.taken_out.appendAssumeCapacity(picture.image);
            assets.bytes -= picture.bytes;
            gpa.free(picture.name);
        }
    }

    /// The cached picture drawn longest ago, if one wasn't drawn in the last `kept_frames`.
    fn stalest(assets: *const Assets) ?usize {
        var found: ?usize = null;
        for (assets.pictures.items, 0..) |picture, index| {
            if (picture.drawn + kept_frames > assets.frame) continue;
            if (found) |oldest| if (assets.pictures.items[oldest].drawn <= picture.drawn) continue;
            found = index;
        }
        return found;
    }

    /// The mod's font `path` of the script of `call`, laid out as the built-in font `base` where
    /// it's an outline font. With outline fonts off, that's the base font itself.
    fn loadFont(assets: *Assets, call: Call, path: []const u8, base: Font, view: View) !*hud.Opened {
        const bitmap = view.fontOf(base) orelse return error.FontUnavailable;
        const is_bitmap = std.ascii.endsWithIgnoreCase(path, ".fnt");
        if (!is_bitmap and !std.ascii.endsWithIgnoreCase(path, ".ttf") and !std.ascii.endsWithIgnoreCase(path, ".otf")) return error.InvalidFontExtension;
        const rasterizer = if (is_bitmap) null else view.rasterizer orelse return bitmap;
        // A layer's default can change across menus and flight. Cache its actual layout, not
        // the word "default", so drawing and measurement keep using the selected font's metrics.
        for (assets.fonts.items) |font| {
            const same_layout = if (is_bitmap) !font.outline_layout else font.outline_layout and std.meta.activeTag(font.opened.paint) == bitmap.paint and std.mem.eql(u8, font.bytes, bitmap.font.bytes);
            if (font.context == call.context and same_layout and std.ascii.eqlIgnoreCase(font.name, path)) return font.opened;
        }
        const gpa = call.runtime().gpa;
        const file = try readAsset(call, path);
        defer gpa.free(file);
        const needed = if (is_bitmap) file.len else file.len + bitmap.font.bytes.len;
        try assets.makeRoom(gpa, needed);
        const bytes = try gpa.dupe(u8, if (is_bitmap) file else bitmap.font.bytes);
        errdefer gpa.free(bytes);
        const opened = try gpa.create(hud.Opened);
        errdefer gpa.destroy(opened);
        const font = try openreliant.fnt.Font.parse(bytes);
        opened.* = if (is_bitmap) .monochrome(font) else .like(font, bitmap.*);
        var outline: ?*hud.outline.Outline = null;
        errdefer if (outline) |made| {
            made.deinit();
            gpa.destroy(made);
        };
        if (rasterizer) |fonts| {
            // Fitted over the base font as the game's own replacement for it is
            // (`hud.Opened.standIn`), but drawn in the text's colour.
            const ink = opened.fitting() orelse return error.BaseFontHasNoInk;
            const kept = try gpa.dupe(u8, file);
            errdefer gpa.free(kept);
            const face = fonts.open(kept) orelse return error.InvalidFont;
            errdefer fonts.close(face);
            const fit = try hud.outline.Fit.of(fonts, face, opened.font, &ink.cover, .own, gpa) orelse return error.NoCapitalsInCommon;
            const made = try gpa.create(hud.outline.Outline);
            made.* = .{ .gpa = gpa, .rasterizer = fonts, .face = face, .file = kept, .fit = fit };
            outline = made;
            opened.outline = made;
            opened.own_colours = ink.own_colours;
        }
        const name = try gpa.dupe(u8, path);
        errdefer gpa.free(name);
        try assets.fonts.append(gpa, .{ .context = call.context, .name = name, .outline_layout = !is_bitmap, .bytes = bytes, .opened = opened, .outline = outline });
        assets.bytes += needed;
        return opened;
    }
};

/// What's wrong with a mod's picture or font, in plain words for the script's error.
fn problem(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidAssetName => "a file's name must be printable ASCII",
        error.AssetNotFound => "the mod has no file with that name",
        error.TooManyAssets => std.fmt.comptimePrint("the mods' fonts and the pictures drawn in the last {d} frames already take the {d} files the cache holds", .{ kept_frames, max_assets }),
        error.AssetsTooLarge => std.fmt.comptimePrint("the mods' fonts and the pictures drawn in the last {d} frames would take more than {d} MiB", .{ kept_frames, max_asset_bytes >> 20 }),
        error.PictureTooLarge => std.fmt.comptimePrint("its pixels alone would take more than {d} MiB", .{max_asset_bytes >> 20}),
        error.FontUnavailable => "its base font isn't loaded this frame",
        error.InvalidFontExtension => "a font must be a .fnt, .ttf or .otf file",
        error.NotAFont, error.BadGlyph => "it isn't a valid .fnt font",
        error.InvalidFont => "it can't be read as a TrueType or OpenType font",
        error.BaseFontHasNoInk => "its base font has no letters to fit it over",
        error.NoCapitalsInCommon => "it has none of the capitals " ++ hud.outline.references ++ " that its base font has",
        else => @errorName(err),
    };
}

fn readAsset(call: Call, path: []const u8) ![]u8 {
    if (!openreliant.hog.validName(path)) return error.InvalidAssetName;
    return (try call.context.modOf().readFile(call.runtime().gpa, path)) orelse error.AssetNotFound;
}

fn selectedFont(call: Call, view: View, name: ?[]const u8, base: Font) *hud.Opened {
    const asked = name orelse return view.font;
    if (std.meta.stringToEnum(Font, asked)) |builtin| return view.fontOf(builtin) orelse call.raise("font '{s}' is unavailable this frame", .{asked});
    return presentation.Presentation.of(call, "font").assets.loadFont(call, asked, base, view) catch |err| call.raise("font {s}: {s}", .{ asked, problem(err) });
}

/// Where a script draws.
pub const Which = enum {
    /// Over the flight display, while it is shown.
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
    /// One of the game's fonts, or a font file in the script's mod.
    font: ?[]const u8 = null,
    /// The game's font that gives an outline font in the mod its spacing, and draws the characters
    /// it doesn't have.
    base_font: Font = .default,
    /// Red, green and blue, each from 0 to 1.
    colour: Colour = default_colour,
    /// How opaque it is, from 0 to 1.
    alpha: f32 = 1,
    /// How many times its size in the game's pixels it's drawn at.
    scale: f32 = 1,
    /// Where the text stands from the place it's drawn at.
    @"align": hud.Align = .left,
};

/// How a script's line is drawn.
pub const LineStyle = struct {
    colour: Colour = default_colour,
    alpha: f32 = 1,
    /// How wide it is, in the game's pixels.
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
    /// How many of the window's pixels one of the game's pixels spans.
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
        pub const register_display = if (which == .hud) api.Native("Registers a display, which `name` qualified with the mod's name names. While the flight display shows, `frame` draws it with this package's functions each frame, until it's turned off with `set_display_enabled`. A failed `frame` turns off that display only. `replaces` lists the game's instruments it stands in for, which aren't drawn while it's on, and `layout` moves and scales the instruments it names; they keep working, and go back as they were as soon as it's turned off, fails or its mod stops. Returns the qualified name.", "name: string, definition: {frame: (seconds: number) -> (), replaces: { HudInstrument }?, layout: { [HudInstrument]: HudLayout }?}", "string", @import("registries.zig").registration(.display)) else {};
        pub const set_display_enabled = if (which == .hud) api.Function("Enables or disables a registered HUD display by qualified name. Returns whether it exists.", &.{ "name", "enabled" }, struct {
            fn set(call: Call, name: []const u8, enabled: bool) bool {
                return @import("registries.zig").show(call, .display, name, enabled);
            }
        }.set) else {};
        pub const replaced = if (which == .hud) instruments.replaced else {};
        pub const bounds = if (which == .hud) instruments.bounds else {};
        pub const instruments_shown = if (which == .hud) instruments.instruments_shown else {};
        pub const guns = if (which == .hud) instruments.guns else {};
        pub const missiles = if (which == .hud) instruments.missiles else {};
        pub const target = if (which == .hud) instruments.target else {};
        pub const target_display = if (which == .hud) instruments.target_display else {};
        pub const radar = if (which == .hud) instruments.radar else {};
        pub const kills = if (which == .hud) instruments.kills else {};
        pub const fuel = if (which == .hud) instruments.fuel else {};
        pub const countermeasures = if (which == .hud) instruments.countermeasures else {};
        pub const gauges = if (which == .hud) instruments.gauges else {};
        pub const ship_status = if (which == .hud) instruments.ship_status else {};
        pub const lights = if (which == .hud) instruments.lights else {};
        pub const clock = if (which == .hud) instruments.clock else {};
        pub const view_name = if (which == .hud) instruments.view_name else {};
        pub const caption = if (which == .hud) instruments.caption else {};
        pub const damage = if (which == .hud) instruments.damage else {};
        pub const power = if (which == .hud) instruments.power else {};
        pub const wingmen = if (which == .hud) instruments.wingmen else {};
        pub const objectives = if (which == .hud) instruments.objectives else {};
        pub const comms = if (which == .hud) instruments.comms else {};
        pub const messages = if (which == .hud) instruments.messages else {};
        pub const subtitle = if (which == .hud) instruments.subtitle else {};
        pub const key_prompt = if (which == .hud) instruments.key_prompt else {};
        pub const jump_prompt = if (which == .hud) instruments.jump_prompt else {};
        pub const open_windows = if (which == .hud) instruments.open_windows else {};
        pub const register_screen = if (which == .ui) api.Native("Registers a screen, which `name` qualified with the mod's name names. While it's shown (`show_screen`), `frame` draws it with this package's functions each frame, and `key` gets each key as it goes down and up. Returns the qualified name.", "name: string, definition: {frame: (seconds: number) -> (), key: ((key: Key, down: boolean) -> ())?}", "string", @import("registries.zig").registration(.screen)) else {};
        pub const replace_screen = if (which == .ui) front_end.functions.replace_screen else {};
        pub const go_to = if (which == .ui) front_end.functions.go_to else {};
        pub const start_game_mode = if (which == .ui) front_end.functions.start_game_mode else {};
        pub const launch_mission = if (which == .ui) front_end.functions.launch_mission else {};
        pub const play_movie = if (which == .ui) front_end.functions.play_movie else {};
        pub const quit = if (which == .ui) front_end.functions.quit else {};
        pub const pointer = if (which == .ui) front_end.functions.pointer else {};
        pub const show_screen = if (which == .ui) api.Function("Selects a registered screen by qualified name; nil closes the selected screen. Returns whether it exists.", &.{"name"}, struct {
            fn show(call: Call, name: ?[]const u8) bool {
                return @import("registries.zig").show(call, .screen, name, true);
            }
        }.show) else {};
        pub const picture = api.Function("Draws a PNG from the calling mod at `at`, with `size` in window pixels (nil uses its native size), tinted by `style`. Files are cached for the script context; one that hasn't been drawn for " ++ std.fmt.comptimePrint("{d}", .{kept_frames}) ++ " frames makes room for others when the cache is full.", &.{ "at", "file", "size", "style" }, struct {
            fn draw(call: Call, at: @Vector(3, f32), path: []const u8, size: ?@Vector(3, f32), given: ?FillStyle) void {
                const scripts = presentation.Presentation.of(call, "picture");
                const image = scripts.assets.loadPicture(call, path) catch |err| call.raise("picture {s}: {s}", .{ path, problem(err) });
                const style = given orelse FillStyle{};
                const extent: [2]f32 = if (size) |asked| .{ @max(asked[0], 0), @max(asked[1], 0) } else .{ @floatFromInt(image.width()), @floatFromInt(image.height()) };
                scripts.layers.getPtr(which).add(scripts.gpa, call, .{ .picture = .{ .image = image, .at = screenPoint(at), .size = extent, .colour = rgba(style.colour, style.alpha) } });
            }
        }.draw);

        pub const shape = api.Function("Draws shape `index` of the game's sprite set for this layer (the flight display's, or the front end screen's), with its anchor at `at`, in window pixels. The style's `scale` multiplies its size in the game's pixels.", &.{ "at", "index", "style" }, struct {
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

        pub const measure = api.Function("The size of `text` in window pixels, as `text` draws it: `style` is a text style, or just a number for its scale.", &.{ "text", "style" }, struct {
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

/// Adds a picture of one pixel to `assets` for a test, which takes `bytes` of the budget and was
/// last drawn in frame `drawn`.
fn testPicture(assets: *Assets, context: *runtime.Context, bytes: usize, drawn: u64) !void {
    const gpa = std.testing.allocator;
    try assets.pictures.ensureUnusedCapacity(gpa, 1);
    const name = try gpa.dupe(u8, "a.png");
    errdefer gpa.free(name);
    const pixels = try gpa.alloc(u8, srtexture.Level.Format.rgba8.size(1, 1));
    errdefer gpa.free(pixels);
    const image = try gpa.create(srtexture.Image);
    errdefer gpa.destroy(image);
    image.* = try srtexture.Image.single(gpa, 1, 1, pixels);
    assets.pictures.appendAssumeCapacity(.{ .context = context, .name = name, .image = image, .bytes = bytes, .drawn = drawn });
    assets.bytes += bytes;
}

test "the pictures drawn longest ago make room" {
    const gpa = std.testing.allocator;
    var assets: Assets = .{ .frame = 10 };
    defer assets.deinit(gpa);
    var context: runtime.Context = undefined;
    const quarter = max_asset_bytes / 4;
    // Three pictures, each a quarter of the budget, last drawn in frames 3, 9 and 5.
    for ([_]u64{ 3, 9, 5 }) |drawn| try testPicture(&assets, &context, quarter, drawn);
    var textures: srtexture.testing.Device = .{};
    for (assets.pictures.items) |picture| textures.make(picture.image);
    // Half the budget takes out the one drawn longest ago.
    try assets.makeRoom(gpa, 2 * quarter);
    try std.testing.expectEqual(2, assets.pictures.items.len);
    try std.testing.expectEqual(1, assets.taken_out.items.len);
    try std.testing.expectEqual(2 * quarter, assets.bytes);
    // One drawn in the last frame stays, so the whole budget can't be made.
    try std.testing.expectError(error.AssetsTooLarge, assets.makeRoom(gpa, max_asset_bytes));
    try std.testing.expectEqual(1, assets.pictures.items.len);
    try std.testing.expectEqual(9, assets.pictures.items[0].drawn);

    // What was taken out is freed, its textures handed back, and the cache lets go of the pixels
    // the device holds.
    assets.pictures.items[0].image.held = true;
    assets.release(gpa);
    try std.testing.expectEqual(2, textures.released);
    try std.testing.expectEqual(0, assets.taken_out.items.len);
    try std.testing.expect(!assets.pictures.items[0].image.readable());
    try std.testing.expectEqual(1, assets.pictures.items[0].image.width());
}

test "the fonts and the pictures drawn lately fill the cache" {
    const gpa = std.testing.allocator;
    var assets: Assets = .{ .frame = 2 };
    defer assets.deinit(gpa);
    var context: runtime.Context = undefined;
    for (0..max_assets) |_| try testPicture(&assets, &context, 4, 1);
    try std.testing.expectError(error.TooManyAssets, assets.makeRoom(gpa, 4));
    // A frame on, the first drawn makes room.
    assets.startFrame();
    try assets.makeRoom(gpa, 4);
    try std.testing.expectEqual(max_assets - 1, assets.pictures.items.len);
}

test rgba {
    try std.testing.expectEqual([4]f32{ 1, 0, 0.5, 1 }, rgba(.{ 2, -1, 0.5 }, 3));
}
