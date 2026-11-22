//! How much of the computer's memory is free, so that the game takes no more than there is.
//!
//! An allocation that the computer can't back doesn't fail on most systems: Linux and macOS
//! promise the memory and then swap, and where the swap fills too, Linux stalls and kills
//! processes. An integrated GPU's video memory is the same memory. So the game asks what is free
//! before it loads something large, rather than waiting for a failure that comes too late.

const std = @import("std");
const builtin = @import("builtin");

/// The bytes of memory the system could give a process now without swapping: what is free, and
/// what it holds only as cache. Null where the system doesn't say.
pub fn available(io: std.Io, gpa: std.mem.Allocator) ?u64 {
    return switch (builtin.os.tag) {
        .linux => linux(io, gpa),
        .macos => macos(),
        .windows => windows(),
        else => null,
    };
}

/// `MemAvailable` of `/proc/meminfo`, the kernel's own estimate.
fn linux(io: std.Io, gpa: std.mem.Allocator) ?u64 {
    const text = std.Io.Dir.cwd().readFileAlloc(io, "/proc/meminfo", gpa, .limited(64 * 1024)) catch return null;
    defer gpa.free(text);
    return memAvailable(text);
}

/// The bytes the `MemAvailable` line of `text`, a `/proc/meminfo`, gives in kB.
fn memAvailable(text: []const u8) ?u64 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const rest = std.mem.cutPrefix(u8, line, "MemAvailable:") orelse continue;
        var words = std.mem.tokenizeAny(u8, rest, " \t");
        const kilobytes = std.fmt.parseInt(u64, words.next() orelse return null, 10) catch return null;
        return kilobytes * 1024;
    }
    return null;
}

test memAvailable {
    const text = "MemTotal:       15625000 kB\nMemFree:          812345 kB\nMemAvailable:    2048000 kB\nBuffers:           10000 kB\n";
    try std.testing.expectEqual(2048000 * 1024, memAvailable(text).?);
    try std.testing.expectEqual(null, memAvailable("MemTotal: 1 kB\n"));
    try std.testing.expectEqual(null, memAvailable("MemAvailable: lots\n"));
}

/// `host_statistics64`'s `HOST_VM_INFO64` (`mach/host_info.h`), and the pages of
/// `vm_statistics64` (`mach/vm_statistics.h`) counted as 32-bit words: the free, the inactive and
/// the purgeable pages, which the system gives up before it swaps.
const host_vm_info64 = 4;
const vm_words = 40;
const free_word = 0;
const inactive_word = 2;
const purgeable_word = 22;

extern "c" fn mach_host_self() u32;
extern "c" fn host_statistics64(host: u32, flavor: c_int, info: *[vm_words]u32, count: *u32) c_int;

fn macos() ?u64 {
    var words: [vm_words]u32 = @splat(0);
    var count: u32 = vm_words;
    if (host_statistics64(mach_host_self(), host_vm_info64, &words, &count) != 0) return null;
    if (count <= purgeable_word) return null;
    const pages = @as(u64, words[free_word]) + words[inactive_word] + words[purgeable_word];
    return pages * std.heap.pageSize();
}

/// `MEMORYSTATUSEX` (`sysinfoapi.h`), whose `ullAvailPhys` is the physical memory free now.
const MemoryStatus = extern struct {
    length: u32 = @sizeOf(MemoryStatus),
    load: u32 = 0,
    total_physical: u64 = 0,
    available_physical: u64 = 0,
    total_page_file: u64 = 0,
    available_page_file: u64 = 0,
    total_virtual: u64 = 0,
    available_virtual: u64 = 0,
    available_extended_virtual: u64 = 0,
};

extern "kernel32" fn GlobalMemoryStatusEx(status: *MemoryStatus) callconv(.winapi) c_int;

fn windows() ?u64 {
    var status: MemoryStatus = .{};
    if (GlobalMemoryStatusEx(&status) == 0) return null;
    return status.available_physical;
}

test available {
    // Every system the game runs on says, and none says nothing is free while a test runs.
    const free = available(std.testing.io, std.testing.allocator) orelse return error.SkipZigTest;
    try std.testing.expect(free > 0);
}
