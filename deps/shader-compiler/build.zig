//! Runtime GLSL compilation (#621). Build the GLSL front end and SPIR-V generator from
//! glslang's CMake source lists, without HLSL or SPIRV-Tools. SPIRV-Cross supplies reflection
//! and Metal output. Both libraries keep C++ exceptions inside the platform's C++ boundary.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const glslang = b.dependency("glslang", .{});
    const cross = b.dependency("spirv_cross", .{});
    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true });
    const lib = b.addLibrary(.{ .name = "shader-compiler", .linkage = .static, .root_module = module });
    module.addIncludePath(glslang.path(""));
    module.addIncludePath(cross.path(""));
    const info = b.addConfigHeader(.{
        .style = .{ .cmake = glslang.path("build_info.h.tmpl") },
        .include_path = "glslang/build_info.h",
    }, .{ .major = 16, .minor = 1, .patch = 0, .flavor = "" });
    module.addConfigHeader(info);
    module.addCMacro("ENABLE_SPIRV", "1");
    const flags: []const []const u8 = &.{ "-std=c++17", "-fno-sanitize=undefined" };
    module.addCSourceFiles(.{ .root = glslang.path(""), .files = &glslang_sources, .flags = flags });
    module.addCSourceFile(.{
        .file = glslang.path(if (target.result.os.tag == .windows) "glslang/OSDependent/Windows/ossource.cpp" else "glslang/OSDependent/Unix/ossource.cpp"),
        .flags = flags,
    });
    module.addCSourceFiles(.{ .root = cross.path(""), .files = &.{ "spirv_cross.cpp", "spirv_parser.cpp", "spirv_cross_parsed_ir.cpp", "spirv_cfg.cpp", "spirv_glsl.cpp", "spirv_msl.cpp" }, .flags = flags });
    lib.installHeadersDirectory(glslang.path("glslang"), "glslang", .{ .include_extensions = &.{ ".h", ".hpp" } });
    lib.installHeadersDirectory(glslang.path("SPIRV"), "SPIRV", .{ .include_extensions = &.{ ".h", ".hpp" } });
    lib.installHeadersDirectory(cross.path(""), "spirv-cross", .{ .include_extensions = &.{ ".h", ".hpp" } });
    lib.installConfigHeader(info);
    // These notices travel with releases, alongside the libraries they cover.
    b.addNamedLazyPath("LICENSE-glslang.txt", glslang.path("LICENSE.txt"));
    b.addNamedLazyPath("LICENSE-spirv-cross.txt", cross.path("LICENSE"));
    b.installArtifact(lib);
}

const glslang_sources = [_][]const u8{
    "glslang/GenericCodeGen/CodeGen.cpp",
    "glslang/GenericCodeGen/Link.cpp",
    "glslang/MachineIndependent/glslang_tab.cpp",
    "glslang/MachineIndependent/attribute.cpp",
    "glslang/MachineIndependent/Constant.cpp",
    "glslang/MachineIndependent/iomapper.cpp",
    "glslang/MachineIndependent/InfoSink.cpp",
    "glslang/MachineIndependent/Initialize.cpp",
    "glslang/MachineIndependent/IntermTraverse.cpp",
    "glslang/MachineIndependent/Intermediate.cpp",
    "glslang/MachineIndependent/ParseContextBase.cpp",
    "glslang/MachineIndependent/ParseHelper.cpp",
    "glslang/MachineIndependent/PoolAlloc.cpp",
    "glslang/MachineIndependent/RemoveTree.cpp",
    "glslang/MachineIndependent/Scan.cpp",
    "glslang/MachineIndependent/ShaderLang.cpp",
    "glslang/MachineIndependent/SpirvIntrinsics.cpp",
    "glslang/MachineIndependent/SymbolTable.cpp",
    "glslang/MachineIndependent/Versions.cpp",
    "glslang/MachineIndependent/intermOut.cpp",
    "glslang/MachineIndependent/limits.cpp",
    "glslang/MachineIndependent/linkValidate.cpp",
    "glslang/MachineIndependent/parseConst.cpp",
    "glslang/MachineIndependent/reflection.cpp",
    "glslang/MachineIndependent/preprocessor/Pp.cpp",
    "glslang/MachineIndependent/preprocessor/PpAtom.cpp",
    "glslang/MachineIndependent/preprocessor/PpContext.cpp",
    "glslang/MachineIndependent/preprocessor/PpScanner.cpp",
    "glslang/MachineIndependent/preprocessor/PpTokens.cpp",
    "glslang/MachineIndependent/propagateNoContraction.cpp",
    "glslang/ResourceLimits/ResourceLimits.cpp",
    "SPIRV/GlslangToSpv.cpp",
    "SPIRV/InReadableOrder.cpp",
    "SPIRV/Logger.cpp",
    "SPIRV/SpvBuilder.cpp",
    "SPIRV/SpvPostProcess.cpp",
    "SPIRV/doc.cpp",
    "SPIRV/SpvTools.cpp",
    "SPIRV/disassemble.cpp",
};
