//! Matroska and WebM files, in which mods give movies in place of the game's Bink files
//! ([#1179](https://github.com/OpenReliant/openreliant/issues/1179)). WebM files are Matroska files
//! that hold only a few codecs. A file is a tree of EBML elements (RFC 8794): each has an ID, the
//! size of its data, and its data, which holds a value or more elements. The file's segment holds
//! its tracks and its clusters, and each cluster holds blocks of the tracks' frames, each block
//! with its time (RFC 9559). OpenReliant reads the tracks and the blocks here, and hands the frames
//! of the first video track and the first audio track to FFmpeg's decoders.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ogg = @import("ogg.zig");

/// The extensions of Matroska files, and of WebM files.
pub const extension = ".mkv";
pub const webm_extension = ".webm";

pub const Error = error{
    /// It isn't an EBML file of the Matroska or WebM type.
    NotMatroska,
    /// An element runs past the element that holds it, or a number in it is malformed.
    BadElement,
    /// It has no video track.
    NoVideo,
    /// Its first video track has no frames, or its first frame isn't a key frame.
    NoFrames,
    /// Its first video or audio track's data is compressed or encrypted (`ContentEncodings`).
    Encoded,
} || Allocator.Error;

/// The IDs of the elements OpenReliant reads, with the bits that mark their length, as the
/// specifications write them.
pub const Id = enum(u32) {
    ebml = 0x1A45DFA3,
    doc_type = 0x4282,
    segment = 0x18538067,
    seek_head = 0x114D9B74,
    info = 0x1549A966,
    timestamp_scale = 0x2AD7B1,
    tracks = 0x1654AE6B,
    track_entry = 0xAE,
    track_number = 0xD7,
    track_type = 0x83,
    flag_enabled = 0xB9,
    codec_id = 0x86,
    codec_private = 0x63A2,
    content_encodings = 0x6D80,
    video = 0xE0,
    pixel_width = 0xB0,
    pixel_height = 0xBA,
    audio = 0xE1,
    sampling_frequency = 0xB5,
    channels = 0x9F,
    cluster = 0x1F43B675,
    timestamp = 0xE7,
    simple_block = 0xA3,
    block_group = 0xA0,
    block = 0xA1,
    reference_block = 0xFB,
    cues = 0x1C53BB6B,
    chapters = 0x1043A770,
    tags = 0x1254C367,
    attachments = 0x1941A469,
    _,

    /// Whether it is one of the segment's own elements, which end a cluster of unknown size.
    fn inSegment(id: Id) bool {
        return switch (id) {
            .seek_head, .info, .tracks, .cluster, .cues, .chapters, .tags, .attachments => true,
            else => false,
        };
    }
};

/// The document types of Matroska files and of WebM files.
const doc_types = [_][]const u8{ "matroska", "webm" };

/// The time that a cluster's timestamp and a block's are counted in, unless the segment's
/// information gives another: a millisecond, in nanoseconds.
const default_timestamp_scale = 1_000_000;

/// A movie's file read: its first video track and that track's frames, and its first audio track
/// and that track's packets, each pointing into the file's bytes.
pub const Movie = struct {
    video: Video,
    frames: []Frame,
    audio: ?Audio,
    packets: []const []const u8,

    /// Reads the file `bytes`, which must outlive the movie.
    pub fn parse(gpa: Allocator, bytes: []const u8) Error!Movie {
        if (!isEbml(bytes)) return error.NotMatroska;
        var top: Elements = .{ .bytes = bytes };
        const header = try top.next() orelse return error.NotMatroska;
        if (header.id != .ebml or !isMatroska(header.data)) return error.NotMatroska;
        const segment = while (try top.next()) |element| {
            if (element.id == .segment) break element;
        } else return error.NotMatroska;
        var read: Tracks = .{};
        var scale: u64 = default_timestamp_scale;
        var children: Elements = .{ .bytes = segment.data };
        while (try children.next()) |element| switch (element.id) {
            .info => scale = try timestampScale(element.data),
            .tracks => try read.add(element.data),
            else => {},
        };
        const video = read.video orelse return error.NoVideo;
        if (video.encoded or (read.audio != null and read.audio.?.encoded)) return error.Encoded;

        var frames: std.ArrayList(Frame) = .empty;
        defer frames.deinit(gpa);
        var packets: std.ArrayList([]const u8) = .empty;
        defer packets.deinit(gpa);
        children = .{ .bytes = segment.data };
        while (try children.next()) |element| {
            if (element.id != .cluster) continue;
            try readCluster(gpa, element.data, scale, .{
                .video = video.number,
                .audio = if (read.audio) |audio| audio.number else null,
                .frames = &frames,
                .packets = &packets,
            });
        }
        if (frames.items.len == 0 or !frames.items[0].keyframe) return error.NoFrames;
        return .{
            .video = .{ .codec = .of(video.codec_id), .width = video.width, .height = video.height },
            .frames = try frames.toOwnedSlice(gpa),
            .audio = if (read.audio) |audio| .{
                .codec = .of(audio.codec_id),
                .setup = audio.private,
                .rate = audio.rate,
                .channels = audio.channels,
            } else null,
            .packets = try packets.toOwnedSlice(gpa),
        };
    }

    pub fn deinit(movie: *Movie, gpa: Allocator) void {
        gpa.free(movie.frames);
        gpa.free(movie.packets);
        movie.* = undefined;
    }
};

/// Whether `bytes` start as an EBML file does.
pub fn isEbml(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, &std.mem.toBytes(std.mem.nativeToBig(u32, @backingInt(Id.ebml))));
}

/// A video track: its codec and its size in pixels.
pub const Video = struct {
    codec: VideoCodec,
    width: u32,
    height: u32,
};

/// A video track's codec, where OpenReliant decodes it, or else the ID the file gives it.
pub const VideoCodec = union(enum) {
    vp9,
    other: []const u8,

    fn of(id: []const u8) VideoCodec {
        return if (std.mem.eql(u8, id, "V_VP9")) .vp9 else .{ .other = id };
    }
};

/// An audio track: its codec, its codec's headers (`CodecPrivate`), and its rate and channels.
/// Opus's headers are its identification header, and Vorbis's its three headers laced together,
/// as an Ogg stream's give them to the decoders (`ogg.Stream.setup`).
pub const Audio = struct {
    codec: AudioCodec,
    setup: []const u8,
    /// Samples per second, as the track gives it. Opus always decodes at `ogg.opus_rate`.
    rate: f64,
    channels: u8,
};

/// An audio track's codec, where OpenReliant decodes it, or else the ID the file gives it.
pub const AudioCodec = union(enum) {
    opus,
    vorbis,
    other: []const u8,

    fn of(id: []const u8) AudioCodec {
        if (std.mem.eql(u8, id, "A_OPUS")) return .opus;
        if (std.mem.eql(u8, id, "A_VORBIS")) return .vorbis;
        return .{ .other = id };
    }
};

/// A frame of a video track: its coded data, when it shows, in nanoseconds from the time the
/// file's timestamps count from, and whether it is a key frame, which decodes without the frames
/// before it.
pub const Frame = struct {
    data: []const u8,
    time: i64,
    keyframe: bool,
};

/// Whether the EBML header's data `header` names a Matroska or WebM document; a header without
/// a document type is Matroska's.
fn isMatroska(header: []const u8) bool {
    var children: Elements = .{ .bytes = header };
    while (children.next() catch return false) |element| {
        if (element.id != .doc_type) continue;
        const doc_type = std.mem.trimEnd(u8, element.data, "\x00");
        for (doc_types) |known| if (std.mem.eql(u8, doc_type, known)) return true;
        return false;
    }
    return true;
}

/// The segment information's timestamp scale, the nanoseconds each tick of a timestamp lasts.
fn timestampScale(info: []const u8) Error!u64 {
    var children: Elements = .{ .bytes = info };
    while (try children.next()) |element| {
        if (element.id != .timestamp_scale) continue;
        const scale = try unsigned(element.data);
        return if (scale == 0) error.BadElement else scale;
    }
    return default_timestamp_scale;
}

/// A track's entry, as far as OpenReliant reads it.
const TrackEntry = struct {
    number: u64 = 0,
    kind: u64 = 0,
    enabled: bool = true,
    codec_id: []const u8 = "",
    private: []const u8 = "",
    encoded: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    rate: f64 = default_rate,
    channels: u8 = 1,

    /// The track types of video and of audio (`TrackType`).
    const video_type = 1;
    const audio_type = 2;

    /// The rate and channels an audio track has unless it gives its own.
    const default_rate = 8000;

    /// Reads the track's entry `data`.
    fn read(data: []const u8) Error!TrackEntry {
        var entry: TrackEntry = .{};
        var children: Elements = .{ .bytes = data };
        while (try children.next()) |element| switch (element.id) {
            .track_number => entry.number = try unsigned(element.data),
            .track_type => entry.kind = try unsigned(element.data),
            .flag_enabled => entry.enabled = try unsigned(element.data) != 0,
            .codec_id => entry.codec_id = std.mem.trimEnd(u8, element.data, "\x00"),
            .codec_private => entry.private = element.data,
            .content_encodings => entry.encoded = true,
            .video => try entry.readVideo(element.data),
            .audio => try entry.readAudio(element.data),
            else => {},
        };
        return entry;
    }

    fn readVideo(entry: *TrackEntry, data: []const u8) Error!void {
        var children: Elements = .{ .bytes = data };
        while (try children.next()) |element| switch (element.id) {
            .pixel_width => entry.width = std.math.cast(u32, try unsigned(element.data)) orelse return error.BadElement,
            .pixel_height => entry.height = std.math.cast(u32, try unsigned(element.data)) orelse return error.BadElement,
            else => {},
        };
    }

    fn readAudio(entry: *TrackEntry, data: []const u8) Error!void {
        var children: Elements = .{ .bytes = data };
        while (try children.next()) |element| switch (element.id) {
            .sampling_frequency => entry.rate = try float(element.data),
            .channels => entry.channels = std.math.cast(u8, try unsigned(element.data)) orelse return error.BadElement,
            else => {},
        };
    }
};

/// The first enabled video track and audio track of a file's track entries.
const Tracks = struct {
    video: ?TrackEntry = null,
    audio: ?TrackEntry = null,

    /// Reads the track entries in `tracks`, the data of a `Tracks` element.
    fn add(found: *Tracks, tracks: []const u8) Error!void {
        var children: Elements = .{ .bytes = tracks };
        while (try children.next()) |element| {
            if (element.id != .track_entry) continue;
            const entry: TrackEntry = try .read(element.data);
            if (!entry.enabled or entry.number == 0) continue;
            switch (entry.kind) {
                TrackEntry.video_type => if (found.video == null) {
                    if (entry.width == 0 or entry.height == 0) return error.BadElement;
                    found.video = entry;
                },
                TrackEntry.audio_type => if (found.audio == null) {
                    if (entry.channels == 0 or !(entry.rate > 0)) return error.BadElement;
                    found.audio = entry;
                },
                else => {},
            }
        }
    }
};

/// Where a cluster's blocks go: the tracks they belong to, and the lists of their frames.
const Wanted = struct {
    video: u64,
    audio: ?u64,
    frames: *std.ArrayList(Frame),
    packets: *std.ArrayList([]const u8),
};

/// Reads the blocks of the cluster `data`, with the timestamps counted in ticks of `scale`
/// nanoseconds, into the lists `wanted` gives.
fn readCluster(gpa: Allocator, data: []const u8, scale: u64, wanted: Wanted) Error!void {
    var start: u64 = 0;
    var children: Elements = .{ .bytes = data };
    while (try children.next()) |element| switch (element.id) {
        .timestamp => start = try unsigned(element.data),
        .simple_block => try readBlock(gpa, element.data, null, start, scale, wanted),
        .block_group => {
            var block: ?[]const u8 = null;
            var referenced = false;
            var parts: Elements = .{ .bytes = element.data };
            while (try parts.next()) |part| switch (part.id) {
                .block => block = part.data,
                .reference_block => referenced = true,
                else => {},
            };
            // A block of a group is a key frame where it refers to no other.
            if (block) |found| try readBlock(gpa, found, !referenced, start, scale, wanted);
        },
        else => {},
    };
}

/// The flags of a block's header. A simple block's sets `keyframe`; a block of a group leaves it
/// clear, and says so with a `ReferenceBlock` beside it.
const BlockFlags = packed struct(u8) {
    discardable: bool,
    lacing: Lacing,
    invisible: bool,
    _reserved: u3,
    keyframe: bool,
};

/// How a block holds more than one frame.
const Lacing = enum(u2) {
    none = 0,
    xiph = 1,
    fixed = 2,
    ebml = 3,
};

/// Reads the block `data`, which belongs to the cluster that starts at `start` ticks of `scale`
/// nanoseconds, into the lists `wanted` gives, where it belongs to one of their tracks. A simple
/// block says itself whether it is a key frame; a block of a group is one as `keyframe` says.
fn readBlock(gpa: Allocator, data: []const u8, keyframe: ?bool, start: u64, scale: u64, wanted: Wanted) Error!void {
    const track = try readVint(data, 0, .size);
    if (track.unknown) return error.BadElement;
    const after = track.length;
    if (data.len < after + 3) return error.BadElement;
    const relative = std.mem.readInt(i16, data[after..][0..2], .big);
    const flags: BlockFlags = @bitCast(data[after + 2]);
    const payload = data[after + 3 ..];
    const ticks = @as(i128, start) + relative;
    const time = std.math.cast(i64, ticks * scale) orelse return error.BadElement;
    if (track.value == wanted.video) {
        var laced: std.ArrayList([]const u8) = .empty;
        defer laced.deinit(gpa);
        try unlace(gpa, &laced, flags.lacing, payload);
        for (laced.items) |frame| try wanted.frames.append(gpa, .{
            .data = frame,
            .time = time,
            .keyframe = keyframe orelse flags.keyframe,
        });
    } else if (wanted.audio == track.value) {
        try unlace(gpa, wanted.packets, flags.lacing, payload);
    }
}

/// Appends the frames of a block's `payload`, laced as `lacing` says, to `out`.
fn unlace(gpa: Allocator, out: *std.ArrayList([]const u8), lacing: Lacing, payload: []const u8) Error!void {
    if (lacing == .none) return out.append(gpa, payload);
    if (payload.len == 0) return error.BadElement;
    const count = @as(usize, payload[0]) + 1;
    var at: usize = 1;
    const sizes = try gpa.alloc(usize, count);
    defer gpa.free(sizes);
    switch (lacing) {
        .none => unreachable,
        // Each size but the last as bytes added up, where a byte of 255 carries on into the next
        // byte and any other ends the size.
        .xiph => for (sizes[0 .. count - 1]) |*size| {
            size.* = 0;
            while (true) {
                if (at >= payload.len) return error.BadElement;
                const byte = payload[at];
                at += 1;
                size.* += byte;
                if (byte != 255) break;
            }
        },
        // The first size as a number, and each after it as how much it differs from the one
        // before.
        .ebml => if (count > 1) {
            const first = try readVint(payload, at, .size);
            if (first.unknown) return error.BadElement;
            at += first.length;
            sizes[0] = std.math.cast(usize, first.value) orelse return error.BadElement;
            for (sizes[1 .. count - 1], sizes[0 .. count - 2]) |*size, before| {
                const difference = try readVint(payload, at, .signed);
                at += difference.length;
                const signed = @as(i128, before) + difference.signedValue();
                size.* = std.math.cast(usize, signed) orelse return error.BadElement;
            }
        },
        // As many frames of one size, which the rest divides into evenly.
        .fixed => {
            const rest = payload.len - at;
            if (rest % count != 0) return error.BadElement;
            @memset(sizes, rest / count);
        },
    }
    var used: usize = 0;
    for (sizes[0 .. count - 1]) |size| used = std.math.add(usize, used, size) catch return error.BadElement;
    if (used > payload.len - at) return error.BadElement;
    if (lacing != .fixed) sizes[count - 1] = payload.len - at - used;
    for (sizes) |size| {
        if (size > payload.len - at) return error.BadElement;
        try out.append(gpa, payload[at..][0..size]);
        at += size;
    }
}

/// An element: its ID and its data.
const Element = struct {
    id: Id,
    data: []const u8,
};

/// The elements of an element's data, or of a file, one after another. An element whose size is
/// unknown, as in a file written as a stream, runs to the end of the data that holds it; a cluster
/// whose size is unknown ends where one of the segment's own elements begins (`Id.inSegment`).
const Elements = struct {
    bytes: []const u8,
    at: usize = 0,

    fn next(elements: *Elements) Error!?Element {
        const bytes = elements.bytes;
        if (elements.at >= bytes.len) return null;
        const id = try readVint(bytes, elements.at, .id);
        const size = try readVint(bytes, elements.at + id.length, .size);
        const start = elements.at + id.length + size.length;
        const element_id: Id = @fromBackingInt(@as(u32, @intCast(id.value)));
        const end = if (size.unknown)
            if (element_id == .cluster) clusterEnd(bytes, start) else bytes.len
        else if (size.value <= bytes.len - start) start + @as(usize, @intCast(size.value)) else return error.BadElement;
        elements.at = end;
        return .{ .id = element_id, .data = bytes[start..end] };
    }
};

/// Where a cluster of unknown size that starts its data at `start` in `bytes` ends: at the first of
/// its elements that is one of the segment's own instead, or at the end.
fn clusterEnd(bytes: []const u8, start: usize) usize {
    var children: Elements = .{ .bytes = bytes, .at = start };
    while (true) {
        const before = children.at;
        const element = (children.next() catch return bytes.len) orelse return bytes.len;
        if (element.id.inSegment()) return before;
    }
}

/// How an EBML number of variable length is read (RFC 8794, 4): an ID keeps the bits that mark its
/// length, a size drops them, and a signed number is a size less half its range.
const VintKind = enum { id, size, signed };

/// An EBML number of variable length: its first byte's leading zeros, plus one, give its length.
const Vint = struct {
    value: u64,
    length: usize,
    /// For a size, whether every bit of its value is set, which leaves the size unknown.
    unknown: bool = false,

    /// The value of a signed number: its value as a size less `2^(7n-1) - 1`, for a number of `n`
    /// bytes.
    fn signedValue(vint: Vint) i128 {
        const half = (@as(i128, 1) << @intCast(7 * vint.length - 1)) - 1;
        return @as(i128, vint.value) - half;
    }
};

/// The EBML number at `at` in `bytes`, read as `kind` says. An ID has at most 4 bytes, a size at
/// most 8.
fn readVint(bytes: []const u8, at: usize, kind: VintKind) Error!Vint {
    if (at >= bytes.len) return error.BadElement;
    const first = bytes[at];
    if (first == 0) return error.BadElement;
    const length: usize = @as(usize, @clz(first)) + 1;
    if (kind == .id and length > 4) return error.BadElement;
    if (bytes.len - at < length) return error.BadElement;
    var value: u64 = 0;
    for (bytes[at..][0..length]) |byte| value = value << 8 | byte;
    if (kind == .id) return .{ .value = value, .length = length };
    const bits: u6 = @intCast(7 * length);
    const mask = (@as(u64, 1) << bits) - 1;
    value &= mask;
    return .{ .value = value, .length = length, .unknown = kind == .size and value == mask };
}

/// The unsigned integer `data` holds, big-endian, in up to 8 bytes.
fn unsigned(data: []const u8) Error!u64 {
    if (data.len > 8) return error.BadElement;
    var value: u64 = 0;
    for (data) |byte| value = value << 8 | byte;
    return value;
}

/// The float `data` holds, big-endian, in 4 or 8 bytes, or 0 in none.
fn float(data: []const u8) Error!f64 {
    return switch (data.len) {
        0 => 0,
        4 => @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, data[0..4], .big)))),
        8 => @bitCast(std.mem.readInt(u64, data[0..8], .big)),
        else => error.BadElement,
    };
}

/// Matroska files for the tests, built by hand.
pub const testing = struct {
    /// Appends the element `id` holding `data` to `file`, its size in 8 bytes.
    pub fn element(gpa: Allocator, file: *std.ArrayList(u8), id: Id, data: []const u8) Allocator.Error!void {
        try appendId(gpa, file, id);
        try file.append(gpa, 0x01);
        try file.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToBig(u64, data.len))[1..]);
        try file.appendSlice(gpa, data);
    }

    /// Appends the element `id` holding the unsigned integer `value` to `file`.
    pub fn unsignedElement(gpa: Allocator, file: *std.ArrayList(u8), id: Id, value: u64) Allocator.Error!void {
        try element(gpa, file, id, &std.mem.toBytes(std.mem.nativeToBig(u64, value)));
    }

    /// Appends `id`'s bytes, as many as it takes, to `file`.
    fn appendId(gpa: Allocator, file: *std.ArrayList(u8), id: Id) Allocator.Error!void {
        const value = @backingInt(id);
        const length: usize = 4 - @as(usize, @clz(value)) / 8;
        try file.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToBig(u32, value))[4 - length ..]);
    }

    /// A simple block of track `track`, `relative` ticks into its cluster, holding `frame`.
    pub fn simpleBlock(gpa: Allocator, file: *std.ArrayList(u8), track: u8, relative: i16, keyframe: bool, frame: []const u8) Allocator.Error!void {
        var block: std.ArrayList(u8) = .empty;
        defer block.deinit(gpa);
        try block.append(gpa, 0x80 | track);
        try block.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(i16, relative)));
        try block.append(gpa, if (keyframe) 0x80 else 0);
        try block.appendSlice(gpa, frame);
        try element(gpa, file, .simple_block, block.items);
    }

    /// What a movie for the tests holds.
    pub const Spec = struct {
        doc_type: []const u8 = "webm",
        video_codec: []const u8 = "V_VP9",
        width: u8 = 16,
        height: u8 = 16,
        /// The video frames, one a simple block of track 1, each a tick of 40 ms after the one
        /// before, the first a key frame.
        frames: []const []const u8,
        /// The audio track 2's codec and headers, and its packets, one a simple block, where it
        /// has one.
        audio: ?struct { codec: []const u8, setup: []const u8, packets: []const []const u8 } = null,
    };

    /// The movie `spec` describes, as a WebM file in `gpa`.
    pub fn movie(gpa: Allocator, spec: Spec) Allocator.Error![]u8 {
        var file: std.ArrayList(u8) = .empty;
        defer file.deinit(gpa);
        var header: std.ArrayList(u8) = .empty;
        defer header.deinit(gpa);
        try element(gpa, &header, .doc_type, spec.doc_type);
        try element(gpa, &file, .ebml, header.items);

        var segment: std.ArrayList(u8) = .empty;
        defer segment.deinit(gpa);
        var info: std.ArrayList(u8) = .empty;
        defer info.deinit(gpa);
        try unsignedElement(gpa, &info, .timestamp_scale, 40 * std.time.ns_per_ms);
        try element(gpa, &segment, .info, info.items);

        var tracks: std.ArrayList(u8) = .empty;
        defer tracks.deinit(gpa);
        var video: std.ArrayList(u8) = .empty;
        defer video.deinit(gpa);
        var picture: std.ArrayList(u8) = .empty;
        defer picture.deinit(gpa);
        try unsignedElement(gpa, &picture, .pixel_width, spec.width);
        try unsignedElement(gpa, &picture, .pixel_height, spec.height);
        try unsignedElement(gpa, &video, .track_number, 1);
        try unsignedElement(gpa, &video, .track_type, TrackEntry.video_type);
        try element(gpa, &video, .codec_id, spec.video_codec);
        try element(gpa, &video, .video, picture.items);
        try element(gpa, &tracks, .track_entry, video.items);
        if (spec.audio) |given| {
            var audio: std.ArrayList(u8) = .empty;
            defer audio.deinit(gpa);
            var sound: std.ArrayList(u8) = .empty;
            defer sound.deinit(gpa);
            try element(gpa, &sound, .sampling_frequency, &std.mem.toBytes(std.mem.nativeToBig(u64, @bitCast(@as(f64, ogg.opus_rate)))));
            try unsignedElement(gpa, &sound, .channels, 2);
            try unsignedElement(gpa, &audio, .track_number, 2);
            try unsignedElement(gpa, &audio, .track_type, TrackEntry.audio_type);
            try element(gpa, &audio, .codec_id, given.codec);
            try element(gpa, &audio, .codec_private, given.setup);
            try element(gpa, &audio, .audio, sound.items);
            try element(gpa, &tracks, .track_entry, audio.items);
        }
        try element(gpa, &segment, .tracks, tracks.items);

        var cluster: std.ArrayList(u8) = .empty;
        defer cluster.deinit(gpa);
        try unsignedElement(gpa, &cluster, .timestamp, 0);
        for (spec.frames, 0..) |frame, at| try simpleBlock(gpa, &cluster, 1, @intCast(at), at == 0, frame);
        if (spec.audio) |given| for (given.packets, 0..) |packet, at| try simpleBlock(gpa, &cluster, 2, @intCast(at), true, packet);
        try element(gpa, &segment, .cluster, cluster.items);
        try element(gpa, &file, .segment, segment.items);
        return file.toOwnedSlice(gpa);
    }
};

test Movie {
    const gpa = std.testing.allocator;
    const opus_head = "OpusHead\x01\x02\x38\x01\x80\xBB\x00\x00\x00\x00\x00";
    const bytes = try testing.movie(gpa, .{
        .frames = &.{ "key", "next", "last" },
        .audio = .{ .codec = "A_OPUS", .setup = opus_head, .packets = &.{ "a", "b" } },
    });
    defer gpa.free(bytes);
    try std.testing.expect(isEbml(bytes));
    var movie: Movie = try .parse(gpa, bytes);
    defer movie.deinit(gpa);
    try std.testing.expectEqual(VideoCodec.vp9, movie.video.codec);
    try std.testing.expectEqual(16, movie.video.width);
    // Each frame a tick of the segment's 40 ms after the one before, the first a key frame.
    try std.testing.expectEqual(3, movie.frames.len);
    try std.testing.expectEqualStrings("next", movie.frames[1].data);
    try std.testing.expectEqual(80 * std.time.ns_per_ms, movie.frames[2].time);
    try std.testing.expect(movie.frames[0].keyframe and !movie.frames[1].keyframe);
    // The audio track's headers and packets.
    const audio = movie.audio.?;
    try std.testing.expectEqual(AudioCodec.opus, audio.codec);
    try std.testing.expectEqualStrings(opus_head, audio.setup);
    try std.testing.expectEqual(2, audio.channels);
    try std.testing.expectEqual(2, movie.packets.len);
    try std.testing.expectEqualStrings("b", movie.packets[1]);
}

test "a file that isn't a movie OpenReliant reads" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NotMatroska, Movie.parse(gpa, "RIFF"));
    const other = try testing.movie(gpa, .{ .doc_type = "other", .frames = &.{"key"} });
    defer gpa.free(other);
    try std.testing.expectError(error.NotMatroska, Movie.parse(gpa, other));
    const empty = try testing.movie(gpa, .{ .frames = &.{} });
    defer gpa.free(empty);
    try std.testing.expectError(error.NoFrames, Movie.parse(gpa, empty));
    // Cut short, an element runs past the end.
    const whole = try testing.movie(gpa, .{ .frames = &.{"key"} });
    defer gpa.free(whole);
    try std.testing.expectError(error.BadElement, Movie.parse(gpa, whole[0 .. whole.len - 1]));
}

test "a block of a group, and a cluster of unknown size" {
    const gpa = std.testing.allocator;
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    const head = try testing.movie(gpa, .{ .frames = &.{"key"} });
    defer gpa.free(head);
    // The test movie with a second cluster of unknown size after the first, then cues: a block
    // of a group that refers to the frame before it, and one that refers to none.
    var extra: std.ArrayList(u8) = .empty;
    defer extra.deinit(gpa);
    try testing.appendId(gpa, &extra, .cluster);
    try extra.append(gpa, 0xFF);
    try testing.unsignedElement(gpa, &extra, .timestamp, 10);
    for ([_]bool{ true, false }) |refers| {
        var group: std.ArrayList(u8) = .empty;
        defer group.deinit(gpa);
        var block: std.ArrayList(u8) = .empty;
        defer block.deinit(gpa);
        try block.appendSlice(gpa, &.{ 0x81, 0x00, 0x01, 0x00 });
        try block.appendSlice(gpa, if (refers) "delta" else "again");
        try testing.element(gpa, &group, .block, block.items);
        if (refers) try testing.unsignedElement(gpa, &group, .reference_block, 1);
        try testing.element(gpa, &extra, .block_group, group.items);
    }
    try testing.element(gpa, &extra, .cues, "");
    // The segment's size grows by what's added.
    try file.appendSlice(gpa, head);
    const segment_at = std.mem.findPos(u8, head, 4, &std.mem.toBytes(std.mem.nativeToBig(u32, @backingInt(Id.segment)))).?;
    const size_at = segment_at + 4 + 1;
    const size = std.mem.readInt(u56, head[size_at..][0..7], .big);
    std.mem.writeInt(u56, file.items[size_at..][0..7], size + @as(u56, @intCast(extra.items.len)), .big);
    try file.appendSlice(gpa, extra.items);
    var movie: Movie = try .parse(gpa, file.items);
    defer movie.deinit(gpa);
    try std.testing.expectEqual(3, movie.frames.len);
    try std.testing.expectEqualStrings("delta", movie.frames[1].data);
    try std.testing.expect(!movie.frames[1].keyframe and movie.frames[2].keyframe);
    try std.testing.expectEqual(11 * 40 * std.time.ns_per_ms, movie.frames[1].time);
}

test unlace {
    const gpa = std.testing.allocator;
    var frames: std.ArrayList([]const u8) = .empty;
    defer frames.deinit(gpa);
    // Three frames of 2, 300 and 1 bytes, laced each way.
    var payload: [303]u8 = undefined;
    for (&payload, 0..) |*byte, at| byte.* = @intCast(at % 251);
    const sizes = [3]usize{ 2, 300, 1 };
    var xiph: std.ArrayList(u8) = .empty;
    defer xiph.deinit(gpa);
    try xiph.appendSlice(gpa, &.{ 2, 2, 255, 45 });
    try xiph.appendSlice(gpa, &payload);
    try unlace(gpa, &frames, .xiph, xiph.items);
    var ebml: std.ArrayList(u8) = .empty;
    defer ebml.deinit(gpa);
    // 2, then 298 more as a signed number of two bytes: 298 plus 8191, with the length's marker.
    try ebml.appendSlice(gpa, &.{ 2, 0x82, 0x60 | ((298 + 8191) >> 8 & 0x1F), (298 + 8191) & 0xFF });
    try ebml.appendSlice(gpa, &payload);
    try unlace(gpa, &frames, .ebml, ebml.items);
    try std.testing.expectEqual(6, frames.items.len);
    for (frames.items, sizes ++ sizes) |frame, size| try std.testing.expectEqual(size, frame.len);
    try std.testing.expectEqualSlices(u8, payload[2..302], frames.items[4]);
    // Fixed lacing splits the rest evenly, and fails where it can't.
    frames.clearRetainingCapacity();
    try unlace(gpa, &frames, .fixed, &.{ 1, 'a', 'b', 'c', 'd' });
    try std.testing.expectEqualStrings("cd", frames.items[1]);
    try std.testing.expectError(error.BadElement, unlace(gpa, &frames, .fixed, &.{ 1, 'a', 'b', 'c' }));
    try std.testing.expectError(error.BadElement, unlace(gpa, &frames, .xiph, &.{ 1, 9, 'a' }));
}

test readVint {
    // A one-byte ID keeps its marker, a size drops it, and all ones leave a size unknown.
    try std.testing.expectEqual(0xA3, (try readVint(&.{0xA3}, 0, .id)).value);
    try std.testing.expectEqual(0x23, (try readVint(&.{0xA3}, 0, .size)).value);
    try std.testing.expect((try readVint(&.{0xFF}, 0, .size)).unknown);
    try std.testing.expectEqual(0x0123, (try readVint(&.{ 0x41, 0x23 }, 0, .size)).value);
    try std.testing.expectEqual(-1, (try readVint(&.{0xBE}, 0, .signed)).signedValue());
    try std.testing.expectError(error.BadElement, readVint(&.{0x00}, 0, .size));
    try std.testing.expectError(error.BadElement, readVint(&.{0x08}, 0, .id));
    try std.testing.expectError(error.BadElement, readVint(&.{0x40}, 0, .size));
}

comptime {
    // A block's flags as the specification numbers its bits from the most significant: the key
    // frame first, the lacing in bits 5 and 6.
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .discardable = false, .lacing = .none, .invisible = false, ._reserved = 0, .keyframe = true })) == 0x80);
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .discardable = false, .lacing = .ebml, .invisible = false, ._reserved = 0, .keyframe = false })) == 0x06);
}
