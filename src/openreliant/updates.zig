//! OpenReliant's check for a newer release of itself
//! ([#1062](https://github.com/OpenReliant/openreliant/issues/1062)). As OpenReliant starts, a
//! thread of its own asks GitHub's API for the latest release, and gives up after `time_limit`.
//! The game never waits for the thread: each frame it only looks at whether the thread has
//! answered, and as it quits it leaves the thread behind. A slow or missing connection never holds
//! up the game, not even a lookup of GitHub's address, which the system's resolver does in a call
//! nothing can interrupt. A release newer than the one playing is logged, and the main menu shows
//! it once (`game.interface.main_menu.Release`): YES opens the release's page in the web browser,
//! and `[OpenReliant] UpdateSeen` keeps the newest release the main menu has shown.
//!
//! **Improvement:** the original never looks for a newer version of itself.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const engine = openreliant.engine;
const main_menu = engine.game.interface.main_menu;
const settings = @import("settings.zig");
const version = @import("version");

const log = std.log.scoped(.updates);

/// Where GitHub's API gives the latest release, which is neither a draft nor a pre-release.
pub const latest_url = "https://api.github.com/repos/OpenReliant/openreliant/releases/latest";

/// A release's page, before its version: its tag is the version after a `v`.
pub const page_url = "https://github.com/OpenReliant/openreliant/releases/tag/v";

/// The room a release's page takes (`Version.page`).
const PageBuffer = [page_url.len + main_menu.max_version + 1]u8;

/// What the request says it comes from, which GitHub's API asks of every request.
const user_agent = "OpenReliant";

/// How long the thread waits for GitHub at most, before it gives up.
pub const time_limit: Io.Duration = .fromSeconds(5);

/// How much of GitHub's answer is read at most. A release's description, with its notes and its
/// files, is far smaller.
const max_answer = 1 << 20;

/// The key in `[OpenReliant]` that keeps the newest release the main menu has shown.
pub const seen_key = "UpdateSeen";

/// A release's version, as its tag names it after the `v`.
pub const Version = struct {
    text: [main_menu.max_version]u8 = undefined,
    len: u8 = 0,

    /// The version the tag `tag` names: `v`, then a semantic version without build metadata, of
    /// at most `main_menu.max_version` characters of letters, digits, dots and hyphens. Null for
    /// another tag. Its characters keep a release's page well formed (`page`).
    pub fn ofTag(tag: []const u8) ?Version {
        const named = std.mem.cutPrefix(u8, tag, "v") orelse return null;
        if (named.len > main_menu.max_version) return null;
        for (named) |character| if (!std.ascii.isAlphanumeric(character) and character != '.' and character != '-') return null;
        _ = std.SemanticVersion.parse(named) catch return null;
        var found: Version = .{ .len = @intCast(named.len) };
        @memcpy(found.text[0..named.len], named);
        return found;
    }

    pub fn slice(found: *const Version) []const u8 {
        return found.text[0..found.len];
    }

    /// As a semantic version, whose parts point into it.
    pub fn semantic(found: *const Version) std.SemanticVersion {
        return std.SemanticVersion.parse(found.slice()) catch unreachable;
    }

    /// Whether it is newer than `than`. Build metadata, such as a build's commits past its release
    /// (`version.string`), counts for nothing.
    pub fn newer(found: *const Version, than: std.SemanticVersion) bool {
        return found.semantic().order(than) == .gt;
    }

    /// Its release's page, in `buffer`.
    pub fn page(found: *const Version, buffer: *PageBuffer) [:0]const u8 {
        return std.mem.printSentinel(buffer, page_url ++ "{s}", .{found.slice()}, 0) catch unreachable;
    }
};

/// What GitHub answered: the latest release's version, or the status it answered with in its
/// place, such as 403 once the requests from this address are past GitHub's limit.
const Answer = union(enum) {
    latest: Version,
    status: std.http.Status,
};

/// Why the thread couldn't tell the latest release.
const Error = std.http.Client.FetchError || std.json.ParseError(std.json.Scanner) || Io.ConcurrentError || error{ BadTag, Timeout };

/// What asks for the latest release, which sets `returned` as it returns: `latest`, or a stand-in
/// in the tests.
const Fetch = *const fn (io: Io, gpa: Allocator, returned: *Io.Event) Error!Answer;

/// What the check and its thread share. It is on the heap, so that the thread can outlive the
/// check, and whichever of the two lets go of it last frees it.
const Shared = struct {
    /// How many of the two still hold it.
    holders: std.atomic.Value(u8) = .init(2),
    /// Whether the thread has answered, and its answer, which is read only once it has.
    answered: std.atomic.Value(bool) = .init(false),
    answer: Error!Answer = undefined,

    /// What it and the thread allocate from: a thread-safe allocator that stays usable after
    /// `main` returns, since the thread can outlive it.
    const allocator = std.heap.smp_allocator;

    /// Leaves the thread's answer for the check.
    fn give(shared: *Shared, answer: Error!Answer) void {
        shared.answer = answer;
        shared.answered.store(true, .release);
    }

    fn letGo(shared: *Shared) void {
        if (shared.holders.fetchSub(1, .acq_rel) == 1) allocator.destroy(shared);
    }
};

/// The check, from its start until the main menu shows what it found.
pub const Check = struct {
    /// `starlancer.ini`, which keeps the newest release the main menu has shown.
    settings_file: *engine.profile.File,
    /// What it shares with its thread, until it takes the answer, or OpenReliant quits.
    shared: ?*Shared = null,
    /// A newer release than the one playing, once the check has found one, and whether the main
    /// menu has shown it, in this run or an earlier one (`seen_key`).
    newer: ?Version = null,
    shown: bool = false,

    /// Starts the thread. A check that can't start is logged, and finds nothing.
    pub fn start(check: *Check) void {
        check.startAsking(latest, time_limit);
    }

    fn startAsking(check: *Check, fetch: Fetch, limit: Io.Duration) void {
        const shared = Shared.allocator.create(Shared) catch |err| return cantCheck("{s}", .{@errorName(err)});
        shared.* = .{};
        const thread = std.Thread.spawn(.{}, ask, .{ shared, fetch, limit }) catch |err| {
            Shared.allocator.destroy(shared);
            return cantCheck("{s}", .{@errorName(err)});
        };
        thread.detach();
        check.shared = shared;
    }

    /// Takes the thread's answer once it has answered; each frame. It never waits.
    pub fn poll(check: *Check) void {
        const shared = check.shared orelse return;
        if (!shared.answered.load(.acquire)) return;
        const answer = shared.answer;
        shared.letGo();
        check.shared = null;
        const reply = answer catch |err| return switch (err) {
            error.Timeout => cantCheck("GitHub didn't answer within {d} seconds", .{time_limit.toSeconds()}),
            else => cantCheck("{s}", .{@errorName(err)}),
        };
        switch (reply) {
            .status => |status| cantCheck("GitHub answered {d}", .{@backingInt(status)}),
            .latest => |latest_release| check.found(latest_release),
        }
    }

    /// Logs the latest release where it is newer than the one playing, and keeps it for the main
    /// menu, unless the menu has already shown it, or a newer one.
    fn found(check: *Check, latest_release: Version) void {
        if (!latest_release.newer(version.semantic)) {
            log.debug("OpenReliant {s} is up to date", .{version.string});
            return;
        }
        var buffer: PageBuffer = undefined;
        log.info("OpenReliant {s} is out, and this is {s}: {s}", .{ latest_release.slice(), version.string, latest_release.page(&buffer) });
        check.newer = latest_release;
        check.shown = seen(check.settings_file.profile, latest_release);
    }

    /// Leaves the thread behind where it hasn't answered, as OpenReliant quits, without waiting for
    /// it.
    pub fn close(check: *Check) void {
        const shared = check.shared orelse return;
        shared.letGo();
        check.shared = null;
    }

    /// What the main menu shows the player.
    pub fn release(check: *Check) main_menu.Release {
        return .{ .context = check, .vtable = &.{ .pending = pending, .answered = answered } };
    }

    fn pending(context: *anyopaque) ?[]const u8 {
        const check: *Check = @ptrCast(@alignCast(context));
        if (check.shown) return null;
        if (check.newer) |*newer| return newer.slice();
        return null;
    }

    /// Keeps the release as the newest the main menu has shown, and opens its page where the player
    /// asked for it.
    fn answered(context: *anyopaque, open: bool) void {
        const check: *Check = @ptrCast(@alignCast(context));
        const newer = check.newer orelse return;
        check.shown = true;
        check.settings_file.write(settings.section, seen_key, newer.slice()) catch |err| log.warn("can't keep {s} as the newest release the main menu has shown: {s}", .{ newer.slice(), @errorName(err) });
        if (!open) return;
        var buffer: PageBuffer = undefined;
        platform.window.openUrl(newer.page(&buffer)) catch {};
    }
};

/// Whether the settings file says the main menu has shown `release`, or a newer one.
fn seen(profile: engine.profile.Profile, release: Version) bool {
    const kept = profile.value(settings.section, seen_key) orelse return false;
    const shown = std.SemanticVersion.parse(kept) catch return false;
    return !release.newer(shown);
}

/// Logs why the check can't tell whether a newer release is out.
fn cantCheck(comptime reason: []const u8, args: anytype) void {
    log.info("can't check for a newer OpenReliant: " ++ reason, args);
}

/// The check's thread, with an `Io` of its own, which `main`'s doesn't wait for as OpenReliant
/// quits: asks for the latest release with `fetch`, as a task it cancels once `limit` is up, and
/// leaves the answer in `shared`.
fn ask(shared: *Shared, fetch: Fetch, limit: Io.Duration) void {
    defer shared.letGo();
    var threaded: Io.Threaded = .init(Shared.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var returned: Io.Event = .unset;
    var task = io.concurrent(call, .{ fetch, io, Shared.allocator, &returned }) catch |err| return shared.give(err);
    const in_time = if (returned.waitTimeout(io, .{ .duration = .{ .raw = limit, .clock = .awake } })) true else |_| false;
    // Cancelling can't interrupt a lookup of GitHub's address, so it waits for the lookup to end;
    // the game doesn't wait for this thread.
    const answer = task.cancel(io);
    shared.give(if (in_time) answer else error.Timeout);
}

/// Calls `fetch`, as a task of the check's thread.
fn call(fetch: Fetch, io: Io, gpa: Allocator, returned: *Io.Event) Error!Answer {
    return fetch(io, gpa, returned);
}

/// Asks GitHub's API for the latest release, on a task of the check's thread, which sets
/// `returned` as it returns.
fn latest(io: Io, gpa: Allocator, returned: *Io.Event) Error!Answer {
    defer returned.set(io);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const answer = try gpa.alloc(u8, max_answer);
    defer gpa.free(answer);
    var writer: Io.Writer = .fixed(answer);
    const result = try client.fetch(.{
        .location = .{ .url = latest_url },
        .response_writer = &writer,
        .keep_alive = false,
        .headers = .{ .user_agent = .{ .override = user_agent } },
        .extra_headers = &.{.{ .name = "Accept", .value = "application/vnd.github+json" }},
    });
    if (result.status != .ok) return .{ .status = result.status };
    return .{ .latest = try tagVersion(gpa, writer.buffered()) };
}

/// The version that the tag of a release names, from GitHub's description of it, `answer`.
fn tagVersion(gpa: Allocator, answer: []const u8) Error!Version {
    const parsed = try std.json.parseFromSlice(struct { tag_name: []const u8 }, gpa, answer, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return Version.ofTag(parsed.value.tag_name) orelse error.BadTag;
}

test "Version.ofTag" {
    try std.testing.expectEqualStrings("0.10.0", Version.ofTag("v0.10.0").?.slice());
    try std.testing.expectEqualStrings("1.0.0-beta.2", Version.ofTag("v1.0.0-beta.2").?.slice());
    // Only a `v` and a semantic version, without build metadata, and short.
    for ([_][]const u8{ "0.10.0", "v0.10", "v0.10.0+12.gabc1234", "v0.10.0/../x", "vx.y.z", "v0.10.0 ", "v" ++ @as([40]u8, @splat('1')) ++ ".0.0" }) |tag| {
        try std.testing.expectEqual(null, Version.ofTag(tag));
    }
}

test "Version.newer" {
    const release = Version.ofTag("v0.10.0").?;
    try std.testing.expect(release.newer(try .parse("0.9.1")));
    try std.testing.expect(release.newer(try .parse("0.10.0-beta.1")));
    try std.testing.expect(!release.newer(try .parse("0.10.0")));
    // A build past a release is that release.
    try std.testing.expect(!release.newer(try .parse("0.10.0+12.gabc1234.dirty")));
    try std.testing.expect(!release.newer(try .parse("0.11.0")));
    var buffer: PageBuffer = undefined;
    try std.testing.expectEqualStrings("https://github.com/OpenReliant/openreliant/releases/tag/v0.10.0", release.page(&buffer));
}

test tagVersion {
    // The tag, wherever it stands among the description's other fields.
    const answer =
        \\{"url":"https://api.github.com/repos/OpenReliant/openreliant/releases/1","html_url":"https://github.com/OpenReliant/openreliant/releases/tag/v0.10.0",
        \\"id":1,"tag_name":"v0.10.0","draft":false,"prerelease":false,"assets":[{"name":"openreliant.zip","size":1}],"body":"Notes"}
    ;
    try std.testing.expectEqualStrings("0.10.0", (try tagVersion(std.testing.allocator, answer)).slice());
    try std.testing.expectError(error.BadTag, tagVersion(std.testing.allocator, "{\"tag_name\":\"nightly\"}"));
    try std.testing.expectError(error.MissingField, tagVersion(std.testing.allocator, "{\"message\":\"Not Found\"}"));
}

test Check {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var file: engine.profile.File = .{ .arena = arena.allocator(), .profile = .empty };
    var check: Check = .{ .settings_file = &file };
    const shown = check.release();
    // Nothing found, nothing to show.
    try std.testing.expectEqual(null, shown.pending());
    // A newer release waits until the player answers, and is kept as the newest shown.
    const newer = Version.ofTag("v99.0.0").?;
    check.found(newer);
    try std.testing.expectEqualStrings("99.0.0", shown.pending().?);
    shown.answered(false);
    try std.testing.expectEqual(null, shown.pending());
    try std.testing.expectEqualStrings("99.0.0", file.profile.value(settings.section, seen_key).?);
    // Found again, as at the next start, it isn't shown again; a newer one is.
    check = .{ .settings_file = &file };
    check.found(newer);
    try std.testing.expectEqual(null, shown.pending());
    check.found(Version.ofTag("v99.1.0").?);
    try std.testing.expectEqualStrings("99.1.0", shown.pending().?);
    // The release playing, or an older one, is never shown.
    check = .{ .settings_file = &file };
    check.found(Version.ofTag("v0.0.1").?);
    try std.testing.expectEqual(null, check.newer);
}

/// Stand-ins for `latest`: one that answers at once with a newer release, one that waits past the
/// time limit, and one that ignores its cancelling for a while, as the system's resolver does.
const testing = struct {
    fn newer(io: Io, _: Allocator, returned: *Io.Event) Error!Answer {
        defer returned.set(io);
        return .{ .latest = Version.ofTag("v99.0.0").? };
    }

    fn slow(io: Io, _: Allocator, returned: *Io.Event) Error!Answer {
        defer returned.set(io);
        try io.sleep(.fromSeconds(10), .awake);
        return .{ .status = .ok };
    }

    fn stuck(io: Io, _: Allocator, returned: *Io.Event) Error!Answer {
        defer returned.set(io);
        const was = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(was);
        io.sleep(.fromMilliseconds(500), .awake) catch unreachable;
        return .{ .status = .ok };
    }

    /// Polls `check` until its thread has answered.
    fn answer(check: *Check) !void {
        const io = std.testing.io;
        for (0..1000) |_| {
            check.poll();
            if (check.shared == null) return;
            try io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.TestTimeout;
    }
};

test "the check's thread answers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var file: engine.profile.File = .{ .arena = arena.allocator(), .profile = .empty };
    var check: Check = .{ .settings_file = &file };
    check.startAsking(testing.newer, time_limit);
    try testing.answer(&check);
    try std.testing.expectEqualStrings("99.0.0", check.release().pending().?);
    // Past its time limit, it gives up, and finds nothing.
    check = .{ .settings_file = &file };
    check.startAsking(testing.slow, .fromMilliseconds(20));
    try testing.answer(&check);
    try std.testing.expectEqual(null, check.newer);
}

test "the game never waits for the check's thread" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var file: engine.profile.File = .{ .arena = arena.allocator(), .profile = .empty };
    var check: Check = .{ .settings_file = &file };
    // A thread that can't be stopped for half a second: polling it and quitting take no time.
    const io = std.testing.io;
    const before = Io.Clock.awake.now(io);
    check.startAsking(testing.stuck, .fromMilliseconds(10));
    check.poll();
    check.close();
    try std.testing.expect(before.durationTo(Io.Clock.awake.now(io)).toMilliseconds() < 100);
    try std.testing.expectEqual(null, check.shared);
}
