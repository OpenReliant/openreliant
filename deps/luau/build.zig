//! Builds Luau as static libraries, as Luau's `Sources.cmake` splits it: `luau-ast`, the parser
//! (`Luau.Common` and `Luau.Ast`), which the tools that read mission source link alone
//! (`src/source_parser.zig`), and `luau` on top of it, the bytecode builder, the compiler and the
//! VM, which mod scripts run on (`src/scripting.zig`). Both are C++17. Luau is MIT licensed; its
//! license text is in `LICENSE.txt`, which the releases include, and the README credits it. The
//! version is the release named in the manifest.
//!
//! Like Luau's `LUAU_EXTERN_C` option, the build makes the C API (`lua.h`, `lualib.h` and
//! `luacode.h`) `extern "C"`, and makes errors use `longjmp` instead of C++ exceptions, which can't
//! unwind through Zig code. Vectors use Luau's default of three single-precision components. The
//! parser's own C++ API has no C form, so `luau-ast` installs its headers for a C++ shim.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const upstream = b.dependency("upstream", .{});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ast = library(b, upstream, "luau-ast", target, optimize, &ast_sources);
    ast.installHeadersDirectory(upstream.path("Common/include"), "", .{});
    ast.installHeadersDirectory(upstream.path("Ast/include"), "", .{});
    b.installArtifact(ast);

    const lib = library(b, upstream, "luau", target, optimize, &sources);
    lib.root_module.linkLibrary(ast);
    lib.root_module.addCMacro("LUA_USE_LONGJMP", "1");
    lib.root_module.addCMacro("LUA_API", "extern \"C\"");
    lib.root_module.addCMacro("LUACODE_API", "extern \"C\"");
    lib.installHeadersDirectory(upstream.path("VM/include"), "", .{});
    lib.installHeader(upstream.path("Compiler/include/luacode.h"), "luacode.h");
    b.installArtifact(lib);
}

/// A static library `name` of Luau's `files`, which sees every part's headers.
fn library(b: *std.Build, upstream: *std.Build.Dependency, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, files: []const []const u8) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true });
    for (include_dirs) |dir| module.addIncludePath(upstream.path(dir));
    module.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = files,
        .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" },
    });
    return b.addLibrary(.{ .linkage = .static, .name = name, .root_module = module });
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

const ast_sources = [_][]const u8{
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
};

const sources = [_][]const u8{
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
