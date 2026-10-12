//! The catalogue of mods on the web (`Catalogue`): the mods that the GET MODS screen
//! (`interface.mod_catalogue`) lists and installs. It is read from one or more repositories
//! (`Repositories`), each the URL of a `mods.json` index like the one the OpenReliant mods site
//! publishes, named in `starlancer.ini`. Each entry gives a mod's name in the `mods` folder, its
//! version, the OpenReliant version it needs, the URL of its archive, and the archive's SHA-256
//! digest and size. The mods of every repository are listed together; where two repositories list
//! the same id, the first one listed wins.
//!
//! Everything is downloaded over HTTPS (`secured`): a plain `http` link is changed to `https`
//! before the request, and so is each redirect, which `Answer.open` follows itself. Plain HTTP
//! never replaces HTTPS when HTTPS fails. Only a loopback address, such as a repository tried on
//! the player's own machine, is read over plain HTTP.
//!
//! `Fetch` downloads a file from the web into memory on another thread, up to a limit. The screen
//! uses it for the indexes and for the thumbnails. `Install` downloads a mod's archive into the
//! `mods` folder on another thread, stops as soon as more arrives than the catalogue's size, and
//! checks the archive against the catalogue's digest, which it writes next to the archive as the
//! archive's checksum file. The screen polls both once per frame, so the menus keep running during
//! a download. Both use one `std.http.Client` the screen owns: the client's connection pool is
//! protected by a lock, and each download makes its own request, so one client serves every
//! download at once.
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

/// The size of the buffers a response is read and an archive is written through.
const chunk_size = 64 * 1024;
/// The longest redirect location accepted, as GitHub's release downloads redirect. RFC 9110
/// recommends at least 8000 bytes.
const redirect_size = 8 * 1024;
/// How many redirects a download follows at most. GitHub's release downloads redirect once, to
/// another host.
const most_redirects = 5;
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

    /// Why a listed mod can't be an entry.
    pub const Skipped = error{ NoId, BadId, NoArchive, BadDigest, NoSize };

    /// The entry for the mod `listed` of the repository `repository`, if the index gives
    /// everything it needs: an id that can name a mod (`validId`), the archive's URL, its digest
    /// (`parseDigest`) and its size.
    fn from(listed: Listed, repository: []const u8) Skipped!Entry {
        const id = listed.id orelse return error.NoId;
        if (!validId(id)) return error.BadId;
        const archive = listed.archive orelse return error.NoArchive;
        const digest = parseDigest(listed.sha256 orelse return error.BadDigest) orelse return error.BadDigest;
        const size = listed.size orelse return error.NoSize;
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
    /// repository added before listed already: the first repository wins.
    pub fn add(catalogue: *Catalogue, repository: Repository, text: []const u8) ParseError!void {
        const arena = catalogue.arena.allocator();
        const index = std.json.parseFromSliceLeaky(Index, arena, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Malformed,
        };
        if (index.format > format) return error.NewerFormat;
        if (index.format < format) return error.UnknownFormat;
        const name = try arena.dupe(u8, repository.name);
        for (index.mods) |listed| {
            const entry = Entry.from(listed, name) catch |err| {
                log.warn("{s}: the mod '{s}' is skipped: {s}", .{ name, listed.id orelse "", Entry.reason(err) });
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

/// How far a download has got. The download thread writes it and the screen's thread reads it,
/// so the fields are atomic.
pub const Progress = struct {
    state: std.atomic.Value(State) = .init(.idle),
    received: std.atomic.Value(u64) = .init(0),
    /// The download's length: the catalogue's size for an archive, and for a fetch the content
    /// length the server announced, 0 until it is known or when the server compresses the file.
    total: std.atomic.Value(u64) = .init(0),

    pub const State = enum(u8) {
        /// Not started, or finished and already collected.
        idle,
        running,
        /// The download is complete; `finish` collects the result.
        done,
        /// The download failed; `failure` says why.
        failed,
    };

    /// The download's state.
    pub fn current(progress: *const Progress) State {
        return progress.state.load(.acquire);
    }

    /// The share of the download received so far, from 0 to 1; null when the length is unknown.
    pub fn fraction(progress: *const Progress) ?f32 {
        const total = progress.total.load(.monotonic);
        if (total == 0) return null;
        const received = progress.received.load(.monotonic);
        return @min(1, @as(f32, @floatFromInt(received)) / @as(f32, @floatFromInt(total)));
    }
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
    pub fn ofStart(err: (Allocator.Error || Io.ConcurrentError)) Failure {
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
            else => .cant_start,
        };
    }
};

/// The URL `uri` is requested at: `https` where it says `http`, unless its host is a loopback
/// address, which a repository tried on the player's own machine has. Fails for any other scheme,
/// such as `ws` or `ftp`, which the HTTP client would otherwise take.
fn secured(uri: std.Uri) error{UnsupportedUriScheme}!std.Uri {
    var secure = uri;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        secure.scheme = "https";
    } else if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) {
        secure.scheme = if (isLoopback(uri)) "http" else "https";
    } else return error.UnsupportedUriScheme;
    return secure;
}

/// Whether `uri` names the player's own machine: `localhost`, `127.0.0.1` or `::1`.
fn isLoopback(uri: std.Uri) bool {
    const host = uri.host orelse return false;
    var buffer: [64]u8 = undefined;
    const raw = host.toRaw(&buffer) catch return false;
    const name = std.mem.trim(u8, raw, "[]");
    return std.ascii.eqlIgnoreCase(name, "localhost") or std.mem.eql(u8, name, "127.0.0.1") or std.mem.eql(u8, name, "::1");
}

/// A request the server answered with OK, whose body `reader` reads. It is made in place, since
/// the response points into the request.
const Answer = struct {
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
    /// location made `secured`. Besides the client's and the URL parser's errors, fails with
    /// `error.NotFound` for a 404, `error.ServerRefused` for any other status than OK,
    /// `error.TooManyRedirects`, and `error.RedirectWithoutLocation`, `error.RedirectTooLong` or
    /// `error.BadRedirect` for a redirect that can't be followed.
    fn open(answer: *Answer, gpa: Allocator, client: *std.http.Client, url: []const u8) !void {
        answer.gpa = gpa;
        answer.decompress_buffer = &.{};
        var uri = try secured(try std.Uri.parse(url));
        var hops: usize = 0;
        while (true) : (hops += 1) {
            answer.request = try client.request(.GET, uri, .{ .redirect_behavior = .unhandled });
            errdefer answer.request.deinit();
            try answer.request.sendBodiless();
            answer.response = try answer.request.receiveHead(&.{});
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
            const resolved = uri.resolveInPlace(location.len, &aux) catch |err| switch (err) {
                error.NoSpaceLeft => return error.RedirectTooLong,
                else => return error.BadRedirect,
            };
            uri = try secured(resolved);
            log.debug("{s} redirects to {f}", .{ url, uri });
            answer.request.deinit();
        }
    }

    /// The length the server announced for the body, where it isn't compressed; null otherwise.
    fn length(answer: *const Answer) ?u64 {
        const head = &answer.response.head;
        return if (head.content_encoding == .identity) head.content_length else null;
    }

    /// The body, decompressed if the server compressed it. Fails with
    /// `error.UnsupportedCompressionMethod` for a compression that can't be read.
    fn reader(answer: *Answer) !*Io.Reader {
        const head = &answer.response.head;
        answer.decompress_buffer = switch (head.content_encoding) {
            .identity => &.{},
            .zstd => try answer.gpa.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try answer.gpa.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        return answer.response.readerDecompressing(&answer.transfer_buffer, &answer.decompress, answer.decompress_buffer);
    }

    /// The error the body's reading failed with, where the reader said `error.ReadFailed`: the
    /// body's, else the connection's.
    fn bodyError(answer: *const Answer) anyerror {
        if (answer.response.bodyErr()) |err| return err;
        if (answer.request.connection) |connection| if (connection.getReadError()) |err| return err;
        return error.ReadFailed;
    }

    fn deinit(answer: *Answer) void {
        answer.gpa.free(answer.decompress_buffer);
        answer.request.deinit();
        answer.* = undefined;
    }
};

/// A download of a file from the web into memory, on another thread: an index, or a thumbnail.
/// A new `Fetch` (`.{}`) is idle until `start`.
pub const Fetch = struct {
    /// What the download runs with, from `start` until the fetch is idle again.
    job: ?Job = null,
    group: Io.Group = .init,
    progress: Progress = .{},
    /// The bytes received, once the download is done; freed by `finish` or `deinit`.
    bytes: std.ArrayList(u8) = .empty,
    /// Why the download failed, once it has.
    failure: ?Failure = null,

    const Job = struct {
        gpa: Allocator,
        io: Io,
        client: *std.http.Client,
        url: []u8,
        /// The most bytes accepted; a longer file fails the download.
        limit: usize,
    };

    /// Starts downloading `url` with `client`, accepting at most `limit` bytes. The fetch must be
    /// idle.
    pub fn start(fetch: *Fetch, gpa: Allocator, io: Io, client: *std.http.Client, url: []const u8, limit: usize) (Allocator.Error || Io.ConcurrentError)!void {
        std.debug.assert(fetch.state() == .idle);
        const copied = try gpa.dupe(u8, url);
        errdefer gpa.free(copied);
        fetch.* = .{ .job = .{ .gpa = gpa, .io = io, .client = client, .url = copied, .limit = limit } };
        fetch.progress.state.store(.running, .release);
        fetch.group.concurrent(io, run, .{fetch}) catch |err| {
            fetch.progress.state.store(.idle, .release);
            fetch.job = null;
            return err;
        };
    }

    /// The download's state.
    pub fn state(fetch: *const Fetch) Progress.State {
        return fetch.progress.current();
    }

    /// The download thread: downloads the file, then sets the final state.
    fn run(fetch: *Fetch) Io.Cancelable!void {
        const job = fetch.job.?;
        fetch.receive(job) catch |err| {
            log.warn("can't download {s}: {s}", .{ job.url, @errorName(err) });
            fetch.failure = .of(err);
            fetch.progress.state.store(.failed, .release);
            return;
        };
        fetch.progress.state.store(.done, .release);
    }

    /// Downloads the file into `bytes`, up to the job's limit (`error.StreamTooLong` past it).
    fn receive(fetch: *Fetch, job: Job) !void {
        var answer: Answer = undefined;
        try answer.open(job.gpa, job.client, job.url);
        defer answer.deinit();
        if (answer.length()) |length| {
            if (length > job.limit) return error.StreamTooLong;
            fetch.progress.total.store(length, .monotonic);
        }
        const reader = try answer.reader();
        // The reader's limit is exclusive: one more accepts a file of exactly the limit's size.
        reader.appendRemaining(job.gpa, &fetch.bytes, .limited(job.limit + 1)) catch |err| switch (err) {
            error.ReadFailed => return answer.bodyError(),
            else => |other| return other,
        };
        fetch.progress.received.store(fetch.bytes.items.len, .monotonic);
    }

    /// Returns the downloaded bytes once the download is done; the caller frees them with the
    /// allocator `start` was given. Returns null while the download runs, if it failed, or if there
    /// is no memory for the copy. Afterwards the fetch is idle and can be started again.
    pub fn finish(fetch: *Fetch) ?[]u8 {
        if (fetch.state() != .done) return null;
        const job = fetch.job.?;
        fetch.group.await(job.io) catch {};
        const bytes = fetch.bytes.toOwnedSlice(job.gpa) catch null;
        fetch.release();
        return bytes;
    }

    /// Cancels the download if it runs, and frees what the fetch holds. A download that runs stops
    /// at its next read, so this waits for at most one chunk.
    pub fn deinit(fetch: *Fetch) void {
        const job = fetch.job orelse return;
        fetch.group.cancel(job.io);
        fetch.release();
    }

    fn release(fetch: *Fetch) void {
        const job = fetch.job.?;
        fetch.bytes.deinit(job.gpa);
        job.gpa.free(job.url);
        fetch.* = .{};
    }
};

/// A download of a mod's archive into the `mods` folder, on another thread. The archive is saved
/// as `<id>.hog` once it is complete, is the catalogue's size and matches the catalogue's digest,
/// with the digest written next to it as `<id>.hog.sha256`.
pub const Install = struct {
    /// What the download runs with, from `start` until the install is idle again.
    job: ?Job = null,
    group: Io.Group = .init,
    progress: Progress = .{},
    /// Why the download failed, once it has.
    failure: ?Failure = null,

    const Job = struct {
        gpa: Allocator,
        io: Io,
        client: *std.http.Client,
        /// The game folder; the archive goes into its `mods` folder.
        game: Io.Dir,
        id: []u8,
        archive_url: []u8,
        digest: checksums.Digest,
        size: u64,
    };

    /// Starts installing `entry` with `client`. The install must be idle.
    pub fn start(install: *Install, gpa: Allocator, io: Io, client: *std.http.Client, game: Io.Dir, entry: Entry) (Allocator.Error || Io.ConcurrentError)!void {
        std.debug.assert(install.state() == .idle);
        const id = try gpa.dupe(u8, entry.id);
        errdefer gpa.free(id);
        const archive_url = try gpa.dupe(u8, entry.archive);
        errdefer gpa.free(archive_url);
        install.* = .{ .job = .{ .gpa = gpa, .io = io, .client = client, .game = game, .id = id, .archive_url = archive_url, .digest = entry.digest, .size = entry.size } };
        install.progress.total.store(entry.size, .monotonic);
        install.progress.state.store(.running, .release);
        install.group.concurrent(io, run, .{install}) catch |err| {
            install.progress.state.store(.idle, .release);
            install.job = null;
            return err;
        };
    }

    /// The download's state.
    pub fn state(install: *const Install) Progress.State {
        return install.progress.current();
    }

    /// The download thread: downloads the archive, then sets the final state.
    fn run(install: *Install) Io.Cancelable!void {
        const job = install.job.?;
        install.work(job) catch |err| {
            log.warn("can't install the mod {s}: {s}", .{ job.id, @errorName(err) });
            install.failure = .of(err);
            install.progress.state.store(.failed, .release);
            return;
        };
        log.info("installed the mod {s} in the mods folder", .{job.id});
        install.progress.state.store(.done, .release);
    }

    /// Downloads the archive into its part file, hashing the bytes on their way, and stops with
    /// `error.WrongSize` as soon as more arrives than the catalogue's size, or when the server
    /// announces another size. Then puts the archive in place (`ArchiveSink.place`).
    fn work(install: *Install, job: Job) !void {
        const io = job.io;
        var name_buffer: [files.max_path]u8 = undefined;
        const archive_name = try archiveNameOf(job.id, &name_buffer);
        var answer: Answer = undefined;
        try answer.open(job.gpa, job.client, job.archive_url);
        defer answer.deinit();
        if (answer.length()) |length| if (length != job.size) return error.WrongSize;
        var folder = try modsFolder(io, job.game);
        defer folder.close(io);
        var sink: ArchiveSink = undefined;
        try sink.open(io, folder, archive_name);
        errdefer sink.abandon();
        const reader = try answer.reader();
        var received: u64 = 0;
        while (true) {
            const read = reader.stream(sink.writer(), .limited(chunk_size)) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return answer.bodyError(),
                error.WriteFailed => return error.CantWrite,
            };
            received += read;
            if (received > job.size) return error.WrongSize;
            install.progress.received.store(received, .monotonic);
        }
        if (received != job.size) return error.WrongSize;
        try sink.place(job.digest);
    }

    /// Waits for the thread to end, once the download is done or has failed, and frees what the
    /// install holds. Afterwards the install is idle and can be started again.
    pub fn finish(install: *Install) void {
        switch (install.state()) {
            .idle, .running => return,
            .done, .failed => {},
        }
        const job = install.job.?;
        install.group.await(job.io) catch {};
        install.release();
    }

    /// Cancels the download if it runs, and frees what the install holds. A download that runs
    /// stops at its next read, so this waits for at most one chunk, and the part file is deleted.
    pub fn deinit(install: *Install) void {
        const job = install.job orelse return;
        install.group.cancel(job.io);
        install.release();
    }

    fn release(install: *Install) void {
        const job = install.job.?;
        job.gpa.free(job.id);
        job.gpa.free(job.archive_url);
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
    file_buffer: [chunk_size]u8,
    hashed: Io.Writer.Hashed(Sha256),
    hash_buffer: [chunk_size]u8,

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
    try std.testing.expectEqual(.cant_start, Failure.ofStart(error.ConcurrencyUnavailable));
}

test "every address is requested over HTTPS, but a loopback one" {
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
        const uri = try secured(try std.Uri.parse(case.url));
        try std.testing.expectEqualStrings(case.scheme, uri.scheme);
    }
    try std.testing.expectError(error.UnsupportedUriScheme, secured(try std.Uri.parse("ws://127.0.0.1/mods.json")));
    try std.testing.expectError(error.UnsupportedUriScheme, secured(try std.Uri.parse("ftp://example.com/mods.json")));
    try std.testing.expectError(error.UnsupportedUriScheme, secured(try std.Uri.parse("file:///mods.json")));
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

        /// A file the server serves at `path`: its body and status, and for a redirect, where to.
        pub const File = struct { path: []const u8, body: []const u8, status: std.http.Status = .ok, location: ?[]const u8 = null };

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
                var in_buffer: [redirect_size]u8 = undefined;
                var out_buffer: [redirect_size]u8 = undefined;
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
                    const headers: []const std.http.Header = if (file.location) |location| &.{.{ .name = "location", .value = location }} else &.{};
                    request.respond(file.body, .{ .status = file.status, .keep_alive = false, .extra_headers = headers }) catch {};
                } else {
                    request.respond("not here", .{ .status = .not_found, .keep_alive = false }) catch {};
                }
            }
        }

        /// Stops the server and waits for its thread: asks it for `/stop`, or closes its socket if
        /// that can't be asked, then closes the socket.
        pub fn stop(server: *Server, gpa: Allocator, client: *std.http.Client) void {
            const io = server.io;
            var buffer: [128]u8 = undefined;
            var fetch: Fetch = .{};
            defer fetch.deinit();
            const asked = if (fetch.start(gpa, io, client, server.url(&buffer, "/stop"), 1024)) |_| asked: {
                fetch.group.await(io) catch {};
                break :asked fetch.state() == .done;
            } else |_| false;
            if (!asked) {
                server.listening.?.deinit(io);
                server.listening = null;
            }
            server.group.await(io) catch {};
            if (server.listening) |*listening| listening.deinit(io);
            server.listening = null;
        }
    };
};

test "the catalogue and a mod download from the web, and the archive is checked on install" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
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
    });
    defer server.stop(gpa, &client);
    var buffer: [128]u8 = undefined;

    // The index downloads and parses as a catalogue.
    var fetch: Fetch = .{};
    defer fetch.deinit();
    try fetch.start(gpa, io, &client, server.url(&buffer, "/mods.json"), most_index_bytes);
    try fetch.group.await(io);
    try std.testing.expectEqual(.done, fetch.state());
    try std.testing.expectEqual(index.len, fetch.progress.received.load(.monotonic));
    const bytes = fetch.finish().?;
    defer gpa.free(bytes);
    var read: Catalogue = .init(gpa);
    defer read.deinit();
    try read.add(test_repository, bytes);
    try std.testing.expectEqual(1, read.entries().len);
    try std.testing.expectEqual(.idle, fetch.state());
    // A missing file fails with not found, a server error with a refusal, and a file over the
    // limit as too large.
    try fetch.start(gpa, io, &client, server.url(&buffer, "/missing.json"), most_index_bytes);
    try fetch.group.await(io);
    try std.testing.expectEqual(.failed, fetch.state());
    try std.testing.expectEqual(.not_found, fetch.failure.?);
    fetch.deinit();
    try fetch.start(gpa, io, &client, server.url(&buffer, "/broken.json"), most_index_bytes);
    try fetch.group.await(io);
    try std.testing.expectEqual(.server_refused, fetch.failure.?);
    fetch.deinit();
    try fetch.start(gpa, io, &client, server.url(&buffer, "/alpha.hog"), archive.len - 1);
    try fetch.group.await(io);
    try std.testing.expectEqual(.too_large, fetch.failure.?);
    fetch.deinit();
    // A file of exactly the limit's size is accepted.
    try fetch.start(gpa, io, &client, server.url(&buffer, "/alpha.hog"), archive.len);
    try fetch.group.await(io);
    try std.testing.expectEqual(.done, fetch.state());
    fetch.deinit();
    // A redirect is followed to its file; too many, one without a location, and one to a scheme
    // the downloads refuse each fail in their own way.
    try fetch.start(gpa, io, &client, server.url(&buffer, "/moved"), most_index_bytes);
    try fetch.group.await(io);
    try std.testing.expectEqual(.done, fetch.state());
    const moved = fetch.finish().?;
    defer gpa.free(moved);
    try std.testing.expectEqualStrings(archive, moved);
    try fetch.start(gpa, io, &client, server.url(&buffer, "/loop"), most_index_bytes);
    try fetch.group.await(io);
    try std.testing.expectEqual(.too_many_redirects, fetch.failure.?);
    fetch.deinit();
    try fetch.start(gpa, io, &client, server.url(&buffer, "/nowhere"), most_index_bytes);
    try fetch.group.await(io);
    try std.testing.expectEqual(.bad_redirect, fetch.failure.?);
    fetch.deinit();
    try fetch.start(gpa, io, &client, server.url(&buffer, "/elsewhere"), most_index_bytes);
    try fetch.group.await(io);
    try std.testing.expectEqual(.bad_url, fetch.failure.?);
    fetch.deinit();

    // The mod is installed in the mods folder, with its checksum file.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive_url: [128]u8 = undefined;
    const alpha: Entry = .{ .id = "alpha", .size = archive.len, .archive = server.url(&archive_url, "/alpha.hog"), .digest = checksums.digest(archive), .repository = "test" };
    var install: Install = .{};
    defer install.deinit();
    try install.start(gpa, io, &client, tmp.dir, alpha);
    try install.group.await(io);
    try std.testing.expectEqual(.done, install.state());
    try std.testing.expectEqual(archive.len, install.progress.received.load(.monotonic));
    try std.testing.expectEqual(1, install.progress.fraction().?);
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
    try install.start(gpa, io, &client, tmp.dir, wrong);
    try install.group.await(io);
    try std.testing.expectEqual(.failed, install.state());
    try std.testing.expectEqual(.checksum_mismatch, install.failure.?);
    install.finish();
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "mods/wrong.hog", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "mods/wrong.hog.part", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "mods/wrong.hog.sha256.part", .{}));
    // An archive that isn't the catalogue's size isn't installed either, whether the server says
    // so up front or more bytes arrive than the catalogue says.
    var sized = alpha;
    sized.size = archive.len + 1;
    try install.start(gpa, io, &client, tmp.dir, sized);
    try install.group.await(io);
    try std.testing.expectEqual(.wrong_size, install.failure.?);
    install.finish();
    sized.size = 3;
    try install.start(gpa, io, &client, tmp.dir, sized);
    try install.group.await(io);
    try std.testing.expectEqual(.wrong_size, install.failure.?);
    install.finish();
    // A redirect to the archive is followed.
    var moved_entry = alpha;
    moved_entry.archive = server.url(&archive_url, "/moved");
    try install.start(gpa, io, &client, tmp.dir, moved_entry);
    try install.group.await(io);
    try std.testing.expectEqual(.done, install.state());
    install.finish();
    // A URL that can't be used fails at once.
    var unusable = alpha;
    unusable.archive = "ftp://example.invalid/alpha.hog";
    try install.start(gpa, io, &client, tmp.dir, unusable);
    try install.group.await(io);
    try std.testing.expectEqual(.bad_url, install.failure.?);
}
