const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // The releases leave the debug information out of the game, which on Linux the executable
    // would otherwise carry, several times the size of its code.
    const strip = b.option(bool, "strip", "Leave the debug information out of the game and sltool") orelse false;
    // The C libraries' headers become Zig modules through the translate-c package, which the build
    // compiles for the host first.
    const translate_c = b.dependency("translate_c", .{});

    // The library: readers for the game's files and the port of the game itself, shared by the
    // game and every tool.
    const lib = b.addModule("openreliant", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    // The outline font OpenReliant carries built in, Newtown, which deps/newtown describes.
    lib.addAnonymousImport("Newtown.ttf", .{ .root_source_file = b.path("deps/newtown/Newtown.ttf") });
    addZlib(b, translate_c, lib, target);

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
        .system_include_path = b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "usr/include" })),
        .system_framework_path = b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "System/Library/Frameworks" })),
        .library_path = b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "usr/lib" })),
    }) else b.dependency("sdl", .{ .target = target, .optimize = optimize });
    const sdl_library = sdl_dependency.artifact("SDL3");
    const platform = b.createModule(.{
        .root_source_file = b.path("src/platform.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "openreliant", .module = lib },
            .{ .name = "sdl", .module = translateHeader(translate_c, b.path("src/platform/sdl.h"), sdl_library, target, optimize) },
        },
    });
    // Mod post effects compile through glslang and SPIRV-Cross. Keep their C++ exceptions
    // inside the platform wrapper, and ship the upstream notices with the executable.
    const shader_dependency = b.dependency("shader_compiler", .{ .target = target, .optimize = .fast });
    const shader_library = shader_dependency.artifact("shader-compiler");
    platform.linkLibrary(shader_library);
    platform.addIncludePath(shader_library.getEmittedIncludeTree());
    platform.addCSourceFile(.{ .file = b.path("src/platform/shader_compiler.cpp"), .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" } });
    // The pinned versions of the libraries, which the shader cache's key covers.
    platform.addAnonymousImport("shader-compiler.zon", .{ .root_source_file = b.path("deps/shader-compiler/build.zig.zon") });
    for ([_][]const u8{ "LICENSE-glslang.txt", "LICENSE-spirv-cross.txt" }) |notice| {
        b.getInstallStep().dependOn(&b.addInstallFile(shader_dependency.namedLazyPath(notice), notice).step);
    }
    // Mods' pictures are compressed for the GPU with bc7enc and rgbcx, built optimized whatever the
    // game's mode, as compressing a large picture is slow otherwise.
    const texture_dependency = b.dependency("texture_compressor", .{ .target = target, .optimize = .fast });
    const texture_library = texture_dependency.artifact("texture-compressor");
    platform.linkLibrary(texture_library);
    platform.addIncludePath(texture_library.getEmittedIncludeTree());
    platform.addCSourceFile(.{ .file = b.path("src/platform/texture_compressor.cpp"), .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" } });
    b.getInstallStep().dependOn(&b.addInstallFile(texture_dependency.namedLazyPath("LICENSE-bc7enc.txt"), "LICENSE-bc7enc.txt").step);
    // The sound: OpenAL Soft in place of Miles's 3D providers, which deps/openal-soft builds from
    // source for the target and the platform renders through its loopback device. It is built
    // optimized whatever the game's own mode: its mixer runs in the audio device's callback and has
    // to keep up with it, and unoptimized, HRTF over a burst of gunfire's voices falls behind and
    // the sound stutters.
    const openal_library = b.dependency("openal_soft", .{ .target = target, .optimize = .fast }).artifact("openal");
    platform.addImport("al", translateHeader(translate_c, b.path("src/platform/openal.h"), openal_library, target, optimize));
    // The movies: FFmpeg's Bink decoders in place of RAD's Bink library, which deps/ffmpeg builds
    // from source for the target. It is built optimized whatever mode the game is built in, as
    // OpenAL Soft is, so that a movie decodes in time in a debug build too.
    const ffmpeg_library = b.dependency("ffmpeg", .{ .target = target, .optimize = .fast }).artifact("avcodec");
    platform.addImport("av", translateHeader(translate_c, b.path("src/platform/ffmpeg.h"), ffmpeg_library, target, optimize));
    // The outline fonts, which draw the interface's text at the window's resolution: FreeType,
    // which deps/freetype builds from source for the target. It is built optimized whatever mode
    // the game is built in, as FFmpeg is, so that a font's glyphs are drawn in time in a debug
    // build too.
    const freetype_library = b.dependency("freetype", .{ .target = target, .optimize = .fast }).artifact("freetype");
    platform.addImport("ft", translateHeader(translate_c, b.path("src/platform/freetype.h"), freetype_library, target, optimize));
    if (macos_sdk) |sdk| {
        // OpenAL Soft reads its configuration through CoreFoundation on a Mac.
        addMacosSdk(b, openal_library.root_module, sdk);
        addMacosSdk(b, platform, sdk);
    }
    // Mod scripts: OpenReliant's scripting module (`src/scripting.zig`) on Luau, which deps/luau
    // builds from source for the target. Like FreeType, Luau is always built optimized so that
    // scripts run fast in debug builds too. Only the game links it; the library the tools share
    // doesn't.
    const luau_library = b.dependency("luau", .{ .target = target, .optimize = .fast }).artifact("luau");
    const scripting = b.createModule(.{
        .root_source_file = b.path("src/scripting.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "openreliant", .module = lib },
            .{ .name = "luau", .module = translateHeader(translate_c, b.path("src/scripting/luau.h"), luau_library, target, optimize) },
        },
    });
    // The scripting API's definitions and reference page as generated, which its tests check
    // against.
    scripting.addAnonymousImport("openreliant.d.luau", .{ .root_source_file = b.path("docs/guide/openreliant.d.luau") });
    scripting.addAnonymousImport("reference.md", .{ .root_source_file = b.path("docs/guide/reference.md") });
    // The example mods' files, which the tests run as they ship, and the list of their scripts,
    // which a test compiles one by one.
    const examples = exampleFiles(b);
    for (examples) |file| {
        scripting.addAnonymousImport(file, .{ .root_source_file = b.path(b.fmt("examples/mods/{s}", .{file})) });
    }
    const example_scripts = b.addOptions();
    var scripts: std.ArrayList([]const u8) = .empty;
    for (examples) |file| if (std.mem.endsWith(u8, file, ".luau")) scripts.append(b.allocator, file) catch @panic("out of memory");
    example_scripts.addOption([]const []const u8, "scripts", scripts.items);
    scripting.addOptions("example_scripts", example_scripts);
    // The installer unpacks the game's cabinet with libarchive, which deps/libarchive builds from
    // source for the target.
    const archive_dependency = b.dependency("libarchive", .{ .target = target, .optimize = optimize });
    const archive_library = archive_dependency.artifact("archive");
    b.getInstallStep().dependOn(&b.addInstallFile(archive_dependency.namedLazyPath("LICENSE-libarchive.txt"), "LICENSE-libarchive.txt").step);
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
                .{ .name = "archive", .module = translateHeader(translate_c, b.path("src/openreliant/archive.h"), archive_library, target, optimize) },
                .{ .name = "version", .module = version },
            },
        }),
    });
    b.installArtifact(openreliant);

    // Mission 0, OpenReliant's own: the sandbox as a standard mission file, which a tool built for
    // the host writes (`src/openreliant/mission0.zig`). The game plays it as its default mission,
    // from the copy it carries, and the build installs it too, for `sltool` and the original.
    const host_lib = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
    });
    addZlib(b, translate_c, host_lib, b.graph.host);
    const mission0 = b.addExecutable(.{
        .name = "mission0",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/openreliant/mission0.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "openreliant", .module = host_lib }},
        }),
    });
    const mission0_file = b.addRunArtifact(mission0).addOutputFileArg2("mission0.dte", .{});
    openreliant.root_module.addAnonymousImport("mission0.dte", .{ .root_source_file = mission0_file });
    b.getInstallStep().dependOn(&b.addInstallFile(mission0_file, "missions/mission0.dte").step);

    runStep(b, "play", "Run the game", openreliant);

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
    // `zig build sltool` installs sltool alone, without the game and the libraries only it needs,
    // as the mods' release pipeline does to pack mods.
    const sltool_step = b.step("sltool", "Build and install sltool alone");
    sltool_step.dependOn(&b.addInstallArtifact(sltool, .{}).step);

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

    runStep(b, "run", "Run sltool", sltool);

    // Every module's tests, and `zig build check`, which compiles the programs and the tests
    // without linking them (the C libraries, translate-c and mission0 build once first):
    // `zig build check -fincremental --watch` reports compile errors within moments of a save.
    const test_step = b.step("test", "Run tests");
    const check_step = b.step("check", "Check that the programs and the tests compile, without writing binaries");
    for ([_]*std.Build.Module{ lib, platform, scripting, version, openreliant.root_module, sltool.root_module, tablegen.root_module, ghidragen.root_module }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
        check_step.dependOn(&b.addTest(.{ .root_module = module }).step);
    }
    for ([_]*std.Build.Step.Compile{ openreliant, sltool, tablegen, ghidragen }) |program| {
        check_step.dependOn(&b.addExecutable(.{ .name = program.name, .root_module = program.root_module }).step);
    }
}

/// A step `name` that installs everything, then runs `program` with the arguments given after
/// `--`.
fn runStep(b: *std.Build, name: []const u8, description: []const u8, program: *std.Build.Step.Compile) void {
    const run = b.addRunArtifact(program);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step(name, description).dependOn(&run.step);
}

/// The Zig module translate-c makes of `header`, which includes `library`'s headers. The module
/// links `library`, so a module that imports it links the library too. Its structs' fields
/// default to zero, as C's do in a partial initializer, so that the platform code can name only
/// the fields it sets.
fn translateHeader(translate_c: *std.Build.Dependency, header: std.Build.LazyPath, library: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const translator: Translator = .init(translate_c, .{ .c_source_file = header, .target = target, .optimize = optimize, .default_init = true });
    translator.linkLibrary(library);
    return translator.mod;
}

/// Gives `module`, the library built from `src/root.zig`, zlib for `target`, which the PNG reader
/// inflates with (`src/formats/png.zig`): several times faster than `std.compress.flate`. It is
/// built optimized whatever mode the rest is built in, as the other C libraries are. libarchive asks
/// for zlib with the same options, so the game builds and links one copy.
fn addZlib(b: *std.Build, translate_c: *std.Build.Dependency, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const zlib = b.dependency("zlib", .{ .target = target, .optimize = .fast }).artifact("z");
    module.addImport("zlib", translateHeader(translate_c, zlib.getEmittedIncludeTree().path(b, "zlib.h"), zlib, target, .fast));
}

/// Gives `module` the macOS SDK's headers, frameworks and libraries at `sdk`, which a build for a
/// Mac other than the host does not find by itself.
fn addMacosSdk(b: *std.Build, module: *std.Build.Module, sdk: []const u8) void {
    module.addSystemIncludePath(b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "usr/include" })));
    module.addSystemFrameworkPath(b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "System/Library/Frameworks" })));
    module.addLibraryPath(b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "usr/lib" })));
}

/// `git describe` of the checkout against the release tags, such as `v0.2.0-12-gabc1234-dirty`, or
/// nothing where there is no git or no tag, as in a source archive. The build can't track what
/// the answer depends on (new commits, edits to any file), so asking poisons the configuration
/// cache: the build runs build.zig again each time, as it always did before Zig 0.17.
fn describe(b: *std.Build) []const u8 {
    b.graph.poisonCache();
    const root = b.root.toString(b.allocator) catch @panic("out of memory");
    return switch (b.runFallible(&.{ "git", "-C", root, "describe", "--tags", "--match", "v*", "--long", "--dirty", "--abbrev=7" }, .{ .stderr_behavior = .ignore })) {
        .success => |out| std.mem.trimEnd(u8, out, "\n"),
        else => "",
    };
}

/// Every file of the example mods, as `<mod>/<file>`, sorted: a mod's files are directly in its
/// folder.
fn exampleFiles(b: *std.Build) []const []const u8 {
    const io = b.graph.io;
    // The listing runs while build.zig configures, so the build is told to configure again when
    // a mod or a file is added, removed or renamed.
    b.dependOnDirectoryContents(b.path("examples/mods"));
    var mods = b.root.root_dir.handle.openDir(io, b.pathJoin(&.{ b.root.sub_path, "examples/mods" }), .{ .iterate = true }) catch |err| std.debug.panic("can't open examples/mods: {t}", .{err});
    defer mods.close(io);
    var found: std.ArrayList([]const u8) = .empty;
    var each_mod = mods.iterate();
    while (each_mod.next(io) catch |err| std.debug.panic("can't list examples/mods: {t}", .{err})) |mod| {
        if (mod.kind != .directory) continue;
        var folder = mods.openDir(io, mod.name, .{ .iterate = true }) catch |err| std.debug.panic("can't open examples/mods/{s}: {t}", .{ mod.name, err });
        defer folder.close(io);
        b.dependOnDirectoryContents(b.path(b.fmt("examples/mods/{s}", .{mod.name})));
        var each_file = folder.iterate();
        while (each_file.next(io) catch |err| std.debug.panic("can't list examples/mods/{s}: {t}", .{ mod.name, err })) |file| {
            if (file.kind != .file) continue;
            found.append(b.allocator, b.fmt("{s}/{s}", .{ mod.name, file.name })) catch @panic("out of memory");
        }
    }
    std.mem.sort([]const u8, found.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);
    return found.items;
}
