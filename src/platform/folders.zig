//! The folder OpenReliant keeps each user's own files in, where the game keeps them in its own
//! folder: SDL's folder for the user's files of an application (`SDL_GetPrefPath`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("sdl");
const sdl = @import("sdl.zig");

/// The name SDL makes the folder from. OpenReliant gives no organisation, which SDL would put a
/// folder above it for, so that the folder is `OpenReliant` alone on every system.
const application = "OpenReliant";

/// The user's folder, with a separator at its end, which SDL makes where it is missing: in
/// `~/Library/Application Support` on macOS, `%APPDATA%` on Windows, and `$XDG_DATA_HOME` or
/// `~/.local/share` elsewhere.
pub fn user(gpa: Allocator) (sdl.Error || Allocator.Error)![]u8 {
    const path = c.SDL_GetPrefPath("", application) orelse return sdl.fail("SDL_GetPrefPath");
    defer c.SDL_free(path);
    return gpa.dupe(u8, std.mem.span(path));
}
