//! Texture compression for mods' pictures (#503): Richard Geldreich's bc7enc for BC7 and rgbcx for
//! BC5, from bc7enc_rdo, under its MIT licence. Only the two encoders are built, not the repository's
//! tools, its ISPC encoder or its PNG reader.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bc7enc = b.dependency("bc7enc", .{});
    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true });
    const lib = b.addLibrary(.{ .name = "texture-compressor", .linkage = .static, .root_module = module });
    module.addCSourceFiles(.{ .root = bc7enc.path(""), .files = &.{ "bc7enc.cpp", "rgbcx.cpp" }, .flags = &.{ "-std=c++17", "-fno-sanitize=undefined", "-w" } });
    lib.installHeader(bc7enc.path("bc7enc.h"), "bc7enc.h");
    lib.installHeader(bc7enc.path("rgbcx.h"), "rgbcx.h");
    lib.installHeader(bc7enc.path("rgbcx_table4.h"), "rgbcx_table4.h");
    lib.installHeader(bc7enc.path("rgbcx_table4_small.h"), "rgbcx_table4_small.h");
    // The notice travels with releases, alongside the library it covers.
    b.addNamedLazyPath("LICENSE-bc7enc.txt", bc7enc.path("LICENSE"));
    b.installArtifact(lib);
}
