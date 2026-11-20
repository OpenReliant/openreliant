//! Check for a newer game release without holding up a dedicated server.
const std = @import("std");
const web = @import("openreliant").engine.web;
const updates = @import("../updates.zig");
const version = @import("version");
const log = std.log.scoped(.updates);

const Job = struct {
    pub fn run(_: *Job, io: std.Io, progress: *web.Progress) !updates.Version {
        return updates.latest(io, progress);
    }
};

const Check = @This();
download: web.Download(Job) = .{},
next: i64 = 0,

pub fn tick(check: *Check, now: i64) void {
    if (check.download.take()) |answer| {
        if (answer) |release| {
            if (release.newer(version.semantic)) {
                var page: [updates.page_url.len + @import("openreliant").engine.game.interface.main_menu.max_version + 1]u8 = undefined;
                log.warn("OpenReliant {s} is available (running {s}). {s}", .{ release.slice(), version.string, release.page(&page) });
            }
        } else |err| log.debug("could not check for updates: {t}", .{err});
    }
    if (now < check.next or check.download.busy()) return;
    check.next = now + 6 * std.time.us_per_hour;
    check.download.start(.{}, .{ .whole = updates.time_limit }) catch |err|
        log.debug("could not start the update check: {t}", .{err});
}

pub fn close(check: *Check) void {
    check.download.abandon();
}
