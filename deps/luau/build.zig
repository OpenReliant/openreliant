//! Builds Luau as a static library for mod scripts (`src/scripting.zig`): the VM and the compiler,
//! with the parser and bytecode builder the compiler needs, in C++17. Luau is MIT licensed; its
//! license text is in `LICENSE.txt`, which the releases include, and the README credits it. The
//! version is the release named in the manifest.
//!
//! The source files are the ones Luau's `Sources.cmake` lists for `Luau.Common`, `Luau.Ast`,
//! `Luau.Bytecode`, `Luau.Compiler` and `Luau.VM`. Like Luau's `LUAU_EXTERN_C` option, the build
//! makes the C API (`lua.h`, `lualib.h` and `luacode.h`) `extern "C"`, and makes errors use
//! `longjmp` instead of C++ exceptions, which can't unwind through Zig code. Vectors use Luau's
//! default of three single-precision components.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const upstream = b.dependency("upstream", .{});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true });
    const lib = b.addLibrary(.{ .linkage = .static, .name = "luau", .root_module = module });

    for (include_dirs) |dir| module.addIncludePath(upstream.path(dir));
    module.addCMacro("LUA_USE_LONGJMP", "1");
    module.addCMacro("LUA_API", "extern \"C\"");
    module.addCMacro("LUACODE_API", "extern \"C\"");
    module.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = &sources,
        .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" },
    });

    lib.installHeadersDirectory(upstream.path("VM/include"), "", .{});
    lib.installHeader(upstream.path("Compiler/include/luacode.h"), "luacode.h");
    b.installArtifact(lib);
}

/// The include paths: each library's headers, and the VM's internal ones.
const include_dirs = [_][]const u8{
    "Common/include",
    "Ast/include",
    "Bytecode/include",
    "Compiler/include",
    "VM/include",
    "VM/src",
};

const sources = [_][]const u8{
    // Luau.Common
    "Common/src/BytecodeWire.cpp",
    "Common/src/StringUtils.cpp",
    "Common/src/TimeTrace.cpp",
    // Luau.Ast
    "Ast/src/Allocator.cpp",
    "Ast/src/Ast.cpp",
    "Ast/src/Confusables.cpp",
    "Ast/src/Cst.cpp",
    "Ast/src/Lexer.cpp",
    "Ast/src/Location.cpp",
    "Ast/src/Parser.cpp",
    "Ast/src/PrettyPrinter.cpp",
    // Luau.Bytecode
    "Bytecode/src/BytecodeBuilder.cpp",
    "Bytecode/src/BytecodeDump.cpp",
    "Bytecode/src/BytecodeGraph.cpp",
    "Bytecode/src/Sccp.cpp",
    // Luau.Compiler
    "Compiler/src/Compiler.cpp",
    "Compiler/src/Builtins.cpp",
    "Compiler/src/BuiltinFolding.cpp",
    "Compiler/src/ConstantFolding.cpp",
    "Compiler/src/CostModel.cpp",
    "Compiler/src/TableShape.cpp",
    "Compiler/src/Types.cpp",
    "Compiler/src/ValueTracking.cpp",
    "Compiler/src/lcode.cpp",
    // Luau.VM
    "VM/src/lapi.cpp",
    "VM/src/laux.cpp",
    "VM/src/lbaselib.cpp",
    "VM/src/lbitlib.cpp",
    "VM/src/lbuffer.cpp",
    "VM/src/lbuflib.cpp",
    "VM/src/lbuiltins.cpp",
    "VM/src/lcorolib.cpp",
    "VM/src/ldblib.cpp",
    "VM/src/ldebug.cpp",
    "VM/src/ldo.cpp",
    "VM/src/lfunc.cpp",
    "VM/src/lgc.cpp",
    "VM/src/lgcdebug.cpp",
    "VM/src/linit.cpp",
    "VM/src/lmathlib.cpp",
    "VM/src/lmem.cpp",
    "VM/src/lnumprint.cpp",
    "VM/src/lobject.cpp",
    "VM/src/loslib.cpp",
    "VM/src/lperf.cpp",
    "VM/src/lstate.cpp",
    "VM/src/lstring.cpp",
    "VM/src/lstrlib.cpp",
    "VM/src/ltable.cpp",
    "VM/src/ltablib.cpp",
    "VM/src/ltm.cpp",
    "VM/src/ludata.cpp",
    "VM/src/lutf8lib.cpp",
    "VM/src/lveclib.cpp",
    "VM/src/lintlib.cpp",
    "VM/src/lvmexecute.cpp",
    "VM/src/lclass.cpp",
    "VM/src/lclasslib.cpp",
    "VM/src/lvector.cpp",
    "VM/src/lvmload.cpp",
    "VM/src/lvmutils.cpp",
};
