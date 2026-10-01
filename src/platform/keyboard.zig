//! The keyboard, as DirectInput gave it to the game: SDL's scan codes, which follow the USB HID
//! usages, turned into DirectInput's (`DIK_*`, `engine.input.Key`), which follow the IBM PC's set 1
//! with the extended keys from `0x80` up. Both name a key by its place on the keyboard, not what it
//! types; the keys' names are what they type in the keyboard's layout (`nameKeys`), as Windows
//! names them for the game.

const std = @import("std");
const c = @import("sdl");
const input = @import("openreliant").engine.input;
pub const Key = input.Key;

/// The DirectInput key SDL names `scancode`, or null for a key DirectInput has no code for.
pub fn directInput(scancode: u32) ?Key {
    if (scancode >= table.len) return null;
    return table[scancode];
}

/// Names every key as the keyboard's layout names it, as `WinMain` renames the keys by
/// `GetKeyNameTextA` as it starts (`key_names_rename`): SDL's name for what the key gives in the
/// layout (`SDL_GetKeyFromScancode`, `SDL_GetKeyName`), the character it types, in capitals, for a
/// key that types one, and else the key's own name; none for a key SDL has no code or no name for.
pub fn nameKeys(names: *input.KeyNames) void {
    for (scancodes, 0..) |held, code| {
        const scancode = held orelse {
            names.set(@intCast(code), "");
            continue;
        };
        const key = c.SDL_GetKeyFromScancode(scancode, c.SDL_KMOD_NONE, false);
        names.set(@intCast(code), std.mem.span(c.SDL_GetKeyName(key)));
    }
}

/// SDL's scan codes and the DirectInput keys they are.
const pairs = [_]struct { u32, Key }{
    .{ c.SDL_SCANCODE_ESCAPE, .escape },
    .{ c.SDL_SCANCODE_1, .one },
    .{ c.SDL_SCANCODE_2, .two },
    .{ c.SDL_SCANCODE_3, .three },
    .{ c.SDL_SCANCODE_4, .four },
    .{ c.SDL_SCANCODE_5, .five },
    .{ c.SDL_SCANCODE_6, .six },
    .{ c.SDL_SCANCODE_7, .seven },
    .{ c.SDL_SCANCODE_8, .eight },
    .{ c.SDL_SCANCODE_9, .nine },
    .{ c.SDL_SCANCODE_0, .zero },
    .{ c.SDL_SCANCODE_MINUS, .minus },
    .{ c.SDL_SCANCODE_EQUALS, .equals },
    .{ c.SDL_SCANCODE_BACKSPACE, .backspace },
    .{ c.SDL_SCANCODE_TAB, .tab },
    .{ c.SDL_SCANCODE_Q, .q },
    .{ c.SDL_SCANCODE_W, .w },
    .{ c.SDL_SCANCODE_E, .e },
    .{ c.SDL_SCANCODE_R, .r },
    .{ c.SDL_SCANCODE_T, .t },
    .{ c.SDL_SCANCODE_Y, .y },
    .{ c.SDL_SCANCODE_U, .u },
    .{ c.SDL_SCANCODE_I, .i },
    .{ c.SDL_SCANCODE_O, .o },
    .{ c.SDL_SCANCODE_P, .p },
    .{ c.SDL_SCANCODE_LEFTBRACKET, .left_bracket },
    .{ c.SDL_SCANCODE_RIGHTBRACKET, .right_bracket },
    .{ c.SDL_SCANCODE_RETURN, .enter },
    .{ c.SDL_SCANCODE_LCTRL, .left_control },
    .{ c.SDL_SCANCODE_A, .a },
    .{ c.SDL_SCANCODE_S, .s },
    .{ c.SDL_SCANCODE_D, .d },
    .{ c.SDL_SCANCODE_F, .f },
    .{ c.SDL_SCANCODE_G, .g },
    .{ c.SDL_SCANCODE_H, .h },
    .{ c.SDL_SCANCODE_J, .j },
    .{ c.SDL_SCANCODE_K, .k },
    .{ c.SDL_SCANCODE_L, .l },
    .{ c.SDL_SCANCODE_SEMICOLON, .semicolon },
    .{ c.SDL_SCANCODE_APOSTROPHE, .apostrophe },
    .{ c.SDL_SCANCODE_GRAVE, .grave },
    .{ c.SDL_SCANCODE_LSHIFT, .left_shift },
    .{ c.SDL_SCANCODE_BACKSLASH, .backslash },
    .{ c.SDL_SCANCODE_NONUSHASH, .backslash },
    .{ c.SDL_SCANCODE_Z, .z },
    .{ c.SDL_SCANCODE_X, .x },
    .{ c.SDL_SCANCODE_C, .c },
    .{ c.SDL_SCANCODE_V, .v },
    .{ c.SDL_SCANCODE_B, .b },
    .{ c.SDL_SCANCODE_N, .n },
    .{ c.SDL_SCANCODE_M, .m },
    .{ c.SDL_SCANCODE_COMMA, .comma },
    .{ c.SDL_SCANCODE_PERIOD, .period },
    .{ c.SDL_SCANCODE_SLASH, .slash },
    .{ c.SDL_SCANCODE_RSHIFT, .right_shift },
    .{ c.SDL_SCANCODE_KP_MULTIPLY, .keypad_multiply },
    .{ c.SDL_SCANCODE_LALT, .left_alt },
    .{ c.SDL_SCANCODE_SPACE, .space },
    .{ c.SDL_SCANCODE_CAPSLOCK, .caps_lock },
    .{ c.SDL_SCANCODE_F1, .f1 },
    .{ c.SDL_SCANCODE_F2, .f2 },
    .{ c.SDL_SCANCODE_F3, .f3 },
    .{ c.SDL_SCANCODE_F4, .f4 },
    .{ c.SDL_SCANCODE_F5, .f5 },
    .{ c.SDL_SCANCODE_F6, .f6 },
    .{ c.SDL_SCANCODE_F7, .f7 },
    .{ c.SDL_SCANCODE_F8, .f8 },
    .{ c.SDL_SCANCODE_F9, .f9 },
    .{ c.SDL_SCANCODE_F10, .f10 },
    .{ c.SDL_SCANCODE_NUMLOCKCLEAR, .num_lock },
    .{ c.SDL_SCANCODE_SCROLLLOCK, .scroll_lock },
    .{ c.SDL_SCANCODE_KP_7, .keypad_7 },
    .{ c.SDL_SCANCODE_KP_8, .keypad_8 },
    .{ c.SDL_SCANCODE_KP_9, .keypad_9 },
    .{ c.SDL_SCANCODE_KP_MINUS, .keypad_minus },
    .{ c.SDL_SCANCODE_KP_4, .keypad_4 },
    .{ c.SDL_SCANCODE_KP_5, .keypad_5 },
    .{ c.SDL_SCANCODE_KP_6, .keypad_6 },
    .{ c.SDL_SCANCODE_KP_PLUS, .keypad_plus },
    .{ c.SDL_SCANCODE_KP_1, .keypad_1 },
    .{ c.SDL_SCANCODE_KP_2, .keypad_2 },
    .{ c.SDL_SCANCODE_KP_3, .keypad_3 },
    .{ c.SDL_SCANCODE_KP_0, .keypad_0 },
    .{ c.SDL_SCANCODE_KP_PERIOD, .keypad_period },
    .{ c.SDL_SCANCODE_NONUSBACKSLASH, .non_us_backslash },
    .{ c.SDL_SCANCODE_F11, .f11 },
    .{ c.SDL_SCANCODE_F12, .f12 },
    .{ c.SDL_SCANCODE_KP_ENTER, .keypad_enter },
    .{ c.SDL_SCANCODE_RCTRL, .right_control },
    .{ c.SDL_SCANCODE_KP_DIVIDE, .keypad_divide },
    .{ c.SDL_SCANCODE_PRINTSCREEN, .print_screen },
    .{ c.SDL_SCANCODE_RALT, .right_alt },
    .{ c.SDL_SCANCODE_PAUSE, .pause },
    .{ c.SDL_SCANCODE_HOME, .home },
    .{ c.SDL_SCANCODE_UP, .up },
    .{ c.SDL_SCANCODE_PAGEUP, .page_up },
    .{ c.SDL_SCANCODE_LEFT, .left },
    .{ c.SDL_SCANCODE_RIGHT, .right },
    .{ c.SDL_SCANCODE_END, .end },
    .{ c.SDL_SCANCODE_DOWN, .down },
    .{ c.SDL_SCANCODE_PAGEDOWN, .page_down },
    .{ c.SDL_SCANCODE_INSERT, .insert },
    .{ c.SDL_SCANCODE_DELETE, .delete },
    .{ c.SDL_SCANCODE_LGUI, .left_windows },
    .{ c.SDL_SCANCODE_RGUI, .right_windows },
    .{ c.SDL_SCANCODE_APPLICATION, .menu },
};

const table = table: {
    var keys: [c.SDL_SCANCODE_COUNT]?Key = @splat(null);
    for (pairs) |pair| keys[pair[0]] = pair[1];
    break :table keys;
};

/// The SDL scan code of each DirectInput key, the first of `pairs` for a key SDL gives two.
const scancodes = scancodes: {
    var codes: [256]?u32 = @splat(null);
    for (pairs) |pair| {
        const code = @intFromEnum(pair[1]);
        if (codes[code] == null) codes[code] = pair[0];
    }
    break :scancodes codes;
};

test directInput {
    try std.testing.expectEqual(Key.one, directInput(c.SDL_SCANCODE_1).?);
    try std.testing.expectEqual(0x02, @intFromEnum(directInput(c.SDL_SCANCODE_1).?));
    try std.testing.expectEqual(0xCB, @intFromEnum(directInput(c.SDL_SCANCODE_LEFT).?));
    try std.testing.expectEqual(Key.right_shift, directInput(c.SDL_SCANCODE_RSHIFT).?);
    try std.testing.expectEqual(null, directInput(c.SDL_SCANCODE_F13));
    try std.testing.expectEqual(null, directInput(100_000));
}

test nameKeys {
    // SDL's own layout while no keyboard's is known: US, its letters in capitals.
    var names: input.KeyNames = .{};
    nameKeys(&names);
    try std.testing.expectEqualStrings("Q", names.of(@intFromEnum(Key.q)));
    try std.testing.expectEqualStrings("1", names.of(@intFromEnum(Key.one)));
    // A key SDL has no code for.
    try std.testing.expectEqualStrings(input.KeyNames.unknown, names.of(0));
}
