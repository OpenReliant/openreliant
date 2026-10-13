//! Builds the part of FFmpeg that OpenReliant uses as a static library: the Bink video and audio
//! decoders for the game's movies (`libavcodec/bink.c`, `libavcodec/binkaudio.c`), the MP3 decoder
//! for the crew's lines and mods' recordings (`libavcodec/mpegaudiodec_float.c`), the FLAC decoder
//! for mods' recordings (`libavcodec/flacdec.c`), and the parts of `libavcodec` and `libavutil`
//! they need. It is plain C, without FFmpeg's assembly or threads. OpenReliant reads the Bink
//! container and the MP3 frames itself (`src/formats/bink.zig`, `src/formats/mp3.zig`) and hands
//! the FLAC decoder whole files, so none of `libavformat` is built. FFmpeg is LGPL-2.1 or later
//! (the upstream's `LICENSE.md`), and none of its GPL parts are built.
//!
//! The files and the configuration are the ones FFmpeg's `configure` gives for
//! `--disable-everything --disable-asm --disable-pthreads
//! --enable-decoder=bink,binkaudio_rdft,binkaudio_dct,mp3float,flac`, minus what the decoding
//! calls never reach: the objects that a program using those calls links, and the settings those
//! files read. The one addition is `libavutil/sha.c`, which the random seed falls back on when no
//! system source of random numbers is set up, as here. The version is the upstream release that
//! the manifest names.
//!
//! Without threads, FFmpeg's one-time setup isn't guarded, so the library is used from one thread.

const std = @import("std");

const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const upstream = b.dependency("upstream", .{});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const windows = target.result.os.tag == .windows;

    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    const lib = b.addLibrary(.{ .linkage = .static, .name = "avcodec", .root_module = module });

    // The settings the files read: plain C for any processor, and the aligned memory and the C99
    // maths every target has.
    const config = b.addConfigHeader(.{ .style = .blank, .include_path = "config.h" }, .{
        .ARCH_X86 = false,
        .HAVE_BIGENDIAN = false,
        .HAVE_FAST_64BIT = false,
        .HAVE_SIMD_ALIGN_32 = false,
        .HAVE_SIMD_ALIGN_64 = false,
        .HAVE_THREADS = false,
        .HAVE_POSIX_MEMALIGN = !windows,
        .HAVE_ALIGNED_MALLOC = windows,
        .CONFIG_GRAY = false,
        .CONFIG_LIBLCEVC_DEC = false,
        .CONFIG_MEMORY_POISONING = false,
        .CONFIG_SAFE_BITSTREAM_READER = true,
    });
    for (maths) |name| config.addValue(b.fmt("HAVE_{s}", .{name}), bool, true);
    const components = b.addConfigHeader(.{ .style = .blank, .include_path = "config_components.h" }, .{
        .CONFIG_BINK_DECODER = true,
        .CONFIG_BINKAUDIO_DCT_DECODER = true,
        .CONFIG_BINKAUDIO_RDFT_DECODER = true,
        .CONFIG_MP3FLOAT_DECODER = true,
        .CONFIG_FLAC_DECODER = true,
    });
    const avconfig = b.addConfigHeader(.{ .style = .blank, .include_path = "libavutil/avconfig.h" }, .{
        .AV_HAVE_BIGENDIAN = false,
        .AV_HAVE_FAST_UNALIGNED = false,
    });
    const ffversion = b.addConfigHeader(.{ .style = .blank, .include_path = "libavutil/ffversion.h" }, .{
        .FFMPEG_VERSION = manifest.version,
    });
    for ([_]*std.Build.Step.ConfigHeader{ config, components, avconfig, ffversion }) |header| module.addConfigHeader(header);

    // The lists `configure` writes of the codecs and the bitstream filters built.
    const lists = b.addWriteFiles();
    _ = lists.add("libavcodec/codec_list.c",
        \\static const FFCodec * const codec_list[] = {
        \\    &ff_bink_decoder,
        \\    &ff_binkaudio_dct_decoder,
        \\    &ff_binkaudio_rdft_decoder,
        \\    &ff_mp3float_decoder,
        \\    &ff_flac_decoder,
        \\    NULL };
        \\
    );
    _ = lists.add("libavcodec/bsf_list.c",
        \\static const FFBitStreamFilter * const bitstream_filters[] = {
        \\    NULL };
        \\
    );
    module.addIncludePath(lists.getDirectory());
    module.addIncludePath(upstream.path(""));
    module.addCMacro("HAVE_AV_CONFIG_H", "1");
    module.addCMacro("_ISOC11_SOURCE", "1");
    module.addCMacro("_FILE_OFFSET_BITS", "64");
    module.addCMacro("_LARGEFILE_SOURCE", "1");
    module.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = &sources,
        .flags = &.{ "-std=c17", "-fno-math-errno", "-fno-sanitize=undefined" },
    });

    lib.installHeadersDirectory(upstream.path("libavcodec"), "libavcodec", .{});
    lib.installHeadersDirectory(upstream.path("libavutil"), "libavutil", .{});
    lib.installConfigHeader(avconfig);
    b.installArtifact(lib);
}

/// The C99 maths `libavutil/libm.h` stands in for where a system lacks them.
const maths = [_][]const u8{
    "ATAN2F",
    "ATANF",
    "CBRT",
    "CBRTF",
    "COPYSIGN",
    "COSF",
    "ERF",
    "EXP2",
    "EXP2F",
    "EXPF",
    "HYPOT",
    "ISFINITE",
    "ISINF",
    "ISNAN",
    "LDEXPF",
    "LLRINT",
    "LLRINTF",
    "LOG10F",
    "LOG2",
    "LOG2F",
    "LRINT",
    "LRINTF",
    "POWF",
    "RINT",
    "ROUND",
    "ROUNDF",
    "SINF",
    "TRUNC",
    "TRUNCF",
};

const sources = [_][]const u8{
    "libavcodec/allcodecs.c",
    "libavcodec/avcodec.c",
    "libavcodec/bink.c",
    "libavcodec/binkaudio.c",
    "libavcodec/binkdsp.c",
    "libavcodec/bitstream_filters.c",
    "libavcodec/blockdsp.c",
    "libavcodec/bsf.c",
    "libavcodec/codec_desc.c",
    "libavcodec/codec_par.c",
    "libavcodec/dct32_fixed.c",
    "libavcodec/dct32_float.c",
    "libavcodec/decode.c",
    "libavcodec/encode.c",
    "libavcodec/exif.c",
    "libavcodec/flac.c",
    "libavcodec/flacdata.c",
    "libavcodec/flacdec.c",
    "libavcodec/flacdsp.c",
    "libavcodec/get_buffer.c",
    "libavcodec/hpeldsp.c",
    "libavcodec/mpegaudio.c",
    "libavcodec/mpegaudiodata.c",
    "libavcodec/mpegaudiodec_common.c",
    "libavcodec/mpegaudiodec_float.c",
    "libavcodec/mpegaudiodecheader.c",
    "libavcodec/mpegaudiodsp.c",
    "libavcodec/mpegaudiodsp_data.c",
    "libavcodec/mpegaudiodsp_fixed.c",
    "libavcodec/mpegaudiodsp_float.c",
    "libavcodec/mpegaudiotabs.c",
    "libavcodec/options.c",
    "libavcodec/packet.c",
    "libavcodec/profiles.c",
    "libavcodec/threadprogress.c",
    "libavcodec/tiff_common.c",
    "libavcodec/utils.c",
    "libavcodec/vlc.c",
    "libavcodec/wma_freqs.c",

    "libavutil/avsscanf.c",
    "libavutil/avstring.c",
    "libavutil/bprint.c",
    "libavutil/buffer.c",
    "libavutil/channel_layout.c",
    "libavutil/container_fifo.c",
    "libavutil/cpu.c",
    "libavutil/crc.c",
    "libavutil/dict.c",
    "libavutil/display.c",
    "libavutil/error.c",
    "libavutil/eval.c",
    "libavutil/fifo.c",
    "libavutil/float_dsp.c",
    "libavutil/float_scalarproduct.c",
    "libavutil/frame.c",
    "libavutil/hwcontext.c",
    "libavutil/imgutils.c",
    "libavutil/log.c",
    "libavutil/log2_tab.c",
    "libavutil/mastering_display_metadata.c",
    "libavutil/mathematics.c",
    "libavutil/mem.c",
    "libavutil/opt.c",
    "libavutil/parseutils.c",
    "libavutil/pixdesc.c",
    "libavutil/random_seed.c",
    "libavutil/rational.c",
    "libavutil/refstruct.c",
    "libavutil/reverse.c",
    "libavutil/samplefmt.c",
    "libavutil/sha.c",
    "libavutil/side_data.c",
    "libavutil/time.c",
    "libavutil/timecode_internal.c",
    "libavutil/tx.c",
    "libavutil/tx_double.c",
    "libavutil/tx_float.c",
    "libavutil/tx_int32.c",
    "libavutil/utils.c",
};
