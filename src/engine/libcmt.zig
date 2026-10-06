//! The C runtime linked into the payload: the static multithreaded library of Visual C++ 6.0,
//! LIBCMT. `ghidra/names/LANCER.EXE.runtime.tsv` names its functions and data; the structures
//! here are those of it that the game's own code handles, for naming the payload's memory in
//! Ghidra. OpenReliant runs none of it and uses Zig's standard library instead, for example for
//! the random numbers (`random.zig`).

const std = @import("std");
const assert = std.debug.assert;

const engine = @import("../engine.zig");
const Pointer = engine.Pointer;
const Range = engine.sources.Range;

/// The runtime's code: from `__fpmath`, after the `srmemory.dll` import thunks, to the end of the
/// last runtime function, before the unwind funclets of the game's own functions.
pub const code: Range = .{ .start = 0x004CF23A, .end = 0x004DB99A };

/// A stdio stream, the runtime's `FILE`. `fopen` returns one, and `_iob` holds the first twenty,
/// of which the first three are stdin, stdout and stderr. `sprintf` and its kin write through one
/// on the stack that points at the caller's buffer.
pub const File = extern struct {
    /// The next character to read or write in the buffer.
    ptr: Pointer(u8),
    /// The characters left to read, or the room left to write.
    cnt: i32,
    /// The buffer.
    base: Pointer(u8),
    flag: Flags,
    /// The low-level handle, an index into the runtime's table of open files.
    file: i32,
    charbuf: i32,
    /// The buffer's size.
    bufsiz: i32,
    /// The name of a temporary file, deleted when the stream closes.
    tmpfname: Pointer(u8),

    /// The stream's state: `_IOREAD` and the rest, bit for bit.
    pub const Flags = packed struct(u32) {
        read: bool = false,
        write: bool = false,
        unbuffered: bool = false,
        /// The runtime allocated the buffer, and frees it on close.
        own_buffer: bool = false,
        eof: bool = false,
        failed: bool = false,
        /// The stream writes to a string: `sprintf`'s.
        string: bool = false,
        read_write: bool = false,
        /// The caller supplied the buffer through `setvbuf`.
        user_buffer: bool = false,
        _unused_9: u1 = 0,
        /// `setvbuf` set the buffer's size, which `fseek` then keeps.
        setvbuf: bool = false,
        feof: bool = false,
        /// Flush when the current call returns: a buffer lent to stdout or stderr for one call.
        flush_on_return: bool = false,
        ctrl_z: bool = false,
        /// Flushing commits the file to disk as well.
        commit: bool = false,
        _unused_15: u17 = 0,
    };

    comptime {
        assert(@offsetOf(File, "flag") == 0x0C);
        assert(@offsetOf(File, "file") == 0x10);
        assert(@sizeOf(File) == 0x20);
    }
};

test "stream flags match the runtime's constants" {
    // `sprintf`'s stream is `_IOWRT | _IOSTRG`, and a stream is in use while any of `_IOREAD`,
    // `_IOWRT` and `_IORW` is set.
    try std.testing.expectEqual(0x42, @as(u32, @bitCast(File.Flags{ .write = true, .string = true })));
    try std.testing.expectEqual(0x83, @as(u32, @bitCast(File.Flags{ .read = true, .write = true, .read_write = true })));
    try std.testing.expectEqual(0x4000, @as(u32, @bitCast(File.Flags{ .commit = true })));
}

test {
    std.testing.refAllDecls(@This());
}
