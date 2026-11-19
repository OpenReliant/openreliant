//! Chat through the original flight COMMS window. The roster comes from the host.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const wire = @import("wire.zig");
const Client = @import("client.zig");
const FlightChat = @This();

target: ?@FieldType(wire.ChatRequest, "to") = null,
line: game.chat.Line = .{},
listed: [wire.slots]?wire.Admission = @splat(null),

/// `chat_line_open` (0x004547A0) clears queued keys. `chat_line_frame` (0x004547C0)
/// sends on Enter and closes COMMS. Escape cancels locally.
pub fn frame(chat: *FlightChat, client: *Client, drawn: *game.main.Drawn, devices: *engine.input.Devices, typed: *game.winmain.Typed, font: *const game.hud.Opened, active: bool) bool {
    const windows = &drawn.display.windows;
    const keys = &devices.keyboard;
    if (!active) {
        if (chat.target != null) typed.clear();
        return chat.target != null;
    }
    if (chat.target) |to| {
        game.chat.edit(&chat.line, typed, .{ .font = font, .max_width = game.chat.flight_width });
        const cancel = keys.pressed(engine.input.scan.escape, .none, true);
        const submit = game.chat.submitted(keys);
        if (cancel or submit) {
            if (!cancel) client.sendChat(.{ .to = to, .text = chat.line });
            chat.line.len = 0;
            chat.target = null;
            windows.close(.comms);
        }
        return true;
    }

    const menu = &drawn.player.menu;
    if (devices.active(.comms_window, true)) {
        if (windows.up(.comms)) {
            windows.close(.comms);
            return false;
        }
        if (!windows.open(.comms, true)) return false;
        windows.status.getPtr(.comms).held = true;
        menu.* = .{};
        menu.add(.{ .network = .{ .label = .{ .id = 0x16D, .english = "Multiplayer" } } }, .multiplayer, -1);
    }
    if (!windows.up(.comms)) return false;
    if (keys.pressed(engine.input.scan.escape, .none, true)) {
        windows.close(.comms);
        return true;
    }
    if (!menu.choose(keys)) return false;
    windows.beeps.add(.done);
    switch (menu.page) {
        .multiplayer => chat.showPilots(menu, client),
        .player => {
            menu.count = 0;
            menu.add(.{ .network = .{ .label = .{ .id = 0x176, .english = "Type message" } } }, if (menu.addressed < 0) .message_all else .message, menu.addressed);
        },
        .message, .message_all => {
            chat.target = if (menu.page == .message_all) .flight else target: {
                const pilot = chat.listed[@intCast(menu.addressed)] orelse break :target null;
                break :target .{ .private = pilot };
            };
            typed.clear();
            return true;
        },
        else => unreachable,
    }
    return false;
}

/// The player list from `comms_menu_run`'s multiplayer page at 0x004545D0.
fn showPilots(chat: *FlightChat, menu: *game.radio.menu.Menu, client: *const Client) void {
    menu.count = 0;
    chat.listed = @splat(null);
    for (client.roster.pilots, 0..) |entry, slot| {
        const pilot = entry orelse continue;
        if (slot == client.joined.?.slot) continue;
        chat.listed[slot] = .{ .slot = @intCast(slot), .generation = pilot.generation };
        const label: game.radio.menu.Label = if (pilot.name.len != 0)
            .{ .network = .{ .callsign = pilot.name } }
        else
            .{ .network = .{ .label = .{ .id = 0xBF, .english = "Pilot" } } };
        menu.add(label, .player, @intCast(slot));
    }
    menu.add(.{ .network = .{ .label = .{ .id = 0x16E, .english = "All players" } } }, .player, -1);
}

test "the flight menu addresses the admission shown when the pilot was listed" {
    var chat: FlightChat = .{};
    var menu: game.radio.menu.Menu = .{};
    var client: Client = .{ .expected_host = null, .joined = .{ .slot = 0, .generation = 1 } };
    client.roster.pilots = .{ .{ .generation = 1 }, .{ .generation = 4, .name = wire.lobbyName("Rook") }, null };
    chat.showPilots(&menu, &client);
    try std.testing.expectEqual(2, menu.count);
    try std.testing.expectEqual(1, menu.shown()[0].addressed);
    try std.testing.expectEqual(-1, menu.shown()[1].addressed);
    client.roster.pilots[1].?.generation = 5;
    try std.testing.expectEqual(4, chat.listed[1].?.generation);
}
