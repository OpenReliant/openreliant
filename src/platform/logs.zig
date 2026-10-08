//! The C libraries' own messages, sent to OpenReliant's log so that the log file holds them too
//! ([#799](https://github.com/OpenReliant/openreliant/issues/799)): SDL's, OpenAL Soft's and
//! FFmpeg's, each under a scope of its own. `route` sets them up, once, before any of the libraries
//! starts.

const std = @import("std");
const sdl = @import("sdl");
const av = @import("av");

const log_sdl = std.log.scoped(.sdl);
const log_openal = std.log.scoped(.openal);
const log_ffmpeg = std.log.scoped(.ffmpeg);

/// Sends SDL's, OpenAL Soft's and FFmpeg's messages to the log. FFmpeg's below its warnings are
/// left out.
pub fn route() void {
    sdl.SDL_SetLogOutputFunction(fromSdl, null);
    alsoft_set_log_callback(fromOpenal, null);
    av.av_log_set_level(av.AV_LOG_WARNING);
    av.av_log_set_callback(fromFfmpeg);
}

/// SDL's output function, in place of its own, which writes to the terminal.
fn fromSdl(_: ?*anyopaque, _: c_int, priority: sdl.SDL_LogPriority, message: [*c]const u8) callconv(.c) void {
    const text = std.mem.span(message);
    switch (priority) {
        sdl.SDL_LOG_PRIORITY_ERROR, sdl.SDL_LOG_PRIORITY_CRITICAL => log_sdl.err("{s}", .{text}),
        sdl.SDL_LOG_PRIORITY_WARN => log_sdl.warn("{s}", .{text}),
        sdl.SDL_LOG_PRIORITY_INFO => log_sdl.info("{s}", .{text}),
        else => log_sdl.debug("{s}", .{text}),
    }
}

/// OpenAL Soft's log callback, which it declares only among its extensions in progress
/// (`alc/inprogext.h`). It still writes its errors to the terminal itself as well.
extern fn alsoft_set_log_callback(callback: ?*const fn (?*anyopaque, u8, [*]const u8, c_int) callconv(.c) void, user: ?*anyopaque) callconv(.c) void;

/// What OpenAL Soft says, at its level: `E` an error, `W` a warning and `I` what it traces.
fn fromOpenal(_: ?*anyopaque, level: u8, message: [*]const u8, length: c_int) callconv(.c) void {
    const text = message[0..@intCast(@max(length, 0))];
    switch (level) {
        'E' => log_openal.err("{s}", .{text}),
        'W' => log_openal.warn("{s}", .{text}),
        else => log_openal.debug("{s}", .{text}),
    }
}

/// The type of FFmpeg's argument list, as its headers are translated on the target.
const Arguments = arguments: {
    const Callback = @typeInfo(@TypeOf(av.av_log_set_callback)).@"fn".param_types[0].?;
    const Function = @typeInfo(@typeInfo(Callback).optional.child).pointer.child;
    break :arguments @typeInfo(Function).@"fn".param_types[3].?;
};

/// The most of a line of FFmpeg's kept.
const line_room = 1024;

/// FFmpeg's log callback: a warning or an error, formatted as its own callback formats it, with
/// what it concerns before it.
fn fromFfmpeg(context: ?*anyopaque, level: c_int, format: [*c]const u8, arguments: Arguments) callconv(.c) void {
    if (level > av.AV_LOG_WARNING) return;
    var line: [line_room]u8 = undefined;
    var prefix: c_int = 1;
    const length = av.av_log_format_line2(context, level, format, arguments, &line, line.len, &prefix);
    if (length <= 0) return;
    const text = std.mem.trimEnd(u8, line[0..@min(@as(usize, @intCast(length)), line.len - 1)], "\n");
    if (level <= av.AV_LOG_ERROR) log_ffmpeg.err("{s}", .{text}) else log_ffmpeg.warn("{s}", .{text});
}
