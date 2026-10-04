const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // The releases leave the debug information out of the game, which on Linux the executable
    // would otherwise carry, several times the size of its code.
    const strip = b.option(bool, "strip", "Leave the debug information out of the game and sltool") orelse false;

    // The library: readers for the game's files and the port of the game itself, shared by the
    // game and every tool.
    const lib = b.addModule("openreliant", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    // The outline font OpenReliant carries built in, Newtown, which deps/newtown describes.
    lib.addAnonymousImport("Newtown.ttf", .{ .root_source_file = b.path("deps/newtown/Newtown.ttf") });

    // The game: SDL3 in place of Win32 and DirectX, from the SDL package, which builds SDL from
    // source for the target.
    // Building for a Mac other than the host, SDL and the game need the SDK's paths: from xcrun.
    const macos_sdk: ?[]const u8 = if (target.result.os.tag == .macos and !target.query.isNative())
        std.mem.trimEnd(u8, b.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }), "\n")
    else
        null;
    const sdl_dependency = if (macos_sdk) |sdk| b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .system_include_path = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) },
        .system_framework_path = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) },
        .library_path = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) },
    }) else b.dependency("sdl", .{ .target = target, .optimize = optimize });
    const sdl_library = sdl_dependency.artifact("SDL3");
    const sdl_c = b.addTranslateC(.{
        .root_source_file = b.path("src/platform/sdl.h"),
        .target = target,
        .optimize = optimize,
    });
    sdl_c.addIncludePath(sdl_library.getEmittedIncludeTree());
    const platform = b.createModule(.{
        .root_source_file = b.path("src/platform.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "openreliant", .module = lib },
            .{ .name = "sdl", .module = sdl_c.createModule() },
        },
    });
    platform.linkLibrary(sdl_library);
    // Mod post effects compile through glslang and SPIRV-Cross. Keep their C++ exceptions
    // inside the platform wrapper, and ship the upstream notices with the executable.
    const shader_dependency = b.dependency("shader_compiler", .{ .target = target, .optimize = .ReleaseFast });
    const shader_library = shader_dependency.artifact("shader-compiler");
    platform.linkLibrary(shader_library);
    platform.addIncludePath(shader_library.getEmittedIncludeTree());
    platform.addCSourceFile(.{ .file = b.path("src/platform/shader_compiler.cpp"), .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" } });
    // The pinned versions of the libraries, which the shader cache's key covers.
    platform.addAnonymousImport("shader-compiler.zon", .{ .root_source_file = b.path("deps/shader-compiler/build.zig.zon") });
    for ([_][]const u8{ "LICENSE-glslang.txt", "LICENSE-spirv-cross.txt" }) |notice| {
        b.getInstallStep().dependOn(&b.addInstallFile(shader_dependency.namedLazyPath(notice), notice).step);
    }
    // The sound: OpenAL Soft in place of Miles's 3D providers, which deps/openal-soft builds from
    // source for the target and the platform renders through its loopback device. It is built
    // optimized whatever the game's own mode: its mixer runs in the audio device's callback and has
    // to keep up with it, and unoptimized, HRTF over a burst of gunfire's voices falls behind and
    // the sound stutters.
    const openal_library = b.dependency("openal_soft", .{ .target = target, .optimize = .ReleaseFast }).artifact("openal");
    const openal_c = b.addTranslateC(.{
        .root_source_file = b.path("src/platform/openal.h"),
        .target = target,
        .optimize = optimize,
    });
    openal_c.addIncludePath(openal_library.getEmittedIncludeTree());
    platform.addImport("al", openal_c.createModule());
    platform.linkLibrary(openal_library);
    // The movies: FFmpeg's Bink decoders in place of RAD's Bink library, which deps/ffmpeg builds
    // from source for the target. It is built optimized whatever mode the game is built in, as
    // OpenAL Soft is, so that a movie decodes in time in a debug build too.
    const ffmpeg_library = b.dependency("ffmpeg", .{ .target = target, .optimize = .ReleaseFast }).artifact("avcodec");
    const ffmpeg_c = b.addTranslateC(.{
        .root_source_file = b.path("src/platform/ffmpeg.h"),
        .target = target,
        .optimize = optimize,
    });
    ffmpeg_c.addIncludePath(ffmpeg_library.getEmittedIncludeTree());
    platform.addImport("av", ffmpeg_c.createModule());
    platform.linkLibrary(ffmpeg_library);
    // The outline fonts, which draw the interface's text at the window's resolution: FreeType,
    // which deps/freetype builds from source for the target. It is built optimized whatever mode
    // the game is built in, as FFmpeg is, so that a font's glyphs are drawn in time in a debug
    // build too.
    const freetype_library = b.dependency("freetype", .{ .target = target, .optimize = .ReleaseFast }).artifact("freetype");
    const freetype_c = b.addTranslateC(.{
        .root_source_file = b.path("src/platform/freetype.h"),
        .target = target,
        .optimize = optimize,
    });
    freetype_c.addIncludePath(freetype_library.getEmittedIncludeTree());
    platform.addImport("ft", freetype_c.createModule());
    platform.linkLibrary(freetype_library);
    if (macos_sdk) |sdk| {
        // OpenAL Soft reads its configuration through CoreFoundation on a Mac.
        addMacosSdk(b, openal_library.root_module, sdk);
        addMacosSdk(b, platform, sdk);
    }
    // Mod scripts: OpenReliant's scripting module (`src/scripting.zig`) on Luau, which deps/luau
    // builds from source for the target. Like FreeType, Luau is always built optimized so that
    // scripts run fast in debug builds too. Only the game links it; the library the tools share
    // doesn't.
    const luau_library = b.dependency("luau", .{ .target = target, .optimize = .ReleaseFast }).artifact("luau");
    const luau_c = b.addTranslateC(.{
        .root_source_file = b.path("src/scripting/luau.h"),
        .target = target,
        .optimize = optimize,
    });
    luau_c.addIncludePath(luau_library.getEmittedIncludeTree());
    const scripting = b.createModule(.{
        .root_source_file = b.path("src/scripting.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "openreliant", .module = lib },
            .{ .name = "luau", .module = luau_c.createModule() },
        },
    });
    scripting.linkLibrary(luau_library);
    // The scripting API's definitions and reference page as generated, which its tests check
    // against.
    scripting.addAnonymousImport("openreliant.d.luau", .{ .root_source_file = b.path("docs/guide/openreliant.d.luau") });
    scripting.addAnonymousImport("reference.md", .{ .root_source_file = b.path("docs/guide/reference.md") });
    // The example mods whose scripts the tests run as they ship.
    const example_files = [_][]const u8{ "wingmen/mod.ini", "wingmen/options.luau", "wingmen/wingman.luau", "wingmen/wingmen.luau", "wingmen/status.luau", "dvd/mod.ini", "dvd/dvd.luau", "custom-order/mod.ini", "custom-order/pulse.luau", "custom-order/action.luau", "drawing-assets/mod.ini", "drawing-assets/drawing.luau", "strafe-run/mod.ini", "strafe-run/order.luau", "strafe-run/actions.luau", "strafe-run/display.luau", "crt/mod.ini", "crt/crt.luau", "crt/crt.frag" };
    for (example_files) |file| {
        scripting.addAnonymousImport(file, .{ .root_source_file = b.path(b.fmt("examples/mods/{s}", .{file})) });
    }
    // The installer unpacks the game's cabinet with libarchive, which deps/libarchive builds from
    // source for the target.
    const archive_library = b.dependency("libarchive", .{ .target = target, .optimize = optimize }).artifact("archive");
    const archive_c = b.addTranslateC(.{
        .root_source_file = b.path("src/openreliant/archive.h"),
        .target = target,
        .optimize = optimize,
    });
    archive_c.addIncludePath(archive_library.getEmittedIncludeTree());
    if (macos_sdk) |sdk| addMacosSdk(b, archive_library.root_module, sdk);
    // The version Release Please keeps in build.zig.zon, and where the checkout is past its last
    // release, for `openreliant --version` and `sltool --version` (`src/version.zig`).
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    build_options.addOption([]const u8, "describe", describe(b));
    const version = b.createModule(.{
        .root_source_file = b.path("src/version.zig"),
        .target = target,
        .optimize = optimize,
    });
    version.addOptions("build_options", build_options);

    const openreliant = b.addExecutable(.{
        .name = "openreliant",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/openreliant/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "openreliant", .module = lib },
                .{ .name = "platform", .module = platform },
                .{ .name = "scripting", .module = scripting },
                .{ .name = "archive", .module = archive_c.createModule() },
                .{ .name = "version", .module = version },
            },
        }),
    });
    openreliant.root_module.linkLibrary(archive_library);
    b.installArtifact(openreliant);

    // Mission 0, OpenReliant's own: the sandbox as a standard mission file, which a tool built for
    // the host writes (`src/openreliant/mission0.zig`). The game plays it as its default mission,
    // from the copy it carries, and the build installs it too, for `sltool` and the original.
    const mission0 = b.addExecutable(.{
        .name = "mission0",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/openreliant/mission0.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "openreliant", .module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = b.graph.host,
            }) }},
        }),
    });
    const mission0_file = b.addRunArtifact(mission0).addOutputFileArg("mission0.dte");
    openreliant.root_module.addAnonymousImport("mission0.dte", .{ .root_source_file = mission0_file });
    b.getInstallStep().dependOn(&b.addInstallFile(mission0_file, "missions/mission0.dte").step);

    const play_step = b.step("play", "Run the game");
    const play_cmd = b.addRunArtifact(openreliant);
    play_step.dependOn(&play_cmd.step);
    play_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| play_cmd.addArgs(args);

    const sltool = b.addExecutable(.{
        .name = "sltool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sltool/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "openreliant", .module = lib },
                .{ .name = "version", .module = version },
            },
        }),
    });
    b.installArtifact(sltool);

    // Derives the engine's static tables from the game binary: the script VM's opcodes, commands
    // and conditions, and the models it loads. Not installed: it is a development tool, run by the
    // `make vm-*` and `make model-tables` targets, and its output is committed.
    const tablegen = b.addExecutable(.{
        .name = "tablegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/tablegen/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "openreliant", .module = lib },
            },
        }),
    });

    const tablegen_step = b.step("tablegen", "Build the generator of the engine's tables");
    tablegen_step.dependOn(&b.addInstallArtifact(tablegen, .{}).step);

    // Writes the names and data types the Ghidra scripts apply, from the Zig definitions. Not
    // installed either: `make ghidra-annotate` runs it.
    const ghidragen = b.addExecutable(.{
        .name = "ghidragen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/ghidragen/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "openreliant", .module = lib },
            },
        }),
    });

    // Its tests check the names tables kept by hand, which Ghidra applies with its own rows.
    for ([_][]const u8{ "LANCER.EXE.tsv", "LANCER.EXE.runtime.tsv", "srd3d.dll.tsv" }) |table| {
        ghidragen.root_module.addAnonymousImport(table, .{
            .root_source_file = b.path(b.fmt("ghidra/names/{s}", .{table})),
        });
    }

    const ghidragen_step = b.step("ghidragen", "Build the Ghidra name and type table generator");
    ghidragen_step.dependOn(&b.addInstallArtifact(ghidragen, .{}).step);

    const run_step = b.step("run", "Run sltool");
    const run_cmd = b.addRunArtifact(sltool);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const lib_tests = b.addTest(.{ .root_module = lib });
    const exe_tests = b.addTest(.{ .root_module = sltool.root_module });
    const tablegen_tests = b.addTest(.{ .root_module = tablegen.root_module });
    const ghidragen_tests = b.addTest(.{ .root_module = ghidragen.root_module });
    const openreliant_tests = b.addTest(.{ .root_module = openreliant.root_module });
    const platform_tests = b.addTest(.{ .root_module = platform });
    const scripting_tests = b.addTest(.{ .root_module = scripting });
    const version_tests = b.addTest(.{ .root_module = version });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(tablegen_tests).step);
    test_step.dependOn(&b.addRunArtifact(ghidragen_tests).step);
    test_step.dependOn(&b.addRunArtifact(openreliant_tests).step);
    test_step.dependOn(&b.addRunArtifact(platform_tests).step);
    test_step.dependOn(&b.addRunArtifact(scripting_tests).step);
    test_step.dependOn(&b.addRunArtifact(version_tests).step);
}

/// Gives `module` the macOS SDK's headers, frameworks and libraries at `sdk`, which a build for a
/// Mac other than the host does not find by itself.
fn addMacosSdk(b: *std.Build, module: *std.Build.Module, sdk: []const u8) void {
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
    module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
}

/// `git describe` of the checkout against the release tags, such as `v0.2.0-12-gabc1234-dirty`, or
/// nothing where there is no git or no tag, as in a source archive.
fn describe(b: *std.Build) []const u8 {
    var code: u8 = undefined;
    const out = b.runAllowFail(&.{ "git", "-C", b.build_root.path orelse ".", "describe", "--tags", "--match", "v*", "--long", "--dirty", "--abbrev=7" }, &code, .ignore) catch return "";
    return std.mem.trimEnd(u8, out, "\n");
}
