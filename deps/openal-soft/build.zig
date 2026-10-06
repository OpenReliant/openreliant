//! Builds OpenAL Soft as a static library for the sound: its mixer, its effects and its HRTF,
//! rendered through the loopback device into the platform's own audio stream, so none of its
//! platform backends are built. OpenAL Soft is LGPL-2.1 (the upstream's `COPYING`).

const std = @import("std");

const version: std.SemanticVersion = .{ .major = 1, .minor = 25, .patch = 2 };

pub fn build(b: *std.Build) void {
    const upstream = b.dependency("upstream", .{});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    const arch = target.result.cpu.arch;
    const windows = os == .windows;
    const x86 = arch.isX86();

    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });
    const lib = b.addLibrary(.{ .linkage = .static, .name = "openal", .root_module = module });

    const config = b.addConfigHeader(.{ .style = .{ .cmake = upstream.path("config.h.in") }, .include_path = "config.h" }, .{
        .ALSOFT_FORCE_ALIGN = "",
        .ALSOFT_EMBED_HRTF_DATA = true,
        .HAVE_PROC_PIDPATH = os == .macos,
        .HAVE_DLFCN_H = !windows,
        .HAVE_PTHREAD_NP_H = null,
        .HAVE_CPUID_H = x86 and !windows,
        .HAVE_INTRIN_H = windows,
        .HAVE_GUIDDEF_H = windows,
        .HAVE_GCC_GET_CPUID = x86 and !windows,
        .HAVE_CPUID_INTRINSIC = x86 and windows,
        .HAVE_PTHREAD_SETSCHEDPARAM = !windows,
        .HAVE_PTHREAD_SETNAME_NP = !windows,
        .HAVE_PTHREAD_SET_NAME_NP = null,
        .ALSOFT_INSTALL_DATADIR = null,
        .HAVE_DLOPEN_NOTES = null,
        .HAVE_CXXMODULES = false,
        .HAVE_DYNLOAD = false,
        .HAVE_RTKIT = false,
        .ALSOFT_UWP = false,
        .ALSOFT_EAX = false,
    });
    // Only the loopback and null devices, which every system has.
    const backends = b.addConfigHeader(.{ .style = .{ .cmake = upstream.path("config_backends.h.in") }, .include_path = "config_backends.h" }, .{
        .HAVE_ALSA = false,
        .HAVE_OSS = false,
        .HAVE_PIPEWIRE = false,
        .HAVE_SOLARIS = false,
        .HAVE_SNDIO = false,
        .HAVE_WASAPI = false,
        .HAVE_DSOUND = false,
        .HAVE_WINMM = false,
        .HAVE_PORTAUDIO = false,
        .HAVE_PULSEAUDIO = false,
        .HAVE_JACK = false,
        .HAVE_COREAUDIO = false,
        .HAVE_OPENSL = false,
        .HAVE_OBOE = false,
        .HAVE_WAVE = false,
        .HAVE_SDL3 = false,
        .HAVE_SDL2 = false,
    });
    const neon = arch.isAarch64();
    const simd = b.addConfigHeader(.{ .style = .{ .cmake = upstream.path("config_simd.h.in") }, .include_path = "config_simd.h" }, .{
        .HAVE_SSE = x86,
        .HAVE_SSE2 = x86,
        .HAVE_SSE3 = x86,
        .HAVE_SSE4_1 = x86,
        .HAVE_SSE_INTRINSICS = x86,
        .HAVE_NEON = neon,
    });
    const version_header = b.addConfigHeader(.{ .style = .{ .cmake = upstream.path("version.h.in") }, .include_path = "version.h" }, .{
        .LIB_VERSION = b.fmt("{f}", .{version}),
        .LIB_VERSION_NUM = b.fmt("{d},{d},{d},0", .{ version.major, version.minor, version.patch }),
        .GIT_BRANCH = "",
        .GIT_COMMIT_HASH = "",
    });
    for ([_]*std.Build.Step.ConfigHeader{ config, backends, simd, version_header }) |header| module.addConfigHeader(header);

    // The default HRTF, embedded as `bin2h.script.cmake` embeds it.
    const bin2h = b.addExecutable(.{
        .name = "bin2h",
        .root_module = b.createModule(.{ .root_source_file = b.path("bin2h.zig"), .target = b.graph.host }),
    });
    const embed = b.addRunArtifact(bin2h);
    embed.addFileArg(upstream.path("hrtf/Default HRTF.mhr"));
    const hrtf = embed.addOutputFileArg2("default_hrtf.hpp", .{});
    embed.addArg("default_hrtf");
    module.addIncludePath(hrtf.dirname());

    for ([_][]const u8{ "", "include", "common", "gsl/include", "fmt-11.2.0/include" }) |dir| {
        module.addIncludePath(upstream.path(dir));
    }
    module.addCMacro("AL_BUILD_LIBRARY", "1");
    module.addCMacro("AL_ALEXT_PROTOTYPES", "1");
    module.addCMacro("AL_LIBTYPE_STATIC", "1");
    module.addCMacro("AL_API", "");
    module.addCMacro("ALC_API", "");
    if (windows) {
        module.addCMacro("_WIN32", "1");
        module.addCMacro("NOMINMAX", "1");
        module.addCMacro("WIN32_LEAN_AND_MEAN", "1");
        module.addCMacro("NTDDI_VERSION", "NTDDI_VISTA");
    }

    const flags: []const []const u8 = &.{ "-std=c++20", "-fno-sanitize=undefined" };
    module.addCSourceFiles(.{ .root = upstream.path(""), .files = &sources, .flags = flags });
    if (x86) module.addCSourceFiles(.{ .root = upstream.path(""), .files = &sse_sources, .flags = flags });
    if (neon) module.addCSourceFiles(.{ .root = upstream.path(""), .files = &.{"core/mixer/mixer_neon.cpp"}, .flags = flags });
    if (windows) {
        for ([_][]const u8{ "ole32", "shell32", "user32", "winmm" }) |name| module.linkSystemLibrary(name, .{});
    }

    lib.installHeadersDirectory(upstream.path("include/AL"), "AL", .{});
    b.installArtifact(lib);
}

const sources = [_][]const u8{
    "common/alcomplex.cpp",
    "common/almalloc.cpp",
    "common/alstring.cpp",
    "common/althrd_setname.cpp",
    "common/altypes.cpp",
    "common/dynload.cpp",
    "common/filesystem.cpp",
    "common/pffft.cpp",
    "common/polyphase_resampler.cpp",
    "common/strutils.cpp",

    "core/ambdec.cpp",
    "core/ambidefs.cpp",
    "core/bformatdec.cpp",
    "core/bs2b.cpp",
    "core/bsinc_tables.cpp",
    "core/context.cpp",
    "core/converter.cpp",
    "core/cpu_caps.cpp",
    "core/cubic_tables.cpp",
    "core/devformat.cpp",
    "core/device.cpp",
    "core/effectslot.cpp",
    "core/except.cpp",
    "core/filters/biquad.cpp",
    "core/filters/nfc.cpp",
    "core/filters/splitter.cpp",
    "core/fpu_ctrl.cpp",
    "core/helpers.cpp",
    "core/hrtf.cpp",
    "core/hrtf_loader.cpp",
    "core/hrtf_resource.cpp",
    "core/logging.cpp",
    "core/mastering.cpp",
    "core/mixer.cpp",
    "core/storage_formats.cpp",
    "core/tsmefilter.cpp",
    "core/uhjfilter.cpp",
    "core/uiddefs.cpp",
    "core/voice.cpp",
    "core/mixer/mixer_c.cpp",

    "al/auxeffectslot.cpp",
    "al/buffer.cpp",
    "al/debug.cpp",
    "al/effect.cpp",
    "al/effects/autowah.cpp",
    "al/effects/chorus.cpp",
    "al/effects/compressor.cpp",
    "al/effects/convolution.cpp",
    "al/effects/dedicated.cpp",
    "al/effects/distortion.cpp",
    "al/effects/echo.cpp",
    "al/effects/effects.cpp",
    "al/effects/equalizer.cpp",
    "al/effects/fshifter.cpp",
    "al/effects/modulator.cpp",
    "al/effects/null.cpp",
    "al/effects/pshifter.cpp",
    "al/effects/reverb.cpp",
    "al/effects/vmorpher.cpp",
    "al/error.cpp",
    "al/event.cpp",
    "al/extension.cpp",
    "al/filter.cpp",
    "al/listener.cpp",
    "al/source.cpp",
    "al/state.cpp",

    "alc/alc.cpp",
    "alc/alu.cpp",
    "alc/alconfig.cpp",
    "alc/context.cpp",
    "alc/device.cpp",
    "alc/effects/autowah.cpp",
    "alc/effects/chorus.cpp",
    "alc/effects/compressor.cpp",
    "alc/effects/convolution.cpp",
    "alc/effects/dedicated.cpp",
    "alc/effects/distortion.cpp",
    "alc/effects/echo.cpp",
    "alc/effects/equalizer.cpp",
    "alc/effects/fshifter.cpp",
    "alc/effects/modulator.cpp",
    "alc/effects/null.cpp",
    "alc/effects/pshifter.cpp",
    "alc/effects/reverb.cpp",
    "alc/effects/vmorpher.cpp",
    "alc/events.cpp",
    "alc/panning.cpp",
    "alc/backends/base.cpp",
    "alc/backends/loopback.cpp",
    "alc/backends/null.cpp",

    "fmt-11.2.0/src/format.cc",
    "fmt-11.2.0/src/os.cc",
};

const sse_sources = [_][]const u8{
    "core/mixer/mixer_sse.cpp",
    "core/mixer/mixer_sse2.cpp",
    "core/mixer/mixer_sse3.cpp",
    "core/mixer/mixer_sse41.cpp",
};
