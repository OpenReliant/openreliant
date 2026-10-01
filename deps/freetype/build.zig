//! Builds FreeType as a static library for the outline fonts, which draw the interface's text at
//! the window's resolution (`src/platform/fonts.zig`): its TrueType and CFF drivers, which read
//! TrueType and OpenType fonts, the modules they need, its auto-hinter and its anti-aliasing
//! rasterizer, in plain C. FreeType is offered under two licences, and OpenReliant takes it under
//! the FreeType License (the upstream's `docs/FTL.TXT`), whose credit the README gives. The version
//! is the manifest's, which names the upstream's release.
//!
//! The files are those the upstream's `docs/INSTALL.ANY` names for these modules, and `ftmm.c`,
//! which the drivers reach for the instances of variable fonts; the library registers these
//! modules alone (`ftmodule.h` here) in place of its default list. The options are the upstream's
//! own (`include/freetype/config/ftoption.h`), whose zlib support, the gzip module here, reads the
//! fonts WOFF packs.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const upstream = b.dependency("upstream", .{});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    const lib = b.addLibrary(.{ .linkage = .static, .name = "freetype", .root_module = module });

    // The modules `FT_Init_FreeType` registers, which `FT_CONFIG_MODULES_H` names.
    const modules = b.addWriteFiles();
    _ = modules.add("openreliant/ftmodule.h",
        \\FT_USE_MODULE( FT_Module_Class, autofit_module_class )
        \\FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
        \\FT_USE_MODULE( FT_Driver_ClassRec, cff_driver_class )
        \\FT_USE_MODULE( FT_Module_Class, psaux_module_class )
        \\FT_USE_MODULE( FT_Module_Class, psnames_module_class )
        \\FT_USE_MODULE( FT_Module_Class, pshinter_module_class )
        \\FT_USE_MODULE( FT_Module_Class, sfnt_module_class )
        \\FT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )
        \\
    );
    module.addIncludePath(modules.getDirectory());
    module.addIncludePath(upstream.path("include"));
    module.addCMacro("FT2_BUILD_LIBRARY", "1");
    module.addCMacro("FT_CONFIG_MODULES_H", "<openreliant/ftmodule.h>");
    module.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = &sources,
        .flags = &.{ "-std=c99", "-fno-sanitize=undefined" },
    });

    lib.installHeadersDirectory(upstream.path("include"), "", .{});
    b.installArtifact(lib);
}

const sources = [_][]const u8{
    "src/base/ftsystem.c",
    "src/base/ftinit.c",
    "src/base/ftdebug.c",
    "src/base/ftbase.c",
    "src/base/ftbbox.c",
    "src/base/ftbitmap.c",
    "src/base/ftmm.c",
    "src/autofit/autofit.c",
    "src/cff/cff.c",
    "src/gzip/ftgzip.c",
    "src/psaux/psaux.c",
    "src/pshinter/pshinter.c",
    "src/psnames/psnames.c",
    "src/sfnt/sfnt.c",
    "src/smooth/smooth.c",
    "src/truetype/truetype.c",
};
