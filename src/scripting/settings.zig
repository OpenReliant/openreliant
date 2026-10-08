//! The `openreliant.settings` package ([#597](https://github.com/OpenReliant/openreliant/issues/597)):
//! the options a mod's scripts offer to the player, on a page the mods screen opens
//! (`mod_options`).
//!
//! - A load or menu script declares the mod's page as OpenReliant starts (`register_page`). Both
//!   run before the front end shows anything, so the pages are fixed for the whole run; the driver
//!   closes the registry once they have started (`Registry.close`).
//! - Any script of the mod reads an option (`get`): the value the player set, or the default.
//! - The values are kept in the mod's global storage, in a section of its own (`section_name`),
//!   which only the screen changes. A value that has become one the option doesn't take, such as a
//!   choice a newer version of the mod no longer has, reads as the default. A value that is the
//!   default is not kept.
//! - A change tells the mod's menu scripts, which are the scripts running in the front end
//!   (`on_setting_changed`), by way of the registry's list of changes (`Registry.takeChange`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const mod_options = openreliant.engine.game.interface.mod_options;
const api = @import("api.zig");
const Call = api.Call;
const values = @import("values.zig");
const stored = @import("stored.zig");
const storage_module = @import("storage.zig");
const Storage = storage_module.Storage;

/// The global storage section that keeps the values, which `storage.global_section` refuses.
pub const section_name = "settings";

/// A choice, as scripts give it.
pub const Choice = struct {
    value: mod_options.Value,
    label: []const u8,
};

/// An option, as scripts give it. A toggle needs a boolean default; a choice needs `choices` and a
/// default among their values; a number or a slider needs `min`, `max` and `step` and a default in
/// the range; a text needs a string default; each needs a key. A heading needs only its label.
pub const Option = struct {
    key: []const u8 = "",
    label: []const u8,
    kind: mod_options.Kind,
    default: ?mod_options.Value = null,
    description: []const u8 = "",
    choices: values.List(Choice, mod_options.max_choices) = .{},
    min: ?f64 = null,
    max: ?f64 = null,
    step: ?f64 = null,
};

/// A mod's page, as scripts give it.
pub const Page = struct {
    title: []const u8,
    options: values.List(Option, mod_options.max_options),
};

/// What `openreliant.settings` holds.
pub const package = struct {
    pub const register_page = api.Function("Declares the page of options the mod offers on the mods screen: a title and up to 64 options. Each option has a `key` that scripts read it by, a `label`, a `kind` and a `default`. A `\"toggle\"` has a boolean default. A `\"choice\"` has `choices`, each a `value` and a `label`, and a default among their values. A `\"number\"` has `min`, `max` and `step`, and a default in the range, and arrows step it. A `\"slider\"` is a number with a knob to drag, for a wide range. A `\"text\"` is a line the player types, of up to 24 characters, with a string default. A `\"heading\"` has only a `label`, and splits a long page. An option may have a `description`, which the screen writes under the list while the pointer is on it. Only load and menu scripts can use it, as OpenReliant starts, and a mod has one page.", &.{"page"}, registerPage);
    pub const get = api.Function("The value of the option `key` of the calling mod's page: what the player set, or the default. A toggle is a boolean, a number is a number, and a choice is the value of the choice set.", &.{"key"}, getOption);
    pub const set = api.Function("Sets the option `key` of the calling mod's page to `value`, as the player does on the mods screen: a toggle to a boolean, a number to a number, which is held to its range, a choice to one of its values, and a text to a string of up to 24 characters. The value is kept, and menu scripts hear of the change (`on_setting_changed`).", &.{ "key", "value" }, setOption);
};

fn registerPage(call: Call, given: Page) void {
    const registry = registryOf(call);
    switch (call.context.family) {
        .load, .menu => {},
        .global, .object, .player => call.raise("{t} scripts can't register a page; load and menu scripts can", .{call.context.family}),
    }
    if (registry.closed) call.raise("a page can only be registered as OpenReliant starts", .{});
    const mod = call.context.modOf().name;
    if (registry.find(mod) != null) call.raise("the mod {s} has registered its page already", .{mod});
    if (given.title.len == 0) call.raise("a page needs a title", .{});
    if (given.options.len == 0) call.raise("a page needs options", .{});
    for (given.options.slice(), 0..) |each, at| {
        var buffer: [mod_options.max_choices]mod_options.Choice = undefined;
        const option = view(&each, &buffer) catch |wrong| call.raise("the option '{s}': {s}", .{ each.key, switch (wrong) {
            error.NeedsDefault => "it needs a default",
            error.StrayDefault => "a heading has no default",
            error.NeedsRange => "a number or a slider needs min, max and step",
            error.StrayChoices => "only a choice has choices",
            error.StrayRange => "only a number or a slider has min, max and step",
        } });
        if (option.problem()) |message| call.raise("the option '{s}': {s}", .{ each.key, message });
        if (each.kind == .heading) continue;
        for (given.options.slice()[0..at]) |before| {
            if (before.kind != .heading and std.mem.eql(u8, before.key, each.key)) call.raise("two options are called '{s}'", .{each.key});
        }
    }
    registry.adopt(mod, given) catch call.raise("out of memory", .{});
}

fn getOption(call: Call, key: []const u8) mod_options.Value {
    const registry = registryOf(call);
    const mod = call.context.modOf().name;
    return registry.value(mod, key) orelse call.raise("the mod {s} has no option '{s}'", .{ mod, key });
}

fn setOption(call: Call, key: []const u8, value: mod_options.Value) void {
    const registry = registryOf(call);
    const mod = call.context.modOf().name;
    const each = registry.option(mod, key) orelse call.raise("the mod {s} has no option '{s}'", .{ mod, key });
    // A number option holds a number to its range; any other option takes only a value that suits
    // it as it is.
    const suits = switch (each.control) {
        .number, .slider => value == .number,
        else => each.fit(value).eql(value),
    };
    if (!suits) call.raise("the option '{s}' can't take that value", .{key});
    registry.set(mod, key, value) catch call.raise("out of memory", .{});
}

fn registryOf(call: Call) *Registry {
    return call.runtime().options.shared.settings orelse call.raise("settings aren't kept here", .{});
}

/// What is wrong with the fields an option's kind doesn't use, or doesn't have.
const ViewError = error{ NeedsDefault, StrayDefault, NeedsRange, StrayChoices, StrayRange };

/// What a heading holds in place of a value, which nothing reads.
const heading_value: mod_options.Value = .{ .boolean = false };

/// The option `given` as the screen holds one, borrowing its strings and, for a choice, `buffer`.
fn view(given: *const Option, buffer: *[mod_options.max_choices]mod_options.Choice) ViewError!mod_options.Option {
    if (given.kind != .choice and given.choices.len > 0) return error.StrayChoices;
    const ranged = given.kind == .number or given.kind == .slider;
    if (!ranged and (given.min != null or given.max != null or given.step != null)) return error.StrayRange;
    if (given.kind == .heading and given.default != null) return error.StrayDefault;
    return .{
        .key = given.key,
        .label = given.label,
        .description = given.description,
        .default = if (given.kind == .heading) heading_value else given.default orelse return error.NeedsDefault,
        .control = switch (given.kind) {
            .toggle => .toggle,
            .choice => choice: {
                for (given.choices.slice(), buffer[0..given.choices.len]) |each, *held| held.* = .{ .value = each.value, .label = each.label };
                break :choice .{ .choice = buffer[0..given.choices.len] };
            },
            .number => .{ .number = try rangeOf(given) },
            .slider => .{ .slider = try rangeOf(given) },
            .text => .text,
            .heading => .heading,
        },
    };
}

/// The range of a number or a slider.
fn rangeOf(given: *const Option) ViewError!mod_options.Option.Range {
    return .{
        .min = given.min orelse return error.NeedsRange,
        .max = given.max orelse return error.NeedsRange,
        .step = given.step orelse return error.NeedsRange,
    };
}

/// A page and the mod that registered it.
const Registered = struct {
    mod: []const u8,
    page: mod_options.Page,
};

/// A value changed on the screen, which the mod's menu scripts are told of.
pub const Change = struct {
    mod: []const u8,
    key: []const u8,
    value: mod_options.Value,
};

/// The mods' pages, and what keeps their values. The strings and the pages live as long as the
/// registry does (`arena`).
pub const Registry = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    storage: *Storage,
    registered: std.ArrayList(Registered) = .empty,
    /// The changes made on the screen that scripts haven't been told of, and the copies of their
    /// texts, which last until every change has been taken (`takeChange`).
    changes: std.ArrayList(Change) = .empty,
    told_texts: std.heap.ArenaAllocator,
    /// Whether registering is over.
    closed: bool = false,

    pub fn init(gpa: Allocator, storage: *Storage) Registry {
        return .{ .gpa = gpa, .arena = .init(gpa), .storage = storage, .told_texts = .init(gpa) };
    }

    pub fn deinit(registry: *Registry) void {
        registry.registered.deinit(registry.gpa);
        registry.changes.deinit(registry.gpa);
        registry.told_texts.deinit();
        registry.arena.deinit();
    }

    /// Ends registering, as the scripts that register have started.
    pub fn close(registry: *Registry) void {
        registry.closed = true;
    }

    fn find(registry: *const Registry, mod: []const u8) ?*const Registered {
        for (registry.registered.items) |*held| if (std.mem.eql(u8, held.mod, mod)) return held;
        return null;
    }

    /// Keeps a copy of `given`, which has been checked, as the page of `mod`.
    fn adopt(registry: *Registry, mod: []const u8, given: Page) Allocator.Error!void {
        const memory = registry.arena.allocator();
        try registry.registered.ensureUnusedCapacity(registry.gpa, 1);
        const options = try memory.alloc(mod_options.Option, given.options.len);
        for (given.options.slice(), options) |each, *held| {
            var buffer: [mod_options.max_choices]mod_options.Choice = undefined;
            const shown = view(&each, &buffer) catch unreachable;
            held.* = .{
                .key = try memory.dupe(u8, shown.key),
                .label = try memory.dupe(u8, shown.label),
                .description = try memory.dupe(u8, shown.description),
                .default = try ownValue(memory, shown.default),
                .control = switch (shown.control) {
                    .toggle => .toggle,
                    .text => .text,
                    .heading => .heading,
                    .number => |range| .{ .number = range },
                    .slider => |range| .{ .slider = range },
                    .choice => |choices| choice: {
                        const kept = try memory.alloc(mod_options.Choice, choices.len);
                        for (choices, kept) |choice, *copy| copy.* = .{ .value = try ownValue(memory, choice.value), .label = try memory.dupe(u8, choice.label) };
                        break :choice .{ .choice = kept };
                    },
                },
            };
        }
        registry.registered.appendAssumeCapacity(.{
            .mod = try memory.dupe(u8, mod),
            .page = .{ .title = try memory.dupe(u8, given.title), .options = options },
        });
    }

    /// The page of `mod`; null where it has none.
    pub fn page(registry: *const Registry, mod: []const u8) ?mod_options.Page {
        return (registry.find(mod) orelse return null).page;
    }

    /// The option `key` of `mod`'s page, which is never a heading.
    fn option(registry: *const Registry, mod: []const u8, key: []const u8) ?mod_options.Option {
        const held = registry.find(mod) orelse return null;
        for (held.page.options) |each| if (each.control != .heading and std.mem.eql(u8, each.key, key)) return each;
        return null;
    }

    /// The value of the option `key` of `mod`: the one kept if it suits the option, else the
    /// default. Null for a key the mod's page doesn't have.
    pub fn value(registry: *const Registry, mod: []const u8, key: []const u8) ?mod_options.Value {
        const each = registry.option(mod, key) orelse return null;
        const kept = registry.storage.read(mod, section_name, .global, key) orelse return each.default;
        const asked: mod_options.Value = switch (kept) {
            .boolean => |on| .{ .boolean = on },
            .number => |number| .{ .number = number },
            .string => |text| .{ .text = text },
            .nil, .vector, .handle, .table => return each.default,
        };
        return each.fit(asked);
    }

    /// Keeps `value` as the option's, if it suits the option, and notes the change for the scripts.
    /// A value that is the default takes the key out of the storage.
    pub fn set(registry: *Registry, mod: []const u8, key: []const u8, asked: mod_options.Value) Allocator.Error!void {
        const each = registry.option(mod, key) orelse return;
        const fitted = each.fit(asked);
        const gpa = registry.storage.gpa;
        const kept: stored.Value = if (fitted.eql(each.default)) .nil else switch (fitted) {
            .boolean => |on| .{ .boolean = on },
            .number => |number| .{ .number = number },
            .text => |text| .{ .string = try gpa.dupe(u8, text) },
        };
        errdefer kept.deinit(gpa);
        const told: mod_options.Value = switch (fitted) {
            .boolean, .number => fitted,
            .text => |text| .{ .text = try registry.told_texts.allocator().dupe(u8, text) },
        };
        try registry.changes.append(registry.gpa, .{ .mod = registry.find(mod).?.mod, .key = each.key, .value = told });
        try registry.storage.put(mod, section_name, .global, key, kept);
    }

    /// The oldest change not yet told to scripts; none once all are, which lets their texts go.
    pub fn takeChange(registry: *Registry) ?Change {
        if (registry.changes.items.len == 0) {
            _ = registry.told_texts.reset(.retain_capacity);
            return null;
        }
        return registry.changes.orderedRemove(0);
    }

    /// The pages and values as the mods screen reaches them.
    pub fn pages(registry: *Registry) mod_options.Pages {
        return .{ .context = registry, .vtable = &.{ .page = pageOf, .get = getOf, .set = setOf } };
    }

    fn from(context: *anyopaque) *Registry {
        return @ptrCast(@alignCast(context));
    }

    fn pageOf(context: *anyopaque, mod: []const u8) ?mod_options.Page {
        return from(context).page(mod);
    }

    fn getOf(context: *anyopaque, mod: []const u8, key: []const u8) ?mod_options.Value {
        return from(context).value(mod, key);
    }

    fn setOf(context: *anyopaque, mod: []const u8, key: []const u8, asked: mod_options.Value) void {
        from(context).set(mod, key, asked) catch |err| std.log.warn("{s}: the option {s} is not kept: {s}", .{ mod, key, @errorName(err) });
    }
};

/// `value`, with its text copied into `memory`.
fn ownValue(memory: Allocator, held: mod_options.Value) Allocator.Error!mod_options.Value {
    return switch (held) {
        .boolean, .number => held,
        .text => |text| .{ .text = try memory.dupe(u8, text) },
    };
}

/// A mod `a` whose load script is `source`, run with a registry over a storage.
fn runMod(source: []const u8, registry: *Registry) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const load = @import("load.zig");
    const mods = openreliant.engine.game.bigfile.mods;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try load.testing.makeMods(io, tmp.dir, &.{.{ "a", &.{ .{ "mod.ini", "[Scripts]\nLoad=options.luau\n" }, .{ "options.luau", source } } }});
    var opened: mods.Mods = try .open(gpa, io, tmp.dir, null);
    defer opened.close(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var held = try load.testing.records3(arena.allocator());
    try load.run(gpa, io, opened.list, &held, "0.7.0", .{ .storage = registry.storage, .settings = registry });
}

const wingmen_page =
    \\local settings = require("openreliant.settings")
    \\settings.register_page({
    \\    title = "Wingmen",
    \\    options = {
    \\        { key = "show", label = "SHOW PANEL", kind = "toggle", default = true, description = "Shows the panel." },
    \\        { key = "flee", label = "FLEE AT", kind = "choice", default = 0.35,
    \\          choices = { { value = 0.2, label = "20%" }, { value = 0.35, label = "35%" } } },
    \\        { key = "regroup", label = "REGROUP AFTER", kind = "number", min = 5, max = 60, step = 5, default = 20 },
    \\        { key = "reach", label = "RADAR REACH", kind = "slider", min = 1000, max = 50000, step = 500, default = 8000 },
    \\        { key = "callsign", label = "CALL SIGN", kind = "text", default = "Viper" },
    \\    },
    \\})
    \\assert(settings.get("show") == true and settings.get("flee") == 0.35 and settings.get("regroup") == 20)
    \\assert(settings.get("reach") == 8000 and settings.get("callsign") == "Viper")
    \\assert(not pcall(settings.get, "missing"))
    \\assert(not pcall(function() require("openreliant.storage").global_section("settings") end))
;

test "a load script declares a page, and every script reads the values" {
    var storage: Storage = .{ .gpa = std.testing.allocator };
    defer storage.deinit();
    var registry: Registry = .init(std.testing.allocator, &storage);
    defer registry.deinit();
    try runMod(wingmen_page, &registry);
    const page = registry.page("a").?;
    try std.testing.expectEqualStrings("Wingmen", page.title);
    try std.testing.expectEqual(5, page.options.len);
    try std.testing.expectEqualStrings("Shows the panel.", page.options[0].description);
    try std.testing.expectEqual(mod_options.Option.Range{ .min = 1000, .max = 50000, .step = 500 }, page.options[3].control.slider);
    try std.testing.expectEqual(null, registry.page("b"));
    // A value set on the screen is kept in the storage, and read back; one that is the default isn't
    // kept. A value that doesn't suit the option reads as the default.
    try registry.set("a", "regroup", .{ .number = 30 });
    try std.testing.expectEqual(mod_options.Value{ .number = 30 }, registry.value("a", "regroup").?);
    try std.testing.expectEqual(30, storage.read("a", section_name, .global, "regroup").?.number);
    try registry.set("a", "regroup", .{ .number = 20 });
    try std.testing.expectEqual(null, storage.read("a", section_name, .global, "regroup"));
    try registry.set("a", "flee", .{ .number = 0.2 });
    try std.testing.expectEqual(mod_options.Value{ .number = 0.2 }, registry.value("a", "flee").?);
    try storage.put("a", section_name, .global, "flee", .{ .number = 0.9 });
    try std.testing.expectEqual(mod_options.Value{ .number = 0.35 }, registry.value("a", "flee").?);
    try registry.set("a", "regroup", .{ .number = 1000 });
    try std.testing.expectEqual(mod_options.Value{ .number = 60 }, registry.value("a", "regroup").?);
    try std.testing.expectEqual(null, registry.value("a", "missing"));
    // A text is kept as a copy, too long a one reads as the default, and the change told keeps its
    // own copy, whatever the storage's becomes.
    var line = "Maverick".*;
    try registry.set("a", "callsign", .{ .text = &line });
    line[0] = 'X';
    try std.testing.expectEqualStrings("Maverick", registry.value("a", "callsign").?.text);
    try registry.set("a", "callsign", .{ .text = &@as([mod_options.text_room + 1]u8, @splat('a')) });
    try std.testing.expectEqualStrings("Viper", registry.value("a", "callsign").?.text);
    // The changes wait, in order, for the scripts to be told.
    var changes: usize = 0;
    while (registry.takeChange()) |change| : (changes += 1) {
        if (changes == 0) {
            try std.testing.expectEqualStrings("a", change.mod);
            try std.testing.expectEqualStrings("regroup", change.key);
            try std.testing.expectEqual(mod_options.Value{ .number = 30 }, change.value);
        }
        if (changes == 4) try std.testing.expectEqualStrings("Maverick", change.value.text);
    }
    try std.testing.expectEqual(6, changes);
}

test "a script sets its mod's own options" {
    var storage: Storage = .{ .gpa = std.testing.allocator };
    defer storage.deinit();
    var registry: Registry = .init(std.testing.allocator, &storage);
    defer registry.deinit();
    try runMod(wingmen_page ++
        \\
        \\settings.set("show", false)
        \\settings.set("regroup", 1000)
        \\settings.set("flee", 0.2)
        \\assert(settings.get("show") == false and settings.get("regroup") == 60 and settings.get("flee") == 0.2)
        \\assert(not pcall(settings.set, "flee", 0.5))
        \\assert(not pcall(settings.set, "show", 3))
        \\assert(not pcall(settings.set, "callsign", string.rep("a", 25)))
        \\assert(not pcall(settings.set, "missing", 1))
    , &registry);
    // The values are kept as the screen keeps them, and the changes wait to be told.
    try std.testing.expectEqual(false, storage.read("a", section_name, .global, "show").?.boolean);
    try std.testing.expectEqual(mod_options.Value{ .number = 60 }, registry.value("a", "regroup").?);
    var changes: usize = 0;
    while (registry.takeChange()) |_| changes += 1;
    try std.testing.expectEqual(3, changes);
}

test "a page that is wrong is refused, and a mod has one page" {
    var storage: Storage = .{ .gpa = std.testing.allocator };
    defer storage.deinit();
    var registry: Registry = .init(std.testing.allocator, &storage);
    defer registry.deinit();
    try runMod(
        \\local settings = require("openreliant.settings")
        \\local function refused(page, text)
        \\    local ok, message = pcall(settings.register_page, page)
        \\    assert(not ok and string.find(message, text, 1, true), message)
        \\end
        \\local function option(fields) fields.key = fields.key or "k"; fields.label = "L"; return { title = "T", options = { fields } } end
        \\refused({ title = "T", options = {} }, "needs options")
        \\refused(option({ kind = "toggle", default = 1 }), "a toggle's default must be a boolean")
        \\refused(option({ kind = "choice", default = 1 }), "needs choices")
        \\refused(option({ kind = "choice", default = 3, choices = { { value = 1, label = "ONE" } } }), "must be one of its values")
        \\refused(option({ kind = "number", default = 1 }), "needs min, max and step")
        \\refused(option({ kind = "number", default = 1, min = 0, max = 5 }), "needs min, max and step")
        \\refused(option({ kind = "number", default = 9, min = 0, max = 5, step = 1 }), "within its range")
        \\refused(option({ kind = "toggle", default = true, choices = { { value = 1, label = "ONE" } } }), "only a choice has choices")
        \\refused(option({ kind = "toggle", default = true, min = 1 }), "only a number or a slider has min, max and step")
        \\refused(option({ kind = "slider", default = 1 }), "needs min, max and step")
        \\refused(option({ kind = "wide", default = true }), "'toggle', 'choice', 'number', 'slider', 'text' or 'heading'")
        \\refused({ title = "T", options = { { key = "k", label = "L", kind = "toggle" } } }, "it needs a default")
        \\refused(option({ kind = "heading", default = true }), "a heading has no default")
        \\refused({ title = "T", options = { { key = "k", label = "L", kind = "toggle", default = true }, { key = "k", label = "M", kind = "toggle", default = false } } }, "two options are called 'k'")
        \\settings.register_page(option({ kind = "toggle", default = true }))
        \\refused(option({ kind = "toggle", default = true }), "already")
    , &registry);
    try std.testing.expectEqual(1, registry.page("a").?.options.len);
}

test "a heading splits a page, and scripts can't read it" {
    var storage: Storage = .{ .gpa = std.testing.allocator };
    defer storage.deinit();
    var registry: Registry = .init(std.testing.allocator, &storage);
    defer registry.deinit();
    try runMod(
        \\local settings = require("openreliant.settings")
        \\settings.register_page({ title = "T", options = {
        \\    { label = "COMBAT", kind = "heading" },
        \\    { key = "show", label = "SHOW", kind = "toggle", default = true },
        \\    { label = "TRAVEL", kind = "heading" },
        \\} })
        \\assert(settings.get("show") == true)
        \\assert(not pcall(settings.get, ""))
    , &registry);
    const page = registry.page("a").?;
    try std.testing.expectEqual(mod_options.Option.Control.heading, page.options[0].control);
    try std.testing.expectEqualStrings("TRAVEL", page.options[2].label);
    try std.testing.expectEqual(null, registry.value("a", ""));
}

test "a page can only be registered as OpenReliant starts" {
    var storage: Storage = .{ .gpa = std.testing.allocator };
    defer storage.deinit();
    var registry: Registry = .init(std.testing.allocator, &storage);
    defer registry.deinit();
    registry.close();
    try runMod(
        \\local settings = require("openreliant.settings")
        \\local ok, message = pcall(settings.register_page, { title = "T", options = { { key = "k", label = "L", kind = "toggle", default = true } } })
        \\assert(not ok and string.find(message, "as OpenReliant starts", 1, true), message)
    , &registry);
    try std.testing.expectEqual(null, registry.page("a"));
}
