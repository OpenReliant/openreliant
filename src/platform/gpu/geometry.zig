//! A frame's vertices and indices on the GPU: a vertex buffer and an index buffer, and the transfer
//! buffer that fills both, made larger when a frame outgrows them. The frame's own draws and the
//! shadows' casters each keep one.

const std = @import("std");
const c = @import("sdl");

const gpu = @import("../gpu.zig");
const sdl = @import("../sdl.zig");
const Error = gpu.Error;

pub const Geometry = struct {
    vertices: *c.SDL_GPUBuffer,
    indices: *c.SDL_GPUBuffer,
    /// Both, vertices first and indices from `size` on.
    transfer: *c.SDL_GPUTransferBuffer,
    size: u32,

    /// Sends `vertices` and 32-bit `indices` up in `copy`, into `slot`'s buffers, made first, or
    /// made again larger, where they don't hold them. Nothing goes up without indices.
    pub fn upload(slot: *?Geometry, handle: *c.SDL_GPUDevice, copy: *c.SDL_GPUCopyPass, vertices: []const u8, indices: []const u8) Error!void {
        const vertex_bytes = std.math.cast(u32, vertices.len) orelse return error.OutOfMemory;
        const index_bytes = std.math.cast(u32, indices.len) orelse return error.OutOfMemory;
        if (index_bytes == 0) return;
        const needed = @max(vertex_bytes, index_bytes);
        if (slot.* == null or slot.*.?.size < needed) {
            release(slot, handle);
            slot.* = try make(handle, needed);
        }
        const geometry = slot.*.?;
        const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(handle, geometry.transfer, true) orelse return sdl.fail("SDL_MapGPUTransferBuffer"));
        @memcpy(mapped[0..vertex_bytes], vertices);
        @memcpy(mapped[geometry.size..][0..index_bytes], indices);
        c.SDL_UnmapGPUTransferBuffer(handle, geometry.transfer);
        c.SDL_UploadToGPUBuffer(copy, &.{ .transfer_buffer = geometry.transfer, .offset = 0 }, &.{ .buffer = geometry.vertices, .size = vertex_bytes }, true);
        c.SDL_UploadToGPUBuffer(copy, &.{ .transfer_buffer = geometry.transfer, .offset = geometry.size }, &.{ .buffer = geometry.indices, .size = index_bytes }, true);
    }

    /// The smallest buffers `make` creates.
    const least_size: u32 = std.fmt.parseIntSizeSuffix("64KiB", 10) catch unreachable;

    /// Buffers of at least `needed` bytes each, in powers of two from `least_size`.
    fn make(handle: *c.SDL_GPUDevice, needed: u32) Error!Geometry {
        const size = std.math.ceilPowerOfTwo(u32, @max(needed, least_size)) catch return error.OutOfMemory;
        const transfer_size = std.math.mul(u32, size, 2) catch return error.OutOfMemory;
        const vertices = c.SDL_CreateGPUBuffer(handle, &.{ .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX, .size = size }) orelse return sdl.fail("SDL_CreateGPUBuffer");
        errdefer c.SDL_ReleaseGPUBuffer(handle, vertices);
        const indices = c.SDL_CreateGPUBuffer(handle, &.{ .usage = c.SDL_GPU_BUFFERUSAGE_INDEX, .size = size }) orelse return sdl.fail("SDL_CreateGPUBuffer");
        errdefer c.SDL_ReleaseGPUBuffer(handle, indices);
        const transfer = c.SDL_CreateGPUTransferBuffer(handle, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = transfer_size }) orelse return sdl.fail("SDL_CreateGPUTransferBuffer");
        return .{ .vertices = vertices, .indices = indices, .transfer = transfer, .size = size };
    }

    pub fn release(slot: *?Geometry, handle: *c.SDL_GPUDevice) void {
        const geometry = slot.* orelse return;
        c.SDL_ReleaseGPUBuffer(handle, geometry.vertices);
        c.SDL_ReleaseGPUBuffer(handle, geometry.indices);
        c.SDL_ReleaseGPUTransferBuffer(handle, geometry.transfer);
        slot.* = null;
    }

    /// Binds the buffers for a pass's indexed draws.
    pub fn bind(geometry: Geometry, pass: *c.SDL_GPURenderPass) void {
        c.SDL_BindGPUVertexBuffers(pass, 0, &c.SDL_GPUBufferBinding{ .buffer = geometry.vertices, .offset = 0 }, 1);
        c.SDL_BindGPUIndexBuffer(pass, &c.SDL_GPUBufferBinding{ .buffer = geometry.indices, .offset = 0 }, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);
    }
};
