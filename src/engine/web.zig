//! OpenReliant's downloads from the web: GET MODS's indexes, thumbnails and archives
//! (`game.bigfile.catalogue`), and the check for a newer release (`openreliant/updates.zig`).
//!
//! - Everything is read over HTTPS (`secured`): a plain `http` link is changed to `https` before
//!   the request, and so is each redirect, which `Answer.open` follows itself. Plain HTTP never
//!   replaces HTTPS when HTTPS fails.
//! - The player's own machine (`isLoopback`) is read only where a download allows it (`Loopback`):
//!   for a repository on the player's machine and its links, which are read over plain HTTP too. A
//!   link anywhere else to the player's machine, or a redirect to it from another host, is refused,
//!   so that a repository on the web can't make OpenReliant send requests to the services on the
//!   player's machine. A host name that the system's resolver turns into the player's own address
//!   isn't caught, as only the link itself is checked, but it is read over HTTPS, so a service
//!   there gets the start of a secure connection that it can't complete, never a request.
//! - Each download runs on a thread of its own, with an `Io` and an HTTP client of its own
//!   (`Download`). The game never waits for it: each frame it looks at whether the download has
//!   ended, and as it quits it leaves the thread behind. A slow or missing connection never holds
//!   the game up, not even a lookup of a host's address, which the system's resolver does in a call
//!   nothing can interrupt.
//! - A download gives up past its limits (`Limits`): a time for the whole download, and a time
//!   without anything arriving, so that a server that stops answering doesn't leave it waiting for
//!   good.
//!
//! **Improvement:** the original never reads the web.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const log = std.log.scoped(.web);

/// What the downloads allocate from: a thread-safe allocator that stays usable after `main`
/// returns, since a download's thread can outlive it.
pub const allocator = std.heap.smp_allocator;

/// The size of the buffers a response is read through.
pub const chunk_size = 64 * 1024;
/// The longest redirect location accepted, as GitHub's release downloads redirect. RFC 9110
/// recommends at least 8000 bytes.
pub const redirect_size = 8 * 1024;
/// How many redirects a download follows at most. GitHub's release downloads redirect once, to
/// another host.
const most_redirects = 5;
/// How often a download's thread looks at its limits and at whether its owner has let go of it.
const watch_step: Io.Duration = .fromMilliseconds(100);

/// Whether a download may read the player's own machine (`isLoopback`).
pub const Loopback = enum {
    refused,
    allowed,

    /// What a download from `url` may do: read the player's machine where `url` names it, as a
    /// repository the player set up there does.
    pub fn of(url: []const u8) Loopback {
        const uri = std.Uri.parse(url) catch return .refused;
        return if (isLoopback(uri)) .allowed else .refused;
    }
};

/// The URL `uri` is requested at: `https` where it says `http`, unless it names the player's own
/// machine where `loopback` allows it. Fails with `error.UnsupportedUriScheme` for any other scheme,
/// such as `ws` or `ftp`, which the HTTP client would otherwise take, and with
/// `error.LoopbackRefused` for the player's own machine where `loopback` refuses it.
pub fn secured(uri: std.Uri, loopback: Loopback) error{ UnsupportedUriScheme, LoopbackRefused }!std.Uri {
    const local = isLoopback(uri);
    if (local and loopback == .refused) return error.LoopbackRefused;
    var secure = uri;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        secure.scheme = "https";
    } else if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) {
        secure.scheme = if (local) "http" else "https";
    } else return error.UnsupportedUriScheme;
    return secure;
}

/// Whether `uri` names the player's own machine: `localhost` or a name under it, an IPv4 address of
/// `127.0.0.0/8` or `0.0.0.0`, in any of the forms the system's resolver reads, such as `127.1` or
/// `2130706433`, or the IPv6 addresses `::1` and `::`, also with an IPv4 one mapped into them. A
/// host whose name can't be decoded counts as the player's machine, so that it is refused.
pub fn isLoopback(uri: std.Uri) bool {
    const host = uri.host orelse return false;
    var buffer: [256]u8 = undefined;
    const raw = host.toRaw(&buffer) catch return true;
    const name = std.mem.trimEnd(u8, std.mem.trim(u8, raw, "[]"), ".");
    if (std.ascii.eqlIgnoreCase(name, "localhost") or std.ascii.endsWithIgnoreCase(name, ".localhost")) return true;
    if (ipv4(name)) |address| return localIpv4(address);
    const address = Io.net.Ip6Address.parse(name, 0) catch return false;
    const bytes = address.bytes;
    if (std.mem.allEqual(u8, bytes[0..15], 0)) return bytes[15] <= 1;
    const mapped = std.mem.allEqual(u8, bytes[0..10], 0) and bytes[10] == 0xff and bytes[11] == 0xff;
    return mapped and localIpv4(bytes[12..16].*);
}

/// Whether an IPv4 address is the player's own machine: `127.0.0.0/8` or `0.0.0.0`.
fn localIpv4(address: [4]u8) bool {
    return address[0] == 127 or std.mem.allEqual(u8, &address, 0);
}

/// The IPv4 address `name` gives as the system's resolver reads it (`inet_aton`): one to four parts
/// split by dots, each decimal, octal with a leading `0` or hexadecimal with a leading `0x`, the
/// last filling the bytes the others leave. Null for a name that isn't such an address.
fn ipv4(name: []const u8) ?[4]u8 {
    var parts: [4]u32 = undefined;
    var count: usize = 0;
    var rest = std.mem.splitScalar(u8, name, '.');
    while (rest.next()) |part| : (count += 1) {
        if (count == parts.len or part.len == 0) return null;
        const base: u8, const digits = if (std.ascii.startsWithIgnoreCase(part, "0x")) .{ 16, part[2..] } else if (part.len > 1 and part[0] == '0') .{ 8, part[1..] } else .{ 10, part };
        parts[count] = if (digits.len == 0) 0 else std.fmt.parseInt(u32, digits, base) catch return null;
    }
    var value: u32 = 0;
    for (parts[0 .. count - 1], 0..) |part, index| {
        if (part > 0xff) return null;
        value |= part << @intCast(24 - 8 * index);
    }
    const last = parts[count - 1];
    const room: u6 = @intCast(32 - 8 * (count - 1));
    if (room < 32 and last >> @intCast(room) != 0) return null;
    value |= last;
    return std.mem.toBytes(std.mem.nativeToBig(u32, value));
}

/// How far a download has got. Its thread writes it and the game's thread reads it, so the fields
/// are atomic.
pub const Progress = struct {
    received: std.atomic.Value(u64) = .init(0),
    /// The download's length, where it is known, else 0.
    total: std.atomic.Value(u64) = .init(0),
    /// How many times something has arrived: the answer's head, and each part of its body. A
    /// download whose count stays the same has stalled (`Limits.quiet`).
    arrivals: std.atomic.Value(u32) = .init(0),

    /// Counts something that arrived.
    pub fn heard(progress: *Progress) void {
        _ = progress.arrivals.fetchAdd(1, .monotonic);
    }

    /// Counts `bytes` of the body that arrived.
    pub fn add(progress: *Progress, bytes: u64) void {
        _ = progress.received.fetchAdd(bytes, .monotonic);
        progress.heard();
    }

    /// The share of the download received so far, from 0 to 1; null when the length is unknown.
    pub fn fraction(progress: *const Progress) ?f32 {
        const total = progress.total.load(.monotonic);
        if (total == 0) return null;
        const received = progress.received.load(.monotonic);
        return @min(1, @as(f32, @floatFromInt(received)) / @as(f32, @floatFromInt(total)));
    }
};

/// How long a download may take, past which it gives up with `error.Timeout`.
pub const Limits = struct {
    /// The whole download, from its start; null for no limit.
    whole: ?Io.Duration = null,
    /// The time without anything arriving (`Progress.arrivals`), from its start or from what last
    /// arrived; null for no limit. A large file may take a long time, but data keeps arriving.
    quiet: ?Io.Duration = null,
};

/// A request the server answered with OK, whose body `reader` reads. It is made in place, since
/// the response points into the request.
pub const Answer = struct {
    gpa: Allocator,
    request: std.http.Client.Request,
    response: std.http.Client.Response,
    transfer_buffer: [chunk_size]u8,
    decompress: std.http.Decompress,
    decompress_buffer: []u8,
    /// Where the redirects' locations are resolved, each against the one before, so two take
    /// turns.
    locations: [2][redirect_size]u8,

    /// Requests `url` with `client`, following redirects itself (`most_redirects`), each to its
    /// location made `secured`. The player's own machine is read where `loopback` allows it, and a
    /// redirect goes there only from the player's own machine. Counts the answer's head in
    /// `progress`. Besides the client's and the URL parser's errors, fails with `error.NotFound`
    /// for a 404, `error.ServerRefused` for any other status than OK, `error.TooManyRedirects`,
    /// and `error.RedirectWithoutLocation`, `error.RedirectTooLong` or `error.BadRedirect` for a
    /// redirect that can't be followed.
    pub fn open(answer: *Answer, gpa: Allocator, client: *std.http.Client, url: []const u8, loopback: Loopback, progress: *Progress) !void {
        answer.gpa = gpa;
        answer.decompress_buffer = &.{};
        var uri = try secured(try std.Uri.parse(url), loopback);
        var hops: usize = 0;
        while (true) : (hops += 1) {
            answer.request = try client.request(.GET, uri, .{ .redirect_behavior = .unhandled });
            errdefer answer.request.deinit();
            try answer.request.sendBodiless();
            answer.response = try answer.request.receiveHead(&.{});
            progress.heard();
            const head = &answer.response.head;
            if (head.status.class() != .redirect) switch (head.status) {
                .ok => return,
                .not_found => return error.NotFound,
                else => return error.ServerRefused,
            };
            if (hops == most_redirects) return error.TooManyRedirects;
            const location = head.location orelse return error.RedirectWithoutLocation;
            const buffer = &answer.locations[hops % answer.locations.len];
            if (location.len > buffer.len) return error.RedirectTooLong;
            @memcpy(buffer[0..location.len], location);
            var aux: []u8 = buffer;
            const from_local = isLoopback(uri);
            const resolved = uri.resolveInPlace(location.len, &aux) catch |err| switch (err) {
                error.NoSpaceLeft => return error.RedirectTooLong,
                else => return error.BadRedirect,
            };
            uri = try secured(resolved, if (from_local) loopback else .refused);
            answer.request.deinit();
        }
    }

    /// The length the server announced for the body, where it isn't compressed; null otherwise.
    pub fn length(answer: *const Answer) ?u64 {
        const head = &answer.response.head;
        return if (head.content_encoding == .identity) head.content_length else null;
    }

    /// The body, decompressed if the server compressed it. Fails with
    /// `error.UnsupportedCompressionMethod` for a compression that can't be read.
    pub fn reader(answer: *Answer) !*Io.Reader {
        const head = &answer.response.head;
        answer.decompress_buffer = switch (head.content_encoding) {
            .identity => &.{},
            .zstd => try answer.gpa.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try answer.gpa.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        return answer.response.readerDecompressing(&answer.transfer_buffer, &answer.decompress, answer.decompress_buffer);
    }

    /// Why reading the body failed, where the reader said `error.ReadFailed`: the body's error,
    /// else the connection's.
    pub const BodyError = std.http.Reader.BodyError || std.http.Client.Connection.ReadError || error{ReadFailed};

    /// The error the body's reading failed with, where the reader said `error.ReadFailed`.
    pub fn bodyError(answer: *const Answer) BodyError {
        if (answer.response.bodyErr()) |err| return err;
        if (answer.request.connection) |connection| if (connection.getReadError()) |err| return err;
        return error.ReadFailed;
    }

    pub fn deinit(answer: *Answer) void {
        answer.gpa.free(answer.decompress_buffer);
        answer.request.deinit();
        answer.* = undefined;
    }
};

/// Downloads `url` into memory, up to `limit` bytes, with a client of its own on `io`: the bytes,
/// allocated with `allocator`. Fails with `error.StreamTooLong` for a longer file.
pub fn fetch(io: Io, url: []const u8, limit: usize, loopback: Loopback, progress: *Progress) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var answer: Answer = undefined;
    try answer.open(allocator, &client, url, loopback, progress);
    defer answer.deinit();
    if (answer.length()) |announced| {
        if (announced > limit) return error.StreamTooLong;
        progress.total.store(announced, .monotonic);
    }
    const body = try answer.reader();
    var bytes: Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    while (true) {
        const read = body.stream(&bytes.writer, .limited(chunk_size)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return answer.bodyError(),
            error.WriteFailed => return error.OutOfMemory,
        };
        if (bytes.writer.end > limit) return error.StreamTooLong;
        progress.add(read);
    }
    return bytes.toOwnedSlice();
}

/// A download on a thread of its own, which the game never waits for: `Job`'s `run`, within its
/// limits (`Limits`). A new `Download` (`.{}`) is idle until `start`.
///
/// `Job` has `fn run(job: *Job, io: Io, progress: *Progress) !Output`, called on the
/// thread with an `Io` of its own, and may have `fn deinit(job: *Job) void`, which frees what the
/// job holds, and `fn discard(output: Output) void`, which frees an answer nobody took. The game
/// polls it each frame (`take`), and lets go of it without waiting (`abandon`).
pub fn Download(comptime Job: type) type {
    return struct {
        /// What it shares with its thread, from `start` until it takes the answer or lets go.
        shared: ?*Shared = null,

        const Self = @This();
        const Returned = @typeInfo(@typeInfo(@TypeOf(Job.run)).@"fn".return_type.?).error_union;
        /// What `Job.run` gives when it succeeds.
        pub const Output = Returned.payload;
        /// Why a download fails: `Job.run`'s errors, no thread to run it on, its limits
        /// (`error.Timeout`), or being let go of (`error.Canceled`).
        pub const Error = Returned.error_set || Io.ConcurrentError || error{ Timeout, Canceled };

        /// What the download and its thread share. It is on the heap, so that the thread can
        /// outlive the download, and whichever of the two lets go of it last frees it.
        const Shared = struct {
            /// How many of the two still hold it.
            holders: std.atomic.Value(u8) = .init(2),
            /// Whether the thread has answered, and its answer, which is read only once it has, and
            /// whether the download took it.
            answered: std.atomic.Value(bool) = .init(false),
            answer: Error!Output = undefined,
            taken: bool = false,
            /// Whether the download has let go, so that the thread stops at its next step.
            abandoned: std.atomic.Value(bool) = .init(false),
            progress: Progress = .{},
            job: Job,
            limits: Limits,

            /// Leaves the thread's answer for the download.
            fn give(shared: *Shared, answer: Error!Output) void {
                shared.answer = answer;
                shared.answered.store(true, .release);
            }

            fn letGo(shared: *Shared) void {
                if (shared.holders.fetchSub(1, .acq_rel) != 1) return;
                if (!shared.taken and shared.answered.load(.acquire)) {
                    if (shared.answer) |output| discard(output) else |_| {}
                }
                if (@hasDecl(Job, "deinit")) shared.job.deinit();
                allocator.destroy(shared);
            }
        };

        /// Frees an answer nobody took.
        fn discard(output: Output) void {
            if (@hasDecl(Job, "discard")) Job.discard(output);
        }

        /// Starts `job` on a thread of its own, within `limits`. The download takes the job, which
        /// is freed with it (`Job.deinit`), even if it can't start. It must be idle.
        pub fn start(download: *Self, job: Job, limits: Limits) (Allocator.Error || std.Thread.SpawnError)!void {
            std.debug.assert(download.shared == null);
            var taken = job;
            const shared = allocator.create(Shared) catch |err| {
                if (@hasDecl(Job, "deinit")) taken.deinit();
                return err;
            };
            shared.* = .{ .job = taken, .limits = limits };
            const thread = std.Thread.spawn(.{}, work, .{shared}) catch |err| {
                if (@hasDecl(Job, "deinit")) shared.job.deinit();
                allocator.destroy(shared);
                return err;
            };
            thread.detach();
            download.shared = shared;
        }

        /// Whether it runs, or has answered and waits for `take`.
        pub fn busy(download: Self) bool {
            return download.shared != null;
        }

        /// How far it has got, while it runs.
        pub fn progress(download: Self) ?*const Progress {
            const shared = download.shared orelse return null;
            return &shared.progress;
        }

        /// Takes the thread's answer once it has answered; null while it runs, or when nothing
        /// runs. Afterwards the download is idle. It never waits.
        pub fn take(download: *Self) ?(Error!Output) {
            const shared = download.shared orelse return null;
            if (!shared.answered.load(.acquire)) return null;
            const answer = shared.answer;
            shared.taken = true;
            shared.letGo();
            download.shared = null;
            return answer;
        }

        /// Lets go of the download without waiting for it, as the game quits or forgets it. Its
        /// thread stops at its next step, or once a lookup of a host's address ends, and frees what
        /// it holds. Afterwards the download is idle.
        pub fn abandon(download: *Self) void {
            const shared = download.shared orelse return;
            shared.abandoned.store(true, .release);
            shared.letGo();
            download.shared = null;
        }

        /// The thread, with an `Io` of its own, which `main`'s doesn't wait for as OpenReliant quits:
        /// runs the job as a task it cancels once the job is past its limits or abandoned, and
        /// leaves the answer in `shared`.
        fn work(shared: *Shared) void {
            defer shared.letGo();
            var threaded: Io.Threaded = .init(allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var returned: Io.Event = .unset;
            var task = io.concurrent(run, .{ shared, io, &returned }) catch |err| return shared.give(err);
            const ended = watch(io, &returned, &shared.progress, &shared.abandoned, shared.limits);
            // Cancelling can't interrupt a lookup of a host's address, so it waits for the lookup to
            // end; the game doesn't wait for this thread.
            const answer = task.cancel(io);
            if (ended == .returned) return shared.give(answer);
            if (answer) |output| discard(output) else |_| {}
            shared.give(if (ended == .timed_out) error.Timeout else error.Canceled);
        }

        /// Runs the job, as a task of the thread, and sets `returned` as it returns.
        fn run(shared: *Shared, io: Io, returned: *Io.Event) Returned.error_set!Output {
            defer returned.set(io);
            return shared.job.run(io, &shared.progress);
        }
    };
}

/// How a download's job ended (`watch`).
const Ended = enum { returned, timed_out, abandoned };

/// Waits for a job to return, looking every `watch_step` at whether it is past `limits`, by the
/// time since it started and since something last arrived (`Progress.arrivals`), or `abandoned`.
fn watch(io: Io, returned: *Io.Event, progress: *const Progress, abandoned: *const std.atomic.Value(bool), limits: Limits) Ended {
    const started = Io.Clock.awake.now(io);
    var arrivals = progress.arrivals.load(.monotonic);
    var heard_at = started;
    while (true) {
        if (returned.waitTimeout(io, .{ .duration = .{ .raw = watch_step, .clock = .awake } })) |_| return .returned else |_| {}
        if (abandoned.load(.acquire)) return .abandoned;
        const now = Io.Clock.awake.now(io);
        if (limits.whole) |whole| if (started.durationTo(now).nanoseconds >= whole.nanoseconds) return .timed_out;
        const counted = progress.arrivals.load(.monotonic);
        if (counted != arrivals) {
            arrivals = counted;
            heard_at = now;
        } else if (limits.quiet) |quiet| if (heard_at.durationTo(now).nanoseconds >= quiet.nanoseconds) return .timed_out;
    }
}

test "every address is requested over HTTPS, but the player's own machine where allowed" {
    const Case = struct { url: []const u8, scheme: []const u8 };
    for ([_]Case{
        .{ .url = "https://example.com/mods.json", .scheme = "https" },
        .{ .url = "http://example.com/mods.json", .scheme = "https" },
        .{ .url = "HTTP://Example.com:8080/mods.json", .scheme = "https" },
        .{ .url = "http://127.0.0.1:8000/mods.json", .scheme = "http" },
        .{ .url = "http://localhost/mods.json", .scheme = "http" },
        .{ .url = "http://[::1]:8000/mods.json", .scheme = "http" },
        .{ .url = "https://127.0.0.1/mods.json", .scheme = "https" },
    }) |case| {
        const uri = try secured(try std.Uri.parse(case.url), .allowed);
        try std.testing.expectEqualStrings(case.scheme, uri.scheme);
    }
    try std.testing.expectError(error.UnsupportedUriScheme, secured(try std.Uri.parse("ws://127.0.0.1/mods.json"), .allowed));
    try std.testing.expectError(error.UnsupportedUriScheme, secured(try std.Uri.parse("ftp://example.com/mods.json"), .refused));
    try std.testing.expectError(error.UnsupportedUriScheme, secured(try std.Uri.parse("file:///mods.json"), .refused));
    // Where the player's machine is refused, every way of naming it is.
    try std.testing.expectEqualStrings("https", (try secured(try std.Uri.parse("http://example.com/x"), .refused)).scheme);
    for ([_][]const u8{
        "http://127.0.0.1/x",       "http://localhost:8000/x",     "https://LOCALHOST./x", "http://api.localhost/x",
        "http://127.1/x",           "http://2130706433/x",         "http://0x7f000001/x",  "http://0177.0.0.1/x",
        "http://127.255.255.254/x", "http://0.0.0.0/x",            "http://0/x",           "http://[::1]/x",
        "http://[::]/x",            "http://[::ffff:127.0.0.1]/x", "http://%6Cocalhost/x",
    }) |url| {
        try std.testing.expectError(error.LoopbackRefused, secured(try std.Uri.parse(url), .refused));
    }
    // Other addresses are only other addresses.
    for ([_][]const u8{ "http://128.0.0.1/x", "http://192.168.1.2/x", "http://[2001:db8::1]/x", "http://localhost.example.com/x", "http://1.2.3.4.5/x" }) |url| {
        try std.testing.expect(!isLoopback(try std.Uri.parse(url)));
    }
}

test "a repository on the player's machine may read it" {
    try std.testing.expectEqual(.allowed, Loopback.of("http://127.0.0.1:8000/mods.json"));
    try std.testing.expectEqual(.refused, Loopback.of("https://openreliant.github.io/openreliant-mods/mods.json"));
    try std.testing.expectEqual(.refused, Loopback.of("not a url"));
}

test ipv4 {
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, ipv4("127.0.0.1").?);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, ipv4("127.1").?);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, ipv4("2130706433").?);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, ipv4("0x7F.0.0.1").?);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, ipv4("0177.0.1").?);
    try std.testing.expectEqual([4]u8{ 10, 0, 1, 0 }, ipv4("10.256").?);
    // A bare `0x` is 0, as the resolver reads it.
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, ipv4("0x").?);
    for ([_][]const u8{ "", "example.com", "1.2.3.4.5", "256.1.1.1", "1..2", "08.1.1.1", "1.2.3.256", "4294967296" }) |name| {
        try std.testing.expectEqual(null, ipv4(name));
    }
}

/// Jobs for the tests: one that answers at once, one that waits past any limit, one that ignores
/// its cancelling for a while, as the system's resolver does, and one that keeps something
/// arriving.
const testing = struct {
    const Answers = struct {
        value: u32,
        fn run(job: *Answers, _: Io, _: *Progress) error{}!u32 {
            return job.value;
        }
    };

    const Slow = struct {
        fn run(_: *Slow, io: Io, _: *Progress) Io.Cancelable!u32 {
            try io.sleep(.fromSeconds(10), .awake);
            return 0;
        }
    };

    const Stuck = struct {
        fn run(_: *Stuck, io: Io, _: *Progress) error{}!u32 {
            const was = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(was);
            io.sleep(.fromMilliseconds(500), .awake) catch unreachable;
            return 0;
        }
    };

    const Trickles = struct {
        fn run(_: *Trickles, io: Io, progress: *Progress) Io.Cancelable!u32 {
            for (0..8) |_| {
                try io.sleep(.fromMilliseconds(40), .awake);
                progress.add(1);
            }
            return 8;
        }
    };

    /// Polls `download` until it answers.
    fn answer(download: anytype) !(@TypeOf(download.*).Error!u32) {
        for (0..1000) |_| {
            if (download.take()) |answered| return answered;
            try std.testing.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.TestTimeout;
    }
};

test Download {
    var answers: Download(testing.Answers) = .{};
    try answers.start(.{ .value = 7 }, .{});
    try std.testing.expectEqual(7, try (try testing.answer(&answers)));
    try std.testing.expect(!answers.busy());
    // Past its whole time, it gives up.
    var slow: Download(testing.Slow) = .{};
    try slow.start(.{}, .{ .whole = .fromMilliseconds(30) });
    try std.testing.expectError(error.Timeout, try testing.answer(&slow));
    // With nothing arriving, it gives up; while something keeps arriving, it doesn't.
    try slow.start(.{}, .{ .quiet = .fromMilliseconds(30) });
    try std.testing.expectError(error.Timeout, try testing.answer(&slow));
    var trickles: Download(testing.Trickles) = .{};
    try trickles.start(.{}, .{ .quiet = .fromMilliseconds(150) });
    try std.testing.expectEqual(8, try (try testing.answer(&trickles)));
}

test "the game never waits for a download's thread" {
    // A thread that can't be stopped for half a second: polling it and letting go take no time.
    const io = std.testing.io;
    const before = Io.Clock.awake.now(io);
    var stuck: Download(testing.Stuck) = .{};
    try stuck.start(.{}, .{ .whole = .fromMilliseconds(10) });
    try std.testing.expectEqual(null, stuck.take());
    stuck.abandon();
    try std.testing.expect(before.durationTo(Io.Clock.awake.now(io)).toMilliseconds() < 100);
    try std.testing.expect(!stuck.busy());
}
