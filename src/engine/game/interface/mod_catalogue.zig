//! The GET MODS screen (`ModCatalogue`), opened by the GET MODS button of the mods screen. It lists
//! the mods of the catalogue on the web (`bigfile.catalogue`), read from the repositories that
//! `starlancer.ini` names, in a list like the mods screen's, grouped by top category (SHIPS,
//! MISSIONS, ...) under headings that fold and unfold, with the chosen mod's thumbnail, version,
//! author, category, repository, size and description in the panel next to it. INSTALL downloads
//! the chosen mod's archive into the `mods` folder, checks it against the catalogue's digest and
//! records in `starlancer.ini` which repository it came from, showing the progress in the panel.
//! UPDATE does the same for a mod that is installed in an older version. RELOAD reads the
//! repositories again. The indexes and the downloads run on other threads, so the screen keeps
//! running while they come in. The repositories are read one after another, and one download
//! runs at a time: INSTALL and RELOAD wait for it.
//!
//! The screen uses the mods screen's layout and shapes: the framed list with its arrows, the
//! panel, and the settings screen's buttons. OK goes back to the mods screen, which rereads the
//! `mods` folder if a mod was installed. MAIN MENU leaves. A mod that needs a newer OpenReliant is
//! listed in red and can't be installed, and a folder mod of the same name, copied in by hand, is
//! left as it is: the loader would load both it and the archive.
//!
//! Not yet: cancelling a download that runs
//! ([#1040](https://github.com/OpenReliant/openreliant/issues/1040)), and updates shown on the
//! mods screen itself ([#1041](https://github.com/OpenReliant/openreliant/issues/1041)).
//!
//! **Improvement:** the original has no mods, and never reads the web.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const input = @import("../../input.zig");
const profile = @import("../../profile.zig");
const bigfile = @import("../bigfile.zig");
const checksums = @import("../../../formats/checksums.zig");
const catalogue = bigfile.catalogue;
const Repositories = catalogue.Repositories;
const Order = bigfile.mods.Order;
const hog = @import("../../../formats/hog.zig");
const hud = @import("../hud.zig");
const canvas_module = @import("canvas.zig");
const Canvas = canvas_module.Canvas;
const Pointer = canvas_module.Pointer;
const Rect = canvas_module.Rect;
const Label = canvas_module.Label;
const Arrow = canvas_module.Arrow;
const settings = @import("settings.zig");
const widgets = settings.widgets;
const mod_manager = @import("mod_manager.zig");
const mod_options = @import("mod_options.zig");

const Entry = catalogue.Entry;
const Mod = bigfile.mods.Mod;

const log = std.log.scoped(.interface);

/// The most rows the list holds, as on the mods screen, and the most mods it lists. Each mod takes
/// a row and each group a heading row, so at most half the rows are mods.
const capacity = std.math.maxInt(u8);
const most_mods = capacity / 2;

/// How far a mod's name is indented under its group's heading.
const indent = 14;

/// What a heading starts with: `+` while the group is folded, `-` while it is open.
const folded_mark = "+ ";
const open_mark = "- ";

/// The heading of the mods that have no category.
const no_category_heading = "OTHER MODS";

/// What separates the folders of a category's path when the screen writes it, as in
/// `SHIPS / FIGHTERS / ALLIANCE`.
const path_separator = " / ";

/// The list and the panel, in the same places as the mods screen's.
const list_frame = mod_manager.list_frame;
const details_frame = mod_manager.details_frame;
const arrows = mod_manager.arrows;
const shown_rows = mod_manager.shown_rows;
const row_spacing = mod_manager.row_spacing;
const first_row = mod_manager.first_row;
const name_x = mod_manager.box_x;
/// How wide a row's text can be: up to the list's frame, less a margin before the arrows.
const name_width = list_frame.at[0] + list_frame.extent[0] - name_x - name_margin;
const name_margin = 8;
const list_middle = mod_manager.list_middle;
const details_middle = mod_manager.details_middle;
const details_inside = mod_manager.details_inside;
const details_lines = mod_manager.details_lines;
const description_lines = mod_manager.description_lines;
const frame_height = mod_manager.frame_height;
const name_buffer = mod_manager.name_buffer;

/// The title, where the settings screen has its tabs.
const title: Label = .{ .text = .{ .words = "GET MODS" }, .at = .{ 320, settings.title_y }, .alignment = .centre };

/// The notes the list shows while the catalogue downloads, when it can't be read, and when it is
/// empty. Words OpenReliant adds to the screens use American spelling.
const reading_note: Label = .{ .text = .{ .words = "READING THE CATALOG" }, .at = list_middle, .alignment = .centre };
const unreadable_note: Label = .{ .text = .{ .words = "CAN'T READ THE CATALOG" }, .at = list_middle, .alignment = .centre };
const empty_note: Label = .{ .text = .{ .words = "THE CATALOG OFFERS NO MODS" }, .at = list_middle, .alignment = .centre };
/// Where the second line of the list's note goes: the reason the catalogue can't be read.
const note_below: [2]i32 = .{ list_middle[0], list_middle[1] + row_spacing };
/// Where the note about a repository that can't be read goes, while the others' mods are listed:
/// above the list, ending at the panel's right edge like the mods screen's RESTART TO APPLY.
const repository_note_at: [2]i32 = .{ details_frame.at[0] + details_frame.extent[0], list_frame.at[1] - mod_manager.restart_note_above };
/// The note the panel shows for a folder mod copied in by hand, which INSTALL leaves alone.
const by_hand_note = "INSTALLED BY HAND AS A FOLDER: INSTALL WON'T REPLACE IT";

/// The note the panel shows when no mod is chosen.
const choose_note: Label = .{ .text = .{ .words = "CHOOSE A MOD" }, .at = details_middle, .alignment = .centre };

/// The gap under the chosen mod's thumbnail, the same as the mods screen's.
const thumbnail_gap = mod_manager.thumbnail_gap;

/// The progress bar at the bottom of the panel: its height, and the gap between its frame and its
/// fill.
const bar_height = 8;
const bar_inside = 2;
const bar_at: [2]i32 = .{ details_frame.at[0] + details_inside, details_frame.at[1] + frame_height - details_inside - bar_height };
const bar_width = details_lines.width;

/// The buttons, in the settings screen's places: INSTALL (or UPDATE) where RESET DEFAULTS is, and
/// RELOAD where CANCEL CHANGES is.
pub const Button = enum {
    ok,
    leave,
    install,
    reload,

    fn settingsButton(button: Button) settings.Button {
        return switch (button) {
            .ok => .ok,
            .leave => .leave,
            .install => .reset_defaults,
            .reload => .cancel_changes,
        };
    }

    fn rect(button: Button) Rect {
        return button.settingsButton().rect();
    }

    fn shown(button: Button, action: Action) canvas_module.Button {
        return switch (button) {
            .install => button.settingsButton().labelled(.{ .words = if (action == .update) "UPDATE" else "INSTALL" }),
            .reload => button.settingsButton().labelled(.{ .words = "RELOAD" }),
            .ok, .leave => button.settingsButton().shown(.game_options),
        };
    }
};

/// What INSTALL does for the chosen mod: install it, update an older copy, or nothing.
const Action = enum { install, update, none };

/// Whether a mod of the catalogue is in the `mods` folder.
const Status = union(enum) {
    /// Not in the folder.
    absent,
    installed: Installed,
};

/// A mod of the catalogue that is in the `mods` folder.
const Installed = struct {
    /// Its version as its manifest writes it; null when the manifest gives none.
    version: ?[]const u8,
    /// Whether it is a folder mod, which was copied in by hand. INSTALL and UPDATE leave it alone,
    /// since the loader would load both it and the archive.
    folder: bool,
    /// The repository GET MODS installed it from, as the settings file records it; null for a mod
    /// copied in by hand.
    repository: ?[]const u8,
};

/// A repository that couldn't be read: its name, copied with `gpa`, and why.
const Failed = struct { gpa: Allocator, name: []u8, failure: catalogue.Failure };

/// What the pointer finds on the screen.
pub const Item = union(enum) {
    button: Button,
    scroll: Arrow,
    /// A mod's name, which selects the mod, by its index in the catalogue.
    choose: u8,
    /// A group's heading, which folds or unfolds the group, by its index in `groups`.
    fold: u8,
};

/// A row of the list: a group's heading, by its index in `groups`, or a mod's name, by its index
/// in the catalogue.
const Row = union(enum) {
    heading: u8,
    mod: u8,
};

/// The mod whose thumbnail is downloading: its id, copied with `gpa`.
const ThumbnailOf = struct { gpa: Allocator, id: []u8 };

/// What one pass of the screen reads and changes.
pub const Context = struct {
    pointer: Pointer,
    keyboard: *input.Keyboard,
    /// `starlancer.ini`, which names the repositories to read, gives the order of the installed
    /// mods, and records the ones GET MODS installed.
    settings_file: *profile.File,
    /// The timer's ticks (`game_ticks`), used to scroll the list while an arrow is held.
    ticks: u32,
    /// The loaded mods, and how to reread them.
    source: mod_manager.Source,
};

/// How the screen ends.
pub const Leave = union(enum) {
    /// OK or Escape: back to the mods screen. `installed` says whether a mod was installed since the
    /// mods screen was left, so it rereads the `mods` folder.
    mods: struct { installed: bool },
    /// MAIN MENU.
    main_menu,
};

/// The screen's state.
pub const ModCatalogue = struct {
    /// The HTTP client every download uses, made when the screen first opens and kept until the
    /// front end closes.
    client: ?std.http.Client = null,
    /// The download of the repositories' indexes, one after another: the index of the repository
    /// being read, by its place in the settings file's list, and the catalogue the indexes are
    /// gathered into. Null while nothing is read.
    fetch: catalogue.Fetch = .{},
    reading: ?usize = null,
    gathering: ?catalogue.Catalogue = null,
    /// The catalogue once every repository has been read. It is kept while the screen is left and
    /// opened again, until RELOAD.
    loaded: ?catalogue.Catalogue = null,
    /// The last repository that couldn't be read, and why; shown with the list.
    failed: ?Failed = null,
    /// The selected mod, by its index in the catalogue; the panel shows it.
    chosen: ?u8 = null,
    /// The rows of the list: a heading for each group, then the mods in it unless the group is
    /// folded. A group is a top category, the first folder of the mods' category paths, such as
    /// `ships`. The groups are in the order of their names, and the mods in the order of their
    /// full paths and then of their names. Rebuilt when the catalogue arrives and when a group is
    /// folded or unfolded.
    rows: [capacity]Row = undefined,
    row_count: u8 = 0,
    /// The groups' names, in the order of the headings, and which groups are folded.
    groups: [capacity][]const u8 = undefined,
    group_count: u8 = 0,
    folded: std.StaticBitSet(capacity) = .empty,
    list: widgets.List = .of(0, shown_rows, 0),
    /// The item under the pointer, highlighted while the button is up.
    lit: ?Item = null,
    /// Whether the button press that selected an item is still held. Nothing else is selected until
    /// it is released.
    held: bool = false,
    /// The download of the mod being installed, and the mod's index in the catalogue. The
    /// catalogue can't be reloaded while it runs, so the index stays valid.
    install: catalogue.Install = .{},
    installing: ?u8 = null,
    /// The result of the last install, shown in the panel of its mod: the mod's id and, if it
    /// failed, why.
    outcome: ?struct { gpa: Allocator, id: []u8, failure: ?catalogue.Failure } = null,
    /// Whether a mod was installed since the mods screen was left. The mods screen then rereads the
    /// `mods` folder.
    installed_any: bool = false,
    /// The mods in the `mods` folder, read when the screen opens and after each install, and what
    /// the settings file said of them then. They say which catalogue mods are installed, in which
    /// version, and from which repository.
    present: ?struct { gpa: Allocator, mods: bigfile.Mods, order: Order } = null,
    /// The thumbnails downloaded so far, by mod id, the download in progress, and the id of the
    /// mod it is for.
    thumbnails: mod_manager.Thumbnails = .{},
    thumbnail_fetch: catalogue.Fetch = .{},
    thumbnail_of: ?ThumbnailOf = null,
    /// The OpenReliant version that runs, as the last pass gave it, which says whether a mod needs
    /// a newer one. Null until the screen is entered, or when the version isn't known.
    running: ?std.SemanticVersion = null,

    /// Opens the screen: reads the `mods` folder, and starts reading the repositories if the
    /// catalogue hasn't been read yet.
    pub fn enter(screen: *ModCatalogue, context: Context) void {
        const source = context.source;
        screen.running = source.version;
        if (screen.client == null) screen.client = .{ .allocator = source.gpa, .io = source.io };
        screen.lit = null;
        screen.held = false;
        screen.installed_any = false;
        screen.makeRows();
        screen.list = .of(screen.row_count, shown_rows, context.ticks);
        if (screen.chosen == null) screen.chosen = screen.firstMod();
        screen.scan(context);
        if (screen.loaded == null and screen.reading == null) screen.startReading(context);
    }

    /// Frees everything the screen holds, when the front end closes. The downloads are cancelled
    /// before the client they use is freed.
    pub fn deinit(screen: *ModCatalogue) void {
        screen.fetch.deinit();
        screen.thumbnail_fetch.deinit();
        screen.install.deinit();
        if (screen.client) |*client| client.deinit();
        screen.client = null;
        if (screen.gathering) |*gathering| gathering.deinit();
        screen.gathering = null;
        screen.reading = null;
        if (screen.loaded) |*loaded| loaded.deinit();
        screen.loaded = null;
        screen.forgetFailure();
        screen.forgetOutcome();
        if (screen.thumbnail_of) |pending| pending.gpa.free(pending.id);
        screen.thumbnail_of = null;
        screen.thumbnails.deinit();
        if (screen.present) |*present| present.mods.close(present.gpa);
        screen.present = null;
    }

    /// The HTTP client, once the screen has been entered.
    fn httpClient(screen: *ModCatalogue) ?*std.http.Client {
        return if (screen.client) |*client| client else null;
    }

    /// The catalogue's mods, at most `most_mods` of them.
    fn entries(screen: ModCatalogue) []const Entry {
        const loaded = screen.loaded orelse return &.{};
        const all = loaded.entries();
        return all[0..@min(all.len, most_mods)];
    }

    fn count(screen: ModCatalogue) u8 {
        return @intCast(screen.entries().len);
    }

    /// Makes the rows and the groups from the catalogue's mods: the mods sorted by their category's
    /// path and then by their name, a heading row where the top category changes, and the mods'
    /// rows after it unless the group is folded. Mods without a category come last, under
    /// `no_category_heading`.
    fn makeRows(screen: *ModCatalogue) void {
        const all = screen.entries();
        var order: [most_mods]u8 = undefined;
        for (order[0..all.len], 0..) |*at, index| at.* = @intCast(index);
        std.mem.sort(u8, order[0..all.len], all, entryBefore);
        screen.row_count = 0;
        screen.group_count = 0;
        var current: ?u8 = null;
        for (order[0..all.len]) |index| {
            const group = groupOf(all[index]);
            if (current == null or !std.ascii.eqlIgnoreCase(screen.groups[current.?], group)) {
                screen.groups[screen.group_count] = group;
                current = screen.group_count;
                screen.group_count += 1;
                screen.rows[screen.row_count] = .{ .heading = current.? };
                screen.row_count += 1;
            }
            if (screen.folded.isSet(current.?)) continue;
            screen.rows[screen.row_count] = .{ .mod = index };
            screen.row_count += 1;
        }
    }

    /// The group of `entry`: the first folder of its category's path, such as `ships` for
    /// `ships/fighters/alliance`; empty without a category.
    fn groupOf(entry: Entry) []const u8 {
        const path = entry.category orelse "";
        return path[0 .. std.mem.findScalar(u8, path, '/') orelse path.len];
    }

    /// Whether the mod `a` is listed before the mod `b`: by their categories' paths, a mod without
    /// a category last, then by their names, ignoring case.
    fn entryBefore(all: []const Entry, a: u8, b: u8) bool {
        const path_a = all[a].category orelse "";
        const path_b = all[b].category orelse "";
        if ((path_a.len == 0) != (path_b.len == 0)) return path_b.len == 0;
        return switch (std.ascii.orderIgnoreCase(path_a, path_b)) {
            .lt => true,
            .gt => false,
            .eq => std.ascii.lessThanIgnoreCase(all[a].title(), all[b].title()),
        };
    }

    /// The first mod in the list's order, if there is one.
    fn firstMod(screen: ModCatalogue) ?u8 {
        for (screen.rows[0..screen.row_count]) |row| switch (row) {
            .mod => |index| return index,
            .heading => {},
        };
        return null;
    }

    /// Folds the group if it is open, or unfolds it, and remakes the rows. The list keeps its scroll
    /// position, moved up if fewer rows are left.
    fn fold(screen: *ModCatalogue, group: u8) void {
        screen.folded.toggle(group);
        screen.makeRows();
        screen.list.rows.count = screen.row_count;
        if (screen.list.rows.first + shown_rows > screen.row_count) screen.list.rows.first = screen.row_count -| shown_rows;
    }

    /// A group's heading, written into `buffer`: its mark, then its name in capitals, such as
    /// `- SHIPS`, or `- OTHER MODS` for the mods without a category.
    fn headingOf(screen: ModCatalogue, buffer: *[name_buffer]u8, group: u8) []const u8 {
        var writer: Io.Writer = .fixed(buffer);
        writer.writeAll(if (screen.folded.isSet(group)) folded_mark else open_mark) catch {};
        const name = screen.groups[group];
        writePath(&writer, if (name.len == 0) no_category_heading else name);
        return writer.buffered();
    }

    /// Starts reading the repositories the settings file names, the first one first (`readNext`),
    /// into a new catalogue. Without a repository, nothing is read: GET MODS is hidden then.
    fn startReading(screen: *ModCatalogue, context: Context) void {
        if (!Repositories.of(context.settings_file.profile).any()) return;
        screen.forgetFailure();
        if (screen.gathering) |*gathering| gathering.deinit();
        screen.gathering = .init(context.source.gpa);
        screen.reading = 0;
        screen.readNext(context);
    }

    /// Starts downloading the index of the repository being read, skipping one whose download
    /// can't start, or, past the last repository, lists the catalogue gathered so far.
    fn readNext(screen: *ModCatalogue, context: Context) void {
        const source = context.source;
        while (screen.reading) |index| {
            const repository = Repositories.of(context.settings_file.profile).at(index) orelse break;
            const client = screen.httpClient() orelse break;
            screen.fetch.start(source.gpa, source.io, client, repository.url, catalogue.most_index_bytes) catch |err| {
                log.warn("{s}: the catalogue can't be read: {s}", .{ repository.name, @errorName(err) });
                screen.recordFailure(source.gpa, repository.name, catalogue.Failure.ofStart(err));
                screen.reading = index + 1;
                continue;
            };
            return;
        }
        screen.finishReading(context);
    }

    /// Lists the catalogue gathered from every repository, in place of the one listed before.
    fn finishReading(screen: *ModCatalogue, context: Context) void {
        screen.reading = null;
        const gathered = screen.gathering orelse return;
        screen.gathering = null;
        if (screen.loaded) |*old| old.deinit();
        screen.loaded = gathered;
        screen.folded = .empty;
        screen.makeRows();
        screen.list = .of(screen.row_count, shown_rows, context.ticks);
        screen.chosen = screen.firstMod();
        const listed = gathered.entries().len;
        log.info("the catalogue lists {d} mods", .{listed});
        if (listed > most_mods) log.warn("the GET MODS screen lists {d} mods; the rest are left out", .{most_mods});
    }

    /// Keeps the repository `name` as the one that couldn't be read, and why. A copy of the name
    /// that can't be made is logged and left out.
    fn recordFailure(screen: *ModCatalogue, gpa: Allocator, name: []const u8, failure: catalogue.Failure) void {
        screen.forgetFailure();
        const copied = gpa.dupe(u8, name) catch {
            log.warn("the failure to read {s} can't be kept for the screen: out of memory", .{name});
            return;
        };
        screen.failed = .{ .gpa = gpa, .name = copied, .failure = failure };
    }

    fn forgetFailure(screen: *ModCatalogue) void {
        if (screen.failed) |failed| failed.gpa.free(failed.name);
        screen.failed = null;
    }

    /// Reads the `mods` folder, to know which mods are installed. The OpenReliant version isn't
    /// checked: every mod found counts as installed, whichever list it lands in.
    fn scan(screen: *ModCatalogue, context: Context) void {
        const source = context.source;
        const order: Order = .{ .profile = context.settings_file.profile };
        const found: bigfile.Mods = bigfile.Mods.installed(source.gpa, source.io, source.game, null, order) catch |err| {
            log.warn("the mods folder can't be read: {s}", .{@errorName(err)});
            return;
        };
        if (screen.present) |*present| present.mods.close(present.gpa);
        screen.present = .{ .gpa = source.gpa, .mods = found, .order = order };
    }

    /// Whether the mod `entry` is in the `mods` folder, in which version, as a folder or an
    /// archive, and from which repository GET MODS installed it.
    fn statusOf(screen: ModCatalogue, entry: Entry) Status {
        const present = screen.present orelse return .absent;
        for ([_][]const Mod{ present.mods.list, present.mods.off, present.mods.damaged, present.mods.unmet }) |each| for (each) |mod| {
            if (!std.ascii.eqlIgnoreCase(mod.qualifier(), entry.id)) continue;
            return .{ .installed = .{ .version = mod.about(.version), .folder = mod.source == .folder, .repository = present.order.installedFrom(mod.name) } };
        };
        return .absent;
    }

    /// What INSTALL does for the mod at `index` in the catalogue. Nothing while a download runs, when
    /// the mod needs a newer OpenReliant, when a folder mod of its name is installed, or when the
    /// installed version is the catalogue's or newer.
    fn actionFor(screen: ModCatalogue, index: u8) Action {
        if (screen.installing != null) return .none;
        const entry = screen.entries()[index];
        if (entry.needsLater(screen.running) != null) return .none;
        return switch (screen.statusOf(entry)) {
            .absent => .install,
            .installed => |installed| {
                if (installed.folder) return .none;
                const have = bigfile.mods.parseVersion(installed.version orelse return .install) orelse return .install;
                const offered = entry.semantic() orelse return .install;
                return if (offered.order(have) == .gt) .update else .none;
            },
        };
    }

    /// What INSTALL does for the selected mod; nothing when no mod is selected.
    fn action(screen: ModCatalogue) Action {
        const index = screen.chosen orelse return .none;
        return screen.actionFor(index);
    }

    /// Whether RELOAD can read the repositories again: not while they are being read, and not
    /// while a mod downloads, since the download's mod is known by its place in the catalogue.
    fn canReload(screen: ModCatalogue) bool {
        return screen.installing == null and screen.reading == null;
    }

    /// One pass of the screen's loop. Collects the catalogue, the install and the thumbnail when their
    /// downloads finish, then handles the input. Returns how the screen ends, once it does.
    pub fn frame(screen: *ModCatalogue, context: Context) ?Leave {
        screen.running = context.source.version;
        screen.takeCatalogue(context);
        screen.takeInstall(context);
        screen.takeThumbnail(context.source);
        if (context.keyboard.pressed(input.scan.escape, .none, true)) return .{ .mods = .{ .installed = screen.installed_any } };
        var pointer = context.pointer;
        if (pointer.down and screen.held) pointer.down = false else screen.held = false;
        screen.lit = null;
        screen.list.scrollBy(pointer.wheel, context.keyboard, context.ticks);
        const under = screen.itemAt(pointer.at) orelse return null;
        if (!pointer.down) {
            screen.lit = under;
            return null;
        }
        screen.held = true;
        switch (under) {
            .button => |button| switch (button) {
                .ok => return .{ .mods = .{ .installed = screen.installed_any } },
                .leave => return .main_menu,
                .install => screen.startInstall(context),
                .reload => screen.reload(context),
            },
            .scroll => |way| {
                screen.list.scrollHeld(way, context.ticks);
                screen.held = false;
            },
            .choose => |index| screen.chosen = index,
            .fold => |group| screen.fold(group),
        }
        return null;
    }

    /// Once the index of the repository being read has downloaded, or has failed to, adds its mods
    /// to the catalogue being gathered, and goes on to the next repository.
    fn takeCatalogue(screen: *ModCatalogue, context: Context) void {
        const index = screen.reading orelse return;
        const gpa = context.source.gpa;
        switch (screen.fetch.state()) {
            .idle, .running => return,
            .failed => {
                const name = if (Repositories.of(context.settings_file.profile).at(index)) |repository| repository.name else "";
                screen.recordFailure(gpa, name, screen.fetch.failure.?);
                screen.fetch.deinit();
            },
            .done => screen.gather(context, index),
        }
        screen.reading = index + 1;
        screen.readNext(context);
    }

    /// Adds the mods of the index that has downloaded, of the repository at `index` in the settings
    /// file's list, to the catalogue being gathered. The fetch is idle afterwards.
    fn gather(screen: *ModCatalogue, context: Context, index: usize) void {
        const gpa = context.source.gpa;
        const repository = Repositories.of(context.settings_file.profile).at(index) orelse catalogue.Repository{ .name = "", .url = "" };
        const bytes = screen.fetch.finish() orelse {
            screen.recordFailure(gpa, repository.name, .out_of_memory);
            return;
        };
        defer gpa.free(bytes);
        const gathering = &(screen.gathering orelse return);
        gathering.add(repository, bytes) catch |err| {
            log.warn("{s}: the catalogue can't be read: {s}", .{ repository.name, @errorName(err) });
            screen.recordFailure(gpa, repository.name, .of(err));
        };
    }

    /// RELOAD: reads the repositories again, when it can (`canReload`).
    fn reload(screen: *ModCatalogue, context: Context) void {
        if (!screen.canReload()) return;
        screen.scan(context);
        screen.startReading(context);
    }

    /// INSTALL or UPDATE: starts downloading the selected mod, if there is something to do.
    fn startInstall(screen: *ModCatalogue, context: Context) void {
        const index = screen.chosen orelse return;
        if (screen.actionFor(index) == .none) return;
        const source = context.source;
        const client = screen.httpClient() orelse return;
        const entry = screen.entries()[index];
        screen.forgetOutcome();
        screen.install.start(source.gpa, source.io, client, source.game, entry) catch |err| {
            log.warn("the mod {s} can't be installed: {s}", .{ entry.id, @errorName(err) });
            screen.recordOutcome(source.gpa, entry.id, catalogue.Failure.ofStart(err));
            return;
        };
        screen.installing = index;
    }

    /// Once the install is done or has failed, rereads the `mods` folder and keeps the result for the
    /// panel.
    fn takeInstall(screen: *ModCatalogue, context: Context) void {
        const index = screen.installing orelse return;
        const failure: ?catalogue.Failure = switch (screen.install.state()) {
            .idle, .running => return,
            .done => null,
            .failed => screen.install.failure,
        };
        screen.install.finish();
        screen.installing = null;
        const entry = screen.entries()[index];
        if (failure == null) {
            screen.installed_any = true;
            recordInstalled(context, entry);
            screen.scan(context);
        }
        screen.forgetOutcome();
        screen.recordOutcome(context.source.gpa, entry.id, failure);
    }

    /// Records in the settings file that GET MODS installed `entry`, and from which repository, so
    /// that the loader checks the archive against its checksum file from now on
    /// (`bigfile.order.installed_section`). A record that can't be written is logged.
    fn recordInstalled(context: Context, entry: Entry) void {
        var buffer: [name_buffer]u8 = undefined;
        const archive = entry.archiveName(&buffer) catch return;
        Order.recordInstall(context.settings_file, archive, entry.repository) catch |err| {
            log.warn("{s}: the install isn't recorded in the settings file: {s}", .{ entry.id, @errorName(err) });
        };
    }

    /// Keeps the result of the install of the mod `id` for the panel; a copy that can't be made is
    /// logged and left out.
    fn recordOutcome(screen: *ModCatalogue, gpa: Allocator, id: []const u8, failure: ?catalogue.Failure) void {
        const copied = gpa.dupe(u8, id) catch {
            log.warn("the result of installing {s} can't be kept for the screen: out of memory", .{id});
            return;
        };
        screen.outcome = .{ .gpa = gpa, .id = copied, .failure = failure };
    }

    fn forgetOutcome(screen: *ModCatalogue) void {
        if (screen.outcome) |outcome| outcome.gpa.free(outcome.id);
        screen.outcome = null;
    }

    /// Stores the thumbnail whose download has finished, then starts downloading the selected mod's
    /// thumbnail if it has one that isn't downloaded yet. One thumbnail downloads at a time.
    fn takeThumbnail(screen: *ModCatalogue, source: mod_manager.Source) void {
        const gpa = source.gpa;
        switch (screen.thumbnail_fetch.state()) {
            .running => return,
            .idle => {},
            .done, .failed => screen.keepThumbnail(gpa),
        }
        const index = screen.chosen orelse return;
        const entry = screen.entries()[index];
        const url = entry.thumbnail orelse return;
        if (screen.thumbnails.kept(entry.id) != null) return;
        const client = screen.httpClient() orelse return;
        const id = gpa.dupe(u8, entry.id) catch return;
        screen.thumbnail_fetch.start(gpa, source.io, client, url, catalogue.most_thumbnail_bytes) catch |err| {
            log.warn("{s}: can't download the thumbnail: {s}", .{ entry.id, @errorName(err) });
            gpa.free(id);
            _ = screen.thumbnails.keep(gpa, entry.id, null);
            return;
        };
        screen.thumbnail_of = .{ .gpa = gpa, .id = id };
    }

    /// Keeps the thumbnail whose download has ended, decoded if it came, or none if it failed, so
    /// that it isn't downloaded again. The fetch is idle afterwards.
    fn keepThumbnail(screen: *ModCatalogue, gpa: Allocator) void {
        const bytes = screen.thumbnail_fetch.finish();
        if (bytes == null) screen.thumbnail_fetch.deinit();
        defer if (bytes) |downloaded| gpa.free(downloaded);
        const pending = screen.thumbnail_of orelse return;
        const id = pending.id;
        defer {
            pending.gpa.free(id);
            screen.thumbnail_of = null;
        }
        // A download that failed was logged by the fetch.
        const image = if (bytes) |downloaded| mod_manager.decodeThumbnail(gpa, downloaded, id) else null;
        _ = screen.thumbnails.keep(gpa, id, image);
    }

    /// The item under the pointer at `at`: a button, a list arrow, or a visible row, which is a mod's
    /// name or a group's heading. INSTALL is found only when it has something to do, and RELOAD
    /// only when it can reload.
    pub fn itemAt(screen: ModCatalogue, at: [2]i32) ?Item {
        for (std.enums.values(Button)) |button| {
            if (!screen.usable(button)) continue;
            if (button.rect().holds(at)) return .{ .button = button };
        }
        if (arrows.itemAt(at)) |arrow| return .{ .scroll = arrow };
        for (screen.list.rows.first..screen.list.rows.end(), 0..) |row, place| {
            if (!nameRect(place).holds(at)) continue;
            return switch (screen.rows[row]) {
                .mod => |index| .{ .choose = index },
                .heading => |group| .{ .fold = group },
            };
        }
        return null;
    }

    /// Whether `button` does something now: INSTALL when there is a mod to install or update, RELOAD
    /// when the catalogue can be read again, and the others always.
    fn usable(screen: ModCatalogue, button: Button) bool {
        return switch (button) {
            .install => screen.action() != .none,
            .reload => screen.canReload(),
            .ok, .leave => true,
        };
    }

    /// Draws the screen over the background: the title, the list, the panel, the buttons with the one
    /// under the pointer highlighted and the ones that do nothing dimmed, OpenReliant's version, and
    /// the pointer.
    pub fn draw(screen: ModCatalogue, canvas: Canvas, art: *hud.Art, pointer: Pointer) canvas_module.Error!void {
        try title.write(canvas, canvas.fonts.large, canvas_module.white);
        list_frame.draw(canvas);
        details_frame.draw(canvas);
        try screen.drawList(canvas, art);
        try screen.drawDetails(canvas);
        const doing = screen.action();
        for (std.enums.values(Button)) |button| {
            try button.shown(doing).draw(canvas.dimmedUnless(screen.usable(button)), art, settings.button_shapes, std.meta.eql(screen.lit, Item{ .button = button }));
        }
        try canvas.drawVersion();
        try canvas.onScreen().shape(art, pointer.shape(), pointer.at);
    }

    /// Draws the visible rows: a group's heading in the large font, in blue, like the controls tab's
    /// headings, or a mod's name and version in the small font, indented. A mod that needs a newer
    /// OpenReliant is red, else the selected mod is white, a mod with an update available is gold,
    /// and an installed mod is dimmed. Then draws the arrows, with the one under the pointer
    /// highlighted.
    fn drawList(screen: ModCatalogue, canvas: Canvas, art: *hud.Art) canvas_module.Error!void {
        const font = canvas.fonts.small;
        if (screen.loaded == null) {
            if (screen.reading != null) {
                try reading_note.write(canvas, font, canvas_module.blue);
            } else if (screen.failed) |failed| {
                try unreadable_note.write(canvas, font, canvas_module.red);
                try canvas.text(font, note_below, failed.failure.words(), canvas_module.red, .centre);
            }
        } else if (screen.count() == 0) {
            if (screen.failed) |failed| {
                try unreadable_note.write(canvas, font, canvas_module.red);
                try canvas.text(font, note_below, failed.failure.words(), canvas_module.red, .centre);
            } else {
                try empty_note.write(canvas, font, canvas_module.blue);
            }
        } else if (screen.failed) |failed| {
            // The other repositories' mods are listed; the one that can't be read is named above.
            var note: [name_buffer]u8 = undefined;
            try canvas.text(font, repository_note_at, repositoryNote(&note, failed), canvas_module.red, .right);
        }
        for (screen.list.rows.first..screen.list.rows.end(), 0..) |row, place| {
            var named: [name_buffer]u8 = undefined;
            const lines: Canvas.Lines = .{ .width = name_width, .height = row_spacing, .most = 1 };
            switch (screen.rows[row]) {
                .heading => |group| try canvas.wrapped(canvas.fonts.large, nameAt(place), screen.headingOf(&named, group), canvas_module.blue, .left, lines),
                .mod => |index| {
                    const entry = screen.entries()[index];
                    const is_chosen = screen.chosen == index;
                    const too_new = entry.needsLater(screen.running) != null;
                    const updatable = screen.actionFor(index) == .update;
                    const colour = if (too_new) canvas_module.red else if (is_chosen) canvas_module.white else if (updatable) canvas_module.gold else canvas_module.blue;
                    const bright = is_chosen or too_new or updatable or screen.statusOf(entry) == .absent;
                    const at = nameAt(place);
                    try canvas.dimmedUnless(bright).wrapped(font, .{ at[0] + indent, at[1] }, nameOf(&named, entry), colour, .left, lines);
                },
            }
        }
        const lit_arrow: ?Arrow = if (screen.lit) |lit| switch (lit) {
            .scroll => |arrow| arrow,
            .button, .choose, .fold => null,
        } else null;
        try arrows.draw(canvas, art, lit_arrow);
    }

    /// Draws the panel: the selected mod's thumbnail if it has downloaded, its name, then its status
    /// line right under the name so that it stands out (installed and in which version, downloading,
    /// or the result of its install), then what the catalogue says about it (version, author,
    /// category, the OpenReliant it needs, size, description), and the progress bar at the bottom
    /// during a download.
    fn drawDetails(screen: ModCatalogue, canvas: Canvas) canvas_module.Error!void {
        const chosen = screen.chosen orelse return choose_note.write(canvas, canvas.fonts.small, canvas_module.blue);
        const entry = screen.entries()[chosen];
        const font = canvas.fonts.small;
        const x = details_frame.at[0] + details_inside;
        var y = details_frame.at[1] + details_inside;
        if (screen.thumbnails.kept(entry.id)) |kept| if (kept.image) |picture| {
            const size = mod_manager.thumbnailSize(picture);
            canvas.imageOver(picture, .{ x + @divTrunc(details_lines.width - size[0], 2), y }, size);
            y += size[1] + thumbnail_gap;
        };
        try canvas.wrapped(font, .{ x, y }, entry.title(), canvas_module.white, .left, details_lines);
        y += details_lines.height;
        var status_buffer: [name_buffer]u8 = undefined;
        if (screen.statusLine(&status_buffer, chosen)) |line| {
            try canvas.wrapped(font, .{ x, y }, line.text, line.colour, .left, status_lines);
            y += status_lines.height * @as(i32, @intCast(status_lines.count(font, line.text)));
        }
        var size_buffer: [name_buffer]u8 = undefined;
        var category_buffer: [name_buffer]u8 = undefined;
        const too_new = entry.needsLater(screen.running) != null;
        const facts = [_]Fact{
            .{ .prefix = "VERSION ", .value = entry.version, .colour = canvas_module.blue },
            .{ .prefix = "BY ", .value = entry.author, .colour = canvas_module.blue },
            .{ .prefix = "IN ", .value = if (entry.category) |path| pathText(&category_buffer, path) else null, .colour = canvas_module.blue },
            .{ .prefix = "FROM ", .value = entry.repository, .colour = canvas_module.blue },
            .{ .prefix = "NEEDS OPENRELIANT ", .value = entry.openreliant, .colour = if (too_new) canvas_module.red else canvas_module.blue },
            .{ .prefix = "SIZE ", .value = sizeText(&size_buffer, entry.size), .colour = canvas_module.blue },
        };
        for (facts) |fact| if (fact.value) |value| {
            var line_buffer: [name_buffer]u8 = undefined;
            const line = std.mem.print(&line_buffer, "{s}{s}", .{ fact.prefix, value }) catch value;
            try canvas.wrapped(font, .{ x, y }, line, fact.colour, .left, details_lines);
            y += details_lines.height;
        };
        // The description takes the lines left above the bottom, or above the progress bar during
        // a download.
        const downloading = screen.installing == chosen;
        const bottom = if (downloading) bar_at[1] - thumbnail_gap else details_frame.at[1] + frame_height - details_inside;
        if (entry.description) |description| {
            const room = @divTrunc(bottom - y, details_lines.height);
            var shown = description_lines;
            shown.most = @min(description_lines.most, @as(usize, @intCast(@max(room, 1))));
            try canvas.wrapped(font, .{ x, y }, description, canvas_module.blue, .left, shown);
        }
        if (downloading) screen.drawBar(canvas);
    }

    /// The status line of the mod at `index` in the catalogue, written into `buffer`: the download's
    /// progress, the result of its install, that it needs a newer OpenReliant, that a folder mod of
    /// its name was installed by hand, or the installed version, BY HAND where the settings file
    /// doesn't record the install, and, if the catalogue's is newer, the update. Null when there is nothing to say. The versions are shown as the manifest and
    /// the catalogue write them.
    fn statusLine(screen: ModCatalogue, buffer: *[name_buffer]u8, index: u8) ?Note {
        const entry = screen.entries()[index];
        if (screen.installing == index) {
            const text = if (screen.install.progress.fraction()) |fraction|
                std.mem.print(buffer, "DOWNLOADING {d}%", .{@as(u32, @intFromFloat(fraction * 100))}) catch "DOWNLOADING"
            else
                "DOWNLOADING";
            return .{ .text = text, .colour = canvas_module.gold };
        }
        if (screen.outcome) |outcome| if (std.mem.eql(u8, outcome.id, entry.id)) {
            if (outcome.failure) |failure| return .{ .text = failure.words(), .colour = canvas_module.red };
            return .{ .text = "INSTALLED: RESTART TO APPLY", .colour = canvas_module.gold };
        };
        if (entry.needsLater(screen.running) != null) {
            return .{ .text = std.mem.print(buffer, "NEEDS OPENRELIANT {s}", .{entry.openreliant.?}) catch "NEEDS A NEWER OPENRELIANT", .colour = canvas_module.red };
        }
        // Installed, in gold as the mods screen's RESTART TO APPLY note is, so that it stands out.
        return switch (screen.statusOf(entry)) {
            .absent => null,
            .installed => |installed| {
                if (installed.folder) {
                    const have = installed.version orelse return .{ .text = by_hand_note, .colour = canvas_module.gold };
                    return .{ .text = std.mem.print(buffer, "INSTALLED {s} BY HAND AS A FOLDER: INSTALL WON'T REPLACE IT", .{have}) catch by_hand_note, .colour = canvas_module.gold };
                }
                // An archive the settings file doesn't record was copied in by hand.
                const how: []const u8 = if (installed.repository == null) " BY HAND" else "";
                const have = installed.version orelse return .{ .text = if (installed.repository == null) "INSTALLED BY HAND" else "INSTALLED", .colour = canvas_module.gold };
                if (screen.actionFor(index) == .update) {
                    return .{ .text = std.mem.print(buffer, "INSTALLED {s}{s}, UPDATE TO {s}", .{ have, how, entry.version.? }) catch "UPDATE AVAILABLE", .colour = canvas_module.gold };
                }
                return .{ .text = std.mem.print(buffer, "INSTALLED {s}{s}", .{ have, how }) catch "INSTALLED", .colour = canvas_module.gold };
            },
        };
    }

    /// Draws the progress bar at the bottom of the panel, filled to the download's progress.
    fn drawBar(screen: ModCatalogue, canvas: Canvas) void {
        canvas.box(bar_at, .{ bar_width, bar_height });
        const fraction = screen.install.progress.fraction() orelse return;
        const filled: i32 = @intFromFloat(@round(fraction * @as(f32, @floatFromInt(bar_width - 2 * bar_inside))));
        if (filled <= 0) return;
        canvas.wipe(.{ bar_at[0] + bar_inside, bar_at[1] + bar_inside }, .{ bar_at[0] + bar_inside + filled - 1, bar_at[1] + bar_height - bar_inside - 1 }, canvas_module.gold);
    }
};

/// A line of the panel's status, with its colour.
const Note = struct { text: []const u8, colour: [3]f32 };

/// The note about the repository `failed`, which couldn't be read, written into `buffer`: its
/// name and why, such as `CAN'T READ MINE: NOT FOUND ON THE SERVER`.
fn repositoryNote(buffer: *[name_buffer]u8, failed: Failed) []const u8 {
    var writer: Io.Writer = .fixed(buffer);
    writer.writeAll("CAN'T READ ") catch {};
    for (failed.name) |byte| writer.writeByte(std.ascii.toUpper(byte)) catch break;
    writer.print(": {s}", .{failed.failure.words()}) catch {};
    return writer.buffered();
}

/// The layout of the status line: up to two lines.
const status_lines: Canvas.Lines = .{ .width = details_lines.width, .height = details_lines.height, .most = 2 };

/// A line of the panel's facts about a mod: its prefix, such as `VERSION `, its value where the
/// catalogue gives one, and its colour.
const Fact = struct { prefix: []const u8, value: ?[]const u8, colour: [3]f32 };

/// Writes a category's `path` in capitals, with its folders separated by `path_separator`:
/// `SHIPS / FIGHTERS / ALLIANCE` for `ships/fighters/alliance`. Stops where `writer` is full.
fn writePath(writer: *Io.Writer, path: []const u8) void {
    var folders = std.mem.splitScalar(u8, path, '/');
    var first = true;
    while (folders.next()) |folder| {
        if (!first) writer.writeAll(path_separator) catch return;
        first = false;
        for (folder) |byte| writer.writeByte(std.ascii.toUpper(byte)) catch return;
    }
}

/// A category's `path` as the panel shows it (`writePath`), written into `buffer`.
fn pathText(buffer: *[name_buffer]u8, path: []const u8) []const u8 {
    var writer: Io.Writer = .fixed(buffer);
    writePath(&writer, path);
    return writer.buffered();
}

/// A row's text, the mod's name followed by its version, written into `buffer`.
fn nameOf(buffer: *[name_buffer]u8, entry: Entry) []const u8 {
    const version = entry.version orelse return entry.title();
    return std.mem.print(buffer, "{s} {s}", .{ entry.title(), version }) catch entry.title();
}

/// The units a size is shown in.
const kilobyte = 1024;
const megabyte = 1024 * kilobyte;

/// A size in bytes as the panel shows it, written into `buffer`: in megabytes with one decimal,
/// or in kilobytes below one megabyte, each rounded to the nearest.
fn sizeText(buffer: []u8, bytes: u64) []const u8 {
    if (bytes >= megabyte) {
        const tenths = (bytes * 10 + megabyte / 2) / megabyte;
        return std.mem.print(buffer, "{d}.{d} MB", .{ tenths / 10, tenths % 10 }) catch "";
    }
    return std.mem.print(buffer, "{d} KB", .{(bytes + kilobyte / 2) / kilobyte}) catch "";
}

/// Where the name of the `place`th visible row starts.
fn nameAt(place: usize) [2]i32 {
    return .{ name_x, first_row + @as(i32, @intCast(place)) * row_spacing };
}

/// The area of the name of the `place`th visible row, for the pointer: the row's height, and the
/// text's width plus a little on each side, as on the mods screen.
fn nameRect(place: usize) Rect {
    const at = nameAt(place);
    return .{ .x = @intCast(at[0] - name_reach), .y = @intCast(at[1]), .width = name_width + 2 * name_reach, .height = widgets.Box.size };
}

/// How far past a name's text the pointer still finds it, on each side.
const name_reach = 2;

fn nameCentre(place: usize) [2]i32 {
    return nameRect(place).centre();
}

/// The test setup: a catalogue of three mods, two under `ships` and one without a category, a `mods`
/// folder where two of them are installed, Alpha as an archive in an older version and Gamma as a
/// folder copied in by hand, and no web access unless a test serves the files itself. The rows are
/// the heading SHIPS, Alpha, Beta, the heading OTHER MODS, and Gamma.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    mods: bigfile.Mods,
    file: profile.File,
    keyboard: input.Keyboard = .{},
    screen: ModCatalogue = .{},
    /// No mod offers options.
    options: mod_options.Recorder = .{ .mod = "", .page = .{ .title = "", .options = &.{} } },

    /// A digest for the mods whose archives are nowhere.
    const some_digest = "abababababababababababababababababababababababababababababababab";

    /// The catalogue, with Alpha's archive at `archive`, of `size` bytes and with the digest
    /// `digest`, which `index` fills in. Gamma is offered in a newer version than the folder's.
    const index_template =
        \\{{"format": 1, "mods": [
        \\  {{"id": "alpha", "name": "Alpha mod", "category": "ships/fighters", "version": "1.3", "author": "Someone", "openreliant": "0.7",
        \\   "size": {d}, "description": "Changes the alpha.", "archive": "{s}", "sha256": "{s}"}},
        \\  {{"id": "beta", "name": "Beta mod", "category": "ships/fighters/alliance", "version": "4.0.3", "openreliant": "99.0",
        \\   "size": 1, "archive": "https://example.invalid/beta.hog", "sha256": "
    ++ some_digest ++
        \\"}},
        \\  {{"id": "gamma", "version": "2.0", "size": 1, "archive": "https://example.invalid/gamma.hog", "sha256": "
    ++ some_digest ++
        \\"}}
        \\]}}
    ;

    /// The index with Alpha's archive at `archive`, of `size` bytes and with the digest `digest`.
    fn index(buffer: []u8, archive: []const u8, size: usize, digest: []const u8) []const u8 {
        return std.mem.print(buffer, index_template, .{ size, archive, digest }) catch unreachable;
    }

    /// The settings file with an empty section of repositories, so that the screen reads nothing.
    const no_repositories = "[OpenReliantModRepositories]\n";

    /// Opens the screen on the catalogue `text`, as if it had been downloaded from the repository
    /// `test`, with `no_repositories` to read.
    fn init(fixture: *Fixture, text: []const u8) !void {
        try fixture.initWith(text, no_repositories);
    }

    /// Opens the screen with `settings_text` as the settings file, and the catalogue `text`
    /// already read, or none to read the repositories the settings file names.
    fn initWith(fixture: *Fixture, text: ?[]const u8, settings_text: []const u8) !void {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        fixture.tmp = std.testing.tmpDir(.{ .iterate = true });
        fixture.arena = .init(gpa);
        try fixture.tmp.dir.createDirPath(io, "mods/gamma");
        try hog.testing.write(gpa, io, fixture.tmp.dir, "mods/alpha.hog", &.{.{ .name = "mod.ini", .data = "[Mod]\nName=Alpha mod\nVersion=1.2\n" }});
        try fixture.tmp.dir.writeFile(io, .{ .sub_path = "mods/gamma/mod.ini", .data = "[Mod]\nName=Gamma mod\nVersion=1.0\n" });
        fixture.file = .{ .arena = fixture.arena.allocator(), .profile = .{ .text = settings_text } };
        fixture.mods = try .openOrdered(gpa, io, fixture.tmp.dir, null, .{ .profile = fixture.file.profile });
        fixture.keyboard = .{};
        fixture.screen = .{};
        if (text) |given| {
            fixture.screen.loaded = .init(gpa);
            try fixture.screen.loaded.?.add(.{ .name = "test", .url = "" }, given);
        }
        fixture.screen.enter(fixture.context(.{}));
    }

    /// The index with Alpha's archive nowhere.
    fn initOffline(fixture: *Fixture) !void {
        var buffer: [1024]u8 = undefined;
        try fixture.init(index(&buffer, "https://example.invalid/alpha.hog", 5624773, some_digest));
    }

    fn deinit(fixture: *Fixture) void {
        fixture.screen.deinit();
        fixture.mods.close(std.testing.allocator);
        fixture.arena.deinit();
        fixture.tmp.cleanup();
    }

    fn source(fixture: *Fixture) mod_manager.Source {
        return .{
            .loaded = &fixture.mods,
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .game = fixture.tmp.dir,
            .version = .{ .major = 0, .minor = 9, .patch = 0 },
            .pages = fixture.options.pages(),
        };
    }

    fn context(fixture: *Fixture, pointer: Pointer) Context {
        return .{ .pointer = pointer, .keyboard = &fixture.keyboard, .settings_file = &fixture.file, .ticks = 0, .source = fixture.source() };
    }

    /// A click at `at`: a frame with the pointer there and its button up, then one with it down.
    fn click(fixture: *Fixture, at: [2]i32) ?Leave {
        _ = fixture.screen.frame(fixture.context(.{ .at = at }));
        return fixture.screen.frame(fixture.context(.{ .at = at, .down = true }));
    }
};

test "the rows are the catalogue's mods under their categories, and the panel says which are installed" {
    var fixture: Fixture = undefined;
    try fixture.initOffline();
    defer fixture.deinit();
    const screen = &fixture.screen;
    try std.testing.expectEqual(3, screen.count());
    try std.testing.expectEqual(5, screen.row_count);
    try std.testing.expectEqualDeep(&[_]Row{ .{ .heading = 0 }, .{ .mod = 0 }, .{ .mod = 1 }, .{ .heading = 1 }, .{ .mod = 2 } }, screen.rows[0..5]);
    var heading: [name_buffer]u8 = undefined;
    try std.testing.expectEqualStrings("- SHIPS", screen.headingOf(&heading, 0));
    try std.testing.expectEqualStrings("- OTHER MODS", screen.headingOf(&heading, 1));
    try std.testing.expectEqualStrings("SHIPS / FIGHTERS / ALLIANCE", pathText(&heading, "ships/fighters/alliance"));
    try std.testing.expectEqual(0, screen.chosen.?);
    // Alpha is installed in 1.2 as an archive copied in by hand, and the catalogue offers 1.3: an
    // update. Beta needs OpenReliant 99: nothing can be done. Gamma is installed as a folder, so
    // the newer version the catalogue offers is left alone.
    try std.testing.expectEqual(.update, screen.actionFor(0));
    try std.testing.expectEqual(.none, screen.actionFor(1));
    try std.testing.expectEqual(.none, screen.actionFor(2));
    const alpha = screen.statusOf(screen.entries()[0]).installed;
    try std.testing.expectEqualStrings("1.2", alpha.version.?);
    try std.testing.expect(!alpha.folder);
    try std.testing.expectEqual(null, alpha.repository);
    try std.testing.expectEqual(.absent, screen.statusOf(screen.entries()[1]));
    try std.testing.expect(screen.statusOf(screen.entries()[2]).installed.folder);
    var buffer: [name_buffer]u8 = undefined;
    // The versions are shown as the manifest and the catalogue write them.
    try std.testing.expectEqualStrings("INSTALLED 1.2 BY HAND, UPDATE TO 1.3", screen.statusLine(&buffer, 0).?.text);
    try std.testing.expectEqualStrings("NEEDS OPENRELIANT 99.0", screen.statusLine(&buffer, 1).?.text);
    try std.testing.expectEqualStrings("INSTALLED 1.0 BY HAND AS A FOLDER: INSTALL WON'T REPLACE IT", screen.statusLine(&buffer, 2).?.text);
    // The repository that can't be read is named above the list, in capitals.
    try std.testing.expectEqualStrings("CAN'T READ MINE: NOT FOUND ON THE SERVER", repositoryNote(&buffer, .{ .gpa = std.testing.allocator, .name = @constCast("mine"), .failure = .not_found }));
    try std.testing.expectEqualStrings("Alpha mod 1.3", nameOf(&buffer, screen.entries()[0]));
    try std.testing.expectEqualStrings("gamma 2.0", nameOf(&buffer, screen.entries()[2]));
}

test "clicking a name selects the mod, and INSTALL is active only when it does something" {
    var fixture: Fixture = undefined;
    try fixture.initOffline();
    defer fixture.deinit();
    const screen = &fixture.screen;
    try std.testing.expectEqual(Item{ .button = .install }, screen.itemAt(Button.install.rect().centre()).?);
    try std.testing.expectEqual(Item{ .button = .reload }, screen.itemAt(Button.reload.rect().centre()).?);
    // Beta is in the third row, after Alpha under SHIPS.
    _ = fixture.click(nameCentre(2));
    try std.testing.expectEqual(1, screen.chosen.?);
    try std.testing.expectEqual(null, screen.itemAt(Button.install.rect().centre()));
    try std.testing.expectEqual(null, fixture.click(Button.install.rect().centre()));
    try std.testing.expectEqual(null, screen.installing);
    try std.testing.expectEqual(Item{ .scroll = .down }, screen.itemAt(arrows.rect(.down).centre()).?);
    try std.testing.expectEqual(null, screen.itemAt(.{ 500, 300 }));
}

test "clicking a heading folds its group and unfolds it, keeping the selected mod" {
    var fixture: Fixture = undefined;
    try fixture.initOffline();
    defer fixture.deinit();
    const screen = &fixture.screen;
    try std.testing.expectEqual(Item{ .fold = 0 }, screen.itemAt(nameCentre(0)).?);
    // Folding SHIPS hides Alpha and Beta; Alpha stays selected, and OTHER MODS stays open.
    _ = fixture.click(nameCentre(0));
    try std.testing.expectEqual(3, screen.row_count);
    try std.testing.expectEqualDeep(&[_]Row{ .{ .heading = 0 }, .{ .heading = 1 }, .{ .mod = 2 } }, screen.rows[0..3]);
    try std.testing.expectEqual(0, screen.chosen.?);
    var heading: [name_buffer]u8 = undefined;
    try std.testing.expectEqualStrings("+ SHIPS", screen.headingOf(&heading, 0));
    try std.testing.expectEqual(3, screen.list.rows.count);
    // Unfolding it brings them back.
    _ = fixture.click(nameCentre(0));
    try std.testing.expectEqual(5, screen.row_count);
    try std.testing.expectEqual(Row{ .mod = 0 }, screen.rows[1]);
    // A catalogue read again starts with every group open.
    screen.folded.set(1);
    screen.makeRows();
    try std.testing.expectEqual(4, screen.row_count);
    screen.folded = .empty;
    screen.makeRows();
    try std.testing.expectEqual(5, screen.row_count);
}

test "OK, MAIN MENU and Escape end the screen, saying whether a mod was installed" {
    var fixture: Fixture = undefined;
    try fixture.initOffline();
    defer fixture.deinit();
    try std.testing.expectEqual(Leave{ .mods = .{ .installed = false } }, fixture.click(Button.ok.rect().centre()).?);
    try std.testing.expectEqual(Leave.main_menu, fixture.click(Button.leave.rect().centre()).?);
    fixture.screen.installed_any = true;
    fixture.keyboard.down[input.scan.escape] = true;
    try std.testing.expectEqual(Leave{ .mods = .{ .installed = true } }, fixture.screen.frame(fixture.context(.{})).?);
    // Opening the screen again resets the flag.
    fixture.keyboard = .{};
    fixture.screen.enter(fixture.context(.{}));
    try std.testing.expectEqual(Leave{ .mods = .{ .installed = false } }, fixture.click(Button.ok.rect().centre()).?);
}

test "a screen without repositories lists nothing" {
    var fixture: Fixture = undefined;
    try fixture.initOffline();
    defer fixture.deinit();
    var empty: ModCatalogue = .{};
    defer empty.deinit();
    // The settings file names no repository: nothing is read, and nothing is wrong.
    empty.enter(fixture.context(.{}));
    try std.testing.expectEqual(null, empty.loaded);
    try std.testing.expectEqual(null, empty.reading);
    try std.testing.expectEqual(null, empty.failed);
    try std.testing.expectEqual(0, empty.count());
    try std.testing.expectEqual(0, empty.row_count);
    try std.testing.expectEqual(null, empty.chosen);
    try std.testing.expectEqual(null, empty.frame(fixture.context(.{})));
    try std.testing.expectEqual(.none, empty.action());
}

test "UPDATE downloads the mod into the mods folder, and the mods screen is told to read it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // The archive is a real one, so that the mods folder lists it once it is installed.
    const archive = try hog.build(gpa, &.{.{ .name = "mod.ini", .data = "[Mod]\nName=Alpha mod\nVersion=1.3\n" }});
    defer gpa.free(archive);
    const digest = std.fmt.bytesToHex(checksums.digest(archive), .lower);
    var fixture: Fixture = undefined;
    var server: catalogue.testing.Server = undefined;
    try server.start(io, &.{.{ .path = "/alpha.hog", .body = archive }});
    var archive_url: [128]u8 = undefined;
    var text: [1024]u8 = undefined;
    try fixture.init(Fixture.index(&text, server.url(&archive_url, "/alpha.hog"), archive.len, &digest));
    defer fixture.deinit();
    defer server.stop(gpa, fixture.screen.httpClient().?);
    const screen = &fixture.screen;
    // Alpha is selected, with an update to get. UPDATE starts the download; INSTALL and RELOAD then
    // do nothing until it ends.
    try std.testing.expectEqual(null, fixture.click(Button.install.rect().centre()));
    try std.testing.expectEqual(0, screen.installing.?);
    try std.testing.expect(!screen.canReload());
    try std.testing.expectEqual(null, screen.itemAt(Button.reload.rect().centre()));
    try screen.install.group.await(io);
    // The next pass takes the install in: the archive is in the mods folder with its checksum file,
    // the panel says so, and OK tells the mods screen.
    try std.testing.expectEqual(null, screen.frame(fixture.context(.{})));
    try std.testing.expectEqual(null, screen.installing);
    try std.testing.expect(screen.installed_any);
    try std.testing.expect(screen.canReload());
    var buffer: [name_buffer]u8 = undefined;
    try std.testing.expectEqualStrings("INSTALLED: RESTART TO APPLY", screen.statusLine(&buffer, 0).?.text);
    const written = try fixture.tmp.dir.readFileAlloc(io, "mods/alpha.hog", gpa, .limited(1024));
    defer gpa.free(written);
    try std.testing.expectEqualSlices(u8, archive, written);
    try fixture.tmp.dir.access(io, "mods/alpha.hog.sha256", .{});
    // The install is recorded with its repository, and the panel knows the new version and the
    // repository from then on: nothing is left to update.
    try std.testing.expectEqualStrings("[OpenReliantModRepositories]\n[OpenReliantInstalledMods]\nalpha.hog=test\n", fixture.file.profile.text);
    const installed = screen.statusOf(screen.entries()[0]).installed;
    try std.testing.expectEqualStrings("1.3", installed.version.?);
    try std.testing.expectEqualStrings("test", installed.repository.?);
    try std.testing.expectEqual(.none, screen.actionFor(0));
    try std.testing.expectEqual(Leave{ .mods = .{ .installed = true } }, fixture.click(Button.ok.rect().centre()).?);
}

test sizeText {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("30.8 MB", sizeText(&buffer, 32297124));
    try std.testing.expectEqualStrings("1.0 MB", sizeText(&buffer, 1024 * 1024));
    try std.testing.expectEqualStrings("73 KB", sizeText(&buffer, 74285));
    try std.testing.expectEqualStrings("0 KB", sizeText(&buffer, 0));
}

test "the repositories are read one after another, and one that can't be read is named" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const first_index = "{\"mods\": [{\"id\": \"alpha\", \"size\": 1, \"archive\": \"/alpha.hog\", \"sha256\": \"" ++ Fixture.some_digest ++ "\"}]}";
    const second_index = "{\"mods\": [{\"id\": \"alpha\", \"size\": 2, \"archive\": \"/other.hog\", \"sha256\": \"" ++ Fixture.some_digest ++ "\"}, {\"id\": \"beta\", \"size\": 1, \"archive\": \"/beta.hog\", \"sha256\": \"" ++ Fixture.some_digest ++ "\"}]}";
    var server: catalogue.testing.Server = undefined;
    try server.start(io, &.{
        .{ .path = "/first.json", .body = first_index },
        .{ .path = "/second.json", .body = second_index },
    });
    var first_url: [128]u8 = undefined;
    var missing_url: [128]u8 = undefined;
    var second_url: [128]u8 = undefined;
    var text: [512]u8 = undefined;
    const settings_text = try std.mem.print(&text, "[OpenReliantModRepositories]\nfirst={s}\nmissing={s}\nsecond={s}\n", .{ server.url(&first_url, "/first.json"), server.url(&missing_url, "/missing.json"), server.url(&second_url, "/second.json") });
    var fixture: Fixture = undefined;
    try fixture.initWith(null, settings_text);
    defer fixture.deinit();
    defer server.stop(gpa, fixture.screen.httpClient().?);
    const screen = &fixture.screen;
    // Entering the screen starts reading the first repository. Each pass takes one in and starts
    // the next, until all three have been tried.
    try std.testing.expectEqual(0, screen.reading.?);
    try std.testing.expect(!screen.canReload());
    var passes: usize = 0;
    while (screen.reading != null) : (passes += 1) {
        try std.testing.expect(passes < 3);
        try screen.fetch.group.await(io);
        try std.testing.expectEqual(null, screen.frame(fixture.context(.{})));
    }
    try std.testing.expectEqual(3, passes);
    // The second repository's alpha is left out, since the first lists it, and its beta is added.
    try std.testing.expectEqual(2, screen.count());
    try std.testing.expectEqualStrings("alpha", screen.entries()[0].id);
    try std.testing.expectEqualStrings("first", screen.entries()[0].repository);
    try std.testing.expectEqual(1, screen.entries()[0].size);
    try std.testing.expectEqualStrings("beta", screen.entries()[1].id);
    try std.testing.expectEqualStrings("second", screen.entries()[1].repository);
    try std.testing.expectEqualStrings("missing", screen.failed.?.name);
    try std.testing.expectEqual(.not_found, screen.failed.?.failure);
    try std.testing.expect(screen.canReload());
    try std.testing.expectEqual(0, screen.chosen.?);
    // RELOAD reads them again, forgetting the failure until it happens again.
    try std.testing.expectEqual(null, fixture.click(Button.reload.rect().centre()));
    try std.testing.expectEqual(0, screen.reading.?);
    try std.testing.expectEqual(null, screen.failed);
    try std.testing.expect(screen.loaded != null);
}
