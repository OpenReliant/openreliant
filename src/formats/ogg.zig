//! Ogg files, which mods can use for music, lines and sounds in Vorbis or Opus
//! ([#1176](https://github.com/OpenReliant/openreliant/issues/1176)). A file is a series of pages
//! (RFC 3533). Each page has a header, a table of segment lengths and the segments, and the
//! segments join into the packets of a stream. A Vorbis or Opus stream starts with its header
//! packets, and the packets after them hold the audio. OpenReliant reads the pages and the headers
//! here, and hands the packets to FFmpeg's Vorbis and Opus decoders.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const layout = @import("layout.zig");

pub const extension = ".ogg";

/// The extension of Ogg files of Opus audio (RFC 7845).
pub const opus_extension = ".opus";

/// The four bytes each page starts with.
pub const capture = "OggS";

/// A page's flags.
pub const Flags = packed struct(u8) {
    /// The page continues a packet that started on the stream's previous page.
    continued: bool = false,
    /// The stream's first page.
    first: bool = false,
    /// The stream's last page.
    last: bool = false,
    _unused: u5 = 0,
};

/// A page's header. The lengths of its segments follow it, one byte each, then the segments.
pub const PageHeader = extern struct {
    capture: [capture.len]u8,
    /// 0 in every version so far.
    version: u8,
    flags: Flags,
    /// How far the stream has got after the last packet that ends on the page, in the codec's own
    /// units: samples of each channel for Vorbis, and samples at 48 kHz for Opus. -1 if no packet
    /// ends on the page.
    granule: i64 align(1),
    /// Which stream the page belongs to.
    serial: u32 align(1),
    /// The page's number in its stream.
    sequence: u32 align(1),
    /// The page's checksum (`Crc`), worked out with this field as 0.
    crc: u32 align(1),
    segment_count: u8,

    comptime {
        assert(@offsetOf(PageHeader, "granule") == 6);
        assert(@offsetOf(PageHeader, "crc") == 22);
        assert(@sizeOf(PageHeader) == 27);
    }
};

/// The pages' checksum: a CRC-32 with the polynomial 0x04C11DB7, starting at 0, neither reflected
/// nor inverted.
pub const Crc = std.hash.crc.Generic(u32, .{
    .polynomial = 0x04c11db7,
    .initial = 0,
    .reflect_input = false,
    .reflect_output = false,
    .xor_output = 0,
});

/// The length of a segment that doesn't end its packet: the packet goes on in the next segment.
const segment_most = 255;

/// A page of a file.
pub const Page = struct {
    header: *align(1) const PageHeader,
    /// The segments' lengths.
    lacing: []const u8,
    /// The segments, one after another.
    body: []const u8,

    /// The page's granule position; null if no packet ends on the page.
    pub fn granule(page: Page) ?u64 {
        return std.math.cast(u64, page.header.granule);
    }

    /// The page's length in bytes, from its header to the end of its last segment.
    fn length(page: Page) usize {
        return @sizeOf(PageHeader) + page.lacing.len + page.body.len;
    }

    /// The page that `bytes` start with, if it's whole and its checksum is right.
    fn parse(bytes: []const u8) ?Page {
        const header = layout.view(PageHeader, bytes) catch return null;
        if (header.version != 0) return null;
        const lacing_end = @sizeOf(PageHeader) + @as(usize, header.segment_count);
        if (bytes.len < lacing_end) return null;
        const lacing = bytes[@sizeOf(PageHeader)..lacing_end];
        var body_length: usize = 0;
        for (lacing) |segment| body_length += segment;
        if (bytes.len - lacing_end < body_length) return null;
        const page: Page = .{ .header = header, .lacing = lacing, .body = bytes[lacing_end..][0..body_length] };
        return if (page.checksum(bytes) == header.crc) page else null;
    }

    /// The checksum of the page at the start of `bytes`, computed with the checksum field as 0.
    fn checksum(page: Page, bytes: []const u8) u32 {
        const crc_at = @offsetOf(PageHeader, "crc");
        var crc: Crc = .init();
        crc.update(bytes[0..crc_at]);
        crc.update(&@as([@sizeOf(u32)]u8, @splat(0)));
        crc.update(bytes[crc_at + @sizeOf(u32) .. page.length()]);
        return crc.final();
    }
};

/// A file's pages, in order. It skips bytes that don't start a page, and pages that are cut short or
/// have a wrong checksum, the way a decoder resynchronises.
pub const Pages = struct {
    bytes: []const u8,
    at: usize = 0,

    pub fn init(bytes: []const u8) Pages {
        return .{ .bytes = bytes };
    }

    /// The next page; null at the end.
    pub fn next(pages: *Pages) ?Page {
        while (std.mem.findPos(u8, pages.bytes, pages.at, capture)) |start| {
            const page = Page.parse(pages.bytes[start..]) orelse {
                pages.at = start + 1;
                continue;
            };
            pages.at = start + page.length();
            return page;
        }
        pages.at = pages.bytes.len;
        return null;
    }
};

/// The packets of a file's first stream, in order, skipping the pages of other streams. It joins a
/// packet that spans pages, and skips a packet that a missing or damaged page cuts.
pub const Packets = struct {
    pages: Pages,
    /// The stream's serial number, from its first page.
    serial: ?u32 = null,
    /// The number of the last page read.
    sequence: u32 = 0,
    /// The page being read, its next segment, and where that segment starts in the page's body.
    page: ?Page = null,
    segment: usize = 0,
    at: usize = 0,
    /// The part of a packet read so far, where the packet runs over pages.
    joined: std.ArrayList(u8) = .empty,
    /// Whether `joined` holds the start of a packet that the next page carries on.
    joining: bool = false,
    /// The granule position of the last page read that has one. At the stream's end, it says how
    /// far the packets go (`samples`).
    granule: ?u64 = null,
    /// Whether the stream's last page has been read.
    ended: bool = false,

    pub fn init(bytes: []const u8) Packets {
        return .{ .pages = .init(bytes) };
    }

    pub fn deinit(packets: *Packets, gpa: Allocator) void {
        packets.joined.deinit(gpa);
        packets.* = undefined;
    }

    /// Returns the stream's next packet, valid until the next call; null at the end of the
    /// stream.
    pub fn next(packets: *Packets, gpa: Allocator) Allocator.Error!?[]const u8 {
        // Drop the previous packet, which `joined` holds if it spanned pages.
        if (!packets.joining) packets.joined.clearRetainingCapacity();
        while (true) {
            const page = packets.page orelse {
                if (!packets.advance()) return null;
                continue;
            };
            if (packets.segment == page.lacing.len) {
                if (!packets.advance()) return null;
                continue;
            }
            const part = packets.take(page);
            if (part.ends and !packets.joining) return part.bytes;
            try packets.joined.appendSlice(gpa, part.bytes);
            packets.joining = !part.ends;
            if (part.ends) return packets.joined.items;
        }
    }

    /// Part of a packet on one page, and whether the packet ends there.
    const Part = struct { bytes: []const u8, ends: bool };

    /// The page's segments from the next one up to a short one, which ends its packet.
    fn take(packets: *Packets, page: Page) Part {
        const start = packets.at;
        const ends = while (packets.segment < page.lacing.len) {
            const segment = page.lacing[packets.segment];
            packets.segment += 1;
            packets.at += segment;
            if (segment < segment_most) break true;
        } else false;
        return .{ .bytes = page.body[start..packets.at], .ends = ends };
    }

    /// The number of samples per channel the stream's packets decode to: the granule position of
    /// the last page read, less `pre_skip`, the samples the decoder drops at the start
    /// (`Stream.pre_skip`). Null if no page gave a granule position.
    pub fn samples(packets: Packets, pre_skip: u16) ?u64 {
        return (packets.granule orelse return null) -| pre_skip;
    }

    /// Moves on to the stream's next page. Returns false at the stream's end.
    fn advance(packets: *Packets) bool {
        if (packets.ended) return false;
        while (packets.pages.next()) |page| {
            const serial = packets.serial orelse page.header.serial;
            if (page.header.serial != serial) continue;
            const follows = packets.serial != null and page.header.sequence == packets.sequence +% 1;
            packets.serial = serial;
            packets.sequence = page.header.sequence;
            packets.page = page;
            packets.segment = 0;
            packets.at = 0;
            if (page.granule()) |granule| packets.granule = granule;
            packets.ended = page.header.flags.last;
            // Skip the start of a packet whose next page is missing, and the end of a packet whose
            // start was missing.
            if (packets.joining and !(follows and page.header.flags.continued)) {
                packets.joining = false;
                packets.joined.clearRetainingCapacity();
            }
            if (!packets.joining and page.header.flags.continued) _ = packets.take(page);
            return true;
        }
        return false;
    }
};

/// Appends the segment lengths of a packet of `length` bytes to `lacing`: `segment_most` for each
/// full segment, then the remainder, which may be 0.
fn lace(gpa: Allocator, lacing: *std.ArrayList(u8), length: usize) Allocator.Error!void {
    @memset(try lacing.addManyAsSlice(gpa, length / segment_most), segment_most);
    try lacing.append(gpa, @intCast(length % segment_most));
}

/// The codecs of the streams that OpenReliant reads.
pub const Codec = enum { vorbis, opus };

pub const Error = error{
    /// The file holds no packet.
    NoStream,
    /// Its first stream is neither Vorbis nor Opus.
    UnknownCodec,
    /// Its header packets are missing or damaged.
    BadHeaders,
} || Allocator.Error;

/// What a stream's header packets say, for setting up its decoder.
pub const Stream = struct {
    codec: Codec,
    /// Samples per second.
    rate: u32,
    channels: u8,
    /// The samples of each channel that the decoder drops at the start: Opus's pre-skip, the
    /// encoder's delay (RFC 7845, 4.2), and none for Vorbis.
    pre_skip: u16,
    /// The headers, as the decoder takes them: Opus's identification header, or Vorbis's three
    /// header packets laced together (`xiph_lacing`).
    setup: []u8,

    /// Reads the stream's header packets from `packets`. The packets that follow are audio.
    pub fn read(gpa: Allocator, packets: *Packets) Error!Stream {
        const first = try packets.next(gpa) orelse return error.NoStream;
        if (std.mem.startsWith(u8, first, opus_head)) return readOpus(gpa, packets, first);
        if (vorbisHeaderOf(first) != null) return readVorbis(gpa, packets, first);
        return error.UnknownCodec;
    }

    pub fn deinit(stream: *Stream, gpa: Allocator) void {
        gpa.free(stream.setup);
        stream.* = undefined;
    }

    /// An Opus stream, whose identification header is `first`, then its comment header.
    fn readOpus(gpa: Allocator, packets: *Packets, first: []const u8) Error!Stream {
        const head = layout.view(OpusHead, first) catch return error.BadHeaders;
        const channels = head.channels;
        const pre_skip = head.pre_skip;
        if (channels == 0) return error.BadHeaders;
        const setup = try gpa.dupe(u8, first);
        errdefer gpa.free(setup);
        const tags = try packets.next(gpa) orelse return error.BadHeaders;
        if (!std.mem.startsWith(u8, tags, opus_tags)) return error.BadHeaders;
        return .{ .codec = .opus, .rate = opus_rate, .channels = channels, .pre_skip = pre_skip, .setup = setup };
    }

    /// A Vorbis stream, whose identification header is `first`, then its comment and setup headers.
    fn readVorbis(gpa: Allocator, packets: *Packets, first: []const u8) Error!Stream {
        const identification = layout.view(VorbisIdentification, first) catch return error.BadHeaders;
        const channels = identification.channels;
        const rate = identification.rate;
        if (identification.packet_type != .identification or channels == 0 or rate == 0) return error.BadHeaders;
        // The decoder takes the three headers laced together, so the first two are kept until the
        // third is read.
        const kept = try gpa.dupe(u8, first);
        defer gpa.free(kept);
        const comment = try gpa.dupe(u8, try vorbisHeader(gpa, packets, .comment));
        defer gpa.free(comment);
        const codebooks = try vorbisHeader(gpa, packets, .setup);
        var setup: std.ArrayList(u8) = .empty;
        errdefer setup.deinit(gpa);
        try setup.append(gpa, xiph_lacing);
        for ([_][]const u8{ kept, comment }) |header| try lace(gpa, &setup, header.len);
        for ([_][]const u8{ kept, comment, codebooks }) |header| try setup.appendSlice(gpa, header);
        return .{ .codec = .vorbis, .rate = rate, .channels = channels, .pre_skip = 0, .setup = try setup.toOwnedSlice(gpa) };
    }

    /// The stream's next packet, which must be the Vorbis header of type `header`.
    fn vorbisHeader(gpa: Allocator, packets: *Packets, header: VorbisHeader) Error![]const u8 {
        const packet = try packets.next(gpa) orelse return error.BadHeaders;
        if (vorbisHeaderOf(packet) != header) return error.BadHeaders;
        return packet;
    }
};

/// The type of Vorbis header that `packet` is: its first byte, followed by `vorbis`. Null if it
/// isn't a Vorbis header.
fn vorbisHeaderOf(packet: []const u8) ?VorbisHeader {
    if (packet.len <= vorbis_signature.len or !std.mem.eql(u8, packet[1..][0..vorbis_signature.len], vorbis_signature)) return null;
    return @fromBackingInt(packet[0]);
}

/// The rate that Opus decodes at, whatever the rate of the audio the encoder was given.
pub const opus_rate = 48000;

/// The starts of Opus's identification and comment headers.
const opus_head = "OpusHead";
const opus_tags = "OpusTags";

/// Opus's identification header, the stream's first packet (RFC 7845, 5.1). Where `mapping` isn't
/// 0, a table follows it of how the channels map to the Opus streams in each packet.
pub const OpusHead = extern struct {
    signature: [opus_head.len]u8,
    /// 1, or up to 15 for later versions that this decoder can still read.
    version: u8,
    channels: u8,
    pre_skip: u16 align(1),
    /// The sample rate of the encoder's input. The stream always decodes at `opus_rate`.
    input_rate: u32 align(1),
    /// A gain for the decoder to apply, in 256ths of a decibel. FFmpeg's decoder applies it.
    output_gain: i16 align(1),
    mapping: u8,

    comptime {
        assert(@offsetOf(OpusHead, "pre_skip") == 10);
        assert(@offsetOf(OpusHead, "output_gain") == 16);
        assert(@sizeOf(OpusHead) == 19);
    }
};

/// What Vorbis's header packets say after the type of header they are.
const vorbis_signature = "vorbis";

/// The types of Vorbis's header packets, their first byte.
pub const VorbisHeader = enum(u8) {
    identification = 1,
    comment = 3,
    setup = 5,
    _,
};

/// Vorbis's identification header, the stream's first packet (the Vorbis I specification, 4.2.2).
pub const VorbisIdentification = extern struct {
    packet_type: VorbisHeader,
    signature: [vorbis_signature.len]u8,
    /// 0.
    version: u32 align(1),
    channels: u8,
    rate: u32 align(1),
    bit_rate_maximum: i32 align(1),
    bit_rate_nominal: i32 align(1),
    bit_rate_minimum: i32 align(1),
    /// The short and the long block's size, each a power of two in four bits, the short one first.
    block_sizes: u8,
    /// 1.
    framing: u8,

    comptime {
        assert(@offsetOf(VorbisIdentification, "rate") == 12);
        assert(@offsetOf(VorbisIdentification, "block_sizes") == 28);
        assert(@sizeOf(VorbisIdentification) == 30);
    }
};

/// The first byte of Vorbis's three headers in Xiph lacing: the number of headers less one. The
/// lengths of the first two headers follow, coded like a page's segment lengths.
const xiph_lacing = 2;

/// Ogg files for the tests, built by hand.
pub const testing = struct {
    /// The serial number of the streams that the tests make.
    pub const serial = 0x4F52;

    /// A page's header fields: flags, granule position, stream and page number.
    pub const Place = struct {
        flags: Flags = .{},
        granule: i64,
        serial: u32 = serial,
        sequence: u32,
    };

    /// Appends a page to `file` at `place`: the segments' lengths `lacing`, the segments `body`, and
    /// the page's checksum.
    pub fn page(gpa: Allocator, file: *std.ArrayList(u8), place: Place, lacing: []const u8, body: []const u8) Allocator.Error!void {
        const start = file.items.len;
        const header: PageHeader = .{
            .capture = capture.*,
            .version = 0,
            .flags = place.flags,
            .granule = place.granule,
            .serial = place.serial,
            .sequence = place.sequence,
            .crc = 0,
            .segment_count = @intCast(lacing.len),
        };
        try file.appendSlice(gpa, std.mem.asBytes(&header));
        try file.appendSlice(gpa, lacing);
        try file.appendSlice(gpa, body);
        const crc = Crc.hash(file.items[start..]);
        std.mem.writeInt(u32, file.items[start + @offsetOf(PageHeader, "crc") ..][0..@sizeOf(u32)], crc, .little);
    }

    /// Appends a page to `file` at `place` that holds `packets`, each whole.
    pub fn pageOf(gpa: Allocator, file: *std.ArrayList(u8), place: Place, packets: []const []const u8) Allocator.Error!void {
        var lacing: std.ArrayList(u8) = .empty;
        defer lacing.deinit(gpa);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        for (packets) |packet| {
            try lace(gpa, &lacing, packet.len);
            try body.appendSlice(gpa, packet);
        }
        try page(gpa, file, place, lacing.items, body.items);
    }

    /// An Ogg Opus file in `channels` channels, with `pre_skip`, and `frames` packets of 20 ms of
    /// CELT, each with an empty frame, which decodes to silence. Its last page's granule position
    /// is `end`.
    pub fn opus(gpa: Allocator, channels: u8, pre_skip: u16, frames: usize, end: i64) Allocator.Error![]u8 {
        var file: std.ArrayList(u8) = .empty;
        errdefer file.deinit(gpa);
        const head: OpusHead = .{ .signature = opus_head.*, .version = 1, .channels = channels, .pre_skip = pre_skip, .input_rate = opus_rate, .output_gain = 0, .mapping = 0 };
        try pageOf(gpa, &file, .{ .flags = .{ .first = true }, .granule = 0, .sequence = 0 }, &.{std.mem.asBytes(&head)});
        // A comment header with an empty vendor string and no comments.
        const tags = opus_tags ++ [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
        try pageOf(gpa, &file, .{ .granule = 0, .sequence = 1 }, &.{tags});
        // Each packet is its table of contents alone: configuration 31, which is CELT at full band
        // for 20 ms, stereo or not, and one frame, which takes the rest of the packet.
        const table_of_contents = [_]u8{31 << 3 | @as(u8, @intFromBool(channels == 2)) << 2};
        const packets = try gpa.alloc([]const u8, frames);
        defer gpa.free(packets);
        @memset(packets, &table_of_contents);
        try pageOf(gpa, &file, .{ .flags = .{ .last = true }, .granule = end, .sequence = 2 }, packets);
        return file.toOwnedSlice(gpa);
    }

    /// An Ogg Vorbis file at `rate` in `channels` channels, with `packets` audio packets of short
    /// blocks of 256 samples, each with its floors unused, which decodes to silence: none from the
    /// first packet and 128 samples of each channel from each after it. Its last page's granule
    /// position is `end`.
    pub fn vorbis(gpa: Allocator, rate: u32, channels: u8, packets: usize, end: i64) Allocator.Error![]u8 {
        var file: std.ArrayList(u8) = .empty;
        errdefer file.deinit(gpa);
        const identification: VorbisIdentification = .{
            .packet_type = .identification,
            .signature = vorbis_signature.*,
            .version = 0,
            .channels = channels,
            .rate = rate,
            .bit_rate_maximum = 0,
            .bit_rate_nominal = 0,
            .bit_rate_minimum = 0,
            .block_sizes = 8 | 8 << 4,
            .framing = 1,
        };
        try pageOf(gpa, &file, .{ .flags = .{ .first = true }, .granule = 0, .sequence = 0 }, &.{std.mem.asBytes(&identification)});
        // A comment header with an empty vendor string and no comments.
        const comment = [_]u8{@backingInt(VorbisHeader.comment)} ++ vorbis_signature ++ [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1 };
        var bits: Bits = .{};
        defer bits.bytes.deinit(gpa);
        for ([_]u8{@backingInt(VorbisHeader.setup)} ++ vorbis_signature) |byte| try bits.put(gpa, byte, 8);
        // One codebook of one dimension, with two entries one bit long, and no lookup.
        try bits.puts(gpa, &.{ .{ 0, 8 }, .{ 0x564342, 24 }, .{ 1, 16 }, .{ 2, 24 }, .{ 0, 1 }, .{ 0, 1 }, .{ 0, 5 }, .{ 0, 5 }, .{ 0, 4 } });
        // One time transform, of type 0, and one floor of type 1, without partitions.
        try bits.puts(gpa, &.{ .{ 0, 6 }, .{ 0, 16 }, .{ 0, 6 }, .{ 1, 16 }, .{ 0, 5 }, .{ 0, 2 }, .{ 7, 4 } });
        // One residue of type 0 over the first two values, in partitions of two, with one class
        // and no books.
        try bits.puts(gpa, &.{ .{ 0, 6 }, .{ 0, 16 }, .{ 0, 24 }, .{ 2, 24 }, .{ 1, 24 }, .{ 0, 6 }, .{ 0, 8 }, .{ 0, 3 }, .{ 0, 1 } });
        // One mapping: one submap, of the floor and the residue, without coupling.
        try bits.puts(gpa, &.{ .{ 0, 6 }, .{ 0, 16 }, .{ 0, 1 }, .{ 0, 1 }, .{ 0, 2 }, .{ 0, 8 }, .{ 0, 8 }, .{ 0, 8 } });
        // One mode, of short blocks with the mapping, and the framing bit.
        try bits.puts(gpa, &.{ .{ 0, 6 }, .{ 0, 1 }, .{ 0, 16 }, .{ 0, 16 }, .{ 0, 8 }, .{ 1, 1 } });
        try pageOf(gpa, &file, .{ .granule = 0, .sequence = 1 }, &.{ comment, bits.bytes.items });
        // Each audio packet is its type bit, and each channel's floor unused.
        const silent = [_]u8{0};
        const audio = try gpa.alloc([]const u8, packets);
        defer gpa.free(audio);
        @memset(audio, &silent);
        try pageOf(gpa, &file, .{ .flags = .{ .last = true }, .granule = end, .sequence = 2 }, audio);
        return file.toOwnedSlice(gpa);
    }

    /// Bits packed into bytes from the lowest bit up, as Vorbis packs them.
    const Bits = struct {
        bytes: std.ArrayList(u8) = .empty,
        /// The bits used of the last byte.
        used: u3 = 0,

        /// Appends the lowest `count` bits of `value`.
        fn put(bits: *Bits, gpa: Allocator, value: u32, count: u6) Allocator.Error!void {
            for (0..count) |bit| {
                if (bits.used == 0) try bits.bytes.append(gpa, 0);
                const set: u8 = @intCast(value >> @intCast(bit) & 1);
                bits.bytes.items[bits.bytes.items.len - 1] |= set << bits.used;
                bits.used +%= 1;
            }
        }

        /// Appends each value with its count of bits.
        fn puts(bits: *Bits, gpa: Allocator, values: []const struct { u32, u6 }) Allocator.Error!void {
            for (values) |value| try bits.put(gpa, value[0], value[1]);
        }
    };
};

test Crc {
    try std.testing.expectEqual(0x89A1897F, Crc.hash("123456789"));
}

test Pages {
    const gpa = std.testing.allocator;
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    // Bytes that start no page, a page, a page whose checksum is wrong, another page, and a page
    // cut short.
    try file.appendSlice(gpa, "junk OggS");
    try testing.pageOf(gpa, &file, .{ .flags = .{ .first = true }, .granule = -1, .sequence = 0 }, &.{"one"});
    try testing.pageOf(gpa, &file, .{ .granule = 5, .sequence = 1 }, &.{"two"});
    file.items[file.items.len - 1] ^= 1;
    try testing.pageOf(gpa, &file, .{ .granule = 7, .sequence = 2 }, &.{"three"});
    try testing.pageOf(gpa, &file, .{ .granule = 9, .sequence = 3 }, &.{"four"});
    var pages: Pages = .init(file.items[0 .. file.items.len - 1]);
    const first = pages.next().?;
    try std.testing.expectEqualStrings("one", first.body);
    try std.testing.expect(first.header.flags.first);
    try std.testing.expectEqual(null, first.granule());
    const third = pages.next().?;
    try std.testing.expectEqual(2, third.header.sequence);
    try std.testing.expectEqualStrings("three", third.body);
    try std.testing.expectEqual(7, third.granule());
    try std.testing.expectEqual(null, pages.next());
}

test Packets {
    const gpa = std.testing.allocator;
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    // A packet on the first page; one that runs from it over the second page, with a page of
    // another stream between them; and one on the third.
    const long: [600]u8 = @splat('x');
    try testing.page(gpa, &file, .{ .flags = .{ .first = true }, .granule = 10, .sequence = 0 }, &.{ 3, 255, 255 }, "one" ++ long[0..510]);
    try testing.page(gpa, &file, .{ .flags = .{ .first = true }, .granule = 0, .serial = 1, .sequence = 0 }, &.{4}, "else");
    try testing.page(gpa, &file, .{ .flags = .{ .continued = true }, .granule = -1, .sequence = 1 }, &.{ 90, 5 }, long[510..] ++ "three");
    try testing.pageOf(gpa, &file, .{ .flags = .{ .last = true }, .granule = 30, .sequence = 2 }, &.{"four"});
    var packets: Packets = .init(file.items);
    defer packets.deinit(gpa);
    try std.testing.expectEqualStrings("one", (try packets.next(gpa)).?);
    try std.testing.expectEqualSlices(u8, &long, (try packets.next(gpa)).?);
    try std.testing.expectEqualStrings("three", (try packets.next(gpa)).?);
    // A page without a granule position leaves the last one.
    try std.testing.expectEqual(10, packets.granule);
    try std.testing.expectEqualStrings("four", (try packets.next(gpa)).?);
    try std.testing.expectEqual(null, try packets.next(gpa));
    try std.testing.expectEqual(30, packets.granule);
    try std.testing.expectEqual(24, packets.samples(6));
}

test "Packets passes over a packet that a missing page cuts" {
    const gpa = std.testing.allocator;
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    // A packet that runs on into page 1, which is missing, and page 2, which starts with the end
    // of a packet.
    const long: [255]u8 = @splat('x');
    try testing.page(gpa, &file, .{ .flags = .{ .first = true }, .granule = -1, .sequence = 0 }, &.{255}, &long);
    try testing.page(gpa, &file, .{ .flags = .{ .continued = true, .last = true }, .granule = 4, .sequence = 2 }, &.{ 2, 4 }, "..next");
    var packets: Packets = .init(file.items);
    defer packets.deinit(gpa);
    try std.testing.expectEqualStrings("next", (try packets.next(gpa)).?);
    try std.testing.expectEqual(null, try packets.next(gpa));
}

test Stream {
    const gpa = std.testing.allocator;
    // An Opus stream: its rate, channels and pre-skip, and its identification header for the
    // decoder. Its audio packets follow.
    const opus = try testing.opus(gpa, 2, 312, 3, 2480);
    defer gpa.free(opus);
    var opus_packets: Packets = .init(opus);
    defer opus_packets.deinit(gpa);
    var opus_stream: Stream = try .read(gpa, &opus_packets);
    defer opus_stream.deinit(gpa);
    try std.testing.expectEqual(Codec.opus, opus_stream.codec);
    try std.testing.expectEqual(48000, opus_stream.rate);
    try std.testing.expectEqual(2, opus_stream.channels);
    try std.testing.expectEqual(312, opus_stream.pre_skip);
    try std.testing.expectEqualStrings(opus_head, opus_stream.setup[0..opus_head.len]);
    try std.testing.expectEqual(1, (try opus_packets.next(gpa)).?.len);

    // A Vorbis stream: its three headers laced together.
    const vorbis = try testing.vorbis(gpa, 22050, 1, 2, 128);
    defer gpa.free(vorbis);
    var vorbis_packets: Packets = .init(vorbis);
    defer vorbis_packets.deinit(gpa);
    var vorbis_stream: Stream = try .read(gpa, &vorbis_packets);
    defer vorbis_stream.deinit(gpa);
    try std.testing.expectEqual(Codec.vorbis, vorbis_stream.codec);
    try std.testing.expectEqual(22050, vorbis_stream.rate);
    try std.testing.expectEqual(1, vorbis_stream.channels);
    try std.testing.expectEqual(0, vorbis_stream.pre_skip);
    // The lacing gives the lengths of the identification and comment headers, which follow it,
    // then the setup header.
    const comment_length = 16;
    try std.testing.expectEqualSlices(u8, &.{ xiph_lacing, @sizeOf(VorbisIdentification), comment_length }, vorbis_stream.setup[0..3]);
    try std.testing.expectEqual(@backingInt(VorbisHeader.identification), vorbis_stream.setup[3]);
    try std.testing.expectEqual(@backingInt(VorbisHeader.setup), vorbis_stream.setup[3 + @sizeOf(VorbisIdentification) + comment_length]);

    // A stream of another codec, a file without one, and an Opus stream without its comment
    // header, on the file's first page alone.
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    try testing.pageOf(gpa, &file, .{ .flags = .{ .first = true }, .granule = 0, .sequence = 0 }, &.{"\x80theora"});
    var other: Packets = .init(file.items);
    defer other.deinit(gpa);
    try std.testing.expectError(error.UnknownCodec, Stream.read(gpa, &other));
    var none: Packets = .init("not an Ogg file");
    defer none.deinit(gpa);
    try std.testing.expectError(error.NoStream, Stream.read(gpa, &none));
    var cut: Packets = .init(opus[0 .. @sizeOf(PageHeader) + 1 + @sizeOf(OpusHead)]);
    defer cut.deinit(gpa);
    try std.testing.expectError(error.BadHeaders, Stream.read(gpa, &cut));
}
