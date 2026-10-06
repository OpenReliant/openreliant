//! The mods screen (`ModManager`), which GAME OPTIONS' MODS button opens: a list of the mods in the
//! game's `mods` folder ([#497](https://github.com/OpenReliant/openreliant/issues/497)). A check box
//! turns each mod on or off, a box of up and down arrows sets the order the mods load in, and the
//! panel on the right shows the chosen mod's thumbnail and what its manifest says of it. The order
//! and the state are kept in `starlancer.ini`'s `[OpenReliantMods]` section (`bigfile.mods.Order`)
//! as they change, and take effect the next time OpenReliant starts, which the screen says while
//! they differ from what is loaded.
//!
//! It is laid out as the settings screen's controls tab is, on the same shapes
//! (`settings.shapes_name`): a framed list with the lists' arrows, a second frame beside it, and the
//! buttons of the settings screen. OK and MAIN MENU leave. REFRESH, where RESET DEFAULTS stands on the
//! settings screen, reads the `mods` folder again, to find the mods added or removed since OpenReliant
//! started. CANCEL CHANGES puts the mods back as they were when the screen opened. OPTIONS, in the
//! panel, opens the page of options the chosen mod's scripts offer, where it has one
//! (`mod_options`).
//!
//! **Improvement:** the original can't load mods.
//!
//! Not ported: a mod's conflicts, and the mods it depends on
//! ([#497](https://github.com/OpenReliant/openreliant/issues/497)).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const input = @import("../../input.zig");
const profile = @import("../../profile.zig");
const bigfile = @import("../bigfile.zig");
const hud = @import("../hud.zig");
const png = @import("../../../formats/png.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const canvas_module = @import("canvas.zig");
const Canvas = canvas_module.Canvas;
const Pointer = canvas_module.Pointer;
const Rect = canvas_module.Rect;
const Label = canvas_module.Label;
const Arrow = canvas_module.Arrow;
const settings = @import("settings.zig");
const widgets = settings.widgets;
const mod_options = @import("mod_options.zig");

const Mod = bigfile.mods.Mod;
const Order = bigfile.mods.Order;

const log = std.log.scoped(.interface);

/// The movie that leads into the screen from GAME OPTIONS and the background it shows: the settings
/// screen's.
pub const opening = settings.opening(.game_options, .controls).?;

/// The most mods the list holds; a screen counts its rows in a byte, as the game's lists do.
const capacity = std.math.maxInt(u8);

/// The list's frame and the lists' arrows, where the controls tab has its first pane and its
/// arrows (`0x0042CFC0`), and the frame beside it that the chosen mod's manifest is written in. They
/// are taller than the controls tab's, down to the buttons.
pub const frame_height = 250;
pub const list_frame: widgets.Frame = .{ .at = .{ 45, 136 }, .extent = .{ 324, frame_height } };
pub const details_frame: widgets.Frame = .{ .at = .{ 401, 136 }, .extent = .{ 195, frame_height } };
pub const arrows: widgets.ListArrows = .{ .at = .{ 374, 136 } };

/// The rows the list shows at once, and where they stand: the first row's check box, and how far
/// apart the rows are.
pub const shown_rows = 9;
pub const box_x = 60;
pub const first_row = 146;
pub const row_spacing = 26;

/// How far right of its check box a row's name starts (`widgets.Toggle.check_gap`), and how wide it
/// can be before the list's arrows.
const name_gap = widgets.Toggle.check_gap;
const name_width = list_frame.at[0] + list_frame.extent[0] - box_x - name_gap - name_margin;
const name_margin = 8;

/// The middle of each frame, which what the screen says of an empty list or no mod chosen is
/// centred on.
pub const list_middle: [2]i32 = .{ list_frame.at[0] + list_frame.extent[0] / 2, list_frame.at[1] + list_frame.extent[1] / 2 };
pub const details_middle: [2]i32 = .{ details_frame.at[0] + details_frame.extent[0] / 2, details_frame.at[1] + details_frame.extent[1] / 2 };

/// The note over the frames that says the mods wait for the next start, in gold, ending where the
/// frames do, as the video tab's note ends where its pane does.
const restart_note: Label = .{
    .text = .{ .words = "RESTART TO APPLY" },
    .at = .{ details_frame.at[0] + details_frame.extent[0], list_frame.at[1] - restart_note_above },
    .alignment = .right,
};
const restart_note_above = 18;

/// The title, in the place of the settings screen's tabs.
const title: Label = .{ .text = .{ .words = "MODS" }, .at = .{ 320, settings.title_y }, .alignment = .centre };

/// What the list says when the `mods` folder holds no mods, two lines, a row apart.
const empty_notes = [_]Label{
    .{ .text = .{ .words = "NO MODS FOUND" }, .at = list_middle, .alignment = .centre },
    .{ .text = .{ .words = "PUT MODS IN THE MODS FOLDER" }, .at = .{ list_middle[0], list_middle[1] + row_spacing }, .alignment = .centre },
};

/// What the panel on the right says when no mod is chosen.
const choose_note: Label = .{ .text = .{ .words = "CHOOSE A MOD" }, .at = details_middle, .alignment = .centre };

/// How the panel lays out the chosen mod's manifest, from the frame's corner.
pub const details_inside = 10;
pub const details_lines: Canvas.Lines = .{ .width = details_frame.extent[0] - 2 * details_inside, .height = 15, .most = 1 };
pub const description_lines: Canvas.Lines = .{ .width = details_lines.width, .height = 15, .most = 9 };

/// The box the chosen mod's thumbnail fits in, at the panel's top, keeping its proportions, and the
/// gap below it. The description takes the lines left below it.
const thumbnail_box: [2]i32 = .{ details_lines.width, 70 };
const thumbnail_gap = 6;
/// The most pixels' bytes a thumbnail is read to, far more than the panel shows.
const most_thumbnail_bytes = 16 * 1024 * 1024;

/// The arrows that move the chosen mod up or down the order: a gold box of up and down arrows, unlike
/// the lists' arrows that scroll the list, in the middle of the gap between the frames and
/// `movers_above` above the frames' foot.
const movers: widgets.UpDown = .{ .at = .{
    (list_frame.at[0] + list_frame.extent[0] + details_frame.at[0] - widgets.UpDown.box_size[0]) / 2,
    list_frame.at[1] + frame_height - widgets.UpDown.box_size[1] - movers_above,
} };
const movers_above = 7;

/// The buttons, which are the settings screen's, REFRESH standing where its RESET DEFAULTS does.
const Button = enum {
    ok,
    leave,
    refresh,
    cancel_changes,

    fn settingsButton(button: Button) settings.Button {
        return switch (button) {
            .ok => .ok,
            .leave => .leave,
            .refresh => .reset_defaults,
            .cancel_changes => .cancel_changes,
        };
    }

    fn rect(button: Button) Rect {
        return button.settingsButton().rect();
    }

    fn shown(button: Button) canvas_module.Button {
        return switch (button) {
            .refresh => button.settingsButton().labelled(.{ .words = "REFRESH" }),
            .ok, .leave, .cancel_changes => button.settingsButton().shown(.game_options),
        };
    }
};

/// OPTIONS, in the panel's foot: a button of the settings screen's shapes, 25 by 16, its label right
/// of it as the right column's buttons have theirs, and found 100 by 15 as they are.
const button_height = 16;
const options_button_at: [2]i32 = .{ details_frame.at[0] + details_inside, details_frame.at[1] + frame_height - details_inside - button_height };
const options_button: canvas_module.Button = .{ .at = options_button_at, .label = .{ .text = .{ .words = "OPTIONS" }, .at = .{ options_button_at[0] + options_label_from, options_button_at[1] - 1 } } };
const options_label_from = 33;
const options_rect: Rect = .{ .x = @intCast(options_button_at[0]), .y = @intCast(options_button_at[1]), .width = 100, .height = 15 };

/// A mod in the list and whether it is on.
const Row = struct {
    mod: *const Mod,
    on: bool,

    /// Its name on the screen: the manifest's, or its name in the `mods` folder.
    fn title(row: Row) []const u8 {
        return row.mod.about(.name) orelse row.mod.name;
    }

    /// Whether the settings file can keep it (`Order.listable`). A mod that can't be is on, and
    /// stays where the mods the list lacks load.
    fn listable(row: Row) bool {
        return Order.listable(row.mod.name);
    }

    /// Whether it is an archive that doesn't match its checksum file, which doesn't load.
    fn damaged(row: Row) bool {
        return row.mod.checksum == .mismatch;
    }
};

/// The thumbnails of the mods chosen so far, by their names, each read once and kept until the
/// front end closes (`deinit`), as the device keeps a picture it draws for good.
const Thumbnails = struct {
    gpa: ?Allocator = null,
    entries: std.ArrayList(Entry) = .empty,
    /// How many times REFRESH has read the `mods` folder again; only the thumbnails read since
    /// the last time are used, as a mod's thumbnail may have changed.
    listing: u32 = 0,

    const Entry = struct { name: []u8, listing: u32, image: ?*srtexture.Image };

    /// `mod`'s thumbnail, read the first time it is asked for in this listing; null if it has
    /// none, or it can't be read, which the log says.
    fn of(thumbnails: *Thumbnails, gpa: Allocator, mod: *const Mod) ?*srtexture.Image {
        for (thumbnails.entries.items) |entry| {
            if (entry.listing == thumbnails.listing and std.mem.eql(u8, entry.name, mod.name)) return entry.image;
        }
        thumbnails.gpa = gpa;
        const image = read(gpa, mod);
        const name = gpa.dupe(u8, mod.name) catch return forget(gpa, image);
        thumbnails.entries.append(gpa, .{ .name = name, .listing = thumbnails.listing, .image = image }) catch {
            gpa.free(name);
            return forget(gpa, image);
        };
        return image;
    }

    /// `mod`'s thumbnail decoded, with its mipmaps; null if it has none, or it can't be read.
    fn read(gpa: Allocator, mod: *const Mod) ?*srtexture.Image {
        const bytes = (mod.thumbnail(gpa) catch |err| {
            log.warn("{s}: can't read {s}: {s}", .{ mod.name, bigfile.mods.thumbnail_name, @errorName(err) });
            return null;
        }) orelse return null;
        defer gpa.free(bytes);
        const picture = png.readLimited(gpa, bytes, most_thumbnail_bytes) catch |err| {
            log.warn("{s}: {s} is left out: {s}", .{ mod.name, bigfile.mods.thumbnail_name, @errorName(err) });
            return null;
        };
        const image = gpa.create(srtexture.Image) catch {
            picture.deinit(gpa);
            return null;
        };
        image.* = srtexture.mipmapped(gpa, picture) catch {
            gpa.destroy(image);
            return null;
        };
        return image;
    }

    /// Lets go of `image`, which there was no room to keep; returns null.
    fn forget(gpa: Allocator, image: ?*srtexture.Image) ?*srtexture.Image {
        if (image) |held| {
            held.deinit(gpa);
            gpa.destroy(held);
        }
        return null;
    }

    fn deinit(thumbnails: *Thumbnails) void {
        const gpa = thumbnails.gpa orelse return;
        for (thumbnails.entries.items) |entry| {
            _ = forget(gpa, entry.image);
            gpa.free(entry.name);
        }
        thumbnails.entries.deinit(gpa);
        thumbnails.* = .{};
    }
};

/// The size `picture` is drawn at in the thumbnail's box: as large as fits, keeping its
/// proportions.
fn thumbnailSize(picture: *const srtexture.Image) [2]i32 {
    const width: f32 = @floatFromInt(picture.width());
    const height: f32 = @floatFromInt(picture.height());
    const fit = @min(@as(f32, @floatFromInt(thumbnail_box[0])) / width, @as(f32, @floatFromInt(thumbnail_box[1])) / height);
    return .{ @max(1, @as(i32, @intFromFloat(@round(width * fit)))), @max(1, @as(i32, @intFromFloat(@round(height * fit)))) };
}

/// What the pointer finds on the screen.
pub const Item = union(enum) {
    button: Button,
    options,
    /// An arrow that moves the chosen mod up or down the order.
    move: Arrow,
    scroll: Arrow,
    /// A row's check box, and a row's name, which chooses it, by the row's place in the list.
    check: u8,
    choose: u8,
};

/// What a pass of the screen reads, and changes.
pub const Context = struct {
    pointer: Pointer,
    keyboard: *input.Keyboard,
    /// `starlancer.ini`, which the order and the state of the mods are written to.
    settings_file: *profile.File,
    /// The timer's ticks (`game_ticks`), which a held arrow scrolls the list by.
    ticks: u32,
    /// The mods, and where to read them again.
    source: Source,
};

/// How the screen ends.
pub const Leave = union(enum) {
    /// OK, MAIN MENU or Escape.
    end: settings.End,
    /// OPTIONS: on to the options of the mod of this name.
    options: []const u8,
};

/// The mods, and where to find them again.
pub const Source = struct {
    /// The mods OpenReliant started with.
    loaded: *const bigfile.Mods,
    /// What REFRESH opens the mods with: its allocator, the game's folder, and the OpenReliant
    /// version, which mods that need a later one are left out by (`bigfile.mods.Mods.installed`).
    gpa: Allocator,
    io: Io,
    game: Io.Dir,
    version: ?std.SemanticVersion,
    /// The pages of options the mods' scripts offer.
    pages: mod_options.Pages,
};

/// The screen's state.
pub const ModManager = struct {
    /// The mods in the order the list shows them, the first `count` of them.
    rows: [capacity]Row = undefined,
    count: u8 = 0,
    /// The rows as the screen opened, which CANCEL CHANGES puts back.
    kept: [capacity]Row = undefined,
    /// The mods OpenReliant started with, in load order.
    loaded: []const Mod = &.{},
    /// The row chosen, whose manifest the panel shows.
    chosen: ?u8 = null,
    list: widgets.List = .of(0, shown_rows, 0),
    /// The item under the pointer, lit while its button is up.
    lit: ?Item = null,
    /// Whether the press that chose an item is still down, which chooses nothing more until it
    /// comes up.
    held: bool = false,
    /// Whether the chosen mod's scripts offer a page of options, which OPTIONS opens; kept up to date
    /// as each pass begins.
    has_options: bool = false,
    /// The mods REFRESH opened, which the rows are of from then on, until the screen is left
    /// (`release`).
    scanned: ?struct { gpa: Allocator, mods: bigfile.Mods } = null,
    /// The thumbnails read so far, which stay as the screen is left and opened again.
    thumbnails: Thumbnails = .{},
    /// The chosen mod's thumbnail, if it has one; kept up to date after each pass.
    thumbnail: ?*srtexture.Image = null,

    /// Opens the screen: the mods OpenReliant found, in the order the settings file gives them.
    pub fn enter(screen: *ModManager, context: Context) void {
        screen.release();
        screen.* = .{ .loaded = context.source.loaded.list, .thumbnails = screen.thumbnails };
        screen.fill(context.source.loaded, .{ .profile = context.settings_file.profile });
        screen.kept = screen.rows;
        screen.list = .of(screen.count, shown_rows, context.ticks);
        if (screen.count > 0) screen.chosen = 0;
        screen.has_options = screen.optionsOf(context.source) != null;
        screen.showThumbnail(context.source);
    }

    /// Lets go of the thumbnails, and what REFRESH opened, as the front end closes.
    pub fn deinit(screen: *ModManager) void {
        screen.release();
        screen.thumbnails.deinit();
        screen.thumbnail = null;
    }

    /// Takes the chosen mod's thumbnail for the panel (`Thumbnails.of`).
    fn showThumbnail(screen: *ModManager, source: Source) void {
        const row = screen.chosen orelse {
            screen.thumbnail = null;
            return;
        };
        screen.thumbnail = screen.thumbnails.of(source.gpa, screen.rows[row].mod);
    }

    /// Frees what REFRESH opened, as the screen is left.
    pub fn release(screen: *ModManager) void {
        if (screen.scanned) |*scanned| scanned.mods.close(scanned.gpa);
        screen.scanned = null;
    }

    /// Makes the rows of the mods of `mods`, the ones on and the ones off, in the order `order`
    /// gives. Beyond `capacity` they are left out, and stay as the settings file has them.
    fn fill(screen: *ModManager, mods: *const bigfile.Mods, order: Order) void {
        screen.count = 0;
        for ([_][]const Mod{ mods.list, mods.off, mods.damaged }) |each| for (each) |*mod| {
            if (screen.count == capacity) {
                log.warn("the mods screen lists {d} mods; {s} and the rest are left out", .{ capacity, mod.name });
                return;
            }
            // Where it goes, among the rows before it, by the order.
            var at: u8 = screen.count;
            while (at > 0 and order.before(mod.name, screen.rows[at - 1].mod.name)) : (at -= 1) screen.rows[at] = screen.rows[at - 1];
            screen.rows[at] = .{ .mod = mod, .on = order.isOn(mod.name) };
            screen.count += 1;
        };
    }

    /// REFRESH: reads the `mods` folder again, so that the list has the mods added since, and not
    /// the ones removed, with the state and the order the settings file has. The list goes back to
    /// the top, with the mod that was chosen still chosen where it remains. The mods as they now
    /// stand are the ones CANCEL CHANGES puts back.
    fn refresh(screen: *ModManager, context: Context) Allocator.Error!void {
        const source = context.source;
        const order: Order = .{ .profile = context.settings_file.profile };
        var found: bigfile.Mods = try .installed(source.gpa, source.io, source.game, source.version, order);
        errdefer found.close(source.gpa);
        // The mods the rows are of now stay until the new rows are made, which find the chosen mod
        // by its name.
        var previous = screen.scanned;
        const chosen = if (screen.chosen) |row| screen.rows[row].mod.name else null;
        screen.scanned = .{ .gpa = source.gpa, .mods = found };
        screen.thumbnails.listing +%= 1;
        screen.fill(&found, order);
        screen.kept = screen.rows;
        screen.list = .of(screen.count, shown_rows, context.ticks);
        screen.chooseNamed(chosen);
        if (previous) |*old| old.mods.close(old.gpa);
    }

    /// Chooses the row of the mod called `name`, ignoring case, and shows it; the first row where
    /// there is no such mod, or no name.
    fn chooseNamed(screen: *ModManager, name: ?[]const u8) void {
        screen.chosen = if (screen.count > 0) 0 else null;
        const wanted = name orelse return;
        for (screen.rows[0..screen.count], 0..) |row, at| if (std.ascii.eqlIgnoreCase(row.mod.name, wanted)) {
            screen.chosen = @intCast(at);
            screen.show(@intCast(at));
        };
    }

    /// A pass of the screen's loop: how it ends, once it does. What it can't write to the settings
    /// file is logged.
    pub fn frame(screen: *ModManager, context: Context) ?Leave {
        defer screen.showThumbnail(context.source);
        return screen.pass(context) catch |err| {
            log.warn("the mods are not kept: {s}", .{@errorName(err)});
            return null;
        };
    }

    /// Escape ends the screen, as OK does: the changes are kept as they are made. The wheel and the
    /// keys scroll the list, then the item under the pointer is chosen as the pointer's button goes
    /// down, and lit while it is up.
    fn pass(screen: *ModManager, context: Context) Allocator.Error!?Leave {
        if (context.keyboard.pressed(input.scan.escape, .none, true)) return .{ .end = .back };
        var pointer = context.pointer;
        if (pointer.down and screen.held) pointer.down = false else screen.held = false;
        screen.lit = null;
        screen.list.scrollBy(pointer.wheel, context.keyboard, context.ticks);
        screen.has_options = screen.optionsOf(context.source) != null;
        const under = screen.itemAt(pointer.at) orelse return null;
        if (!pointer.down) {
            screen.lit = under;
            return null;
        }
        screen.held = true;
        switch (under) {
            .button => |button| switch (button) {
                .ok => return .{ .end = .back },
                .leave => return .{ .end = .main_menu },
                .refresh => try screen.refresh(context),
                .cancel_changes => try screen.cancel(context),
            },
            .options => if (screen.optionsOf(context.source)) |mod| return .{ .options = mod },
            .move => |way| try screen.move(way, context),
            .scroll => |way| {
                screen.list.scrollHeld(way, context.ticks);
                screen.held = false;
            },
            .check => |row| try screen.toggle(row, context),
            .choose => |row| screen.chosen = row,
        }
        return null;
    }

    /// What the pointer finds at `at`: the buttons, then the list's arrows, then the rows shown.
    pub fn itemAt(screen: ModManager, at: [2]i32) ?Item {
        for (std.enums.values(Button)) |button| if (button.rect().holds(at)) return .{ .button = button };
        if (screen.has_options and options_rect.holds(at)) return .options;
        if (arrows.itemAt(at)) |arrow| return .{ .scroll = arrow };
        if (movers.itemAt(at)) |arrow| return .{ .move = arrow };
        for (screen.list.rows.first..screen.list.rows.end(), 0..) |row, place| {
            if (checkBox(place).rect().holds(at)) return .{ .check = @intCast(row) };
            if (nameRect(place).holds(at)) return .{ .choose = @intCast(row) };
        }
        return null;
    }

    /// The name of the chosen mod, if its scripts offer a page of options.
    fn optionsOf(screen: ModManager, source: Source) ?[]const u8 {
        const row = screen.chosen orelse return null;
        const name = screen.rows[row].mod.name;
        return if (source.pages.page(name) != null) name else null;
    }

    /// Turns the row's mod on or off, where the settings file can keep that.
    fn toggle(screen: *ModManager, row: u8, context: Context) Allocator.Error!void {
        const chosen = &screen.rows[row];
        if (!chosen.listable()) return;
        chosen.on = !chosen.on;
        screen.chosen = row;
        try screen.save(context);
    }

    /// Moves the chosen mod a place up or down the order, past a mod the settings file can keep.
    fn move(screen: *ModManager, way: Arrow, context: Context) Allocator.Error!void {
        const from = screen.chosen orelse return;
        const to = switch (way) {
            .up => if (from == 0) return else from - 1,
            .down => if (from + 1 == screen.count) return else from + 1,
        };
        if (!screen.rows[from].listable() or !screen.rows[to].listable()) return;
        std.mem.swap(Row, &screen.rows[from], &screen.rows[to]);
        screen.chosen = to;
        screen.show(to);
        try screen.save(context);
    }

    /// Scrolls the list to show `row`.
    fn show(screen: *ModManager, row: u8) void {
        while (screen.list.place(row) == null) screen.list.rows.scroll(if (row < screen.list.rows.first) .up else .down);
    }

    /// CANCEL CHANGES: the mods as the screen opened.
    fn cancel(screen: *ModManager, context: Context) Allocator.Error!void {
        const chosen = if (screen.chosen) |row| screen.rows[row].mod.name else null;
        screen.rows = screen.kept;
        screen.chooseNamed(chosen);
        try screen.save(context);
    }

    /// Writes the mods' order and state to the settings file.
    fn save(screen: ModManager, context: Context) Allocator.Error!void {
        var listed: [capacity]bigfile.mods.Listed = undefined;
        for (screen.rows[0..screen.count], listed[0..screen.count]) |row, *each| each.* = .{ .name = row.mod.name, .on = row.on };
        try Order.write(context.settings_file, listed[0..screen.count]);
    }

    /// Whether the mods that are on, in their order, differ from the ones OpenReliant started with.
    /// A damaged archive never loads, so it counts for neither.
    pub fn waits(screen: ModManager) bool {
        var at: usize = 0;
        for (screen.rows[0..screen.count]) |row| {
            if (!row.on or row.damaged()) continue;
            if (at == screen.loaded.len or !std.mem.eql(u8, row.mod.name, screen.loaded[at].name)) return true;
            at += 1;
        }
        return at != screen.loaded.len;
    }

    /// The screen's drawing, over the background: the title, the note while the mods wait for the
    /// next start, the list and the panel, the buttons, the one under the pointer lit, OpenReliant's
    /// version, then the pointer.
    pub fn draw(screen: ModManager, canvas: Canvas, art: *hud.Art, pointer: Pointer) canvas_module.Error!void {
        try title.write(canvas, canvas.fonts.large, canvas_module.white);
        if (screen.waits()) try restart_note.write(canvas, canvas.fonts.small, canvas_module.gold);
        list_frame.draw(canvas);
        details_frame.draw(canvas);
        try screen.drawList(canvas, art);
        try screen.drawDetails(canvas);
        if (screen.has_options) try options_button.draw(canvas, art, settings.button_shapes, std.meta.eql(screen.lit, Item.options));
        for (std.enums.values(Button)) |button| {
            try button.shown().draw(canvas, art, settings.button_shapes, std.meta.eql(screen.lit, Item{ .button = button }));
        }
        try movers.draw(canvas, art, screen.litArrow(.move));
        try canvas.drawVersion();
        try canvas.onScreen().shape(art, pointer.shape(), pointer.at);
    }

    /// The rows shown, each a check box and the mod's name, the chosen one white, a damaged one red,
    /// a mod that is off dim, and the arrows, the one under the pointer lit.
    fn drawList(screen: ModManager, canvas: Canvas, art: *hud.Art) canvas_module.Error!void {
        if (screen.count == 0) for (empty_notes) |note| try note.write(canvas, canvas.fonts.small, canvas_module.blue);
        for (screen.list.rows.first..screen.list.rows.end(), 0..) |at, place| {
            const row = screen.rows[at];
            const box = checkBox(place);
            try widgets.Box.draw(canvas.dimmedUnless(row.listable()), art, box.at, row.on);
            var named: [name_buffer]u8 = undefined;
            const is_chosen = if (screen.chosen) |chosen| chosen == at else false;
            const colour = if (row.damaged()) canvas_module.red else if (is_chosen) canvas_module.white else canvas_module.blue;
            try canvas.dimmedUnless(row.on).wrapped(canvas.fonts.small, box.label(.{ .words = "" }).at, nameOf(&named, row), colour, .left, .{ .width = name_width, .height = row_spacing, .most = 1 });
        }
        try arrows.draw(canvas, art, screen.litArrow(.scroll));
    }

    /// The arrow of the list's arrows (`.scroll`) or of the box that moves a mod (`.move`) that is
    /// lit.
    fn litArrow(screen: ModManager, comptime pair: enum { scroll, move }) ?Arrow {
        return switch (screen.lit orelse return null) {
            .scroll => |arrow| if (pair == .scroll) arrow else null,
            .move => |arrow| if (pair == .move) arrow else null,
            .button, .options, .check, .choose => null,
        };
    }

    /// The chosen mod's thumbnail, if it has one, then its manifest: its name, version and author,
    /// its description and its page; and for an archive that doesn't match its checksum file, that
    /// it isn't loaded.
    fn drawDetails(screen: ModManager, canvas: Canvas) canvas_module.Error!void {
        const row = screen.rows[screen.chosen orelse return choose_note.write(canvas, canvas.fonts.small, canvas_module.blue)];
        const font = canvas.fonts.small;
        const x = details_frame.at[0] + details_inside;
        var y = details_frame.at[1] + details_inside;
        if (screen.thumbnail) |picture| {
            const size = thumbnailSize(picture);
            canvas.imageOver(picture, .{ x + @divTrunc(details_lines.width - size[0], 2), y }, size);
            y += size[1] + thumbnail_gap;
        }
        var buffer: [name_buffer]u8 = undefined;
        try canvas.wrapped(font, .{ x, y }, row.title(), canvas_module.white, .left, details_lines);
        y += details_lines.height;
        const facts = [_]struct { []const u8, ?[]const u8 }{ .{ "VERSION ", row.mod.about(.version) }, .{ "BY ", row.mod.about(.author) } };
        for (facts) |fact| if (fact[1]) |value| {
            const line = std.mem.print(&buffer, "{s}{s}", .{ fact[0], value }) catch value;
            try canvas.wrapped(font, .{ x, y }, line, canvas_module.blue, .left, details_lines);
            y += details_lines.height;
        };
        if (row.mod.about(.description)) |description| {
            // As many lines as fit above the lines below it and the OPTIONS button.
            const lines_below = @as(i32, @intFromBool(row.mod.about(.url) != null)) + @intFromBool(row.damaged());
            const bottom = if (screen.has_options) options_button_at[1] else details_frame.at[1] + frame_height - details_inside;
            const room = @divTrunc(bottom - y, details_lines.height) - lines_below;
            var shown = description_lines;
            shown.most = @min(description_lines.most, @as(usize, @intCast(@max(room, 1))));
            try canvas.wrapped(font, .{ x, y }, description, canvas_module.blue, .left, shown);
            y += shown.height * @as(i32, @intCast(shown.count(font, description)));
        }
        if (row.mod.about(.url)) |url| {
            try canvas.wrapped(font, .{ x, y }, url, canvas_module.gold, .left, details_lines);
            y += details_lines.height;
        }
        if (row.damaged()) try canvas.wrapped(font, .{ x, y }, "DAMAGED: NOT LOADED", canvas_module.red, .left, details_lines);
    }
};

/// How long a name on the screen can be, in bytes.
pub const name_buffer = 256;

/// A row's name and, after it, its version, written in `buffer`.
fn nameOf(buffer: *[name_buffer]u8, row: Row) []const u8 {
    const title_text = row.title();
    const version = row.mod.about(.version) orelse return title_text;
    return std.mem.print(buffer, "{s} {s}", .{ title_text, version }) catch title_text;
}

/// The check box of the row shown `place`th from the top, with its name beside it.
fn checkBox(place: usize) widgets.Toggle {
    return .{ .at = .{ box_x, first_row + @as(i32, @intCast(place)) * row_spacing }, .gap = name_gap, .reach = 4 };
}

/// Where the pointer finds the name of the row shown `place`th from the top.
fn nameRect(place: usize) Rect {
    const box = checkBox(place);
    return .{ .x = @intCast(box.at[0] + name_gap - 2), .y = @intCast(box.at[1]), .width = name_width + 4, .height = widgets.Box.size };
}

fn boxCentre(place: usize) [2]i32 {
    return checkBox(place).rect().centre();
}

fn nameCentre(place: usize) [2]i32 {
    return nameRect(place).centre();
}

/// What the tests stand a screen in with: three folder mods in a `mods` folder, and a settings file.
const hog = @import("../../../formats/hog.zig");
const checksums = @import("../../../formats/checksums.zig");

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    mods: bigfile.Mods,
    file: profile.File,
    keyboard: input.Keyboard = .{},
    screen: ModManager = .{},
    /// The options of the mod `beta`.
    options: mod_options.Recorder,

    fn init(fixture: *Fixture, text: []const u8) !void {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        fixture.tmp = std.testing.tmpDir(.{ .iterate = true });
        fixture.arena = .init(gpa);
        for ([_][]const u8{ "alpha", "beta", "gamma" }) |name| {
            const folder = try gpa.print("mods/{s}", .{name});
            defer gpa.free(folder);
            try fixture.tmp.dir.createDirPath(io, folder);
            const manifest = try gpa.print("{s}/mod.ini", .{folder});
            defer gpa.free(manifest);
            const contents = try gpa.print("[Mod]\nName={c}{s} mod\nVersion=1.0\nAuthor=Someone\nDescription=Changes the {s}.\n", .{ std.ascii.toUpper(name[0]), name[1..], name });
            defer gpa.free(contents);
            try fixture.tmp.dir.writeFile(io, .{ .sub_path = manifest, .data = contents });
            const scripted = try gpa.print("{s}/{s}.luau", .{ folder, name });
            defer gpa.free(scripted);
            try fixture.tmp.dir.writeFile(io, .{ .sub_path = scripted, .data = "return {}" });
        }
        fixture.file = .{ .arena = fixture.arena.allocator(), .profile = .{ .text = text } };
        fixture.mods = try .openOrdered(gpa, io, fixture.tmp.dir, null, .{ .profile = fixture.file.profile });
        fixture.keyboard = .{};
        fixture.options = .{ .mod = "beta", .page = .{ .title = "BETA", .options = &mod_options.test_options } };
        fixture.screen = .{};
        fixture.screen.enter(fixture.context(.{}));
    }

    fn deinit(fixture: *Fixture) void {
        fixture.screen.deinit();
        fixture.mods.close(std.testing.allocator);
        fixture.arena.deinit();
        fixture.tmp.cleanup();
    }

    fn context(fixture: *Fixture, pointer: Pointer) Context {
        return .{ .pointer = pointer, .keyboard = &fixture.keyboard, .settings_file = &fixture.file, .ticks = 0, .source = .{
            .loaded = &fixture.mods,
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .game = fixture.tmp.dir,
            .version = null,
            .pages = fixture.options.pages(),
        } };
    }

    /// A click at `at`: the pointer there with its button up, then down.
    fn click(fixture: *Fixture, at: [2]i32) ?Leave {
        _ = fixture.screen.frame(fixture.context(.{ .at = at }));
        return fixture.screen.frame(fixture.context(.{ .at = at, .down = true }));
    }

    fn names(fixture: *const Fixture, buffer: *[capacity][]const u8) []const []const u8 {
        const listed = buffer[0..fixture.screen.count];
        for (fixture.screen.rows[0..fixture.screen.count], listed) |row, *name| name.* = row.mod.name;
        return listed;
    }
};

test "the rows are the mods in the order the settings file gives, the first chosen" {
    var fixture: Fixture = undefined;
    try fixture.init("[OpenReliantMods]\ngamma=1\nalpha=0\n");
    defer fixture.deinit();
    var buffer: [capacity][]const u8 = undefined;
    // The mods the file lists, in its order, then the others by name; alpha is off.
    try std.testing.expectEqualDeep(&[_][]const u8{ "gamma", "alpha", "beta" }, fixture.names(&buffer));
    try std.testing.expect(!fixture.screen.rows[1].on and fixture.screen.rows[2].on);
    try std.testing.expectEqual(0, fixture.screen.chosen.?);
    // What it started with has no alpha, and gamma before beta: the screen has nothing to apply.
    try std.testing.expectEqualStrings("gamma", fixture.mods.list[0].name);
    try std.testing.expect(!fixture.screen.waits());
}

test "a check box turns a mod on or off and the file keeps it" {
    var fixture: Fixture = undefined;
    try fixture.init("");
    defer fixture.deinit();
    try std.testing.expect(!fixture.screen.waits());
    // The second row's box.
    try std.testing.expectEqual(null, fixture.click(boxCentre(1)));
    try std.testing.expect(!fixture.screen.rows[1].on);
    try std.testing.expectEqualStrings("0", fixture.file.profile.value("OpenReliantMods", "beta").?);
    try std.testing.expectEqualStrings("1", fixture.file.profile.value("OpenReliantMods", "alpha").?);
    try std.testing.expect(fixture.screen.waits());
    // The press that did it, held, does it no more; coming up and down again turns it on.
    _ = fixture.screen.frame(fixture.context(.{ .at = boxCentre(1), .down = true }));
    try std.testing.expect(!fixture.screen.rows[1].on);
    _ = fixture.click(boxCentre(1));
    try std.testing.expect(fixture.screen.rows[1].on);
    try std.testing.expect(!fixture.screen.waits());
    // The order the file now gives is the one the mods load in.
    const order: Order = .{ .profile = fixture.file.profile };
    try std.testing.expect(order.isOn("beta") and order.before("alpha", "beta"));
}

test "a name chooses the mod, and the lower arrows set the order" {
    var fixture: Fixture = undefined;
    try fixture.init("");
    defer fixture.deinit();
    var buffer: [capacity][]const u8 = undefined;
    _ = fixture.click(nameCentre(2));
    try std.testing.expectEqual(2, fixture.screen.chosen.?);
    // The up arrow takes gamma past beta, the down arrow back; the first can't go up, nor the last down.
    _ = fixture.click(movers.rect(.up).centre());
    try std.testing.expectEqualDeep(&[_][]const u8{ "alpha", "gamma", "beta" }, fixture.names(&buffer));
    try std.testing.expectEqual(1, fixture.screen.chosen.?);
    try std.testing.expect(fixture.screen.waits());
    const order: Order = .{ .profile = fixture.file.profile };
    try std.testing.expectEqual(1, order.position("gamma"));
    try std.testing.expectEqual(2, order.position("beta"));
    // The down arrow puts it back, as far as the list goes.
    _ = fixture.click(movers.rect(.down).centre());
    try std.testing.expectEqualDeep(&[_][]const u8{ "alpha", "beta", "gamma" }, fixture.names(&buffer));
    try std.testing.expect(!fixture.screen.waits());
    _ = fixture.click(movers.rect(.down).centre());
    try std.testing.expectEqual(2, fixture.screen.chosen.?);
    fixture.screen.chosen = 0;
    _ = fixture.click(movers.rect(.up).centre());
    try std.testing.expectEqualDeep(&[_][]const u8{ "alpha", "beta", "gamma" }, fixture.names(&buffer));
}

test "CANCEL CHANGES puts the mods back as the screen opened them" {
    var fixture: Fixture = undefined;
    try fixture.init("[OpenReliantMods]\ngamma=1\nbeta=0\nalpha=1\n");
    defer fixture.deinit();
    var buffer: [capacity][]const u8 = undefined;
    try std.testing.expectEqualDeep(&[_][]const u8{ "gamma", "beta", "alpha" }, fixture.names(&buffer));
    // A change, then CANCEL CHANGES: the screen as it opened, and the file says so.
    _ = fixture.click(boxCentre(0));
    try std.testing.expect(!fixture.screen.rows[0].on);
    _ = fixture.click(Button.cancel_changes.rect().centre());
    try std.testing.expect(fixture.screen.rows[0].on);
    try std.testing.expectEqualStrings("1", fixture.file.profile.value("OpenReliantMods", "gamma").?);
    try std.testing.expectEqualStrings("0", fixture.file.profile.value("OpenReliantMods", "beta").?);
    // A move, then CANCEL CHANGES, with the moved mod still chosen where it goes back to.
    fixture.screen.chosen = 2;
    _ = fixture.click(movers.rect(.up).centre());
    try std.testing.expectEqualDeep(&[_][]const u8{ "gamma", "alpha", "beta" }, fixture.names(&buffer));
    _ = fixture.click(Button.cancel_changes.rect().centre());
    try std.testing.expectEqualDeep(&[_][]const u8{ "gamma", "beta", "alpha" }, fixture.names(&buffer));
    try std.testing.expectEqual(2, fixture.screen.chosen.?);
}

test "REFRESH reads the mods folder again" {
    var fixture: Fixture = undefined;
    try fixture.init("");
    defer fixture.deinit();
    const io = std.testing.io;
    // Beta turned off and chosen; a mod added and one removed since the screen opened.
    _ = fixture.click(boxCentre(1));
    fixture.screen.chosen = 1;
    try fixture.tmp.dir.createDirPath(io, "mods/delta");
    try fixture.tmp.dir.deleteTree(io, "mods/alpha");
    var buffer: [capacity][]const u8 = undefined;
    try std.testing.expectEqualDeep(&[_][]const u8{ "alpha", "beta", "gamma" }, fixture.names(&buffer));
    try std.testing.expectEqual(null, fixture.click(Button.refresh.rect().centre()));
    // The list has the new mod, after the ones the file lists, and not the removed one; beta is
    // still off and still chosen.
    try std.testing.expectEqualDeep(&[_][]const u8{ "beta", "gamma", "delta" }, fixture.names(&buffer));
    try std.testing.expect(!fixture.screen.rows[0].on and fixture.screen.rows[1].on);
    try std.testing.expectEqual(0, fixture.screen.chosen.?);
    try std.testing.expect(fixture.screen.scanned != null);
    // What OpenReliant started with is unchanged, so the screen says the mods wait: beta is off, and
    // alpha is gone.
    try std.testing.expect(fixture.screen.waits());
    // Beta turned on, then refreshing again, which frees the mods it opened before; CANCEL CHANGES
    // puts back the mods as they stood at the last refresh.
    _ = fixture.click(boxCentre(0));
    try std.testing.expect(fixture.screen.rows[0].on);
    _ = fixture.click(Button.refresh.rect().centre());
    try std.testing.expect(fixture.screen.rows[0].on);
    _ = fixture.click(boxCentre(0));
    _ = fixture.click(Button.cancel_changes.rect().centre());
    try std.testing.expect(fixture.screen.rows[0].on);
}

test "the panel takes a mod's thumbnail, and a damaged archive is listed but doesn't wait" {
    var fixture: Fixture = undefined;
    try fixture.init("");
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Alpha gets a thumbnail, 4 by 2 pixels; delta.hog is an archive that doesn't match its
    // checksum file.
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try png.writeRgba(gpa, &written.writer, 4, 2, &@as([4 * 2 * 4]u8, @splat(200)));
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "mods/alpha/mod.png", .data = written.written() });
    try hog.testing.write(gpa, io, fixture.tmp.dir, "mods/delta.hog", &.{.{ .name = "ship.shp", .data = "a ship" }});
    var line_buffer: [128]u8 = undefined;
    var line: std.Io.Writer = .fixed(&line_buffer);
    try checksums.writeLine(&line, checksums.digest("another archive"), "delta.hog");
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "mods/delta.hog.sha256", .data = line.buffered() });
    _ = fixture.click(Button.refresh.rect().centre());
    var buffer: [capacity][]const u8 = undefined;
    try std.testing.expectEqualDeep(&[_][]const u8{ "alpha", "beta", "delta.hog", "gamma" }, fixture.names(&buffer));

    // Alpha's thumbnail fits the box as high as it is; beta has none, and the panel shows none.
    fixture.screen.chosen = 0;
    fixture.screen.showThumbnail(fixture.context(.{}).source);
    const thumbnail = fixture.screen.thumbnail.?;
    try std.testing.expectEqual([2]i32{ thumbnail_box[1] * 2, thumbnail_box[1] }, thumbnailSize(thumbnail));
    fixture.screen.chosen = 1;
    fixture.screen.showThumbnail(fixture.context(.{}).source);
    try std.testing.expectEqual(null, fixture.screen.thumbnail);
    // The damaged archive is on, but never loads, so the mods don't wait for a restart.
    try std.testing.expect(fixture.screen.rows[2].damaged() and fixture.screen.rows[2].on);
    try std.testing.expect(!fixture.screen.waits());
    // Thumbnails are read once for each listing, and kept as the screen opens again; alpha's from
    // before REFRESH, which had none, stays unused.
    fixture.screen.enter(fixture.context(.{}));
    try std.testing.expectEqual(thumbnail, fixture.screen.thumbnails.of(gpa, fixture.screen.rows[0].mod).?);
    try std.testing.expectEqual(3, fixture.screen.thumbnails.entries.items.len);
}

test "OPTIONS opens the page of the mod that has one" {
    var fixture: Fixture = undefined;
    try fixture.init("");
    defer fixture.deinit();
    // Alpha is chosen and offers nothing: the panel has no button.
    try std.testing.expectEqual(null, fixture.screen.itemAt(options_rect.centre()));
    try std.testing.expectEqual(null, fixture.click(options_rect.centre()));
    // Beta offers a page.
    _ = fixture.click(nameCentre(1));
    _ = fixture.screen.frame(fixture.context(.{}));
    try std.testing.expectEqual(Item.options, fixture.screen.itemAt(options_rect.centre()).?);
    const left = fixture.click(options_rect.centre()).?;
    try std.testing.expectEqualStrings("beta", left.options);
}

test "the list scrolls, and OK, MAIN MENU and Escape end the screen" {
    var fixture: Fixture = undefined;
    try fixture.init("");
    defer fixture.deinit();
    // Three mods fit in the list: nothing scrolls.
    _ = fixture.screen.frame(fixture.context(.{ .wheel = -1 }));
    try std.testing.expectEqual(0, fixture.screen.list.rows.first);
    try std.testing.expectEqual(null, fixture.screen.itemAt(.{ 500, 300 }));
    try std.testing.expectEqual(Item{ .scroll = .down }, fixture.screen.itemAt(arrows.rect(.down).centre()).?);
    try std.testing.expectEqual(Item{ .move = .up }, fixture.screen.itemAt(movers.rect(.up).centre()).?);
    try std.testing.expectEqual(Item{ .move = .down }, fixture.screen.itemAt(movers.rect(.down).centre()).?);
    try std.testing.expectEqual(Leave{ .end = .back }, fixture.click(Button.ok.rect().centre()).?);
    try std.testing.expectEqual(Leave{ .end = .main_menu }, fixture.click(Button.leave.rect().centre()).?);
    fixture.keyboard.down[input.scan.escape] = true;
    try std.testing.expectEqual(Leave{ .end = .back }, fixture.screen.frame(fixture.context(.{})).?);
}

test "a mod the settings file can't keep stays on and in place" {
    var fixture: Fixture = undefined;
    try fixture.init("");
    defer fixture.deinit();
    const odd: Mod = .{ .name = "odd=mod", .source = undefined };
    try std.testing.expect(!(Row{ .mod = &odd, .on = true }).listable());
    // It sits last, where the mods the file lacks load.
    fixture.screen.rows[3] = .{ .mod = &odd, .on = true };
    fixture.screen.count = 4;
    try fixture.screen.toggle(3, fixture.context(.{}));
    try std.testing.expect(fixture.screen.rows[3].on);
    fixture.screen.chosen = 2;
    try fixture.screen.move(.down, fixture.context(.{}));
    try std.testing.expectEqualStrings("gamma", fixture.screen.rows[2].mod.name);
    try std.testing.expectEqual(null, fixture.file.profile.value("OpenReliantMods", "beta"));
}

test "a screen without mods" {
    var fixture: Fixture = undefined;
    try fixture.init("");
    defer fixture.deinit();
    var empty: ModManager = .{};
    defer empty.deinit();
    empty.enter(fixture.context(.{}));
    var none: bigfile.Mods = .none;
    var context = fixture.context(.{});
    context.source.loaded = &none;
    empty.enter(context);
    try std.testing.expectEqual(0, empty.count);
    try std.testing.expectEqual(null, empty.chosen);
    try std.testing.expect(!empty.waits());
    try std.testing.expectEqual(null, empty.frame(context));
}
