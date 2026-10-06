//! Portable Executable reader, covering what this project needs: the section table, the data
//! directories, the import descriptors, and the resources, string tables among them. Read-only,
//! and it never maps or runs anything.

const std = @import("std");
const assert = std.debug.assert;

const layout = @import("layout.zig");

pub const dos_magic = "MZ";
pub const nt_signature = "PE\x00\x00";

pub const Machine = enum(u16) {
    i386 = 0x014C,
    amd64 = 0x8664,
    arm64 = 0xAA64,
    _,
};

pub const DosHeader = extern struct {
    magic: [2]u8,
    _unused: [58]u8,
    /// File offset of the PE signature.
    nt_offset: u32,

    comptime {
        assert(@sizeOf(DosHeader) == 64);
    }
};

pub const FileHeader = extern struct {
    machine: Machine,
    section_count: u16,
    timestamp: u32,
    symbol_table_offset: u32,
    symbol_count: u32,
    optional_header_size: u16,
    characteristics: Characteristics,

    pub const Characteristics = packed struct(u16) {
        relocs_stripped: bool,
        executable: bool,
        line_numbers_stripped: bool,
        local_symbols_stripped: bool,
        aggressive_working_set_trim: bool,
        large_address_aware: bool,
        _reserved: u1,
        bytes_reversed_lo: bool,
        machine_32bit: bool,
        debug_stripped: bool,
        removable_run_from_swap: bool,
        net_run_from_swap: bool,
        system: bool,
        dll: bool,
        uniprocessor_only: bool,
        bytes_reversed_hi: bool,
    };

    comptime {
        assert(@sizeOf(FileHeader) == 20);
    }
};

/// What the DOS header's `nt_offset` points at: the PE signature, then the file header.
pub const NtHeaders = extern struct {
    signature: [nt_signature.len]u8,
    file_header: FileHeader,

    comptime {
        assert(@offsetOf(NtHeaders, "file_header") == nt_signature.len);
        assert(@sizeOf(NtHeaders) == 24);
    }
};

pub const OptionalHeaderMagic = enum(u16) {
    pe32 = 0x010B,
    pe32plus = 0x020B,
    _,
};

/// The PE32 optional header, up to the data directories. PE32+ differs from `image_base` on, which
/// this project has no 64-bit images to need.
pub const OptionalHeader32 = extern struct {
    magic: OptionalHeaderMagic,
    linker_major: u8,
    linker_minor: u8,
    code_size: u32,
    initialized_data_size: u32,
    uninitialized_data_size: u32,
    entry_point: u32,
    code_base: u32,
    data_base: u32,
    image_base: u32,
    section_alignment: u32,
    file_alignment: u32,
    os_major: u16,
    os_minor: u16,
    image_major: u16,
    image_minor: u16,
    subsystem_major: u16,
    subsystem_minor: u16,
    win32_version: u32,
    image_size: u32,
    headers_size: u32,
    checksum: u32,
    subsystem: u16,
    dll_characteristics: u16,
    stack_reserve: u32,
    stack_commit: u32,
    heap_reserve: u32,
    heap_commit: u32,
    loader_flags: u32,
    directory_count: u32,

    comptime {
        assert(@sizeOf(OptionalHeader32) == 96);
    }
};

/// The data directories a PE32 optional header has room for (`IMAGE_NUMBEROF_DIRECTORY_ENTRIES`).
/// A header may say it has more; the rest are not read.
pub const directory_entries = 16;

pub const DataDirectory = extern struct {
    rva: u32,
    size: u32,

    comptime {
        assert(@sizeOf(DataDirectory) == 8);
    }
};

pub const DirectoryIndex = enum(u32) {
    @"export" = 0,
    import = 1,
    resource = 2,
    exception = 3,
    security = 4,
    base_relocation = 5,
    debug = 6,
    architecture = 7,
    global_pointer = 8,
    tls = 9,
    load_config = 10,
    bound_import = 11,
    /// Import address table: the slots the loader writes resolved addresses into.
    iat = 12,
    delay_import = 13,
    clr = 14,
    _,
};

pub const SectionHeader = extern struct {
    name_bytes: [8]u8,
    virtual_size: u32,
    virtual_address: u32,
    raw_size: u32,
    raw_offset: u32,
    relocations_offset: u32,
    line_numbers_offset: u32,
    relocation_count: u16,
    line_number_count: u16,
    characteristics: Characteristics,

    /// Section names are 8 bytes, NUL-padded rather than NUL-terminated.
    pub fn name(header: *align(1) const SectionHeader) []const u8 {
        return std.mem.sliceTo(&header.name_bytes, 0);
    }

    pub const Characteristics = packed struct(u32) {
        _reserved0: u3,
        no_pad: bool,
        _reserved1: u1,
        code: bool,
        initialized_data: bool,
        uninitialized_data: bool,
        link_other: bool,
        link_info: bool,
        _reserved2: u1,
        link_remove: bool,
        link_comdat: bool,
        _reserved3: u2,
        gp_relative: bool,
        _reserved4: u1,
        purgeable: bool,
        locked: bool,
        preload: bool,
        /// Byte alignment, as a power-of-two exponent plus one; zero means the default.
        alignment: u4,
        extended_relocations: bool,
        discardable: bool,
        not_cached: bool,
        not_paged: bool,
        shared: bool,
        execute: bool,
        read: bool,
        write: bool,
    };

    comptime {
        assert(@sizeOf(SectionHeader) == 40);
    }
};

pub const ImportDescriptor = extern struct {
    /// Import lookup table: what the file asks for. Zero in a bound-only descriptor.
    lookup_table_rva: u32,
    timestamp: u32,
    forwarder_chain: u32,
    name_rva: u32,
    /// Import address table: where resolved addresses land. Identical to the lookup table on disk
    /// unless the image was bound or, as here, rewritten by a protection layer.
    address_table_rva: u32,

    pub fn isTerminator(descriptor: *align(1) const ImportDescriptor) bool {
        return descriptor.name_rva == 0 and descriptor.lookup_table_rva == 0 and
            descriptor.address_table_rva == 0;
    }

    comptime {
        assert(@sizeOf(ImportDescriptor) == 20);
    }
};

pub const ParseError = error{
    NotPe,
    UnsupportedFormat,
    /// A header points outside the file.
    Truncated,
};

/// A PE image held in memory. Borrows `bytes`; `Image` never copies or frees them, so a tool that
/// wants to edit an image parses a mutable buffer and writes it back out itself.
pub const Image = struct {
    bytes: []u8,
    file_header: *align(1) FileHeader,
    optional_header: *align(1) OptionalHeader32,
    directories: []align(1) DataDirectory,
    sections: []align(1) SectionHeader,

    pub fn parse(bytes: []u8) ParseError!Image {
        const dos = layout.view(DosHeader, bytes) catch return error.NotPe;
        if (!std.mem.eql(u8, &dos.magic, dos_magic)) return error.NotPe;

        if (dos.nt_offset > bytes.len) return error.Truncated;
        const nt = try layout.viewMut(NtHeaders, bytes[dos.nt_offset..]);
        if (!std.mem.eql(u8, &nt.signature, nt_signature)) return error.NotPe;

        const file_header = &nt.file_header;
        const optional_offset = @as(usize, dos.nt_offset) + @sizeOf(NtHeaders);
        if (file_header.optional_header_size < @sizeOf(OptionalHeader32)) return error.UnsupportedFormat;
        if (bytes.len < optional_offset + file_header.optional_header_size) return error.Truncated;

        const optional_header = try layout.viewMut(OptionalHeader32, bytes[optional_offset..]);
        if (optional_header.magic != .pe32) return error.UnsupportedFormat;

        const directories = try layout.arrayMut(
            DataDirectory,
            bytes[optional_offset + @sizeOf(OptionalHeader32) ..],
            @min(optional_header.directory_count, directory_entries),
        );
        const sections = try layout.arrayMut(
            SectionHeader,
            bytes[optional_offset + file_header.optional_header_size ..],
            file_header.section_count,
        );

        return .{
            .bytes = bytes,
            .file_header = file_header,
            .optional_header = optional_header,
            .directories = directories,
            .sections = sections,
        };
    }

    /// The record of type `T` at `offset` into the file, or null where it runs past the end.
    fn recordAt(image: Image, comptime T: type, offset: usize) ?*align(1) const T {
        if (offset > image.bytes.len) return null;
        return layout.view(T, image.bytes[offset..]) catch null;
    }

    pub fn directory(image: Image, index: DirectoryIndex) ?DataDirectory {
        const i = @backingInt(index);
        if (i >= image.directories.len) return null;
        const entry = image.directories[i];
        return if (entry.rva == 0) null else entry;
    }

    pub fn sectionByName(image: Image, name: []const u8) ?*align(1) SectionHeader {
        for (image.sections) |*section| {
            if (std.mem.eql(u8, section.name(), name)) return section;
        }
        return null;
    }

    pub fn sectionContaining(image: Image, rva: u32) ?*align(1) SectionHeader {
        for (image.sections) |*section| {
            const size = @max(section.virtual_size, section.raw_size);
            if (rva >= section.virtual_address and rva - section.virtual_address < size) return section;
        }
        return null;
    }

    /// The bytes a section occupies in the file. Shorter than its virtual size when the section
    /// has a zero-filled tail that is not stored.
    pub fn sectionData(image: Image, section: *align(1) const SectionHeader) ![]u8 {
        const end = std.math.add(u32, section.raw_offset, section.raw_size) catch return error.Truncated;
        if (end > image.bytes.len) return error.Truncated;
        return image.bytes[section.raw_offset..end];
    }

    /// Translates a relative virtual address to a file offset.
    pub fn fileOffset(image: Image, rva: u32) ?u32 {
        const section = image.sectionContaining(rva) orelse return null;
        const delta = rva - section.virtual_address;
        if (delta >= section.raw_size) return null;
        return section.raw_offset + delta;
    }

    /// Reads a NUL-terminated string at `rva`.
    pub fn stringAt(image: Image, rva: u32) ?[]const u8 {
        const offset = image.fileOffset(rva) orelse return null;
        const rest = image.bytes[offset..];
        const end = std.mem.findScalar(u8, rest, 0) orelse return null;
        return rest[0..end];
    }

    pub fn imports(image: Image) ?ImportIterator {
        const dir = image.directory(.import) orelse return null;
        const offset = image.fileOffset(dir.rva) orelse return null;
        return .{ .image = image, .offset = offset };
    }

    /// The data of the resource of `kind` and `id`, in the first language it comes in, as
    /// `FindResource` and `LoadResource` find it where a module holds one language. Null when the
    /// image has none, or when a directory points outside the file.
    pub fn resource(image: Image, kind: ResourceType, id: u16) ?[]const u8 {
        const dir = image.directory(.resource) orelse return null;
        const root = image.fileOffset(dir.rva) orelse return null;
        const kinds = image.resourceEntry(root, 0, @backingInt(kind)) orelse return null;
        const ids = image.resourceEntry(root, kinds.below() orelse return null, id) orelse return null;
        const languages = ids.below() orelse return null;
        const language = image.resourceEntries(root, languages) orelse return null;
        if (language.len == 0 or language[0].below() != null) return null;
        const at = std.math.add(u32, root, language[0].offset) catch return null;
        const data = image.recordAt(ResourceData, at) orelse return null;
        const offset = image.fileOffset(data.rva) orelse return null;
        const end = std.math.add(u32, offset, data.size) catch return null;
        if (end > image.bytes.len) return null;
        return image.bytes[offset..end];
    }

    /// The string of `id` in the image's string tables, as `LoadString` finds it: the table of
    /// block `id / 16 + 1` holds strings `id` rounded down to a multiple of 16 on, each a length
    /// and that many UTF-16 units. Null when there is no such string; an empty one is empty.
    pub fn string(image: Image, id: u16) ?[]align(1) const u16 {
        const block = image.resource(.string, id / strings_per_block + 1) orelse return null;
        var at: usize = 0;
        for (0..strings_per_block) |index| {
            const length = (layout.view(u16, block[at..]) catch return null).*;
            at += @sizeOf(u16);
            const units = layout.array(u16, block[at..], length) catch return null;
            if (index == id % strings_per_block) return units;
            at += units.len * @sizeOf(u16);
        }
        return null;
    }

    /// The entries of the resource directory `offset` past `root`, or null past the file.
    fn resourceEntries(image: Image, root: u32, offset: u32) ?[]align(1) const ResourceEntry {
        const at = std.math.add(u32, root, offset) catch return null;
        const directory_header = image.recordAt(ResourceDirectory, at) orelse return null;
        const count = @as(usize, directory_header.named_count) + directory_header.id_count;
        return layout.array(ResourceEntry, image.bytes[at + @sizeOf(ResourceDirectory) ..], count) catch null;
    }

    /// The entry of `id` in the resource directory `offset` past `root`.
    fn resourceEntry(image: Image, root: u32, offset: u32, id: u16) ?ResourceEntry {
        for (image.resourceEntries(root, offset) orelse return null) |entry| {
            if (entry.id() == id) return entry;
        }
        return null;
    }
};

// --- Resources ---------------------------------------------------------------------------------

/// A resource directory, followed by its named entries and then the ones with ids.
pub const ResourceDirectory = extern struct {
    characteristics: u32,
    timestamp: u32,
    major_version: u16,
    minor_version: u16,
    named_count: u16,
    id_count: u16,

    comptime {
        assert(@sizeOf(ResourceDirectory) == 16);
    }
};

/// An entry of a resource directory. Its offset is from the start of the resource section's
/// root directory, to a directory below it when the top bit is set and to the entry's data
/// otherwise.
pub const ResourceEntry = extern struct {
    /// An id, or with the top bit set the offset of a name.
    name: u32,
    offset: u32,

    const high: u32 = 0x8000_0000;

    /// The entry's id, or null for one that is named.
    pub fn id(entry: ResourceEntry) ?u16 {
        return if (entry.name & high != 0) null else @truncate(entry.name);
    }

    /// The offset of the directory below the entry, or null when it points at data.
    pub fn below(entry: ResourceEntry) ?u32 {
        return if (entry.offset & high != 0) entry.offset & ~high else null;
    }

    comptime {
        assert(@sizeOf(ResourceEntry) == 8);
    }
};

/// Where a resource's data lies: an address relative to the image base, not to the section.
pub const ResourceData = extern struct {
    rva: u32,
    size: u32,
    code_page: u32,
    _reserved: u32,

    comptime {
        assert(@sizeOf(ResourceData) == 16);
    }
};

/// The resource types this project reads.
pub const ResourceType = enum(u16) {
    string = 6,
    _,
};

/// Strings to a block of a string table.
pub const strings_per_block = 16;

pub const ImportIterator = struct {
    image: Image,
    offset: u32,

    pub const Entry = struct {
        descriptor: *align(1) const ImportDescriptor,
        name: []const u8,
    };

    pub fn next(iterator: *ImportIterator) ?Entry {
        const descriptor = iterator.image.recordAt(ImportDescriptor, iterator.offset) orelse return null;
        if (descriptor.isTerminator()) return null;
        iterator.offset += @sizeOf(ImportDescriptor);
        return .{
            .descriptor = descriptor,
            .name = iterator.image.stringAt(descriptor.name_rva) orelse "",
        };
    }
};

/// Builds PE images in memory, for the tests of code that reads them.
pub const testing = struct {
    pub const Section = struct {
        name: []const u8 = ".data",
        /// Where the section loads, relative to the image base.
        rva: u32,
        data: []const u8,
    };

    const nt_offset = 0x80;
    const headers_size = 0x400;
    const file_alignment = 0x200;

    /// A data directory for `buildWith` to set.
    pub const Directory = struct {
        index: DirectoryIndex,
        rva: u32,
        size: u32,
    };

    /// A PE32 image of `sections`, loaded at `image_base`, that `Image.parse` accepts. Each
    /// section's virtual size is its data's. The caller owns the bytes.
    pub fn build(allocator: std.mem.Allocator, image_base: u32, sections: []const Section) ![]u8 {
        return buildWith(allocator, image_base, sections, &.{});
    }

    /// As `build`, with `directories` set.
    pub fn buildWith(
        allocator: std.mem.Allocator,
        image_base: u32,
        sections: []const Section,
        directories: []const Directory,
    ) ![]u8 {
        const optional_offset = nt_offset + @sizeOf(NtHeaders);
        const optional_size = @sizeOf(OptionalHeader32) + directory_entries * @sizeOf(DataDirectory);
        const sections_offset = optional_offset + optional_size;
        if (sections_offset + sections.len * @sizeOf(SectionHeader) > headers_size) return error.TooManySections;

        var size: usize = headers_size;
        for (sections) |section| size += std.mem.alignForward(usize, section.data.len, file_alignment);
        const bytes = try allocator.alloc(u8, size);
        errdefer allocator.free(bytes);
        @memset(bytes, 0);

        const dos = try layout.viewMut(DosHeader, bytes);
        dos.magic = dos_magic.*;
        dos.nt_offset = nt_offset;

        (try layout.viewMut(NtHeaders, bytes[nt_offset..])).* = .{
            .signature = nt_signature.*,
            .file_header = .{
                .machine = .i386,
                .section_count = @intCast(sections.len),
                .timestamp = 0,
                .symbol_table_offset = 0,
                .symbol_count = 0,
                .optional_header_size = optional_size,
                .characteristics = @bitCast(@as(u16, 0x010E)),
            },
        };
        const optional = try layout.viewMut(OptionalHeader32, bytes[optional_offset..]);
        optional.magic = .pe32;
        optional.image_base = image_base;
        optional.file_alignment = file_alignment;
        optional.headers_size = headers_size;
        optional.directory_count = directory_entries;
        const table = try layout.arrayMut(DataDirectory, bytes[optional_offset + @sizeOf(OptionalHeader32) ..], directory_entries);
        for (directories) |entry| table[@backingInt(entry.index)] = .{ .rva = entry.rva, .size = entry.size };

        const headers = try layout.arrayMut(SectionHeader, bytes[sections_offset..], sections.len);
        var raw_offset: u32 = headers_size;
        for (sections, headers) |section, *header| {
            header.* = std.mem.zeroes(SectionHeader);
            const name_len = @min(section.name.len, header.name_bytes.len);
            @memcpy(header.name_bytes[0..name_len], section.name[0..name_len]);
            header.virtual_address = section.rva;
            header.virtual_size = @intCast(section.data.len);
            header.raw_offset = raw_offset;
            header.raw_size = @intCast(section.data.len);
            @memcpy(bytes[raw_offset..][0..section.data.len], section.data);
            raw_offset += @intCast(std.mem.alignForward(usize, section.data.len, file_alignment));
        }
        return bytes;
    }

    /// A resource section, to load at `rva`, holding one string table of `strings` from id 0 on,
    /// ASCII, in language `0x409`. A string of null is left out of its block, as an empty one.
    pub fn stringResources(allocator: std.mem.Allocator, rva: u32, strings: []const ?[]const u8) ![]u8 {
        const blocks = (strings.len + strings_per_block - 1) / strings_per_block;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        const directory_size = @sizeOf(ResourceDirectory);
        const entry_size = @sizeOf(ResourceEntry);
        // The root holds the string type; the type's directory each block; each block's directory
        // its one language; then the data entries and the blocks' data.
        const root_size = directory_size + entry_size;
        const kinds_size = directory_size + blocks * entry_size;
        const languages_size = blocks * (directory_size + entry_size);
        const data_entries = root_size + kinds_size + languages_size;
        const block_data = data_entries + blocks * @sizeOf(ResourceData);

        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(allocator);
        var offsets = try allocator.alloc(u32, blocks + 1);
        defer allocator.free(offsets);
        for (0..blocks) |block| {
            offsets[block] = @intCast(data.items.len);
            for (0..strings_per_block) |index| {
                const at = block * strings_per_block + index;
                const text = if (at < strings.len) strings[at] orelse "" else "";
                try appendRecord(allocator, &data, @as(u16, @intCast(text.len)));
                for (text) |c| try appendRecord(allocator, &data, @as(u16, c));
            }
        }
        offsets[blocks] = @intCast(data.items.len);

        try appendRecord(allocator, &out, directory(1));
        try appendRecord(allocator, &out, ResourceEntry{ .name = @backingInt(ResourceType.string), .offset = ResourceEntry.high | root_size });
        try appendRecord(allocator, &out, directory(blocks));
        for (0..blocks) |block| {
            const below: u32 = @intCast(root_size + kinds_size + block * (directory_size + entry_size));
            try appendRecord(allocator, &out, ResourceEntry{ .name = @intCast(block + 1), .offset = ResourceEntry.high | below });
        }
        for (0..blocks) |block| {
            try appendRecord(allocator, &out, directory(1));
            try appendRecord(allocator, &out, ResourceEntry{ .name = 0x409, .offset = @intCast(data_entries + block * @sizeOf(ResourceData)) });
        }
        for (0..blocks) |block| {
            try appendRecord(allocator, &out, ResourceData{
                .rva = rva + @as(u32, @intCast(block_data)) + offsets[block],
                .size = offsets[block + 1] - offsets[block],
                .code_page = 0,
                ._reserved = 0,
            });
        }
        try out.appendSlice(allocator, data.items);
        return out.toOwnedSlice(allocator);
    }

    /// A resource directory of `ids` entries, all by id.
    fn directory(ids: usize) ResourceDirectory {
        return .{ .characteristics = 0, .timestamp = 0, .major_version = 0, .minor_version = 0, .named_count = 0, .id_count = @intCast(ids) };
    }

    fn appendRecord(allocator: std.mem.Allocator, out: *std.ArrayList(u8), record: anytype) !void {
        try out.appendSlice(allocator, std.mem.asBytes(&record));
    }
};

test "parses a minimal image" {
    const bytes = try testing.build(std.testing.allocator, 0x400000, &.{
        .{ .name = ".text", .rva = 0x1000, .data = "hello" ++ @as([0x3B]u8, @splat(0)) },
    });
    defer std.testing.allocator.free(bytes);

    const image: Image = try .parse(bytes);
    try std.testing.expectEqual(Machine.i386, image.file_header.machine);
    try std.testing.expectEqual(@as(u32, 0x400000), image.optional_header.image_base);
    try std.testing.expectEqual(@as(usize, 1), image.sections.len);

    const text = image.sectionByName(".text").?;
    try std.testing.expectEqualStrings(".text", text.name());
    try std.testing.expectEqualSlices(u8, "hello", (try image.sectionData(text))[0..5]);
    try std.testing.expectEqual(@as(?u32, 0x405), image.fileOffset(0x1005));
    try std.testing.expectEqualStrings("hello", image.stringAt(0x1000).?);
    try std.testing.expectEqual(@as(?*align(1) SectionHeader, null), image.sectionContaining(0x9999));
    try std.testing.expectEqual(@as(?DataDirectory, null), image.directory(.import));
    try std.testing.expectEqual(null, image.imports());
}

test "lists the libraries an image imports from" {
    const allocator = std.testing.allocator;
    const rva = 0x2000;
    const address_table = rva + 0x40;
    // A descriptor, the zeroed one that ends the list, then the library's name.
    var idata: [0x60]u8 = @splat(0);
    const name_at = 2 * @sizeOf(ImportDescriptor);
    (try layout.viewMut(ImportDescriptor, &idata)).* = .{
        .lookup_table_rva = address_table,
        .timestamp = 0,
        .forwarder_chain = 0,
        .name_rva = rva + name_at,
        .address_table_rva = address_table,
    };
    @memcpy(idata[name_at..][0.."KERNEL32.dll".len], "KERNEL32.dll");
    const bytes = try testing.buildWith(allocator, 0x400000, &.{
        .{ .name = ".idata", .rva = rva, .data = &idata },
    }, &.{.{ .index = .import, .rva = rva, .size = idata.len }});
    defer allocator.free(bytes);
    const image: Image = try .parse(bytes);

    var imports = image.imports().?;
    const kernel = imports.next().?;
    try std.testing.expectEqualStrings("KERNEL32.dll", kernel.name);
    try std.testing.expectEqual(address_table, kernel.descriptor.address_table_rva);
    try std.testing.expectEqual(null, imports.next());
}

test "maps each section to its own file offset" {
    const bytes = try testing.build(std.testing.allocator, 0x400000, &.{
        .{ .name = ".text", .rva = 0x1000, .data = &@as([0x10]u8, @splat(0xC3)) },
        .{ .name = ".data", .rva = 0x5000, .data = &@as([0x300]u8, @splat(0xAA)) },
    });
    defer std.testing.allocator.free(bytes);

    const image: Image = try .parse(bytes);
    try std.testing.expectEqual(@as(usize, 2), image.sections.len);
    try std.testing.expectEqual(@as(?u32, 0x400), image.fileOffset(0x1000));
    try std.testing.expectEqual(@as(?u32, 0x600), image.fileOffset(0x5000));
    try std.testing.expectEqual(@as(?u32, 0x8FF), image.fileOffset(0x52FF));
    // Past a section's data, and between sections, nothing maps.
    try std.testing.expectEqual(@as(?u32, null), image.fileOffset(0x5300));
    try std.testing.expectEqual(@as(?u32, null), image.fileOffset(0x3000));
    try std.testing.expectEqual(@as(u8, 0xAA), bytes[image.fileOffset(0x5123).?]);
}

test "finds a string as LoadString does" {
    const allocator = std.testing.allocator;
    var strings: [20]?[]const u8 = @splat(null);
    strings[1] = "COCKPIT";
    strings[15] = "LAST OF THE FIRST BLOCK";
    strings[17] = "EXTERNAL";
    const rsrc = try testing.stringResources(allocator, 0x3000, &strings);
    defer allocator.free(rsrc);
    const bytes = try testing.buildWith(allocator, 0x10000000, &.{
        .{ .name = ".rsrc", .rva = 0x3000, .data = rsrc },
    }, &.{.{ .index = .resource, .rva = 0x3000, .size = @intCast(rsrc.len) }});
    defer allocator.free(bytes);
    const image: Image = try .parse(bytes);

    const expectString = struct {
        fn check(found: ?[]align(1) const u16, expected: []const u8) !void {
            const units = found orelse return error.TestExpectedString;
            try std.testing.expectEqual(expected.len, units.len);
            for (units, expected) |unit, c| try std.testing.expectEqual(@as(u16, c), unit);
        }
    }.check;
    try expectString(image.string(1), "COCKPIT");
    try expectString(image.string(15), "LAST OF THE FIRST BLOCK");
    // The second block holds the strings from 16.
    try expectString(image.string(17), "EXTERNAL");
    // A string the block leaves empty is empty; a block the image lacks has none.
    try std.testing.expectEqual(0, image.string(0).?.len);
    try std.testing.expectEqual(null, image.string(40));
    // No resource of another type.
    try std.testing.expectEqual(null, image.resource(@fromBackingInt(@intCast(3)), 1));
}

test "rejects non-PE input" {
    var bytes: [64]u8 = @splat(0);
    try std.testing.expectError(error.NotPe, Image.parse(&bytes));
    try std.testing.expectError(error.NotPe, Image.parse(bytes[0..8]));

    // A DOS header whose PE signature lies past the end of the file.
    bytes[0..2].* = dos_magic.*;
    std.mem.writeInt(u32, bytes[60..64], 0xFFFF_FFF0, .little);
    try std.testing.expectError(error.Truncated, Image.parse(&bytes));
}
