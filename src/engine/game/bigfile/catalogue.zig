//! The catalogue of mods on the web (`Catalogue`): the mods that the GET MODS screen
//! (`interface.mod_catalogue`) lists and installs. It is read from one or more repositories
//! (`Repositories`), each the URL of a `mods.json` index like the one the OpenReliant mods site
//! publishes, named in `starlancer.ini`. Each entry gives a mod's name in the `mods` folder, its
//! version, the OpenReliant version it needs, the URL of its archive, and the archive's SHA-256
//! digest and size. The mods of every repository are listed together; where two repositories list
//! the same id, the first one listed wins.
//!
//! Everything is downloaded as `web` downloads: over HTTPS, on a thread of its own that the game
//! never waits for, and within a time limit. The player's own machine is read only for a repository
//! there and its links (`Entry.loopback`).
//!
//! `Fetch` downloads a file from the web into memory, up to a limit. The screen uses it for the
//! indexes and for the thumbnails. `Install` downloads a mod's archive into the `mods` folder, stops
//! as soon as more arrives than the catalogue's size, and checks the archive against the
//! catalogue's digest, which it writes next to the archive as the archive's checksum file. The
//! screen polls both once per frame, so the menus keep running during a download. An index or a
//! thumbnail gives up after a minute, or 15 seconds without anything arriving, and an archive after
//! 30 seconds without anything arriving (`fetch_limits`, `install_limits`). A download the screen
//! lets go of, as OpenReliant quits, stops on its own thread; an archive's part file is deleted then,
//! unless OpenReliant has ended first, in which case the next install of the mod replaces it.
//!
//! **Improvement:** the original has no mods, and never reads the web.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const checksums = @import("../../../formats/checksums.zig");
const files = @import("../../files.zig");
const profile = @import("../../profile.zig");
const mods = @import("mods.zig");
const order = @import("order.zig");
const web = @import("../../web.zig");

const log = std.log.scoped(.catalogue);

/// A repository: the URL of a `mods.json` index, under the name the settings file gives it.
pub const Repository = struct {
    name: []const u8,
    url: []const u8,
};

/// The section of `starlancer.ini` that lists the repositories, one key for each: a name of the
/// player's choosing, and the URL of its index. Without the section, OpenReliant reads
/// `default_repository` alone. With it, OpenReliant reads the repositories it lists, in its
/// order, so a player can add repositories or leave ours out. An empty section hides GET MODS.
pub const section = "OpenReliantModRepositories";

/// The repository OpenReliant reads when the settings file has no `section`: the OpenReliant mods
/// site's index.
pub const default_repository: Repository = .{ .name = "openreliant-mods", .url = "https://openreliant.github.io/openreliant-mods/mods.json" };

/// The repositories the settings file names (`section`).
pub const Repositories = struct {
    profile: profile.Profile,

    pub fn of(settings: profile.Profile) Repositories {
        return .{ .profile = settings };
    }

    /// Whether there is a repository to read, so that GET MODS is shown.
    pub fn any(repositories: Repositories) bool {
        var listed = repositories.iterator();
        return listed.next() != null;
    }

    /// The repository at `index` in the list, if there is one.
    pub fn at(repositories: Repositories, index: usize) ?Repository {
        var listed = repositories.iterator();
        var place: usize = 0;
        while (listed.next()) |repository| : (place += 1) {
            if (place == index) return repository;
        }
        return null;
    }

    /// The repositories, in the section's order.
    pub fn iterator(repositories: Repositories) Iterator {
        const keys = if (repositories.profile.hasSection(section)) repositories.profile.keys(section) else null;
        return .{ .profile = repositories.profile, .keys = keys };
    }

    pub const Iterator = struct {
        profile: profile.Profile,
        /// The section's keys; null without the section, where the default repository stands alone.
        keys: ?profile.Profile.Keys,
        default_given: bool = false,

        /// The next repository. A key without a URL is skipped.
        pub fn next(listed: *Iterator) ?Repository {
            if (listed.keys) |*keys| {
                while (keys.next()) |key| {
                    const url = listed.profile.value(section, key) orelse continue;
                    if (url.len > 0) return .{ .name = key, .url = url };
                }
                return null;
            }
            if (listed.default_given) return null;
            listed.default_given = true;
            return default_repository;
        }
    };
};

/// The index format this version reads, the `format` field of `mods.json`.
pub const format = 1;

/// The size limit of an index, in bytes.
pub const most_index_bytes = 4 * 1024 * 1024;
/// The size limit of a thumbnail, in bytes.
pub const most_thumbnail_bytes = 2 * 1024 * 1024;

/// The largest archive an entry may have: a HOG archive's offsets and sizes are 32-bit (`hog`), so
/// it can't be larger. A larger size skips the entry, as a missing one does.
pub const most_archive_bytes: u64 = std.math.maxInt(u32);
/// How long an index or a thumbnail may take: a minute in all, and 15 seconds without anything
/// arriving.
pub const fetch_limits: web.Limits = .{ .whole = .fromSeconds(60), .quiet = .fromSeconds(15) };
/// How long an archive may go without anything arriving: 30 seconds. A large one takes as long as
/// it takes while data keeps arriving.
pub const install_limits: web.Limits = .{ .quiet = .fromSeconds(30) };
/// The longest line of a checksum file: the digest's digits, two spaces, the name and a newline.
const checksum_line_size = 2 * Sha256.digest_length + 2 + files.max_path + 1;

/// A mod in the catalogue, as the index of its repository describes it (`Listed`), once checked.
pub const Entry = struct {
    /// The mod's name in the `mods` folder. Its archive is named `<id>.hog`.
    id: []const u8,
    /// The name the screen shows; the id when there is none.
    name: ?[]const u8 = null,
    /// The site's category, such as `ships/fighters/alliance`.
    category: ?[]const u8 = null,
    /// The mod's version, as its manifest writes it, such as `1.3`.
    version: ?[]const u8 = null,
    /// The mod's author.
    author: ?[]const u8 = null,
    /// What the mod is, in a sentence or two.
    description: ?[]const u8 = null,
    /// The OpenReliant version the mod needs, like the `OpenReliant` key of `mod.ini`, such as `0.8.1`.
    openreliant: ?[]const u8 = null,
    /// The date of its latest release, as the site writes it.
    updated: ?[]const u8 = null,
    /// The archive's size in bytes. The download stops as soon as more arrives.
    size: u64,
    /// The URL of the archive.
    archive: []const u8,
    /// The archive's SHA-256 digest, the `sha256` key. The download is checked against it, and it
    /// is written next to the archive as the archive's checksum file.
    digest: checksums.Digest,
    /// The URL of its thumbnail, a PNG, if it has one.
    thumbnail: ?[]const u8 = null,
    /// The URL of its web page.
    url: ?[]const u8 = null,
    /// The name of the repository that lists it (`Repository.name`).
    repository: []const u8,
    /// Whether that repository is on the player's own machine, whose links may then go there too
    /// (`loopback`).
    local: bool = false,

    /// The name the screen shows.
    pub fn title(entry: Entry) []const u8 {
        return entry.name orelse entry.id;
    }

    /// The mod's version, if the index gives one that parses.
    pub fn semantic(entry: Entry) ?std.SemanticVersion {
        return mods.parseVersion(entry.version orelse return null);
    }

    /// The OpenReliant version the mod needs, if it's newer than `running`. Null when it isn't, or
    /// when either version is unknown.
    pub fn needsLater(entry: Entry, running: ?std.SemanticVersion) ?std.SemanticVersion {
        return mods.versionNeeded(entry.openreliant orelse return null, running orelse return null) catch null;
    }

    /// The archive's name in the `mods` folder, `<id>.hog`, written into `buffer`.
    pub fn archiveName(entry: Entry, buffer: []u8) error{NameTooLong}![]const u8 {
        return archiveNameOf(entry.id, buffer);
    }

    /// Whether its links may go to the player's own machine: only where its repository is there.
    pub fn loopback(entry: Entry) web.Loopback {
        return if (entry.local) .allowed else .refused;
    }

    /// Why a listed mod can't be an entry.
    pub const Skipped = error{ NoId, BadId, NoArchive, BadDigest, NoSize, TooLarge };

    /// The entry for the mod `listed` of the repository `repository`, which is on the player's
    /// machine where `local`, if the index gives everything it needs: an id that can name a mod
    /// (`validId`), the archive's URL, its digest (`parseDigest`) and its size, at most
    /// `most_archive_bytes`.
    fn from(listed: Listed, repository: []const u8, local: bool) Skipped!Entry {
        const id = listed.id orelse return error.NoId;
        if (!validId(id)) return error.BadId;
        const archive = listed.archive orelse return error.NoArchive;
        const digest = parseDigest(listed.sha256 orelse return error.BadDigest) orelse return error.BadDigest;
        const size = listed.size orelse return error.NoSize;
        if (size > most_archive_bytes) return error.TooLarge;
        return .{
            .id = id,
            .name = listed.name,
            .category = listed.category,
            .version = listed.version,
            .author = listed.author,
            .description = listed.description,
            .openreliant = listed.openreliant,
            .updated = listed.updated,
            .size = size,
            .archive = archive,
            .digest = digest,
            .thumbnail = listed.thumbnail,
            .url = listed.url,
            .repository = repository,
            .local = local,
        };
    }

    /// Why a mod was skipped, for the log.
    fn reason(skipped: Skipped) []const u8 {
        return switch (skipped) {
            error.NoId => "it has no id",
            error.BadId => "its id can't name a mod in the mods folder",
            error.NoArchive => "it has no archive link",
            error.BadDigest => "it has no sha256 digest of 64 hexadecimal digits",
            error.NoSize => "it has no size",
            error.TooLarge => "its size is larger than an archive can be",
        };
    }

    /// Whether `id` can name a mod in the `mods` folder on every system, and in the settings file:
    /// not empty, not hidden (the loader skips a name that starts with a dot), no path separators,
    /// no drive letters, no characters that a file name can't contain, no trailing dot or space,
    /// not one of Windows's device names such as `CON`, even with an extension as `con.v2`, and a
    /// name `<id>.hog` that the mods screen can keep in `starlancer.ini` (`order.Order.listable`).
    pub fn validId(id: []const u8) bool {
        if (id.len == 0 or id.len > longest_id) return false;
        if (id[0] == '.') return false;
        for (id) |byte| if (byte < ' ' or byte == std.ascii.control_code.del or std.mem.findScalar(u8, "/\\:*?\"<>|", byte) != null) return false;
        if (id[id.len - 1] == '.' or id[id.len - 1] == ' ') return false;
        // Windows reserves a device name followed by any extension too: `con.v2` is the console.
        const stem = std.mem.trimEnd(u8, id[0 .. std.mem.findScalar(u8, id, '.') orelse id.len], " ");
        for (device_names) |name| if (std.ascii.eqlIgnoreCase(stem, name)) return false;
        var buffer: [files.max_path]u8 = undefined;
        const archive = archiveNameOf(id, &buffer) catch return false;
        return order.Order.listable(archive);
    }
};

/// The longest id allowed, which leaves room for `.hog.sha256` in a path.
const longest_id = 200;

/// The names Windows reserves for devices, which can't name a file.
const device_names = [_][]const u8{
    "CON",  "PRN",  "AUX",  "NUL",
    "COM1", "COM2", "COM3", "COM4",
    "COM5", "COM6", "COM7", "COM8",
    "COM9", "LPT1", "LPT2", "LPT3",
    "LPT4", "LPT5", "LPT6", "LPT7",
    "LPT8", "LPT9",
};

/// The archive name for the mod `id`, `<id>.hog`, written into `buffer`.
fn archiveNameOf(id: []const u8, buffer: []u8) error{NameTooLong}![]const u8 {
    return std.mem.print(buffer, "{s}{s}", .{ id, mods.archive_extension }) catch return error.NameTooLong;
}

/// What a `sha256` value may start with, as GitHub writes a release asset's digest.
const digest_prefix = "sha256:";

/// The digest `text` gives: 64 hexadecimal digits, in either case, with or without
/// `digest_prefix`. Null if it is anything else.
fn parseDigest(text: []const u8) ?checksums.Digest {
    const hex = if (std.ascii.startsWithIgnoreCase(text, digest_prefix)) text[digest_prefix.len..] else text;
    if (hex.len != 2 * Sha256.digest_length) return null;
    var digest: checksums.Digest = undefined;
    _ = std.fmt.hexToBytes(&digest, hex) catch return null;
    return digest;
}

/// A mod as `mods.json` writes it. Every key is optional here, so that an entry that lacks one is
/// skipped on its own (`Entry.from`) rather than failing the index, and unknown keys are ignored,
/// so the index can add keys later.
const Listed = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    category: ?[]const u8 = null,
    version: ?[]const u8 = null,
    author: ?[]const u8 = null,
    description: ?[]const u8 = null,
    openreliant: ?[]const u8 = null,
    updated: ?[]const u8 = null,
    size: ?u64 = null,
    archive: ?[]const u8 = null,
    sha256: ?[]const u8 = null,
    thumbnail: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

/// The whole of `mods.json`. `format` is 1 when the key is missing. `generated` says when the
/// index was written, which the game doesn't use.
const Index = struct {
    format: u32 = format,
    generated: ?[]const u8 = null,
    mods: []Listed,
};

pub const ParseError = error{
    /// The text isn't valid JSON, or doesn't have the index's shape.
    Malformed,
    /// The index's `format` is older than any this version reads.
    UnknownFormat,
    /// The index's `format` is newer than this version reads: OpenReliant needs updating.
    NewerFormat,
    OutOfMemory,
};

/// The catalogue: the mods of every repository read so far, in the order the repositories list
/// them. Everything it keeps is in its arena.
pub const Catalogue = struct {
    arena: std.heap.ArenaAllocator,
    listed: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: Allocator) Catalogue {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(catalogue: *Catalogue) void {
        catalogue.arena.deinit();
        catalogue.* = undefined;
    }

    /// Adds the mods of the index `text` of `repository`. The catalogue copies every string it
    /// keeps, so the caller can free `text` afterwards. A mod that lacks a key it needs, or whose
    /// id can't name a mod, is skipped with a warning in the log, and so is a mod whose id a
    /// repository added before listed already: the first repository wins. The log escapes what the
    /// index says, as the index may come from anywhere.
    pub fn add(catalogue: *Catalogue, repository: Repository, text: []const u8) ParseError!void {
        const arena = catalogue.arena.allocator();
        const index = std.json.parseFromSliceLeaky(Index, arena, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Malformed,
        };
        if (index.format > format) return error.NewerFormat;
        if (index.format < format) return error.UnknownFormat;
        const name = try arena.dupe(u8, repository.name);
        const local = web.Loopback.of(repository.url) == .allowed;
        for (index.mods) |listed| {
            const entry = Entry.from(listed, name, local) catch |err| {
                log.warn("{s}: the mod \"{f}\" is skipped: {s}", .{ name, std.zig.fmtString(listed.id orelse ""), Entry.reason(err) });
                continue;
            };
            if (catalogue.find(entry.id)) |earlier| {
                log.warn("{s}: the mod {s} is skipped: {s} lists it already", .{ name, entry.id, earlier.repository });
                continue;
            }
            try catalogue.listed.append(arena, entry);
        }
    }

    /// The mods, in the order they were added.
    pub fn entries(catalogue: Catalogue) []const Entry {
        return catalogue.listed.items;
    }

    /// The mod with the id `id`, ignoring case, as file names do on Windows; null if there is none.
    pub fn find(catalogue: Catalogue, id: []const u8) ?*const Entry {
        for (catalogue.listed.items) |*entry| if (std.ascii.eqlIgnoreCase(entry.id, id)) return entry;
        return null;
    }
};

/// Where a download is.
pub const State = enum {
    /// Not started, or finished and already collected.
    idle,
    running,
    /// The download is complete; `finish` collects the result.
    done,
    /// The download failed; `failure` says why.
    failed,
};

/// Why a download failed. `words` says it as the screen shows it.
pub const Failure = enum {
    /// The server can't be reached, or the connection broke.
    unreachable_server,
    /// The server's name can't be looked up.
    unknown_host,
    /// The TLS connection can't be made: the server's certificate doesn't verify, or the
    /// handshake failed.
    insecure_connection,
    /// The system's root certificates can't be loaded, so no server can be verified.
    no_certificates,
    /// The server answered 404: the file isn't there.
    not_found,
    /// The server answered with a status other than OK, a redirect and 404, such as 500.
    server_refused,
    /// The server redirected more than `most_redirects` times.
    too_many_redirects,
    /// The server redirected without a location, or to one that can't be used.
    bad_redirect,
    /// The URL in the index can't be used: it isn't a URL, or isn't `https` or `http`.
    bad_url,
    /// The URL in the index names the player's own machine, which only a repository there may
    /// (`web.Loopback`).
    refused_address,
    /// The server stopped answering, or took longer than the download may (`web.Limits`).
    no_answer,
    /// The content isn't what was expected: not an index, or compressed in a way that can't be
    /// read.
    bad_content,
    /// The file is longer than its limit allows.
    too_large,
    /// The archive isn't the size the catalogue says.
    wrong_size,
    /// The index is in a format newer than this version reads.
    newer_format,
    /// The archive doesn't match the catalogue's digest.
    checksum_mismatch,
    /// The archive can't be written in the `mods` folder.
    cant_write,
    out_of_memory,
    /// The download's thread can't be started.
    cant_start,

    /// The failure as the screen shows it.
    pub fn words(failure: Failure) []const u8 {
        return switch (failure) {
            .unreachable_server => "CAN'T REACH THE SERVER",
            .unknown_host => "THE SERVER'S NAME CAN'T BE FOUND",
            .insecure_connection => "CAN'T MAKE A SECURE CONNECTION",
            .no_certificates => "CAN'T LOAD THE SYSTEM'S CERTIFICATES",
            .not_found => "NOT FOUND ON THE SERVER",
            .server_refused => "THE SERVER REFUSED THE REQUEST",
            .too_many_redirects => "THE SERVER REDIRECTS TOO MANY TIMES",
            .bad_redirect => "THE SERVER SENT A BAD REDIRECT",
            .bad_url => "THE ADDRESS IN THE CATALOG IS INVALID",
            .refused_address => "THE CATALOG POINTS AT THIS COMPUTER",
            .no_answer => "THE SERVER DOESN'T ANSWER",
            .bad_content => "THE FILE ISN'T AS EXPECTED",
            .too_large => "THE FILE IS LARGER THAN ALLOWED",
            .wrong_size => "THE ARCHIVE ISN'T THE SIZE THE CATALOG SAYS",
            .newer_format => "THE CATALOG NEEDS A NEWER OPENRELIANT",
            .checksum_mismatch => "THE ARCHIVE DOESN'T MATCH ITS CHECKSUM",
            .cant_write => "CAN'T WRITE IN THE MODS FOLDER",
            .out_of_memory => "OUT OF MEMORY",
            .cant_start => "CAN'T START THE DOWNLOAD",
        };
    }

    /// The failure that a download error maps to: this module's own errors, the URL parser's, the
    /// index parser's, and the HTTP client's. The client's errors that aren't named here are the
    /// connection's: refused, reset, timed out, unreachable or broken.
    pub fn of(err: anyerror) Failure {
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.NotFound => .not_found,
            error.ServerRefused => .server_refused,
            error.TooManyRedirects => .too_many_redirects,
            error.RedirectWithoutLocation, error.RedirectTooLong, error.BadRedirect => .bad_redirect,
            error.UnsupportedUriScheme, error.UriMissingHost, error.InvalidHostName, error.InvalidFormat, error.InvalidPort, error.UnexpectedCharacter => .bad_url,
            error.LoopbackRefused => .refused_address,
            error.Timeout => .no_answer,
            error.UnknownHostName,
            error.NameServerFailure,
            error.NoAddressReturned,
            error.ResolvConfParseFailed,
            error.InvalidDnsARecord,
            error.InvalidDnsAAAARecord,
            error.InvalidDnsCnameRecord,
            error.DetectingNetworkConfigurationFailed,
            => .unknown_host,
            error.TlsInitializationFailed,
            error.TlsAlert,
            error.TlsBadLength,
            error.TlsBadRecordMac,
            error.TlsBadRsaSignatureBitCount,
            error.TlsBadSignatureScheme,
            error.TlsCertificateNotVerified,
            error.TlsConnectionTruncated,
            error.TlsDecodeError,
            error.TlsDecryptError,
            error.TlsDecryptFailure,
            error.TlsIllegalParameter,
            error.TlsRecordOverflow,
            error.TlsSequenceOverflow,
            error.TlsUnexpectedMessage,
            => .insecure_connection,
            error.CertificateBundleLoadFailure => .no_certificates,
            error.StreamTooLong => .too_large,
            error.WrongSize => .wrong_size,
            error.UnsupportedCompressionMethod, error.HttpContentEncodingUnsupported, error.HttpHeadersInvalid, error.HttpHeadersOversize, error.HttpChunkInvalid, error.HttpChunkTruncated, error.Malformed, error.UnknownFormat => .bad_content,
            error.NewerFormat => .newer_format,
            error.ChecksumMismatch => .checksum_mismatch,
            error.CantWrite, error.NameTooLong => .cant_write,
            else => .unreachable_server,
        };
    }

    /// The failure that an error of starting a download maps to.
    pub fn ofStart(err: StartError) Failure {
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
            else => .cant_start,
        };
    }
};

/// Why a download can't start: no memory, or no thread.
pub const StartError = Allocator.Error || std.Thread.SpawnError;

/// A download of a file from the web into memory: an index, or a thumbnail. A new `Fetch` (`.{}`)
/// is idle until `start`.
pub const Fetch = struct {
    download: web.Download(Job) = .{},
    /// What `finish` copies the bytes with, and the URL, for the log, copied with it.
    gpa: ?Allocator = null,
    url: ?[]u8 = null,
    /// The bytes received, once the download is done, allocated with `web.allocator`.
    bytes: ?[]u8 = null,
    /// Why the download failed, once it has.
    failure: ?Failure = null,

    /// What to download.
    pub const Request = struct {
        url: []const u8,
        /// The most bytes accepted; a longer file fails the download.
        most_bytes: usize,
        /// Whether the URL may name the player's own machine.
        loopback: web.Loopback = .refused,
        limits: web.Limits = fetch_limits,
    };

    /// What the download's thread runs (`web.Download`).
    pub const Job = struct {
        url: []u8,
        most_bytes: usize,
        loopback: web.Loopback,

        pub fn run(job: *Job, io: Io, progress: *web.Progress) ![]u8 {
            return web.fetch(io, .{ .url = job.url, .loopback = job.loopback }, job.most_bytes, progress);
        }

        pub fn deinit(job: *Job) void {
            web.allocator.free(job.url);
        }

        pub fn discard(bytes: []u8) void {
            web.allocator.free(bytes);
        }
    };

    /// Starts downloading `request`. The fetch must be idle.
    pub fn start(fetch: *Fetch, gpa: Allocator, request: Request) StartError!void {
        std.debug.assert(fetch.state() == .idle);
        const url = try gpa.dupe(u8, request.url);
        errdefer gpa.free(url);
        const job_url = try web.allocator.dupe(u8, request.url);
        try fetch.download.start(.{ .url = job_url, .most_bytes = request.most_bytes, .loopback = request.loopback }, request.limits);
        fetch.gpa = gpa;
        fetch.url = url;
    }

    /// The download's state. Takes its answer in once it has arrived, logging why it failed.
    pub fn state(fetch: *Fetch) State {
        if (fetch.download.take()) |answer| {
            if (answer) |bytes| fetch.bytes = bytes else |err| {
                log.warn("can't download {f}: {s}", .{ std.zig.fmtString(fetch.url.?), @errorName(err) });
                fetch.failure = .of(err);
            }
        }
        if (fetch.download.busy()) return .running;
        if (fetch.bytes != null) return .done;
        if (fetch.failure != null) return .failed;
        return .idle;
    }

    /// Returns the downloaded bytes once the download is done; the caller frees them with the
    /// allocator `start` was given. Returns null while the download runs, if it failed, or if there
    /// is no memory for the copy. Afterwards the fetch is idle and can be started again.
    pub fn finish(fetch: *Fetch) ?[]u8 {
        if (fetch.state() != .done) return null;
        const bytes = fetch.gpa.?.dupe(u8, fetch.bytes.?) catch null;
        fetch.release();
        return bytes;
    }

    /// Lets go of the download if it runs, without waiting for it (`web.Download.abandon`), and
    /// frees what the fetch holds. Afterwards the fetch is idle.
    pub fn deinit(fetch: *Fetch) void {
        fetch.download.abandon();
        fetch.release();
    }

    fn release(fetch: *Fetch) void {
        if (fetch.bytes) |bytes| web.allocator.free(bytes);
        if (fetch.url) |url| fetch.gpa.?.free(url);
        fetch.* = .{};
    }
};

/// A download of a mod's archive into the `mods` folder. The archive is saved as `<id>.hog` once
/// it is complete, is the catalogue's size and matches the catalogue's digest, with the digest
/// written next to it as `<id>.hog.sha256`. A new `Install` (`.{}`) is idle until `start`.
pub const Install = struct {
    download: web.Download(Job) = .{},
    /// The mod's id, for the log, copied with `gpa`.
    gpa: ?Allocator = null,
    id: ?[]u8 = null,
    /// Whether the archive is in place, once the download has ended.
    done: bool = false,
    /// Why the download failed, once it has.
    failure: ?Failure = null,

    /// What the download's thread runs (`web.Download`).
    pub const Job = struct {
        /// The game folder; the archive goes into its `mods` folder. OpenReliant closes it as it
        /// quits, without waiting for the download, so the job opens the `mods` folder first.
        game: Io.Dir,
        id: []u8,
        archive_url: []u8,
        digest: checksums.Digest,
        size: u64,
        loopback: web.Loopback,

        /// Downloads the archive into its part file, hashing the bytes on their way, and stops with
        /// `error.WrongSize` as soon as more arrives than the catalogue's size, or when the server
        /// announces another size. Then puts the archive in place (`ArchiveSink.place`). A download
        /// that stops early, or is let go of, deletes its part file.
        pub fn run(job: *Job, io: Io, progress: *web.Progress) !void {
            progress.total.store(job.size, .monotonic);
            var name_buffer: [files.max_path]u8 = undefined;
            const archive_name = try archiveNameOf(job.id, &name_buffer);
            var folder = try modsFolder(io, job.game);
            defer folder.close(io);
            var answer: web.Answer = undefined;
            try answer.open(io, .{ .url = job.archive_url, .loopback = job.loopback }, progress);
            defer answer.deinit();
            if (answer.length()) |length| if (length != job.size) return error.WrongSize;
            var sink: ArchiveSink = undefined;
            try sink.open(io, folder, archive_name);
            errdefer sink.abandon();
            const received = answer.stream(sink.writer(), job.size, progress) catch |err| return switch (err) {
                error.StreamTooLong => error.WrongSize,
                error.WriteFailed => error.CantWrite,
                else => |other| other,
            };
            if (received != job.size) return error.WrongSize;
            try sink.place(job.digest);
        }

        pub fn deinit(job: *Job) void {
            web.allocator.free(job.id);
            web.allocator.free(job.archive_url);
        }
    };

    /// Starts installing `entry` into the `mods` folder of `game`. The install must be idle.
    pub fn start(install: *Install, gpa: Allocator, game: Io.Dir, entry: Entry) StartError!void {
        std.debug.assert(install.state() == .idle);
        const id = try gpa.dupe(u8, entry.id);
        errdefer gpa.free(id);
        const job_id = try web.allocator.dupe(u8, entry.id);
        const archive_url = web.allocator.dupe(u8, entry.archive) catch |err| {
            web.allocator.free(job_id);
            return err;
        };
        try install.download.start(.{
            .game = game,
            .id = job_id,
            .archive_url = archive_url,
            .digest = entry.digest,
            .size = entry.size,
            .loopback = entry.loopback(),
        }, install_limits);
        install.gpa = gpa;
        install.id = id;
    }

    /// The download's state. Takes its answer in once it has arrived, logging how it ended.
    pub fn state(install: *Install) State {
        if (install.download.take()) |answer| {
            if (answer) |_| {
                log.info("installed the mod {s} in the mods folder", .{install.id.?});
                install.done = true;
            } else |err| {
                log.warn("can't install the mod {s}: {s}", .{ install.id.?, @errorName(err) });
                install.failure = .of(err);
            }
        }
        if (install.download.busy()) return .running;
        if (install.done) return .done;
        if (install.failure != null) return .failed;
        return .idle;
    }

    /// The share of the archive received so far, while it downloads.
    pub fn fraction(install: Install) ?f32 {
        const progress = install.download.progress() orelse return null;
        return progress.fraction();
    }

    /// Forgets the install once the download is done or has failed. Afterwards the install is idle
    /// and can be started again.
    pub fn finish(install: *Install) void {
        switch (install.state()) {
            .idle, .running => return,
            .done, .failed => install.release(),
        }
    }

    /// Lets go of the download if it runs, without waiting for it (`web.Download.abandon`), and
    /// frees what the install holds. The download deletes its part file on its own thread.
    pub fn deinit(install: *Install) void {
        install.download.abandon();
        install.release();
    }

    fn release(install: *Install) void {
        if (install.id) |id| install.gpa.?.free(id);
        install.* = .{};
    }
};

/// Opens the game's `mods` folder, creating it if it doesn't exist.
fn modsFolder(io: Io, game: Io.Dir) !Io.Dir {
    var path: [files.max_path]u8 = undefined;
    const found = files.find(io, game, mods.folder_name, &path) orelse made: {
        game.createDirPath(io, mods.folder_name) catch return error.CantWrite;
        break :made mods.folder_name;
    };
    return game.openDir(io, found, .{}) catch error.CantWrite;
}

/// Where a downloading archive is written: `<name>.part` in the `mods` folder, through a writer
/// that hashes the bytes on their way to the file. `place` renames it to `<name>` once it is
/// complete, and writes its checksum file next to it.
const ArchiveSink = struct {
    io: Io,
    folder: Io.Dir,
    name: []const u8,
    part_name: []const u8,
    part_buffer: [files.max_path]u8,
    /// The part file, while it is open.
    file: ?Io.File,
    file_writer: Io.File.Writer,
    file_buffer: [web.chunk_size]u8,
    hashed: Io.Writer.Hashed(Sha256),
    hash_buffer: [web.chunk_size]u8,

    /// What the part files are named: the archive's name, or its checksum file's, plus this.
    const part_extension = ".part";

    /// Opens the part file. The sink is initialised in place because its writers and its part name
    /// point into its own buffers.
    fn open(sink: *ArchiveSink, io: Io, folder: Io.Dir, name: []const u8) !void {
        sink.io = io;
        sink.folder = folder;
        sink.name = name;
        sink.part_name = std.mem.print(&sink.part_buffer, "{s}{s}", .{ name, part_extension }) catch return error.NameTooLong;
        const file = folder.createFile(io, sink.part_name, .{}) catch return error.CantWrite;
        sink.file = file;
        sink.file_writer = file.writer(io, &sink.file_buffer);
        sink.hashed = .initHasher(&sink.file_writer.interface, Sha256.init(.{}), &sink.hash_buffer);
    }

    /// Where the archive's bytes go.
    fn writer(sink: *ArchiveSink) *Io.Writer {
        return &sink.hashed.writer;
    }

    /// Finishes the archive: writes out what is buffered and closes the part, checks its digest
    /// against `expected`, writes the checksum file as a part too, renames the archive's part to
    /// the archive's name (replacing an older copy), then renames the checksum file's part. Until
    /// the archive is renamed, a failure leaves nothing behind. If the checksum file can't be put
    /// in place, the archive is removed again, with the checksum file of the copy it replaced:
    /// the loader refuses an installed archive without its checksum file.
    fn place(sink: *ArchiveSink, expected: checksums.Digest) !void {
        const io = sink.io;
        sink.hashed.writer.flush() catch return error.CantWrite;
        sink.file_writer.interface.flush() catch return error.CantWrite;
        sink.close();
        const digest = sink.hashed.hasher.finalResult();
        if (!std.mem.eql(u8, &digest, &expected)) return error.ChecksumMismatch;
        var checksum_buffer: [files.max_path]u8 = undefined;
        var checksum_part_buffer: [files.max_path]u8 = undefined;
        const checksum_name = std.mem.print(&checksum_buffer, "{s}{s}", .{ sink.name, checksums.extension }) catch return error.NameTooLong;
        const checksum_part = std.mem.print(&checksum_part_buffer, "{s}{s}", .{ checksum_name, part_extension }) catch return error.NameTooLong;
        sink.writeChecksum(checksum_part, expected) catch return error.CantWrite;
        sink.folder.rename(sink.part_name, sink.folder, sink.name, io) catch return error.CantWrite;
        sink.folder.rename(checksum_part, sink.folder, checksum_name, io) catch |err| {
            log.warn("{s} can't be given its checksum file, so it is removed again: {s}", .{ sink.name, @errorName(err) });
            sink.folder.deleteFile(io, checksum_part) catch {};
            sink.folder.deleteFile(io, sink.name) catch {};
            sink.folder.deleteFile(io, checksum_name) catch {};
            return error.CantWrite;
        };
    }

    /// Writes the line `sltool hog pack --checksum` writes for the archive, into the file `name`.
    fn writeChecksum(sink: *ArchiveSink, name: []const u8, digest: checksums.Digest) !void {
        var line_buffer: [checksum_line_size]u8 = undefined;
        var line: Io.Writer = .fixed(&line_buffer);
        try checksums.writeLine(&line, digest, sink.name);
        try sink.folder.writeFile(sink.io, .{ .sub_path = name, .data = line.buffered() });
    }

    /// Closes the part file, if it is open.
    fn close(sink: *ArchiveSink) void {
        const file = sink.file orelse return;
        file.close(sink.io);
        sink.file = null;
    }

    /// Abandons the download: closes the part file if it is open, and deletes the part files.
    fn abandon(sink: *ArchiveSink) void {
        sink.close();
        sink.folder.deleteFile(sink.io, sink.part_name) catch {};
        var checksum_part_buffer: [files.max_path]u8 = undefined;
        const checksum_part = std.mem.print(&checksum_part_buffer, "{s}{s}{s}", .{ sink.name, checksums.extension, part_extension }) catch return;
        sink.folder.deleteFile(sink.io, checksum_part) catch {};
    }
};

/// The repositories of the tests, named without a URL where the test gives the index itself.
const test_repository: Repository = .{ .name = "test", .url = "" };
const other_repository: Repository = .{ .name = "other", .url = "" };

test "the settings file names the repositories, or the default one stands alone" {
    const default: Repositories = .of(.{ .text = "[OpenReliantMods]\nviper.hog=1\n" });
    try std.testing.expect(default.any());
    try std.testing.expectEqualStrings("openreliant-mods", default.at(0).?.name);
    try std.testing.expectEqualStrings(default_repository.url, default.at(0).?.url);
    try std.testing.expectEqual(null, default.at(1));
    // The section's repositories, in its order; a key without a URL is skipped.
    const listed: Repositories = .of(.{ .text = "[OpenReliantModRepositories]\nmine=http://127.0.0.1:8000/mods.json\nblank=\nopenreliant-mods=https://openreliant.github.io/openreliant-mods/mods.json\n" });
    var repositories = listed.iterator();
    try std.testing.expectEqualStrings("mine", repositories.next().?.name);
    const second = repositories.next().?;
    try std.testing.expectEqualStrings("openreliant-mods", second.name);
    try std.testing.expectEqualStrings(default_repository.url, second.url);
    try std.testing.expectEqual(null, repositories.next());
    try std.testing.expectEqualStrings("openreliant-mods", listed.at(1).?.name);
    // An empty section names none, so GET MODS is hidden.
    const empty: Repositories = .of(.{ .text = "[OpenReliantModRepositories]\n" });
    try std.testing.expect(!empty.any());
    try std.testing.expectEqual(null, empty.at(0));
}

test "the index is read, and mods that can't be installed are left out" {
    const gpa = std.testing.allocator;
    const digest = "sha256:" ++ "abababababababababababababababababababababababababababababababab";
    // The text is freed right after parsing: the catalogue keeps its own copy of every string.
    const text = try gpa.dupe(u8,
        \\{"format": 1, "generated": "2026-10-10T00:00:00Z", "mods": [
        \\  {"id": "alpha", "name": "Alpha mod", "version": "1.3", "author": "Someone", "openreliant": "0.7",
        \\   "size": 5624773, "archive": "https://example.com/alpha.hog", "sha256": "
    ++ digest ++
        \\",
        \\   "colour": "red"},
        \\  {"id": "../evil", "size": 1, "archive": "https://example.com/evil.hog", "sha256": "
    ++ digest ++
        \\"},
        \\  {"id": "unchecked", "size": 1, "archive": "https://example.com/unchecked.hog"},
        \\  {"id": "unsized", "archive": "https://example.com/unsized.hog", "sha256": "
    ++ digest ++
        \\"},
        \\  {"id": "unlinked", "size": 1, "sha256": "
    ++ digest ++
        \\"},
        \\  {"size": 1, "archive": "https://example.com/nameless.hog", "sha256": "
    ++ digest ++
        \\"},
        \\  {"id": "plain", "size": 1, "archive": "https://example.com/plain.hog", "sha256": "
    ++ "ABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABAB" ++
        \\"},
        \\  {"id": "huge", "size": 4294967296, "archive": "https://example.com/huge.hog", "sha256": "
    ++ digest ++
        \\"}
        \\]}
    );
    var catalogue: Catalogue = .init(gpa);
    defer catalogue.deinit();
    try catalogue.add(test_repository, text);
    gpa.free(text);
    const entries = catalogue.entries();
    try std.testing.expectEqual(2, entries.len);
    try std.testing.expectEqualStrings("Alpha mod", entries[0].title());
    try std.testing.expectEqualStrings("plain", entries[1].title());
    try std.testing.expectEqualStrings("test", entries[0].repository);
    try std.testing.expectEqual(5624773, entries[0].size);
    try std.testing.expectEqual(.refused, entries[0].loopback());
    // The digest is read with or without GitHub's prefix, in either case.
    try std.testing.expectEqual(@as([32]u8, @splat(0xab)), entries[0].digest);
    try std.testing.expectEqual(@as([32]u8, @splat(0xab)), entries[1].digest);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("alpha.hog", try entries[0].archiveName(&buffer));
    try std.testing.expectEqual(std.SemanticVersion{ .major = 1, .minor = 3, .patch = 0 }, entries[0].semantic().?);
    // Alpha needs 0.7: 0.6.1 is too old, 0.7.0 and 0.9 are fine, and an unknown version is accepted.
    try std.testing.expect(entries[0].needsLater(.{ .major = 0, .minor = 6, .patch = 1 }) != null);
    try std.testing.expectEqual(null, entries[0].needsLater(.{ .major = 0, .minor = 7, .patch = 0 }));
    try std.testing.expectEqual(null, entries[0].needsLater(.{ .major = 0, .minor = 9, .patch = 0 }));
    try std.testing.expectEqual(null, entries[0].needsLater(null));
    try std.testing.expectEqual(null, entries[1].needsLater(.{ .major = 0, .minor = 1, .patch = 0 }));
    // A second repository adds its mods after the first's, but not one the first listed already,
    // whatever its case.
    try catalogue.add(other_repository,
        \\{"mods": [
        \\  {"id": "Alpha", "version": "9.9", "size": 1, "archive": "https://example.org/alpha.hog", "sha256": "
    ++ "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd" ++
        \\"},
        \\  {"id": "delta", "size": 2, "archive": "https://example.org/delta.hog", "sha256": "
    ++ "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd" ++
        \\"}
        \\]}
    );
    try std.testing.expectEqual(3, catalogue.entries().len);
    try std.testing.expectEqualStrings("1.3", catalogue.find("ALPHA").?.version.?);
    try std.testing.expectEqualStrings("delta", catalogue.entries()[2].id);
    try std.testing.expectEqualStrings("other", catalogue.entries()[2].repository);
    try std.testing.expectEqual(null, catalogue.find("omega"));
    // A repository on the player's machine may send its mods' downloads there.
    try catalogue.add(.{ .name = "mine", .url = "http://127.0.0.1:8000/mods.json" },
        \\{"mods": [{"id": "epsilon", "size": 1, "archive": "/epsilon.hog", "sha256": "
    ++ "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd" ++
        \\"}]}
    );
    try std.testing.expectEqual(.allowed, catalogue.find("epsilon").?.loopback());
}

test "an index that isn't JSON, or of another format, is refused" {
    const gpa = std.testing.allocator;
    var catalogue: Catalogue = .init(gpa);
    defer catalogue.deinit();
    try std.testing.expectError(error.Malformed, catalogue.add(test_repository, "<html>"));
    try std.testing.expectError(error.Malformed, catalogue.add(test_repository, "{\"format\": 1}"));
    try std.testing.expectError(error.NewerFormat, catalogue.add(test_repository, "{\"format\": 2, \"mods\": []}"));
    try std.testing.expectError(error.UnknownFormat, catalogue.add(test_repository, "{\"format\": 0, \"mods\": []}"));
    try catalogue.add(test_repository, "{\"mods\": []}");
    try std.testing.expectEqual(0, catalogue.entries().len);
}

test parseDigest {
    try std.testing.expectEqual(@as([32]u8, @splat(0x01)), parseDigest("0101010101010101010101010101010101010101010101010101010101010101").?);
    try std.testing.expectEqual(@as([32]u8, @splat(0xef)), parseDigest("SHA256:" ++ "EFEFEFEFEFEFEFEFEFEFEFEFEFEFEFEFEFEFEFEFEFEFEFEFEFEFEFEFEFEFEFEF").?);
    try std.testing.expectEqual(null, parseDigest("01010101010101010101010101010101010101010101010101010101010101"));
    try std.testing.expectEqual(null, parseDigest("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));
    try std.testing.expectEqual(null, parseDigest(""));
}

test "an id can name a mod in the mods folder and in the settings file" {
    try std.testing.expect(Entry.validId("worn-paint"));
    try std.testing.expect(Entry.validId("10-ships"));
    try std.testing.expect(Entry.validId("console"));
    try std.testing.expect(Entry.validId("my mod"));
    try std.testing.expect(!Entry.validId(""));
    try std.testing.expect(!Entry.validId(".."));
    try std.testing.expect(!Entry.validId(".hidden"));
    try std.testing.expect(!Entry.validId("a/b"));
    try std.testing.expect(!Entry.validId("a\\b"));
    try std.testing.expect(!Entry.validId("c:"));
    try std.testing.expect(!Entry.validId("a\nb"));
    try std.testing.expect(!Entry.validId("trailing."));
    try std.testing.expect(!Entry.validId("trailing "));
    try std.testing.expect(!Entry.validId(" leading"));
    try std.testing.expect(!Entry.validId("con"));
    try std.testing.expect(!Entry.validId("LPT1"));
    try std.testing.expect(!Entry.validId("con.v2"));
    try std.testing.expect(!Entry.validId("Con .v2"));
    // The settings file can't keep a key with an equals sign or a leading bracket.
    try std.testing.expect(!Entry.validId("a=b"));
    try std.testing.expect(!Entry.validId("[mod]"));
}

test Failure {
    try std.testing.expectEqualStrings("NOT FOUND ON THE SERVER", Failure.of(error.NotFound).words());
    try std.testing.expectEqual(.server_refused, Failure.of(error.ServerRefused));
    try std.testing.expectEqual(.checksum_mismatch, Failure.of(error.ChecksumMismatch));
    try std.testing.expectEqual(.bad_url, Failure.of(error.UnsupportedUriScheme));
    try std.testing.expectEqual(.cant_write, Failure.of(error.NameTooLong));
    try std.testing.expectEqual(.too_many_redirects, Failure.of(error.TooManyRedirects));
    try std.testing.expectEqual(.bad_redirect, Failure.of(error.RedirectWithoutLocation));
    try std.testing.expectEqual(.insecure_connection, Failure.of(error.TlsCertificateNotVerified));
    try std.testing.expectEqual(.unknown_host, Failure.of(error.UnknownHostName));
    try std.testing.expectEqual(.too_large, Failure.of(error.StreamTooLong));
    try std.testing.expectEqual(.wrong_size, Failure.of(error.WrongSize));
    try std.testing.expectEqual(.newer_format, Failure.of(error.NewerFormat));
    try std.testing.expectEqual(.unreachable_server, Failure.of(error.ConnectionRefused));
    try std.testing.expectEqual(.out_of_memory, Failure.ofStart(error.OutOfMemory));
    try std.testing.expectEqual(.cant_start, Failure.ofStart(error.SystemResources));
}

test "an archive is written as a part, then placed with its checksum file once it matches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Mods");
    // The mods folder is found whatever the case of its name.
    var folder = try modsFolder(io, tmp.dir);
    defer folder.close(io);
    const contents = "an archive's bytes";
    var sink: ArchiveSink = undefined;
    try sink.open(io, folder, "alpha.hog");
    try sink.writer().writeAll(contents[0..3]);
    try sink.writer().writeAll(contents[3..]);
    try sink.place(checksums.digest(contents));
    const written = try tmp.dir.readFileAlloc(io, "Mods/alpha.hog", gpa, .limited(1024));
    defer gpa.free(written);
    try std.testing.expectEqualStrings(contents, written);
    const checksum = try tmp.dir.readFileAlloc(io, "Mods/alpha.hog.sha256", gpa, .limited(1024));
    defer gpa.free(checksum);
    try std.testing.expectEqual(checksums.digest(contents), (try checksums.digestOf(checksum, "alpha.hog")).?);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "Mods/alpha.hog.part", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "Mods/alpha.hog.sha256.part", .{}));
    // A newer copy replaces it, with its checksum file.
    var again: ArchiveSink = undefined;
    try again.open(io, folder, "alpha.hog");
    try again.writer().writeAll("newer");
    try again.place(checksums.digest("newer"));
    const replaced = try tmp.dir.readFileAlloc(io, "Mods/alpha.hog", gpa, .limited(1024));
    defer gpa.free(replaced);
    try std.testing.expectEqualStrings("newer", replaced);
    const replaced_checksum = try tmp.dir.readFileAlloc(io, "Mods/alpha.hog.sha256", gpa, .limited(1024));
    defer gpa.free(replaced_checksum);
    try std.testing.expectEqual(checksums.digest("newer"), (try checksums.digestOf(replaced_checksum, "alpha.hog")).?);
    // A copy that doesn't match its digest is abandoned, as a failed download is, and the old
    // copy stays. Abandoning it twice, as a failure after a close does, is harmless.
    var wrong: ArchiveSink = undefined;
    try wrong.open(io, folder, "alpha.hog");
    try wrong.writer().writeAll("tampered");
    try std.testing.expectError(error.ChecksumMismatch, wrong.place(checksums.digest(contents)));
    wrong.abandon();
    wrong.abandon();
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "Mods/alpha.hog.part", .{}));
    const kept = try tmp.dir.readFileAlloc(io, "Mods/alpha.hog", gpa, .limited(1024));
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("newer", kept);
    // An abandoned download leaves no part file behind.
    var given_up: ArchiveSink = undefined;
    try given_up.open(io, folder, "other.hog");
    try given_up.writer().writeAll("half");
    given_up.abandon();
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "Mods/other.hog.part", .{}));
}

test "the mods folder is made where there is none" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var folder = try modsFolder(io, tmp.dir);
    folder.close(io);
    try tmp.dir.access(io, "mods", .{});
}

test "a fetch and an install that were never started are idle and can be freed" {
    var fetch: Fetch = .{};
    try std.testing.expectEqual(.idle, fetch.state());
    try std.testing.expectEqual(null, fetch.finish());
    try std.testing.expectEqual(null, fetch.failure);
    fetch.deinit();
    var install: Install = .{};
    try std.testing.expectEqual(.idle, install.state());
    try std.testing.expectEqual(null, install.failure);
    install.finish();
    install.deinit();
}

/// What the tests download from: an HTTP server on the loopback address, on another thread, that
/// serves the files it is given, like the web would, until it is stopped.
pub const testing = struct {
    pub const Server = struct {
        io: Io,
        listening: ?Io.net.Server,
        served: []const File,
        group: Io.Group = .init,

        /// A file the server serves at `path`: its body and status, for a redirect, where to, and
        /// how long the server waits before it answers, as a server that has stalled does.
        pub const File = struct { path: []const u8, body: []const u8, status: std.http.Status = .ok, location: ?[]const u8 = null, stall: ?Io.Duration = null };

        /// Starts serving `served` on a free port.
        pub fn start(server: *Server, io: Io, served: []const File) !void {
            const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
            var listening = try address.listen(io, .{});
            errdefer listening.deinit(io);
            server.* = .{ .io = io, .listening = listening, .served = served };
            try server.group.concurrent(io, serve, .{server});
        }

        /// The URL of `path` on this server, written into `buffer`.
        pub fn url(server: Server, buffer: []u8, path: []const u8) []const u8 {
            return std.mem.print(buffer, "http://127.0.0.1:{d}{s}", .{ server.listening.?.socket.address.getPort(), path }) catch unreachable;
        }

        /// The server thread: answers each request with the file asked for, 404 for a file it
        /// doesn't serve, until it is asked for `/stop` or its socket is closed.
        fn serve(server: *Server) Io.Cancelable!void {
            const io = server.io;
            while (true) {
                const stream = server.listening.?.accept(io) catch return;
                defer stream.close(io);
                var in_buffer: [web.redirect_size]u8 = undefined;
                var out_buffer: [web.redirect_size]u8 = undefined;
                var in = stream.reader(io, &in_buffer);
                var out = stream.writer(io, &out_buffer);
                var http_server: std.http.Server = .init(&in.interface, &out.interface);
                var request = http_server.receiveHead() catch continue;
                const target = request.head.target;
                if (std.mem.eql(u8, target, "/stop")) {
                    request.respond("", .{ .keep_alive = false }) catch {};
                    return;
                }
                const found: ?File = for (server.served) |file| {
                    if (std.mem.eql(u8, file.path, target)) break file;
                } else null;
                if (found) |file| {
                    if (file.stall) |stall| io.sleep(stall, .awake) catch return;
                    const headers: []const std.http.Header = if (file.location) |location| &.{.{ .name = "location", .value = location }} else &.{};
                    request.respond(file.body, .{ .status = file.status, .keep_alive = false, .extra_headers = headers }) catch {};
                } else {
                    request.respond("not here", .{ .status = .not_found, .keep_alive = false }) catch {};
                }
            }
        }

        /// Stops the server and waits for its thread: asks it for `/stop`, or closes its socket if
        /// that can't be asked, then closes the socket.
        pub fn stop(server: *Server, gpa: Allocator) void {
            const io = server.io;
            var buffer: [128]u8 = undefined;
            var fetch: Fetch = .{};
            defer fetch.deinit();
            const asked = if (fetch.start(gpa, .{ .url = server.url(&buffer, "/stop"), .most_bytes = 1024, .loopback = .allowed })) |_|
                (wait(&fetch) catch .running) == .done
            else |_|
                false;
            if (!asked) {
                server.listening.?.deinit(io);
                server.listening = null;
            }
            server.group.await(io) catch {};
            if (server.listening) |*listening| listening.deinit(io);
            server.listening = null;
        }
    };

    /// Polls `download`, a `Fetch` or an `Install`, until its download has ended, and returns its
    /// state then.
    pub fn wait(download: anytype) !State {
        for (0..2000) |_| {
            const now = download.state();
            if (now != .running) return now;
            try std.testing.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.TestTimeout;
    }
};

test "the catalogue and a mod download from the web, and the archive is checked on install" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const archive = "the alpha's archive";
    const digest_hex = std.fmt.bytesToHex(checksums.digest(archive), .lower);
    var index_buffer: [512]u8 = undefined;
    const index = try std.mem.print(&index_buffer,
        \\{{"format": 1, "mods": [{{"id": "alpha", "version": "1.3", "size": {d}, "archive": "/alpha.hog", "sha256": "{s}"}}]}}
    , .{ archive.len, &digest_hex });
    var server: testing.Server = undefined;
    try server.start(io, &.{
        .{ .path = "/mods.json", .body = index },
        .{ .path = "/alpha.hog", .body = archive },
        .{ .path = "/wrong.hog", .body = "another archive" },
        .{ .path = "/broken.json", .body = "", .status = .internal_server_error },
        .{ .path = "/moved", .body = "", .status = .found, .location = "/alpha.hog" },
        .{ .path = "/loop", .body = "", .status = .found, .location = "/loop" },
        .{ .path = "/nowhere", .body = "", .status = .found },
        .{ .path = "/elsewhere", .body = "", .status = .found, .location = "ws://127.0.0.1:1/alpha.hog" },
        .{ .path = "/stalled.json", .body = index, .stall = .fromMilliseconds(400) },
    });
    defer server.stop(gpa);
    var buffer: [128]u8 = undefined;

    // The index downloads and parses as a catalogue. The test server is on the player's machine,
    // as a repository tried there is.
    var fetch: Fetch = .{};
    defer fetch.deinit();
    try fetch.start(gpa, .{ .url = server.url(&buffer, "/mods.json"), .most_bytes = most_index_bytes, .loopback = .allowed });
    try std.testing.expectEqual(.done, try testing.wait(&fetch));
    const bytes = fetch.finish().?;
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings(index, bytes);
    var read: Catalogue = .init(gpa);
    defer read.deinit();
    try read.add(test_repository, bytes);
    try std.testing.expectEqual(1, read.entries().len);
    try std.testing.expectEqual(.idle, fetch.state());
    // A missing file fails with not found, a server error with a refusal, and a file over the
    // limit as too large.
    const Case = struct { path: []const u8, most_bytes: usize = most_index_bytes, failure: Failure };
    for ([_]Case{
        .{ .path = "/missing.json", .failure = .not_found },
        .{ .path = "/broken.json", .failure = .server_refused },
        .{ .path = "/alpha.hog", .most_bytes = archive.len - 1, .failure = .too_large },
        // Too many redirects, one without a location, and one to a scheme the downloads refuse
        // each fail in their own way.
        .{ .path = "/loop", .failure = .too_many_redirects },
        .{ .path = "/nowhere", .failure = .bad_redirect },
        .{ .path = "/elsewhere", .failure = .bad_url },
    }) |case| {
        try fetch.start(gpa, .{ .url = server.url(&buffer, case.path), .most_bytes = case.most_bytes, .loopback = .allowed });
        try std.testing.expectEqual(.failed, try testing.wait(&fetch));
        try std.testing.expectEqual(case.failure, fetch.failure.?);
        fetch.deinit();
    }
    // A file of exactly the limit's size is accepted, and a redirect is followed to its file.
    try fetch.start(gpa, .{ .url = server.url(&buffer, "/alpha.hog"), .most_bytes = archive.len, .loopback = .allowed });
    try std.testing.expectEqual(.done, try testing.wait(&fetch));
    fetch.deinit();
    try fetch.start(gpa, .{ .url = server.url(&buffer, "/moved"), .most_bytes = most_index_bytes, .loopback = .allowed });
    try std.testing.expectEqual(.done, try testing.wait(&fetch));
    const moved = fetch.finish().?;
    defer gpa.free(moved);
    try std.testing.expectEqualStrings(archive, moved);
    // Where the player's machine isn't allowed, it isn't read.
    try fetch.start(gpa, .{ .url = server.url(&buffer, "/mods.json"), .most_bytes = most_index_bytes });
    try std.testing.expectEqual(.failed, try testing.wait(&fetch));
    try std.testing.expectEqual(.refused_address, fetch.failure.?);
    fetch.deinit();
    // A server that stops answering is given up on, and so the fetch can start again.
    try fetch.start(gpa, .{ .url = server.url(&buffer, "/stalled.json"), .most_bytes = most_index_bytes, .loopback = .allowed, .limits = .{ .quiet = .fromMilliseconds(100) } });
    try std.testing.expectEqual(.failed, try testing.wait(&fetch));
    try std.testing.expectEqual(.no_answer, fetch.failure.?);
    fetch.deinit();
    // A fetch let go of mid-download returns at once.
    try fetch.start(gpa, .{ .url = server.url(&buffer, "/stalled.json"), .most_bytes = most_index_bytes, .loopback = .allowed });
    const before = Io.Clock.awake.now(io);
    fetch.deinit();
    try std.testing.expect(before.durationTo(Io.Clock.awake.now(io)).toMilliseconds() < 100);
    try std.testing.expectEqual(.idle, fetch.state());

    // The mod is installed in the mods folder, with its checksum file.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive_url: [128]u8 = undefined;
    const alpha: Entry = .{ .id = "alpha", .size = archive.len, .archive = server.url(&archive_url, "/alpha.hog"), .digest = checksums.digest(archive), .repository = "test", .local = true };
    var install: Install = .{};
    defer install.deinit();
    try install.start(gpa, tmp.dir, alpha);
    try std.testing.expectEqual(.done, try testing.wait(&install));
    install.finish();
    try std.testing.expectEqual(.idle, install.state());
    const written = try tmp.dir.readFileAlloc(io, "mods/alpha.hog", gpa, .limited(1024));
    defer gpa.free(written);
    try std.testing.expectEqualStrings(archive, written);
    const checksum = try tmp.dir.readFileAlloc(io, "mods/alpha.hog.sha256", gpa, .limited(1024));
    defer gpa.free(checksum);
    try std.testing.expectEqual(checksums.digest(archive), (try checksums.digestOf(checksum, "alpha.hog")).?);
    // An archive that doesn't match the catalogue's digest isn't installed.
    var wrong = alpha;
    wrong.id = "wrong";
    wrong.size = "another archive".len;
    wrong.archive = server.url(&archive_url, "/wrong.hog");
    try install.start(gpa, tmp.dir, wrong);
    try std.testing.expectEqual(.failed, try testing.wait(&install));
    try std.testing.expectEqual(.checksum_mismatch, install.failure.?);
    install.finish();
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "mods/wrong.hog", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "mods/wrong.hog.part", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "mods/wrong.hog.sha256.part", .{}));
    // An archive that isn't the catalogue's size isn't installed either, whether the server says
    // so up front or more bytes arrive than the catalogue says.
    for ([_]u64{ archive.len + 1, 3 }) |size| {
        var sized = alpha;
        sized.size = size;
        try install.start(gpa, tmp.dir, sized);
        try std.testing.expectEqual(.failed, try testing.wait(&install));
        try std.testing.expectEqual(.wrong_size, install.failure.?);
        install.finish();
    }
    // A redirect to the archive is followed.
    var moved_entry = alpha;
    moved_entry.archive = server.url(&archive_url, "/moved");
    try install.start(gpa, tmp.dir, moved_entry);
    try std.testing.expectEqual(.done, try testing.wait(&install));
    install.finish();
    // A URL that can't be used fails at once, and so does a link to the player's machine from a
    // repository that isn't there.
    var unusable = alpha;
    unusable.archive = "ftp://example.invalid/alpha.hog";
    try install.start(gpa, tmp.dir, unusable);
    try std.testing.expectEqual(.failed, try testing.wait(&install));
    try std.testing.expectEqual(.bad_url, install.failure.?);
    install.finish();
    var remote = alpha;
    remote.local = false;
    try install.start(gpa, tmp.dir, remote);
    try std.testing.expectEqual(.failed, try testing.wait(&install));
    try std.testing.expectEqual(.refused_address, install.failure.?);
}
